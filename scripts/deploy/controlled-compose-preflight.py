#!/usr/bin/env python3
"""检查 Compose 最终配置，避免环境变量覆盖绕过静态部署预检。"""

import copy
import ipaddress
import json
from pathlib import Path
import subprocess
import sys


def require(condition, message):
    """只输出固定错误说明，不输出包含凭据的 Compose 内容。"""
    if not condition:
        raise RuntimeError("ERR-2393 " + message)


def verify(config):
    """核对三容器的真实鉴权、端口和健康依赖，不启动任何服务。"""
    services = config.get("services", {})
    api_name = "rustdesk-api-server-pro"
    require(set(services) == {api_name, "rustdesk-hbbs", "rustdesk-hbbr"}, "只接受正式三容器服务定义")
    api = services[api_name]
    api_env = api.get("environment", {})
    secret = api_env.get("RUSTDESK_API_INTERNAL_SECRET", "")
    require(isinstance(secret, str) and len(secret) >= 32 and secret not in {
        "CHANGE_ME_TO_A_RANDOM_32_BYTE_SECRET", "please-change-this-sign-key",
    }, "内部密钥缺失、过短或仍为示例值")
    password = api_env.get("ADMIN_PASS", "")
    require(api_env.get("ADMIN_USER") and isinstance(password, str) and len(password) >= 12,
            "管理员初始账号或密码缺失、过短")
    require(api.get("environment", {}).get("CONTROLLED_API_ONLY") == "1", "API 必须使用专用运行模式")
    require(api.get("environment", {}).get("PORT") == "12345"
            and api.get("environment", {}).get("ADMIN_PORT") == "12346", "API 容器端口与部署契约不一致")
    for name, service in services.items():
        require(not service.get("privileged") and not service.get("network_mode"), "禁止特权或共享主机网络模式")
        require(service.get("image") and not service.get("build"), "正式服务必须指定已构建镜像")
        destinations = {"/app/data", "/app/rustdesk-server", "/app/logs"} if name == api_name else {"/data"}
        volumes = service.get("volumes", [])
        require(len(volumes) == len(destinations) and {item.get("target") for item in volumes} == destinations,
                "服务挂载了部署契约以外的目录")
        if name == api_name:
            require(next(item for item in volumes if item["target"] == "/app/logs").get("type") == "volume",
                    "API 日志必须使用独立持久卷")
        for port in service.get("ports", []):
            require(isinstance(port, dict), "端口未规范化")
            target = int(port.get("target", 0))
            expected = {api_name: {12345, 12346}, "rustdesk-hbbs": {21115, 21116, 21118}, "rustdesk-hbbr": {21117, 21119}}
            require(target in expected[name], "服务发布了部署契约以外的端口")
            if target in {12346, 21118, 21119}:
                require(ipaddress.ip_address(port.get("host_ip", "0.0.0.0")).is_loopback,
                        "管理或 WebSocket 端口必须仅绑定回环地址")
        if name != api_name:
            env = service.get("environment", {})
            require(env.get("MUST_LOGIN") == "1" and env.get("API_INTERNAL_SECRET") == secret,
                    "server 强制登录或内部密钥与 API 不一致")
            require(env.get("API_SERVER") == "http://rustdesk-api-server-pro:12345", "server 鉴权地址必须指向同部署 API")
            require(service.get("depends_on", {}).get(api_name, {}).get("condition") == "service_healthy",
                    "server 缺少 API 健康依赖")
    keys = []
    for name, service in services.items():
        destination = "/app/rustdesk-server" if name == api_name else "/data"
        mounts = [item for item in service.get("volumes", []) if item.get("target") == destination]
        require(len(mounts) == 1 and mounts[0].get("type") == "volume", "server key 必须来自独立持久卷")
        keys.append(mounts[0].get("source"))
    require(keys[0] and len(set(keys)) == 1, "API 与 server 未共享同一 server key 卷")


def verify_data_separation(config, original):
    """首次切换的新数据必须独立于旧容器挂载，防止原库被原地迁移。"""
    mounts = config["services"]["rustdesk-api-server-pro"].get("volumes", [])
    data = [item for item in mounts if item.get("target") == "/app/data"]
    require(len(data) == 1 and data[0].get("type") == "bind" and data[0].get("source"), "新 API 数据必须来自独立宿主目录")
    candidate = Path(data[0]["source"]).resolve()
    require(candidate != Path(candidate.anchor), "新 API 数据不能使用文件系统根目录")
    for mount in original.get("Mounts", []):
        if mount.get("Source"):
            source = Path(mount["Source"]).resolve()
            require(not candidate.is_relative_to(source) and not source.is_relative_to(candidate),
                    "新数据目录与旧容器挂载重叠，禁止原地迁移")


