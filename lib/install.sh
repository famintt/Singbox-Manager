#!/usr/bin/env bash
set -eEuo pipefail

umask 077

detect_arch() {
  case "$(uname -m)" in
  x86_64 | amd64) printf 'amd64' ;;
  aarch64 | arm64) printf 'arm64' ;;
  armv7l | armv7) printf 'armv7' ;;
  armv6l | armv6) printf 'armv6' ;;
  *) return 1 ;;
  esac
}

pkg_install() {
  if [ "$#" -eq 0 ]; then
    fatal "未解析出需要安装的依赖包。"
  fi
  if command_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    # 单个第三方源损坏不应阻断整个安装：update 失败仅告警，最终由
    # verify_runtime_prereqs 校验真正缺失的命令。
    apt-get update -y >/dev/null 2>&1 || print_warn "apt-get update 失败，继续尝试安装依赖。"
    apt-get install -y "$@" || {
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y "$@"
    }
  elif command_exists dnf; then
    dnf install -y "$@"
  elif command_exists yum; then
    yum install -y "$@"
  elif command_exists apk; then
    apk update >/dev/null 2>&1 || true
    apk add --no-cache "$@"
  elif command_exists pacman; then
    pacman -Sy --noconfirm "$@"
  elif command_exists zypper; then
    zypper --non-interactive install "$@"
  else
    fatal "暂不支持当前包管理器，请手动安装以下依赖：$*"
  fi
}

required_commands() {
  printf '%s\n' curl tar jq openssl awk sed grep find head mktemp install nohup tr hostname kill rm mv chmod cat cp
  if systemd_available; then
    printf '%s\n' systemctl
  elif openrc_available; then
    printf '%s\n' rc-service rc-update
  fi
}

deps_present() {
  local cmd
  while IFS= read -r cmd; do
    command_exists "${cmd}" || return 1
  done < <(required_commands)
  command_exists ss || command_exists netstat || return 1
  return 0
}

ensure_dependencies() {
  # 依赖齐全时跳过包管理器（避免每次菜单操作都全量刷新软件源索引）
  if ! deps_present; then
    local packages=()
    if command_exists apt-get; then
      packages=(ca-certificates curl tar jq openssl procps iproute2 util-linux findutils grep sed gawk coreutils)
    elif command_exists dnf || command_exists yum; then
      packages=(ca-certificates curl tar jq openssl procps-ng iproute util-linux findutils grep sed gawk coreutils)
    elif command_exists apk; then
      packages=(ca-certificates curl tar jq openssl procps iproute2 util-linux findutils grep sed gawk coreutils gcompat)
    elif command_exists pacman; then
      packages=(ca-certificates curl tar jq openssl procps-ng iproute2 util-linux findutils grep sed gawk coreutils)
    elif command_exists zypper; then
      packages=(ca-certificates curl tar jq openssl procps iproute2 util-linux findutils grep sed gawk coreutils)
    fi

    pkg_install "${packages[@]}"
  fi
  verify_runtime_prereqs
}

verify_runtime_prereqs() {
  local missing=() cmd
  while IFS= read -r cmd; do
    command_exists "${cmd}" || missing+=("${cmd}")
  done < <(required_commands)

  if ! command_exists ss && ! command_exists netstat; then
    missing+=("ss/netstat")
  fi

  if [ "${#missing[@]}" -gt 0 ]; then
    fatal "缺少必要命令：${missing[*]}"
  fi
}

ensure_binary_runs() {
  local binary="$1"
  local label="$2"
  shift 2

  if "$binary" "$@" >/dev/null 2>&1; then
    return 0
  fi

  if command_exists apk; then
    print_info "检测到 Alpine，正在安装 gcompat 兼容层"
    apk update >/dev/null 2>&1 || true
    apk add --no-cache gcompat >/dev/null 2>&1
  fi

  "$binary" "$@" >/dev/null 2>&1 || fatal "${label} 已安装，但当前系统无法运行。"
}

