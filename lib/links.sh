#!/usr/bin/env bash
set -eEuo pipefail

umask 077

build_share_link() {
  local tag="$1"
  local public_ip="${2:-}"
  local protocol name port host uuid password username fp
  local reality_server public_key short_id ws_path preferred_domain endpoint_domain host_domain tls_server cert_mode ws_mode cdn_port cdn_sni ext certificate_path fp insecure_flag

  # 单次 jq 批量取出全部字段（nodes+secrets），替代逐字段 node_value/secret_value
  # 的多次 jq 进程（每次 sbm list/sub 对每个节点可省十次左右 jq 启动）
  node_meta_array "$tag"
  protocol="${NODE_META[0]}"
  name="${NODE_META[1]}"
  port="${NODE_META[2]}"
  uuid="${NODE_META[3]}"
  password="${NODE_META[4]}"
  public_key="${NODE_META[6]}"
  short_id="${NODE_META[7]}"
  reality_server="${NODE_META[8]}"
  tls_server="${NODE_META[9]}"
  preferred_domain="${NODE_META[10]}"
  host_domain="${NODE_META[11]}"
  ws_path="${NODE_META[12]}"
  ws_mode="${NODE_META[13]}"
  cdn_port="${NODE_META[14]}"
  cdn_sni="${NODE_META[15]}"
  cert_mode="${NODE_META[16]}"
  certificate_path="${NODE_META[17]}"
  endpoint_domain="${NODE_META[19]}"
  username="${NODE_META[24]}"
  # 支持外部一次性传入解析好的公网 IP（第 2 参），便于订阅/列表在一次网络探测后
  # 复用，避免 N 个节点重复探测；未传时回退进程内缓存探测。
  direct_host="$(manager_env_or_setting "direct_host" "")"
  server_ip="$(manager_env_or_setting "server_ip" "")"
  if [ -n "${direct_host}" ]; then
    public_ip="${direct_host}"
  elif [ -n "${server_ip}" ]; then
    public_ip="${server_ip}"
  else
    public_ip="${public_ip:-$(get_public_ip)}"
  fi
  host="$(wrap_host "$public_ip")"

  case "$protocol" in
  vless-reality)
    # 批量 url_encode：4 个字段一次 jq 子进程（原逐字段 url_encode 每字段一个 jq fork）
    {
      read -r reality_server
      read -r public_key
      read -r short_id
      read -r name
    } <<EOF
$(url_encode_many "${reality_server}" "${public_key}" "${short_id}" "${name}")
EOF
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
      "$uuid" "$host" "$port" "$reality_server" "$public_key" "$short_id" "$name"
    ;;
  vless-ws-tls)
    ws_mode="${ws_mode:-direct}"
    cdn_port="${cdn_port:-443}"
    if [ "${ws_mode}" = "cdn" ]; then
      # CDN 中转模式：客户端连 cdn_host:cdn_port，SNI/Host 走回源域名（cdn_sni，默认同连接地址），
      # 由前置 CDN 根据 SNI/Host 识别并回源到本机。
      if [ -z "${preferred_domain}" ] || [ "${preferred_domain}" = "${DEFAULT_CDN_DOMAIN}" ]; then
        print_warn "WS-TLS 节点 ${tag} 使用默认优选域名 ${DEFAULT_CDN_DOMAIN}：仅当该域名已接入本机前置 CDN 时可用，否则请把 cdn_host 设为你自己的域名或改用 ws_mode=direct 直连。"
      fi
      cdn_sni="${cdn_sni:-${preferred_domain}}"
      # 批量编码 cdn_sni×2 + ws_path（一次 jq 子进程）
      {
        read -r cdn_sni_enc
        read -r cdn_sni_enc2
        read -r ws_path_enc
      } <<EOF
$(url_encode_many "${cdn_sni}" "${cdn_sni}" "${ws_path}")
EOF
      printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s' \
        "$uuid" "$(wrap_host "$preferred_domain")" "$cdn_port" \
        "${cdn_sni_enc}" "${cdn_sni_enc2}" "${ws_path_enc}"
    else
      # 直连模式：客户端连服务器 IP + wspt，SNI/Host 均走 WS Host 域名（自签证书跳过校验）
      # 批量编码 host_domain×2（sni+host）+ ws_path（一次 jq 子进程）
      {
        read -r sni_enc
        read -r host_enc
        read -r ws_path_enc
      } <<EOF
