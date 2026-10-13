#!/usr/bin/env python3
"""在授权局域网 PoC 中验证中继核销、撤销与 API 超时默认拒绝。"""

import base64
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
import uuid
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo


PROJECT = "rustdesk-controlled-lan-poc"
PROBE_CODE = """
import base64, socket, sys
with socket.create_connection((sys.argv[1], 21117), timeout=6) as stream:
    stream.sendall(base64.b64decode(sys.argv[2]))
    try:
        print('data' if stream.recv(1) else 'closed')
    except socket.timeout:
        print('pending')
"""


def require(condition, message):
    """统一输出不包含凭据的失败信息。"""
    if not condition:
        raise RuntimeError("ERR-239D " + message)


def interrupted(signum, _frame):
    """中断时仍进入清理流程，API 的独立恢复定时器继续兜底。"""
    raise RuntimeError("ERR-239D 验收收到中断信号：" + str(signum))


def command(*args, timeout=30):
    """运行系统工具，不将可能含凭据的参数或原始输出写入错误。"""
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    require(result.returncode == 0, "系统工具执行失败：" + Path(args[0]).name)
    return result.stdout.strip()


def target_settings(info):
    """只允许修改指定隔离项目的运行容器和专属数据卷。"""
    labels = info["Config"].get("Labels") or {}
    require(labels.get("com.docker.compose.project") == PROJECT, "拒绝操作非隔离 PoC 容器")
    require(labels.get("com.docker.compose.service") == "rustdesk-controlled", "隔离服务标签不匹配")
    require(info["State"].get("Running"), "隔离 PoC 未运行")
    networks = info["NetworkSettings"]["Networks"]
    require(set(networks) == {PROJECT + "_default"}, "隔离网络不匹配")
    address = networks[PROJECT + "_default"]["IPAddress"]
    require(ipaddress.ip_address(address).version == 4, "缺少隔离 IPv4 地址")
    mounts = [m for m in info["Mounts"] if m["Destination"] == "/app/data"]
    require(len(mounts) == 1 and mounts[0].get("Type") == "volume"
            and mounts[0].get("Name") == PROJECT + "_controlled-data", "拒绝操作非专属测试数据卷")
    return address, mounts[0]["Name"]


def relay_frame(session):
    """按固定官方基线编码不携带 token 的 RequestRelay 探针。"""
    require(str(uuid.UUID(session)) == session and uuid.UUID(session).version == 4, "会话必须是规范 UUID v4")
    relay = b"\x12\x24" + session.encode("ascii")
    message = b"\x92\x01" + bytes([len(relay)]) + relay
    return bytes([len(message) << 2]) + message


def self_test():
    """检查协议固定字节以及禁止写入生产数据的保护。"""
    session = "123e4567-e89b-42d3-a456-426614174000"
    require(relay_frame(session).hex() == "a49201261224" + session.encode().hex(), "探针帧编码自测失败")
    info = {"Config": {"Labels": {"com.docker.compose.project": PROJECT,
            "com.docker.compose.service": "rustdesk-controlled"}}, "State": {"Running": True},
            "NetworkSettings": {"Networks": {PROJECT + "_default": {"IPAddress": "172.20.0.2"}}},
            "Mounts": [{"Destination": "/app/data", "Type": "volume", "Name": PROJECT + "_controlled-data"}]}
    require(target_settings(info) == ("172.20.0.2", PROJECT + "_controlled-data"), "隔离目标识别失败")
    for mutate in (
        lambda item: item["Config"]["Labels"].update({"com.docker.compose.project": "production"}),
        lambda item: item["Mounts"][0].update({"Name": "production-data"}),
        lambda item: item["Mounts"][0].update({"Type": "bind"}),
        lambda item: item["State"].update({"Running": False}),
        lambda item: item["NetworkSettings"]["Networks"].update({"host": {}}),
    ):
        bad = json.loads(json.dumps(info))
        mutate(bad)
        try:
            target_settings(bad)
        except RuntimeError:
            continue
        require(False, "危险目标未被拒绝")
    print("PASS: 协议帧及隔离目标保护自测")


