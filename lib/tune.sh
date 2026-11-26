#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

# 统一调优标准（2026-11-26）：
#   - 内存 <256MB：TCP 缓冲 16MB；>=256MB：32MB
#   - tcp_mem 按内存推导：low=1/4 max、pressure=1/2 max、max=RAM/4，上限 128MB
#   - tcp_wmem/tcp_rmem 默认 256KB，上限跟随内存档位
#   - fq quantum=18028 / initial_quantum=90140
#   - 不做测速/延迟推断/带宽档位：参数可重复、无网络依赖
NET_TUNE_FQ_QUANTUM="${NET_TUNE_FQ_QUANTUM:-18028}"
NET_TUNE_FQ_INITIAL_QUANTUM="${NET_TUNE_FQ_INITIAL_QUANTUM:-90140}"
NET_TUNE_TCP_LIMIT_OUTPUT_BYTES="${NET_TUNE_TCP_LIMIT_OUTPUT_BYTES:-4194304}"
NET_TUNE_SYSCTL_FILE="${NET_TUNE_SYSCTL_FILE:-/etc/sysctl.d/99-singbox-manager-net-tune.conf}"
NET_TUNE_BUFFER_SMALL_MB=16
NET_TUNE_BUFFER_LARGE_MB=32
NET_TUNE_BUFFER_THRESHOLD_KB=262144
NET_TUNE_SOCKET_DEFAULT_BYTES=262144
NET_TUNE_TCP_MEM_MAX_CAP_BYTES=134217728

go_gc_requested() {
  [ "$(manager_env_or_setting "go_gc")" = "off" ] && return 0
  return 1
}

net_tune_requested() {
  case "$(manager_env_or_setting "net_tune")" in
  0 | off | no) return 1 ;;
  *) return 0 ;;
  esac
}

net_tune_number() {
  local key="$1"
  local default="$2"
  local value
  value="$(manager_env_or_setting "${key}" "")"
  if [[ "${value}" =~ ^[0-9]+$ ]] && [ "${value}" -gt 0 ]; then
    printf '%s' "${value}"
  else
    printf '%s' "${default}"
  fi
}

net_tune_mem_kb() {
  local value="${NET_TUNE_MEM_KB:-}"
  if [[ "${value}" =~ ^[0-9]+$ ]] && [ "${value}" -gt 0 ]; then
    printf '%s' "${value}"
    return 0
  fi
  awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || printf '0'
}

net_tune_buffer_mb() {
  local value mem_kb
  value="$(manager_env_or_setting "net_tune_buffer_mb" "")"
  if [[ "${value}" =~ ^[0-9]+$ ]] && [ "${value}" -gt 0 ]; then
    printf '%s' "${value}"
    return 0
  fi
  mem_kb="$(net_tune_mem_kb)"
  if [[ "${mem_kb}" =~ ^[0-9]+$ ]] && [ "${mem_kb}" -lt "${NET_TUNE_BUFFER_THRESHOLD_KB}" ]; then
    printf '%s' "${NET_TUNE_BUFFER_SMALL_MB}"
  else
    printf '%s' "${NET_TUNE_BUFFER_LARGE_MB}"
  fi
}

# tcp_mem 使用「页」为单位，返回 low pressure max。
net_tune_tcp_mem_pages() {
  local mem_kb page_size pages max_pages cap_pages floor_pages low pressure
  mem_kb="$(net_tune_mem_kb)"
  [[ "${mem_kb}" =~ ^[0-9]+$ ]] && [ "${mem_kb}" -gt 0 ] || mem_kb=262144
  page_size="$(getconf PAGESIZE 2>/dev/null || printf '4096')"
  [[ "${page_size}" =~ ^[0-9]+$ ]] && [ "${page_size}" -gt 0 ] || page_size=4096
  pages=$((mem_kb * 1024 / page_size))
  [ "${pages}" -gt 0 ] || pages=262144
  max_pages=$((pages / 4))
  cap_pages=$((NET_TUNE_TCP_MEM_MAX_CAP_BYTES / page_size))
  floor_pages=$((16 * 1024 * 1024 / page_size))
  [ "${max_pages}" -gt "${cap_pages}" ] && max_pages="${cap_pages}"
  [ "${max_pages}" -lt "${floor_pages}" ] && max_pages="${floor_pages}"
  low=$((max_pages / 4))
  pressure=$((max_pages / 2))
  [ "${low}" -lt 1 ] && low=1
  [ "${pressure}" -le "${low}" ] && pressure=$((low + 1))
  printf '%s %s %s' "${low}" "${pressure}" "${max_pages}"
}

