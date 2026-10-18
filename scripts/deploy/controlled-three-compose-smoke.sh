#!/bin/sh
set -eu

# 统一输出部署错误码。
fail() {
    printf 'ERR-239B %s\n' "$1" >&2
    exit 1
}

ROOT_DIR="${1:-$(pwd)}"
COMPOSE_FILE="$ROOT_DIR/docker-compose.controlled-three-isolated.yaml"
[ -f "$COMPOSE_FILE" ] || fail "找不到三容器隔离 Compose 配置"
for tool in docker python3 openssl; do
    command -v "$tool" >/dev/null 2>&1 || fail "缺少工具：$tool"
done
RUSTDESK_API_IMAGE="${RUSTDESK_API_IMAGE:-}"
RUSTDESK_CONTROLLED_SERVER_IMAGE="${RUSTDESK_CONTROLLED_SERVER_IMAGE:-}"
[ -n "$RUSTDESK_API_IMAGE" ] && [ -n "$RUSTDESK_CONTROLLED_SERVER_IMAGE" ] || fail "未设置受控 API 和 server 镜像"
for image in "$RUSTDESK_API_IMAGE" "$RUSTDESK_CONTROLLED_SERVER_IMAGE" alpine:3.20.3; do
    docker image inspect "$image" >/dev/null 2>&1 || fail "找不到指定测试镜像"
done
docker run --rm --pull=never --network none --entrypoint sh "$RUSTDESK_API_IMAGE" -ec \
    'test "$CONTROLLED_API_ONLY" = 1; test -x /app/rustdesk-api-server-pro; test ! -e /usr/local/bin/hbbs; test ! -e /usr/local/bin/hbbr' \
    || fail "API 镜像不满足专用运行契约"
docker run --rm --pull=never --network none --entrypoint sh "$RUSTDESK_CONTROLLED_SERVER_IMAGE" -ec \
    'ldd /usr/local/bin/hbbs >/dev/null && ldd /usr/local/bin/hbbr >/dev/null' \
    || fail "server 镜像缺少可运行的真实二进制"

PROJECT_NAME="rustdesk-controlled-three-$(date +%s)-$$"
export RUSTDESK_API_IMAGE RUSTDESK_CONTROLLED_SERVER_IMAGE
export ADMIN_USER=controlledtest
export ADMIN_PASS="$(sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" generate-internal-secret)"
export RUSTDESK_API_INTERNAL_SECRET="$(sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" generate-internal-secret)"
STARTED=0
WSS_COMPOSE_FILE=""
WSS_WORK_DIR=""

# 只操作本次随机项目。
compose() {
    if [ -n "$WSS_COMPOSE_FILE" ]; then
        docker compose --env-file /dev/null -p "$PROJECT_NAME" -f "$COMPOSE_FILE" -f "$WSS_COMPOSE_FILE" "$@"
    else
        docker compose --env-file /dev/null -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
    fi
}

# 失败、中断和正常结束均清理本次专属资源。
cleanup() {
    result=$?
    trap - EXIT
    if [ "$STARTED" = 1 ]; then
        compose down --volumes --remove-orphans || result=1
    fi
    [ -z "$WSS_WORK_DIR" ] || rm -rf -- "$WSS_WORK_DIR"
    [ "$result" -eq 0 ] || printf 'ERR-239B 三容器测试或清理失败\n' >&2
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 检查真实监听健康状态与无宿主端口发布。
wait_healthy() {
    service="$1"
    container_id="$(compose ps -q "$service")"
    [ -n "$container_id" ] || fail "找不到隔离服务：$service"
    attempt=0
    while [ "$attempt" -lt 40 ]; do
        status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing-healthcheck{{end}}' "$container_id")"
        case "$status" in
            healthy) [ -z "$(docker port "$container_id")" ] || fail "隔离服务意外发布宿主端口：$service"; return 0 ;;
            starting) ;;
            *) fail "隔离服务不健康：$service $status" ;;
        esac
        attempt=$((attempt + 1))
        sleep 3
    done
    fail "等待隔离服务健康超时：$service"
}

