# 端口与访问路径说明

本文档说明当前项目的端口用途、默认值、访问路径，以及和配置文件的对应关系。

## 1. 总体结构（重要）

当前项目默认是“双 HTTP 端口”架构：

- RustDesk 客户端 API（`/api/...`）和插件签名兼容接口（`/lic/web/api/...`）使用客户端 API 端口
- 管理后台登录与管理接口（`/admin/...`）、普通用户门户（`/user-portal/...`）和管理后台前端静态页面（`/`）使用管理端口

部署到公网时，只应在路由器上转发客户端 API 端口。管理端口只供内网或受控 VPN 访问，不要做公网端口转发。

## 2. HTTP 端口

配置项位置：`backend/server.yaml`

```yaml
httpConfig:
  port: ":12345"
  adminPort: ":12346"
```

代码默认值（当 `server.yaml` 不存在或读取失败时）：

- 客户端 API 端口：`:8080`
- 管理端口：`:8081`

说明：

- `httpConfig.port` 是 RustDesk 客户端 API 端口，通常需要由路由器转发到公网
- `httpConfig.adminPort` 是管理后台 Web/API 端口，通常只在局域网开放
- `PORT` 环境变量会覆盖 `httpConfig.port`
- `ADMIN_PORT` 环境变量会覆盖 `httpConfig.adminPort`
- 如果 `adminPort` 为空或和 `port` 相同，程序会回退为旧的单端口模式

## 3. 路径划分

假设配置如下：

```yaml
httpConfig:
  port: ":12345"
  adminPort: ":12346"
```

### 3.1 RustDesk 客户端 API（公网端口）

- 地址：`http://<host>:12345`
- 前缀：`/api`
- 示例：
  - `POST /api/login`
  - `GET /api/users`
  - `GET /api/peers`
  - `POST /api/heartbeat`
  - `GET /api/login-options`

### 3.2 插件签名兼容接口（公网端口）

- 地址：`http://<host>:12345`
- 前缀：`/lic/web/api`
- 当前兼容端点：
  - `POST /lic/web/api/plugin-sign`

说明：这是为了兼容新版官方客户端/插件流程的请求路径，当前为兼容占位实现，不是官方真实签名服务。

### 3.3 管理后台前端页面（内网端口）

- 地址：`http://<host>:12346/`
- 入口：`/`

说明：

- 由管理端口通过 `HandleDir("/", staticdir)` 提供
- `staticdir` 路径不正确时，浏览器会打不开后台页面或出现 404

### 3.4 管理后台接口（内网端口）

- 地址：`http://<host>:12346`
- 前缀：`/admin`
- 示例：
  - `POST /admin/auth/login`
  - `GET /admin/users/list`
  - `GET /admin/devices/list`

### 3.5 普通用户门户（内网端口）

- 地址：`http://<host>:12346`
- 前缀：`/user-portal`

## 4. Docker 场景下的端口说明

Docker/Compose 常见配置是“容器内端口 + 主机映射端口”：

- 客户端 API 容器端口：由 `PORT` 或 `httpConfig.port` 决定，默认 `12345`
- 管理容器端口：由 `ADMIN_PORT` 或 `httpConfig.adminPort` 决定，默认 `12346`
- 宿主机访问端口：由 `docker-compose.yaml` 端口映射决定

示例：

```yaml
ports:
  - "${FNOS_HTTP_PORT:-12345}:12345"
  - "${FNOS_ADMIN_HTTP_PORT:-12346}:12346"
```

路由器公网转发建议：

- 转发 `FNOS_HTTP_PORT` 到公网，供 RustDesk 客户端访问
- 不转发 `FNOS_ADMIN_HTTP_PORT`，只允许局域网访问管理后台

## 5. 静态目录与端口的关系

配置项：

```yaml
httpConfig:
  staticdir: "/app/dist"
```

说明：

- `staticdir` 决定管理端口 `/` 页面展示什么
- 它不是端口配置，但配置错误会让你误以为“管理端口没启动”
- 常见症状：
  - 客户端 API 端口 `/api/*` 正常
  - 管理端口 `/` 首页空白或 404

排查顺序：

1. 先确认客户端 API 端口和管理端口分别监听正常
2. 再确认 `staticdir` 路径存在并且是前端构建产物目录
3. 最后检查防火墙、Docker 映射和路由器端口转发

## 6. SMTP 端口

配置项位置：`backend/server.yaml`

```yaml
smtpConfig:
  host: "127.0.0.1"
  port: 1025
```

注意：这是“连接外部 SMTP 服务器”的目标端口，不是本程序额外监听的本地端口。

## 7. 建议的生产规划

最小化部署建议：

- RustDesk 客户端 API：`12345`，按需在路由器转发到公网
- 管理后台 Web/API：`12346`，只允许局域网或 VPN 访问
- SMTP：使用现有企业邮件服务，无需本机开放 SMTP 监听

如果使用反向代理：

- 公网域名只反代到客户端 API 端口
- 管理后台使用内网域名、VPN、ACL 或防火墙限制访问
