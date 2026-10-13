#!/usr/bin/env python3
"""只读备份原 SQLite，在无网络容器内演练迁移并验证数据保留。"""

import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile


def require(condition, message):
    """统一输出错误码，禁止携带数据库行和工具原始输出。"""
    if not condition:
        raise RuntimeError("ERR-239D " + message)


def quoted(name):
    """引用 SQLite 自身提供的表名和列名。"""
    return '"' + name.replace('"', '""') + '"'


def interrupted(signum, _frame):
    """让可处理的中断进入容器和私有副本清理流程。"""
    raise RuntimeError("ERR-239D 迁移演练收到中断信号：" + str(signum))


def verify(original, migrated):
    """比对所有原表的原字段，仅允许令牌脱敏与新增准入字段。"""
    require(migrated.execute("PRAGMA quick_check").fetchone() == ("ok",), "迁移副本完整性检查失败")
    tables = [row[0] for row in original.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
    require({"user", "device", "auth_token"}.issubset(tables), "原库缺少必要业务表")
    for table in tables:
        columns = [row[1] for row in original.execute("PRAGMA table_info(" + quoted(table) + ")")]
        if table == "auth_token":
            columns = [name for name in columns if name not in ("token", "token_hash")]
        select = "SELECT " + ",".join(map(quoted, columns)) + " FROM " + quoted(table)
        require(sorted(map(repr, original.execute(select))) == sorted(map(repr, migrated.execute(select))),
                "迁移副本未保留原表字段或数据：" + table)
    original.row_factory = sqlite3.Row
    try:
        tokens = original.execute("SELECT * FROM auth_token").fetchall()
        for row in tokens:
            raw = row["token"] or ""
            digest = (row["token_hash"] if "token_hash" in row.keys() else "") or ""
            expected = digest or (hashlib.sha256(raw.encode()).hexdigest() if raw else "")
            current = migrated.execute("SELECT token,token_hash FROM auth_token WHERE id=?", (row["id"],)).fetchone()
            require(current is not None and not current[0] and (current[1] or "") == expected,
                    "迁移副本残留明文令牌或改变已有摘要")
    finally:
        original.row_factory = None
    old_columns = {row[1] for row in original.execute("PRAGMA table_info(device)")}
    trusted = "SELECT count(*) FROM device WHERE approval_status='approved'"
    before = original.execute(trusted).fetchone()[0] if "approval_status" in old_columns else 0
    require(migrated.execute(trusted).fetchone()[0] == before, "迁移意外增加已审批设备")
    return len(tables)


def verify_restored(original, restored):
    """恢复必须使用迁移前快照，完整保留原 schema 和记录。"""
    require(restored.execute("PRAGMA quick_check").fetchone() == ("ok",), "回滚副本完整性检查失败")
    require(list(original.iterdump()) == list(restored.iterdump()), "回滚副本与迁移前快照不一致")


def health_command(program):
    """在无网络容器内检查程序存活和本机健康接口。"""
    return ("export PORT=12345 ADMIN_PORT=12346; " + program + " start & pid=$!; "
            "trap 'kill \"$pid\" 2>/dev/null || true; wait \"$pid\" 2>/dev/null || true' EXIT; "
            "for attempt in $(seq 1 30); do kill -0 \"$pid\" || exit 1; "
            "if wget -q -T 1 -O /dev/null http://127.0.0.1:12345/api/health; then exit 0; fi; sleep 1; done; exit 1")


def rehearse(source, binary, image, legacy_config=None, rollback_binary=None):
    """备份始终只读，容器只挂载副本，退出后销毁副本及临时容器。"""
    require(sys.platform == "linux" and os.geteuid() == 0, "请在授权 Linux Docker 主机以 root 执行")
    source, binary = Path(source), Path(binary)
    require(source.is_file() and not source.is_symlink(), "原数据库路径无效")
    require(binary.is_file() and not binary.is_symlink(), "迁移程序路径无效")
    if legacy_config is not None:
        legacy_config = Path(legacy_config)
        require(legacy_config.is_file() and not legacy_config.is_symlink(), "旧配置路径无效")
    if rollback_binary is not None:
        require(legacy_config is not None, "回滚启动演练必须提供旧配置")
        rollback_binary = Path(rollback_binary)
        require(rollback_binary.is_file() and not rollback_binary.is_symlink(), "原版程序路径无效")
        with rollback_binary.open("rb") as stream:
            require(stream.read(4) == b"\x7fELF", "原版程序不是 Linux ELF")
    with binary.open("rb") as stream:
        require(stream.read(4) == b"\x7fELF", "迁移程序不是 Linux ELF")
    inspected = subprocess.run(["docker", "image", "inspect", image], capture_output=True, timeout=15)
    require(inspected.returncode == 0, "找不到已有 API 镜像")
    require("CONTROLLED_API_ONLY=1" in json.loads(inspected.stdout)[0]["Config"].get("Env", []), "需要专用 API 镜像")
    name = "rustdesk-controlled-migration-" + secrets.token_hex(8)
    mask = os.umask(0o077)
    try:
        with tempfile.TemporaryDirectory(prefix="rustdesk-controlled-migration-") as directory:
            root = Path(directory)
            work = root / "work"
            work.mkdir()
            snapshot = root / "snapshot.db"
            with sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True, timeout=10) as live:
                with sqlite3.connect(snapshot) as backup:
                    live.backup(backup)
            snapshot_hash = hashlib.sha256(snapshot.read_bytes()).digest()
            shutil.copy2(snapshot, work / "server.db")
            if legacy_config is not None:
                shutil.copy2(legacy_config, work / "server.yaml")
            args = ["docker", "run", "--rm", "--pull=never", "--name", name, "--network", "none", "--read-only",
                    "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--tmpfs", "/tmp:rw,nosuid,nodev,size=64m",
                    "--mount", "type=bind,src=" + str(binary.resolve()) + ",dst=/app/migration-binary,readonly",
                    "--mount", "type=bind,src=" + str(work) + ",dst=/app/data", "--workdir", "/app/data",
                    "--entrypoint", "sh", image, "-ec",
                    ("cp /app/server.yaml ./server.yaml; grep -Eq '^[[:space:]]*showSql: false' server.yaml; "
                     if legacy_config is None else "") + "/app/migration-binary sync"]
            for attempt in range(2):
                try:
                    result = subprocess.run(args, capture_output=True, timeout=90)
                finally:
                    subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=15)
                require(result.returncode == 0, "隔离副本迁移失败，原库未修改")
                with sqlite3.connect(snapshot) as original, sqlite3.connect(work / "server.db") as migrated:
                    count = verify(original, migrated)
                print("PASS: " + ("首次迁移" if attempt == 0 else "重复迁移") + "保留 " + str(count) + " 张原表数据，令牌脱敏且无新增已审批设备")
            if legacy_config is not None:
                # 原配置仅留在私有副本；无网络、只读根目录防止外部数据库和认证服务被访问。
                startup = args[:-1] + [health_command("/app/migration-binary")]
                try:
                    result = subprocess.run(startup, capture_output=True, timeout=50)
                finally:
                    subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=15)
                require(result.returncode == 0, "原配置副本启动或健康检查失败，原服务未修改")
                require((work / "server.yaml").read_bytes() == legacy_config.read_bytes(), "原配置副本被意外改写")
                print("PASS: 原配置与迁移库副本在无网络容器启动，健康检查通过，配置内容未改写")
            if rollback_binary is not None:
                rollback = root / "rollback"
                rollback.mkdir()
                shutil.copy2(snapshot, rollback / "server.db")
                shutil.copy2(legacy_config, rollback / "server.yaml")
                with sqlite3.connect(snapshot) as original, sqlite3.connect(rollback / "server.db") as restored:
                    verify_restored(original, restored)
                replacements = {
                    "type=bind,src=" + str(binary.resolve()) + ",dst=/app/migration-binary,readonly":
                        "type=bind,src=" + str(rollback_binary.resolve()) + ",dst=/app/migration-binary,readonly",
                    "type=bind,src=" + str(work) + ",dst=/app/data":
                        "type=bind,src=" + str(rollback) + ",dst=/app/data",
                }
                rollback_args = [replacements.get(value, value) for value in startup]
                try:
                    result = subprocess.run(rollback_args, capture_output=True, timeout=50)
                finally:
                    subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=15)
                require(result.returncode == 0, "迁移前备份恢复后原版程序启动或健康检查失败")
                require((rollback / "server.yaml").read_bytes() == legacy_config.read_bytes(), "回滚副本配置被意外改写")
                require(hashlib.sha256(snapshot.read_bytes()).digest() == snapshot_hash, "迁移前备份被意外改写")
                print("PASS: 迁移前快照恢复到独立目录，原 schema/记录一致，原版程序无网络启动及健康检查通过")
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=15)
        os.umask(mask)
    print("PASS: 原库仅以只读方式打开，无网络临时容器与数据库副本已清理")


