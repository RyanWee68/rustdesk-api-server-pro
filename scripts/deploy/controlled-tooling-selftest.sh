#!/bin/sh

set -eu

ROOT_DIR="${1:-$(pwd)}"
TMP_PARENT="$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)"
WORK_DIR="$(mktemp -d "$TMP_PARENT/rustdesk-controlled-tooling.XXXXXX")"
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) CAN_VERIFY_POSIX_MODE=0 ;;
    *) CAN_VERIFY_POSIX_MODE=1 ;;
esac

fail() {
    printf 'FAIL: ERR-239G %s\n' "$1" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$1"
}

cleanup() {
    [ -d "$WORK_DIR" ] || return
    resolved_work="$(CDPATH= cd -- "$WORK_DIR" && pwd -P)"
    case "$resolved_work" in
        "$TMP_PARENT"/rustdesk-controlled-tooling.*)
            rm -rf -- "$resolved_work"
            ;;
        *)
            printf 'WARN: 拒绝清理非预期临时目录：%s\n' "$resolved_work" >&2
            ;;
    esac
}

trap cleanup EXIT INT TERM

[ -f "$ROOT_DIR/docs/CONTROLLED_RUSTDESK_DEPLOYMENT_PLAN.md" ] || \
    fail "传入目录不像当前 RustDeskWeb 仓库：$ROOT_DIR"

FORK_DIR="$WORK_DIR/rustdesk-server-fork"
mkdir -p "$FORK_DIR"
printf '[workspace]\nmembers = []\n' > "$FORK_DIR/Cargo.toml"

CONTROLLED_ROOT_DIR="$ROOT_DIR" \
    sh "$ROOT_DIR/scripts/deploy/controlled-fork-bootstrap.sh" "$FORK_DIR" --dry-run >/dev/null
[ ! -e "$FORK_DIR/controlled-api" ] || fail "fork 脚手架 dry-run 不应写入文件"
pass "fork 接入脚手架 dry-run"

CONTROLLED_ROOT_DIR="$ROOT_DIR" \
    sh "$ROOT_DIR/scripts/deploy/controlled-fork-bootstrap.sh" "$FORK_DIR" >/dev/null 2>&1
for file in \
    controlled_admission.rs \
    Cargo.toml \
    README.md \
    CONTROLLED_RUSTDESK_API_CONTRACT.md \
    CONTROLLED_RUSTDESK_SERVER_FORK.md \
    CONTROLLED_RUSTDESK_SERVER_SOURCE_CHECK.md
do
    [ -f "$FORK_DIR/controlled-api/$file" ] || fail "fork 脚手架缺少输出文件：$file"
done
pass "fork 接入脚手架真实复制"

SECRET="$(sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" generate-internal-secret)"
[ "${#SECRET}" -ge 32 ] || fail "生成的内部密钥长度不足"
case "$SECRET" in
    *[!A-Za-z0-9]*) fail "生成的内部密钥包含非字母数字字符" ;;
esac
pass "内部 API 密钥生成"

SERVER_YAML="$WORK_DIR/server.yaml"
printf 'signKey: "example-sign-key"\ndebugMode: false\n' > "$SERVER_YAML"
sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" rotate-sign-key "$SERVER_YAML" >/dev/null
sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" rotate-sign-key "$SERVER_YAML" >/dev/null
grep -q '^signKey: "example-sign-key"$' "$SERVER_YAML" && fail "API signKey 未完成轮换"
grep -q '^debugMode: false$' "$SERVER_YAML" || fail "signKey 轮换破坏了其他 YAML 字段"
[ "$(find "$WORK_DIR" -maxdepth 1 -type f -name 'server.yaml.bak.*' | wc -l)" -eq 2 ] || fail "连续 signKey 轮换未保留两份独立备份"
if [ "$CAN_VERIFY_POSIX_MODE" -eq 1 ] && \
    find "$WORK_DIR" -maxdepth 1 -type f -name 'server.yaml.bak.*' -exec stat -c %a {} \; | grep -v '^600$' >/dev/null; then
    fail "signKey 备份权限不是 0600"
fi
[ -z "$(find "$WORK_DIR" -maxdepth 1 -type f -name 'server.yaml.tmp.*' -print -quit)" ] || fail "signKey 轮换留下临时配置文件"
if [ "$CAN_VERIFY_POSIX_MODE" -eq 1 ]; then
    ln -s "$SERVER_YAML" "$WORK_DIR/server-link.yaml"
    if sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" rotate-sign-key "$WORK_DIR/server-link.yaml" >"$WORK_DIR/signkey-link.log" 2>&1; then
        fail "signKey 轮换未拒绝符号链接配置文件"
    fi
    grep -q 'ERR-2395.*符号链接' "$WORK_DIR/signkey-link.log" || fail "符号链接配置文件未明确拒绝"
fi
pass "API signKey 连续轮换、独立备份和权限"

KEY_DIR="$WORK_DIR/server-key"
BACKUP_DIR="$WORK_DIR/key-backups"
mkdir -p "$KEY_DIR" "$BACKUP_DIR"
printf 'test-public-key\n' > "$KEY_DIR/id_ed25519.pub"
if CONTROLLED_KEY_BACKUP_DIR="$BACKUP_DIR" \
    sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" reset-server-key-dir "$KEY_DIR" >"$WORK_DIR/no-force.log" 2>&1; then
    fail "server key 清理未要求 --force"
fi
grep -q 'ERR-2395' "$WORK_DIR/no-force.log" || fail "server key 拒绝路径缺少 ERR-2395"

if CONTROLLED_KEY_BACKUP_DIR="$BACKUP_DIR" \
    sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" reset-server-key-dir "$KEY_DIR" --force >"$WORK_DIR/no-root.log" 2>&1; then
    fail "server key 清理未要求显式允许目录"
fi
grep -q 'ERR-2395.*CONTROLLED_KEY_ALLOWED_ROOT' "$WORK_DIR/no-root.log" || fail "缺少允许目录未明确拒绝"
[ -f "$KEY_DIR/id_ed25519.pub" ] || fail "缺少允许目录时修改了 key 文件"

