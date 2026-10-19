# 受控 RustDesk 正式切换与回滚

## 2026-10-19 WSS 现用窗口

15:38 已在独立 45 分钟保护下更新 hbbs/hbbr，server 固定 `sha256:009a8e77e509324ac69a187267f80c06dd40fefaa7ad7bf6227dccd31e2e2f78`；API 保留已验性能镜像 `4b4f20d...`，未重建。完整隔离 TCP/WSS 双版本验收、原证书 TLS 1.2/1.3、现用回环 WSS 严格升级/在线拒绝审计/明文拒绝，以及 API 和管理入口检查通过。WSS `22118/22119` 仍仅回环，不增加路由器映射，不计公网或浏览器完整远控通过。

root 私有备份为部署目录下 `backups/wss-update-20261019-window2`。`controlled-wss-update-rollback-20261019-window2.timer` 预定北京时间 **16:23:27**；恢复前保留更新后的 server 数据及配置，再恢复旧 server 数据/配置，仅重建双 server，不恢复 API 数据或重启 API。用户桌面客户端三次远控回归待收，保护尚未取消。需要提前恢复时，仅停止该 timer，再启动同名 `.service`；不要使用旧 API 窗口恢复整份数据，不要覆盖本轮保留的性能更新。

本节覆盖下方早期“网络不可达、TLS 未部署、WSS 尚未切换”等快照；若人工反馈晚于回滚时刻，必须先核对实际镜像与启动时间，不能将回滚后的连接算成本次候选通过。

2026-10-18 范围补充：用户确认保留官方客户端，共享出口独立角色与被控端密码学当前登录态证明移出本期范围，作为已接受限制保留，不再列为本期上线待开发项。共享出口中继仍拒绝，数据库有效令牌不等于密码学登录态证明；原生 WSS 及隔离双向协议验证已通过，目标部署与下述实机验收待办不变，浏览器页面暂停。以下 2026-10-17 主机状态是历史快照，不代表当前可达或已部署后续修复。

更新时间：2026-10-18，以下运行状态来自 2026-10-17 及更早快照，不代表目标机当前状态。已完成授权主机局域网正式端口切换、原容器真实回滚及再次切换；旧容器删除后又从离线材料完成隔离重建和 API 健康验证。三容器宿主端口已迁移到 22xxx；公网管理入口为 `https://rustdesk.jtzxsoft.com:22346`，另有仅绑定局域网的 HTTP 管理入口 `http://192.168.0.211:22347`，禁止路由器转发后者。证书与客户端分发页面已部署，Windows 人工安装仍待核对。此前公网 HTTPS、客户端 API 及 RustDesk 原生 TCP 端口检查通过，用户确认 `22116/UDP` 已转发且旧公网 2111x 映射已删除；官方 1.4.9 跨网络普通连接自动中继已通过。0.211 短时恢复连接时三容器健康、HTTPS/明文拒绝/下载摘要复核通过，但发现现用 Compose 没有显式声明 TLS 三项环境变量；候选修复已通过预检但未部署。准备回滚保护时命令被中断，当前又无法连接 0.211；恢复连接后必须先审计临时回滚单元、Compose 差异和容器状态。旧 2111x 只随独立公网扫描复核关闭状态，不再作为单独配置阻断项；WSS 目标部署仍未完成，共享出口角色证明按用户决定移出本期范围并维持拒绝限制。

## 网络恢复后的更新顺序

双端新版补充（2026-10-19 收到）：用户确认被控端升级 1.5.0 后，双端官方 1.5.0 三次远程均成功，并明确更正时间为 **15:04、15:05、15:06**，原 14 点记录为笔误，时间待核对项关闭。该组功能结果按用户反馈通过，尚未逐次关联服务端审计；WSS、强制中继与其他出口条件不计通过。

2026-10-19 14:58 最新混合版本结果：用户补充两次远程成功，结合 14:54 的一次，官方 1.5.0 发起端 `487921466` 到保持 1.4.9 的 `443005947` 已完成三次断开重连验收。仅按这组方向和版本结项，不计强制中继、其他网络出口、双端新版或 WSS 已通过；下述“尚差两次”为早先收到一次时的历史状态。

2026-10-19 14:54 混合版本补充：用户确认发起端 `487921466` 已升级官方 1.5.0，连接 `443005947` 成功，被控按本轮安排保持 1.4.9。三次重复验收已收到一次成功，尚差两次；未说明强制中继或网络出口，不归入对应矩阵。新版 API 保留状态不因本次记录变更，双端新版与 WSS 仍待验收。

最新确认（2026-10-19 14:41）：用户打开 `/#/home` 后进入系统，退出后重新 admin 登录正常，结合 14:19 的 1.4.9 远控成功，本轮 API 基线验收完成。主机复核仍为 14:17:10 启动的同一新版容器、重启 0，三容器和四入口健康、证书未变；已取消 API 更新窗口自动回滚，确认恢复服务未执行，新版正式保留。旧镜像及完整备份继续保留。初次 403 根因未确认，不能将恢复写成已证实缓存问题。下一步是 1.5.0 混合/双端实机验收及另开 WSS 更新窗口，下述“保护仍活动/403 未恢复”为先前窗口记录，不代表最新状态。

