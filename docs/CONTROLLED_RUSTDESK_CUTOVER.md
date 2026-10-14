# 受控 RustDesk 正式切换与回滚

更新时间：2026-10-13。已完成授权主机局域网正式端口切换、原容器真实回滚及再次切换；旧容器删除后又从离线材料完成隔离重建和 API 健康验证。下面保留原操作清单；公网发布和完整官方客户端验收尚未完成。

## 本次切换结果

1. 用户允许原 `12345` 服务停机、删除。切换及真实回滚验收期间先停止并重命名原容器；2026-10-13 再次确认离线备份、迁移完整性、旧令牌撤销和新公钥持久化后，已删除停机的旧容器。原应用目录、数据库、密钥归档和切换报告仍保留。
2. 停机前预设 20 分钟独立 systemd 自动回滚；配置副本严格解析及最终 Compose 预检先通过才停机。首次预检因旧 YAML 没有 `rustdeskServer` 区段而终止，原服务未重启；补齐默认区段后重试成功。
3. 原应用完整目录与原 key 挂载目录离线归档，分别执行 tar 内容比较，旧 SQLite 完整性检查通过，归档及容器清单摘要已记录。备份目录权限 0700，文件 0600，仅保存在主机 root 私有目录。
4. 新数据来自独立副本，SQLite DSN 和静态资源路径按新镜像核对；新副本轮换 signKey 和内部密钥，撤销旧登录令牌，保留 `.init.lock`、原账号和业务数据，设备不自动审批。原 OIDC 未启用、OAuth 提供者数量为 0；外部服务联调不计通过。
5. 使用固定 API 镜像 `sha256:eb587aa52cda3c7a7618f057eca4deabe347c6472e1f62c5f2350d77f149184f` 与 server 镜像 `sha256:91746f12dbf37ff9b1ae135db24734ed593125b15cdaa533e6d4202e90036b99`。新建 server key 卷，hbbs 宣告局域网中继地址。API、新管理页与三容器健康通过。
6. 停止新项目但不删除卷，恢复原容器名并启动；原 API 和原局域网管理页返回 200，原镜像及 YAML 摘要不变。再停止原容器、恢复保留名并启动新项目，健康通过；新数据库完整性、零自动审批、旧 token 全部撤销及脱敏、备份摘要再次核对通过。
7. 新公钥写入 API 配置并重启 API 后健康通过，server 密钥及卷不变。2026-10-13 已确认历史隔离资源与正式挂载分离，并清理四个历史测试容器、六个测试卷和一个测试网络；2026-10-14 又清理三只无容器引用的旧局域网 PoC data/key/log 卷，并复核正式部署文件、API 配置与正式 key 卷公钥一致。正式三容器及正式数据、key、日志均保留。
8. 成功后取消本次自动回滚定时器。主机私有部署目录保留 `cutover.py`、`runtime.env`、`cutover-report.json` 和 `server-public-key.txt`；操作脚本的三个回滚时序与名称冲突保护自检通过。需要回滚时，在主机使用私有部署目录中的脚本执行 `python3 cutover.py rollback`；先暂停新管理写入并保留新库，脚本不合并切换后的数据。

当前容器为 `rustdesk-api-server-pro`、`rustdesk-hbbs-controlled`、`rustdesk-hbbr-controlled`；旧容器 `rustdesk-api-server-pro-precontrolled` 已删除。API、管理和原生 server 端口仅绑定主机局域网 IP，WebSocket 端口仅回环；不配置公网转发。

局域网 API 与管理页均 HTTP 200，内部鉴权无密钥 HTTP 401；三次未签发中继连接均关闭且对应 `ERR-2315`。当前 API/管理端口分别绑定 `192.168.0.211:12345/12346`，尚未挂接公网；LAN HTTP 仍有凭据传输风险。公网扫描、正常 WebSocket、官方客户端全矩阵和真实外部认证仍待验收，不能因端口切换成功而认为全部生产验收已通过。

## 已核对的现状

- 原 `rustdesk-api-server-pro` 使用 `alpine:3.20.3` 包装，以 `/app/start.sh` 启动；实际网络为 bridge。
- 宿主 `12345` 已由原 API 占用，原管理端口绑定内网 `12346`。正式三容器 Compose 的固定容器名和 API 端口均会冲突。
- 原应用通过宿主目录挂载 `/app`，另有 `/root` 挂载；实际宿主路径仅保存在仓库外私有部署配置中。
- 有效旧库和配置位于容器 `/app/data/server.db`、`/app/data/server.yaml`，初始化标记为 `/app/data/.init.lock`。不要误用 `/app/server.yaml` 替代当前持久配置。
- 旧库完整性检查通过；有 2 个用户、2 台设备、6 条令牌。旧设备表缺少审批和中继策略字段。
- 新 Linux 程序在旧库只读快照的无网络副本上连续迁移两次通过，30 张原业务表数据保留，令牌脱敏且没有增加已审批设备。追加原有效 YAML 严格解析、实际加载与内存往返通过；原 YAML 加迁移库副本启动新版 API，健康检查通过且配置未改写。未覆盖外部 OAuth/SMTP/WebAuthn 联调、客户端或正式端口。