$(url_encode_many "${host_domain}" "${host_domain}" "${ws_path}")
EOF
      printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s' \
        "$uuid" "$host" "$port" "${sni_enc}" "${host_enc}" "${ws_path_enc}"
    fi
    # 固定指纹/跳过校验仅在直连模式有意义：客户端直连本机、面对的就是源站证书。
    # CDN 模式客户端面对的是前置 CDN（如 Cloudflare）边缘的公开证书，不能固定源站
    # 指纹，否则必然校验失败。
    # 触发条件从"仅自签"扩展为"证书不覆盖链接 SNI"：自定义证书 + 伪装 SNI 的
    # 部署同样会校验失败（v1.5.8 实测 anytls/hy2/tuic 全灭），必须一并跳过。
    if [ "${ws_mode}" != "cdn" ] && cert_needs_insecure "$cert_mode" "$certificate_path" "${host_domain}"; then
      # 固定指纹（新版 Xray/v2rayN 已拒绝 allowInsecure，改用 pinnedPeerCertSha256）；
      # 无证书文件（旧节点）时回退 allowInsecure=1
      fp="$(cert_fingerprint "${certificate_path}" 2>/dev/null || true)"
      if [ -n "${fp}" ]; then
        printf '&pcs=%s' "${fp}"
      else
        printf '&allowInsecure=1'
      fi
    fi
    # 指纹参数必须作为 query 输出在 # 之前；fragment 只输出一次，名称仅编码一遍
    printf '#%s' "$(url_encode "$name")"
    ;;
  anytls)
    # 批量编码 password + name（一次 jq 子进程，原逐字段 2 fork）
    {
      read -r password_enc
      read -r name_enc
    } <<EOF
$(url_encode_many "${password}" "${name}")
EOF
    # 先按原文判断证书覆盖（url_encode 后再比会失败），再编码用于链接
    if cert_needs_insecure "$cert_mode" "$certificate_path" "${tls_server}"; then
      ext="insecure=1&"
    else
      ext=""
    fi
    tls_server="$(url_encode "${tls_server}")"
    printf 'anytls://%s@%s:%s?%ssecurity=tls&sni=%s&type=tcp&headerType=none' \
      "${password_enc}" "$host" "$port" "$ext" "$tls_server"
    printf '#%s' "${name_enc}"
    ;;
  vless-argo)
    cdn_port="${cdn_port:-443}"
    if [ -z "${endpoint_domain}" ] || [ "${endpoint_domain}" = "待分配.example.com" ]; then
      print_warn "节点 ${tag} 的 Argo 域名尚未分配（隧道可能未连上），链接暂不可用；稍后重试 sbm list。"
      return 0
    fi
    printf 'vless://%s@%s:%s?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%s#%s' \
      "$uuid" "$(wrap_host "$preferred_domain")" "$cdn_port" \
      "$(url_encode "$endpoint_domain")" "$(url_encode "$endpoint_domain")" "$(url_encode "$ws_path")" "$(url_encode "$name")"
    ;;
  tuic-v5)
    # 证书不覆盖链接 SNI（自签或自定义+伪装 SNI）时 allow_insecure=1 跳过校验
    if cert_needs_insecure "$cert_mode" "$certificate_path" "${tls_server}"; then
      insecure_flag='&allow_insecure=1'
    else
      insecure_flag=""
    fi
    tls_server="$(url_encode "${tls_server}")"
    printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&alpn=h3&sni=%s%s#%s' \
      "$uuid" "$(url_encode "$password")" "$host" "$port" "$tls_server" "${insecure_flag}" "$(url_encode "$name")"
    ;;
  hy2)
    # 证书不覆盖链接 SNI（自签或自定义+伪装 SNI）时固定指纹/跳过校验
    if cert_needs_insecure "$cert_mode" "$certificate_path" "${tls_server}"; then
      # 自签优先固定证书指纹（新版客户端已拒绝 insecure）；无指纹再退回 insecure=1
      fp="$(cert_fingerprint "${certificate_path}" 2>/dev/null || true)"
      if [ -n "${fp}" ]; then
        insecure_flag="&pinSHA256=${fp}"
      else
        insecure_flag="&insecure=1"
      fi
    else
      insecure_flag=""
    fi
    tls_server="$(url_encode "${tls_server}")"
    printf 'hysteria2://%s@%s:%s?sni=%s%s#%s' \
      "$(url_encode "$password")" "$host" "$port" "$tls_server" "${insecure_flag}" "$(url_encode "$name")"
    ;;
  socks5)
    printf 'socks5://%s:%s@%s:%s#%s' \
      "$(url_encode "$username")" "$(url_encode "$password")" "$host" "$port" "$(url_encode "$name")"
    ;;
  esac
}

build_vless_argo_link() {
  build_share_link "$1"
}
