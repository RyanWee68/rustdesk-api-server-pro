#!/usr/bin/env python3
"""仅在专属三容器项目中验证原生 WSS 身份校验与在线准入拒绝。"""

import base64
from contextlib import contextmanager
import hashlib
from importlib import import_module
import json
import secrets
import socket
import ssl
import sys
import time
import uuid

sys.dont_write_bytecode = True
protocol = import_module("controlled-hbbs-protocol-acceptance")
require, command, field = protocol.require, protocol.command, protocol.field


@contextmanager
def websocket(address, port, certificate, headers=b""):
    """只在证书与主机名校验成功后发送 WebSocket 握手和业务数据。"""
    context = ssl.create_default_context(cafile=certificate)
    with socket.create_connection((address, port), timeout=7) as raw:
        with context.wrap_socket(raw, server_hostname="localhost") as stream:
            key = base64.b64encode(secrets.token_bytes(16))
            stream.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + key + b"\r\n" + headers + b"\r\n")
            response = bytearray()
            while not response.endswith(b"\r\n\r\n"):
                require(len(response) < 4096, "WSS 响应头过大")
                response.extend(protocol.receive(stream, 1))
            expected = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
            require(response.startswith(b"HTTP/1.1 101 ") and expected.lower() in response.lower(), "受信任 WSS 升级失败")
            yield stream


def send_binary(stream, payload):
    """沿用既有协议探针的短掩码二进制帧格式。"""
    require(len(payload) < 126, "WSS 探针帧过大")
    mask = secrets.token_bytes(4)
    stream.sendall(bytes([0x82, 0x80 | len(payload)]) + mask
                   + bytes(value ^ mask[index % 4] for index, value in enumerate(payload)))


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
            except ConnectionResetError:
                pass
        for _ in range(50):
            if count(container, "ERR-239F WSS TLS 握手失败") > before:
                break
            time.sleep(0.1)
        else:
            require(False, "缺少 WSS 明文握手拒绝审计")
    print("PASS: 原生 hbbs/hbbr WSS 受信任升级、错误身份拒绝、明文拒绝及在线准入"
          + ("故障拒绝" if unavailable else "策略拒绝") + "，不代表浏览器完整远控通过")


if __name__ == "__main__":
    try:
        require(len(sys.argv) in (4, 5) and (len(sys.argv) == 4 or sys.argv[4] == "--api-unavailable"),
                "用法：controlled-wss-protocol-acceptance.py HBBS HBBR CA_PEM [--api-unavailable]")
        acceptance(*sys.argv[1:4], len(sys.argv) == 5)
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError) else "ERR-239D WSS 协议验收异常：" + type(error).__name__, file=sys.stderr)
        sys.exit(1)
