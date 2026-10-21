# 原生 WSS 与浏览器远控

## 逐会话审计关联加固（2026-10-21，候选未部署）

- API 签发和核销审计新增 `session_sha256`，不记录原始会话 UUID、token 或内部密钥；摘要只关联证据，不改变准入、一次性核销或共享出口限制。
- 外网收集器不再用同 IP 的其他会话拒绝凑满三次：每个会话须有一条双来源签发、两端各一条允许核销、两端各至少一条重放拒绝；源地址仍按 IPv4/映射 IPv6 的地址语义关联。结果新增 `audit_session_sha256=true`，不自动证明独立家庭网络或浏览器远控。
- 没有摘要的旧审计默认拒绝，不能直接把新版收集器接到旧 API；先经备份、自动回滚及至少三十分钟人工窗口完成 API 更新后再配套使用。本轮只完善代码和离线回归，不创建人工窗口、不改写历史记录，不追加历史验收的逐会话审计结论。

## 人工验收窗口调整（2026-10-21，工具未部署）

- 按用户要求，后续需人工配合的窗口至少留 30 分钟。`--prepare-external` 现在创建 45 分钟独立清理保护，两个角色配置在 44 分钟后失效；PowerShell 探针接受最长 45 分钟的剩余有效期，过期和超长配置仍拒绝。
- 先确认家庭脚本路径、证书信任和文件传输方式，再准备窗口；公司端就绪后通知开始时，须确认配置剩余有效期至少 30 分钟，否则精确清理并重开，不复用旧配置。通知明确本地时间的建议完成、配置失效及自动恢复/清理时间。
- 配置与凭据期限统一锚定在启动清理保护前的 UTC 时间，不随准备耗时顺延；工具交付配置前检查剩余至少三十分钟，不足则拒绝并执行既有精确清理。通知人工前仍需再次核对，文件传输耗时不自动延长窗口。
- 无需人工的 `--run` 保持十分钟自动清理；不改真实设备、账号、单会话授权有效期或服务安全策略。备份、先验证保护后创建夹具、精确清理和审计关联要求不变。
- Windows/Linux 11 项模拟回归、PowerShell 5.1/7 离线自测通过；保护未生效时不创建身份或凭据，旧二十分钟逻辑被反向回归捕获。此次未在现用服务创建新夹具、计时器或更新镜像；下方已结束窗口保留其历史时间。

## 家庭独立外网真实授权验收通过，新版保留（2026-10-19 20:27）

用户明确确认家庭电脑使用家庭网络，提供 `wss-source-result-0e7cfb1919e841dbb84f3e645a173bc6.json`；源端、目标端与服务端三个会话 UUID 集合完全一致，三次真实签发、六次逐端核销、双向随机数据与两端各三次重放拒绝证据完整。不同公网出口和人工来源确认已关联，本轮家庭独立外网真实授权 WSS 协议验收通过。源端无凭据结果已归档为本轮 root 私有备份中的 `source-result.json`，与 `target-result.json` 和 `external-server-result.json` 一同保留；原始短期凭据已撤销并清理。

用户另反馈北京时间 **20:25 `487921466 → 163316348` 普通远控成功**。20:27:41 核对候选镜像仍为 `rustdesk-controlled-server:wss-rate-20261019`、三容器健康、API/hbbr 未重建、证书摘要未变且回滚未启动，停止原 **20:51:05** 镜像回滚 timer，再确认其不活动、无 `rolled-back.json`、容器身份/启动时间不变。新版正式保留，`backups/hbbs-rate-452f287a3ab84e4a8812ce111c242d06/retained.json` 记录取消与关联证据，备份仍可供人工恢复。以下待收/保护活动描述均为此前历史。

边界：本轮是合成身份的真实 WSS 授权协议会话，不是官方浏览器完整远控；普通原生客户端回归也不反推该客户端采用 WSS。官方 Web 合法发行包仍缺，相关端到端验收继续暂停；同出口限制与官方客户端身份能力限制未解除。

## 新窗三次授权业务完成，来源与原生回归待确认（2026-10-19 20:17）