## 切换前条件

1. 将最新修复镜像纳入正式发布，固定镜像摘要。当前候选为 `rustdesk-controlled-api:test-20261012-online-v1`，镜像 ID `sha256:eb587aa52cda3c7a7618f057eca4deabe347c6472e1f62c5f2350d77f149184f`，包含迁移及在线超时时区修复，后端全量测试、完整三容器验收及迁移/恢复副本复验通过。旧 `test-20261012-migration-v1` 不含在线超时修复，`test-20261012-v2` 还缺迁移修复；不要用历史镜像替代当前候选。
2. 完成官方客户端负向验收、跨网络策略和正式暴露检查。共享出口 IP 的双端目前仍拒绝中继；带 token 的 WebSocket 请求当前默认拒绝，正常 WebSocket 客户端不应列为已支持。
3. 在私有部署配置中明确 `SOURCE_APP_DIR`、`SOURCE_KEY_DIR`、`CONTROLLED_DEPLOY_DIR`、`BACKUP_DIR`、`PRIVATE_ENV`。这些目录必须彼此分离；新 `data` 不得指向原应用目录。
4. 准备管理员凭据、独立内部 API 密钥、新 server key 及客户端配置。旧库迁移后设备仍须审批，用户远控/中继策略须逐项核对，不能批量自动审批。
5. 核对客户端 Relay 地址；如需 hbbs 宣告中继地址，在私有 Compose 覆盖中为 hbbs 设置 `-r <客户端可达地址>:21117`。
6. 已准备不可变镜像 ID 的离线候选包，见 `CONTROLLED_RUSTDESK_OFFLINE_RELEASE.md`；正式使用前核对全部文件摘要，并在独立部署目录运行 `controlled-compose-preflight.py`，检查实际端口覆盖与原数据目录隔离。原数据保护只识别原容器名和 `-precontrolled` 保留名，不能代替完整路径审阅、停机备份及正式端口占用检查。

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

## 仅更新前端的测试部署（2026-10-14）

在组件回归、类型检查、生产构建及独立浏览器验收通过后，使用 `docker/Dockerfile.controlled-api-frontend` 构建增量镜像。构建上下文只能是前端 `dist`，不可传入包含配置或临时凭据的部署目录；构建前先核对基镜像标签对应摘要，使用 `--network=none`，不修改后端或配置模板。受控部署 CI 已加入增量镜像契约回归并使用其产物执行三容器测试；新增构建步骤已在授权 Linux 上离线通过，新提交的完整远程运行仍需核对。

本次基镜像为 `test-20261013-device-nickname`，ID `sha256:928f214e2a801d08d3604267152a0b171cd6db86703f809e871ca4de675b753b`；产物为 `rustdesk-controlled-api:test-20261014-audit-detail`，ID `sha256:da73ffbb9578d0821e99d1b6a7ccaa7e1fb63bd22da81aad7c5e9bf0bd8893d8`。新旧镜像中后端 SHA-256 均为 `54177b2889a76b1d1b7ce3c14f08ebba260026e7900f6a3edb4d7abfb3ce8cf1`，配置模板均为 `d60a46a30c7e1a18ee536d90eb8e00dbc22a35e4df94f782f4585ace5ecd60dc`。

更新前使用 SQLite backup 保存 `data/server.db.before-audit-detail-20261014`，并备份 `runtime.env.before-audit-detail-20261014`；先确认唯一命名的五分钟回滚定时器 active，再仅替换 runtime.env 中的 API 镜像，并对 API 服务执行 `up -d --no-deps`。验证 API healthy、两个网页 HTTP 200、设备/用户权限和公钥不变、hbbs/hbbr 容器 ID 与启动时间不变后取消回滚。现用服务已保留新镜像；旧镜像与备份未删除。

该更新不迁移数据 schema，不改变账号、审批、中继权限或 server 密钥，也未对本次更新补做官方客户端连接验收。回退前端可恢复本次 runtime.env 备份并仅重建 API，不应覆盖回旧数据库。
