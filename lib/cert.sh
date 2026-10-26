#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 9.2：CERT_FP_CACHE 声明于 env.sh（见注释；此处勿再 declare，避免函数作用域遮蔽）。
# 9.4：自签证书优先 ECDSA P-256（握手计算量小、公钥短，移动端低能耗），
# 旧 OpenSSL 不支持 EC 时的回退 RSA-2048；两者均先试 -addext，不支持时回退 -extfile。
_generate_self_signed() {
  local key_file="$1" cert_file="$2" domain="$3"
  local saf extfile alg
  if [[ "$domain" =~ ^[0-9a-fA-F:.]+$ ]]; then
    saf="subjectAltName=IP:${domain}"
  else
    saf="subjectAltName=DNS:${domain}"
  fi

  local -a algs=()
  if openssl ecparam -name prime256v1 -check >/dev/null 2>&1; then
    algs+=(ecdsa)
  fi
  algs+=(rsa)

  for alg in "${algs[@]}"; do
    if [ "${alg}" = "ecdsa" ]; then
      if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 36135 \
        -keyout "${key_file}" -out "${cert_file}" -subj "/CN=${domain}" \
        -addext "${saf}" >/dev/null 2>&1; then
        return 0
      fi
      extfile="$(mktemp "${CERT_DIR}/.ext.XXXXXX")"
      printf '%s\n' "${saf}" >"${extfile}"
      if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 36135 \
        -keyout "${key_file}" -out "${cert_file}" -subj "/CN=${domain}" \
        -extfile "${extfile}" >/dev/null 2>&1; then
        rm -f "${extfile}"
        return 0
      fi
      rm -f "${extfile}"
    else
      if openssl req -x509 -newkey rsa:2048 -nodes -days 36135 \
        -keyout "${key_file}" -out "${cert_file}" -subj "/CN=${domain}" \
        -addext "${saf}" >/dev/null 2>&1; then
        return 0
      fi
      extfile="$(mktemp "${CERT_DIR}/.ext.XXXXXX")"
      printf '%s\n' "${saf}" >"${extfile}"
      if openssl req -x509 -newkey rsa:2048 -nodes -days 36135 \
        -keyout "${key_file}" -out "${cert_file}" -subj "/CN=${domain}" \
        -extfile "${extfile}" >/dev/null 2>&1; then
        rm -f "${extfile}"
        return 0
      fi
      rm -f "${extfile}"
    fi
  done
  return 1
}

ensure_tls_material() {
  local tag="$1"
  local domain="$2"
  local cert_file="${CERT_DIR}/${tag}.crt"
  local key_file="${CERT_DIR}/${tag}.key"

  if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
    chmod 600 "$cert_file" "$key_file"
    printf '%s|%s' "$cert_file" "$key_file"
    return 0
  fi

  # 自签证书有效期 99 年（99×365=36135 天），配合证书指纹固定（pcs），
  # 避免客户端的证书过期告警与频繁重建。
  if ! _generate_self_signed "$key_file" "$cert_file" "$domain"; then
    rm -f "${cert_file}" "${key_file}"
    print_err "自签证书生成失败（含 SAN）：${domain}"
    return 1
  fi

  chmod 600 "$cert_file" "$key_file"
  printf '%s|%s' "$cert_file" "$key_file"
}

# 判断给定证书是否覆盖目标主机名：subject CN 或 SAN（DNS/IP）精确匹配，
# 支持 DNS 通配证书（DNS:*.example.com 匹配 foo.example.com）。
# 用于分享链接跳过校验判定：证书主体不覆盖链接 SNI 时（如自定义证书 +
# 伪装 SNI），客户端对证书的常规校验必然失败，必须追加 insecure/pinSHA256。
cert_covers_host() {
  local cert_file="$1" host="$2"
  [ -f "${cert_file}" ] || return 1
  [ -n "${host}" ] || return 1
  local cn san entry base
  cn="$(openssl x509 -in "${cert_file}" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,]\{1,\}\).*/\1/p' || true)"
  [ -n "${cn}" ] && [ "${cn}" = "${host}" ] && return 0
  san="$(openssl x509 -in "${cert_file}" -noout -ext subjectAltName 2>/dev/null | grep -oE '(DNS|IP Address):[^, ]+' || true)"
  while IFS= read -r entry; do
    [ -n "${entry}" ] || continue
    entry="${entry#*:}"
    [ "${entry}" = "${host}" ] && return 0
    case "${entry}" in
    "*."*)
      base="${entry#\*.}"
      [ -n "${base}" ] && [ "${host}" != "${base}" ] && [[ "${host}" == *".${base}" ]] && return 0
      ;;
    esac
  done <<<"${san}"
  return 1
}

