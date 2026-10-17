#!/usr/bin/env python3
"""在无宿主端口的三容器隔离环境验收 hbbs 加密和失败拒绝。"""

import base64
from concurrent.futures import ThreadPoolExecutor
import ctypes
import ctypes.util
import hashlib
import json
from pathlib import Path
import secrets
import socket
import sqlite3
import subprocess
import sys
import time
import uuid
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo


def require(condition, message):
    """失败时只输出错误说明，不输出密钥或请求内容。"""
    if not condition:
        raise RuntimeError("ERR-239D " + message)


def command(*args):
    """读取 Docker 状态，不透传可能包含凭据的工具输出。"""
    result = subprocess.run(args, capture_output=True, timeout=15)
    require(result.returncode == 0, "Docker 状态读取失败")
    return result.stdout + result.stderr if args[:2] == ("docker", "logs") else result.stdout


def varint(value):
    """编码固定基线使用的非负 protobuf 整数。"""
    require(value >= 0, "协议整数不能为负")
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    return bytes(result + bytes([value]))


def field(number, value):
    """编码 protobuf 字节字段。"""
    return varint(number * 8 + 2) + varint(len(value)) + value


def encoded_ipv4(address, port):
    """使用固定基线 AddrMangle 的零时间戳编码构造隔离反射目标。"""
    require(0 < port <= 65535, "反射目标端口无效")
    value = (int.from_bytes(socket.inet_aton(address), "little") << 49) | port
    return value.to_bytes(16, "little").rstrip(b"\x00")


def fields(data):
    """仅解析探针需要的整数和字节字段，并限制消息长度。"""
    require(len(data) <= 4096, "协议消息过大")
    offset, result = 0, []

    def integer():
        """读取有界 varint，拒绝截断或溢出。"""
        nonlocal offset
        value = 0
        for shift in range(0, 70, 7):
            require(offset < len(data), "协议整数被截断")
            item = data[offset]
            offset += 1
            value |= (item & 127) << shift
            if not item & 128:
                return value
        raise RuntimeError("ERR-239D 协议整数溢出")

    while offset < len(data):
        tag = integer()
        require(tag >> 3 > 0, "协议字段编号无效")
        if tag & 7 == 0:
            value = integer()
        else:
            require(tag & 7 == 2, "协议字段类型不支持")
            size = integer()
            require(offset + size <= len(data), "协议字段被截断")
            value = data[offset:offset + size]
            offset += size
        result.append((tag >> 3, value))
    return result


def framed(data):
    """编码 RustDesk BytesCodec 长度头。"""
    require(len(data) <= 4096, "探针帧过大")
    size = 1 if len(data) < 64 else 2
    return ((len(data) << 2) | (size - 1)).to_bytes(size, "little") + data


def receive(stream, size):
    """完整读取指定长度，拒绝提前断开。"""
    result = bytearray()
    while len(result) < size:
        part = stream.recv(size - len(result))
        require(part, "协议连接提前断开")
        result.extend(part)
    return bytes(result)


def read_frame(stream):
    """读取有界 RustDesk 帧。"""
    first = receive(stream, 1)
    header = first + receive(stream, first[0] & 3)
    size = int.from_bytes(header, "little") >> 2
    require(0 < size <= 4096, "协议帧长度无效")
    return receive(stream, size)


