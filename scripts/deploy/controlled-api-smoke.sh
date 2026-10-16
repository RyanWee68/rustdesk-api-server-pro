#!/bin/sh

set -eu

ROOT_DIR="${1:-$(pwd)}"
API_SMOKE_PORT="${API_SMOKE_PORT:-19055}"
API_SMOKE_ADMIN_PORT="${API_SMOKE_ADMIN_PORT:-19056}"
API_SMOKE_SECRET="${API_SMOKE_SECRET:-local-smoke-internal-secret-0123456789abcdef}"
API_SMOKE_SIGN_KEY="${API_SMOKE_SIGN_KEY:-local-smoke-sign-key-0123456789abcdef}"
API_SMOKE_TIMEOUT_SECONDS="${API_SMOKE_TIMEOUT_SECONDS:-30}"
TMP_PARENT="${TMPDIR:-/tmp}"
WORK_DIR="$(mktemp -d "$TMP_PARENT/rustdesk-api-smoke.XXXXXX")"
SERVER_PID=""

fail() {
    printf 'FAIL: ERR-239F %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        if kill -0 "$SERVER_PID" >/dev/null 2>&1; then
            kill "$SERVER_PID" >/dev/null 2>&1 || true
            wait "$SERVER_PID" >/dev/null 2>&1 || true
            sleep 1
        fi
        if kill -0 "$SERVER_PID" >/dev/null 2>&1; then
            kill -9 "$SERVER_PID" >/dev/null 2>&1 || true
            wait "$SERVER_PID" >/dev/null 2>&1 || true
        fi
    fi
    rm -rf "$WORK_DIR" >/dev/null 2>&1 || printf 'WARN: 临时目录清理失败，请手动检查：%s\n' "$WORK_DIR" >&2
}

trap cleanup EXIT INT TERM

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        fail "缺少命令：$1"
    fi
}

wait_health() {
    deadline=$((API_SMOKE_TIMEOUT_SECONDS * 2))
    i=0
    while [ "$i" -lt "$deadline" ]; do
        if curl -sS -m 2 "http://127.0.0.1:$API_SMOKE_PORT/api/health" >/dev/null 2>&1; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.5
    done
    return 1
}

require_cmd go
require_cmd curl

case "$(uname -s 2>/dev/null || printf unknown)" in
    MINGW*|MSYS*|CYGWIN*)
        if [ "${ALLOW_WINDOWS_API_SMOKE:-0}" != "1" ]; then
            fail "Windows Git Bash 无法可靠停止外部服务进程；如确认可接受，请设置 ALLOW_WINDOWS_API_SMOKE=1"
        fi
        ;;
esac

if [ ! -f "$ROOT_DIR/backend/go.mod" ]; then
    fail "传入目录不像当前 RustDeskWeb 仓库：$ROOT_DIR"
fi

if [ ! -x "$ROOT_DIR/scripts/deploy/controlled-admission-smoke.sh" ] && [ ! -f "$ROOT_DIR/scripts/deploy/controlled-admission-smoke.sh" ]; then
    fail "找不到内部准入 smoke 脚本"
fi

mkdir -p "$WORK_DIR/app-dist" "$WORK_DIR/gocache"

GOCACHE="$WORK_DIR/gocache" go -C "$ROOT_DIR/backend" build -o "$WORK_DIR/rustdesk-api-server-pro.exe" .
pass "临时 API 二进制构建完成"

cat > "$WORK_DIR/server.yaml" <<EOF
signKey: "$API_SMOKE_SIGN_KEY"
debugMode: false
db:
  driver: "sqlite"
  dsn: "server.db"
  timeZone: "Asia/Shanghai"
  showSql: false
httpConfig:
  printRequestLog: false
  staticdir: "app-dist"
  port: ":$API_SMOKE_PORT"
  adminPort: ":$API_SMOKE_ADMIN_PORT"
rustdeskServer:
  idServer: ""
  relayServer: ""
  apiServer: ""
  key: ""
  internalSecret: "$API_SMOKE_SECRET"
  authCacheSeconds: 60
smtpConfig:
  host: "127.0.0.1"
  port: 1025
  username: ""
  password: ""
  encryption: "none"
  from: "noreply@example.com"
jobsConfig:
  deviceCheckJob:
    duration: 1
    offlineAfterSeconds: 30
oidc:
  enabled: false
oauth:
  providers: []
EOF

if (
    cd "$WORK_DIR"
    ./rustdesk-api-server-pro.exe sync > "$WORK_DIR/sync.log" 2>&1
); then
    pass "临时 API 数据库结构同步完成"
else
    cat "$WORK_DIR/sync.log" >&2 || true
    fail "临时 API 数据库结构同步失败"
fi

(
    cd "$WORK_DIR"
    exec ./rustdesk-api-server-pro.exe start > "$WORK_DIR/server.log" 2>&1
) &
SERVER_PID="$!"

if wait_health; then
    pass "临时 API 健康检查通过"
else
    if [ -f "$WORK_DIR/server.log" ]; then
        tail -n 80 "$WORK_DIR/server.log" >&2 || true
    fi
    fail "临时 API 未在超时时间内通过健康检查"
fi

API_BASE_URL="http://127.0.0.1:$API_SMOKE_PORT" \
RUSTDESK_API_INTERNAL_SECRET="$API_SMOKE_SECRET" \
HTTP_TIMEOUT_SECONDS=5 \
sh "$ROOT_DIR/scripts/deploy/controlled-admission-smoke.sh"

pass "临时 API 内部准入 smoke 完成"
