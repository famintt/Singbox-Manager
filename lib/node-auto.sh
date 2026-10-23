#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 3.1：Reality multi short_id——短 ID 以逗号分隔配置（ENV short_ids），
# 过滤掉非法的十六进制/奇数长度/超长 token；无合法项时返回失败由调用方生成默认单 ID。
resolve_short_ids() {
  local raw="$1" tok out=""
  local -a tokens
  [ -n "${raw}" ] || return 1
  raw="$(printf '%s' "${raw}" | tr -d ' \r\n')"
  IFS=',' read -r -a tokens <<<"${raw}"
  for tok in "${tokens[@]}"; do
    if [[ "${tok}" =~ ^[0-9a-fA-F]+$ ]] && [ $((${#tok} % 2)) -eq 0 ] &&
      [ "${#tok}" -ge 2 ] && [ "${#tok}" -le 32 ]; then
      if [ -n "${out}" ]; then
        out="${out},"
      fi
      out="${out}${tok,,}"
    fi
  done
  [ -n "${out}" ] || return 1
  printf '%s' "${out}"
}

tls_sni_auto() {
  local key="$1" fallback="$2" raw mode
  raw="$(env_var "${key}")"
  mode="$(env_var "cert")"
  mode="${mode:-self}"
  case "${raw,,}" in
  "")
    env_domain_or_default "${key}" "${fallback}"
    ;;
  auto)
    if [ "${mode}" = "custom" ]; then
      print_warn "${key}=auto 不能用于自定义证书，回退 ${fallback}；请填写证书域名。"
      printf '%s' "${fallback}"
      return 0
    fi
    if [ -n "${TLS_SNI_AUTO_CACHE:-}" ]; then
      printf '%s' "${TLS_SNI_AUTO_CACHE}"
      return 0
    fi
    print_info "正在检测 TLS SNI（TLS 1.3 + HTTP/2，自签证书）..." >&2
    TLS_SNI_AUTO_CACHE="$(detect_sni_best 2>/dev/null || printf '%s' "${fallback}")"
    printf '%s' "${TLS_SNI_AUTO_CACHE}"
    ;;
  *)
    env_domain_or_default "${key}" "${fallback}"
    ;;
  esac
}

auto_cert_bundle() {
  local tag="$1"
  local domain="$2"
  # 局部变量统一 __ 前缀：cert_path/key_path/cert_b64/key_b64 是环境变量键名，
  # 若声明同名局部变量，env_var 的间接引用会命中空的局部变量（bash 动态作用域）
  local __mode __cert_path __key_path __cert_b64 __key_b64 __pair

  __mode="$(env_var "cert")"
  __mode="${__mode:-self}"
  if [ "${__mode}" = "custom" ]; then
    # v1.2.5 优先接口粘贴的 PEM 内容（base64），无内容时回退文件路径方式
    __cert_b64="$(env_var "cert_b64")"
    __key_b64="$(env_var "key_b64")"
    if [ -n "$__cert_b64" ] || [ -n "$__key_b64" ]; then
      if [ -n "$__cert_b64" ] && [ -n "$__key_b64" ] && __pair="$(import_custom_certificate_content "$tag" "$__cert_b64" "$__key_b64")"; then
        printf 'custom|%s|%s' "${__pair%|*}" "${__pair#*|}"
        return 0
      fi
      print_warn "cert_b64/key_b64 解码失败（无效的 base64 或缺少其一），节点 ${tag} 回退自签证书。"
      __pair="$(ensure_tls_material "$tag" "www.bing.com")"
      printf 'self-signed|%s|%s' "${__pair%|*}" "${__pair#*|}"
      return 0
    fi
    __cert_path="$(env_var "cert_path")"
    __key_path="$(env_var "key_path")"
    if [ -n "$__cert_path" ] && [ -n "$__key_path" ] && __pair="$(import_custom_certificate_bundle "$tag" "$__cert_path" "$__key_path")"; then
      printf 'custom|%s|%s' "${__pair%|*}" "${__pair#*|}"
      return 0
    fi
    print_warn "自定义证书不可用（缺少 cert_path/key_path 或读取失败），节点 ${tag} 回退自签证书。"
  elif [ "${__mode}" != "self" ] && [ "${__mode}" != "self-signed" ]; then
    print_warn "未知证书模式 cert=${__mode}，节点 ${tag} 使用自签证书。"
  fi
  __pair="$(ensure_tls_material "$tag" "www.bing.com")"
  printf 'self-signed|%s|%s' "${__pair%|*}" "${__pair#*|}"
}
auto_add_vless_reality() {
  local port="$1"
  local tag name uuid reality_server key_output private_key public_key short_id node_json secret_json
  tag="$(generate_tag "vless-reality")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-Reality"; else name="VLESS-Reality"; fi
  uuid="${ENV_UUID:-$(generate_uuid)}"
  reality_server="${ENV_VL_SNI:-${DEFAULT_REALITY_SERVER}}"

  private_key="$(manager_env_or_setting "reality_private" "")"
  public_key="$(manager_env_or_setting "reality_public" "")"
  if [ -z "${private_key}" ] || [ -z "${public_key}" ]; then
    if [ -n "${private_key}" ] || [ -n "${public_key}" ]; then
      print_warn "reality_private/reality_public 必须成对提供，缺少一项，将重新生成 Reality 密钥对。"
    fi
    if ! key_output="$("${SINGBOX_BIN}" generate reality-keypair)"; then
      print_err "生成 Reality 密钥对失败，跳过 vlrt 节点。"
      return 1
    fi
    private_key="$(printf '%s\n' "$key_output" | sed -n 's/^PrivateKey:[[:space:]]*//p' | head -n 1)"
    public_key="$(printf '%s\n' "$key_output" | sed -n 's/^PublicKey:[[:space:]]*//p' | head -n 1)"
  fi
  if [ -z "$private_key" ] || [ -z "$public_key" ]; then
    print_err "无法解析 Reality 密钥对，跳过 vlrt 节点。"
    return 1
  fi
  # 3.1：ENV short_ids 逗号分隔多 short_id（集群客户端用不同短 ID 做入口区分），
  # 无合法项时回退生成单个默认短 ID
  if ! short_id="$(resolve_short_ids "$(env_var "short_ids")")"; then
    short_id="$(generate_hex 4)"
  fi

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

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}
auto_add_vless_ws_tls() {
  local port="$1"
  local tag name uuid preferred_domain host_domain ws_path cert_bundle cert_mode cert_file key_file node_json secret_json ws_mode cdn_port cdn_sni
  tag="$(generate_tag "vless-ws-tls")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-WS-TLS"; else name="VLESS-WS-TLS"; fi
  uuid="${ENV_UUID:-$(generate_uuid)}"
  # CDN 连接地址（ws_cdn 设计：脚本专用 > 共享 > 兼容旧名 cdn_host > 内置默认）
  preferred_domain="${ENV_WS_CDN_VLESS_CF_HOST:-${ENV_WS_CDN_CF_HOST:-${ENV_CDN_HOST:-${DEFAULT_CDN_DOMAIN}}}}"
  host_domain="${ENV_WS_HOST:-${DEFAULT_TLS_SERVER}}"
  ws_path="${ENV_WS_PATH:-$(random_ws_path)}"
  ws_mode="${ENV_WS_MODE:-direct}"
  # CDN 端口：脚本专用 > 共享 > 兼容旧名 cdn_port > 443
  cdn_port="${ENV_WS_CDN_VLESS_CF_PT:-${ENV_WS_CDN_CF_PT:-${ENV_CDN_PORT:-443}}}"
  # CDN 回源域名/SNI（仅 cdn 模式使用）：脚本专用 > 共享 > 内置默认（= 连接地址，与 jyucoeng 语义一致）
  cdn_sni="${ENV_WS_CDN_VLESS_SNI:-${ENV_WS_CDN_SNI:-${preferred_domain}}}"
  case "${ws_mode}" in
  direct | cdn) ;;
  *)
    print_warn "ws_mode=${ws_mode} 非法，回退 direct（可选值：direct|cdn）。"
    ws_mode="direct"
    ;;
  esac
  if [[ ! "${cdn_port}" =~ ^[0-9]+$ ]] || [ "${cdn_port}" -lt 1 ] || [ "${cdn_port}" -gt 65535 ]; then
    print_warn "cdn_port=${cdn_port} 非法，回退 443。"
    cdn_port=443
  fi
  cert_bundle="$(auto_cert_bundle "$tag" "$host_domain")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "vless-ws-tls" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --arg host_domain "$host_domain" \
    --arg ws_path "$ws_path" \
    --arg ws_mode "$ws_mode" \
    --argjson cdn_port "$cdn_port" \
    --arg cdn_sni "$cdn_sni" \
    --arg certificate_mode "$cert_mode" \
    --arg certificate_path "$cert_file" \
    --arg key_path "$key_file" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      host_domain: $host_domain,
      ws_path: $ws_path,
      ws_mode: $ws_mode,
      cdn_port: $cdn_port,
      cdn_sni: $cdn_sni,
      certificate_mode: $certificate_mode,
      certificate_path: $certificate_path,
      key_path: $key_path
    }')"

  secret_json="$(jq -n --arg uuid "$uuid" '{ uuid: $uuid }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}
