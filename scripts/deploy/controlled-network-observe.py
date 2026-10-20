#!/usr/bin/env python3
"""限时观察固定受控端口的 IPv4 元信息，不保存载荷或修改网络。"""

from datetime import datetime, timezone
import json
import socket
import struct
import sys
import time

HOST = "192.168.0.211"


def metadata(packet):
    """仅接受目标主机的有效固定头，忽略分片和非受控端口。"""
    if len(packet) < 20 or packet[0] >> 4 != 4:
        return None
    size = (packet[0] & 15) * 4
    protocol = packet[9]
    if size < 20 or protocol not in (6, 17) or len(packet) < size + (20 if protocol == 6 else 8):
        return None
    if struct.unpack_from("!H", packet, 6)[0] & 0xbfff:
        return None
    total = struct.unpack_from("!H", packet, 2)[0]
    if total < size + (20 if protocol == 6 else 8):
        return None
    if protocol == 6:
        tcp_size = (packet[size + 12] >> 4) * 4
        if tcp_size < 20 or size + tcp_size > total or len(packet) < size + tcp_size:
            return None
    elif struct.unpack_from("!H", packet, size + 4)[0] != total - size:
        return None
    source, target = socket.inet_ntoa(packet[12:16]), socket.inet_ntoa(packet[16:20])
    sport, dport = struct.unpack_from("!HH", packet, size)
    ports = (22115, 22117) if protocol == 6 else (22116,)
    if target == HOST and dport in ports:
        direction = "in"
    elif source == HOST and sport in ports:
        direction = "out"
    else:
        return None
    return {"direction": direction, "protocol": "TCP" if protocol == 6 else "UDP",
            "source": source, "source_port": sport, "target": target, "target_port": dport,
            "ip_length": total, "tcp_flags": packet[size + 13] if protocol == 6 else None}


def observe():
    """只绑定 eth0，最多十五分钟或一千条记录，自动关闭观察套接字。"""
    deadline = time.monotonic() + 900
    count = 0
    # ETH_P_ALL 才能同时观察网卡收包与发包，解析后仅输出目标 IPv4 元信息。
    with socket.socket(socket.AF_PACKET, socket.SOCK_DGRAM, socket.htons(0x0003)) as stream:
        stream.bind(("eth0", 0))
        stream.settimeout(1)
        print("READY metadata-only eth0 TCP:22115,22117 UDP:22116 limit=900s/1000", flush=True)
        while time.monotonic() < deadline and count < 1000:
            try:
                packet = stream.recv(80)
            except socket.timeout:
                continue
            record = metadata(packet)
            if record is not None:
                record["utc"] = datetime.now(timezone.utc).isoformat()
                print(json.dumps(record), flush=True)
                count += 1
    print("STOP records=" + str(count), flush=True)


def self_test():
    """合成报文验证端口、方向、截断、分片和载荷不落日志。"""
    def packet(protocol, source, target, sport, dport):
        """构造固定 IPv4 头与最小传输头。"""
        if protocol == 6:
            transport = struct.pack("!HH", sport, dport) + bytes(8) + b"\x50" + bytes(7)
        else:
            transport = struct.pack("!HHHH", sport, dport, 8, 0)
        return struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + len(transport), 0, 0, 64,
                           protocol, 0, socket.inet_aton(source), socket.inet_aton(target)) + transport

    inbound = packet(17, "203.0.113.9", HOST, 40000, 22116)
    assert metadata(inbound)["direction"] == "in"
    assert metadata(packet(17, HOST, "203.0.113.9", 22116, 40000))["direction"] == "out"
    tcp = bytearray(packet(6, "203.0.113.9", HOST, 40000, 22117))
    tcp[33] = 2
    assert metadata(tcp)["tcp_flags"] == 2
    # TCP 选项属于头部，截断时不能用未完整捕获的头作为取证依据。
    options = bytearray(tcp + bytes(40))
    struct.pack_into("!H", options, 2, len(options))
    options[32] = 0xf0
    assert metadata(options)["tcp_flags"] == 2
    assert metadata(options[:40]) is None
    assert metadata(options[:-1]) is None
    assert metadata(options + b"secret-payload") == metadata(options)
    assert metadata(inbound + b"secret-payload") == metadata(inbound)
    for bad in (inbound[:27], b"", packet(17, "203.0.113.9", HOST, 40000, 21116),
                packet(17, "203.0.113.9", "192.168.21.251", 40000, 22116),
                inbound[:6] + b"\x20\x00" + inbound[8:],
                inbound[:6] + b"\x80\x00" + inbound[8:],
                inbound[:2] + b"\x00\x01" + inbound[4:],
                inbound[:24] + b"\x00\x07" + inbound[26:],
                inbound[:24] + b"\x00\x09" + inbound[26:],
                bytes(tcp[:32]) + b"\x40" + bytes(tcp[33:]),
                bytes(tcp[:32]) + b"\xf0" + bytes(tcp[33:])):
        assert metadata(bad) is None
    # 长载荷可被观察套接字截断，但头部长度一致时仍应保留元信息。
    large = bytearray(inbound + bytes(256))
    struct.pack_into("!H", large, 2, len(large))
    struct.pack_into("!H", large, 24, len(large) - 20)
    assert metadata(large[:80])["ip_length"] == len(large)
    large_tcp = bytearray(options + bytes(256))
    struct.pack_into("!H", large_tcp, 2, len(large_tcp))
    assert metadata(large_tcp[:80])["ip_length"] == len(large_tcp)
    print("PASS metadata-only self-test")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif sys.argv[1:] == ["--observe"]:
            observe()
        else:
            raise RuntimeError("ERR-2394 用法：--self-test 或 --observe（仅目标 Linux）")
    except Exception:
        print("ERR-2394 端口观察失败，未修改网络或服务", file=sys.stderr)
        sys.exit(1)