def acceptance(container):
    """创建独立夹具并通过运行中的 API 与 hbbr 验证准入。"""
    require(os.geteuid() == 0, "实机验收需在授权 Linux Docker 主机以 root 运行")
    for tool in ("docker", "nsenter", "systemd-run", "systemctl"):
        require(shutil.which(tool), "缺少工具：" + tool)
    info = json.loads(command("docker", "inspect", container))[0]
    address, volume = target_settings(info)
    volume_info = json.loads(command("docker", "volume", "inspect", volume))[0]
    db_path = Path(volume_info["Mountpoint"]) / "server.db"
    require(db_path.is_file() and not db_path.is_symlink(), "找不到隔离数据库或数据库是符号链接")
    environment = dict(value.split("=", 1) for value in info["Config"]["Env"] if "=" in value)
    secret = environment.get("RUSTDESK_API_INTERNAL_SECRET", "")
    require(len(secret) >= 32, "缺少隔离内部密钥")
    run_id = uuid.uuid4().hex[:12]
    source, target = "relay-source-" + run_id, "relay-target-" + run_id
    device_uuid, token = str(uuid.uuid4()), secrets.token_urlsafe(48)
    unit = "controlled-relay-api-resume-" + run_id
    peers, sessions = [], []
    db = sqlite3.connect(db_path, timeout=5)
    user_id = token_id = None
    resume_needed = timer_created = False
    since = str(int(time.time()) - 1)

    def flags(session):
        """读取本次授权的逐端核销状态。"""
        return db.execute("SELECT source_used,target_used FROM rustdesk_relay_grant WHERE session_uuid=?", (session,)).fetchone()

    def denial_count(code):
        """只统计拒绝错误码，不输出可能含会话标识的原始日志。"""
        result = subprocess.run(["docker", "logs", "--since", since, container], capture_output=True, text=True, timeout=10)
        require(result.returncode == 0, "无法读取隔离中继日志")
        return (result.stdout + result.stderr).count("中继会话被拒绝：" + code)

    def issue():
        """通过真实内部 API 签发短时授权，令牌仅在内存中使用。"""
        session = str(uuid.uuid4())
        sessions.append(session)
        payload = {"target_id": target, "access_token": token, "session_uuid": session,
                   "source_ip": peers[0][1], "target_ip": peers[1][1]}
        connection = http.client.HTTPConnection(address, 12345, timeout=5)
        try:
            connection.request("POST", "/internal/rustdesk/relay/grant/issue", json.dumps(payload),
                               {"Content-Type": "application/json", "X-Internal-Secret": secret})
            response = connection.getresponse()
            require(response.status == 200 and json.loads(response.read()).get("allow") is True, "隔离 API 未允许测试授权签发")
        finally:
            connection.close()
        require(flags(session) == (0, 0), "新授权核销状态不正确")
        return session

    def probe(session, peer, expected, code=None):
        """从独立来源网络发送协议帧，联查断开、日志与数据库状态。"""
        before = denial_count(code) if code else 0
        frame = base64.b64encode(relay_frame(session)).decode("ascii")
        result = command("nsenter", "-t", str(peers[peer][2]), "-n", sys.executable,
                         "-c", PROBE_CODE, address, frame, timeout=10)
        require(flags(session) == expected, "核销状态与预期不符")
        if code:
            require(result == "closed", "被拒绝的中继连接未及时关闭")
            require(denial_count(code) > before, "未找到对应的中继拒绝日志：" + code)

    def resume_api():
        """恢复隔离 API；成功恢复前保留自动恢复定时器。"""
        command("docker", "exec", container, "sh", "-ec", 'kill -CONT "$(cat /tmp/rustdesk-controlled-api.pid)"')

    try:
        for role in ("source", "target", "wrong"):
            name = "controlled-relay-probe-" + run_id + "-" + role
            command("docker", "run", "-d", "--rm", "--pull=never", "--name", name,
                    "--network", PROJECT + "_default", "alpine:3.20.3", "sleep", "600")
            peers.append((name, "", 0))
            peer_info = json.loads(command("docker", "inspect", name))[0]
            peers[-1] = (name, peer_info["NetworkSettings"]["Networks"][PROJECT + "_default"]["IPAddress"], peer_info["State"]["Pid"])
        expiry = (datetime.now(ZoneInfo("Asia/Shanghai")) + timedelta(minutes=10)).strftime("%Y-%m-%d %H:%M:%S")
        with db:
            user_id = db.execute("INSERT INTO user (username,password,status,is_admin,allow_remote_access,allow_relay) VALUES (?,?,1,0,1,1)",
                                 ("relay-probe-" + run_id, secrets.token_hex(32))).lastrowid
            for device in (source, target):
                db.execute("INSERT INTO device (rustdesk_id,user_id,uuid,approval_status,disabled,allow_relay) VALUES (?,?,?,'approved',0,1)",
                           (device, user_id, device_uuid if device == source else str(uuid.uuid4())))
            token_id = db.execute("INSERT INTO auth_token (user_id,rustdesk_id,uuid,token,token_hash,expired,is_admin,status) VALUES (?,?,?,'',?,?,0,1)",
                                  (user_id, source, device_uuid, hashlib.sha256(token.encode()).hexdigest(), expiry)).lastrowid
        session = issue()
        probe(session, 0, (1, 0))
        probe(session, 0, (1, 0), "ERR-2315")
        probe(session, 1, (1, 1))
        probe(session, 1, (1, 1), "ERR-2315")
        print("PASS: API 签发授权、双端单次核销与未过期重放拒绝")
        session = issue()
        probe(session, 2, (0, 0), "ERR-2315")
        probe(session, 0, (1, 0))
        print("PASS: 错误来源 IP 被拒绝且不占用合法端点名额")
        cases = (
            ("令牌撤销", "UPDATE auth_token SET status=? WHERE id=?", token_id, 0, "ERR-2303"),
            ("禁用用户", "UPDATE user SET status=? WHERE id=?", user_id, 0, "ERR-2308"),
            ("禁用目标设备", "UPDATE device SET disabled=? WHERE rustdesk_id=?", target, 1, "ERR-2307"),
            ("关闭目标中继", "UPDATE device SET allow_relay=? WHERE rustdesk_id=?", target, 0, "ERR-2309"),
        )
        for label, sql, key, denied, code in cases:
            for peer in (0, 1):
                session = issue()
                if peer == 1:
                    probe(session, 0, (1, 0))
                with db:
                    db.execute(sql, (denied, key))
                probe(session, peer, (peer, 0), code)
                with db:
                    db.execute(sql, (1 - denied, key))
                probe(session, peer, (1, peer))
            print("PASS: 授权后" + label + "在第一端及第二端均立即拒绝，恢复后名额可用（" + code + "）")
        for peer in (0, 1):
            session = issue()
            if peer == 1:
                probe(session, 0, (1, 0))
            unit = "controlled-relay-api-resume-" + run_id + "-" + str(peer)
            command("systemd-run", "--unit=" + unit, "--on-active=20s", "--property=Type=oneshot",
                    shutil.which("docker"), "exec", container, "sh", "-ec", 'kill -CONT "$(cat /tmp/rustdesk-controlled-api.pid)"')
            timer_created = True
            require(command("systemctl", "is-active", unit + ".timer") == "active", "API 自动恢复定时器未启用")
            resume_needed = True
            command("docker", "exec", container, "sh", "-ec", 'kill -STOP "$(cat /tmp/rustdesk-controlled-api.pid)"')
            api_pid = command("docker", "exec", container, "cat", "/tmp/rustdesk-controlled-api.pid")
            require(api_pid.isdigit(), "API 进程标识无效")
            status = command("docker", "exec", container, "cat", "/proc/" + api_pid + "/status")
            require(any(line.startswith("State:") and "\tT" in line for line in status.splitlines()), "API 未进入停挂状态")
            command("docker", "exec", container, "sh", "-ec", 'kill -0 "$(cat /tmp/rustdesk-controlled-hbbr.pid)"')
            probe(session, peer, (peer, 0), "ERR-239B")
            resume_api()
            resume_needed = False
            probe(session, peer, (1, peer))
            command("systemctl", "stop", unit + ".timer")
            timer_created = False
        print("PASS: API 停挂时两端均拒绝新中继且不占名额，恢复后同一授权可核销")
    finally:
        cleanup_errors = []
        if resume_needed:
            try:
                resume_api()
                resume_needed = False
            except Exception:
                cleanup_errors.append("API 手动恢复失败，自动恢复定时器保留")
        if timer_created and not resume_needed:
            try:
                command("systemctl", "stop", unit + ".timer")
            except Exception:
                cleanup_errors.append("停止 API 恢复定时器失败")
        try:
            with db:
                for session in sessions:
                    db.execute("DELETE FROM rustdesk_relay_grant WHERE session_uuid=?", (session,))
                if token_id is not None:
                    db.execute("DELETE FROM auth_token WHERE id=? AND rustdesk_id=?", (token_id, source))
                db.execute("DELETE FROM device WHERE rustdesk_id IN (?,?)", (source, target))
                if user_id is not None:
                    db.execute("DELETE FROM user WHERE id=? AND username=?", (user_id, "relay-probe-" + run_id))
        except Exception:
            cleanup_errors.append("合成数据库记录清理失败")
        finally:
            db.close()
        for name, _, _ in peers:
            try:
                command("docker", "rm", "-f", name)
            except Exception:
                cleanup_errors.append("探针容器清理失败")
        require(not cleanup_errors, "；".join(cleanup_errors))
        print("PASS: 合成授权、令牌、设备、用户与探针容器已清理")


if __name__ == "__main__":
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        else:
            require(len(sys.argv) == 2, "用法：python3 controlled-relay-protocol-acceptance.py <隔离容器名>|--self-test")
            acceptance(sys.argv[1])
    except Exception as error:
        message = str(error) if isinstance(error, RuntimeError) else "ERR-239D 验收异常（" + type(error).__name__ + "），请检查测试环境"
        print(message, file=sys.stderr)
        sys.exit(1)
