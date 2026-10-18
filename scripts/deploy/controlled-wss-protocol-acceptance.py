#!/usr/bin/env python3
"""验证隔离 WSS 准入，或只读检查指定公网 WSS 传输入口。"""

import base64
from contextlib import contextmanager
import hashlib
from importlib import import_module
import json
from pathlib import Path
import re
import secrets
import socket
import ssl
import sys
import time
from urllib.parse import urlsplit
import uuid

sys.dont_write_bytecode = True
protocol = import_module("controlled-hbbs-protocol-acceptance")
require, command, field = protocol.require, protocol.command, protocol.field


@contextmanager
def websocket(address, port, certificate, headers=b"", hostname="localhost"):
    """只在证书与主机名校验成功后发送 WebSocket 握手和业务数据。"""
    context = ssl.create_default_context(cafile=certificate)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    with socket.create_connection((address, port), timeout=7) as raw:
        with context.wrap_socket(raw, server_hostname=hostname) as stream:
            key = base64.b64encode(secrets.token_bytes(16))
            stream.sendall(b"GET / HTTP/1.1\r\nHost: " + f"{hostname}:{port}".encode("ascii")
                           + b"\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + key + b"\r\n" + headers + b"\r\n")
            response = bytearray()
            deadline = time.monotonic() + 7
            while not response.endswith(b"\r\n\r\n"):
                require(len(response) < 4096, "WSS 响应头过大")
                remaining = deadline - time.monotonic()
                require(remaining > 0, "WSS 升级响应超时")
                stream.settimeout(remaining)
                response.extend(protocol.receive(stream, 1))
            validate_upgrade(bytes(response), key)
            stream.settimeout(7)
            yield stream


def validate_upgrade(response, key):
    """严格校验升级字段，不把正文、重复头或摘要大小写变化当作成功。"""
    lines = response.split(b"\r\n")
    require(re.fullmatch(rb"HTTP/1\.1 101 [\t\x20-\x7e\x80-\xff]*", lines[0])
            and lines[-2:] == [b"", b""], "WSS 升级状态无效")
    headers = {}
    for line in lines[1:-2]:
        name, separator, value = line.partition(b":")
        require(separator and re.fullmatch(rb"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name), "WSS 响应头无效")
        name = name.lower()
        require(name not in headers and not re.search(rb"[\x00-\x08\x0a-\x1f\x7f]", value), "WSS 响应头重复或含控制字符")
        headers[name] = value.strip(b" \t")
    expected = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
    require(headers.get(b"sec-websocket-accept") == expected
            and headers.get(b"upgrade", b"").lower() == b"websocket"
            and b"upgrade" in [token.strip().lower() for token in headers.get(b"connection", b"").split(b",")]
            and b"sec-websocket-extensions" not in headers
            and b"sec-websocket-protocol" not in headers, "受信任 WSS 升级失败")


def public_acceptance(host, hbbs_port, hbbr_port, certificate, hbbs_url, hbbr_url):
    """绑定待验公网主机及两端端口，只握手，不发送账号或业务令牌。"""
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", host) is not None, "公网 WSS 主机必须是域名或 IPv4")
    ca = Path(certificate)
    require(ca.is_file() and not ca.is_symlink(), "公网 WSS CA 必须是普通非链接文件")
    endpoints = []
    for url, expected_port in ((hbbs_url, hbbs_port), (hbbr_url, hbbr_port)):
        parsed = urlsplit(url)
        require(not re.search(r"[\x00-\x20\x7f]", url)
                and parsed.scheme == "wss" and parsed.netloc.lower() == f"{host}:{expected_port}".lower()
                and parsed.path in ("", "/") and not parsed.query and not parsed.fragment
                and "?" not in url and "#" not in url and 0 < int(expected_port) <= 65535,
                "公网 WSS URL 必须匹配 PUBLIC_HOST、显式 Web 端口和根路径")
        endpoints.append(int(expected_port))
    require(len(set(endpoints)) == 2, "公网 WSS 两个角色必须使用不同端口")
    # 先验证全部参数，避免配置缺项时探测任意或无关端点。
    for port in endpoints:
        with websocket(host, port, certificate, hostname=host) as stream:
            stream.sendall(b"\x88\x80" + secrets.token_bytes(4))
    print("PASS: 公网 hbbs/hbbr WSS 证书、主机名及严格升级通过；未验证业务准入、明文拒绝或浏览器远控")


def send_binary(stream, payload):
    """发送有界且带随机掩码的完整二进制消息。"""
    require(0 < len(payload) <= 4096, "WSS 探针帧长度无效")
    mask = secrets.token_bytes(4)
    length = bytes([len(payload)]) if len(payload) < 126 else b"\x7e" + len(payload).to_bytes(2, "big")
    stream.sendall(b"\x82" + bytes([length[0] | 0x80]) + length[1:] + mask
                   + bytes(value ^ mask[index % 4] for index, value in enumerate(payload)))


def read_binary(stream):
    """读取未协商扩展的完整服务端消息，首字节 EOF 或完整关闭帧返回空值。"""
    first = stream.recv(1)
    if not first:
        return None
    flags = protocol.receive(stream, 1)[0]
    require(first[0] in (0x82, 0x88) and flags & 0x80 == 0, "WSS 响应不是完整无掩码二进制或关闭消息")
    size = flags & 0x7f
    require(size != 127 and (first[0] != 0x88 or size < 126), "WSS 响应长度编码无效")
    if size == 126:
        size = int.from_bytes(protocol.receive(stream, 2), "big")
        require(size >= 126, "WSS 响应长度编码非规范")
    require(size <= 4096 and (first[0] != 0x88 or size != 1), "WSS 响应帧长度无效")
    payload = protocol.receive(stream, size)
    return None if first[0] == 0x88 else payload


def acceptance(hbbs, hbbr, certificate, unavailable):
    """拒绝非隔离容器，并关联每次 TLS 请求与新增准入审计。"""
    info = json.loads(command("docker", "inspect", hbbs))[0]
    project, address = protocol.target(info)
    network = json.loads(command("docker", "network", "inspect", project + "_rustdesk-control"))[0]
    require(network.get("Internal") is True, "WSS 测试网络不是内部网络")
    relay = json.loads(command("docker", "inspect", hbbr))[0]
    labels = relay["Config"].get("Labels") or {}
    require(labels.get("com.docker.compose.project") == project
            and labels.get("com.docker.compose.service") == "rustdesk-hbbr"
            and relay["State"].get("Running") and not relay["HostConfig"].get("PortBindings")
            and relay["HostConfig"].get("NetworkMode") != "host"
            and set(relay["NetworkSettings"]["Networks"]) == {project + "_rustdesk-control"},
            "拒绝非同项目无端口隔离 hbbr")
    relay_address = relay["NetworkSettings"]["Networks"][project + "_rustdesk-control"]["IPAddress"]
    marker = secrets.token_hex(16).encode()

    def count(container, text):
        """仅输出断言，不回显令牌或原始服务日志。"""
        logs = command("docker", "logs", container).decode(errors="replace")
        require(marker.decode() not in logs, "WSS 测试令牌出现在日志中")
        return logs.count(text)

    for container, ip, port, payload, expected in (
        (hbbs, address, 21118, field(8, field(1, b"987654321") + field(5, marker)),
         "连接被拒绝：" + ("ERR-239B" if unavailable else "ERR-2303")),
        (hbbr, relay_address, 21119, field(18, field(2, str(uuid.uuid4()).encode())),
         "中继会话被拒绝：" + ("ERR-239B" if unavailable else "ERR-2315")),
    ):
        for trusted, hostname in ((False, "localhost"), (True, "wrong.invalid")):
            context = ssl.create_default_context(cafile=certificate if trusted else None)
            with socket.create_connection((ip, port), timeout=7) as raw:
                try:
                    with context.wrap_socket(raw, server_hostname=hostname):
                        require(False, "错误 WSS 服务端身份未被拒绝")
                except ssl.SSLCertVerificationError:
                    pass
        for headers in (b"", b"X-Real-IP: 192.0.2.10\r\n", b"X-Forwarded-For: 192.0.2.10\r\n"):
            before = count(container, expected)
            with websocket(ip, port, certificate, headers) as stream:
                send_binary(stream, payload)
                for _ in range(70):
                    if count(container, expected) > before:
                        break
                    time.sleep(0.1)
                else:
                    require(False, "WSS 未经过在线准入或缺少本次拒绝审计")
        before = count(container, "ERR-239F WSS TLS 握手失败")
        with socket.create_connection((ip, port), timeout=7) as stream:
            try:
                stream.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
                reply = stream.recv(32)
                require(not reply or reply[0] == 21, "WSS 端口返回明文应用响应")
            except ConnectionError:
                pass
        for _ in range(50):
            if count(container, "ERR-239F WSS TLS 握手失败") > before:
                break
            time.sleep(0.1)
        else:
            require(False, "缺少 WSS 明文握手拒绝审计")
    if not unavailable:
        public_key = base64.b64decode(command("docker", "exec", hbbs, "cat", "/data/id_ed25519.pub").strip(), validate=True)

        def exchange(message, response=False):
            """WSS 已完成服务端身份验证，不再走 TCP 专用的额外密钥交换。"""
            with websocket(address, 21118, certificate) as stream:
                send_binary(stream, message)
                if response:
                    reply = read_binary(stream)
                    require(reply is not None, "WSS 正向准入响应提前关闭")
                    return protocol.fields(reply)
                time.sleep(0.3)

        def observed(action, expected):
            """要求 WSS 本次请求新增拒绝审计，旧日志不算通过。"""
            before = count(hbbs, expected)
            action()
            for _ in range(70):
                if count(hbbs, expected) > before:
                    return
                time.sleep(0.1)
            require(False, "WSS 缺少本次策略拒绝日志")

        protocol.fixture_cases(project, address, hbbs, public_key, exchange, observed,
                               relay_certificate=certificate)
    print("PASS: 原生 hbbs/hbbr WSS 受信任升级、错误身份拒绝、明文拒绝及在线准入"
          + ("故障拒绝" if unavailable else "策略拒绝") + "，不代表浏览器完整远控通过")


if __name__ == "__main__":
    try:
        if len(sys.argv) == 8 and sys.argv[1] == "--public":
            public_acceptance(*sys.argv[2:])
        else:
            require(len(sys.argv) in (4, 5) and (len(sys.argv) == 4 or sys.argv[4] == "--api-unavailable"),
                    "用法：controlled-wss-protocol-acceptance.py HBBS HBBR CA_PEM [--api-unavailable] 或 --public HOST HBBS_PORT HBBR_PORT CA_PEM HBBS_URL HBBR_URL")
            acceptance(*sys.argv[1:4], len(sys.argv) == 5)
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError) else "ERR-239D WSS 协议验收异常：" + type(error).__name__, file=sys.stderr)
        sys.exit(1)