if [ "$CAN_VERIFY_POSIX_MODE" -eq 1 ]; then
    ln -s "$KEY_DIR" "$WORK_DIR/server-key-link"
    if CONTROLLED_KEY_ALLOWED_ROOT="$WORK_DIR" CONTROLLED_KEY_BACKUP_DIR="$BACKUP_DIR" \
        sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" reset-server-key-dir "$WORK_DIR/server-key-link" --force >"$WORK_DIR/key-link.log" 2>&1; then
        fail "server key 清理未拒绝符号链接目标"
    fi
    grep -q 'ERR-2395.*符号链接' "$WORK_DIR/key-link.log" || fail "符号链接目标未明确拒绝"
    [ -f "$KEY_DIR/id_ed25519.pub" ] || fail "符号链接被拒绝后修改了 key 文件"
fi

mkdir -p "$KEY_DIR/nested-backup"
if CONTROLLED_KEY_ALLOWED_ROOT="$WORK_DIR" CONTROLLED_KEY_BACKUP_DIR="$KEY_DIR/nested-backup" \
    sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" reset-server-key-dir "$KEY_DIR" --force >"$WORK_DIR/nested-backup.log" 2>&1; then
    fail "server key 清理未拒绝嵌套备份目录"
fi
grep -q 'ERR-2395.*备份目录不能位于' "$WORK_DIR/nested-backup.log" || fail "嵌套备份目录未明确拒绝"
[ -f "$KEY_DIR/id_ed25519.pub" ] || fail "嵌套备份被拒绝后修改了 key 文件"

CONTROLLED_KEY_ALLOWED_ROOT="$WORK_DIR" CONTROLLED_KEY_BACKUP_DIR="$BACKUP_DIR" \
    sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" reset-server-key-dir "$KEY_DIR" --force >/dev/null
[ -z "$(find "$KEY_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "server key 目录未被清空"
[ -n "$(find "$BACKUP_DIR" -type f -name 'id_ed25519.pub' -print -quit)" ] || fail "server key 未生成备份"
pass "RustDesk server key 强制轮换保护"

# 只加载配置更新函数，避免启动进程；覆盖后台保存后的四空格缩进和 TLS 校验。
(
    eval "$(sed -n '/^fail() {$/,/^}$/p' "$ROOT_DIR/docker/controlled-entrypoint.sh")"
    eval "$(sed -n '/^normalize_port() {$/,/^}$/p' "$ROOT_DIR/docker/controlled-entrypoint.sh")"
    eval "$(sed -n '/^write_or_replace_yaml_value() {$/,/^}$/p' "$ROOT_DIR/docker/controlled-entrypoint.sh")"
    eval "$(sed -n '/^configure_tls() {$/,/^}$/p' "$ROOT_DIR/docker/controlled-entrypoint.sh")"
    if [ "$CAN_VERIFY_POSIX_MODE" -eq 0 ]; then
        find() {
            case " $* " in
                *' -perm /077 '*) return 0 ;;
                *) command find "$@" ;;
            esac
        }
    fi
    indent_yaml="$WORK_DIR/indent.yaml"
    printf 'httpConfig:\n    port: ":12345"\n    staticdir: "/app/dist"\nrustdeskServer:\n    internalSecret: "fixture"\n' > "$indent_yaml"
    write_or_replace_yaml_value "$indent_yaml" httpConfig port '":22345"'
    write_or_replace_yaml_value "$indent_yaml" httpConfig adminPort '":22346"'
    write_or_replace_yaml_value "$indent_yaml" rustdeskServer internalSecret '"fixture-updated"'
    write_or_replace_yaml_value "$indent_yaml" rustdeskServer authCacheSeconds 60
    grep -q '^    port: ":22345"$' "$indent_yaml" || fail "配置更新未保留四空格缩进"
    grep -q '^    adminPort: ":22346"$' "$indent_yaml" || fail "缺失字段插入未沿用四空格缩进"
    grep -q '^    internalSecret: "fixture-updated"$' "$indent_yaml" || fail "内部密钥更新破坏缩进"
    grep -q '^    authCacheSeconds: 60$' "$indent_yaml" || fail "末尾字段插入破坏缩进"
    printf 'httpConfig:\n' > "$indent_yaml"
    write_or_replace_yaml_value "$indent_yaml" httpConfig port '":12345"'
    grep -q '^  port: ":12345"$' "$indent_yaml" || fail "空配置段缺失默认缩进"

    tls_dir="$WORK_DIR/tls"
    mkdir -p "$tls_dir"
    printf 'fixture certificate\n' > "$tls_dir/server.fullchain.pem"
    printf 'fixture private key\n' > "$tls_dir/server.key.pem"
    chmod 600 "$tls_dir/server.key.pem"
    printf 'httpConfig:\n  port: ":12345"\n' > "$indent_yaml"
    CONTROLLED_TLS_ALLOWED_DIR="$tls_dir" TLS_PORT=12443 \
        TLS_CERT_FILE="$tls_dir/server.fullchain.pem" TLS_KEY_FILE="$tls_dir/server.key.pem" \
        configure_tls "$indent_yaml"
    grep -q '^  tlsPort: ":12443"$' "$indent_yaml" || fail "TLS 端口未写入配置"
    grep -q "^  tlsCertFile: \"$tls_dir/server.fullchain.pem\"$" "$indent_yaml" || fail "TLS 证书路径未写入配置"
    grep -q "^  tlsKeyFile: \"$tls_dir/server.key.pem\"$" "$indent_yaml" || fail "TLS 私钥路径未写入配置"
    if (CONTROLLED_TLS_ALLOWED_DIR="$tls_dir" TLS_PORT=12443 TLS_CERT_FILE="$tls_dir/server.fullchain.pem" \
        TLS_KEY_FILE="" configure_tls "$indent_yaml") >/dev/null 2>&1; then
        fail "TLS 配置缺项未被拒绝"
    fi
    if (CONTROLLED_TLS_ALLOWED_DIR="$tls_dir" TLS_PORT=12443 TLS_CERT_FILE="$tls_dir/bad\"path.pem" \
        TLS_KEY_FILE="$tls_dir/server.key.pem" configure_tls "$indent_yaml") >/dev/null 2>&1; then
        fail "TLS 非法文件路径未被拒绝"
    fi
    cp "$indent_yaml" "$WORK_DIR/tls-config.good"
    printf 'outside certificate\n' > "$WORK_DIR/outside-cert.pem"
    printf 'outside private key\n' > "$WORK_DIR/outside-key.pem"
    chmod 600 "$WORK_DIR/outside-key.pem"
    mkdir -p "$tls_dir/nested"
    for tls_field in cert key; do
        for tls_relative in "../outside-${tls_field}.pem" "nested/../../outside-${tls_field}.pem"; do
            tls_cert="$tls_dir/server.fullchain.pem"
            tls_key="$tls_dir/server.key.pem"
            case "$tls_field" in
                cert) tls_cert="$tls_dir/$tls_relative" ;;
                key) tls_key="$tls_dir/$tls_relative" ;;
            esac
            if (CONTROLLED_TLS_ALLOWED_DIR="$tls_dir" TLS_PORT=12443 TLS_CERT_FILE="$tls_cert" \
                TLS_KEY_FILE="$tls_key" configure_tls "$indent_yaml") >"$WORK_DIR/tls-path.log" 2>&1; then
                fail "TLS 路径穿越未被拒绝：$tls_field"
            fi
            grep -q 'ERR-2390.*直接子文件' "$WORK_DIR/tls-path.log" || fail "TLS 路径穿越拒绝缺少明确原因"
            cmp -s "$indent_yaml" "$WORK_DIR/tls-config.good" || fail "TLS 拒绝路径仍改写了配置"
        done
    done
    if [ "$CAN_VERIFY_POSIX_MODE" -eq 1 ]; then
        ln -s "$tls_dir" "$WORK_DIR/tls-link"
        if (CONTROLLED_TLS_ALLOWED_DIR="$WORK_DIR/tls-link" TLS_PORT=12443 \
            TLS_CERT_FILE="$WORK_DIR/tls-link/server.fullchain.pem" TLS_KEY_FILE="$WORK_DIR/tls-link/server.key.pem" \
            configure_tls "$indent_yaml") >"$WORK_DIR/tls-dir-link.log" 2>&1; then
            fail "TLS 符号链接目录未被拒绝"
        fi
        grep -q 'ERR-2390.*符号链接' "$WORK_DIR/tls-dir-link.log" || fail "TLS 目录符号链接拒绝缺少明确原因"
        cmp -s "$indent_yaml" "$WORK_DIR/tls-config.good" || fail "TLS 符号链接拒绝仍改写了配置"
        chmod 644 "$tls_dir/server.key.pem"
        if (CONTROLLED_TLS_ALLOWED_DIR="$tls_dir" TLS_PORT=12443 TLS_CERT_FILE="$tls_dir/server.fullchain.pem" \
            TLS_KEY_FILE="$tls_dir/server.key.pem" configure_tls "$indent_yaml") >/dev/null 2>&1; then
            fail "权限过宽的 TLS 私钥未被拒绝"
        fi
    fi
)
if [ "$CAN_VERIFY_POSIX_MODE" -eq 1 ]; then
    pass "配置更新、TLS 完整性、私钥权限及空配置段缩进回归"
