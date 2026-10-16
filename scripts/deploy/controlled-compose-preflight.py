#!/usr/bin/env python3
"""检查 Compose 最终配置，避免环境变量覆盖绕过静态部署预检。"""

import copy
import ipaddress
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


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
    tls_env = {name: api_env.get(name, "") for name in ("TLS_PORT", "TLS_CERT_FILE", "TLS_KEY_FILE")}
    expected_ports = {
        api_name: {(12345, "tcp"), (12346, "tcp"), (12443, "tcp")},
        "rustdesk-hbbs": {(21115, "tcp"), (21116, "tcp"), (21116, "udp"), (21118, "tcp")},
        "rustdesk-hbbr": {(21117, "tcp"), (21119, "tcp")},
    }
    admin_lan_networks = tuple(ipaddress.ip_network(cidr) for cidr in
                               ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))
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
        actual_ports = []
        for port in service.get("ports", []):
            require(isinstance(port, dict), "端口未规范化")
            target = int(port.get("target", 0))
            protocol = port.get("protocol", "tcp")
            require((target, protocol) in expected_ports[name], "服务发布了部署契约以外的端口或协议")
            published = str(port.get("published", ""))
            require(published.isdecimal() and 1 <= int(published) <= 65535, "服务端口必须固定发布到有效宿主端口")
            actual_ports.append((target, protocol))
            if target == 12346:
                address = ipaddress.ip_address(port.get("host_ip", "0.0.0.0"))
                require(address.is_loopback or any(address in network for network in admin_lan_networks),
                        "管理端口必须绑定回环或明确的局域网 IPv4 地址")
            elif target in {21118, 21119}:
                require(ipaddress.ip_address(port.get("host_ip", "0.0.0.0")).is_loopback,
                        "WebSocket 端口必须仅绑定回环地址")
        require(len(actual_ports) == len(set(actual_ports)), "正式三容器存在重复端口发布")
        if name == api_name:
            require((12345, "tcp") in actual_ports
                    and bool(set(actual_ports) & {(12346, "tcp"), (12443, "tcp")}),
                    "API 必须发布客户端端口及至少一个管理入口")
            if (12443, "tcp") in actual_ports:
                require(tls_env["TLS_PORT"] == "12443", "HTTPS 端口与 TLS_PORT 不一致")
                require(all(isinstance(tls_env[key], str) and tls_env[key].startswith("/app/data/tls/")
                            and ".." not in Path(tls_env[key]).parts
                            and re.fullmatch(r"/app/data/tls/[A-Za-z0-9_.-]+", tls_env[key])
                            for key in ("TLS_CERT_FILE", "TLS_KEY_FILE")),
                        "TLS 证书和私钥必须位于持久化数据目录的 tls 子目录")
                require(tls_env["TLS_CERT_FILE"] != tls_env["TLS_KEY_FILE"], "TLS 证书和私钥不能使用同一路径")
            else:
                require(not any(tls_env.values()), "未发布 HTTPS 端口时禁止残留 TLS 环境配置")
        else:
            require(set(actual_ports) == expected_ports[name], "正式三容器缺少必需 TCP/UDP 端口")
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
    key_volume = config.get("volumes", {}).get(keys[0])
    require(isinstance(key_volume, dict), "server key 卷必须由当前 Compose 定义")
    require(not key_volume.get("external") and not key_volume.get("driver_opts")
            and key_volume.get("driver", "local") == "local",
            "server key 卷禁止复用外部卷或绑定宿主目录")


def verify_data_separation(config, original):
    """首次切换保护旧数据，同时允许已运行的受控容器复检自身目录。"""
    mounts = config["services"]["rustdesk-api-server-pro"].get("volumes", [])
    data = [item for item in mounts if item.get("target") == "/app/data"]
    require(len(data) == 1 and data[0].get("type") == "bind" and data[0].get("source"), "新 API 数据必须来自独立宿主目录")
    candidate = Path(data[0]["source"]).resolve()
    require(candidate != Path(candidate.anchor), "新 API 数据不能使用文件系统根目录")
    if (original.get("Name") == "/rustdesk-api-server-pro"
            and "CONTROLLED_API_ONLY=1" in original.get("Config", {}).get("Env", [])):
        return
    for mount in original.get("Mounts", []):
        if mount.get("Source"):
            source = Path(mount["Source"]).resolve()
            require(not candidate.is_relative_to(source) and not source.is_relative_to(candidate),
                    "新数据目录与旧容器挂载重叠，禁止原地迁移")