用户反馈源端 `PASS source 1/2/3`（家庭电脑显示 **20:17:19**）和 `PASS complete`；公司目标同时完成三次（公司时钟 **20:17:02**）。目标结果与服务端三个会话 UUID 集合一致，服务端核对三次真实签发、六次逐端核销、双方各三次重放拒绝、双向随机数据、日志/审计无原始令牌和三容器未变均通过；观测到双方是不同全球可路由公网来源。证据 `backups/wss-live-0e7cfb1919e841dbb84f3e645a173bc6/external-server-result.json`、`target-result.json`。

本轮夹具用户、设备、令牌、授权均为零，服务端与公司端原始配置已删除，保留结果、审计和备份；停止本轮夹具 timer，未恢复整库。对比镜像更新前原 3 用户、7 设备身份/策略一致。家庭来源仍需用户明确确认，源端无凭据结果文件尚待收，不能仅由不同 IP 自动确认独立网络。另请求一次现有官方客户端普通远控回归；**20:51:05 镜像自动回滚仍活动、未执行，尚未正式取消保护**。本次为合成身份真实 WSS 协议验收，不代表官方浏览器完整远控或原生客户端实际采用 WSS。

## 注册限流修复与新窗口（2026-10-19 20:08）

根因是 `check_ip_blocker` 每次注册刷新计数窗口起点，使每十秒正常注册也会持续累加并最终返回 `TOO_FREQUENT=4`。独立 fork 仅将起点更新移至窗口到期分支，保留原突发计数阈值和所有准入策略；新增固定起点、突发拒绝、窗口到期恢复回归。离线 25 项 Rust 库测试通过，本地候选镜像 `rustdesk-controlled-server:wss-rate-20261019` 构建通过，没有发布镜像或推送代码。

备份 `backups/hbbs-rate-452f287a3ab84e4a8812ce111c242d06` 保存配置、密钥及两份完整性通过的一致性 SQLite 副本；独立镜像回滚截止北京时间 **20:51:05**。只替换 hbbs 镜像，API/hbbr 身份及启动时间、证书摘要不变，三容器健康。回滚工具 `controlled-hbbs-rate-update.py` 只恢复预期候选的 hbbs 镜像，不整库回退、不覆盖其他服务，并在镜像被其他更新修改时拒绝覆盖。更新预检曾因 Compose 采用变量引用而停止，未改服务；兼容该引用后才实际切换。

20:14 公司目标已连续至少 40 次注册允许，进程仍存活、未收到状态 `4`，超过此前失败时长；`target-idle-check.json` 已在本轮 root 私有备份保存。已通知家庭电脑运行新配置，建议 20:24 前反馈；操作期 **20:26:50**、自动清理 **20:27:50**，旧 `fd44e485` 配置不得复用。命令使用已自检通过的 `[Environment]::GetFolderPath('Desktop')` 绝对路径，不依赖当前目录或易漏写的环境变量名。家庭三次结果和来源仍待收。

切换后三次真实 WSS 签发、双端核销、双向随机数据及重放拒绝通过，证据 `backups/wss-live-5dc97395d9c24d17941fc4ae0c018250`，已精确清理。本轮新外网夹具 `backups/wss-live-0e7cfb1919e841dbb84f3e645a173bc6` 已先备份并开启独立二十分钟清理；公司目标正在做超过旧故障时长的长等待复验，家庭业务尚未通过。公司端私有源配置位于仓库外 `wss-home-0e7cfb19/source.json`，只允许私有复制，不公开凭据。

## 家庭独立外网正式窗口（2026-10-19 19:06）

19:24 公司侧最终取得注册状态 `4`（`TOO_FREQUENT`），确认长时间定期注册触发来源地址限流；未放宽服务端策略。家庭第二次仍在 `C:\WINDOWS\system32` 运行相对路径，脚本不存在；随后命令的配置路径再次误用 `$env`，没有收到三次业务通过证据。19:25 主动执行精确清理，窗口结束，旧配置禁止复用。后续须先确认家庭脚本实际路径，并解决测试目标长等待的限流问题，再备份重开；下方开窗在线描述是历史状态。

