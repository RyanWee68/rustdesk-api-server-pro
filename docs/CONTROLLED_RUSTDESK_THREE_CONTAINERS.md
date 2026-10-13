# RustDesk 受控三容器部署

三容器模式分别运行 API、hbbs 和 hbbr。服务间使用 Docker 网络访问内部准入 API；API 健康后启动 hbbs，hbbs 健康后启动 hbbr，server key 通过专属卷共享。

## 镜像准备

先按 [一体化构建说明](CONTROLLED_RUSTDESK_ONE_CONTAINER.md) 构建同一版本的受控 server 和一体化镜像，再从一体化产物生成专用 API 镜像：

```bash
docker build --network none \
  --build-arg RUSTDESK_CONTROLLED_IMAGE=rustdesk-api-server-pro-controlled:local \
  -f Dockerfile.controlled-api -t rustdesk-controlled-api:local .

export RUSTDESK_API_IMAGE=rustdesk-controlled-api:local
export RUSTDESK_CONTROLLED_SERVER_IMAGE=rustdesk-server-controlled:local
```

API 镜像复用已有后端、前端和无凭据配置模板，移除 hbbs/hbbr 可执行入口，并启用 `CONTROLLED_API_ONLY=1`。共享入口负责配置、迁移、管理员初始化和 API 进程回收；一体化镜像默认仍启动三个进程。非法模式、缺少内部密钥和把 API 专用镜像切回一体化模式均拒绝启动。

## 隔离验收

在授权 Linux Docker 主机执行：

```bash
sh scripts/deploy/controlled-three-compose-smoke.sh .
```

依赖本机已有的两个镜像、Docker Compose、Python 3、libsodium、nsenter、`alpine:3.20.3` 镜像和 curl。隔离配置通过 `extends` 复用正式服务定义，使用 `!reset` 清除固定容器名及宿主端口，使用 `!override` 替换 API 数据挂载。本轮使用 Docker Compose 5.1.3 验证；其他版本需支持这两个标记。

脚本生成随机管理员密码与内部密钥，忽略部署目录的 `.env`。启动前解析 Compose JSON，确认只有三个服务、没有宿主端口或固定容器名、全部使用本项目专属卷，网络设置为内部网络；失败或正常结束均清理本次项目。

验收覆盖：

- API、hbbs、hbbr 健康和跨容器准入烟测。
- 未签发中继请求关闭，hbbr 日志为 `ERR-2315`。
- `hbbs` 签名密钥交换与加密收发；未登录、撤销令牌、禁用用户/目标、待审批目标及关闭远控/中继的拒绝和恢复；真实 `hbbs` 签发的未过期授权由 `hbbr` 双端核销，两端重放拒绝，审计记录与令牌脱敏联查。
- 明文令牌、篡改密文与 WebSocket 明文令牌拒绝；UDP 新设备注册拒绝。
- UDP 四类打洞/通知/地址/中继消息无响应；另一来源无 UUID 心跳不能改写原注册 IP。
- 独立停止 API 后 hbbs/hbbr 仍存活，加密连接、UDP 注册和新中继请求拒绝并记录 `ERR-239B`；恢复 API 后重新验收准入。
- 模拟后台保存四空格 YAML 后，API 重启及所有容器强制重建仍正常。
- 配置及 server key 摘要不变，初始化标记和三个数据卷内容保留。

该验收不覆盖官方客户端远控、WebSocket 正常连接、跨网络身份或生产端口切换。

## 正式配置

正式配置为 `docker-compose.controlled.yaml`，另需提供仓库外的管理员凭据和内部密钥：

```bash
export ADMIN_USER='替换为管理员用户名'
export ADMIN_PASS='替换为至少12字符的独立随机密码'
export RUSTDESK_API_INTERNAL_SECRET='替换为至少32字符的随机密钥'
docker compose -f docker-compose.controlled.yaml config --quiet
```

配置不再强制挂载不存在的根目录 `server.yaml`；首次启动从镜像模板初始化，以后的修改保存在 `./data/server.yaml`。API 数据位于 `./data`，日志使用 `controlled-logs` 卷，server key 使用 `rustdesk-server-key` 卷，并挂载到三个服务对应目录。

正式配置保留既有容器名与端口约定：API `12345`、回环管理端口 `12346`、RustDesk `21115/21116/21117`，WebSocket 端口默认绑定回环。正式端口、旧服务切换、密钥轮换和回滚仍需独立验收。

原服务只读核对、数据库副本迁移及切换/回滚清单见 [正式切换说明](CONTROLLED_RUSTDESK_CUTOVER.md)。本轮 Go 迁移修复已包含在 `rustdesk-controlled-api:test-20261012-migration-v1`，完整三容器隔离复验通过；正式切换前仍需纳入发布并核对原 YAML 配置。
