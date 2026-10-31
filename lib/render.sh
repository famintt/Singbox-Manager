#!/usr/bin/env bash
set -eEuo pipefail

umask 077

rollback_new_node() {
  local tag="$1"
  local cert_file="${2:-}"
  local key_file="${3:-}"
  delete_node_records "$tag" || true
  remove_node_certificates "$tag" "$cert_file" "$key_file"
  render_config || true
  start_service || true
}

save_node_bundle() {
  local tag="$1"
  local node_json="$2"
  local secret_json="$3"
  json_set_record "${NODES_FILE}" "$tag" "$node_json"
  json_set_record "${SECRETS_FILE}" "$tag" "$secret_json"
  invalidate_port_caches
}

# B4/4.2：DNS 块默认开启（空 dns_servers 走一组加密 DNS，降低解析延迟并抗污染）；
#   dns_servers=off|none 可整体关闭；非法格式不渲染（输出 {}）。逗号分隔多源。
#   strategy 跟随全局 ip_version（auto→prefer_ipv4，6→ipv4_and_ipv6）。
#   局部名用 __ 前缀：dns_servers 是环境变量键名，同名局部变量会在
#   env_var 的间接引用（${!key}）中命中空值（bash 动态作用域）
render_dns_object() {
  local __dns_servers="" __ds __strategy ok=0
  __dns_servers="$(env_var "dns_servers")"
  case "${__dns_servers,,}" in
  off | none | 0 | false | disabled)
    printf '{}'
    return 0
    ;;
  esac
  # 4.2：未显式配置时默认提供一组加密 DNS（1.1.1.1 + dns.google 双源）
  [ -n "${__dns_servers}" ] || __dns_servers="https://1.1.1.1/dns-query,https://dns.google/resolve"
  for __ds in ${__dns_servers//,/ }; do
    [ -n "${__ds}" ] || continue
    case "${__ds}" in
    https://* | tls://* | udp://* | h3://* | quic://* | tcp://*) ok=1 ;;
    *)
      ok=0
      break
      ;;
    esac
  done
  if [ "${ok}" = 0 ]; then
    printf '{}'
    return 0
  fi
  case "$(manager_env_or_setting "ip_version" "4")" in
  6 | v6) __strategy="ipv4_and_ipv6" ;;
  *) __strategy="prefer_ipv4" ;;
  esac
  # sing-box 1.12.0 起 legacy `address` 字段弃用，1.14.0 移除（schema 直接拒绝）。
  # 新格式按协议拆成 type/server 两个字段：https://host/dns-query → {type:"https", server:"host"},
  # tls://host → {type:"tls", server:"host"}, bare/none → {type:"udp", server:"IP-hosts"}。
  # 1.14.0 要求：域名型 DNS server（server 为域名而非字面 IP）必须显式提供 domain_resolver，
  # 否则 FATAL: missing domain resolver for domain server address。为避免"域名解析域名"的自举死循环，
  # 固定附带纯 IP 的 UDP bootstrap 解析器并 tag: "bootstrap"，凡 server 不是字面 IP 一律
  # domain_resolver: "bootstrap"（先经 bootstrap 解析出 IP 再连真实 server）。
  # independent_cache 在 1.14.0 弃用（1.16.0 移除），去掉，缓存即共享缓存。
  jq -n --arg dns_servers "${__dns_servers}" --arg strategy "${__strategy}" '
    { dns: {
        servers: (
          ($dns_servers | split(",")
            | map(select(. != "")
              | (if startswith("https://") then
                  { type: "https", server: (sub("^https://"; "") | split("/")[0]) }
                 elif startswith("tls://") then
                  { type: "tls", server: sub("^tls://"; "") }
                 elif startswith("h3://") then
                  { type: "h3", server: (sub("^h3://"; "") | split("/")[0]) }
                 elif startswith("quic://") then
                  { type: "quic", server: sub("^quic://"; "") }
                 elif startswith("udp://") then
                  { type: "udp", server: sub("^udp://"; "") }
                 elif startswith("tcp://") then
                  { type: "tcp", server: sub("^tcp://"; "") }
                 else
                  { type: "udp", server: . }
                 end)))
          | map(if (.server | test("^[0-9a-fA-F:.]+$")) then . else (. + { domain_resolver: "bootstrap" }) end)
          + [ { type: "udp", tag: "bootstrap", server: "8.8.8.8" } ]
          ),
        disable_cache: false,
        cache_capacity: 4096,
        strategy: $strategy
      } }'
}