家庭首次执行把 `$env:USERPROFILE` 误写为 `$env`，脚本未启动，因此不属于 WSS 业务失败。改为在桌面文件夹打开 PowerShell、使用 `-File .\controlled-wss-external-probe.ps1 -Config .\source.json`。公司侧目标等待期间曾收到注册拒绝；同期 API 注册与心跳审计允许，服务端存在来源地址注册频率限制，尚未取得该次具体协议状态码，不能记为账号策略拒绝。探针补充非敏感状态码与套接字错误分类，重新启动后再次收到 `READY target`；服务端策略、证书和现用容器均未修改。家庭三次业务仍待收。

用户反馈家庭电脑 `PASS self-test` 后重新备份并开启 `backups/wss-live-fd44e48556ba4bd4bff81aeb813cf173`；19 分钟配置操作期至北京时间 **19:25:31**，独立自动清理定于 **19:26:31**。公司侧目标已重新注册并保持在线，正式操作说明已发送，家庭电脑本轮三次业务结果和来源确认待收，不提前记为通过。

两个角色配置仅经 SSH 传到当前用户私有目录，本轮 `source.json` 需由用户以私有文件方式复制到家庭电脑；不公开下载、不回显令牌，不修改现用账户设备配置或重建三容器。正式源角色结果、公司侧目标结果及服务端实际授权/核销/拒绝审计收齐后才能取消本轮保护。19:25 后不得复用旧配置，迟到需先核对清理状态再开新窗口。

## 独立外网授权会话工具已就绪（2026-10-19 17:59）

- 新增 `scripts/deploy/controlled-wss-external-probe.ps1`，支持 Windows PowerShell 5.1/7，无 Python 和第三方依赖，使用系统默认 WSS 证书/域名校验，不设置跳过验证回调。源角色请求真实 hbbs 签发；目标角色经 UDP 注册并接收 hbbs 通知，双方只经 `22119` WSS 完成三次随机挑战、摘要和确认，再分别尝试已核销会话重放。UDP 注册仅为发现通知，不代替 WSS 业务证明。
- PowerShell 5.1、7 离线自检通过。17:55/17:59 在两份不同备份和清理窗口，各验证 Windows 目标/源角色三次完整配对，核对同一轮服务端三条签发、六条核销、双端各三次重放拒绝审计后清理；配置及短期原始凭据不放到 Git、聊天、进程参数或公开下载目录。证据分别在 `backups/wss-live-24d36292485b47168e67e6f66d16e376`、`backups/wss-live-52814e7fb8bd4c4e972700b4256caff8`。对端是容器探针，因此两轮仅为工具回归，不能记为独立家庭外网通过。
- 首轮收集器将授权中的 IPv4 和审计中的 `::ffff:` 映射地址按字符串比较，未收齐计数而拒绝通过；已改为标准地址语义匹配，增加对应回归，并重收完整计数后才清理。不放宽三次/六次门槛，不宣称产品授权缺陷。另有一次 SSH 连接超时，重连后收集清理成功。
- `controlled-live-wss-acceptance.py --prepare-external /绝对部署目录` 复用先备份、再建独立保护的流程；提供 root 私有 `source.json`/`target.json`，当前工具为 44 分钟配置操作期、45 分钟凭据和自动清理（2026-10-21 调整；旧窗口仍按当时期限）。`--collect-external /绝对备份目录` 核对三会话、双来源、逐端核销、两端各三次拒绝审计、无原始令牌日志及服务未变后保存证据并清理，删除源/目标私有配置，保留审计和备份。若未收齐，不写通过且保留保护；过期后需新窗口，不重复使用旧凭据。

人工步骤：先把不含凭据的 PowerShell 文件复制到家庭电脑，使用此前已信任证书的同一 Windows 用户运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\controlled-wss-external-probe.ps1 -SelfTest`，回复就绪。此时不开正式计时窗口。随后由操作者重新备份/开窗，在公司侧启动目标角色，只经私有文件传输将本轮 `source.json` 交给家庭电脑，在同目录运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\controlled-wss-external-probe.ps1 -Config .\source.json`；不要提供账号密码，也不要把配置文件内容发到聊天。回传三次 PASS 及不含令牌的 `wss-source-result-本轮标识.json`，与公司目标结果和服务端会话集合交叉核对，再明确记录家庭网络来源。