# 返回仅用于主机本地验收的容器地址。
service_ip() {
    docker inspect --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$(compose ps -q "$1")"
}

# 固定基线中继帧不含 token，联查实际断开和服务端拒绝码。
relay_probe() {
    expected="$1"
    before="$(docker logs "$(compose ps -q rustdesk-hbbr)" 2>&1 | grep -c "中继会话被拒绝：$expected" || true)"
    python3 - "$(service_ip rustdesk-hbbr)" <<'PY'
import socket
import sys
import uuid

session = str(uuid.uuid4()).encode("ascii")
relay = b"\x12\x24" + session
message = b"\x92\x01" + bytes([len(relay)]) + relay
try:
    with socket.create_connection((sys.argv[1], 21117), timeout=6) as stream:
        stream.sendall(bytes([len(message) << 2]) + message)
        if stream.recv(1) != b"":
            raise SystemExit("ERR-239D 无效会话收到非预期中继数据")
except OSError:
    raise SystemExit("ERR-239D 中继探针连接或等待关闭失败")
PY
    after="$(docker logs "$(compose ps -q rustdesk-hbbr)" 2>&1 | grep -c "中继会话被拒绝：$expected" || true)"
    [ "$after" -gt "$before" ] || fail "未出现预期中继拒绝码：$expected"
}

compose config --quiet
# 使用 Compose 的规范化 JSON 校验隔离边界，不输出凭据。
compose config --format json | python3 -c '
import json, sys
config = json.load(sys.stdin)
services = config["services"]
unsafe = set(services) != {"rustdesk-api-server-pro", "rustdesk-hbbs", "rustdesk-hbbr"}
unsafe |= any(service.get("container_name") or service.get("ports") or any(volume["type"] != "volume" for volume in service.get("volumes", [])) for service in services.values())
unsafe |= any(volume.get("external") or not volume.get("name", "").startswith(sys.argv[1] + "_") for volume in config["volumes"].values())
unsafe |= not config["networks"]["rustdesk-control"].get("internal")
if unsafe:
    raise SystemExit("ERR-239B 三容器配置未满足独立名称、卷、网络及无端口发布的隔离约束")
' "$PROJECT_NAME"
STARTED=1
compose up -d --no-build
for item in rustdesk-api-server-pro rustdesk-hbbs rustdesk-hbbr; do
    wait_healthy "$item"
done
API_BASE_URL="http://$(service_ip rustdesk-api-server-pro):12345" \
    sh "$ROOT_DIR/scripts/deploy/controlled-admission-smoke.sh"
relay_probe ERR-2315
python3 "$ROOT_DIR/scripts/deploy/controlled-hbbs-protocol-acceptance.py" "$(compose ps -q rustdesk-hbbs)"
compose exec -T rustdesk-api-server-pro sh -ec \
    'test -s /app/data/server.yaml; test -s /app/rustdesk-server/id_ed25519.pub; test -s /app/data/server.db; test -f /app/data/.init.lock; for dir in /app/data /app/rustdesk-server /app/logs; do printf controlled-three-smoke > "$dir/.controlled-three-smoke"; done'
# 模拟后台保存四空格配置，再验证 API 重启和全部重建。
compose exec -T rustdesk-api-server-pro sed -i 's/^  /    /' /app/data/server.yaml
before_config="$(compose exec -T rustdesk-api-server-pro sha256sum /app/data/server.yaml)"
before_key="$(compose exec -T rustdesk-api-server-pro sha256sum /app/rustdesk-server/id_ed25519.pub)"