# 1.2：可观测面开关。clash_api 仅监听 127.0.0.1（无暴露风险），secret 随机生成持久化。
clash_api_enabled() {
  case "$(manager_env_or_setting "clash_api" "")" in
  0 | off | no | false) return 1 ;;
  *) return 0 ;;
  esac
}

clash_api_port() {
  local p
  p="$(manager_env_or_setting "clash_api_port" "19990")"
  [[ "${p}" =~ ^[0-9]+$ ]] && [ "${p}" -ge 1 ] && [ "${p}" -le 65535 ] || p="19990"
  printf '%s' "${p}"
}

ensure_clash_api_secret() {
  local s
  s="$(get_setting "clash_api_secret")"
  if [ -z "${s}" ]; then
    s="$(generate_hex 16)"
    set_setting "clash_api_secret" "${s}"
  fi
  printf '%s' "${s}"
}

# 1.1/1.2：experimental 段——cache_file 连接缓存（重启秒级恢复）+ clash_api 可观测。
# 生成整段 JSON（{} 表示该节留空），供 render_config 合并。
render_experimental_object() {
  local __cache_path
  mkdir -p "${RUNTIME_DIR}" 2>/dev/null || true
  __cache_path="${RUNTIME_DIR}/cache.db"
  if clash_api_enabled; then
    jq -n \
      --arg cache_path "${__cache_path}" \
      --arg controller "127.0.0.1:$(clash_api_port)" \
      --arg secret "$(ensure_clash_api_secret)" '{
        experimental: {
          cache_file: { enabled: true, path: $cache_path },
          clash_api: { external_controller: $controller, secret: $secret }
        }
      }'
  else
    jq -n --arg cache_path "${__cache_path}" '{
      experimental: { cache_file: { enabled: true, path: $cache_path } }
    }'
  fi
}

# 1.2：clash_api 基础 curl。controller 或 secret 缺失/curl 不可用时返回失败。
clash_api_fetch() {
  local _p="$1" _out
  command_exists curl || return 1
  _out="$(curl -fsS --max-time 4 -H "Authorization: Bearer $(ensure_clash_api_secret)" \
    "http://127.0.0.1:$(clash_api_port)${_p}" 2>/dev/null || true)"
  [ -n "${_out}" ] || return 1
  printf '%s' "${_out}"
}

# 1.2：活跃连接汇总行（数量 + 上下行速率），供 sbm status 展示。
clash_api_conn_summary() {
  local _out _active _down _up _start _elapsed
  clash_api_enabled || return 1
  _out="$(clash_api_fetch "/connections" 2>/dev/null || true)"
  [ -n "${_out}" ] || {
    print_warn "clash_api 不可达（sing-box 可能未运行或未启用实验面）。"
    return 1
  }
  _active="$(printf '%s' "${_out}" | jq -r '.connections | length // 0' 2>/dev/null || printf 0)"
  _down="$(printf '%s' "${_out}" | jq -r '.downloadTotal // empty' 2>/dev/null || true)"
  _up="$(printf '%s' "${_out}" | jq -r '.uploadTotal // empty' 2>/dev/null || true)"
  _start="$(printf '%s' "${_out}" | jq -r '.startTime // empty' 2>/dev/null || true)"
  # 速率 = 累计字节 ×8 / 运行秒数（downloadTotal/uploadTotal 为字节）
  if [[ "${_down}" =~ ^[0-9]+$ ]] && [[ "${_up}" =~ ^[0-9]+$ ]] && [[ "${_start}" =~ ^[0-9.]+$ ]]; then
    _elapsed="$(awk -v s="${_start}" 'BEGIN { e = systime() - s; printf "%d", e < 0 ? 0 : e }' 2>/dev/null || printf 0)"
    printf '%s 连接 | 下行 %s | 上行 %s' \
      "${_active}" \
      "$(_fmt_mbps "${_down}" "${_elapsed}")" \
      "$(_fmt_mbps "${_up}" "${_elapsed}")"
  else
    printf '%s 连接' "${_active}"
  fi
}

