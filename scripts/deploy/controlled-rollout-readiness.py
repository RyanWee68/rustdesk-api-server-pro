#!/usr/bin/env python3
"""只读检查恢复后的目标主机，不执行 SSH、清理、重启或部署。"""

import datetime
import json
import re
import subprocess
import sys


CONTAINERS = ("rustdesk-api-server-pro", "rustdesk-hbbs-controlled", "rustdesk-hbbr-controlled")
ROLLBACK_PATTERN = "controlled-*"
PROTECTION_PATTERN = r"controlled-[A-Za-z0-9_.@-]*(?:rollback|hbbs-rate-|api-relay-|wss-live-cleanup-)[A-Za-z0-9_.@-]*\.(?:timer|service)"
INSPECT_FORMAT = ('{"name":{{json .Name}},"image":{{json .Image}},'
                  '"running":{{json .State.Running}},'
                  '"health":{{if .State.Health}}{{json .State.Health.Status}}{{else}}null{{end}},'
                  '"restart_count":{{json .RestartCount}}}')


def require(condition, message):
    """只返回固定错误，不透出命令输出中的私有信息。"""
    if not condition:
        raise RuntimeError("ERR-2393 " + message)


def read_command(arguments):
    """只接受调用方固定的只读命令，拒绝错误、超时和无法解码的结果。"""
    result = subprocess.run(arguments, capture_output=True, timeout=15)
    require(result.returncode == 0, "无法读取主机就绪状态，停止更新并在主机本地检查权限和工具版本")
    return result.stdout.decode("utf-8")


def read_rollback_units():
    """同时检查已加载的临时单元和磁盘单元，避免漏掉未启用的旧回滚任务。"""
    loaded = read_command(["systemctl", "show", "--all", "--property=Id", "--value", ROLLBACK_PATTERN])
    installed = read_command(["systemctl", "list-unit-files", "--no-legend", "--no-pager",
                              "--plain", "--full"])
    names = {line.strip() for line in loaded.splitlines() if line.strip()}
    for line in installed.splitlines():
        if line.strip():
            fields = line.split()
            require(2 <= len(fields) <= 3, "回滚单元清单格式无法确认")
            # 无匹配项时部分 systemd 版本返回 1，因此列全量后仅保留受控回滚单元。
            if fields[0].startswith("controlled-"):
                names.add(fields[0])
    require(all(re.fullmatch(r"controlled-[A-Za-z0-9_.@-]*\.(timer|service)", name)
                for name in names), "保护单元名称或清单格式无法确认")
    return sorted(name for name in names if re.fullmatch(PROTECTION_PATTERN, name))


def inspect_host():
    """返回脱敏快照；发现任何遗留回滚单元或非健康容器即阻断更新。"""
    units = read_rollback_units()
    output = read_command(["docker", "inspect", "--type=container", "--format", INSPECT_FORMAT, *CONTAINERS])
    containers = [json.loads(line) for line in output.splitlines() if line.strip()]
    require(len(containers) == len(CONTAINERS), "三容器状态数量不符")
    require({item.get("name") for item in containers} == {"/" + name for name in CONTAINERS},
            "三容器名称不符或状态重复")
    for item in containers:
        require(set(item) == {"name", "image", "running", "health", "restart_count"}
                and isinstance(item["image"], str) and re.fullmatch(r"sha256:[0-9a-f]{64}", item["image"])
                and isinstance(item["running"], bool)
                and item["health"] in (None, "starting", "healthy", "unhealthy")
                and type(item["restart_count"]) is int and item["restart_count"] >= 0,
                "三容器状态字段无法确认")
    return {"checked_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "ready": not units and all(item["running"] and item["health"] == "healthy" for item in containers),
            "rollback_units": units, "containers": containers}


def main(arguments):
    """只有显式 --check 才访问本机服务，其他输入不启动子进程。"""
    try:
        if arguments == ["--self-test"]:
            self_test()
            return 0
        require(arguments == ["--check"], "用法：controlled-rollout-readiness.py --check|--self-test")
        report = inspect_host()
        print(json.dumps(report, ensure_ascii=False, indent=2))
        require(report["ready"], "发现遗留回滚单元或三容器未健康，禁止继续更新；本工具不会自动清理或修复")
        print("PASS: 只读就绪快照通过；仍须核对私有配置差异、备份、公钥、证书及新的自动回滚保护")
        print("WARN: 仅检查 controlled-* 下的 rollback、hbbs-rate、api-relay 和 wss-live-cleanup 系统单元，不覆盖其他命名、用户单元、cron 或外部调度；不是部署许可或业务验收")
        return 0
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError)
              else "ERR-2393 主机就绪检查失败：" + type(error).__name__, file=sys.stderr)
        return 1


