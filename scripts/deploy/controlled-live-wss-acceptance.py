#!/usr/bin/env python3
"""在现用服务使用短期合成身份验收 WSS，不修改既有身份或重建服务。"""

import base64
from contextlib import closing
from datetime import datetime, timedelta
import hashlib
import ipaddress
from importlib import import_module
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import sqlite3
import subprocess
import sys
import time
import uuid
from zoneinfo import ZoneInfo

sys.dont_write_bytecode = True
wss = import_module("controlled-wss-protocol-acceptance")
p = wss.protocol
require, command, field = p.require, p.command, p.field


def validate_manifest(m):
    """限制自动清理范围，拒绝用普通用户或设备充当夹具。"""
    run = m["run"]
    require(re.fullmatch(r"[0-9a-f]{32}", run) is not None, "清理标识无效")
    require(m["username"] == "wss-live-" + run and m["source"] == "wss-source-" + run,
            "拒绝清理非本轮测试身份")
    require(re.fullmatch(r"[1-9][0-9]{8}", m["target"]) is not None, "测试目标编号无效")
    require(len(base64.b64decode(m["device_uuid"], validate=True)) == 16, "测试设备 UUID 无效")
    require(m["peer"] == "controlled-live-wss-" + run, "测试容器名称无效")


def delete_rows(db, m):
    """按本轮身份联合约束清理，保留审计，不覆盖既有数据库。"""
    validate_manifest(m)
    user = db.execute("SELECT id FROM user WHERE username=?", (m["username"],)).fetchone()
    if not user:
        return
    uid = user[0]
    devices = db.execute("SELECT rustdesk_id,uuid FROM device WHERE user_id=?", (uid,)).fetchall()
    require(set(devices).issubset({(m["source"], m["run"]), (m["target"], m["device_uuid"])}),
            "身份已发生非夹具变更，拒绝自动删除")
    tokens = db.execute("SELECT rustdesk_id FROM auth_token WHERE user_id=?", (uid,)).fetchall()
    require(all(row[0] in (m["source"], m["target"]) for row in tokens),
            "身份已有非夹具令牌，拒绝自动删除")
    with db:
        db.execute("DELETE FROM rustdesk_relay_grant WHERE source_id=? AND target_id=?",
                   (m["source"], m["target"]))
        db.execute("DELETE FROM auth_token WHERE user_id=? AND rustdesk_id IN (?,?)",
                   (uid, m["source"], m["target"]))
        db.execute("DELETE FROM device WHERE user_id=? AND rustdesk_id IN (?,?)",
                   (uid, m["source"], m["target"]))
        db.execute("DELETE FROM user WHERE id=? AND username=?", (uid, m["username"]))


def remove_fixture_container(m):
    """Docker 查询失败不能冒充容器已不存在，且只移除标签匹配的夹具。"""
    validate_manifest(m)
    result = subprocess.run(["docker", "inspect", m["peer"]], capture_output=True, timeout=15)
    if result.returncode == 0:
        info = json.loads(result.stdout)[0]
        require((info["Config"].get("Labels") or {}).get("controlled.wss.run") == m["run"],
                "拒绝移除非本轮测试容器")
        command("docker", "rm", "-f", m["peer"])
    else:
        remaining = command("docker", "ps", "-a", "--filter", "name=^/" + m["peer"] + "$", "--format", "{{.ID}}")
        require(not remaining.strip(), "测试容器仍存在或无法确认，保留清理保护")


def backup_database(source, destination):
    """有界备份只读源，正确转义路径并及时关闭两端连接。"""
    deadline = time.monotonic() + 60

    def check_deadline(status, remaining, total):
        """锁竞争或持续写入时在创建测试身份之前拒绝继续。"""
        require(time.monotonic() < deadline, "数据库备份超时，未创建测试身份")

    with closing(sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True)) as original:
        with closing(sqlite3.connect(destination)) as copy:
            original.backup(copy, pages=256, progress=check_deadline, sleep=0.05)
            require(copy.execute("PRAGMA integrity_check").fetchone() == ("ok",), "备份完整性检查失败")


