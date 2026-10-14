# RustDesk 官方协议与内部准入映射

更新日期：2026-10-12。server 基线为 `a7736be5e40f85bfc141120dce587e836e5d4b80`，官方 1.4.9 客户端已有单次远控实测；独立本地 fork 的维护提交为 `adb8c245135396e191f3bf6a042eea0d6a46695f`，完整负向和跨网络联调仍未完成。

共享出口逐角色证明、被控端当前登录态租约及可信 WSS 边界设计见 `CONTROLLED_RUSTDESK_ROLE_PROOF.md`。该设计尚未实现，需要客户端配合；当前仍同 IP 拒绝，不能把历史双 IP 核销证据写成共享 NAT 已兼容。2026-10-12 晚的局域网正式端口切换和真实回滚不改变这些协议限制。

## 已核对的协议事实

| 消息或调用 | 上游字段语义 | 内部接入要求 |
| --- | --- | --- |
| RegisterPeer | 设备 ID 与序列号，无登录 token | 不能把心跳当登录证明 |
| RegisterPk | 设备 ID、二进制 UUID、公钥 | 统一编码 UUID/公钥指纹，先在 server 验证协议身份 |
| PunchHoleRequest | 目标 ID、控制端 token | 使用 connection/check 分别校验控制端与被控端 |
| 客户端 request_relay 发往 hbbs | 目标 ID、控制端 token、新生成的会话 UUID | 使用 connection/check，relay=true；会话 UUID 不写入设备表 |
| 客户端 create_relay 发往 hbbr | 目标 ID、会话 UUID、licence_key，未显式填入 token | 不能直接使用要求设备 token 的 relay/check 完成官方客户端接入 |

来源：[官方协议定义](https://github.com/rustdesk/hbb_common/blob/main/protos/rendezvous.proto)；[官方客户端 request_relay/create_relay](https://github.com/rustdesk/rustdesk/blob/master/src/client.rs)。链接指向上游活动分支，后续选定基线时需改为固定 commit。

## 本次实现

新增内部 `POST /internal/rustdesk/connection/check` 与 Rust 模板的 `check_connection` 方法。接口以控制端 token 解析来源身份，目标 ID 仅用于检查被控端设备。返回双方策略交集，不修改设备归属。

原有 auth 和 relay/check 保持“token 属于所指定设备”的语义。注册及心跳仅判断设备策略，不承诺登录态。API 不可用时，Rust 模板通过逐次在线校验拒绝新请求，不复用先前允许结果。

## 尚需实现的协议层工作

1. 固定客户端兼容基线，实测 UUID 与公钥编码；server 使用的 `hbb_common` 子模块已固定为 `69cea8dafee147848ae88702029f4bf7df7224c3`。
2. hbbs 的注册、心跳和发起连接入口已有 API 接线，但仍需实机验证输入身份；不能仅凭客户端自报 ID、公钥或来源 IP 认定设备可信。
3. 已在固定 server 基线补丁中实现 hbbs 签发与 hbbr 双端核销的短时会话授权，并限制会话 UUID、目标、双方 IP、有效期和重放。当前 API 对同 IP 双端拒绝签发，也拒绝遗留同 IP 授权核销；共享出口 IP 的合法双端暂不支持中继。仍需通过真实客户端验证公网 IP 变化、代理和并发路径，并为同 IP 场景设计独立角色证明；不能把仅编译通过等同于防绕过验收。

`hbbr` 的 `CreateRelay` 入口只向 API 发送会话 UUID 和观察到的来源 IP，本地无法再次比较目标 ID；目标身份由 API 中已签发的会话记录、设备与用户状态核验。Rust 侧已覆盖 API 不可达、响应不完整、策略拒绝和过期时的签发/核销拒绝测试，但同公网 IP 下的独立角色证明仍待协议设计和实机验证。
4. 明确被控端登录态验证方案；当前 connection/check 仅要求其审批与绑定用户策略有效。
5. 同时验证 TCP、WebSocket、中继直连及 API 宕机路径，记录官方客户端成功和拒绝案例。

## 固定补丁的 UDP 入口静态核对

在固定 server 补丁中，UDP `RegisterPeer` 只要求客户端发送 `RegisterPk`，不更新设备地址；UDP `RegisterPk` 必须经注册和心跳 API 放行后才更新 peer 表。UDP `PunchHoleRequest`、`PunchHoleSent`、`LocalAddr` 分支直接丢弃；TCP/WebSocket `PunchHoleRequest` 经双端连接 API 检查，`RequestRelay` 经中继签发。hbbr 在会话配对前在线核销每个端点。源码检查脚本已对接线点复跑，结果为 0 失败、0 警告。

2026-10-12 隔离探针验证四类 UDP 打洞/通知/本地地址/中继消息无响应，API 正常、停止及恢复阶段均通过；另一来源伪造无 UUID 心跳后，后续真实中继授权仍绑定原注册 IP。该结果不包含反射目标抓包、全部字段组合或官方 UDP 客户端验收，NAT/代理身份仍有缺口。

WebSocket 路径当前以 `secured=false` 调用处理，携带 token 的请求被拒绝；明文令牌拒绝已有探针，但不能据此宣称正常带登录态 WebSocket 客户端可用。恢复支持前需明确该传输的可信加密入口。

本文件解释了原有四接口不能直接完成官方客户端接入的原因。固定基线补丁见 `patches/rustdesk-server/`；阶段 4 的官方客户端联调与防绕过验收仍未完成。
