#!/bin/sh

set -eu

failures=0
warnings=0

fail() {
    failures=$((failures + 1))
    printf 'FAIL: ERR-2398 %s\n' "$1" >&2
}

warn() {
    warnings=$((warnings + 1))
    printf 'WARN: %s\n' "$1" >&2
}

pass() {
    printf 'PASS: %s\n' "$1"
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        fail "缺少命令：$1"
        return 1
    fi
    return 0
}

post_json() {
    path="$1"
    secret="$2"
    body="$3"
    url="${API_BASE_URL}${path}"
    if [ -n "$secret" ]; then
        curl -sS -m "${HTTP_TIMEOUT_SECONDS:-5}" \
            -H "Content-Type: application/json" \
            -H "X-Internal-Secret: $secret" \
            -d "$body" \
            "$url" || true
    else
        curl -sS -m "${HTTP_TIMEOUT_SECONDS:-5}" \
            -H "Content-Type: application/json" \
            -d "$body" \
            "$url" || true
    fi
}

expect_code() {
    label="$1"
    response="$2"
    expected="$3"
    case "$response" in
        *"\"code\":\"$expected\""*|*"\"code\": \"$expected\""*)
            pass "$label 返回 $expected"
            ;;
        "")
            fail "$label 无响应"
            ;;
        *)
            fail "$label 未返回 $expected，响应：$response"
            ;;
    esac
}

expect_not_code() {
    label="$1"
    response="$2"
    unexpected="$3"
    case "$response" in
        *"\"code\":\"$unexpected\""*|*"\"code\": \"$unexpected\""*)
            fail "$label 不应返回 $unexpected，响应：$response"
            ;;
        "")
            fail "$label 无响应"
            ;;
        *)
            pass "$label 已进入业务准入逻辑"
            ;;
    esac
}

print_response() {
    label="$1"
    response="$2"
    if [ "${VERBOSE:-0}" = "1" ]; then
        printf '\n[%s]\n%s\n' "$label" "$response"
    fi
}

API_BASE_URL="${API_BASE_URL:-http://127.0.0.1:12345}"
RUSTDESK_API_INTERNAL_SECRET="${RUSTDESK_API_INTERNAL_SECRET:-}"
SMOKE_RUSTDESK_ID="${SMOKE_RUSTDESK_ID:-smoke-device-001}"
SMOKE_UUID="${SMOKE_UUID:-smoke-uuid-001}"
SMOKE_FINGERPRINT="${SMOKE_FINGERPRINT:-smoke-fingerprint-001}"
SMOKE_TOKEN="${SMOKE_TOKEN:-smoke-invalid-token}"

API_BASE_URL="${API_BASE_URL%/}"

require_cmd curl || true

if [ -z "$RUSTDESK_API_INTERNAL_SECRET" ]; then
    fail "未设置 RUSTDESK_API_INTERNAL_SECRET"
elif [ "${#RUSTDESK_API_INTERNAL_SECRET}" -lt 32 ]; then
    fail "RUSTDESK_API_INTERNAL_SECRET 长度不足 32 字符"
fi

register_body='{"rustdesk_id":"'"$SMOKE_RUSTDESK_ID"'","id":"'"$SMOKE_RUSTDESK_ID"'","uuid":"'"$SMOKE_UUID"'","fingerprint":"'"$SMOKE_FINGERPRINT"'","hostname":"smoke-host","username":"smoke-user","os":"linux","client_version":"smoke","source_ip":"127.0.0.1"}'
auth_body='{"rustdesk_id":"'"$SMOKE_RUSTDESK_ID"'","id":"'"$SMOKE_RUSTDESK_ID"'","uuid":"'"$SMOKE_UUID"'","fingerprint":"'"$SMOKE_FINGERPRINT"'","access_token":"'"$SMOKE_TOKEN"'","client_version":"smoke","source_ip":"127.0.0.1"}'
heartbeat_body='{"rustdesk_id":"'"$SMOKE_RUSTDESK_ID"'","id":"'"$SMOKE_RUSTDESK_ID"'","uuid":"'"$SMOKE_UUID"'","client_version":"smoke","source_ip":"127.0.0.1","conn_count":0}'
relay_body='{"rustdesk_id":"'"$SMOKE_RUSTDESK_ID"'","id":"'"$SMOKE_RUSTDESK_ID"'","uuid":"'"$SMOKE_UUID"'","access_token":"'"$SMOKE_TOKEN"'","source_ip":"127.0.0.1"}'
connection_body='{"target_id":"'"$SMOKE_RUSTDESK_ID"'","access_token":"'"$SMOKE_TOKEN"'","source_ip":"127.0.0.1","relay":true}'
relay_issue_body='{"target_id":"'"$SMOKE_RUSTDESK_ID"'","access_token":"'"$SMOKE_TOKEN"'","session_uuid":"123e4567-e89b-42d3-a456-426614174000","source_ip":"127.0.0.1","target_ip":"127.0.0.1"}'
relay_consume_body='{"session_uuid":"123e4567-e89b-42d3-a456-426614174000","peer_ip":"127.0.0.1"}'

