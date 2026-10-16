# RustDesk 受控部署密钥轮换说明

本文档用于受控部署 PoC 和生产上线前的密钥轮换操作。这里的说明只记录流程和检查点，不记录真实密钥。

## 2026-10-13 当前服务隔离复核

当前正式局域网 hbbs 入口的无令牌真实握手已验证：客户端当前配置公钥通过服务端签名校验，旧 PoC 配置公钥在签名校验阶段拒绝，未发送会话密钥或登录令牌。使用现有 libsodium 和固定协议验收工具核对，没有关闭加密、清空客户端公钥或再次轮换密钥。

此证据只覆盖当前服务和已知旧 PoC 公钥；原生产所有旧裸服务的公钥、其他主机及公网暴露仍没有完整证据，不能把它写成旧生产信任链全部隔离。当前测试部署管理端口允许局域网访问，仍使用 HTTP，不应复用外部生产密码。

## 密钥类型

受控部署至少涉及三类密钥：

1. API `signKey`
   - 位于 `server.yaml` 的顶层 `signKey`。
   - 用于当前 API 服务的登录态、token 和 OAuth state 签名。
   - 轮换后，已有后台登录态和客户端 API token 可能失效。
2. RustDesk server key
   - 由 `hbbs/hbbr` 使用，建议持久化在 `RUSTDESK_KEY_DIR` 对应目录。
   - 客户端配置会绑定该 key；更换后客户端需要同步新配置。
   - 这是切断旧裸服务信任链的关键。
3. 内部 API 密钥
   - 由环境变量 `RUSTDESK_API_INTERNAL_SECRET` 注入到 API。
   - 由改造版 `hbbs/hbbr` 通过 `API_INTERNAL_SECRET` 调用内部准入接口。
   - 只允许容器内或可信网络使用，禁止暴露到前端和客户端。

## 轮换原则

1. 生产环境不得使用示例值、空值或少于 32 字符的内部密钥。
2. 新受控部署必须使用新的 RustDesk server key，不能复用旧裸服务 key。
3. 旧裸 `hbbs/hbbr` 下线前，不应把新 key 分发给客户端。
4. `RUSTDESK_API_INTERNAL_SECRET` 和 RustDesk server key 必须分开生成、分开保存。
5. 密钥轮换应先完成备份，再执行替换和重启。
6. 轮换后必须执行预检和最小连接验收。

## API signKey 轮换

适用场景：

- 示例 `signKey` 尚未替换；
- 怀疑 API token 或 OAuth state 签名密钥泄露；
- 从测试环境切换到生产环境。

操作步骤：

1. 停止对外维护窗口内的新登录操作。
2. 备份当前数据目录和 `server.yaml`。
3. 生成不少于 32 字符的随机字符串。
4. 修改持久化 `server.yaml` 顶层 `signKey`。
5. 重启 API 容器。
6. 验证后台可重新登录。
7. 验证客户端需要重新获取 token 时可以正常完成登录。

验收点：

- `scripts/deploy/controlled-preflight.sh` 不再报告 `signKey` 使用示例值。
- API 启动日志无 `unsafe signKey` 相关错误。
- 管理后台登录、OAuth 回调和客户端登录流程可用。

## RustDesk server key 轮换

适用场景：

- 从官方裸 `hbbs/hbbr` 切换到受控部署；
- 旧服务已暴露公网，无法保证只有已审批设备使用；
- 怀疑 server key 泄露；
- 需要强制所有客户端切换到新受控服务。

操作步骤：

1. 停止旧裸 `hbbs/hbbr` 的公网访问。
2. 备份旧服务 key，仅用于回滚，不再分发给客户端。
3. 清空或重新初始化受控部署中的 RustDesk server key 持久化目录。
4. 启动受控 `hbbs/hbbr`，生成或加载新的 server key。
5. 从受控服务获取新客户端配置。
6. 只向已授权用户分发新的 server key 和服务器地址。
7. 验证旧客户端配置无法继续连入旧裸服务。
8. 验证未审批设备即使拿到服务地址，也会被准入 API 拒绝。

验收点：

- 客户端显示的新 key 与旧裸服务 key 不一致。
- 旧裸服务端口不再对公网开放。
- 新受控服务通过 `/internal/rustdesk/*` 完成准入判断。
- 禁用设备后，在缓存过期时间内或之后连接被拒绝。

## 内部 API 密钥轮换

适用场景：

- `RUSTDESK_API_INTERNAL_SECRET` 使用了示例值；
- 怀疑内部密钥泄露；
- 更换受控 `hbbs/hbbr` 镜像或部署节点；
- 定期安全轮换。

操作步骤：

1. 生成不少于 32 字符的随机密钥。
2. 同时更新 API 容器的 `RUSTDESK_API_INTERNAL_SECRET`。
3. 同时更新 `hbbs/hbbr` 容器的 `API_INTERNAL_SECRET`。
4. 重启 API、`hbbs`、`hbbr`。
5. 执行预检脚本。
6. 执行未注册设备、待审批设备、已审批设备的最小连接验收。

