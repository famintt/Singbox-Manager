#!/usr/bin/env bash
# 测试内的 net_tune_* 小写变量由被测函数经 env_var 间接消费，shellcheck 不可见。
# shellcheck disable=SC2016,SC2034,SC2153
set -eEuo pipefail

# 函数级冒烟测试：source sb.sh（SBM_TEST_MODE=1 阻止入口执行），
# 在临时目录中验证纯逻辑函数，不安装二进制、不触碰 systemd。
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TESTS_DIR}/.." && pwd)"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "${expected}" = "${actual}" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "${desc}" "${expected}" "${actual}" >&2
  fi
}

assert_eval_true() {
  if eval "$2" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL (应为真): %s\n' "$1" >&2
  fi
}

assert_eval_false() {
  if eval "$2" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf 'FAIL (应为假): %s\n' "$1" >&2
  else
    PASS=$((PASS + 1))
  fi
}

# Windows (Git Bash/MSYS) 下使用 C:/ 风格路径作为沙箱，避免 native 二进制
# (openssl/jq) 与 MSYS 路径转换互相破坏；Linux 仍用 mktemp。
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*)
  base_tmp="${LOCALAPPDATA:-${TEMP:-C:/Temp}}"
  TEST_ROOT="$(cygpath -m "${base_tmp}")/sbm-smoke-$$"
  mkdir -p "${TEST_ROOT}"
  ;;
*)
  TEST_ROOT="$(mktemp -d)"
  ;;
esac
export BASE_DIR="${TEST_ROOT}/etc"
export LIB_DIR="${TEST_ROOT}/lib"
export INSTALL_BIN="${TEST_ROOT}/sbm"
export CLOUDFLARED_BIN="${TEST_ROOT}/bin/cloudflared"
export PUBLIC_IP_CACHE="203.0.113.10"
export SBM_TEST_MODE=1
# MSYS 下禁用参数路径转换：沙箱路径已是 C:/ 风格无需转换，
# 同时防止 -subj "/CN=..." 被误转换（Linux 上这些变量无效果）
case "$(uname -s)" in
MINGW* | MSYS* | CYGWIN*) export MSYS2_ARG_CONV_EXCL="*" MSYS_NO_PATHCONV=1 ;;
esac

# shellcheck source=../sb.sh
source "${ROOT_DIR}/sb.sh"

# --- v1.9.3 主线命名与版本 ---
assert_eq "VERSION 稳定版 1.9.3" "v1.9.3" "$(tr -d "\r\n" < "${ROOT_DIR}/VERSION")"
assert_eval_true "UI 使用 VLESS+Vision+Reality 标签" 'grep -q "VLESS+Vision+Reality" "${ROOT_DIR}/interface/index.html"'
assert_eval_true "UI 使用 VLESS+XUDP+Reality 标签" 'grep -q "VLESS+XUDP+Reality" "${ROOT_DIR}/interface/index.html"'
assert_eval_true "UI XUDP 安全层默认 Reality" 'grep -q "option value=\"reality\" selected" "${ROOT_DIR}/interface/index.html"'

# --- 模块分组索引（对应 docs/ARCHITECTURE.md 的 lib/*.sh 分层） ---
# env       : 前置检查/陷阱（隐含：sb.sh 加载即验证）；normalize_input 依赖的变量
# fmt       : normalize_input / env_var / IP 工具 / IPv6 authority 编码
# io        : 下载校验（本环境不联网，经 jq/openssl 边缘用例间接覆盖）
# storage   : 存储初始化 / JSON 读写 / 备份恢复 / 崩溃对账 / wipe / 日志轮转 / PID 文件 / 文件锁
# settings  : 全局设置读写
# network   : 端口占用快照 / 端口探活
# cert      : 自签证书与回退 / 指纹
# render    : node_meta 批量字段 / Reality / WS-TLS / AnyTLS / HY2 渲染（单 outbound 校验）
# links     : 分享链接 / 参数编码 / url 编码
# node-add  : add_* 交互入库（经由 node_bundle 事务）
# node-spec : 环境变量规格收集（auto_collect_specs 等）
# node-auto : auto_add_* 记录字段 / 环境变量自动安装
# node-cmd  : CLI 用法输出 / list / sub / 清理
# argo      : vless_argo 链接与临时域名（网络依赖场景显式跳过）
# tune      : GOGC / net_tune 开关 / 固定 BBR+fq 参数（无测速）
# service   : PID→二进制身份校验 / GOMEMLIMIT 计算 / 进程托管断言（按环境跳过）
# install   : 端到端安装编排（SINGBOX/CLOUDFLARED 二进制 stub）
# menu/cli  : main 命令分发（SBM_TEST_MODE 下不直接执行，由各命令函数覆盖）
# -------------------------------------------------------------------------

# --- normalize_input ---
assert_eq "normalize_input 去首尾空白" "hello" "$(normalize_input "  hello  ")"
assert_eq "normalize_input 删除控制字符" "abcd" "$(normalize_input "$(printf 'ab\tc\rd')")"

# --- env_var（纯 bash 实现，语义对齐 normalize_input） ---
assert_eq "env_var 修剪首尾空白" "hi" "$(
  ENV_TEST_X="  hi  "
  env_var ENV_TEST_X
)"
# shellcheck disable=SC2034 # 供 env_var 读取的环境变量，仅存在于子 shell 内
assert_eq "env_var 剔除控制字符/CR" "abcd" "$(
  ENV_TEST_X="$(printf 'ab\tc\rd')"
  env_var ENV_TEST_X
)"
assert_eq "env_var 未设置返回空" "" "$(
  unset ENV_TEST_X
  env_var ENV_TEST_X
)"

# --- 端口与环境变量解析 ---
assert_eval_true "env_port 合法端口" 'vlrt=2083; [ "$(env_port vlrt)" = "2083" ]'
assert_eval_false "env_port 非法端口" 'vlrt=abc; env_port vlrt'
assert_eval_false "env_port 端口越界" 'vlrt=70000; env_port vlrt'
assert_eval_false "env_port 未设置" 'unset vlrt; env_port vlrt'
assert_eval_true "auto_has_node_env 有 vlrt" 'vlrt=2083; auto_has_node_env'
assert_eval_true "auto_has_node_env 有 vxpt" 'vxpt=5444; auto_has_node_env'
assert_eval_true "auto_has_node_env 有 argo" 'argo=vlpt; auto_has_node_env'
assert_eval_false "auto_has_node_env 全空" 'unset vlrt vxpt wspt tupt anypt hypt socks5pt argo; auto_has_node_env'
assert_eq "auto_collect_specs 收集 vxpt" "vless-xudp 5444" "$(vxpt=5444 auto_collect_specs)"
assert_eval_true "auto_argo_requested vlpt" 'argo=vlpt; auto_argo_requested'
assert_eval_false "auto_argo_requested trpt" 'argo=trpt; auto_argo_requested'
assert_eval_false "auto_argo_requested 未设置" 'unset argo; auto_argo_requested'
assert_eval_true "auto_positive_or_default 合法" 'up_mbps=500; [ "$(auto_positive_or_default up_mbps 200)" = "500" ]'
assert_eval_true "auto_positive_or_default 非法回退" 'up_mbps=abc; [ "$(auto_positive_or_default up_mbps 200)" = "200" ]'

# --- IP 工具 ---
assert_eval_true "is_ip_address IPv4" 'is_ip_address 1.2.3.4'
assert_eval_true "is_ip_address IPv6" 'is_ip_address 2001:db8::1'
assert_eval_false "is_ip_address 域名" 'is_ip_address example.com'
assert_eval_false "is_ip_address 越界八位组" 'is_ip_address 1.2.3.999'
assert_eval_false "is_ip_address 多重 ::" 'is_ip_address ::::'
assert_eval_true "is_private_ip 10段" 'is_private_ip 10.0.0.1'
assert_eval_true "is_private_ip 172.16段" 'is_private_ip 172.16.0.1'
assert_eval_false "is_private_ip 172.32段" 'is_private_ip 172.32.0.1'
assert_eval_false "is_private_ip 公网" 'is_private_ip 8.8.8.8'
assert_eq "wrap_host IPv6 加括号" "[::1]" "$(wrap_host "::1")"
assert_eq "wrap_host IPv4 原样" "1.2.3.4" "$(wrap_host "1.2.3.4")"
assert_eq "get_public_ip 使用缓存" "203.0.113.10" "$(get_public_ip)"

# --- 存储初始化与 JSON 读写 ---
init_storage
assert_eval_true "init_storage 建立目录" '[ -d "${CERT_DIR}" ] && [ -d "${RUNTIME_DIR}" ]'
assert_eq "nodes.json 权限 600" "600" "$(stat -c %a "${NODES_FILE}")"

json_set_record "${NODES_FILE}" "n1" '{"protocol":"vless-reality","name":"VLESS-Reality","port":443,"public_key":"pbk_test","short_id":"abcd"}'
json_set_record "${SECRETS_FILE}" "n1" '{"uuid":"uuid-1111","private_key":"priv_test"}'
assert_eq "node_value 读取协议" "vless-reality" "$(node_value n1 protocol)"
assert_eq "secret_value 读取 uuid" "uuid-1111" "$(secret_value n1 uuid)"
json_set_field "${NODES_FILE}" "n1" "endpoint_domain" "demo.example.com"
assert_eq "json_set_field 写入字段" "demo.example.com" "$(node_value n1 endpoint_domain)"

# --- Argo 按需安装判定（cloudflared 只在有 Argo 时安装） ---
assert_eval_false "argo_nodes_exist 无 Argo 节点" 'argo_nodes_exist'
json_set_record "${NODES_FILE}" "nargo-check" '{"protocol":"vless-argo","name":"A","port":8001,"argo_mode":"temp"}'
assert_eval_true "argo_nodes_exist 检出 vless-argo" 'argo_nodes_exist'
json_delete_record "${NODES_FILE}" "nargo-check"
assert_eval_true "argo_required 环境变量 argo=vlpt" 'argo=vlpt; argo_required'
assert_eval_false "argo_required 无 Argo 环境/节点" 'unset argo; argo_required'
mkdir -p "$(dirname "${CLOUDFLARED_BIN}")"
printf '#!/bin/sh\n' >"${CLOUDFLARED_BIN}"
chmod 0755 "${CLOUDFLARED_BIN}"
assert_eval_true "无 Argo 时回收 cloudflared" 'unset argo; cleanup_unused_cloudflared'
assert_eval_false "cloudflared 已被移除" '[ -e "${CLOUDFLARED_BIN}" ]'

