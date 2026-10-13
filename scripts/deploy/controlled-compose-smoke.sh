#!/bin/sh
set -eu

# 输出带错误码的失败原因。
fail() {
    printf 'ERR-239A %s\n' "$1" >&2
    exit 1
}

case "${1:-}" in
    -h|--help) printf '用法：sh controlled-compose-smoke.sh [项目根目录]\n'; exit 0 ;;
esac
command -v docker >/dev/null 2>&1 || fail "缺少 docker"
ROOT_DIR="${1:-$(pwd)}"
COMPOSE_FILE="$ROOT_DIR/docker-compose.controlled-smoke.yaml"
[ -f "$COMPOSE_FILE" ] || fail "找不到隔离测试 Compose 文件"
PROJECT_NAME="rustdesk-controlled-smoke-$(date +%s)-$$"
MOCK_IMAGE="$PROJECT_NAME-server:local"
export RUSTDESK_CONTROLLED_SERVER_IMAGE="$MOCK_IMAGE"
export RUSTDESK_CONTROLLED_IMAGE="$PROJECT_NAME-api:local"
export RUSTDESK_API_INTERNAL_SECRET="$(sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" generate-internal-secret)"
export ADMIN_USER="controlledsmoke"
export ADMIN_PASS="$(sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" generate-internal-secret)"
STARTED=0

# 所有操作使用相同参数，禁止读取部署目录中的 .env。
compose() {
    docker compose --env-file /dev/null -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
}

# 只删除本次测试独占的资源，保留失败退出码。
cleanup() {
    result=$?
    trap - EXIT
    if [ "${KEEP_CONTROLLED_SMOKE:-0}" = "1" ]; then
        printf '已保留测试资源：项目=%s 镜像=%s,%s\n' "$PROJECT_NAME" "$MOCK_IMAGE" "$RUSTDESK_CONTROLLED_IMAGE"
    else
        if [ "$STARTED" = "1" ]; then
            compose down --volumes --remove-orphans || result=1
        fi
        docker image rm "$RUSTDESK_CONTROLLED_IMAGE" "$MOCK_IMAGE" >/dev/null 2>&1 || true
    fi
    [ "$result" -eq 0 ] || printf 'ERR-239A 测试或资源清理失败\n' >&2
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 只有健康检查明确通过才放行，无健康检查的 running 不算通过。
wait_healthy() {
    attempt=0
    while [ "$attempt" -lt "${SMOKE_HEALTH_RETRIES:-40}" ]; do
        status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing-healthcheck{{end}}' "$container_id")"
        case "$status" in
            healthy) return 0 ;;
            starting) ;;
            *) fail "容器健康检查失败：$status" ;;
        esac
        attempt=$((attempt + 1))
        sleep 3
    done
    fail "等待健康检查超时"
}

docker build -t "$MOCK_IMAGE" "$ROOT_DIR/docker/mock-rustdesk-server"
compose config --quiet
compose build
STARTED=1
compose up -d
container_id="$(compose ps -q rustdesk-controlled)"
[ -n "$container_id" ] || fail "找不到测试容器"
wait_healthy

# 用测试标记覆盖三个持久卷，并比较重建前后的配置摘要。
compose exec -T rustdesk-controlled sh -ec 'for dir in /app/data /app/rustdesk-server /app/logs; do printf controlled-smoke > "$dir/.controlled-smoke"; done'
before="$(compose exec -T rustdesk-controlled sha256sum /app/data/server.yaml)"
[ -n "$before" ] || fail "配置摘要为空"
compose up -d --force-recreate
container_id="$(compose ps -q rustdesk-controlled)"
[ -n "$container_id" ] || fail "重建后找不到测试容器"
wait_healthy
after="$(compose exec -T rustdesk-controlled sha256sum /app/data/server.yaml)"
[ "$before" = "$after" ] || fail "重建后配置发生变化"
compose exec -T rustdesk-controlled sh -ec 'for dir in /app/data /app/rustdesk-server /app/logs; do test "$(cat "$dir/.controlled-smoke")" = controlled-smoke; done'
printf 'PASS: Mock 一体化启动、健康检查、容器重建和持久卷检查通过\n'
