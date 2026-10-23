#!/usr/bin/env bash
# 运行期共享全局（LOCK_*/PUBLIC_IP_CACHE/HAS_PUBLIC_IPV4/CLOUDFLARED_LATEST_CACHE/NODE_META 等）
# 由 lib/*.sh 各模块消费，跨文件引用 shellcheck 不可见，文件级豁免 SC2034。
# shellcheck disable=SC2034
set -eEuo pipefail

umask 077

PROJECT_NAME="${PROJECT_NAME:-Singbox Manager}"
BASE_DIR="${BASE_DIR:-/usr/local/etc/singbox-manager}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/singbox-manager}"
CONFIG_FILE="${CONFIG_FILE:-${BASE_DIR}/config.json}"
NODES_FILE="${NODES_FILE:-${BASE_DIR}/nodes.json}"
SECRETS_FILE="${SECRETS_FILE:-${BASE_DIR}/secrets.json}"
SETTING_FILE="${SETTING_FILE:-${BASE_DIR}/settings.json}"
CERT_DIR="${CERT_DIR:-${BASE_DIR}/certs}"
LOG_DIR="${LOG_DIR:-${BASE_DIR}/logs}"
RUNTIME_DIR="${RUNTIME_DIR:-${BASE_DIR}/runtime}"
LOCK_FILE="${LOCK_FILE:-${BASE_DIR}/.lock}"
LOCK_TIMEOUT="${LOCK_TIMEOUT:-30}"
LOG_ROTATE_SIZE_MB="${LOG_ROTATE_SIZE_MB:-50}"
LOG_ROTATE_BACKUPS="${LOG_ROTATE_BACKUPS:-3}"

SINGBOX_BIN="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"
SERVICE_NAME="${SERVICE_NAME:-singbox-manager}"
DEFAULT_CDN_DOMAIN="${DEFAULT_CDN_DOMAIN:-saas.sin.fan}"

COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_RED="\033[1;31m"
COLOR_BLUE="\033[1;34m"
COLOR_RESET="\033[0m"
COLOR_NUM_HL="\033[1;92m"

LOCK_HELD=false
LOCK_FD=""
LOCK_DIR_FALLBACK="${LOCK_FILE}.d"
PUBLIC_IP_CACHE="${PUBLIC_IP_CACHE:-}"
HAS_PUBLIC_IPV4=""
CLOUDFLARED_LATEST_CACHE=""
NODE_META=()
# 9.2：证书指纹进程级缓存（key 为"证书路径|mtime"），须在 env.sh（源文件最外层）声明，
# 否则会被 sbm_load_all 的函数作用域吞掉变为局部变量。
declare -A CERT_FP_CACHE=()
_METADATA_PORTS=""
_SYSTEM_PORTS=""
_NET_TUNE_APPLIED=""

# 模块统一加载：source 顺序即依赖顺序，sb.sh / watchdog.sh / 安装校验共用。
# 开发态优先读 SOURCE_ROOT（源码目录），否则读安装态 LIB_DIR。
SBM_MODULES=(env io fmt storage settings network cert render links node-add node-spec node-auto node-cmd argo tune service sub install menu cli-add cli)

sbm_module_path() {
  local m="$1"
  if [ -n "${SOURCE_ROOT:-}" ] && [ -f "${SOURCE_ROOT}/lib/${m}.sh" ]; then
    printf '%s' "${SOURCE_ROOT}/lib/${m}.sh"
  elif [ -f "${LIB_DIR}/${m}.sh" ]; then
    printf '%s' "${LIB_DIR}/${m}.sh"
  fi
}

sbm_load_all() {
  local m f
  for m in "${SBM_MODULES[@]}"; do
    f="$(sbm_module_path "$m")"
    if [ -z "${f}" ]; then
      echo "未找到 lib/${m}.sh。" >&2
      return 1
    fi
    # shellcheck source=/dev/null
    . "${f}"
  done
}

require_bash4() {
  if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "需要 bash 4.0 及以上版本（当前：${BASH_VERSION:-未知}）。" >&2
    exit 1
  fi
}

hl_num() {
  local v="${1:-}"
  case "${v}" in
  '' | *[!0-9.]*) printf '%s' "${v}" ;;
  *) printf '%b%s%b' "${COLOR_NUM_HL}" "${v}" "${COLOR_RESET}" ;;
  esac
}

print_ok() {
  echo -e "${COLOR_GREEN}[成功]${COLOR_RESET} $*"
}

print_warn() {
  echo -e "${COLOR_YELLOW}[警告]${COLOR_RESET} $*" >&2
}

print_err() {
  echo -e "${COLOR_RED}[错误]${COLOR_RESET} $*" >&2
}

print_info() {
  echo -e "${COLOR_BLUE}[信息]${COLOR_RESET} $*"
}

fatal() {
  print_err "$*"
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    fatal "请使用 root 用户运行。"
  fi
}

setup_common_traps() {
  trap 'release_lock' EXIT
  trap 'release_lock; exit 130' INT
  trap 'release_lock; exit 143' TERM
  trap 'handle_common_error "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}" "${BASH_LINENO[0]:-0}" "$?"' ERR
}

handle_common_error() {
  local source_file="$1"
  local line_no="$2"
  local exit_code="$3"
  print_err "命令执行失败：${source_file}:${line_no}"
  # 事务回滚（auto_install 的 rep 窗口）：已清空旧节点但尚未提交时，
  # 失败必须恢复备份，避免停留"旧节点消失、新配置未启动"的不一致状态（F-02）
  if [ -n "${_AUTO_ROLLBACK_DIR:-}" ] && [ -d "${_AUTO_ROLLBACK_DIR}" ]; then
    print_err "检测到未提交的 rep 事务，正在自动恢复到安装前状态..."
    _AUTO_ROLLBACK_DIR=""
    restore_latest_backup || true
    reconcile_state || true
    render_config || true
    start_service || true
  fi
  release_lock
  exit "${exit_code}"
}
