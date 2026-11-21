#!/usr/bin/env bash
set -eEuo pipefail

umask 077

ensure_dir_mode() {
  local dir="$1"
  local mode="$2"
  if install -d -m "$mode" "$dir" 2>/dev/null; then
    return 0
  fi
  mkdir -p "$dir"
  chmod "$mode" "$dir"
}

ensure_file_mode() {
  local file="$1"
  local mode="$2"
  local default_content="${3:-}"
  if [ ! -f "$file" ]; then
    printf '%s' "$default_content" >"$file"
  fi
  chmod "$mode" "$file"
}

init_storage() {
  ensure_dir_mode "${BASE_DIR}" 700
  ensure_dir_mode "${LIB_DIR}" 700
  ensure_dir_mode "${CERT_DIR}" 700
  ensure_dir_mode "${LOG_DIR}" 700
  ensure_dir_mode "${RUNTIME_DIR}" 700
  ensure_file_mode "${NODES_FILE}" 600 "{}"$'\n'
  ensure_file_mode "${SECRETS_FILE}" 600 "{}"$'\n'
  ensure_file_mode "${CONFIG_FILE}" 600 "{}"$'\n'
  ensure_file_mode "${SETTING_FILE}" 600 "{}"$'\n'
}

sanitize_permissions() {
  ensure_dir_mode "${BASE_DIR}" 700
  ensure_dir_mode "${LIB_DIR}" 700
  ensure_dir_mode "${CERT_DIR}" 700
  ensure_dir_mode "${LOG_DIR}" 700
  ensure_dir_mode "${RUNTIME_DIR}" 700

  [ -f "${NODES_FILE}" ] && chmod 600 "${NODES_FILE}"
  [ -f "${SECRETS_FILE}" ] && chmod 600 "${SECRETS_FILE}"
  [ -f "${CONFIG_FILE}" ] && chmod 600 "${CONFIG_FILE}"
  [ -f "${SETTING_FILE}" ] && chmod 600 "${SETTING_FILE}"

  find "${CERT_DIR}" -type f -name '*.key' -exec chmod 600 {} \; 2>/dev/null || true
  find "${CERT_DIR}" -type f -name '*.crt' -exec chmod 600 {} \; 2>/dev/null || true
  find "${RUNTIME_DIR}" -type f -exec chmod 600 {} \; 2>/dev/null || true
}

acquire_lock() {
  local start_time now
  init_storage

  if [ "${LOCK_HELD}" = true ]; then
    return 0
  fi

  start_time="$(date +%s)"
  if command_exists flock; then
    # A07：锁必须记归属者。命令替换/basename 等子 shell 会继承 LOCK_HELD=true，
    # 若它们也调用 release_lock，就会把父进程持有的锁提前释放（事务失去保护）。
    LOCK_OWNER_PID="${BASHPID}"
    exec {LOCK_FD}>"${LOCK_FILE}"
    while ! flock -n "${LOCK_FD}"; do
      now="$(date +%s)"
      if [ $((now - start_time)) -ge "${LOCK_TIMEOUT}" ]; then
        fatal "在 ${LOCK_TIMEOUT} 秒内无法获取锁。"
      fi
      sleep 1
    done
  else
    while ! mkdir "${LOCK_DIR_FALLBACK}" 2>/dev/null; do
      now="$(date +%s)"
      if [ $((now - start_time)) -ge "${LOCK_TIMEOUT}" ]; then
        fatal "在 ${LOCK_TIMEOUT} 秒内无法获取锁。"
      fi
      # 陈旧锁自愈：持有 mkdir 锁的进程死亡不会自动释放，
      # 锁目录年龄超过 4 倍超时即判定为残留并强制清除
      local lock_age
      lock_age="$(stat -c %Y "${LOCK_DIR_FALLBACK}" 2>/dev/null || printf 0)"
      now="$(date +%s)"
      if [ "$((now - lock_age))" -gt "$((LOCK_TIMEOUT * 4))" ]; then
        print_warn "检测到陈旧锁目录，强制清除：${LOCK_DIR_FALLBACK}"
        rm -rf "${LOCK_DIR_FALLBACK}"
        continue
      fi
      sleep 1
    done
  fi

  LOCK_OWNER_PID="${BASHPID}"
  LOCK_HELD=true
}

try_acquire_lock() {
  init_storage

  if [ "${LOCK_HELD}" = true ]; then
    return 0
  fi

  if command_exists flock; then
    exec {LOCK_FD}>"${LOCK_FILE}" || return 1
    if ! flock -n "${LOCK_FD}" 2>/dev/null; then
      eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
      LOCK_FD=""
      return 1
    fi
  else
    mkdir "${LOCK_DIR_FALLBACK}" 2>/dev/null || return 1
  fi

  LOCK_OWNER_PID="${BASHPID}"
  LOCK_HELD=true
  return 0
}

# A07：只有锁的持有进程才能释放锁；子 shell 继承的 LOCK_HELD 不得据此放锁。
lock_owned_by_self() {
  [ "${LOCK_HELD}" = true ] || return 1
  [ -z "${LOCK_OWNER_PID:-}" ] && return 0
  [ "${LOCK_OWNER_PID}" = "${BASHPID}" ]
}

