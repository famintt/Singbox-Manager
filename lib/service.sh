#!/usr/bin/env bash
# openrc 模板内的 PID_FILE 为模板变量（定义于 sb.sh），按要求豁免 SC2153。
# shellcheck disable=SC2153
set -eEuo pipefail

umask 077

read_restart_count() {
  local tag="$1"
  local file="${RUNTIME_DIR}/${tag}.restart_count"
  [ -f "${file}" ] || {
    printf '0'
    return 0
  }
  tr -dc '0-9' <"${file}" 2>/dev/null | grep -E '^[0-9]+$' || printf '0'
}

bump_restart_count() {
  local tag="$1"
  local file="${RUNTIME_DIR}/${tag}.restart_count"
  local current
  current="$(read_restart_count "$tag")"
  printf '%s' "$((current + 1))" >"${file}.tmp" && chmod 600 "${file}.tmp" && mv "${file}.tmp" "${file}"
}

reset_restart_count() {
  local tag="$1"
  rm -f "${RUNTIME_DIR}/${tag}.restart_count"
}

write_pid_file() {
  local pid_file="$1"
  local pid="$2"
  printf '%s\n' "$pid" >"$pid_file"
  chmod 600 "$pid_file"
}

read_pid_file() {
  local pid_file="$1"
  local content
  [ -f "$pid_file" ] || return 1
  content="$(tr -d ' \r\n' <"$pid_file")"
  # PID 文件只接受纯数字，拒绝负数、特殊值与被污染的内容
  [[ "${content}" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "${content}"
}

pid_matches_binary() {
  local pid="$1"
  local binary="$2"
  [ -n "${pid}" ] && [ -n "${binary}" ] || return 1
  local exe=""
  exe="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
  [ -n "${exe}" ] || return 1
  [ "${exe}" = "${binary}" ] || [ "${exe}" = "${binary} (deleted)" ]
}

pid_matches_binary_or_alive() {
  local pid="$1"
  local binary="$2"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  if [ ! -d /proc ]; then
    return 0
  fi
  pid_matches_binary "${pid}" "${binary}"
}

kill_pid_file() {
  local pid_file="$1"
  local expect="${2:-}"
  local pid
  pid="$(read_pid_file "${pid_file}" 2>/dev/null || true)"
  rm -f "${pid_file}"
  [ -n "${pid}" ] || return 0

  # 提供预期二进制时先做身份校验（需 /proc，root 下可用）
  if [ -n "${expect}" ] && [ -d /proc ] && ! pid_matches_binary "${pid}" "${expect}"; then
    if kill -0 "${pid}" 2>/dev/null; then
      print_warn "PID ${pid} 已不属于 ${expect}（疑似 PID 复用），跳过终止。"
    fi
    return 0
  fi

  kill "${pid}" >/dev/null 2>&1 || return 0
  # TERM 后等待退出，最多 5 秒，仍存活则 KILL
  for _ in 1 2 3 4 5; do
    kill -0 "${pid}" 2>/dev/null || return 0
    sleep 1
  done
  kill -9 "${pid}" >/dev/null 2>&1 || true
  return 0
}

compute_go_mem_limit_mb() {
  local pct="${SBM_GOMEM_LIMIT_PCT:-45}"
  local floor_mb="${SBM_GOMEM_FLOOR_MB:-32}"
  local total_kb limit_mb v

  total_kb="$(awk '/^(MemTotal|MemTotal:)/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  [ -n "${total_kb}" ] || total_kb=0

  local f
  for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.high; do
    [ -r "${f}" ] || continue
    v="$(tr -d ' \r\n' <"${f}" 2>/dev/null || true)"
    [ -n "${v}" ] || continue
    [ "${v}" = "max" ] && continue
    [[ "${v}" =~ ^[0-9]+$ ]] || continue
    [ "${v}" -le 0 ] && continue
    if [ "${total_kb}" -le 0 ] || [ "$((v / 1024))" -lt "${total_kb}" ]; then
      total_kb=$((v / 1024))
    fi
  done

  if [ "${total_kb}" -le 0 ]; then
    return 1
  fi

  limit_mb=$((total_kb * 1024 * pct / 100 / 1024 / 1024))
  if [ "${limit_mb}" -lt "${floor_mb}" ]; then
    limit_mb="${floor_mb}"
  fi
  printf '%s' "${limit_mb}"
}

go_mem_limit_value() {
  local mb
  mb="$(compute_go_mem_limit_mb 2>/dev/null || true)"
  [ -n "${mb}" ] || return 0
  printf '%sMiB' "${mb}"
}

systemd_available() {
  command_exists systemctl && [ -d /run/systemd/system ]
}

openrc_available() {
  command_exists rc-service && [ -x /sbin/openrc-run ]
}

systemd_timer_active() {
  local line
  line="$(systemctl list-timers --all --no-legend "${WATCHDOG_TIMER_NAME}" 2>/dev/null | head -n 1 || true)"
  [ -n "${line}" ] || return 1
  [[ "${line}" == n/a* ]] && return 1
  return 0
}

create_systemd_units() {
  local mem_line=""
  local mem_limit gogc_line memory_high_line memory_max_line nofile_line
  local mem_high mem_max
  mem_limit="$(go_mem_limit_value)"
  if [ -n "${mem_limit}" ]; then
    mem_line="Environment=GOMEMLIMIT=${mem_limit}"
  fi
  # P5：GOGC=off 彻底关闭逃逸堆目标（可选）；MemoryHigh/MemoryMax 软硬内存上限（可选）
  gogc_line=""
  if go_gc_requested; then
    gogc_line="Environment=GOGC=off"
  fi
  mem_high="$(manager_env_or_setting "mem_high_mb")"
  mem_max="$(manager_env_or_setting "mem_max_mb")"
  memory_high_line=""
  memory_max_line=""
  if [ -n "${mem_high}" ] && [[ "${mem_high}" =~ ^[0-9]+$ ]] && [ "${mem_high}" -gt 0 ]; then
    memory_high_line="MemoryHigh=${mem_high}M"
  fi
  if [ -n "${mem_max}" ] && [[ "${mem_max}" =~ ^[0-9]+$ ]] && [ "${mem_max}" -gt 0 ]; then
    memory_max_line="MemoryMax=${mem_max}M"
  fi
  # P2：放宽文件描述符上限，适配高连接数
  nofile_line="LimitNOFILE=1048576"

  cat >"${SYSTEMD_SERVICE_FILE}" <<EOF
[Unit]
Description=Singbox Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${BASE_DIR}
ExecStartPre=/bin/mkdir -p ${BASE_DIR}/logs ${RUNTIME_DIR}
ExecStartPre=${SINGBOX_BIN} check -c ${CONFIG_FILE}
${mem_line}
${gogc_line}
${memory_high_line}
${memory_max_line}
${nofile_line}
ExecStart=${SINGBOX_BIN} run -c ${CONFIG_FILE}
Restart=on-failure
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectProc=invisible
ProcSubset=pid
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
# 5.1：纵深加固——系统调用白名单裁剪 + EPERM 静默 + 能力边界只留网络授权；
#   地址族收窄（AF_NETLINK 为 auto_detect_interface 路由探测所需保留）
SystemCallFilter=@system-service
SystemCallFilter=~@chown
SystemCallFilter=~@privileged
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
OOMPolicy=kill
OOMScoreAdjust=-100
RestartSteps=10
RestartSec=3
MemorySwapMax=0
ReadWritePaths=${BASE_DIR} ${LIB_DIR}

[Install]
WantedBy=multi-user.target
EOF

  cat >"${SYSTEMD_WATCHDOG_SERVICE_FILE}" <<EOF
[Unit]
Description=Singbox Manager Watchdog
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG_TARGET}
KillMode=process
UMask=0077
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectControlGroups=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectProc=invisible
ProcSubset=pid
ReadWritePaths=${BASE_DIR} ${LIB_DIR}
EOF

  cat >"${SYSTEMD_WATCHDOG_TIMER_FILE}" <<EOF
[Unit]
Description=Run Singbox Manager Watchdog Every Minute

# C1：开机首检 90s→30s（端口探活并行后单轮足够快，提前拉起可缩短故障窗口）
[Timer]
OnBootSec=30
OnUnitActiveSec=60
Unit=${WATCHDOG_SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl enable --now "${WATCHDOG_TIMER_NAME}" >/dev/null 2>&1 || true
}

create_openrc_units() {
  local mem_line gogc_line
  local mem_limit
  mem_line=""
  gogc_line=""
  mem_limit="$(go_mem_limit_value)"
  if [ -n "${mem_limit}" ]; then
    mem_line="export GOMEMLIMIT=${mem_limit}"
  fi
  if go_gc_requested; then
    gogc_line="export GOGC=off"
  fi

  cat >"${OPENRC_SERVICE_FILE}" <<EOF
#!/sbin/openrc-run

name="${SERVICE_NAME}"
description="Singbox Manager"
command="${SINGBOX_BIN}"
command_args="run -c ${CONFIG_FILE}"
command_background=true
pidfile="${PID_FILE}"

depend() {
  need net
}

start_pre() {
  mkdir -p ${BASE_DIR}/logs ${RUNTIME_DIR}
  ${SINGBOX_BIN} check -c ${CONFIG_FILE} >/dev/null
  ${mem_line}
  ${gogc_line}
}
EOF

  chmod 0755 "${OPENRC_SERVICE_FILE}"
  rc-update add "${SERVICE_NAME}" default >/dev/null 2>&1 || true

  if command_exists rc-service && [ -x /etc/init.d/crond ]; then
    rc-update add crond default >/dev/null 2>&1 || true
    rc-service crond start >/dev/null 2>&1 || true
  fi
}

create_cron_watchdog() {
  if ! command_exists crontab; then
    print_warn "未找到 crontab，已跳过 watchdog 的 cron 创建。"
    return 0
  fi

  (
    crontab -l 2>/dev/null | grep -Fv "${WATCHDOG_TARGET}" | grep -Fv "no crontab for" || true
    echo "* * * * * ${WATCHDOG_TARGET} >/dev/null 2>&1"
  ) | crontab -
}

service_state() {
  if systemd_available; then
    if systemctl is-active --quiet "${SERVICE_NAME}"; then
      printf '运行中'
    else
      printf '已停止'
    fi
    return 0
  fi

  if openrc_available; then
    if rc-service "${SERVICE_NAME}" status >/dev/null 2>&1; then
      printf '运行中'
    else
      printf '已停止'
    fi
    return 0
  fi

  local pid
  pid="$(read_pid_file "${PID_FILE}" 2>/dev/null || true)"
  # 存活且确为 sing-box 实例才显示运行中，防止 PID 复用导致误报
  if [ -n "${pid}" ] && pid_matches_binary_or_alive "${pid}" "${SINGBOX_BIN}"; then
    printf '运行中'
  else
    printf '已停止'
  fi
}

socks5_whitelist_cleanup() {
  local chain="SBM_SOCKS5_WL" ipt nums n
  command_exists iptables || return 0
  for ipt in iptables ip6tables; do
    command_exists "${ipt}" || continue
    # 按行号删除 INPUT 中跳转到本链的规则；规则包含 --dport 等参数时
    # 不能用 "-D INPUT -j chain" 精确匹配，否则旧规则会残留。
    nums="$("${ipt}" -L INPUT --line-numbers -n 2>/dev/null | awk -v c="${chain}" '$2 == c {print $1}' | sort -rn)"
    for n in ${nums}; do
      "${ipt}" -D INPUT "${n}" >/dev/null 2>&1 || true
    done
    "${ipt}" -F "${chain}" >/dev/null 2>&1 || true
    "${ipt}" -X "${chain}" >/dev/null 2>&1 || true
  done
}

# 仅用 iptables 做源地址白名单；没有 iptables 的环境只告警，不影响节点本身。
socks5_whitelist_apply() {
  local enabled ips ip port tag proto chain="SBM_SOCKS5_WL" ipt
  enabled="$(manager_env_or_setting "socks5_wl_flag" "")"
  case "${enabled,,}" in
  true | 1 | yes | on) ;;
  *) socks5_whitelist_cleanup; return 0 ;;
  esac
  if ! command_exists iptables; then
    print_warn "socks5 白名单需要 iptables，当前系统不可用，未应用。"
    return 0
  fi
  ips="$(manager_env_or_setting "socks5_ips" "")"
  if [ -z "${ips}" ]; then
    print_warn "socks5_wl_flag 已开启但 socks5_ips 为空，未应用白名单。"
    socks5_whitelist_cleanup
    return 0
  fi
  socks5_whitelist_cleanup
  for ipt in iptables ip6tables; do
    command_exists "${ipt}" || continue
    "${ipt}" -N "${chain}" >/dev/null 2>&1 || true
    "${ipt}" -F "${chain}" >/dev/null 2>&1 || true
    for ip in ${ips//,/ }; do
      [ -n "${ip}" ] || continue
      "${ipt}" -A "${chain}" -s "${ip}" -j ACCEPT >/dev/null 2>&1 || true
    done
    "${ipt}" -A "${chain}" -j DROP >/dev/null 2>&1 || true
  done
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    proto="$(node_value "${tag}" "protocol")"
    [ "${proto}" = "socks5" ] || continue
    port="$(node_value "${tag}" "port")"
    [[ "${port}" =~ ^[0-9]+$ ]] || continue
    for ipt in iptables ip6tables; do
      command_exists "${ipt}" || continue
      "${ipt}" -I INPUT -p tcp --dport "${port}" -m comment --comment "sbm_socks5_wl" -j "${chain}" >/dev/null 2>&1 || true
    done
  done < <(iter_node_tags)
}

stop_service() {
  local log_file="${BASE_DIR}/logs/sing-box.log" reason_file="${BASE_DIR}/logs/stop_reason.log"
  if [ -s "${log_file}" ]; then
    tail -n 50 "${log_file}" >"${reason_file}" 2>/dev/null || true
    chmod 600 "${reason_file}" 2>/dev/null || true
  fi
  socks5_whitelist_cleanup || true
  if systemd_available; then
    systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true
  elif openrc_available; then
    rc-service "${SERVICE_NAME}" stop >/dev/null 2>&1 || true
    kill_pid_file "${PID_FILE}" "${SINGBOX_BIN}"
  else
    kill_pid_file "${PID_FILE}" "${SINGBOX_BIN}"
  fi
}

ensure_low_memory_guard() {
  local total_kb avail_mb low_mb
  low_mb="${SBM_LOW_MEM_MB:-200}"
  total_kb="$(awk '/^(MemTotal|MemTotal:)/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)"
  [ -n "${total_kb}" ] || return 0
  avail_mb=$((total_kb / 1024))
  if [ "${avail_mb}" -lt "${low_mb}" ]; then
    print_warn "检测到低内存环境（约 ${avail_mb}MB < ${low_mb}MB）：已为 sing-box/cloudflared 设置 GOMEMLIMIT 软上限并强制 cloudflared http2 模式。"
    print_warn "建议少开协议节点、避免同时开启多个 Argo 节点；隧道进程内存尖峰靠 Go 软上限抑制。"
  fi
}

# P1：返回正在运行的 sing-box 实例 PID（systemd 取 MainPID，其余读 PID_FILE），
# 未运行或 PID 非法时返回 1。不做二进制身份校验，交由调用方决定是否可信。
running_singbox_pid() {
  local pid
  if systemd_available; then
    pid="$(systemctl show -p MainPID --value "${SERVICE_NAME}" 2>/dev/null || true)"
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s' "${pid}"
    return 0
  fi
  pid="$(read_pid_file "${PID_FILE}" 2>/dev/null || true)"
  [ -n "${pid}" ] || return 1
  printf '%s' "${pid}"
  return 0
}

# P1：配置重载。sing-box 官方不支持 SIGHUP 热重载（Issue #284，2022-12 至今未实现），
# 仅注册 SIGINT/SIGTERM；未忽略的 SIGHUP 默认直接终止进程，nohup 启动时又会被置为
# SIG_IGN 而静默无效。因此统一为"校验通过 → stop + start（systemd 即 restart，秒级）"：
#   - 配置校验失败 → fail-closed，拒绝重载并返回 1（保留运行中的旧配置）；
#   - 服务未运行 → 直接完整启动。
#   就绪自检（P3）在非测试环境于重启后执行，端口未监听时给出明确报错。
reload_service() {
  if ! "${SINGBOX_BIN}" check -c "${CONFIG_FILE}" >/dev/null 2>&1; then
    print_err "配置校验失败，已拒绝重载（保留现有运行配置）。"
    return 1
  fi
  if [ -n "$(running_singbox_pid 2>/dev/null || true)" ]; then
    print_info "配置校验通过，重启 sing-box 以应用新配置（不支持 SIGHUP 热重载，走 stop+start）。"
  else
    print_info "服务未运行，直接启动。"
  fi
  stop_service
  start_service
  if [ "${SBM_TEST_MODE:-0}" != "1" ]; then
    verify_data_plane_ready || true
  fi
  return 0
}

# P3：等待一组 TCP 端口可探活（就绪自检核心，SBM_READINESS_RETRIES 次重试，
# 每次探活 1s 超时、间隔 1s）。UDP 节点不在此列（见 verify_data_plane_ready）。
await_tcp_ports() {
  local host="$1" ports="$2" tries="${3:-${SBM_READINESS_RETRIES:-3}}"
  local attempt port all_ok
  [ -n "${ports}" ] || return 0
  [[ "${tries}" =~ ^[1-9][0-9]*$ ]] || tries=3
  for ((attempt = 1; attempt <= tries; attempt++)); do
    all_ok=1
    for port in ${ports}; do
      [[ "${port}" =~ ^[0-9]+$ ]] || continue
      if ! probe_tcp_port "${host}" "${port}" 1; then
        all_ok=0
        break
      fi
    done
    [ "${all_ok}" = 1 ] && return 0
    sleep 1
  done
  return 1
}

# P3：数据面就绪自检——render/start/reload 后逐个探活 TCP 类入站端口，
# 未监听时明确报出端口（端口冲突/绑定失败定位）；纯 UDP（hy2/tuic）节点
# 与全 UDP 部署跳过（TCP 探活不适用，进程存活由 watchdog 保证）。
verify_data_plane_ready() {
  # 全节点仅需 protocol/port 两字段：用 node_meta_bulk 一次 jq 拿到（9.3 jq 批量化）
  # 字段顺序同 node_value：protocol / port；node_meta_bulk 输出 4 列，argo_mode 用占位列吸收（F-09）
  local tag protocol port _argo ports="" tcp_count
  [ -f "${NODES_FILE}" ] || return 0
  while IFS=$'\t' read -r tag protocol port _argo; do
    [ -n "${tag}" ] || continue
    case "${protocol}" in
    vless-reality | vless-ws-tls | anytls | vless-argo | socks5)
      ports="${ports} ${port}"
      ;;
    esac
  done < <(node_meta_bulk)
  tcp_count="$(tcp_probeable_node_count)"
  if [ "${tcp_count}" -eq 0 ]; then
    print_info "当前无 TCP 类入站节点（均为 UDP 或空），跳过端口就绪探活。"
    return 0
  fi
  ports="${ports# }"
  if await_tcp_ports "127.0.0.1" "${ports}" 3; then
    print_ok "数据面就绪：${tcp_count} 个 TCP 入站端口可探测。"
    return 0
  fi
  print_err "数据面就绪自检失败：TCP 入站端口未监听或存在冲突。端口：${ports}"
  print_err "可用 ss -ltnup 检查占用情况；确认冲突后调整节点端口并重新应用。"
  return 1
}