net_tune_values() {
  local buffer_mb
  NET_TUNE_FQ_QUANTUM="$(net_tune_number "net_tune_fq_quantum" "${NET_TUNE_FQ_QUANTUM}")"
  NET_TUNE_FQ_INITIAL_QUANTUM="$(net_tune_number "net_tune_fq_initial_quantum" "${NET_TUNE_FQ_INITIAL_QUANTUM}")"
  buffer_mb="$(net_tune_buffer_mb)"
  NET_TUNE_BUFFER_MB="${buffer_mb}"
  NET_TUNE_TCP_RMEM_MAX=$((buffer_mb * 1024 * 1024))
  NET_TUNE_TCP_WMEM_MAX=$((buffer_mb * 1024 * 1024))
  NET_TUNE_TCP_MEM="$(net_tune_tcp_mem_pages)"
  NET_TUNE_TCP_LIMIT_OUTPUT_BYTES="$(net_tune_number "net_tune_tcp_limit_output_bytes" "${NET_TUNE_TCP_LIMIT_OUTPUT_BYTES}")"
}

# 默认路由网卡；IPv4 无默认路由时回退 IPv6（IPv6-only 机器同样能调 fq）。
net_tune_default_iface() {
  local iface=""
  command_exists ip || return 1
  iface="$(ip route show default 2>/dev/null | awk 'NR==1 {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
  if [ -z "${iface}" ]; then
    iface="$(ip -6 route show default 2>/dev/null | awk 'NR==1 {for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
  fi
  [ -n "${iface}" ] || return 1
  printf '%s' "${iface}"
}

net_tune_mtu() {
  local value
  value="$(manager_env_or_setting "net_tune_mtu" "")"
  if [[ "${value}" =~ ^[0-9]+$ ]] && [ "${value}" -ge 576 ] && [ "${value}" -le 9000 ]; then
    printf '%s' "${value}"
  fi
}

ensure_bbr_module() {
  local available=""
  available="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
  if ! printf '%s' "${available}" | grep -qw bbr; then
    if command_exists modprobe; then
      modprobe tcp_bbr 2>/dev/null || true
    fi
  fi
  if command_exists modprobe; then
    modprobe sch_fq 2>/dev/null || true
  fi
  if [ -d /etc/modules-load.d ]; then
    printf 'tcp_bbr\n' >"/etc/modules-load.d/tcp_bbr.conf" 2>/dev/null || true
    printf 'sch_fq\n' >"/etc/modules-load.d/sch_fq.conf" 2>/dev/null || true
  fi
}