当前家庭电脑尚未运行本轮授权业务；仅公网 IP 不同不能证明物理网络来源。没有官方 Web 发行包，仍不计浏览器完整远控；保留同出口 fail-closed 和官方客户端限制。该探针是合成身份的协议验收，不是安装/替换 RustDesk 客户端。

## 现用服务授权 WSS 三次通过（2026-10-19 17:31）

`controlled-live-wss-acceptance.py` 使用短期合成用户、已审批测试设备和十分钟有效令牌，在现用 `hbbs/hbbr/API` 完成三次业务会话：源端经过公网域名 `22118` 请求真实 hbbs 签发，再通过 `22119` 与容器网络中的测试目标配对，逐端核销、256/257 字节双向随机数据一致，以及两端各一次重放拒绝均通过。数据库核对三次签发允许、六次核销允许审计，日志和所查审计无原始测试令牌。不是直接向 API 预置中继授权，也不是仅完成 TLS 握手。

执行前备份 Compose、运行环境及两个一致性 SQLite 副本，建立十分钟独立 systemd 自动清理。备份及结果：`backups/wss-live-2a0c1cc3713241c2a9cdccb30c2e551a`。结束后精确清理本轮用户、设备、令牌、授权、注册持久化记录及测试容器，保留审计；复核全部为零、原 3 个用户和 7 个设备的身份/策略与备份一致，配置和三容器启动时间不变。没有部署变更，不用整库恢复覆盖同时发生的业务写入。

边界：源端实际被观测为本机公网 IP，可能是 NAT 回流；目标为容器来源。此次证明现用真实授权 WSS 业务链路，不证明两个独立外网端点、官方浏览器完整远控、设备私钥或当前登录态证明。原隔离验收脚本禁止访问现用数据库的门禁未放宽。

目标机人工执行入口：`python3 -B scripts/deploy/controlled-live-wss-acceptance.py --run /绝对部署目录`。必须在已授权窗口以 root 执行，依赖同目录既有协议工具、systemd、Docker、nsenter 和本地 `alpine:3.20.3`；会创建少量短期测试记录，不是只读探针。`--cleanup /绝对备份目录` 可重复精确清理，拒绝身份 UUID 不匹配或测试用户关联非夹具设备。离线清理边界自检已加入维护 CI，不会在 CI 自动操作现用主机。

## 公网 WSS 保留（2026-10-19 17:17）

用户确认家庭电脑使用家庭网络，Windows 默认系统信任校验下 `PASS 22118` / `PASS 22119`，独立外网 WSS 传输通过；17:14 同机官方客户端普通远控成功。该远控会话传输未核实，不算真实授权 WSS 正向业务或浏览器完整远控。17:17:04 核验本轮双 server、绑定/证书、三容器与管理/API 正常，恢复未执行后取消公网 window1 timer，复核容器身份/启动时间未变。原 17:51:19 自动回滚取消，公网绑定及 `backups/wss-public-20261019-window1` 保留；后续变更需新建保护窗口。下方“独立外网待收、保护活动”是本轮早期记录。

## 公网映射窗口（2026-10-19）

用户已确认路由器新增 TCP `22118/22119` 到 `192.168.0.211` 同号端口。16:51 仅将 WSS 宿主绑定从回环改为该 LAN 地址，server 镜像与安全配置未变，API 未重建；备份 `backups/wss-public-20261019-window1`，配置预检及两库一致性检查通过。

LAN WSS、当前 Windows 经 `rustdesk.jtzxsoft.com` 的双端证书/域名/严格升级、TLS 1.2/1.3、错误身份与明文拒绝，以及无凭据探针新增服务端拒绝审计均通过。此路径可能经过路由回流，独立外网仍待用户切手机热点验证；没有官方 Web 发行包，浏览器完整远控继续暂停。

当前 `controlled-wss-public-rollback-20261019-window1.timer` 截止北京时间 **17:51:19**，人工独立外网及普通远控结果待收。自动恢复只将两个 WSS 端口重新绑定回环，并重建双 server，不恢复数据库/API，也不覆盖其他 env 字段；路由器规则不会自动删除。下方“仍仅回环、未开放公网”是此前阶段记录，不代表当前状态。

