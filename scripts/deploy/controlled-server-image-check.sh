#!/bin/sh

set -eu

failures=0
warnings=0

fail() {
    failures=$((failures + 1))
    printf 'FAIL: ERR-2397 %s\n' "$1" >&2
}

warn() {
    warnings=$((warnings + 1))
    printf 'WARN: %s\n' "$1" >&2
}

pass() {
    printf 'PASS: %s\n' "$1"
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        fail "未找到 docker 命令，无法检查受控 rustdesk-server 镜像"
        return 1
    fi
    return 0
}

run_in_image() {
    image="$1"
    shift
    docker run --rm --entrypoint sh "$image" -c "$*"
}

check_image_basics() {
    image="$1"

    if run_in_image "$image" 'test -x /usr/local/bin/hbbs'; then
        pass "镜像包含 /usr/local/bin/hbbs"
    else
        fail "镜像缺少可执行 /usr/local/bin/hbbs"
    fi

    if run_in_image "$image" 'test -x /usr/local/bin/hbbr'; then
        pass "镜像包含 /usr/local/bin/hbbr"
    else
        fail "镜像缺少可执行 /usr/local/bin/hbbr"
    fi

    if run_in_image "$image" '/usr/local/bin/hbbs --help >/tmp/hbbs.help 2>&1 || true; test -s /tmp/hbbs.help'; then
        pass "hbbs 可输出帮助信息"
    else
        warn "hbbs 未输出帮助信息，需人工确认参数和环境变量支持"
    fi

    if run_in_image "$image" '/usr/local/bin/hbbr --help >/tmp/hbbr.help 2>&1 || true; test -s /tmp/hbbr.help'; then
        pass "hbbr 可输出帮助信息"
    else
        warn "hbbr 未输出帮助信息，需人工确认参数和环境变量支持"
    fi
}

check_env_contract() {
    image="$1"
    # 该检查只验证镜像能在这些环境变量存在时启动到解析阶段。
    # 真正的 API 调用点和 fail-closed 行为必须通过真实客户端 PoC 验收确认。
    if docker run --rm \
        -e MUST_LOGIN=1 \
        -e API_SERVER=http://127.0.0.1:9 \
        -e API_INTERNAL_SECRET=12345678901234567890123456789012 \
        -e API_TIMEOUT_SECONDS=1 \
        -e AUTH_CACHE_SECONDS=30 \
        -e RUSTDESK_KEY_DIR=/tmp/rustdesk-key \
        --entrypoint sh "$image" \
        -c 'mkdir -p /tmp/rustdesk-key; timeout 3 /usr/local/bin/hbbs >/tmp/hbbs.log 2>&1 || true; test -s /tmp/hbbs.log' >/dev/null 2>&1; then
        pass "hbbs 可在受控环境变量下启动到日志输出阶段"
    else
        warn "hbbs 受控环境变量启动检查未得到日志输出，需人工检查镜像 entrypoint/参数"
    fi

    if docker run --rm \
        -e MUST_LOGIN=1 \
        -e API_SERVER=http://127.0.0.1:9 \
        -e API_INTERNAL_SECRET=12345678901234567890123456789012 \
        -e API_TIMEOUT_SECONDS=1 \
        -e AUTH_CACHE_SECONDS=30 \
        -e RUSTDESK_KEY_DIR=/tmp/rustdesk-key \
        --entrypoint sh "$image" \
        -c 'mkdir -p /tmp/rustdesk-key; timeout 3 /usr/local/bin/hbbr >/tmp/hbbr.log 2>&1 || true; test -s /tmp/hbbr.log' >/dev/null 2>&1; then
        pass "hbbr 可在受控环境变量下启动到日志输出阶段"
    else
        warn "hbbr 受控环境变量启动检查未得到日志输出，需人工检查镜像 entrypoint/参数"
    fi
}

IMAGE="${1:-${RUSTDESK_CONTROLLED_SERVER_IMAGE:-}}"

if [ -z "$IMAGE" ]; then
    fail "未提供镜像名，请传入参数或设置 RUSTDESK_CONTROLLED_SERVER_IMAGE"
else
    if require_docker; then
        check_image_basics "$IMAGE"
        check_env_contract "$IMAGE"
    fi
fi

if [ "$failures" -gt 0 ]; then
    printf '\n受控 rustdesk-server 镜像检查未通过：%s 项失败，%s 项警告。\n' "$failures" "$warnings" >&2
    exit 1
fi

printf '\n受控 rustdesk-server 镜像检查通过：%s 项警告。\n' "$warnings"
