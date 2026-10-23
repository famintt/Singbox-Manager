#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 9.5：多源探测响应归一化——裸 IP 直接返回，否则优先 grep IPv4/IPv6，再尝试 JSON 字段。
# 兼容 icanhazip/ipify(裸 IP)、ifconfig.me/ip(裸 IP)、4.ipw.cn(裸 IP)、
# ip.3322.net(文本)、cip.cc(HTML 文本)、myip.ipip.net(文本"当前 IP：…")。
extract_public_ip() {
  local raw="$1" m ip
  [ -n "${raw}" ] || return 1
  # L5：仅去除 CR/LF（多行响应）并裁剪首尾空白，保留内部空白分隔符——
  # 原先 tr -d ' ' 会把空格分隔的多个 IP（如 "1.2.3.4 5.6.7.8"）拼接成
  # "1.2.3.45.6.7.8" 这类非法地址，随后被 grep 截段误取成错误 IP。
  raw="$(printf '%s' "${raw}" | tr -d '\r\n' | sed -e 's/^[[:space:]]\{1,\}//' -e 's/[[:space:]]\{1,\}$//')"
  if [ -n "${raw}" ] && is_ip_address "${raw}"; then
    printf '%s' "${raw}"
    return 0
  fi
  if command_exists grep; then
    m="$(printf '%s' "${raw}" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|(([0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{0,4})' | grep -vE '^(0\.0\.0\.0|::|0::|::0|127\.)' | head -1 2>/dev/null || true)"
    if [ -n "${m}" ] && is_ip_address "${m}"; then
      printf '%s' "${m}"
      return 0
    fi
  fi
  ip="$(printf '%s' "${raw}" | jq -r '.ip // .IpAddr // .ipaddr // .address // .data // empty' 2>/dev/null | tr -d '\r\n' || true)"
  if [ -n "${ip}" ] && is_ip_address "${ip}" && ! is_private_ip "${ip}"; then
    printf '%s' "${ip}"
    return 0
  fi
  return 1
}

