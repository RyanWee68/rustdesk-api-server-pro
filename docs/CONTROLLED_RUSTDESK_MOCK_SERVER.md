# 受控部署 Mock RustDesk Server

本文档说明 `docker/mock-rustdesk-server` 的用途和边界。

## 用途

当前仓库已有固定官方基线的受控补丁，但尚未在独立 fork 维护，也未完成真实客户端验收。为了单独验证一体化 Dockerfile、entrypoint、healthcheck 和 Compose 生命周期，仓库提供一个 mock 镜像：

```text
docker/mock-rustdesk-server/
```

该 mock 镜像只提供：

- `/usr/local/bin/hbbs`
- `/usr/local/bin/hbbr`

两个脚本都会检查 `MUST_LOGIN`、`API_SERVER`、`API_INTERNAL_SECRET` 和 `RUSTDESK_KEY_DIR`，然后保持进程常驻，供一体化容器验证启动顺序和健康检查。

## 严格边界

mock 镜像不实现 RustDesk 协议，不调用内部准入 API，也不能证明注册制、防绕过或真实客户端连接有效。

以下验收不能使用 mock 作为通过证据：

- 未注册设备无法连入；
- 审批通过后可以连入；
- 禁用设备后连接失败；
- 禁用用户后连接失败；
- 关闭中继后 relay 失败；
- `hbbr` 不能被客户端绕过直接使用。

这些项目必须等待真实改造版 `rustdesk-server` fork 和真实客户端 PoC。

## 一体化 Compose 生命周期 Smoke

在有 Docker CLI 的环境运行：

```bash
sh scripts/deploy/controlled-compose-smoke.sh .
```

脚本会：

1. 构建独立命名的 mock server 镜像并生成随机测试凭据；
2. 使用 mock 镜像作为 `RUSTDESK_CONTROLLED_SERVER_IMAGE`；
3. 构建 `Dockerfile.controlled` 的 `controlled-smoke` 测试阶段；默认最终 `production` 阶段仍强制检查真实 `hbbs/hbbr` 动态库；
4. 启动专用的 `docker-compose.controlled-smoke.yaml`；
5. 等待容器健康；
6. 强制重建容器并校验配置摘要和三个持久卷标记；
7. 无论成功或失败，自动清理本次测试创建的容器、网络和卷。

脚本使用时间和进程号生成独立项目名、镜像名，忽略正式部署的项目名和镜像变量。专用 Compose 不映射宿主端口，也不挂载正式配置或数据。如需保留现场可设置 `KEEP_CONTROLLED_SMOKE=1`；退出时输出项目名和镜像名。重建持久化检查仅验证配置与卷，不验证真实授权状态。

2026-10-09 已在授权 Linux 主机执行该脚本，Mock 启动、健康检查、强制重建和三个持久卷检查均通过，测试容器、网络和卷已自动清理。无 Docker 环境可执行 `bash scripts/deploy/controlled-compose-regression.sh .`，验证六个模拟流程；该结果不能视为镜像或容器验收通过。不要将 mock 镜像用于正式 Compose 或客户端验收。
