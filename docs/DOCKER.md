# Docker 安装与配置参考（详细版）

本文档提供当前项目的 Docker / Docker Compose 安装、配置、默认参数、升级和常见排查方式。

当前推荐部署形态是**一体化容器**：同一个 `rustdesk-api-server-pro` 容器同时提供管理后台前端、管理后台接口和 RustDesk 客户端 API。

```text
rustdesk-api-server-pro
├── /          管理后台前端静态页面
├── /admin/*   管理后台接口
└── /api/*     RustDesk 客户端接口
```

如果你之前单独部署过 `rustdesk-web` / nginx 前端容器，升级到当前镜像后建议删除旧前端容器，避免旧版 `dist` 覆盖新版登录页，导致第三方登录按钮不显示或页面行为不一致。

## 受控三容器的 HTTPS 管理入口

受控部署使用 `docker-compose.controlled.yaml`；需要内置 HTTPS 管理入口时，再叠加 `docker-compose.controlled-tls.yaml`。证书和私钥必须预先放在持久化数据目录的 `data/tls/server.fullchain.pem`、`data/tls/server.key.pem`，私钥权限必须为 `0600`，且不能是符号链接。TLS 文件只接受 `tls` 目录的直接子文件，目录本身及其父路径不得经过符号链接，不接受含 `..` 或嵌套子目录的文件路径。覆盖文件不会生成、下载或提交证书。

```bash
chmod 600 data/tls/server.key.pem
docker compose \
  -f docker-compose.controlled.yaml \
  -f docker-compose.controlled-tls.yaml \
  up -d
```

HTTPS 宿主端口由 `FNOS_ADMIN_HTTPS_PORT` 设置，默认 `12443`。基础 Compose 的明文管理端口仍默认只绑定 `127.0.0.1`；如显式改为局域网地址，只能供内网使用，不得配置公网转发。公网管理应只转发 HTTPS 端口。

## 安装命令示例（可直接执行）

### 方式一：`docker compose`（推荐）

```bash
mkdir -p /opt/rustdesk-api-server-pro/data
cd /opt/rustdesk-api-server-pro

# 下载示例配置（下载后请修改 signKey、端口、数据库等）
curl -L -o server.yaml https://raw.githubusercontent.com/liyan-lucky/rustdesk-api-server-pro/main/backend/server.yaml

cat > docker-compose.yaml <<'YAML'
services:
  rustdesk-api-server-pro:
    container_name: rustdesk-api-server-pro
    image: ghcr.io/liyan-lucky/rustdesk-api-server-pro:latest
    environment:
      - "ADMIN_USER=${ADMIN_USER:-test}"
      - "ADMIN_PASS=${ADMIN_PASS:-testadmin}"
      - "PORT=12345"
      - "ADMIN_PORT=12346"
      - "RUSTDESK_HBBS_DIR=/root"
    ports:
      - "${FNOS_HTTP_PORT:-12345}:12345"
      - "${FNOS_ADMIN_HTTP_PORT:-12346}:12346"
    volumes:
      - ./server.yaml:/app/server.yaml
      - ./data:/app/data
      - /vol1/docker/rustdesk/hbbs:/root:ro
    restart: unless-stopped
    labels:
      name: "RustDesk API Server Pro"
      desc: "RustDesk API 增强服务端：独立客户端 API、内网管理后台、第三方登录、SQLite 数据持久化"
      ports: "12345/tcp,12346/tcp"
YAML

docker compose up -d
docker compose logs -f rustdesk-api-server-pro
```

飞牛 Docker 使用桥接网络时，可在同目录的 `.env` 中设置宿主机端口，容器内客户端 API 端口默认 `12345`，管理端口默认 `12346`：

```dotenv
FNOS_HTTP_PORT=12345
FNOS_ADMIN_HTTP_PORT=12346
ADMIN_USER=test
ADMIN_PASS=testadmin
```

路由器公网端口只转发 `FNOS_HTTP_PORT`。`FNOS_ADMIN_HTTP_PORT` 只供局域网访问，不要做公网转发。

账号只在空数据目录首次启动时创建。生产环境应立即替换示例密码；后续升级会复用现有数据库、环境变量、挂载和端口映射，不会重置账号。

### 方式二：`docker run`（host 网络）