start_service() {
  [ -x "${SINGBOX_BIN}" ] || fatal "尚未安装 sing-box。"
  rotate_log_file "${BASE_DIR}/logs/sing-box.log" || true
  "${SINGBOX_BIN}" check -c "${CONFIG_FILE}" >/dev/null
  warn_if_bindv6only

  local mem_limit
  mem_limit="$(go_mem_limit_value)"

  if systemd_available; then
    systemctl daemon-reload
    systemctl restart "${SERVICE_NAME}" >/dev/null 2>&1 || systemctl start "${SERVICE_NAME}" >/dev/null 2>&1
    systemctl enable --now "${WATCHDOG_TIMER_NAME}" >/dev/null 2>&1 || true
  elif openrc_available; then
    stop_service
    rc-service "${SERVICE_NAME}" restart >/dev/null 2>&1 || rc-service "${SERVICE_NAME}" start >/dev/null 2>&1
  else
    stop_service
    local env_prefix=()
    if [ -n "${mem_limit}" ]; then
      env_prefix+=(GOMEMLIMIT="${mem_limit}")
    fi
    # P5：可选 GOGC=off（彻底关闭逃逸堆目标，适合希望避免频繁 GC 的场景）
    if go_gc_requested; then
      env_prefix+=(GOGC="off")
    fi
    if [ "${#env_prefix[@]}" -gt 0 ]; then
      nohup env "${env_prefix[@]}" "${SINGBOX_BIN}" run -c "${CONFIG_FILE}" >>"${BASE_DIR}/logs/sing-box.log" 2>&1 </dev/null &
    else
      nohup "${SINGBOX_BIN}" run -c "${CONFIG_FILE}" >>"${BASE_DIR}/logs/sing-box.log" 2>&1 </dev/null &
    fi
    write_pid_file "${PID_FILE}" "$!"
  fi

  socks5_whitelist_apply || true
  print_ok "服务状态：$(service_state)"
}