release_lock() {
  if [ "${LOCK_HELD}" != true ]; then
    return 0
  fi
  if ! lock_owned_by_self; then
    return 0
  fi

  if command_exists flock && [ -n "${LOCK_FD}" ]; then
    flock -u "${LOCK_FD}" || true
    eval "exec ${LOCK_FD}>&-"
    LOCK_FD=""
  else
    rmdir "${LOCK_DIR_FALLBACK}" 2>/dev/null || true
  fi

  LOCK_HELD=false
  LOCK_OWNER_PID=""
}

json_update() {
  local file="$1"
  shift
  local tmp
  tmp="$(mktemp "${BASE_DIR}/.json.XXXXXX")"
  if ! jq "$@" "$file" >"${tmp}"; then
    rm -f "${tmp}"
    return 1
  fi
  if ! chmod 600 "${tmp}" || ! mv "${tmp}" "$file"; then
    rm -f "${tmp}"
    return 1
  fi
}

json_set_record() {
  local file="$1"
  local tag="$2"
  local json="$3"
  # shellcheck disable=SC2016
  json_update "$file" --arg tag "$tag" --argjson value "$json" '.[$tag] = $value'
  invalidate_port_caches_if_defined
}

json_delete_record() {
  local file="$1"
  local tag="$2"
  # shellcheck disable=SC2016
  json_update "$file" --arg tag "$tag" 'del(.[$tag])'
  invalidate_port_caches_if_defined
}

json_set_field() {
  local file="$1"
  local tag="$2"
  local field="$3"
  local value="$4"
  # shellcheck disable=SC2016
  json_update "$file" --arg tag "$tag" --arg field "$field" --arg value "$value" '.[$tag][$field] = $value'
  invalidate_port_caches_if_defined
}

invalidate_port_caches_if_defined() {
  if declare -F invalidate_port_caches >/dev/null 2>&1; then
    invalidate_port_caches
  fi
}

record_value() {
  local file="$1"
  local tag="$2"
  local field="$3"
  # tr -d '\r'：防御个别平台 jq 输出 CRLF 导致取值带 \r 无法匹配
  jq -r --arg tag "$tag" --arg field "$field" '.[$tag][$field] // empty' "$file" | tr -d '\r'
}

node_value() {
  record_value "${NODES_FILE}" "$1" "$2"
}

secret_value() {
  record_value "${SECRETS_FILE}" "$1" "$2"
}

iter_node_tags() {
  jq -r 'keys[]' "${NODES_FILE}" 2>/dev/null | tr -d '\r'
}

# 9.3：jq 批量化——一次启动输出全部节点 protocol/port/argo_mode（TSV，@tsv 转义 tab/换行）。
# 由调用方定读法（read -r tag protocol port mode），供 watchdog/argo 替代逐节点 node_value 多次 jq。
# 字段顺序与 node_value 语义一致：protocol / port / argo_mode。
node_meta_bulk() {
  if [ ! -f "${NODES_FILE}" ]; then
    return 0
  fi
  jq -r 'to_entries[] | [.key,
       (.value.protocol // ""),
       ((.value.port // "") | tostring),
       (.value.argo_mode // "")] | @tsv' "${NODES_FILE}" 2>/dev/null | tr -d '\r'
}

delete_node_records() {
  local tag="$1"
  json_delete_record "${NODES_FILE}" "$tag"
  json_delete_record "${SECRETS_FILE}" "$tag"
}

# A06：对账只在"能确定记录不存在"时删除。jq -e 在结果 false 与解析失败时都返回非 0，
# 旧实现把"状态文件损坏/读失败"当成"记录不存在"，会连带删掉有效节点或密钥。
# 这里显式分开三态：has=true 保留、has=false 删除、读失败只告警不删。
json_has_record() {
  local file="$1" tag="$2" out
  [ -f "${file}" ] || return 2
  out="$(jq -r --arg tag "${tag}" 'if type == "object" then (has($tag) | tostring) else "null" end' "${file}" 2>/dev/null)" || return 2
  case "${out}" in
  true) return 0 ;;
  false) return 1 ;;
  *) return 2 ;;
  esac
}

reconcile_state() {
  local tag rc
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    rc=0
    json_has_record "${SECRETS_FILE}" "${tag}" || rc=$?
    case "${rc}" in
    0) ;;
    1)
      print_warn "对账：节点 ${tag} 缺少密钥记录，已移除。"
      json_delete_record "${NODES_FILE}" "${tag}" || print_err "对账：移除 ${tag} 失败。"
      ;;
    *)
      print_warn "对账：密钥文件不可读或格式异常，已跳过本轮删除（避免误删节点 ${tag}）。"
      return 1
      ;;
    esac
  done < <(iter_node_tags)
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    rc=0
    json_has_record "${NODES_FILE}" "${tag}" || rc=$?
    case "${rc}" in
    0) ;;
    1)
      print_warn "对账：孤儿密钥 ${tag}，已移除。"
      json_delete_record "${SECRETS_FILE}" "${tag}" || print_err "对账：移除密钥 ${tag} 失败。"
      ;;
    *)
      print_warn "对账：节点文件不可读或格式异常，已跳过本轮删除（避免误删密钥 ${tag}）。"
      return 1
      ;;
    esac
  done < <(jq -r 'if type == "object" then keys[] else empty end' "${SECRETS_FILE}" 2>/dev/null | tr -d '\r')
  return 0
}

