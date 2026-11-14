#!/usr/bin/env bash
set -eEuo pipefail

cli_add_usage() {
  cat <<'EOF'
用法: sbm add --protocol PROTOCOL [选项]

协议:
  reality       VLESS+Vision+Reality (TCP)
  xudp          VLESS+Reality+XUDP (TCP)
  xudp-reality  VLESS+Reality+XUDP（xudp 别名）
  anytls        AnyTLS (TCP)
  tuic          TUIC v5 (UDP)
  hysteria2     Hysteria2 (UDP)
  socks5        SOCKS5 (TCP)
  argo          VLESS + Argo 临时隧道
  ws            VLESS + WS-TLS

选项:
  --port PORT          监听端口；省略随机选择
  --name NAME          节点名称
  --sni DOMAIN         SNI；Reality 可用 auto 自动检测
  --uuid UUID          指定 UUID
  --password VALUE     指定密码
  --socks5-username U  SOCKS5 用户名
  --socks5-password P  SOCKS5 密码
  --server-ip IP       分享链接使用的服务器 IP
  --direct-host HOST   直连协议使用的域名
  --argo-cdn-host HOST Argo 优选域名
  --argo-cdn-port PORT Argo 优选端口
EOF
}

random_free_port() {
  local p
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    p=$(( (RANDOM * 32768 + RANDOM) % 50000 + 10000 ))
    if command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q "[:.]${p} "; then
      continue
    fi
    printf '%s' "${p}"
    return 0
  done
  printf '%s' "443"
}

sni_candidates() {
  cat <<'EOF'
www.bing.com
www.microsoft.com
www.adobe.com
deb.debian.org
pypi.org
dl-cdn.alpinelinux.org
static.rust-lang.org
rubygems.org
addons.mozilla.org
www.python.org
www.fastly.com
gateway.icloud.com
www.utoronto.ca
www.cam.ac.uk
www.kyoto-u.ac.jp
www.nus.edu.sg
www.hku.hk
www.cathaypacific.com
www.lg.com
EOF
}

