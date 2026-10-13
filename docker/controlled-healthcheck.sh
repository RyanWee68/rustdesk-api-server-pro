#!/bin/sh

set -eu

PORT="${PORT:-12345}"
case "$PORT" in :*) PORT="${PORT#:}" ;; esac

if ! wget -q -T "${API_HEALTH_TIMEOUT_SECONDS:-2}" -O - "http://127.0.0.1:${PORT}/api/health" >/dev/null 2>&1; then
    printf 'ERR-2391 API 健康检查失败\n' >&2
    exit 1
fi

for pid_file in /tmp/rustdesk-controlled-api.pid /tmp/rustdesk-controlled-hbbs.pid /tmp/rustdesk-controlled-hbbr.pid; do
    if [ -f "$pid_file" ]; then
        pid="$(cat "$pid_file")"
        if [ -n "$pid" ] && ! kill -0 "$pid" >/dev/null 2>&1; then
            printf 'ERR-2392 进程不存在：%s\n' "$pid_file" >&2
            exit 1
        fi
    fi
done

exit 0