if [ "$failures" -eq 0 ]; then
    no_secret_response="$(post_json /internal/rustdesk/device/register "" "$register_body")"
    print_response "register without secret" "$no_secret_response"
    expect_code "无内部密钥注册请求" "$no_secret_response" "ERR-2301"

    wrong_secret_response="$(post_json /internal/rustdesk/device/register "wrong-secret" "$register_body")"
    print_response "register with wrong secret" "$wrong_secret_response"
    expect_code "错误内部密钥注册请求" "$wrong_secret_response" "ERR-2301"

    register_response="$(post_json /internal/rustdesk/device/register "$RUSTDESK_API_INTERNAL_SECRET" "$register_body")"
    print_response "register with correct secret" "$register_response"
    expect_not_code "正确内部密钥注册请求" "$register_response" "ERR-2301"

    auth_response="$(post_json /internal/rustdesk/auth "$RUSTDESK_API_INTERNAL_SECRET" "$auth_body")"
    print_response "auth with correct secret" "$auth_response"
    expect_not_code "正确内部密钥鉴权请求" "$auth_response" "ERR-2301"

    heartbeat_response="$(post_json /internal/rustdesk/device/heartbeat "$RUSTDESK_API_INTERNAL_SECRET" "$heartbeat_body")"
    print_response "heartbeat with correct secret" "$heartbeat_response"
    expect_not_code "正确内部密钥心跳请求" "$heartbeat_response" "ERR-2301"

    relay_response="$(post_json /internal/rustdesk/relay/check "$RUSTDESK_API_INTERNAL_SECRET" "$relay_body")"
    print_response "relay check with correct secret" "$relay_response"
    expect_not_code "正确内部密钥中继请求" "$relay_response" "ERR-2301"

    connection_no_secret="$(post_json /internal/rustdesk/connection/check "" "$connection_body")"
    expect_code "无内部密钥双端连接请求" "$connection_no_secret" "ERR-2301"
    connection_response="$(post_json /internal/rustdesk/connection/check "$RUSTDESK_API_INTERNAL_SECRET" "$connection_body")"
    expect_not_code "正确内部密钥双端连接请求" "$connection_response" "ERR-2301"

    relay_issue_no_secret="$(post_json /internal/rustdesk/relay/grant/issue "" "$relay_issue_body")"
    expect_code "无内部密钥中继签发请求" "$relay_issue_no_secret" "ERR-2301"
    relay_issue_response="$(post_json /internal/rustdesk/relay/grant/issue "$RUSTDESK_API_INTERNAL_SECRET" "$relay_issue_body")"
    expect_code "同 IP 中继会话签发请求" "$relay_issue_response" "ERR-2315"

    relay_consume_no_secret="$(post_json /internal/rustdesk/relay/grant/consume "" "$relay_consume_body")"
    expect_code "无内部密钥中继核销请求" "$relay_consume_no_secret" "ERR-2301"
    relay_consume_response="$(post_json /internal/rustdesk/relay/grant/consume "$RUSTDESK_API_INTERNAL_SECRET" "$relay_consume_body")"
    expect_code "未签发中继会话核销" "$relay_consume_response" "ERR-2315"

    if [ -n "$auth_response" ]; then
        case "$auth_response" in
            *"\"code\":\"ERR-2303\""*|*"\"code\": \"ERR-2303\""*)
                pass "无真实客户端 token 时鉴权返回 ERR-2303 符合 smoke 预期"
                ;;
            *"\"allow\":true"*|*"\"allow\": true"*)
                warn "鉴权请求返回允许，请确认 SMOKE_TOKEN 是否使用了真实客户端 token"
                ;;
            *)
                warn "鉴权请求返回非 ERR-2303，需结合当前设备审批状态人工确认"
                ;;
        esac
    fi
fi

if [ "$failures" -gt 0 ]; then
    printf '\nRustDesk 内部准入 smoke 未通过：%s 项失败，%s 项警告。\n' "$failures" "$warnings" >&2
    exit 1
fi

printf '\nRustDesk 内部准入 smoke 通过：%s 项警告。\n' "$warnings"
