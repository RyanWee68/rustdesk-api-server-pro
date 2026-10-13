#!/bin/sh
set -eu

fail() {
    printf 'ERR-239B %s\n' "$1" >&2
    exit 1
}

case "${1:-}" in
    -h|--help) printf '用法：sh controlled-real-compose-smoke.sh [项目根目录]\n'; exit 0 ;;
esac

command -v docker >/dev/null 2>&1 || fail "缺少 docker"
ROOT_DIR="${1:-$(pwd)}"
COMPOSE_FILE="$ROOT_DIR/docker-compose.controlled-isolated.yaml"
[ -f "$COMPOSE_FILE" ] || fail "找不到隔离 Compose 文件"
RUSTDESK_CONTROLLED_IMAGE="${RUSTDESK_CONTROLLED_IMAGE:-}"
[ -n "$RUSTDESK_CONTROLLED_IMAGE" ] || fail "未设置 RUSTDESK_CONTROLLED_IMAGE"
docker image inspect "$RUSTDESK_CONTROLLED_IMAGE" >/dev/null 2>&1 || fail "找不到真实镜像"
docker run --rm --entrypoint sh "$RUSTDESK_CONTROLLED_IMAGE" -ec \
    'ldd /usr/local/bin/hbbs >/dev/null && ldd /usr/local/bin/hbbr >/dev/null' \
    || fail "hbbs/hbbr 不是可用的真实动态链接二进制"

PROJECT_NAME="rustdesk-controlled-real-$(date +%s)-$$"
export RUSTDESK_CONTROLLED_IMAGE
export ADMIN_USER="controlledtest"
export ADMIN_PASS="$(sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" generate-internal-secret)"
export RUSTDESK_API_INTERNAL_SECRET="$(sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" generate-internal-secret)"
STARTED=0

compose() {
    docker compose --env-file /dev/null -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
}

cleanup() {
    result=$?
    trap - EXIT
    if [ "${KEEP_CONTROLLED_REAL_SMOKE:-0}" = "1" ]; then
        printf '测试资源已保留：项目=%s\n' "$PROJECT_NAME"
    elif [ "$STARTED" = "1" ]; then
        compose down --volumes --remove-orphans || result=1
    fi
    [ "$result" -eq 0 ] || printf 'ERR-239B 测试或资源清理失败\n' >&2
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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

compose config --quiet
STARTED=1
compose up -d --no-build
container_id="$(compose ps -q rustdesk-controlled)"
[ -n "$container_id" ] || fail "找不到测试容器"
wait_healthy
[ -z "$(docker port "$container_id")" ] || fail "测试容器意外发布了宿主端口"
compose exec -T rustdesk-controlled sh -ec 'test -s /app/data/server.yaml; test -s /app/rustdesk-server/id_ed25519.pub; test -f /app/data/.init.lock; for dir in /app/data /app/rustdesk-server /app/logs; do printf controlled-real-smoke > "$dir/.controlled-real-smoke"; done'
# 模拟后台保存四空格配置，重建后摘要和语法都必须保持有效。
compose exec -T rustdesk-controlled sed -i 's/^  /    /' /app/data/server.yaml
before_config="$(compose exec -T rustdesk-controlled sha256sum /app/data/server.yaml)"
before_key="$(compose exec -T rustdesk-controlled sha256sum /app/rustdesk-server/id_ed25519.pub)"

compose up -d --force-recreate --no-build
container_id="$(compose ps -q rustdesk-controlled)"
[ -n "$container_id" ] || fail "重建后找不到测试容器"
wait_healthy
[ -z "$(docker port "$container_id")" ] || fail "重建后意外发布了宿主端口"
[ "$before_config" = "$(compose exec -T rustdesk-controlled sha256sum /app/data/server.yaml)" ] || fail "重建后配置摘要变化"
[ "$before_key" = "$(compose exec -T rustdesk-controlled sha256sum /app/rustdesk-server/id_ed25519.pub)" ] || fail "重建后 server key 变化"
compose exec -T rustdesk-controlled sh -ec 'test -f /app/data/.init.lock; for dir in /app/data /app/rustdesk-server /app/logs; do test "$(cat "$dir/.controlled-real-smoke")" = controlled-real-smoke; done'
printf 'PASS: 真实镜像隔离 Compose 启动、健康、无端口发布、重建和三个卷持久化通过\n'