# 1.2：watchdog 探活失败时把当前 connections dump 到运行时日志辅助根因定位。
clash_api_dump_connections() {
  [ -f "${NODES_FILE}" ] || return 0
  clash_api_enabled || return 0
  command_exists curl || return 0
  local _out
  _out="$(clash_api_fetch "/connections" 2>/dev/null || true)"
  [ -n "${_out}" ] || return 0
  {
    printf '\n[%s] clash_api connections dump（探活失败快照）：\n' "$(date -Is 2>/dev/null || date +%s)"
    printf '%s\n' "${_out}" | jq '{downloadTotal, uploadTotal, connections: [(.connections|length)]}' 2>/dev/null || printf '%s\n' "${_out}"
  } >>"${RUNTIME_DIR}/clash-api-dump.log" 2>/dev/null || true
}

# 字节→Mbps：bytes ×8 / 秒 / 1e6 = bytes / 秒 / 125000
_fmt_mbps() {
  local _b="$1" _s="$2" _mbps=0
  [ "${_s}" -gt 0 ] 2>/dev/null && _mbps=$((_b / _s / 125000))
  printf '%s Mbps' "${_mbps}"
}

render_config() {
  local inbounds_json tmp tags
  migrate_custom_certificates || return 1
  if ! tags="$(iter_node_tags)"; then
    print_err "读取节点列表失败。"
    return 1
  fi
  if ! inbounds_json="$(
    while IFS= read -r tag; do
      [ -n "${tag}" ] || continue
      render_inbound_for_tag "${tag}" || exit 1
    done <<<"$tags"
  )"; then
    print_err "生成 sing-box 入站配置失败。"
    return 1
  fi

  if [ -n "${inbounds_json}" ]; then
    if ! inbounds_json="$(printf '%s\n' "${inbounds_json}" | jq -s '.')"; then
      print_err "合并 sing-box 入站配置失败。"
      return 1
    fi
  else
    inbounds_json='[]'
  fi

  tmp="$(mktemp "${BASE_DIR}/.config.XXXXXX")"
  # 数据面日志等级可调（warn/info/debug），生产默认 warn 降低高负载磁盘 IO
  local log_level
  log_level="$(manager_env_or_setting "log_level" "")"
  if [ "$(manager_env_or_setting "debug_flag" "0")" = "1" ]; then
    log_level="debug"
  fi
  case "${log_level}" in
  "info" | "debug") : ;;
  *) log_level="warn" ;;
  esac
  local dns_object experimental_object
  dns_object="$(render_dns_object)"
  experimental_object="$(render_experimental_object)"
  if ! jq -n --arg log_path "${BASE_DIR}/logs/sing-box.log" --arg log_level "${log_level}" --argjson inbounds "${inbounds_json}" --argjson dns_object "${dns_object}" --argjson experimental "${experimental_object}" '{
    log: {
      level: $log_level,
      timestamp: true,
      output: $log_path
    },
    inbounds: $inbounds,
    outbounds: [
      { type: "direct", tag: "direct" }
    ],
    route: ({
      final: "direct",
      auto_detect_interface: true
    } + (if ($dns_object | has("dns")) then { default_domain_resolver: { server: "bootstrap" } } else {} end))
  } + $dns_object + $experimental' >"${tmp}"; then
    rm -f "${tmp}"
    print_err "写入 sing-box 配置失败。"
    return 1
  fi
  # S4：落盘前用 sing-box 校验 tmp，失败则删除 tmp、保留旧配置并报错（fail-closed）
  if [ -n "${SINGBOX_BIN:-}" ] && [ -x "${SINGBOX_BIN}" ] && ! "${SINGBOX_BIN}" check -c "${tmp}" >/dev/null 2>&1; then
    rm -f "${tmp}"
    print_err "sing-box check 失败，已拒绝覆盖现有配置（旧配置保留）。"
    return 1
  fi
  if ! chmod 600 "${tmp}" || ! mv "${tmp}" "${CONFIG_FILE}"; then
    rm -f "${tmp}"
    print_err "保存 sing-box 配置失败。"
    return 1
  fi
}

