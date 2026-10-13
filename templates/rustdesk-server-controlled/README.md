# rustdesk-server 受控准入客户端模板

本目录保存 Rust 侧内部准入客户端。固定官方基线的完整源码改动见 `patches/rustdesk-server/`，该补丁将本模块接入 `hbbs/hbbr`。模板本身仍可独立编译和测试。

## 文件

- `controlled_admission.rs`：内部准入 API 客户端、请求/响应结构、在线检查和日志摘要。
- `Cargo.toml`：独立模板包清单，便于复制到 fork 前做 `cargo check` 或对齐依赖。

## 依赖建议

复制到 fork 后，通常需要在 `Cargo.toml` 中确认以下依赖或等价库：

```toml
anyhow = "1"
reqwest = { version = "0.11", features = ["json", "rustls-tls"] }
serde = { version = "1", features = ["derive"] }
tokio = { version = "1", features = ["time"] }
```

如果 fork 已经使用其它 HTTP 客户端，可以保留结构体和 fail-closed 策略，替换 `reqwest` 调用。

本目录自带的 `Cargo.toml` 可以作为最小类型检查入口；在有 Rust 工具链和依赖下载能力的机器上运行：

```bash
cargo check --manifest-path templates/rustdesk-server-controlled/Cargo.toml
cargo test --manifest-path templates/rustdesk-server-controlled/Cargo.toml
```

## 接入位置

`hbbs` 推荐接入点：

1. 设备首次出现或基础信息更新时调用 `register_device`；
2. 持有该设备登录凭据时调用 `authorize`；控制端请求连接被控端时调用 `check_connection`，分别传入目标 ID 和控制端 token；
3. 周期心跳调用 `heartbeat`；
4. 控制端请求中继时调用 `issue_relay_grant`，同时传入会话 UUID 与双方实际连接 IP。

`hbbr` 推荐接入点：

1. 每端建立 relay 前调用 `consume_relay_grant`；
2. 仅在双方分别核销通过后配对中继流量。

官方客户端的 hbbr 建链请求不提供控制端 token，不能直接照搬 `check_relay`。中继会话 UUID 不是设备 UUID；详见 `docs/CONTROLLED_RUSTDESK_PROTOCOL_MAPPING.md`。

## 在线校验边界

为满足 API 停止后新连接拒绝的要求，鉴权、中继和双端连接检查每次都访问 API，不复用允许结果。`AUTH_CACHE_SECONDS` 配置及响应字段保留兼容，但当前模板不启用放行缓存。

HTTP 非 2xx、请求失败、JSON 解析失败、缺少策略、授权过期均拒绝。连接检查额外验证目标 ID、控制端 ID、用户 ID 及中继策略；HTTP 重定向禁用，含 token 或内部密钥的请求/配置不派生 Debug。

模板自带本机 HTTP 测试，覆盖连续请求重新校验、HTTP 错误伪造允许结果、不完整/过期响应、API 不可用，以及中继签发和核销端点。协议入口接线见固定基线补丁；Linux 镜像和官方客户端验收仍需另行执行。

## 环境变量

模板读取：

- `MUST_LOGIN`
- `API_SERVER`
- `API_INTERNAL_SECRET`
- `API_TIMEOUT_SECONDS`
- `AUTH_CACHE_SECONDS`

`MUST_LOGIN=1` 时，`API_SERVER` 或 `API_INTERNAL_SECRET` 为空会直接报错，调用方必须拒绝启动或拒绝连接。

## 验证

复制到 fork 并完成接入后，在本仓库运行：

```bash
scripts/deploy/controlled-server-source-check.sh /path/to/rustdesk-server-controlled
```

构建镜像后运行：

```bash
export RUSTDESK_CONTROLLED_SERVER_IMAGE="<改造版 rustdesk-server 镜像>"
scripts/deploy/controlled-server-image-check.sh
```

API 启动后运行：

```bash
export API_BASE_URL="http://127.0.0.1:12345"
export RUSTDESK_API_INTERNAL_SECRET="<至少 32 字符内部密钥>"
scripts/deploy/controlled-admission-smoke.sh
```
