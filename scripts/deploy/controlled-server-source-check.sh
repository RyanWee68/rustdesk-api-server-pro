#!/bin/sh

set -eu

failures=0
warnings=0

fail() {
    failures=$((failures + 1))
    printf 'FAIL: ERR-2399 %s\n' "$1" >&2
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

contains() (
    pattern="$1"
    dir="$2"
    case "$pattern" in
        /*) pattern=${pattern#/} ;;
    esac
    rg -n --hidden \
        --glob '!target/**' \
        --glob '!.git/**' \
        --glob '*.rs' \
        --glob '*.toml' \
        --glob '*.sh' \
        --glob '*.yaml' \
        --glob '*.yml' \
        --glob 'Dockerfile*' \
        --regexp="$pattern" "$dir" >/dev/null 2>&1
)

contains_any() (
    dir="$1"
    shift
    for pattern in "$@"; do
        if contains "$pattern" "$dir"; then
            return 0
        fi
    done
    return 1
)

check_source_root() {
    dir="$1"

    if [ ! -d "$dir" ]; then
        fail "源码目录不存在：$dir"
        return 1
    fi

    if [ -f "$dir/Cargo.toml" ]; then
        pass "找到 Cargo.toml"
    else
        fail "未找到 Cargo.toml，传入目录不像 rustdesk-server 源码根目录"
    fi

    if contains_any "$dir" 'hbbs' 'Hbbs' 'rendezvous'; then
        pass "源码中存在 hbbs/rendezvous 相关实现线索"
    else
        fail "未找到 hbbs/rendezvous 相关实现线索"
    fi

    if contains_any "$dir" 'hbbr' 'Hbbr' 'relay'; then
        pass "源码中存在 hbbr/relay 相关实现线索"
    else
        fail "未找到 hbbr/relay 相关实现线索"
    fi
}

check_env_contract() {
    dir="$1"

    for name in MUST_LOGIN API_SERVER API_INTERNAL_SECRET API_TIMEOUT_SECONDS AUTH_CACHE_SECONDS RUSTDESK_KEY_DIR; do
        if contains "$name" "$dir"; then
            pass "源码包含环境变量：$name"
        else
            fail "源码缺少环境变量：$name"
        fi
    done

    if contains_any "$dir" 'X-Internal-Secret' 'Authorization: Bearer' 'API_INTERNAL_SECRET'; then
        pass "源码包含内部密钥请求头线索"
    else
        fail "未找到内部密钥请求头线索"
    fi
}

check_api_contract() {
    dir="$1"

    for path in \
        '/internal/rustdesk/connection/check' \
        '/internal/rustdesk/device/register' \
        '/internal/rustdesk/device/heartbeat' \
        '/internal/rustdesk/relay/grant/issue' \
        '/internal/rustdesk/relay/grant/consume'
    do
        if contains "$path" "$dir"; then
            pass "源码包含内部 API 调用点：$path"
        else
            fail "源码缺少内部 API 调用点：$path"
        fi
    done

    for binding in \
        'rendezvous_server.rs:register_device' \
        'rendezvous_server.rs:heartbeat' \
        'rendezvous_server.rs:check_connection' \
        'rendezvous_server.rs:issue_relay_grant' \
        'relay_server.rs:consume_relay_grant'
    do
        file=${binding%%:*}
        method=${binding#*:}
        if contains "$method" "$dir/src/$file"; then
            pass "源码入口已接线：$file $method"
        else
            fail "源码入口缺少接线：$file $method"
        fi
    done

    for field in rustdesk_id access_token fingerprint allow allow_relay cache_ttl expire_at; do
        if contains "$field" "$dir"; then
            pass "源码包含准入字段：$field"
        else
            warn "未找到准入字段：$field，需人工确认字段映射"
        fi
    done
}

check_fail_closed_contract() {
    dir="$1"

    for file in rendezvous_server.rs relay_server.rs; do
        if [ ! -f "$dir/src/$file" ]; then
            fail "源码缺少 WebSocket 入口：$file"
        elif contains_any "$dir/src/$file" 'X-Real-IP' 'X-Forwarded-For'; then
            fail "WebSocket 入口仍信任未认证的转发来源头：$file"
        else
            pass "WebSocket 入口忽略未认证的转发来源头：$file"
        fi
        if ! contains 'controlled_ws::accept' "$dir/src/$file"; then
            fail "WebSocket 入口缺少原生 TLS 传输校验：$file"
        fi
    done
    if [ -f "$dir/src/controlled_ws.rs" ] &&
        contains 'WSS_CERT_FILE' "$dir/src/controlled_ws.rs" &&
        contains 'WSS_KEY_FILE' "$dir/src/controlled_ws.rs" &&
        contains 'WSS 未配置证书，拒绝 WebSocket 连接' "$dir/src/controlled_ws.rs"; then
        pass "原生 WSS 显式证书配置且禁用时拒绝连接"
    else
        fail "缺少原生 WSS 证书与默认拒绝入口"
    fi

    if contains_any "$dir" 'MUST_LOGIN' 'must_login'; then
        pass "源码包含强制登录开关线索"
    else
        fail "未找到强制登录开关线索"
    fi

    if contains_any "$dir" 'fail.closed' 'fail_closed' 'default.*deny' 'deny.*default' 'refuse' 'reject'; then
        pass "源码包含默认拒绝或拒绝连接线索"
    else
        warn "未找到明确 fail-closed 线索，需人工确认 API 失败时是否拒绝新连接"
    fi

    if contains_any "$dir" 'timeout' 'API_TIMEOUT_SECONDS'; then
        pass "源码包含 API 超时控制线索"
    else
        fail "未找到 API 超时控制线索"
    fi

    if contains_any "$dir" 'AUTH_CACHE_SECONDS' 'cache_ttl' 'CacheTTL' 'ttl'; then
        pass "源码包含授权缓存线索"
    else
        warn "未找到授权缓存线索，需人工确认禁用设备后的失效时间"
    fi
}

check_sensitive_logging() {
    dir="$1"

    if contains_any "$dir" \
        '(println!|eprintln!|log::(trace|debug|info|warn|error)!|tracing::(trace|debug|info|warn|error)!).*API_INTERNAL_SECRET' \
        '(println!|eprintln!|log::(trace|debug|info|warn|error)!|tracing::(trace|debug|info|warn|error)!).*api_internal_secret'
    then
        fail "源码疑似记录 API_INTERNAL_SECRET 到日志"
    else
        pass "未发现 API_INTERNAL_SECRET 明文日志线索"
    fi

    if contains_any "$dir" \
        '(println!|eprintln!|log::(trace|debug|info|warn|error)!|tracing::(trace|debug|info|warn|error)!).*access_token' \
        '(println!|eprintln!|log::(trace|debug|info|warn|error)!|tracing::(trace|debug|info|warn|error)!).*ACCESS_TOKEN'
    then
        fail "源码疑似记录 access_token 到日志"
    else
        pass "未发现 access_token 明文日志线索"
    fi
}

check_registration_window() {
    dir="$1"
    if contains 'periodic_registration_does_not_extend_rate_window' "$dir/src/rendezvous_server.rs"; then
        pass "源码包含持续注册、突发限流及窗口恢复回归"
    else
        fail "源码缺少注册限流窗口回归，可能遗漏已验收修复"
    fi
}

SOURCE_DIR="${1:-${RUSTDESK_SERVER_SOURCE_DIR:-}}"

if [ -z "$SOURCE_DIR" ]; then
    fail "未提供源码目录，请传入参数或设置 RUSTDESK_SERVER_SOURCE_DIR"
else
    if require_cmd rg; then
        check_source_root "$SOURCE_DIR"
        check_env_contract "$SOURCE_DIR"
        check_api_contract "$SOURCE_DIR"
        check_fail_closed_contract "$SOURCE_DIR"
        check_sensitive_logging "$SOURCE_DIR"
        check_registration_window "$SOURCE_DIR"
    fi
fi

if [ "$failures" -gt 0 ]; then
    printf '\n受控 rustdesk-server 源码检查未通过：%s 项失败，%s 项警告。\n' "$failures" "$warnings" >&2
    exit 1
fi

printf '\n受控 rustdesk-server 源码检查通过：%s 项警告。\n' "$warnings"