人工验收补充（2026-10-19）：用户 14:19 证实 1.4.9 远控正常，但 admin 登录域名管理页出现 403 且返回首页无响应。本窗口未通过验收，15:02:08 自动回滚保留，未取消。管理员标志未改，合成真实管理路由角色回归及独立浏览器模拟登录通过，真实故障根因仍待定位；已请用户强制刷新/无痕复验，不应擅自放宽权限或将模拟结果写成生产成功。后续动作必须先复核计时器和现用镜像，超出窗口的成功不能用于取消已执行的恢复。

最新窗口（2026-10-19 14:17）：新版 API 与管理页已切入候选镜像 `sha256:45f60d858addcbc1aa95e5ad7a776d29f71d55f9691ae517f4b8a7368a3e1d9f`，原 TLS 配置与证书保留，官方 1.5.0 安装包已上线且两版安装包/证书 HTTPS 下载摘要核对通过，入口和库完整性检查通过，双 server 未变。新自动回滚 `controlled-api-update-rollback-20261019-window1` 预定北京时间 15:02:08，当前待用户 1.4.9 连接及管理页确认；没有取消保护。若回滚执行，停 API 后保留更新后 data，再恢复窗口前完整 data 与配置，不合并期间写入，因此本窗口应避免管理配置变更。下一次操作先核对实际任务与现用镜像，不将窗口中状态作为最终完成证据。

最新状态（2026-10-19 14:10）：TLS 第二窗口已完成。用户 14:09 官方 1.4.9 连接成功；主机复核本窗口回滚未执行、API 仍为 13:51:39 启动的同一容器，TLS 三项已生效，镜像与证书未变，三容器健康，HTTPS 200/同端口 HTTP 400/LAN 管理 200/API 健康 200。已停止第二窗口自动回滚计时器并确认回滚服务未执行，TLS 配置正式保留。后续从新版 API 候选更新步骤继续，必须另建独立恢复保护；下述第一窗口失败归属仅为历史记录。

2026-10-19 13:47 复核：上述 TLS 窗口的自动回滚已经执行，API 启动时间为北京时间 12:15:18，TLS 三项环境变量已恢复为空，现用镜像未改变。用户 13:46 官方 1.4.9 成功连接仅是回滚恢复证据，不能用于关闭 TLS 更新验收。三容器健康、双 server 未重启；下一窗口重新建立保护，不复用已结束的定时器。

2026-10-19 后续窗口：现用 API 已在备份与独立自动恢复保护下，仅应用原候选的 TLS 三项并重建，四入口及证书不变复核通过；尚缺客户端连接确认。该窗口回滚预定北京时间 12:14:54，记录不代表保护已取消，下一次操作必须先核对实际任务与 Compose，不能照抄窗口中状态。新版 API 镜像 `sha256:45f60d858addcbc1aa95e5ad7a776d29f71d55f9691ae517f4b8a7368a3e1d9f` 已在目标无网络、无宿主端口的数据副本上启动并通过健康与库完整性验证，测试容器已停止，尚未切入现用服务。

2026-10-19 用户已通知网络恢复，原有 SSH 身份验证成功；已在目标通过标准输入执行下述只读检查，未发现受控回滚单元，三容器健康且累计重启次数为 0。HTTPS、同端口明文拒绝及内网 HTTP 入口复核通过，TLS 三项环境变量仍缺失，尚未部署任何更新。以下顺序继续适用，检查快照不替代变更前的备份及自动恢复保护。

复用现有 SSH 身份进入目标主机，不生成替代密钥；先同步经过验证的工具到私有工作目录，再在主机本地执行：

```bash
python3 scripts/deploy/controlled-rollout-readiness.py --check
```

