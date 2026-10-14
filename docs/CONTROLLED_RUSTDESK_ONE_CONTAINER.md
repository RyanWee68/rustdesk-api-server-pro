# RustDesk 受控一体化镜像说明

本文档描述 `API + hbbs + hbbr` 单容器 PoC。`Dockerfile.controlled-server` 从固定官方基线应用本仓库补丁并构建专用 server 镜像；不能使用官方未改造镜像替代。2026-10-09 已在授权 Linux 主机完成镜像构建和隔离容器健康、重启持久化验证，真实客户端协议验收仍未完成。

同日还使用 `docker-compose.controlled-isolated.yaml` 对真实一体化镜像完成无端口发布的 Compose 启动、强制重建和数据卷持久化验收。该配置只供隔离测试，不代表下方正式 Compose 的生产端口部署已通过。

## 前置要求

改造版 `rustdesk-server` 镜像必须满足以下条件：

- 镜像内存在可执行文件 `/usr/local/bin/hbbs`；
- 镜像内存在可执行文件 `/usr/local/bin/hbbr`；
- `hbbs/hbbr` 支持 `MUST_LOGIN`、`API_SERVER`、`API_INTERNAL_SECRET`、`API_TIMEOUT_SECONDS`、`AUTH_CACHE_SECONDS` 等环境变量；
- API 不可用或 API 返回拒绝时，默认拒绝新连接；
- `hbbr` 必须校验 API 或只接受 `hbbs` 授权后的流量。

## 构建

```bash
docker build -f Dockerfile.controlled-server -t rustdesk-server-controlled:local .
export RUSTDESK_CONTROLLED_SERVER_IMAGE=rustdesk-server-controlled:local
export RUSTDESK_API_INTERNAL_SECRET='替换为至少32字符的随机密钥'
export ADMIN_USER='替换为管理员用户名'
export ADMIN_PASS='替换为至少12字符的独立密码'
# 默认使用 proxy.golang.org；若该源不可达，可指定经审核的 Go 模块源。
# export GO_MODULE_PROXY='https://goproxy.cn'
docker compose -f docker-compose.controlled-one.yaml build
```

构建 server 镜像时必须能从 GitHub 获取固定 commit、子模块及 Cargo 依赖。server 构建和一体化运行镜像均基于 Debian bookworm，避免将 GNU/Linux Rust 二进制复制到 Alpine；两个镜像在构建时用 `ldd` 拒绝缺失动态库。若改用其他 server 镜像，必须先核对 `/usr/local/bin/hbbs`、`/usr/local/bin/hbbr` 路径及动态库兼容性。镜像构建和隔离容器运行已有通过记录，但不能代替官方客户端验收。

三容器 Compose 另需显式设置 `RUSTDESK_API_IMAGE`。可使用新增的 `Dockerfile.controlled-api`，从同版受控一体化镜像复用后端、前端与配置模板，移除 hbbs/hbbr 可执行入口并仅启动 API；普通公开 API 镜像不能默认视为兼容。构建及隔离验收说明见 [三容器部署](CONTROLLED_RUSTDESK_THREE_CONTAINERS.md)。

受控 Compose 均要求显式提供初始管理员用户名和密码；entrypoint 会拒绝空密码、已知示例值和少于 12 字符的密码。不要把真实凭据写进仓库或构建参数。

真实 fork 完成前，可以使用 mock 镜像验证一体化容器生命周期，说明见：

```text
docs/CONTROLLED_RUSTDESK_MOCK_SERVER.md
```

注意：mock 只能验证 Docker 启动和健康检查，不能作为真实 RustDesk 客户端准入验收依据。

## 启动

在不开放宿主端口的隔离环境，可先执行：

```bash
RUSTDESK_CONTROLLED_IMAGE=rustdesk-api-server-pro-controlled:local \
  sh scripts/deploy/controlled-real-compose-smoke.sh .
```

脚本先检查镜像中的 `hbbs/hbbr` 为可用的动态链接二进制，避免误传 Mock 或普通镜像；随后生成一次性管理员密码和内部密钥，使用独立项目及命名卷，结束后清理本次资源；失败时也会尝试清理。它不验证官方客户端协议。

正式部署前仍需独立完成端口、凭据和客户端准入验收：

```bash
docker compose -f docker-compose.controlled-one.yaml up -d
docker logs rustdesk-api-server-pro-controlled --tail 100
```

启动顺序由 `/app/controlled-entrypoint.sh` 控制：

1. 检查内部密钥、`MUST_LOGIN` 和 `hbbs/hbbr` 二进制；
2. 初始化 `/app/data/server.yaml`；
3. 执行数据库迁移和首次管理员初始化；
4. 启动 API；
5. 等待 `/api/health` 通过；
6. 启动 `hbbs`；
7. 启动 `hbbr`；
8. 监控三个进程，任一进程退出则容器失败退出。

## 持久化目录

- `/app/data`：API 数据库和持久化配置；
- 镜像内的无密钥模板仅在首次启动时复制到 `/app/data/server.yaml`，无需从仓库挂载真实配置；后续配置保存在持久化数据目录中；
- `/app/rustdesk-server`：RustDesk server key；
- `/app/logs`：预留日志目录。

## 端口

- `12345`：客户端/API 端口；
- `12346`：管理后台端口，默认绑定 `127.0.0.1`；
- `21115/tcp`、`21116/tcp`、`21116/udp`、`21117/tcp`：RustDesk 受控服务端口；
- `21118/tcp`、`21119/tcp`：Web 端口，默认绑定 `127.0.0.1`。

## 验收清单

- 未设置 `RUSTDESK_API_INTERNAL_SECRET` 时容器拒绝启动；
- 内部密钥长度不足 32 字符时容器拒绝启动；
- `hbbs/hbbr` 二进制缺失时容器拒绝启动；
- API 健康检查通过后才启动 `hbbs/hbbr`；
- API 进程退出后容器失败退出；
- `hbbs/hbbr` 任一进程退出后容器失败退出；
- 容器重启后 `/app/data` 和 `/app/rustdesk-server` 数据不丢失；
- 未注册设备不能连入；
- 审批通过设备可以连入；
- 禁用设备后在缓存过期时间内失效；
- API 停止后新连接失败。
