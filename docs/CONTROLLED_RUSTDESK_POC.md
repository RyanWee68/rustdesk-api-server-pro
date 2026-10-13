# RustDesk 受控部署 PoC 说明

本文档描述当前仓库已经准备好的 API 准入能力，以及改造版 `hbbs/hbbr` 接入时需要遵守的最小契约。

## 当前边界

当前仓库已经完成：

- API 内部准入接口；
- 设备注册制字段；
- 后台设备审批、拒绝、禁用、启用和中继开关；
- 受控 Compose 示例；
- 部署前预检脚本。

当前仓库包含固定官方基线的受控补丁和镜像构建定义，但尚未完成 Linux Docker 构建及官方客户端验收，因此不能单靠 API 或源码静态检查证明官方客户端无法绕过。真正的准入控制必须由改造版 `hbbs/hbbr` 在协议链路中调用 API 完成。三容器 Compose 必须显式提供由当前受控源码构建的 `RUSTDESK_API_IMAGE`。

## 改造版 RustDesk Server 必须支持的环境变量

`hbbs` 和 `hbbr` 镜像至少需要支持：

- `MUST_LOGIN=1`：开启强制准入；
- `API_SERVER`：API 服务地址，例如 `http://rustdesk-api-server-pro:12345`；
- `API_INTERNAL_SECRET`：调用内部接口使用的密钥；
- `API_TIMEOUT_SECONDS`：API 调用超时时间，建议 3 秒；
- `AUTH_CACHE_SECONDS`：授权结果短缓存，建议 30 到 120 秒；
- `RUSTDESK_KEY_DIR`：server key 持久化目录。

API 不可用、超时、响应不可解析或返回 `allow=false` 时，`hbbs/hbbr` 必须默认拒绝新连接。

`rustdesk-server` fork 的基线选择和改造任务见：

```text
docs/CONTROLLED_RUSTDESK_SERVER_FORK.md
```

内部准入 API 的字段级契约见：

```text
docs/CONTROLLED_RUSTDESK_API_CONTRACT.md
```

## 内部接口调用点

### 设备注册

`hbbs` 首次发现设备或收到设备基础信息时调用：

```http
POST /internal/rustdesk/device/register
X-Internal-Secret: <secret>
Content-Type: application/json
```

请求示例：

```json
{
  "rustdesk_id": "123456789",
  "uuid": "client-uuid",
  "fingerprint": "device-fingerprint",
  "hostname": "office-pc",
  "username": "alice",
  "os": "windows",
  "client_version": "1.4.9",
  "source_ip": "192.168.1.10"
}
```

新设备默认返回待审批：

```json
{
  "allow": false,
  "code": "ERR-2305",
  "message": "ERR-2305 DevicePendingApproval"
}
```

### 登录态和准入校验

`hbbs` 在允许设备进入受控链路前调用：

```http
POST /internal/rustdesk/auth
X-Internal-Secret: <secret>
Content-Type: application/json
```

请求示例：

```json
{
  "rustdesk_id": "123456789",
  "uuid": "client-uuid",
  "fingerprint": "device-fingerprint",
  "access_token": "client-api-token",
  "client_version": "1.4.9",
  "source_ip": "192.168.1.10"
}
```

允许示例：

```json
{
  "allow": true,
  "user_id": 1,
  "device_id": "123456789",
  "policy": {
    "allow_relay": true,
    "expire_at": 1790000000,
    "cache_ttl": 60
  }
}
```

### 心跳

`hbbs` 周期性调用：

```http
POST /internal/rustdesk/device/heartbeat
X-Internal-Secret: <secret>
Content-Type: application/json
```

请求示例：

```json
{
  "rustdesk_id": "123456789",
  "uuid": "client-uuid",
  "client_version": "1.4.9",
  "source_ip": "192.168.1.10",
  "conn_count": 1
}
```

如果设备被禁用、拒绝或授权过期，返回 `allow=false`，`hbbs` 应断开或拒绝后续连接。

### 中继校验

`hbbr` 优先直接调用；如果协议层不适合直接校验，则必须只接受 `hbbs` 授权后的流量。

```http
POST /internal/rustdesk/relay/check
X-Internal-Secret: <secret>
Content-Type: application/json
```

请求示例：

```json
{
  "rustdesk_id": "123456789",
  "uuid": "client-uuid",
  "access_token": "client-api-token",
  "source_ip": "192.168.1.10"
}
```

当后台关闭设备中继时，返回：

```json
{
  "allow": false,
  "code": "ERR-2309",
  "message": "ERR-2309 RelayNotAllowed"
}
```

## Compose PoC

使用示例文件：

```bash
export RUSTDESK_API_INTERNAL_SECRET="<至少 32 字符随机密钥>"
export RUSTDESK_CONTROLLED_SERVER_IMAGE="<改造版 rustdesk-server 镜像>"
docker compose -f docker-compose.controlled.yaml up -d
```

预检：

```bash
RUSTDESK_API_INTERNAL_SECRET="<至少 32 字符随机密钥>" \
RUSTDESK_CONTROLLED_SERVER_IMAGE="<改造版 rustdesk-server 镜像>" \
sh scripts/deploy/controlled-preflight.sh .
```

没有 Docker CLI 的环境可先执行静态检查：

```bash
sh scripts/deploy/controlled-static-check.sh .
```

## PoC 验收清单

1. 未注册设备连接时，后台出现 `pending` 设备，客户端连接被拒绝。
2. 管理后台通过设备后，同一设备可以连入。
3. 后台禁用设备后，短缓存时间内连接失败。
4. 后台关闭中继后，中继连接失败。
5. 禁用用户后，其设备连接失败。
6. 停止 API 后，新连接默认失败。
7. 公网只暴露受控 `hbbs/hbbr` 必需端口和客户端 API 端口；管理后台只绑定内网或本机。
8. 新部署使用新的 server key，旧裸服务下线。

完整验收结果记录到：

```text
docs/CONTROLLED_RUSTDESK_ACCEPTANCE.md
```
