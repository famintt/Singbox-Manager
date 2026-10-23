#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 是否需要 cloudflared：当前环境显式启用 Argo，或已有 vless-argo 节点。
# 只有这两种情况才安装/保留 cloudflared——纯 Reality/WS/TUIC/HY2/SOCKS5 部署
# 不应白占 40MB+ 磁盘（旧版无条件安装的根因）。
argo_nodes_exist() {
  [ -f "${NODES_FILE}" ] || return 1
  jq -e 'to_entries | any(.value.protocol == "vless-argo")' "${NODES_FILE}" >/dev/null 2>&1
}

argo_required() {
  if command -v auto_argo_requested >/dev/null 2>&1 && auto_argo_requested; then
    return 0
  fi
  argo_nodes_exist
}

# 无 Argo 节点时回收 cloudflared 二进制；仍有运行中的隧道进程则保留到进程退出，
# 避免删除正在使用的可执行文件后 systemd/pid 记录混乱。
cleanup_unused_cloudflared() {
  [ -x "${CLOUDFLARED_BIN}" ] || return 0
  if argo_required; then
    return 0
  fi
  if command_exists pgrep && pgrep -f "${CLOUDFLARED_BIN} tunnel" >/dev/null 2>&1; then
    print_warn "检测到仍在运行的 cloudflared 进程，暂不回收二进制。"
    return 0
  fi
  if rm -f "${CLOUDFLARED_BIN}"; then
    print_info "未启用 Argo，已移除 cloudflared（约 40MB 磁盘）；需要时会在添加 Argo 节点时自动安装。"
  fi
}

parse_trycloudflare_domain() {
  local log_file="$1"
  grep -aoE '[a-z0-9-]+\.trycloudflare\.com' "$log_file" 2>/dev/null | tail -n 1
}

wait_for_trycloudflare_domain() {
  local log_file="$1"
  local timeout="${2:-60}"
  local interval="${3:-2}"
  # 3.2:可传 cloudflared pid：进程假死/提前退出时立即失败，不等满 timeout（快速失败）
  local pid="${4:-}"
  local elapsed=0
  local domain=""

  while [ "${elapsed}" -lt "${timeout}" ]; do
    if [ -n "${pid}" ] && ! kill -0 "${pid}" 2>/dev/null; then
      print_warn "cloudflared 进程（pid ${pid}）已退出，停止等待临时域名。"
      return 1
    fi
    domain="$(parse_trycloudflare_domain "$log_file" || true)"
    if [ -n "$domain" ]; then
      printf '%s' "$domain"
      return 0
    fi
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  return 1
}