class Sodium:
    """复用主机 libsodium，避免自实现加密或引入 Python 依赖。"""

    def __init__(self):
        """声明 C ABI，防止长度参数被截断。"""
        library = ctypes.util.find_library("sodium")
        require(library, "主机缺少 libsodium")
        self.lib = ctypes.CDLL(library)
        ptr, length = ctypes.c_void_p, ctypes.c_ulonglong
        for name, args in (
            ("crypto_sign_open", [ptr, ptr, ptr, length, ptr]),
            ("crypto_box_keypair", [ptr, ptr]),
            ("crypto_box_easy", [ptr, ptr, length, ptr, ptr, ptr]),
            ("crypto_secretbox_easy", [ptr, ptr, length, ptr, ptr]),
            ("crypto_secretbox_open_easy", [ptr, ptr, length, ptr, ptr]),
        ):
            function = getattr(self.lib, name)
            function.argtypes, function.restype = args, ctypes.c_int
        require(self.lib.sodium_init() >= 0, "libsodium 初始化失败")

    def secure(self, stream, public_key):
        """校验配置公钥签名后完成官方基线密钥交换。"""
        message = fields(read_frame(stream))
        require(len(message) == 1 and message[0][0] == 25, "首包不是密钥交换")
        keys = fields(message[0][1])
        require(len(keys) == 1 and keys[0][0] == 1 and len(keys[0][1]) == 96, "服务端密钥格式无效")
        verified, size = ctypes.create_string_buffer(96), ctypes.c_ulonglong()
        require(len(public_key) == 32, "签名公钥长度无效")
        require(self.lib.crypto_sign_open(verified, ctypes.byref(size), keys[0][1], 96, public_key) == 0
                and size.value == 32, "服务端签名不匹配")
        public, private = ctypes.create_string_buffer(32), ctypes.create_string_buffer(32)
        require(self.lib.crypto_box_keypair(public, private) == 0, "客户端密钥生成失败")
        session = secrets.token_bytes(32)
        encrypted = ctypes.create_string_buffer(48)
        require(self.lib.crypto_box_easy(encrypted, session, 32, bytes(24), verified.raw[:32], private) == 0,
                "会话密钥封装失败")
        stream.sendall(framed(field(25, field(1, public.raw) + field(1, encrypted.raw))))
        return session

    def encrypt(self, data, key):
        """编码首个加密请求，计数器与官方客户端一致。"""
        output = ctypes.create_string_buffer(len(data) + 16)
        require(self.lib.crypto_secretbox_easy(output, data, len(data), b"\x01" + bytes(23), key) == 0,
                "请求加密失败")
        return output.raw

    def decrypt(self, data, key):
        """校验首个服务端加密响应，证明双向加密而非只验证首包。"""
        require(len(data) > 16, "加密响应过短")
        output = ctypes.create_string_buffer(len(data) - 16)
        require(self.lib.crypto_secretbox_open_easy(output, data, len(data), b"\x01" + bytes(23), key) == 0,
                "服务端响应认证失败")
        return output.raw


def target(info):
    """拒绝生产服务、端口发布和非专属网络。"""
    labels = info["Config"].get("Labels") or {}
    project = labels.get("com.docker.compose.project", "")
    require(project.startswith("rustdesk-controlled-three-"), "拒绝操作非三容器隔离项目")
    require(labels.get("com.docker.compose.service") == "rustdesk-hbbs", "服务不是隔离 hbbs")
    require(info["State"].get("Running"), "隔离 hbbs 未运行")
    require(not info["HostConfig"].get("PortBindings"), "隔离服务存在宿主端口发布")
    networks = info["NetworkSettings"]["Networks"]
    require(set(networks) == {project + "_rustdesk-control"}, "隔离网络不匹配")
    require(info["HostConfig"].get("NetworkMode") != "host", "禁止 host 网络")
    return project, networks[project + "_rustdesk-control"]["IPAddress"]


