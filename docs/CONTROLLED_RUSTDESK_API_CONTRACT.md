# RustDesk 内部准入 API 契约

本文档供改造版 `rustdesk-server` fork 实现 `hbbs/hbbr` 调用时使用。字段以当前 Go 代码中的 `backend/internal/core/rustdesk_admission.go` 为准。

## 通用约束

- 所有接口都使用 `POST`。
- 请求头必须包含 `X-Internal-Secret: <secret>`，也兼容 `Authorization: Bearer <secret>`。
- `Content-Type` 使用 `application/json`。
- `MUST_LOGIN=1` 时，内部密钥缺失、错误或 API 不可达必须默认拒绝连接。
- `rustdesk_id` 是首选设备 ID 字段；兼容字段 `id` 可作为 fallback。
- `access_token` 只用于请求，不允许写入日志。
- 响应 `allow=false` 时，`code` 和 `message` 必须被 `hbbs/hbbr` 原样记录到安全日志，但不要回显敏感 token。
- 已登记 UUID 或指纹与本次提供的非空值冲突时返回 `ERR-2313`；设备已绑定其他用户时返回 `ERR-2314`，不允许通过登录自动转移归属。
- 鉴权、心跳及中继请求被拒绝时，不更新设备绑定、指纹、在线状态或连接数。
- 新连接必须在线校验 API；模板不复用允许结果。仅配置短缓存不能同时保证 API 停止后所有新连接立即拒绝。

## 通用响应

允许：

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

拒绝：

```json
{
  "allow": false,
  "code": "ERR-2305",
  "message": "ERR-2305 DevicePendingApproval"
}
```

## 设备注册

`hbbs` 首次发现设备或设备基础信息变化时调用。

```http
POST /internal/rustdesk/device/register
X-Internal-Secret: <secret>
Content-Type: application/json
```

请求：

```json
{
  "rustdesk_id": "123456789",
  "id": "123456789",
  "uuid": "client-uuid",
  "fingerprint": "device-fingerprint",
  "hostname": "office-pc",
  "username": "alice",
  "os": "windows",
  "client_version": "1.4.9",
  "source_ip": "192.168.1.10"
}
```

处理要求：

- 新设备通常返回 `ERR-2305`，表示已登记但待审批；
- 重复注册保留已有审批状态；未填写审批状态的旧设备转为待审批；
- `hbbs` 收到 `allow=false` 必须拒绝连接；
- `hbbs` 可以缓存待审批结果，但缓存时间不得超过 `AUTH_CACHE_SECONDS`。

## 登录态和准入校验

`hbbs` 在允许设备进入受控链路前调用。

```http
POST /internal/rustdesk/auth
X-Internal-Secret: <secret>
Content-Type: application/json
```

请求：

```json
{
  "rustdesk_id": "123456789",
  "id": "123456789",
  "uuid": "client-uuid",
  "fingerprint": "device-fingerprint",
  "access_token": "client-api-token",
  "source_ip": "192.168.1.10",
  "client_version": "1.4.9"
}
```

处理要求：

- `access_token` 缺失或无效会返回 `ERR-2303`；
- 设备未注册返回 `ERR-2304`；
- 待审批返回 `ERR-2305`；
- 已拒绝返回 `ERR-2306`；
- 已禁用返回 `ERR-2307`；
- 用户禁用返回 `ERR-2308`；
- 设备授权过期返回 `ERR-2310`；
- 用户远控权限关闭返回 `ERR-2311`；
- 用户远控授权过期返回 `ERR-2312`。

## 设备心跳

`hbbs` 周期性上报设备在线状态。

```http
POST /internal/rustdesk/device/heartbeat
X-Internal-Secret: <secret>
Content-Type: application/json
```

请求：

```json
{
  "rustdesk_id": "123456789",
  "id": "123456789",
  "uuid": "client-uuid",
  "source_ip": "192.168.1.10",
  "client_version": "1.4.9",
  "conn_count": 1
}
```

处理要求：

- 返回 `allow=false` 时，`hbbs` 应拒绝后续连接，必要时断开现有会话；
- 心跳间隔和缓存时间共同决定禁用后的最长生效延迟。
- 零连接数会清除上一次的非零计数；同一设备鉴权不会修改计数。
- 心跳响应是设备策略检查结果，不是用户登录证明或中继票据。

## 连接双方校验

`POST /internal/rustdesk/connection/check` 用于 hbbs 处理控制端请求连接另一台设备。不要把官方协议中的目标 ID 与控制端 token 传入同一设备 `/auth` 接口。

```json
{
  "target_id": "target-device-id",
  "access_token": "controller-api-token",
  "source_ip": "192.0.2.1",
  "relay": true
}
```

