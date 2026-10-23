#!/usr/bin/env bash
# SOURCE_ROOT 由 sbm_load_all 的 sbm_module_path 消费（跨文件引用），豁免 SC2034。
# shellcheck disable=SC2034
set -eEuo pipefail

umask 077

BASE_DIR="/usr/local/etc/singbox-manager"
LIB_DIR="/usr/local/lib/singbox-manager"
SINGBOX_BIN="/usr/local/bin/sing-box"
CLOUDFLARED_BIN="/usr/local/bin/cloudflared"
CONFIG_FILE="${BASE_DIR}/config.json"
RUNTIME_DIR="${BASE_DIR}/runtime"
LOG_DIR="${BASE_DIR}/logs"
SERVICE_NAME="singbox-manager"
PID_FILE="${RUNTIME_DIR}/sing-box.pid"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT=""
if [ -f "${SCRIPT_DIR}/../lib/env.sh" ]; then
  SOURCE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
  # shellcheck source=../lib/env.sh
  . "${SCRIPT_DIR}/../lib/env.sh"
elif [ -f "${LIB_DIR}/env.sh" ]; then
  # shellcheck source=/usr/local/lib/singbox-manager/env.sh
  . "${LIB_DIR}/env.sh"
else
  echo "未找到 env.sh。" >&2
  exit 1
fi

if ! sbm_load_all; then
  exit 1
fi

require_bash4
setup_common_traps

start_non_systemd_singbox() {
  if [ ! -x "${SINGBOX_BIN}" ] || [ ! -f "${CONFIG_FILE}" ]; then
    return 0
  fi

  if ! "${SINGBOX_BIN}" check -c "${CONFIG_FILE}" >/dev/null 2>&1; then
    print_warn "配置校验失败，已跳过 sing-box 重启。"
    return 0
  fi

  rotate_log_file "${LOG_DIR}/sing-box.log" || true
  local mem_limit
  mem_limit="$(go_mem_limit_value)"
  local env_prefix=()
  if [ -n "${mem_limit}" ]; then
    env_prefix+=(GOMEMLIMIT="${mem_limit}")
  fi
  # P5：GOGC=off 在 standalone（无 systemd/openrc）场景同样生效
  if go_gc_requested; then
    env_prefix+=(GOGC="off")
  fi
  if [ "${#env_prefix[@]}" -gt 0 ]; then
    nohup env "${env_prefix[@]}" "${SINGBOX_BIN}" run -c "${CONFIG_FILE}" >>"${LOG_DIR}/sing-box.log" 2>&1 </dev/null &
  else
    nohup "${SINGBOX_BIN}" run -c "${CONFIG_FILE}" >>"${LOG_DIR}/sing-box.log" 2>&1 </dev/null &
  fi
  write_pid_file "${PID_FILE}" "$!"
}

ensure_log_rotation() {
  rotate_log_file "${LOG_DIR}/sing-box.log" || true
  # cloudflared 节点日志同样按大小轮转，防止长期运行无上限增长
  local lf
  while IFS= read -r lf; do
    [ -n "${lf}" ] || continue
    rotate_log_file "${lf}" || true
  done < <(find "${LOG_DIR}" -type f -name '*.cloudflared.log' 2>/dev/null)
  # 1.1：cache.db 连接缓存超阈值直接清空（开心保活防膨胀；重建代价低）
  local cache_file cache_size
  cache_file="${RUNTIME_DIR}/cache.db"
  if [ -f "${cache_file}" ]; then
    cache_size="$(wc -c <"${cache_file}" 2>/dev/null | tr -d '[:space:]')"
    if [ -n "${cache_size}" ] && [ "${cache_size}" -gt $((LOG_ROTATE_SIZE_MB * 1024 * 1024)) ]; then
      rm -f "${cache_file}"
      print_warn "cache.db 超过 ${LOG_ROTATE_SIZE_MB}MB，已清空重建。"
    fi
  fi
}

# 5.2：数据面健康判定——TCP 任一可探活即健康；全 UDP / 混合部署在进程存活前提下
# 额外旁路 UDP(QUIC) 端口绑定探测（TCP 探活对 hy2/tuic 无意义）：
#   UDP 节点存在且全部未绑定 → 假活；status=2(全 UDP) 且绑定正常 → 健康。
singbox_healthy() {
  local status=0 udp_cnt
  # set -e 下用 || 捕获探活退出码，防止假死/不适用时提前退出
  singbox_probe_status || status=$?
  [ "${status}" = 0 ] && return 0
  udp_cnt="$(udp_node_count)"
  if [ "${udp_cnt}" -gt 0 ]; then
    if any_udp_port_bound; then
      return 0
    fi
    return 1
  fi
  [ "${status}" = 2 ] && return 0
  return 1
}

