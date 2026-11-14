#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 环境变量驱动的自动安装规格层：从环境变量解析节点参数（auto_collect_specs 等），
# 供 node-auto.sh 的 auto_install 编排使用。
env_port() {
  local __env_key="$1"
  local __env_value
  __env_value="$(env_var "$__env_key")"
  if [ -z "$__env_value" ]; then
    return 1
  fi
  if ! [[ "$__env_value" =~ ^[0-9]+$ ]] || [ "$__env_value" -lt 1 ] || [ "$__env_value" -gt 65535 ]; then
    print_warn "环境变量 ${__env_key} 不是有效端口（1-65535）：${__env_value}，已忽略。"
    return 1
  fi
  printf '%s' "$__env_value"
}
auto_has_node_env() {
  local v
  for v in vlrt vxpt wspt tupt anypt hypt socks5pt argo; do
    if [ -n "$(env_var "$v")" ]; then
      return 0
    fi
  done
  return 1
}
auto_collect_specs() {
  local entry var proto raw port
  for entry in vlrt:vless-reality vxpt:vless-xudp wspt:vless-ws-tls tupt:tuic-v5 anypt:anytls hypt:hy2 socks5pt:socks5; do
    var="${entry%%:*}"
    proto="${entry##*:}"
    raw="$(env_var "$var")"
    [ -n "${raw}" ] || continue
    if ! port="$(env_port "$var")"; then
      print_err "环境变量 ${var}=${raw} 不是有效端口。"
      return 1
    fi
    printf '%s %s\n' "${proto}" "${port}"
  done
  if auto_argo_requested; then
    if ! port="$(auto_argo_local_port)"; then
      print_err "环境变量 argo_pt=$(env_var "argo_pt") 不是有效端口。"
      return 1
    fi
    printf '%s %s\n' "vless-argo" "${port}"
  fi
  return 0
}
auto_save_node() {
  local tag="$1"
  local node_json="$2"
  local secret_json="$3"
  save_node_bundle "$tag" "$node_json" "$secret_json"
}
# argo 环境变量语义：
#   vlpt/vless/true/1/yes → 启用（本地端口取 argo_pt，默认 8001）
#   2-65535 的数字        → 启用且该数字即本地端口（v1.9.6 及此前数字被静默忽略，
#                            纯 Argo 部署会直接报"未检测到有效端口"中止；1 保留为真值语义）
auto_argo_requested() {
  local v
  v="$(env_var "argo")"
  case "${v,,}" in
  vlpt | vless | true | 1 | yes) return 0 ;;
  *)
    if [[ "${v}" =~ ^[0-9]+$ ]] && [ "${v}" -ge 2 ] && [ "${v}" -le 65535 ]; then
      return 0
    fi
    return 1
    ;;
  esac
}

# Argo 本地端口：argo 环境变量为 2-65535 数字时用之；否则 argo_pt；默认 8001
auto_argo_local_port() {
  local v
  v="$(env_var "argo")"
  if [[ "${v}" =~ ^[0-9]+$ ]] && [ "${v}" -ge 2 ] && [ "${v}" -le 65535 ]; then
    printf '%s' "${v}"
    return 0
  fi
  v="$(env_var "argo_pt")"
  if [ -n "${v}" ]; then
    if ! [[ "${v}" =~ ^[0-9]+$ ]] || [ "${v}" -lt 1 ] || [ "${v}" -gt 65535 ]; then
      return 1
    fi
    printf '%s' "${v}"
    return 0
  fi
  printf '8001'
}
auto_positive_or_default() {
  local __env_key="$1"
  local __env_default="$2"
  local __env_value
  __env_value="$(env_var "$__env_key")"
  if [[ "$__env_value" =~ ^[0-9]+$ ]] && [ "$__env_value" -gt 0 ]; then
    printf '%s' "$__env_value"
  else
    printf '%s' "$__env_default"
  fi
}
auto_try_port() {
  local port="$1"
  local label="$2"
  if ! port_available "$port"; then
    local owner
    owner="$(port_owner_name "$port")"
    print_warn "端口 ${port} 已被占用${owner:+（${owner}）}，跳过 ${label} 节点。"
    return 1
  fi
  return 0
}
