#!/usr/bin/env bash
set -eEuo pipefail

umask 077

download_file() {
  local url="$1"
  local out="$2"
  # curl 失败自动换 wget 再试：弱网/单工具缺失时仍可交付。
  # --max-time 防止半开连接把安装/更新永久挂住（弱网下比无限等待更重要）。
  if command_exists curl; then
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 300 "$url" -o "$out" && return 0
  fi
  if command_exists wget; then
    wget -qO "$out" --tries=3 --timeout=60 "$url" && return 0
  fi
  if command_exists curl || command_exists wget; then
    return 1
  fi
  fatal "需要安装 curl 或 wget。"
}

# 原子替换文件：先写到目标目录内的临时文件，再 rename。
# 对正在运行的 /usr/local/bin/sbm 尤其重要——install 直接截断目标文件会让
# 当前 bash 进程后续读取到半截脚本（菜单/更新流程突然消失的典型根因）。
install_atomic() {
  local src="$1"
  local dst="$2"
  local mode="${3:-0755}"
  local tmp
  tmp="${dst}.tmp.$$"
  rm -f "${tmp}"
  if ! install -m "${mode}" "${src}" "${tmp}" 2>/dev/null; then
    rm -f "${tmp}"
    return 1
  fi
  if ! mv -f "${tmp}" "${dst}"; then
    rm -f "${tmp}"
    return 1
  fi
  return 0
}

download_file_multi() {
  local out="$1"
  shift
  local url
  for url in "$@"; do
    [ -n "${url}" ] || continue
    if download_file "${url}" "${out}"; then
      return 0
    fi
  done
  return 1
}

sha256_file() {
  local target="$1"
  if command_exists sha256sum; then
    sha256sum "$target" | awk '{print $1}'
  elif command_exists shasum; then
    shasum -a 256 "$target" | awk '{print $1}'
  else
    openssl dgst -sha256 "$target" | awk '{print $2}'
  fi
}

sha256_matches() {
  local target="$1"
  local expected="$2"
  local actual
  [ -n "${expected}" ] || return 1
  actual="$(sha256_file "$target")"
  [ "${actual}" = "${expected}" ]
}

verify_sha256() {
  local target="$1"
  local expected="$2"
  local actual
  actual="$(sha256_file "$target")"
  if [ "$actual" != "$expected" ]; then
    fatal "SHA256 校验失败：${target}，预期 ${expected}，实际 ${actual}"
  fi
}

url_encode() {
  jq -nr --arg s "$1" '$s|@uri'
}

url_encode_many() {
  jq -nr --args -- '$ARGS.positional[] | @uri' "$@"
}

generate_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command_exists uuidgen; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    local hex variant
    hex="$(openssl rand -hex 16)"
    variant="$(printf '%x' "$(((0x${hex:16:1} & 0x3) | 0x8))")"
    printf '%s-%s-%s-%s-%s\n' \
      "${hex:0:8}" \
      "${hex:8:4}" \
      "4${hex:13:3}" \
      "${variant}${hex:17:3}" \
      "${hex:20:12}"
  fi
}

generate_hex() {
  local bytes="${1:-8}"
  openssl rand -hex "$bytes"
}

random_ws_path() {
  printf '/%s' "$(generate_hex 4)"
}

generate_tag() {
  local prefix="$1"
  printf '%s-%s-%s' "$prefix" "$(date +%s)" "$(generate_hex 4)"
}