```bash
mkdir -p /opt/rustdesk-api-server-pro/data
cd /opt/rustdesk-api-server-pro

curl -L -o server.yaml https://raw.githubusercontent.com/liyan-lucky/rustdesk-api-server-pro/main/backend/server.yaml

docker run -d \
  --name rustdesk-api-server-pro \
  --restart unless-stopped \
  -p "${FNOS_HTTP_PORT:-12345}:12345" \
  -p "${FNOS_ADMIN_HTTP_PORT:-12346}:12346" \
  --label "name=RustDesk API Server Pro" \
  --label "desc=RustDesk API 增强服务端：独立客户端 API、内网管理后台、第三方登录、SQLite 数据持久化" \
  --label "ports=12345/tcp,12346/tcp" \
  -e ADMIN_USER=test \
  -e ADMIN_PASS='testadmin' \
  -e PORT=12345 \
  -e ADMIN_PORT=12346 \
  -e RUSTDESK_HBBS_DIR=/root \
  -v $(pwd)/server.yaml:/app/server.yaml \
  -v $(pwd)/data:/app/data \
  -v /vol1/docker/rustdesk/hbbs:/root:ro \
  ghcr.io/liyan-lucky/rustdesk-api-server-pro:latest

docker logs -f rustdesk-api-server-pro
```

### 方式三：OpenWrt / x86 软路由一键对齐更新

OpenWrt 场景推荐阅读：

- [OpenWrt 一体化部署与对齐更新指南](./OPENWRT_ONE_CONTAINER.md)

可直接执行：

```bash
curl -L -o /tmp/update-openwrt-one-container.sh \
  https://raw.githubusercontent.com/liyan-lucky/rustdesk-api-server-pro/main/docker/update-openwrt-one-container.sh

sh /tmp/update-openwrt-one-container.sh
```

脚本默认会：

- 使用 `/mnt/docker/rustdesk-api` 作为数据目录
- 备份旧数据到 `/mnt/docker/backup/rustdesk-api`
- 使用 `--network host`
- 删除旧 `rustdesk-web` 容器，避免旧前端干扰
- 启动一体化 `rustdesk-api-server-pro` 容器
- 添加中文 `label` 和 `ports=12345/tcp,12346/tcp` 标记

## 常用命令

```bash
# compose 升级
docker compose pull
docker compose up -d

# compose 重启
docker compose restart rustdesk-api-server-pro

# 查看运行状态
docker compose ps

# 进入容器
docker exec -it rustdesk-api-server-pro sh

# 手动执行数据库同步（通常启动脚本已自动执行）
docker exec -it rustdesk-api-server-pro rustdesk-api-server-pro sync
```

镜像内附带可回滚更新脚本。在 Docker 主机执行以下命令即可提取并运行；脚本会从旧容器读取用户名、密码、应用端口和飞牛端口映射：

```bash
docker cp rustdesk-api-server-pro:/usr/local/share/rustdesk-api-server-pro/update-container.sh ./update-rustdesk-api.sh
chmod 700 ./update-rustdesk-api.sh
./update-rustdesk-api.sh
```

## 1. 容器镜像与启动行为

### 版本系统

镜像版本由仓库根目录的 `VERSION` 文件控制（单一事实来源）。当前自用部署不向 GitHub/GHCR 发布镜像，也不再由 Docker 工作流自动递增版本；版本变更应明确提交，并在 `192.168.0.211` 本地构建时通过 Go ldflags 和 Vite 环境变量注入。

- 后端：`main.appVersion` 和 `main.buildTime` 通过 ldflags 注入，运行时设置 `APP_VERSION` 和 `BUILD_TIME` 环境变量
- 前端：`VITE_APP_VERSION` 和 `VITE_BUILD_TIME` 在构建时注入
- 首页更新日志区域显示：`兼容版本 / 服务端版本` 和构建时间

### 镜像标签

当前部署只使用 `192.168.0.211` 上的本地标签。建议同时保留明确版本或完整提交 SHA 的标签用于回滚，不使用远程仓库标签作为部署来源。

### 启动流程

容器启动时会执行以下流程：

1. 建立可执行文件软链接（如需要）
2. 创建 `/app/data`
3. 若 `/app/data/server.yaml` 不存在，将挂载的 `/app/server.yaml` 复制过去（避免覆盖用户修改）
4. 切换工作目录到 `/app/data`
5. 若设置了 `PORT` / `ADMIN_PORT` 环境变量，分别更新 `httpConfig.port` / `httpConfig.adminPort`（仅修改 httpConfig 段）
6. 检测并替换不安全的默认 signKey
7. 执行 `rustdesk-api-server-pro sync`
8. 若首次启动且设置了 `ADMIN_USER` / `ADMIN_PASS`，自动创建管理员
9. 通过 `exec` 启动 `rustdesk-api-server-pro start`（Go 进程成为 PID 1，可接收 SIGTERM 优雅关闭）

程序读取配置文件的位置是当前工作目录下的 `server.yaml`。容器内进程实际在 `/app/data` 下运行，所以最终生效的配置文件是 `/app/data/server.yaml`。启动脚本会把你挂载到 `/app/server.yaml` 的配置复制到 `/app/data/server.yaml`。

