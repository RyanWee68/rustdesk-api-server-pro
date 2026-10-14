# rustdesk-server fork 接入脚手架

## 当前独立 fork

2026-10-13：用户私有远程仓库 `https://github.com/RyanWee68/rustdesk-server-controlled.git` 已接为 origin；官方 upstream 保留。`codex/controlled-admission` 已推送并跟踪远程，当前维护提交 `6a2be11`。首次 CI 的作业级 runner 上下文错误已修复，[远程运行 38329154144](https://github.com/RyanWee68/rustdesk-server-controlled/actions/runs/38329154144) 已全部成功，覆盖固定子模块核对、Linux 双二进制编译和库回归；本地结构检查及库回归 16/16 再次通过。下面的“尚无 origin/未推送”是 10 月 12 日历史状态。本工作流不构建 API/前端镜像，不替代完整三容器或官方客户端验收。

同日显式强制中继修复已作为 `41e846f` 推送，[远程运行 38346988802](https://github.com/RyanWee68/rustdesk-server-controlled/actions/runs/38346988802) 已完成且结论为 success，覆盖固定子模块核对、Linux 双二进制编译和 16 项库回归。

2026-10-12 已有本地独立维护仓库 `D:/WorkSpace/Other/RustDeskServerControlled`，分支 `codex/controlled-admission`；只有 upstream，没有 origin。已新增 `.github/workflows/controlled-maintenance.yml`：支持 main/codex 分支推送、PR 和手工触发，只读权限，固定 Rust 1.99.0 和协议子模块，编译双二进制并运行库回归；缓存及测试工作目录放在 runner 临时目录，避免上游数据库测试写入源码目录。

尚未推送该工作流，也没有远程 CI 执行记录；需要用户提供可推送的目标远程仓库。不得将 upstream 改作用户仓库或将维护分支直接推到官方上游。本轮没有提交或推送。

本轮工作流 YAML/手工触发/只读权限/步骤与缓存配置检查通过，Windows 独立 fork 库回归 16/16 再次通过。先 `cargo test --no-run`，再在仓库外运行生成的测试程序，确保上游的 `test.sqlite3` 不污染源码目录；CI 也采用同样隔离。上游编译警告未作无关修改；这些本地结果不代表 Linux 远程 CI 已执行。

本文档用于阶段 4：在真实 `rustdesk-server` fork 创建后，把当前仓库已经固定的准入 API 契约、Rust 客户端模板和检查说明复制到 fork 中。

## 前置条件

- 已准备一个真实 `rustdesk-server` fork 源码目录；
- fork 根目录存在 `Cargo.toml`；
- 当前仓库保留 `templates/rustdesk-server-controlled/` 和 `docs/CONTROLLED_RUSTDESK_API_CONTRACT.md`。

## dry-run

先执行 dry-run，确认目标目录和复制清单：

```bash
scripts/deploy/controlled-fork-bootstrap.sh /path/to/rustdesk-server-fork --dry-run
```

脚本会检查目标目录是否像 Rust workspace，并显示将写入的文件，不会实际修改 fork。

## 写入接入资料

确认无误后执行：

```bash
scripts/deploy/controlled-fork-bootstrap.sh /path/to/rustdesk-server-fork
```

脚本会在 fork 中创建：

```text
controlled-api/
├── Cargo.toml
├── README.md
├── controlled_admission.rs
├── CONTROLLED_RUSTDESK_API_CONTRACT.md
├── CONTROLLED_RUSTDESK_SERVER_FORK.md
└── CONTROLLED_RUSTDESK_SERVER_SOURCE_CHECK.md
```

如果目标目录已经存在，脚本会拒绝覆盖；确需覆盖时显式传入：

```bash
scripts/deploy/controlled-fork-bootstrap.sh /path/to/rustdesk-server-fork --force
```

## 接入后检查

完成 `hbbs/hbbr` 源码接入后，在当前仓库运行：

```bash
scripts/deploy/controlled-server-source-check.sh /path/to/rustdesk-server-fork
```

如果 fork 机器有 Rust 工具链，也可以先检查模板包：

```bash
cargo check --manifest-path /path/to/rustdesk-server-fork/controlled-api/Cargo.toml
```

## 边界

该脚本只复制模板和契约，不会自动修改 `hbbs/hbbr` 源码。真实准入是否生效，仍必须通过源码接入检查、镜像契约检查和官方客户端 PoC 验收确认。
