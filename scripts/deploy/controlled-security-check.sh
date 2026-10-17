#!/bin/sh

set -eu

failures=0
warnings=0

fail() {
    failures=$((failures + 1))
    printf 'FAIL: ERR-2394 %s\n' "$1" >&2
}

warn() {
    warnings=$((warnings + 1))
    printf 'WARN: %s\n' "$1" >&2
}

pass() {
    printf 'PASS: %s\n' "$1"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

http_post() {
    url="$1"
    secret="$2"
    body='{}'
    if [ -n "$secret" ]; then
        printf 'X-Internal-Secret: %s\n' "$secret" | curl -q --noproxy '*' -sS -m "${HTTP_TIMEOUT_SECONDS:-5}" -w '\n%{http_code}' \
            -H "Content-Type: application/json" \
            -H @- \
            -d "$body" \
            -- "$url"
    else
        curl -q --noproxy '*' -sS -m "${HTTP_TIMEOUT_SECONDS:-5}" -w '\n%{http_code}' \
            -H "Content-Type: application/json" \
            -d "$body" \
            -- "$url"
    fi
}

check_internal_response() {
    url="$1"
    secret="$2"
    expected_status="$3"
    expected_code="$4"
    label="$5"

    if ! result="$(http_post "$url" "$secret" 2>/dev/null)"; then
        fail "$label 请求失败，请确认 API 是否运行：$url"
        return
    fi
    status="$(printf '%s\n' "$result" | tail -n 1)"
    response="$(printf '%s\n' "$result" | sed '$d')"
    if [ "$status" != "$expected_status" ]; then
        fail "$label 返回 HTTP $status，预期 $expected_status"
        return
    fi
    if ! printf '%s' "$response" | "$json_parser" -c \
        'import json,sys; data=json.load(sys.stdin); raise SystemExit(0 if data.get("allow") is False and data.get("code") == sys.argv[1] else 1)' \
        "$expected_code" >/dev/null 2>&1; then
        fail "$label 未返回 allow=false 和 $expected_code"
        return
    fi
    pass "$label"
}

check_internal_api_auth() {
    api_base="${API_BASE_URL:-http://127.0.0.1:12345}"
    url="$api_base/internal/rustdesk/auth"

    if ! have_cmd curl; then
        fail "未找到 curl，无法检查内部准入接口鉴权"
        return
    fi
    if ! select_python; then
        fail "未找到可执行的 python3/python，无法严格解析内部接口响应"
        return
    fi

    check_internal_response "$url" "" 401 "ERR-2301" "内部接口未携带密钥时拒绝访问"
    check_internal_response "$url" "wrong-internal-secret-for-security-check" 401 "ERR-2301" "内部接口错误密钥时拒绝访问"

    if [ -n "${RUSTDESK_API_INTERNAL_SECRET:-}" ]; then
        check_internal_response "$url" "$RUSTDESK_API_INTERNAL_SECRET" 200 "ERR-2302" "内部接口正确密钥进入准入逻辑"
    else
        fail "未设置 RUSTDESK_API_INTERNAL_SECRET，无法检查正确密钥路径"
    fi
}

check_management_https() {
    https_url="${ADMIN_HTTPS_URL:-}"
    ca_file="${ADMIN_TLS_CA_FILE:-}"
    if [ -z "$https_url" ] && [ -z "$ca_file" ]; then
        warn "未设置 ADMIN_HTTPS_URL 和 ADMIN_TLS_CA_FILE，跳过管理页 HTTPS 实测"
        return
    fi
    if [ -z "$https_url" ] || [ -z "$ca_file" ]; then
        fail "ADMIN_HTTPS_URL 和 ADMIN_TLS_CA_FILE 必须同时设置"
        return
    fi
    if [ -L "$ca_file" ] || [ ! -f "$ca_file" ] || [ ! -r "$ca_file" ]; then
        fail "管理页 HTTPS CA 文件不存在、不可读或为符号链接"
        return
    fi

    case "$https_url" in
        https://*/|https://*) ;;
        *) fail "ADMIN_HTTPS_URL 必须使用 https://"; return ;;
    esac
    authority="${https_url#https://}"
    authority="${authority%/}"
    case "$authority" in
        ""|*/*|*@*|*\?*|*\#*) fail "ADMIN_HTTPS_URL 只允许域名或 IPv4、显式端口和根路径"; return ;;
    esac
    host="${authority%:*}"
    port="${authority##*:}"
    if [ "$host" = "$authority" ]; then
        fail "ADMIN_HTTPS_URL 必须包含有效的显式端口"
        return
    fi
    if ! validate_endpoint "$host" "$port" "管理页 HTTPS"; then
        return
    fi
    https_url="https://${authority}/"
    http_url="http://${authority}/"

    if ! https_status="$(curl -q --noproxy '*' --proto '=https' --tlsv1.2 --cacert "$ca_file" \
        -sS -m "${HTTP_TIMEOUT_SECONDS:-5}" -o /dev/null -w '%{http_code}' -- "$https_url" 2>/dev/null)"; then
        fail "管理页 HTTPS 证书或连接验证失败：$https_url"
        return
    fi
    if [ "$https_status" != "200" ]; then
        fail "管理页 HTTPS 返回 HTTP $https_status，预期 200"
        return
    fi
    pass "管理页 HTTPS 证书和首页访问通过：$https_url"

    check_https_download "$https_url" "downloads/rustdesk.jtzxsoft.com.cert.cer" \
        "${ADMIN_CERT_SHA256:-f56a892ab90b0e85687403979d5f9901084b6e2657c74eff6dc9e93aede0d96d}" \
        "管理页公开证书" "$ca_file"
    check_https_download "$https_url" "downloads/rustdesk-1.4.9-x86_64.exe" \
        "${ADMIN_INSTALLER_SHA256:-eaedeb0088e687bf46f7c46a9c6ea5493ce51f3134dfd6acbedb47b5b9136274}" \
        "RustDesk 1.4.9 安装包" "$ca_file"

    http_status="000"
    if http_result="$(curl -q --noproxy '*' --proto '=http' -sS -m "${HTTP_TIMEOUT_SECONDS:-5}" \
        -o /dev/null -w '%{http_code}' -- "$http_url" 2>/dev/null)"; then
        http_status="$http_result"
    fi
    case "$http_status" in
        2??|3??) fail "管理页 TLS 端口仍接受明文 HTTP：$http_url（HTTP $http_status）" ;;
        *) pass "管理页 TLS 端口拒绝明文 HTTP：$http_url" ;;
    esac
}

check_https_download() {
    base_url="$1"
    relative_path="$2"
    expected_sha256="$3"
    label="$4"
    download_ca_file="$5"

    if [ "${#expected_sha256}" -ne 64 ]; then
        fail "$label 的预期 SHA-256 长度无效"
        return
    fi
    case "$expected_sha256" in
        *[!0-9A-Fa-f]*) fail "$label 的预期 SHA-256 格式无效"; return ;;
    esac
    if ! select_python; then
        fail "未找到可执行的 python3/python，无法校验 $label 摘要"
        return
    fi
    temp_file="$(mktemp)" || {
        fail "无法创建 $label 临时文件"
        return
    }
    download_url="${base_url}${relative_path}"
    status="000"
    if result="$(curl -q --noproxy '*' --proto '=https' --tlsv1.2 --cacert "$download_ca_file" \
        -sS -m "${DOWNLOAD_TIMEOUT_SECONDS:-60}" -o "$temp_file" -w '%{http_code}' -- "$download_url" 2>/dev/null)"; then
        status="$result"
    fi
    if [ "$status" != "200" ]; then
        rm -f "$temp_file"
        fail "$label 下载失败：$download_url（HTTP $status）"
        return
    fi
    actual_sha256="$("$json_parser" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$temp_file")" || {
        rm -f "$temp_file"
        fail "$label 摘要计算失败"
        return
    }
    rm -f "$temp_file"
    if [ "$(printf '%s' "$actual_sha256" | tr 'A-F' 'a-f')" != "$(printf '%s' "$expected_sha256" | tr 'A-F' 'a-f')" ]; then
        fail "$label SHA-256 不匹配"
        return
    fi
    pass "$label HTTPS 下载和 SHA-256 校验通过"
}

select_python() {
    if have_cmd python3 && python3 --version >/dev/null 2>&1; then
        json_parser="python3"
    elif have_cmd python && python -c 'import sys; sys.exit(sys.version_info[0] < 3)' >/dev/null 2>&1; then
        json_parser="python"
    else
        return 1
    fi
}

validate_endpoint() {
    host="$1"
    port="$2"
    label="$3"
    case "$host" in
        ""|*[!A-Za-z0-9._:%-]*)
            fail "$label 的主机名包含非法字符"
            return 1
            ;;
    esac
    case "$port" in
        ""|*[!0-9]*)
            fail "$label 的端口不是有效数字：$port"
            return 1
            ;;
        ??????*)
            fail "$label 的端口超出有效范围：$port"
            return 1
            ;;
    esac
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        fail "$label 的端口超出有效范围：$port"
        return 1
    fi
}

probe_tcp() {
    if ! select_python; then
        return 2
    fi
    "$json_parser" -c '
import errno, socket, sys
try:
    timeout = float(sys.argv[3])
    if not 0 < timeout <= 30:
        sys.exit(2)
    addresses = socket.getaddrinfo(sys.argv[1], int(sys.argv[2]), type=socket.SOCK_STREAM)
    if not addresses:
        sys.exit(2)
    results = []
    for family, kind, proto, _, address in addresses:
        try:
            with socket.socket(family, kind, proto) as connection:
                connection.settimeout(timeout)
                result = connection.connect_ex(address)
        except OSError:
            results.append(None)
            continue
        if result == 0:
            sys.exit(0)
        results.append(result)
    sys.exit(1 if all(result == errno.ECONNREFUSED for result in results) else 2)
except (OSError, ValueError, OverflowError):
    sys.exit(2)
' "$1" "$2" "${PORT_TIMEOUT_SECONDS:-2}" >/dev/null 2>&1
}

check_port_closed() {
    host="$1"
    port="$2"
    label="$3"
    if ! validate_endpoint "$host" "$port" "$label"; then
        return 0
    fi
    status=0
    probe_tcp "$host" "$port" || status=$?
    case "$status" in
        0) fail "$label 仍可连接：$host:$port" ;;
        1) pass "$label 明确拒绝连接：$host:$port" ;;
        *) fail "$label 无法确认已关闭（解析失败、超时或网络不可达）：$host:$port" ;;
    esac
}

check_port_open() {
    host="$1"
    port="$2"
    label="$3"
    if ! validate_endpoint "$host" "$port" "$label"; then
        return 0
    fi
    if probe_tcp "$host" "$port"; then
        pass "$label 可连接：$host:$port"
    else
        fail "$label 不可连接或无法确认：$host:$port"
    fi
}

check_public_exposure() {
    public_host="${PUBLIC_HOST:-}"
    if [ -z "$public_host" ]; then
        warn "未设置 PUBLIC_HOST，跳过公网暴露实测"
        return
    fi

    check_port_open "$public_host" "${RUSTDESK_HBBS_TCP_21115:-21115}" "受控 hbbs 21115"
    check_port_open "$public_host" "${RUSTDESK_HBBS_TCP_21116:-21116}" "受控 hbbs 21116"
    check_port_open "$public_host" "${RUSTDESK_HBBR_TCP_21117:-21117}" "受控 hbbr 21117"

    check_port_closed "$public_host" "${FNOS_ADMIN_HTTP_PORT:-12346}" "管理后台公网端口"
    check_port_closed "$public_host" "${RUSTDESK_HBBS_WEB_PORT:-21118}" "hbbs Web 公网端口"
    check_port_closed "$public_host" "${RUSTDESK_HBBR_WEB_PORT:-21119}" "hbbr Web 公网端口"
    public_udp_port="${RUSTDESK_HBBS_UDP_21116:-${RUSTDESK_HBBS_TCP_21116:-21116}}"
    warn "公网 hbbs ${public_udp_port}/UDP 未经 TCP 探针验证，需从独立网络做协议级检查"
}

check_old_service_shutdown() {
    old_host="${OLD_RUSTDESK_HOST:-}"
    if [ -z "$old_host" ]; then
        warn "未设置 OLD_RUSTDESK_HOST，跳过旧裸服务下线实测"
        return
    fi

    check_port_closed "$old_host" "${OLD_RUSTDESK_HBBS_21115:-21115}" "旧裸 hbbs 21115"
    check_port_closed "$old_host" "${OLD_RUSTDESK_HBBS_21116:-21116}" "旧裸 hbbs 21116"
    check_port_closed "$old_host" "${OLD_RUSTDESK_HBBR_21117:-21117}" "旧裸 hbbr 21117"
    old_udp_port="${OLD_RUSTDESK_HBBS_UDP_21116:-${OLD_RUSTDESK_HBBS_21116:-21116}}"
    warn "旧裸 hbbs ${old_udp_port}/UDP 未经 TCP 探针验证，需从独立网络做协议级检查"
}

check_internal_api_auth
check_management_https
check_public_exposure
check_old_service_shutdown

if [ "$failures" -gt 0 ]; then
    printf '\n受控部署安全检查未通过：%s 项失败，%s 项警告。\n' "$failures" "$warnings" >&2
    exit 1
fi

if [ "$warnings" -gt 0 ]; then
    printf '\n受控部署安全检查部分完成：%s 项未验证警告。\n' "$warnings"
else
    printf '\n受控部署安全检查通过。\n'
fi
