#!/bin/sh

set -eu

failures=0

fail() {
    failures=$((failures + 1))
    printf 'FAIL: ERR-239C %s\n' "$1" >&2
}

pass() {
    printf 'PASS: %s\n' "$1"
}

contains() {
    pattern="$1"
    file="$2"
    grep -Eq "$pattern" "$file"
}

ROOT_DIR="${1:-$(pwd)}"
TEMPLATE="$ROOT_DIR/templates/rustdesk-server-controlled/controlled_admission.rs"
README="$ROOT_DIR/templates/rustdesk-server-controlled/README.md"
MANIFEST="$ROOT_DIR/templates/rustdesk-server-controlled/Cargo.toml"

if [ -f "$TEMPLATE" ]; then
    pass "找到 Rust 准入客户端模板"
else
    fail "找不到 Rust 准入客户端模板：$TEMPLATE"
fi

if [ -f "$README" ]; then
    pass "找到模板说明文档"
else
    fail "找不到模板说明文档：$README"
fi

if [ -f "$MANIFEST" ]; then
    pass "找到模板 Cargo 清单"
else
    fail "找不到模板 Cargo 清单：$MANIFEST"
fi

if [ -f "$TEMPLATE" ]; then
    for name in MUST_LOGIN API_SERVER API_INTERNAL_SECRET API_TIMEOUT_SECONDS AUTH_CACHE_SECONDS; do
        if contains "$name" "$TEMPLATE"; then
            pass "模板包含环境变量：$name"
        else
            fail "模板缺少环境变量：$name"
        fi
    done

    for path in \
        '/internal/rustdesk/auth' \
        '/internal/rustdesk/device/register' \
        '/internal/rustdesk/device/heartbeat' \
        '/internal/rustdesk/relay/check' \
        '/internal/rustdesk/connection/check' \
        '/internal/rustdesk/relay/grant/issue' \
        '/internal/rustdesk/relay/grant/consume'
    do
        if contains "$path" "$TEMPLATE"; then
            pass "模板包含内部 API 路径：$path"
        else
            fail "模板缺少内部 API 路径：$path"
        fi
    done

    for symbol in RegisterRequest AuthRequest HeartbeatRequest RelayCheckRequest ConnectionCheckRequest AdmissionResponse AdmissionPolicy ControlledAdmissionClient; do
        if contains "$symbol" "$TEMPLATE"; then
            pass "模板包含类型：$symbol"
        else
            fail "模板缺少类型：$symbol"
        fi
    done

    if contains 'X-Internal-Secret' "$TEMPLATE"; then
        pass "模板使用内部密钥请求头"
    else
        fail "模板未使用内部密钥请求头"
    fi

    if contains 'deny_internal' "$TEMPLATE"; then
        pass "模板包含 fail-closed 默认拒绝路径"
    else
        fail "模板缺少 fail-closed 默认拒绝路径"
    fi

    if contains '(println!|eprintln!|log::(trace|debug|info|warn|error)!|tracing::(trace|debug|info|warn|error)!).*access_token' "$TEMPLATE"; then
        fail "模板疑似记录 access_token"
    else
        pass "模板未发现 access_token 明文日志"
    fi

    if contains '(println!|eprintln!|log::(trace|debug|info|warn|error)!|tracing::(trace|debug|info|warn|error)!).*api_internal_secret' "$TEMPLATE"; then
        fail "模板疑似记录 API_INTERNAL_SECRET"
    else
        pass "模板未发现 API_INTERNAL_SECRET 明文日志"
    fi
fi

if [ -f "$MANIFEST" ]; then
    for dependency in anyhow reqwest serde tokio; do
        if contains "$dependency" "$MANIFEST"; then
            pass "Cargo 清单包含依赖：$dependency"
        else
            fail "Cargo 清单缺少依赖：$dependency"
        fi
    done

    if contains 'path = "controlled_admission.rs"' "$MANIFEST"; then
        pass "Cargo 清单指向准入模板源码"
    else
        fail "Cargo 清单未指向准入模板源码"
    fi
fi

if [ "$failures" -gt 0 ]; then
    printf '\n受控 rustdesk-server 模板检查未通过：%s 项失败。\n' "$failures" >&2
    exit 1
fi

printf '\n受控 rustdesk-server 模板检查通过。\n'
