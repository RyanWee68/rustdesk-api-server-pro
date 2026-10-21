#!/usr/bin/env python3
"""使用内存数据库验证现用 WSS 夹具的清理边界，不访问目标主机。"""

import base64
import contextlib
from datetime import datetime, timedelta, timezone
import io
import json
from contextlib import closing
from importlib import import_module
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True
live = import_module("controlled-live-wss-acceptance")


class CleanupTests(unittest.TestCase):
    """保护真实身份、审计和与测试无关的中继授权。"""

    def setUp(self):
        """建立最小表结构及一个真实用户和一个本轮夹具。"""
        run = "a" * 32
        self.m = {"run": run, "username": "wss-live-" + run, "source": "wss-source-" + run,
                  "target": "987654321", "device_uuid": base64.b64encode(bytes(16)).decode(),
                  "peer": "controlled-live-wss-" + run}
        self.db = sqlite3.connect(":memory:")
        self.addCleanup(self.db.close)
        self.db.executescript("""
CREATE TABLE user(id INTEGER PRIMARY KEY, username TEXT UNIQUE);
CREATE TABLE device(rustdesk_id TEXT PRIMARY KEY, uuid TEXT, user_id INTEGER);
CREATE TABLE auth_token(id INTEGER PRIMARY KEY, user_id INTEGER, rustdesk_id TEXT);
CREATE TABLE rustdesk_relay_grant(source_id TEXT,target_id TEXT);
CREATE TABLE operation_audit(resource_id TEXT,result TEXT);
INSERT INTO user VALUES(1,'admin');
INSERT INTO device VALUES('443005947','real-uuid',1);
INSERT INTO auth_token VALUES(1,1,'443005947');
INSERT INTO rustdesk_relay_grant VALUES('487921466','443005947');
INSERT INTO operation_audit VALUES('987654321','allow');
""")
        with self.db:
            self.db.execute("INSERT INTO user VALUES(2,?)", (self.m["username"],))
            for ident, uid in ((self.m["source"], run), (self.m["target"], self.m["device_uuid"])):
                self.db.execute("INSERT INTO device VALUES(?,?,2)", (ident, uid))
                self.db.execute("INSERT INTO auth_token(user_id,rustdesk_id) VALUES(2,?)", (ident,))
            self.db.execute("INSERT INTO rustdesk_relay_grant VALUES(?,?)", (self.m["source"], self.m["target"]))

    def test_cleanup_is_scoped_and_idempotent(self):
        """重复清理只删除本轮身份，保留真实数据与验收审计。"""
        for _ in range(2):
            live.delete_rows(self.db, self.m)
        self.assertEqual(self.db.execute("SELECT * FROM user").fetchall(), [(1, "admin")])
        self.assertEqual(self.db.execute("SELECT * FROM device").fetchall(), [("443005947", "real-uuid", 1)])
        self.assertEqual(self.db.execute("SELECT * FROM auth_token").fetchall(), [(1, 1, "443005947")])
        self.assertEqual(self.db.execute("SELECT * FROM rustdesk_relay_grant").fetchall(), [("487921466", "443005947")])
        self.assertEqual(self.db.execute("SELECT count(*) FROM operation_audit").fetchone(), (1,))

    def test_changed_identity_fails_before_any_deletion(self):
        """测试用户关联了非夹具设备时禁止部分清理。"""
        with self.db:
            self.db.execute("INSERT INTO device VALUES('real-extra','real-uuid',2)")
        with self.assertRaisesRegex(RuntimeError, "ERR-239D"):
            live.delete_rows(self.db, self.m)
        self.assertEqual(self.db.execute("SELECT count(*) FROM auth_token").fetchone(), (3,))
        self.assertEqual(self.db.execute("SELECT count(*) FROM user").fetchone(), (2,))

    def test_changed_uuid_fails_closed(self):
        """编号相同但 UUID 不匹配时禁止删除。"""
        with self.db:
            self.db.execute("UPDATE device SET uuid='changed' WHERE rustdesk_id=?", (self.m["target"],))
        with self.assertRaisesRegex(RuntimeError, "ERR-239D"):
            live.delete_rows(self.db, self.m)
        self.assertEqual(self.db.execute("SELECT count(*) FROM device").fetchone(), (3,))

    def test_unrelated_token_fails_before_deletion(self):
        """已有非夹具令牌时不删除账号或部分夹具记录。"""
        with self.db:
            self.db.execute("INSERT INTO auth_token(user_id,rustdesk_id) VALUES(2,'real-extra')")
        with self.assertRaisesRegex(RuntimeError, "ERR-239D"):
            live.delete_rows(self.db, self.m)
        self.assertEqual(self.db.execute("SELECT count(*) FROM user").fetchone(), (2,))
        self.assertEqual(self.db.execute("SELECT count(*) FROM auth_token").fetchone(), (4,))

    def test_external_window_has_time_for_manual_acceptance(self):
        """人工窗口为 45 分钟，配置提前一分钟失效且保护失败不创建身份。"""
        for timer_state in (b"active", b"inactive"):
            with self.subTest(timer=timer_state), tempfile.TemporaryDirectory(prefix="controlled-wss-window-") as directory:
                root = Path(directory).resolve()
                (root / "data/tls").mkdir(parents=True)
                (root / "backups").mkdir()
                keys = root / "keys"
                keys.mkdir()
                (keys / "id_ed25519.pub").write_text(base64.b64encode(bytes(32)).decode())
                (root / "data/tls/rustdesk.jtzxsoft.com.fullchain.pem").write_text("fixture")
                for name in ("compose.yaml", "runtime.env"):
                    (root / name).write_text("fixture")
                with closing(sqlite3.connect(root / "data/server.db")) as db:
                    db.executescript("""
CREATE TABLE user(id INTEGER PRIMARY KEY,username TEXT,password TEXT,status INTEGER,is_admin INTEGER,allow_remote_access INTEGER,allow_relay INTEGER);
CREATE TABLE device(rustdesk_id TEXT,user_id INTEGER,uuid TEXT,fingerprint TEXT,approval_status TEXT,disabled INTEGER,allow_relay INTEGER);
CREATE TABLE auth_token(user_id INTEGER,rustdesk_id TEXT,uuid TEXT,token TEXT,token_hash TEXT,expired TEXT,is_admin INTEGER,status INTEGER);
CREATE TABLE operation_audit(id INTEGER PRIMARY KEY);
""")
                with closing(sqlite3.connect(keys / "db_v2.sqlite3")) as db:
                    db.execute("CREATE TABLE peer(id TEXT)")
                infos = {}
                for name in ("rustdesk-api-server-pro", "rustdesk-hbbs-controlled", "rustdesk-hbbr-controlled"):
                    infos[name] = {"Id": name, "State": {"Running": True, "Health": {"Status": "healthy"}, "StartedAt": "fixture"},
                                   "Config": {"Labels": {"com.docker.compose.project": "fixture"}},
                                   "NetworkSettings": {"Networks": {"fixture_rustdesk-control": {}}}, "Mounts": []}
                infos["rustdesk-api-server-pro"]["Mounts"] = [{"Destination": "/app/data", "Source": str(root / "data")}]
                infos["rustdesk-hbbs-controlled"]["Mounts"] = [{"Destination": "/data", "Source": str(keys), "Type": "volume"}]

                def command(*args):
                    """仅模拟本轮准备阶段允许调用的 Docker 查询与保护定时器。"""
                    if args[:2] == ("docker", "inspect"):
                        return json.dumps([infos[args[2]]]).encode()
                    if args[0] == "systemd-run":
                        self.assertIn("--on-active=45m", args)
                        return b""
                    if args[:2] == ("systemctl", "is-active"):
                        return timer_state
                    self.fail("出现预期外命令")

                before = datetime.now(timezone.utc)
                with patch.object(live.os, "geteuid", return_value=0, create=True), \
                        patch.object(live, "ZoneInfo", side_effect={"Asia/Shanghai": timezone(timedelta(hours=8)), "UTC": timezone.utc}.__getitem__), \
                        patch.object(live, "command", side_effect=command), \
                        patch.object(live.wss, "public_acceptance") as public, \
                        patch.object(live, "cleanup") as cleanup, contextlib.redirect_stdout(io.StringIO()):
                    if timer_state == b"active":
                        live.run(root, external=True)
                    else:
                        with self.assertRaisesRegex(RuntimeError, "ERR-239D"):
                            live.run(root, external=True)
                    public.assert_called_once()
                    cleanup.assert_not_called()
                after = datetime.now(timezone.utc)
                backup, = (root / "backups").iterdir()
                with closing(sqlite3.connect(root / "data/server.db")) as db:
                    self.assertEqual(db.execute("SELECT count(*) FROM user").fetchone()[0], 1 if timer_state == b"active" else 0)
                    self.assertEqual(db.execute("SELECT count(*) FROM auth_token").fetchone()[0], 2 if timer_state == b"active" else 0)
                if timer_state == b"inactive":
                    self.assertFalse((backup / "source.json").exists())
                    continue
                configs = [json.loads((backup / name).read_text()) for name in ("source.json", "target.json", "external-window.json")]
                expires = datetime.fromisoformat(configs[0]["expires_utc"])
                self.assertGreaterEqual(expires, before + timedelta(minutes=44))
                self.assertLessEqual(expires, after + timedelta(minutes=44))
                self.assertTrue(all(config["expires_utc"] == configs[0]["expires_utc"] for config in configs))
                self.assertEqual([config["role"] for config in configs[:2]], ["source", "target"])

    def test_probe_process_is_reaped_on_failure(self):
        """成功不误杀，超时和通信异常均回收仍运行的子进程。"""
        child = Mock()
        child.communicate.return_value = (b"ok", b"")
        child.poll.return_value = 0
        self.assertEqual(live.communicate_peer(child, b"private-input"), (b"ok", b""))
        child.kill.assert_not_called()
        child.communicate.assert_called_once_with(b"private-input", timeout=12)
        for error in (subprocess.TimeoutExpired("probe", 12), BrokenPipeError("selftest")):
            with self.subTest(error=type(error).__name__):
                child = Mock()
                child.poll.return_value = None
                child.communicate.side_effect = [error, (b"", b"")]
                with self.assertRaises(type(error)):
                    live.communicate_peer(child, b"private-input")
                child.kill.assert_called_once_with()
                self.assertEqual(child.communicate.call_count, 2)
                self.assertEqual(child.communicate.call_args.kwargs, {"timeout": 5})

    def test_real_probe_timeout_leaves_no_child_or_open_pipes(self):
        """用本机休眠子进程验证终止、等待和管道关闭，不访问网络。"""
        child = subprocess.Popen([sys.executable, "-B", "-c", "import time; time.sleep(60)"],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        communicate = child.communicate
        first = True

        def brief_timeout(*args, **kwargs):
            """仅缩短测试首轮等待，回收仍沿用真实五秒上限。"""
            nonlocal first
            if first:
                first = False
                kwargs["timeout"] = 0.05
            return communicate(*args, **kwargs)

        try:
            with patch.object(child, "communicate", side_effect=brief_timeout):
                with self.assertRaises(subprocess.TimeoutExpired):
                    live.communicate_peer(child, b"fixture")
            self.assertIsNotNone(child.poll())
            self.assertTrue(child.stdout.closed and child.stderr.closed)
        finally:
            if child.poll() is None:
                child.kill()
            communicate(timeout=5)

    def test_container_absence_must_be_confirmed(self):
        """查询失败、仍存在、超时和标签冲突都不能触发容器删除。"""
        missing = subprocess.CompletedProcess([], 1, b"", b"private-error")
        with patch.object(live.subprocess, "run", return_value=missing) as inspect:
            with patch.object(live, "command", return_value=b"") as command:
                live.remove_fixture_container(self.m)
                self.assertEqual(command.call_args.args[:3], ("docker", "ps", "-a"))
                self.assertEqual(inspect.call_args.kwargs["timeout"], 15)
            for result in (b"still-present", RuntimeError("ERR-239D Docker 不可用")):
                with self.subTest(result=type(result).__name__), patch.object(live, "command") as command:
                    if isinstance(result, Exception):
                        command.side_effect = result
                    else:
                        command.return_value = result
                    with self.assertRaisesRegex(RuntimeError, "ERR-239D"):
                        live.remove_fixture_container(self.m)
                    self.assertEqual(command.call_count, 1)
        for run_id in (self.m["run"], "unrelated"):
            found = subprocess.CompletedProcess([], 0, json.dumps([{"Config": {"Labels": {"controlled.wss.run": run_id}}}]).encode())
            with patch.object(live.subprocess, "run", return_value=found), patch.object(live, "command") as command:
                if run_id == self.m["run"]:
                    live.remove_fixture_container(self.m)
                    command.assert_called_once_with("docker", "rm", "-f", self.m["peer"])
                else:
                    with self.assertRaisesRegex(RuntimeError, "ERR-239D"):
                        live.remove_fixture_container(self.m)
                    command.assert_not_called()
        with patch.object(live.subprocess, "run", side_effect=subprocess.TimeoutExpired("docker", 15)), \
                patch.object(live, "command") as command:
            with self.assertRaises(subprocess.TimeoutExpired):
                live.remove_fixture_container(self.m)
            command.assert_not_called()

    def test_backup_escapes_path_and_closes_connections(self):
        """空格和井号不改变 URI，成功与失败均关闭连接。"""
        with tempfile.TemporaryDirectory(prefix="controlled-wss-backup-") as directory:
            source = Path(directory) / "source #1.sqlite3"
            target = Path(directory) / "copy.sqlite3"
            with closing(sqlite3.connect(source)) as db:
                with db:
                    db.execute("CREATE TABLE fixture(id INTEGER)")
                    db.execute("INSERT INTO fixture VALUES(7)")
            connect = sqlite3.connect
            for failure in (False, True):
                connections = []

                def tracked_connect(*args, **kwargs):
                    """保留连接引用，确认备份函数显式关闭而非依赖回收。"""
                    if failure and connections:
                        raise sqlite3.OperationalError("selftest")
                    connection = connect(*args, **kwargs)
                    connections.append(connection)
                    return connection

                with patch.object(live.sqlite3, "connect", side_effect=tracked_connect):
                    if failure:
                        with self.assertRaises(sqlite3.OperationalError):
                            live.backup_database(source, target)
                    else:
                        live.backup_database(source, target)
                for connection in connections:
                    with self.assertRaises(sqlite3.ProgrammingError):
                        connection.execute("SELECT 1")
            with closing(connect(target)) as db:
                self.assertEqual(db.execute("SELECT * FROM fixture").fetchall(), [(7,)])
            with patch.object(live.time, "monotonic", side_effect=[0, 61]):
                with self.assertRaisesRegex(RuntimeError, "ERR-239D.*超时"):
                    live.backup_database(source, target)

    def test_manifest_rejects_non_fixture_identity(self):
        """拒绝普通账户、容器及路径注入式标识。"""
        for key, value in (("run", "../admin"), ("username", "admin"), ("source", "487921466"),
                           ("target", "443005947 OR 1=1"), ("peer", "rustdesk-hbbs-controlled"),
                           ("device_uuid", base64.b64encode(bytes(15)).decode())):
            with self.subTest(key=key), self.assertRaisesRegex(RuntimeError, "ERR-239D"):
                live.delete_rows(self.db, {**self.m, key: value})
        self.assertEqual(self.db.execute("SELECT count(*) FROM user").fetchone(), (2,))

    def test_external_evidence_requires_both_roles_and_audits(self):
        """不把半核销、同出口或只有关闭现象记为真实授权通过。"""
        self.db.executescript("""
ALTER TABLE rustdesk_relay_grant ADD COLUMN session_uuid TEXT;
ALTER TABLE rustdesk_relay_grant ADD COLUMN source_ip TEXT;
ALTER TABLE rustdesk_relay_grant ADD COLUMN target_ip TEXT;
ALTER TABLE rustdesk_relay_grant ADD COLUMN source_used INTEGER;
ALTER TABLE rustdesk_relay_grant ADD COLUMN target_used INTEGER;
ALTER TABLE operation_audit ADD COLUMN id INTEGER;
ALTER TABLE operation_audit ADD COLUMN action TEXT;
ALTER TABLE operation_audit ADD COLUMN resource_type TEXT;
ALTER TABLE operation_audit ADD COLUMN error_message TEXT;
ALTER TABLE operation_audit ADD COLUMN before_data TEXT;
DELETE FROM rustdesk_relay_grant;
""")
        with self.db:
            for index in range(3):
                self.db.execute("INSERT INTO rustdesk_relay_grant VALUES(?,?,?,?,?,1,1)",
                                (self.m["source"], self.m["target"], str(index), "203.0.113.1", "198.51.100.2"))
                for action, count in (("rustdesk_internal_relay_grant_issue", 1), ("rustdesk_internal_relay_grant_consume", 2)):
                    for _ in range(count):
                        self.db.execute("INSERT INTO operation_audit VALUES(?,'allow',1,?,'rustdesk_admission','','{}')", (self.m["target"], action))
                for peer in ("203.0.113.1", "198.51.100.2"):
                    self.db.execute("INSERT INTO operation_audit VALUES('','deny',1,'rustdesk_internal_relay_grant_consume','rustdesk_admission','ERR-2315',?)", (json.dumps({"peer_ip": "::ffff:" + peer if peer == "203.0.113.1" else peer}),))
        result = live.external_evidence(self.db, self.m, 0)
        self.assertFalse(result["external_network_human_confirmation"])
        self.assertEqual(len(result["sessions"]), 3)
        for sql in ("UPDATE rustdesk_relay_grant SET target_used=0", "UPDATE rustdesk_relay_grant SET target_ip=source_ip",
                    "DELETE FROM operation_audit WHERE result='deny'", "DELETE FROM operation_audit WHERE action='rustdesk_internal_relay_grant_issue'"):
            with self.subTest(sql=sql):
                self.db.execute("SAVEPOINT failure")
                self.db.execute(sql)
                with self.assertRaisesRegex(RuntimeError, "ERR-239D"):
                    live.external_evidence(self.db, self.m, 0)
                self.db.execute("ROLLBACK TO failure")
                self.db.execute("RELEASE failure")


if __name__ == "__main__":
    unittest.main()
