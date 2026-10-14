#!/bin/sh

set -eu

usage() {
    cat <<'USAGE'
用法：
  controlled-key-rotation.sh generate-internal-secret
  controlled-key-rotation.sh rotate-sign-key <server.yaml>
  controlled-key-rotation.sh reset-server-key-dir <key-dir> --force

说明：
  generate-internal-secret  生成不少于 32 字符的内部 API 密钥。
  rotate-sign-key           备份 server.yaml 后轮换顶层 signKey。
  reset-server-key-dir      清空 RustDesk server key 目录，必须显式传入 --force。
USAGE
}

fail() {
    printf 'ERR-2395 %s\n' "$1" >&2
    exit 1
}

generate_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 48 | tr -d '=+/\n' | cut -c1-48
        return
    fi
    if [ -r /dev/urandom ]; then
        dd if=/dev/urandom bs=48 count=1 2>/dev/null | base64 | tr -d '=+/\n' | cut -c1-48
        return
    fi
    fail "当前环境缺少 openssl 和 /dev/urandom，无法生成随机密钥"
}

backup_file() {
    file="$1"
    timestamp="$(date +%Y%m%d%H%M%S)"
    backup="${file}.bak.${timestamp}"
    cp "$file" "$backup"
    printf '%s\n' "$backup"
}

rotate_sign_key() {
    file="$1"
    [ -f "$file" ] || fail "找不到 server.yaml：$file"
    new_key="$(generate_secret)"
    backup="$(backup_file "$file")"

    if grep -q '^signKey:' "$file"; then
        tmp_file="$(mktemp)"
        sed "s|^signKey:.*|signKey: \"$new_key\"|" "$file" > "$tmp_file"
        cat "$tmp_file" > "$file"
        rm -f "$tmp_file"
    else
        tmp_file="$(mktemp)"
        {
            printf 'signKey: "%s"\n' "$new_key"
            cat "$file"
        } > "$tmp_file"
        cat "$tmp_file" > "$file"
        rm -f "$tmp_file"
    fi

    printf '已轮换 API signKey，备份文件：%s\n' "$backup"
    printf '请重启 API，并重新执行 scripts/deploy/controlled-preflight.sh。\n'
}

reset_server_key_dir() {
    key_dir="$1"
    force="${2:-}"
    [ "$force" = "--force" ] || fail "reset-server-key-dir 必须显式传入 --force"
    [ -n "$key_dir" ] || fail "key-dir 不能为空"
    [ -d "$key_dir" ] || fail "找不到 key 目录：$key_dir"

    resolved="$(cd "$key_dir" && pwd -P)"
    case "$resolved" in
        "/"|"/app"|"/app/data"|"/data"|"/var"|"/var/lib"|"/usr"|"/usr/local")
            fail "拒绝清空高风险目录：$resolved"
            ;;
    esac

    if [ -n "${CONTROLLED_KEY_ALLOWED_ROOT:-}" ]; then
        allowed_root="$(CDPATH= cd -- "$CONTROLLED_KEY_ALLOWED_ROOT" && pwd -P)"
        case "$resolved" in
            "$allowed_root"/*) ;;
            *) fail "key-dir 不在允许目录内：$resolved" ;;
        esac
    fi

    backup_parent="${CONTROLLED_KEY_BACKUP_DIR:-$(dirname "$resolved")}"
    timestamp="$(date +%Y%m%d%H%M%S)"
    backup_dir="$backup_parent/server-key-backup-$timestamp"
    mkdir -p "$backup_dir"

    if find "$resolved" -mindepth 1 -maxdepth 1 | grep -q .; then
        find "$resolved" -mindepth 1 -maxdepth 1 -exec cp -a {} "$backup_dir"/ \;
        find "$resolved" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        printf '已备份并清空 RustDesk server key 目录：%s\n' "$resolved"
        printf '备份目录：%s\n' "$backup_dir"
    else
        printf 'RustDesk server key 目录为空，无需清理：%s\n' "$resolved"
    fi

    printf '请重启受控 hbbs/hbbr 生成新 server key，并确认旧客户端配置无法继续连入。\n'
}

cmd="${1:-}"
case "$cmd" in
    generate-internal-secret)
        generate_secret
        printf '\n'
        ;;
    rotate-sign-key)
        [ "$#" -eq 2 ] || fail "rotate-sign-key 需要且仅需要一个 server.yaml 参数"
        rotate_sign_key "$2"
        ;;
    reset-server-key-dir)
        [ "$#" -eq 3 ] || fail "reset-server-key-dir 需要 key-dir 和 --force 参数"
        reset_server_key_dir "$2" "$3"
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        fail "未知命令：$cmd"
        ;;
esac