write_net_tune_sysctl_file() {
  local tmp
  tmp="$(mktemp "${NET_TUNE_SYSCTL_FILE}.XXXXXX" 2>/dev/null)" || tmp="$(mktemp 2>/dev/null)" || return 1
  {
    echo "# singbox-manager net_tune：统一标准（内存档位 + tcp_mem + 连接参数），开机自动加载"
    echo "net.ipv4.tcp_congestion_control=bbr"
    # 容器/精简内核可能根本没有 default_qdisc 节点，写进去会在 sysctl -p 时报错
    [ -e /proc/sys/net/core/default_qdisc ] && echo "net.core.default_qdisc=fq"
    # BUG-09：只调 tcp_wmem/tcp_rmem 的上限无效——内核同时受 core.wmem_max/rmem_max
    # 约束，二者不放开时 socket 缓冲区仍被钳在默认 208KB。
    echo "net.core.wmem_max=${NET_TUNE_TCP_WMEM_MAX}"
    echo "net.core.rmem_max=${NET_TUNE_TCP_RMEM_MAX}"
    echo "net.core.wmem_default=${NET_TUNE_SOCKET_DEFAULT_BYTES}"
    echo "net.core.rmem_default=${NET_TUNE_SOCKET_DEFAULT_BYTES}"
    echo "net.ipv4.tcp_wmem=4096 ${NET_TUNE_SOCKET_DEFAULT_BYTES} ${NET_TUNE_TCP_WMEM_MAX}"
    echo "net.ipv4.tcp_rmem=4096 ${NET_TUNE_SOCKET_DEFAULT_BYTES} ${NET_TUNE_TCP_RMEM_MAX}"
    echo "net.ipv4.tcp_mem=${NET_TUNE_TCP_MEM}"
    echo "net.ipv4.tcp_limit_output_bytes=${NET_TUNE_TCP_LIMIT_OUTPUT_BYTES}"
    echo "net.core.netdev_max_backlog=8192"
    echo "net.core.somaxconn=4096"
    echo "net.ipv4.tcp_max_syn_backlog=8192"
    echo "net.ipv4.tcp_fastopen=3"
    echo "net.ipv4.tcp_mtu_probing=1"
    echo "net.ipv4.tcp_tw_reuse=1"
    echo "net.ipv4.ip_local_port_range=10000 65535"
    echo "net.ipv4.tcp_slow_start_after_idle=0"
  } >"${tmp}" 2>/dev/null || {
    rm -f "${tmp}"
    return 1
  }
  chmod 0644 "${tmp}" 2>/dev/null || true
  if ! mv -f "${tmp}" "${NET_TUNE_SYSCTL_FILE}"; then
    rm -f "${tmp}"
    return 1
  fi
  # 清掉旧版额外调优文件，避免 98- 与 99- 两套参数互相覆盖
  rm -f /etc/sysctl.d/98-singbox-manager-net-tune-extra.conf 2>/dev/null || true
  return 0
}

