#!/usr/bin/env bash
# test_discovery_timing.sh — 本机服务发现「请求路径去阻塞化」的计时回归。
#
# 钉死的病状（旧实现实测）：per-worker 缓存过期那一次请求在**请求路径里串行**探测全部
# 候选端口（connect 100ms / read 200ms 超时），/_authz/api/menu-tree 单次 9 秒级。
# 新实现：共享字典 + stale-while-revalidate + 分波并发探测 —— 过期请求必须先吃旧值秒回，
# 重扫挪进 ngx.timer 后台。
#
# 夹具
#   - fixture 容器：单 worker、AUTHZ_DISCOVERY_TTL=5、x-api-key 控制面（不依赖本地登录）；
#   - test/mock_silent_listen.py 绑 24 个只 LISTEN、永不 accept 的端口：合法候选、永不回
#     HTTP、也没有连接痕迹（不被免测直通），给「过期即串扫」的旧口径制造每端口一次
#     read 超时的确定性成本；
#   - test/mock_http.py 起一个新的真实 HTTP 服务，用来证明后台重扫真的发生；
#   - test/fixtures/discovery_legacy.lua 钉住 HEAD 的旧实现，供反向对照。
#
# 断言
#   1) 冷启动首请求 200 且形状不变（[{port,source,note,enabled}] 口径未动）；
#   2) 抓到一次过期路径上的 menu-tree 请求：time_total < 1s，且同一次请求确实触发
#      了后台重扫（扫描轮数在它之后增加）—— 两条同时成立才算数，避免新鲜窗口里
#      那次「其实还没过期」的假通过；
#   3) 随后 ≤8s 轮询内，新起的真实 HTTP 服务出现在列表里（后台刷新真的执行）；
#   4) 静默 LISTEN 端口不出现在列表（免测直通只放行、不排除；探测判假有效）；
#   5) 容器日志无 lua entry thread aborted，且扫描统计行至少出现一次；
#   6) 反向对照：旧的 discovery.lua 在同一段断言上必须慢（>=1s），证明夹具有鉴别力
#      而不是永远通过。
#

# 用法：OPENRESTY_TEST_IMAGE=authz:latest bash test/test_discovery_timing.sh
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$REPO_DIR/test/support_lualib.sh"
IMAGE=${OPENRESTY_TEST_IMAGE:-ghcr.io/yorkane/authz:latest}
CONTAINER_NAME="authz-discovery-test-$$"
TMP_DIR=$(mktemp -d)
SILENT_PID=""
MOCK_PID=""
PASS=0
FAILS=0

free_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

HTTP_PORT=$(free_port)
HTTPS_PORT=$(free_port)
NEW_PORT=$(free_port)
SILENT_N=${DISCOVERY_TIMING_SILENT_PORTS:-24}
TEST_KEY="discovery-timing-agent-key-0123456789abcdef0123"