# P2：数据面探活失败计数与升级——按 SBM_PROBE_FAIL_LIMIT（默认 3）
# 允许达 N 次连续失败后才强制重启（失败计数在下一轮探活成功时清零）。
# 三态语义见 singbox_probe_status：0=健康、1=假死候选、2=不适用。
probe_fail_escalate() {
  local restart_cmd="$1"
  local probe_fail_file="${RUNTIME_DIR}/probe_fail_count"
  local probe_fail probe_fail_limit
  probe_fail_limit="${SBM_PROBE_FAIL_LIMIT:-3}"
  if [ -f "${probe_fail_file}" ]; then
    probe_fail="$(tr -dc '0-9' <"${probe_fail_file}" 2>/dev/null || true)"
  fi
  probe_fail="${probe_fail:-0}"
  probe_fail=$((probe_fail + 1))
  printf '%s' "${probe_fail}" >"${probe_fail_file}"
  chmod 600 "${probe_fail_file}"
  if [ "${probe_fail}" -lt "${probe_fail_limit}" ]; then
    print_warn "sing-box 数据面探活失败 ${probe_fail}/${probe_fail_limit} 次，暂不重启（避免瞬断误杀）。"
    return 0
  fi
  rm -f "${probe_fail_file}"
  print_warn "sing-box 连续 ${probe_fail} 次数据面探活失败，判定假死，强制重启。"
  # 1.2：重启前 dump 当前活动连接快照到运行时日志，辅助根因定位
  clash_api_dump_connections || true
  eval "${restart_cmd}"
}

ensure_singbox() {
  if [ ! -x "${SINGBOX_BIN}" ] || [ ! -f "${CONFIG_FILE}" ]; then
    return 0
  fi

  local pid

  if systemd_available; then
    if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
      systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || true
      return 0
    fi
    if singbox_healthy; then
      rm -f "${RUNTIME_DIR}/probe_fail_count"
      return 0
    fi
    probe_fail_escalate "systemctl restart ${SERVICE_NAME} >/dev/null 2>&1 || true"
    return 0
  fi

  if openrc_available; then
    if rc-service "${SERVICE_NAME}" status >/dev/null 2>&1; then
      if singbox_healthy; then
        rm -f "${RUNTIME_DIR}/probe_fail_count"
        return 0
      fi
      probe_fail_escalate "rc-service ${SERVICE_NAME} restart >/dev/null 2>&1 || rc-service ${SERVICE_NAME} start >/dev/null 2>&1 || true"
      return 0
    fi
    kill_pid_file "${PID_FILE}" "${SINGBOX_BIN}"
    rc-service "${SERVICE_NAME}" restart >/dev/null 2>&1 || rc-service "${SERVICE_NAME}" start >/dev/null 2>&1 || true
    return 0
  fi

  pid="$(read_pid_file "${PID_FILE}" 2>/dev/null || true)"
  # 存活且（/proc 可用时）确为 sing-box 实例才认为健康，防止 PID 复用导致漏重启
  if [ -n "${pid}" ] && pid_matches_binary_or_alive "${pid}" "${SINGBOX_BIN}"; then
    # S1：进程存活但数据传输面无响应时视为假死候选，按失败计数升级重启；
    # 全 UDP 部署由 singbox_healthy 的端口绑定旁路判定。
    if singbox_healthy; then
      rm -f "${RUNTIME_DIR}/probe_fail_count"
      return 0
    fi
    probe_fail_escalate "rm -f \"${PID_FILE}\"; start_non_systemd_singbox"
    return 0
  fi

  rm -f "${PID_FILE}"
  start_non_systemd_singbox
}