# --- node_meta 单次 jq 批量字段（性能优化：nodes+secrets 合并取 25 字段） ---
assert_eq "node_meta 协议" "vless-reality" "$(node_meta n1 | sed -n '1p')"
assert_eq "node_meta 端口" "443" "$(node_meta n1 | sed -n '3p')"
assert_eq "node_meta uuid" "uuid-1111" "$(node_meta n1 | sed -n '4p')"
assert_eq "node_meta private_key" "priv_test" "$(node_meta n1 | sed -n '6p')"
assert_eq "node_meta public_key" "pbk_test" "$(node_meta n1 | sed -n '7p')"
assert_eq "node_meta short_id" "abcd" "$(node_meta n1 | sed -n '8p')"
assert_eq "node_meta 缺失字段补空行" "" "$(node_meta n1 | sed -n '9p')"
assert_eq "node_meta 输出恰好 25 行" "25" "$(node_meta n1 | wc -l)"

# --- 端口占用快照（性能优化：每端口不再重复 jq/ss） ---
assert_eval_true "metadata_has_port 命中节点端口" 'metadata_has_port 443'
assert_eval_false "metadata_has_port 未占用端口" 'metadata_has_port 55337'
assert_eval_false "port_available 已占用端口为假" 'port_available 443'
assert_eval_true "port_available 未占用端口为真" 'port_available 55337'
json_set_record "${NODES_FILE}" "nport" '{"protocol":"socks5","name":"Port","port":55337}'
assert_eval_true "写记录后快照即时刷新检出端口" 'metadata_has_port 55337'
assert_eval_false "写记录后 port_available 拒绝该端口" 'port_available 55337'
json_delete_record "${NODES_FILE}" "nport"
assert_eval_false "删记录后快照即时释放端口" 'metadata_has_port 55337'
assert_eval_true "删记录后 port_available 放行" 'port_available 55337'

# Reality inbound 渲染直接消费 node_meta 的 uuid/private_key/short_id
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag n1 >"${tmpcfg}" 2>/dev/null
assert_eval_true "Reality inbound 用 node_meta 的 uuid/private_key" 'jq -e ".users[0].uuid == \"uuid-1111\" and .tls.reality.private_key == \"priv_test\" and .tls.reality.short_id[0] == \"abcd\"" "${tmpcfg}" >/dev/null'
rm -f "${tmpcfg}"

# 3.1：multi short_id——逗号分隔渲染为 short_id 数组，非法项被过滤
json_set_record "${NODES_FILE}" "nmulti" '{"protocol":"vless-reality","name":"Multi","port":443,"public_key":"pbk_x","short_id":"ab01,cd02,ef03"}'
json_set_record "${SECRETS_FILE}" "nmulti" '{"uuid":"u-1","private_key":"pk_x"}'
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag nmulti >"${tmpcfg}" 2>/dev/null
assert_eval_true "multi short_id 渲染为数组" 'jq -e ".tls.reality.short_id == [\"ab01\",\"cd02\",\"ef03\"]" "${tmpcfg}" >/dev/null'
rm -f "${tmpcfg}"
assert_eval_true "resolve_short_ids 过滤非法项(保持大小写规范)" '[ "$(resolve_short_ids "AB01,xyz,cd0,EF02")" = "ab01,ef02" ]'
assert_eval_false "resolve_short_ids 全非法返回失败" 'resolve_short_ids "zz,123,x0"'
assert_eval_false "resolve_short_ids 空返回失败" 'resolve_short_ids ""'
json_delete_record "${NODES_FILE}" "nmulti"
json_delete_record "${SECRETS_FILE}" "nmulti"

# 9.5：多源探测响应归一化（裸 IP / 文本 / JSON 字段）
assert_eq "extract_public_ip 裸 IP 直通" "1.2.3.4" "$(extract_public_ip "  1.2.3.4  ")"
assert_eq "extract_public_ip 文本含 IP" "203.0.113.9" "$(extract_public_ip "当前 IP：203.0.113.9 来自于：北京市 电信")"
assert_eq "extract_public_ip JSON data 字段" "198.51.100.7" "$(extract_public_ip '{"ip":"198.51.100.7","detail":"x"}')"
assert_eval_false "extract_public_ip 无 IP 返回失败" 'extract_public_ip "no ip here"'

# 1.2：clash_api 开关/端口/secret 持久化
assert_eval_true "clash_api 默认开启" 'clash_api_enabled'
assert_eval_false "clash_api=0 关闭" 'clash_api=0 clash_api_enabled'
assert_eval_false "clash_api=off 关闭" 'clash_api=off clash_api_enabled'
assert_eq "clash_api_port 默认 19990" "19990" "$(clash_api_port)"
assert_eq "clash_api_port 非法回退默认" "19990" "$(clash_api_port=abc clash_api_port)"
assert_eval_true "clash_api_secret 生成并持久化" '
  s1="$(ensure_clash_api_secret)"
  s2="$(ensure_clash_api_secret)"
  [ -n "$s1" ] && [ "$s1" = "$s2" ] && [ "$(get_setting clash_api_secret)" = "$s1" ] && [ "${#s1}" -ge 16 ]'
assert_eval_true "clash_api=0 不渲染 experimental.clash_api" '
  clash_api=off render_experimental_object | jq -e ".experimental.clash_api == null and .experimental.cache_file.enabled == true" >/dev/null'
assert_eval_true "clash_api 默认渲染 experimental.clash_api" '
  clash_api="" render_experimental_object | jq -e ".experimental.clash_api.secret != null and (.experimental.clash_api.external_controller | startswith(\"127.0.0.1:\"))" >/dev/null'
# 1.2：clash_api 关闭时 render_config 不产 experimental.clash_api，开启时含之
assert_eval_true "clash_api e2e: off 态 config 无 clash_api" 'clash_api=off render_config; jq -e ".experimental | (has(\"clash_api\") | not)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "clash_api e2e: 默认态 config 含 clash_api + cache_file" 'clash_api="" render_config; jq -e ".experimental.clash_api and .experimental.cache_file.enabled" "${CONFIG_FILE}" >/dev/null'

# --- 分享链接 ---
assert_eval_true "Reality 链接含 reality 参数" 'build_share_link n1 | grep -q "security=reality"'
assert_eval_true "Reality 链接含缓存公网 IP" 'build_share_link n1 | grep -q "203.0.113.10:443"'

json_set_record "${NODES_FILE}" "n2" '{"protocol":"hy2","name":"Hysteria2","port":11443,"tls_server":"www.bing.com","certificate_mode":"self-signed"}'
json_set_record "${SECRETS_FILE}" "n2" '{"password":"pw123"}'
assert_eval_true "hy2 自签无指纹时回退 insecure=1" 'build_share_link n2 | grep -q "insecure=1"'

# 9.3：node_meta_bulk —— 批量输出各节点 tag/protocol/port/argo_mode（TSV）
# 5.2：UDP 探活协议识别与节点计数（纯函数；ss/netstat 存在时测端口绑定回退语义）
assert_eval_true "node_meta_bulk 覆盖 n1/n2" 'c="$(node_meta_bulk)"; printf %s "$c" | grep -q "n1.vless-reality.443." && printf %s "$c" | grep -q "n2.hy2.11443."'
# F-09：node_meta_bulk 输出 4 列(key/protocol/port/argo_mode)，消费端 read 必须用占位列
# 吸收多余字段，否则尾列拼接进 protocol/mode/port——token 节点会被当临时隧道重启
json_set_record "${NODES_FILE}" "n_argo" '{"protocol":"vless-argo","name":"Argo","port":54433,"argo_mode":"token","endpoint_domain":"ex.example.com"}'
json_set_record "${SECRETS_FILE}" "n_argo" '{"uuid":"u","argo_token":"tok123"}'
assert_eval_true "node_meta_bulk 4列: argo_mode=token 可达" 'node_meta_bulk | grep -q $'"'"'n_argo\tvless-argo\t54433\ttoken'"'"''
assert_eval_true "restart_all_argo_nodes 解析 protocol=vless-argo(占位列吸收尾列)" '
  hit=""
  while IFS=$'"'"'\t'"'"' read -r tag protocol _port _argo; do [ "${protocol}" = "vless-argo" ] && hit="${tag}"; done < <(node_meta_bulk)
  [ "${hit}" = "n_argo" ]'
assert_eval_true "watchdog 4列解析 mode=token(port 不污染 mode)" '
  got=""
  while IFS=$'"'"'\t'"'"' read -r tag protocol _port mode; do [ "${tag}" = "n_argo" ] && got="${mode}"; done < <(node_meta_bulk)
  [ "${got}" = "token" ]'
assert_eval_true "verify_data_plane_ready 解析 port=54433(argo_mode 不污染 port)" '
  got=""
  while IFS=$'"'"'\t'"'"' read -r tag protocol port _argo; do [ "${tag}" = "n_argo" ] && got="${port}"; done < <(node_meta_bulk)
  [ "${got}" = "54433" ]'
json_delete_record "${NODES_FILE}" "n_argo"
json_delete_record "${SECRETS_FILE}" "n_argo"
assert_eval_true "udp_probeable_protocol hy2 识别" 'udp_probeable_protocol hy2'
assert_eval_true "udp_probeable_protocol tuic-v5 识别" 'udp_probeable_protocol tuic-v5'
assert_eval_false "udp_probeable_protocol 非UDP 拒绝" 'udp_probeable_protocol vless-reality'
assert_eval_true "udp_node_count 含 n2(hy2)" '[ "$(udp_node_count)" -ge 1 ]'
if command_exists ss || command_exists netstat; then
  assert_eval_false "udp_port_binding_alive 未占用端口为假" 'udp_port_binding_alive 55338'
else
  printf '[提示] 无 ss/netstat：跳过 udp_port_binding_alive 端口级断言\n' >&2
fi

json_set_record "${NODES_FILE}" "n2b" '{"protocol":"hy2","name":"Hysteria2-Pin","port":11444,"tls_server":"www.bing.com","certificate_mode":"self-signed","certificate_path":"cert"}'
json_set_record "${SECRETS_FILE}" "n2b" '{"password":"pw123"}'
# 为 n2b 生成真实自签证书供指纹提取
pin_pair="$(ensure_tls_material tag_pin www.bing.com)"
jq --arg p "${pin_pair%|*}" '.n2b.certificate_path = $p' "${NODES_FILE}" >"${NODES_FILE}.tmp" && mv "${NODES_FILE}.tmp" "${NODES_FILE}"
assert_eval_true "hy2 自签有证书时输出 pinSHA256" 'build_share_link n2b | grep -q "pinSHA256=[0-9a-f]\{64\}"'
assert_eval_false "hy2 pin 链接不再含 insecure" 'build_share_link n2b | grep -q "insecure=1"'
assert_eval_true "cert_fingerprint 输出 64 位 hex" 'fp="$(cert_fingerprint "${pin_pair%|*}")"; [[ "${fp}" =~ ^[0-9a-f]{64}$ ]]'

json_set_record "${NODES_FILE}" "n3" '{"protocol":"socks5","name":"SOCKS5","port":1080,"username":"user"}'
json_set_record "${SECRETS_FILE}" "n3" '{"password":"pw456"}'
assert_eval_true "socks5 链接含用户名密码" 'build_share_link n3 | grep -q "user:pw456@"'