def self_test():
    """覆盖环境覆盖后的公网绑定、错误鉴权和不安全运行模式。"""
    api_name = "rustdesk-api-server-pro"
    config = {"volumes": {"key": {}}, "services": {api_name: {
        "image": "fixture-api", "environment": {"RUSTDESK_API_INTERNAL_SECRET": "x" * 48,
        "CONTROLLED_API_ONLY": "1", "PORT": "12345", "ADMIN_PORT": "12346", "ADMIN_USER": "fixture", "ADMIN_PASS": "x" * 32},
        "ports": [{"target": 12346, "host_ip": "127.0.0.1", "published": "12346"},
                  {"target": 12345, "published": "12345"}],
        "volumes": [{"target": "/app/rustdesk-server", "type": "volume", "source": "key"},
                    {"target": "/app/data", "type": "bind", "source": "/fixture/data"},
                    {"target": "/app/logs", "type": "volume", "source": "logs"}],
    }}}
    for name, port in (("rustdesk-hbbs", 21118), ("rustdesk-hbbr", 21119)):
        config["services"][name] = {
            "image": "fixture-server", "environment": {"MUST_LOGIN": "1", "API_INTERNAL_SECRET": "x" * 48,
            "API_SERVER": "http://rustdesk-api-server-pro:12345"},
            "depends_on": {api_name: {"condition": "service_healthy"}},
            "ports": [{"target": port, "host_ip": "::1", "published": str(port)}],
            "volumes": [{"target": "/data", "type": "volume", "source": "key"}],
        }
    config["services"]["rustdesk-hbbs"]["ports"].extend([
        {"target": 21115, "published": "21115"},
        {"target": 21116, "published": "21116"},
        {"target": 21116, "protocol": "udp", "published": "21116"},
    ])
    config["services"]["rustdesk-hbbr"]["ports"].append({"target": 21117, "published": "21117"})
    verify(config)
    lan_config = copy.deepcopy(config)
    lan_config["services"][api_name]["ports"][0]["host_ip"] = "192.168.0.211"
    verify(lan_config)
    tls_config = copy.deepcopy(config)
    tls_config["services"][api_name]["ports"] = [
        {"target": 12345, "published": "22345"},
        {"target": 12443, "published": "22346"},
    ]
    tls_config["services"][api_name]["environment"].update({
        "TLS_PORT": "12443",
        "TLS_CERT_FILE": "/app/data/tls/server.fullchain.pem",
        "TLS_KEY_FILE": "/app/data/tls/server.key.pem",
    })
    verify(tls_config)
    tls_config["services"][api_name]["ports"].append(
        {"target": 12346, "host_ip": "192.168.0.211", "published": "22347"})
    verify(tls_config)
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
        lambda s: s["rustdesk-hbbs"]["ports"].pop(),
        lambda s: s["rustdesk-hbbs"]["ports"][3].update(protocol="tcp"),
        lambda s: s[api_name]["ports"][0].update(protocol="udp"),
        lambda s: s["rustdesk-hbbr"]["ports"].append(copy.deepcopy(s["rustdesk-hbbr"]["ports"][0])),
        lambda s: s[api_name]["ports"][1].pop("published"),
        lambda s: s[api_name]["ports"][0].update(host_ip="169.254.1.1"),
        lambda s: s[api_name]["ports"][0].update(host_ip="8.8.8.8"),
        lambda s: s[api_name]["ports"].pop(0),
        lambda s: s[api_name]["ports"].pop(1),
        lambda s: s[api_name]["ports"].append(copy.deepcopy(s[api_name]["ports"][0])),
        lambda s: s[api_name]["ports"].append({"target": 12443, "protocol": "udp", "published": "22346"}),
    )
    for mutate in mutations:
        invalid = copy.deepcopy(config)
        mutate(invalid["services"])
        try:
            verify(invalid)
        except RuntimeError:
            continue
        raise RuntimeError("ERR-2393 危险 Compose 配置未被拒绝")
    tls_mutations = (
        lambda s: s[api_name]["ports"][2].update(host_ip="0.0.0.0"),
        lambda s: s[api_name]["ports"][2].update(host_ip="::"),
        lambda s: s[api_name]["ports"][2].pop("host_ip"),
        lambda s: s[api_name]["ports"].append(copy.deepcopy(s[api_name]["ports"][1])),
        lambda s: s[api_name]["environment"].update(TLS_PORT="12444"),
        lambda s: s[api_name]["environment"].update(TLS_CERT_FILE="/tmp/server.pem"),
        lambda s: s[api_name]["environment"].update(TLS_KEY_FILE="/app/data/tls/server.fullchain.pem"),
        lambda s: s[api_name]["environment"].update(TLS_CERT_FILE='/app/data/tls/bad"path.pem'),
    )
    for mutate in tls_mutations:
        invalid = copy.deepcopy(tls_config)
        mutate(invalid["services"])
        try:
            verify(invalid)
        except RuntimeError:
            continue
        raise RuntimeError("ERR-2393 HTTPS 部署中的不安全管理端口未被拒绝")
    for mutate in (
        lambda c: c["volumes"].pop("key"),
        lambda c: c["volumes"]["key"].update(external=True),
        lambda c: c["volumes"]["key"].update(driver_opts={"type": "none", "o": "bind", "device": "/fixture/old-key"}),
        lambda c: c["volumes"]["key"].update(driver="other"),
    ):
        invalid = copy.deepcopy(config)
        mutate(invalid)
        try:
            verify(invalid)
        except RuntimeError:
            continue
        raise RuntimeError("ERR-2393 外部或宿主绑定 server key 卷未被拒绝")
    original = {"Mounts": [{"Type": "bind", "Source": "/fixture/original"}]}
    verify_data_separation(config, original)
    current = {"Name": "/rustdesk-api-server-pro", "Config": {"Env": ["CONTROLLED_API_ONLY=1"]},
               "Mounts": [{"Type": "bind", "Source": "/fixture/data"}]}
    verify_data_separation(config, current)
    invalid_root = copy.deepcopy(config)
    invalid_root["services"][api_name]["volumes"][1]["source"] = "/"
    try:
        verify_data_separation(invalid_root, current)
    except RuntimeError:
        pass
    else:
        raise RuntimeError("ERR-2393 当前受控容器复检绕过了数据根目录保护")
    for legacy in (
        {"Name": "/rustdesk-api-server-pro", "Mounts": current["Mounts"]},
        {**current, "Name": "/rustdesk-api-server-pro-precontrolled"},
    ):
        try:
            verify_data_separation(config, legacy)
        except RuntimeError:
            continue
        raise RuntimeError("ERR-2393 旧容器或保留容器的数据目录重叠未被拒绝")
    for source in ("/fixture/original", "/fixture/original/data", "/fixture", "/"):
        invalid = copy.deepcopy(config)
        invalid["services"][api_name]["volumes"][1]["source"] = source
        try:
            verify_data_separation(invalid, original)
        except RuntimeError:
            continue
        raise RuntimeError("ERR-2393 原库目录重叠未被拒绝")
    print("PASS: 最终配置预检拒绝 " + str(len(mutations) + 4) + " 类不安全覆盖")
    print("PASS: 新数据目录相同、子目录、父目录及根目录均被拒绝")
    print("PASS: 当前受控容器复检不误拒，旧容器与保留容器仍保护数据目录")
    print("PASS: 仅 HTTPS 及 HTTPS 加内网 HTTP 通过，" + str(len(tls_mutations)) + " 类不安全 TLS 覆盖被拒绝")
    with tempfile.TemporaryDirectory(prefix="rustdesk-compose-preflight-") as directory:
        path = Path(directory) / "compose.json"
        path.write_text(json.dumps(tls_config), encoding="utf-8")
        result = subprocess.run([sys.executable, __file__, "--config-json", str(path)],
                                capture_output=True, timeout=15)
        require(result.returncode == 0 and b"WARN:" in result.stdout,
                "离线 JSON 检查未通过或未说明静态边界")
        tls_config["services"][api_name]["ports"][2]["host_ip"] = "0.0.0.0"
        path.write_text(json.dumps(tls_config), encoding="utf-8")
        result = subprocess.run([sys.executable, __file__, "--config-json", str(path)],
                                capture_output=True, timeout=15)
        require(result.returncode != 0 and b"ERR-2393" in result.stderr,
                "离线 JSON 检查未拒绝不安全配置")
        require(("x" * 48).encode() not in result.stdout + result.stderr,
                "离线 JSON 检查输出了内部密钥")
        path.write_text("{", encoding="utf-8")
        result = subprocess.run([sys.executable, __file__, "--config-json", str(path)],
                                capture_output=True, timeout=15)
        require(result.returncode != 0 and b"ERR-2393" in result.stderr,
                "离线 JSON 检查未拒绝损坏输入")
    print("PASS: 离线 JSON 命令的正常、拒绝、损坏输入及不泄密路径通过")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif len(sys.argv) == 3 and sys.argv[1] == "--config-json":
            with open(sys.argv[2], encoding="utf-8") as source:
                verify(json.load(source))
            print("PASS: 离线 Compose JSON 契约检查通过")
            print("WARN: 仅静态检查，未检查宿主挂载重叠、卷来源、端口占用、TLS 配置、证书或实际网络")
        else:
            require(len(sys.argv) == 2, "用法：controlled-compose-preflight.py <正式三容器 Compose>|--config-json <JSON 文件>|--self-test")
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
            print("PASS: 最终 Compose 鉴权、管理/WebSocket 绑定、运行模式、健康依赖和密钥卷一致")
            print("WARN: TLS 端口发布不证明启用加密，仍须核对配置、证书和运行时 HTTPS/明文拒绝")
            print("PASS: 新 API 数据目录未与当前原容器挂载重叠（不代表正式端口可用）")
    except Exception as error:
        print(str(error) if isinstance(error, RuntimeError) else "ERR-2393 最终配置预检失败：" + type(error).__name__, file=sys.stderr)
        sys.exit(1)
