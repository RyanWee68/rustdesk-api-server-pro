# RustDesk Server 受控改造基线与任务清单

更新时间：2026-10-16

当前已固定官方基线并形成可重放补丁：`patches/rustdesk-server/`。独立本地维护仓库为 `D:/WorkSpace/Other/RustDeskServerControlled`，分支 `codex/controlled-admission`；私有远程 fork 为 `RyanWee68/rustdesk-server-controlled`，官方仓库保留为 `upstream`。显式强制中继修复提交 `41e846fcb4e345084bc84af4263a9bb1f5def1e1` 已通过维护 CI；普通连接自动中继修复提交 `8996bd5` 已推送到用户 fork，Linux release 构建和 17 项库回归通过，0.211 上官方 1.4.9 跨网络普通连接实测成功。以下清单继续作为维护要求，共享出口角色证明、正常 WSS、任意代理换出口与独立公网防绕过验收仍未完成。

## 选型结论

阶段 4 的推荐路线是：以官方 `rustdesk/rustdesk-server` 作为长期维护基线，参考 `lejianwen/rustdesk-api` 指向的 `lejianwen/rustdesk-server` 强制登录思路，维护本项目自己的受控 fork。

理由：

- 官方仓库是 `hbbs/hbbr` 的主要上游，后续协议和客户端兼容风险最低；
- `lejianwen/rustdesk-api` 的部署说明已经验证了“API + 改造版 server + MUST_LOGIN”的产品形态；
- 直接依赖第三方 fork 镜像会让安全边界、更新节奏和补丁审计不可控；
- 当前 Go API 已经完成内部准入接口，`rustdesk-server` 侧只需要调用这些稳定接口，不需要在 Go API 内模拟 RustDesk 协议。

## 外部参考

- 官方 server 源码：`https://github.com/rustdesk/rustdesk-server`
- 参考 API 项目：`https://github.com/lejianwen/rustdesk-api`
- 参考 server fork：`https://github.com/lejianwen/rustdesk-server`

## fork 基线要求

选择基线时必须记录：

- 上游仓库 URL；
- 上游 commit SHA 或 tag；
- fork 仓库 URL；
- `hbbs/hbbr` 构建命令；
- 生成镜像的 Dockerfile；
- 二进制输出路径；
- 当前客户端版本兼容范围；
- 与本项目 API 契约对应的改造 commit。

推荐在 fork 仓库中维护 `CONTROLLED_API_CONTRACT.md`，记录 `MUST_LOGIN`、`API_SERVER`、`API_INTERNAL_SECRET`、`API_TIMEOUT_SECONDS`、`AUTH_CACHE_SECONDS`、`RUSTDESK_KEY_DIR` 的语义。

当前 API 契约见本仓库：

```text
docs/CONTROLLED_RUSTDESK_API_CONTRACT.md
```

Rust 侧准入客户端模板见：

```text
templates/rustdesk-server-controlled/
```

固定官方基线可直接使用 `scripts/deploy/controlled-fork-apply.sh` 应用完整补丁；模板可单独测试，旧资料脚手架仍只复制说明文件。

真实 fork 创建后，可用脚手架脚本复制模板和契约文档：

```bash
scripts/deploy/controlled-fork-bootstrap.sh /path/to/rustdesk-server-fork --dry-run
scripts/deploy/controlled-fork-bootstrap.sh /path/to/rustdesk-server-fork
```

脚手架说明见：

```text
docs/CONTROLLED_RUSTDESK_FORK_BOOTSTRAP.md
```

## 必须实现的配置项

`hbbs` 和 `hbbr` 必须支持：

- `MUST_LOGIN=1`：强制开启准入；
- `API_SERVER`：当前 API 根地址；
- `API_INTERNAL_SECRET`：调用内部接口的密钥；
- `API_TIMEOUT_SECONDS`：单次 API 调用超时时间；
- `AUTH_CACHE_SECONDS`：准入结果短缓存；
- `RUSTDESK_KEY_DIR`：server key 持久化目录。

缺省策略：