# 分享链接是否需要跳过证书校验（追加 insecure/pinSHA256/allowInsecure）：
#   - 自签（self-signed）→ 是；
#   - 自定义证书且本机配置了证书文件 → 证书不覆盖目标 SNI 时是（自定义证书 +
#     伪装 SNI 部署，客户端常规校验必然失败）；证书覆盖目标主机名为否；
#   - 自定义/无证书文件（未配置本地证书的受信部署）→ 否（无据可依，保持旧行为）。
# 输出 0=需要跳过校验（需加 insecure），1=不需要。
cert_needs_insecure() {
  local cert_mode="$1" cert_file="$2" host="$3"
  [ "${cert_mode}" = "self-signed" ] && return 0
  [ -n "${cert_file}" ] && [ -f "${cert_file}" ] || return 1
  ! cert_covers_host "${cert_file}" "${host}"
}

cert_fingerprint() {
  local cert_file="$1"
  [ -f "${cert_file}" ] || return 1
  # 9.2：mtime 指纹缓存——同证书重复计算（ldc/分享链接）只做一次 openssl
  local mtime cached key
  mtime="$(stat -c %Y "${cert_file}" 2>/dev/null || true)"
  [ -n "${mtime}" ] || mtime=""
  key="${cert_file}|${mtime}"
  # L7：关联数组下标 -v 检测要求 bash >= 4.3，而 require_bash4 仅保证 >= 4.0，
  # 改用 ${arr[key]+set} 惯用法（bash 3.0+ 通吃），避免低版本运行时数组未定义告警。
  if [[ "${CERT_FP_CACHE[$key]+set}" = "set" ]]; then
    printf '%s' "${CERT_FP_CACHE["$key"]}"
    return 0
  fi
  cached="$(openssl x509 -in "${cert_file}" -outform DER 2>/dev/null | openssl dgst -sha256 -r 2>/dev/null | awk '{print $1}')"
  [ -n "${cached}" ] || return 1
  CERT_FP_CACHE["${key}"]="${cached}"
  printf '%s' "${cached}"
}