else
    pass "配置更新、TLS 完整性及空配置段缩进回归（Windows 不验证 POSIX 权限）"
fi

FAKE_BIN="$WORK_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/wget" <<'EOF'
#!/bin/sh
for argument in "$@"; do url="$argument"; done
printf '%s\n' "$url" >> "$MOCK_WGET_LOG"
case "$url" in
    https://*) [ "${MOCK_TLS_FAIL:-0}" = 0 ] ;;
    http://*) exit 0 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$FAKE_BIN/wget"
MOCK_WGET_LOG="$WORK_DIR/wget.log" PATH="$FAKE_BIN:$PATH" CONTROLLED_PID_DIR="$WORK_DIR/pids" \
    TLS_PORT=12443 sh "$ROOT_DIR/docker/controlled-healthcheck.sh"
grep -q '^http://127.0.0.1:12345/api/health$' "$WORK_DIR/wget.log" || fail "健康检查未调用客户端 API"
grep -q '^https://127.0.0.1:12443/$' "$WORK_DIR/wget.log" || fail "健康检查未调用 HTTPS"
if MOCK_WGET_LOG="$WORK_DIR/wget-fail.log" MOCK_TLS_FAIL=1 PATH="$FAKE_BIN:$PATH" \
    CONTROLLED_PID_DIR="$WORK_DIR/pids" TLS_PORT=12443 \
    sh "$ROOT_DIR/docker/controlled-healthcheck.sh" >"$WORK_DIR/health-tls-fail.log" 2>&1; then
    fail "HTTPS 握手失败未使健康检查失败"
fi
grep -q 'ERR-2391 HTTPS 健康检查失败' "$WORK_DIR/health-tls-fail.log" || fail "HTTPS 失败缺少 ERR-2391"
pass "客户端 API 与内置 HTTPS 健康检查回归"

cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/sh
secret=""
url=""
noproxy=0
output_file=""
[ "$1" = "-q" ] || exit 1
while [ "$#" -gt 0 ]; do
    case "$1" in
        -k|--insecure|-L|--location) exit 1 ;;
        --noproxy)
            shift
            [ "$1" = "*" ] || exit 1
            noproxy=1
            ;;
        -H)
            shift
            case "$1" in
                @-)
                    IFS= read -r header || exit 1
                    case "$header" in
                        "X-Internal-Secret: "*) secret="${header#X-Internal-Secret: }" ;;
                        *) exit 1 ;;
                    esac
                    ;;
                "X-Internal-Secret: "*) exit 1 ;;
            esac
            ;;
        -o)
            shift
            output_file="$1"
            ;;
        http://*|https://*) url="$1" ;;
    esac
    shift
