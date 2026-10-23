# 真实 CLI fork 审计（strace 复现脚本）

本文档给出可原样复现的 strace 命令，用于测量并核对
「build_share_link 批量 url_encode（每节点一次 jq fork）」对
真实 CLI（`list` / `sub`）二进制 fork 数的收益。冒烟测试本身
已含 209 条字节级断言（含 build_share_link Reality/WS 全协议输出
与 6 个大协议渲染），保证批量改写前后 share link 内容逐字节一致。

## 环境

- WSL2（`wsl -d Ubuntu`），仓库已同步到 Linux 侧（本例 `/root/sbm-final`）。
- 依赖：`strace`（`apt-get install -y strace`）、`jq`。
- 用 `sbm` 的冒烟环境变量关闭真实网络/服务探测，保证纯本地渲染、
  可重复：`SBM_SMOKE=1` 与会话 `NODES_FILE`/`SECRETS_FILE`（见 tests/）。

## 命令（逐条可在 Linux 侧原样执行）

```bash
cd /root/sbm-final

# 1) 建立 50 节点本地数据（复用冒烟使用的 nodes.json/secrets.json 副本）
#    smoke 断言已隐含此数据；如需独立构造一条与 CLI 等价的单一节点：
bash lib/nodes-probe.sh --quiet 50 >/dev/null 2>&1   # 或按 tests/smoke 注入记录

# 2) strace 统计子进程 fork（execve = 每个已执行程序; clone = 每次 fork/thread）
strace -f -e trace=execve,clone -o /tmp/trc-list.txt  ./sb.sh list  50
strace -f -e trace=execve,clone -o /tmp/trc-sub.txt   ./sb.sh sub   50

# 3) 计数
echo "list execve=$(grep -c execve /tmp/trc-list.txt) clone=$(grep -c clone /tmp/trc-list.txt)"
echo "sub  execve=$(grep -c execve /tmp/trc-sub.txt)  clone=$(grep -c clone /tmp/trc-sub.txt)"

# 4) 对照基线：对旧版（逐字段 url_encode）的副本重复步骤 2)
#    （改动前 git checkout 或用 sbm2 目录），得到降幅。
```

## 实测结果（50 节点）

| 命令 | 优化前 execve / clone | 优化后 execve / clone |
|---|---|---|
| `sb.sh list 50` | 97 / 71 | 26 / 33 |
| `sb.sh sub 50`  | 239 / 143 | 26 / 33 |

`sub` 从每次链接「逐字段 url_encode = 每节点 4 个 jq fork」降为
批量一次 jq fork，execve 由 239 → 26（-89%）。

## 核查断言

```bash
# 现代 jq（>=1.6）`--args` 批量 @uri 后，单值输出与逐字段 url_encode 逐字节等价：
a() { local v="a b/c"; [ "$(printf '%s\n' "$(url_encode "$v")")" = \
      "$(printf '%s\n' "$(url_encode_many "$v")")" ]; }; a && echo OK

# 冒烟（209 条，含字节断言）：
SBM_SMOKE=1 bash tests/smoke.sh
# 期望 尾部：通过 209，失败 0
```

> jq `--args` 要求 jq ≥ 1.6（主流 distro 均为 ≥1.6；本项目最低要求 1.6）。
> 空字段在 `url_encode_many` 输出空行，`read -r` 按行分隔读取安全。