start_temp_tunnel() {
  local tag="$1"
  local local_port pid_file log_file domain edge_ip tmp_pid
  local_port="$(node_value "$tag" "port")"
  pid_file="${RUNTIME_DIR}/${tag}.pid"
  log_file="${LOG_DIR}/${tag}.cloudflared.log"

  : >"${log_file}"
  chmod 600 "${log_file}"
  # 截断（非追加）启动：日志只含本次进程内容，避免 parse_trycloudflare_domain
  # 从上一轮已死的 cloudflared 进程残留中误取旧域名（stale domain）。
  # 与 sb.sh start_argo_node 的 `: >` 语义一致。
  # 启动前清空旧域名：隧道失败时分享链接不再显示失效地址。
  # 用非阻塞 try_acquire_lock：watchdog 场景外层已释放锁，拿不到锁时
  # 跳过本轮写（与 watchdog 兜底语义一致），绝不在此阻塞占用 watch 周期。
  if ! try_acquire_lock; then
    print_warn "无法获取锁，跳过 ${tag} 的临时 Argo 域名清理。"
    return 1
  fi
  json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "" 2>/dev/null || true
  release_lock
  edge_ip="$(argo_edge_ip_version)"
  # --protocol http2：压掉 QUIC 内存尖峰；追加模式写入（O_APPEND）避免轮转后稀疏文件
  nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --protocol http2 --edge-ip-version "${edge_ip}" --url "http://127.0.0.1:${local_port}" \
    >>"${log_file}" 2>&1 </dev/null &
  tmp_pid=$!
  write_pid_file "${pid_file}" "${tmp_pid}"

  # 域名需通过公共 DNS 发布确认（DoH）才写入节点，防止"看似成功实则不可解析"；
  # 传入 pid：进程假死/提前退出时快速失败，不等满 60s 超时
  if domain="$(wait_for_trycloudflare_domain_verified "${log_file}" 60 1 "${tmp_pid}")"; then
    try_acquire_lock || {
      kill_pid_file "${pid_file}" "${CLOUDFLARED_BIN}"
      print_warn "写入 ${tag} 的临时 Argo 域名时无法获取锁，已保留隧道待下轮确认。"
      return 1
    }
    if jq -e --arg tag "$tag" 'has($tag)' "${NODES_FILE}" >/dev/null 2>&1; then
      if ! json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "${domain}"; then
        kill_pid_file "${pid_file}" "${CLOUDFLARED_BIN}"
        print_warn "写入 ${tag} 的临时 Argo 域名失败。"
      fi
    else
      kill_pid_file "${pid_file}" "${CLOUDFLARED_BIN}"
    fi
    release_lock
  else
    kill_pid_file "${pid_file}" "${CLOUDFLARED_BIN}"
    try_acquire_lock || {
      print_warn "等待 ${tag} 的临时 Argo 域名超时，且无法获取锁清除旧域名。"
      return 1
    }
    json_set_field "${NODES_FILE}" "${tag}" "endpoint_domain" "" 2>/dev/null || true
    release_lock
    print_warn "等待 ${tag} 的临时 Argo 域名超时（含 DNS 发布确认），已清除旧域名。"
  fi
}

start_token_tunnel() {
  local tag="$1"
  local token pid_file log_file edge_ip
  token="$(secret_value "$tag" "argo_token")"
  if [ -z "${token}" ]; then
    print_warn "节点 ${tag} 的 Argo Token 为空，已跳过启动。"
    return 0
  fi
  pid_file="${RUNTIME_DIR}/${tag}.pid"
  log_file="${LOG_DIR}/${tag}.cloudflared.log"

  : >"${log_file}"
  chmod 600 "${log_file}"
  edge_ip="$(argo_edge_ip_version)"
  # token 经环境变量传入，避免明文出现在进程命令行（ps 可见）
  TUNNEL_TOKEN="${token}" nohup "${CLOUDFLARED_BIN}" tunnel --no-autoupdate --protocol http2 --edge-ip-version "${edge_ip}" run \
    >>"${log_file}" 2>&1 </dev/null &
  write_pid_file "${pid_file}" "$!"
}

ensure_argo_nodes() {
  local tag protocol mode pid_file pid
  local restarts last_restart now backoff restart_at_file
  [ -f "${NODES_FILE}" ] || return 0
  [ -x "${CLOUDFLARED_BIN}" ] || return 0

  # 9.3：jq 批量化——一次 bulk 拿到全部 (tag, protocol, argo_mode)，替代逐 tag node_value
  # node_meta_bulk 输出 4 列(key/protocol/port/argo_mode)：port 用占位列吸收，
  # 否则 mode 拿到的仍是 port，token 节点会被当临时隧道重启（F-09）
  while IFS=$'\t' read -r tag protocol _port mode; do
    [ -n "${tag}" ] || continue
    [ "${protocol}" = "vless-argo" ] || continue

    pid_file="${RUNTIME_DIR}/${tag}.pid"
    pid="$(read_pid_file "${pid_file}" 2>/dev/null || true)"
    # 存活且（/proc 可用时）确为 cloudflared 实例才跳过重启，防止 PID 复用漏拉起
    if [ -n "${pid}" ] && pid_matches_binary_or_alive "${pid}" "${CLOUDFLARED_BIN}"; then
      # 5.4：token 固定隧道做健康探活（endpoint_domain:443）；临时隧道不探（域名属云端分配）
      if [ "${mode}" = "token" ]; then
        if probe_token_tunnel "${tag}"; then
          reset_restart_count "${tag}"
        fi
      else
        # 隧道长时间稳定运行：清零崩溃计数，避免旧失败影响后续退避
        reset_restart_count "${tag}"
      fi
      continue
    fi

    # S2：崩溃退避——按 2^(n-1) 秒退避（封顶 30min），防止崩溃循环秒级重启风暴
    restarts="$(read_restart_count "$tag")"
    if [ "${restarts}" -gt 0 ]; then
      backoff="$(argo_backoff_delay "${restarts}")"
      restart_at_file="${RUNTIME_DIR}/${tag}.restart_at"
      if [ -f "${restart_at_file}" ]; then
        last_restart="$(tr -dc '0-9' <"${restart_at_file}" 2>/dev/null | head -c 12 || true)"
        last_restart="${last_restart:-0}"
        now="$(date +%s 2>/dev/null || echo 0)"
        if [ -n "${now}" ] && [ $((now - last_restart)) -lt "${backoff}" ]; then
          print_warn "节点 ${tag} 处于退避窗口（第 ${restarts} 次崩溃，${backoff}s 内不再重启）。"
          continue
        fi
      fi
    fi

    rm -f "${pid_file}"
    if [ "${mode}" = "token" ]; then
      if start_token_tunnel "${tag}"; then
        bump_restart_count "${tag}"
        date +%s >"${RUNTIME_DIR}/${tag}.restart_at" 2>/dev/null || true
      fi
    else
      release_lock
      if start_temp_tunnel "${tag}"; then
        # 临时隧道启动即记录，成功与否由下轮域名核验/进程存活清空计数
        bump_restart_count "${tag}"
        date +%s >"${RUNTIME_DIR}/${tag}.restart_at" 2>/dev/null || true
      fi
      try_acquire_lock || true
    fi
  done < <(node_meta_bulk)
}

