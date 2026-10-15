#!/bin/sh

set -eu

failures=0
warnings=0

fail() {
    failures=$((failures + 1))
    printf 'FAIL: ERR-2396 %s\n' "$1" >&2
}

warn() {
    warnings=$((warnings + 1))
    printf 'WARN: %s\n' "$1" >&2
}

pass() {
    printf 'PASS: %s\n' "$1"
}

contains() {
    file="$1"
    pattern="$2"
    grep -Eq "$pattern" "$file"
}

require_file() {
    file="$1"
    if [ -f "$file" ]; then
        pass "找到文件：$file"
    else
        fail "找不到文件：$file"
    fi
}

check_dockerfile() {
    file="$1"
    require_file "$file"
    [ -f "$file" ] || return

    if contains "$file" '^ARG RUSTDESK_CONTROLLED_SERVER_IMAGE'; then
        pass "Dockerfile 要求改造版 rustdesk-server 镜像参数"
    else
        fail "Dockerfile 未声明 RUSTDESK_CONTROLLED_SERVER_IMAGE"
    fi

    if contains "$file" '^FROM \$\{RUSTDESK_CONTROLLED_SERVER_IMAGE\} AS rustdesk-server'; then
        pass "Dockerfile 从改造版镜像抽取 hbbs/hbbr"
    else
        fail "Dockerfile 未使用 RUSTDESK_CONTROLLED_SERVER_IMAGE 作为 rustdesk-server 阶段"
    fi

    if contains "$file" 'COPY --from=rustdesk-server /usr/local/bin/hbbs /usr/local/bin/hbbs' &&
        contains "$file" 'COPY --from=rustdesk-server /usr/local/bin/hbbr /usr/local/bin/hbbr'; then
        pass "Dockerfile 复制 hbbs/hbbr 二进制"
    else
        fail "Dockerfile 未复制 hbbs/hbbr 二进制"
    fi

    if contains "$file" 'controlled-entrypoint.sh' && contains "$file" 'controlled-healthcheck.sh'; then
        pass "Dockerfile 包含受控 entrypoint 和 healthcheck"
    else
        fail "Dockerfile 缺少受控 entrypoint 或 healthcheck"
    fi

    if contains "$file" '^HEALTHCHECK '; then
        pass "Dockerfile 配置健康检查"
    else
        fail "Dockerfile 未配置 HEALTHCHECK"
    fi

    if contains "$file" '^ENV CGO_ENABLED=0' && contains "$file" '^FROM debian:bookworm-slim'; then
        pass "一体化镜像使用静态 Go 二进制和 Debian 运行基底"
    else
        fail "一体化镜像缺少 CGO 关闭或 Debian 运行基底"
    fi

    if contains "$file" '^FROM node:22-alpine AS node' && contains "$file" 'npm install -g pnpm@9'; then
        pass "一体化镜像的前端构建工具版本与 CI 对齐"
    else
        fail "一体化镜像的 Node/pnpm 版本未与 CI 对齐"
    fi

    if contains "$file" 'COPY ./templates/controlled-server.yaml /app/server.yaml' &&
        ! contains "$file" 'COPY --from=golang /backend/server.yaml'; then
        pass "一体化镜像使用无凭据配置模板"
    else
        fail "一体化镜像可能复制工作区运行配置"
    fi

    if contains "$file" '^FROM controlled-smoke AS production' &&
        contains "$file" 'ldd /usr/local/bin/hbbs' &&
        contains "$file" 'ldd /usr/local/bin/hbbr'; then
        pass "默认生产阶段检查 RustDesk 动态库"
    else
        fail "默认生产阶段缺少 RustDesk 动态库检查"
    fi
}

check_build_context() {
    file="$1"
    require_file "$file"
    [ -f "$file" ] || return
    if contains "$file" '^server.yaml$' && contains "$file" '^\*\*/node_modules$' &&
        contains "$file" '^\*\*/\.env\*$'; then
        pass "Docker 构建上下文排除运行配置、依赖和私有环境文件"
    else
        fail "Docker 构建上下文缺少敏感文件排除规则"
    fi
}

