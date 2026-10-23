#!/usr/bin/env bash
set -eEuo pipefail

umask 077

menu_add_node() {
  echo
  echo "1. VLESS + Reality"
  echo "2. VLESS + WS + TLS"
  echo "3. AnyTLS"
  echo "4. VLESS + Argo"
  echo "5. TUIC v5"
  echo "6. Hysteria2"
  echo "7. SOCKS5"
  echo "0. 返回"
  echo
  read -r -p "请选择: " choice || return 0
  case "${choice}" in
  1) add_vless_reality ;;
  2) add_vless_ws_tls ;;
  3) add_anytls ;;
  4) add_vless_argo ;;
  5) add_tuic_v5 ;;
  6) add_hy2 ;;
  7) add_socks5 ;;
  0) return 0 ;;
  *) print_warn "无效的选择。" ;;
  esac
}

print_header() {
  clear 2>/dev/null || true
  echo "=============================================="
  echo "${PROJECT_NAME} ${SCRIPT_VERSION}"
  echo "=============================================="
  echo
}

ipver_display() {
  case "$(get_setting "ip_version" "4")" in
  6 | v6) printf 'v6' ;;
  auto) printf 'auto（v4 优先）' ;;
  *) printf 'v4（默认）' ;;
  esac
}

settings_menu() {
  local choice value
  while true; do
    print_header
    echo "全局设置"
    echo
    echo "1. 分享链接默认 IP 版本   当前：$(ipver_display)"
    echo "0. 返回"
    echo
    read -r -p "请选择: " choice || return 0
    case "${choice}" in
    1)
      read -r -p "IP 版本 (4/v6/auto) [4]: " value || continue
      value="$(normalize_input "${value:-4}")"
      case "${value,,}" in
      4 | v4) set_setting "ip_version" "4" ;;
      6 | v6) set_setting "ip_version" "6" ;;
      auto) set_setting "ip_version" "auto" ;;
      *) print_warn "无效的值：${value}（可选 4 / v6 / auto）" ;;
      esac
      ;;
    0) return 0 ;;
    *)
      print_warn "无效的选择。"
      sleep 1
      ;;
    esac
  done
}

pause_menu() {
  read -r -p "按回车继续..." _ || true
}

# 交互输入统一落到控制终端：sshd 在 `ssh host sbm`、部分面板/脚本包装器下
# 会把 stdin 接成管道，read 立即 EOF，菜单一闪而过（长期运行后误以为"sbm 坏了"）。
# 仅当 stdout 仍是终端且 /dev/tty 可读写时才切换，管道/CI 场景保持原样。
ensure_menu_tty() {
  # 仅 stdin 是字符设备（典型为 /dev/null）且 stdout 仍是终端时，才改接控制终端；
  # stdin 是管道/FIFO（printf ... | sbm、脚本喂输入）或普通文件时保持原样，
  # 绝不能把用户已重定向的输入吞掉。
  if [ ! -t 0 ] && [ -c /dev/stdin ] && [ -t 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
    exec </dev/tty
  fi
  return 0
}

main_menu() {
  if ! init_storage; then
    print_warn "存储目录初始化失败，菜单仍会显示；涉及写入的操作可能失败（请检查磁盘/权限）。"
  fi
  while true; do
    print_header
    echo "1. 安装/更新核心组件"
    echo "2. 添加节点"
    echo "3. 查看节点"
    echo "4. 删除节点"
    echo "5. 重启服务"
    echo "6. 查看状态"
    echo "7. 更新项目文件"
    echo "8. BBR+FQ+缓存设置"
    echo "9. 全局设置"
    echo "10. 卸载"
    echo "0. 退出"
    echo
    choice=""
    read -r -p "请选择: " choice || true
    if [ -z "${choice}" ] && [ ! -t 0 ]; then
      return 0
    fi
    case "${choice}" in
    1)
      install_core
      pause_menu
      ;;
    2)
      menu_add_node
      pause_menu
      ;;
    3)
      list_nodes
      pause_menu
      ;;
    4)
      delete_node
      pause_menu
      ;;
    5)
      restart_stack
      pause_menu
      ;;
    6)
      show_status
      pause_menu
      ;;
    7)
      update_script || print_warn "更新未完成，已保留当前可用版本。"
      pause_menu
      ;;
    8)
      net_tune_menu
      ;;
    9)
      settings_menu
      ;;
    10)
      if uninstall_project; then
        exit 0
      fi
      pause_menu
      ;;
    0) exit 0 ;;
    *)
      print_warn "无效的选择。"
      sleep 1
      ;;
    esac
  done
}

