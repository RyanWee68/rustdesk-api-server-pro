#!/bin/sh

set -eu

fail() {
    printf 'ERR-2390 %s\n' "$1" >&2
    exit 1
}

require_secret() {
    name="$1"
    value="${2:-}"
    case "$value" in
        ""|"change-me"|"CHANGE_ME"|"CHANGE_ME_TO_A_RANDOM_32_BYTE_SECRET"|"please-change-this-sign-key"|"test"|"testadmin")
            fail "$name 未设置或仍为示例值"
            ;;
    esac
    if [ "${#value}" -lt 32 ]; then
        fail "$name 长度不足 32 字符"
    fi
}

normalize_port() {
    value="$1"
    case "$value" in
        :*) printf '%s' "${value#:}" ;;
        *) printf '%s' "$value" ;;
    esac
}

write_or_replace_yaml_value() {
    file="$1"
    section="$2"
    key="$3"
    value="$4"
    tmp_yaml="$(mktemp)"
    awk -v section="$section" -v key="$key" -v value="$value" '
        $0 == section ":" {
            in_section = 1
            seen_section = 1
            indent = "  "
            seen_indent = 0
            print
            next
        }
        in_section && /^[^ ]/ {
            if (!seen_key) {
                print indent key ": " value
            }
            in_section = 0
        }
        in_section && !seen_indent && /^[[:space:]]+[^[:space:]#]/ {
            match($0, /^[[:space:]]*/)
            indent = substr($0, RSTART, RLENGTH)
            seen_indent = 1
        }
        in_section && $0 ~ "^[[:space:]]*" key ":" {
            print indent key ": " value
            seen_key = 1
            next
        }
        { print }
        END {
            if (in_section && !seen_key) {
                print indent key ": " value
            }
            if (!seen_section) {
                print section ":"
                print "  " key ": " value
            }
        }
    ' "$file" > "$tmp_yaml"
    cat "$tmp_yaml" > "$file"
    rm -f "$tmp_yaml"
}

wait_api_health() {
    health_port="$(normalize_port "$PORT")"
    health_url="http://127.0.0.1:${health_port}/api/health"
    retries="${API_HEALTH_RETRIES:-60}"
    i=1
    while [ "$i" -le "$retries" ]; do
        if wget -q -T "${API_HEALTH_TIMEOUT_SECONDS:-2}" -O - "$health_url" >/dev/null 2>&1; then
            printf 'API 健康检查通过：%s\n' "$health_url"
            return 0
        fi
        if ! kill -0 "$API_PID" >/dev/null 2>&1; then
            fail "API 进程提前退出"
        fi
        sleep 1
        i=$((i + 1))
    done
    fail "API 健康检查超时：$health_url"
}

cleanup() {
    set +e
    [ -n "${HBBS_PID:-}" ] && kill "$HBBS_PID" >/dev/null 2>&1
    [ -n "${HBBR_PID:-}" ] && kill "$HBBR_PID" >/dev/null 2>&1
    [ -n "${API_PID:-}" ] && kill "$API_PID" >/dev/null 2>&1
    wait >/dev/null 2>&1
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ ! -x /app/rustdesk-api-server-pro ]; then
    fail "找不到 API 二进制：/app/rustdesk-api-server-pro"
fi

if [ ! -f /usr/local/bin/rustdesk-api-server-pro ]; then
    ln -s /app/rustdesk-api-server-pro /usr/local/bin/rustdesk-api-server-pro
fi

ADMIN_USER="${ADMIN_USER:-}"
ADMIN_PASS="${ADMIN_PASS:-}"
PORT="${PORT:-12345}"
ADMIN_PORT="${ADMIN_PORT:-12346}"
RUSTDESK_API_INTERNAL_SECRET="${RUSTDESK_API_INTERNAL_SECRET:-}"
RUSTDESK_AUTH_CACHE_SECONDS="${RUSTDESK_AUTH_CACHE_SECONDS:-60}"
MUST_LOGIN="${MUST_LOGIN:-1}"
API_SERVER="${API_SERVER:-http://127.0.0.1:$(normalize_port "$PORT")}"
API_INTERNAL_SECRET="${API_INTERNAL_SECRET:-$RUSTDESK_API_INTERNAL_SECRET}"
AUTH_CACHE_SECONDS="${AUTH_CACHE_SECONDS:-$RUSTDESK_AUTH_CACHE_SECONDS}"
RUSTDESK_KEY_DIR="${RUSTDESK_KEY_DIR:-/app/rustdesk-server}"
HBBS_BIN="${HBBS_BIN:-/usr/local/bin/hbbs}"
HBBR_BIN="${HBBR_BIN:-/usr/local/bin/hbbr}"
HBBS_ARGS="${HBBS_ARGS:-}"
HBBR_ARGS="${HBBR_ARGS:-}"
CONTROLLED_API_ONLY="${CONTROLLED_API_ONLY:-0}"

case "$CONTROLLED_API_ONLY" in
    0|1) ;;
    *) fail "CONTROLLED_API_ONLY 必须为 0 或 1" ;;
esac