# --- 链接参数编码与域名校验（审查 F-09） ---
json_set_record "${NODES_FILE}" "n9" '{"protocol":"vless-ws-tls","name":"EN&X","port":443,"preferred_domain":"cdn.example.com","host_domain":"a&b.com","ws_path":"/p","certificate_mode":"custom"}'
json_set_record "${SECRETS_FILE}" "n9" '{"uuid":"u9"}'
assert_eval_true "特殊字符 host 被编码" 'build_share_link n9 | grep -q "sni=a%26b.com"'
assert_eval_true "特殊字符 name 被编码" 'build_share_link n9 | grep -q "EN%26X"'
json_set_record "${NODES_FILE}" "nargo" '{"protocol":"vless-argo","name":"A","port":8001,"preferred_domain":"saas.sin.fan","ws_path":"/w","endpoint_domain":""}'
json_set_record "${SECRETS_FILE}" "nargo" '{"uuid":"ua"}'
assert_eq "空 endpoint 不生成失效链接" "" "$(build_share_link nargo)"
assert_eval_true "is_safe_domain 合法域名" 'is_safe_domain cdn.example.com'
assert_eval_true "is_safe_domain IPv6" 'is_safe_domain 2001:db8::1'
assert_eval_false "is_safe_domain 含空格" 'is_safe_domain "a b.com"'
assert_eval_false "is_safe_domain 含 &" 'is_safe_domain "a&b.com"'
assert_eval_false "is_safe_domain 空值" 'is_safe_domain ""'

# --- IPv6 authority 生成（审查 F-05）：必须先 wrap_host 加括号、再编码 query 字段 ---
json_set_record "${NODES_FILE}" "n6ws" '{"protocol":"vless-ws-tls","name":"IPv6WS","port":443,"preferred_domain":"2001:db8::1","host_domain":"t.example.com","ws_path":"/p","certificate_mode":"custom","ws_mode":"cdn"}'
json_set_record "${SECRETS_FILE}" "n6ws" '{"uuid":"u6ws"}'
assert_eval_true "IPv6 WS(CDN) authority 加括号（不被 url_encode）" 'build_share_link n6ws | grep -q "@\[2001:db8::1\]:443"'
assert_eval_false "IPv6 WS(CDN) authority 不做 %5B 编码" 'build_share_link n6ws | grep -q "%5B2001"'
json_set_record "${NODES_FILE}" "n6a" '{"protocol":"vless-argo","name":"A6","port":443,"preferred_domain":"2001:db8::99","ws_path":"/w","endpoint_domain":"demo.trycloudflare.com"}'
json_set_record "${SECRETS_FILE}" "n6a" '{"uuid":"u6a"}'
assert_eval_true "IPv6 Argo authority 加括号" 'build_share_link n6a | grep -q "@\[2001:db8::99\]:443"'
json_set_record "${NODES_FILE}" "n6d" '{"protocol":"vless-ws-tls","name":"Domain","port":443,"preferred_domain":"cdn.example.com","host_domain":"h.example.com","ws_path":"/p","certificate_mode":"custom","ws_mode":"cdn"}'
json_set_record "${SECRETS_FILE}" "n6d" '{"uuid":"u6d"}'
assert_eval_true "域名 WS(CDN) authority 不受影响" 'build_share_link n6d | grep -q "@cdn.example.com:443"'
# WS-TLS 直连与 CDN 中转双模式（v0.2.22）：
json_set_record "${NODES_FILE}" "nws-direct" '{"protocol":"vless-ws-tls","name":"WS-Direct","port":20835,"host_domain":"ws.example.com","ws_path":"/p","certificate_mode":"self-signed","ws_mode":"direct"}'
json_set_record "${SECRETS_FILE}" "nws-direct" '{"uuid":"uwsd"}'
assert_eval_true "WS 直连 authority 用服务器 IP" 'build_share_link nws-direct | grep -q "@203.0.113.10:20835"'
assert_eval_true "WS 直连 sni/host 用 WS Host 域名" 'build_share_link nws-direct | grep -q "sni=ws.example.com&type=ws&host=ws.example.com"'
assert_eval_true "WS 直连自签无证书时回退 allowInsecure=1" 'build_share_link nws-direct | grep -q "allowInsecure=1"'
assert_eval_true "WS 直连 allowInsecure 在 query 段（位于 # 之前）" 'build_share_link nws-direct | grep -q "&allowInsecure=1#WS-Direct$"'
assert_eval_true "WS 直连链接 fragment 唯一（仅 1 个 #）" 'l="$(build_share_link nws-direct)"; [ -n "${l#*#}" ] && [[ "${l#*#}" != *"#"* ]]'
json_set_record "${NODES_FILE}" "nws-pin" '{"protocol":"vless-ws-tls","name":"WS-Pin","port":20835,"host_domain":"ws.example.com","ws_path":"/p","certificate_mode":"self-signed","ws_mode":"direct"}'
json_set_record "${SECRETS_FILE}" "nws-pin" '{"uuid":"uwsp"}'
ws_pin_pair="$(ensure_tls_material tag_wspin ws.example.com)"
json_set_field "${NODES_FILE}" "nws-pin" "certificate_path" "${ws_pin_pair%|*}"
assert_eval_true "WS 自签有证书时输出 pcs=pinnedPeerCertSha256" 'build_share_link nws-pin | grep -q "pcs=[0-9a-f]\{64\}"'
assert_eval_true "WS pcs 在 query 段且 fragment 唯一" 'build_share_link nws-pin | grep -q "&pcs=[0-9a-f]\{64\}#WS-Pin$"'
assert_eval_false "WS pcs 链接不再含 allowInsecure" 'build_share_link nws-pin | grep -q "allowInsecure=1"'
json_set_record "${NODES_FILE}" "nws-cdn" '{"protocol":"vless-ws-tls","name":"WS-CDN","port":20835,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/p","certificate_mode":"custom","ws_mode":"cdn","cdn_port":8443}'
json_set_record "${SECRETS_FILE}" "nws-cdn" '{"uuid":"uwsc"}'
assert_eval_true "WS CDN authority 用优选域名+CDN 端口" 'build_share_link nws-cdn | grep -q "@cdn.example.com:8443"'
assert_eval_true "WS CDN sni/host 用优选域名" 'build_share_link nws-cdn | grep -q "sni=cdn.example.com&type=ws&host=cdn.example.com"'
# WS CDN + 自签证书：不得输出 pcs（CDN 模式下客户端面对前置 CDN 的公开证书，固定源站自签指纹必然失败）
json_set_record "${NODES_FILE}" "nws-cdn-pin" '{"protocol":"vless-ws-tls","name":"WS-CDN-Pin","port":20835,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/p","certificate_mode":"self-signed","ws_mode":"cdn","cdn_port":8443}'
json_set_record "${SECRETS_FILE}" "nws-cdn-pin" '{"uuid":"uwscp"}'
ws_cdn_pin_pair="$(ensure_tls_material tag_wscdnpin ws.example.com)"
json_set_field "${NODES_FILE}" "nws-cdn-pin" "certificate_path" "${ws_cdn_pin_pair%|*}"
assert_eval_false "WS CDN 自签证书不输出 pcs" 'build_share_link nws-cdn-pin | grep -q "pcs="'
assert_eval_false "WS CDN 自签证书不输出 allowInsecure" 'build_share_link nws-cdn-pin | grep -q "allowInsecure"'
# AnyTLS 链接格式（v0.2.22）：insecure=1 + type=tcp&headerType=none
json_set_record "${NODES_FILE}" "nanytls" '{"protocol":"anytls","name":"AnyTLS","port":20834,"tls_server":"dl.google.com","certificate_mode":"self-signed"}'
json_set_record "${SECRETS_FILE}" "nanytls" '{"password":"pwany"}'
assert_eval_true "AnyTLS 自签链接含 insecure=1" 'build_share_link nanytls | grep -q "insecure=1"'
assert_eval_true "AnyTLS 链接含 type=tcp&headerType=none" 'build_share_link nanytls | grep -q "type=tcp&headerType=none"'
assert_eval_false "AnyTLS 自签链接不再含 allowInsecure" 'build_share_link nanytls | grep -q "allowInsecure"'
json_set_record "${NODES_FILE}" "nanytls-custom" '{"protocol":"anytls","name":"AnyTLS-C","port":20834,"tls_server":"trust.example.com","certificate_mode":"custom"}'
json_set_record "${SECRETS_FILE}" "nanytls-custom" '{"password":"pwanyb"}'
assert_eval_false "AnyTLS 受信证书链接不含 insecure" 'build_share_link nanytls-custom | grep -q "insecure"'
assert_eval_true "AnyTLS 受信证书链接保留 type=tcp" 'build_share_link nanytls-custom | grep -q "type=tcp&headerType=none"'
assert_eval_true "anytls 自签 ext 不泄漏到全局" 'unset ext; build_share_link nanytls >/dev/null; [ -z "${ext:-}" ]'

# VLESS + XUDP：TLS/TCP inbound（TLS 分支），客户端 XUDP 编码，服务端不需要 flow/multiplex
json_set_record "${NODES_FILE}" "nxudp" '{"protocol":"vless-xudp","name":"VLESS-XUDP","port":20837,"tls_server":"www.bing.com","certificate_mode":"self-signed"}'
json_set_record "${SECRETS_FILE}" "nxudp" '{"uuid":"uxudp"}'
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag nxudp >"${tmpcfg}" 2>/dev/null
assert_eq "VLESS-XUDP inbound type" "vless" "$(jq -r '.type' "${tmpcfg}")"
assert_eq "VLESS-XUDP inbound TLS" "true" "$(jq -r '.tls.enabled' "${tmpcfg}")"
assert_eq "VLESS-XUDP inbound SNI" "www.bing.com" "$(jq -r '.tls.server_name' "${tmpcfg}")"
assert_eval_true "VLESS-XUDP 不使用 flow" 'jq -e ".users[0].flow == null" "${tmpcfg}" >/dev/null'
assert_eval_true "VLESS-XUDP 不渲染 multiplex" 'jq -e ".multiplex == null" "${tmpcfg}" >/dev/null'
rm -f "${tmpcfg}"
assert_eval_true "VLESS-XUDP 链接含 TLS + XUDP" 'build_share_link nxudp | grep -q "security=tls.*packetEncoding=xudp"'
assert_eval_true "VLESS-XUDP 链接含 type=tcp" 'build_share_link nxudp | grep -q "type=tcp"'
assert_eval_false "VLESS-XUDP 链接不带 Vision flow" 'build_share_link nxudp | grep -q "flow="'
assert_eval_true "VLESS-XUDP 自签无证书回退 allow_insecure=1" 'build_share_link nxudp | grep -q "allow_insecure=1"'
xudp_pair="$(ensure_tls_material tag_xudp www.bing.com)"
json_set_field "${NODES_FILE}" "nxudp" "certificate_path" "${xudp_pair%|*}"
assert_eval_true "VLESS-XUDP 自签有证书输出 allow_insecure=1" 'build_share_link nxudp | grep -q "allow_insecure=1"'
assert_eval_true "VLESS-XUDP 自签有证书输出 pcs" 'build_share_link nxudp | grep -q "pcs=[0-9a-f]\{64\}"'
assert_eval_false "VLESS-XUDP 不再使用旧版 allowInsecure" 'build_share_link nxudp | grep -q "allowInsecure=1"'
assert_eval_true "VLESS-XUDP pcs 在 fragment 前" 'build_share_link nxudp | grep -q "&pcs=[0-9a-f]\{64\}#VLESS-XUDP$"'