managed_cert_path() {
  local tag="$1"
  local path="$2"
  [ "${path%/*}" = "${CERT_DIR}" ] || return 1
  case "$path" in
  "${CERT_DIR}/${tag}."*/*) return 1 ;;
  "${CERT_DIR}/${tag}."*) return 0 ;;
  *) return 1 ;;
  esac
}

import_custom_certificate_bundle() {
  local tag="$1"
  local cert_path="$2"
  local key_path="$3"
  local cert_file="${CERT_DIR}/${tag}.custom.crt"
  local key_file="${CERT_DIR}/${tag}.custom.key"
  local cert_copied=false

  if [ "$cert_path" != "$cert_file" ]; then
    cp "$cert_path" "$cert_file" || return 1
    cert_copied=true
  fi
  if [ "$key_path" != "$key_file" ]; then
    cp "$key_path" "$key_file" || {
      if [ "$cert_copied" = true ]; then
        rm -f "$cert_file"
      fi
      return 1
    }
  fi
  chmod 600 "$cert_file" "$key_file"
  printf '%s|%s' "$cert_file" "$key_file"
}

import_custom_certificate_content() {
  local tag="$1"
  local cert_b64="$2"
  local key_b64="$3"
  local cert_file="${CERT_DIR}/${tag}.custom.crt"
  local key_file="${CERT_DIR}/${tag}.custom.key"

  if [ -z "$cert_b64" ] || [ -z "$key_b64" ]; then
    return 1
  fi
  printf '%s' "$cert_b64" | base64 -d >"$cert_file" || return 1
  printf '%s' "$key_b64" | base64 -d >"$key_file" || {
    rm -f "$cert_file"
    return 1
  }
  chmod 600 "$cert_file" "$key_file"
  printf '%s|%s' "$cert_file" "$key_file"
}

remove_node_certificates() {
  local tag="$1"
  local cert_file="${2:-}"
  local key_file="${3:-}"

  if [ -n "$cert_file" ] && [ -f "$cert_file" ] && managed_cert_path "$tag" "$cert_file"; then
    rm -f "$cert_file"
  fi
  if [ -n "$key_file" ] && [ -f "$key_file" ] && managed_cert_path "$tag" "$key_file"; then
    rm -f "$key_file"
  fi
}

migrate_custom_certificate_bundle() {
  local tag="$1"
  local cert_mode cert_file key_file pair

  cert_mode="$(node_value "$tag" "certificate_mode")"
  [ "$cert_mode" = "custom" ] || return 0

  cert_file="$(node_value "$tag" "certificate_path")"
  key_file="$(node_value "$tag" "key_path")"
  if managed_cert_path "$tag" "$cert_file" && managed_cert_path "$tag" "$key_file"; then
    return 0
  fi
  if [ ! -r "$cert_file" ] || [ ! -r "$key_file" ]; then
    print_err "自定义证书不可读取，无法导入托管目录：${tag}"
    return 1
  fi

  pair="$(import_custom_certificate_bundle "$tag" "$cert_file" "$key_file")" || return 1
  json_set_field "${NODES_FILE}" "$tag" "certificate_path" "${pair%|*}" || return 1
  json_set_field "${NODES_FILE}" "$tag" "key_path" "${pair#*|}" || return 1
}

migrate_custom_certificates() {
  local tags tag
  if ! tags="$(iter_node_tags)"; then
    print_err "读取节点列表失败。"
    return 1
  fi
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    migrate_custom_certificate_bundle "$tag" || return 1
  done <<<"$tags"
}

prompt_certificate_bundle() {
  local tag="$1"
  local default_domain="$2"
  local mode cert_path key_path pair

  while true; do
    mode="$(prompt_choice "证书模式 (self-signed/custom)" "self-signed")"
    case "$mode" in
    self-signed | self | quick)
      pair="$(ensure_tls_material "$tag" "$default_domain")"
      printf 'self-signed|%s|%s' "${pair%|*}" "${pair#*|}"
      return 0
      ;;
    custom)
      cert_path="$(prompt_nonempty "证书路径")"
      key_path="$(prompt_nonempty "私钥路径")"
      [ -r "$cert_path" ] || {
        print_warn "证书不可读取：${cert_path}"
        continue
      }
      [ -r "$key_path" ] || {
        print_warn "私钥不可读取：${key_path}"
        continue
      }
      if ! pair="$(import_custom_certificate_bundle "$tag" "$cert_path" "$key_path")"; then
        print_warn "导入自定义证书失败，请检查路径和权限。"
        continue
      fi
      printf 'custom|%s|%s' "${pair%|*}" "${pair#*|}"
      return 0
      ;;
    *)
      print_warn "请输入 self-signed 或 custom。"
      ;;
    esac
  done
}

cleanup_orphan_certs() {
  local f path tag
  # 约定（L8 钉住）：证书文件名一律为 <tag>.crt / <tag>.key / <tag>.custom.crt / <tag>.custom.key，
  # tag 即首点前段（generate_tag 产物为 <前缀>-<时间戳>-<hex>，不含点——若未来 tag 允许含点必须先改此处）。
  # 防御性校验 tag 字符集（仅允许 [A-Za-z0-9_-]），异常命名一律跳过，绝不误删。
  while IFS= read -r f; do
    path="${f##*/}"
    tag="${path%%.*}"
    [[ "${tag}" =~ ^[A-Za-z0-9_-]+$ ]] || continue
    if ! jq -e --arg tag "${tag}" 'has($tag)' "${NODES_FILE}" >/dev/null 2>&1; then
      rm -f "${f}"
    fi
  done < <(find "${CERT_DIR}" -type f \( -name '*.crt' -o -name '*.key' \) 2>/dev/null)
}
