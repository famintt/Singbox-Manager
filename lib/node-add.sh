#!/usr/bin/env bash
set -eEuo pipefail

umask 077

prompt_reality_sni() {
  local value detected
  while true; do
    value="$(prompt_with_default "Reality 域名（留空/auto 自动检测）" "auto")"
    case "${value,,}" in
    "" | auto)
      print_info "正在检测 Reality SNI（TLS 1.3 + HTTP/2）..." >&2
      if declare -F detect_sni_best >/dev/null 2>&1; then
        detected="$(detect_sni_best 2>/dev/null || true)"
        if [ -n "${detected}" ]; then
          print_ok "自动选择：${detected}" >&2
          printf '%s' "${detected}"
          return 0
        fi
      fi
      print_warn "自动检测失败，回退 ${DEFAULT_REALITY_SERVER}；建议稍后运行 sbm sni 手动指定。"
      printf '%s' "${DEFAULT_REALITY_SERVER}"
      return 0
      ;;
    *)
      if is_safe_domain "${value}"; then
        printf '%s' "${value}"
        return 0
      fi
      print_warn "域名格式无效：${value}"
      ;;
    esac
  done
}

prompt_tls_sni() {
  local value detected
  while true; do
    value="$(prompt_with_default "SNI 域名（留空=${DEFAULT_TLS_SERVER}；输入 auto 自动检测；自定义证书必须填写证书域名）" "${DEFAULT_TLS_SERVER}")"
    case "${value,,}" in
    "" | auto)
      if [ "${value}" = "" ]; then
        printf '%s' "${DEFAULT_TLS_SERVER}"
        return 0
      fi
      print_info "正在检测 TLS SNI（TLS 1.3 + HTTP/2）..." >&2
      if declare -F detect_sni_best >/dev/null 2>&1; then
        detected="$(detect_sni_best 2>/dev/null || true)"
        if [ -n "${detected}" ]; then
          print_ok "自动选择：${detected}" >&2
          printf '%s' "${detected}"
          return 0
        fi
      fi
      print_warn "自动检测失败，回退 ${DEFAULT_TLS_SERVER}；请稍后手动指定。" >&2
      printf '%s' "${DEFAULT_TLS_SERVER}"
      return 0
      ;;
    *)
      if is_safe_domain "${value}"; then
        printf '%s' "${value}"
        return 0
      fi
      print_warn "域名格式无效：${value}" >&2
      ;;
    esac
  done
}

