#!/bin/sh

set -eu

failures=0
warnings=0

fail() {
    failures=$((failures + 1))
    printf 'FAIL: ERR-2394 %s\n' "$1" >&2
}

warn() {
    warnings=$((warnings + 1))
    printf 'WARN: %s\n' "$1" >&2
}

pass() {
    printf 'PASS: %s\n' "$1"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

http_post() {
    url="$1"
    secret="$2"
    body='{}'
    if [ -n "$secret" ]; then
        curl -sS -m "${HTTP_TIMEOUT_SECONDS:-5}" -w '\n%{http_code}' \
            -H "Content-Type: application/json" \
            -H "X-Internal-Secret: $secret" \
            -d "$body" \
            "$url"
    else
        curl -sS -m "${HTTP_TIMEOUT_SECONDS:-5}" -w '\n%{http_code}' \
            -H "Content-Type: application/json" \
            -d "$body" \
            "$url"
    fi
}

check_internal_response() {
    url="$1"
    secret="$2"
    expected_status="$3"
    expected_code="$4"
    label="$5"

    if ! result="$(http_post "$url" "$secret" 2>/dev/null)"; then
        fail "$label 请求失败，请确认 API 是否运行：$url"
        return
    fi
    status="$(printf '%s\n' "$result" | tail -n 1)"
    response="$(printf '%s\n' "$result" | sed '$d')"
    if [ "$status" != "$expected_status" ]; then
        fail "$label 返回 HTTP $status，预期 $expected_status"
        return
    fi
    if ! printf '%s' "$response" | "$json_parser" -c \
        'import json,sys; data=json.load(sys.stdin); raise SystemExit(0 if data.get("allow") is False and data.get("code") == sys.argv[1] else 1)' \
        "$expected_code" >/dev/null 2>&1; then
        fail "$label 未返回 allow=false 和 $expected_code"
        return
    fi
    pass "$label"
}

check_internal_api_auth() {
    api_base="${API_BASE_URL:-http://127.0.0.1:12345}"
    url="$api_base/internal/rustdesk/auth"

    if ! have_cmd curl; then
        warn "未找到 curl，跳过内部准入接口鉴权检查"
        return
    fi
    json_parser=""
    if have_cmd python3 && python3 --version >/dev/null 2>&1; then
        json_parser="python3"
    elif have_cmd python && python --version >/dev/null 2>&1; then
        json_parser="python"
    else
        fail "未找到可执行的 python3/python，无法严格解析内部接口响应"
        return
    fi

    check_internal_response "$url" "" 401 "ERR-2301" "内部接口未携带密钥时拒绝访问"
    check_internal_response "$url" "wrong-internal-secret-for-security-check" 401 "ERR-2301" "内部接口错误密钥时拒绝访问"

    if [ -n "${RUSTDESK_API_INTERNAL_SECRET:-}" ]; then
        check_internal_response "$url" "$RUSTDESK_API_INTERNAL_SECRET" 200 "ERR-2302" "内部接口正确密钥进入准入逻辑"
    else
        warn "未设置 RUSTDESK_API_INTERNAL_SECRET，跳过正确密钥路径检查"
    fi
}

validate_endpoint() {
    host="$1"
    port="$2"
    label="$3"
    case "$host" in
        ""|*[!A-Za-z0-9._:%-]*)
            fail "$label 的主机名包含非法字符"
            return 1
            ;;
    esac
    case "$port" in
        ""|*[!0-9]*)
            fail "$label 的端口不是有效数字：$port"
            return 1
            ;;
        ??????*)
            fail "$label 的端口超出有效范围：$port"
            return 1
            ;;
    esac
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        fail "$label 的端口超出有效范围：$port"
        return 1
    fi
}

check_port_closed() {
    host="$1"
    port="$2"
    label="$3"
    if ! validate_endpoint "$host" "$port" "$label"; then
        return 0
    fi
    if have_cmd nc; then
        if nc -z -w "${PORT_TIMEOUT_SECONDS:-2}" "$host" "$port" >/dev/null 2>&1; then
            fail "$label 仍可连接：$host:$port"
        else
            pass "$label 不可连接：$host:$port"
        fi
        return
    fi
    if have_cmd timeout && have_cmd bash; then
        if timeout "${PORT_TIMEOUT_SECONDS:-2}" bash -c 'cat < /dev/null > "/dev/tcp/$1/$2"' sh "$host" "$port" >/dev/null 2>&1; then
            fail "$label 仍可连接：$host:$port"
        else
            pass "$label 不可连接：$host:$port"
        fi
        return
    fi
    warn "未找到 nc 或 bash /dev/tcp，跳过端口检查：$label $host:$port"
}

check_port_open() {
    host="$1"
    port="$2"
    label="$3"
    if ! validate_endpoint "$host" "$port" "$label"; then
        return 0
    fi
    if have_cmd nc; then
        if nc -z -w "${PORT_TIMEOUT_SECONDS:-2}" "$host" "$port" >/dev/null 2>&1; then
            pass "$label 可连接：$host:$port"
        else
            fail "$label 不可连接：$host:$port"
        fi
        return
    fi
    warn "未找到 nc，跳过开放端口检查：$label $host:$port"
}

check_public_exposure() {
    public_host="${PUBLIC_HOST:-}"
    if [ -z "$public_host" ]; then
        warn "未设置 PUBLIC_HOST，跳过公网暴露实测"
        return
    fi

    check_port_open "$public_host" "${RUSTDESK_HBBS_TCP_21115:-21115}" "受控 hbbs 21115"
    check_port_open "$public_host" "${RUSTDESK_HBBS_TCP_21116:-21116}" "受控 hbbs 21116"
    check_port_open "$public_host" "${RUSTDESK_HBBR_TCP_21117:-21117}" "受控 hbbr 21117"

    check_port_closed "$public_host" "${FNOS_ADMIN_HTTP_PORT:-12346}" "管理后台公网端口"
    check_port_closed "$public_host" "${RUSTDESK_HBBS_WEB_PORT:-21118}" "hbbs Web 公网端口"
    check_port_closed "$public_host" "${RUSTDESK_HBBR_WEB_PORT:-21119}" "hbbr Web 公网端口"
}

check_old_service_shutdown() {
    old_host="${OLD_RUSTDESK_HOST:-}"
    if [ -z "$old_host" ]; then
        warn "未设置 OLD_RUSTDESK_HOST，跳过旧裸服务下线实测"
        return
    fi

    check_port_closed "$old_host" "${OLD_RUSTDESK_HBBS_21115:-21115}" "旧裸 hbbs 21115"
    check_port_closed "$old_host" "${OLD_RUSTDESK_HBBS_21116:-21116}" "旧裸 hbbs 21116"
    check_port_closed "$old_host" "${OLD_RUSTDESK_HBBR_21117:-21117}" "旧裸 hbbr 21117"
}

check_internal_api_auth
check_public_exposure
check_old_service_shutdown

if [ "$failures" -gt 0 ]; then
    printf '\n受控部署安全检查未通过：%s 项失败，%s 项警告。\n' "$failures" "$warnings" >&2
    exit 1
fi

printf '\n受控部署安全检查通过：%s 项警告。\n' "$warnings"
