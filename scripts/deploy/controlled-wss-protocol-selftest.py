#!/usr/bin/env python3
"""仅用回环一次性证书和内存响应回归公网 WSS 门禁，不访问部署主机。"""

import base64
from contextlib import contextmanager
import hashlib
from importlib import import_module
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
wss = import_module("controlled-wss-protocol-acceptance")


def upgrade(key):
    """生成与请求随机值绑定的标准升级响应。"""
    digest = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
    return (b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
            b"Connection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: " + digest + b"\r\n\r\n")


class UpgradeTests(unittest.TestCase):
    """覆盖无法靠 TCP 成功判断的握手及参数边界。"""

    def test_upgrade(self):
        """正确响应通过，伪造摘要、正文及重复头均拒绝。"""
        key = base64.b64encode(b"0123456789abcdef")
        response = upgrade(key)
        wss.validate_upgrade(response, key)
        for invalid in (
            response.replace(b"101 Switching", b"200 Switching"),
            response.replace(b"101 Switching", b"101 \nSwitching"),
            response.replace(b"websocket", b"not-websocket"),
            response.replace(b"keep-alive, Upgrade", b"not-Upgrade"),
            response.replace(b"Sec-WebSocket-Accept:", b"X-Body:"),
            response.replace(b"Sec-WebSocket-Accept:", b" Sec-WebSocket-Accept:"),
            response.replace(b"Sec-WebSocket-Accept:", b"Sec-WebSocket-Accept:\x00"),
            response.replace(b"\r\n\r\n", b"\r\nUpgrade: websocket\r\n\r\n"),
            response.replace(b"\r\n\r\n", b"\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n"),
            response.replace(b"\r\n\r\n", b"\r\nSec-WebSocket-Protocol: other\r\n\r\n"),
            response.lower(), response + b"body", response[:-1],
        ):
            with self.subTest(response=invalid), self.assertRaisesRegex(RuntimeError, "ERR-239D"):
                wss.validate_upgrade(invalid, key)

    def test_public_parameters(self):
        """先校验两端配置，拒绝无关主机、路径、端口与链接 CA。"""
        with tempfile.TemporaryDirectory(prefix="rustdesk-controlled-wss-") as directory:
            ca = Path(directory) / "ca.pem"
            ca.touch()
            args = ["localhost", "22118", "22119", str(ca),
                    "wss://localhost:22118/", "wss://localhost:22119/"]
            for index, value in (
                (0, "localhost;cmd"), (1, "70000"), (2, "22118"), (3, directory), (3, str(ca) + ".missing"),
                (4, "ws://localhost:22118/"), (4, "wss://other:22118/"),
                (4, "wss://localhost/"), (4, "wss://user@localhost:22118/"),
                (4, "wss://localhost:22118/path"), (4, "wss://localhost:22118/?token=secret"),
                (4, "wss://localhost:22118/#"), (4, "wss://localhost:22118/?"),
                (4, "wss://localhost:\t22118/"),
                (5, "wss://localhost:22118/"),
            ):
                invalid = args.copy()
                invalid[index] = value
                with self.subTest(index=index, value=value), patch.object(wss, "websocket") as connect:
                    with self.assertRaises((RuntimeError, ValueError)):
                        wss.public_acceptance(*invalid)
                    connect.assert_not_called()
            with patch.object(wss, "websocket", side_effect=TimeoutError):
                with self.assertRaises(TimeoutError):
                    wss.public_acceptance(*args)
            with patch.object(Path, "is_symlink", return_value=True), patch.object(wss, "websocket") as connect:
                with self.assertRaisesRegex(RuntimeError, "ERR-239D.*CA"):
                    wss.public_acceptance(*args)
                connect.assert_not_called()
            with patch.object(wss, "websocket") as connect:
                with self.assertRaisesRegex(RuntimeError, "ERR-239D.*不同端口"):
                    wss.public_acceptance("localhost", "22118", "022118", str(ca),
                                          "wss://localhost:22118/", "wss://localhost:022118/")
                connect.assert_not_called()

    def test_response_limits(self):
        """响应过大和慢速升级不能无限占用探针或返回成功。"""
        for reply, times in ((b"x", [0, 0] * 5000), (b"x", [0, 8])):
            with self.subTest(times=times[:2]), patch.object(wss.ssl, "create_default_context") as tls:
                stream = tls.return_value.wrap_socket.return_value.__enter__.return_value
                stream.recv.return_value = reply
                with patch.object(wss.socket, "create_connection"), patch.object(wss.time, "monotonic", side_effect=times):
                    with self.assertRaisesRegex(RuntimeError, "ERR-239D.*(过大|超时)"):
                        with wss.websocket("localhost", 22118, "fixture.pem"):
                            self.fail("ERR-239D 无效响应不应升级成功")


