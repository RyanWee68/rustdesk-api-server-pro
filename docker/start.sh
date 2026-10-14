#!/bin/sh

set -eu

if [ ! -f /usr/local/bin/rustdesk-api-server-pro ]; then
    ln -s /app/rustdesk-api-server-pro /usr/local/bin/rustdesk-api-server-pro
fi

mkdir -p /app/data

# 首次安装默认值可由容器环境变量覆盖；已有数据目录不会重置账号。
ADMIN_USER="${ADMIN_USER:-test}"
ADMIN_PASS="${ADMIN_PASS:-testadmin}"
PORT="${PORT:-12345}"
ADMIN_PORT="${ADMIN_PORT:-12346}"
RUSTDESK_API_INTERNAL_SECRET="${RUSTDESK_API_INTERNAL_SECRET:-}"
RUSTDESK_AUTH_CACHE_SECONDS="${RUSTDESK_AUTH_CACHE_SECONDS:-60}"
export ADMIN_USER ADMIN_PASS PORT ADMIN_PORT RUSTDESK_API_INTERNAL_SECRET RUSTDESK_AUTH_CACHE_SECONDS

# Make mounted config at /app/server.yaml effective, because the binary reads server.yaml from CWD.
# The process runs in /app/data, so keep /app/data/server.yaml in sync with /app/server.yaml.
# Only copy when /app/data/server.yaml does not exist yet, to avoid overwriting user edits.
if [ -f /app/server.yaml ] && [ ! -f /app/data/server.yaml ]; then
    cp /app/server.yaml /app/data/server.yaml
fi

cd /app/data

# Allow PORT env var to override the listening port (e.g. Docker -p 21114:21114 -e PORT=21114).
# The Go binary also reads PORT env var directly, but updating server.yaml ensures
# config display and health probes are consistent.
if [ -n "$PORT" ]; then
    port_val="$PORT"
    case "$port_val" in :*) ;; *) port_val=":$port_val" ;; esac
    if [ -f /app/data/server.yaml ]; then
        # Preserve the indentation produced by yaml.v3. Hard-coding two spaces
        # corrupts a persisted four-space YAML file after an admin UI save.
        sed -i "/^httpConfig:/,/^[^ ]/ s|^\([[:space:]]*port:\).*|\1 \"$port_val\"|" /app/data/server.yaml
    fi
fi

if [ -n "$ADMIN_PORT" ]; then
    admin_port_val="$ADMIN_PORT"
    case "$admin_port_val" in :*) ;; *) admin_port_val=":$admin_port_val" ;; esac
    if [ -f /app/data/server.yaml ]; then
        if sed -n "/^httpConfig:/,/^[^ ]/p" /app/data/server.yaml | grep -q '^[[:space:]]*adminPort:'; then
            sed -i "/^httpConfig:/,/^[^ ]/ s|^\([[:space:]]*adminPort:\).*|\1 \"$admin_port_val\"|" /app/data/server.yaml
        else
            tmp_yaml="$(mktemp)"
            awk -v admin_port_val="$admin_port_val" '
                /^httpConfig:/ { in_http = 1 }
                in_http && /^[^ ]/ && $0 !~ /^httpConfig:/ {
                    if (!inserted) {
                        print "  adminPort: \"" admin_port_val "\""
                        inserted = 1
                    }
                    in_http = 0
                }
                {
                    print
                    if (in_http && !inserted && $0 ~ /^[[:space:]]*port:/) {
                        match($0, /^[[:space:]]*/)
                        indent = substr($0, RSTART, RLENGTH)
                        print indent "adminPort: \"" admin_port_val "\""
                        inserted = 1
                    }
                }
                END {
                    if (in_http && !inserted) {
                        print "  adminPort: \"" admin_port_val "\""
                    }
                }
            ' /app/data/server.yaml > "$tmp_yaml"
            cat "$tmp_yaml" > /app/data/server.yaml
            rm -f "$tmp_yaml"
        fi
    fi
fi

if [ -f /app/data/server.yaml ]; then
    tmp_yaml="$(mktemp)"
    awk -v internal_secret="$RUSTDESK_API_INTERNAL_SECRET" -v cache_seconds="$RUSTDESK_AUTH_CACHE_SECONDS" '
        function print_rustdesk_block(indent) {
            print "rustdeskServer:"
            print indent "idServer: \"\""
            print indent "relayServer: \"\""
            print indent "apiServer: \"\""
            print indent "key: \"\""
            print indent "internalSecret: \"" internal_secret "\""
            print indent "authCacheSeconds: " cache_seconds
        }

        /^rustdeskServer:/ {
            in_rustdesk = 1
            seen_rustdesk = 1
            print
            next
        }
        in_rustdesk && /^[^ ]/ {
            if (!seen_internal_secret) {
                print "  internalSecret: \"" internal_secret "\""
            }
            if (!seen_cache_seconds) {
                print "  authCacheSeconds: " cache_seconds
            }
            in_rustdesk = 0
        }
        in_rustdesk && /^[[:space:]]*internalSecret:/ {
            print "  internalSecret: \"" internal_secret "\""
            seen_internal_secret = 1
            next
        }
        in_rustdesk && /^[[:space:]]*authCacheSeconds:/ {
            print "  authCacheSeconds: " cache_seconds
            seen_cache_seconds = 1
            next
        }
        { print }
        END {
            if (in_rustdesk) {
                if (!seen_internal_secret) {
                    print "  internalSecret: \"" internal_secret "\""
                }
                if (!seen_cache_seconds) {
                    print "  authCacheSeconds: " cache_seconds
                }
            }
            if (!seen_rustdesk) {
                print_rustdesk_block("  ")
            }
        }
    ' /app/data/server.yaml > "$tmp_yaml"
    cat "$tmp_yaml" > /app/data/server.yaml
    rm -f "$tmp_yaml"
fi

# Harden first-run Docker defaults. The image contains a sample server.yaml, but the
# server refuses unsafe placeholder signKey values. Generate a stable random key in
# the persisted /app/data/server.yaml so a fresh container can start safely without
# reusing a public example secret.
if [ -f /app/data/server.yaml ]; then
    current_sign_key="$(grep -E '^signKey:' /app/data/server.yaml | head -n1 | sed 's/#.*//' | sed 's/^signKey:[[:space:]]*//' | tr -d '"' | tr -d "'" | sed 's/[[:space:]]*$//' || true)"
    case "$current_sign_key" in
        ""|"CHANGE_ME_TO_A_RANDOM_32_BYTE_SECRET"|'sercrethatmaycontainch@r$32chars')
            generated_sign_key="$(head -c 48 /dev/urandom | base64 | tr -d '=+/\n' | cut -c1-48)"
            sed -i "s|^signKey:.*|signKey: \"$generated_sign_key\"|" /app/data/server.yaml
            ;;
    esac
fi

#if [ ! -f /app/server.db ]; then # This is not good if one wants to upgrade instance
/app/rustdesk-api-server-pro sync
#fi

if [ ! -f /app/data/.init.lock ] && [ -n "$ADMIN_USER" ] && [ -n "$ADMIN_PASS" ]; then
    /app/rustdesk-api-server-pro user add "$ADMIN_USER" "$ADMIN_PASS" --admin
    touch /app/data/.init.lock
fi

export APP_VERSION="${APP_VERSION:-latest}"
export BUILD_TIME="${BUILD_TIME:-}"

exec /app/rustdesk-api-server-pro start