done
[ "$noproxy" -eq 1 ] || exit 1
printf '%s\n' "$url" >> "$MOCK_CURL_LOG"
case "$url" in
    http://public.test:22345/api/health|http://public.test:22345/api/login-options)
        [ -z "$secret" ] || exit 1
        case "${MOCK_PUBLIC_API_MODE:-ok}" in
            timeout) exit 28 ;;
            redirect) printf '<html>redirect</html>\n302\n'; exit 0 ;;
            html) printf '<html>management</html>\n200\n'; exit 0 ;;
            wrapped) printf '{"data":["password"]}\n200\n'; exit 0 ;;
            wrong-service) printf '{"ok":true,"service":"another-service"}\n200\n'; exit 0 ;;
            *)
                case "$url" in
                    */health) printf '{"ok":true,"service":"rustdesk-api-server-pro"}\n200\n' ;;
                    *)
                        case "${MOCK_PUBLIC_API_MODE:-ok}" in
                            login-object) printf '{"data":["password"]}\n200\n' ;;
                            login-number) printf '["password",1]\n200\n' ;;
                            *) printf '["password"]\n200\n' ;;
                        esac
                        ;;
                esac
                exit 0
                ;;
        esac
        ;;
    https://management.test:22346/)
        [ "${MOCK_MANAGEMENT_MODE:-ok}" != "cert-fail" ] || exit 60
        printf '200'
        exit 0
        ;;
    https://management.test:22346/downloads/rustdesk.jtzxsoft.com.cert.cer)
        printf 'fixture certificate' > "$output_file"
        printf '200'
        exit 0
        ;;
    https://management.test:22346/downloads/rustdesk-1.4.9-x86_64.exe|https://management.test:22346/downloads/rustdesk-1.5.0-x86_64.exe)
        if [ "${MOCK_MANAGEMENT_MODE:-ok}" = "download-fail" ]; then
            printf '404'
            exit 0
        fi
        printf 'fixture installer' > "$output_file"
        printf '200'
        exit 0
        ;;
    http://management.test:22346/)
        if [ "${MOCK_MANAGEMENT_MODE:-ok}" = "http-open" ]; then
            printf '200'
        else
            printf '%s' "${MOCK_MANAGEMENT_HTTP_STATUS:-400}"
        fi
        exit "${MOCK_MANAGEMENT_HTTP_EXIT:-0}"
        ;;
esac
case "$secret" in
    ""|wrong-internal-secret-for-security-check)
        printf '{"allow":false,"code":"ERR-2301"}\n401\n'
        ;;
    fixture-secret)
        if [ "${MOCK_CORRECT_MODE:-ok}" = "http500" ]; then
            printf '<html>upstream error</html>\n500\n'
        elif [ "${MOCK_CORRECT_MODE:-ok}" = "spoof" ]; then
            printf '<html>"allow":false "code":"ERR-2302"</html>\n200\n'
        else
            printf '{"allow":false,"code":"ERR-2302"}\n200\n'
        fi
        ;;
esac
EOF
chmod +x "$FAKE_BIN/curl"

MOCK_CURL_LOG="$WORK_DIR/curl.log" PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-good.log" 2>&1
grep -q '/internal/rustdesk/auth$' "$WORK_DIR/curl.log" || fail "安全检查未调用无副作用鉴权端点"
grep -q '/device/register' "$WORK_DIR/curl.log" && fail "安全检查仍调用会写入设备的注册端点"
grep -q '安全检查部分完成' "$WORK_DIR/security-good.log" || fail "缺少公网与旧地址时不得报告全部检查通过"

if MOCK_CURL_LOG="$WORK_DIR/curl-no-secret.log" PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="" \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-no-secret.log" 2>&1; then
    fail "缺少内部密钥时安全检查不应通过"
fi
grep -q 'ERR-2394.*未设置 RUSTDESK_API_INTERNAL_SECRET' "$WORK_DIR/security-no-secret.log" || fail "缺少内部密钥未明确报告失败"

if MOCK_CURL_LOG="$WORK_DIR/curl-http500.log" MOCK_CORRECT_MODE=http500 PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-http500.log" 2>&1; then
    fail "安全检查不应把正确密钥路径的 HTTP 500 误判为通过"
fi
grep -q 'ERR-2394' "$WORK_DIR/security-http500.log" || fail "安全检查 HTTP 失败路径缺少 ERR-2394"

if MOCK_CURL_LOG="$WORK_DIR/curl-spoof.log" MOCK_CORRECT_MODE=spoof PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-spoof.log" 2>&1; then
    fail "安全检查不应把正文中的伪造字段误判为结构化响应"
fi
grep -q 'ERR-2394' "$WORK_DIR/security-spoof.log" || fail "安全检查 JSON 失败路径缺少 ERR-2394"
pass "内部 API 安全检查严格响应与无副作用回归"

printf 'fixture public certificate\n' > "$WORK_DIR/management-ca.pem"
fixture_cert_sha256="$(printf 'fixture certificate' | sha256sum | awk '{print $1}')"
fixture_installer_sha256="$(printf 'fixture installer' | sha256sum | awk '{print $1}')"
export ADMIN_INSTALLER_150_SHA256="$fixture_installer_sha256"
MOCK_CURL_LOG="$WORK_DIR/curl-management.log" PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    ADMIN_HTTPS_URL="https://management.test:22346" ADMIN_TLS_CA_FILE="$WORK_DIR/management-ca.pem" \
    ADMIN_CERT_SHA256="$fixture_cert_sha256" ADMIN_INSTALLER_SHA256="$fixture_installer_sha256" \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-management.log" 2>&1
grep -q 'PASS: 管理页 HTTPS 证书和首页访问通过' "$WORK_DIR/security-management.log" || fail "管理页 HTTPS 正向检查未通过"
grep -q 'PASS: 管理页公开证书 HTTPS 下载和 SHA-256 校验通过' "$WORK_DIR/security-management.log" || fail "管理页证书下载摘要检查未通过"
grep -q 'PASS: RustDesk 1.4.9 安装包 HTTPS 下载和 SHA-256 校验通过' "$WORK_DIR/security-management.log" || fail "安装包下载摘要检查未通过"
grep -q 'PASS: RustDesk 1.5.0 安装包 HTTPS 下载和 SHA-256 校验通过' "$WORK_DIR/security-management.log" || fail "新版安装包下载摘要检查未通过"
grep -q 'PASS: 管理页 TLS 端口拒绝明文 HTTP' "$WORK_DIR/security-management.log" || fail "管理页明文 HTTP 拒绝未通过"

if MOCK_CURL_LOG="$WORK_DIR/curl-management-digest.log" PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    ADMIN_HTTPS_URL="https://management.test:22346" ADMIN_TLS_CA_FILE="$WORK_DIR/management-ca.pem" \
    ADMIN_CERT_SHA256="$fixture_cert_sha256" ADMIN_INSTALLER_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-management-digest.log" 2>&1; then
    fail "安装包下载摘要错误未被拒绝"
