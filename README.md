# Singbox Manager

**在线一键命令生成器：<https://sbm.1733.dpdns.org>**（即本仓库 `interface/worker.js` 的部署，可自行用 Pages/Workers 托管）—— 填协议端口即可生成下面的环境变量一键安装命令。

面向常用 `sing-box` 场景的管理脚本：安装核心、添加节点、生成分享链接、自动保活一体化，支持 VLESS-Reality / VLESS-WS-TLS / AnyTLS / VLESS-Argo / TUIC v5 / Hysteria2 / SOCKS5；并附带独立的 **MTProxy（Go mtg）** 管理脚本。

## 快速安装

```bash
bash <(curl -fsSL https://github.com/famintt/sbm/releases/latest/download/install.sh)
sbm          # 打开交互菜单
```

无 curl 的精简系统（如纯净 Alpine）可用 wget，或让命令自动回退：

```bash
bash <(wget -qO- https://github.com/famintt/sbm/releases/latest/download/install.sh)
bash <(curl -fsSL https://github.com/famintt/sbm/releases/latest/download/install.sh 2>/dev/null || wget -qO- https://github.com/famintt/sbm/releases/latest/download/install.sh)
```

## 环境变量一键安装

端口变量启用对应协议，其余可选；`rep` 清空重建（适合首次/重置），`ins` 保留已有节点追加：

```bash
vlrt=2083 hypt=2082 name='HK' bash <(curl -fsSL https://github.com/famintt/sbm/releases/latest/download/install.sh)
vlrt=2083 hypt=2082 name='HK' sbm rep      # 已安装时
```