# VLESS + Reality + XUDP：同一 vless-xudp 协议的 Reality 安全层
json_set_record "${NODES_FILE}" "nxudp-reality" '{"protocol":"vless-xudp","name":"XUDP-Reality","port":20840,"reality_server":"www.apple.com","public_key":"pbk-test","short_id":"abcd1234"}'
json_set_record "${SECRETS_FILE}" "nxudp-reality" '{"uuid":"uxudp-reality","private_key":"priv-test"}'
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag nxudp-reality >"${tmpcfg}" 2>/dev/null
assert_eq "XUDP-Reality inbound type" "vless" "$(jq -r '.type' "${tmpcfg}")"
assert_eq "XUDP-Reality 启用 Reality" "true" "$(jq -r '.tls.reality.enabled' "${tmpcfg}")"
assert_eq "XUDP-Reality handshake" "www.apple.com:443" "$(jq -r '.tls.reality.handshake.server + ":" + (.tls.reality.handshake.server_port|tostring)' "${tmpcfg}")"
assert_eq "XUDP-Reality 无证书路径" "null" "$(jq -r '.tls.certificate_path // null' "${tmpcfg}")"
assert_eval_true "XUDP-Reality 不使用 flow" 'jq -e ".users[0].flow == null" "${tmpcfg}" >/dev/null'
assert_eval_true "XUDP-Reality 不渲染 multiplex" 'jq -e ".multiplex == null" "${tmpcfg}" >/dev/null'
rm -f "${tmpcfg}"
assert_eval_true "XUDP-Reality 链接为 reality" 'build_share_link nxudp-reality | grep -q "security=reality.*pbk=pbk-test.*sid=abcd1234.*packetEncoding=xudp"'
assert_eval_false "XUDP-Reality 链接不带证书参数" 'build_share_link nxudp-reality | grep -qE "(pcs=|allow_insecure=|allowInsecure=)"'
assert_eval_true "XUDP-Reality 链接 fragment 正确" 'build_share_link nxudp-reality | grep -q "#XUDP-Reality$"'

# --- fp 局部变量隔离（Bug #5）：hy2 自签时 fp 不得泄漏到全局 ---
assert_eval_true "hy2 fp 不泄漏到全局" 'unset fp; build_share_link n2b >/dev/null; [ -z "${fp:-}" ]'

# --- sbm list 输出：名称与链接分行，链接顶格，便于整行复制 ---
_list_out="$(print_node_list 2>/dev/null || true)"
assert_eval_true "list 链接单独顶格一行" 'printf "%s\n" "${_list_out}" | grep -q "^vless://"'
assert_eval_false "list 不再使用 链接: 同行前缀" 'printf "%s\n" "${_list_out}" | grep -q "链接: "'
assert_eval_true "list 名称行保留序号/协议/端口" 'printf "%s\n" "${_list_out}" | grep -q "^1\..* | .* | 端口: "'

# --- 订阅链接（测试版）：token / base64 内容 / 开关 ---
assert_eval_false "sub 默认关闭" 'unset sub; unset sub_enabled; sub_enabled'
assert_eval_true "sub token 为 32 位 hex" '[[ "$(sub_token)" =~ ^[0-9a-f]{32}$ ]]'
assert_eval_true "sub 订阅文件可生成" 'sub_build_file'
assert_eval_true "sub 内容可 base64 解出节点链接" 'base64 -d <"$(sub_file)" | grep -q "^vless://"'
assert_eq "sub_mode 默认 temp" "temp" "$(unset -v sub_mode; sub_mode)"
assert_eq "sub_mode worker" "worker" "$(sub_mode=worker; sub_mode)"
assert_eq "sub_worker_base 补 https" "https://sub.example.com" "$(sub_domain=sub.example.com; sub_worker_base)"
assert_eq "sub_worker_base 去尾斜杠" "https://sub.example.com" "$(sub_domain=https://sub.example.com/; sub_worker_base)"
assert_eq "sub_machine 规范化" "my-node" "$(sub_machine='My Node!'; sub_machine)"

# --- PID 文件严格校验（审查 F-03） ---
printf 'abc\n' >"${RUNTIME_DIR}/bad.pid"
assert_eval_false "非数字 PID 被拒绝" 'read_pid_file "${RUNTIME_DIR}/bad.pid"'
printf ' 42 \n' >"${RUNTIME_DIR}/ws.pid"
assert_eq "PID 去除空白" "42" "$(read_pid_file "${RUNTIME_DIR}/ws.pid")"
rm -f "${RUNTIME_DIR}/bad.pid" "${RUNTIME_DIR}/ws.pid"

# --- PID→二进制身份校验（审查 F-01）：错误二进制不得判为存活的服务实例 ---
assert_eval_false "pid_matches_binary_or_alive 拒绝身份不符进程" 'pid_matches_binary_or_alive $$ /nonexistent/sbm-other-binary'
# 回归：in-place 升级后旧进程 /proc/PID/exe 带 " (deleted)" 后缀仍应判定为"我们的实例"
# （否则 kill_pid_file 会跳过终止，导致旧进程残留与新实例并存）。
if [ -d /proc ] && command -v sleep >/dev/null 2>&1; then
  _pb="${TEST_ROOT}/.pidbin"
  cp /bin/sleep "${_pb}" 2>/dev/null || cp "$(dirname "$(command -v sleep)")/sleep" "${_pb}"
  chmod +x "${_pb}"
  "${_pb}" 30 &
  _pb_pid=$!
  sleep 0.2
  rm -f "${_pb}"
  # MSYS 下 /proc/PID/exe 与 Windows 风格路径无法对等模拟原地替换，仅 Linux 上断言 (deleted)
  if [[ "$(readlink "/proc/${_pb_pid}/exe" 2>/dev/null || true)" == *" (deleted)"* ]]; then
    assert_eval_true "pid_matches_binary 命中原地替换后的 (deleted) exe（兼容升级）" 'pid_matches_binary "'"${_pb_pid}"'" "'"${_pb}"'"'
    assert_eval_true "pid_matches_binary_or_alive 对 (deleted) exe 判为存活（兼容升级）" 'pid_matches_binary_or_alive "'"${_pb_pid}"'" "'"${_pb}"'"'
  fi
  kill "${_pb_pid}" 2>/dev/null || true
fi

# --- 自签证书与回退逻辑 ---
assert_eval_true "ensure_tls_material 生成证书" 'pair="$(ensure_tls_material tag_tls www.bing.com)"; [ -f "${pair%|*}" ] && [ -f "${pair#*|}" ]'
# 9.4：优先 ECDSA P-256；OpenSSL 不支持 EC 的环境回退 RSA-2048
if openssl ecparam -name prime256v1 -check >/dev/null 2>&1; then
  assert_eval_true "自签证书优先 ECDSA P-256" 'openssl x509 -in "${CERT_DIR}/tag_tls.crt" -noout -text 2>/dev/null | grep -q "prime256v1"'
else
  assert_eval_true "无 EC 支持时回退 RSA-2048" 'openssl x509 -in "${CERT_DIR}/tag_tls.crt" -noout -text 2>/dev/null | grep -qE "rsaEncryption|RSA Public Key"'
fi
assert_eval_true "自签证书含 SAN(DNS)" 'openssl x509 -in "${CERT_DIR}/tag_tls.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "www.bing.com"'
# 9.2：证书指纹进程级缓存（同证书重复计算幂等）
assert_eval_true "cert_fingerprint 输出 64 位 hex" 'fp="$(cert_fingerprint "${CERT_DIR}/tag_tls.crt")"; [[ "${fp}" =~ ^[0-9a-f]{64}$ ]]'
assert_eval_true "cert_fingerprint 缓存命中幂等" '
  out="$(
    cert_fingerprint "${CERT_DIR}/tag_tls.crt" >/dev/null
    cert_fingerprint "${CERT_DIR}/tag_tls.crt" >/dev/null
    printf "%s" "${#CERT_FP_CACHE[@]}"
  )"
  [ "${out}" -ge 1 ]'
assert_eval_true "auto_cert_bundle 默认自签" 'auto_cert_bundle t_auto www.bing.com | grep -q "^self-signed|"'
assert_eval_false "auto_cert_bundle custom 缺路径回退自签" 'unset cert_path key_path; cert=custom; auto_cert_bundle t_c www.bing.com | grep -q "^custom|"'
# 回归：cert_path/key_path 环境变量不再被局部变量遮蔽
cpair="$(ensure_tls_material certsrc www.bing.com)"
export cert=custom
export cert_path="${cpair%|*}"
export key_path="${cpair#*|}"
assert_eval_true "custom 证书经环境变量正确导入" 'auto_cert_bundle ctest2 www.bing.com | grep -q "^custom|"'
unset cert cert_path key_path
# v1.2.5：cert_b64/key_b64 直接粘贴 PEM 内容（base64）导入
# shellcheck disable=SC2034 # 结果在下方 assert_eval_true 的 eval 字符串内消费
b64pair="$(ensure_tls_material certb64 www.bing.com)"
assert_eval_true "cert_b64/key_b64 内容导入为 custom" 'export cert=custom cert_b64="$(base64 -w0 <"${b64pair%|*}")" key_b64="$(base64 -w0 <"${b64pair#*|}")"; auto_cert_bundle ctest3 www.bing.com | grep -q "^custom|"'
unset cert cert_b64 key_b64
assert_eval_false "cert_b64 缺 key_b64 回退自签" 'export cert=custom cert_b64="QUJD"; unset key_b64; auto_cert_bundle t_b64miss www.bing.com | grep -q "^custom|"'
unset cert cert_b64

# --- 状态备份与恢复（含证书，审查 F-02/F-09） ---
wipe_records
json_set_record "${NODES_FILE}" "bk" '{"protocol":"socks5","name":"BK","port":1234,"username":"u"}'
json_set_record "${SECRETS_FILE}" "bk" '{"password":"p"}'
mkdir -p "${CERT_DIR}" && printf 'CERT' >"${CERT_DIR}/bk.crt" && printf 'KEY' >"${CERT_DIR}/bk.key"
# shellcheck disable=SC2034 # 结果在下方 assert_eval_true 的 eval 字符串内消费
bkp_dir="$(backup_state)"
assert_eval_true "备份目录名唯一（随机+进程后缀, 审查 F-09）" '[[ "${bkp_dir}" =~ [0-9]{4}-[0-9]+$ ]]'
assert_eval_true "备份含证书文件（审查 F-02）" '[ -f "${bkp_dir}/certs/bk.crt" ] && [ -f "${bkp_dir}/certs/bk.key" ]'
wipe_records
assert_eq "清空后节点为 0" "0" "$(jq length "${NODES_FILE}")"
restore_latest_backup
assert_eq "备份恢复节点" "1" "$(jq length "${NODES_FILE}")"
assert_eval_true "恢复过程一并还原证书（审查 F-02）" '[ -f "${CERT_DIR}/bk.crt" ] && [ -f "${CERT_DIR}/bk.key" ]'
rm -f "${CERT_DIR}/bk.crt" "${CERT_DIR}/bk.key"

