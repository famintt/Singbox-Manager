#!/usr/bin/env bash
set -eEuo pipefail

umask 077

wipe_records() {
  local tmp
  tmp="$(mktemp "${BASE_DIR}/.nodes.XXXXXX")"
  printf '{}\n' >"${tmp}" && chmod 600 "${tmp}" && mv "${tmp}" "${NODES_FILE}"
  tmp="$(mktemp "${BASE_DIR}/.secrets.XXXXXX")"
  printf '{}\n' >"${tmp}" && chmod 600 "${tmp}" && mv "${tmp}" "${SECRETS_FILE}"
  invalidate_port_caches
}

delete_all_nodes() {
  local tag cert_file key_file
  init_storage
  acquire_lock
  backup_state >/dev/null
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    stop_argo_node "${tag}"
    cert_file="$(node_value "${tag}" "certificate_path")"
    key_file="$(node_value "${tag}" "key_path")"
    remove_node_certificates "${tag}" "${cert_file}" "${key_file}"
  done < <(iter_node_tags)
  wipe_records
  render_config
  reload_service
  sanitize_permissions
  release_lock
  print_ok "已删除全部节点（含证书）并重启服务。"
}

print_node_list() {
  local idx=1
  local tag protocol name port public_ip link
  if [ -n "$(manager_env_or_setting "direct_host" "")" ] || [ -n "$(manager_env_or_setting "server_ip" "")" ]; then
    public_ip=""
  else
    public_ip="$(get_public_ip)"
  fi
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    protocol="$(node_value "$tag" "protocol")"
    name="$(node_value "$tag" "name")"
    port="$(node_value "$tag" "port")"
    link="$(build_share_link "$tag" "$public_ip")"
    # 名称一行、链接单独一行（链接顶格且前后留空行），方便终端里双击/三击
    # 整行复制；不再把"链接: "前缀和 URL 混在同一行。
    echo "${idx}. ${name} | ${protocol} | 端口: ${port}"
    echo "   标识: ${tag}"
    if [ -n "${link}" ]; then
      printf '%s\n\n' "${link}"
    else
      echo "   （链接暂不可用：Argo 隧道可能尚未分配域名，稍后重试 sbm list）"
      echo
    fi
    idx=$((idx + 1))
  done < <(iter_node_tags)

  if [ "${idx}" -eq 1 ]; then
    echo "当前没有节点。"
  fi
}

sub_command() {
  local out_file="${1:-}"
  local links="" tag content public_ip
  init_storage
  if [ -n "$(manager_env_or_setting "direct_host" "")" ] || [ -n "$(manager_env_or_setting "server_ip" "")" ]; then
    public_ip=""
  else
    public_ip="$(get_public_ip)"
  fi
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    links+="$(build_share_link "${tag}" "$public_ip")"$'\n'
  done < <(iter_node_tags)
  if [ -z "${links//[$'\n']/}" ]; then
    print_err "当前没有可输出的节点。"
    return 1
  fi
  content="$(printf '%s' "${links}" | base64 | tr -d '\n')"
  if [ -n "${out_file}" ]; then
    printf '%s\n' "${content}" >"${out_file}"
    chmod 600 "${out_file}" 2>/dev/null || true
    print_ok "订阅已写入：${out_file}（节点数：$(printf '%s' "${links}" | grep -c .)）"
  else
    printf '%s\n' "${content}"
  fi
}

select_node_tag() {
  local -a rows
  local idx input tag protocol name port
  mapfile -t rows < <(jq -r 'to_entries[] | [.key, .value.protocol, .value.name, (.value.port|tostring)] | @tsv' "${NODES_FILE}" 2>/dev/null)
  [ "${#rows[@]}" -gt 0 ] || return 1

  idx=1
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r tag protocol name port <<<"${row}"
    printf '%s\n' "${idx}. ${name} | ${protocol} | 端口: ${port}" >&2
    idx=$((idx + 1))
  done

  read -r -p "请选择节点编号: " input || return 1
  if ! [[ "${input}" =~ ^[0-9]+$ ]] || [ "${input}" -lt 1 ] || [ "${input}" -gt "${#rows[@]}" ]; then
    return 1
  fi

  IFS=$'\t' read -r tag _ <<<"${rows[$((input - 1))]}"
  printf '%s' "${tag}"
}

list_nodes() {
  init_storage
  echo
  print_node_list
  echo
}

delete_node() {
  local tag protocol cert_file key_file
  init_storage
  tag="$(select_node_tag)" || {
    print_warn "没有可选节点，或输入的编号无效。"
    return 0
  }

  protocol="$(node_value "$tag" "protocol")"
  if ! confirm_yes "确认删除节点 ${tag} 吗？"; then
    return 0
  fi

  acquire_lock
  cert_file="$(node_value "$tag" "certificate_path")"
  key_file="$(node_value "$tag" "key_path")"
  if [ "${protocol}" = "vless-argo" ]; then
    stop_argo_node "$tag"
  fi
  delete_node_records "$tag"
  remove_node_certificates "$tag" "$cert_file" "$key_file"
  invalidate_port_caches
  render_config || true
  reload_service || true
  sanitize_permissions
  release_lock
  print_ok "已删除节点：${tag}"
}

show_status() {
  local count installed_version
  init_storage
  count="$(jq 'length' "${NODES_FILE}" 2>/dev/null || printf '0')"
  installed_version="${SINGBOX_VERSION#v}"
  if [ -x "${SINGBOX_BIN}" ]; then
    installed_version="$("${SINGBOX_BIN}" version 2>/dev/null | head -n 1 | awk '{print $NF}')"
    installed_version="${installed_version#v}"
    installed_version="${installed_version:-${SINGBOX_VERSION#v}}"
  fi
  echo
  echo "项目名称：${PROJECT_NAME}"
  echo "当前版本：${SCRIPT_VERSION}"
  echo "服务状态：$(service_state)"
  echo "节点数量：${count}"
  if systemd_available; then
    if systemd_timer_active; then
      echo "守护定时器：active (下次触发已调度)"
    else
      echo "守护定时器：inactive (未调度)"
    fi
  elif openrc_available; then
    echo "守护方式：OpenRC + cron"
  else
    echo "守护方式：cron"
  fi
  echo "sing-box 版本：${installed_version}"
  echo "cloudflared 版本：$(cloudflared_installed_version)"
  # 1.2：可观测面处于开态时展示实时连接汇总（本地 127.0.0.1 的 clash_api）
  if clash_api_enabled; then
    local _conns
    if _conns="$(clash_api_conn_summary 2>/dev/null || true)"; then
      echo "实时连接：${_conns}"
    else
      echo "实时连接：不可用（sing-box 未跑或实验面未启用）"
    fi
  fi
  echo
  print_node_list
  echo
}

restart_stack() {
  acquire_lock
  render_config
  start_service
  restart_all_argo_nodes
  sanitize_permissions
  release_lock
}