本工具仅运行 `systemctl show`、`systemctl list-unit-files` 与带字段白名单的 `docker inspect`，不打印环境、启动命令、健康日志、密码或令牌。依据 [systemd 官方说明](https://www.freedesktop.org/software/systemd/man/258/systemctl.html)使用属性查询读取已加载单元，并额外检查磁盘单元，避免仅看当前活动计时器而漏掉旧任务。发现任何 `controlled-*rollback*` 服务/计时器（含未启用、已屏蔽或历史失败单元），或三容器不完整、未运行、无健康检查、未健康、命令失败或结果损坏时，均返回非零，不自动停止或删除单元。

1. 就绪检查若报告遗留单元，在主机本地私下核对其用途、备份路径、执行内容与实际现用配置，重点检查 `controlled-tls-contract-rollback-20261017`。不要把 `systemctl cat`、完整 `docker inspect` 或私有 env 输出粘贴到报告。确认只是历史遗留后按既有运维流程处理，再重新运行检查。容器镜像 ID 和累计重启次数只作快照，不能证明持续稳定或允许发布。
2. 保存当时实际运行的镜像 ID、私有 Compose/env、业务库一致性备份、公钥与证书公开摘要；核对回滚材料可读，不能把文档中的历史镜像 ID 当成当前候选。先修正 TLS 三项显式环境变量，在独立自动回滚保护下只重建 API，验证 HTTPS、明文拒绝及 1.4.9 现用连接。不要与下一项一次性合并，避免无法定位回退范围。
3. 目标主机本地构建包含 `c84469f` 的 1.5.0 兼容升级、`e5bf77c` 的认证事务/有效期修复、`ed92102` 的 TLS 材料保护及后续修正的候选；记录实际 Git 提交、API/server 镜像 ID 与程序摘要。不能使用下文 2026-10-12 的历史候选代替，也不推送镜像。每个更新窗口均先确认独立自动恢复已生效，再只更新对应服务；WSS server 更新单独处理。保留旧镜像和当时私有配置，不清库、不轮换公钥、不批量撤销有效会话。
4. API/前端更新后核对两版下载摘要，先保留 1.4.9 客户端确认恢复，再做 1.4.9/1.5.0 混合及双端新版实机矩阵。旧无有效期的未完成 2FA 挑战须重新登录，真正有效的既有令牌不批量注销。实机证据与服务端审计对应后再关闭该窗口自动回滚。
5. 原生 WSS 部署先保持路由器端口不扩大，在隔离或局域网验证证书、严格升级、明文拒绝和业务准入；通过后再安排独立外网门禁。使用下文无凭据公网模式检查公开端点与端口，并分别记录 UDP、Windows 信任安装和官方客户端结果。真实 OAuth/OIDC 仍待用户提供服务，不以无服务或模拟结果结项。

本检查用于新维护窗口建立回滚保护之前；它不会区分“历史遗留”与“本次刚设定”的回滚单元。新窗口的自动恢复已生效后，再运行本工具也会因发现该保护任务而拒绝；此时应按窗口计划人工核对，不得为了让工具变绿而删除仍需生效的保护。

就绪快照只覆盖当前系统管理器中匹配 `controlled-*rollback*` 的单元，不覆盖其他命名、用户级 systemd、cron 或外部调度，不替代运维审阅。它不持锁，也不证明快照后状态未改变；所有变更前仍须重新确认状态、备份及新的自动回滚保护。离线验证仅运行 `--self-test`，不会读取本机 Docker/systemd 或访问网络。

### 候选 TLS 材料检查

新版 API 启动 HTTPS 时，证书与私钥必须为两个不同的普通非链接文件且正确配对，证书必须处于有效期内；Unix 私钥不得允许组或其他用户访问。仅当两个文件均不存在时才自动生成十年有效期的自签名材料，使用独占创建，不覆盖既有文件。显式只配置一个路径、仅缺半对、解析或配对错误、过期或权限过宽均返回 `ERR-B011`，不自动重签或改权限。

更新前应在主机本地核对已有证书与私钥、公钥/公开摘要、有效期及文件权限；历史自动生成的私钥可能继承宽权限，须在审核后仅收紧该私钥的权限再更新。不要删除证书或密钥来使服务自动生成，不要把新证书下载摘要冒充原有受信任证书。检查失败只拒绝 HTTPS 监听，不代表客户端 HTTP API 一并停止，也不能替代既有 HTTP 管理访问限制。加载成功仍须按 HTTPS 公网门禁验证信任链、域名、下载摘要与明文拒绝，WSS 使用独立的原生服务端检查；此修改不代表 WSS 或目标机已更新。

## 本次切换结果

1. 用户允许原 `12345` 服务停机、删除。切换及真实回滚验收期间先停止并重命名原容器；2026-10-13 再次确认离线备份、迁移完整性、旧令牌撤销和新公钥持久化后，已删除停机的旧容器。原应用目录、数据库、密钥归档和切换报告仍保留。
2. 停机前预设 20 分钟独立 systemd 自动回滚；配置副本严格解析及最终 Compose 预检先通过才停机。首次预检因旧 YAML 没有 `rustdeskServer` 区段而终止，原服务未重启；补齐默认区段后重试成功。
3. 原应用完整目录与原 key 挂载目录离线归档，分别执行 tar 内容比较，旧 SQLite 完整性检查通过，归档及容器清单摘要已记录。备份目录权限 0700，文件 0600，仅保存在主机 root 私有目录。
4. 新数据来自独立副本，SQLite DSN 和静态资源路径按新镜像核对；新副本轮换 signKey 和内部密钥，撤销旧登录令牌，保留 `.init.lock`、原账号和业务数据，设备不自动审批。原 OIDC 未启用、OAuth 提供者数量为 0；外部服务联调不计通过。
5. 使用固定 API 镜像 `sha256:eb587aa52cda3c7a7618f057eca4deabe347c6472e1f62c5f2350d77f149184f` 与 server 镜像 `sha256:91746f12dbf37ff9b1ae135db24734ed593125b15cdaa533e6d4202e90036b99`。新建 server key 卷，hbbs 宣告局域网中继地址。API、新管理页与三容器健康通过。
6. 停止新项目但不删除卷，恢复原容器名并启动；原 API 和原局域网管理页返回 200，原镜像及 YAML 摘要不变。再停止原容器、恢复保留名并启动新项目，健康通过；新数据库完整性、零自动审批、旧 token 全部撤销及脱敏、备份摘要再次核对通过。
7. 新公钥写入 API 配置并重启 API 后健康通过，server 密钥及卷不变。2026-10-13 已确认历史隔离资源与正式挂载分离，并清理四个历史测试容器、六个测试卷和一个测试网络；2026-10-14 又清理三只无容器引用的旧局域网 PoC data/key/log 卷，并复核正式部署文件、API 配置与正式 key 卷公钥一致。正式三容器及正式数据、key、日志均保留。
8. 成功后取消本次自动回滚定时器。主机私有部署目录保留 `cutover.py`、`runtime.env`、`cutover-report.json` 和 `server-public-key.txt`；操作脚本的三个回滚时序与名称冲突保护自检通过。需要回滚时，在主机使用私有部署目录中的脚本执行 `python3 cutover.py rollback`；先暂停新管理写入并保留新库，脚本不合并切换后的数据。

最近已记录的容器为 `rustdesk-api-server-pro`、`rustdesk-hbbs-controlled`、`rustdesk-hbbr-controlled`；旧容器 `rustdesk-api-server-pro-precontrolled` 已删除。客户端 API `192.168.0.211:22345/TCP` 保持不变；管理宿主端口 `192.168.0.211:22346/TCP` 映射容器 TLS `12443`，内网 HTTP `192.168.0.211:22347/TCP` 映射容器明文管理端口 `12346`。后者仅绑定局域网地址，不得配置公网转发。hbbs `:22115/TCP` 与 `:22116/TCP+UDP`、hbbr `:22117/TCP` 仅绑定主机局域网 IP，WebSocket `127.0.0.1:22118/22119/TCP` 仅回环。`hbbs` 对外宣告公网中继 `171.217.92.118:22117`，并通过 `MASK=192.168.0.0/16`、`LOCAL_IP=192.168.0.211:22117` 向内网客户端返回局域网中继。管理证书为覆盖 `rustdesk.jtzxsoft.com`、公网 IP 和局域网 IP 的自签名证书，私钥权限为 `0600`；原宿主端口已关闭，路由器已转发 22xxx 端口，用户确认 `22116/UDP` 规则已开启；仍需逐台固定信任管理证书并从独立环境复核未开放端口。

迁移后 API `/api/health` 与管理页均可用，三容器 healthy；2026-10-16 13:39，官方 1.4.9 从内部端 `192.168.21.23` 普通连接外部端 `171.213.15.205` 成功，`hbbr` 记录同一 UUID 双端配对。server 当前固定为本地镜像 `sha256:45505751dd4205e12bec7baa34cc826939f73789335935281fbc9647c4563fa9`，API、数据库、公钥与端口未因本次更新改变。LAN/公网 HTTP 仍有凭据传输风险；正常 WSS、独立公网扫描、共享出口角色和真实外部认证仍待验收，不能因本次跨网络连接成功而认为全部生产验收已通过。

## 历史基线（原服务切换前）

- 原 `rustdesk-api-server-pro` 使用 `alpine:3.20.3` 包装，以 `/app/start.sh` 启动；实际网络为 bridge。
- 宿主 `12345` 已由原 API 占用，原管理端口绑定内网 `12346`。正式三容器 Compose 的固定容器名和 API 端口均会冲突。
- 原应用通过宿主目录挂载 `/app`，另有 `/root` 挂载；实际宿主路径仅保存在仓库外私有部署配置中。
- 有效旧库和配置位于容器 `/app/data/server.db`、`/app/data/server.yaml`，初始化标记为 `/app/data/.init.lock`。不要误用 `/app/server.yaml` 替代当前持久配置。
- 旧库完整性检查通过；有 2 个用户、2 台设备、6 条令牌。旧设备表缺少审批和中继策略字段。
- 新 Linux 程序在旧库只读快照的无网络副本上连续迁移两次通过，30 张原业务表数据保留，令牌脱敏且没有增加已审批设备。追加原有效 YAML 严格解析、实际加载与内存往返通过；原 YAML 加迁移库副本启动新版 API，健康检查通过且配置未改写。未覆盖外部 OAuth/SMTP/WebAuthn 联调、客户端或正式端口。

## 历史切换条件（非下一次更新配方）

1. 当时使用 `rustdesk-controlled-api:test-20261012-online-v1`，镜像 ID `sha256:eb587aa52cda3c7a7618f057eca4deabe347c6472e1f62c5f2350d77f149184f`，包含迁移及在线超时时区修复，后端全量测试、完整三容器验收及迁移/恢复副本复验通过。旧 `test-20261012-migration-v1` 不含在线超时修复，`test-20261012-v2` 还缺迁移修复。这些都是历史候选，不包含后续 1.5.0 和认证修复；下一次更新按本文最新顺序重新构建并固定实际摘要。
2. 完成官方客户端负向验收、跨网络策略和正式暴露检查。共享出口 IP 的双端目前仍拒绝中继；带 token 的 WebSocket 请求当前默认拒绝，正常 WebSocket 客户端不应列为已支持。
3. 在私有部署配置中明确 `SOURCE_APP_DIR`、`SOURCE_KEY_DIR`、`CONTROLLED_DEPLOY_DIR`、`BACKUP_DIR`、`PRIVATE_ENV`。这些目录必须彼此分离；新 `data` 不得指向原应用目录。
4. 准备管理员凭据、独立内部 API 密钥、新 server key 及客户端配置。旧库迁移后设备仍须审批，用户远控/中继策略须逐项核对，不能批量自动审批。
5. 核对客户端 Relay 地址；如需 hbbs 宣告中继地址，在私有 Compose 覆盖中为 hbbs 设置 `-r <客户端可达地址>:21117`。
6. 已准备不可变镜像 ID 的离线候选包，见 `CONTROLLED_RUSTDESK_OFFLINE_RELEASE.md`；正式使用前核对全部文件摘要，并在独立部署目录运行 `controlled-compose-preflight.py`，检查实际端口覆盖、原数据目录隔离和 key 卷定义。预检现区分当前受控 API 容器与旧容器，允许现用容器复检自身目录，旧容器或 `-precontrolled` 保留容器仍须与新数据分离；key 卷检查拒绝外部卷、宿主绑定和非本地驱动。26 类危险覆盖 Linux 自测及 0.211 当前正式 Compose 预检均已通过；静态检查仍不能证明同名 Docker 卷是全新生成的，须另外核对卷来源、公钥和轮换记录。原数据保护只识别上述容器名，不能代替完整路径审阅、停机备份及正式端口占用检查。

## 无目标主机的离线预检

自定义现有证书文件名及默认 HTTPS/WSS 合并配置已通过 `d829577` 的[完整 CI 39095818469](https://github.com/RyanWee68/rustdesk-api-server-pro/actions/runs/39095818469)，四作业成功。该结果确认配置变量保留，不证明 0.211 实际证书文件、回滚单元或当前服务状态；目标操作仍按下述顺序执行。

`controlled-compose-preflight.py` 已支持仅 HTTPS 管理入口以及 HTTPS 加局域网 HTTP 的组合：容器 `12345/TCP` 必须发布，管理端口 `12346/TCP`、`12443/TCP` 至少一个发布；明文管理仍必须绑定回环或明确的 RFC1918 IPv4，WebSocket 仍必须只绑定回环，重复端口和错误协议仍拒绝。发布 `12443` 本身不能证明服务已启用 TLS。

0.211 当前私有部署的实际证书文件名是 `data/tls/rustdesk.jtzxsoft.com.fullchain.pem` 和 `data/tls/rustdesk.jtzxsoft.com.key.pem`。现用持久化 `server.yaml` 已引用这两个文件并能提供 HTTPS，但 Compose 尚未显式声明 `TLS_PORT=12443`、`TLS_CERT_FILE=/app/data/tls/rustdesk.jtzxsoft.com.fullchain.pem`、`TLS_KEY_FILE=/app/data/tls/rustdesk.jtzxsoft.com.key.pem`，所以不能按当前预检独立重建。下次连接后的处理顺序必须是：先核对并清理可能遗留的 `controlled-tls-contract-rollback-20261017` 单元，再确认现用文件仍等于备份、候选仍只增加上述三项，最后才在新的自动回滚保护下重建 API 并复验。

在有 Docker 的环境生成最终配置 JSON 后，可在无 Docker、无法访问目标主机的电脑执行静态校验。最终 JSON 可能包含密码与内部密钥，只能存放仓库外受保护目录，不得提交 Git、上传或粘贴到聊天。

```bash
python3 scripts/deploy/controlled-compose-preflight.py --config-json "$PRIVATE_COMPOSE_JSON"
python3 scripts/deploy/controlled-compose-preflight.py --self-test
```

离线入口不会调用 Docker 或发起网络连接；成功只表示 JSON 契约检查通过，不包含现用数据挂载重叠、卷来源、宿主端口占用、实际 TLS 配置与证书或路由器转发检查。网络恢复后仍须执行原有完整预检和运行时 HTTPS、明文拒绝及独立公网检查。公网安全检查中的 `FNOS_ADMIN_HTTP_PORT` 应指定明文管理宿主端口 `22347`，不得把允许开放的 HTTPS `22346` 当作应关闭的明文管理端口。

仓库内 `docker-compose.controlled-tls.yaml` 是基础三容器定义的最小 HTTPS 覆盖，支持 `TLS_CERT_NAME`、`TLS_KEY_NAME`，未设置时仍使用 `server.fullchain.pem`、`server.key.pem`。0.211 现有证书应保持原文件名及内容，只设置名称变量，不复制或重命名；私钥权限保持 `0600`，不要放入仓库。入口仍拒绝缺项、越界路径、符号链接、证书与私钥同文件及权限过宽的私钥。网络恢复后的候选启动方式为：

```bash
export TLS_CERT_NAME=rustdesk.jtzxsoft.com.fullchain.pem
export TLS_KEY_NAME=rustdesk.jtzxsoft.com.key.pem
docker compose --env-file "$PRIVATE_ENV" \
  -f docker-compose.controlled.yaml \
  -f docker-compose.controlled-tls.yaml \
  config --format json > "$PRIVATE_COMPOSE_JSON"
python3 scripts/deploy/controlled-compose-preflight.py --config-json "$PRIVATE_COMPOSE_JSON"
```

上述 JSON 含展开后的私有环境值，只能放在仓库外受保护目录并在使用后按既定运维流程处理。静态通过后仍须在目标主机运行完整预检；不能据此宣称证书、HTTPS 或端口实际可用。

网络恢复后，从独立网络执行完整安全检查时，可额外提供公网管理 URL 和服务器 PEM 完整证书链。`ADMIN_TLS_CA_FILE` 使用服务端 `server.fullchain.pem` 一类 PEM 文件，不使用供 Windows 安装的 DER `.cer`；内部密钥仍从仓库外私有环境加载，不在命令记录中写明值。

```bash
export ADMIN_HTTPS_URL="https://rustdesk.jtzxsoft.com:22346"
export ADMIN_TLS_CA_FILE="$PRIVATE_DEPLOY_DIR/data/tls/rustdesk.jtzxsoft.com.fullchain.pem"
sh scripts/deploy/controlled-security-check.sh
```

该检查要求受信任 HTTPS 首页返回 200，同端口明文 HTTP 请求成功完成且返回明确的 4xx/5xx 才记为拒绝，并下载公开 DER 证书和 RustDesk 1.4.9、1.5.0 安装包核对固定 SHA-256。明文 2xx/3xx、异常响应或任何传输失败都会使检查失败；超时、连接重置或空响应需另取服务端证据，不可据此认定仅 HTTPS 已生效。证书或安装包经审核替换时，可分别通过 `ADMIN_CERT_SHA256`、`ADMIN_INSTALLER_SHA256`、`ADMIN_INSTALLER_150_SHA256` 提供新的预期摘要，但必须同步更新下载页和后端门禁。它不会替代浏览器证书安装、RustDesk 客户端连接、UDP 或独立公网端口扫描。

## 独立外网无凭据验收

目标网络恢复并通知开始验收后，在真正独立的网络执行；不要为此把内部准入密钥、管理员密码、客户端令牌或整个私有环境文件复制到外网设备。`--public-only` 不调用内部接口，只需公开端点与事先通过可信渠道取得的公开 PEM 证书链。本模式不能自动证明执行设备没有经过同一出口、代理或 NAT 回环，须在验收记录中注明实际网络来源。

```bash
export PUBLIC_HOST=rustdesk.jtzxsoft.com
export PUBLIC_API_BASE_URL=http://rustdesk.jtzxsoft.com:22345
export ADMIN_HTTPS_URL=https://rustdesk.jtzxsoft.com:22346
export ADMIN_TLS_CA_FILE="$PUBLIC_CERT_PEM"
export RUSTDESK_HBBS_TCP_21115=22115 RUSTDESK_HBBS_TCP_21116=22116
export RUSTDESK_HBBR_TCP_21117=22117 RUSTDESK_HBBS_UDP_21116=22116
export FNOS_ADMIN_HTTP_PORT=22347
export RUSTDESK_HBBS_WEB_PORT=22118 RUSTDESK_HBBR_WEB_PORT=22119
export OLD_RUSTDESK_HOST="$PUBLIC_HOST"
sh scripts/deploy/controlled-security-check.sh --public-only
```

上述命令为恢复后的准备材料，本轮离线推进不执行。端口变量沿用旧名称以兼容现有工具，但值均为当前 22xxx；旧裸服务检查默认仍检查旧公网 `21115/21116/21117`，不要求重复修改路由器。关闭端口只有明确拒绝连接才记为通过，超时或解析失败均为无法确认。

公网 API 仅检查 `/api/health` 的服务标识和 `/api/login-options` 的直接字符串数组，不发送登录请求、不跟随重定向、不关闭证书校验、不输出响应正文。URL 不允许用户信息、查询参数或额外路径；HTTPS API 使用系统受信任证书链。示例保留现用 HTTP API，仅用于无凭据检查，不消除官方客户端经 HTTP 登录的凭据传输风险。

默认要求 `22118/22119` 关闭。只有目标原生 WSS 已部署、证书已审核且准备检查双端入口后，才额外设置 `PUBLIC_WSS_HBBS_URL=wss://rustdesk.jtzxsoft.com:22118/`、`PUBLIC_WSS_HBBR_URL=wss://rustdesk.jtzxsoft.com:22119/` 和 `PUBLIC_WSS_CA_FILE="$PUBLIC_CERT_PEM"`；不要以测试脚本支持 WSS 为由提前开放路由器端口。此时只验证 WSS 传输门禁，业务授权和浏览器远控仍不能记为通过。

该模式始终保留内部鉴权未验提示，UDP 仍需独立协议证据；不要将退出码 0 或“部分完成”写成全项验收完成。记录执行时间/网络来源、两项 API 响应、HTTPS/下载摘要、当前端口/旧地址结果与未验证项，凭据和私有配置不得进入报告。

## 数据迁移演练

当前候选程序 SHA-256 为 `0cda590ef066d686c0ade0bf678c449009de49fa681ebe14752667fe5050b8d3`；以下构建配方与 `132a6908...` 摘要描述的是前一迁移修复版，保留作历史记录。最新候选再次通过本节的原配置副本迁移、健康检查和原版恢复启动演练。

新测试镜像从已验证的专用 API 镜像增量构建，只替换静态 Linux 程序，构建使用 `--network none`。构建配方如下，程序位于仓库外构建上下文中：

```dockerfile
FROM rustdesk-controlled-api:test-20261012-v2
COPY rustdesk-api-server-migration-linux /app/rustdesk-api-server-pro
RUN chmod 0755 /app/rustdesk-api-server-pro
```

镜像内程序与本地编译产物的 SHA-256 均为 `132a6908d3b02199de6a6f7f9f94f25d644db451887501677d2c2801558a6225`。后端全量 Go 回归及新镜像的三容器准入、故障、重建和持久化检查已通过。

在授权 Linux Docker 主机以 root 执行，传入仓库外的原库路径、新 Linux 程序和已有专用 API 镜像：

```bash
python3 scripts/deploy/controlled-sqlite-migration-rehearsal.py --self-test
python3 scripts/deploy/controlled-sqlite-migration-rehearsal.py \
  "$SOURCE_APP_DIR/data/server.db" "$NEW_LINUX_BINARY" "$RUSTDESK_API_IMAGE"
python3 scripts/deploy/controlled-sqlite-migration-rehearsal.py \
  "$SOURCE_APP_DIR/data/server.db" "$NEW_LINUX_BINARY" "$RUSTDESK_API_IMAGE" \
  --legacy-config "$SOURCE_APP_DIR/data/server.yaml"
python3 scripts/deploy/controlled-sqlite-migration-rehearsal.py \
  "$SOURCE_APP_DIR/data/server.db" "$NEW_LINUX_BINARY" "$RUSTDESK_API_IMAGE" \
  --legacy-config "$SOURCE_APP_DIR/data/server.yaml" \
  --rollback-binary "$SOURCE_APP_DIR/rustdesk-api-server-pro"
```

工具以 SQLite 只读连接备份原库，容器仅挂载副本和新程序，使用 `--network none`、只读根文件系统和无额外权限。默认使用无密钥模板；指定 `--legacy-config` 时仅复制原 YAML 到权限受限的私有副本，容器不挂载原文件，连续迁移后启动 API 并检查健康及配置未改写。原 SQLite DSN 必须能在隔离副本目录解析；非本地数据库不属于本工具支持范围。启动演练仅覆盖健康接口，外部认证与邮件因无网络不作通过判断。正常结束、异常或可处理的中断会清理副本及容器。强制杀死进程后，应核对名称以 `rustdesk-controlled-migration-` 开头的临时容器与主机临时目录。工具输出仅包含结论，不输出令牌和数据库记录。

指定 `--rollback-binary` 时必须同时提供旧 YAML。工具在新版副本两次迁移和启动之后，将迁移前快照复制到另一个独立目录，核对完整 SQL schema 与记录，再只读挂入原版 Linux 程序执行启动和健康检查；不会尝试用旧版读取已迁移数据库。恢复前快照的摘要和配置内容均须保持不变。原版程序使用候选 API 镜像的运行环境，不等同于原包装镜像、正式端口或完整目录备份恢复。

2026-10-12 授权主机实测通过上述完整流程：30 张原业务表保留，恢复副本原 schema/记录一致，原版程序健康接口通过，私有副本及临时容器已清理；原配置摘要未变，原服务未重启且健康为 200。自检分别拒绝恢复记录变更和 schema 变更。仍需在维护窗口完成原应用/密钥完整备份及正式容器切换回滚。

## 正式切换顺序

以下步骤须在上述条件满足后执行；本轮仅形成清单，没有停止原服务。

1. 设置维护窗口，暂停管理写入并通知测试客户端重新登录及更新新 server 公钥。将 Docker 容器配置、镜像 ID、端口和挂载清单保存到 root 私有备份目录，不输出环境变量或凭据。
2. 停止原容器，完整备份原应用目录、原 key 目录和 SQLite 的 WAL/SHM 文件。离线备份后再次检查数据库完整性，并记录文件摘要。仅复制运行中 `.db` 文件不是可靠备份。
3. 将原容器重命名为 `rustdesk-api-server-pro-precontrolled`，保留容器及原挂载。不要删除原容器或让新程序直接迁移原库。
4. 在独立 `CONTROLLED_DEPLOY_DIR/data` 复制离线数据与 `.init.lock`，保留原配置备份。用当前配置结构核对数据库 DSN、端口、内部密钥、静态资源与 OAuth；测试过的新镜像模板不能代替原业务配置审阅。轮换新副本的 API `signKey`，新建受控 server key 卷；原 key 和旧配置保持可回滚。
5. 将正式 Compose 放在独立部署目录，使相对 `./data` 正确指向新副本。通过私有 env 注入镜像与凭据，先执行 `config --quiet`，再按 API、hbbs、hbbr 健康依赖启动。管理及 WebSocket 端口保持回环绑定。
6. 核对三服务健康、内部鉴权、旧库记录、设备待审批状态、登录重新签发、正向远控与各负向场景。每项记录客户端时间、服务端错误码和后台审计，再从独立公网位置执行暴露扫描。

## 回滚顺序

以下原容器改名回滚流程已在正式切换验收中通过，但旧容器于 2026-10-13 按授权删除，**不再是当前可直接执行的回滚路径**。同日已复核三份备份文件摘要，并使用原镜像、原启动脚本和原挂载内容在无网络、无宿主端口的临时容器中重建旧 API，健康检查通过且临时资源已清理。当前回滚仍必须在维护窗口根据保留的容器清单、原应用目录和离线归档重新创建旧容器；恢复前须保留新库，并复核备份摘要、旧配置和端口占用。该隔离健康验证不包含旧客户端、公钥或外部认证联调。

1. 停止新 Compose 并执行 `down`，不添加 `--volumes`；保留新库、日志和新 key 供排查。
2. 历史验收曾将原容器从 `rustdesk-api-server-pro-precontrolled` 改回原名并启动；该容器现已删除。后续须按保留的容器清单重建原镜像与挂载，禁止将新 schema 的数据库覆盖回旧目录。
3. 检查旧 API/管理页、原客户端配置及数据库完整性。回滚后客户端需恢复旧服务地址和旧公钥。
4. 将切换后产生的新数据单独保留；直接回滚不会自动合并新旧库之间的写入。关闭维护窗口前核对这段时间的审批、账号和审计差异。

## 验收边界

已完成只读清单、数据库副本迁移、原 YAML 严格解析及副本启动、迁移前快照恢复、正式端口切换、旧服务下线、原容器实机回滚，以及删除旧容器后的离线材料重建与旧 API 隔离健康检查。仍未完成独立公网扫描、外部认证配置联调、旧客户端/旧公钥恢复和切换后新旧数据合并验收。

## 仅回退 2026-10-15 server 镜像

0.211 当前 hbbs/hbbr 镜像为 `sha256:7207a963d0423bd135d7cf296b5da60977749b88f7c4ecfe6f34c1d3b32892ae`。更新前的镜像 `sha256:c6b9d7d5a36476de33c2f4da46f0d5d22532f11a2058f8c0d5df3030bb183f67` 和 `runtime.env.before-ws-ip-20261015` 均保留；2026-10-16 只读核对旧配置可通过正式 Compose 解析，`20261015-current-images-v1` 离线包三项摘要匹配。该镜像回退不需要恢复旧数据库、API 镜像或 server key。

需要回退时先安排维护窗口和自动恢复保护，备份**当时**的 `runtime.env`，只把其中 `RUSTDESK_CONTROLLED_SERVER_IMAGE` 改为上述旧镜像 ID；不要直接用 2026-10-15 的整份 env 覆盖日后可能更新的 API 或密钥配置。执行 `docker compose --env-file runtime.env -f compose.yaml config --quiet` 后，仅对 `rustdesk-hbbr rustdesk-hbbs` 执行 `up -d --no-deps`，再检查两只容器健康、公钥、API/管理页及官方客户端连接。旧镜像恢复只撤回 WebSocket 来源头修复，不能当作整站数据回滚。

## 仅更新前端的测试部署（2026-10-14）

在组件回归、类型检查、生产构建及独立浏览器验收通过后，使用 `docker/Dockerfile.controlled-api-frontend` 构建增量镜像。构建上下文只能是前端 `dist`，不可传入包含配置或临时凭据的部署目录；构建前先核对基镜像标签对应摘要，使用 `--network=none`，不修改后端或配置模板。受控部署 CI 已加入增量镜像契约回归并使用其产物执行三容器测试；新增构建步骤已在授权 Linux 上离线通过，新提交的完整远程运行仍需核对。

本次基镜像为 `test-20261013-device-nickname`，ID `sha256:928f214e2a801d08d3604267152a0b171cd6db86703f809e871ca4de675b753b`；产物为 `rustdesk-controlled-api:test-20261014-audit-detail`，ID `sha256:da73ffbb9578d0821e99d1b6a7ccaa7e1fb63bd22da81aad7c5e9bf0bd8893d8`。新旧镜像中后端 SHA-256 均为 `54177b2889a76b1d1b7ce3c14f08ebba260026e7900f6a3edb4d7abfb3ce8cf1`，配置模板均为 `d60a46a30c7e1a18ee536d90eb8e00dbc22a35e4df94f782f4585ace5ecd60dc`。

更新前使用 SQLite backup 保存 `data/server.db.before-audit-detail-20261014`，并备份 `runtime.env.before-audit-detail-20261014`；先确认唯一命名的五分钟回滚定时器 active，再仅替换 runtime.env 中的 API 镜像，并对 API 服务执行 `up -d --no-deps`。验证 API healthy、两个网页 HTTP 200、设备/用户权限和公钥不变、hbbs/hbbr 容器 ID 与启动时间不变后取消回滚。现用服务已保留新镜像；旧镜像与备份未删除。

该更新不迁移数据 schema，不改变账号、审批、中继权限或 server 密钥，也未对本次更新补做官方客户端连接验收。回退前端可恢复本次 runtime.env 备份并仅重建 API，不应覆盖回旧数据库。