require_secret "RUSTDESK_API_INTERNAL_SECRET" "$RUSTDESK_API_INTERNAL_SECRET"
[ -n "$ADMIN_USER" ] || fail "ADMIN_USER 未设置"
case "$ADMIN_PASS" in
    ""|"test"|"testadmin"|"admin"|"password") fail "ADMIN_PASS 未设置或仍为示例值" ;;
esac
[ "${#ADMIN_PASS}" -ge 12 ] || fail "ADMIN_PASS 长度不足 12 字符"

if [ "$MUST_LOGIN" != "1" ] && [ "$MUST_LOGIN" != "true" ]; then
    fail "MUST_LOGIN 必须启用"
fi

if [ "$CONTROLLED_API_ONLY" = "0" ] && [ ! -x "$HBBS_BIN" ]; then
    fail "找不到 hbbs 二进制：$HBBS_BIN"
fi

if [ "$CONTROLLED_API_ONLY" = "0" ] && [ ! -x "$HBBR_BIN" ]; then
    fail "找不到 hbbr 二进制：$HBBR_BIN"
fi

mkdir -p /app/data "$RUSTDESK_KEY_DIR" /app/logs

if [ -f /app/server.yaml ] && [ ! -f /app/data/server.yaml ]; then
    cp /app/server.yaml /app/data/server.yaml
fi

if [ -f /app/data/server.yaml ]; then
    port_val="$PORT"
    case "$port_val" in :*) ;; *) port_val=":$port_val" ;; esac
    admin_port_val="$ADMIN_PORT"
    case "$admin_port_val" in :*) ;; *) admin_port_val=":$admin_port_val" ;; esac
    write_or_replace_yaml_value /app/data/server.yaml httpConfig port "\"$port_val\""
    write_or_replace_yaml_value /app/data/server.yaml httpConfig adminPort "\"$admin_port_val\""
    write_or_replace_yaml_value /app/data/server.yaml rustdeskServer internalSecret "\"$RUSTDESK_API_INTERNAL_SECRET\""
    write_or_replace_yaml_value /app/data/server.yaml rustdeskServer authCacheSeconds "$RUSTDESK_AUTH_CACHE_SECONDS"

    current_sign_key="$(grep -E '^signKey:' /app/data/server.yaml | head -n1 | sed 's/#.*//' | sed 's/^signKey:[[:space:]]*//' | tr -d '"' | tr -d "'" | sed 's/[[:space:]]*$//' || true)"
    case "$current_sign_key" in
        ""|"CHANGE_ME_TO_A_RANDOM_32_BYTE_SECRET"|'sercrethatmaycontainch@r$32chars')
            generated_sign_key="$(head -c 48 /dev/urandom | base64 | tr -d '=+/\n' | cut -c1-48)"
            sed -i "s|^signKey:.*|signKey: \"$generated_sign_key\"|" /app/data/server.yaml
            ;;
    esac
fi

export ADMIN_USER ADMIN_PASS PORT ADMIN_PORT RUSTDESK_API_INTERNAL_SECRET RUSTDESK_AUTH_CACHE_SECONDS
export MUST_LOGIN API_SERVER API_INTERNAL_SECRET AUTH_CACHE_SECONDS RUSTDESK_KEY_DIR
export APP_VERSION="${APP_VERSION:-latest}"
export BUILD_TIME="${BUILD_TIME:-}"

cd /app/data
/app/rustdesk-api-server-pro sync

if [ ! -f /app/data/.init.lock ] && [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ]; then
    /app/rustdesk-api-server-pro user add "$ADMIN_USER" "$ADMIN_PASS" --admin
    touch /app/data/.init.lock
fi

/app/rustdesk-api-server-pro start &
API_PID="$!"
printf '%s' "$API_PID" > /tmp/rustdesk-controlled-api.pid
wait_api_health

if [ "$CONTROLLED_API_ONLY" = "1" ]; then
    wait "$API_PID" || true
    fail "API 进程已退出"
fi

(
    cd "$RUSTDESK_KEY_DIR"
    unset PORT
    # shellcheck disable=SC2086
    exec "$HBBS_BIN" $HBBS_ARGS
) &
HBBS_PID="$!"
printf '%s' "$HBBS_PID" > /tmp/rustdesk-controlled-hbbs.pid

(
    cd "$RUSTDESK_KEY_DIR"
    unset PORT
    # shellcheck disable=SC2086
    exec "$HBBR_BIN" $HBBR_ARGS
) &
HBBR_PID="$!"
printf '%s' "$HBBR_PID" > /tmp/rustdesk-controlled-hbbr.pid

printf '受控服务已启动：api=%s hbbs=%s hbbr=%s\n' "$API_PID" "$HBBS_PID" "$HBBR_PID"

while :; do
    if ! kill -0 "$API_PID" >/dev/null 2>&1; then
        fail "API 进程已退出"
    fi
    if ! kill -0 "$HBBS_PID" >/dev/null 2>&1; then
        fail "hbbs 进程已退出"
    fi
    if ! kill -0 "$HBBR_PID" >/dev/null 2>&1; then
        fail "hbbr 进程已退出"
    fi
    sleep 5
done