- `MUST_LOGIN=1` 时，`API_SERVER` 或 `API_INTERNAL_SECRET` 为空必须拒绝启动；
- API 超时、API 不可达、响应不可解析、响应 `allow=false` 时默认拒绝新连接；
- 当前补丁不缓存允许结果，`AUTH_CACHE_SECONDS` 保留兼容但不影响新连接的在线校验；
- 日志不得输出 `API_INTERNAL_SECRET`、access token 或 server key 私钥。

## hbbs 改造点

`hbbs` 至少需要在以下点调用 API：

1. 设备首次出现或基础信息更新：
   - 调用 `POST /internal/rustdesk/device/register`；
   - 未注册设备应进入待审批，不允许继续连接。
2. 设备进入受控链路前：
   - 调用 `POST /internal/rustdesk/auth`；
   - `allow=false` 时拒绝。
3. 设备心跳：
   - 调用 `POST /internal/rustdesk/device/heartbeat`；
   - 返回拒绝时断开或拒绝后续连接。
4. 获取中继信息前：
   - 确认设备、用户和授权状态仍有效；
   - 中继策略关闭时不能下发可用 relay。

## hbbr 改造点

固定基线补丁使用 hbbs 签发和 hbbr 双端核销：显式中继在 `RequestRelay` 收到控制端 token 后签发；普通连接直连失败后的自动中继只接受 30 秒内与原发起端 socket、目标 ID 和目标实际 IP 匹配的 RelayResponse，再使用其 UUID 签发。hbbr 对每端实际连接 IP 调用 `/internal/rustdesk/relay/grant/consume`。API 失败、上下文缺失、会话过期、重复核销或策略撤销时拒绝；当前 API 还在签发及核销阶段拒绝同 IP 双端，直到具备独立设备角色证明。原 `/relay/check` 保留用于设备本身持 token 的内部调用，不直接适配官方 hbbr 请求。

## 授权缓存要求

- 当前补丁逐次调用 API，不缓存允许结果；
- 禁用用户、设备、关闭中继或撤销 token 后，新连接和下一端中继核销应立即拒绝；
- 现有会话的断开时间仍需结合心跳和真实客户端测试。

## 镜像契约

用于本仓库 `Dockerfile.controlled` 的镜像必须满足：

- `/usr/local/bin/hbbs` 可执行；
- `/usr/local/bin/hbbr` 可执行；
- 直接运行二进制时读取上述环境变量；
- 支持以 `RUSTDESK_KEY_DIR` 指定 key 持久化目录；
- 不要求外部 entrypoint 才能启用 `MUST_LOGIN`。

可用以下脚本做最低契约检查：

```bash
export RUSTDESK_CONTROLLED_SERVER_IMAGE="<改造版 rustdesk-server 镜像>"
scripts/deploy/controlled-server-image-check.sh
```

该脚本不能替代真实客户端 PoC，只用于提前发现镜像缺少二进制或环境变量启动不兼容。

在构建镜像前，可先对 fork 源码做静态接入检查：

```bash
scripts/deploy/controlled-server-source-check.sh /path/to/rustdesk-server-controlled
```

检查项和人工复核边界见：

```text
docs/CONTROLLED_RUSTDESK_SERVER_SOURCE_CHECK.md
```

模板本身可用以下命令检查：

```bash
scripts/deploy/controlled-template-check.sh .
```

API 启动后，可用以下脚本检查内部准入端点基础行为：

```bash
export API_BASE_URL="http://127.0.0.1:12345"
export RUSTDESK_API_INTERNAL_SECRET="<至少 32 字符内部密钥>"
scripts/deploy/controlled-admission-smoke.sh
```

## PoC 验收门槛

阶段 4 完成必须同时满足：

- 未注册设备使用官方客户端无法连入；
- 待审批设备无法连入；
- 审批通过后可以连入；
- 禁用设备后在缓存过期时间内或之后无法连入；
- 禁用用户后无法连入；
- 关闭中继后 relay 不可用；
- API 停止后新连接失败；
- `hbbr` 不能被客户端绕过直接使用；
- 审计日志能看到拒绝原因；
- 新 server key 与旧裸服务 key 不一致。

## 仍需人工决策

- fork 仓库归属和命名；
- 后续升级使用的基线 commit/tag；当前补丁基线已固定；
- 是否直接基于 `lejianwen/rustdesk-server` cherry-pick，还是从官方上游重新实现；
- 镜像发布位置；
- 真实 NAS/公网验收窗口。
