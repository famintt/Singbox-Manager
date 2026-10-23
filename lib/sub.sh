#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

# 订阅链接（测试版）：
#   - 只在 127.0.0.1 上跑一个静态 HTTP 服务（darkhttpd / python3 -m http.server）；
#   - 用第二个 cloudflared 临时隧道把它暴露成 https://<random>.trycloudflare.com/<token>.txt；
#   - token 为 32 位随机 hex，路径不可猜；订阅内容是全部节点链接的 base64。
#   - 不占用 NAT 机的公网端口：本地端口仅 loopback，公网走 Cloudflare 443。

sub_dir() { printf '%s/sub' "${BASE_DIR}"; }
sub_url_file() { printf '%s/url' "$(sub_dir)"; }
sub_http_log() { printf '%s/sub-http.log' "${LOG_DIR}"; }
sub_tunnel_log() { printf '%s/sub.cloudflared.log' "${LOG_DIR}"; }
sub_http_pid_file() { printf '%s/sub-http.pid' "${RUNTIME_DIR}"; }
sub_tunnel_pid_file() { printf '%s/sub-tunnel.pid' "${RUNTIME_DIR}"; }

sub_enabled() {
  case "$(manager_env_or_setting "sub" "")" in
  1 | on | yes | true) return 0 ;;
  esac
  [ "$(get_setting "sub_enabled" "0")" = "1" ]
}

sub_mode() {
  local mode
  mode="$(manager_env_or_setting "sub_mode" "temp")"
  case "${mode}" in
  worker | temp) printf '%s' "${mode}" ;;
  *) printf 'temp' ;;
  esac
}

sub_worker_base() {
  local base
  base="$(manager_env_or_setting "sub_domain" "")"
  [ -n "${base}" ] || return 1
  case "${base}" in
  http://* | https://*) ;;
  *) base="https://${base}" ;;
  esac
  printf '%s' "${base%/}"
}

sub_worker_token() {
  manager_env_or_setting "sub_token" ""
}

sub_machine() {
  local raw
  raw="$(manager_env_or_setting "sub_machine" "")"
  [ -n "${raw}" ] || raw="$(manager_env_or_setting "name" "")"
  [ -n "${raw}" ] || raw="$(hostname 2>/dev/null || printf 'node')"
  raw="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  [ -n "${raw}" ] || raw="node"
  printf '%s' "${raw:0:64}"
}

sub_content_hash() {
  local file="$1"
  if command_exists sha256sum; then
    sha256sum "${file}" | awk '{print $1}'
  elif command_exists shasum; then
    shasum -a 256 "${file}" | awk '{print $1}'
  else
    openssl dgst -sha256 "${file}" | awk '{print $NF}'
  fi
}

# 上报到 sub-worker；成功时写入固定订阅链接。
sub_report() {
  local base token machine file url header_file response_file status hash
  base="$(sub_worker_base)" || {
    print_err "订阅设置缺少域名（sub_domain）。"
    return 1
  }
  token="$(sub_worker_token)"
  [ -n "${token}" ] || {
    print_err "订阅设置缺少密钥（sub_token）。"
    return 1
  }
  machine="$(sub_machine)"
  file="$(sub_file)"
  [ -s "${file}" ] || {
    print_err "订阅文件不存在：${file}"
    return 1
  }
  command_exists curl || {
    print_err "订阅上报需要 curl。"
    return 1
  }

  header_file="$(mktemp "$(sub_dir)/.report-header.XXXXXX")" || return 1
  response_file="$(mktemp "$(sub_dir)/.report-response.XXXXXX")" || {
    rm -f "${header_file}"
    return 1
  }
  chmod 600 "${header_file}" "${response_file}"
  # token 不进入 argv，避免 ps 可见
  printf 'Authorization: Bearer %s\nContent-Type: text/plain\n' "${token}" >"${header_file}"

  status="$(curl -sS --retry 2 --retry-delay 2 --connect-timeout 10 --max-time 30 \
    -o "${response_file}" -w '%{http_code}' \
    -X POST -H "@${header_file}" --data-binary "@${file}" \
    "${base}/api/v1/report/${machine}" 2>/dev/null || true)"
  if [ "${status}" != "200" ]; then
    print_err "订阅上报失败（HTTP ${status:-000}）：$(head -c 300 "${response_file}" 2>/dev/null || true)"
    rm -f "${header_file}" "${response_file}"
    return 1
  fi

  hash="$(sub_content_hash "${file}" 2>/dev/null || true)"
  url="${base}/sub/${machine}/$(url_encode "${token}")"
  printf '%s\n' "${url}" >"$(sub_url_file)"
  chmod 600 "$(sub_url_file)"
  set_setting "sub_url" "${url}" || true
  set_setting "sub_hash" "${hash}" || true
  set_setting "sub_machine" "${machine}" || true
  rm -f "${header_file}" "${response_file}"
  print_ok "订阅已上报：${url}"
  return 0
}