node_meta() {
  local tag="$1"
  # 单进程 jq 合并 nodes+secrets 输出 25 个字段（每行一个，空值输出空行），
  # 字段路径与 node_value/secret_value（.[$tag][$field]）完全一致；
  # 渲染/分享链接按节点仅启动 1 次 jq，替代逐字段 node_value/secret_value 的多次启动。
  # 输出用"每行一个字段"而非 tab 分隔：bash 的 read/cut 会合并连续 tab 并吞掉空字段，
  # 空行则能被 while read 完整保留。
  jq -n -r --arg tag "$tag" \
    --rawfile nodes "${NODES_FILE}" \
    --rawfile secrets "${SECRETS_FILE}" '
    ($nodes | fromjson | .[$tag] // {}) as $n |
    ($secrets | fromjson | .[$tag] // {}) as $s |
    [
      ($n.protocol // ""),
      ($n.name // ""),
      (($n.port // "") | tostring),
      ($s.uuid // ""),
      ($s.password // ""),
      ($s.private_key // ""),
      ($n.public_key // ""),
      ($n.short_id // ""),
      ($n.reality_server // ""),
      ($n.tls_server // ""),
      ($n.preferred_domain // ""),
      ($n.host_domain // ""),
      ($n.ws_path // ""),
      ($n.ws_mode // ""),
      (($n.cdn_port // "") | tostring),
      ($n.cdn_sni // ""),
      ($n.certificate_mode // ""),
      ($n.certificate_path // ""),
      ($n.key_path // ""),
      ($n.endpoint_domain // ""),
      ($n.argo_mode // ""),
      ($s.argo_token // ""),
      (($n.up_mbps // "") | tostring),
      (($n.down_mbps // "") | tostring),
      ($n.username // "")
    ] | .[]
  '
}

node_meta_array() {
  local tag="$1" i=0 _f
  NODE_META=()
  while IFS= read -r _f; do
    NODE_META[i++]="${_f%$'\r'}"
    [ "$i" -ge 25 ] && break
  done < <(node_meta "$tag")
  while [ "$i" -lt 25 ]; do NODE_META[i++]=""; done
}

render_inbound_for_tag() {
  local tag="$1"
  local protocol name port uuid password cert_file key_file ws_path reality_server tls_server
  local up_mbps down_mbps bbr_profile private_key short_id
  local __tfo

  # 单次 jq 批量取出 nodes+secrets 全部字段，替代逐字段 node_value/secret_value（每节点省多次 jq 启动）
  node_meta_array "$tag"
  protocol="${NODE_META[0]}"
  name="${NODE_META[1]}"
  port="${NODE_META[2]}"
  uuid="${NODE_META[3]}"
  password="${NODE_META[4]}"
  private_key="${NODE_META[5]}"
  short_id="${NODE_META[7]}"
  reality_server="${NODE_META[8]}"
  tls_server="${NODE_META[9]}"
  ws_path="${NODE_META[12]}"
  cert_file="${NODE_META[17]}"
  key_file="${NODE_META[18]}"
  up_mbps="${NODE_META[22]}"
  down_mbps="${NODE_META[23]}"
  username="${NODE_META[24]}"
  # 全局 TCP Fast Open（默认开启，1.14.0 各 TCP 入站均支持）
  case "$(env_var "tcp_fast_open")" in
  "" | 1) __tfo=true ;;
  *) __tfo=false ;;
  esac

  # B3：TCP keepalive 显式化（NAT 映射保鲜，长连接/手机网络更稳）
  local __tka_iv
  __tka_iv="$(env_var "tcp_keep_alive_interval")"
  [[ "${__tka_iv}" =~ ^[0-9]+(ms|[smh])$ ]] || __tka_iv="30s"

  case "$protocol" in
  vless-reality)
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg server "$reality_server" \
      --arg private_key "$private_key" \
      --arg short_id "$short_id" \
      --argjson port "$port" \
      --argjson tfo "${__tfo}" \
      --arg tka_iv "${__tka_iv}" '{
          type: "vless",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          tcp_fast_open: $tfo,
          tcp_keep_alive: $tka_iv,
          users: [{ name: $name, uuid: $uuid, flow: "xtls-rprx-vision" }],
          tls: {
            enabled: true,
            server_name: $server,
            reality: {
              enabled: true,
              handshake: { server: $server, server_port: 443 },
              private_key: $private_key,
              short_id: ($short_id | split(",") | map(select(. != "")))
            }
          }
        }'
    ;;
  vless-ws-tls)
    # 主 inbound：TLS 端口（v1.2.4 起 CDN 模式统一单端口：客户端连 CDN 边缘，CF 按 SSL 模式
    # Full/Full(Strict) 以 HTTPS 回源到本 TLS 端口，无需明文回源 inbound）。
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg ws_path "$ws_path" \
      --arg cert_file "$cert_file" \
      --arg key_file "$key_file" \
      --argjson port "$port" \
      --argjson tfo "${__tfo}" \
      --arg tka_iv "${__tka_iv}" '{
          type: "vless",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          tcp_fast_open: $tfo,
          tcp_keep_alive: $tka_iv,
          users: [{ name: $name, uuid: $uuid }],
          tls: {
            enabled: true,
            certificate_path: $cert_file,
            key_path: $key_file
          },
          transport: { type: "ws", path: $ws_path, max_early_data: 2048, early_data_header_name: "Sec-WebSocket-Protocol" }
        }'
    ;;
  vless-xudp)
    # VLESS + XUDP：新节点固定 Reality；TLS 分支仅用于兼容旧节点。XUDP 是 VLESS 的 UDP 封装能力，
    # 由客户端 packet_encoding=xudp 启用，服务端不需要 multiplex。
    # 不加 flow：优先保证 XUDP 的客户端兼容性。
    if [ -n "$reality_server" ] && [ -n "$private_key" ]; then
      jq -n \
        --arg tag "$tag" \
        --arg name "$name" \
        --arg uuid "$uuid" \
        --arg server "$reality_server" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        --argjson port "$port" \
        --argjson tfo "${__tfo}" \
        --arg tka_iv "${__tka_iv}" '{
            type: "vless",
            tag: $tag,
            listen: "::",
            listen_port: $port,
            tcp_fast_open: $tfo,
            tcp_keep_alive: $tka_iv,
            users: [{ name: $name, uuid: $uuid }],
            tls: {
              enabled: true,
              server_name: $server,
              reality: {
                enabled: true,
                handshake: { server: $server, server_port: 443 },
                private_key: $private_key,
                short_id: ($short_id | split(",") | map(select(. != "")))
              }
            }
          }'
    else
      jq -n \
        --arg tag "$tag" \
        --arg name "$name" \
        --arg uuid "$uuid" \
        --arg cert_file "$cert_file" \
        --arg key_file "$key_file" \
        --arg server "$tls_server" \
        --argjson port "$port" \
        --argjson tfo "${__tfo}" \
        --arg tka_iv "${__tka_iv}" '{
            type: "vless",
            tag: $tag,
            listen: "::",
            listen_port: $port,
            tcp_fast_open: $tfo,
            tcp_keep_alive: $tka_iv,
            users: [{ name: $name, uuid: $uuid }],
            tls: {
              enabled: true,
              server_name: $server,
              certificate_path: $cert_file,
              key_path: $key_file
            }
          }'
    fi
    ;;
  anytls)
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg password "$password" \
      --arg cert_file "$cert_file" \
      --arg key_file "$key_file" \
      --arg server "$tls_server" \
      --argjson port "$port" \
      --argjson tfo "${__tfo}" \
      --arg tka_iv "${__tka_iv}" '{
          type: "anytls",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          tcp_fast_open: $tfo,
          tcp_keep_alive: $tka_iv,
          users: [{ name: $name, password: $password }],
          tls: {
            enabled: true,
            server_name: $server,
            certificate_path: $cert_file,
            key_path: $key_file
          }
        }'
    ;;
  vless-argo)
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg ws_path "$ws_path" \
      --argjson port "$port" \
      --argjson tfo "${__tfo}" \
      --arg tka_iv "${__tka_iv}" '{
          type: "vless",
          tag: $tag,
          listen: "127.0.0.1",
          listen_port: $port,
          tcp_fast_open: $tfo,
          tcp_keep_alive: $tka_iv,
          users: [{ name: $name, uuid: $uuid }],
          transport: { type: "ws", path: $ws_path, max_early_data: 2048, early_data_header_name: "Sec-WebSocket-Protocol" }
        }'
    ;;
  tuic-v5)
    # B1：TUIC 0-RTT 默认开启（TLS1.3 会话恢复，移动网络断线重连免全握手）；
    # 安全敏感场景可 tuic_zero_rtt=0 回退为关闭
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg uuid "$uuid" \
      --arg password "$password" \
      --arg cert_file "$cert_file" \
      --arg key_file "$key_file" \
      --argjson port "$port" '{
          type: "tuic",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          users: [{ name: $name, uuid: $uuid, password: $password }],
          congestion_control: "bbr",
          tls: {
            enabled: true,
            alpn: ["h3"],
            certificate_path: $cert_file,
            key_path: $key_file
          }
        }'
    ;;
  hy2)
    up_mbps="${up_mbps:-200}"
    down_mbps="${down_mbps:-200}"
    # 全局 bbr_profile：aggressive|standard|conservative（sing-box 1.14.0+），空=默认
    bbr_profile="$(env_var "bbr_profile")"
    case "${bbr_profile}" in
    aggressive | standard | conservative) : ;;
    *) bbr_profile="" ;;
    esac
    # 默认上下行 200 Mbps（未显式设置时）；bbr_profile 留空用 sing-box 默认
    jq -n \
      --arg tag "$tag" \
      --arg name "$name" \
      --arg password "$password" \
      --arg cert_file "$cert_file" \
      --arg key_file "$key_file" \
      --argjson up_mbps "${up_mbps:-0}" \
      --argjson down_mbps "${down_mbps:-0}" \
      --arg bbr_profile "${bbr_profile}" \
      --argjson port "$port" '{
          type: "hysteria2",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          users: [{ name: $name, password: $password }],
          tls: {
            enabled: true,
            alpn: ["h3"],
            certificate_path: $cert_file,
            key_path: $key_file
          }
        }
        + (if ($up_mbps > 0) then { up_mbps: $up_mbps } else {} end)
        + (if ($down_mbps > 0) then { down_mbps: $down_mbps } else {} end)
        + (if ($bbr_profile != "") then { bbr_profile: $bbr_profile } else {} end)'
    ;;
  socks5)
    jq -n \
      --arg tag "$tag" \
      --arg username "$username" \
      --arg password "$password" \
      --argjson port "$port" \
      --argjson tfo "${__tfo}" \
      --arg tka_iv "${__tka_iv}" '{
          type: "socks",
          tag: $tag,
          listen: "::",
          listen_port: $port,
          tcp_fast_open: $tfo,
          tcp_keep_alive: $tka_iv,
          users: [{ username: $username, password: $password }]
        }'
    ;;
  *)
    print_err "不支持的节点协议：${protocol}"
    return 1
    ;;
  esac
}