def self_test():
    """通过替代全部子进程验证边界，不调用真实 Docker、systemd 或网络。"""
    import contextlib
    import copy
    import io
    from unittest.mock import patch

    baseline = [{"name": "/" + name, "image": "sha256:" + "a" * 64, "running": True,
                 "health": "healthy", "restart_count": 0} for name in CONTAINERS]
    unit = "controlled-tls-contract-rollback-20261017"
    cases = [("normal", "", "", baseline, True),
             ("unrelated-files", "", "ssh.service enabled enabled\napt-daily.timer enabled enabled\n", baseline, True),
             ("loaded-timer", unit + ".timer\n", "", baseline, False),
             ("loaded-service", unit + ".service\n", "", baseline, False),
             ("rate-window", "controlled-hbbs-rate-abc.timer\n", "", baseline, False),
             ("api-relay-window", "controlled-api-relay-abc.timer\n", "", baseline, False),
             ("api-relay-service", "controlled-api-relay-abc.service\n", "", baseline, False),
             ("installed-api-relay", "", "controlled-api-relay-abc.timer enabled enabled\n", baseline, False),
             ("fixture-window", "controlled-wss-live-cleanup-abc.service\n", "", baseline, False),
             ("installed-rate", "", "controlled-hbbs-rate-abc.timer disabled enabled\n", baseline, False),
             ("installed-fixture", "", "controlled-wss-live-cleanup-abc.timer enabled enabled\n", baseline, False),
             ("unrelated-controlled", "controlled-monitor.timer\n", "controlled-monitor.service static -\n", baseline, True),
             ("disabled-file", "", unit + ".timer disabled enabled\n", baseline, False),
             ("masked-file", "", unit + ".service masked -\n", baseline, False),
             ("malformed-units", "", "invalid-format\n", baseline, False),
             ("unsafe-unit", unit + ".timer;secret\n", "", baseline, False),
             ("missing-container", "", "", baseline[:2], False)]
    for field, value in (("running", False), ("running", "true"), ("health", None),
                         ("health", "starting"), ("health", "unhealthy"), ("restart_count", -1),
                         ("image", "latest"), ("name", "/another-container"),
                         ("name", baseline[1]["name"]), ("unexpected", "secret")):
        rows = copy.deepcopy(baseline)
        rows[0][field] = value
        cases.append((field + str(value), "", "", rows, False))
    for label, loaded, installed, rows, expected in cases:
        responses = [loaded, installed, "\n".join(json.dumps(row) for row in rows)]
        results = [subprocess.CompletedProcess([], 0, response.encode(), b"") for response in responses]
        stdout, stderr = io.StringIO(), io.StringIO()
        with patch.object(subprocess, "run", side_effect=results) as run, \
                contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            status = main(["--check"])
        require((status == 0) == expected, "就绪自测结论错误：" + label)
        require("secret" not in stdout.getvalue() + stderr.getvalue(), "就绪检查泄漏无效输出")
        for call in run.call_args_list:
            command = call.args[0]
            require((command[0] == "systemctl" and command[1] in ("show", "list-unit-files"))
                    or (command[0] == "docker" and command[1] == "inspect"), "就绪检查执行了非只读命令")
            require(call.kwargs == {"capture_output": True, "timeout": 15}, "就绪检查丢失输出隔离或超时")
            if command[:2] == ["systemctl", "list-unit-files"]:
                require(ROLLBACK_PATTERN not in command, "磁盘单元查询不能因无匹配项误报失败")
    for index in range(3):
        for failure in (OSError("secret"), subprocess.TimeoutExpired("secret", 15),
                        subprocess.CompletedProcess([], 1, b"secret", b"secret"),
                        subprocess.CompletedProcess([], 0, b"\xff", b""),
                        subprocess.CompletedProcess([], 0, b"{secret", b"")):
            stdout, stderr = io.StringIO(), io.StringIO()
            preceding = [subprocess.CompletedProcess([], 0, b"", b"")] * index
            with patch.object(subprocess, "run", side_effect=preceding + [failure]), \
                    contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                require(main(["--check"]) == 1, "工具错误被误判就绪")
            require("secret" not in stdout.getvalue() + stderr.getvalue(), "工具错误输出泄漏")
    with patch.object(subprocess, "run") as run, contextlib.redirect_stderr(io.StringIO()):
        require(main([]) == 1 and main(["--unknown"]) == 1, "无效参数未拒绝")
        require(not run.called, "无效参数仍执行主机命令")
    print("PASS: 只读就绪检查正常、遗留任务、容器故障、工具失败和参数边界自测通过")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
