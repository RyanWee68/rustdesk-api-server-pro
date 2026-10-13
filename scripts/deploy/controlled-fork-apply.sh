#!/bin/sh

set -eu

SOURCE_DIR="${1:-}"
ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
PATCH_FILE="$ROOT_DIR/patches/rustdesk-server/a7736be5-controlled.patch"
BASELINE="a7736be5e40f85bfc141120dce587e836e5d4b80"
COMMON_BASELINE="69cea8dafee147848ae88702029f4bf7df7224c3"

fail() {
    printf 'FAIL: ERR-239D %s\n' "$1" >&2
    exit 1
}

[ -n "$SOURCE_DIR" ] || fail "需要提供 rustdesk-server 源码目录"
[ -f "$PATCH_FILE" ] || fail "固定基线补丁不存在：$PATCH_FILE"
[ -f "$SOURCE_DIR/Cargo.toml" ] || fail "源码目录缺少 Cargo.toml"
[ "$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null)" = "$BASELINE" ] || fail "server 源码 commit 与固定基线不符"
[ "$(git -C "$SOURCE_DIR/libs/hbb_common" rev-parse HEAD 2>/dev/null)" = "$COMMON_BASELINE" ] || fail "hbb_common 子模块 commit 与固定基线不符"
git -C "$SOURCE_DIR" diff --quiet || fail "源码已有未提交改动"
git -C "$SOURCE_DIR" diff --cached --quiet || fail "源码已有暂存改动"
git -C "$SOURCE_DIR" apply --check "$PATCH_FILE" || fail "补丁无法应用到当前源码"
git -C "$SOURCE_DIR" apply "$PATCH_FILE" || fail "补丁应用失败"

printf 'PASS: 已应用受控 server 补丁：%s\n' "$BASELINE"