## 16:26 新验收窗口

原窗口已于 16:23 自动恢复旧 server，不能因旧构建检查通过而认为候选已保留。用户要求重开后，按现用下载入口 API `35be96d...` 重新完整备份并预检，16:26:53 仅重建双 server 为同一已验候选 `009a8e7...`；16:27:36 现用 WSS、在线拒绝审计、明文拒绝及管理/API 检查通过，原证书、密钥和 API 容器未变。

用户反馈 16:46 完成三次连接，按本轮普通远控回归记录成功；16:47:09 核对仍为本轮双 server、三容器健康、API 未变及入口通过，确认无回滚执行后停止 `controlled-wss-update-rollback-20261019-window3.timer`，再核对服务身份和启动时间未变。原 **17:26:39** 自动回滚已取消，新版保留，备份 `backups/wss-update-20261019-window3` 继续保留。管理页本轮人工结果未单独收到；WSS 仍仅回环、未开放公网，浏览器远控暂停。下方 window2 的 16:23:27 是已结束的历史窗口。

## 2026-10-19 部署窗口

- fork `a8c1c2a` 在 0.211 离线构建为 `sha256:009a8e77e509324ac69a187267f80c06dd40fefaa7ad7bf6227dccd31e2e2f78`，24 项库测试、9 项探针自检及完整双版本 TCP/WSS 隔离三容器验证通过。
- 原域名证书只读挂入零宿主端口的临时 hbbs/hbbr，TLS 1.2/1.3、SAN、证书摘要、严格升级、错误身份与明文拒绝通过，临时资源清理成功。现用证书和 server 密钥没有轮换。
- 管理页性能更新验收保留后，重新备份并预检；15:38 仅重建双 server，API 容器未变。现用回环 WSS 受信任升级、在线准入拒绝审计、明文拒绝和全部 API/管理入口检查通过。
- 独立自动回滚 `controlled-wss-update-rollback-20261019-window2` 截止北京时间 **16:23:27**，备份 `backups/wss-update-20261019-window2`。回滚先保留新 server 数据，再恢复旧 server 数据/配置，不恢复 API 数据、不重启 API。现有桌面客户端远控回归待用户反馈，尚未取消保护或记为最终保留。
- `22118/22119` 宿主仍仅绑定 `127.0.0.1`，没有新增路由器映射。公网 WSS 与浏览器完整远控仍未通过；浏览器页面继续等待合法发行包。下文“目标尚未部署”是早先历史状态，不覆盖本窗口记录。
- 本地缓存增量入口为 `docker/Dockerfile.controlled-server-incremental`。上下文仅取固定提交的 `Cargo.toml`、`Cargo.lock`、`build.rs`、`src/`；显式传入本地 `BUILDER_IMAGE`、`RUNTIME_IMAGE`，先核对 builder 的 `libs/hbb_common` 为 `69cea8dafee147848ae88702029f4bf7df7224c3`。使用 `--pull=false --network=none` 离线测试/构建，不带入 `.env`、数据库或私钥，不发布镜像，也不替代从干净上游构建的正式 Dockerfile。

## 当前范围

2026-10-18 用户确认需要 WSS 与浏览器远控，并优先自托管合法可用的官方 Web 客户端。服务端直接终止 TLS，不新增外部反向代理，也不改造官方桌面客户端。