fi
grep -q 'ERR-2394.*安装包 SHA-256 不匹配' "$WORK_DIR/security-management-digest.log" || fail "安装包摘要错误缺少 ERR-2394"

if MOCK_CURL_LOG="$WORK_DIR/curl-management-digest150.log" PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    ADMIN_HTTPS_URL="https://management.test:22346" ADMIN_TLS_CA_FILE="$WORK_DIR/management-ca.pem" \
    ADMIN_CERT_SHA256="$fixture_cert_sha256" ADMIN_INSTALLER_SHA256="$fixture_installer_sha256" \
    ADMIN_INSTALLER_150_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-management-digest150.log" 2>&1; then
    fail "新版安装包下载摘要错误未被拒绝"
fi
grep -q 'ERR-2394.*1.5.0 安装包 SHA-256 不匹配' "$WORK_DIR/security-management-digest150.log" || fail "新版安装包摘要错误缺少 ERR-2394"

if MOCK_CURL_LOG="$WORK_DIR/curl-management-download.log" MOCK_MANAGEMENT_MODE=download-fail PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    ADMIN_HTTPS_URL="https://management.test:22346" ADMIN_TLS_CA_FILE="$WORK_DIR/management-ca.pem" \
    ADMIN_CERT_SHA256="$fixture_cert_sha256" ADMIN_INSTALLER_SHA256="$fixture_installer_sha256" \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-management-download.log" 2>&1; then
    fail "安装包下载 HTTP 失败未被拒绝"
fi
grep -q 'ERR-2394.*安装包.*下载失败.*HTTP 404' "$WORK_DIR/security-management-download.log" || fail "安装包下载 HTTP 失败缺少 ERR-2394"

invalid_digest_index=0
for invalid_digest in bad gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg; do
    invalid_digest_index=$((invalid_digest_index + 1))
    invalid_digest_log="$WORK_DIR/security-management-invalid-digest-${invalid_digest_index}.log"
    if MOCK_CURL_LOG="$WORK_DIR/curl-management-invalid-digest-${invalid_digest_index}.log" PATH="$FAKE_BIN:$PATH" \
        API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
        ADMIN_HTTPS_URL="https://management.test:22346" ADMIN_TLS_CA_FILE="$WORK_DIR/management-ca.pem" \
        ADMIN_CERT_SHA256="$invalid_digest" ADMIN_INSTALLER_SHA256="$fixture_installer_sha256" \
        sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$invalid_digest_log" 2>&1; then
        fail "非法下载摘要未被拒绝"
    fi
    grep -q 'ERR-2394.*预期 SHA-256.*无效' "$invalid_digest_log" || fail "非法下载摘要缺少 ERR-2394"
done

if MOCK_CURL_LOG="$WORK_DIR/curl-management-cert.log" MOCK_MANAGEMENT_MODE=cert-fail PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    ADMIN_HTTPS_URL="https://management.test:22346" ADMIN_TLS_CA_FILE="$WORK_DIR/management-ca.pem" \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-management-cert.log" 2>&1; then
    fail "管理页 HTTPS 证书失败未被拒绝"
fi
grep -q 'ERR-2394.*HTTPS 证书或连接验证失败' "$WORK_DIR/security-management-cert.log" || fail "管理页证书失败缺少 ERR-2394"

if MOCK_CURL_LOG="$WORK_DIR/curl-management-http.log" MOCK_MANAGEMENT_MODE=http-open PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    ADMIN_HTTPS_URL="https://management.test:22346" ADMIN_TLS_CA_FILE="$WORK_DIR/management-ca.pem" \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-management-http.log" 2>&1; then
    fail "管理页 TLS 端口接受明文 HTTP 时安全检查未失败"
fi
grep -q 'ERR-2394.*仍接受明文 HTTP' "$WORK_DIR/security-management-http.log" || fail "管理页明文开放缺少 ERR-2394"

for http_exit in 6 7 28 52 56; do
    http_failure_log="$WORK_DIR/security-management-http-exit-${http_exit}.log"
    if MOCK_CURL_LOG="$WORK_DIR/curl-management-http-exit-${http_exit}.log" \
        MOCK_MANAGEMENT_HTTP_EXIT="$http_exit" PATH="$FAKE_BIN:$PATH" \
        API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
        ADMIN_HTTPS_URL="https://management.test:22346" ADMIN_TLS_CA_FILE="$WORK_DIR/management-ca.pem" \
        ADMIN_CERT_SHA256="$fixture_cert_sha256" ADMIN_INSTALLER_SHA256="$fixture_installer_sha256" \
        sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$http_failure_log" 2>&1; then
        fail "明文 HTTP 请求错误 $http_exit 被误判为拒绝通过"
    fi
    grep -q "ERR-2394.*拒绝状态无法确认.*curl $http_exit" "$http_failure_log" || fail "明文 HTTP 请求错误缺少明确失败原因"
    if grep -q 'PASS: 管理页 TLS 端口拒绝明文 HTTP' "$http_failure_log"; then
        fail "明文 HTTP 请求错误仍输出拒绝通过"
    fi
done

for http_status in 101 302 000 invalid; do
    http_status_log="$WORK_DIR/security-management-http-status-${http_status}.log"
    if MOCK_CURL_LOG="$WORK_DIR/curl-management-http-status-${http_status}.log" \
        MOCK_MANAGEMENT_HTTP_STATUS="$http_status" PATH="$FAKE_BIN:$PATH" \
        API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
        ADMIN_HTTPS_URL="https://management.test:22346" ADMIN_TLS_CA_FILE="$WORK_DIR/management-ca.pem" \
        ADMIN_CERT_SHA256="$fixture_cert_sha256" ADMIN_INSTALLER_SHA256="$fixture_installer_sha256" \
        sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$http_status_log" 2>&1; then
        fail "明文 HTTP 非拒绝响应 $http_status 被误判为通过"
    fi
    grep -q 'ERR-2394' "$http_status_log" || fail "明文 HTTP 非拒绝响应缺少 ERR-2394"
done

if MOCK_CURL_LOG="$WORK_DIR/curl-management-url.log" PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    ADMIN_HTTPS_URL="https://management.test:22346/admin" ADMIN_TLS_CA_FILE="$WORK_DIR/management-ca.pem" \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-management-url.log" 2>&1; then
    fail "管理页 HTTPS 检查接受了带路径的 URL"