# --- 崩溃对账 ---
wipe_records
json_set_record "${NODES_FILE}" "pair1" '{"protocol":"hy2"}'
json_set_record "${SECRETS_FILE}" "pair1" '{"password":"y"}'
json_set_record "${NODES_FILE}" "orphan1" '{"protocol":"socks5"}'
json_set_record "${SECRETS_FILE}" "orphan2" '{"password":"x"}'
reconcile_state
assert_eq "对账后孤儿节点已清除" "1" "$(jq length "${NODES_FILE}")"
assert_eq "对账后孤儿密钥已清除" "1" "$(jq length "${SECRETS_FILE}")"

# --- 全局设置 ---
assert_eq "get_setting 默认 ip_version" "4" "$(get_setting ip_version 4)"
set_setting "ip_version" "6"
assert_eq "set_setting 回读" "6" "$(get_setting ip_version 4)"
set_setting "ip_version" "auto"
assert_eq "set_setting auto" "auto" "$(get_setting ip_version 4)"
assert_eq "settings.json 权限 600" "600" "$(stat -c %a "${SETTING_FILE}")"

# --- wipe_records ---
wipe_records
assert_eq "wipe_records 清空 nodes" "0" "$(jq length "${NODES_FILE}")"
assert_eq "wipe_records 清空 secrets" "0" "$(jq length "${SECRETS_FILE}")"

# --- 日志轮转 ---
big_file="${TEST_ROOT}/big.log"
head -c 2048 /dev/zero >>"${big_file}"
LOG_ROTATE_SIZE_MB=0 rotate_log_file "${big_file}" || true
assert_eval_true "rotate_log_file 产生轮转文件" '[ -f "${big_file}.1" ]'

# --- v0.2.17：GOMEMLIMIT 计算 / DoH 域名确认 / 多源下载 ---
assert_eval_true "compute_go_mem_limit_mb 输出正整数" 'v="$(compute_go_mem_limit_mb)"; [[ "${v}" =~ ^[0-9]+$ ]] && [ "${v}" -gt 0 ]'
assert_eval_true "compute_go_mem_limit_mb 不低于下限" 'v="$(SBM_GOMEM_FLOOR_MB=9999 compute_go_mem_limit_mb)"; [ "${v}" = "9999" ]'
assert_eval_true "go_mem_limit_value 带 MiB 后缀" 'v="$(go_mem_limit_value)"; [ -z "${v}" ] || [[ "${v}" =~ ^[0-9]+MiB$ ]]'
assert_eval_true "argo_domain_resolvable 公网域名可解析" 'argo_domain_resolvable cloudflare.com'
# 拒绝性断言仅在 DoH 可达环境执行：双源均不可达时函数按设计 fail-open 放行
if curl -fsS --max-time 5 -H 'accept: application/dns-json' "https://1.1.1.1/dns-query?name=cloudflare.com.&type=A" >/dev/null 2>&1; then
  assert_eval_false "argo_domain_resolvable 无效域名拒绝" 'argo_domain_resolvable "nonexistent-sbm-test.invalid"'
else
  PASS=$((PASS + 1))
  printf 'SKIP (DoH 不可达，fail-open 路径): argo_domain_resolvable 无效域名拒绝
' >&2
fi
assert_eval_false "download_file_multi 全部源失败返回非零" 'download_file_multi "${TEST_ROOT}/dl.out" "https://sbm.invalid/nonexist-a" "https://sbm.invalid/nonexist-b"'

# --- CLI 用法输出 ---
assert_eval_true "print_cli_usage 可执行" 'print_cli_usage | grep -q "用法"'

# --- auto_add_vless_ws_tls 记录 ws_mode/cdn_port/cdn_sni（v0.2.22 / v0.3.0） ---
ENV_NAME=Sm ENV_UUID=22222222-3333-4444-5555-666666666666 ENV_CDN_HOST=cdn.example.com ENV_WS_HOST=ws.example.com ENV_WS_MODE=cdn ENV_CDN_PORT=8443 auto_add_vless_ws_tls 20837
assert_eval_true "ws_mode=cdn 与 cdn_port 写入节点记录" 'jq -e "to_entries[] | select(.value.protocol == \"vless-ws-tls\" and .value.port == 20837 and .value.ws_mode == \"cdn\" and .value.cdn_port == 8443)" "${NODES_FILE}" >/dev/null'
assert_eval_true "cdn_sni 未显式设置时默认同连接地址" 'jq -e "to_entries[] | select(.value.port == 20837 and .value.cdn_sni == \"cdn.example.com\")" "${NODES_FILE}" >/dev/null'
# v0.3.0：ws_cdn 专用前缀优先于共享与旧名
ENV_NAME=Sm2 ENV_WS_CDN_VLESS_CF_HOST=per-proto.example.com ENV_WS_CDN_VLESS_CF_PT=2096 ENV_WS_CDN_SNI=shared-sni.example.com ENV_WS_MODE=cdn auto_add_vless_ws_tls 20838
# --- VLESS+XUDP 自动安装记录（防止 jq 行继续符/参数错误回归） ---
ENV_NAME=Xu ENV_UUID=44444444-5555-6666-7777-888888888888 ENV_VX_SNI=www.bing.com ENV_VX_SECURITY=tls auto_add_vless_xudp 20839
assert_eq "auto_add_vless_xudp 节点协议" "vless-xudp" "$(jq -r 'to_entries[] | select(.value.port == 20839) | .value.protocol' "${NODES_FILE}")"
assert_eq "auto_add_vless_xudp 节点 SNI" "www.bing.com" "$(jq -r 'to_entries[] | select(.value.port == 20839) | .value.tls_server' "${NODES_FILE}")"
assert_eq "auto_add_vless_xudp secret UUID" "44444444-5555-6666-7777-888888888888" "$(jq -r 'to_entries[] | select(.value.uuid == "44444444-5555-6666-7777-888888888888") | .value.uuid' "${SECRETS_FILE}")"
assert_eval_true "ws_cdn_vless_* 覆盖共享/旧名值" 'jq -e "to_entries[] | select(.value.port == 20838 and .value.preferred_domain == \"per-proto.example.com\" and .value.cdn_port == 2096 and .value.cdn_sni == \"shared-sni.example.com\")" "${NODES_FILE}" >/dev/null'

# --- v0.3.3：Argo 独立优选域名/端口（argo_cdn_host/argo_cdn_port 独立于 WS-CDN） ---
ENV_NAME=Ar1 ENV_ARGO_CDN_HOST=argo.example.com ENV_ARGO_CDN_PORT=2053 auto_add_vless_argo 8002
assert_eval_true "argo_cdn_host/argo_cdn_port 写入节点记录" 'jq -e "to_entries[] | select(.value.protocol == \"vless-argo\" and .value.port == 8002 and .value.preferred_domain == \"argo.example.com\" and .value.cdn_port == 2053)" "${NODES_FILE}" >/dev/null'
ENV_ARGO_CDN_HOST="" ENV_CDN_HOST="fallback.example.com" auto_add_vless_argo 8003
assert_eval_true "argo_cdn 未设置时回退 cdn_host" 'jq -e "to_entries[] | select(.value.port == 8003 and .value.preferred_domain == \"fallback.example.com\" and .value.cdn_port == 443)" "${NODES_FILE}" >/dev/null'
json_set_record "${NODES_FILE}" "nargo-cdn" '{"protocol":"vless-argo","name":"ArgoCDN","port":8001,"preferred_domain":"argo.example.com","cdn_port":2053,"ws_path":"/w","endpoint_domain":"demo.trycloudflare.com"}'
json_set_record "${SECRETS_FILE}" "nargo-cdn" '{"uuid":"uac"}'
assert_eval_true "Argo 链接使用 argo_cdn_port" 'build_share_link nargo-cdn | grep -q "@argo.example.com:2053"'
assert_eval_false "Argo 链接不再硬编码 443" 'build_share_link nargo-cdn | grep -q "443?encryption"'

# --- v0.3.0：CDN 模式 cdn_sni 编号或回退连接地址链接生成（审查 ws_cdn 设计） ---
json_set_record "${NODES_FILE}" "nws-cdn2" '{"protocol":"vless-ws-tls","name":"WS-CDN2","port":20835,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/p","certificate_mode":"custom","ws_mode":"cdn","cdn_port":8443,"cdn_sni":"origin.example.com"}'
json_set_record "${SECRETS_FILE}" "nws-cdn2" '{"uuid":"uwsc2"}'
assert_eval_true "WS CDN 连接地址用优选域名、SNI/Host 用 cdn_sni" 'build_share_link nws-cdn2 | grep -q "@cdn.example.com:8443?encryption=none&security=tls&sni=origin.example.com&type=ws&host=origin.example.com"'
json_set_record "${NODES_FILE}" "nws-cdn0" '{"protocol":"vless-ws-tls","name":"WS-CDN0","port":20835,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/p","certificate_mode":"custom","ws_mode":"cdn","cdn_port":8443}'
json_set_record "${SECRETS_FILE}" "nws-cdn0" '{"uuid":"uwsc0"}'
assert_eval_true "WS CDN 无 cdn_sni 时回退连接地址" 'build_share_link nws-cdn0 | grep -q "sni=cdn.example.com&type=ws&host=cdn.example.com"'

# --- v1.1.0：性能/稳定性（TCP Fast Open / HY2 不限速 / GOGC / 退避 / 探活） ---
json_set_record "${NODES_FILE}" "nhyu" '{"protocol":"hy2","name":"HY2-UNLIM","port":11445,"tls_server":"www.bing.com","certificate_mode":"self-signed"}'
json_set_record "${SECRETS_FILE}" "nhyu" '{"password":"pw"}'
json_set_record "${NODES_FILE}" "nws-tune" '{"protocol":"vless-ws-tls","name":"WS-Tune","port":20840,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/e","certificate_mode":"custom","certificate_path":"cert"}'
json_set_record "${SECRETS_FILE}" "nws-tune" '{"uuid":"ut"}'

