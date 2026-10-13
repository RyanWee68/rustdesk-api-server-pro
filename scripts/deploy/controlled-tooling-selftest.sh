#!/bin/sh

set -eu

ROOT_DIR="${1:-$(pwd)}"
TMP_PARENT="$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)"
WORK_DIR="$(mktemp -d "$TMP_PARENT/rustdesk-controlled-tooling.XXXXXX")"

fail() {
    printf 'FAIL: ERR-239G %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

cleanup() {
    [ -d "$WORK_DIR" ] || return
    resolved_work="$(CDPATH= cd -- "$WORK_DIR" && pwd -P)"
    case "$resolved_work" in
        "$TMP_PARENT"/rustdesk-controlled-tooling.*)
            rm -rf -- "$resolved_work"
            ;;
        *)
            printf 'WARN: 拒绝清理非预期临时目录：%s\n' "$resolved_work" >&2
            ;;
    esac
}

trap cleanup EXIT INT TERM

[ -f "$ROOT_DIR/docs/CONTROLLED_RUSTDESK_DEPLOYMENT_PLAN.md" ] || \
    fail "传入目录不像当前 RustDeskWeb 仓库：$ROOT_DIR"

FORK_DIR="$WORK_DIR/rustdesk-server-fork"
mkdir -p "$FORK_DIR"
printf '[workspace]\nmembers = []\n' > "$FORK_DIR/Cargo.toml"

CONTROLLED_ROOT_DIR="$ROOT_DIR" \
    sh "$ROOT_DIR/scripts/deploy/controlled-fork-bootstrap.sh" "$FORK_DIR" --dry-run >/dev/null
[ ! -e "$FORK_DIR/controlled-api" ] || fail "fork 脚手架 dry-run 不应写入文件"
pass "fork 接入脚手架 dry-run"

CONTROLLED_ROOT_DIR="$ROOT_DIR" \
    sh "$ROOT_DIR/scripts/deploy/controlled-fork-bootstrap.sh" "$FORK_DIR" >/dev/null 2>&1
for file in \
    controlled_admission.rs \
    Cargo.toml \
    README.md \
    CONTROLLED_RUSTDESK_API_CONTRACT.md \
    CONTROLLED_RUSTDESK_SERVER_FORK.md \
    CONTROLLED_RUSTDESK_SERVER_SOURCE_CHECK.md
do
    [ -f "$FORK_DIR/controlled-api/$file" ] || fail "fork 脚手架缺少输出文件：$file"
done
pass "fork 接入脚手架真实复制"

SECRET="$(sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" generate-internal-secret)"
[ "${#SECRET}" -ge 32 ] || fail "生成的内部密钥长度不足"
case "$SECRET" in
    *[!A-Za-z0-9]*) fail "生成的内部密钥包含非字母数字字符" ;;
esac
pass "内部 API 密钥生成"

SERVER_YAML="$WORK_DIR/server.yaml"
printf 'signKey: "example-sign-key"\ndebugMode: false\n' > "$SERVER_YAML"
sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" rotate-sign-key "$SERVER_YAML" >/dev/null
grep -q '^signKey: "example-sign-key"$' "$SERVER_YAML" && fail "API signKey 未完成轮换"
find "$WORK_DIR" -maxdepth 1 -type f -name 'server.yaml.bak.*' | grep -q . || fail "API signKey 轮换未生成备份"
pass "API signKey 轮换和备份"

KEY_DIR="$WORK_DIR/server-key"
BACKUP_DIR="$WORK_DIR/key-backups"
mkdir -p "$KEY_DIR" "$BACKUP_DIR"
printf 'test-public-key\n' > "$KEY_DIR/id_ed25519.pub"
if CONTROLLED_KEY_BACKUP_DIR="$BACKUP_DIR" \
    sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" reset-server-key-dir "$KEY_DIR" >"$WORK_DIR/no-force.log" 2>&1; then
    fail "server key 清理未要求 --force"
fi
grep -q 'ERR-2395' "$WORK_DIR/no-force.log" || fail "server key 拒绝路径缺少 ERR-2395"

CONTROLLED_KEY_ALLOWED_ROOT="$WORK_DIR" CONTROLLED_KEY_BACKUP_DIR="$BACKUP_DIR" \
    sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" reset-server-key-dir "$KEY_DIR" --force >/dev/null
[ -z "$(find "$KEY_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "server key 目录未被清空"
find "$BACKUP_DIR" -type f -name 'id_ed25519.pub' | grep -q . || fail "server key 未生成备份"
pass "RustDesk server key 强制轮换保护"

# 只加载配置更新函数，避免启动进程；覆盖后台保存后的四空格缩进。
(
    eval "$(sed -n '/^write_or_replace_yaml_value() {$/,/^}$/p' "$ROOT_DIR/docker/controlled-entrypoint.sh")"
    indent_yaml="$WORK_DIR/indent.yaml"
    printf 'httpConfig:\n    port: ":12345"\n    staticdir: "/app/dist"\nrustdeskServer:\n    internalSecret: "fixture"\n' > "$indent_yaml"
    write_or_replace_yaml_value "$indent_yaml" httpConfig port '":22345"'
    write_or_replace_yaml_value "$indent_yaml" httpConfig adminPort '":22346"'
    write_or_replace_yaml_value "$indent_yaml" rustdeskServer internalSecret '"fixture-updated"'
    write_or_replace_yaml_value "$indent_yaml" rustdeskServer authCacheSeconds 60
    grep -q '^    port: ":22345"$' "$indent_yaml" || fail "配置更新未保留四空格缩进"
    grep -q '^    adminPort: ":22346"$' "$indent_yaml" || fail "缺失字段插入未沿用四空格缩进"
    grep -q '^    internalSecret: "fixture-updated"$' "$indent_yaml" || fail "内部密钥更新破坏缩进"
    grep -q '^    authCacheSeconds: 60$' "$indent_yaml" || fail "末尾字段插入破坏缩进"
    printf 'httpConfig:\n' > "$indent_yaml"
    write_or_replace_yaml_value "$indent_yaml" httpConfig port '":12345"'
    grep -q '^  port: ":12345"$' "$indent_yaml" || fail "空配置段缺失默认缩进"
)
pass "配置更新、缺失字段及空配置段缩进回归"

printf '\n受控部署工具自测通过。\n'
