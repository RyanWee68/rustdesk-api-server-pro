#!/bin/sh

set -eu

PORT="${PORT:-12345}"
case "$PORT" in :*) PORT="${PORT#:}" ;; esac

if ! wget -q -T "${API_HEALTH_TIMEOUT_SECONDS:-2}" -O - "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    printf 'ERR-2391 API 健康检查失败\n' >&2
    exit 1
fi

if [ -n "${TLS_PORT:-}" ]; then
    tls_port="${TLS_PORT#:}"
    if ! wget --no-check-certificate -q -T "${API_HEALTH_TIMEOUT_SECONDS:-2}" -O - \
        "https://127.0.0.1:${tls_port}/" >/dev/null 2>&1; then
        printf 'ERR-2391 HTTPS 健康检查失败\n' >&2
        exit 1
    fi
fi

pid_dir="${CONTROLLED_PID_DIR:-/tmp}"
for pid_file in "$pid_dir"/rustdesk-controlled-api.pid "$pid_dir"/rustdesk-controlled-hbbs.pid "$pid_dir"/rustdesk-controlled-hbbr.pid; do
    if [ -f "$pid_file" ]; then
        pid="$(cat "$pid_file")"
        if [ -n "$pid" ] && ! kill -0 "$pid" >/dev/null 2>&1; then
            printf 'ERR-2392 进程不存在：%s\n' "$pid_file" >&2
            exit 1
        fi
    fi
done

exit 0