| 变量 | 说明 | 默认 |
|---|---|---|
| `vlrt` `wspt` `tupt` `anypt` `hypt` `socks5pt` | 各协议端口，填了即启用 | 不启用 |
| `argo=vlpt` `argo_pt` | 启用 VLESS-Argo；本地端口 | 8001 |
| `agn` `agk` | Argo 固定隧道域名 + Token（临时隧道留空） | 临时隧道 |
| `cdn_host` | CDN 中转连接地址（优选 IP/域名），WS-TLS CDN 使用（Argo 也可回退使用） | `saas.sin.fan` |
| `argo_cdn_host` | **Argo 专属优选域名**，独立于 `cdn_host`（v0.3.3；留空回退 `cdn_host`） | `cdn_host` |
| `argo_cdn_port` | **Argo CDN 转发端口**（如 443/2053/2083/2087/2096/8443），独立于 `cdn_port` | `443` |
| `ws_mode` | WS-TLS 连接方式：`cdn`（经 `cdn_host` 中转）或 `direct` 直连服务器 IP（脚本后端保留，命令行可设）。注意：网页生成器填写 `wspt` 后**强制下发** `ws_mode=cdn` 与 `cert=custom`（未粘贴证书内容时后端回退自签，仍按 Full 模式使用） | `direct` |
| `cdn_port` | WS-TLS `cdn` 模式使用的 CDN 转发端口（如 443/8443/2053/2096） | `443` |
| `ws_cdn_cf_host` | ws_cdn 共享 CDN 连接地址（专用前缀，覆盖 `cdn_host`） | `cdn_host` |
| `ws_cdn_cf_pt` | ws_cdn 共享 CDN 转发端口（专用前缀，覆盖 `cdn_port`） | `cdn_port` |
| `ws_cdn_sni` | **必填**：ws_cdn 回源域名 = 客户端 SNI/Host（默认同连接地址，可单独设真实回源域名） | 连接地址 |
| `cert` | 源站证书方式：`self`（自签 99 年，配 Cloudflare SSL=Full）/ `custom`（Cloudflare Origin CA 或有效证书，配 SSL=Full(Strict)） | `self` |
| `cert_b64` `key_b64` | `cert=custom` 时直接粘贴的源站 PEM 证书/私钥内容（base64，界面自动编码；服务器解码后写入托管证书目录，无需先上传文件） | 无 |
| `cert_path` `key_path` | `cert=custom` 时源站证书/私钥文件路径（兼容旧方式：先上传到服务器；`cert_b64`/`key_b64` 优先） | 自签路径 |
| `ws_cdn_vless_cf_host/ws_cdn_vless_cf_pt/ws_cdn_vless_sni` | VLESS 专属覆盖（优先于 `ws_cdn_*` 共享值） | 共享值 |
| `confirm_default_cdn=1` | 确知并接受默认优选域名时消除对应警告 | 未设置 |
| `uuid` | VLESS/TUIC 共用 UUID | 自动生成 |
| `passwd` | AnyTLS/HY2/TUIC 密码 | 自动生成 |
| `name` | 节点名前缀（生成 `HK-Reality` 等） | 内置默认名 |
| `vl_sni` `ws_host` `tu_sni` `any_sni` `hy_sni` | 各协议 SNI（ws_host 仅供命令行 `ws_mode=direct` 直连用；界面 WS 已仅 CDN，SNI/Host 用 `ws_cdn_sni`） | `www.apple.com` |
| `ws_path` | WS 路径 | 随机 |
| `up_mbps` `down_mbps` | HY2 带宽 | 200 |
| `socks5_username` `socks5_password` | SOCKS5 账号 | user / 随机 |
| `net_tune` | 网络内核调优（BBR + fq + 固定 TCP 缓冲，参数对齐 jyucoeng/singbox-tools `bbr.sh`；`0/off/no` 关闭） | 开启 |
| `net_tune_mtu` | 可选：显式设置默认网卡 MTU（576-9000）；不填表示保持系统现值（推荐，避免破坏 PPPoE/隧道） | 不修改 |
| `net_tune_fq_quantum` / `net_tune_fq_initial_quantum` | fq qdisc 参数（默认 18028 / 90140） | jyucoeng 默认值 |
| `net_tune_tcp_rmem_max` / `net_tune_tcp_wmem_max` | TCP 自动调优上限（默认 32MB） | 33554432 |
| `net_tune_tcp_limit_output_bytes` | 单次发送配额（默认 4MB） | 4194304 |
| `sub` | `sub=1` 启用订阅生成；配合 `sub_mode=worker` 上报到 sub-worker | 关闭 |
| `sub_mode` | 订阅模式：`worker`（固定 Worker，推荐）或 `temp`（临时隧道，兼容旧用法） | `temp` |
| `sub_domain` | sub-worker 域名，如 `https://sbsub.example.com` | 空 |
| `sub_token` | sub-worker 的 `TOKEN`，上报和读取共用 | 空 |
| `server_ip` | 分享链接使用的服务器 IP；默认自动探测 | 自动 |
| `direct_host` | 直连协议链接显示的域名，优先于 server_ip/public_ip | 空 |
| `reality_private` / `reality_public` | 固定 Reality 密钥对（必须成对提供） | 自动生成 |
| `socks5_wl_flag` / `socks5_ips` | Socks5 源地址白名单（iptables；逗号分隔 IP/CIDR） | 关闭 / 空 |
| `debug_flag` | 调试日志开关（1=debug） | 0 |
| `sub_machine` | Worker 中的机器 slug，默认取 `name` 或主机名并转小写 | 自动 |
| `sub_port` | 临时订阅 HTTP 服务监听端口（仅 `127.0.0.1`，不占公网端口） | `18080` |

## WS-TLS + CDN（CF 证书方案，v1.2.4）

v1.2.4 起 WS-TLS 的 CDN 中转采用 **Cloudflare 证书方案**：源站只有一个 TLS WS inbound（端口 `wspt`），即**统一的回源端口**，不再生成明文 HTTP 回源 inbound、不再依赖 nginx。Cloudflare 边缘 SSL 模式设为 **Full** 或 **Full(Strict)**，以 HTTPS 回源到该 TLS 端口。

