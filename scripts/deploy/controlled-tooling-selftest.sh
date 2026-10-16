#!/bin/sh

set -eu

ROOT_DIR="${1:-$(pwd)}"
TMP_PARENT="$(CDPATH= cd -- "${TMPDIR:-/tmp}" && pwd -P)"
WORK_DIR="$(mktemp -d "$TMP_PARENT/rustdesk-controlled-tooling.XXXXXX")"

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
if find "$WORK_DIR" -maxdepth 1 -type f -name 'server.yaml.bak.*' -exec stat -c %a {} \; | grep -vq '^600$'; then
    fail "signKey 备份权限不是 0600"
fi
[ -z "$(find "$WORK_DIR" -maxdepth 1 -type f -name 'server.yaml.tmp.*' -print -quit)" ] || fail "signKey 轮换留下临时配置文件"
ln -s "$SERVER_YAML" "$WORK_DIR/server-link.yaml"
if sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" rotate-sign-key "$WORK_DIR/server-link.yaml" >"$WORK_DIR/signkey-link.log" 2>&1; then
    fail "signKey 轮换未拒绝符号链接配置文件"
fi
grep -q 'ERR-2395.*符号链接' "$WORK_DIR/signkey-link.log" || fail "符号链接配置文件未明确拒绝"
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

ln -s "$KEY_DIR" "$WORK_DIR/server-key-link"
if CONTROLLED_KEY_ALLOWED_ROOT="$WORK_DIR" CONTROLLED_KEY_BACKUP_DIR="$BACKUP_DIR" \
    sh "$ROOT_DIR/scripts/deploy/controlled-key-rotation.sh" reset-server-key-dir "$WORK_DIR/server-key-link" --force >"$WORK_DIR/key-link.log" 2>&1; then
    fail "server key 清理未拒绝符号链接目标"
fi
grep -q 'ERR-2395.*符号链接' "$WORK_DIR/key-link.log" || fail "符号链接目标未明确拒绝"
[ -f "$KEY_DIR/id_ed25519.pub" ] || fail "符号链接被拒绝后修改了 key 文件"

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
find "$BACKUP_DIR" -type f -name 'id_ed25519.pub' | grep -q . || fail "server key 未生成备份"
pass "RustDesk server key 强制轮换保护"

# 只加载配置更新函数，避免启动进程；覆盖后台保存后的四空格缩进。
(
    eval "$(sed -n '/^write_or_replace_yaml_value() {$/,/^}$/p' "$ROOT_DIR/docker/controlled-entrypoint.sh")"
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
)
pass "配置更新、缺失字段及空配置段缩进回归"

FAKE_BIN="$WORK_DIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/curl" <<'EOF'
#!/bin/sh
secret=""
url=""
noproxy=0
[ "$1" = "-q" ] || exit 1
while [ "$#" -gt 0 ]; do
    case "$1" in
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
        http://*|https://*) url="$1" ;;
    esac
    shift
done
[ "$noproxy" -eq 1 ] || exit 1
printf '%s\n' "$url" >> "$MOCK_CURL_LOG"
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
    OLD_RUSTDESK_HOST="unresolvable.invalid" OLD_RUSTDESK_HBBS_UDP_21116=32116 PORT_TIMEOUT_SECONDS=1 \
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