- 使用与其他内部接口相同的内部密钥鉴权。
- 从有效、未过期、非管理员 token 解析控制端设备和用户，调用者不能指定或覆盖控制端身份。
- 控制端与被控端设备均需登记并审批通过；被控端还必须存在绑定该设备、未撤销且未过期的非管理员客户端 token，双方用户均需启用且远控授权有效。
- `relay=true` 时，同时检查双方设备及用户的中继策略。
- 成功响应的 `device_id` 是被控端，`source_device_id` 是控制端，`user_id` 是控制端登录用户。
- `policy.allow_relay` 是双方策略交集；`expire_at` 不晚于双方授权或双方 token 到期时间。
- 接口只读，不修改双方设备归属；审计只记录 `has_token`。
- 该接口会拒绝没有有效客户端 token 的被控端，退出或撤销 token 后的新连接默认拒绝；数据库 token 仍不是设备私钥挑战或短期登录租约，不应写成密码学当前登录态证明。中继会话仍由下述签发与核销链路约束。

## 中继会话签发与核销

固定基线补丁中的 `hbbs` 在收到控制端 `RequestRelay` 后，向
`POST /internal/rustdesk/relay/grant/issue` 提交：

```json
{
  "target_id": "target-device-id",
  "access_token": "controller-api-token",
  "session_uuid": "123e4567-e89b-42d3-a456-426614174000",
  "source_ip": "192.0.2.10",
  "target_ip": "198.51.100.20"
}
```

- `session_uuid` 必须是标准 UUID v4，仅用于一次中继会话；不能写入设备 UUID 字段。
- 双方设备、用户、中继策略和 token 必须通过双端校验，签发有效期最多 30 秒，不晚于策略到期时间。
- IP 来自 hbbs 实际连接地址；同一 UUID 不能重复签发。双方 IP 标准化后相同则返回 `ERR-2315`，目前不支持共享出口 IP 的双端中继。
- API 使用持久化 `rustdesk_relay_grant` 表，部署前需执行数据库 `sync`。

`hbbr` 在接纳每一端时向 `POST /internal/rustdesk/relay/grant/consume` 提交：

```json
{
  "session_uuid": "123e4567-e89b-42d3-a456-426614174000",
  "peer_ip": "192.0.2.10"
}
```

API 校验会话有效期、连接实际 IP、控制端 token 状态及双方当前策略，再原子核销对应端点。每端只能核销一次；两个端点都通过后 hbbr 才能配对。未签发、过期、重放、IP 不匹配，以及升级前遗留的同 IP 授权均返回 `ERR-2315`。审计记录结果，不记录 token、内部密钥或会话 UUID。公网 IP 在 hbbs/hbbr 间变化的 NAT 或代理场景尚需实机验证；同公网 IP 双端目前直接拒绝，必须增加独立设备角色证明后才能安全恢复支持。

## 中继校验

优先由 `hbbr` 在建立 relay 前直接调用；如果协议层不适合直接调用，必须证明 `hbbr` 只接受 `hbbs` 授权后的流量。

```http
POST /internal/rustdesk/relay/check
X-Internal-Secret: <secret>
Content-Type: application/json
```

请求：

```json
{
  "rustdesk_id": "123456789",
  "id": "123456789",
  "uuid": "client-uuid",
  "access_token": "client-api-token",
  "source_ip": "192.168.1.10"
}
```

处理要求：

- 设备或用户不允许中继时返回 `ERR-2309`；
- API 不可用时必须拒绝 relay；
- 不允许客户端绕过 `hbbs` 直接获得可用 relay。

## 错误码

| 错误码 | 含义 | server 侧处理 |
| --- | --- | --- |
| `ERR-2301` | 内部密钥无效 | 拒绝并记录安全日志 |
| `ERR-2302` | 设备 ID 为空 | 拒绝，检查上报字段 |
| `ERR-2303` | 登录态无效 | 拒绝，要求客户端重新登录 |
| `ERR-2304` | 设备未注册 | 拒绝，先调用注册接口 |
| `ERR-2305` | 设备待审批 | 拒绝，等待管理员审批 |
| `ERR-2306` | 设备已拒绝 | 拒绝 |
| `ERR-2307` | 设备已禁用 | 拒绝 |
| `ERR-2308` | 用户已禁用 | 拒绝 |
| `ERR-2309` | 不允许中继 | 拒绝 relay |
| `ERR-2310` | 设备授权过期 | 拒绝 |
| `ERR-2311` | 用户远控权限关闭 | 拒绝 |
| `ERR-2312` | 用户远控授权过期 | 拒绝 |
| `ERR-2313` | 设备 UUID 或指纹冲突 | 拒绝，核实身份，不能直接覆盖 |
| `ERR-2314` | 设备绑定用户与登录用户冲突 | 拒绝，由管理员核实归属 |
| `ERR-2315` | 中继会话无效、过期或已核销 | 拒绝并重新发起连接 |

## Smoke 验证

API 启动后可以运行：

```bash
export API_BASE_URL="http://127.0.0.1:12345"
export RUSTDESK_API_INTERNAL_SECRET="<至少 32 字符内部密钥>"
scripts/deploy/controlled-admission-smoke.sh
```

默认 `SMOKE_TOKEN` 是无效 token，因此 `/internal/rustdesk/auth` 返回 `ERR-2303` 属于预期。若要验证允许路径，需要传入真实客户端 token，并确保设备已审批通过。