## 2. 默认参数与目录

Dockerfile 中的默认项：

- 镜像内工作目录：`/app`
- 默认声明端口：`EXPOSE 12345 12346`
- 启动命令：`sh /app/start.sh`

注意：`EXPOSE 12345 12346` 只是镜像声明，程序实际监听端口仍由 `PORT` / `ADMIN_PORT` 或 `server.yaml` 的 `httpConfig.port` / `httpConfig.adminPort` 决定。

示例 `backend/server.yaml` 常见默认值：

- `httpConfig.port: ":12345"`
- `httpConfig.adminPort: ":12346"`
- `httpConfig.staticdir: "/app/dist"`
- `db.driver: "sqlite"`
- `db.dsn: "./server.db"`

建议持久化 `/app/data`，其中包含：

- `server.db`：SQLite 数据库
- `server.yaml`：实际生效配置
- `.init.lock`：自动创建管理员后的标记
- `record_uploads/`：录制上传文件

## 3. 配置文件最小示例

```yaml
signKey: "please-change-this-sign-key"
debugMode: false

db:
  driver: "sqlite"
  dsn: "./server.db"
  timeZone: "Asia/Shanghai"
  showSql: false

httpConfig:
  printRequestLog: false
  staticdir: "/app/dist"
  port: ":12345"
  adminPort: ":12346"

smtpConfig:
  host: "127.0.0.1"
  port: 1025
  username: ""
  password: ""
  encryption: "none"
  from: "noreply@example.com"

jobsConfig:
  deviceCheckJob:
    duration: 30
```

重点：

- `signKey` 必须修改，并且升级时保持固定。
- `httpConfig.staticdir` 在官方镜像内应为 `/app/dist`。
- SQLite 相对路径会落在 `/app/data`，因为进程工作目录是 `/app/data`。

## 4. 环境变量说明

当前镜像明确支持：

- `ADMIN_USER`：首次启动自动创建管理员用户名（可选）
- `ADMIN_PASS`：首次启动自动创建管理员密码（可选）
- `PORT`：覆盖 `server.yaml` 中的客户端 API 监听端口，如 `PORT=21114`（可选）
- `ADMIN_PORT`：覆盖 `server.yaml` 中的管理后台 Web/API 监听端口，如 `ADMIN_PORT=21115`（可选）
- `RUSTDESK_HBBS_DIR`：指定 hbbs 数据目录，用于自动读取 `id_ed25519.pub` 获取 KEY（可选）
- `APP_VERSION`：服务端版本号（Dockerfile 构建时注入，通常无需手动设置）
- `BUILD_TIME`：构建时间（Dockerfile 构建时注入，通常无需手动设置）

### KEY 自动检测

管理后台的 KEY 字段按以下优先级获取：

1. `RUSTDESK_KEY` 环境变量（最高优先级）
2. `RUSTDESK_HBBS_DIR` 环境变量指向的目录中的 `id_ed25519.pub`
3. 当前工作目录（Docker 中即 `/app/data`）中的 `id_ed25519.pub`
4. `/app/data/id_ed25519.pub`

Docker 部署时，将 hbbs 数据目录挂载到 `/app/data` 即可自动获取 KEY，无需手动设置。

### 端口配置

Docker 的 `-p` 端口映射只是 NAT 转发，不改变应用实际监听端口。设置 `PORT` / `ADMIN_PORT` 环境变量可同时修改应用监听端口和配置文件：

```bash
docker run -e PORT=21114 -e ADMIN_PORT=21115 -p 21114:21114 -p 21115:21115 ...
```

生效条件：

- 两者都非空
- `/app/data/.init.lock` 不存在

注意：首次创建后会写入 `.init.lock`。后续即使修改环境变量，也不会再次自动创建管理员，除非你删除 `.init.lock` 并自行确认风险。

## 5. 访问方式与端口说明

假设 `server.yaml` 配置 `httpConfig.port: ":12345"`、`httpConfig.adminPort: ":12346"`：

- 客户端 API：`http://<host>:12345/api/...`
- 管理后台页面：`http://<host>:12346/`
- 管理后台接口：`http://<host>:12346/admin/...`

路由器公网端口只转发客户端 API 端口。管理端口只建议在局域网、VPN 或受控反向代理中访问。

更多细节可结合：

- [端口与访问路径说明](./PORTS.md)

## 6. 第三方登录与反向代理

新版推荐使用 `oauth.providers` 配置 GitHub / Google / OIDC。管理后台登录回调路径为：

```text
/admin/auth/oauth/<provider>/callback
```

客户端第三方登录会使用公网客户端 API 端口上的回调路径：

```text
/api/oauth/<provider>/callback
```

如果使用外部 Nginx / Caddy / OpenWrt 反代，建议只把公网域名反代到客户端 API 端口，例如：

