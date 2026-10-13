#!/bin/sh

set -eu

failures=0

fail() {
    failures=$((failures + 1))
    printf 'FAIL: ERR-2393 %s\n' "$1" >&2
}

warn() {
    printf 'WARN: %s\n' "$1" >&2
}

pass() {
    printf 'PASS: %s\n' "$1"
}

require_secret() {
    name="$1"
    value="${2:-}"
    case "$value" in
        ""|"change-me"|"CHANGE_ME"|"CHANGE_ME_TO_A_RANDOM_32_BYTE_SECRET"|"please-change-this-sign-key"|"test"|"testadmin")
            fail "$name 未设置或仍为示例值"
            ;;
        *)
            if [ "${#value}" -lt 32 ]; then
                fail "$name 长度不足 32 字符"
            else
                pass "$name 已设置"
            fi
            ;;
    esac
}

check_compose_file() {
    file="$1"
    if [ ! -f "$file" ]; then
        fail "找不到 Compose 文件：$file"
        return
    fi
    pass "找到 Compose 文件：$file"

    if grep -Eq '0\.0\.0\.0:12346|"\$\{FNOS_ADMIN_HTTP_PORT:-12346\}:12346"|-[[:space:]]*"\$\{FNOS_ADMIN_HTTP_PORT:-12346\}:12346"' "$file"; then
        fail "管理后台端口疑似公网暴露，请绑定 127.0.0.1 或内网地址"
    else
        pass "管理后台端口未发现明显公网绑定"
    fi

    if grep -Eq 'RUSTDESK_API_INTERNAL_SECRET=\$\{RUSTDESK_API_INTERNAL_SECRET:\?' "$file"; then
        pass "Compose 强制要求 RUSTDESK_API_INTERNAL_SECRET"
    else
        fail "Compose 未强制要求 RUSTDESK_API_INTERNAL_SECRET"
    fi

    if grep -Eq '\$\{RUSTDESK_CONTROLLED_SERVER_IMAGE:\?' "$file"; then
        pass "Compose 强制要求改造版 RustDesk Server 镜像"
    else
        fail "Compose 未强制要求改造版 RustDesk Server 镜像"
    fi

    if grep -Eq 'MUST_LOGIN=1' "$file"; then
        pass "Compose 已启用 MUST_LOGIN"
    else
        fail "Compose 未启用 MUST_LOGIN"
    fi

    if grep -Eq '21118|21119' "$file"; then
        if grep -Eq '127\.0\.0\.1:21118|127\.0\.0\.1:21119' "$file"; then
            pass "Web 端口未发现明显公网绑定"
        else
            warn "未确认 21118/21119 是否绑定本机，请人工核对 Web 端口暴露范围"
        fi
    fi
}

check_server_yaml() {
    file="$1"
    if [ ! -f "$file" ]; then
        warn "未找到 server.yaml：$file"
        return
    fi

    sign_key="$(grep -E '^signKey:' "$file" | head -n1 | sed 's/#.*//' | sed 's/^signKey:[[:space:]]*//' | tr -d '"' | tr -d "'" | sed 's/[[:space:]]*$//' || true)"
    require_secret "signKey" "$sign_key"

    internal_secret="$(sed -n '/^rustdeskServer:/,/^[^ ]/p' "$file" | grep -E '^[[:space:]]*internalSecret:' | head -n1 | sed 's/#.*//' | sed 's/^[[:space:]]*internalSecret:[[:space:]]*//' | tr -d '"' | tr -d "'" | sed 's/[[:space:]]*$//' || true)"
    if [ -n "$internal_secret" ]; then
        require_secret "rustdeskServer.internalSecret" "$internal_secret"
    else
        warn "server.yaml 未写入 rustdeskServer.internalSecret；如果由环境变量注入，这是可以接受的"
    fi
}

check_env() {
    require_secret "RUSTDESK_API_INTERNAL_SECRET" "${RUSTDESK_API_INTERNAL_SECRET:-}"

    if [ -z "${RUSTDESK_CONTROLLED_SERVER_IMAGE:-}" ]; then
        fail "RUSTDESK_CONTROLLED_SERVER_IMAGE 未设置"
    else
        pass "RUSTDESK_CONTROLLED_SERVER_IMAGE 已设置"
    fi

    cache_seconds="${RUSTDESK_AUTH_CACHE_SECONDS:-60}"
    case "$cache_seconds" in
        ''|*[!0-9]*)
            fail "RUSTDESK_AUTH_CACHE_SECONDS 必须是数字"
            ;;
        *)
            if [ "$cache_seconds" -gt 120 ]; then
                fail "RUSTDESK_AUTH_CACHE_SECONDS 不应超过 120 秒"
            else
                pass "RUSTDESK_AUTH_CACHE_SECONDS 在建议范围内"
            fi
            ;;
    esac
}

ROOT_DIR="${1:-$(pwd)}"
COMPOSE_FILE="${CONTROLLED_COMPOSE_FILE:-$ROOT_DIR/docker-compose.controlled.yaml}"
ONE_CONTAINER_COMPOSE_FILE="${CONTROLLED_ONE_CONTAINER_COMPOSE_FILE:-$ROOT_DIR/docker-compose.controlled-one.yaml}"
SERVER_YAML="${SERVER_YAML:-$ROOT_DIR/backend/server.yaml}"

check_env
check_compose_file "$COMPOSE_FILE"
if [ -f "$ONE_CONTAINER_COMPOSE_FILE" ]; then
    check_compose_file "$ONE_CONTAINER_COMPOSE_FILE"
else
    warn "未找到一体化 Compose 文件：$ONE_CONTAINER_COMPOSE_FILE"
fi
check_server_yaml "$SERVER_YAML"

if command -v docker >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    if python3 "$ROOT_DIR/scripts/deploy/controlled-compose-preflight.py" "$COMPOSE_FILE"; then
        pass "最终三容器配置检查通过"
    else
        fail "最终三容器配置检查未通过"
    fi
else
    fail "缺少 Docker 或 Python，不能完成正式预检；离线检查请使用 controlled-static-check.sh"
fi

if [ "$failures" -gt 0 ]; then
    printf '\n受控部署预检未通过：%s 项失败。\n' "$failures" >&2
    exit 1
fi

printf '\n受控部署预检通过。\n'