本轮开发了原生 WSS 传输和 HTTPS 客户端 API 分流。修复提交 `1a2c6d6` 的[远程 CI 39057113188](https://github.com/RyanWee68/rustdesk-api-server-pro/actions/runs/39057113188) 四作业全部成功，包含 Linux 24 项库测试及真实 WSS 三容器的在线准入、API 故障和恢复。传输及协议测试通过不等于浏览器完整远控通过，目标主机部署和官方 Web 客户端端到端验收仍待进行。

后续补齐公网传输门禁，并同步独立用户 fork `a8c1c2a`：主仓库 `606bef7` 的[39082466648](https://github.com/RyanWee68/rustdesk-api-server-pro/actions/runs/39082466648) 四作业全部成功，严格升级在真实三容器的 API 正常、故障和恢复窗口通过；独立 fork 的[39082930156](https://github.com/RyanWee68/rustdesk-server-controlled/actions/runs/39082930156) Linux 编译和 24 项库测试通过。服务端代码及隔离协议验证已补齐，0.211 部署和独立公网仍未执行。

进一步正向补验发现并修复 WSS 覆盖丢失中继地址的问题。最终 `aabbd43` 的[39094622416](https://github.com/RyanWee68/rustdesk-api-server-pro/actions/runs/39094622416) 成功：有效令牌、五类策略三次拒绝/恢复、强制签发、双来源逐端核销、双向随机二进制传输及重放均通过，API 故障及恢复继续通过。新增 9 项探针自测和 20 类 WSS 不安全配置回归通过；首次依赖缺失和第二次中继地址失败保留在验收记录，不以放宽断言处理。目标部署和独立公网仍未执行。

HTTPS 覆盖随后支持自定义现有证书名，与 WSS 配置对齐；`d829577` 的[39095818469](https://github.com/RyanWee68/rustdesk-api-server-pro/actions/runs/39095818469) 四作业全部成功。实际正式 Compose 合并后六个证书/私钥路径均保留域名文件名，默认配置、前后端、Linux server 24 项测试、完整 TCP/WSS 三容器及持久化继续通过；没有读取、复制或更换 0.211 的实际证书。

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
   HTTPS 覆盖同样支持 `TLS_CERT_NAME`、`TLS_KEY_NAME`，默认文件名不变。0.211 应沿用 `rustdesk.jtzxsoft.com.fullchain.pem` 和 `rustdesk.jtzxsoft.com.key.pem`；若两类服务复用现有证书，分别将 WSS 两项设置为相同文件名，`WSS_TLS_DIR` 指向现有证书目录。不复制、重命名或重新签发证书。
   同时设置 `RUSTDESK_RELAY_SERVERS` 为现用 `hbbs -r` 的客户端可达地址，例如 `rustdesk.jtzxsoft.com:22117`。当前覆盖仅接受单一域名或 IPv4 加端口，不填写 `wss://`；不要把隔离测试专用的 `rustdesk-hbbr` 容器名用于公网。覆盖文件会重建启动命令，不能假定旧的 `-r` 参数会自动保留。
4. 合并基础、HTTPS 和 WSS 三份配置，先完整预检，再在保护窗口重建：

```sh
umask 077
export TLS_CERT_NAME=rustdesk.jtzxsoft.com.fullchain.pem
export TLS_KEY_NAME=rustdesk.jtzxsoft.com.key.pem
export WSS_CERT_NAME="$TLS_CERT_NAME" WSS_KEY_NAME="$TLS_KEY_NAME"
export RUSTDESK_RELAY_SERVERS=rustdesk.jtzxsoft.com:22117
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
- WSS 覆盖必须显式传入中继地址，最终配置预检拒绝缺失地址、错误协议、缺少或越界端口及额外启动参数；证书有效不代表中继地址正确，正向协议验收仍须检查实际响应及双向传输。
- `controlled-three-compose-smoke.sh` 在随机项目、内部网络且无宿主端口的环境生成一次性证书，真实验证两端 WSS 升级、证书身份拒绝、明文拒绝、在线准入、API 故障和恢复；测试后清理容器、卷、网络及测试证书。
- 有效令牌及重复策略矩阵已扩展到 WSS，hbbs WSS 签发、hbbr WSS 双来源核销及双向随机数据的正向链路已通过；结果见上述最新 CI，不以升级成功或旧 CI 代替新业务验证。
- `controlled-wss-protocol-selftest.py` 验证握手字段、摘要大小写、重复头、未协商扩展/子协议、响应大小与总超时、URL/CA 参数边界，并用一次性回环证书执行真实双端 TLS 升级、错误身份及明文假服务拒绝。已接入本地综合验收，临时材料不进入仓库。
- 当前服务端仍需目标部署、真实证书和独立公网入口验收。浏览器页面已暂停；若以后恢复该范围，再补官方 Web 客户端的已登录且已审批连接成功、未登录/待审批/禁用/关闭中继/API 故障拒绝及恢复证据，现有协议探针不能替代这些人工结果。
