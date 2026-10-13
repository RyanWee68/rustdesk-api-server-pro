#!/bin/sh
set -eu

# 统一输出部署错误码。
fail() {
    printf 'ERR-239C %s\n' "$1" >&2
    exit 1
}

ACTION="${1:-}"
ROOT_DIR="${2:-$(pwd)}"
STATE_DIR="${CONTROLLED_LAN_STATE_DIR:-/tmp/rustdesk-controlled-lan-poc}"
ENV_FILE="$STATE_DIR/runtime.env"
BASE_FILE="$ROOT_DIR/docker-compose.controlled-isolated.yaml"
LAN_FILE="$ROOT_DIR/docker-compose.controlled-lan-poc.yaml"
PROJECT_NAME=rustdesk-controlled-lan-poc

case "$ACTION" in
    start|status|stop) ;;
    *) fail "用法：sh controlled-lan-poc.sh start|status|stop [项目根目录]" ;;
esac
command -v docker >/dev/null 2>&1 || fail "缺少 docker"
[ -f "$BASE_FILE" ] && [ -f "$LAN_FILE" ] || fail "找不到隔离 Compose 配置"
[ ! -L "$STATE_DIR" ] && [ ! -L "$ENV_FILE" ] || fail "测试状态目录或凭据文件不能是符号链接"
if [ -d "$STATE_DIR" ]; then
    [ "$(stat -c %u "$STATE_DIR")" = "$(id -u)" ] || fail "测试状态目录所有者不匹配"
    chmod 700 "$STATE_DIR"
fi

if [ "$ACTION" = start ] && [ ! -f "$ENV_FILE" ]; then
    LAN_BIND_IP="${LAN_BIND_IP:-}"
    case "$LAN_BIND_IP" in
        10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) ;;
        *) fail "LAN_BIND_IP 必须是测试主机的私有 IPv4 地址" ;;
    esac
    ip -4 -o addr show | grep -q "inet $LAN_BIND_IP/" || fail "测试主机没有指定的局域网地址"
    RUSTDESK_CONTROLLED_IMAGE="${RUSTDESK_CONTROLLED_IMAGE:-}"
    [ -n "$RUSTDESK_CONTROLLED_IMAGE" ] || fail "未设置 RUSTDESK_CONTROLLED_IMAGE"
    docker image inspect "$RUSTDESK_CONTROLLED_IMAGE" >/dev/null 2>&1 || fail "找不到真实一体化镜像"
    docker run --rm --entrypoint sh "$RUSTDESK_CONTROLLED_IMAGE" -ec \
        'ldd /usr/local/bin/hbbs >/dev/null && ldd /usr/local/bin/hbbr >/dev/null' \
        || fail "hbbs/hbbr 不是可用的真实二进制"
    umask 077
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    temp_env="$(mktemp "$STATE_DIR/.runtime.env.XXXXXX")"
    admin_pass="$(sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" generate-internal-secret)"
    internal_secret="$(sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" generate-internal-secret)"
    printf 'LAN_BIND_IP=%s\nRUSTDESK_CONTROLLED_IMAGE=%s\nADMIN_USER=controlledpoc\nADMIN_PASS=%s\nRUSTDESK_API_INTERNAL_SECRET=%s\n' \
        "$LAN_BIND_IP" "$RUSTDESK_CONTROLLED_IMAGE" "$admin_pass" "$internal_secret" > "$temp_env"
    mv "$temp_env" "$ENV_FILE"
fi

[ -f "$ENV_FILE" ] || fail "找不到测试凭据文件，尚未启动过测试"
[ "$(stat -c %u "$ENV_FILE")" = "$(id -u)" ] || fail "测试凭据文件所有者不匹配"
chmod 600 "$ENV_FILE"
set -a
. "$ENV_FILE"
set +a

# 始终使用本次 PoC 的独立 Compose 项目与凭据。
compose() {
    docker compose --env-file "$ENV_FILE" -p "$PROJECT_NAME" -f "$BASE_FILE" -f "$LAN_FILE" "$@"
}

case "$ACTION" in
    stop)
        compose down --remove-orphans
        printf 'PASS: 局域网测试端口已关闭，独立测试卷保留\n'
        exit 0
        ;;
    status)
        compose ps
        exit 0
        ;;
esac

compose config --quiet
if ! compose up -d --no-build; then
    compose down --remove-orphans || true
    fail "局域网测试容器启动失败"
fi

container_id="$(compose ps -q rustdesk-controlled)"
[ -n "$container_id" ] || fail "找不到局域网测试容器"
attempt=0
while [ "$attempt" -lt 40 ]; do
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing-healthcheck{{end}}' "$container_id")"
    case "$health" in
        healthy) break ;;
        starting) ;;
        *) compose down --remove-orphans || true; fail "测试容器不健康：$health" ;;
    esac
    attempt=$((attempt + 1))
    sleep 3
done
if [ "$attempt" -eq 40 ]; then
    compose down --remove-orphans || true
    fail "等待测试容器健康超时"
fi

ports="$(docker port "$container_id")"
for expected in \
    "12345/tcp -> $LAN_BIND_IP:22545" \
    "12346/tcp -> 127.0.0.1:22546" \
    "21115/tcp -> $LAN_BIND_IP:21115" \
    "21116/tcp -> $LAN_BIND_IP:21116" \
    "21116/udp -> $LAN_BIND_IP:21116" \
    "21117/tcp -> $LAN_BIND_IP:21117"
do
    printf '%s\n' "$ports" | grep -Fq "$expected" || {
        compose down --remove-orphans || true
        fail "端口映射与局域网测试配置不一致：$expected"
    }
done
printf 'PASS: 局域网测试容器健康，端口仅绑定指定局域网地址；管理端口仅绑定本机\n'