def cleanup(backup):
    """供独立 systemd 定时器调用，可重复执行精确清理。"""
    require(backup.is_dir() and not backup.is_symlink() and backup.stat().st_uid == 0
            and backup.stat().st_mode & 0o077 == 0, "清理目录必须由 root 私有持有")
    m = json.loads((backup / "fixture.json").read_text())
    validate_manifest(m)
    root = backup.parent.parent
    require(backup.parent.name == "backups" and (root / "compose.yaml").is_file(), "部署目录无效")
    with closing(sqlite3.connect(root / "data/server.db", timeout=10)) as db:
        delete_rows(db, m)
    # 先撤销 API 凭据；仅删除 UUID 同时匹配的测试注册记录。
    key_dir = Path(m["key_dir"])
    with closing(sqlite3.connect(key_dir / "db_v2.sqlite3", timeout=10)) as db:
        with db:
            db.execute("DELETE FROM peer WHERE id=? AND uuid=?",
                       (m["target"], base64.b64decode(m["device_uuid"])))
    remove_fixture_container(m)
    for name in ("source.json", "target.json"):
        (backup / name).unlink(missing_ok=True)
    (backup / "cleanup.json").write_text(json.dumps({"cleaned": True, "time": datetime.now().isoformat()}))


def peer_call(pid, code, data):
    """通过标准输入传递短期测试材料，不放到进程参数或输出。"""
    return subprocess.Popen(["nsenter", "-t", str(pid), "-n", sys.executable, "-c", code,
                             str(Path(__file__).resolve().parent)],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE), json.dumps(data).encode()


def communicate_peer(child, data):
    """一次性探针超时或通信异常时终止并回收子进程。"""
    try:
        return child.communicate(data, timeout=12)
    finally:
        if child.poll() is None:
            child.kill()
            child.communicate(timeout=5)


def external_evidence(db, m, audit_start):
    """核对本轮三次真实签发、逐端核销及两个实际来源的重放审计。"""
    validate_manifest(m)
    rows = db.execute("SELECT session_uuid,source_ip,target_ip,source_used,target_used FROM rustdesk_relay_grant WHERE source_id=? AND target_id=?",
                      (m["source"], m["target"])).fetchall()
    require(len(rows) == 3 and all(row[3:] == (1, 1) for row in rows), "本轮三次授权尚未全部核销")
    require(len({row[0] for row in rows}) == 3 and len({row[1:3] for row in rows}) == 1,
            "会话重复或双端出口发生变化，需要新窗口")
    def normalized(value):
        """审计保留 IPv4 映射地址，按地址语义关联授权中的 IPv4。"""
        address = ipaddress.ip_address(value)
        if isinstance(address, ipaddress.IPv6Address):
            address = address.ipv4_mapped or address
        return address

    source, target = rows[0][1:3]
    require(normalized(source) != normalized(target), "双端实际来源不能相同")
    audits = db.execute("SELECT action,result,error_message,before_data FROM operation_audit WHERE id>? AND resource_type='rustdesk_admission' AND resource_id IN (?,?)",
                        (audit_start, m["source"], m["target"])).fetchall()
    for action, minimum in (("rustdesk_internal_relay_grant_issue", 3), ("rustdesk_internal_relay_grant_consume", 6)):
        require(sum(row[0] == action and row[1] == "allow" for row in audits) == minimum, "签发或核销允许审计不完整")
    denied = db.execute("SELECT before_data FROM operation_audit WHERE id>? AND resource_type='rustdesk_admission' AND action='rustdesk_internal_relay_grant_consume' AND result='deny' AND error_message='ERR-2315'",
                        (audit_start,)).fetchall()
    allowed = [(row[0], json.loads(row[3])) for row in audits if row[1] == "allow"]
    replays = [json.loads(row[0]) for row in denied]
    for session, source_ip, target_ip, _, _ in rows:
        digest = hashlib.sha256(session.encode()).hexdigest()
        issued = [data for action, data in allowed if action == "rustdesk_internal_relay_grant_issue"
                  and data.get("session_sha256") == digest]
        require(len(issued) == 1 and normalized(issued[0]["source_ip"]) == normalized(source_ip)
                and normalized(issued[0]["target_ip"]) == normalized(target_ip), "缺少本会话双来源签发审计")
        for peer in (source_ip, target_ip):
            require(sum(action == "rustdesk_internal_relay_grant_consume" and data.get("session_sha256") == digest
                        and normalized(data["peer_ip"]) == normalized(peer) for action, data in allowed) == 1,
                    "缺少本会话逐端核销审计")
            require(any(data.get("session_sha256") == digest and normalized(data["peer_ip"]) == normalized(peer)
                        for data in replays), "缺少本会话逐端重放拒绝审计，请勿沿用旧版无摘要审计")
    return {"sessions": [row[0] for row in rows], "source_ip": source, "target_ip": target,
            "source_global": ipaddress.ip_address(source).is_global, "target_global": ipaddress.ip_address(target).is_global,
            "consumed": [1, 1], "issued": 3, "replays_rejected_minimum": 6,
            "audit_session_sha256": True,
            "external_network_human_confirmation": False, "browser_remote_desktop": False}