fi
grep -q 'ERR-2394.*只允许域名或 IPv4' "$WORK_DIR/security-management-url.log" || fail "非法管理 URL 缺少 ERR-2394"

if MOCK_CURL_LOG="$WORK_DIR/curl-management-missing.log" PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    ADMIN_HTTPS_URL="https://management.test:22346" ADMIN_TLS_CA_FILE="" \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-management-missing.log" 2>&1; then
    fail "管理页 HTTPS URL 与 CA 缺项未被拒绝"
fi
grep -q 'ERR-2394.*必须同时设置' "$WORK_DIR/security-management-missing.log" || fail "管理页 HTTPS 缺项拒绝缺少 ERR-2394"
pass "管理页受信任 HTTPS、下载摘要、证书失败和明文拒绝回归"

INJECTION_MARKER="$WORK_DIR/port-injection"
if MOCK_CURL_LOG="$WORK_DIR/curl-endpoint.log" PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    PUBLIC_HOST="127.0.0.1;touch $INJECTION_MARKER;#" \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-endpoint.log" 2>&1; then
    fail "安全检查不应接受包含 shell 字符的探测主机名"
fi
[ ! -e "$INJECTION_MARKER" ] || fail "端口探测把主机名当作 shell 语句执行"
grep -q 'ERR-2394' "$WORK_DIR/security-endpoint.log" || fail "非法探测主机拒绝路径缺少 ERR-2394"
grep -q '主机名包含非法字符' "$WORK_DIR/security-endpoint.log" || fail "非法探测主机未返回明确原因"

if MOCK_CURL_LOG="$WORK_DIR/curl-port.log" PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    PUBLIC_HOST="127.0.0.1" RUSTDESK_HBBS_TCP_21115="70000" \
    RUSTDESK_HBBS_TCP_21116="bad" RUSTDESK_HBBR_TCP_21117="0" \
    FNOS_ADMIN_HTTP_PORT="999999999999999999999999999999" \
    RUSTDESK_HBBS_WEB_PORT="bad" RUSTDESK_HBBR_WEB_PORT="0" \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-port.log" 2>&1; then
    fail "安全检查不应接受无效探测端口"
fi
grep -q '端口不是有效数字' "$WORK_DIR/security-port.log" || fail "非数字探测端口未返回明确原因"
grep -q '端口超出有效范围' "$WORK_DIR/security-port.log" || fail "越界探测端口未返回明确原因"
grep -q 'integer expression expected' "$WORK_DIR/security-port.log" && fail "超长端口触发了 shell 整数错误"
pass "端口探测参数校验与命令注入回归"

if MOCK_CURL_LOG="$WORK_DIR/curl-unresolved.log" PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    OLD_RUSTDESK_HOST="::gg" OLD_RUSTDESK_HBBS_UDP_21116=32116 PORT_TIMEOUT_SECONDS=1 \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-unresolved.log" 2>&1; then
    fail "无法解析的旧服务地址不应被判定为端口已关闭"
fi
grep -q 'ERR-2394.*无法确认已关闭' "$WORK_DIR/security-unresolved.log" || fail "旧服务地址解析失败未明确报告无法确认"
grep -q 'PASS: 旧裸' "$WORK_DIR/security-unresolved.log" && fail "旧服务地址解析失败被误记为通过"
grep -q '旧裸 hbbs 32116/UDP 未经 TCP 探针验证' "$WORK_DIR/security-unresolved.log" || fail "旧服务 UDP 暴露边界未使用实际公网端口"

if MOCK_CURL_LOG="$WORK_DIR/curl-timeout.log" PATH="$FAKE_BIN:$PATH" \
    API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
    OLD_RUSTDESK_HOST="127.0.0.1" PORT_TIMEOUT_SECONDS=invalid \
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-timeout.log" 2>&1; then
    fail "无效探测超时不应被判定为端口已关闭"
fi
grep -q 'ERR-2394.*无法确认已关闭' "$WORK_DIR/security-timeout.log" || fail "无效探测超时未明确报告无法确认"
pass "端口探测解析失败及无效超时默认拒绝回归"

if command -v python3 >/dev/null 2>&1 && python3 --version >/dev/null 2>&1; then
    REAL_PYTHON="$(command -v python3)"
else
    REAL_PYTHON="$(command -v python)"
fi
export REAL_PYTHON
cat > "$FAKE_BIN/python3" <<'EOF'
#!/bin/sh
case "${2:-}" in
    --public)
        [ "$#" -eq 8 ] && [ "$3" = "wss.test" ] && [ "$4" = "21118" ] && [ "$5" = "21119" ] \
            && [ -f "$6" ] && [ "$7" = "wss://wss.test:21118/" ] && [ "$8" = "wss://wss.test:21119/" ] || exit 19
        printf 'fixture-public-wss\n'
        exit "${MOCK_WSS_EXIT:-0}"
        ;;
    *connect_ex*)
        if [ "$3" = public.test ]; then
            case "$4" in
                22115|22116|22117) exit 0 ;;
                *) exit 1 ;;
            esac
        fi
        case "$4" in
            12346) exit 1 ;;
            *) exit 0 ;;
        esac
        ;;
esac
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$FAKE_BIN/python3"
cp "$FAKE_BIN/python3" "$FAKE_BIN/python"