def acceptance(container, unavailable):
    """联查加密请求、明文拒绝、UDP 注册响应及对应服务日志。"""
    info = json.loads(command("docker", "inspect", container))[0]
    project, address = target(info)
    network = json.loads(command("docker", "network", "inspect", project + "_rustdesk-control"))[0]
    require(network.get("Internal") is True, "隔离网络不是内部网络")
    public_key = base64.b64decode(command("docker", "exec", container, "cat", "/data/id_ed25519.pub").strip(), validate=True)
    sodium = Sodium()
    marker = secrets.token_hex(16).encode()
    request = field(8, field(1, b"987654321") + field(5, marker))

    def log_count(text):
        """只检查错误码和测试令牌是否泄漏，不输出原始日志。"""
        logs = command("docker", "logs", container).decode(errors="replace")
        require(marker.decode() not in logs, "测试令牌出现在服务日志中")
        return logs.count(text)

    def observed(action, text):
        """要求本次请求后新增指定拒绝日志。"""
        before = log_count(text)
        action()
        for _ in range(60):
            if log_count(text) > before:
                return
            time.sleep(0.1)
        raise RuntimeError("ERR-239D 缺少预期拒绝日志：" + text)

    def encrypted(message, corrupt=False, response=False):
        """通过已验证签名的加密连接发送请求。"""
        with socket.create_connection((address, 21116), timeout=7) as stream:
            key = sodium.secure(stream, public_key)
            payload = sodium.encrypt(message, key)
            if corrupt:
                payload = bytes([payload[0] ^ 1]) + payload[1:]
            stream.sendall(framed(payload))
            if response:
                return fields(sodium.decrypt(read_frame(stream), key))
            if corrupt:
                require(stream.recv(1) == b"", "篡改密文后连接未关闭")
            else:
                # 拒绝分支保持连接等待后续帧，日志证明本次请求已被判定。
                time.sleep(4 if unavailable else 0.3)

    code = "ERR-239B" if unavailable else "ERR-2303"
    for label, message in (("未登录", field(8, field(1, b"987654321"))), ("无效令牌", request)):
        for _ in range(3):
            observed(lambda: encrypted(message), "连接被拒绝：" + code)
        print("PASS: hbbs 签名校验及加密" + label + "连接连续三次拒绝（" + code + "）")
    with socket.create_connection((address, 21116), timeout=7) as stream:
        wrong_key = bytes([public_key[0] ^ 1]) + public_key[1:]
        try:
            sodium.secure(stream, wrong_key)
        except RuntimeError as error:
            require(str(error) == "ERR-239D 服务端签名不匹配", "错误公钥未在签名校验阶段拒绝")
        else:
            require(False, "错误公钥仍接受服务端身份")
    print("PASS: 错误配置公钥在发送会话密钥与令牌前被拒绝")
    observed(lambda: encrypted(request, True), "ERR-239E 拒绝无效的加密 TCP 数据帧")
    print("PASS: 篡改密文被拒绝并关闭连接")

    def plaintext(message):
        """验证携带令牌的明文 TCP 帧被关闭。"""
        with socket.create_connection((address, 21116), timeout=7) as stream:
            stream.sendall(framed(message))
            require(stream.recv(1) == b"", "明文令牌连接未关闭")

    for message in (request, field(18, field(1, b"987654321") + field(8, marker)), field(26, field(1, marker))):
        observed(lambda: plaintext(message), "ERR-239E 拒绝携带令牌的明文 TCP 请求")
    print("PASS: 打洞、中继和健康检查三类明文令牌请求均拒绝且日志不泄漏令牌")

    def websocket(extra_headers=b""):
        """未配置 WSS 时，标准握手和携令牌帧必须在升级前被拒绝。"""
        with socket.create_connection((address, 21118), timeout=7) as stream:
            key = base64.b64encode(secrets.token_bytes(16))
            mask = secrets.token_bytes(4)
            require(len(request) < 126, "WebSocket 探针帧过大")
            upgrade = b"GET / HTTP/1.1\r\nHost: isolated\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + key + b"\r\n" + extra_headers + b"\r\n"
            frame = bytes([0x82, 0x80 | len(request)]) + mask + bytes(item ^ mask[i % 4] for i, item in enumerate(request))
            try:
                stream.sendall(upgrade + frame)
                require(stream.recv(2) == b"", "未启用 WSS 时仍返回 WebSocket 响应")
            except ConnectionError:
                pass

    observed(websocket, "ERR-239F WSS 未配置证书")
    for header in (b"X-Real-IP: 192.0.2.10\r\n", b"X-Forwarded-For: 192.0.2.10\r\n"):
        observed(lambda: websocket(header), "ERR-239F WSS 未配置证书")
    print("PASS: 未配置 WSS 时明文 WebSocket 与伪造来源头均在升级前拒绝")

    def registration():
        """独立随机设备注册仅写入将随隔离卷清理的待审批记录。"""
        device = str(secrets.randbelow(800000000) + 100000000).encode()
        payload = field(15, field(1, device) + field(2, secrets.token_bytes(16)) + field(3, secrets.token_bytes(32)))
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as stream:
            stream.settimeout(7)
            stream.sendto(payload, (address, 21116))
            response, _ = stream.recvfrom(4096)
        outer = fields(response)
        require(len(outer) == 1 and outer[0][0] == 16 and (1, 8) in fields(outer[0][1]), "未审批注册未返回 NOT_DEPLOYED")

    observed(registration, "设备注册被拒绝：" + ("ERR-239B" if unavailable else "ERR-2305"))
    print("PASS: UDP 新设备注册默认拒绝（" + ("ERR-239B" if unavailable else "ERR-2305") + "）")
    # 同一套已确认可达的 UDP 服务不能接受 TCP 专用打洞和中继入口。
    for number, payload in (
        (8, field(1, b"987654321") + field(5, marker)),
        (10, field(2, b"987654321")),
        (13, field(4, b"987654321")),
        (18, field(1, b"987654321") + field(2, str(uuid.uuid4()).encode()) + field(8, marker)),
    ):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as stream:
            stream.settimeout(0.5)
            stream.sendto(field(number, payload), (address, 21116))
            try:
                stream.recvfrom(4096)
            except socket.timeout:
                continue
            require(False, "UDP 专用丢弃分支返回了非预期响应")
    print("PASS: UDP 打洞请求、打洞通知、本地地址及中继请求无响应（不代替反射目标抓包）")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as victim:
        victim.connect((address, 21116))
        victim.send(field(15, field(1, b"reflection-probe") + field(2, secrets.token_bytes(16)) + field(3, secrets.token_bytes(32))))
        victim.settimeout(7)
        require(fields(victim.recv(4096))[0][0] == 16, "反射目标正向可达性检查失败")
        destination = encoded_ipv4(*victim.getsockname())
        victim.settimeout(0.5)
        for number in (10, 13):
            payload = field(1, destination) + field(2 if number == 10 else 4, b"987654321")
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as attacker:
                attacker.sendto(field(number, payload), (address, 21116))
            try:
                victim.recv(4096)
            except socket.timeout:
                continue
            require(False, "UDP 通知向指定第三方端口反射数据")
    print("PASS: UDP 通知未向可达的独立目标端口反射数据（非伪造源 IP 或全量抓包验收）")
    if not unavailable:
        fixture_cases(project, address, container, public_key, encrypted, observed)