# P2/P3：渲染单 outbound 直接校验（写 stdout，不依赖 CONFIG_FILE）
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
(tcp_fast_open=0 render_inbound_for_tag nws-tune) >"${tmpcfg}" 2>/dev/null
assert_eval_true "tcp_fast_open=false 渲染进 inbound" 'jq -e ".tcp_fast_open == false" "${tmpcfg}" >/dev/null'
(tcp_fast_open=1 render_inbound_for_tag nws-tune) >"${tmpcfg}" 2>/dev/null
assert_eval_true "tcp_fast_open=true 渲染进 inbound" 'jq -e ".tcp_fast_open == true" "${tmpcfg}" >/dev/null'
assert_eval_true "WS inbound 带 0-RTT early data 字段" 'jq -e ".transport.max_early_data == 2048 and .transport.early_data_header_name == \"Sec-WebSocket-Protocol\"" "${tmpcfg}" >/dev/null'
rm -f "${tmpcfg}"

# P1：HY2 无 up/down 字段 -> 渲染时回退默认 200 Mbps
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag nhyu >"${tmpcfg}" 2>/dev/null
assert_eval_true "HY2 未设置带宽时写默认 up_mbps=200" 'jq -e ".up_mbps == 200" "${tmpcfg}" >/dev/null'
assert_eval_true "HY2 未设置带宽时写默认 down_mbps=200" 'jq -e ".down_mbps == 200" "${tmpcfg}" >/dev/null'
rm -f "${tmpcfg}"

# P1：填写带宽时仍正确写入（含 0-RTT WS 渲染）
json_set_record "${NODES_FILE}" "nhyu" '{"protocol":"hy2","name":"HY2-UNLIM","port":11445,"tls_server":"www.bing.com","certificate_mode":"self-signed","up_mbps":400,"down_mbps":800}'
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag nhyu >"${tmpcfg}" 2>/dev/null
assert_eval_true "HY2 限速时写 up_mbps=400" 'jq -e ".up_mbps == 400" "${tmpcfg}" >/dev/null'
assert_eval_true "HY2 限速时写 down_mbps=800" 'jq -e ".down_mbps == 800" "${tmpcfg}" >/dev/null'
rm -f "${tmpcfg}"

# --- B1：TUIC 0-RTT（默认开启；tuic_zero_rtt=0 关闭；不携带 TCP keepalive 字段） ---
json_set_record "${NODES_FILE}" "ntic" '{"protocol":"tuic-v5","name":"TUIC-ZRTT","port":10111,"tls_server":"www.bing.com","certificate_mode":"self-signed"}'
json_set_record "${SECRETS_FILE}" "ntic" '{"uuid":"uz","password":"pz"}'
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag ntic >"${tmpcfg}" 2>/dev/null
assert_eval_true "B1 TUIC 不携带 zero_rtt 字段" 'jq -e "(has(\"zero_rtt_handshake\") | not) and .congestion_control == \"bbr\"" "${tmpcfg}" >/dev/null'
assert_eval_true "B1 TUIC 不携带 TCP keepalive 字段" 'jq -e "has(\"tcp_keep_alive\") | not" "${tmpcfg}" >/dev/null'
rm -f "${tmpcfg}"

# --- B3：TCP keepalive 显式化（默认 30s；interval 可调；非法回退） ---
# 1.13.0+ schema：tcp_keep_alive 为字符串型间隔（旧 bool+interval 双字段已废弃），
# 由环境变量 tcp_keep_alive_interval 驱动，非法值回退 30s。
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag nws-tune >"${tmpcfg}" 2>/dev/null
assert_eval_true "B3 WS-TLS 默认 keepalive=\"30s\"且无独立 interval 键" 'jq -e ".tcp_keep_alive == \"30s\" and (has(\"tcp_keep_alive_interval\") | not)" "${tmpcfg}" >/dev/null'
tcp_keep_alive_interval=15s render_inbound_for_tag nws-tune >"${tmpcfg}" 2>/dev/null
assert_eval_true "B3 tcp_keep_alive 间隔可调 15s" 'jq -e ".tcp_keep_alive == \"15s\"" "${tmpcfg}" >/dev/null'
tcp_keep_alive_interval=abc render_inbound_for_tag nws-tune >"${tmpcfg}" 2>/dev/null
assert_eval_true "B3 非法间隔回退 30s" 'jq -e ".tcp_keep_alive == \"30s\"" "${tmpcfg}" >/dev/null'
rm -f "${tmpcfg}"

# --- B4/4.2：DNS 块（默认开启双源加密 DNS；dns_servers=off/none 整体关闭；
#   strategy 跟随 ip_version；非法 scheme 不渲染） ---
# 注意：env 赋值一律用“前缀+命令”形式，避免 eval 在顶层残留变量污染后续 render_config
# 1.14.0 起服务器数含 bootstrap（域名型 server 的 domain_resolver），independent_cache 已移除
assert_eval_true "B4 dns_servers 空 => 默认双源加密 DNS+bootstrap" '( render_dns_object ) | jq -e "(.dns.servers | length) == 3 and (.dns | has(\"independent_cache\") | not) and .dns.disable_cache == false and .dns.cache_capacity == 4096 and .dns.strategy == \"prefer_ipv4\""'
assert_eval_true "B4 双源显式渲染 dns 块(含 bootstrap)" '( dns_servers="https://1.1.1.1/dns-query,https://dns.google/resolve" render_dns_object ) | jq -e "(.dns.servers | length) == 3 and .dns.strategy == \"prefer_ipv4\""'
assert_eval_true "B4 ip_version=6 => strategy ipv4_and_ipv6" '( ip_version=6 render_dns_object ) | jq -e ".dns.strategy == \"ipv4_and_ipv6\""'
assert_eval_true "B4 dns_servers=off 整体关闭" '( dns_servers=off render_dns_object ) | jq -e "has(\"dns\") | not"'
assert_eval_true "B4 dns_servers=none 整体关闭" '( dns_servers=none render_dns_object ) | jq -e "has(\"dns\") | not"'
assert_eq "B4 非法 scheme 不渲染" "{}" "$(dns_servers='http://plain' render_dns_object)"
assert_eq "B4 混入非法源整体不渲染" "{}" "$(dns_servers='https://1.1.1.1/dns-query,ftp://bad' render_dns_object)"

# --- A2：并行端口探活（桩函数：存活端口=11111 置于最后；死端口 sleep 超时后失败） ---
assert_eval_true "A2 并行探活：存活端口在最后仍快速返回真（串行≈2s/并行≈1s）" '
  ( probe_tcp_port() { [ "$2" = "11111" ] && return 0; sleep "${3:-2}"; return 1; }
    iter_node_tags() { printf "pa\npb\npc\n"; }
    node_value() { case "$2" in protocol) printf "vless-reality"; return 0 ;; port) case "$1" in pa|pb) printf "22222" ;; pc) printf "11111" ;; *) return 1 ;; esac ;; *) return 1 ;; esac; }
    SBM_PROBE_TIMEOUT_S=1
    SECONDS=0
    if any_node_port_alive; then rc=0; else rc=1; fi
    printf "rc=%s wall=%s" "$rc" "$SECONDS" ) | grep -qxE "rc=0 wall=[01]"
'
assert_eval_false "A2 并行探活：全部死端口快速失败" '
  ( probe_tcp_port() { sleep "${3:-2}"; return 1; }
    iter_node_tags() { printf "pa\npb\n"; }
    node_value() { case "$2" in protocol) printf "vless-reality"; return 0 ;; port) printf "22222" ;; *) return 1 ;; esac; }
    SBM_PROBE_TIMEOUT_S=1
    if any_node_port_alive; then exit 0; else exit 1; fi )
'
assert_eval_true "A2 串行回退：存活端口返回真" '
  ( probe_tcp_port() { [ "$2" = "11111" ] && return 0; sleep "${3:-2}"; return 1; }
    iter_node_tags() { printf "pa\npb\n"; }
    node_value() { case "$2" in protocol) printf "vless-reality"; return 0 ;; port) case "$1" in pb) printf "11111" ;; *) printf "22222" ;; esac ;; *) return 1 ;; esac; }
    SBM_PROBE_PARALLEL=0
    if any_node_port_alive; then exit 0; else exit 1; fi )
'

# v1.2.4：CDN 模式采用 CF 证书方案（Full/Full-Strict 回源）——源站仅渲染 TLS WS inbound（wspt 统一单端口），
# 旧 ws_cdn_origin_port（明文 HTTP 回源）已废弃：即使节点记录里残留该字段也忽略，不再追加明文 inbound。
json_set_record "${NODES_FILE}" "nws-cdnextra" '{"protocol":"vless-ws-tls","name":"WS-CDNX","port":20844,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/x","certificate_mode":"custom","ws_mode":"cdn","cdn_port":443,"ws_cdn_origin_port":80}'
json_set_record "${SECRETS_FILE}" "nws-cdnextra" '{"uuid":"ux"}'
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag nws-cdnextra >"${tmpcfg}" 2>/dev/null
assert_eq "CDN 模式(CF证书)只渲染 1 条 TLS inbound" "1" "$(jq -s "length" "${tmpcfg}")"
assert_eval_true "CDN TLS inbound 带证书且监听 wspt" 'jq -s -e ".[0] | (.tls.enabled == true) and (.listen_port == 20844) and (.transport.path == \"/x\") and (.users[0].uuid == \"ux\")" "${tmpcfg}" >/dev/null'
rm -f "${tmpcfg}"

# v1.2.4：CDN 仅 TLS inbound 时不产生端口冲突问题（单端口即 wspt 本身）
json_set_record "${NODES_FILE}" "nws-cdnconflict" '{"protocol":"vless-ws-tls","name":"WS-CDC","port":20845,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/c","certificate_mode":"custom","ws_mode":"cdn","cdn_port":443,"ws_cdn_origin_port":20845}'
json_set_record "${SECRETS_FILE}" "nws-cdnconflict" '{"uuid":"uc"}'
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag nws-cdnconflict >"${tmpcfg}" 2>/dev/null
assert_eq "CDN 模式忽略残留 ws_cdn_origin_port 仍只 1 条 inbound" "1" "$(jq -s "length" "${tmpcfg}")"
rm -f "${tmpcfg}"

# v1.2.4：direct 模式不渲染 CDN 相关端口（回归，防直连被误加端口）
json_set_record "${NODES_FILE}" "nws-direct2" '{"protocol":"vless-ws-tls","name":"WS-DIR","port":20846,"preferred_domain":"cdn.example.com","host_domain":"ws.example.com","ws_path":"/d","certificate_mode":"custom","tcp_fast_open":true}'
json_set_record "${SECRETS_FILE}" "nws-direct2" '{"uuid":"ud"}'
tmpcfg="$(mktemp "${TEST_ROOT}/cfg.XXXXXX")"
render_inbound_for_tag nws-direct2 >"${tmpcfg}" 2>/dev/null
assert_eq "direct 模式只渲染 1 条 inbound" "1" "$(jq -s "length" "${tmpcfg}")"
rm -f "${tmpcfg}"

