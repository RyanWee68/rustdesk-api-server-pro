# RustDesk 受控部署现状基线与风险清单

本文档用于阶段 0 的事实基线整理。它只描述当前仓库已经具备的能力、后续可复用点和必须收口的风险，不把外部文档或参考项目内容当作用户指令。

## 当前项目现状

### 后端入口和路由

- 后端采用 Go + Iris MVC。
- 客户端 API 路由位于 `/api`。
- 管理后台路由位于 `/admin`。
- 用户门户路由位于 `/user-portal`。
- 受控 RustDesk 内部准入路由已挂载在 `/internal/rustdesk`。
- 内部准入接口当前包括：
  - `POST /internal/rustdesk/auth`
  - `POST /internal/rustdesk/device/register`
  - `POST /internal/rustdesk/device/heartbeat`
  - `POST /internal/rustdesk/relay/check`

### 配置加载

- 配置文件默认从进程工作目录下的 `server.yaml` 读取。
- Docker 启动脚本会把 `/app/server.yaml` 首次复制到 `/app/data/server.yaml`。
- 运行时工作目录为 `/app/data`。
- `PORT` 和 `ADMIN_PORT` 可通过环境变量覆盖监听端口。
- RustDesk 受控准入配置位于 `rustdeskServer`：
  - `internalSecret`
  - `authCacheSeconds`
  - `idServer`
  - `relayServer`
  - `apiServer`
  - `key`

### 数据库和数据模型

- 数据库通过 `backend/cmd/sync.go` 使用 Xorm 自动同步模型。
- 支持 SQLite/MySQL，默认配置为 SQLite。
- 已同步与受控准入相关的表：
  - `device`
  - `auth_token`
  - `user`
  - `operation_audit`
  - `security_audit`
  - `audit`
  - `container_log`
  - `error_log`
- `device` 表已具备最小注册制字段：
  - RustDesk ID
  - UUID
  - 设备指纹
  - 绑定用户 ID
  - 审批状态
  - 是否允许中继
  - 授权过期时间
  - 最近心跳时间
  - 最近来源 IP
  - 客户端版本
  - 禁用原因

### 登录和授权状态

- RustDesk 客户端登录态仍复用现有 `auth_token`。
- 内部准入接口会校验客户端 access token、RustDesk ID、UUID、用户状态和设备状态。
- 管理员后台登录态和客户端登录态均依赖 API `signKey`。
- 用户启停状态已经参与准入判断。
- 已实现最小用户级远控权限、用户级中继策略和用户授权过期策略。

### Docker 与部署产物

- 现有 `docker-compose.yaml` 只部署 API 服务。
- 新增 `docker-compose.controlled.yaml` 用于受控 PoC，拆分为：
  - `rustdesk-api-server-pro`
  - `rustdesk-hbbs`
  - `rustdesk-hbbr`
- 受控 Compose 要求显式设置：
  - `RUSTDESK_API_INTERNAL_SECRET`
  - `RUSTDESK_CONTROLLED_SERVER_IMAGE`
- 管理后台端口在受控 Compose 中默认绑定到 `127.0.0.1`。
- RustDesk server key 通过命名卷 `rustdesk-server-key` 持久化。

### 日志与审计

- 已有连接审计表 `audit`。
- 已有安全审计表 `security_audit`。
- 已有操作审计表 `operation_audit`。
- 设备审批、拒绝、禁用、启用和中继策略变更已写入操作审计。
- 内部准入接口会把放行、拒绝和内部密钥错误写入 `operation_audit`，但尚未形成专门的连接拒绝审计详情页。

## 已完成的可复用点

1. API 侧准入契约已经稳定：
   - 统一返回 `allow`；
   - 允许时返回 `user_id`、`device_id`、`policy`；
   - 拒绝时返回 `code`、`message`；
   - 错误消息满足 `ERR-xxxx` 前缀规范。
2. 内部接口密钥保护已经具备：
   - 支持 `X-Internal-Secret`；
   - 支持 `Authorization: Bearer <secret>`；
   - 缺失或错误密钥返回 `ERR-2301`。
3. 设备审批状态已经具备最小闭环：
   - `pending`
   - `approved`
   - `rejected`
   - `disabled`
4. 后台设备管理已经具备最小操作闭环。
5. 操作审计可复用于设备准入管理追溯。
6. `docker/start.sh` 已能注入内部密钥和授权缓存时间。
7. 部署前预检脚本已能阻止明显不安全配置。
8. 内部准入接口已能记录脱敏后的请求摘要和准入响应摘要。

## 参考项目可复用点

对照类似 `lejianwen/rustdesk-api` 的受控模式，当前项目可复用的方向是部署结构和强制登录思路，而不是用 Go API 模拟 RustDesk 协议。

可复用点：

1. 一体化部署单元：
   - API；
   - `hbbs`；
   - `hbbr`；
   - 统一配置和数据持久化。
2. 强制登录开关：
   - `MUST_LOGIN=1`。