def collect_external(backup):
    """收集仍在保护期的实际授权证据，成功后精确清理，不恢复整库。"""
    require(backup.is_dir() and backup.stat().st_uid == 0 and backup.stat().st_mode & 0o077 == 0, "证据目录必须由 root 私有持有")
    m = json.loads((backup / "fixture.json").read_text())
    validate_manifest(m)
    window = json.loads((backup / "external-window.json").read_text())
    root = backup.parent.parent
    require(backup.parent.name == "backups", "证据目录不在部署备份中")
    with closing(sqlite3.connect(root / "data/server.db", timeout=10)) as db:
        result = external_evidence(db, m, window["audit_start"])
        source = json.loads((backup / "source.json").read_text())
        logs = command("docker", "logs", "rustdesk-hbbs-controlled") + command("docker", "logs", "rustdesk-hbbr-controlled")
        audit_text = str(db.execute("SELECT before_data,after_data FROM operation_audit WHERE id>?", (window["audit_start"],)).fetchall())
        require(source["token"].encode() not in logs and source["token"] not in audit_text, "测试令牌出现在日志或审计中")
    infos = [json.loads(command("docker", "inspect", entry[0]))[0] for entry in window["containers"]]
    require([[v["Id"], v["State"]["StartedAt"]] for v in infos] == window["containers"]
            and all(v["State"]["Health"]["Status"] == "healthy" for v in infos), "窗口内现用服务发生变更")
    result["time"] = datetime.now().isoformat()
    (backup / "external-server-result.json").write_text(json.dumps(result, indent=2))
    cleanup(backup)
    command("systemctl", "stop", "controlled-wss-live-cleanup-" + m["run"] + ".timer")
    print("PASS: 双端各三次真实 WSS 授权核销和重放审计通过，已清理；仍需核对客户端结果及独立外网来源。")