# v1.2.4：auto_add_vless_ws_tls 持久化 cdn_sni/CDN 端口，不再写 ws_cdn_origin_port
ENV_NAME=SmX ENV_UUID=33333333-4444-5555-6666-777777777777 ENV_WS_MODE=cdn ENV_CDN_HOST=cdn.example.com ENV_WS_CDN_ORIGIN_PORT=8088 auto_add_vless_ws_tls 20847
assert_eval_true "节点记录含 cdn_sni=cdn.example.com" 'jq -e "to_entries[] | select(.value.port == 20847 and .value.ws_mode == \"cdn\" and .value.cdn_sni == \"cdn.example.com\")" "${NODES_FILE}" >/dev/null'
assert_eval_false "节点记录不再含 ws_cdn_origin_port" 'jq -e "to_entries[] | select(.value.port == 20847) | .value.ws_cdn_origin_port" "${NODES_FILE}" >/dev/null'
assert_eq "退避 delay 第1次" "1" "$(argo_backoff_delay 1)"
assert_eq "退避 delay 第2次" "2" "$(argo_backoff_delay 2)"
assert_eq "退避 delay 第3次" "4" "$(argo_backoff_delay 3)"
assert_eq "退避 delay 上限30min" "1800" "$(argo_backoff_delay 20)"
assert_eq "restart_count 初始 0" "0" "$(read_restart_count ntest)"
assert_eval_true "bump_restart_count 自增" '( bump_restart_count ntest; [ "$(read_restart_count ntest)" = "1" ] )'
assert_eval_true "reset_restart_count 清零" '( reset_restart_count ntest; [ "$(read_restart_count ntest)" = "0" ] )'
rm -f "${RUNTIME_DIR}/ntest.restart_count"

# S1：端口探活纯探测函数（本机未监听某高端口 -> 失败）
assert_eval_false "probe_tcp_port 未监听端口失败" 'probe_tcp_port 127.0.0.1 65123 1'

# P2：TCP 可探活协议分类（hy2/tuic 纯 UDP 排除，避免 watchdog 误判假死）
assert_eval_true "P2 tcp_probeable_protocol reality" 'tcp_probeable_protocol vless-reality'
assert_eval_true "P2 tcp_probeable_protocol xudp" 'tcp_probeable_protocol vless-xudp'
assert_eval_true "P2 tcp_probeable_protocol argo" 'tcp_probeable_protocol vless-argo'
assert_eval_false "P2 tcp_probeable_protocol hy2" 'tcp_probeable_protocol hy2'
assert_eval_false "P2 tcp_probeable_protocol tuic" 'tcp_probeable_protocol tuic'
assert_eval_false "P2 tcp_probeable_protocol 未知" 'tcp_probeable_protocol unknown'

# P3：就绪自检核心 await_tcp_ports（python3 起真实监听；缺失则跳过）
if command_exists python3; then
  python3 - <<'PY' &
import socket, time, sys
socks = []
for port in (65124, 65125):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port))
    s.listen(1)
    socks.append(s)
time.sleep(30)
PY
  _lp=$!
  sleep 1
  assert_eval_true "P3 await_tcp_ports 监听中返回 0" 'await_tcp_ports 127.0.0.1 "65124 65125" 2'
  assert_eval_false "P3 await_tcp_ports 未监听端口返回 1" 'await_tcp_ports 127.0.0.1 "65126" 1'
  assert_eval_true "P3 await_tcp_ports 空端口列表返回 0" 'await_tcp_ports 127.0.0.1 "" 1'
  kill "${_lp}" 2>/dev/null || true
else
  printf '[提示] 无 python3，跳过 P3 监听探活断言\n' >&2
fi

# P5：GOGC 开关 / 网络调优固定参数（对齐 jyucoeng bbr.sh，无测速环节）
assert_eval_false "go_gc 默认不启用" 'go_gc_requested'
assert_eval_true "go_gc=off 启用" '( go_gc=off; go_gc_requested )'
assert_eval_true "net_tune 默认启用" 'net_tune_requested'
assert_eval_false "net_tune=0 关闭" '( net_tune=0; net_tune_requested )'
assert_eval_true "net_tune=1 启用" '( net_tune=1; net_tune_requested )'
assert_eq "fq quantum 默认 18028" "18028" "$(
  unset net_tune_fq_quantum
  net_tune_values
  printf '%s' "${NET_TUNE_FQ_QUANTUM}"
)"
assert_eq "fq initial_quantum 默认 90140" "90140" "$(
  unset net_tune_fq_initial_quantum
  net_tune_values
  printf '%s' "${NET_TUNE_FQ_INITIAL_QUANTUM}"
)"
assert_eq "tcp_rmem 上限默认 32MB" "33554432" "$(
  unset net_tune_tcp_rmem_max
  net_tune_values
  printf '%s' "${NET_TUNE_TCP_RMEM_MAX}"
)"
assert_eq "tcp_wmem 上限默认 32MB" "33554432" "$(
  unset net_tune_tcp_wmem_max
  net_tune_values
  printf '%s' "${NET_TUNE_TCP_WMEM_MAX}"
)"
assert_eq "tcp_limit_output 默认 4MB" "4194304" "$(
  unset net_tune_tcp_limit_output_bytes
  net_tune_values
  printf '%s' "${NET_TUNE_TCP_LIMIT_OUTPUT_BYTES}"
)"
assert_eq "fq quantum 可覆写" "20000" "$(
  net_tune_fq_quantum=20000
  net_tune_values
  printf '%s' "${NET_TUNE_FQ_QUANTUM}"
)"
assert_eq "fq quantum 非法值回退默认" "18028" "$(
  net_tune_fq_quantum=abc
  net_tune_values
  printf '%s' "${NET_TUNE_FQ_QUANTUM}"
)"
assert_eq "net_tune_mtu 合法值" "1492" "$(
  net_tune_mtu=1492
  printf '%s' "$(net_tune_mtu)"
)"
assert_eq "net_tune_mtu 非法值不设置" "" "$(
  net_tune_mtu=80
  printf '%s' "$(net_tune_mtu)"
)"
assert_eval_true "net_tune 测试模式跳过真实 sysctl/tc" 'apply_network_tune'
assert_eval_true "watchdog fq 补齐在测试模式无副作用" 'reapply_net_tune_qdisc'

# --- 端到端前置：清空状态 ---
wipe_records
assert_eq "端到端前置清空" "0" "$(jq length "${NODES_FILE}")"

# ---------------------------------------------------------------------------
# 一键安装（auto_install）端到端模拟：stub sing-box 二进制，覆盖 6 种协议
# ---------------------------------------------------------------------------
STUB_BIN="${TEST_ROOT}/bin"
mkdir -p "${STUB_BIN}"
cat >"${STUB_BIN}/sing-box" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
version) echo "sing-box version 1.14.0" ;;
check) exit 0 ;;
run) sleep 300 ;;
generate)
  shift
  if [ "${1:-}" = "reality-keypair" ]; then
    printf 'PrivateKey: %s\n' "$(openssl rand -base64 32 | tr -d '\n')"
    printf 'PublicKey: %s\n' "$(openssl rand -base64 32 | tr -d '\n')"
    exit 0
  fi
  exit 1
  ;;
*) exit 0 ;;
esac
EOF
chmod 0755 "${STUB_BIN}/sing-box"
export SINGBOX_BIN="${STUB_BIN}/sing-box"

export vlrt=20831 wspt=20835 anypt=20834 tupt=20833 hypt=20832 socks5pt=20836
export name=HK uuid=11111111-2222-3333-4444-555555555555 passwd=testpw
export cdn_host=cdn.example.com ws_host=ws.example.com ws_path=/wspath
export vl_sni=www.apple.com tu_sni=tu.example.com any_sni=any.example.com hy_sni=hy.example.com
export up_mbps=100 down_mbps=300 socks5_username=u1 socks5_password=p1
export net_tune=1