get_public_ip() {
  local ip ipver flag url _pid meta_ip
  local cached cached_ts now ttl cached_ver

  if [ -n "${PUBLIC_IP_CACHE}" ]; then
    printf '%s' "${PUBLIC_IP_CACHE}"
    return 0
  fi

  # 分享链接默认使用 IPv4；全局设置 ip_version 可选 auto(=v4 优先) / 4 / 6
  ipver="$(get_setting "ip_version" "4")"
  case "${ipver,,}" in
  6 | v6) ipver="6" ;;
  *) ipver="4" ;;
  esac

  # 持久化缓存：settings.json 的 public_ip/public_ip_ts 在 TTL 内且 ip 版本匹配时直接复用，
  # 避免 sbm list/sub/show_status 每次启动都外呼公网探测服务（SBM_IP_CACHE_TTL 秒，默认 600）。
  ttl="${SBM_IP_CACHE_TTL:-600}"
  cached="$(get_setting "public_ip")"
  cached_ts="$(get_setting "public_ip_ts")"
  cached_ver="$(get_setting "public_ip_version")"
  now="$(date +%s 2>/dev/null || printf 0)"
  if [ -n "${cached}" ] && is_ip_address "${cached}" && ! is_private_ip "${cached}" &&
    { [ -z "${cached_ver}" ] || [ "${cached_ver}" = "${ipver}" ]; } &&
    { [ "${now}" -eq 0 ] || { [[ "${cached_ts}" =~ ^[0-9]+$ ]] && [ $((now - cached_ts)) -lt "${ttl}" ]; }; }; then
    PUBLIC_IP_CACHE="${cached}"
    printf '%s' "${PUBLIC_IP_CACHE}"
    return 0
  fi

  # GCP 等云厂商的公网 IP 常为 1:1 NAT，网卡上只有内网地址。
  # 优先从本机元数据读取，不需要外部探测，也不受临时出网故障影响。
  if command_exists curl; then
    meta_ip="$(curl -fsS --max-time 3 -H 'Metadata-Flavor: Google' \
      'http://169.254.169.254/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip' \
      2>/dev/null | tr -d '\r\n' || true)"
    if is_ip_address "${meta_ip}" && ! is_private_ip "${meta_ip}"; then
      PUBLIC_IP_CACHE="${meta_ip}"
      set_setting "public_ip" "${PUBLIC_IP_CACHE}" || true
      set_setting "public_ip_version" "4" || true
      set_setting "public_ip_ts" "$(date +%s 2>/dev/null || printf 0)" || true
      printf '%s' "${PUBLIC_IP_CACHE}"
      return 0
    fi
  fi

  local families=(4 6)
  if [ "${ipver}" = "6" ]; then
    families=(6 4)
  fi

  # A1/9.5：同族多源并行探测（SBM_IP_PROBE_PARALLEL=0 回退串行）。IPv4 含境内可达源
  # （4.ipw.cn / ip.3322.net / myip.ipip.net / cip.cc），首个合法公网 IP 即回，
  # 冷启动最坏耗时从 4×5s 降到 ≈5s（每 curl --max-time 5 为硬上限）。
  local -a probe_urls=()
  local probe_tmp rawip _u _i _f
  for ipver in "${families[@]}"; do
    if [ "${ipver}" = "4" ]; then
      flag="--ipv4"
      probe_urls=(
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://4.ipw.cn"
        "https://ip.3322.net"
        "https://ifconfig.me/ip"
        "https://myip.ipip.net"
        "https://cip.cc"
      )
    else
      flag="--ipv6"
      probe_urls=("https://api64.ipify.org" "https://ipv6.icanhazip.com" "https://ifconfig.me/ip")
    fi

    if [ "${SBM_IP_PROBE_PARALLEL:-1}" = "1" ] && [ "${#probe_urls[@]}" -gt 1 ]; then
      probe_tmp="$(mktemp -d "${BASE_DIR}/.ipprobe.XXXXXX" 2>/dev/null || true)"
      [ -n "${probe_tmp}" ] || probe_tmp="$(mktemp -d 2>/dev/null || true)"
      [ -n "${probe_tmp}" ] || probe_tmp="${TMPDIR:-/tmp}/ipprobe.$$"
      mkdir -p "${probe_tmp}"
      _i=0
      local -a probe_pids=()
      for _u in "${probe_urls[@]}"; do
        # 子 shell 继承 ERR trap：内部 curl|tr 管线在低可达源失败时会打出
        # "命令执行失败: node-cmd.sh:38" 红字噪音(8b77816 只兜了缓存写)。
        # 管线尾部补 || true,让失败静默收敛(本探测本就容忍部分源失败)。
        (curl -fsS --max-time 5 ${flag} "$_u" 2>/dev/null | tr -d '\r\n' || true) >"${probe_tmp}/${_i}" &
        probe_pids+=("$!")
        _i=$((_i + 1))
      done
      # 裸 wait 在部分 Bash 5.2/5.3 的命令替换子 shell 中会对继承的 job
      # 反复 ECHILD 空转；逐个等待自己启动的 PID。
      for _pid in "${probe_pids[@]}"; do
        wait "${_pid}" 2>/dev/null || true
      done
      for _f in "${probe_tmp}"/*; do
        [ -f "${_f}" ] || continue
        if rawip="$(extract_public_ip "$(tr -d '\r\n' <"${_f}" 2>/dev/null || true)")"; then
          rm -rf "${probe_tmp}"
          PUBLIC_IP_CACHE="${rawip}"
          set_setting "public_ip" "${rawip}" || true
          set_setting "public_ip_version" "${ipver}" || true
          set_setting "public_ip_ts" "$now" || true
          printf '%s' "${PUBLIC_IP_CACHE}"
          return 0
        fi
      done
      rm -rf "${probe_tmp}"
    else
      for url in "${probe_urls[@]}"; do
        if ip="$(extract_public_ip "$(curl -fsS --max-time 5 ${flag} "$url" 2>/dev/null | tr -d '\r\n' || true)")"; then
          PUBLIC_IP_CACHE="$ip"
          set_setting "public_ip" "$ip" || true
          set_setting "public_ip_version" "${ipver}" || true
          set_setting "public_ip_ts" "$now" || true
          printf '%s' "${PUBLIC_IP_CACHE}"
          return 0
        fi
      done
    fi
  done

  local fallback=""
  for ip in $(hostname -I 2>/dev/null || true); do
    if is_ip_address "$ip" && ! is_private_ip "$ip"; then
      PUBLIC_IP_CACHE="$ip"
      printf '%s' "${PUBLIC_IP_CACHE}"
      return 0
    fi
    [ -n "${fallback}" ] || fallback="$ip"
  done

  fallback="${fallback:-127.0.0.1}"
  print_err "无法探测公网 IP（候选地址 ${fallback} 不是公网地址），拒绝用内网地址生成分享链接。请检查 VPS 出网/DNS，或在 settings.json 设置 public_ip。"
  return 1
}

probe_tcp_port() {
  local host="$1"
  local port="${2:-}"
  local timeout_s="${3:-2}"
  [ -n "${port}" ] || return 1
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  # 防御性校验（H-2）：host 仅允许域名/IP 合法字符（IPv6 含冒号/括号），
  # 杜绝 ';'、命令替换、路径穿越等注入；非法时直接失败，绝不拼接进 /dev/tcp。
  # 括号字符必须以"[]"开头书写（POSIX 括号表达式规则）：写成 [\[\]] 一类含转义的
  # 形式会经 bash 词法剥离反斜杠后被 regcomp 判为 [:...:] 类构造，整条正则失效，
  # 连 127.0.0.1 都被拒绝（v1.5.8 实测回归，smoke P3 捕获）。勿改写成 [\[...\]]。
  [[ "${host}" =~ ^[][A-Za-z0-9.:-]+$ ]] || return 1
  if command_exists timeout; then
    timeout "${timeout_s}" bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1
  else
    # 环境无 timeout：直接尝试，尽力而为
    bash -c "exec 3<>/dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

# P2：TCP 类节点协议 —— 探活/就绪自检只对它们有意义。
# tuic-v5 与 hy2 为纯 UDP(QUIC) 监听，TCP 探活永远失败，绝不能纳入探活集。
tcp_probeable_protocol() {
  local protocol="$1"
  case "${protocol}" in
  vless-reality | vless-ws-tls | anytls | vless-argo | socks5) return 0 ;;
  esac
  return 1
}

# P2：当前 TCP 可探活节点数量（无节点或无 TCP 类节点时输出 0）。
tcp_probeable_node_count() {
  local tag protocol cnt=0
  [ -f "${NODES_FILE}" ] || {
    printf '0'
    return 0
  }
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    protocol="$(node_value "$tag" "protocol")"
    if tcp_probeable_protocol "${protocol}"; then
      cnt=$((cnt + 1))
    fi
  done < <(iter_node_tags)
  printf '%s' "${cnt}"
}

any_node_port_alive() {
  local tag port protocol _status=1
  local -a jobs=()
  [ -f "${NODES_FILE}" ] || return 1
  if [ "${SBM_PROBE_PARALLEL:-1}" = "1" ]; then
    # A2：全节点端口并行探活，任一成功即判定存活；
    # 10 个死节点从串行 ≈20s 降到 ≈SBM_PROBE_TIMEOUT_S（默认 2s）。
    # P2：仅探 TCP 类协议，hy2/tuic 纯 UDP 节点一律跳过（TCP 探活不适用）。
    while IFS= read -r tag; do
      [ -n "${tag}" ] || continue
      protocol="$(node_value "$tag" "protocol" 2>/dev/null || true)"
      if ! tcp_probeable_protocol "${protocol}"; then
        continue
      fi
      port="$(node_value "$tag" "port" 2>/dev/null || true)"
      [ -n "${port}" ] || continue
      probe_tcp_port "127.0.0.1" "${port}" "${SBM_PROBE_TIMEOUT_S:-2}" &
      jobs+=("$!")
    done < <(iter_node_tags)
    if [ "${#jobs[@]}" -eq 0 ]; then
      return 1
    fi
    for job in "${jobs[@]}"; do
      if wait "${job}" 2>/dev/null; then
        _status=0
        break
      fi
    done
    [ "${_status}" = 0 ] && return 0
    return 1
  fi
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    protocol="$(node_value "$tag" "protocol" 2>/dev/null || true)"
    if ! tcp_probeable_protocol "${protocol}"; then
      continue
    fi
    port="$(node_value "$tag" "port" 2>/dev/null || true)"
    [ -n "${port}" ] || continue
    if probe_tcp_port "127.0.0.1" "${port}" "${SBM_PROBE_TIMEOUT_S:-2}"; then
      return 0
    fi
  done < <(iter_node_tags)
  return 1
}

# P2：数据面探活三态。
#   0=有 TCP 节点且任一可探活（健康）
#   1=存在 TCP 节点但全部不可探活（假死候选）
#   2=无可 TCP 探活节点（全 UDP/空，不适用，调用方以进程存活为准）
singbox_probe_status() {
  local cnt
  cnt="$(tcp_probeable_node_count)"
  [ "${cnt}" -gt 0 ] || return 2
  if any_node_port_alive; then
    return 0
  fi
  return 1
}

has_public_ipv4() {
  if [ -n "${HAS_PUBLIC_IPV4}" ]; then
    [ "${HAS_PUBLIC_IPV4}" = "yes" ]
    return
  fi

  local ip
  ip="$(curl -fsS --max-time 5 --ipv4 "https://api64.ipify.org" 2>/dev/null | tr -d '\r\n' || true)"
  if is_ip_address "${ip}" && ! is_private_ip "${ip}"; then
    HAS_PUBLIC_IPV4="yes"
    return 0
  fi

  HAS_PUBLIC_IPV4="no"
  return 1
}

# 3.2：判定本机是否具备公网 IPv6（任一可达探测源返回合法公网 IPv6）。
has_public_ipv6() {
  local ip
  ip="$(curl -fsS --max-time 5 --ipv6 "https://api64.ipify.org" 2>/dev/null | tr -d '\r\n' || true)"
  if is_ip_address "${ip}" && ! is_private_ip "${ip}"; then
    return 0
  fi
  ip="$(curl -fsS --max-time 5 --ipv6 "https://ifconfig.me/ip" 2>/dev/null | tr -d '\r\n' || true)"
  is_ip_address "${ip}" && ! is_private_ip "${ip}"
}

# 5.2：UDP(QUIC) 类节点协议 —— TCP 探活不适用于它们，改用端口绑定检测。
udp_probeable_protocol() {
  local protocol="$1"
  case "${protocol}" in
  hy2 | tuic-v5) return 0 ;;
  esac
  return 1
}

# 5.2：指定 UDP 端口是否已在监听（ss -lun / netstat -lun 通配与具体地址均算命中）。
# 无检测工具的环境无法验证，视为健康（避免误判触发假阳性重启）。
udp_port_binding_alive() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  if command_exists ss; then
    ss -lunH 2>/dev/null | awk -v p="${port}" '$4 ~ ":" p "$" { found=1 } END { exit found ? 0 : 1 }'
    return $?
  elif command_exists netstat; then
    netstat -lun 2>/dev/null | awk -v p="${port}" '$4 ~ ":" p "$" { found=1 } END { exit found ? 0 : 1 }'
    return $?
  fi
  return 0
}

# 5.2：任意 UDP 端口是否已绑定（hy2/tuic）。全部未绑定则判定数据面假活。
any_udp_port_bound() {
  local tag port protocol found=0
  [ -f "${NODES_FILE}" ] || return 1
  while IFS= read -r tag; do
    [ -n "${tag}" ] || continue
    protocol="$(node_value "$tag" "protocol" 2>/dev/null || true)"
    if ! udp_probeable_protocol "${protocol}"; then
      continue
    fi
    port="$(node_value "$tag" "port" 2>/dev/null || true)"
    [ -n "${port}" ] || continue
    if udp_port_binding_alive "${port}"; then
      found=1
      break
    fi
  done < <(iter_node_tags)
  [ "${found}" = 1 ] && return 0
  return 1
}

# 5.2：当前 UDP(QUIC) 可绑定节点数量（hy2/tuic，无节点或非 UDP 时输出 0）。
udp_node_count() {
  local cnt=0
  [ -f "${NODES_FILE}" ] || {
    printf '0'
    return 0
  }
  local tag protocol _port _argo
  while IFS=$'\t' read -r tag protocol _port _argo; do
    [ -n "${tag}" ] || continue
    if udp_probeable_protocol "${protocol}"; then
      cnt=$((cnt + 1))
    fi
  done < <(node_meta_bulk)
  printf '%s' "${cnt}"
}

invalidate_port_caches() {
  _METADATA_PORTS=""
  _SYSTEM_PORTS=""
}

snapshot_metadata_ports() {
  [ -n "${_METADATA_PORTS:-}" ] && return 0
  _METADATA_PORTS="$(jq -r '.. | objects | .port? // empty' "${NODES_FILE}" 2>/dev/null | tr -d '\r' | grep -E '^[0-9]+$' | sort -nu | tr '\n' ' ' || true)"
  : "${_METADATA_PORTS:=}"
}

snapshot_system_ports() {
  [ -n "${_SYSTEM_PORTS:-}" ] && return 0
  if command_exists ss; then
    _SYSTEM_PORTS="$(ss -ltnuH 2>/dev/null | awk '$1 ~ /^(tcp|tcp6|udp|udp6)$/ { t=$4; sub(/.*:/,"",t); if (t ~ /^[0-9]+$/) print t }' | sort -nu | tr '\n' ' ' || true)"
  elif command_exists netstat; then
    _SYSTEM_PORTS="$(netstat -lntup 2>/dev/null | awk '$1 ~ /^(tcp|tcp6|udp|udp6)$/ { t=$4; sub(/.*:/,"",t); if (t ~ /^[0-9]+$/) print t }' | sort -nu | tr '\n' ' ' || true)"
  fi
  : "${_SYSTEM_PORTS:=}"
}

metadata_has_port() {
  local port="$1"
  snapshot_metadata_ports
  [[ " ${_METADATA_PORTS} " == *" ${port} "* ]]
}

system_has_port() {
  local port="$1"
  snapshot_system_ports
  [[ " ${_SYSTEM_PORTS} " == *" ${port} "* ]]
}

port_available() {
  local port="$1"
  if metadata_has_port "$port"; then
    return 1
  fi
  if system_has_port "$port"; then
    return 1
  fi
  return 0
}
