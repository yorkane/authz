#!/usr/bin/env bash
# test/run_tests.sh — openresty-base 功能验证脚本
# 用法：bash test/run_tests.sh [image]
# 默认镜像：ghcr.io/yorkane/authz:latest

set -euo pipefail

IMAGE="${1:-ghcr.io/yorkane/authz:latest}"
CONTAINER="or-test-$$"
CONTAINER_PORT=8080
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

DOCKER_ARCH="$(docker info --format '{{.Architecture}}')"
case "$DOCKER_ARCH" in
    aarch64|arm64)
        PLATFORM="linux/arm64"
        EXPECTED_FFI_ARCH="arm64"
        ;;
    x86_64|amd64)
        PLATFORM="linux/amd64"
        EXPECTED_FFI_ARCH="x64"
        ;;
    *)
        echo "Unsupported Docker architecture: $DOCKER_ARCH" >&2
        exit 1
        ;;
esac

# ── 颜色 ──────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓ PASS${NC}  $1"; PASS=$((PASS+1)); }
fail() { echo -e "${RED}  ✗ FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
info() { echo -e "${CYAN}▶ $1${NC}"; }

# ── 启动容器 ──────────────────────────────────────────────────────────
cleanup() {
    docker rm -f "$CONTAINER" &>/dev/null || true
}
trap cleanup EXIT

if docker image inspect "$IMAGE" >/dev/null 2>&1 && \
        [[ "$(docker image inspect "$IMAGE" --format '{{.Architecture}}')" == "${PLATFORM#linux/}" ]]; then
    info "Using local image: $IMAGE ($PLATFORM)"
else
    info "Pulling image: $IMAGE ($PLATFORM)"
    docker pull --platform "$PLATFORM" "$IMAGE" --quiet
fi

info "Starting container $CONTAINER on a random local port ..."
docker run -d --name "$CONTAINER" \
    --platform "$PLATFORM" \
    -p "127.0.0.1::${CONTAINER_PORT}" \
    -v "${REPO_DIR}:/repo" \
    "$IMAGE" \
    openresty -g "daemon off;" -c /repo/test/conf/nginx.conf

# 等 nginx 就绪
sleep 2

PORT=$(docker port "$CONTAINER" "${CONTAINER_PORT}/tcp" | awk -F: 'NR == 1 { print $NF }')
BASE="http://localhost:${PORT}"

# ── 辅助函数 ──────────────────────────────────────────────────────────
assert_contains() {
    local desc="$1" url="$2" expect="$3"
    local body
    body=$(curl -sf "$url" 2>&1) || { fail "$desc (curl error)"; return; }
    if echo "$body" | grep -q "$expect"; then
        ok "$desc"
    else
        fail "$desc (expected '$expect', got: ${body:0:120})"
    fi
}

assert_http_status() {
    local desc="$1" method="$2" url="$3" expect_code="$4"
    shift 4
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$@" "$url")
    if [[ "$code" == "$expect_code" ]]; then
        ok "$desc (HTTP $code)"
    else
        fail "$desc (expected HTTP $expect_code, got $code)"
    fi
}

# ── 测试用例 ──────────────────────────────────────────────────────────
echo ""
info "=== 1. Lua 基础 ==="
assert_contains "lua content_by_lua_block"  "$BASE/hello" "hello from lua"
assert_contains "ngx_lua_version exposed"   "$BASE/hello" "ngx_lua_version="

echo ""
info "=== 2. cjson 内置库 ==="
assert_contains "cjson encode"              "$BASE/json"  '"status":"ok"'

echo ""
info "=== 3. resty.core 及常用 resty 库 ==="
assert_contains "resty.core"                "$BASE/core"  "resty.core: OK"
assert_contains "ngx.re"                    "$BASE/core"  "ngx.re: OK"
assert_contains "resty.lrucache"            "$BASE/core"  "resty.lrucache: OK"

echo ""
info "=== 4. LuaJIT FFI ==="
assert_contains "ffi load"                  "$BASE/ffi"   "ffi: OK"
assert_contains "ffi.arch $EXPECTED_FFI_ARCH" "$BASE/ffi" "arch: $EXPECTED_FFI_ARCH"

echo ""
info "=== 5. FancyIndex 目录浏览 ==="
assert_contains "fancyindex HTML response"  "$BASE/files/"  "a.txt"
assert_contains "fancyindex table tag"      "$BASE/files/"  "<table"

echo ""
info "=== 6. WebDAV — OPTIONS ==="
assert_http_status "WebDAV OPTIONS 200"     OPTIONS "$BASE/dav/" 200

echo ""
info "=== 6. WebDAV — PUT 上传文件 ==="
code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
    -H "Content-Type: text/plain" --data "hello webdav" \
    "$BASE/dav/hello.txt")
if [[ "$code" == "201" || "$code" == "204" ]]; then
    ok "WebDAV PUT (HTTP $code)"
else
    fail "WebDAV PUT expected 201/204, got $code"
fi

echo ""
info "=== 6. WebDAV — PROPFIND ==="
code=$(curl -s -o /dev/null -w "%{http_code}" -X PROPFIND \
    -H "Depth: 1" "$BASE/dav/")
if [[ "$code" == "207" ]]; then
    ok "WebDAV PROPFIND (HTTP 207 Multi-Status)"
else
    fail "WebDAV PROPFIND expected 207, got $code"
fi

echo ""
info "=== 7. nginx error log (should be empty / warn only) ==="
ERR_LOG="${REPO_DIR}/test/logs/error.log"
if [[ -f "$ERR_LOG" ]]; then
    ERRORS=$(grep -Ec "\[(error|crit|alert|emerg)\]" "$ERR_LOG" || true)
    if [[ "$ERRORS" -eq 0 ]]; then
        ok "No error-or-higher lines in error.log"
    else
        fail "Found $ERRORS error-or-higher lines in error.log:"
        grep -E "\[(error|crit|alert|emerg)\]" "$ERR_LOG" | head -5
    fi
else
    ok "error.log not created (no warnings)"
fi

echo ""
info "=== 8. JWT 公共库 ==="
assert_contains "resty.jwt 可用"            "$BASE/jwt"  "resty.jwt: OK"
assert_contains "HS256 签发并验证"          "$BASE/jwt"  "sign/verify: OK"
assert_contains "错误密钥应拒绝"            "$BASE/jwt"  "bad secret: rejected"

# ── 汇总 ──────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────"
TOTAL=$((PASS + FAIL))
echo -e "Results: ${GREEN}${PASS} passed${NC} / ${RED}${FAIL} failed${NC} / ${TOTAL} total"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
