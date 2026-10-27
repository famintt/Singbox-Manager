#!/usr/bin/env bash
# 运行期全局配置（PROJECT_NAME 及以下变量）由 lib/*.sh 各模块消费，
# 跨文件引用 shellcheck 不可见，文件级豁免 SC2034（unused）。
# shellcheck disable=SC2034
set -eEuo pipefail

umask 077

PROJECT_NAME="Singbox 管理器"
SCRIPT_VERSION="1.9.2"
REPO_OWNER="famintt"
REPO_NAME="Singbox-Manager"

INSTALL_BIN="${INSTALL_BIN:-/usr/local/bin/sbm}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/singbox-manager}"
BASE_DIR="${BASE_DIR:-/usr/local/etc/singbox-manager}"
WATCHDOG_TARGET="${BASE_DIR}/watchdog.sh"
UPSTREAM_ENV="${LIB_DIR}/upstream.env"
PID_FILE="${BASE_DIR}/runtime/sing-box.pid"

SINGBOX_BIN="${SINGBOX_BIN:-/usr/local/bin/sing-box}"
CLOUDFLARED_BIN="${CLOUDFLARED_BIN:-/usr/local/bin/cloudflared}"
SERVICE_NAME="singbox-manager"
WATCHDOG_SERVICE_NAME="singbox-manager-watchdog"
WATCHDOG_TIMER_NAME="singbox-manager-watchdog.timer"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SYSTEMD_WATCHDOG_SERVICE_FILE="/etc/systemd/system/${WATCHDOG_SERVICE_NAME}.service"
SYSTEMD_WATCHDOG_TIMER_FILE="/etc/systemd/system/${WATCHDOG_TIMER_NAME}"
OPENRC_SERVICE_FILE="/etc/init.d/${SERVICE_NAME}"

DEFAULT_CDN_DOMAIN="saas.sin.fan"
DEFAULT_REALITY_SERVER="www.bing.com"
DEFAULT_TLS_SERVER="www.apple.com"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT=""
if [ -f "${SCRIPT_DIR}/lib/env.sh" ]; then
  SOURCE_ROOT="${SCRIPT_DIR}"
  # shellcheck source=lib/env.sh
  . "${SCRIPT_DIR}/lib/env.sh"
elif [ -f "${LIB_DIR}/env.sh" ]; then
  # shellcheck source=/usr/local/lib/singbox-manager/env.sh
  . "${LIB_DIR}/env.sh"
else
  echo "未找到 env.sh。" >&2
  exit 1
fi

if [ -n "${SOURCE_ROOT}" ] && [ -f "${SOURCE_ROOT}/metadata/upstream.env" ]; then
  # shellcheck source=metadata/upstream.env
  . "${SOURCE_ROOT}/metadata/upstream.env"
elif [ -f "${UPSTREAM_ENV}" ]; then
  # shellcheck source=/usr/local/lib/singbox-manager/upstream.env
  . "${UPSTREAM_ENV}"
else
  fatal "未找到 upstream.env。"
fi

require_bash4
setup_common_traps

# 职责模块（lib/*.sh）：开发态先找 SCRIPT_DIR/lib，安装态回退 LIB_DIR（顺序见 SBM_MODULES）
if ! sbm_load_all; then
  exit 1
fi

if [ "${SBM_TEST_MODE:-0}" != "1" ]; then
  # 测试钩子：SBM_TEST_MODE=1 时供 tests/smoke.sh source 本文件做函数级验证
  main "$@"
fi