def fixture_cases(project, address, container, public_key, encrypted, observed):
    """独立夹具覆盖真实 hbbs 签发与连接策略，绝不修改已有账号设备。"""
    api = command("docker", "ps", "-q", "--filter", "label=com.docker.compose.project=" + project,
                  "--filter", "label=com.docker.compose.service=rustdesk-api-server-pro").decode().split()
    require(len(api) == 1, "找不到同项目独立 API")
    info = json.loads(command("docker", "inspect", api[0]))[0]
    mounts = [item for item in info["Mounts"] if item["Destination"] == "/app/data"]
    require(len(mounts) == 1 and mounts[0]["Type"] == "volume"
            and mounts[0]["Name"] == project + "_controlled-data", "拒绝非专属夹具数据库")
    volume = json.loads(command("docker", "volume", "inspect", mounts[0]["Name"]))[0]
    db_path = Path(volume["Mountpoint"]) / "server.db"
    require(db_path.is_file() and not db_path.is_symlink(), "隔离数据库路径无效")
    run_id = uuid.uuid4().hex[:12]
    username, source = "hbbs-probe-" + run_id, "hbbs-source-" + run_id
    device = str(secrets.randbelow(800000000) + 100000000)
    device_uuid, fingerprint = secrets.token_bytes(16), secrets.token_bytes(32)
    token, target_token, session = secrets.token_urlsafe(48), secrets.token_urlsafe(48), str(uuid.uuid4())
    sessions = [session]
    peer = "controlled-hbbs-probe-" + run_id
    db = sqlite3.connect(db_path, timeout=5)
    audit_start = db.execute("SELECT coalesce(max(id),0) FROM operation_audit").fetchone()[0]
    user_id = token_id = target_token_id = None
    peer_started = False
    expiry = (datetime.now(ZoneInfo("Asia/Shanghai")) + timedelta(minutes=10)).strftime("%Y-%m-%d %H:%M:%S")
    request = field(8, field(1, device.encode()) + field(3, base64.b64encode(public_key)) + field(5, token.encode()))
    try:
        with db:
            user_id = db.execute("INSERT INTO user (username,password,status,is_admin,allow_remote_access,allow_relay) VALUES (?,?,1,0,1,1)",
                                 (username, secrets.token_hex(32))).lastrowid
            for ident in (source, device):
                db.execute("INSERT INTO device (rustdesk_id,user_id,uuid,fingerprint,approval_status,disabled,allow_relay) VALUES (?,?,?,?,'approved',0,1)",
                           (ident, user_id, base64.b64encode(device_uuid).decode() if ident == device else run_id,
                            base64.b64encode(fingerprint).decode() if ident == device else ""))
            token_id = db.execute("INSERT INTO auth_token (user_id,rustdesk_id,uuid,token,token_hash,expired,is_admin,status) VALUES (?,?,?,'',?,?,0,1)",
                                  (user_id, source, run_id, hashlib.sha256(token.encode()).hexdigest(), expiry)).lastrowid
            target_token_id = db.execute("INSERT INTO auth_token (user_id,rustdesk_id,uuid,token,token_hash,expired,is_admin,status) VALUES (?,?,?,'',?,?,0,1)",
                                         (user_id, device, base64.b64encode(device_uuid).decode(),
                                          hashlib.sha256(target_token.encode()).hexdigest(), expiry)).lastrowid
        def allowed_connection():
            """严格检查恢复后的响应，不能只凭消息类型判定允许。"""
            response = encrypted(request, response=True)
            require(len(response) == 1 and response[0][0] == 11
                    and dict(fields(response[0][1])).get(3, 0) == 0,
                    "准入通过后未收到预期加密打洞响应")

        for _ in range(3):
            allowed_connection()
        print("PASS: 双端有效登录令牌连续三次通过策略准入并解密离线目标响应（不是远控或设备私钥证明）")
        for label, sql, ident, denied, allowed, code in (
            ("撤销令牌", "UPDATE auth_token SET status=? WHERE id=?", token_id, 0, 1, "ERR-2303"),
            ("禁用用户", "UPDATE user SET status=? WHERE id=?", user_id, 0, 1, "ERR-2308"),
            ("关闭远控", "UPDATE user SET allow_remote_access=? WHERE id=?", user_id, 0, 1, "ERR-2311"),
            ("禁用目标", "UPDATE device SET disabled=? WHERE rustdesk_id=?", device, 1, 0, "ERR-2307"),
            ("待审批目标", "UPDATE device SET approval_status=? WHERE rustdesk_id=?", device, "pending", "approved", "ERR-2305"),
        ):
            with db:
                db.execute(sql, (denied, ident))
            for _ in range(3):
                observed(lambda: encrypted(request), "连接被拒绝：" + code)
            with db:
                db.execute(sql, (allowed, ident))
            for _ in range(3):
                allowed_connection()
            print("PASS: hbbs 加密连接" + label + "连续三次拒绝及恢复后三次允许（" + code + "）")

        command("docker", "run", "-d", "--rm", "--pull=never", "--name", peer,
                "--network", project + "_rustdesk-control", "alpine:3.20.3", "sleep", "600")
        peer_started = True
        peer_info = json.loads(command("docker", "inspect", peer))[0]
        pid = str(peer_info["State"]["Pid"])
        registration = field(15, field(1, device.encode()) + field(2, device_uuid) + field(3, fingerprint))
        udp_code = "import socket,sys,base64; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(7); s.sendto(base64.b64decode(sys.argv[2]),(sys.argv[1],21116)); print(base64.b64encode(s.recv(4096)).decode())"
        reply = command("nsenter", "-t", pid, "-n", sys.executable, "-c", udp_code, address, base64.b64encode(registration).decode())
        outer = fields(base64.b64decode(reply))
        require(len(outer) == 1 and outer[0][0] == 16 and dict(fields(outer[0][1])).get(1, 0) == 0,
                "已审批目标注册失败")
        registered_ip = peer_info["NetworkSettings"]["Networks"][project + "_rustdesk-control"]["IPAddress"]
        # 从另一来源伪造无 UUID 心跳，后续授权必须仍绑定原注册来源。
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as stream:
            stream.settimeout(7)
            stream.sendto(field(6, field(1, device.encode())), (address, 21116))
            heartbeat, _ = stream.recvfrom(4096)
        outer = fields(heartbeat)
        require(len(outer) == 1 and outer[0][0] == 7 and (2, 1) in fields(outer[0][1]),
                "无 UUID 心跳没有要求重新提交公钥")
        relay = field(18, field(1, device.encode()) + field(2, session.encode()) + field(8, token.encode()))
        with db:
            db.execute("UPDATE device SET allow_relay=0 WHERE rustdesk_id=?", (device,))
        for _ in range(3):
            observed(lambda: encrypted(relay), "中继签发被拒绝：ERR-2309")
        require(db.execute("SELECT count(*) FROM rustdesk_relay_grant WHERE session_uuid=?", (session,)).fetchone()[0] == 0,
                "关闭中继后仍签发授权")
        with db:
            db.execute("UPDATE device SET allow_relay=1 WHERE rustdesk_id=?", (device,))
        encrypted(relay)
        grant = db.execute("SELECT source_used,target_used,source_ip,target_ip FROM rustdesk_relay_grant WHERE session_uuid=?", (session,)).fetchone()
        require(grant and grant[:2] == (0, 0) and grant[2] != grant[3]
                and grant[3] == registered_ip, "真实 hbbs 未签发原注册来源的独立双 IP 授权")
        print("PASS: 另一来源的无 UUID 心跳未劫持已注册设备地址")
        print("PASS: 关闭中继策略经 hbbs 拒绝签发，恢复后真实 hbbs 签发未过期双 IP 授权")
        observed(lambda: encrypted(relay), "中继签发被拒绝：ERR-2315")
        hbbr_ids = command("docker", "ps", "-q", "--filter", "label=com.docker.compose.project=" + project,
                           "--filter", "label=com.docker.compose.service=rustdesk-hbbr").decode().split()
        require(len(hbbr_ids) == 1, "找不到同项目 hbbr")
        hbbr = hbbr_ids[0]
        relay_address = json.loads(command("docker", "inspect", hbbr))[0]["NetworkSettings"]["Networks"][project + "_rustdesk-control"]["IPAddress"]
        frame = base64.b64encode(framed(field(18, field(2, session.encode())))).decode()
        relay_code = """import base64,socket,sys
with socket.create_connection((sys.argv[1],21117),timeout=6) as s:
    s.settimeout(1)
    s.sendall(base64.b64decode(sys.argv[2]))
    try:
        print('data' if s.recv(1) else 'closed')
    except socket.timeout:
        print('pending')
"""
        def relay_attempt(role):
            """从指定独立网络命名空间发送相同授权，不输出会话内容。"""
            args = [sys.executable, "-c", relay_code, relay_address, frame]
            if role != 0:
                namespace_pid = pid if role == 1 else str(json.loads(command("docker", "inspect", container))[0]["State"]["Pid"])
                args = ["nsenter", "-t", namespace_pid, "-n"] + args
            result = subprocess.run(args, capture_output=True, timeout=10)
            require(result.returncode == 0, "实际中继探针执行失败")
            return result.stdout.strip()

        before = command("docker", "logs", hbbr).count(b"ERR-2315")
        require(relay_attempt(2) == b"closed", "换出口请求未被关闭")
        require(db.execute("SELECT source_used,target_used FROM rustdesk_relay_grant WHERE session_uuid=?", (session,)).fetchone() == (0, 0)
                and command("docker", "logs", hbbr).count(b"ERR-2315") > before,
                "换出口请求占用了名额或缺少拒绝日志")
        print("PASS: 已签发授权从第三来源换出口后拒绝且双端名额不变（不是 NAT 兼容通过）")
        before = command("docker", "logs", hbbr).count(b"ERR-2315")
        with ThreadPoolExecutor(max_workers=8) as workers:
            results = list(workers.map(relay_attempt, [0] * 8))
        require(results.count(b"closed") == 7 and results.count(b"pending") == 1,
                "同一源角色并发核销未做到仅一次等待配对")
        require(db.execute("SELECT source_used,target_used FROM rustdesk_relay_grant WHERE session_uuid=?", (session,)).fetchone() == (1, 0)
                and command("docker", "logs", hbbr).count(b"ERR-2315") >= before + 7,
                "并发重放占用目标名额或缺少七条拒绝日志")
        print("PASS: 同一来源八路并发仅一次核销，七次重放拒绝且目标名额保留")
        for role, expected, rejected in ((0, (1, 0), True), (1, (1, 1), False), (1, (1, 1), True)):
            before = command("docker", "logs", hbbr).count(b"ERR-2315")
            result = relay_attempt(role)
            require(db.execute("SELECT source_used,target_used FROM rustdesk_relay_grant WHERE session_uuid=?", (session,)).fetchone() == expected,
                    "真实 hbbs 授权核销状态错误")
            if rejected:
                require(result == b"closed" and command("docker", "logs", hbbr).count(b"ERR-2315") > before,
                        "真实 hbbs 授权重放未拒绝")
        print("PASS: 真实 hbbs 授权不能重复签发，hbbr 双端逐次核销及两端未过期重放拒绝")
        forced = field(8, field(1, device.encode()) + field(3, base64.b64encode(public_key))
                       + field(5, token.encode()) + field(6, b"1.4.9") + b"\x40\x01")
        with db:
            db.execute("UPDATE device SET allow_relay=0 WHERE rustdesk_id=?", (device,))
        observed(lambda: encrypted(forced), "连接被拒绝：ERR-2309")
        with db:
            db.execute("UPDATE device SET allow_relay=1 WHERE rustdesk_id=?", (device,))
        reply = encrypted(forced, response=True)
        require(len(reply) == 1 and reply[0][0] == 19, "强制中继未返回加密 RelayResponse")
        response = dict(fields(reply[0][1]))
        session = response.get(2, b"").decode()
        sessions.append(session)
        require(str(uuid.UUID(session)) == session, "强制中继响应会话格式错误")
        require(response.get(3), "强制中继响应缺少服务器地址")
        require(response.get(5), "强制中继响应缺少签名设备公钥")
        require(db.execute("SELECT source_used,target_used,source_ip,target_ip FROM rustdesk_relay_grant WHERE session_uuid=?", (session,)).fetchone()
                == (0, 0, grant[2], grant[3]), "强制中继没有先签发双端授权")
        frame = base64.b64encode(framed(field(18, field(2, session.encode())))).decode()
        for role, expected in ((0, (1, 0)), (1, (1, 1))):
            relay_attempt(role)
            require(db.execute("SELECT source_used,target_used FROM rustdesk_relay_grant WHERE session_uuid=?", (session,)).fetchone() == expected,
                    "强制中继授权无法逐端核销")
        for role in (0, 1):
            require(relay_attempt(role) == b"closed", "强制中继核销后重放未关闭")
        print("PASS: 强制中继先校验策略并签发，返回加密会话和签名公钥，双端核销及重放拒绝")
        audits = db.execute("SELECT result,error_message,before_data,after_data FROM operation_audit WHERE resource_type='rustdesk_admission' AND resource_id IN (?,?)",
                            (device, session)).fetchall()
        # 核销拒绝不返回设备身份；仅在本次专属副本窗口核对匿名审计。
        consume_audits = db.execute("SELECT result,error_message,before_data,after_data FROM operation_audit WHERE id>? AND resource_type='rustdesk_admission' AND action='rustdesk_internal_relay_grant_consume'",
                                    (audit_start,)).fetchall()
        for code in ("ERR-2303", "ERR-2308", "ERR-2311", "ERR-2307", "ERR-2305", "ERR-2309", "ERR-2315"):
            minimum = 7 if code == "ERR-2315" else 3
            rows = consume_audits if code == "ERR-2315" else audits
            require(sum(row[0] == "deny" and row[1] == code for row in rows) >= minimum,
                    "缺少重复请求的真实准入审计：" + code)
        require(sum(row[0] == "allow" for row in audits) >= 18, "缺少三轮准入及五类策略恢复的允许审计")
        require(all(token not in str(row) for row in audits + consume_audits)
                and token.encode() not in command("docker", "logs", container), "夹具令牌泄漏到日志或审计")
        print("PASS: 重复准入、策略拒绝及并发重放审计数量齐全，日志和审计无原始令牌")
    finally:
        try:
            with db:
                for ident in sessions:
                    db.execute("DELETE FROM rustdesk_relay_grant WHERE session_uuid=?", (ident,))
                    db.execute("DELETE FROM operation_audit WHERE resource_type='rustdesk_admission' AND resource_id=?", (ident,))
                db.execute("DELETE FROM operation_audit WHERE resource_type='rustdesk_admission' AND resource_id=?", (device,))
                if token_id is not None:
                    db.execute("DELETE FROM auth_token WHERE id=? AND rustdesk_id=?", (token_id, source))
                if target_token_id is not None:
                    db.execute("DELETE FROM auth_token WHERE id=? AND rustdesk_id=?", (target_token_id, device))
                db.execute("DELETE FROM device WHERE rustdesk_id IN (?,?) AND user_id=?", (source, device, user_id))
                if user_id is not None:
                    db.execute("DELETE FROM user WHERE id=? AND username=?", (user_id, username))
        finally:
            db.close()
            if peer_started:
                command("docker", "rm", "-f", peer)
        print("PASS: hbbs 合成用户、设备、令牌、授权与来源容器已清理")


