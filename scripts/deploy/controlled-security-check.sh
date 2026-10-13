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
    body='{"rustdesk_id":"preflight-device","device_fingerprint":"preflight-fingerprint","client_version":"preflight"}'
    if [ -n "$secret" ]; then
        curl -sS -m "${HTTP_TIMEOUT_SECONDS:-5}" \
            -H "Content-Type: application/json" \
            -H "X-Internal-Secret: $secret" \
            -d "$body" \
            "$url"
    else
        curl -sS -m "${HTTP_TIMEOUT_SECONDS:-5}" \
            -H "Content-Type: application/json" \
            -d "$body" \
            "$url"
    fi
}

check_internal_api_auth() {
    api_base="${API_BASE_URL:-http://127.0.0.1:12345}"
    url="$api_base/internal/rustdesk/device/register"

    if ! have_cmd curl; then
        warn "未找到 curl，跳过内部准入接口鉴权检查"
        return
    fi

    no_secret_response="$(http_post "$url" "" 2>/dev/null || true)"
    case "$no_secret_response" in
        *ERR-2301*|*ERR2301*)
            pass "内部接口未携带密钥时拒绝访问"
            ;;
        "")
            fail "内部接口无密钥请求没有得到可识别响应，请确认 API 是否运行：$url"
            ;;
        *)
            fail "内部接口无密钥请求未返回 ERR-2301"
            ;;
    esac

    wrong_secret_response="$(http_post "$url" "wrong-internal-secret-for-security-check" 2>/dev/null || true)"
    case "$wrong_secret_response" in
        *ERR-2301*|*ERR2301*)
            pass "内部接口错误密钥时拒绝访问"
            ;;
        "")
            fail "内部接口错误密钥请求没有得到可识别响应，请确认 API 是否运行：$url"
            ;;
        *)
            fail "内部接口错误密钥请求未返回 ERR-2301"
            ;;
    esac

    if [ -n "${RUSTDESK_API_INTERNAL_SECRET:-}" ]; then
        correct_response="$(http_post "$url" "$RUSTDESK_API_INTERNAL_SECRET" 2>/dev/null || true)"
        case "$correct_response" in
            *ERR-2301*|*ERR2301*|"")
                fail "内部接口正确密钥未进入准入逻辑"
                ;;
            *)
                pass "内部接口正确密钥可以进入准入逻辑"
                ;;
        esac
    else
        warn "未设置 RUSTDESK_API_INTERNAL_SECRET，跳过正确密钥路径检查"
    fi
}

check_port_closed() {
    host="$1"
    port="$2"
    label="$3"
    if have_cmd nc; then
        if nc -z -w "${PORT_TIMEOUT_SECONDS:-2}" "$host" "$port" >/dev/null 2>&1; then
            fail "$label 仍可连接：$host:$port"
        else
            pass "$label 不可连接：$host:$port"
        fi
        return
    fi
    if have_cmd timeout && have_cmd bash; then
        if timeout "${PORT_TIMEOUT_SECONDS:-2}" bash -c "cat < /dev/null > /dev/tcp/$host/$port" >/dev/null 2>&1; then
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