apply_sysctls() {
  local ok=true err=""
  local -a keys=(
    net.core.wmem_max "${NET_TUNE_TCP_WMEM_MAX}"
    net.core.rmem_max "${NET_TUNE_TCP_RMEM_MAX}"
    net.core.wmem_default "${NET_TUNE_SOCKET_DEFAULT_BYTES}"
    net.core.rmem_default "${NET_TUNE_SOCKET_DEFAULT_BYTES}"
    net.ipv4.tcp_congestion_control bbr
    net.ipv4.tcp_wmem "4096 ${NET_TUNE_SOCKET_DEFAULT_BYTES} ${NET_TUNE_TCP_WMEM_MAX}"
    net.ipv4.tcp_rmem "4096 ${NET_TUNE_SOCKET_DEFAULT_BYTES} ${NET_TUNE_TCP_RMEM_MAX}"
    net.ipv4.tcp_mem "${NET_TUNE_TCP_MEM}"
    net.ipv4.tcp_limit_output_bytes "${NET_TUNE_TCP_LIMIT_OUTPUT_BYTES}"
    net.core.netdev_max_backlog 8192
    net.core.somaxconn 4096
    net.ipv4.tcp_max_syn_backlog 8192
    net.ipv4.tcp_fastopen 3
    net.ipv4.tcp_mtu_probing 1
    net.ipv4.tcp_tw_reuse 1
    net.ipv4.ip_local_port_range "10000 65535"
    net.ipv4.tcp_slow_start_after_idle 0
  )
  # default_qdisc 只在节点存在时才是有效键（Docker/LXC 常见缺失）
  if [ -e /proc/sys/net/core/default_qdisc ]; then
    keys+=(net.core.default_qdisc fq)
  fi

  local i k v
  for ((i = 0; i < ${#keys[@]}; i += 2)); do
    k="${keys[i]}"
    v="${keys[i + 1]}"
    if ! sysctl -w "${k}=${v}" >/dev/null 2>&1; then
      # 键不存在（精简内核）无害；键存在但写入被拒才记录失败
      if [ -n "$(sysctl -n "${k}" 2>/dev/null)" ]; then
        ok=false
        err="${err}${k} "
      fi
    fi
  done

  if [ "$(id -u 2>/dev/null || echo 1)" = "0" ] && [ -d /etc/sysctl.d ]; then
    write_net_tune_sysctl_file || print_warn "写入 ${NET_TUNE_SYSCTL_FILE} 失败（重启后参数可能不保留）。"
  fi

  if [ "${ok}" = "true" ]; then
    print_ok "已应用统一网络调优：BBR + fq + TCP 缓冲 ${NET_TUNE_BUFFER_MB}MB（rmem_max=${NET_TUNE_TCP_RMEM_MAX} wmem_max=${NET_TUNE_TCP_WMEM_MAX} tcp_mem=${NET_TUNE_TCP_MEM}）。"
  else
    print_warn "部分 sysctl 写入失败：${err}（容器/精简内核可能限制网络参数，其余项已生效）。"
  fi
}

# 参考 jyucoeng bbr.sh：把根 qdisc 换成带 quantum 的 fq，显著提升单流吞吐。
# 容器 veth 的 noqueue 无法替换，直接跳过（不影响 BBR/sysctl）。
apply_fq_qdisc() {
  local iface qdisc
  iface="$(net_tune_default_iface)" || {
    print_warn "无法检测默认网卡，跳过 fq qdisc 设置。"
    return 0
  }
  if ! command_exists tc; then
    print_warn "缺少 tc 命令，跳过 fq qdisc 设置（可安装 iproute2）。"
    return 0
  fi
  qdisc="$(tc qdisc show dev "${iface}" 2>/dev/null || true)"
  case "${qdisc}" in
  *noqueue*)
    print_info "网卡 ${iface} 使用 noqueue（容器虚拟网卡），跳过 fq qdisc；sysctl 优化不受影响。"
    return 0
    ;;
  *"qdisc fq "*)
    if [[ "${qdisc}" == *"quantum ${NET_TUNE_FQ_QUANTUM}"* ]] &&
      [[ "${qdisc}" == *"initial_quantum ${NET_TUNE_FQ_INITIAL_QUANTUM}"* ]]; then
      print_ok "fq qdisc 已生效：${iface} quantum=${NET_TUNE_FQ_QUANTUM} initial_quantum=${NET_TUNE_FQ_INITIAL_QUANTUM}。"
      return 0
    fi
    ;;
  esac

  if tc qdisc replace dev "${iface}" root fq quantum "${NET_TUNE_FQ_QUANTUM}" \
    initial_quantum "${NET_TUNE_FQ_INITIAL_QUANTUM}" >/dev/null 2>&1; then
    print_ok "已在 ${iface} 应用 fq qdisc：quantum=${NET_TUNE_FQ_QUANTUM} initial_quantum=${NET_TUNE_FQ_INITIAL_QUANTUM}。"
  else
    print_warn "在 ${iface} 应用 fq qdisc 失败（内核可能缺少 sch_fq），BBR/sysctl 已独立生效。"
  fi
}

apply_net_tune_mtu() {
  local mtu iface current
  mtu="$(net_tune_mtu)"
  [ -n "${mtu}" ] || return 0
  iface="$(net_tune_default_iface)" || return 0
  command_exists ip || return 0
  current="$(ip link show dev "${iface}" 2>/dev/null | grep -o 'mtu [0-9]*' | head -n 1 | awk '{print $2}' || true)"
  [ -n "${current}" ] || return 0
  [ "${current}" = "${mtu}" ] && return 0
  if ip link set dev "${iface}" mtu "${mtu}" >/dev/null 2>&1; then
    print_ok "网卡 ${iface} MTU：${current} → ${mtu}（显式 net_tune_mtu 配置）。"
  else
    print_warn "设置 ${iface} MTU=${mtu} 失败（当前 ${current}），已跳过。"
  fi
}

apply_network_tune() {
  net_tune_requested || return 0
  [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || return 0
  command_exists sysctl || return 0
  # 冒烟测试环境不执行真实 sysctl/tc（免副作用）
  if [ "${SBM_TEST_MODE:-0}" = "1" ]; then
    return 0
  fi

  net_tune_values
  ensure_bbr_module
  apply_sysctls
  apply_fq_qdisc
  apply_net_tune_mtu
  _NET_TUNE_APPLIED=1
  return 0
}

# watchdog 每轮补齐 fq qdisc（重启后内核会退回 fq_codel/pfifo_fast），
# 已生效时不产生任何输出，避免每分钟刷日志。
reapply_net_tune_qdisc() {
  net_tune_requested || return 0
  [ "$(id -u 2>/dev/null || echo 1)" = "0" ] || return 0
  [ "${SBM_TEST_MODE:-0}" = "1" ] && return 0
  command_exists tc || return 0
  net_tune_values
  local iface qdisc
  iface="$(net_tune_default_iface)" || return 0
  qdisc="$(tc qdisc show dev "${iface}" 2>/dev/null || true)"
  case "${qdisc}" in
  *noqueue*) return 0 ;;
  *"quantum ${NET_TUNE_FQ_QUANTUM}"*"initial_quantum ${NET_TUNE_FQ_INITIAL_QUANTUM}"*) return 0 ;;
  esac
  tc qdisc replace dev "${iface}" root fq quantum "${NET_TUNE_FQ_QUANTUM}" \
    initial_quantum "${NET_TUNE_FQ_INITIAL_QUANTUM}" >/dev/null 2>&1 || true
  return 0
}

