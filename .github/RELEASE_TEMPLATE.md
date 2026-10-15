# RustDesk API Server Pro {tag}

发布日期：{date}

版本：`{version}`

来源提交：`{commit}`

## 本次发布

- 构建 Linux、Windows、macOS 的 amd64 和 arm64 部署包。
- 部署包包含后端程序、管理后台静态资源、示例配置、部署文档以及许可证和合规声明。
- Docker 镜像不随 Release 发布；自用部署在 `192.168.0.211` 本地构建。

## 下载说明

- Linux x86-64：`linux-amd64.zip`
- Linux ARM64：`linux-arm64.zip`
- Windows x86-64：`windows-amd64.zip`
- Windows ARM64：`windows-arm64.zip`
- macOS Intel：`darwin-amd64.zip`
- macOS Apple Silicon：`darwin-arm64.zip`

## 升级说明

- Docker 部署使用目标主机本地构建的明确版本镜像。
- 二进制部署需要同时替换后端程序和 `dist` 静态资源，并执行 `sync` 后重启。
- Docker 启动脚本会自动同步数据库；已有 `/app/data` 配置和账号不会被覆盖。
- 升级前请备份数据库、运行配置和挂载目录。

## 安全与合规

- 发布包不包含生产数据库、OAuth 密钥、SMTP 密码、Token、日志或录屏文件。
- 本项目采用 AGPL-3.0，详细信息见 `LICENSE`、`NOTICE`、`SECURITY.md`、`PRIVACY.md` 和 `COMPLIANCE.md`。
- 本项目是独立兼容实现，并非 RustDesk 或其他第三方厂商的官方项目。
