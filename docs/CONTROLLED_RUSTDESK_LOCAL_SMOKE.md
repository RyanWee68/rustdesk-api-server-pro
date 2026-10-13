# 本地受控准入 smoke

本文档记录不依赖真实 RustDesk 客户端的本地 smoke 方式。它只能验证 API 内部准入 HTTP 路径，不能替代阶段 4 的真实 `hbbs/hbbr` 改造和客户端 PoC。

## 推荐环境

优先在 Linux、NAS 或 CI 环境运行：

```bash
scripts/deploy/controlled-api-smoke.sh .
```

脚本会：

1. 在临时目录构建 API 二进制；
2. 写入临时 `server.yaml` 和 SQLite 数据库；
3. 启动临时 API；
4. 调用 `scripts/deploy/controlled-admission-smoke.sh`；
5. 停止临时 API 并清理临时目录。

## Windows 限制

Windows Git Bash 下，外部 `.exe` 服务进程可能无法被 shell 信号可靠停止。脚本默认拒绝在 Windows Git Bash 运行，避免留下占用端口的临时服务。

如果确认当前环境可以接受并已准备手动清理方式，可显式执行：

```bash
ALLOW_WINDOWS_API_SMOKE=1 scripts/deploy/controlled-api-smoke.sh .
```

如需手动确认端口：

```cmd
netstat -ano | findstr :19055
```

## 结果判读

- 无内部密钥和错误内部密钥必须返回 `ERR-2301`；
- 正确内部密钥必须进入业务准入逻辑，不能继续返回 `ERR-2301`；
- 无真实客户端 token 时，鉴权可能返回 `ERR-2303` 或其它与临时设备状态相关的拒绝码，需要结合 smoke 输出判断；
- 该 smoke 不验证 `hbbs/hbbr` 是否真正调用 API。

## CI 自动回归

`.github/workflows/controlled-deployment.yml` 在 Linux runner 中自动执行：

1. 后端测试与构建；
2. 前端类型检查与构建；
3. 受控部署静态检查、Rust 模板检查和部署工具自测；
4. 临时 API 准入 smoke；
5. Mock 一体化 Compose 生命周期 smoke。

CI 不包含真实改造版 `rustdesk-server` fork 和官方客户端，因此不能把 CI 通过视为阶段 4、阶段 7 或真实客户端验收完成。
