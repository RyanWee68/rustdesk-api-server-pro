# 受控 RustDesk Server 固定基线补丁

本目录的补丁针对官方 `rustdesk/rustdesk-server` commit
`a7736be5e40f85bfc141120dce587e836e5d4b80`，其 `libs/hbb_common`
子模块为 `69cea8dafee147848ae88702029f4bf7df7224c3`。

在干净的官方源码副本中初始化子模块后，从 RustDeskWeb 仓库根目录执行：

```bash
scripts/deploy/controlled-fork-apply.sh /path/to/rustdesk-server
```

脚本仅在上述精确基线应用补丁，不会创建提交。补丁包含两个二进制的准入接线和
`src/controlled_admission.rs`，无需再运行资料复制脚手架。此副本应作为独立的
`rustdesk-server` fork 维护，并按 AGPL-3.0 许可要求处理发布。

2026-10-12 已建立独立本地维护仓库 `D:/WorkSpace/Other/RustDeskServerControlled`，
维护提交 `adb8c245135396e191f3bf6a042eea0d6a46695f` 保存完整补丁，库测试 16/16
通过；远程 fork 后续已推送至用户指定私有仓库，维护提交
`6a2be11f2a4332c9ee8ec23d1d0720fba4cc5002` 的远程 CI 已通过。
2026-10-13 显式强制中继修复已作为 `41e846f` 推送；远程维护 CI
运行 `38346988802` 已完成并通过固定子模块核对、Linux 双二进制编译和 16 项库回归。
镜像构建仍从固定官方基线应用本目录补丁。

改造后的行为：

- `MUST_LOGIN=1`、`API_SERVER`、`API_INTERNAL_SECRET` 是启动条件；
- `RegisterPeer` 只要求重新提交含 UUID/公钥的 `RegisterPk`，不更新设备地址；
- `RegisterPk` 将原始 UUID 和公钥以 Base64 文本登记，审批和心跳失败时拒绝；
- TCP/WebSocket 连接检查控制端 token 和被控端策略；
- hbbs 为中继请求签发 30 秒双端授权，hbbr 对双方实际 IP 分别在线核销；
- 显式强制中继在初始 PunchHoleRequest 路径先签发，再用同一 UUID 通知双端；
- API 请求失败时新连接和新中继默认拒绝，不使用允许结果缓存；
- `RUSTDESK_KEY_DIR` 指定 server key 的工作目录。
- 在未建立可信代理身份前，hbbs/hbbr 的 WebSocket 入口忽略客户端自带的转发来源头，仅使用 TCP 对端地址。

Windows Rust 1.99.0 的 `cargo check --bins`、Linux release 镜像构建与隔离运行已通过。
2026-10-10 已审批的官方 1.4.9 客户端单次远控成功；2026-10-12 隔离三容器中，
真实 hbbs 签发未过期双 IP 授权、hbbr 双端核销和重放拒绝通过，加密连接策略拒绝
及 API 停止时默认拒绝通过。尚未完成官方客户端完整负向、NAT/代理换出口、
WebSocket 正常连接及正式环境验收；局域网正式端口已切换并有重复正向实测。
新增显式强制中继修复仍需更新后的官方客户端实测。中继授权绑定实际观察到的 IP；相同出口 IP
的合法双端当前被 API 拒绝，需独立角色证明后才能恢复支持。

上线阻断项：UDP 注册拒绝已有隔离探针，但 UDP 连接入口仍需逐路径审计；
WebSocket 明文令牌拒绝已验证，正常 WebSocket 客户端连接尚未验收。当前结果不能
视作公网防绕过验收，正式暴露前还需完成官方客户端、跨网络身份和端口扫描。
Linux 镜像的 `ldd` 检查及隔离运行已通过，不代表其他运行基底兼容。