def run(root, external=False):
    """先备份并安排清理，再完成三次真实服务签发与双向 WSS 会话。"""
    require(os.geteuid() == 0 and root.is_dir() and not root.is_symlink(), "必须在目标机以 root 执行")
    os.umask(0o077)
    infos = [json.loads(command("docker", "inspect", name))[0] for name in
             ("rustdesk-api-server-pro", "rustdesk-hbbs-controlled", "rustdesk-hbbr-controlled")]
    api, hbbs, hbbr = infos
    project = api["Config"]["Labels"]["com.docker.compose.project"]
    network = project + "_rustdesk-control"
    for info in infos:
        require(info["State"]["Running"] and info["State"]["Health"]["Status"] == "healthy"
                and info["Config"]["Labels"]["com.docker.compose.project"] == project
                and network in info["NetworkSettings"]["Networks"], "三容器必须健康且同项目同网络")
    mounts = [v for v in api["Mounts"] if v["Destination"] == "/app/data"]
    require(len(mounts) == 1 and Path(mounts[0]["Source"]).resolve() == root / "data", "部署数据库挂载不匹配")
    key_mounts = [v for v in hbbs["Mounts"] if v["Destination"] == "/data"]
    require(len(key_mounts) == 1 and key_mounts[0]["Type"] == "volume", "服务端密钥卷不匹配")
    key_dir = Path(key_mounts[0]["Source"])
    certificate = root / "data/tls/rustdesk.jtzxsoft.com.fullchain.pem"
    require(certificate.is_file() and not certificate.is_symlink(), "现用证书路径无效")
    public_key = base64.b64decode((key_dir / "id_ed25519.pub").read_text().strip(), validate=True)
    require(len(public_key) == 32, "服务端公钥无效")
    host = "rustdesk.jtzxsoft.com"
    # shortcut: 源端可能经过 NAT 回流、目标端走容器网；独立外网双端业务须另验。
    wss.public_acceptance(host, "22118", "22119", str(certificate),
                          "wss://" + host + ":22118/", "wss://" + host + ":22119/")
    run_id = uuid.uuid4().hex
    m = {"run": run_id, "username": "wss-live-" + run_id, "source": "wss-source-" + run_id,
         "target": str(secrets.randbelow(800000000) + 100000000),
         "device_uuid": base64.b64encode(secrets.token_bytes(16)).decode(),
         "peer": "controlled-live-wss-" + run_id, "key_dir": str(key_dir)}
    validate_manifest(m)
    backup = root / "backups" / ("wss-live-" + run_id)
    backup.mkdir(mode=0o700)
    for name in ("compose.yaml", "runtime.env"):
        shutil.copy2(root / name, backup / name)
    for source, name in ((root / "data/server.db", "api.sqlite3"), (key_dir / "db_v2.sqlite3", "server.sqlite3")):
        backup_database(source, backup / name)
    (backup / "fixture.json").write_text(json.dumps(m))
    unit = "controlled-wss-live-cleanup-" + run_id
    minutes = 45 if external else 10
    window_started = datetime.now(ZoneInfo("UTC"))
    command("systemd-run", "--unit=" + unit, "--on-active=" + str(minutes) + "m", "--timer-property=AccuracySec=1s",
            "--property=Type=oneshot", sys.executable, "-B", str(Path(__file__).resolve()), "--cleanup", str(backup))
    require(command("systemctl", "is-active", unit + ".timer").strip() == b"active", "自动清理未启用")
    print("保护已建立：" + str(backup), flush=True)
    fingerprint = secrets.token_bytes(32)
    tokens = [secrets.token_urlsafe(48), secrets.token_urlsafe(48)]
    baseline = [(v["Id"], v["State"]["StartedAt"]) for v in infos]
    db = sqlite3.connect(root / "data/server.db", timeout=10)
    awaiting_external = False
    try:
        expiry = (window_started + timedelta(minutes=minutes)).astimezone(ZoneInfo("Asia/Shanghai")).strftime("%Y-%m-%d %H:%M:%S")
        with db:
            require(db.execute("SELECT count(*) FROM device WHERE rustdesk_id IN (?,?)", (m["source"], m["target"])).fetchone()[0] == 0,
                    "随机测试编号冲突，未修改设备")
            uid = db.execute("INSERT INTO user (username,password,status,is_admin,allow_remote_access,allow_relay) VALUES (?,?,1,0,1,1)",
                             (m["username"], secrets.token_hex(32))).lastrowid
            for ident, device_uuid, token in ((m["source"], run_id, tokens[0]), (m["target"], m["device_uuid"], tokens[1])):
                db.execute("INSERT INTO device (rustdesk_id,user_id,uuid,fingerprint,approval_status,disabled,allow_relay) VALUES (?,?,?,?,'approved',0,1)",
                           (ident, uid, device_uuid, base64.b64encode(fingerprint).decode() if ident == m["target"] else ""))
                db.execute("INSERT INTO auth_token (user_id,rustdesk_id,uuid,token,token_hash,expired,is_admin,status) VALUES (?,?,?,'',?,?,0,1)",
                           (uid, ident, device_uuid, hashlib.sha256(token.encode()).hexdigest(), expiry))
        if external:
            expires_at = window_started + timedelta(minutes=minutes-1)
            require(expires_at - datetime.now(ZoneInfo("UTC")) >= timedelta(minutes=30),
                    "准备耗时过长，剩余操作期不足三十分钟，须清理后重开窗口")
            expires = expires_at.isoformat()
            common = {"run": run_id, "target": m["target"], "expires_utc": expires}
            (backup / "source.json").write_text(json.dumps({**common, "role": "source", "public_key": base64.b64encode(public_key).decode(), "token": tokens[0]}))
            (backup / "target.json").write_text(json.dumps({**common, "role": "target", "device_uuid": m["device_uuid"], "fingerprint": base64.b64encode(fingerprint).decode()}))
            (backup / "external-window.json").write_text(json.dumps({"expires_utc": expires, "containers": baseline,
                "audit_start": db.execute("SELECT coalesce(max(id),0) FROM operation_audit").fetchone()[0]}))
            awaiting_external = True
            print("外网窗口已准备，两个角色配置仅在 root 私有目录；44 分钟操作期，45 分钟自动清理；配置到期 UTC：" + expires, flush=True)
            return
        command("docker", "run", "-d", "--rm", "--pull=never", "--name", m["peer"],
                "--label", "controlled.wss.run=" + run_id, "--network", network, "alpine:3.20.3", "sleep", "600")
        peer = json.loads(command("docker", "inspect", m["peer"]))[0]
        pid = peer["State"]["Pid"]
        target_ip = peer["NetworkSettings"]["Networks"][network]["IPAddress"]
        hbbs_ip = hbbs["NetworkSettings"]["Networks"][network]["IPAddress"]
        relay_ip = hbbr["NetworkSettings"]["Networks"][network]["IPAddress"]
        registration = field(15, field(1, m["target"].encode()) + field(2, base64.b64decode(m["device_uuid"])) + field(3, fingerprint))
        child, data = peer_call(pid, "import sys,json,socket,base64; d=json.load(sys.stdin); s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.settimeout(7); s.sendto(base64.b64decode(d['payload']),(d['host'],21116)); print(base64.b64encode(s.recv(4096)).decode())",
                                {"payload": base64.b64encode(registration).decode(), "host": hbbs_ip})
        output, _ = communicate_peer(child, data)
        outer = p.fields(base64.b64decode(output)) if child.returncode == 0 else []
        require(len(outer) == 1 and outer[0][0] == 16 and dict(p.fields(outer[0][1])).get(1, 0) == 0,
                "本轮测试目标注册失败")
        results = []
        for index in range(3):
            request = field(8, field(1, m["target"].encode()) + field(3, base64.b64encode(public_key))
                            + field(5, tokens[0].encode()) + field(6, b"1.5.0") + b"\x40\x01")
            with wss.websocket(host, 22118, str(certificate), hostname=host) as stream:
                wss.send_binary(stream, request)
                outer = p.fields(wss.read_binary(stream) or b"")
            require(len(outer) == 1 and outer[0][0] == 19, "真实 hbbs 未返回中继会话")
            response = dict(p.fields(outer[0][1]))
            session = response.get(2, b"").decode()
            require(str(uuid.UUID(session)) == session and response.get(3) and response.get(5), "签发响应不完整")
            grant = db.execute("SELECT source_used,target_used,source_ip,target_ip FROM rustdesk_relay_grant WHERE session_uuid=? AND source_id=? AND target_id=?",
                               (session, m["source"], m["target"])).fetchone()
            require(grant and grant[:2] == (0, 0) and grant[2] != grant[3] and grant[3] == target_ip,
                    "真实 hbbs 未签发双来源逐端授权")
            payload = field(18, field(2, session.encode()))
            challenge, answer = secrets.token_bytes(256), secrets.token_bytes(257)
            target_code = """import sys,json,base64,importlib
sys.dont_write_bytecode=True
sys.path.insert(0,sys.argv[1])
w=importlib.import_module('controlled-wss-protocol-acceptance')
d=json.load(sys.stdin)
with w.websocket(d['host'],21119,d['certificate'],hostname=d['name']) as s:
 w.send_binary(s,base64.b64decode(d['payload']))
 w.send_binary(s,base64.b64decode(d['challenge']))
 w.require(w.read_binary(s)==base64.b64decode(d['answer']),'目标双向传输失败')
print('roundtrip-ok')
"""
            child, data = peer_call(pid, target_code, {"host": relay_ip, "certificate": str(certificate), "name": host,
                                                       **{k: base64.b64encode(v).decode() for k, v in
                                                          (("payload", payload), ("challenge", challenge), ("answer", answer))}})
            try:
                child.stdin.write(data)
                child.stdin.close()
                child.stdin = None
                with wss.websocket(host, 22119, str(certificate), hostname=host) as stream:
                    wss.send_binary(stream, payload)
                    require(wss.read_binary(stream) == challenge, "源端收到的数据不一致")
                    wss.send_binary(stream, answer)
                    output, _ = child.communicate(timeout=12)
                    require(child.returncode == 0 and output.strip() == b"roundtrip-ok", "目标端往返验证失败")
            finally:
                if child.poll() is None:
                    child.kill()
                child.communicate(timeout=5)
            require(db.execute("SELECT source_used,target_used FROM rustdesk_relay_grant WHERE session_uuid=?", (session,)).fetchone() == (1, 1),
                    "真实 hbbr 未完成双端核销")
            before = command("docker", "logs", hbbr["Id"]).count(b"ERR-2315")
            for role in ("source", "target"):
                if role == "source":
                    with wss.websocket(host, 22119, str(certificate), hostname=host) as stream:
                        wss.send_binary(stream, payload)
                        require(wss.read_binary(stream) is None, "源端重放未拒绝")
                else:
                    code = "import sys,json,base64,importlib; sys.dont_write_bytecode=True; sys.path.insert(0,sys.argv[1]); w=importlib.import_module('controlled-wss-protocol-acceptance'); d=json.load(sys.stdin); c=w.websocket(d['host'],21119,d['certificate'],hostname=d['name']); s=c.__enter__(); w.send_binary(s,base64.b64decode(d['payload'])); w.require(w.read_binary(s) is None,'目标重放未拒绝'); c.__exit__(None,None,None); print('closed')"
                    child, data = peer_call(pid, code, {"host": relay_ip, "certificate": str(certificate), "name": host,
                                                       "payload": base64.b64encode(payload).decode()})
                    output, _ = communicate_peer(child, data)
                    require(child.returncode == 0 and output.strip() == b"closed", "目标端重放未拒绝")
            require(command("docker", "logs", hbbr["Id"]).count(b"ERR-2315") >= before + 2, "缺少本轮重放拒绝日志")
            results.append({"round": index + 1, "session": session, "source_ip": grant[2], "target_ip": grant[3],
                            "issued": True, "consumed": [1, 1], "bidirectional": True, "replays_rejected": 2})
            print("PASS: 第 %d 次真实 hbbs WSS 签发、hbbr WSS 双端核销、双向数据及两端重放拒绝" % (index + 1), flush=True)
        logs = command("docker", "logs", hbbs["Id"]) + command("docker", "logs", hbbr["Id"])
        audits = db.execute("SELECT result,error_message,before_data,after_data,action FROM operation_audit WHERE resource_type='rustdesk_admission' AND resource_id IN (?,?)",
                            (m["source"], m["target"])).fetchall()
        audit_counts = {action: sum(row[0] == "allow" and row[4] == action for row in audits) for action in
                        ("rustdesk_internal_relay_grant_issue", "rustdesk_internal_relay_grant_consume")}
        require(audit_counts["rustdesk_internal_relay_grant_issue"] == 3
                and audit_counts["rustdesk_internal_relay_grant_consume"] == 6, "缺少三次签发或六次核销允许审计")
        require(all(t.encode() not in logs and all(t not in str(row) for row in audits) for t in tokens), "测试令牌泄漏到审计或日志")
        current = [json.loads(command("docker", "inspect", v["Id"]))[0] for v in infos]
        require([(v["Id"], v["State"]["StartedAt"]) for v in current] == baseline
                and all(v["State"]["Health"]["Status"] == "healthy" for v in current), "验收期间现用服务发生变更")
        (backup / "result.json").write_text(json.dumps({"time": datetime.now().isoformat(), "rounds": results,
            "synthetic_identities": True, "independent_external_peers": False, "browser_remote_desktop": False,
            "containers_unchanged": True, "audit_allow": len([v for v in audits if v[0] == "allow"]),
            "audit_counts": audit_counts}, indent=2))
    finally:
        db.close()
        if not awaiting_external:
            cleanup(backup)
            command("systemctl", "stop", unit + ".timer")
            print("本轮身份已精确清理，原账号与服务未回退；证据保留：" + str(backup), flush=True)


if __name__ == "__main__":
    try:
        require(len(sys.argv) == 3 and sys.argv[1] in ("--run", "--prepare-external", "--collect-external", "--cleanup"), "用法：--run/--prepare-external 部署目录 或 --collect-external/--cleanup 备份目录")
        root = Path(sys.argv[2]).resolve()
        if sys.argv[1] == "--cleanup":
            cleanup(root)
        elif sys.argv[1] == "--collect-external":
            collect_external(root)
        else:
            run(root, external=sys.argv[1] == "--prepare-external")
    except Exception as exc:
        # 不透传外部命令、SQL 或协议异常中的潜在凭据。
        print(str(exc) if isinstance(exc, RuntimeError) and str(exc).startswith("ERR-239D ") else "ERR-239D 现用 WSS 验收失败，请检查 root 私有备份与自动清理状态", file=sys.stderr)
        sys.exit(1)