- **Full（推荐，默认 `cert=self`）**：源站用内置自签证书（99 年）即可，Cloudflare 边缘→源站全程加密但**不校验**源站证书，无需任何额外文件。
- **Full(Strict)**：Cloudflare 会校验源站证书，需选 `cert=custom`。在 DNS 控制台 SSL/TLS → Origin Server → Create Certificate 生成 **Cloudflare Origin CA 证书**，把证书与私钥全文**直接粘贴**到生成器（自动以 base64 传服务器解码存储），无需先上传文件。

端口关系：客户端连 `cdn_host:cdn_port`（443/2053/2083/2087/2096/8443），SNI/Host 用**必填**的 `ws_cdn_sni`；Cloudflare 收到回源域名后按 SSL 模式把请求以 HTTPS 转发到源站。回源默认目标是 **443**，故建议直接设 `wspt=443`（此时 `wspt` 即统一端口）；若 `wspt` 用其他值，需在 Cloudflare 控制台为该域名添加 **Origin Rule**，把 443 改写为你的 `wspt`。

```bash
# 示例：CDN 中转，Full 模式（自签证书，零额外准备）
wspt=443 cdn_host=你的优选域名 cdn_port=443 ws_cdn_sni=ws.example.com name='HK' bash <(curl -fsSL https://github.com/famintt/sbm/releases/latest/download/install.sh)

# 示例：CDN 中转，Full(Strict)（Cloudflare Origin CA 证书，PEM 内容 base64 后直接传，界面自动处理）
# cert_b64 与 key_b64 用界面生成器粘贴证书/私钥内容即可，无需手写 base64
wspt=443 cdn_host=你的优选域名 ws_cdn_sni=ws.example.com cert=custom cert_b64=... key_b64=... name='HK' bash <(curl -fsSL https://github.com/famintt/sbm/releases/latest/download/install.sh)
```

> 兼容性：v1.2.3 遗留的 `ws_cdn_origin_port`（明文 HTTP 回源 inbound）已废弃，升级后源站自动只保留 TLS inbound；已部署的 Cloudflare SSL 模式请从 **Flexible** 改为 Full/Full(Strict)，否则回源到 80 将无法工作。

## 命令行

```text
sbm           交互菜单（安装/添加/查看/删除/重启/状态/更新/卸载/全局设置）
sbm rep|ins   环境变量一键安装（自动快照备份；rep 端口非法时直接拒绝，不动现有数据）
sbm list      查看节点与分享链接
sbm sub [文件] 输出 base64 订阅（不带参数打印到 stdout，带文件参数写入文件）
sbm sub url   启动订阅 HTTP 服务+临时隧道并输出订阅链接
sbm sub start|stop|status 管理订阅服务
sbm delall    删除全部节点（含证书，自动快照）
sbm restore   从最近一次快照恢复节点
sbm un        卸载
```

分享链接默认使用 IPv4；菜单「9. 全局设置」可切换 `v4 / v6 / auto`（仅双栈机器需要调整）。

## 订阅设置（v1.9.0）