sub_local_port() {
  local port
  port="$(manager_env_or_setting "sub_port" "18080")"
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || [ "${port}" -lt 1 ] || [ "${port}" -gt 65535 ]; then
    port=18080
  fi
  printf '%s' "${port}"
}

sub_token() {
  local dir token_file token
  dir="$(sub_dir)"
  token_file="${dir}/token"
  ensure_dir_mode "${dir}" 700
  if [ ! -s "${token_file}" ]; then
    generate_hex 16 >"${token_file}"
    chmod 600 "${token_file}"
  fi
  token="$(tr -d '\r\n' <"${token_file}")"
  if ! [[ "${token}" =~ ^[0-9a-f]{32}$ ]]; then
    generate_hex 16 >"${token_file}"
    chmod 600 "${token_file}"
    token="$(tr -d '\r\n' <"${token_file}")"
  fi
  printf '%s' "${token}"
}

sub_file() {
  printf '%s/%s.txt' "$(sub_dir)" "$(sub_token)"
}

# 生成订阅内容：节点链接一行一个，再整体 base64（订阅客户端标准格式）。
sub_build_file() {
  local dir token tmp links_tmp public_ip tag link
  dir="$(sub_dir)"
  ensure_dir_mode "${dir}" 700
  token="$(sub_token)"
  # 串行探测：避免在部分 Alpine/Bash 组合下，命令替换内的并行 wait 反复空转。
  if [ -n "$(manager_env_or_setting "direct_host" "")" ] || [ -n "$(manager_env_or_setting "server_ip" "")" ]; then
    public_ip=""
  else
    public_ip="$(SBM_IP_PROBE_PARALLEL=0 get_public_ip 2>/dev/null || true)"
  fi
  tmp="$(mktemp "${dir}/.sub.XXXXXX")" || return 1
  links_tmp="$(mktemp "${dir}/.links.XXXXXX")" || {
    rm -f "${tmp}"
    return 1
  }

  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    link="$(build_share_link "${tag}" "${public_ip}" 2>/dev/null || true)"
    [ -n "${link}" ] && printf '%s\n' "${link}" >>"${links_tmp}"
  done < <(iter_node_tags)

  if [ ! -s "${links_tmp}" ]; then
    rm -f "${tmp}" "${links_tmp}"
    print_warn "当前没有可写入订阅的节点。"
    return 1
  fi
  base64 <"${links_tmp}" | tr -d '\n' >"${tmp}"
  printf '\n' >>"${tmp}"
  chmod 600 "${tmp}" "${links_tmp}"
  mv -f "${links_tmp}" "${dir}/links.txt"
  mv -f "${tmp}" "${dir}/${token}.txt"
  chmod 600 "${dir}/links.txt" "${dir}/${token}.txt"
  return 0
}

sub_http_start() {
  local dir port log pid_file pid
  dir="$(sub_dir)"
  port="$(sub_local_port)"
  log="$(sub_http_log)"
  pid_file="$(sub_http_pid_file)"
  ensure_dir_mode "${dir}" 700
  ensure_dir_mode "${LOG_DIR}" 700
  ensure_dir_mode "${RUNTIME_DIR}" 700
  # 防止目录列表泄露 token 文件名（darkhttpd 在无 index 时会列目录）
  printf 'not found\n' >"${dir}/index.html"
  chmod 600 "${dir}/index.html"

  pid="$(read_pid_file "${pid_file}" 2>/dev/null || true)"
  if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
    return 0
  fi

  if ! command_exists darkhttpd && command_exists apk; then
    apk add --no-cache darkhttpd >/dev/null 2>&1 || true
  fi

  if command_exists darkhttpd; then
    nohup darkhttpd "${dir}" --port "${port}" --addr 127.0.0.1 \
      >>"${log}" 2>&1 </dev/null &
  elif command_exists python3; then
    nohup python3 -m http.server "${port}" --bind 127.0.0.1 --directory "${dir}" \
      >>"${log}" 2>&1 </dev/null &
  else
    print_err "订阅服务需要 darkhttpd 或 python3，当前系统均不可用。"
    return 1
  fi
  pid=$!
  write_pid_file "${pid_file}" "${pid}"
  sleep 1
  if ! kill -0 "${pid}" 2>/dev/null; then
    rm -f "${pid_file}"
    print_err "订阅 HTTP 服务启动失败，日志：${log}"
    return 1
  fi
  return 0
}