def self_test():
    """覆盖环境覆盖后的公网绑定、错误鉴权和不安全运行模式。"""
    api_name = "rustdesk-api-server-pro"
    config = {"services": {api_name: {
        "image": "fixture-api", "environment": {"RUSTDESK_API_INTERNAL_SECRET": "x" * 48,
        "CONTROLLED_API_ONLY": "1", "PORT": "12345", "ADMIN_PORT": "12346", "ADMIN_USER": "fixture", "ADMIN_PASS": "x" * 32},
        "ports": [{"target": 12346, "host_ip": "127.0.0.1"}],
        "volumes": [{"target": "/app/rustdesk-server", "type": "volume", "source": "key"},
                    {"target": "/app/data", "type": "bind", "source": "/fixture/data"},
                    {"target": "/app/logs", "type": "volume", "source": "logs"}],
    }}}
    for name, port in (("rustdesk-hbbs", 21118), ("rustdesk-hbbr", 21119)):
        config["services"][name] = {
            "image": "fixture-server", "environment": {"MUST_LOGIN": "1", "API_INTERNAL_SECRET": "x" * 48,
            "API_SERVER": "http://rustdesk-api-server-pro:12345"},
            "depends_on": {api_name: {"condition": "service_healthy"}},
            "ports": [{"target": port, "host_ip": "::1"}],
            "volumes": [{"target": "/data", "type": "volume", "source": "key"}],
        }
    verify(config)
    mutations = (
        lambda s: s[api_name]["ports"][0].update(host_ip="0.0.0.0"),
        lambda s: s["rustdesk-hbbs"]["ports"][0].pop("host_ip"),
        lambda s: s["rustdesk-hbbr"]["ports"][0].update(host_ip="::"),
        lambda s: s["rustdesk-hbbs"]["environment"].update(API_INTERNAL_SECRET="y" * 48),
        lambda s: s["rustdesk-hbbs"]["environment"].update(MUST_LOGIN="0"),
        lambda s: s["rustdesk-hbbr"]["environment"].update(API_SERVER="http://outside.invalid"),
        lambda s: s[api_name]["environment"].update(CONTROLLED_API_ONLY="0"),
        lambda s: s["rustdesk-hbbr"].update(privileged=True),
        lambda s: s["rustdesk-hbbs"].update(network_mode="host"),
        lambda s: s["rustdesk-hbbs"]["depends_on"][api_name].update(condition="service_started"),
        lambda s: s["rustdesk-hbbr"]["volumes"][0].update(source="other-key"),
        lambda s: s[api_name]["ports"][0].update(target=3306),
        lambda s: s[api_name]["environment"].update(ADMIN_PASS="password"),
        lambda s: s["rustdesk-hbbs"]["volumes"].append({"target": "/var/run/docker.sock", "type": "bind"}),
        lambda s: s[api_name]["volumes"][2].update(type="bind", source="/fixture/original"),
    )
    for mutate in mutations:
        invalid = copy.deepcopy(config)
        mutate(invalid["services"])
        try:
            verify(invalid)
        except RuntimeError:
            continue
        raise RuntimeError("ERR-2393 危险 Compose 配置未被拒绝")
    original = {"Mounts": [{"Type": "bind", "Source": "/fixture/original"}]}
    verify_data_separation(config, original)
    for source in ("/fixture/original", "/fixture/original/data", "/fixture", "/"):
        invalid = copy.deepcopy(config)
        invalid["services"][api_name]["volumes"][1]["source"] = source
        try:
            verify_data_separation(invalid, original)
        except RuntimeError:
            continue
        raise RuntimeError("ERR-2393 原库目录重叠未被拒绝")
    print("PASS: 最终配置预检拒绝 " + str(len(mutations)) + " 类不安全覆盖")
    print("PASS: 新数据目录相同、子目录、父目录及根目录均被拒绝")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        else:
            require(len(sys.argv) == 2, "用法：controlled-compose-preflight.py <正式三容器 Compose>|--self-test")
            result = subprocess.run(["docker", "compose", "-f", sys.argv[1], "config", "--format", "json"],
                                    capture_output=True, timeout=30)
            require(result.returncode == 0, "Compose 解析失败，请在主机本地核对私有环境配置")
            config = json.loads(result.stdout)
            verify(config)
            containers = subprocess.run(["docker", "ps", "-aq", "--filter", "name=^/rustdesk-api-server-pro(-precontrolled)?$"],
                                         capture_output=True, timeout=15)
            require(containers.returncode == 0, "无法读取旧容器状态")
            originals = [{}]
            if containers.stdout.strip():
                inspected = subprocess.run(["docker", "inspect", *containers.stdout.decode().split()], capture_output=True, timeout=15)
                require(inspected.returncode == 0, "无法读取旧容器挂载")
                originals = json.loads(inspected.stdout)
            for original in originals:
                verify_data_separation(config, original)
            print("PASS: 最终 Compose 鉴权、回环端口、运行模式、健康依赖和密钥卷一致")
            print("PASS: 新 API 数据目录未与当前原容器挂载重叠（不代表正式端口可用）")
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError) else "ERR-2393 最终配置预检失败：" + type(error).__name__, file=sys.stderr)
        sys.exit(1)
