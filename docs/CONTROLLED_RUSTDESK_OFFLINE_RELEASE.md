# 受控 RustDesk 离线候选包

更新时间：2026-10-15。`20261012-online-v1` 是正式切换时使用的历史完整候选包，包含在线超时的数据库时区修复；`20261012-tested-v1` 更早且不含此修复。两者均不代表当前运行镜像。当前另有 `20261015-current-images-v1` 私有镜像候选包，仍非独立主机正式发布。

## 当前运行镜像候选（2026-10-15）

授权主机的 root 私有发布目录 `20261015-current-images-v1` 只包含 `controlled-images.tar`、`images.env`、`source-docker-id` 和 `SHA256SUMS`，不包含数据库、密钥、运行配置或旧包中的验收报告。目录权限 0700，文件权限 0600。镜像归档为 94507520 字节，SHA-256 为 `a27936e43ba3cfad5912602e86d53265f988a6e862c53fe8a96fbbca90ffb0d8`。

| 项目 | 当前不可变镜像 ID |
| --- | --- |
| API | `sha256:73f96f294a34d9b63b4e6ad4d12baa3534fea5c60d33648e5c4d433c4c9c643c` |
| hbbs/hbbr 共用 server 镜像 | `sha256:c6b9d7d5a36476de33c2f4da46f0d5d22532f11a2058f8c0d5df3030bb183f67` |

两个 ID 与当时三个正式容器一致，三个容器均 healthy。真实包的 `--verify-only` 已通过；完整模式在来源守护进程上以 `ERR-2397` 于加载前拒绝。`source-docker-id` 纳入摘要清单，脚本会与目标 Docker ID 比较，但该比较仅能拒绝同一守护进程，独立物理主机或虚拟机还需单独取证。运行验收需要同时提供本仓库相应提交的脚本和无宿主端口 Compose；旧完整包的其他文件不能默认套用到当前镜像。

## 历史完整候选（2026-10-12）

2026-10-12 晚已使用本包固定镜像在授权主机完成局域网正式端口切换、原容器真实回滚及再次切换；新副本和新 server key 独立。旧容器于 2026-10-13 在备份断言通过后按授权删除，原应用、数据库及密钥归档仍保留；直接改名回滚路径因此退役。删除后再次核对备份摘要，并从原应用/key 归档和容器清单在无网络、无宿主端口的临时容器中重建旧 API，健康检查通过且临时资源已清理。私有运行配置仅修改局域网端口绑定及 hbbs 中继宣告，原包及其摘要未改写。此项不代表独立主机导入、注册表签名发布、公网、旧客户端/旧公钥或完整官方客户端验收通过，详情见 `CONTROLLED_RUSTDESK_CUTOVER.md`。

## 已验证产物

候选包保存在授权 Linux 主机的 root 私有发布目录，实际路径通过仓库外部署配置提供，以下用 `OFFLINE_RELEASE_DIR` 表示。

| 项目 | 值 |
| --- | --- |
| 平台 | Linux amd64 |
| API 镜像 ID | `sha256:eb587aa52cda3c7a7618f057eca4deabe347c6472e1f62c5f2350d77f149184f` |
| server 镜像 ID | `sha256:91746f12dbf37ff9b1ae135db24734ed593125b15cdaa533e6d4202e90036b99` |
| 镜像归档大小 | 298334720 字节 |
| 镜像归档 SHA-256 | `2c4b3199a56df4524ad5019ce8344dec89233ddeebe5bbebeb3ab63176d0c3da` |
| Compose SHA-256 | `a7146b705cfda4132a9c851b362a0efc8defe1e7611d108da8586841fb24eaec` |

包内包含 `controlled-images.tar`、`images.env`、`docker-compose.controlled.yaml`、`controlled-compose-preflight.py`、`controlled-sqlite-migration-rehearsal.py`、`manifest.json`、`online-lifecycle-report.json`、`three-container-report.json`、`rollback-report.json` 和 `SHA256SUMS`。摘要文件覆盖其余九个文件，包括三份验收报告。不含业务数据库、server key、管理员密码、内部密钥或原生产 YAML。目录权限为 0700，产物文件为 0600。

本机 Docker 镜像 ID 是 OCI 索引摘要，不能直接与镜像配置 JSON 的摘要等同。当前归档已核对两镜像的 OCI 引用图、全部 43 个 blob 的内容摘要及引用大小；同机原 Docker 实例重新导入后镜像 ID 保持不变。API 镜像内程序摘要为 `0cda590ef066d686c0ade0bf678c449009de49fa681ebe14752667fe5050b8d3`，与通过回归的 Linux 产物一致；hbbs/hbbr 摘要另存于清单。