sub_tunnel_start() {
  local port log pid_file pid domain token url
  port="$(sub_local_port)"
  log="$(sub_tunnel_log)"
  pid_file="$(sub_tunnel_pid_file)"
  ensure_dir_mode "${LOG_DIR}" 700
  ensure_dir_mode "${RUNTIME_DIR}" 700

  pid="$(read_pid_file "${pid_file}" 2>/dev/null || true)"
  if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && [ -s "$(sub_url_file)" ]; then
    return 0
  fi
  if [ -n "${pid}" ]; then
    kill_pid_file "${pid_file}" "${CLOUDFLARED_BIN}" >/dev/null 2>&1 || true
  fi

  if [ ! -x "${CLOUDFLARED_BIN}" ]; then
    install_cloudflared_bin || return 1
  fi

  : >"${log}"
  chmod 600 "${log}"
  nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --protocol http2 \
    --url "http://127.0.0.1:${port}" >>"${log}" 2>&1 </dev/null &
  pid=$!
  write_pid_file "${pid_file}" "${pid}"
  # 订阅隧道只用于测试分发，域名出现在 cloudflared 日志即可；跳过 DoH
  # 发布核验，避免弱网/NAT DNS 与 Bash 子 shell wait 组合卡住。
  domain="$(SBM_ARGO_SKIP_DNS_VERIFY=1 wait_for_trycloudflare_domain_verified "${log}" 60 1 "${pid}" || true)"
  if [ -z "${domain}" ]; then
    kill_pid_file "${pid_file}" "${CLOUDFLARED_BIN}" >/dev/null 2>&1 || true
    print_err "订阅临时隧道启动失败，日志：${log}"
    return 1
  fi

  token="$(sub_token)"
  url="https://${domain}/${token}.txt"
  printf '%s\n' "${url}" >"$(sub_url_file)"
  chmod 600 "$(sub_url_file)"
  set_setting "sub_domain" "${domain}" || true
  set_setting "sub_url" "${url}" || true
  print_ok "订阅链接已生成：${url}"
  return 0
}

sub_start() {
  sub_build_file || return 1
  if [ "$(sub_mode)" = "worker" ]; then
    sub_report || return 1
    return 0
  fi
  sub_http_start || return 1
  sub_tunnel_start || return 1
  if [ -s "$(sub_url_file)" ]; then
    print_ok "订阅链接：$(cat "$(sub_url_file)")"
  fi
  return 0
}

sub_stop() {
  kill_pid_file "$(sub_tunnel_pid_file)" "${CLOUDFLARED_BIN}" >/dev/null 2>&1 || true
  kill_pid_file "$(sub_http_pid_file)" "" >/dev/null 2>&1 || true
  rm -f "$(sub_url_file)"
}

sub_url() {
  if [ "$(sub_mode)" = "worker" ]; then
    if [ ! -s "$(sub_url_file)" ]; then
      sub_start >/dev/null 2>&1 || {
        print_err "订阅链接生成失败。"
        return 1
      }
    fi
    cat "$(sub_url_file)"
    return 0
  fi
  if [ ! -s "$(sub_url_file)" ] || ! kill -0 "$(read_pid_file "$(sub_tunnel_pid_file)" 2>/dev/null || echo 0)" 2>/dev/null; then
    sub_start >/dev/null 2>&1 || {
      print_err "订阅链接启动失败。"
      return 1
    }
  fi
  cat "$(sub_url_file)"
}

sub_status() {
  local url
  url="$(cat "$(sub_url_file)" 2>/dev/null || true)"
  echo "订阅服务：$(sub_enabled && echo 已启用 || echo 未启用)"
  echo "订阅模式：$(sub_mode)"
  if [ "$(sub_mode)" = "worker" ]; then
    echo "Worker 域名：$(sub_worker_base 2>/dev/null || echo 未配置)"
    echo "订阅机器：$(sub_machine)"
    echo "订阅链接：${url:-未生成}"
    return 0
  fi
  echo "HTTP 端口：127.0.0.1:$(sub_local_port)"
  echo "HTTP 进程：$([ -n "$(read_pid_file "$(sub_http_pid_file)" 2>/dev/null || true)" ] && echo running || echo stopped)"
  echo "隧道进程：$([ -n "$(read_pid_file "$(sub_tunnel_pid_file)" 2>/dev/null || true)" ] && echo running || echo stopped)"
  echo "订阅链接：${url:-未生成}"
}

ensure_sub() {
  sub_enabled || return 0
  sub_build_file || print_warn "订阅内容生成失败（可能暂无节点）。"
  if [ "$(sub_mode)" = "worker" ]; then
    local hash
    hash="$(sub_content_hash "$(sub_file)" 2>/dev/null || true)"
    if [ ! -s "$(sub_url_file)" ] || [ "${hash}" != "$(get_setting "sub_hash" "")" ]; then
      sub_report || return 1
    fi
    return 0
  fi
  sub_http_start || return 1
  sub_tunnel_start || return 1
  return 0
}
