#!/usr/bin/env bash
set -eEuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${ROOT_DIR}" in
/mnt/*)
  echo "[警告] 正在 WSL /mnt/* (DrvFs) 下构建：chmod 不生效，文件会被打包为 0755，哈希与 Linux/CI 不一致。" >&2
  echo "[警告] 请复制到 Linux 原生目录（如 /tmp）或使用 CI 构建发布包。" >&2
  ;;
esac
VERSION="$(tr -d '\r\n' <"${ROOT_DIR}/VERSION")"
DIST_DIR="${ROOT_DIR}/dist"
PACKAGE_DIR="${DIST_DIR}/singbox-manager-${VERSION}"
PACKAGE_NAME="singbox-manager-${VERSION}.tar.gz"

rm -rf "${PACKAGE_DIR}"
mkdir -p "${PACKAGE_DIR}" "${DIST_DIR}"

install -m 0755 "${ROOT_DIR}/sb.sh" "${PACKAGE_DIR}/sb.sh"
install -m 0755 "${ROOT_DIR}/mtp.sh" "${PACKAGE_DIR}/mtp.sh"
install -d -m 0755 "${PACKAGE_DIR}/lib" "${PACKAGE_DIR}/metadata" "${PACKAGE_DIR}/scripts"
for lib_file in "${ROOT_DIR}"/lib/*.sh; do
  install -m 0644 "$lib_file" "${PACKAGE_DIR}/lib/$(basename "$lib_file")"
done
install -m 0644 "${ROOT_DIR}/metadata/upstream.env" "${PACKAGE_DIR}/metadata/upstream.env"
install -m 0755 "${ROOT_DIR}/scripts/watchdog.sh" "${PACKAGE_DIR}/scripts/watchdog.sh"
install -m 0644 "${ROOT_DIR}/README.md" "${PACKAGE_DIR}/README.md"
install -m 0644 "${ROOT_DIR}/VERSION" "${PACKAGE_DIR}/VERSION"

# 显式钉死权限位：部分平台（MSYS）的 install -m 不生效而直接沿用源文件 mode，
# 为保证跨平台字节一致，统一以 chmod 兜底（chmod 两平台语义一致）。
chmod 0644 "${PACKAGE_DIR}/VERSION" "${PACKAGE_DIR}/README.md" "${PACKAGE_DIR}/metadata/upstream.env"
chmod 0644 "${PACKAGE_DIR}"/lib/*.sh
chmod 0755 "${PACKAGE_DIR}/sb.sh" "${PACKAGE_DIR}/mtp.sh" "${PACKAGE_DIR}/scripts/watchdog.sh"

# 归一化 tar 元数据并用 gzip -n 去除时间戳，保证同一内容构建出字节级一致的 bundle。
# --format=gnu：显式钉死归档格式（GNU tar 1.34 前默认 gnu；1.35 起部分发行版默认
# 改为 posix/pax），否则跨平台（MSYS 与 CI ubuntu）会因默认格式不同而产出不同字节。
# --mode='go-w'：MSYS/Git-Bash 的 chmod 是假权限（可写文件一律假到 0777），
# 会随文件进归档（v1.5.8 审查 L-1）；此处统一剥掉组/其他写位——Linux 下对已
# chmod 好的 0644/0755 无影响，Windows 下 0777 归一为 0755。安装期权限由
# install.sh 的 install -m/umask 077 最终收敛，归档模式仅影响浏览及临时解包窗口。
tar --format=gnu --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
  --mode='go-w' \
  -cf - -C "${DIST_DIR}" "singbox-manager-${VERSION}" | gzip -n >"${DIST_DIR}/${PACKAGE_NAME}"

(
  cd "${DIST_DIR}"
  # 归一化为 "hash␣␣文件名"（双空格、无二进制标记 *），与 sb.sh 的解析逻辑严格一致
  awk -v name="${PACKAGE_NAME}" '{ print $1 "  " name }' < <(sha256sum "${PACKAGE_NAME}") >checksums.txt
)

echo "Built ${DIST_DIR}/${PACKAGE_NAME}"
