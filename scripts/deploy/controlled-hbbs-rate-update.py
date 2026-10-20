#!/usr/bin/env python3
"""单独更新 hbbs 或 API 镜像，先备份并安排独立回滚，不回退业务数据库。"""

import copy
from contextlib import closing
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import uuid

SERVICE = "rustdesk-hbbs"
API_SERVICE = "rustdesk-api-server-pro"


def require(ok, message):
    """拒绝越界更新并隐藏潜在敏感命令输出。"""
    if not ok:
        raise RuntimeError("ERR-239D " + message)


def command(*args, timeout=60):
    """有界执行固定管理命令，不回显环境或 Compose 内容。"""
    try:
        result = subprocess.run(args, capture_output=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        raise RuntimeError("ERR-239D 管理命令不可用或超时，请检查私有备份与回滚状态") from None
    require(result.returncode == 0, "管理命令失败，请检查私有备份和系统日志")
    return result.stdout


def replace_image(config, expected, replacement, service=SERVICE):
    """并发变更时拒绝覆盖，仅替换指定服务的预期镜像。"""
    require(service in (SERVICE, API_SERVICE), "服务不在更新范围内")
    require(config["services"][service]["image"] == expected, "服务已被其他更新修改，拒绝覆盖")
    updated = copy.deepcopy(config)
    updated["services"][service]["image"] = replacement
    return updated


def save_compose(path, config):
    """用同目录替换保留当前 Compose 的其他服务和权限。"""
    require(not path.is_symlink() and path.is_file(), "Compose 必须为普通文件")
    content = json.dumps(config, indent=2)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".compose.hbbs-rate-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, path.stat().st_mode & 0o777)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def candidate_id(details, old_id):
    """固定候选内容，防止标签在检查后被重新指向其他镜像。"""
    require(isinstance(details, list) and len(details) == 1 and isinstance(details[0], dict),
            "候选镜像检查结果无效")
    image_id = details[0].get("Id")
    require(isinstance(image_id, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", image_id) is not None,
            "候选镜像 ID 无效")
    require(image_id != old_id, "候选与现用镜像内容相同")
    return image_id


def restart(root, service=SERVICE):
    """只重建指定的受控服务，不重启其依赖。"""
    require(service in (SERVICE, API_SERVICE), "服务不在更新范围内")
    command("docker", "compose", "--project-directory", str(root), "--env-file", str(root / "runtime.env"),
            "-f", str(root / "compose.yaml"), "up", "-d", "--no-deps", "--pull", "never", service, timeout=180)


def backup_database(source, destination):
    """限制备份等待，数据库持续锁定时在切换前拒绝更新。"""
    deadline = time.monotonic() + 60

    def check_deadline(status, remaining, total):
        """持续写入或锁竞争不能无限延长更新前的备份。"""
        require(time.monotonic() < deadline, "数据库备份超时，未切换镜像")

    with closing(sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True)) as original:
        with closing(sqlite3.connect(destination)) as target:
            original.backup(target, pages=256, progress=check_deadline, sleep=0.05)
            require(target.execute("PRAGMA integrity_check").fetchone() == ("ok",), "备份完整性失败")


def rollback(backup):
    """恢复镜像而不恢复数据库，避免覆盖验收期间业务写入。"""
    require(backup.is_dir() and not backup.is_symlink() and backup.stat().st_uid == 0
            and backup.stat().st_mode & 0o077 == 0 and backup.parent.name == "backups", "备份目录必须 root 私有")
    manifest = json.loads((backup / "rate-update.json").read_text())
    service = manifest.get("service", SERVICE)
    require(service in (SERVICE, API_SERVICE), "备份服务不在更新范围内")
    root = backup.parent.parent
    path = root / "compose.yaml"
    config = json.loads(path.read_text())
    if config["services"][service]["image"] != manifest["old_image"]:
        save_compose(path, replace_image(config, manifest["candidate"], manifest["old_image"], service))
    restart(root, service)
    (backup / "rolled-back.json").write_text(json.dumps({"time": datetime.now().isoformat()}))


def stage(root, image, service=SERVICE):
    """备份一致性数据库、密钥与配置后开启四十五分钟回滚保护。"""
    require(os.geteuid() == 0 and root.is_dir(), "须由目标机 root 执行")
    os.umask(0o077)
    require(service in (SERVICE, API_SERVICE), "服务不在更新范围内")
    api = service == API_SERVICE
    config = json.loads((root / "compose.yaml").read_text())
    reference = config["services"][service]["image"]
    require(image.startswith("rustdesk-controlled-api:relay-race-" if api else "rustdesk-controlled-server:wss-rate-"), "候选镜像名称无效")
    candidate = json.loads(command("docker", "image", "inspect", image))
    info = json.loads(command("docker", "inspect", API_SERVICE if api else "rustdesk-hbbs-controlled"))[0]
    old = info["Config"]["Image"]
    require(image != old, "候选镜像已在使用")
    require(info["State"]["Health"]["Status"] == "healthy", "现用服务不健康")
    require(json.loads(command("docker", "image", "inspect", old))[0]["Id"] == info["Image"], "现用镜像与 Compose 不一致")
    resolved = json.loads(command("docker", "compose", "--project-directory", str(root),
                                  "--env-file", str(root / "runtime.env"), "-f", str(root / "compose.yaml"),
                                  "config", "--format", "json"))
    resolved_image = resolved["services"][service]["image"]
    require(json.loads(command("docker", "image", "inspect", resolved_image))[0]["Id"] == info["Image"],
            "Compose 解析后的镜像与现用容器不一致")
    pinned = candidate_id(candidate, info["Image"])
    key_dir = Path(next(v["Source"] for v in info["Mounts"] if v["Destination"] == ("/app/rustdesk-server" if api else "/data")))
    backup = root / "backups" / (("api-relay-" if api else "hbbs-rate-") + uuid.uuid4().hex)
    backup.mkdir(mode=0o700)
    for name in ("compose.yaml", "runtime.env"):
        shutil.copy2(root / name, backup / name)
    if api:
        shutil.copytree(root / "data/tls", backup / "tls")
    for name in ("id_ed25519", "id_ed25519.pub"):
        shutil.copy2(key_dir / name, backup / name)
    for source, name in ((root / "data/server.db", "api.sqlite3"), (key_dir / "db_v2.sqlite3", "server.sqlite3")):
        backup_database(source, backup / name)
    manifest = {"service": service, "old_image": info["Image"], "old_reference": reference, "candidate": pinned,
                "candidate_reference": image, "before_container": info["Id"],
                "other_containers": [[v["Id"], v["State"]["StartedAt"]] for v in
                    json.loads(command("docker", "inspect", "rustdesk-hbbs-controlled" if api else API_SERVICE, "rustdesk-hbbr-controlled"))],
                "certificate_sha256": hashlib.sha256((root / "data/tls/rustdesk.jtzxsoft.com.fullchain.pem").read_bytes()).hexdigest()}
    (backup / "rate-update.json").write_text(json.dumps(manifest))
    rollback_script = backup / "rollback.py"
    shutil.copyfile(Path(__file__).resolve(), rollback_script)
    os.chmod(rollback_script, 0o600)
    unit = "controlled-" + backup.name
    command("systemd-run", "--unit=" + unit, "--on-active=45m", "--timer-property=AccuracySec=1s",
            "--property=Type=oneshot", sys.executable, "-B", str(rollback_script), "--rollback", str(backup))
    require(command("systemctl", "is-active", unit + ".timer").strip() == b"active", "自动回滚未建立")
    print("保护已建立：" + str(backup), flush=True)
    try:
        current = json.loads((root / "compose.yaml").read_text())
        save_compose(root / "compose.yaml", replace_image(current, reference, pinned, service))
        restart(root, service)
    except Exception:
        rollback(backup)
        raise
    print("已切换 " + service + "；未取消回滚，待健康检查及人工验收", flush=True)


def self_test():
    """离线验证更新范围、固定镜像、失败清理与管理命令超时。"""
    from unittest.mock import patch
    import contextlib
    import io

    original = {"services": {SERVICE: {"image": "old", "ports": [22116]}, "api": {"image": "unchanged"}}}
    updated = replace_image(original, "old", "new")
    assert original["services"][SERVICE]["image"] == "old"
    assert updated["services"]["api"] == original["services"]["api"]
    assert updated["services"][SERVICE]["ports"] == [22116]
    assert replace_image(updated, "new", "old") == original
    try:
        replace_image(updated, "unexpected", "old")
    except RuntimeError:
        pass
    else:
        raise AssertionError("ERR-239D 未拒绝并发镜像变更")
    old_id, new_id = "sha256:" + "a" * 64, "sha256:" + "b" * 64
    assert candidate_id([{"Id": new_id}], old_id) == new_id
    for invalid in ([], [{"Id": "latest"}], [{"Id": old_id}], [{"Id": new_id}] * 2, [None]):
        try:
            candidate_id(invalid, old_id)
        except RuntimeError:
            pass
        else:
            raise AssertionError("ERR-239D 未拒绝无效或相同镜像")
    with tempfile.TemporaryDirectory(prefix="controlled-rate-selftest-") as directory:
        path = Path(directory) / "compose.yaml"
        path.write_text(json.dumps(original), encoding="utf-8")
        save_compose(path, updated)
        assert json.loads(path.read_text(encoding="utf-8")) == updated
        assert list(path.parent.iterdir()) == [path]
        with patch.object(os, "replace", side_effect=OSError("secret")):
            try:
                save_compose(path, original)
            except OSError:
                pass
            else:
                raise AssertionError("ERR-239D 未传播原子替换失败")
        assert json.loads(path.read_text(encoding="utf-8")) == updated
        assert list(path.parent.iterdir()) == [path]
    with patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, b"ok", b"secret")) as run:
        assert command("docker", "inspect") == b"ok"
        run.assert_called_once_with(("docker", "inspect"), capture_output=True, timeout=60)
    for failure in (OSError("secret"), subprocess.TimeoutExpired("secret", 60)):
        with patch.object(subprocess, "run", side_effect=failure):
            try:
                command("docker", "inspect")
            except RuntimeError as error:
                assert str(error).startswith("ERR-239D ") and "secret" not in str(error)
            else:
                raise AssertionError("ERR-239D 管理命令故障未拒绝")
    with patch(__name__ + ".command") as run:
        restart(Path("deployment"))
        assert run.call_args.kwargs == {"timeout": 180}
        assert run.call_args.args[-1] == SERVICE and "--no-deps" in run.call_args.args
    with tempfile.TemporaryDirectory(prefix="controlled-rate-stage-selftest-") as directory:
        root = Path(directory) / "deployment #1"
        root.mkdir()
        (root / "backups").mkdir()
        (root / "data/tls").mkdir(parents=True)
        keys = root / "keys"
        keys.mkdir()
        variable_config = copy.deepcopy(original)
        variable_config["services"][SERVICE]["image"] = "${SERVER_IMAGE}"
        (root / "compose.yaml").write_text(json.dumps(variable_config), encoding="utf-8")
        (root / "runtime.env").write_text("SERVER_IMAGE=old", encoding="utf-8")
        for name in ("id_ed25519", "id_ed25519.pub"):
            (keys / name).write_text("selftest-not-a-key", encoding="utf-8")
        (root / "data/tls/rustdesk.jtzxsoft.com.fullchain.pem").write_text("selftest-not-a-certificate", encoding="utf-8")
        for path in (root / "data/server.db", keys / "db_v2.sqlite3"):
            with closing(sqlite3.connect(path)) as db:
                db.execute("CREATE TABLE selftest(id INTEGER)")
        source = root / "data/server.db"
        with patch.object(time, "monotonic", side_effect=[0, 61]):
            try:
                backup_database(source, root / "expired.sqlite3")
            except RuntimeError as error:
                assert "ERR-239D" in str(error) and "超时" in str(error)
            else:
                raise AssertionError("ERR-239D 数据库备份超时未拒绝")
        with closing(sqlite3.connect(source)) as locked:
            locked.execute("BEGIN EXCLUSIVE")
            with patch.object(time, "monotonic", side_effect=[0, 61]):
                try:
                    backup_database(source, root / "locked.sqlite3")
                except RuntimeError as error:
                    assert "ERR-239D" in str(error) and "超时" in str(error)
                else:
                    raise AssertionError("ERR-239D 数据库锁等待未拒绝")
            locked.rollback()
        candidate_tag = "rustdesk-controlled-server:wss-rate-selftest"
        inspected = {"Config": {"Image": "old"}, "Image": old_id, "Id": "container-old",
                     "State": {"Health": {"Status": "healthy"}}, "Mounts": [{"Destination": "/data", "Source": str(keys)}]}
        resolved_config = copy.deepcopy(original)

        def fake_command(*args, **kwargs):
            """模拟 Docker/systemd，不发起任何真实管理命令。"""
            if args == ("docker", "image", "inspect", candidate_tag):
                return json.dumps([{"Id": new_id}]).encode()
            if args == ("docker", "inspect", "rustdesk-hbbs-controlled"):
                return json.dumps([inspected]).encode()
            if args == ("docker", "image", "inspect", "old"):
                return json.dumps([{"Id": old_id}]).encode()
            if args[-3:] == ("config", "--format", "json"):
                return json.dumps(resolved_config).encode()
            if args == ("docker", "inspect", "rustdesk-api-server-pro", "rustdesk-hbbr-controlled"):
                return json.dumps([{"Id": "other", "State": {"StartedAt": "unchanged"}}] * 2).encode()
            if args[0] == "systemd-run":
                snapshot = Path(args[-3])
                assert snapshot.name == "rollback.py" and snapshot.parent.parent == root / "backups"
                assert snapshot.read_bytes() == Path(__file__).read_bytes()
                return b""
            if args[:2] == ("systemctl", "is-active"):
                return b"active"
            raise AssertionError("ERR-239D 意外管理命令")

        with patch.object(os, "geteuid", return_value=0, create=True), patch.object(os, "umask"), \
                patch(__name__ + ".command", side_effect=fake_command), patch(__name__ + ".restart") as run, \
                contextlib.redirect_stdout(io.StringIO()):
            stage(root, candidate_tag)
        run.assert_called_once_with(root, SERVICE)
        result = json.loads((root / "compose.yaml").read_text(encoding="utf-8"))
        assert result["services"][SERVICE]["image"] == new_id
        assert result["services"]["api"] == original["services"]["api"]
        manifest_path = next((root / "backups").glob("*/rate-update.json"))
        manifest = json.loads(manifest_path.read_text())
        assert manifest["old_image"] == old_id and manifest["candidate"] == new_id
        assert manifest["old_reference"] == "${SERVER_IMAGE}" and manifest["candidate_reference"] == candidate_tag
        backup = manifest_path.parent
        real_stat = Path.stat

        def private_backup_stat(path, *args, **kwargs):
            """Windows 下仅模拟当前夹具备份目录的 Linux 所有者与权限。"""
            result = real_stat(path, *args, **kwargs)
            if path == backup:
                values = list(result)
                values[0], values[4] = 0o40700, 0
                return os.stat_result(values)
            return result

        with patch.object(Path, "stat", private_backup_stat), patch(__name__ + ".restart") as run:
            rollback(backup)
            run.assert_called_once_with(root, SERVICE)
            assert json.loads((root / "compose.yaml").read_text())["services"][SERVICE]["image"] == old_id
            legacy = {**manifest, "old_image": "old", "candidate": candidate_tag}
            legacy.pop("service", None)
            manifest_path.write_text(json.dumps(legacy))
            changed = copy.deepcopy(variable_config)
            changed["services"][SERVICE]["image"] = candidate_tag
            save_compose(root / "compose.yaml", changed)
            rollback(backup)
            assert json.loads((root / "compose.yaml").read_text())["services"][SERVICE]["image"] == "old"
            changed["services"][SERVICE]["image"] = "newer-update"
            save_compose(root / "compose.yaml", changed)
            run.reset_mock()
            try:
                rollback(backup)
            except RuntimeError:
                pass
            else:
                raise AssertionError("ERR-239D 回滚覆盖了后续更新")
            run.assert_not_called()
            assert json.loads((root / "compose.yaml").read_text()) == changed
        resolved_config["services"][SERVICE]["image"] = candidate_tag
        before = (root / "compose.yaml").read_bytes()
        with patch.object(os, "geteuid", return_value=0, create=True), patch.object(os, "umask"), \
                patch(__name__ + ".command", side_effect=fake_command), patch(__name__ + ".restart") as run:
            try:
                stage(root, candidate_tag)
            except RuntimeError:
                pass
            else:
                raise AssertionError("ERR-239D 未拒绝 Compose 与容器的镜像漂移")
        run.assert_not_called()
        assert (root / "compose.yaml").read_bytes() == before
        assert list((root / "backups").iterdir()) == [backup]
        resolved_config["services"][SERVICE]["image"] = "old"
        save_compose(root / "compose.yaml", variable_config)
        before = (root / "compose.yaml").read_bytes()
        with patch.object(os, "geteuid", return_value=0, create=True), patch.object(os, "umask"), \
                patch(__name__ + ".command", side_effect=fake_command) as commands, \
                patch(__name__ + ".backup_database", side_effect=RuntimeError("ERR-239D 数据库备份超时")), \
                patch(__name__ + ".restart") as run:
            try:
                stage(root, candidate_tag)
            except RuntimeError:
                pass
            else:
                raise AssertionError("ERR-239D 备份失败仍执行更新")
        run.assert_not_called()
        assert not any(call.args[0] == "systemd-run" for call in commands.call_args_list)
        assert (root / "compose.yaml").read_bytes() == before

        def inactive_timer(*args, **kwargs):
            """保护任务未活动时返回失败状态，不执行真实 systemd。"""
            if args[:2] == ("systemctl", "is-active"):
                return b"inactive"
            return fake_command(*args, **kwargs)

        with patch.object(os, "geteuid", return_value=0, create=True), patch.object(os, "umask"), \
                patch(__name__ + ".command", side_effect=inactive_timer), patch(__name__ + ".restart") as run:
            try:
                stage(root, candidate_tag)
            except RuntimeError:
                pass
            else:
                raise AssertionError("ERR-239D 未建立保护仍执行更新")
        run.assert_not_called()
        assert (root / "compose.yaml").read_bytes() == before
        with patch.object(os, "geteuid", return_value=0, create=True), patch.object(os, "umask"), \
                patch(__name__ + ".command", side_effect=fake_command), \
                patch(__name__ + ".restart", side_effect=RuntimeError("ERR-239D selftest")), \
                patch(__name__ + ".rollback") as restore, contextlib.redirect_stdout(io.StringIO()):
            try:
                stage(root, candidate_tag)
            except RuntimeError:
                pass
            else:
                raise AssertionError("ERR-239D 重建失败未传播")
        restore.assert_called_once()
        assert restore.call_args.args[0].parent == root / "backups"

        api_config = {"services": {API_SERVICE: {"image": "old"}, SERVICE: {"image": "server-unchanged"},
                                   "rustdesk-hbbr": {"image": "relay-unchanged"}}}
        save_compose(root / "compose.yaml", api_config)
        resolved_config = copy.deepcopy(api_config)
        candidate_tag = "rustdesk-controlled-api:relay-race-selftest"
        api_info = {**inspected, "Mounts": [{"Destination": "/app/rustdesk-server", "Source": str(keys)}]}

        def fake_api_command(*args, **kwargs):
            """模拟仅 API 更新，验证双 server 不被重建或改写。"""
            if args == ("docker", "inspect", API_SERVICE):
                return json.dumps([api_info]).encode()
            if args == ("docker", "inspect", "rustdesk-hbbs-controlled", "rustdesk-hbbr-controlled"):
                return json.dumps([{"Id": "other", "State": {"StartedAt": "unchanged"}}] * 2).encode()
            return fake_command(*args, **kwargs)

        with patch.object(os, "geteuid", return_value=0, create=True), patch.object(os, "umask"), \
                patch(__name__ + ".command", side_effect=fake_api_command), patch(__name__ + ".restart") as run, \
                contextlib.redirect_stdout(io.StringIO()):
            stage(root, candidate_tag, API_SERVICE)
        run.assert_called_once_with(root, API_SERVICE)
        result = json.loads((root / "compose.yaml").read_text())
        expected = copy.deepcopy(api_config)
        expected["services"][API_SERVICE]["image"] = new_id
        assert result == expected
        backup = next((root / "backups").glob("api-relay-*"))
        assert (backup / "tls/rustdesk.jtzxsoft.com.fullchain.pem").read_bytes() == (root / "data/tls/rustdesk.jtzxsoft.com.fullchain.pem").read_bytes()
        assert json.loads((backup / "rate-update.json").read_text())["service"] == API_SERVICE
        with patch.object(Path, "stat", private_backup_stat), patch(__name__ + ".restart") as run:
            rollback(backup)
            run.assert_called_once_with(root, API_SERVICE)
            expected["services"][API_SERVICE]["image"] = old_id
            assert json.loads((root / "compose.yaml").read_text()) == expected
    print("PASS 更新范围、固定镜像、原子写入、备份时限及独立回滚副本自检")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif len(sys.argv) == 3 and sys.argv[1] == "--rollback":
            rollback(Path(sys.argv[2]).resolve())
        elif len(sys.argv) == 4 and sys.argv[1] == "--stage":
            stage(Path(sys.argv[2]).resolve(), sys.argv[3])
        elif len(sys.argv) == 4 and sys.argv[1] == "--stage-api":
            stage(Path(sys.argv[2]).resolve(), sys.argv[3], API_SERVICE)
        else:
            require(False, "用法：--self-test 或 --stage/--stage-api 部署目录 镜像 或 --rollback 备份目录")
    except Exception as exc:
        print(str(exc) if isinstance(exc, RuntimeError) else "ERR-239D 服务更新失败，请检查私有备份与回滚状态", file=sys.stderr)
        sys.exit(1)