auto_add_anytls() {
  local port="$1"
  local tag name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  tag="$(generate_tag "anytls")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-AnyTLS"; else name="AnyTLS"; fi
  password="${ENV_PASSWD:-$(generate_hex 8)}"
  tls_server="${ENV_ANY_SNI:-${DEFAULT_TLS_SERVER}}"
  cert_bundle="$(auto_cert_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

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

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}
auto_add_vless_argo() {
  local port="$1"
  local tag name uuid preferred_domain cdn_port ws_path argo_mode argo_token endpoint_domain node_json secret_json
  tag="$(generate_tag "vless-argo")"
  if [ -n "${ENV_NAME:-}" ]; then name="${ENV_NAME}-Argo"; else name="VLESS-Argo"; fi
  uuid="${ENV_UUID:-$(generate_uuid)}"
  # Argo 专属优选域名/端口（v0.3.3）：独立于 WS-CDN，缺省回退 cdn_host/443
  preferred_domain="${ENV_ARGO_CDN_HOST:-${ENV_CDN_HOST:-${DEFAULT_CDN_DOMAIN}}}"
  cdn_port="${ENV_ARGO_CDN_PORT:-443}"
  if [[ ! "${cdn_port}" =~ ^[0-9]+$ ]] || [ "${cdn_port}" -lt 1 ] || [ "${cdn_port}" -gt 65535 ]; then
    print_warn "argo_cdn_port=${cdn_port} 非法，回退 443。"
    cdn_port=443
  fi
  ws_path="${ENV_WS_PATH:-$(random_ws_path)}"
  argo_token="$(env_var "agk")"
  endpoint_domain="$(env_var "agn")"
  if [ -n "$argo_token" ] && [ -n "$endpoint_domain" ] && is_safe_domain "${endpoint_domain}"; then
    argo_mode="token"
  else
    if [ -n "$argo_token" ] || [ -n "$endpoint_domain" ]; then
      # 与交互路径一致：agn 必须通过域名白名单，防止异常值入库后被 watchdog 消费
      if [ -n "$endpoint_domain" ] && ! is_safe_domain "${endpoint_domain}"; then
        print_warn "Argo 固定隧道 agn=${endpoint_domain} 域名格式无效，已回退临时隧道。"
      else
        print_warn "Argo 固定隧道需要同时提供 agn（域名）和 agk（Token），已回退临时隧道。"
      fi
    fi
    argo_mode="temp"
    argo_token=""
    endpoint_domain=""
  fi

  node_json="$(jq -n \
    --arg protocol "vless-argo" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg preferred_domain "$preferred_domain" \
    --argjson cdn_port "$cdn_port" \
    --arg ws_path "$ws_path" \
    --arg argo_mode "$argo_mode" \
    --arg endpoint_domain "$endpoint_domain" '{
      protocol: $protocol,
      name: $name,
      port: $port,
      preferred_domain: $preferred_domain,
      cdn_port: $cdn_port,
      ws_path: $ws_path,
      argo_mode: $argo_mode,
      endpoint_domain: $endpoint_domain
    }')"

  secret_json="$(jq -n \
    --arg uuid "$uuid" \
    --arg argo_token "$argo_token" '{ uuid: $uuid, argo_token: $argo_token }')"

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 本地端口: ${port} | 模式: ${argo_mode}"
}
auto_add_tuic_v5() {
  local port="$1"
  local tag name uuid password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  tag="$(generate_tag "tuic-v5")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-TUIC"; else name="TUIC-v5"; fi
  uuid="${ENV_UUID:-$(generate_uuid)}"
  password="${ENV_PASSWD:-$uuid}"
  tls_server="${ENV_TU_SNI:-${DEFAULT_TLS_SERVER}}"
  cert_bundle="$(auto_cert_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

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

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}
auto_add_hy2() {
  local port="$1"
  local tag name password tls_server cert_bundle cert_mode cert_file key_file node_json secret_json
  local __hy_up __hy_down
  tag="$(generate_tag "hy2")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-HY2"; else name="Hysteria2"; fi
  password="${ENV_PASSWD:-$(generate_hex 8)}"
  tls_server="${ENV_HY_SNI:-${DEFAULT_TLS_SERVER}}"
  # 局部名不用 up_mbps/down_mbps，避免遮蔽同名用户环境变量导致读取为空
  # 默认 200 Mbps（未显式设置时）；只填其一则另一个独立成单方向限速
  __hy_up="$(env_var "up_mbps")"
  __hy_down="$(env_var "down_mbps")"
  __hy_up="${__hy_up:-200}"
  __hy_down="${__hy_down:-200}"
  case "${__hy_up}" in
  *[!0-9]* | "") __hy_up="200" ;;
  esac
  case "${__hy_down}" in
  *[!0-9]* | "") __hy_down="200" ;;
  esac
  cert_bundle="$(auto_cert_bundle "$tag" "$tls_server")"
  cert_mode="${cert_bundle%%|*}"
  cert_file="${cert_bundle#*|}"
  cert_file="${cert_file%%|*}"
  key_file="${cert_bundle##*|}"

  node_json="$(jq -n \
    --arg protocol "hy2" \
    --arg name "$name" \
    --argjson port "$port" \
    --arg tls_server "$tls_server" \
    --argjson up_mbps "$__hy_up" \
    --argjson down_mbps "$__hy_down" \
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

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}
auto_add_socks5() {
  local port="$1"
  local tag name username password node_json secret_json
  tag="$(generate_tag "socks5")"
  if [ -n "${ENV_NAME}" ]; then name="${ENV_NAME}-SOCKS5"; else name="SOCKS5"; fi
  username="${ENV_SOCKS5_USER:-user}"
  password="${ENV_SOCKS5_PASS:-$(generate_hex 6)}"

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

  auto_save_node "$tag" "$node_json" "$secret_json"
  print_ok "已写入节点：${name} | 端口: ${port}"
}
auto_install() {
  local action="$1"
  local tag port spec line backup_dir
  local added=0 failed=0
  local -a specs=()
  local ENV_NAME ENV_UUID ENV_PASSWD
  local ENV_VL_SNI ENV_TU_SNI ENV_ANY_SNI ENV_HY_SNI ENV_WS_HOST ENV_WS_PATH ENV_CDN_HOST
  local ENV_WS_MODE ENV_CDN_PORT
  local ENV_ARGO_CDN_HOST ENV_ARGO_CDN_PORT
  local ENV_WS_CDN_CF_HOST ENV_WS_CDN_CF_PT ENV_WS_CDN_SNI
  local ENV_WS_CDN_VLESS_CF_HOST ENV_WS_CDN_VLESS_CF_PT ENV_WS_CDN_VLESS_SNI
  local ENV_SOCKS5_USER ENV_SOCKS5_PASS

  if [ -x /usr/local/bin/mm ] || [ -f /usr/local/etc/mihomo-manager/settings.json ]; then
    print_warn "检测到 Mihomo Manager。sbm 与 mm 共用 cloudflared，且可能占用相同端口；建议同机只保留一套。"
  fi

  init_storage

  if ! auto_has_node_env; then
    print_err "未检测到任何节点环境变量（vlrt / wspt / tupt / anypt / hypt / socks5pt / argo），放弃安装。"
    print_info "示例：vlrt=2083 hypt=2082 name='HK' sbm ${action}"
    exit 1
  fi

  # 预校验：端口非法在这里直接失败，任何已有数据都不会被改动
  if ! spec="$(auto_collect_specs)"; then
    print_err "输入校验失败，未更改任何数据。"
    exit 1
  fi
  while IFS= read -r line; do
    [ -n "${line}" ] && specs+=("${line}")
  done <<<"${spec}"
  if [ "${#specs[@]}" -eq 0 ]; then
    print_err "未检测到有效的节点端口环境变量，放弃安装。"
    exit 1
  fi

  ensure_singbox_ready
  # 已有安装时 ensure_singbox_ready 不会重跑 install_core；每次 rep/ins 都补应用一次
  # 网络调优，保证升级到固定 BBR+fq 参数后无需手动进菜单。刚走完 install_core
  # 的本轮已应用过，避免重复打印/重复写 sysctl。
  if [ -z "${_NET_TUNE_APPLIED:-}" ]; then
    apply_network_tune || true
  fi
  acquire_lock

  # 破坏性操作前先快照；rep 失败时据此恢复
  backup_dir="$(backup_state)"

  if [ "${action}" = "rep" ]; then
    while IFS= read -r tag; do
      [ -n "${tag}" ] || continue
      stop_argo_node "${tag}"
    done < <(iter_node_tags)
    stop_service || true
    wipe_records
    # 标记 rep 事务窗口：此后任何失败（render/check/start/证书迁移）都会触发
    # handle_common_error 自动恢复该备份，禁止停留"旧节点消失、新配置未启动"状态（F-02）
    # shellcheck disable=SC2034  # 在 lib/env.sh 的 ERR 陷阱中读取
    _AUTO_ROLLBACK_DIR="${backup_dir}"
    print_info "已清空原有节点（备份：${backup_dir}），按环境变量重建。"
  else
    print_info "已备份现有状态：${backup_dir}"
  fi

  ENV_NAME="$(env_var "name")"
  ENV_UUID="$(env_var "uuid")"
  ENV_PASSWD="$(env_var "passwd")"
  # 域名类环境变量经白名单校验，非法值回退内置默认
  ENV_VL_SNI_RAW="$(env_var "vl_sni")"
  if [ -z "${ENV_VL_SNI_RAW}" ] || [ "${ENV_VL_SNI_RAW,,}" = "auto" ]; then
    ENV_VL_SNI="$(detect_sni_best 2>/dev/null || printf '%s' "${DEFAULT_REALITY_SERVER}")"
  else
    ENV_VL_SNI="$(env_domain_or_default "vl_sni" "${DEFAULT_REALITY_SERVER}")"
  fi
  ENV_TU_SNI="$(tls_sni_auto "tu_sni" "${DEFAULT_TLS_SERVER}")"
  ENV_ANY_SNI="$(tls_sni_auto "any_sni" "${DEFAULT_TLS_SERVER}")"
  ENV_HY_SNI="$(tls_sni_auto "hy_sni" "${DEFAULT_TLS_SERVER}")"
  ENV_WS_HOST="$(env_domain_or_default "ws_host" "${DEFAULT_TLS_SERVER}")"
  ENV_WS_PATH="$(env_var "ws_path")"
  ENV_WS_MODE="$(env_var "ws_mode")"
  ENV_CDN_PORT="$(env_var "cdn_port")"
  ENV_CDN_HOST="$(env_domain_or_default "cdn_host" "${DEFAULT_CDN_DOMAIN}")"
  # Argo 专属优选域名/端口（v0.3.3）：与 WS-CDN 独立设置，缺省回退 cdn_host/443
  ENV_ARGO_CDN_HOST="$(env_domain_or_default "argo_cdn_host" "${ENV_CDN_HOST}")"
  ENV_ARGO_CDN_PORT="$(env_var "argo_cdn_port")"
  # ws_cdn 设计（v0.3.0）：脚本专用前缀优先，共享前缀次之，兼容旧名 cdn_host/ws_host/cdn_port 兜底。
  # 域名类变量经白名单校验，空值留给调用方回退链处理。
  ENV_WS_CDN_CF_HOST="$(env_domain_or_default "ws_cdn_cf_host" "")"
  ENV_WS_CDN_CF_PT="$(env_var "ws_cdn_cf_pt")"
  ENV_WS_CDN_SNI="$(env_domain_or_default "ws_cdn_sni" "")"
  ENV_WS_CDN_VLESS_CF_HOST="$(env_domain_or_default "ws_cdn_vless_cf_host" "")"
  ENV_WS_CDN_VLESS_CF_PT="$(env_var "ws_cdn_vless_cf_pt")"
  ENV_WS_CDN_VLESS_SNI="$(env_domain_or_default "ws_cdn_vless_sni" "")"
  # v1.2.4：CDN 采 CF 证书方案（Full/Full-Strict 回源），源站仅一个 TLS WS inbound（wspt），
  # 不再生成明文 HTTP 回源 inbound；ws_cdn_origin_port 已废弃。证书方式支持
  # cert=custom（如 Cloudflare Origin CA 证书）+ cert_path/key_path，自签默认适用于 Full 模式。
  # 默认优选域名仅在 ws_mode=cdn（CDN 中转）时要求本机已接入前置 CDN；直连模式（默认）不依赖 cdn_host
  if [ "${ENV_CDN_HOST}" = "${DEFAULT_CDN_DOMAIN}" ] && [ "${ENV_WS_MODE:-direct}" = "cdn" ] && [ "${confirm_default_cdn:-}" != "1" ]; then
    print_warn "⚠️ 未设置有效 cdn_host：WS-TLS(CDN 中转) 节点将使用内置优选域名 ${DEFAULT_CDN_DOMAIN}（仅该域名已接入本机前置 CDN 时可达）。"
    print_warn "   请改用 cdn_host=你的优选域名或IP 重新执行；确认使用默认值可加 confirm_default_cdn=1 消除本提示。"
  fi
  ENV_SOCKS5_USER="$(env_var "socks5_username")"
  ENV_SOCKS5_PASS="$(env_var "socks5_password")"

  # P5/S3：持久化性能与调优参数（go_gc / net_tune / 内存上限），使 rep、重启、
  # watchdog 等后续流程在无 install 环境变量时也能读取同一套全局配置。
  local _key _val
  for _key in go_gc net_tune mem_high_mb mem_max_mb server_ip direct_host reality_private reality_public debug_flag socks5_wl_flag socks5_ips; do
    _val="$(env_var "$_key")"
    if [ -n "${_val}" ]; then
      set_setting "$_key" "$_val"
    fi
  done

  for line in "${specs[@]}"; do
    port="${line##* }"
    case "${line%% *}" in
    vless-reality)
      if auto_try_port "$port" "VLESS-Reality"; then
        auto_add_vless_reality "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    vless-ws-tls)
      if auto_try_port "$port" "VLESS-WS-TLS"; then
        auto_add_vless_ws_tls "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    anytls)
      if auto_try_port "$port" "AnyTLS"; then
        auto_add_anytls "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    vless-argo)
      if auto_try_port "$port" "VLESS-Argo"; then
        auto_add_vless_argo "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    tuic-v5)
      if auto_try_port "$port" "TUIC-v5"; then
        auto_add_tuic_v5 "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    hy2)
      if auto_try_port "$port" "Hysteria2"; then
        auto_add_hy2 "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    socks5)
      if auto_try_port "$port" "SOCKS5"; then
        auto_add_socks5 "$port" && added=$((added + 1)) || failed=$((failed + 1))
      else
        failed=$((failed + 1))
      fi
      ;;
    esac
  done

  if [ "${added}" -eq 0 ]; then
    _AUTO_ROLLBACK_DIR=""
    if [ "${action}" = "rep" ]; then
      restore_latest_backup || true
      reconcile_state || true
      render_config || true
      start_service || true
      print_err "没有成功写入任何节点（added=0, failed=${failed}），已恢复安装前的节点状态。"
    else
      print_err "没有成功写入任何节点（added=0, failed=${failed}），现有节点未受影响。"
    fi
    release_lock
    exit 1
  fi

  if [ "${action}" = "rep" ]; then
    cleanup_orphan_certs
  fi
  render_config
  reload_service
  # 事务已提交：清除回滚标记，此后失败不再触发整事务回滚
  _AUTO_ROLLBACK_DIR=""
  # 隧道启动失败（如临时域名等待超时）不应判定整次安装失败
  restart_all_argo_nodes || print_warn "部分 Argo 隧道启动失败，稍后可用 sbm list 重查域名。"
  cleanup_unused_cloudflared || true

  case "$(env_var "sub")" in
  1 | on | yes | true) set_setting "sub_enabled" "1" || true ;;
  esac
  case "$(env_var "sub_mode")" in
  worker)
    set_setting "sub_mode" "worker" || true
    set_setting "sub_domain" "$(env_var "sub_domain")" || true
    set_setting "sub_token" "$(env_var "sub_token")" || true
    set_setting "sub_machine" "$(env_var "sub_machine")" || true
    ;;
  *) set_setting "sub_mode" "temp" || true ;;
  esac
  if sub_enabled; then
    sub_start || print_warn "订阅链接启动失败，可稍后在菜单/命令行重试。"
  fi

  sanitize_permissions
  release_lock

  echo
  print_ok "一键安装完成：新增 ${added} 个节点，失败 ${failed} 个。"
  echo
  print_node_list
  if [ -s "$(sub_url_file)" ]; then
    echo "订阅链接：$(cat "$(sub_url_file)")"
    echo
  fi
  if [ "${failed}" -gt 0 ]; then
    exit 1
  fi
}