def self_test():
    """离线验证协议边界和危险目标拒绝。"""
    require(field(25, field(1, b"x")).hex() == "ca01030a0178", "protobuf 固定字节错误")
    require(encoded_ipv4("127.0.0.1", 21116).hex() == "7c5200000000fe000002", "反射目标地址编码错误")
    for size in (1, 63, 64, 255, 4096):
        left, right = socket.socketpair()
        with left, right:
            data = b"x" * size
            left.sendall(framed(data))
            require(read_frame(right) == data, "长度头边界错误")
    for data in (b"\x00", b"\x0a\x05x", b"\x80" * 10):
        try:
            fields(data)
        except RuntimeError:
            continue
        require(False, "损坏的协议消息未拒绝")
    project = "rustdesk-controlled-three-selftest"
    info = {"Config": {"Labels": {"com.docker.compose.project": project,
            "com.docker.compose.service": "rustdesk-hbbs"}}, "State": {"Running": True},
            "HostConfig": {"PortBindings": {}, "NetworkMode": project + "_rustdesk-control"},
            "NetworkSettings": {"Networks": {project + "_rustdesk-control": {"IPAddress": "172.20.0.2"}}}}
    require(target(info) == (project, "172.20.0.2"), "隔离目标识别失败")
    for mutate in (
        lambda item: item["Config"]["Labels"].update({"com.docker.compose.project": "production"}),
        lambda item: item["Config"]["Labels"].update({"com.docker.compose.service": "rustdesk-api-server-pro"}),
        lambda item: item["State"].update({"Running": False}),
        lambda item: item["HostConfig"].update({"PortBindings": {"21116/tcp": [{"HostPort": "21116"}]}}),
        lambda item: item["HostConfig"].update({"NetworkMode": "host"}),
        lambda item: item["NetworkSettings"]["Networks"].update({"other": {}}),
    ):
        bad = json.loads(json.dumps(info))
        mutate(bad)
        try:
            target(bad)
        except RuntimeError:
            continue
        require(False, "危险目标未拒绝")
    print("PASS: hbbs 帧边界、损坏消息及六类危险目标拒绝自测")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        else:
            require(len(sys.argv) in (2, 3) and (len(sys.argv) == 2 or sys.argv[2] == "--api-unavailable"),
                    "用法：controlled-hbbs-protocol-acceptance.py <隔离 hbbs 容器> [--api-unavailable]|--self-test")
            acceptance(sys.argv[1], len(sys.argv) == 3)
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError) else "ERR-239D hbbs 协议验收异常：" + type(error).__name__, file=sys.stderr)
        sys.exit(1)