for wss_mode in default partial enabled rejected; do
    wss_hbbs=""
    wss_hbbr=""
    wss_ca=""
    wss_exit=0
    case "$wss_mode" in
        partial) wss_hbbs="wss://wss.test:21118/" ;;
        enabled|rejected)
            wss_hbbs="wss://wss.test:21118/"
            wss_hbbr="wss://wss.test:21119/"
            wss_ca="$WORK_DIR/management-ca.pem"
            [ "$wss_mode" != rejected ] || wss_exit=17
            ;;
    esac
    result=0
    MOCK_CURL_LOG="$WORK_DIR/curl-wss-$wss_mode.log" PATH="$FAKE_BIN:$PATH" \
        API_BASE_URL="http://api.test" RUSTDESK_API_INTERNAL_SECRET="fixture-secret" \
        PUBLIC_HOST=wss.test PUBLIC_WSS_HBBS_URL="$wss_hbbs" PUBLIC_WSS_HBBR_URL="$wss_hbbr" \
        PUBLIC_WSS_CA_FILE="$wss_ca" MOCK_WSS_EXIT="$wss_exit" \
        sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" >"$WORK_DIR/security-wss-$wss_mode.log" 2>&1 || result=$?
    if [ "$wss_mode" = enabled ]; then
        [ "$result" -eq 0 ] || fail "显式 WSS 配置未调用双端证书升级门禁"
        grep -q 'fixture-public-wss' "$WORK_DIR/security-wss-$wss_mode.log" || fail "未实际调用 WSS 探针"
        grep -q '公网 WSS 仅验证传输入口' "$WORK_DIR/security-wss-$wss_mode.log" || fail "WSS 门禁缺少业务未验证提示"
    else
        [ "$result" -ne 0 ] || fail "WSS 默认关闭、缺项或探针失败被误判通过：$wss_mode"
        grep -q 'ERR-2394' "$WORK_DIR/security-wss-$wss_mode.log" || fail "WSS 门禁失败缺少错误编码"
    fi
done

# 外网只需公开端点与公开证书，不应复制目标主机内部密钥。
run_public_check() (
    export PATH="$FAKE_BIN:$PATH" MOCK_CURL_LOG="$WORK_DIR/curl-public.log" \
        PUBLIC_HOST=public.test PUBLIC_API_BASE_URL=http://public.test:22345 \
        ADMIN_HTTPS_URL=https://management.test:22346 ADMIN_TLS_CA_FILE="$WORK_DIR/management-ca.pem" \
        ADMIN_CERT_SHA256="$fixture_cert_sha256" ADMIN_INSTALLER_SHA256="$fixture_installer_sha256" \
        RUSTDESK_HBBS_TCP_21115=22115 RUSTDESK_HBBS_TCP_21116=22116 RUSTDESK_HBBR_TCP_21117=22117 \
        FNOS_ADMIN_HTTP_PORT=22347 RUSTDESK_HBBS_WEB_PORT=22118 RUSTDESK_HBBR_WEB_PORT=22119 \
        OLD_RUSTDESK_HOST=public.test RUSTDESK_API_INTERNAL_SECRET=fixture-secret
    for setting in "$@"; do
        export "$setting"
    done
    sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" --public-only
)

run_public_check >"$WORK_DIR/security-public.log" 2>&1
grep -q 'PASS: 公网 API health 应用层响应通过' "$WORK_DIR/security-public.log" || {
    cat "$WORK_DIR/security-public.log"
    fail "公网 API 健康契约未通过"
}
grep -q 'PASS: 公网 API login-options 应用层响应通过' "$WORK_DIR/security-public.log" || fail "公网 API 登录选项未通过"
grep -q '/internal/' "$WORK_DIR/curl-public.log" && fail "独立公网模式调用了内部接口"
grep -q '安全检查部分完成' "$WORK_DIR/security-public.log" || fail "独立公网模式未保留 UDP 和内部鉴权边界"

for api_mode in timeout redirect html wrapped wrong-service login-object login-number; do
    if run_public_check MOCK_PUBLIC_API_MODE="$api_mode" >"$WORK_DIR/security-public-$api_mode.log" 2>&1; then
        fail "公网 API 错误响应被误判成功：$api_mode"
    fi
    grep -q 'ERR-2394.*公网 API' "$WORK_DIR/security-public-$api_mode.log" || fail "公网 API 失败未明确报告"
done
for invalid_api in 'http://user:secret@public.test:22345' 'http://public.test:22345/?token=secret' \
    'file:///etc/passwd' 'http://public.test:70000' 'http://public.test:22345/admin'; do
    if run_public_check PUBLIC_API_BASE_URL="$invalid_api" >"$WORK_DIR/security-public-url.log" 2>&1; then
        fail "公网 API URL 非法边界未拒绝"
    fi
    grep -q 'secret' "$WORK_DIR/security-public-url.log" && fail "公网 API URL 拒绝日志泄漏用户信息或查询凭据"
done
for required_setting in PUBLIC_HOST PUBLIC_API_BASE_URL ADMIN_HTTPS_URL ADMIN_TLS_CA_FILE; do
    : > "$WORK_DIR/curl-public.log"
    if run_public_check "$required_setting=" >"$WORK_DIR/security-public-missing.log" 2>&1; then
        fail "独立公网模式缺少必填端点未拒绝：$required_setting"
    fi
    [ ! -s "$WORK_DIR/curl-public.log" ] || fail "独立公网模式缺项后仍发起 HTTP 请求"
done
if sh "$ROOT_DIR/scripts/deploy/controlled-security-check.sh" --unknown >"$WORK_DIR/security-public-argument.log" 2>&1; then
    fail "未知参数未拒绝"
fi
pass "独立公网无凭据入口、API 契约、错误响应与 URL 边界回归"
rm "$FAKE_BIN/python3" "$FAKE_BIN/python"
pass "公网 WSS 默认关闭、显式双端升级、配置缺项及失败拒绝回归"

THREE_BIN="$WORK_DIR/three-preflight-bin"
mkdir -p "$THREE_BIN"
cat > "$THREE_BIN/docker" <<'EOF'
#!/bin/sh
if [ "$1" = image ] && [ "$2" = inspect ]; then
    [ "$3" != alpine:3.20.3 ] || exit 1
    exit 0
fi
printf 'unexpected-runtime-call\n' >> "$MOCK_THREE_LOG"
exit 91
EOF
chmod +x "$THREE_BIN/docker"
if MOCK_THREE_LOG="$WORK_DIR/three-runtime.log" PATH="$THREE_BIN:$PATH" \
    RUSTDESK_API_IMAGE=fixture-api RUSTDESK_CONTROLLED_SERVER_IMAGE=fixture-server \
    sh "$ROOT_DIR/scripts/deploy/controlled-three-compose-smoke.sh" "$ROOT_DIR" >"$WORK_DIR/three-preflight.log" 2>&1; then
    fail "三容器入口未提前拒绝缺少独立来源镜像"