compose stop rustdesk-api-server-pro
wait_healthy rustdesk-hbbs
wait_healthy rustdesk-hbbr
relay_probe ERR-239B
python3 "$ROOT_DIR/scripts/deploy/controlled-hbbs-protocol-acceptance.py" "$(compose ps -q rustdesk-hbbs)" --api-unavailable
compose up -d --no-build rustdesk-api-server-pro
wait_healthy rustdesk-api-server-pro
relay_probe ERR-2315
python3 "$ROOT_DIR/scripts/deploy/controlled-hbbs-protocol-acceptance.py" "$(compose ps -q rustdesk-hbbs)"
printf 'PASS: API 独立停止时 hbbs/hbbr 存活，新中继拒绝；恢复后准入调用恢复\n'

compose up -d --force-recreate --no-build
for item in rustdesk-api-server-pro rustdesk-hbbs rustdesk-hbbr; do
    wait_healthy "$item"
done
[ "$before_config" = "$(compose exec -T rustdesk-api-server-pro sha256sum /app/data/server.yaml)" ] || fail "重建后 API 配置变化"
[ "$before_key" = "$(compose exec -T rustdesk-api-server-pro sha256sum /app/rustdesk-server/id_ed25519.pub)" ] || fail "重建后 server key 变化"
compose exec -T rustdesk-api-server-pro sh -ec \
    'test -s /app/data/server.db; test -f /app/data/.init.lock; for dir in /app/data /app/rustdesk-server /app/logs; do test "$(cat "$dir/.controlled-three-smoke")" = controlled-three-smoke; done'
API_BASE_URL="http://$(service_ip rustdesk-api-server-pro):12345" \
    sh "$ROOT_DIR/scripts/deploy/controlled-admission-smoke.sh"
relay_probe ERR-2315
printf 'PASS: 三容器隔离启动、健康依赖、无端口发布、跨容器准入、重建与三个卷持久化通过\n'

# 只在本次无宿主端口的隔离容器启用原生 TLS，证书与私钥随测试清理。
WSS_WORK_DIR="$(mktemp -d)"
export WSS_TLS_DIR="$WSS_WORK_DIR"
export WSS_CERT_NAME=server.fullchain.pem WSS_KEY_NAME=server.key.pem
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost -addext basicConstraints=critical,CA:FALSE \
    -keyout "$WSS_WORK_DIR/server.key.pem" -out "$WSS_WORK_DIR/server.fullchain.pem" \
    >"$WSS_WORK_DIR/openssl.log" 2>&1 || fail "临时 WSS 测试证书生成失败"
chmod 600 "$WSS_WORK_DIR/server.key.pem"
WSS_COMPOSE_FILE="$ROOT_DIR/docker-compose.controlled-wss.yaml"
compose up -d --no-build rustdesk-hbbs rustdesk-hbbr
wait_healthy rustdesk-hbbs
wait_healthy rustdesk-hbbr
python3 "$ROOT_DIR/scripts/deploy/controlled-wss-protocol-acceptance.py" \
    "$(compose ps -q rustdesk-hbbs)" "$(compose ps -q rustdesk-hbbr)" "$WSS_WORK_DIR/server.fullchain.pem"
compose stop rustdesk-api-server-pro
python3 "$ROOT_DIR/scripts/deploy/controlled-wss-protocol-acceptance.py" \
    "$(compose ps -q rustdesk-hbbs)" "$(compose ps -q rustdesk-hbbr)" "$WSS_WORK_DIR/server.fullchain.pem" --api-unavailable
compose up -d --no-build rustdesk-api-server-pro
wait_healthy rustdesk-api-server-pro
python3 "$ROOT_DIR/scripts/deploy/controlled-wss-protocol-acceptance.py" \
    "$(compose ps -q rustdesk-hbbs)" "$(compose ps -q rustdesk-hbbr)" "$WSS_WORK_DIR/server.fullchain.pem"
printf 'PASS: 原生 WSS 三容器在线准入、API 故障及恢复通过，无宿主端口发布\n'