# 5.4：token 固定隧道的健康探活——endpoint_domain:443 连不上且连续
# SBM_TUNNEL_PROBE_LIMIT（默认 2）轮失败即 kill 进程，交由退避重启路径拉起。
probe_token_tunnel() {
  local tag="$1"
  local domain fail_file fails
  domain="$(node_value "$tag" "endpoint_domain")"
  [ -n "${domain}" ] || return 0
  if probe_tcp_port "${domain}" 443 3; then
    rm -f "${RUNTIME_DIR}/${tag}.tunnel_probe_fail"
    return 0
  fi
  fail_file="${RUNTIME_DIR}/${tag}.tunnel_probe_fail"
  fails="$(tr -dc '0-9' <"${fail_file}" 2>/dev/null || true)"
  fails="${fails:-0}"
  fails=$((fails + 1))
  printf '%s' "${fails}" >"${fail_file}"
  chmod 600 "${fail_file}" 2>/dev/null || true
  if [ "${fails}" -ge "${SBM_TUNNEL_PROBE_LIMIT:-2}" ]; then
    print_warn "token 隧道 ${tag} 连续 ${fails} 轮探活失败（${domain}:443 不可达），判定假活，准备退避重启。"
    rm -f "${fail_file}"
    kill_pid_file "${RUNTIME_DIR}/${tag}.pid" "${CLOUDFLARED_BIN}"
    return 1
  fi
  print_warn "token 隧道 ${tag} 第 ${fails}/${SBM_TUNNEL_PROBE_LIMIT:-2} 轮探活失败（${domain}:443 不可达）。"
  return 0
}

# 5.5：minimal metrics——每轮 watchdog 追加一行 jsonl（探活三态，秒级时间戳），
# 供运维排障回溯探活失败窗口；超过 5MB 裁为 backups 仅留最近一份。
write_metrics_line() {
  local ts probe=0 sz
  ts="$(date +%s 2>/dev/null || printf 0)"
  # F1：set -e 下必须用 || 捕获探活退出码，否则探活失败（1/2）时整行被吞，指标永不落盘
  singbox_probe_status || probe=$?
  printf '{"ts":%s,"probe":%s}\n' "${ts}" "${probe}" >>"${RUNTIME_DIR}/metrics.jsonl" 2>/dev/null || true
  sz="$(wc -c <"${RUNTIME_DIR}/metrics.jsonl" 2>/dev/null | tr -d '[:space:]' || printf 0)"
  if [ -n "${sz}" ] && [ "${sz}" -gt 5242880 ]; then
    mv "${RUNTIME_DIR}/metrics.jsonl" "${RUNTIME_DIR}/metrics.jsonl.1" 2>/dev/null || true
  fi
}

require_root
require_bash4
init_storage
sanitize_permissions
# 拿不到锁说明另一实例正在工作：静默跳过本轮，不报错
if ! try_acquire_lock; then
  exit 0
fi
ensure_log_rotation
reconcile_state || true
ensure_singbox
reapply_net_tune_qdisc || true
ensure_argo_nodes
ensure_sub || true
write_metrics_line
sanitize_permissions
release_lock