fi
grep -q 'ERR-239B 找不到指定测试镜像' "$WORK_DIR/three-preflight.log" || fail "缺少来源镜像未返回明确错误"
[ ! -e "$WORK_DIR/three-runtime.log" ] || fail "缺少来源镜像时已经启动容器或修改运行状态"
pass "缺少固定独立来源镜像在任何容器启动前拒绝"

OFFLINE_DIR="$WORK_DIR/offline-release"
mkdir -p "$OFFLINE_DIR"
printf 'fixture archive\n' > "$OFFLINE_DIR/controlled-images.tar"
printf '%s\n' \
    'RUSTDESK_API_IMAGE=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    'RUSTDESK_CONTROLLED_SERVER_IMAGE=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    > "$OFFLINE_DIR/images.env"
printf '11111111-2222-3333-4444-555555555555\n' > "$OFFLINE_DIR/source-docker-id"
(
    cd "$OFFLINE_DIR"
    sha256sum controlled-images.tar images.env source-docker-id > SHA256SUMS
)
sh "$ROOT_DIR/scripts/deploy/controlled-offline-import-acceptance.sh" --verify-only "$OFFLINE_DIR" "$ROOT_DIR" >/dev/null
if sh "$ROOT_DIR/scripts/deploy/controlled-offline-import-acceptance.sh" "$OFFLINE_DIR" "$ROOT_DIR" >"$WORK_DIR/offline-host.log" 2>&1; then
    fail "离线导入检查未要求独立主机显式确认"
fi
grep -q 'ERR-2397' "$WORK_DIR/offline-host.log" || fail "独立主机确认拒绝缺少 ERR-2397"
grep -q 'CONTROLLED_INDEPENDENT_HOST=1' "$WORK_DIR/offline-host.log" || fail "独立主机确认拒绝缺少明确操作提示"
cat > "$FAKE_BIN/docker" <<'EOF'
#!/bin/sh
if [ "$1" = "info" ]; then
    printf '11111111-2222-3333-4444-555555555555\n'
else
    printf 'unexpected docker call: %s\n' "$1" >&2
    exit 1
fi
EOF
chmod +x "$FAKE_BIN/docker"
if PATH="$FAKE_BIN:$PATH" CONTROLLED_INDEPENDENT_HOST=1 \
    sh "$ROOT_DIR/scripts/deploy/controlled-offline-import-acceptance.sh" "$OFFLINE_DIR" "$ROOT_DIR" >"$WORK_DIR/offline-same-host.log" 2>&1; then
    fail "离线导入检查未拒绝来源 Docker 守护进程"
fi
grep -q 'ERR-2397 目标使用来源 Docker 守护进程' "$WORK_DIR/offline-same-host.log" || fail "同机拒绝缺少 ERR-2397"

cp "$OFFLINE_DIR/SHA256SUMS" "$WORK_DIR/SHA256SUMS.good"
if [ "$CAN_VERIFY_POSIX_MODE" -eq 1 ]; then
    for linked_file in SHA256SUMS controlled-images.tar images.env source-docker-id; do
        mv "$OFFLINE_DIR/$linked_file" "$WORK_DIR/offline-original-$linked_file"
        ln -s "$WORK_DIR/offline-original-$linked_file" "$OFFLINE_DIR/$linked_file"
        if sh "$ROOT_DIR/scripts/deploy/controlled-offline-import-acceptance.sh" --verify-only \
            "$OFFLINE_DIR" "$ROOT_DIR" >"$WORK_DIR/offline-link.log" 2>&1; then
            fail "离线导入检查未拒绝符号链接：$linked_file"
        fi
        grep -q 'ERR-2397.*符号链接' "$WORK_DIR/offline-link.log" || fail "离线符号链接拒绝缺少明确原因"
        rm "$OFFLINE_DIR/$linked_file"
        mv "$WORK_DIR/offline-original-$linked_file" "$OFFLINE_DIR/$linked_file"
    done
    sh "$ROOT_DIR/scripts/deploy/controlled-offline-import-acceptance.sh" --verify-only "$OFFLINE_DIR" "$ROOT_DIR" >/dev/null
    pass "离线摘要清单、镜像归档、环境与来源文件符号链接拒绝及恢复"
else
    printf 'SKIP: Windows 不验证离线候选包符号链接语义，需 Linux 回归\n'
fi
printf 'tampered\n' >> "$OFFLINE_DIR/controlled-images.tar"
if sh "$ROOT_DIR/scripts/deploy/controlled-offline-import-acceptance.sh" --verify-only "$OFFLINE_DIR" "$ROOT_DIR" >"$WORK_DIR/offline-hash.log" 2>&1; then
    fail "离线导入检查未拒绝摘要不匹配"
fi
grep -q 'ERR-2397' "$WORK_DIR/offline-hash.log" || fail "离线摘要拒绝路径缺少 ERR-2397"
printf 'fixture archive\n' > "$OFFLINE_DIR/controlled-images.tar"
cp "$WORK_DIR/SHA256SUMS.good" "$OFFLINE_DIR/SHA256SUMS"

printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  ../escape' > "$OFFLINE_DIR/SHA256SUMS"
if sh "$ROOT_DIR/scripts/deploy/controlled-offline-import-acceptance.sh" --verify-only "$OFFLINE_DIR" "$ROOT_DIR" >"$WORK_DIR/offline-path.log" 2>&1; then
    fail "离线导入检查未拒绝越界摘要路径"
fi
grep -q 'ERR-2397' "$WORK_DIR/offline-path.log" || fail "离线路径拒绝缺少 ERR-2397"
cp "$WORK_DIR/SHA256SUMS.good" "$OFFLINE_DIR/SHA256SUMS"

printf 'UNEXPECTED=value\n' >> "$OFFLINE_DIR/images.env"
(
    cd "$OFFLINE_DIR"
    sha256sum controlled-images.tar images.env source-docker-id > SHA256SUMS
)
if sh "$ROOT_DIR/scripts/deploy/controlled-offline-import-acceptance.sh" --verify-only "$OFFLINE_DIR" "$ROOT_DIR" >"$WORK_DIR/offline-env.log" 2>&1; then
    fail "离线导入检查未拒绝未知环境变量"
fi
grep -q 'ERR-2397' "$WORK_DIR/offline-env.log" || fail "离线环境拒绝缺少 ERR-2397"
pass "离线候选包摘要、路径和镜像清单回归"

printf '\n受控部署工具自测通过。\n'
