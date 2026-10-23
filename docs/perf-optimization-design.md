# 性能优化 & 成功率/稳定性提升 — 可行性设计文档

- 状态：已确认，按 Phase A/B/C/D 落地
- 目标版本：v1.5.0
- 关联：docs/ARCHITECTURE.md（模块分层）、lib/*（实现）

## 1. 背景与目标

singbox-manager v1.4.0 已完成 `lib/` 模块化拆分。本阶段聚焦运行时质量三指标：

1. **提高链接成功率**：探测/核验/握手路径更快、更稳，降低"看似启动实则不可用"的窗口
2. **减少延迟**：命令首屏感知延迟、客户端握手延迟、域名解析延迟
3. **提升稳定性**：探活更及时、NAT 长连接更稳、启动恢复更快

约束：所有改动保持既有门禁（bash -n、smoke 209+、check-version、bundle 可复现）；不确定行为默认关闭或可回退。

## 2. 现状诊断（性能热区）

已就绪：`node_meta` 单进程 jq 批量取字段 / `url_encode_many` 批量编码 / IP 持久化缓存(600s) / watchdog 崩溃退避 / Argo `--protocol http2` / TCP Fast Open(TCP 入站全开) / WS `max_early_data=2048` / GOMEMLIMIT + LimitNOFILE。

待优化（串行/缺失项）：

| 项 | 位置 | 问题 | 类别 |
|---|---|---|---|
| 公网 IP 探测 | lib/network.sh get_public_ip | ipify/icanhazip 串行，冷启动最坏 4×5s | 延迟 |
| watchdog 端口探活 | lib/network.sh any_node_port_alive | 多节点串行，10 死节点≈20s/轮 | 稳定性 |
| Argo DoH 核验 | lib/argo.sh argo_domain_resolvable | 2源×2类型串行 curl，最坏 24s | 成功率 |
| cloudflared 版本源 | lib/argo.sh latest/version | GitHub API → jsdelivr 串行回退 | 延迟 |
| TUIC 握手 | lib/render.sh tuic-v5 | zero_rtt_handshake=false 每次全握手 | 延迟 |
| TCP keepalive | lib/render.sh TCP 入站 | 未显式设置，NAT 映射易过期 | 稳定性 |
| 目标域名解析 | lib/render.sh render_config | 无 DNS 缓存块，每次连接重查询 | 延迟 |
| 开机首检 | lib/service.sh create_systemd_units | 定时器 OnBootSec=90 恢复慢 | 稳定性 |

## 3. 拍板值（已确认）

1. **HY2 默认带宽：保持 200 Mbps**（上/下行既有上限不变，不作调节）
2. **TUIC：zero_rtt_handshake 开启**（默认 true，env `tuic_zero_rtt=0` 可回退 false）
3. **DNS 块：默认关闭、仅开关接入**（env `dns_servers` 非空才渲染；空=维持现行为）

## 4. 实施方案

### Phase A — 探测路径并行化（降感知延迟）

- **A1 get_public_ip 并行探测**：对每个地址族，ipify/icanhazip 改为后台并发（`&` + `wait`），首个合法公网 IP 即回。总预算受单 curl `--max-time 5` 约束，最坏 4×5s→≈5s。保留 TTL 缓存、hostname -I 回退与 127.0.0.1 兜底语义。
- **A2 watchdog 端口探活并行**：`any_node_port_alive` 内对全部节点端口以 `timeout timeout_s bash -c '</dev/tcp/...>'` 后台并发 + `wait`，任一成功即 0。失败计数 / SBM_PROBE_FAIL_LIMIT / SBM_PROBE_TIMEOUT_S 语义不变。10 死节点 20s→≈timeout_s。
- **A3 Argo DoH 并行核验**：`argo_domain_resolvable` 把 2 源 × A/AAAA 的循环改为后台并发，先到先得；任一源确认(有记录)→成功；所有源确认无记录→失败；全部不可达→fail-open（与现语义一致）。总预算 ≤8s（现最坏 24s）。
- **A4 cloudflared 版本双源并行**：GitHub API 与 jsdelivr 同时后台发，先到者优先；两者都失败才报错。CLOUDFLARED_LATEST_CACHE 缓存不变。

### Phase B — 协议/传输层（降握手延迟、提吞吐）

- **B1 TUIC 0-RTT**：`zero_rtt_handshake: true` 默认；env `tuic_zero_rtt` 为 `0` 时渲染 `false`。
- **B3 TCP keepalive 显式化**：vless-reality / vless-ws-tls / anytls / vless-argo / socks5 五个 TCP 入站统一加 `tcp_keep_alive: true` 与 `tcp_keep_alive_interval: "30s"`（NAT 映射保鲜，长连接/手机网络更稳）。
- **B4 DNS 块开关**：env `dns_servers`（如 `https://1.1.1.1/dns-query`，可逗号多源）非空时，render_config 追加 `dns` 块：`server` 多源、`independent_cache: true`、`strategy: ipv4_only`；then `route` 维持 direct 出站不变。空值=不渲染=现行为。

### Phase C — 存活链路稳健性

- **C1 watchdog 开机首检提前**：systemd 定时器 `OnBootSec=90`→`30`（A2 并行后单轮足够快），`OnUnitActiveSec=60` 不变。

### Phase D — 门禁与发布

- **D1 tests/smoke.sh 新增性能组**：并行探活完成时间断言（模拟探活，非真网络）、TUIC/HY2/DNS/keepalive 渲染键断言、tuic_zero_rtt / dns_servers 开关断言、get_public_ip 缓存路径不变。
- **D2 interface/index.html 新增高级项**：`tuic_zero_rtt`、`dns_servers` 提示条目；`python3 interface/build.py` 重建 worker.js。
- **D3 文档与发布**：ARCHITECTURE.md 补"性能设计"小节；版本 bump **v1.5.0**（VERSION / sb.sh / mtp.sh / install.sh）；`bash scripts/build-release-bundle.sh` 重建 bundle；回填 install.sh PACKAGE_SHA256；`bash scripts/check-version.sh` 全绿；提交 + tag v1.5.0 + push + Release（tar.gz + checksums.txt）。

## 5. 不改变的部分（明确边界）

- HY2 上/下行默认上限 200 Mbps 不变
- TUİC 已有 `congestion_control: bbr`、`heartbeat: 10s` 不变
- Argo `--protocol http2`、崩溃退避、watchdog 轮询 60s 语义不变
- 日志 warn 默认、GOMEMLIMIT/LimitNOFILE/go_gc 语义不变
- mtp.sh（独立单文件）不参与本次改动

## 6. 风险与回退

| 风险 | 等级 | 回退 |
|---|---|---|
| 并行探测在极弱网后台残留进程 | 低 | SBM_IP_PROBE_PARALLEL=0 / SBM_IP_PROBE_MAX_S 预算收紧 |
| TUIC 0-RTT 在极敏感场景的语义变化 | 低 | `tuic_zero_rtt=0` 回退 false |
| DNS 块上游不可达 | 低 | 默认关闭；开启后失联可 `dns_servers=` 清空重 render |
| keepalive 30s 对极少数防火墙的包风暴 | 低 | env `tcp_keep_alive_interval` 可调（默认 30s） |

## 7. 验收标准

- `bash -n` 全部模块通过
- 冒烟 209 基数上新增性能断言组全绿
- `check-version.sh` 全绿（含 bundle 哈希回填）
- 线上：`sbm list` 冷启动显著快于 v1.4.0；TUIC 客户端重连无感；DNS 开关按 env 生效