# RustDesk Server 受控源码检查清单

更新时间：2026-10-08

本文档用于阶段 4 的真实 `rustdesk-server` fork 接入前检查。它不能替代真实客户端 PoC，但可以在 fork 源码阶段提前拦截“只改了镜像包装、没有真正接入准入 API”的风险。

## 检查脚本

新增脚本：

```bash
scripts/deploy/controlled-server-source-check.sh <rustdesk-server-fork源码目录>
```

也可以使用环境变量：

```bash
export RUSTDESK_SERVER_SOURCE_DIR="/path/to/rustdesk-server-controlled"
scripts/deploy/controlled-server-source-check.sh
```

脚本会检查：

- 源码根目录是否像 `rustdesk-server`；
- 是否存在 `hbbs` / `hbbr` 或 rendezvous / relay 相关实现；
- 是否实现受控环境变量：
  - `MUST_LOGIN`
  - `API_SERVER`
  - `API_INTERNAL_SECRET`
  - `API_TIMEOUT_SECONDS`
  - `AUTH_CACHE_SECONDS`
  - `RUSTDESK_KEY_DIR`
- 是否包含固定基线实际使用的五个内部 API 调用点：
  - `/internal/rustdesk/connection/check`
  - `/internal/rustdesk/device/register`
  - `/internal/rustdesk/device/heartbeat`
  - `/internal/rustdesk/relay/grant/issue`
  - `/internal/rustdesk/relay/grant/consume`
- `rendezvous_server.rs` 是否出现注册、心跳、双端连接和中继签发接线，`relay_server.rs` 是否出现中继核销接线；
- 是否包含关键请求和响应字段；
- 是否存在 API 超时、默认拒绝和授权缓存相关线索；
- 是否疑似把 `API_INTERNAL_SECRET` 或 `access_token` 写入日志。

脚本失败统一使用 `ERR-2399`。

## 使用位置

建议阶段 4 按以下顺序推进：

1. 固定官方 `rustdesk/rustdesk-server` 上游 commit 或 tag。
2. 在 fork 中实现受控准入调用。
3. 在 fork 源码目录运行：

```bash
scripts/deploy/controlled-server-source-check.sh /path/to/rustdesk-server-controlled
```

4. 构建受控 server 镜像后运行：

```bash
export RUSTDESK_CONTROLLED_SERVER_IMAGE="<改造版 rustdesk-server 镜像>"
scripts/deploy/controlled-server-image-check.sh
```

5. API 启动后运行：

```bash
export API_BASE_URL="http://127.0.0.1:12345"
export RUSTDESK_API_INTERNAL_SECRET="<至少 32 字符内部密钥>"
scripts/deploy/controlled-admission-smoke.sh
```

6. 最后再做真实 RustDesk 客户端验收。

## 人工复核项

源码检查脚本只做静态线索检查，以下项必须人工或集成测试确认：

- `hbbs` 在设备注册和控制端发起连接前实际执行注册、心跳与双端校验；
- 未注册或待审批设备不会被继续放行；
- API 不可达、超时、响应不可解析时默认拒绝新连接；
- 禁用用户、禁用设备、关闭中继后，新连接和下一端中继核销立即重新查询 API；现有会话断开时间另行验证；
- `hbbr` 不能被客户端绕过 `hbbs` 直接使用；
- 日志中不包含内部密钥、access token 或 server key 私钥；
- 镜像内 `/usr/local/bin/hbbs` 和 `/usr/local/bin/hbbr` 是改造后的二进制，而不是官方裸二进制。

## 与验收模板的关系

通过源码检查只能说明 fork 具备受控接入线索。阶段 4 完成仍必须在 `docs/CONTROLLED_RUSTDESK_ACCEPTANCE.md` 中记录真实客户端证据：

- 未注册设备连接失败；
- 审批通过后连接成功；
- 禁用设备或用户后连接失败；
- API 停止后新连接失败；
- 关闭中继后 relay 不可用；
- `hbbr` 绕过测试失败。