print_cli_usage() {
  cat <<EOF
用法: sbm [命令]

命令:
  (无参数)   打开交互式主菜单
  menu       强制打开交互式主菜单（等价无参数）
  rep        覆盖式一键安装：备份后清空已有节点，按环境变量重建并启动
  ins        追加式一键安装：备份后保留已有节点，按环境变量追加节点并启动
  list       查看节点与分享链接
  add         按参数添加单个节点（sbm add --help）
  sni         检测并推荐 Reality SNI
  status      查看服务/节点状态
  doctor      配置与服务健康检查
  fw          防火墙查看/放行/关闭
  sub [文件] 输出 base64 订阅内容（不带文件参数打印到 stdout，带则写入文件）
  sub url    启动订阅 HTTP 服务+临时隧道并输出订阅链接
  sub start  启动订阅服务（配合环境变量 sub=1 使用）
  sub stop   停止订阅 HTTP/隧道进程
  sub status 查看订阅服务状态
  delall     删除全部节点（含证书）并重启服务
  restore    从最近一次状态备份恢复节点
  un         卸载本项目

环境变量一键安装示例（配合网页命令生成器使用）:
  vlrt=2083 hypt=2082 name='HK' bash sb.sh rep
  支持的环境变量见 README「环境变量一键安装」章节。

MTProxy（Go mtg）为独立脚本，不依赖本命令：
  mtpt=端口 bash <(curl -fsSL https://github.com/famintt/Singbox-Manager/releases/latest/download/install.sh)
  或已安装时直接: mtpt=端口 mtp
EOF
}

prompt_with_default() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "${prompt} [${default}]: " value
  value="$(normalize_input "${value:-$default}")"
  printf '%s' "${value:-$default}"
}

prompt_nonempty() {
  local prompt="$1"
  local value=""
  while [ -z "$value" ]; do
    read -r -p "${prompt}: " value
    value="$(normalize_input "$value")"
  done
  printf '%s' "$value"
}

prompt_optional_value() {
  local prompt="$1"
  local value
  read -r -p "${prompt}: " value
  normalize_input "$value"
}

confirm_yes() {
  local prompt="$1"
  local answer
  read -r -p "${prompt} [y/N]: " answer
  answer="$(normalize_input "$answer")"
  [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss]|是)$ ]]
}

prompt_choice() {
  local prompt="$1"
  local default="$2"
  local value
  read -r -p "${prompt} [${default}]: " value
  value="$(normalize_input "${value:-$default}")"
  printf '%s' "${value,,}"
}

prompt_positive_integer() {
  local prompt="$1"
  local default="$2"
  local value
  while true; do
    value="$(prompt_with_default "${prompt}" "${default}")"
    if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -gt 0 ]; then
      printf '%s' "$value"
      return 0
    fi
    print_warn "${prompt} 必须是大于 0 的整数。"
  done
}

prompt_safe_domain() {
  local prompt="$1"
  local default="$2"
  local value
  while true; do
    value="$(prompt_with_default "${prompt}" "${default}")"
    if is_safe_domain "${value}"; then
      printf '%s' "${value}"
      return 0
    fi
    print_warn "域名格式无效：${value}（仅允许字母数字与 . _ : -）"
  done
}

prompt_cdn_domain() {
  local value
  while true; do
    value="$(prompt_safe_domain "连接地址（优选 IP/域名）" "${DEFAULT_CDN_DOMAIN}")"
    if [ "${value}" != "${DEFAULT_CDN_DOMAIN}" ]; then
      printf '%s' "${value}"
      return 0
    fi
    print_warn "内置优选域名 ${DEFAULT_CDN_DOMAIN} 仅在该域名已接入本机前置 CDN 时可用；没有自备域名请填优选 IP 或你自己的域名。"
    if confirm_yes "确认仍使用 ${DEFAULT_CDN_DOMAIN}？"; then
      printf '%s' "${value}"
      return 0
    fi
  done
}

prompt_port() {
  local default="$1"
  local port
  while true; do
    port="$(prompt_with_default "端口" "$default")"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
      print_warn "端口无效：${port}"
      continue
    fi
    if ! port_available "$port"; then
      print_warn "端口 ${port} 已被占用。"
      continue
    fi
    printf '%s' "$port"
    return 0
  done
}
