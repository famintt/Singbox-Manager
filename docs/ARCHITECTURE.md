# 架构规划（v1.4.0 目标）

本仓库为 bash 编写的 sing-box / MTProxy 管理器。最近三个版本（v1.3.0~v1.3.2）已完成
热路径性能优化（env_var 纯 bash、node_meta 批量取字段、端口快照、url_encode_many 合并
jq fork）。性能空间收窄后，本轮聚焦架构：`common.sh`（1678 行 ×24 职责）与
`nodes.sh`（1782 行 ×8 职责）已成"上帝文件"，且存在分层反向依赖。

## 1. 职责分布现状

### 入口 / 独立脚本
| 文件 | 行数 | 职责 |
|---|---|---|
| sb.sh | 138 | 薄壳：全局常量 + source 模块 + `main` 命令分发 |
| mtp.sh | 479 | MTProxy 独立脚本（重写 `command_exists`/`download_file`/`require_root`） |
| install.sh | 156 | 安装器：下载 → SHA256 → 解包 → 安装 |
| scripts/watchdog.sh | 274 | 常驻看门狗，复用 lib |

### lib/common.sh（24 组职责混装）
日志输出、前置检查、下载校验、存储初始化、文件锁、JSON 底层、存储访问、
备份恢复、编码/校验、设置、公网 IP、ID 生成、证书材料、Argo 域名、重启计数、
端口探测、调优门控、内核调优、cloudflared 上游、PID 管理、日志轮转、
Go 内存、分享链接（L1545 调 `node_meta_array` → 反向依赖）。

### lib/nodes.sh（8 大块）
端口快照、证书导入/迁移/清理、证书选择交互、节点事务、渲染（render_config /
node_meta / render_inbound_for_tag）、Argo 进程、交互式添加（×7）、自动安装（auto_*）、
CRUD 清理、CLI 命令（print_node_list/sub_command/list_nodes/...）。

### lib/core.sh / menu.sh / ui.sh
- core.sh：服务识别、依赖安装、安装升级、服务单元、服务生命周期、顶层运维。
- menu.sh：交互总控。
- ui.sh：纯输入提示工具。

## 2. 问题诊断

- **P0 God File**：common.sh / nodes.sh 单文件职责过多。
- **P0 分层违规**：`common.sh:1545` build_share_link → nodes.sh 的 node_meta_array；
  `common.sh:107` handle_common_error → render_config/start_service；
  `declare -F` 运行时探测（invalidate_port_caches_if_defined）。
- **P1 同域分裂**：证书逻辑、Argo 逻辑分别散在 2~3 个文件。
- **P1 重复实现**：mtp.sh 重写 3 个函数；watchdog.sh 重复声明常量。
- **P2 耦合方式**：靠全局可变状态（has_systemd/has_openrc）+ 固定 source 顺序耦合。

## 3. 目标分层

```
工具层 env/io/fmt
  └── 存储层 storage/settings/network
        └── 领域层 cert/render/links/argo/tune
              └── 编排层 service/install
                    └── 表现层 menu/cli
```

### lib/ 模块与 source 顺序（唯一顺序清单）
1. `env.sh` —— 路径/服务常量、日志输出、前置检查、陷阱
2. `io.sh` —— 下载/校验、url 编码、ID 生成
3. `fmt.sh` —— 纯校验：IP/域名/主机名
4. `storage.sh` —— 目录权限、存储初始化、锁、JSON 读写、备份恢复、日志轮转
5. `settings.sh` —— 全局设置读写
6. `network.sh` —— 公网 IP、端口探测与快照
7. `cert.sh` —— 证书全部：材料生成/指纹/导入/迁移/交互/清理
8. `render.sh` —— 节点元数据 + inbound/config 渲染
9. `links.sh` —— 分享链接生成（依赖 render 的 node_meta_array）
10. `node-add.sh` —— 交互式添加七种节点
11. `node-auto.sh` —— 环境变量自动安装（auto_*）
12. `node-cmd.sh` —— CLI 命令（list/sub/del/show/restart 等）
13. `argo.sh` —— Argo/TryCloudflare 域名与隧道进程
14. `tune.sh` —— 内核调优（BBR、fq qdisc、固定 TCP 缓冲；参数对齐 jyucoeng bbr.sh，无测速）
15. `service.sh` —— 服务生命周期、systemd/openrc、PID、Go 内存
16. `install.sh` —— 安装升级、依赖、核心组件
17. `menu.sh` —— 交互菜单 + 输入提示工具
18. `cli.sh` —— 命令分发（sb.sh 的 main）

### 加载约定
- `SBM_MODULES` 有序数组定义在 env.sh，sb.sh 与 watchdog.sh 共用一套循环加载。
- 安装/打包脚本按 `lib/*.sh` 通配安装，不再维护模块清单。

## 4. 实施阶段

- **Phase 1 纯搬移**：函数原样搬入新模块，零行为变更；每步 bash -n + 冒烟全绿。
- **Phase 2 去全局耦合**：`has_systemd`/`has_openrc` 全局变量改为
  `systemd_available()` / `openrc_available()` 谓词；`detect_systemd` 不再写全局。
- **Phase 3 修复反向依赖 + 去重**：build_share_link 依赖 node_meta_array 上移至
  render 层 source 顺序；watchdog/install 统一模块加载与安装；mtp.sh 共享基础工具。
- **Phase 4 测试分层与门禁**：tests/smoke.sh 按模块分组；check-version.sh 增加
  模块清单与 source 顺序校验。

### 实施记录（v1.4.0 过程）
- Phase 1 完成：197 个函数原样搬入 19 个模块（纯搬移，逐字验证），旧
  common.sh / nodes.sh / core.sh / ui.sh 删除；sb.sh / watchdog.sh 改用
  `sbm_load_all` 统一加载；install.sh / lib/install.sh / build-release-bundle.sh
  改为 `lib/*.sh` 通配安装 / 校验。bash -n 全绿，冒烟 209 断言全绿。
- Phase 2 完成：has_systemd / has_openrc 全局变量删除，改为
  `systemd_available()` / `openrc_available()` 谓词；detect_systemd 移除，
  相关调用点全部迁移（lib/service.sh、lib/install.sh、lib/node-cmd.sh、
  lib/menu.sh、lib/node-auto.sh、scripts/watchdog.sh、tests/smoke.sh）。
- Phase 3 完成：`render links` 顺序消解 build_share_link 反向依赖；
  handle_common_error→render_config/start_service 依赖由全量加载保证；
  watchdog/install 已统一模块加载与安装。
- **mtp.sh 决策（Phase 3）**：保持单文件自包含，不共享 lib 基础工具。
  理由：头部注释明示 "与 Singbox Manager 完全分离"，要求单文件可移植
  （可脱离 lib 独立部署）；重复面仅 command_exists / download_file /
  require_root 三个数行级工具，引入 lib 耦合的收益小于可移植性损失。

## 5. 验收门禁

- 每阶段：全量 `bash -n` + tests/smoke.sh（209 断言）全绿 + CI 通过。
- 质量红线：单文件 ≤ 600 行、模块职责单一、禁止反向依赖。
- 版本：整体升至 v1.4.0，sb.sh / mtp.sh / install.sh 版本一致由 check-version.sh 兜底。