# 专用 API 镜像必须复用受控产物并禁用 RustDesk 子进程。
check_api_dockerfile() {
    file="$1"
    require_file "$file"
    [ -f "$file" ] || return
    if contains "$file" '^ARG RUSTDESK_CONTROLLED_IMAGE=' &&
        contains "$file" '^FROM \$\{RUSTDESK_CONTROLLED_IMAGE\}' &&
        contains "$file" '^ENV CONTROLLED_API_ONLY=1' &&
        contains "$file" 'rm -f /usr/local/bin/hbbs /usr/local/bin/hbbr' &&
        contains "$file" '^HEALTHCHECK '; then
        pass "专用 API 镜像复用受控产物并移除 hbbs/hbbr 入口"
    else
        fail "专用 API 镜像缺少受控来源、独立运行或健康检查"
    fi
}

check_server_dockerfile() {
    file="$1"
    require_file "$file"
    [ -f "$file" ] || return

    if contains "$file" 'a7736be5e40f85bfc141120dce587e836e5d4b80' &&
        contains "$file" 'controlled-fork-apply.sh'; then
        pass "server 镜像使用固定基线和受控补丁"
    else
        fail "server 镜像缺少固定基线或补丁应用"
    fi

    if contains "$file" 'cargo build --jobs.*--locked --release --bin hbbs --bin hbbr' &&
        contains "$file" '^FROM debian:bookworm-slim'; then
        pass "server 镜像构建双二进制并使用 Debian 运行基底"
    else
        fail "server 镜像缺少双二进制构建或 Debian 运行基底"
    fi
}

check_release_workflow() {
    file="$1"
    require_file "$file"
    [ -f "$file" ] || return

    if contains "$file" '^[[:space:]]+workflow_dispatch:$' &&
        ! contains "$file" '^[[:space:]]+(push|pull_request|schedule):$'; then
        pass "受控镜像构建验收仅允许手工触发"
    else
        fail "受控镜像构建验收包含非手工触发入口"
    fi

    if contains "$file" 'controlled-three-compose-smoke\.sh' &&
        contains "$file" 'rustdesk-controlled-server:check' &&
        contains "$file" 'rustdesk-controlled-api:check'; then
        pass "受控 server/API 镜像构建后执行三容器验收"
    else
        fail "受控镜像构建验收缺少双镜像或三容器验收"
    fi

    if ! contains "$file" 'ghcr\.io|docker/login-action|packages:[[:space:]]*write|push-to-registry:[[:space:]]*true|docker push|actions/attest'; then
        pass "受控镜像仅在运行器本地构建，不登录或写入镜像仓库"
    else
        fail "受控镜像构建流程仍包含外部镜像发布能力"
    fi
}

check_compose() {
    file="$1"
    label="$2"
    require_file "$file"
    [ -f "$file" ] || return

    if contains "$file" '\$\{RUSTDESK_API_INTERNAL_SECRET:\?'; then
        pass "$label 强制要求 RUSTDESK_API_INTERNAL_SECRET"
    else
        fail "$label 未强制要求 RUSTDESK_API_INTERNAL_SECRET"
    fi

    if contains "$file" '\$\{ADMIN_USER:\?' && contains "$file" '\$\{ADMIN_PASS:\?'; then
        pass "$label 强制要求初始管理员凭据"
    else
        fail "$label 未强制要求初始管理员凭据"
    fi

    if [ "$label" = "三容器 Compose" ]; then
        if contains "$file" '\$\{RUSTDESK_API_IMAGE:\?'; then
            pass "$label 强制要求兼容的 API 镜像"
        else
            fail "$label 未强制要求兼容的 API 镜像"
        fi
    else
        if ! contains "$file" '\./server\.yaml:/app/server\.yaml' &&
            contains "$file" 'GO_MODULE_PROXY:'; then
            pass "$label 使用镜像配置模板并支持 Go 模块源参数"
        else
            fail "$label 不应强制挂载仓库配置，且需支持 Go 模块源参数"
        fi
    fi

    if contains "$file" '\$\{RUSTDESK_CONTROLLED_SERVER_IMAGE:\?'; then
        pass "$label 强制要求 RUSTDESK_CONTROLLED_SERVER_IMAGE"
    else
        fail "$label 未强制要求 RUSTDESK_CONTROLLED_SERVER_IMAGE"
    fi

    if contains "$file" 'MUST_LOGIN=1'; then
        pass "$label 已启用 MUST_LOGIN"
    else
        fail "$label 未启用 MUST_LOGIN"
    fi

    if contains "$file" '127\.0\.0\.1.*12346'; then
        pass "$label 管理后台默认绑定本机"
    else
        fail "$label 管理后台默认绑定范围不安全"
    fi

    if contains "$file" '127\.0\.0\.1:21118' && contains "$file" '127\.0\.0\.1:21119'; then
        pass "$label Web 端口默认绑定本机"
    else
        fail "$label Web 端口默认绑定范围不安全"
    fi

    if contains "$file" 'rustdesk-server-key'; then
        pass "$label 持久化 RustDesk server key"
    else
        fail "$label 未持久化 RustDesk server key"
    fi
}

