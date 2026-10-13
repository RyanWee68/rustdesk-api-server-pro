#!/bin/sh

set -eu

ROOT_DIR="${CONTROLLED_ROOT_DIR:-$(pwd)}"
SOURCE_DIR=""
DRY_RUN=0
FORCE=0

fail() {
    printf 'FAIL: ERR-239D %s\n' "$1" >&2
    exit 1
}

warn() {
    printf 'WARN: %s\n' "$1" >&2
}

pass() {
    printf 'PASS: %s\n' "$1"
}

usage() {
    cat <<'EOF'
用法：
  scripts/deploy/controlled-fork-bootstrap.sh /path/to/rustdesk-server-fork [--dry-run] [--force]

说明：
  将当前仓库的受控准入模板和 API 契约复制到 rustdesk-server fork。
  该脚本不会修改 fork 的 hbbs/hbbr 源码，只创建 controlled-api 接入资料目录。

环境变量：
  CONTROLLED_ROOT_DIR  当前 RustDeskWeb 仓库根目录，默认使用当前目录
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --force)
            FORCE=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            fail "未知参数：$1"
            ;;
        *)
            if [ -n "$SOURCE_DIR" ]; then
                fail "只能提供一个 rustdesk-server fork 目录"
            fi
            SOURCE_DIR="$1"
            ;;
    esac
    shift
done

if [ -z "$SOURCE_DIR" ]; then
    fail "未提供 rustdesk-server fork 目录"
fi

if [ ! -d "$ROOT_DIR" ]; then
    fail "当前仓库根目录不存在：$ROOT_DIR"
fi

if [ ! -d "$SOURCE_DIR" ]; then
    fail "rustdesk-server fork 目录不存在：$SOURCE_DIR"
fi

if [ ! -f "$SOURCE_DIR/Cargo.toml" ]; then
    fail "目标目录缺少 Cargo.toml，不像 rustdesk-server fork 根目录"
fi

TEMPLATE_DIR="$ROOT_DIR/templates/rustdesk-server-controlled"
CONTRACT_DOC="$ROOT_DIR/docs/CONTROLLED_RUSTDESK_API_CONTRACT.md"
FORK_DOC="$ROOT_DIR/docs/CONTROLLED_RUSTDESK_SERVER_FORK.md"
SOURCE_CHECK_DOC="$ROOT_DIR/docs/CONTROLLED_RUSTDESK_SERVER_SOURCE_CHECK.md"
TARGET_DIR="$SOURCE_DIR/controlled-api"

for file in \
    "$TEMPLATE_DIR/controlled_admission.rs" \
    "$TEMPLATE_DIR/Cargo.toml" \
    "$TEMPLATE_DIR/README.md" \
    "$CONTRACT_DOC" \
    "$FORK_DOC" \
    "$SOURCE_CHECK_DOC"
do
    if [ ! -f "$file" ]; then
        fail "缺少源文件：$file"
    fi
done

if [ -e "$TARGET_DIR" ] && [ "$FORCE" != "1" ]; then
    fail "目标目录已存在：$TARGET_DIR；如需覆盖请传入 --force"
fi

copy_file() {
    src="$1"
    dest="$2"
    if [ "$DRY_RUN" = "1" ]; then
        printf 'DRY-RUN: cp %s %s\n' "$src" "$dest"
    else
        cp "$src" "$dest"
    fi
}

if [ "$DRY_RUN" = "1" ]; then
    pass "dry-run：将创建目录 $TARGET_DIR"
else
    mkdir -p "$TARGET_DIR"
fi

copy_file "$TEMPLATE_DIR/controlled_admission.rs" "$TARGET_DIR/controlled_admission.rs"
copy_file "$TEMPLATE_DIR/Cargo.toml" "$TARGET_DIR/Cargo.toml"
copy_file "$TEMPLATE_DIR/README.md" "$TARGET_DIR/README.md"
copy_file "$CONTRACT_DOC" "$TARGET_DIR/CONTROLLED_RUSTDESK_API_CONTRACT.md"
copy_file "$FORK_DOC" "$TARGET_DIR/CONTROLLED_RUSTDESK_SERVER_FORK.md"
copy_file "$SOURCE_CHECK_DOC" "$TARGET_DIR/CONTROLLED_RUSTDESK_SERVER_SOURCE_CHECK.md"

if [ "$DRY_RUN" = "1" ]; then
    pass "dry-run 完成，未写入目标目录"
else
    pass "已写入 fork 接入资料目录：$TARGET_DIR"
fi

warn "脚本只复制模板和契约，不会自动改造 hbbs/hbbr 源码"
warn "完成源码接入后，请运行：scripts/deploy/controlled-server-source-check.sh $SOURCE_DIR"