add_vless_reality() {
  local tag port name uuid reality_server key_output private_key public_key short_id node_json secret_json
  ensure_singbox_ready
  tag="$(generate_tag "vless-reality")"
  port="$(prompt_port 443)"
  name="$(prompt_with_default "节点名称" "VLESS-Reality")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  reality_server="$(prompt_reality_sni)"

  key_output="$("${SINGBOX_BIN}" generate reality-keypair)"
  private_key="$(printf '%s\n' "$key_output" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n 1)"
  public_key="$(printf '%s\n' "$key_output" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n 1)"
  [ -n "$private_key" ] || fatal "无法解析 Reality 私钥。"
  [ -n "$public_key" ] || fatal "无法解析 Reality 公钥。"
  short_id="$(generate_hex 4)"

  # L11：先收集完输入再拿锁，避免用户停在提示期间长时间占用锁阻塞其他实例
  acquire_lock
  node_json="$(jq -n \
    --arg protocol "vless-reality" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg reality_server "$reality_server" \
    --arg public_key "$public_key" \
    --arg short_id "$short_id" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      reality_server: $reality_server,
      public_key: $public_key,
      short_id: $short_id
    }')"

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg private_key "$private_key" '{ uuid: $uuid, private_key: $private_key }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    rollback_new_node "$tag"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_vless_ws_tls() {
  local tag port name uuid preferred_domain host_domain ws_path cert_bundle cert_mode cert_file key_file node_json secret_json
  ensure_singbox_ready
  tag="$(generate_tag "vless-ws-tls")"
  port="$(prompt_port 8443)"
  name="$(prompt_with_default "节点名称" "VLESS-WS-TLS")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  preferred_domain="$(prompt_cdn_domain)"
  host_domain="$(prompt_safe_domain "Host/SNI 域名" "${DEFAULT_TLS_SERVER}")"
  ws_path="$(prompt_with_default "WebSocket 路径" "$(random_ws_path)")"
  cert_bundle="$(prompt_certificate_bundle "$tag" "$host_domain")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  # L11：先收集完输入再拿锁，避免用户停在提示期间长时间占用锁阻塞其他实例
  acquire_lock
  node_json="$(jq -n \
    --arg protocol "vless-ws-tls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --arg host_domain "$host_domain" \
    --arg ws_path "$ws_path" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      host_domain: $host_domain,
      ws_path: $ws_path,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg uuid "$uuid" '{ uuid: $uuid }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_anytls() {
  local tag port name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  ensure_singbox_ready
  tag="$(generate_tag "anytls")"
  port="$(prompt_port 5443)"
  name="$(prompt_with_default "节点名称" "AnyTLS")"
  password="$(prompt_optional_value "密码（留空自动生成）")"
  password="${password:-$(generate_hex 8)}"
  tls_server="$(prompt_tls_sni)"
  cert_bundle="$(prompt_certificate_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  # L11：先收集完输入再拿锁，避免用户停在提示期间长时间占用锁阻塞其他实例
  acquire_lock
  node_json="$(jq -n \
    --arg protocol "anytls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_vless_xudp() {
  local tag port name uuid security reality_server tls_server key_output private_key public_key short_id
  local cert_bundle cert_mode cert_file key_file node_json secret_json
  ensure_singbox_ready
  tag="$(generate_tag "vless-xudp")"
  port="$(prompt_port 5444)"
  security="${vx_security:-reality}"
  security="$(prompt_with_default "安全方式 (tls/reality)" "$security")"
  case "${security}" in
  tls | reality) ;;
  *) fatal "安全方式无效：${security}（可选 tls/reality）" ;;
  esac

  if [ "${security}" = "reality" ]; then
    name="$(prompt_with_default "节点名称" "VLESS-XUDP-Reality")"
    uuid="$(prompt_optional_value "UUID（留空自动生成）")"
    uuid="${uuid:-$(generate_uuid)}"
    reality_server="$(prompt_reality_sni)"
    key_output="$("${SINGBOX_BIN}" generate reality-keypair)"
    private_key="$(printf '%s\n' "$key_output" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n 1)"
    public_key="$(printf '%s\n' "$key_output" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n 1)"
    [ -n "$private_key" ] || fatal "无法解析 Reality 私钥。"
    [ -n "$public_key" ] || fatal "无法解析 Reality 公钥。"
    short_id="$(generate_hex 4)"

    # L11：先收集完输入再拿锁，避免用户停在提示期间长时间占用锁阻塞其他实例
    acquire_lock
    node_json="$(jq -n \
      --arg protocol "vless-xudp" \
      --arg name "$name" \
      --argjson port "$port" \
      --arg reality_server "$reality_server" \
      --arg public_key "$public_key" \
      --arg short_id "$short_id" '{
        protocol: $protocol,
        name: $name,
        port: $port,
        reality_server: $reality_server,
        public_key: $public_key,
        short_id: $short_id
      }')"
    secret_json="$(jq -n \
      --arg uuid "$uuid" \
      --arg private_key "$private_key" '{ uuid: $uuid, private_key: $private_key }')"

    if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
      rollback_new_node "$tag"
      release_lock
      fatal "添加节点失败：${name}"
    fi
  else
    name="$(prompt_with_default "节点名称" "VLESS-XUDP")"
    uuid="$(prompt_optional_value "UUID（留空自动生成）")"
    uuid="${uuid:-$(generate_uuid)}"
    tls_server="$(prompt_tls_sni)"
    cert_bundle="$(prompt_certificate_bundle "$tag" "$tls_server")"
    cert_mode="${cert_bundle%%|*}"
    cert_file="${cert_bundle#*|}"
    cert_file="${cert_file%%|*}"
    key_file="${cert_bundle##*|}"

    # L11：先收集完输入再拿锁，避免用户停在提示期间长时间占用锁阻塞其他实例
    acquire_lock
    node_json="$(jq -n \
      --arg protocol "vless-xudp" \
      --arg name "$name" \
      --argjson port "$port" \
      --arg tls_server "$tls_server" \
      --arg certificate_mode "$cert_mode" \
      --arg certificate_path "$cert_file" \
      --arg key_path "$key_file" '{
        protocol: $protocol,
        name: $name,
        port: $port,
        tls_server: $tls_server,
        certificate_mode: $certificate_mode,
        certificate_path: $certificate_path,
        key_path: $key_path
      }')"
    secret_json="$(jq -n --arg uuid "$uuid" '{ uuid: $uuid }')"

    if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
      rollback_new_node "$tag" "$cert_file" "$key_file"
      release_lock
      fatal "添加节点失败：${name}"
    fi
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_vless_argo() {
  local tag port name uuid preferred_domain ws_path argo_mode argo_token endpoint_domain node_json secret_json
  ensure_singbox_ready
  tag="$(generate_tag "vless-argo")"
  port="$(prompt_port 8001)"
  name="$(prompt_with_default "节点名称" "VLESS-Argo")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  preferred_domain="$(prompt_cdn_domain)"
  ws_path="$(prompt_with_default "WebSocket 路径" "$(random_ws_path)")"
  argo_mode="$(prompt_choice "隧道模式 (temp/token)" "temp")"
  if [ "${argo_mode}" = "token" ]; then
    argo_token="$(prompt_nonempty "Cloudflared 隧道 Token")"
    endpoint_domain="$(prompt_nonempty "Argo 回源域名")"
    if ! is_safe_domain "${endpoint_domain}"; then
      print_warn "回源域名格式无效：${endpoint_domain}，已回退临时隧道。"
      argo_mode="temp"
      argo_token=""
      endpoint_domain=""
    fi
  else
    argo_mode="temp"
    argo_token=""
    endpoint_domain=""
  fi

  # L11：先收集完输入再拿锁，避免用户停在提示期间长时间占用锁阻塞其他实例
  acquire_lock
  node_json="$(jq -n \
    --arg protocol "vless-argo" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --arg ws_path "$ws_path" \
    --arg argo_mode "$argo_mode" \
    --arg endpoint_domain "$endpoint_domain" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      ws_path: $ws_path,
      argo_mode: $argo_mode,
      endpoint_domain: $endpoint_domain
    }')"

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg argo_token "$argo_token" '{ uuid: $uuid, argo_token: $argo_token }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service || ! start_argo_node "$tag"; then
    # L12：先显式停掉可能已启动的 cloudflared 隧道，避免回滚后进程残留/孤儿 PID
    stop_argo_node "$tag" 2>/dev/null || true
    rollback_new_node "$tag"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_tuic_v5() {
  local tag port name uuid password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  ensure_singbox_ready
  tag="$(generate_tag "tuic-v5")"
  port="$(prompt_port 10443)"
  name="$(prompt_with_default "节点名称" "TUIC-v5")"
  uuid="$(prompt_optional_value "UUID（留空自动生成）")"
  uuid="${uuid:-$(generate_uuid)}"
  password="$(prompt_optional_value "密码（留空自动生成）")"
  password="${password:-$uuid}"
  tls_server="$(prompt_tls_sni)"
  cert_bundle="$(prompt_certificate_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  # L11：先收集完输入再拿锁，避免用户停在提示期间长时间占用锁阻塞其他实例
  acquire_lock
  node_json="$(jq -n \
    --arg protocol "tuic-v5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg uuid "$uuid" --arg password "$password" '{ uuid: $uuid, password: $password }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_hy2() {
  local tag port name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json up_mbps down_mbps
  ensure_singbox_ready
  tag="$(generate_tag "hy2")"
  port="$(prompt_port 11443)"
  name="$(prompt_with_default "节点名称" "Hysteria2")"
  password="$(prompt_optional_value "密码（留空自动生成）")"
  password="${password:-$(generate_hex 8)}"
  tls_server="$(prompt_tls_sni)"
  # L3：带宽须为正整数（留空=默认 200，0=不限速），非数字/负数直接拒收重输；
  # 非数字会被 jq --argjson 当成非法 JSON 中断，必须在此拦截。
  up_mbps="$(prompt_optional_value "上行带宽 Mbps（留空=默认 200，0=不限速）")"
  while [ -n "${up_mbps}" ] && ! [[ "${up_mbps}" =~ ^[0-9]+$ ]]; do
    print_warn "上行带宽应为非负整数（Mbps）。"
    up_mbps="$(prompt_optional_value "上行带宽 Mbps（留空=默认 200，0=不限速）")"
  done
  up_mbps="${up_mbps:-200}"
  down_mbps="$(prompt_optional_value "下行带宽 Mbps（留空=默认 200，0=不限速）")"
  while [ -n "${down_mbps}" ] && ! [[ "${down_mbps}" =~ ^[0-9]+$ ]]; do
    print_warn "下行带宽应为非负整数（Mbps）。"
    down_mbps="$(prompt_optional_value "下行带宽 Mbps（留空=默认 200，0=不限速）")"
  done
  down_mbps="${down_mbps:-200}"
  cert_bundle="$(prompt_certificate_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  # L11：先收集完输入再拿锁，避免用户停在提示期间长时间占用锁阻塞其他实例
  acquire_lock
  node_json="$(jq -n \
    --arg protocol "hy2" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --argjson up_mbps "${up_mbps:-0}" \
    --argjson down_mbps "${down_mbps:-0}" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      tls_server: $tls_server,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }
    + (if ($up_mbps > 0) then { up_mbps: $up_mbps } else {} end)
    + (if ($down_mbps > 0) then { down_mbps: $down_mbps } else {} end)')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    rollback_new_node "$tag" "$cert_file" "$key_file"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}

add_socks5() {
  local tag port name username password node_json secret_json
  ensure_singbox_ready
  tag="$(generate_tag "socks5")"
  port="$(prompt_port 1080)"
  name="$(prompt_with_default "节点名称" "SOCKS5")"
  username="$(prompt_with_default "用户名" "user")"
  password="$(prompt_optional_value "密码（留空自动生成）")"
  password="${password:-$(generate_hex 6)}"

  # L11：先收集完输入再拿锁，避免用户停在提示期间长时间占用锁阻塞其他实例
  acquire_lock
  node_json="$(jq -n \
    --arg protocol "socks5" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg username "$username" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      username: $username
    }')"

  secret_json="$(jq -n --arg password "$password" '{ password: $password }')"

  if ! save_node_bundle "$tag" "$node_json" "$secret_json" || ! render_config || ! reload_service; then
    rollback_new_node "$tag"
    release_lock
    fatal "添加节点失败：${name}"
  fi

  sanitize_permissions
  release_lock
  print_ok "已添加节点：${name}"
}