check_entrypoint() {
    file="$1"
    require_file "$file"
    [ -f "$file" ] || return

    if contains "$file" 'require_secret "RUSTDESK_API_INTERNAL_SECRET"'; then
        pass "entrypoint 校验内部 API 密钥"
    else
        fail "entrypoint 未校验内部 API 密钥"
    fi

    if contains "$file" 'ADMIN_PASS 未设置或仍为示例值' && contains "$file" 'ADMIN_PASS 长度不足'; then
        pass "entrypoint 拒绝示例管理员密码"
    else
        fail "entrypoint 未拒绝示例管理员密码"
    fi

    if contains "$file" 'MUST_LOGIN.*必须启用'; then
        pass "entrypoint 强制 MUST_LOGIN"
    else
        fail "entrypoint 未强制 MUST_LOGIN"
    fi

    if contains "$file" 'wait_api_health'; then
        pass "entrypoint 等待 API 健康检查"
    else
        fail "entrypoint 未等待 API 健康检查"
    fi

    if contains "$file" 'rustdesk-controlled-api.pid' &&
        contains "$file" 'rustdesk-controlled-hbbs.pid' &&
        contains "$file" 'rustdesk-controlled-hbbr.pid'; then
        pass "entrypoint 写入 API/hbbs/hbbr PID"
    else
        fail "entrypoint 未写入完整 PID 文件"
    fi

    if contains "$file" 'hbbs 进程已退出' && contains "$file" 'hbbr 进程已退出'; then
        pass "entrypoint 监控 hbbs/hbbr 退出"
    else
        fail "entrypoint 未监控 hbbs/hbbr 退出"
    fi

    if [ "$(grep -Ec '^[[:space:]]*unset PORT$' "$file")" -eq 2 ]; then
        pass "entrypoint 不向 hbbs/hbbr 传递 API 端口"
    else
        fail "entrypoint 必须在 hbbs/hbbr 子进程中分别移除 API 的 PORT"
    fi
    if contains "$file" 'CONTROLLED_API_ONLY.*必须为 0 或 1' &&
        contains "$file" 'if \[ "\$CONTROLLED_API_ONLY" = "1" \]'; then
        pass "entrypoint 校验并支持 API 专用模式"
    else
        fail "entrypoint 缺少 API 专用模式或模式校验"
    fi
}

check_healthcheck() {
    file="$1"
    require_file "$file"
    [ -f "$file" ] || return

    if contains "$file" '/api/health'; then
        pass "healthcheck 检查 API 健康接口"
    else
        fail "healthcheck 未检查 API 健康接口"
    fi

    if contains "$file" 'rustdesk-controlled-api.pid' &&
        contains "$file" 'rustdesk-controlled-hbbs.pid' &&
        contains "$file" 'rustdesk-controlled-hbbr.pid'; then
        pass "healthcheck 检查 PID 文件"
    else
        fail "healthcheck 未检查完整 PID 文件"
    fi
}

ROOT_DIR="${1:-$(pwd)}"

check_dockerfile "$ROOT_DIR/Dockerfile.controlled"
check_api_dockerfile "$ROOT_DIR/Dockerfile.controlled-api"
check_build_context "$ROOT_DIR/.dockerignore"
check_server_dockerfile "$ROOT_DIR/Dockerfile.controlled-server"
check_release_workflow "$ROOT_DIR/.github/workflows/controlled-release.yml"
check_compose "$ROOT_DIR/docker-compose.controlled.yaml" "三容器 Compose"
check_compose "$ROOT_DIR/docker-compose.controlled-one.yaml" "一体化 Compose"
check_entrypoint "$ROOT_DIR/docker/controlled-entrypoint.sh"
check_healthcheck "$ROOT_DIR/docker/controlled-healthcheck.sh"

if [ "$failures" -gt 0 ]; then
    printf '\n受控部署静态检查未通过：%s 项失败，%s 项警告。\n' "$failures" "$warnings" >&2
    exit 1
fi

printf '\n受控部署静态检查通过：%s 项警告。\n' "$warnings"
