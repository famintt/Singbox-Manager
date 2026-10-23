#!/usr/bin/env bash
set -eEuo pipefail

# 一致性门禁：版本号单一来源 + install.sh 内嵌校验值与可复现 bundle 一致
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

fail() {
  echo "一致性校验失败：$1" >&2
  exit 1
}

version_file="$(sed 's/^v//' VERSION | tr -d '\r\n')"
version_sb="$(grep -m1 '^SCRIPT_VERSION=' sb.sh | cut -d'"' -f2)"
version_mtp="$(grep -m1 '^SCRIPT_VERSION=' mtp.sh | cut -d'"' -f2)"
version_install="$(grep -m1 '^PROJECT_VERSION=' install.sh | sed 's/.*v//; s/"$//' | tr -d '\r\n')"

[ "${version_file}" = "${version_sb}" ] || fail "VERSION(${version_file}) 与 sb.sh SCRIPT_VERSION(${version_sb}) 不一致"
[ "${version_file}" = "${version_mtp}" ] || fail "VERSION(${version_file}) 与 mtp.sh SCRIPT_VERSION(${version_mtp}) 不一致"
[ "${version_file}" = "${version_install}" ] || fail "VERSION(${version_file}) 与 install.sh PROJECT_VERSION(${version_install}) 不一致"

# 模块清单校验：SBM_MODULES(lib/env.sh) 必须与 lib/*.sh 严格一一对应且去重，
# 顺序以 env.sh 为准（首个必须为 env），防止新增/删除模块时漏维护清单或乱序。
modules_line="$(grep -oE '^SBM_MODULES=\([^)]*\)' lib/env.sh | head -n1)"
[ -n "${modules_line}" ] || fail "lib/env.sh 缺少 SBM_MODULES 声明"
modules="$(printf '%s' "${modules_line}" | sed 's/^SBM_MODULES=(//; s/)$//')"
[ -z "${modules}" ] && fail "SBM_MODULES 为空"
read -r -a module_arr <<<"${modules}"
dup="$(printf '%s\n' "${module_arr[@]}" | sort | uniq -d | tr '\n' ' ')"
[ -z "${dup}" ] || fail "SBM_MODULES 存在重复模块：${dup}"
[ "${module_arr[0]}" = "env" ] || fail "SBM_MODULES 首个模块必须为 env（当前：${module_arr[0]}）"
for m in "${module_arr[@]}"; do
  [ -f "lib/${m}.sh" ] || fail "SBM_MODULES 声明了 ${m}，但缺少 lib/${m}.sh"
  bash -n "lib/${m}.sh" || fail "lib/${m}.sh 语法错误"
done
for f in lib/*.sh; do
  b="$(basename "$f" .sh)"
  printf '%s\n' "${module_arr[@]}" | grep -qx "${b}" || fail "lib/${b}.sh 未在 SBM_MODULES 中声明"
done

# README / interface 的安装入口必须指向 releases/latest，不得钉死版本号，
# 防止用户照文档装到旧版（v0.2.11 事故）
if grep -qE 'releases/download/v[0-9]+\.[0-9]+\.[0-9]+' README.md; then
  fail "README.md 出现钉死版本号的下载链接，请改用 releases/latest/download/"
fi
grep -q 'releases/latest/download/install.sh' interface/index.html ||
  fail "interface RELEASE_BASE 应指向 releases/latest/download/install.sh"

bash scripts/build-release-bundle.sh >/dev/null
bundle_name="singbox-manager-v${version_file}.tar.gz"
[ -f "dist/${bundle_name}" ] || fail "构建产物缺失：dist/${bundle_name}"

actual="$(sha256sum "dist/${bundle_name}" | awk '{print $1}')"
pinned="$(grep -m1 '^PACKAGE_SHA256=' install.sh | grep -o '[a-f0-9]\{64\}')"
[ -n "${pinned}" ] || fail "install.sh 未找到 PACKAGE_SHA256"
[ "${actual}" = "${pinned}" ] || fail "install.sh 内嵌校验值(${pinned}) 与实际 bundle(${actual}) 不一致（注：Git-for-Windows/MSYS 对含 shebang 的脚本强制可执行位，WSL /mnt/* DrvFs 同样伪造 0777 权限且 chmod 不生效，此类主机本地构建的 lib/README 恒为 0755，无法与 Linux 构建字节对齐——属宿主限制；请在 Linux 原生文件系统或 ubuntu CI 构建）"

# checksums.txt 必须是 "hash␣␣文件名" 归一化格式（无 * 二进制标记）
expected_line="${actual}  ${bundle_name}"
line="$(tr -d '\r' <dist/checksums.txt)"
[ "${line}" = "${expected_line}" ] || fail "checksums.txt 格式异常：${line}"

# worker.js 必须与 index.html 保持同步再生成
# 注意：Windows 商店的 python3 假别名能被 command -v 找到但执行即失败，按可执行性探测
py=""
if command -v python3 >/dev/null 2>&1 && python3 -c "pass" >/dev/null 2>&1; then
  py="python3"
elif command -v python >/dev/null 2>&1 && python -c "pass" >/dev/null 2>&1; then
  py="python"
fi
[ -n "${py}" ] || fail "需要 python 以校验 worker.js 同步性"

# worker.js 必须与 index.html 保持同步：在临时目录中重建一份再逐字节对比
tmp_iface="$(mktemp -d)"
cp interface/index.html interface/build.py VERSION "${tmp_iface}/"
(cd "${tmp_iface}" && "$py" build.py >/dev/null)
if ! diff -q interface/worker.js "${tmp_iface}/worker.js" >/dev/null; then
  rm -rf "${tmp_iface}"
  fail "interface/worker.js 与 index.html 不同步，请运行 python interface/build.py"
fi
rm -rf "${tmp_iface}"

raw_hash="$(gzip -dc "dist/${bundle_name}" | sha256sum | awk '{print $1}')"
rm -rf dist
echo "一致性校验通过：v${version_file} / ${actual:0:12}..."
echo "可复现性：tar=$(tar --version | head -n1 | sed -E 's/.*\) ([0-9.]+).*/\1/') gzip=$(gzip --version | head -n1 | awk '{print $2}') 未压缩tar=${raw_hash}"