assert_eval_true "一键安装 6 协议成功" '( auto_install ins )'
assert_eq "一键安装写入 6 个节点" "6" "$(jq length "${NODES_FILE}")"
assert_eq "config 生成 6 个 inbound" "6" "$(jq '.inbounds | length' "${CONFIG_FILE}")"
assert_eq "P2 一键安装 6 节点中 TCP 可探活数" "4" "$(tcp_probeable_node_count)"
assert_eval_true "Reality inbound 正确" 'jq -e ".inbounds[] | select(.type == \"vless\" and .tls.reality.enabled == true)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "TUIC inbound 正确" 'jq -e ".inbounds[] | select(.type == \"tuic\")" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "HY2 inbound 带宽生效" 'jq -e ".inbounds[] | select(.type == \"hysteria2\" and .up_mbps == 100)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "WS inbound 路径生效" 'jq -e ".inbounds[] | select(.transport.path == \"/wspath\")" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "SOCKS5 inbound 用户生效" 'jq -e ".inbounds[] | select(.type == \"socks\" and .users[0].username == \"u1\")" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "vless 使用指定 uuid" 'jq -e ".inbounds[].users[]? | select(.uuid == \"11111111-2222-3333-4444-555555555555\")" "${CONFIG_FILE}" >/dev/null'
assert_eq "config 日志级别默认 warn" "warn" "$(jq -r '.log.level' "${CONFIG_FILE}")"
# 1.1/1.2/4.1：cache_file 连接缓存、clash_api 可观测面（route.sniff 已于 sing-box 1.13 移除）
assert_eval_true "cache_file 连接缓存默认开启" 'jq -e ".experimental.cache_file.enabled == true and (.experimental.cache_file.path | endswith(\"cache.db\"))" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "clash_api 可观测面默认开启(127.0.0.1)" 'jq -e ".experimental.clash_api.external_controller | startswith(\"127.0.0.1:\")" "${CONFIG_FILE}" >/dev/null'
# route.sniff 在 sing-box 1.13 移除，v1.5.6 起不再渲染（渲染出来会被 1.13+ 的 check 直接拒绝）
assert_eval_true "route 不含已废弃的 sniff 块" 'jq -e "(.route | has(\"sniff\") | not)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "vless TFO 默认开" 'jq -e ".inbounds[] | select(.type == \"vless\" and .tcp_fast_open == true)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "anytls TFO 默认开" 'jq -e ".inbounds[] | select(.type == \"anytls\" and .tcp_fast_open == true)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "socks TFO 默认开" 'jq -e ".inbounds[] | select(.type == \"socks\" and .tcp_fast_open == true)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "WS inbound 全局带 0-RTT" 'jq -e ".inbounds[] | select(.transport.type? == \"ws\" and .transport.max_early_data == 2048 and .transport.early_data_header_name == \"Sec-WebSocket-Protocol\")" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "HY2 限速 100/300 写入" 'jq -e ".inbounds[] | select(.type == \"hysteria2\" and .up_mbps == 100 and .down_mbps == 300)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "TUIC inbound 不携带 0-RTT 字段" 'jq -e "[.inbounds[] | select(.type == \"tuic\") | has(\"zero_rtt_handshake\")] | all(. == false)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "socks inbound 默认 keepalive \"30s\"" 'jq -e ".inbounds[] | select(.type == \"socks\" and .tcp_keep_alive == \"30s\" and (has(\"tcp_keep_alive_interval\") | not))" "${CONFIG_FILE}" >/dev/null'
# stub 进程存活仅对"纯进程托管"环境有意义：systemd/openrc 下 sing-box 由系统管理器
# 托管且不写 PID 文件（GitHub 托管 runner 即 systemd 环境），断言按环境跳过。
if ! systemd_available && ! openrc_available; then
  _stub_pid="$(read_pid_file "${PID_FILE}" 2>/dev/null || true)"
  if [ -n "${_stub_pid}" ] && kill -0 "${_stub_pid}" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL (应为真): sing-box stub 已启动 (pid=%s)\n' "${_stub_pid:-<空>}" >&2
    printf '  PID_FILE=%s\n' "${PID_FILE}" >&2
    sed 's/^/  content: /' "${PID_FILE}" 2>/dev/null >&2 || true
    if [ -n "${_stub_pid}" ]; then
      ps -o pid,ppid,stat,comm,args -p "${_stub_pid}" 2>&1 | sed 's/^/  ps: /' >&2 || true
    fi
    pgrep -af "sing-box|sleep 300" 2>&1 | sed 's/^/  pgrep: /' >&2 || true
  fi
else
  printf '[提示] systemd/openrc 托管环境：跳过 stub 进程存活断言\n' >&2
fi

# P1：热重载语义。standalone 沙箱下 stub(脚本) 与 sing-box 二进制身份不匹配，
# 因此运行中路径验证"回退完整重启仍返回 0"；未运行路径验证"回退启动并写 PID"。
if ! systemd_available && ! openrc_available; then
  _p="$(read_pid_file "${PID_FILE}" 2>/dev/null || true)"
  if [ -n "${_p}" ] && kill -0 "${_p}" 2>/dev/null; then
    assert_eval_true "P1 running_singbox_pid 有运行实例时返回输出" 'running_singbox_pid >/dev/null'
    assert_eval_true "P1 运行中 reload_service 返回 0" 'reload_service'
    _p2="$(read_pid_file "${PID_FILE}" 2>/dev/null || true)"
    assert_eval_true "P1 回退重启后 PID 文件仍有有效实例" '[ -n "${_p2:-}" ] && kill -0 "${_p2}" 2>/dev/null'
  else
    printf '[提示] 无运行 stub，跳过 P1 运行态断言\n' >&2
  fi
  rm -f "${PID_FILE}"
  assert_eval_false "P1 无实例时 running_singbox_pid 为空" 'running_singbox_pid'
  assert_eval_true "P1 未运行时 reload_service 回退完整启动" '
    reload_service
    _p3="$(read_pid_file "${PID_FILE}" 2>/dev/null || true)"
    [ -n "${_p3}" ] && kill -0 "${_p3}" 2>/dev/null
  '
  kill_pid_file "${PID_FILE}" || true
else
  printf '[提示] systemd/openrc 托管环境：跳过 P1 热重载进程断言\n' >&2
fi

# S4：sing-box check 失败时拒写配置（fail-closed，保留旧配置）
cp "${CONFIG_FILE}" "${TEST_ROOT}/config.before"
assert_eval_false "check 失败 render_config 拒写" '( SINGBOX_BIN="/bin/false"; render_config )'
assert_eval_true "check 失败保留旧配置" 'cmp -s "${CONFIG_FILE}" "${TEST_ROOT}/config.before"'

# B4/4.2：DNS 块 e2e（默认 config 含双源加密 DNS；显式 dns_servers 渲染；off 关闭后还原）
assert_eval_true "默认 config 含双源加密 DNS 块+bootstrap" 'jq -e "(.dns.servers | length) == 3 and (.dns | has(\"independent_cache\") | not)" "${CONFIG_FILE}" >/dev/null'
assert_eval_true "DNS 显式单源渲染 dns 块(含 bootstrap)" 'dns_servers="https://1.1.1.1/dns-query" render_config; jq -e "(.dns.servers | length) == 2 and .dns.strategy == \"prefer_ipv4\"" "${CONFIG_FILE}" >/dev/null'
dns_servers="" render_config
assert_eval_true "DNS 关闭(off)后还原默认双源" 'dns_servers=off render_config; jq -e "has(\"dns\") | not" "${CONFIG_FILE}" >/dev/null'
dns_servers="" render_config

# sbm sub：base64 订阅输出（6 节点）
assert_eval_true "sub 输出非空 base64" 'c="$(sub_command)"; [ "${#c}" -gt 100 ] && [[ "${c}" =~ ^[A-Za-z0-9+/=]+$ ]]'
assert_eval_true "sub 解码后包含节点链接" 'c="$(sub_command)"; printf %s "${c}" | base64 -d | grep -q "vless://"'

# 重复 ins：端口已被现有节点占用，全部跳过 → added=0 退出码 1（子 shell 中运行以捕获 exit）
assert_eval_false "重复 ins 端口冲突时拒绝" '( auto_install ins )'

# rep：清空后按新端口重建（先 unset 其余协议端口）
unset wspt anypt tupt socks5pt
export vlrt=21831 hypt=21832
assert_eval_true "rep 重建成功" '( auto_install rep )'
assert_eq "rep 后只剩新节点" "2" "$(jq length "${NODES_FILE}")"
assert_eq "rep 后 config 为 2 个 inbound" "2" "$(jq '.inbounds | length' "${CONFIG_FILE}")"
assert_eq "P2 rep 后 TCP 可探活数（hy2 排除）" "1" "$(tcp_probeable_node_count)"

# P0 回归：rep 输入非法端口时先失败且不清空已有节点（预校验先于清空）
vlrt=99999
assert_eval_false "rep 非法端口预校验失败" '( auto_install rep )'
assert_eq "rep 预校验失败不清空节点" "2" "$(jq length "${NODES_FILE}")"
unset vlrt
vlrt=21831

# P0 回归：delall 清理证书与私钥文件
assert_eval_true "证书文件存在（hy2 自签）" '[ "$(find "${CERT_DIR}" -type f | wc -l)" -gt 0 ]'
assert_eval_true "delete_all_nodes 成功" '( delete_all_nodes )'
assert_eq "delall 后无残留证书" "0" "$(find "${CERT_DIR}" -type f | wc -l)"
assert_eq "P2 空节点后探活态为不适用(2)" "2" "$(singbox_probe_status 2>/dev/null && printf '0' || printf '%s' "$?")"

# 清理 stub 进程
kill_pid_file "${PID_FILE}" || true

# --- MTProxy 独立脚本（mtp.sh）纯函数验证 ---
# shellcheck source=../mtp.sh
export MTP_TEST_MODE=1
source "${ROOT_DIR}/mtp.sh"

# MTProxy 纯函数验证（generate_secret/random_domain/valid_port/mtp_tg_secret）不读写 /opt/mtproxy，
# 无需沙箱覆盖 MTP_WORKDIR。

assert_eval_true "generate_secret 输出 32 位 hex" 's="$(generate_secret)"; [[ "$s" =~ ^[0-9a-f]{32}$ ]]'
assert_eval_true "random_domain 命中内置列表" 'd="$(random_domain)"; printf "%s\n" "${MTP_FAKE_DOMAINS[@]}" | grep -qx "$d"'
assert_eq "valid_port 边界 65535" "0" "$(
  valid_port 65535
  echo $?
)"
assert_eval_false "valid_port 0 非法" 'valid_port 0'
assert_eval_false "valid_port 非数字非法" 'valid_port 12a'
assert_eq "env_port 合法透传" "20086" "$(env_port 20086)"
assert_eval_false "env_port 非法拒绝" 'env_port 0x1F'

# tg:// secret 编码（黄金样例：密钥 16 字节全零 + 域名 apple.com，参照上游算法）
# secret = 00000000000000000000000000000000, domain = apple.com
# FULL 原始字节 = ee + 16x00 + "apple.com"，base64 url-safe 无 padding
assert_eq "mtp_tg_secret 全零密钥 apple.com" "7gAAAAAAAAAAAAAAAAAAAABhcHBsZS5jb20" "$(mtp_tg_secret "00000000000000000000000000000000" "apple.com")"

# mtp_run_args：IP_MODE 决定监听地址（v4/v6/dual），安装与无服务管理器重启共用
assert_eq "mtp_run_args v4 模式" "simple-run -n 1.1.1.1 -t 30s -a 1mb -c 65535 -i only-ipv4 0.0.0.0:20086 eeabcd" "$(mtp_run_args 20086 eeabcd v4)"
assert_eq "mtp_run_args v6 模式" "simple-run -n 1.1.1.1 -t 30s -a 1mb -c 65535 -i only-ipv6 [::]:20086 eeabcd" "$(mtp_run_args 20086 eeabcd v6)"
assert_eq "mtp_run_args dual 模式" "simple-run -n 1.1.1.1 -t 30s -a 1mb -c 65535 -i prefer-ipv6 [::]:20086 eeabcd" "$(mtp_run_args 20086 eeabcd dual)"
assert_eval_true "mtp_run_args 空模式回退 v4" 'mtp_run_args 20086 eeabcd | grep -q "only-ipv4 0.0.0.0:20086"'

# 生成的 tg 链接可解码回原文：0xee + secret(16字节) + domain ascii
assert_eval_true "mtp_tg_secret 可解码回原文" 's="$(mtp_tg_secret "cafebabecafebabecafebabecafebabe" "www.apple.com")"; p="$(printf %s "$s" | sed "s/-/+/g;s/_/\//g")"; while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done; h="$(printf %s "$p" | base64 -d 2>/dev/null | od -A n -t x1 | tr -d " \n")"; [[ "$h" == "eecafebabecafebabecafebabecafebabe7777772e6170706c652e636f6d" ]]'

# --- v1.9.3：XUDP 默认安全层为 Reality ---
unset ENV_VX_SECURITY
ENV_NAME=Td ENV_UUID=99999999-8888-7777-6666-555555555555 ENV_VX_SNI=www.apple.com auto_add_vless_xudp 20841 >/dev/null
assert_eq "默认 XUDP 节点协议" "vless-xudp" "$(jq -r 'to_entries[] | select(.value.port == 20841) | .value.protocol' "${NODES_FILE}")"
assert_eq "默认 XUDP 使用 Reality SNI" "www.apple.com" "$(jq -r 'to_entries[] | select(.value.port == 20841) | .value.reality_server' "${NODES_FILE}")"
assert_eval_true "默认 XUDP 生成 Reality 公钥" 'jq -e "to_entries[] | select(.value.port == 20841) | .value.public_key | length > 0" "${NODES_FILE}" >/dev/null'
assert_eval_true "默认 XUDP 生成 Reality 私钥" 'jq -e "to_entries[] | select(.value.private_key != null and (.value.private_key | length) > 0)" "${SECRETS_FILE}" >/dev/null'

delete_all_nodes >/dev/null 2>&1 || true
rm -rf "${TEST_ROOT}"

echo
echo "冒烟测试结果：通过 ${PASS}，失败 ${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
  exit 1
fi
