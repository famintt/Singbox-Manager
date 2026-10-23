#!/usr/bin/env bash
set -eEuo pipefail

umask 077

is_safe_domain() {
  local value="$1"
  [ -n "${value}" ] || return 1
  [[ "${value}" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
  [[ "${value}" =~ ^[A-Za-z0-9] ]] || return 1
  [[ "${value}" =~ [A-Za-z0-9]$ ]] || return 1
  return 0
}

env_domain_or_default() {
  local __ed_key="$1"
  local __ed_default="$2"
  local __ed_value
  __ed_value="$(env_var "$__ed_key")"
  if [ -z "${__ed_value}" ]; then
    printf '%s' "${__ed_default}"
    return 0
  fi
  if is_safe_domain "${__ed_value}"; then
    printf '%s' "${__ed_value}"
  else
    print_warn "环境变量 ${__ed_key}=${__ed_value} 域名格式无效，已回退默认值 ${__ed_default}。"
    printf '%s' "${__ed_default}"
  fi
}

warn_if_bindv6only() {
  if [ -r /proc/sys/net/ipv6/bindv6only ] &&
    [ "$(cat /proc/sys/net/ipv6/bindv6only 2>/dev/null || printf 0)" = "1" ]; then
    print_warn "检测到 net.ipv6.bindv6only=1：入站监听 :: 不会接受 IPv4 连接，IPv4 分享链接可能不可达。"
  fi
}

is_ip_address() {
  local ip="$1" octet
  # IPv4：四组 0-255（兼容前导零）
  if [[ "${ip}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    for octet in "${BASH_REMATCH[@]:1:4}"; do
      [ "$((10#${octet}))" -le 255 ] || return 1
    done
    return 0
  fi
  # IPv6：仅含 hex 与冒号，且 :: 至多出现一次
  if [[ "${ip}" == *:* ]] && [[ "${ip}" =~ ^[0-9a-fA-F:]+$ ]]; then
    case "${ip}" in
    *::*::*) return 1 ;;
    *) return 0 ;;
    esac
  fi
  return 1
}

is_private_ip() {
  local ip="$1"
  local lower
  lower="${ip,,}"

  if [[ "${ip}" =~ ^10\. ]] || [[ "${ip}" =~ ^127\. ]] || [[ "${ip}" =~ ^169\.254\. ]] || [[ "${ip}" =~ ^192\.168\. ]]; then
    return 0
  fi
  if [[ "${ip}" =~ ^172\.([1][6-9]|2[0-9]|3[0-1])\. ]] || [[ "${ip}" =~ ^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\. ]]; then
    return 0
  fi
  # L4：补充协议保留/特殊用途段（RFC 6890）：0/8、198.18/15、IETF 协议保留 192.0.0.0/24、
  # TEST-NET 192.0.2/24、198.51.100/24、203.0.113/24、组播 224/4、保留 240/4（含广播）
  if [[ "${ip}" =~ ^0\. ]] || [[ "${ip}" =~ ^198\.(18|19)\. ]] || [[ "${ip}" =~ ^192\.0\.(0|2)\. ]] ||
    [[ "${ip}" =~ ^198\.51\.100\. ]] || [[ "${ip}" =~ ^203\.0\.113\. ]] ||
    [[ "${ip}" =~ ^2(2[4-9]|3[0-9])\. ]] || [[ "${ip}" =~ ^2(4[0-9]|5[0-5])\. ]]; then
    return 0
  fi

  case "${lower}" in
  "" | "::" | "::1" | fe80:* | fc*:* | fd*:* | 2001:db8:* | 2002:* | 64:ff9b:* | ff*:* | ::ffff:*) return 0 ;;
  esac

  return 1
}

wrap_host() {
  local host="$1"
  if [[ "$host" == *:* ]] && [[ "$host" != \[*\] ]]; then
    printf '[%s]' "$host"
  else
    printf '%s' "$host"
  fi
}

normalize_input() {
  local value="$1"
  printf '%s' "$value" |
    tr -d '\000-\037\177' |
    sed -e 's/\r//g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