推荐使用固定 Worker 订阅：管理器生成全部节点链接的 base64，上报到 [sub-worker](https://github.com/famintt/sub-worker)，客户端使用固定域名；服务器重启后订阅 URL 不变。

```bash
sub=1 \
sub_mode=worker \
sub_domain='https://sbsub.example.com' \
sub_token='<sub-worker 的 TOKEN>' \
bash <(curl -fsSL .../install.sh) rep
```

- `sub_domain` 填 Worker 的自定义域名或 `*.workers.dev` 地址；
- `sub_token` 只填原始值，不要带引号或 `TOKEN=`；
- `sub_machine` 可选，默认用 `name` 或主机名生成小写 slug；
- 安装完成后会输出：

```text
https://sbsub.example.com/sub/<machine>/<TOKEN>
```

- 也支持全量合并地址：`https://sbsub.example.com/sub/<TOKEN>`（不带 `/all`）；
- 相关命令：`sbm sub url`、`sbm sub status`、`sbm sub stop`；
- Worker 不可达时不会影响 sing-box 节点安装，只打印订阅上报失败警告。

兼容旧的临时隧道模式：不设置 `sub_mode=worker` 时，`sub=1` 仍会在 `127.0.0.1:18080` 启动静态订阅服务并通过第二个临时 cloudflared 暴露；该域名重启会变化，仅适合测试。

## MTProxy（Go mtg，独立脚本）

与 `sb.sh` **完全分离**的 MTProxy 管理器（工作目录 `/opt/mtproxy`，systemd 服务 `mtp`，二进制 `mtg-go` 来自 jyucoeng/singbox-tools 官方 Go 构建镜像）。单用户模式，端口由你指定，伪装域名 / 通信密钥 / 监听模式（默认 v4）由服务器自动随机生成：

```bash
# 首次安装（配合网页生成器，端口即 mtpt；伪装域、密钥、模式全部随机）
mtpt=20086 bash <(curl -fsSL https://github.com/famintt/sbm/releases/latest/download/install.sh)

# 已安装时直接管理
mtpt=20086 mtp            # 安装/更新（改端口自动重装）
mtp info                  # 查看已安装服务连接信息（tg://proxy 链接）
mtp restart               # 重启 MTProxy 服务
mtp un                    # 全量卸载并清理（服务/二进制/配置/日志）
```

| 变量 | 说明 | 默认 |
|---|---|---|
| `mtpt` | 监听端口（必填） | 无 |
| `mtp_domain` | 伪装域名 | 内置列表随机（apple/microsoft/amazon/bing/mozilla） |
| `mtp_secret` | 通信密钥（32 位 hex） | 随机生成 |
| `mtp_ip_mode` | 监听模式 `v4` / `v6` / `dual` | `v4` |

MTProxy 与 sing-box 互不依赖：卸载其中一方不影响另一方；`sbm un` 只卸载 sing-box 相关，MTProxy 需单独 `mtp un`。

## 项目结构

```text
sb.sh / mtp.sh / install.sh / lib/*.sh / metadata/upstream.env
scripts/watchdog.sh          保活（systemd timer 或 cron，每分钟）
scripts/build-release-bundle.sh
interface/                   网页命令生成器（Pages / Workers 部署）
tests/smoke.sh               冒烟测试
```

## 说明

- 稳健性：`rep`/`ins`/`delall` 前自动快照到 `backups/`（保留 10 份，目录含唯一后缀，且一并备份自签证书/私钥），`sbm restore` 一键回滚；`rep` 在"清空已有节点后"至"提交前"任一环节失败都会自动恢复到安装前状态；watchdog 每轮自动对账清理孤儿记录；Argo 临时域名经公共 DNS（DoH，A/AAAA 任一可解析即通过）发布确认后才写入节点；Argo Token 经环境变量传递，不出现在进程命令行
- 进程识别：service/watchdog 的存活判断与清理全部做 PID→预期二进制的身份校验（`/proc` 可用时），PID 被复用不会导致漏重启或误杀；临时 Argo 隧道日志每次启动截断，避免旧进程残留域名被误解析
- 交付韧性：sing-box 固定版本 + SHA256（官方 → 本仓库镜像多源回退）；cloudflared 强校验模型——拿不到官方 SHA256 时默认 **fail-closed 拒绝安装**，绝不静默以"版本自报"代替完整性校验；仅当显式设置 `CLOUDFLARED_ALLOW_RUNTIME_VERIFY=1` 才允许降级（弱网机器的明确选择，不推荐用于生产）
- 低内存：sing-box/cloudflared 按物理内存与 cgroup 上限自动设置 `GOMEMLIMIT` 软上限（防 OOM）；cloudflared 默认 `http2` 模式压内存尖峰；低于 200MB 内存自动提示资源约束
- 保活：systemd 环境用 service + timer；OpenRC/无 systemd 用 cron + pidfile，cloudflared 异常退出约 1 分钟内自动拉起
- WS-TLS CDN 证书方案（v1.2.4）：CDN 中转统一单端口（`wspt`=回源端口），Cloudflare SSL 用 Full/Full(Strict) 以 HTTPS 回源；`cert=self` 自签即可支持 Full，`cert=custom` 供 Full(Strict) 用 Cloudflare Origin CA 证书；已废弃 `ws_cdn_origin_port` 明文回源。
- WS-TLS CDN 证书粘贴式导入（v1.2.5）：`cert=custom` 时界面直接把 PEM 证书/私钥内容粘贴进命令（`cert_b64`/`key_b64`），服务器解码写入托管目录自动加载，无需先上传文件；`cert_path`/`key_path` 文件路径方式保留兼容。
- 网络内核调优（v1.6.0，参数对齐 [jyucoeng/singbox-tools bbr.sh](https://github.com/jyucoeng/singbox-tools)）：默认启用 `BBR + fq`，**不再测速/不再推断带宽**，固定使用 `fq quantum=18028 initial_quantum=90140`、`tcp_rmem=4096 131072 33554432`、`tcp_wmem=4096 16384 33554432`、`tcp_limit_output_bytes=4194304`；持久化到 `/etc/sysctl.d/99-singbox-manager-net-tune.conf`，watchdog 每分钟检查并补齐重启后丢失的 fq qdisc（容器 noqueue 网卡自动跳过）；菜单 **8. BBR+FQ+缓存设置** 可随时重应用/查看，无任何网络测速环节。
- 按需交付：`cloudflared` 仅在启用 Argo（环境变量 `argo` 或已存在 `vless-argo` 节点）时安装；纯 Reality/WS/TUIC/HY2/SOCKS5 部署不再白占约 40MB 磁盘；无 Argo 时更新/重装会自动回收未使用的 cloudflared，添加 Argo 节点时再按需安装。
- 输出格式：`sbm list` / 安装结果改为**名称一行、分享链接单独顶格一行**（前后留空行），终端里双击/三击即可整行复制，不再把"链接: "前缀和 URL 混排。
- 安全：`set -eEuo pipefail`、`umask 077`、secrets/证书/pid 全部 600；分享链接 authority 对 IPv6 正确加方括号（不再先做查询参数编码）；`build_share_link` 局部变量隔离（`fp` 不泄漏到全局）
- CI：shellcheck / bash -n / shfmt / 冒烟测试 / 可复现 bundle 构建 / 版本与 `worker.js` 一致性门禁
- 上游版本见 `metadata/upstream.env`

## 发布流程

1. 更新代码与 `VERSION`
2. 在 **Linux 原生文件系统**（或 CI runner）执行 `bash scripts/build-release-bundle.sh`，将新校验值同步到 `install.sh`；不要在 WSL `/mnt/*`（DrvFs 会伪造 0777 权限）或 Git-for-Windows/MSYS 下构建，否则 bundle 哈希与 CI 不一致
3. 上传 bundle、checksums.txt、install.sh、install.sh.sha256 到 GitHub Release

### 可选：二进制镜像源

在仓库创建 `upgrade-mirror` Release 并上传 `metadata/upstream.env` 中列出的 sing-box 压缩包与 cloudflared 二进制（文件名保持一致），弱网机器在官方源不可达时自动回退到该镜像；所有镜像文件仍执行相同 SHA256 校验。不上传镜像不影响正常功能。

## 注意事项

- `sbm rep` 会清空全部节点；`TUIC` 自签模式链接默认带跳过校验参数
- Argo 临时隧道域名会变化，用 `sbm list` 获取最新地址
