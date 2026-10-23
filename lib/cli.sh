#!/usr/bin/env bash
set -eEuo pipefail

umask 077

# 命令分发：由 sb.sh 在全部模块加载后调用 main "$@"
main() {
  local action="${1:-}"
  case "${action}" in
  "")
    require_root
    ensure_menu_tty
    # 菜单内任何非零返回（如 stdin EOF）都以干净状态退出，不触发 ERR trap；
    # 但初始化/终端异常要让用户看见原因，而不是静默回到 shell。
    if ! main_menu; then
      print_err "菜单启动失败（请检查 /usr/local/etc/singbox-manager 权限与磁盘空间）。"
      exit 1
    fi
    ;;
  menu)
    require_root
    ensure_menu_tty
    if ! main_menu; then
      print_err "菜单启动失败（请检查 /usr/local/etc/singbox-manager 权限与磁盘空间）。"
      exit 1
    fi
    ;;
  rep | ins)
    require_root
    auto_install "${action}"
    ;;
  list)
    require_root
    init_storage
    echo
    print_node_list
    echo
    ;;
  add)
    require_root
    cli_add "${@:2}"
    ;;
  sni)
    require_root
    cli_sni
    ;;
  status)
    require_root
    cli_status
    ;;
  doctor)
    require_root
    cli_doctor || exit 1
    ;;
  fw)
    require_root
    cli_fw "${@:2}"
    ;;
  logs)
    require_root
    init_storage
    if [ -s "${BASE_DIR}/logs/sing-box.log" ]; then
      tail -n "${2:-100}" "${BASE_DIR}/logs/sing-box.log"
    else
      print_warn "日志不存在：${BASE_DIR}/logs/sing-box.log"
    fi
    ;;
  log_stop)
    require_root
    init_storage
    if [ -s "${BASE_DIR}/logs/stop_reason.log" ]; then
      cat "${BASE_DIR}/logs/stop_reason.log"
    else
      print_warn "没有停止原因日志。"
    fi
    ;;
  sub)
    require_root
    case "${2:-}" in
    url | link) sub_url ;;
    start) sub_start ;;
    stop) sub_stop ;;
    status) sub_status ;;
    *) sub_command "${2:-}" ;;
    esac
    ;;
  delall)
    require_root
    delete_all_nodes
    ;;
  restore)
    require_root
    init_storage
    acquire_lock
    if restore_latest_backup; then
      reconcile_state || true
      render_config
      start_service
      print_ok "已恢复并重启服务。"
    fi
    release_lock
    ;;
  un)
    require_root
    if uninstall_project; then
      exit 0
    fi
    exit 1
    ;;
  -h | --help | help)
    print_cli_usage
    ;;
  *)
    print_warn "未知命令：${action}"
    print_cli_usage
    exit 1
    ;;
  esac
}