验收点：

- 不带内部密钥访问 `/internal/rustdesk/device/register` 返回 `ERR-2301`。
- 携带错误内部密钥访问同一接口返回 `ERR-2301`。
- 携带正确内部密钥时可以进入设备准入逻辑。
- `hbbs/hbbr` 日志中没有持续出现内部接口 401。

辅助命令：

```bash
scripts/deploy/controlled-key-rotation.sh generate-internal-secret
```

该命令只输出随机密钥，不会写入配置文件。请把输出值分别配置到 API 侧 `RUSTDESK_API_INTERNAL_SECRET` 和 `hbbs/hbbr` 侧 `API_INTERNAL_SECRET`。

## 自动化辅助脚本

本仓库提供 `scripts/deploy/controlled-key-rotation.sh`，用于减少手工误操作。

### 生成内部 API 密钥

```bash
scripts/deploy/controlled-key-rotation.sh generate-internal-secret
```

### 轮换 API signKey

```bash
scripts/deploy/controlled-key-rotation.sh rotate-sign-key ./server.yaml
```

脚本会先生成唯一备份并将权限限制为 `0600`，在配置文件同目录写好候选文件后再替换顶层 `signKey`；连续轮换不会覆盖上一份备份，符号链接配置文件会被拒绝。连续轮换、备份权限、字段保留和符号链接拒绝的 Linux 自测已通过。轮换后需要重启 API，并重新登录管理后台。

### 重置 RustDesk server key 目录

```bash
export CONTROLLED_KEY_ALLOWED_ROOT="$(pwd -P)"
export CONTROLLED_KEY_BACKUP_DIR="$CONTROLLED_KEY_ALLOWED_ROOT/key-backups"
install -d -m 0700 "$CONTROLLED_KEY_BACKUP_DIR"
scripts/deploy/controlled-key-rotation.sh reset-server-key-dir ./rustdesk-server-key --force
```

先核对当前工作目录确为独立部署目录、目标是其直接子目录，且备份目录与目标分离。脚本要求同时设置 `CONTROLLED_KEY_ALLOWED_ROOT` 和显式传入 `--force`；符号链接目标、根目录及高风险目录会被拒绝。备份采用独立目录并核对内容后才清空原 key 目录。缺少允许目录、符号链接、嵌套备份及成功备份/清空的 Linux 自测已通过；未对现用 key 卷执行本操作。操作后必须重启受控 `hbbs/hbbr`，并确认新 key 与旧裸服务 key 不一致。

## 回滚注意事项

1. 回滚 API `signKey` 会恢复旧登录态信任，应只在确认未泄露时使用。
2. 回滚 RustDesk server key 会让旧客户端重新具备连接能力，不能用于防绕过收口后的常规回滚。
3. 回滚内部 API 密钥时，必须确保 API 与 `hbbs/hbbr` 两侧保持一致。
4. 任何回滚后都必须重新执行预检脚本和最小连接验收。

## 预检命令

在受控 Compose 启动前运行：

```bash
export RUSTDESK_API_INTERNAL_SECRET="<至少 32 字符随机密钥>"
export RUSTDESK_CONTROLLED_SERVER_IMAGE="<改造版 rustdesk-server 镜像>"
scripts/deploy/controlled-preflight.sh .
```

在 Windows Git Bash 中运行时建议使用：

```bash
"C:/Program Files/Git/bin/bash.exe" --login scripts/deploy/controlled-preflight.sh .
```

## 上线安全检查

受控部署启动后运行：

```bash
export API_BASE_URL="http://127.0.0.1:12345"
export RUSTDESK_API_INTERNAL_SECRET="<当前内部 API 密钥>"
export PUBLIC_HOST="<公网访问域名或 IP>"
export OLD_RUSTDESK_HOST="<旧裸服务公网域名或 IP>"
scripts/deploy/controlled-security-check.sh
```

该脚本会检查：

- 内部准入接口无密钥时返回 `ERR-2301`；
- 内部准入接口错误密钥时返回 `ERR-2301`；
- 内部准入接口正确密钥时可以进入准入逻辑；
- 受控 `21115/21116/21117` TCP 端口可连通；
- 管理后台端口和 `21118/21119` Web 端口不对公网开放；
- 旧裸 `21115/21116/21117` TCP 端口明确拒绝连接。

端口探测直连目标，不通过 HTTP 代理；解析失败、超时或网络不可达不能记为端口关闭。缺少公网或旧服务地址时，脚本仅报告部分完成。UDP 不属于 TCP 探针的验证范围，脚本按 `RUSTDESK_HBBS_UDP_21116` 报告实际公网端口；当前 22xxx 部署应为 `22116/UDP`，容器内部才是 `21116/UDP`。即使脚本退出 0 且仅剩 UDP 警告，也不能将阶段 7 公网验收记为全部通过。
