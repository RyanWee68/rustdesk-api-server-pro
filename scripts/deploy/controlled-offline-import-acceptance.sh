#!/bin/sh

set -eu

fail() {
    printf 'ERR-2397 %s\n' "$1" >&2
    exit 1
}

VERIFY_ONLY=0
if [ "${1:-}" = "--verify-only" ]; then
    VERIFY_ONLY=1
    shift
fi

BUNDLE_DIR="${1:-}"
ROOT_DIR="${2:-$(pwd)}"
[ -n "$BUNDLE_DIR" ] || fail "用法：controlled-offline-import-acceptance.sh [--verify-only] OFFLINE_RELEASE_DIR [ROOT_DIR]"
[ -d "$BUNDLE_DIR" ] || fail "离线候选包目录不存在"
PYTHON_BIN=""
if command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
    PYTHON_BIN="python3"
elif command -v python >/dev/null 2>&1 && python --version >/dev/null 2>&1; then
    PYTHON_BIN="python"
else
    fail "缺少可执行的 Python"
fi

BUNDLE_DIR="$(CDPATH= cd -- "$BUNDLE_DIR" && pwd -P)"
for file in controlled-images.tar images.env SHA256SUMS; do
    [ -f "$BUNDLE_DIR/$file" ] || fail "离线候选包缺少文件：$file"
done

# 标准库校验摘要路径和镜像 ID，避免 source 不可信环境文件。
parsed="$("$PYTHON_BIN" - "$BUNDLE_DIR" <<'PY'
import hashlib
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
if (root / "SHA256SUMS").is_symlink():
    raise SystemExit("ERR-2397 SHA256SUMS 不能是符号链接")
entries = {}
for number, raw in enumerate((root / "SHA256SUMS").read_text(encoding="utf-8").splitlines(), 1):
    match = re.fullmatch(r"([0-9a-f]{64}) [ *]([A-Za-z0-9._-]+)", raw)
    if not match or match.group(2) in {"", ".", "..", "SHA256SUMS"}:
        raise SystemExit(f"ERR-2397 SHA256SUMS 第 {number} 行格式或路径不安全")
    digest, name = match.groups()
    if name in entries:
        raise SystemExit(f"ERR-2397 SHA256SUMS 包含重复文件：{name}")
    path = root / name
    if path.is_symlink():
        raise SystemExit(f"ERR-2397 摘要文件不能是符号链接：{name}")
    if not path.is_file():
        raise SystemExit(f"ERR-2397 摘要文件不存在：{name}")
    digest_builder = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest_builder.update(chunk)
    actual = digest_builder.hexdigest()
    if actual != digest:
        raise SystemExit(f"ERR-2397 文件摘要不匹配：{name}")
    entries[name] = digest

for required in ("controlled-images.tar", "images.env"):
    if required not in entries:
        raise SystemExit(f"ERR-2397 SHA256SUMS 未覆盖文件：{required}")

values = {}
for number, raw in enumerate((root / "images.env").read_text(encoding="utf-8").splitlines(), 1):
    if not raw:
        continue
    match = re.fullmatch(r"(RUSTDESK_API_IMAGE|RUSTDESK_CONTROLLED_SERVER_IMAGE)=(sha256:[0-9a-f]{64})", raw)
    if not match or match.group(1) in values:
        raise SystemExit(f"ERR-2397 images.env 第 {number} 行无效")
    values[match.group(1)] = match.group(2)

for key in ("RUSTDESK_API_IMAGE", "RUSTDESK_CONTROLLED_SERVER_IMAGE"):
    if key not in values:
        raise SystemExit(f"ERR-2397 images.env 缺少 {key}")
print(values["RUSTDESK_API_IMAGE"], values["RUSTDESK_CONTROLLED_SERVER_IMAGE"])
PY
)" || exit $?
set -- $parsed

[ "$#" -eq 2 ] || fail "无法解析离线镜像 ID"
API_IMAGE="$1"
SERVER_IMAGE="$2"
printf 'PASS: 离线候选包摘要和不可变镜像 ID 校验通过\n'

[ "$VERIFY_ONLY" -eq 0 ] || exit 0
[ "${CONTROLLED_INDEPENDENT_HOST:-0}" = "1" ] || fail "仅允许在独立主机执行；确认后设置 CONTROLLED_INDEPENDENT_HOST=1"
command -v docker >/dev/null 2>&1 || fail "缺少 Docker"
[ -f "$BUNDLE_DIR/source-docker-id" ] || fail "离线候选包缺少来源 Docker ID，不能证明与目标隔离"
grep -Eq '^[0-9a-f]{64} [ *]source-docker-id$' "$BUNDLE_DIR/SHA256SUMS" || fail "来源 Docker ID 未纳入摘要清单"
SOURCE_DOCKER_ID="$(tr -d '\r\n' < "$BUNDLE_DIR/source-docker-id")"
TARGET_DOCKER_ID="$(docker info --format '{{.ID}}' 2>/dev/null)" || fail "无法读取目标 Docker ID"
[ -n "$SOURCE_DOCKER_ID" ] && [ -n "$TARGET_DOCKER_ID" ] || fail "来源或目标 Docker ID 为空"
[ "$SOURCE_DOCKER_ID" != "$TARGET_DOCKER_ID" ] || fail "目标使用来源 Docker 守护进程，拒绝同机导入"
[ -f "$ROOT_DIR/scripts/deploy/controlled-three-compose-smoke.sh" ] || fail "找不到三容器验收脚本"
[ -f "$ROOT_DIR/docker-compose.controlled-three-isolated.yaml" ] || fail "找不到三容器隔离 Compose"

# 必须先成功读取完整清单，不能把守护进程故障当作镜像不存在。
existing_images="$(docker image ls --all --quiet --no-trunc 2>/dev/null)" || fail "无法读取目标镜像清单，拒绝导入"
for image in "$API_IMAGE" "$SERVER_IMAGE"; do
    if printf '%s\n' "$existing_images" | grep -Fxq "$image"; then
        fail "独立主机在导入前已存在候选镜像：$image"
    fi
done

docker image load --input "$BUNDLE_DIR/controlled-images.tar" >/dev/null || fail "离线镜像导入失败"
for image in "$API_IMAGE" "$SERVER_IMAGE"; do
    actual="$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true)"
    [ "$actual" = "$image" ] || fail "导入后的镜像 ID 不一致：$image"
done
printf 'PASS: 独立主机离线镜像导入及 ID 核对通过\n'

RUSTDESK_API_IMAGE="$API_IMAGE" RUSTDESK_CONTROLLED_SERVER_IMAGE="$SERVER_IMAGE" \
    sh "$ROOT_DIR/scripts/deploy/controlled-three-compose-smoke.sh" "$ROOT_DIR" || fail "独立主机三容器验收失败"
printf 'PASS: 独立主机离线导入与三容器完整验收通过\n'