backup_state() {
  local backup_dir tmpdir f
  backup_dir="${BASE_DIR}/backups/$(date +%Y%m%d-%H%M%S)-$(printf '%04d' $((RANDOM % 10000)))-$$"
  ensure_dir_mode "${BASE_DIR}/backups" 700
  tmpdir="$(mktemp -d "${BASE_DIR}/backups/.staging.XXXXXX")" || return 1
  mkdir -p "${tmpdir}/certs" && chmod 700 "${tmpdir}/certs"

  for f in nodes.json secrets.json config.json settings.json; do
    [ -f "${BASE_DIR}/${f}" ] && cp "${BASE_DIR}/${f}" "${tmpdir}/${f}" && chmod 600 "${tmpdir}/${f}"
  done
  # 证书/私钥（仅当存在）一并纳入，恢复时可完整回滚
  if [ -d "${CERT_DIR}" ]; then
    find "${CERT_DIR}" -maxdepth 1 -type f \( -name '*.crt' -o -name '*.key' \) -exec cp {} "${tmpdir}/certs/" \; 2>/dev/null || true
  fi
  chmod 700 "${BASE_DIR}/backups" 2>/dev/null || true
  if ! mv "${tmpdir}" "${backup_dir}"; then
    rm -rf "${tmpdir}"
    return 1
  fi

  # P3：BusyBox 的 xargs 不支持 -r，空输入会执行 rm -rf（无参数误报）；显式判空。
  local old_backups
  old_backups="$(find "${BASE_DIR}/backups" -mindepth 1 -maxdepth 1 ! -name '.staging.*' -type d 2>/dev/null | sort -r | tail -n +11)"
  if [ -n "${old_backups}" ]; then
    printf '%s\n' "${old_backups}" | while IFS= read -r f; do
      [ -n "${f}" ] && rm -rf "${f}"
    done
  fi
  printf '%s' "${backup_dir}"
}

# A07：按指定快照回滚。事务失败时旧实现取"最新备份"，若期间有并发/多次备份，
# 恢复到的可能不是本次事务开始前的状态，等于回到别人的中间态。
restore_snapshot() {
  local latest="$1" f
  if [ -z "${latest}" ] || [ ! -d "${latest}" ]; then
    print_err "指定的状态快照不存在：${latest:-<空>}"
    return 1
  fi
  for f in nodes.json secrets.json config.json settings.json; do
    if [ -f "${latest}/${f}" ]; then
      cp "${latest}/${f}" "${BASE_DIR}/${f}" && chmod 600 "${BASE_DIR}/${f}" || return 1
    fi
  done
  # 一并恢复证书/私钥（若该快照含 certs/），使自签/自定义证书节点完整可回滚
  if [ -d "${latest}/certs" ]; then
    ensure_dir_mode "${CERT_DIR}" 700
    local cf
    for cf in "${latest}/certs/"*.crt "${latest}/certs/"*.key; do
      [ -f "${cf}" ] || continue
      if cp "${cf}" "${CERT_DIR}/" 2>/dev/null; then
        chmod 600 "${CERT_DIR}/$(basename "${cf}")" 2>/dev/null || true
      fi
    done
  fi
  print_ok "已从备份恢复：${latest}"
}

restore_latest_backup() {
  local latest
  latest="$(find "${BASE_DIR}/backups" -mindepth 1 -maxdepth 1 ! -name '.staging.*' -type d 2>/dev/null | sort | tail -n 1)"
  if [ -z "${latest}" ]; then
    print_err "没有可用的状态备份。"
    return 1
  fi
  restore_snapshot "${latest}"
}

rotate_log_file() {
  local file="$1"
  local size max_bytes idx

  [ -f "$file" ] || return 1
  size="$(wc -c <"$file" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$size" ] || return 1

  max_bytes=$((LOG_ROTATE_SIZE_MB * 1024 * 1024))
  if [ "$size" -lt "$max_bytes" ]; then
    return 1
  fi

  if [ "${LOG_ROTATE_BACKUPS}" -le 0 ]; then
    : >"$file" || return 1
    chmod 600 "$file" || return 1
    return 0
  fi

  rm -f "${file}.${LOG_ROTATE_BACKUPS}"

  if [ "${LOG_ROTATE_BACKUPS}" -gt 1 ]; then
    idx=$((LOG_ROTATE_BACKUPS - 1))
    while [ "$idx" -ge 1 ]; do
      if [ -f "${file}.${idx}" ]; then
        mv "${file}.${idx}" "${file}.$((idx + 1))" || return 1
      fi
      idx=$((idx - 1))
    done
  fi

  cp "$file" "${file}.1" || return 1
  : >"$file" || return 1
  chmod 600 "$file" "${file}.1" || return 1
  return 0
}