net_tune_status() {
  local iface
  iface="$(net_tune_default_iface 2>/dev/null || true)"
  echo "------------------ BBR / TCP ------------------"
  sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc \
    net.core.rmem_max net.core.wmem_max net.core.rmem_default net.core.wmem_default \
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_mem \
    net.ipv4.tcp_limit_output_bytes net.ipv4.tcp_slow_start_after_idle \
    net.ipv4.tcp_fastopen net.ipv4.tcp_mtu_probing net.core.somaxconn \
    net.core.netdev_max_backlog 2>/dev/null || echo "(部分内核项不可用)"
  echo "------------------ fq qdisc -------------------"
  if [ -n "${iface}" ] && command_exists tc; then
    echo "网卡: ${iface}"
    tc qdisc show dev "${iface}" 2>/dev/null || echo "(无法读取)"
  else
    echo "(无 tc / 无法检测默认网卡)"
  fi
}

net_tune_display_values() {
  local iface mtu qdisc
  iface="$(net_tune_default_iface 2>/dev/null || printf '未检测到')"
  mtu="$(net_tune_mtu)"
  qdisc=""
  if [ -n "${iface}" ] && [ "${iface}" != "未检测到" ] && command_exists tc; then
    qdisc="$(tc qdisc show dev "${iface}" 2>/dev/null | head -n 1 || true)"
  fi
  printf '参数：fq quantum %s / initial_quantum %s；TCP 缓冲 %sMB；tcp_mem %s；limit_output %s 字节\n' \
    "$(hl_num "${NET_TUNE_FQ_QUANTUM}")" "$(hl_num "${NET_TUNE_FQ_INITIAL_QUANTUM}")" \
    "$(hl_num "${NET_TUNE_BUFFER_MB}")" "${NET_TUNE_TCP_MEM}" \
    "$(hl_num "${NET_TUNE_TCP_LIMIT_OUTPUT_BYTES}")"
  printf '网卡：%s | MTU：%s | qdisc：%s\n' \
    "${iface}" "${mtu:-保持系统默认}" "${qdisc:-不可用}"
}

net_tune_menu() {
  local choice
  while true; do
    net_tune_values
    print_header
    echo "BBR+FQ+统一网络调优（内存档位，无测速）"
    echo
    net_tune_display_values
    echo
    echo "1. 重新应用 BBR+FQ+TCP 缓冲"
    echo "2. 查看当前生效参数"
    echo "0. 返回"
    echo
    read -r -p "请选择: " choice || return 0
    case "${choice}" in
    1)
      apply_network_tune
      pause_menu
      ;;
    2)
      echo
      net_tune_status
      echo
      pause_menu
      ;;
    0) return 0 ;;
    *)
      print_warn "无效的选择。"
      sleep 1
      ;;
    esac
  done
}