class TransportTests(unittest.TestCase):
    """使用真实 TLS 握手验证信任链、域名与公网双端入口。"""

    @classmethod
    def setUpClass(cls):
        """在系统临时目录生成一次性证书，不复用任何部署凭据。"""
        openssl = shutil.which("openssl")
        if not openssl:
            raise RuntimeError("ERR-239D WSS 传输自测需要 openssl")
        cls.directory = tempfile.TemporaryDirectory(prefix="rustdesk-controlled-wss-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.cert = str(Path(cls.directory.name) / "cert.pem")
        cls.key = str(Path(cls.directory.name) / "key.pem")
        subprocess.run([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost",
                        "-keyout", cls.key, "-out", cls.cert], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        cls.context.load_cert_chain(cls.cert, cls.key)

    @contextmanager
    def server(self, malformed=False, plaintext=False):
        """只接受一次回环连接，结束时等待线程并关闭所有套接字。"""
        errors = []
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            listener.settimeout(10)

            def handle():
                """只记录意外异常，预期的 TLS 身份拒绝不算服务异常。"""
                try:
                    with listener.accept()[0] as raw:
                        raw.settimeout(7)
                        if plaintext:
                            raw.recv(4096)
                            raw.sendall(b"HTTP/1.1 200 OK\r\n\r\n")
                            return
                        with self.context.wrap_socket(raw, server_side=True) as stream:
                            request = bytearray()
                            while not request.endswith(b"\r\n\r\n"):
                                request.extend(wss.protocol.receive(stream, 1))
                            key = next(line.split(b":", 1)[1].strip() for line in request.split(b"\r\n")
                                       if line.startswith(b"Sec-WebSocket-Key:"))
                            response = upgrade(key)
                            stream.sendall(response.lower() if malformed else response)
                            stream.recv(32)
                except (ssl.SSLError, ConnectionError):
                    pass
                except Exception as error:
                    errors.append(error)

            thread = threading.Thread(target=handle, daemon=True)
            thread.start()
            try:
                yield listener.getsockname()[1]
            finally:
                thread.join(11)
                self.assertFalse(thread.is_alive(), "ERR-239D 回环测试线程未结束")
                self.assertEqual(errors, [])

    def test_public_tls_pair(self):
        """双端必须同时完成受信任升级，不发送业务消息。"""
        with self.server() as hbbs, self.server() as hbbr:
            wss.public_acceptance("localhost", str(hbbs), str(hbbr), self.cert,
                                  f"wss://localhost:{hbbs}/", f"wss://localhost:{hbbr}/")

    def test_identity_rejected(self):
        """不可信证书和错误域名必须明确拒绝。"""
        for trusted, hostname in ((False, "localhost"), (True, "wrong.invalid")):
            with self.subTest(trusted=trusted), self.server() as port:
                context = ssl.create_default_context(cafile=self.cert if trusted else None)
                with socket.create_connection(("localhost", port), timeout=7) as raw:
                    with self.assertRaises(ssl.SSLCertVerificationError):
                        context.wrap_socket(raw, server_hostname=hostname)

    def test_bad_upgrade_and_plaintext(self):
        """TLS 后伪造升级及明文假服务均不能通过入口验收。"""
        for plaintext in (False, True):
            with self.subTest(plaintext=plaintext), self.server(malformed=True, plaintext=plaintext) as port:
                with self.assertRaises((RuntimeError, ssl.SSLError)):
                    with wss.websocket("localhost", port, self.cert):
                        self.fail("ERR-239D 伪造 WSS 不应成功")


if __name__ == "__main__":
    unittest.main()