argo_domain_resolvable() {
  local domain="$1"
  [ -n "${domain}" ] || return 1

  # 快路径：本机解析成功即可确认（getent/host 退出码可靠）
  if command_exists getent; then
    if getent ahosts "${domain}" >/dev/null 2>&1; then
      return 0
    fi
  elif command_exists host; then
    if host "${domain}" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # 本地解析不可用或未命中：查公共 DoH 记录（1.1.1.1 / dns.google 双源，绕开本机负缓存）。
  # A 与 AAAA 都查：TryCloudflare 域名可能只发布 IPv6（AAAA），仅看 A 会漏判；
  # 任一类型有记录即视为已发布。
  # 语义区分：
  #   DoH 应答"无记录"（确认未发布）           -> 返回失败，调用方重试
  #   DoH 网络不可达（无法核验，如墙内环境）   -> fail-open 放行并告警，
  #     因为 cloudflared 日志已出现域名即代表边缘注册成功，此时拒绝会让
  #     弱网机器的临时隧道永远写不进域名（v0.2.19 前的故障面）
  if command_exists curl && command_exists jq; then
    # A2：2 源 × A/AAAA 四路并发核验（原串行最坏 4×6s→并行 ≈6s），
    # 语义与原实现一致：任一有记录→已发布；有应答但不含记录→未发布；
    # 全部不可达→fail-open（隧道日志已出现域名即放行，弱网不回滚）。
    local probe_tmp _f raw _i=0 _any_ok=0 _any_rec=0 _pid
    local base_url record_type
    local -a probe_pids=()
    probe_tmp="$(mktemp -d "${BASE_DIR}/.argodoh.XXXXXX" 2>/dev/null || true)"
    [ -n "${probe_tmp}" ] || probe_tmp="$(mktemp -d 2>/dev/null || true)"
    [ -n "${probe_tmp}" ] || probe_tmp="${TMPDIR:-/tmp}/argodoh.$$"
    mkdir -p "${probe_tmp}"
    for base_url in "https://1.1.1.1/dns-query?name=${domain}." "https://dns.google/resolve?name=${domain}."; do
      for record_type in A AAAA; do
        (
          cnt="$(curl -fsS --max-time 6 -H 'accept: application/dns-json' "${base_url}&type=${record_type}" 2>/dev/null | jq -r '[.Answer[]? | select(.type == 1 or .type == 28)] | length' 2>/dev/null || true)"
          if [[ "${cnt}" =~ ^[0-9]+$ ]]; then
            printf 'R%s' "${cnt}"
          else
            printf 'E'
          fi
        ) >"${probe_tmp}/${_i}" &
        probe_pids+=("$!")
        _i=$((_i + 1))
      done
    done
    # 不使用裸 wait：部分 Bash 5.2/5.3 在命令替换子 shell 中会继承父 shell
    # 的 job 表，裸 wait 对非子进程反复 ECHILD，导致 100% CPU 空转。
    for _pid in "${probe_pids[@]}"; do
      wait "${_pid}" 2>/dev/null || true
    done
    for _f in "${probe_tmp}"/*; do
      [ -f "${_f}" ] || continue
      raw="$(tr -d '\r\n' <"${_f}" 2>/dev/null || true)"
      case "${raw}" in
      R*)
        _any_ok=1
        if [ "${raw#R}" -gt 0 ] 2>/dev/null; then
          _any_rec=1
        fi
        ;;
      esac
    done
    rm -rf "${probe_tmp}"
    if [ "${_any_rec}" = "1" ]; then
      return 0
    fi
    if [ "${_any_ok}" = "1" ]; then
      return 1
    fi
    print_warn "公共 DoH 均不可达，无法核验 ${domain} 的 DNS 发布，按隧道注册结果放行。"
    return 0
  fi

  return 1
}

wait_for_trycloudflare_domain_verified() {
  local log_file="$1"
  local timeout="${2:-60}"
  local retry="${3:-1}"
  local pid="${4:-}"
  local domain attempt

  for attempt in 0 1 2; do
    [ "${attempt}" -le "${retry}" ] || break
    domain="$(wait_for_trycloudflare_domain "${log_file}" "${timeout}" 2 "${pid}" || true)"
    [ -n "${domain}" ] || continue
    # NAT/弱网环境可跳过 DoH 发布核验（日志已出现域名即认为注册成功），
    # 避免个别 DNS 环境卡住安装流程。
    if [ "${SBM_ARGO_SKIP_DNS_VERIFY:-0}" = "1" ]; then
      printf '%s' "${domain}"
      return 0
    fi
    if argo_domain_resolvable "${domain}"; then
      printf '%s' "${domain}"
      return 0
    fi
    print_warn "临时域名 ${domain} 尚未进入公共 DNS，等待发布后重试..."
    sleep 5
  done

  return 1
}

argo_backoff_delay() {
  local fail_count="$1"
  local delay=1 i
  for ((i = 1; i < fail_count && delay < 1800; i++)); do
    delay=$((delay * 2))
  done
  [ "${delay}" -gt 1800 ] && delay=1800
  printf '%s' "${delay}"
}

argo_edge_ip_version() {
  local has4 has6
  # 边缘 IP 族选择：双栈环境交给 cloudflared --edge-ip-version auto（3.2）；
  # 单栈环境先探测 Cloudflare 同族边缘可达性；探测失败时只在本机实际具备的
  # IP 族内判断，绝不可翻转到本机没有的族（IPv4-only 主机回退 IPv6 必现
  # "network is unreachable"，v1.5.8 实测根因）。
  has4=false
  has6=false
  has_public_ipv4 && has4=true
  has_public_ipv6 && has6=true

  if [ "${has4}" = "true" ] && [ "${has6}" = "true" ]; then
    printf 'auto'
    return 0
  fi
  if [ "${has4}" = "true" ]; then
    if probe_edge_family "4"; then
      printf '4'
    else
      print_warn "IPv4 边缘（region1.v2.argotunnel.com）不可达，本机无 IPv6，保持 IPv4 边缘。"
      printf '4'
    fi
    return 0
  fi
  if [ "${has6}" = "true" ]; then
    if probe_edge_family "6"; then
      printf '6'
    else
      print_warn "IPv6 边缘（region1.v2.argotunnel.com）不可达，本机无 IPv4，保持 IPv6 边缘。"
      printf '6'
    fi
    return 0
  fi
  printf 'auto'
}

# 探测 Cloudflare 边缘注册服务（region1.v2.argotunnel.com:443）在指定 IP 族的可达性。
# 该端点并非 HTTP 站点：curl -f 对待 TLS 握手失败会误判为不可达（HTTPS GET 语义错误，
# 实际 TCP/TLS 均可达，属正常拒绝）。改为协议无关的 TCP 层连接测试：按目标族解析出
# 地址后直接建立 TCP 连接。优先解析族内地址 + bash /dev/tcp（不依赖 nc 的 -4/-6，BusyBox
# nc 不支持族参数）；getent 无族参数（部分 busybox）时以 curl 双保险回退。
probe_edge_family() {
  local fam="$1"
  local ip
  # getent ahostsv4/ahostsv6 返回"族内全部地址 STREAM/PROTO"行，取首个地址
  ip="$(getent "ahostsv${fam}" region1.v2.argotunnel.com 2>/dev/null | awk 'NR==1{print $1}' || true)"
  if [ -n "${ip}" ]; then
    if command_exists timeout; then
      timeout 4 bash -c "exec 3<>/dev/tcp/${ip}/443" >/dev/null 2>&1
    else
      bash -c "exec 3<>/dev/tcp/${ip}/443" >/dev/null 2>&1
    fi
    return $?
  fi
  # getent 无族参数：退化为不限族的 TCP 握手探测（仅诊断用，不影响已锁定返回族）
  if command_exists nc; then
    timeout 4 nc -z -w 3 region1.v2.argotunnel.com 443 >/dev/null 2>&1
    return $?
  fi
  command_exists curl && curl -fsS --max-time 4 "https://region1.v2.argotunnel.com" >/dev/null 2>&1
}

cloudflared_latest_release_json() {
  if [ -n "${CLOUDFLARED_LATEST_CACHE}" ]; then
    printf '%s' "${CLOUDFLARED_LATEST_CACHE}"
    return 0
  fi

  local json
  json="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 30 -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/cloudflare/cloudflared/releases/latest" 2>/dev/null || true)"
  [ -n "${json}" ] || return 1

  CLOUDFLARED_LATEST_CACHE="${json}"
  printf '%s' "${json}"
}

# 一次拿到最新版本与目标资产 digest（可能为空）：GitHub API 优先，jsdelivr 仅能提供版本号。
# 输出 "版本 digest"，digest 不可得时只输出 "版本 "（尾随空格）——调用方不得把
# 其他版本的固定 digest 套到最新版上校验。
cloudflared_latest_info() {
  local json version digest jsdelivr_json tag
  if [ -n "${CLOUDFLARED_LATEST_CACHE}" ]; then
    json="${CLOUDFLARED_LATEST_CACHE}"
  else
    json="$(cloudflared_latest_release_json 2>/dev/null || true)"
  fi
  if [ -n "${json}" ]; then
    version="$(printf '%s' "${json}" | jq -r '.tag_name // empty' 2>/dev/null || true)"
    if [ -n "${version}" ]; then
      digest="$(printf '%s' "${json}" | jq -r --arg name "${1:-}" \
        '.assets[]? | select(.name == $name) | .digest // empty' 2>/dev/null | sed 's/^sha256://' || true)"
      printf '%s %s' "${version}" "${digest}"
      return 0
    fi
  fi
  # GitHub API 不可达：jsdelivr 只能给版本，digest 留空由安装器决定回退/降级
  jsdelivr_json="$(curl -fsSL --retry 1 --max-time 15 "https://data.jsdelivr.com/v1/package/gh/cloudflare/cloudflared" 2>/dev/null || true)"
  tag="$(printf '%s' "${jsdelivr_json}" | jq -r '.versions[]? | select(type == "string" and test("^[0-9]{4}\\.[0-9]+\\.[0-9]+$"))' 2>/dev/null | head -n 1 || true)"
  if [ -n "${tag}" ]; then
    printf '%s ' "${tag}"
    return 0
  fi
  return 1
}

cloudflared_latest_version() {
  local info
  info="$(cloudflared_latest_info "${1:-}" 2>/dev/null || true)"
  [ -n "${info}" ] || return 1
  printf '%s' "${info%% *}"
}

cloudflared_latest_digest() {
  local asset="$1" info digest
  info="$(cloudflared_latest_info "${asset}" 2>/dev/null || true)"
  [ -n "${info}" ] || return 1
  digest="${info#* }"
  [ -n "${digest}" ] || return 1
  printf '%s' "${digest}"
}

cloudflared_installed_version() {
  local out
  if [ ! -x "${CLOUDFLARED_BIN}" ]; then
    printf '未安装（仅 Argo 节点需要）'
    return 0
  fi
  out="$("${CLOUDFLARED_BIN}" version 2>/dev/null | head -n 1 || true)"
  printf '%s' "${out#cloudflared version }"
}

cleanup_argo_pid() {
  local pid_file="$1"
  kill_pid_file "$pid_file"
}

stop_argo_node() {
  local tag="$1"
  kill_pid_file "${BASE_DIR}/runtime/${tag}.pid" "${CLOUDFLARED_BIN}"
}

start_argo_node() {
  local tag="$1"
  local mode port token log_file pid_file domain edge_ip

  [ -x "${CLOUDFLARED_BIN}" ] || install_cloudflared_bin
  mode="$(node_value "$tag" "argo_mode")"
  port="$(node_value "$tag" "port")"
  log_file="${BASE_DIR}/logs/${tag}.cloudflared.log"
  pid_file="${BASE_DIR}/runtime/${tag}.pid"

  stop_argo_node "$tag"
  : >"${log_file}"
  chmod 600 "${log_file}"

  # token 模式的 endpoint_domain 是安装时提供的不变值：不得清空，
  # 否则每次服务重启后固定隧道链接会显示"尚未分配"（v0.2.18 回归）
  if [ "${mode}" != "token" ]; then
    # 启动前清空旧域名：临时隧道失败时分享链接不再显示失效地址
    json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "" 2>/dev/null || true
  fi

  edge_ip="$(argo_edge_ip_version)"

  if [ "${mode}" = "token" ]; then
    token="$(secret_value "$tag" "argo_token")"
    # token 经环境变量传入，避免明文出现在进程命令行（ps 可见）
    # --protocol http2：压掉 QUIC 内存尖峰（30-50MB → 25-40MB），小内存机更稳
    TUNNEL_TOKEN="${token}" nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --protocol http2 --edge-ip-version "${edge_ip}" run \
      >>"${log_file}" 2>&1 </dev/null &
    write_pid_file "${pid_file}" "$!"
    # L13：token 模式下 cloudflared 全程静默（无 trycloudflare 域名可展示），
    # 对 endpoint_domain:443 快速探测一次给安装者即时反馈；刚启动时公网解析未就绪
    # 属正常，仅告警不阻断。
    if domain="$(node_value "$tag" "endpoint_domain" 2>/dev/null || true)" && [ -n "${domain}" ] && probe_tcp_port "${domain}" 443 3; then
      print_ok "Argo 固定隧道已启动（${domain}:443 可达）。"
    else
      print_warn "Argo 固定隧道进程已拉起${domain:+（域名 ${domain}）}，尚未通过本地 443 探测——公网发布可能需要数十秒，稍后可运行 status 复核。"
    fi
    return 0
  fi

  nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --protocol http2 --edge-ip-version "${edge_ip}" --url "http://127.0.0.1:${port}" \
    >>"${log_file}" 2>&1 </dev/null &
  local _pid=$!
  write_pid_file "${pid_file}" "${_pid}"

  # 等待域名出现且确认公共 DNS 已发布（DoH 核验，防"看似成功实则不可解析"）；
  # 传入 pid：进程假死/提前退出时快速失败，不等满 60s 超时
  if domain="$(wait_for_trycloudflare_domain_verified "${log_file}" 60 1 "${_pid}")"; then
    if ! json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "${domain}"; then
      cleanup_argo_pid "${pid_file}"
      return 1
    fi
  else
    cleanup_argo_pid "${pid_file}"
    json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "" 2>/dev/null || true
    print_err "等待 ${tag} 的临时 Argo 域名超时（含 DNS 发布确认）。"
    return 1
  fi
}

restart_all_argo_nodes() {
  # 9.3:jq 批量化——一次 bulk 拿到全部 (tag, protocol)，替代逐 tag node_value
  # node_meta_bulk 输出 4 列(key/protocol/port/argo_mode)：用占位列吸收多余字段，
  # 否则尾列拼接进 protocol 导致永远匹配不上 vless-argo（F-09）
  local tag protocol _port _argo
  while IFS=$'\t' read -r tag protocol _port _argo; do
    [ -n "${tag}" ] || continue
    if [ "${protocol}" = "vless-argo" ]; then
      # 单个隧道启动失败不影响其余隧道与调用方
      start_argo_node "$tag" || print_warn "Argo 隧道 ${tag} 启动失败。"
    fi
  done < <(node_meta_bulk)
}
