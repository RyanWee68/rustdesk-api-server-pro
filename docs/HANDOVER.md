# 交接文档

> 本文档供新会话快速了解项目当前状态，避免重复探索。易变化事实只指向单一事实来源，不在此处重复维护。

## 当前事实入口

- 当前版本：以根目录 `VERSION` 为准。
- 当前状态：以 [CURRENT_STATUS.md](./CURRENT_STATUS.md) 为准。
- 文档索引：以 [README.md](./README.md) 和 [DOCUMENTATION_GUIDE.md](./DOCUMENTATION_GUIDE.md) 为准。
- 部署方式：当前推荐单容器一体化服务；部署细节见 [DOCKER.md](./DOCKER.md) 和 [OPENWRT_ONE_CONTAINER.md](./OPENWRT_ONE_CONTAINER.md)。
- 端口规则：默认客户端 API 端口为 `12345`，默认管理后台 Web/API 端口为 `12346`；实际监听以 `server.yaml` 的 `httpConfig.port` / `httpConfig.adminPort` 或运行环境变量为准；详见 [PORTS.md](./PORTS.md)。

## 项目快速概览

- 项目名称：RustDesk API Server Pro（兼容增强版）。
- 技术栈：Go + Vue3 + SQLite/MySQL。
- 主分支：`main`。
- 仓库结构：
  - `backend/`：Go 后端（Iris v12 + Xorm + SQLite/MySQL）。
  - `soybean-admin/`：Vue3 管理后台（Vite + Naive UI + Pinia）。
  - `docs/`：项目文档。
  - `Dockerfile`：多阶段构建。
  - `VERSION`：版本号单一事实来源。

## 架构边界

- 双 HTTP 端口分别提供：
  - 客户端 API 端口：RustDesk 客户端 API `/api/*`、plugin-sign 兼容 `/lic/web/api/plugin-sign`
  - 管理端口：管理后台接口 `/admin/*`、用户门户接口 `/user-portal/*`、管理后台前端 `/`
- 前端使用 hash 路由模式。
- plugin-sign、企业策略等能力是兼容占位或最小兼容模型，不能描述为官方完整 Pro 能力。

## 鉴权中间件

- `AdminAuth`：管理员鉴权（`is_admin=true`）。
- `UserAuth`：用户鉴权（允许 admin 和普通用户）。
- `AdminOrUserAuth`：管理员或用户鉴权，查看允许，写操作需检查 `isAdmin`。
- `ApiAuth`：客户端 API 鉴权（`is_admin=false`）。
- 鉴权中间件返回 401/406 时必须使用 `StopWithJSON`，错误消息必须带 `ERR-xxxx` 编码前缀。

## 本地验证

### 后端

```bash
cd backend
go test ./...
go vet ./...
go build -o rustdesk-api-server-pro.exe .
```

### 前端

```bash
cd soybean-admin
pnpm install
pnpm typecheck
pnpm build
```

### 安全检查

```bash
git grep -nE "(BEGIN RSA|BEGIN OPENSSH|AKIA|ghp_|clientSecret|password|private_key|token)" -- .
```

人工确认命中项只包含代码字段名、测试占位符或文档占位符。手工接口文件只能提交占位符，真实 token、密码和 Cookie 放入被忽略的 `*.local.http` 或 `*.private.http`。

## 关键文档

| 文档 | 用途 |
|------|------|
| `README.md` | 项目总览、快速开始、配置说明 |
| `docs/CURRENT_STATUS.md` | 当前能力、架构和边界 |
| `docs/PROJECT_DESCRIPTION.md` | 项目详细描述 |
| `docs/PROJECT_WORKFLOW.md` | 开发、验证、提交和发布规范 |
| `docs/LESSONS_LEARNED.md` | 经验教训与技术笔记 |
| `docs/DOCKER.md` | Docker 部署 |
| `docs/OPENWRT_ONE_CONTAINER.md` | OpenWrt 一体化部署 |
| `docs/PORTS.md` | 端口说明 |
| `docs/TROUBLESHOOTING.md` | 排障手册 |
| `docs/SECRET_HANDLING.md` | 密钥处理规范 |
| `AGENTS.md` | AI 代理与开发规则 |

## 交接维护要求

- 重要变更后同步更新本文件，但不要复制会随发布自动变化的版本号、线上主机、个人 SSH alias、真实路径或私有部署参数。
- 部署、端口、OAuth、数据库、默认配置变化时，同步更新 `CURRENT_STATUS.md`、根 README 和对应专项文档。
- 历史流水放入 `docs/archive/devlog.txt`，不要把旧事实保留为当前事实。