ensure_singbox_ready() {
  init_storage
  if [ ! -x "${SINGBOX_BIN}" ]; then
    print_info "检测到 sing-box 尚未安装，开始自动安装。"
    install_core
  fi
  # F-05：systemd unit 缺失时补建（历史上 install 若中途失败/被清理会留下无 unit 状态，
  # rep/restart/update 等后续流程单独 start 即失败；这里幂等重建，存在则覆盖为同内容）。
  if systemd_available && [ ! -f "${SYSTEMD_SERVICE_FILE}" ]; then
    print_info "systemd unit 缺失，重建服务单元。"
    create_systemd_units
  fi
  # F-06：OpenRC init 脚本缺失时同样补建。与 F-05 对称：当 sing-box/cloudflared
  # 已预置（如二进制旁路安装/install_core 未走）时，ensure_singbox_ready 不会触发
  # install_core，而 create_openrc_units 只在 install_core 里调用——缺失的
  # /etc/init.d/singbox-manager 会让 start_service 的 rc-service restart 报
  # "service does not exist" 令 rep/ins 整体回滚（Alpine/OpenRC 实测阻断）。
  if openrc_available && [ ! -f "${OPENRC_SERVICE_FILE}" ]; then
    print_info "OpenRC init 脚本缺失，重建服务单元。"
    create_openrc_units
    create_cron_watchdog
  fi
}
