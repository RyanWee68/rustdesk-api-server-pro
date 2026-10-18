# 原生 WSS 与浏览器远控

## 当前范围

2026-10-18 用户确认需要 WSS 与浏览器远控，并优先自托管合法可用的官方 Web 客户端。服务端直接终止 TLS，不新增外部反向代理，也不改造官方桌面客户端。

本轮开发了原生 WSS 传输和 HTTPS 客户端 API 分流。修复提交 `1a2c6d6` 的[远程 CI 39057113188](https://github.com/RyanWee68/rustdesk-api-server-pro/actions/runs/39057113188) 四作业全部成功，包含 Linux 24 项库测试及真实 WSS 三容器的在线准入、API 故障和恢复。传输及协议测试通过不等于浏览器完整远控通过，目标主机部署和官方 Web 客户端端到端验收仍待进行。

后续补齐公网传输门禁，并同步独立用户 fork `a8c1c2a`：主仓库 `606bef7` 的[39082466648](https://github.com/RyanWee68/rustdesk-api-server-pro/actions/runs/39082466648) 四作业全部成功，严格升级在真实三容器的 API 正常、故障和恢复窗口通过；独立 fork 的[39082930156](https://github.com/RyanWee68/rustdesk-server-controlled/actions/runs/39082930156) Linux 编译和 24 项库测试通过。服务端代码及隔离协议验证已补齐，0.211 部署和独立公网仍未执行。

官方说明：自托管 Web 客户端集成在 Server Pro 中，并要求符合条件的订阅。用户已确认没有授权及发行包，最新范围为先完成 WSS 服务端，浏览器页面暂停；不采购订阅，不下载或重新打包官方托管站资源，也不向第三方页面提供账号或令牌。仅在用户以后重新明确浏览器客户端来源时继续。[官方来源](https://www.rustdesk.com/blog/rustdesk-web-client-v2-preview/)

## 安全边界

- `hbbs/hbbr` 使用 `WSS_CERT_FILE` 和 `WSS_KEY_FILE` 加载同一目录中的证书链及私钥，完成 TLS 握手后才处理 WebSocket 消息。只允许 TLS 1.2/1.3，握手有超时限制。
- 两项均未设置时，WSS 禁用，直接拒绝 WebSocket 连接；仅设置一项、文件无效、证书与私钥不匹配、链接路径或 Linux 私钥权限过宽均拒绝启动，不回退明文 WS。
- WSS 部署的启动命令必须包含 `--require-wss`。旧二进制会因不认识该参数而失败，新二进制在没有证书时也会拒绝启动，避免旧镜像忽略环境变量后误暴露明文端口。
- 来源地址始终为实际 TCP 对端，忽略客户端提供的 `X-Real-IP`、`X-Forwarded-For`。本方案不支持在前面叠加未认证的代理并信任其转发头。
- TLS 只证明传输安全，不代替客户端登录、设备审批或中继授权核销。有效登录、用户和设备策略、短时中继授权及 API 故障默认拒绝继续执行。
- 共享出口 IP 中继继续拒绝，被控端密码学当前登录态证明仍是用户已接受的限制；浏览器接入不会改变这些边界。

## 部署准备

仅在目标网络恢复、审计遗留回滚单元及现用配置后执行，临时切换仍须预设自动恢复。以下是配置契约，不表示已经部署：

1. 从当前受控源码构建 server/API 镜像，使用不可变镜像 ID；不发布镜像仓库。
2. 准备主机上的规范绝对证书目录，证书 SAN 必须包含实际访问域名；私钥权限为 `0600`。只读挂载给两个 server，不复制进镜像或 Git。
3. 设置 `WSS_TLS_DIR` 为该目录；证书名默认 `server.fullchain.pem`，私钥名默认 `server.key.pem`。现有证书文件名不同时，通过 `WSS_CERT_NAME`、`WSS_KEY_NAME` 指定，不覆盖现用文件。
4. 合并基础、HTTPS 和 WSS 三份配置，先完整预检，再在保护窗口重建：

```sh
umask 077
docker compose -f docker-compose.controlled.yaml \
  -f docker-compose.controlled-tls.yaml \
  -f docker-compose.controlled-wss.yaml config --format json \
  > "${PRIVATE_DEPLOY_DIR:?set trusted directory outside Git}/wss-compose.json"
python3 scripts/deploy/controlled-compose-preflight.py \
  --config-json "$PRIVATE_DEPLOY_DIR/wss-compose.json"
```

`PRIVATE_DEPLOY_DIR` 必须是仓库外已有的受限可信目录，输出文件不得是已有链接。完整配置含私有凭据，不要把内容粘贴到聊天、日志或 Git。

WSS 覆盖不会自动扩大端口暴露。基础配置仍绑定回环，必须在隔离验收及自动回滚保护准备完成后，显式调整两个 WebSocket 宿主映射。拟使用端点为：

| 用途 | 端点 |
| --- | --- |
| 浏览器客户端 API | `https://rustdesk.jtzxsoft.com:22346`，仅客户端 API 路径转到 API 监听端口 |
| ID WSS | `wss://rustdesk.jtzxsoft.com:22118/` |
| Relay WSS | `wss://rustdesk.jtzxsoft.com:22119/` |

这不是官方 Web 客户端各输入框的填写说明；具体 UI、路径和设备身份字段需取得发行包后核对。届时路由器仅增加 TCP `22118/22119` 到主机相同端口，不开放旧 2111x 端口，不转发局域网 HTTP 管理 `22347`，也不改变现有 TCP/UDP 远控端口。尚未通知进行此映射。

`controlled-security-check.sh` 默认仍要求 WebSocket 公网端口明确拒绝连接。新增的可选 WSS 模式只在完整设置以下四项时，改为验证两端的证书链、主机名、TLS 1.2 以上及严格 WebSocket 升级；缺项或任意端点失败均不通过，不把 TCP 可连接当作安全通过。本轮没有开放这些端口。

```sh
export PUBLIC_HOST=rustdesk.jtzxsoft.com
export RUSTDESK_HBBS_WEB_PORT=22118 RUSTDESK_HBBR_WEB_PORT=22119
export PUBLIC_WSS_HBBS_URL=wss://rustdesk.jtzxsoft.com:22118/
export PUBLIC_WSS_HBBR_URL=wss://rustdesk.jtzxsoft.com:22119/
export PUBLIC_WSS_CA_FILE="${PRIVATE_DEPLOY_DIR:?set trusted directory outside Git}/trusted-ca.pem"
```

其余 API、管理 HTTPS、明文管理端口关闭及旧服务检查参数继续按实际部署设置，再运行 `sh scripts/deploy/controlled-security-check.sh`。CA 必须是事先核对的普通非链接 PEM 文件，不能从当前待验入口临时下载后直接信任。URL 必须与 `PUBLIC_HOST` 和对应 Web 端口一致，两个角色必须使用不同端口；仅允许根路径，无凭据、查询或片段。

也可单独执行只读传输检查，不需要内部密钥，不发送账号或业务令牌：

```sh
python3 scripts/deploy/controlled-wss-protocol-acceptance.py --public \
  "$PUBLIC_HOST" "$RUSTDESK_HBBS_WEB_PORT" "$RUSTDESK_HBBR_WEB_PORT" \
  "$PUBLIC_WSS_CA_FILE" "$PUBLIC_WSS_HBBS_URL" "$PUBLIC_WSS_HBBR_URL"
```

该模式仅证明执行位置到指定入口的受信任 WSS 升级；明文拒绝还须服务端新增审计，业务允许/拒绝及浏览器完整远控仍须另验。从内网、NAT 回环或受 TUN 影响的主机运行，不能记为独立公网验收。完整安全脚本保留这些未验证警告及 UDP 边界，不会因 WSS 传输通过而宣称整体完成。

HTTPS 管理入口现在按路径分流 `/api`、`/api/*`、`/lic/web/api`、`/lic/web/api/*` 到客户端 API；其他路径留在管理路由。路径先规范化用于边界判断，`/api/../internal` 不能转入内部 API。浏览器应使用 HTTPS API，不能从 HTTPS 页面调用现有明文客户端 API。

## 验收入口

- server 库测试覆盖受信任 WSS 二进制往返、错误证书、错误主机名、证书私钥不匹配、未配置及明文请求拒绝、握手超时；Linux 另验证私钥权限与链接拒绝。
- `controlled-compose-preflight.py --self-test` 包含原生能力参数、只读目录、双端一致性及证书路径的负向回归。静态配置通过不代替容器实际加载证书。
- `controlled-three-compose-smoke.sh` 在随机项目、内部网络且无宿主端口的环境生成一次性证书，真实验证两端 WSS 升级、证书身份拒绝、明文拒绝、在线准入、API 故障和恢复；测试后清理容器、卷、网络及测试证书。
- `controlled-wss-protocol-selftest.py` 验证握手字段、摘要大小写、重复头、未协商扩展/子协议、响应大小与总超时、URL/CA 参数边界，并用一次性回环证书执行真实双端 TLS 升级、错误身份及明文假服务拒绝。已接入本地综合验收，临时材料不进入仓库。
- 当前服务端仍需目标部署、真实证书和独立公网入口验收。浏览器页面已暂停；若以后恢复该范围，再补官方 Web 客户端的已登录且已审批连接成功、未登录/待审批/禁用/关闭中继/API 故障拒绝及恢复证据，现有协议探针不能替代这些人工结果。