cleanup() {
    # /data 里的证书/库由容器内 root 写，宿主机侧 rm 前先放开权限（与 gateway 套件同法）。
    docker exec "$CONTAINER_NAME" chmod -R a+rwx /data >/dev/null 2>&1 || true
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if [[ -n "$SILENT_PID" ]]; then kill "$SILENT_PID" >/dev/null 2>&1 || true; fi
    if [[ -n "$MOCK_PID" ]]; then kill "$MOCK_PID" >/dev/null 2>&1 || true; fi
    rm -rf "$TMP_DIR" || true
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL: %s\n' "$1"; }
assert_eq() {
    local name=$1 actual=$2 expected=$3
    if [[ "$actual" == "$expected" ]]; then pass "$name"; else fail "$name (expected '$expected', got '$actual')"; fi
}

# 计时取 menu-tree：输出 time_total（秒，小数）。curl 失败（超时等）记为 999，
# 让"慢"本身成为可断言的数值而不是让脚本被 set -e 杀掉。
timed_menu_tree() {
    local value
    value=$(curl -sS --max-time 30 -H "x-api-key: $TEST_KEY" \
        -o "$TMP_DIR/body" -w '%{time_total}' \
        "http://127.0.0.1:$HTTP_PORT/_authz/api/menu-tree" 2>/dev/null) || value=999
    printf '%s\n' "${value:-999}"
}

applications_body() { # 拉一次 /_authz/api/applications 到 $TMP_DIR/body
    curl -sS --max-time 15 -H "x-api-key: $TEST_KEY" -o "$TMP_DIR/body" \
        -w '%{http_code}' "http://127.0.0.1:$HTTP_PORT/_authz/api/applications" 2>/dev/null || true
}

body_has_unbound_port() { # body_has_unbound_port <port>
    jq -e --argjson port "$1" \
        '.data[] | select(.port == $port and .binding == false)' \
        "$TMP_DIR/body" >/dev/null 2>&1
}

scan_rounds() { # 已完成的扫描轮数（init_worker 预热 + 冷扫 + 每次后台重扫各一行 INFO）
    docker logs "$CONTAINER_NAME" 2>&1 | grep -c 'authz: discovery scan done' || true
}

start_container() { # start_container <lualib 挂载目录>
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d \
        --name "$CONTAINER_NAME" \
        --network host \
        -e NGINX_WORKER_PROCESSES=1 \
        -e AUTHZ_HTTP_PORT="$HTTP_PORT" \
        -e AUTHZ_HTTPS_PORT="$HTTPS_PORT" \
        -e AUTHZ_HTTP_MODE=serve \
        -e AUTHZ_ADMIN_PASSWORD=admin123 \
        -e "AUTHZ_API_KEY=$TEST_KEY" \
        -e AUTHZ_PORT_MIN=1000 \
        -e AUTHZ_PORT_MAX=65535 \
        -e AUTHZ_DISCOVERY_TTL=5 \
        -e OPENRESTY_TEMPLATE_DIR=/etc/openresty/templates \
        -v "$TMP_DIR/data:/data" \
        -v "$TMP_DIR/templates:/etc/openresty/templates:ro" \
        -v "$REPO_DIR/docker-entrypoint.sh:/docker-entrypoint.sh:ro" \
        -v "$1:/usr/local/openresty/site/lualib:ro" \
        "$IMAGE" /usr/local/openresty/bin/openresty \
        -g "daemon off; error_log /dev/stderr info;" >/dev/null
    for _ in $(seq 1 120); do
        local status
        status=$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' \
            "http://127.0.0.1:$HTTP_PORT/_authz/api/session" 2>/dev/null || true)
        [[ "$status" == "401" ]] && return 0
        sleep 0.25
    done
    return 1
}

# ── 夹具：静默 LISTEN 端口（合法候选、永不回 HTTP、无连接痕迹）───────────────
SILENT_LOG="$TMP_DIR/silent-listen.log"
python3 "$REPO_DIR/test/mock_silent_listen.py" "$SILENT_N" >"$SILENT_LOG" 2>&1 &
SILENT_PID=$!
for _ in $(seq 1 60); do
    [[ "$(grep -c '^BOUND ' "$SILENT_LOG" || true)" == "$SILENT_N" ]] && break
    sleep 0.1
done
if [[ "$(grep -c '^BOUND ' "$SILENT_LOG" || true)" == "$SILENT_N" ]]; then
    pass "silent listen fixture bound $SILENT_N ports"
else
    fail "silent listen fixture bound only $(grep -c '^BOUND ' "$SILENT_LOG" || echo 0)/$SILENT_N ports"
fi

LUALIB_NEW=$(prepare_lualib_mount "$IMAGE" "$TMP_DIR/new")
mkdir -p "$TMP_DIR/templates"
cp "$REPO_DIR/conf/nginx.conf.template" "$TMP_DIR/templates/nginx.conf.template"
cp "$REPO_DIR/conf/server.conf.template" "$TMP_DIR/templates/server.conf.template"

if ! start_container "$LUALIB_NEW"; then
    fail "discovery fixture container did not become ready"
    printf '\n%s failed check(s)\n' "$FAILS"
    docker logs "$CONTAINER_NAME" 2>&1 | tail -n 40 || true
    exit 1
fi

STATUS=$(curl -sS --max-time 30 -H "x-api-key: $TEST_KEY" -o "$TMP_DIR/body" \
    -w '%{http_code}' "http://127.0.0.1:$HTTP_PORT/_authz/api/menu-tree" 2>/dev/null || true)
assert_eq "cold-start menu-tree responds" "$STATUS" "200"
if jq -e '.data.groups | type == "array"' "$TMP_DIR/body" >/dev/null 2>&1; then
    pass "menu-tree shape unchanged with the shared-dict cache"
else
    fail "menu-tree shape changed: $(head -c 200 "$TMP_DIR/body")"
fi

# 本修复的钉死点：过期路径上的请求必须秒回。过期窗口取决于预热定时器与上一轮扫描
# 落地的时刻（TTL=5、预热延时 5s），单发一次请求可能正好落在新鲜窗口里 —— 那种
# 「通过」是假的。因此反复采样，直到抓到一次同时满足两条的请求：
#   a) time_total < 1s；b) 它确实触发了后台重扫（扫描轮数在它之后增加）。
STALE_VERDICT=""
STALE_SAMPLES=""
for _ in $(seq 1 8); do
    BASE=$(scan_rounds)
    ELAPSED=$(timed_menu_tree)
    sleep 2
    AFTER=$(scan_rounds)
    if [[ "$AFTER" != "$BASE" ]]; then TRIGGERED=yes; else TRIGGERED=no; fi
    STALE_SAMPLES="$STALE_SAMPLES ${ELAPSED}s/refresh=$TRIGGERED"
    if [[ "$TRIGGERED" == "yes" ]] && awk -v e="$ELAPSED" 'BEGIN { exit !(e + 0 < 1.0) }'; then
        STALE_VERDICT="pass"
        break
    fi
    sleep 3
done
if [[ "$STALE_VERDICT" == "pass" ]]; then
    pass "expired menu-tree served stale in ${ELAPSED}s and triggered a background rescan"
else
    fail "never saw a stale-serving request;$STALE_SAMPLES"
fi

# 后台刷新真的发生：容器起来之后再开一个真实 HTTP 服务，≤8s 轮询内必须出现在列表。
python3 "$REPO_DIR/test/mock_http.py" "$NEW_PORT" >"$TMP_DIR/new-mock.log" 2>&1 &
MOCK_PID=$!
for _ in $(seq 1 30); do
    curl -fsS --max-time 1 "http://127.0.0.1:$NEW_PORT/" >/dev/null 2>&1 && break
    sleep 0.1
done
Seen=""
for _ in $(seq 1 16); do
    sleep 0.5
    applications_body >/dev/null
    if body_has_unbound_port "$NEW_PORT"; then Seen=1; break; fi
done
if [[ -n "$Seen" ]]; then
    pass "background refresh picked up the newly started service"
else
    fail "background refresh never picked up port $NEW_PORT within 8s"
fi

# 免测直通的方向性：静默 LISTEN 端口没有痕迹 → 仍进探测队列并被判为「非 HTTP」。
applications_body >/dev/null
LEAKED=""
for port in $(awk '/^BOUND /{print $2}' "$SILENT_LOG"); do
    if body_has_unbound_port "$port"; then LEAKED="$LEAKED $port"; fi
done
if [[ -z "$LEAKED" ]]; then
    pass "silent listen ports stay out of the list (no false passthrough)"
else
    fail "silent listen ports leaked into the local service list:$LEAKED"
fi

ABORTS=$(docker logs "$CONTAINER_NAME" 2>&1 | grep -c 'lua entry thread aborted' || true)
assert_eq "no aborted lua entry thread" "$ABORTS" "0"
SCANS=$(scan_rounds)
if [[ "$SCANS" != "0" ]]; then
    pass "discovery scan stats logged ($SCANS round(s))"
    docker logs "$CONTAINER_NAME" 2>&1 | grep 'authz: discovery scan done' | tail -n 2 || true
else
    fail "no discovery scan was logged (warm_start / timer not running?)"
fi

docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# ── 反向对照：旧实现必须在同一段断言上慢下来（证明上面的计时断言有鉴别力）────
OLD_LUALIB=$(prepare_lualib_mount "$IMAGE" "$TMP_DIR/old")
# 旧实现用钉在 test/fixtures 里的 HEAD 副本：241.t 部署目录不是 git 仓库，不能现场
# git show。本机（有 git）额外核对副本与 HEAD 一致，防止夹具悄悄漂移。
cp "$REPO_DIR/test/fixtures/discovery_legacy.lua" "$OLD_LUALIB/resty/authz/discovery.lua"
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    HEAD_MD5=$(git -C "$REPO_DIR" show HEAD:lualib/resty/authz/discovery.lua | md5sum | awk '{print $1}')
    FIX_MD5=$(md5sum "$OLD_LUALIB/resty/authz/discovery.lua" | awk '{print $1}')
    assert_eq "legacy fixture matches HEAD discovery.lua" "$FIX_MD5" "$HEAD_MD5"
else
    pass "legacy fixture installed (no git available to cross-check)"
fi
if ! start_container "$OLD_LUALIB"; then
    fail "legacy discovery fixture container did not become ready"
else
    # 旧实现没有共享字典：第一次请求冷扫（允许慢，只为填充内部缓存），
    # sleep 越过 TTL=5 后第二次请求必然在请求路径里逐端口串行重扫。
    timed_menu_tree >/dev/null
    sleep 6
    OLD_ELAPSED=$(timed_menu_tree)
    if awk -v e="$OLD_ELAPSED" 'BEGIN { exit !(e + 0 >= 1.0) }'; then
        pass "legacy implementation blocks the expired request (${OLD_ELAPSED}s >= 1s)"
    else
        fail "legacy implementation did not reproduce the blocking (${OLD_ELAPSED}s)"
    fi
    # 容器内 root 写的 /data（证书/库）宿主机删不掉：先放开权限再收（gateway 套件同法）。
    docker exec "$CONTAINER_NAME" chmod -R a+rwx /data >/dev/null 2>&1 || true
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# 收尾核对：被测挂载目录里仍是修复版（反向对照只动 old 副本，不污染新实现）
WORK_MD5=$(md5sum "$REPO_DIR/lualib/resty/authz/discovery.lua" | awk '{print $1}')
MOUNT_MD5=$(md5sum "$LUALIB_NEW/resty/authz/discovery.lua" | awk '{print $1}')
assert_eq "mounted lualib still carries the fixed discovery.lua" "$MOUNT_MD5" "$WORK_MD5"

printf '\n%s discovery timing checks passed, %s failed\n' "$PASS" "$FAILS"
[[ "$FAILS" == "0" ]]
