#!/usr/bin/env bash
set -eu

ROOT_DIR="${1:-$(pwd)}"

# 模拟 Docker 边界，验证脚本流程；不创建容器或临时文件。
docker() {
    case "$1" in
        build|image) return 0 ;;
        inspect) printf '%s\n' "${TEST_HEALTH:-healthy}"; return 0 ;;
        compose)
            [ "$2" = "--env-file" ] && [ "$3" = "/dev/null" ] || return 90
            [[ "$5" = rustdesk-controlled-smoke-* ]] || return 91
            [[ "$7" = */docker-compose.controlled-smoke.yaml ]] || return 92
            shift 7
            printf 'CALL:%s\n' "$*" >&2
            case "$1" in
                up) [ "${TEST_UP_FAIL:-0}" = 0 ] || return 42 ;;
                down) [ "${TEST_DOWN_FAIL:-0}" = 0 ] || return 43 ;;
                ps) printf 'mock-container\n' ;;
                exec)
                    if [ "$4" = sha256sum ]; then printf 'mock-digest  /app/data/server.yaml\n'; fi
                    ;;
            esac
            ;;
        *) return 93 ;;
    esac
}
export -f docker

# 每个场景独立运行，检查退出码和清理动作。
check_case() {
    local name="$1" expected="$2" output status=0
    output="$(bash "$ROOT_DIR/scripts/deploy/controlled-compose-smoke.sh" "$ROOT_DIR" 2>&1)" || status=$?
    if { [ "$expected" = pass ] && [ "$status" -ne 0 ]; } ||
       { [ "$expected" = fail ] && [ "$status" -eq 0 ]; }; then
        printf 'ERR-239A 回归失败：%s\n%s\n' "$name" "$output" >&2
        exit 1
    fi
    if [ "${KEEP_CONTROLLED_SMOKE:-0}" = 1 ]; then
        [[ "$output" != *"CALL:down"* ]] || exit 1
    else
        [[ "$output" = *"CALL:down --volumes --remove-orphans"* ]] || exit 1
    fi
    if [ "$expected" = pass ]; then
        [[ "$output" = *"CALL:up -d --force-recreate"* ]] || exit 1
    fi
    printf 'PASS: %s\n' "$name"
}

TEST_HEALTH=healthy check_case 正常启动重建清理 pass
TEST_HEALTH=running check_case 缺少健康检查拒绝 fail
TEST_HEALTH=unhealthy check_case 健康检查失败清理 fail
TEST_UP_FAIL=1 check_case 部分启动失败清理 fail
TEST_DOWN_FAIL=1 check_case 清理失败必须失败 fail
KEEP_CONTROLLED_SMOKE=1 check_case 保留现场 pass
