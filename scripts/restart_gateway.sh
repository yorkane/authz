#!/usr/bin/env bash
# Recreate the local Authz Gateway container with the current .env.
#
# Default behavior is intentionally --no-build: .env and conf template changes
# require a new container, not a new image. Use --build only when Dockerfile or
# other image sources changed and a local platform image should be rebuilt.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
SERVICE_NAME="gateway"
CONTAINER_NAME="openresty-gateway"
IMAGE_NAME="ghcr.io/yorkane/authz:latest"
BUILD_IMAGE=0

if [[ "${1:-}" == "--build" ]]; then
    BUILD_IMAGE=1
elif [[ $# -gt 0 ]]; then
    printf '用法: %s [--build]\n' "$0" >&2
    exit 2
fi

cd "$PROJECT_DIR"

if [[ ! -f "$PROJECT_DIR/.env" ]]; then
    printf '错误: 缺少 %s/.env，请先配置运行环境。\n' "$PROJECT_DIR" >&2
    exit 1
fi

for command in docker jq curl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf '错误: 未找到命令 %s。\n' "$command" >&2
        exit 1
    fi
done

wait_for_docker() {
    local attempt
    if docker info >/dev/null 2>&1; then return 0; fi

    if [[ "$(uname -s)" == "Darwin" ]] && command -v open >/dev/null 2>&1; then
        printf 'Docker daemon 未运行，正在启动 Docker Desktop...\n'
        open -a Docker >/dev/null 2>&1 || true
    fi

    for attempt in $(seq 1 12); do
        if docker info >/dev/null 2>&1; then return 0; fi
        sleep 5
    done

    printf '错误: Docker daemon 在 60 秒内未就绪。\n' >&2
    exit 1
}

wait_for_docker

printf '校验 Compose 配置...\n'
docker compose config --quiet

HTTP_PORT="$(docker compose config --format json | jq -r '.services.gateway.environment.AUTHZ_HTTP_PORT // "6080"')"
HTTPS_PORT="$(docker compose config --format json | jq -r '.services.gateway.environment.AUTHZ_HTTPS_PORT // "6443"')"
NETWORK_MODE="$(docker compose config --format json | jq -r '.services.gateway.network_mode // ""')"
if [[ "$NETWORK_MODE" != "host" ]]; then
    printf '错误: gateway 必须使用 host 网络，当前为 %s。\n' "${NETWORK_MODE:-未配置}" >&2
    exit 1
fi

if [[ "$BUILD_IMAGE" == 1 ]]; then
    DOCKER_ARCH="$(docker info --format '{{.Architecture}}')"
    case "$DOCKER_ARCH" in
        aarch64|arm64) PLATFORM="linux/arm64" ;;
        x86_64|amd64) PLATFORM="linux/amd64" ;;
        *)
            printf '错误: 不支持的 Docker 架构: %s\n' "$DOCKER_ARCH" >&2
            exit 1
            ;;
    esac

    RESTY_J="$(docker compose config --format json | jq -r '.services.gateway.build.args.RESTY_J // "8"')"
    printf '构建本地镜像 %s (%s)...\n' "$IMAGE_NAME" "$PLATFORM"
    if docker buildx version >/dev/null 2>&1; then
        docker buildx build \
            --platform "$PLATFORM" \
            --load \
            --build-arg "RESTY_J=$RESTY_J" \
            --tag "$IMAGE_NAME" \
            .
    else
        printf '未找到 docker buildx，回退到 docker build。\n'
        docker build \
            --platform "$PLATFORM" \
            --build-arg "RESTY_J=$RESTY_J" \
            --tag "$IMAGE_NAME" \
            .
    fi
fi

printf '按当前 .env 重建服务...\n'
docker compose up -d --force-recreate --no-build "$SERVICE_NAME"

for attempt in $(seq 1 20); do
    status="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    if [[ "$status" == "running" ]]; then break; fi
    if [[ "$attempt" == 20 ]]; then
        printf '错误: 容器未进入 running 状态。\n' >&2
        docker compose ps >&2 || true
        docker compose logs --tail=40 "$SERVICE_NAME" >&2 || true
        exit 1
    fi
    sleep 1
done

printf '检查 OpenResty 配置...\n'
docker exec "$CONTAINER_NAME" openresty -t

ACTUAL_NETWORK_MODE="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CONTAINER_NAME")"
if [[ "$ACTUAL_NETWORK_MODE" != "host" ]]; then
    printf '错误: 容器实际网络模式不是 host，而是 %s。\n' "$ACTUAL_NETWORK_MODE" >&2
    exit 1
fi
printf '容器网络: host\n'

ACTUAL_TEMPLATE_SOURCE="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/openresty/templates"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME")"
if [[ -z "$ACTUAL_TEMPLATE_SOURCE" ]]; then
    printf '错误: 未挂载运行时 Nginx 模板目录 /etc/openresty/templates。\n' >&2
    exit 1
fi
printf '运行时 Nginx 模板: %s\n' "$ACTUAL_TEMPLATE_SOURCE"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openresty-gateway-restart.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

check_status() {
    local label="$1"
    local expected="$2"
    local url="$3"
    local actual

    # 容器刚启动时端口绑定可能略晚于 docker up 返回, 重试最多 15 秒。
    for _ in $(seq 1 15); do
        if [[ "$#" -gt 3 ]]; then
            actual="$(curl -sS --connect-timeout 3 --max-time 10 "${@:4}" -o /dev/null -w '%{http_code}' "$url" || true)"
        else
            actual="$(curl -sS --connect-timeout 3 --max-time 10 -o /dev/null -w '%{http_code}' "$url" || true)"
        fi
        [[ "$actual" == "$expected" ]] && break
        sleep 1
    done
    if [[ "$actual" != "$expected" ]]; then
        printf '错误: %s 返回 %s，期望 %s。\n' "$label" "$actual" "$expected" >&2
        exit 1
    fi
    printf '%s: %s\n' "$label" "$actual"
}

check_status "HTTP 登录页" "200" "http://127.0.0.1:${HTTP_PORT}/_authz/login"
check_status "HTTP 未认证 session API" "401" "http://127.0.0.1:${HTTP_PORT}/_authz/api/session"
check_status "HTTP Admin 入口" "302" "http://127.0.0.1:${HTTP_PORT}/_authz/apps/"
check_status "HTTPS 登录页" "200" "https://127.0.0.1:${HTTPS_PORT}/_authz/login" "-k"

printf '\n服务状态:\n'
docker compose ps
printf '\nAuthz Gateway 重启完成。\n'