detect_sni_best() {
  local host t best="" best_t="999"
  command -v curl >/dev/null 2>&1 || return 1
  while IFS= read -r host; do
    [ -n "${host}" ] || continue
    t="$(curl -fsS --http2 --tlsv1.3 -o /dev/null --connect-timeout 3 --max-time 6 \
      -w '%{time_appconnect}' "https://${host}" 2>/dev/null || true)"
    [[ "${t}" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
    if awk -v a="${t}" -v b="${best_t}" 'BEGIN { exit !(a < b) }'; then
      best="${host}"
      best_t="${t}"
    fi
  done < <(sni_candidates)
  [ -n "${best}" ] || return 1
  printf '%s' "${best}"
}

cli_sni() {
  local best
  print_info "正在检测 Reality SNI 候选（TLS 1.3 + HTTP/2）..."
  if best="$(detect_sni_best)"; then
    print_ok "推荐 SNI：${best}"
  else
    print_warn "自动检测失败，建议使用 www.bing.com"
    return 1
  fi
}

cli_add() {
  require_root
  local protocol="" port="" name="" sni="" uuid="" password="" s5user="" s5pass="" server_ip="" direct_host="" argo_host="" argo_port=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --protocol) protocol="${2:-}"; shift 2 ;;
      --port) port="${2:-}"; shift 2 ;;
      --name) name="${2:-}"; shift 2 ;;
      --sni) sni="${2:-}"; shift 2 ;;
      --uuid) uuid="${2:-}"; shift 2 ;;
      --password) password="${2:-}"; shift 2 ;;
      --socks5-username) s5user="${2:-}"; shift 2 ;;
      --socks5-password) s5pass="${2:-}"; shift 2 ;;
      --server-ip) server_ip="${2:-}"; shift 2 ;;
      --direct-host) direct_host="${2:-}"; shift 2 ;;
      --argo-cdn-host) argo_host="${2:-}"; shift 2 ;;
      --argo-cdn-port) argo_port="${2:-}"; shift 2 ;;
      -h|--help) cli_add_usage; return 0 ;;
      *) print_err "未知参数：$1"; cli_add_usage; return 2 ;;
    esac
  done
  [ -n "${protocol}" ] || { print_err "缺少 --protocol"; cli_add_usage; return 2; }
  [[ "${port}" =~ ^[0-9]+$ ]] || port="$(random_free_port)"
  # 端口范围校验
  if [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
    print_err "端口无效：${port}"; return 2
  fi
  [ -n "${name}" ] || name="${protocol}-${port}"
  if [ "${sni}" = "auto" ]; then
    sni="$(detect_sni_best || printf 'www.bing.com')"
  fi
  export name
  [ -n "${uuid}" ] && export uuid
  [ -n "${password}" ] && export passwd
  [ -n "${server_ip}" ] && export server_ip
  [ -n "${direct_host}" ] && export direct_host
  case "${protocol,,}" in
    reality|vless-reality)
      export vlrt="${port}"
      [ -n "${sni}" ] && export vl_sni="${sni}"
      ;;
    xudp|vless-xudp|xudp-reality|vless-xudp-reality)
      export vxpt="${port}"
      [ -n "${sni}" ] && export vx_sni="${sni}"
      ;;
    anytls)
      export anypt="${port}"
      [ -n "${sni}" ] && export any_sni="${sni}"
      ;;
    tuic|tuic-v5)
      export tupt="${port}"
      [ -n "${sni}" ] && export tu_sni="${sni}"
      ;;
    hysteria2|hy2)
      export hypt="${port}"
      [ -n "${sni}" ] && export hy_sni="${sni}"
      ;;
    socks5)
      export socks5pt="${port}"
      [ -n "${s5user}" ] && export socks5_username="${s5user}"
      [ -n "${s5pass}" ] && export socks5_password="${s5pass}"
      ;;
    argo|vless-argo)
      export argo="vlpt" argo_pt="${port}"
      [ -n "${argo_host}" ] && export argo_cdn_host="${argo_host}"
      [ -n "${argo_port}" ] && export argo_cdn_port="${argo_port}"
      ;;
    ws|vless-ws|vless-ws-tls)
      export wspt="${port}" ws_mode="cdn"
      [ -n "${sni}" ] && export ws_host="${sni}"
      ;;
    *)
      print_err "不支持的协议：${protocol}"; return 2
      ;;
  esac
  auto_install ins
}

cli_status() {
  local n=0
  init_storage
  n="$(iter_node_tags | wc -l | tr -d ' ')"
  printf '版本: %s\n' "${SCRIPT_VERSION}"
  printf '服务: %s\n' "$(service_state)"
  printf '节点: %s\n' "${n}"
  printf '配置: %s\n' "${CONFIG_FILE}"
}

# 服务未运行时的可操作原因线索：配置校验已通过但启动失败，最高频是端口冲突
# （实测：clash api 127.0.0.1:19990 被 mm/mihomo 占用 → sing-box external controller
# 绑定失败无限重启）；其次是端口被其他入站占用。其余给出最近一条服务错误日志。
doctor_service_failure_hint() {
  local ctl port owner last
  ctl="$(jq -r '.experimental.clash_api.external_controller // empty' "${CONFIG_FILE}" 2>/dev/null || true)"
  port="${ctl##*:}"
  if [ -n "${port}" ] && [[ "${port}" =~ ^[0-9]+$ ]] && system_has_port "${port}"; then
    owner="$(port_owner_name "${port}")"
    if [ -n "${owner}" ] && [ "${owner}" != "sing-box" ]; then
      print_warn "疑似原因：clash api 端口 ${port} 已被 ${owner} 占用（external_controller=${ctl}）。"
      print_info "处理：重新执行 sbm rep（自动换口），或先停掉占用方后 sbm restart。"
      return 0
    fi
  fi
  if systemd_available && command_exists journalctl; then
    last="$(journalctl -u "${SERVICE_NAME}" --no-pager -n 60 2>/dev/null |
      grep -E "FATAL|ERROR|Fatal|error" | tail -n 1 || true)"
    if [ -n "${last}" ]; then
      print_info "最近服务错误：${last:0:200}"
      return 0
    fi
  fi
  if [ -s "${LOG_DIR}/stop_reason.log" ]; then
    print_info "最近停止原因：$(tail -n 1 "${LOG_DIR}/stop_reason.log" | head -c 200)"
  fi
}

