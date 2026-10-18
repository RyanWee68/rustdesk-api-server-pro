#!/bin/sh

set -u

ROOT_DIR="${1:-$(pwd)}"
failures=0
warnings=0
skips=0

fail() {
    failures=$((failures + 1))
    printf 'FAIL: ERR-239E %s\n' "$1" >&2
}

warn() {
    warnings=$((warnings + 1))
    printf 'WARN: %s\n' "$1" >&2
}

skip() {
    skips=$((skips + 1))
    printf 'SKIP: %s\n' "$1"
}

pass() {
    printf 'PASS: %s\n' "$1"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

run_required() {
    label="$1"
    shift
    printf '\n[%s]\n' "$label"
    if "$@"; then
        pass "$label"
    else
        fail "$label 未通过"
    fi
}

run_optional() {
    label="$1"
    reason="$2"
    shift 2
    printf '\n[%s]\n' "$label"
    if "$@"; then
        pass "$label"
    else
        warn "$label 未通过：$reason"
    fi
}

if [ ! -d "$ROOT_DIR" ]; then
    fail "仓库目录不存在：$ROOT_DIR"
    printf '\n本地验收未通过：%s 项失败，%s 项警告，%s 项跳过。\n' "$failures" "$warnings" "$skips" >&2
    exit 1
fi

if [ ! -f "$ROOT_DIR/docs/CONTROLLED_RUSTDESK_DEPLOYMENT_PLAN.md" ]; then
    fail "传入目录不像当前 RustDeskWeb 仓库：$ROOT_DIR"
fi

run_required "受控部署静态检查" sh "$ROOT_DIR/scripts/deploy/controlled-static-check.sh" "$ROOT_DIR"
run_required "受控 Rust 模板检查" sh "$ROOT_DIR/scripts/deploy/controlled-template-check.sh" "$ROOT_DIR"
run_required "受控部署工具自测" sh "$ROOT_DIR/scripts/deploy/controlled-tooling-selftest.sh" "$ROOT_DIR"

python_bin=""
if have_cmd python3 && python3 --version >/dev/null 2>&1; then
    python_bin="python3"
elif have_cmd python && python --version >/dev/null 2>&1; then
    python_bin="python"
fi
if [ -n "$python_bin" ]; then
    run_required "中继协议探针自测" "$python_bin" "$ROOT_DIR/scripts/deploy/controlled-relay-protocol-acceptance.py" --self-test
    run_required "hbbs 协议探针自测" "$python_bin" "$ROOT_DIR/scripts/deploy/controlled-hbbs-protocol-acceptance.py" --self-test
    run_required "WSS 公网门禁与回环 TLS 自测" "$python_bin" "$ROOT_DIR/scripts/deploy/controlled-wss-protocol-selftest.py"
    run_required "SQLite 迁移演练自检" "$python_bin" "$ROOT_DIR/scripts/deploy/controlled-sqlite-migration-rehearsal.py" --self-test
    run_required "最终 Compose 配置预检自测" "$python_bin" "$ROOT_DIR/scripts/deploy/controlled-compose-preflight.py" --self-test
else
    skip "未检测到可执行的 python3/python，跳过 Python 自测"
fi

printf '\n[Shell 语法检查]\n'
for script in \
    "$ROOT_DIR/docker/start.sh" \
    "$ROOT_DIR/docker/controlled-entrypoint.sh" \
    "$ROOT_DIR/docker/controlled-healthcheck.sh" \
    "$ROOT_DIR/docker/mock-rustdesk-server/hbbs" \
    "$ROOT_DIR/docker/mock-rustdesk-server/hbbr" \
    "$ROOT_DIR/scripts/deploy/controlled-admission-smoke.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-api-smoke.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-compose-smoke.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-real-compose-smoke.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-three-compose-smoke.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-fork-bootstrap.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-lan-poc.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-local-acceptance.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-offline-import-acceptance.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-preflight.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-server-image-check.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-server-source-check.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-static-check.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-template-check.sh" \
    "$ROOT_DIR/scripts/deploy/controlled-tooling-selftest.sh"
do
    if [ -f "$script" ]; then
        if sh -n "$script"; then
            pass "语法通过：$script"
        else
            fail "脚本语法错误：$script"
        fi
    else
        fail "找不到脚本：$script"
    fi
done

# 使用隔离副本，避免 Cargo.lock 和 target 中间产物写入仓库。
run_rust_tests() (
    set -eu
    rust_parent="$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)"
    rust_work="$(mktemp -d "$rust_parent/rustdesk-controlled-rust.XXXXXX")"
    cleanup_rust_work() {
        [ -d "$rust_work" ] || return
        resolved_work="$(CDPATH= cd -- "$rust_work" && pwd -P)"
        case "$resolved_work" in
            "$rust_parent"/rustdesk-controlled-rust.*) rm -rf -- "$resolved_work" ;;
            *) printf 'ERR-239E 拒绝清理非预期 Rust 临时目录：%s\n' "$resolved_work" >&2 ;;
        esac
    }
    trap cleanup_rust_work EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cp "$ROOT_DIR/templates/rustdesk-server-controlled/Cargo.toml" "$ROOT_DIR/templates/rustdesk-server-controlled/controlled_admission.rs" "$rust_work/"
    cargo test --manifest-path "$rust_work/Cargo.toml"
)

