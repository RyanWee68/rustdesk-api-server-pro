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
  reset-server-key-dir      备份并清空 server key 目录，必须设置 CONTROLLED_KEY_ALLOWED_ROOT 并传入 --force。
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
    backup="$(mktemp "${file}.bak.XXXXXXXX")" || fail "无法创建 signKey 独立备份"
    cp "$file" "$backup" || fail "signKey 备份失败，未修改原文件"
    chmod 600 "$backup" || fail "无法限制 signKey 备份权限，未修改原文件"
    printf '%s\n' "$backup"
}

rotate_sign_key() {
    file="$1"
    [ -f "$file" ] || fail "找不到 server.yaml：$file"
    [ ! -L "$file" ] || fail "拒绝轮换符号链接指向的 server.yaml"
    new_key="$(generate_secret)"
    backup="$(backup_file "$file")"
    tmp_file="$(mktemp "${file}.tmp.XXXXXXXX")" || fail "无法创建 signKey 临时文件"
    cp -p "$file" "$tmp_file" || { rm -f -- "$tmp_file"; fail "无法复制 server.yaml 属性，原文件未修改"; }

    if grep -q '^signKey:' "$file"; then
        sed "s|^signKey:.*|signKey: \"$new_key\"|" "$file" > "$tmp_file" ||
            { rm -f -- "$tmp_file"; fail "生成新 signKey 配置失败，原文件未修改"; }
    else
        {
            printf 'signKey: "%s"\n' "$new_key"
            cat "$file"
        } > "$tmp_file" || { rm -f -- "$tmp_file"; fail "生成新 signKey 配置失败，原文件未修改"; }
    fi
    mv -f -- "$tmp_file" "$file" || { rm -f -- "$tmp_file"; fail "替换 server.yaml 失败，原文件未修改"; }

    printf '已轮换 API signKey，备份文件：%s\n' "$backup"
    printf '请重启 API，并重新执行 scripts/deploy/controlled-preflight.sh。\n'
}

reset_server_key_dir() {
    key_dir="$1"
    force="${2:-}"
    [ "$force" = "--force" ] || fail "reset-server-key-dir 必须显式传入 --force"
    [ -n "$key_dir" ] || fail "key-dir 不能为空"
    [ -d "$key_dir" ] || fail "找不到 key 目录：$key_dir"
    [ ! -L "$key_dir" ] || fail "拒绝清空符号链接指向的 key 目录"
    [ -n "${CONTROLLED_KEY_ALLOWED_ROOT:-}" ] || fail "必须设置 CONTROLLED_KEY_ALLOWED_ROOT 限定清理范围"

    resolved="$(cd "$key_dir" && pwd -P)"
    case "$resolved" in
        "/"|"/app"|"/app/data"|"/data"|"/var"|"/var/lib"|"/usr"|"/usr/local")
            fail "拒绝清空高风险目录：$resolved"
            ;;
    esac

    allowed_root="$(CDPATH= cd -- "$CONTROLLED_KEY_ALLOWED_ROOT" && pwd -P)" || fail "允许目录不存在"
    [ "$allowed_root" != "/" ] && [ "$(dirname "$resolved")" = "$allowed_root" ] ||
        fail "key-dir 必须是允许目录的直接子目录：$resolved"

    backup_parent="${CONTROLLED_KEY_BACKUP_DIR:-$(dirname "$resolved")}"
    backup_parent="$(CDPATH= cd -- "$backup_parent" && pwd -P)" || fail "备份目录不存在"
    case "$backup_parent" in
        "$resolved"|"$resolved"/*) fail "备份目录不能位于待清空的 key 目录内" ;;
    esac

    if find "$resolved" -mindepth 1 -maxdepth 1 | grep -q .; then
        backup_dir="$(mktemp -d "$backup_parent/server-key-backup.XXXXXXXX")" || fail "无法创建独立备份目录"
        cp -a "$resolved/." "$backup_dir/" || fail "server key 备份失败，未清空原目录"
        diff -qr "$resolved" "$backup_dir" >/dev/null || fail "server key 备份内容不一致，未清空原目录"
        find "$resolved" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
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