def self_test():
    """用内存夹具证明校验能识别数据丢失、明文残留和意外审批。"""
    with sqlite3.connect(":memory:") as original, sqlite3.connect(":memory:") as migrated:
        original.executescript("CREATE TABLE user(id INTEGER, name TEXT); INSERT INTO user VALUES(1,'fixture'); CREATE TABLE device(id INTEGER); INSERT INTO device VALUES(1); CREATE TABLE auth_token(id INTEGER, token TEXT); INSERT INTO auth_token VALUES(1,'fixture-token');")
        original.backup(migrated)
        migrated.executescript("ALTER TABLE device ADD approval_status TEXT; ALTER TABLE auth_token ADD token_hash TEXT;")
        migrated.execute("UPDATE auth_token SET token='',token_hash=?", (hashlib.sha256(b"fixture-token").hexdigest(),))
        require(verify(original, migrated) == 3, "正确副本校验失败")
        for sql, restore in (
            ("UPDATE user SET name='changed'", "UPDATE user SET name='fixture'"),
            ("UPDATE auth_token SET token='leaked'", "UPDATE auth_token SET token=''"),
            ("UPDATE device SET approval_status='approved'", "UPDATE device SET approval_status=NULL"),
        ):
            migrated.execute(sql)
            try:
                verify(original, migrated)
            except RuntimeError:
                pass
            else:
                raise RuntimeError("ERR-239D 错误迁移结果未被拒绝")
            migrated.execute(restore)
    print("PASS: 迁移比对自检拒绝数据变更、明文残留及自动审批")
    with sqlite3.connect(":memory:") as original, sqlite3.connect(":memory:") as restored:
        original.executescript("CREATE TABLE fixture(id INTEGER, value TEXT); INSERT INTO fixture VALUES(1,'before');")
        original.backup(restored)
        verify_restored(original, restored)
        for sql in ("UPDATE fixture SET value='after'", "ALTER TABLE fixture ADD migrated TEXT"):
            restored.commit()
            original.backup(restored)
            restored.execute(sql)
            try:
                verify_restored(original, restored)
            except RuntimeError:
                pass
            else:
                raise RuntimeError("ERR-239D 回滚校验未拒绝数据或 schema 变更")
    print("PASS: 回滚快照自检拒绝记录及 schema 差异")


if __name__ == "__main__":
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        else:
            require(len(sys.argv) == 4 or (len(sys.argv) in (6, 8) and sys.argv[4] == "--legacy-config"
                    and (len(sys.argv) == 6 or sys.argv[6] == "--rollback-binary")),
                    "用法：controlled-sqlite-migration-rehearsal.py <原 SQLite> <新 Linux 程序> <API 镜像> [--legacy-config <旧 YAML> [--rollback-binary <原版 Linux 程序>]]|--self-test")
            rehearse(*sys.argv[1:4], legacy_config=sys.argv[5] if len(sys.argv) >= 6 else None,
                     rollback_binary=sys.argv[7] if len(sys.argv) == 8 else None)
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError) else "ERR-239D 迁移演练失败：" + type(error).__name__, file=sys.stderr)
        sys.exit(1)