cli_doctor() {
  local fail=0
  init_storage
  printf '== %s doctor ==\n' "${SCRIPT_VERSION}"
  if [ -x "${SINGBOX_BIN:-${MIHOMO_BIN:-}}" ]; then
    print_ok "内核可执行"
  else
    print_err "内核不可执行：${SINGBOX_BIN:-${MIHOMO_BIN:-}}"
    fail=1
  fi
  if [ -s "${CONFIG_FILE}" ]; then
    print_ok "配置文件存在"
  else
    print_err "配置文件缺失：${CONFIG_FILE}"
    fail=1
  fi
  if [ -x "${SINGBOX_BIN:-${MIHOMO_BIN:-}}" ] && [ -s "${CONFIG_FILE}" ]; then
    if [ -n "${SINGBOX_BIN:-}" ] && "${SINGBOX_BIN}" check -c "${CONFIG_FILE}" >/dev/null 2>&1; then
      print_ok "配置校验通过"
    elif [ -n "${MIHOMO_BIN:-}" ] && "${MIHOMO_BIN}" -t -d "${BASE_DIR}" -f "${CONFIG_FILE}" >/dev/null 2>&1; then
      print_ok "配置校验通过"
    else
      print_err "配置校验失败"
      fail=1
    fi
  fi
  case "$(service_state)" in
    *运行中*) print_ok "服务运行中" ;;
    *)
      print_err "服务未运行"
      doctor_service_failure_hint
      fail=1
      ;;
  esac
  if [ "${fail}" -eq 0 ]; then
    print_ok "doctor 检查通过"
  else
    print_warn "doctor 检查发现问题"
  fi
  return "${fail}"
}

cli_fw_usage() {
  cat <<'EOF'
用法: sbm fw list
      sbm fw open --port PORT [--proto tcp|udp]
      sbm fw close --port PORT [--proto tcp|udp]

优先使用 ufw/firewalld；裸 iptables 规则仅当前运行期生效。
EOF
}

cli_fw() {
  require_root
  local cmd="${1:-list}" port="" proto="tcp"
  shift || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port) port="${2:-}"; shift 2 ;;
      --proto) proto="${2:-}"; shift 2 ;;
      -h|--help) cli_fw_usage; return 0 ;;
      *) print_err "未知参数：$1"; cli_fw_usage; return 2 ;;
    esac
  done
  case "${cmd}" in
    list)
      if command -v ufw >/dev/null 2>&1; then ufw status
      elif command -v firewall-cmd >/dev/null 2>&1; then firewall-cmd --list-all
      elif command -v iptables >/dev/null 2>&1; then iptables -S INPUT
      else print_warn "未检测到 ufw/firewalld/iptables"; return 0
      fi
      ;;
    open|close)
      [[ "${port}" =~ ^[0-9]+$ ]] || { print_err "缺少有效 --port"; return 2; }
      case "${proto}" in tcp|udp) ;; *) print_err "--proto 仅支持 tcp/udp"; return 2 ;; esac
      if fw_apply_port "${cmd}" "${proto}" "${port}"; then
        # 裸 iptables 路径（ufw/firewalld 都不可用）需提示持久化
        if ! { command -v ufw >/dev/null 2>&1 && ufw status >/dev/null 2>&1; } &&
          ! { command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; }; then
          print_warn "裸 iptables 规则不会自动持久化，请自行保存。"
        fi
        print_ok "防火墙${cmd}：${port}/${proto}"
      else
        print_warn "未检测到可用的防火墙工具"; return 1
      fi
      ;;
    *) print_err "未知 fw 子命令：${cmd}"; cli_fw_usage; return 2 ;;
  esac
}