sync_project_assets_from_source() {
  if [ -z "${SOURCE_ROOT}" ]; then
    return 0
  fi

  init_storage
  install -d -m 700 "${LIB_DIR}" "${BASE_DIR}"
  # 原子替换入口：源码目录直接执行时，sync 会覆盖正在运行的 sbm 自身
  install_atomic "${SOURCE_ROOT}/sb.sh" "${INSTALL_BIN}" 0755
  for lib_file in "${SOURCE_ROOT}"/lib/*.sh; do
    install_atomic "$lib_file" "${LIB_DIR}/$(basename "$lib_file")" 0644
  done
  install_atomic "${SOURCE_ROOT}/metadata/upstream.env" "${UPSTREAM_ENV}" 0644
  install_atomic "${SOURCE_ROOT}/scripts/watchdog.sh" "${WATCHDOG_TARGET}" 0755
  sanitize_permissions
}

install_release_bundle() {
  local tag="$1"
  local bundle_url checksums_url install_url bundle_name tmpdir bundle_file checksums_file installer_file expected root_dir

  tmpdir="$(mktemp -d)"
  bundle_name="singbox-manager-${tag}.tar.gz"
  bundle_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${tag}/${bundle_name}"
  checksums_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${tag}/checksums.txt"
  install_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${tag}/install.sh"
  bundle_file="${tmpdir}/${bundle_name}"
  checksums_file="${tmpdir}/checksums.txt"
  installer_file="${tmpdir}/install.sh"

  if ! download_file "${checksums_url}" "${checksums_file}"; then
    # 兼容历史 Release 未上传 checksums.txt 的情况：回退从同 tag 的 install.sh
    # 读取 PACKAGE_SHA256（发布包摘要始终内嵌在安装器里），避免 sbm update 永久 404。
    print_warn "checksums.txt 不可用，尝试从 install.sh 读取发布包校验值。"
    if ! download_file "${install_url}" "${installer_file}"; then
      rm -rf "${tmpdir}"
      print_err "下载 checksums.txt / install.sh 均失败，无法更新。"
      return 1
    fi
    expected="$(grep -m1 '^PACKAGE_SHA256=' "${installer_file}" 2>/dev/null | grep -o '[a-f0-9]\{64\}' || true)"
  else
    # 兼容 GNU sha256sum 二进制模式输出（文件名带 * 前缀）与 CRLF
    expected="$(awk -v file="${bundle_name}" '{ sub(/\r$/, "", $2); sub(/^\*/, "", $2); if ($2 == file) print $1 }' "${checksums_file}")"
  fi
  if ! download_file "${bundle_url}" "${bundle_file}"; then
    rm -rf "${tmpdir}"
    print_err "下载 ${bundle_name} 失败。"
    return 1
  fi
  if [ -z "${expected}" ]; then
    rm -rf "${tmpdir}"
    print_err "未找到 ${bundle_name} 的校验值，已取消更新。"
    return 1
  fi
  if ! sha256_matches "${bundle_file}" "${expected}"; then
    rm -rf "${tmpdir}"
    print_err "发布包 SHA256 校验失败，已取消更新。"
    return 1
  fi

  tar -xzf "${bundle_file}" -C "${tmpdir}"
  root_dir="$(find "${tmpdir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  if [ -z "${root_dir}" ]; then
    rm -rf "${tmpdir}"
    print_err "发布包结构异常：未找到根目录。"
    return 1
  fi

  # 安装前先校验候选脚本，避免中断/半写入造成新旧版本混装
  if ! bash -n "${root_dir}/sb.sh" || ! bash -n "${root_dir}/scripts/watchdog.sh"; then
    rm -rf "${tmpdir}"
    print_err "发布包脚本语法校验失败，已取消安装（原文件未改动）。"
    return 1
  fi
  for lib_file in "${root_dir}"/lib/*.sh; do
    if ! bash -n "$lib_file"; then
      rm -rf "${tmpdir}"
      print_err "发布包脚本语法校验失败，已取消安装（原文件未改动）。"
      return 1
    fi
  done

  install -d -m 700 "${LIB_DIR}" "${BASE_DIR}"
  # 先装共享库与 watchdog，最后原子替换入口 sbm，保证入口加载到配套实现，
  # 且更新期间正在运行的菜单不会读到被截断的脚本。
  for lib_file in "${root_dir}"/lib/*.sh; do
    install_atomic "$lib_file" "${LIB_DIR}/$(basename "$lib_file")" 0644 || {
      print_err "写入 $(basename "$lib_file") 失败。"
      return 1
    }
  done
  install_atomic "${root_dir}/metadata/upstream.env" "${UPSTREAM_ENV}" 0644 || return 1
  install_atomic "${root_dir}/scripts/watchdog.sh" "${WATCHDOG_TARGET}" 0755 || return 1
  install_atomic "${root_dir}/sb.sh" "${INSTALL_BIN}" 0755 || return 1
  sanitize_permissions
  rm -rf "${tmpdir}"
}

install_singbox_core() {
  local arch asset tmpdir archive binary expected
  local -a urls
  arch="$(detect_arch)" || fatal "暂不支持当前 CPU 架构：$(uname -m)"
  asset="${SINGBOX_ASSET[$arch]:-}"
  expected="${SINGBOX_SHA256[$arch]:-}"
  [ -n "${asset}" ] || fatal "未配置 ${arch} 对应的 sing-box 安装包。"
  [ -n "${expected}" ] || fatal "未配置 ${arch} 对应的 sing-box 校验值。"

  # 官方源优先，官方源不可达时回退本仓库镜像（SHA256 校验不因换源放松）
  local -a urls=()
  urls+=("https://github.com/SagerNet/sing-box/releases/download/${SINGBOX_VERSION}/${asset}")
  [ -n "${SINGBOX_MIRROR_BASE:-}" ] && urls+=("${SINGBOX_MIRROR_BASE}/${asset}")

  tmpdir="$(mktemp -d)"
  archive="${tmpdir}/${asset}"
  print_info "正在安装 sing-box ${SINGBOX_VERSION} (${arch})"
  if ! download_file_multi "${archive}" "${urls[@]}"; then
    rm -rf "${tmpdir}"
    fatal "下载 sing-box 失败（已尝试 ${#urls[@]} 个源）。"
  fi
  verify_sha256 "${archive}" "${expected}"
  tar -xzf "${archive}" -C "${tmpdir}"
  binary="$(find "${tmpdir}" -type f -name sing-box | head -n 1)"
  [ -n "${binary}" ] || fatal "安装包中未找到 sing-box 可执行文件。"
  install -m 0755 "${binary}" "${SINGBOX_BIN}"
  ensure_binary_runs "${SINGBOX_BIN}" "sing-box" version
  rm -rf "${tmpdir}"
  print_ok "sing-box 已安装到 ${SINGBOX_BIN}"
}

cloudflared_runtime_version_ok() {
  local file="$1"
  local expected="$2"
  local actual
  chmod 0755 "${file}" 2>/dev/null || return 1
  actual="$("${file}" version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  [ "${actual}" = "${expected}" ]
}

# 尝试安装单个 cloudflared 版本；失败只返回 1，由调用方决定回退，绝不中途退出。
install_cloudflared_candidate() {
  local version="$1"
  local expected="$2"
  local verify_mode="$3"
  local asset="$4"
  local tmpfile
  local -a urls=()

  urls+=("https://github.com/cloudflare/cloudflared/releases/download/${version}/${asset}")
  [ -n "${CLOUDFLARED_MIRROR_BASE:-}" ] && urls+=("${CLOUDFLARED_MIRROR_BASE}/${asset}")

  tmpfile="$(mktemp)" || return 1
  print_info "正在安装 cloudflared ${version}（${asset}）"
  if ! download_file_multi "${tmpfile}" "${urls[@]}"; then
    rm -f "${tmpfile}"
    print_warn "下载 cloudflared ${version} 失败（已尝试 ${#urls[@]} 个源）。"
    return 1
  fi
  if [ "${verify_mode}" = "sha256" ]; then
    if ! sha256_matches "${tmpfile}" "${expected}"; then
      rm -f "${tmpfile}"
      print_warn "cloudflared ${version} SHA256 校验失败，已丢弃该文件。"
      return 1
    fi
  elif ! cloudflared_runtime_version_ok "${tmpfile}" "${version}"; then
    rm -f "${tmpfile}"
    print_warn "cloudflared ${version} 运行时版本校验失败。"
    return 1
  fi
  if ! install_atomic "${tmpfile}" "${CLOUDFLARED_BIN}" 0755; then
    rm -f "${tmpfile}"
    print_warn "写入 ${CLOUDFLARED_BIN} 失败。"
    return 1
  fi
  rm -f "${tmpfile}"
  if ! ensure_binary_runs "${CLOUDFLARED_BIN}" "cloudflared" version; then
    return 1
  fi
  print_ok "cloudflared 已安装到 ${CLOUDFLARED_BIN}（${version}，校验：${verify_mode}）"
  return 0
}

install_cloudflared_bin() {
  local arch asset fallback_version fallback_expected
  local info latest_version latest_digest runtime_mode
  arch="$(detect_arch)" || fatal "暂不支持当前 CPU 架构：$(uname -m)"
  asset="${CLOUDFLARED_ASSET[$arch]:-}"
  [ -n "${asset}" ] || fatal "未配置 ${arch} 对应的 cloudflared 安装包。"
  fallback_version="${CLOUDFLARED_FALLBACK_VERSION:-}"
  fallback_expected="${CLOUDFLARED_SHA256[$arch]:-}"
  runtime_mode="${CLOUDFLARED_ALLOW_RUNTIME_VERIFY:-0}"

  # 最新版优先：能拿到 GitHub API 的版本+digest 时走完整 SHA256。
  # 拿不到 digest 时不再 fail-closed 卡死安装，而是回退到固定版本（同样完整校验）——
  # 这是"有时装不上"最常见的根因（API 被墙/限流/资产 digest 缺失）。
  if [ "${CLOUDFLARED_LATEST:-false}" = "true" ]; then
    info="$(cloudflared_latest_info "${asset}" 2>/dev/null || true)"
    latest_version="${info%% *}"
    if [ "${info}" = "${latest_version}" ]; then
      latest_digest=""
    else
      latest_digest="${info#* }"
    fi
    if [ -n "${latest_version}" ] && [ -n "${latest_digest}" ]; then
      print_info "cloudflared 官方最新版本：${latest_version}"
      if install_cloudflared_candidate "${latest_version}" "${latest_digest}" sha256 "${asset}"; then
        return 0
      fi
      print_warn "最新版 cloudflared ${latest_version} 安装失败，回退固定版本。"
    elif [ -n "${latest_version}" ] && [ "${latest_version}" = "${fallback_version}" ] && [ -n "${fallback_expected}" ]; then
      # 版本恰好等于固定回退版本：可用固定版本表的 digest 完整校验
      if install_cloudflared_candidate "${latest_version}" "${fallback_expected}" sha256 "${asset}"; then
        return 0
      fi
    elif [ -n "${latest_version}" ] && [ "${runtime_mode}" = "1" ]; then
      print_warn "无法获取 cloudflared ${latest_version} 的官方 digest，按显式配置降级为运行时版本校验。"
      if install_cloudflared_candidate "${latest_version}" "" runtime "${asset}"; then
        return 0
      fi
    elif [ -n "${latest_version}" ]; then
      print_warn "无法获取 cloudflared ${latest_version} 的可信 SHA256，回退固定版本 ${fallback_version:-（未配置）}。"
    else
      print_warn "无法获取 cloudflared 最新版本信息，回退固定版本 ${fallback_version:-（未配置）}。"
    fi
  fi

  if [ "${CLOUDFLARED_LATEST:-false}" != "true" ] && [ -n "${CLOUDFLARED_VERSION:-}" ] &&
    [ "${CLOUDFLARED_VERSION}" != "${fallback_version}" ]; then
    fatal "固定版本模式仅支持内置回退版本 ${fallback_version:-（未配置）}，请改用 CLOUDFLARED_LATEST=true。"
  fi

  # 固定版本兜底（官方 → 本仓库镜像），摘要来自版本表，安全强度不降级。
  if [ -n "${fallback_version}" ] && [ -n "${fallback_expected}" ]; then
    if install_cloudflared_candidate "${fallback_version}" "${fallback_expected}" sha256 "${asset}"; then
      return 0
    fi
    fatal "cloudflared 安装失败：最新版与固定版本 ${fallback_version} 均不可用（已尝试官方源与本仓库镜像）。"
  fi
  fatal "无法获取 cloudflared 可信版本/校验值，拒绝安装未校验的二进制。"
}

install_core() {
  acquire_lock
  ensure_dependencies
  init_storage
  sync_project_assets_from_source
  install_singbox_core
  if argo_required; then
    install_cloudflared_bin
  else
    print_info "未启用 Argo：跳过 cloudflared 安装（仅 Argo 节点需要，节省磁盘与内存）。"
    cleanup_unused_cloudflared
  fi
  ensure_low_memory_guard
  render_config
  apply_network_tune
  if systemd_available; then
    create_systemd_units
  elif openrc_available; then
    create_openrc_units
    create_cron_watchdog
  else
    create_cron_watchdog
  fi
  start_service
  restart_all_argo_nodes
  sanitize_permissions
  release_lock
}

update_script() {
  local latest_tag
  # 首选 GitHub API；不可用时回退 jsdelivr 镜像索引（只接受 v0.0.0 语义化 tag，
  # 防止二进制镜像等特殊 tag 混入）
  latest_tag="$(curl -fsSL --retry 2 --retry-delay 2 --max-time 20 -H "Accept: application/vnd.github+json" "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest" 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true)"
  if [ -z "${latest_tag}" ]; then
    latest_tag="$(curl -fsSL --retry 2 --max-time 20 "https://data.jsdelivr.com/v1/package/gh/${REPO_OWNER}/${REPO_NAME}" 2>/dev/null | jq -r '.versions[]? | select(type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' 2>/dev/null | head -n 1 || true)"
    [ -n "${latest_tag}" ] && print_info "GitHub API 不可用，已经 jsdelivr 获取最新版本：${latest_tag}"
  fi
  [ -n "${latest_tag}" ] || {
    print_err "无法获取最新发布版本（GitHub API 与 jsdelivr 均不可用）。"
    return 1
  }
  acquire_lock
  # 更新失败必须返回菜单，而不是让 fatal/exit 把交互会话一起带走
  if ! install_release_bundle "${latest_tag}"; then
    release_lock
    print_err "更新失败，当前版本保持可用。"
    return 1
  fi
  sanitize_permissions
  cleanup_unused_cloudflared || true
  apply_network_tune || true
  # 让运行中的服务与新版本文件保持一致（配置未变时仅为快速重启）
  if [ -x "${SINGBOX_BIN}" ] && [ -f "${CONFIG_FILE}" ]; then
    print_info "重启服务以应用新版本..."
    start_service || true
    restart_all_argo_nodes || true
  fi
  ensure_sub || true
  release_lock
  print_ok "项目文件已更新到 ${latest_tag}"
  return 0
}

uninstall_project() {
  local tag
  if ! confirm_yes "这将卸载 ${PROJECT_NAME}，是否继续？"; then
    print_info "已取消卸载。"
    return 1
  fi

  acquire_lock
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    stop_argo_node "${tag}"
  done < <(iter_node_tags)

  stop_service || true
  sub_stop || true
  socks5_whitelist_cleanup || true
  if command_exists pkill; then pkill -x darkhttpd >/dev/null 2>&1 || true; fi

  if systemd_available; then
    systemctl disable --now "${WATCHDOG_TIMER_NAME}" >/dev/null 2>&1 || true
    systemctl disable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
    rm -f "${SYSTEMD_SERVICE_FILE}" "${SYSTEMD_WATCHDOG_SERVICE_FILE}" "${SYSTEMD_WATCHDOG_TIMER_FILE}"
    systemctl daemon-reload || true
  elif openrc_available; then
    rc-update del "${SERVICE_NAME}" default >/dev/null 2>&1 || true
    rm -f "${OPENRC_SERVICE_FILE}"
  fi

  if command_exists crontab; then
    (crontab -l 2>/dev/null | grep -Fv "${WATCHDOG_TARGET}" | grep -Fv "no crontab for" || true) | crontab -
  fi

  rm -rf "${BASE_DIR}" "${LIB_DIR}" "${INSTALL_BIN}" "${SINGBOX_BIN}"
  print_info "保留 cloudflared（可能被其他项目共用）。"
  release_lock
  print_ok "项目已卸载。"
  return 0
}