if have_cmd cargo; then
    run_required "Rust 模板编译及 HTTP 回归" run_rust_tests
else
    skip "未检测到 cargo，跳过 Rust 模板类型检查"
fi

if [ -n "${RUSTDESK_SERVER_SOURCE_DIR:-}" ]; then
    run_required "受控 rustdesk-server 源码接入检查" \
        sh "$ROOT_DIR/scripts/deploy/controlled-server-source-check.sh" "$RUSTDESK_SERVER_SOURCE_DIR"
else
    skip "未设置 RUSTDESK_SERVER_SOURCE_DIR，跳过真实 fork 源码接入检查"
fi

if [ -n "${RUSTDESK_API_INTERNAL_SECRET:-}" ] && [ -n "${RUSTDESK_CONTROLLED_SERVER_IMAGE:-}" ]; then
    run_required "部署前预检" sh "$ROOT_DIR/scripts/deploy/controlled-preflight.sh" "$ROOT_DIR"
else
    skip "未设置 RUSTDESK_API_INTERNAL_SECRET/RUSTDESK_CONTROLLED_SERVER_IMAGE，跳过部署前预检"
fi

if [ -n "${API_BASE_URL:-}" ] && [ -n "${RUSTDESK_API_INTERNAL_SECRET:-}" ]; then
    run_required "内部准入 API smoke" sh "$ROOT_DIR/scripts/deploy/controlled-admission-smoke.sh"
else
    skip "未设置 API_BASE_URL/RUSTDESK_API_INTERNAL_SECRET，跳过内部准入 API smoke"
fi

if [ "${RUN_LOCAL_API_SMOKE:-0}" = "1" ]; then
    run_required "临时 API 内部准入 smoke" sh "$ROOT_DIR/scripts/deploy/controlled-api-smoke.sh" "$ROOT_DIR"
else
    skip "未设置 RUN_LOCAL_API_SMOKE=1，跳过临时 API 内部准入 smoke"
fi

if have_cmd docker; then
    if [ -n "${RUSTDESK_CONTROLLED_SERVER_IMAGE:-}" ]; then
        run_required "受控 server 镜像契约检查" \
            sh "$ROOT_DIR/scripts/deploy/controlled-server-image-check.sh" "$RUSTDESK_CONTROLLED_SERVER_IMAGE"
    else
        skip "未设置 RUSTDESK_CONTROLLED_SERVER_IMAGE，跳过受控 server 镜像契约检查"
    fi

    run_required "Mock 一体化 Compose 生命周期" \
        sh "$ROOT_DIR/scripts/deploy/controlled-compose-smoke.sh" "$ROOT_DIR"

    if [ -n "${RUSTDESK_CONTROLLED_IMAGE:-}" ]; then
        run_required "真实镜像隔离 Compose 生命周期" \
            sh "$ROOT_DIR/scripts/deploy/controlled-real-compose-smoke.sh" "$ROOT_DIR"
    else
        skip "未设置 RUSTDESK_CONTROLLED_IMAGE，跳过真实镜像隔离 Compose 生命周期"
    fi
    if [ -n "${RUSTDESK_API_IMAGE:-}" ] && [ -n "${RUSTDESK_CONTROLLED_SERVER_IMAGE:-}" ]; then
        run_required "三容器隔离 Compose 生命周期" \
            sh "$ROOT_DIR/scripts/deploy/controlled-three-compose-smoke.sh" "$ROOT_DIR"
    else
        skip "未设置 RUSTDESK_API_IMAGE/RUSTDESK_CONTROLLED_SERVER_IMAGE，跳过三容器隔离验收"
    fi
else
    skip "未检测到 docker，跳过镜像契约和 Compose 生命周期检查"
fi

printf '\n本地验收汇总：%s 项失败，%s 项警告，%s 项跳过。\n' "$failures" "$warnings" "$skips"

if [ "$failures" -gt 0 ]; then
    exit 1
fi