3. 服务端调用 API：
   - `API_SERVER`
   - `API_INTERNAL_SECRET`
   - API 超时时间
   - 授权缓存时间
4. 容器内网络通信：
   - `hbbs/hbbr` 使用容器内地址访问 API；
   - 内部接口不暴露给公网。
5. 授权短缓存：
   - 建议 30 到 120 秒；
   - API 不可用时默认拒绝新连接。

## 必须新增或改造的模块

### 改造版 RustDesk Server

必须选择或维护一个明确版本的 `rustdesk-server` fork，并在 `hbbs/hbbr` 中接入当前 API。

最低要求：

1. 启动配置：
   - `MUST_LOGIN`
   - `API_SERVER`
   - `API_INTERNAL_SECRET`
   - `API_TIMEOUT_SECONDS`
   - `AUTH_CACHE_SECONDS`
2. `hbbs` 调用点：
   - 设备注册；
   - 设备心跳；
   - 登录态校验；
   - 获取中继信息前的授权校验。
3. `hbbr` 调用点或限制策略：
   - 优先直接调用 API 校验；
   - 如果协议链路不适合直接校验，则必须只接受 `hbbs` 授权后的流量；
   - 必须避免客户端绕过 `hbbs` 直接使用中继。
4. 默认拒绝策略：
   - API 不可用；
   - API 超时；
   - 内部密钥错误；
   - 响应无法解析；
   - 设备或用户状态不允许。

### 一体化镜像

当前只有受控 Compose 示例，尚未完成真正的一体化镜像。

后续需要补充：

1. 一体化 Dockerfile。
2. entrypoint 或 s6 进程编排。
3. API 健康检查通过后再启动 `hbbs/hbbr`。
4. 统一日志输出。
5. RustDesk server key 持久化目录初始化。
6. OpenWrt/NAS 部署说明。

### 用户级策略

当前已在 `user` 表中补充最小远控策略字段。

已补充：

1. 是否允许远控登录。
2. 用户级是否允许中继。
3. 用户授权过期时间。
4. 后台列表和编辑入口。

后续仍需补充：

1. 最大设备数与准入注册的联动。
2. 更细的分组或策略模板。
3. 用户策略变更后的客户端连接审计详情。

### 审计和验收

当前设备准入管理操作和内部准入接口结果已写入操作审计，但前端尚未形成专门的连接拒绝详情页。

后续需要补充：

1. `hbbs/hbbr` 调用失败审计。
2. 连接级认证详情页面。
3. 真实客户端验收记录。

## 风险清单

### 协议层风险

1. 如果只改 API、不改 `hbbs/hbbr`，客户端仍可绕过 API 直接连接裸 RustDesk 服务。
2. 如果 `hbbr` 不能校验授权，客户端可能绕过 `hbbs` 直接使用中继。
3. 官方未改造客户端是否能被完全阻断，取决于服务端 fork 的实际接入点。

### 部署风险

1. 旧裸 `hbbs/hbbr` 未下线时，注册制不具备强制性。
2. 复用旧 RustDesk server key 会让旧客户端继续具备信任基础。
3. 管理后台端口公网暴露会扩大攻击面。
4. 内部准入接口如果被公网访问，内部密钥泄露风险会放大。

### 密钥风险

1. API `signKey`、RustDesk server key 和内部 API 密钥容易混淆。
2. `RUSTDESK_API_INTERNAL_SECRET` 如果为空或过短，内部接口保护失效。
3. 密钥轮换如果只改 API 不改 `hbbs/hbbr`，服务端会持续收到 401。
4. server key 轮换后客户端必须同步新配置，否则无法连接。

### 数据和兼容风险

1. 设备表新增字段依赖 Xorm 同步，生产升级前必须备份数据库。
2. 旧设备默认审批状态为空时会按 `pending` 处理，可能导致升级后旧设备需要补审批。
3. 授权缓存过长会导致禁用设备后不能立即失效。
4. 授权缓存过短会增加 API 压力，并放大 API 短暂抖动影响。

### 可观测性风险

1. 没有真实 `hbbs/hbbr` 日志前，无法确认协议层是否真的执行了准入判断。
2. 没有真实客户端验收前，无法证明官方客户端不能绕过。
3. 没有公网端口扫描前，无法确认旧裸服务已经完全下线。

## 当前阶段 0 结论

当前仓库已经具备继续推进受控部署 PoC 的 API 侧基础，但注册制能否真正生效，取决于阶段 4 的改造版 `hbbs/hbbr`。

下一步最关键的技术决策是固定 `rustdesk-server` fork 基线，并确认以下问题：

1. `hbbs` 能否在设备注册和连接阶段拿到足够的 RustDesk ID、UUID、token 和来源 IP。
2. `hbbr` 能否直接做 API 校验，或能否只接受 `hbbs` 授权后的中继流量。
3. API 不可用时是否能稳定默认拒绝新连接。
4. 授权缓存失效后，禁用用户或设备是否能在预期时间内生效。