当时的候选镜像后端全量测试通过；真实定时任务在停止心跳约 31 秒后将合成设备下线，新心跳恢复上线，拒绝心跳不刷新状态，连接数由 3 清零通过。三容器加密/策略/重放/API 故障及重建持久化复验通过；原库连续迁移、迁移前快照恢复和原版程序隔离启动通过。该历史候选包未执行空存储或独立主机导入。

历史验证（仅前一候选包）：同一 Linux 主机的临时 Docker 实例中确认镜像存储为空后导入，两镜像 ID 和三个程序摘要一致；三个无网络容器分别启动，API 健康检查及重启持久化通过。不是独立机器验收，也未验证容器间协议；历史报告保留在前一候选包。

**隔离事故及限制：** 临时实例测试结束后发现宿主默认 `docker0` 网桥缺失，原 API 和回环测试 API 访问超时。此前仅比较网络列表与容器启动时间不足以证明宿主网络未变；具体触发步骤未单独隔离。已按原 Docker 网络元数据重建网桥，并通过容器网络命名空间的对端索引确认、重新接入两条原有 veth，未重启原容器。恢复后两个 API 健康接口、原管理页均为 200，默认桥中新建容器访问原 API 也通过。临时实例及数据已清理，报告明确记录网络副作用，不能将本次记为安全同机隔离验收。后续空环境导入必须使用独立虚拟机或独立主机，不在承载原服务的宿主机启动第二个 Docker 实例。

另在专属数据卷、网络及回环端口的临时 API 中完成后台页面基础验收：合成设备审批、拒绝、禁用、启用和中继关闭，测试用户远控/中继策略启用与撤销，准入日志按设备与错误码筛选；结果与数据库及六类后台操作审计一致。测试资源已删除，不包含官方客户端操作后的连接验收、在线状态变化或完整错误目录覆盖。

## 使用前检查

通过可信 SSH 或其他可信渠道传输候选包。摘要只能检查内容一致性，不能替代签名或可信来源认证。

```bash
cd "$OFFLINE_RELEASE_DIR"
sha256sum -c SHA256SUMS
docker image load --input controlled-images.tar
set -a
. ./images.env
set +a
```

`images.env` 仅提供不可变镜像 ID，不提供运行凭据。管理员凭据和内部密钥仍从仓库外私有配置注入；正式部署目录及其 `data` 必须独立于原应用和回滚保留目录。不要在离线包目录直接启动正式服务。

在准备好的独立部署目录执行首次切换预检：

```bash
python3 "$OFFLINE_RELEASE_DIR/controlled-compose-preflight.py" \
  "$CONTROLLED_DEPLOY_DIR/docker-compose.controlled.yaml"
```

在独立物理主机或独立虚拟机上执行离线导入验收。目标 Docker 在导入前不得已存在候选镜像；脚本先校验摘要和镜像清单，再导入、核对不可变 ID 并运行无宿主端口的三容器完整验收：

```bash
CONTROLLED_INDEPENDENT_HOST=1 \
  sh scripts/deploy/controlled-offline-import-acceptance.sh \
  "$OFFLINE_RELEASE_DIR" "$RUSTDESKWEB_ROOT"
```

只检查包内容而不导入镜像时使用 `--verify-only`。该模式已在授权主机对历史完整包和当前运行镜像包通过，但不计作独立主机导入验收。`SHA256SUMS` 及清单中的每个文件都必须是包内普通文件，符号链接以 `ERR-2397` 拒绝，即使链接目标的摘要正确也不允许。完整模式要求当前包的 `source-docker-id` 有摘要覆盖，且目标 Docker ID 与来源不同；旧完整包缺少该文件，不能直接用于完整模式。

预检解析实际环境变量覆盖后的 Compose，不打印凭据，检查回环管理/Web 端口、强制登录、内部密钥一致、专用 API 模式、服务鉴权地址、健康依赖、允许挂载和共享 key 卷。还会只读检查原 `rustdesk-api-server-pro` 及 `rustdesk-api-server-pro-precontrolled` 的挂载，拒绝新数据与这些目录重叠，包括符号链接解析后的重叠。

该保护面向首次切换，不是常规原地更新工具；旧容器改为其他名称后须单独核对其路径。预检不检查正式端口可用性、不备份数据、不轮换密钥，也不代表完整客户端验收完成。

## 尚未完成

- 独立干净主机实际导入验收及其他架构验证；导入工具、当前运行镜像包只读校验与同守护进程拒绝已完成。镜像仓库发布已按用户决定取消，不再是完成条件。
- 完整官方客户端矩阵、外部认证联调。
- 独立公网收口验收，以及旧客户端/旧公钥和切换后数据差异的完整回滚验收。

共享出口 IP 的双端仍拒绝中继。正式切换步骤继续以 `CONTROLLED_RUSTDESK_CUTOVER.md` 为准。