```text
127.0.0.1:12345
```

管理后台请使用内网地址、VPN、ACL 或防火墙限制访问，例如：

```text
127.0.0.1:12346
```

不要再让 `/` 指向旧 `rustdesk-web` 的 dist，也不要把管理端口转发到公网。

反代建议传递：

```nginx
proxy_set_header Host $host;
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Real-IP $remote_addr;
```

用于检查第三方登录配置是否生效：

```bash
curl http://127.0.0.1:12346/admin/auth/oauth/providers
curl "http://127.0.0.1:12346/admin/auth/oauth/url?provider=github"
```

## 7. 升级命令

### Compose 升级

```bash
docker compose pull
docker compose up -d
docker compose logs -f rustdesk-api-server-pro
```

### docker run 升级

```bash
docker pull ghcr.io/liyan-lucky/rustdesk-api-server-pro:latest
docker rm -f rustdesk-api-server-pro
# 然后重新执行 docker run，保持原有 -v / -e / label / 网络参数
```

当前启动脚本会自动执行 `sync`，升级后仍建议查看日志确认数据库同步成功。

## 8. 常见问题

### 8.1 修改了 `server.yaml` 但配置没生效

排查：

1. 确认挂载的是 `/app/server.yaml`
2. 重启容器
3. 进入容器检查 `/app/data/server.yaml` 内容是否已更新

### 8.2 首页打不开，但 `/api/*` 正常

通常是 `httpConfig.staticdir` 配置错误。Docker 环境下应指向：

```text
/app/dist
```

### 8.3 第三方登录按钮不显示

常见原因：

- 仍然访问旧 `rustdesk-web` 容器里的旧前端
- `oauth.providers` 没有启用任何 provider
- 当前访问入口和 OAuth `redirectUrl` 不一致

建议：删除旧 `rustdesk-web` 容器，只保留一体化 `rustdesk-api-server-pro` 容器，再访问管理端口 `http://<host>:12346/`。

### 8.4 数据丢失

通常是没有持久化 `/app/data`。请确认：

```text
-v ./data:/app/data
```

或等价挂载已经配置。

### 8.5 录制上传失败

请确认：

- `/app/data/record_uploads` 可写
- 容器日志中无文件写入报错
- 宿主机磁盘空间充足

### 8.6 docker pull ghcr.io 报 TLS 错误

**现象**：`http: server gave HTTP response to HTTPS client` 或 `SSL routines::wrong version number`

**原因**：Clash/Surge 代理的 fake-ip 模式缓存失效，DNS 返回 `198.18.x.x` 假地址

**处理**：

1. 重启 Clash 通常可恢复
2. 或开启 fake-ip 持久化：`uci set openclash.config.store_fakeip='1' && uci commit openclash`
3. 或给 Docker 配代理：`mkdir -p /etc/systemd/system/docker.service.d && cat > /etc/systemd/system/docker.service.d/proxy.conf << 'EOF' [Service] Environment="HTTPS_PROXY=http://127.0.0.1:7890" EOF && systemctl daemon-reload && systemctl restart docker`

### 8.7 更新镜像后 Web 页面 404

**原因**：旧容器残留的 `/app/data/server.yaml` 被保留（新版不再覆盖），但该文件可能已被 PORT sed 损坏

**处理**：删除 `/app/data/server.yaml`，重新创建容器

## 9. GHCR `denied` 排查

如果执行下面命令报错：

```bash
docker pull ghcr.io/liyan-lucky/rustdesk-api-server-pro:latest
# Error response from daemon: Head ... denied
```

通常是以下原因之一：

- GHCR 包未发布
- GHCR 包是私有，匿名拉取会被拒绝
- `latest` 标签不存在
- 未登录 GHCR（私有包场景）

排查建议：

1. 在仓库 `Actions` 中手动运行 Docker build 工作流，确认推送成功。
2. 到 GitHub 仓库右侧 `Packages` 打开 `rustdesk-api-server-pro`，将包可见性改为 `Public`。
3. 若暂时不公开，先执行 `docker login ghcr.io`，使用 GitHub 用户名 + PAT（需 `read:packages` 权限）。
4. 检查镜像标签是否存在。

## 10. 生产部署建议

最小上线清单：

1. 修改并固定 `signKey`
2. 配置正确的 `httpConfig.port` 和 `httpConfig.adminPort`
3. 持久化 `/app/data`
4. 首次启动创建管理员
5. 删除旧前端容器，避免旧 dist 干扰
6. 如使用反代，只把公网入口反代到客户端 API 端口，管理端口保持内网访问
7. 用最新版 RustDesk 客户端做冒烟测试：登录、地址簿、设备列表、分组面板、审计、录制上传
