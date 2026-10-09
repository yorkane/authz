#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$REPO_DIR/test/support_lualib.sh"
IMAGE=${OPENRESTY_TEST_IMAGE:-ghcr.io/yorkane/authz:latest}
SHARED_REDIS_CONTAINER=""
SHARED_FIRST_CONTAINER=""
SHARED_SECOND_CONTAINER=""
SHARED_STRICT_CONTAINER=""
TMP_DIR=$(mktemp -d)
PASS=0

free_port() {
    python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}

SHARED_REDIS_PORT=$(free_port)
SHARED_HTTP_PORT=$(free_port)
SHARED_HTTPS_PORT=$(free_port)
SHARED_B_HTTP_PORT=$(free_port)
SHARED_B_HTTPS_PORT=$(free_port)
SHARED_STRICT_HTTP_PORT=$(free_port)
SHARED_STRICT_HTTPS_PORT=$(free_port)
SHARED_WRITER_USER="authz-writer"
SHARED_READER_USER="authz-reader"
SHARED_WRITER_PASS="shared-writer-test-secret"
SHARED_READER_PASS="shared-reader-test-secret"
SHARED_SIGNING_KEY="shared-session-signing-key-for-tests-0123456789abcdef"
SHARED_REDIS_ADMIN_USER="authz-admin"
SHARED_REDIS_ADMIN_PASS="shared-admin-test-secret"
# 实例级 admin API Key：共享会话健康段只对 admin 输出，而 Redis 配置类故障时
# 任何会话都认证不过去，x-api-key 是唯一还读得到 state="config" 的路。
SHARED_TEST_API_KEY="shared-session-test-api-key-0123456789abcdef"
# iptables 黑洞规则的标记，cleanup 里按它精确删除。
SHARED_IPT_COMMENT="authz-shared-session-test"
SHARED_OUTAGE_BLOCKED=0
# 重放定时器间隔：默认 15s 会把降级回归拖成分钟级，测试统一压到 1s（env 钳位下限）。
SHARED_RETRY_INTERVAL_MS=${SHARED_RETRY_INTERVAL_MS:-1000}

cleanup() {
    if [[ -n "$SHARED_FIRST_CONTAINER" ]]; then
        docker exec "$SHARED_FIRST_CONTAINER" chmod -R a+rwx /data >/dev/null 2>&1 || true
        docker rm -f "$SHARED_FIRST_CONTAINER" >/dev/null 2>&1 || true
    fi
    if [[ -n "$SHARED_SECOND_CONTAINER" ]]; then
        docker exec "$SHARED_SECOND_CONTAINER" chmod -R a+rwx /data >/dev/null 2>&1 || true
        docker rm -f "$SHARED_SECOND_CONTAINER" >/dev/null 2>&1 || true
    fi
    if [[ -n "$SHARED_REDIS_CONTAINER" ]]; then
        # 故障注入用的黑洞规则必须无条件撤掉，否则本机同端口的其它服务会被牵连。
        sudo -n iptables -w -D INPUT -p tcp -s 127.0.0.1 --dport "$SHARED_REDIS_PORT" \
            -m comment --comment "$SHARED_IPT_COMMENT" -j DROP >/dev/null 2>&1 || true
        docker rm -f "$SHARED_REDIS_CONTAINER" >/dev/null 2>&1 || true
    fi
    if [[ -n "$SHARED_STRICT_CONTAINER" ]]; then
        docker exec "$SHARED_STRICT_CONTAINER" chmod -R a+rwx /data >/dev/null 2>&1 || true
        docker rm -f "$SHARED_STRICT_CONTAINER" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR" || true
}
trap cleanup EXIT

# KEEP_GOING=1：分诊模式，失败只记一行并继续，末尾汇总全部 FAIL。
# 与 test_authz_gateway.sh 同一约定；结论只当线索，确认用默认严格模式复跑。
KEEP_GOING=${KEEP_GOING:-0}
FAILS=0
if [[ "$KEEP_GOING" == "1" ]]; then set +eu; fi

fail() {
    if [[ "$KEEP_GOING" == "1" ]]; then
        printf 'FAIL: %s\n' "$1"
        FAILS=$((FAILS + 1))
        return
    fi
    printf 'FAIL: %s\n' "$1" >&2
    [[ -f "$TMP_DIR/body" ]] && cat "$TMP_DIR/body" >&2 || true
    exit 1
}

pass() {
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$1"
}

assert_eq() {
    local name=$1 actual=$2 expected=$3
    [[ "$actual" == "$expected" ]] || { fail "$name (expected '$expected', got '$actual')"; return; }
    pass "$name"
}

assert_contains() {
    local name=$1 actual=$2 expected=$3
    [[ "$actual" == *"$expected"* ]] || { fail "$name (missing '$expected')"; return; }
    pass "$name"
}

assert_not_contains() {
    local name=$1 actual=$2 unexpected=$3
    [[ "$actual" != *"$unexpected"* ]] || fail "$name (unexpected '$unexpected')"
    pass "$name"
}

assert_json() {
    local name=$1 filter=$2 expected=$3 actual
    actual=$(jq -er "$filter" "$TMP_DIR/body") || { fail "$name (invalid JSON or filter)"; return; }
    assert_eq "$name" "$actual" "$expected"
}

cookie_header() {
    awk '
        !/^#/ && NF >= 7 {
            value = $6 "=" $7
            cookies = cookies (cookies == "" ? "" : "; ") value
            next
        }
        !/^#/ && /^[^=[:space:]]+=/ {
            cookies = cookies (cookies == "" ? "" : "; ") $0
        }
        END { print cookies }
    ' "$1"
}

save_session_cookie() {
    local headers=$1 cookie=$2 token
    token=$(awk 'BEGIN { IGNORECASE=1 } /^Set-Cookie:/ { line=$0; sub(/^[^:]+:[[:space:]]*/, "", line); sub(/;.*/, "", line); if (line ~ /^authz_session=/) { sub(/^authz_session=/, "", line); print line; exit } }' "$headers")
    [[ "$token" =~ ^[A-Fa-f0-9]{64}$ ]] || fail "response did not set a valid session cookie"
    printf 'authz_session=%s' "$token" > "$cookie"
}

# 共享网关容器直接挂载仓库内模板
mkdir -p "$TMP_DIR/templates"
LUALIB_MOUNT=$(prepare_lualib_mount "$IMAGE" "$TMP_DIR")
cp "$REPO_DIR/conf/nginx.conf.template" "$TMP_DIR/templates/nginx.conf.template"
cp "$REPO_DIR/conf/server.conf.template" "$TMP_DIR/templates/server.conf.template"

# ── 共享会话 (Redis): 单写多读、ACL 隔离、故障降级 ──────────────
SHARED_REDIS_CONTAINER="authz-shared-redis-test-$$"
SHARED_FIRST_CONTAINER="authz-shared-writer-test-$$"
SHARED_SECOND_CONTAINER="authz-shared-reader-test-$$"
SHARED_A_HOST="shared-writer.test.example"
SHARED_B_HOST="shared-reader.test.example"

docker run -d --name "$SHARED_REDIS_CONTAINER" --network host \
    redis:8-alpine redis-server --port "$SHARED_REDIS_PORT" \
    --user default off \
    --user "$SHARED_WRITER_USER" on ">$SHARED_WRITER_PASS" "~authz-test:*" \
        +get +setex +del +scan +exists +ping \
    --user "$SHARED_READER_USER" on ">$SHARED_READER_PASS" "~authz-test:*" \
        +get +ping \
    --user "$SHARED_REDIS_ADMIN_USER" on ">$SHARED_REDIS_ADMIN_PASS" "~*" \
        +@all >/dev/null

redis_writer() {
    docker exec "$SHARED_REDIS_CONTAINER" redis-cli -p "$SHARED_REDIS_PORT" \
        --user "$SHARED_WRITER_USER" -a "$SHARED_WRITER_PASS" --no-auth-warning "$@"
}

for _ in $(seq 1 30); do
    PONG=$(redis_writer ping 2>/dev/null || true)
    [[ "$PONG" == "PONG" ]] && break
    sleep 0.2
done
[[ "$PONG" == "PONG" ]] || fail "shared redis container did not become ready"
pass "shared redis with separate writer and reader ACL users is ready"

start_shared_gateway() {
    local name=$1 http_port=$2 https_port=$3 mode=$4 redis_user=$5 redis_password=$6
    mkdir -p "$TMP_DIR/$name-data/authz"
    # SHARED_EXTRA_ENVS 由调用方预设（如 AUTHZ_SESSION_SHARED_FALLBACK=false），
    # 消费后立即清空，因此原有调用点行为不变。
    local extra_args=()
    local item
    for item in ${SHARED_EXTRA_ENVS[@]+"${SHARED_EXTRA_ENVS[@]}"}; do
        extra_args+=(-e "$item")
    done
    SHARED_EXTRA_ENVS=()
    docker run -d \
        --name "$name" \
        --network host \
        -e NGINX_WORKER_PROCESSES=1 \
        -e AUTHZ_HTTP_PORT="$http_port" \
        -e AUTHZ_HTTPS_PORT="$https_port" \
        -e AUTHZ_HTTP_MODE=serve \
        -e AUTHZ_ADMIN_PASSWORD=admin123 \
        -e AUTHZ_PORT_MIN=1000 \
        -e AUTHZ_PORT_MAX=65535 \
        -e AUTHZ_SESSION_SHARED=true \
        -e "AUTHZ_SESSION_REDIS_URL=redis://127.0.0.1:$SHARED_REDIS_PORT" \
        -e "AUTHZ_SESSION_REDIS_MODE=$mode" \
        -e "AUTHZ_SESSION_REDIS_USERNAME=$redis_user" \
        -e "AUTHZ_SESSION_REDIS_PASSWORD=$redis_password" \
        -e AUTHZ_SESSION_REDIS_PREFIX=authz-test \
        -e "AUTHZ_SESSION_RETRY_INTERVAL_MS=$SHARED_RETRY_INTERVAL_MS" \
        -e "AUTHZ_API_KEY=$SHARED_TEST_API_KEY" \
        ${extra_args[@]+"${extra_args[@]}"} \
        -e "AUTHZ_SESSION_SIGNING_KEY=$SHARED_SIGNING_KEY" \
        -e OPENRESTY_TEMPLATE_DIR=/etc/openresty/templates \
        -v "$TMP_DIR/$name-data:/data" \
        -v "$REPO_DIR/admin:/usr/local/openresty/nginx/html/admin:ro" \
        -v "$TMP_DIR/templates:/etc/openresty/templates:ro" \
        -v "$REPO_DIR/docker-entrypoint.sh:/docker-entrypoint.sh:ro" \
        -v "$LUALIB_MOUNT:/usr/local/openresty/site/lualib:ro" \
        "$IMAGE" >/dev/null
}

wait_shared_gateway() {
    local host_port="$1" status=""
    for _ in $(seq 1 60); do
        status=$(curl -sS --max-time 2 --resolve "$host_port:127.0.0.1" \
            -o /dev/null -w '%{http_code}' "http://$host_port/_authz/login" 2>/dev/null || true)
        [[ "$status" == "200" ]] && break
        sleep 0.5
    done
    [[ "$status" == "200" ]] || fail "shared gateway on $host_port did not become ready"
}

start_shared_gateway "$SHARED_FIRST_CONTAINER" "$SHARED_HTTP_PORT" "$SHARED_HTTPS_PORT" \
    read-write "$SHARED_WRITER_USER" "$SHARED_WRITER_PASS"
start_shared_gateway "$SHARED_SECOND_CONTAINER" "$SHARED_B_HTTP_PORT" "$SHARED_B_HTTPS_PORT" \
    read-only "$SHARED_READER_USER" "$SHARED_READER_PASS"
wait_shared_gateway "$SHARED_A_HOST:$SHARED_HTTP_PORT"
wait_shared_gateway "$SHARED_B_HOST:$SHARED_B_HTTP_PORT"
pass "shared writer and reader gateways are ready"

shared_login() {
    local host=$1 port=$2 username=$3 password=$4 cookie=$5
    rm -f "$cookie"
    STATUS=$(curl -sS --max-time 5 --resolve "$host:$port:127.0.0.1" \
        -D "$TMP_DIR/shared-login-headers" -o "$TMP_DIR/body" -w '%{http_code}' \
        -X POST "http://$host:$port/_authz/login" \
        --data-urlencode "username=$username" --data-urlencode "password=$password")
    [[ "$STATUS" == "302" ]] || fail "shared login on $host failed (got $STATUS)"
    save_session_cookie "$TMP_DIR/shared-login-headers" "$cookie"
}

shared_session() {
    local host=$1 port=$2 cookie=$3
    curl -sS --max-time 5 --resolve "$host:$port:127.0.0.1" \
        -H "Cookie: $(cookie_header "$cookie")" -D "$TMP_DIR/shared-headers" \
        -o "$TMP_DIR/body" -w '%{http_code}' "http://$host:$port/_authz/api/session"
}

SHARED_ADMIN_COOKIE="$TMP_DIR/shared-admin.cookie"
shared_login "$SHARED_A_HOST" "$SHARED_HTTP_PORT" admin admin123 "$SHARED_ADMIN_COOKIE"
SHARED_ADMIN_TOKEN=$(cookie_header "$SHARED_ADMIN_COOKIE" | sed 's/^authz_session=//')
assert_eq "writer stores the shared session" \
    "$(redis_writer exists "authz-test:session:$SHARED_ADMIN_TOKEN")" "1"

STATUS=$(shared_session "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
assert_eq "writer session is accepted by reader" "$STATUS" "200"
assert_json "reader resolves shared identity from its local user" '.data.identity' "user:local:admin"
SHARED_ADMIN_CSRF=$(jq -er '.data.csrf' "$TMP_DIR/body")

STATUS=$(curl -sS --max-time 5 --resolve "$SHARED_B_HOST:$SHARED_B_HTTP_PORT:127.0.0.1" \
    -o "$TMP_DIR/body" -w '%{http_code}' -X POST \
    "http://$SHARED_B_HOST:$SHARED_B_HTTP_PORT/_authz/login" \
    --data-urlencode 'username=admin' --data-urlencode 'password=admin123')
assert_eq "reader refuses to create a shared login" "$STATUS" "503"
assert_contains "reader login points to authentication writer" "$(cat "$TMP_DIR/body")" "请在认证主实例完成登录"

READER_WRITE=$(docker exec "$SHARED_REDIS_CONTAINER" redis-cli -p "$SHARED_REDIS_PORT" \
    --user "$SHARED_READER_USER" -a "$SHARED_READER_PASS" --no-auth-warning \
    setex authz-test:session:reader-write-probe 60 denied 2>&1 || true)
assert_contains "Redis ACL independently denies reader writes" "$READER_WRITE" "NOPERM"

REDIS_PAYLOAD=$(redis_writer get "authz-test:session:$SHARED_ADMIN_TOKEN")
assert_contains "redis payload carries username" "$REDIS_PAYLOAD" '"username":"admin"'
assert_contains "redis payload carries source" "$REDIS_PAYLOAD" '"source":"local"'
assert_not_contains "redis payload excludes roles" "$REDIS_PAYLOAD" "roles"

# 公共 Redis 无法依赖 ACL 约束写入方：未签名与篡改的记录必须被 reader 拒绝。
printf 'authz_session=%s' "$(printf 'f%.0s' {1..64})" > "$TMP_DIR/forged.cookie"
redis_writer setex "authz-test:session:$(printf 'f%.0s' {1..64})" 120 \
    '{"username":"admin","source":"local","csrf":"forged","expires_at":99999999999}' >/dev/null
STATUS=$(shared_session "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" "$TMP_DIR/forged.cookie")
assert_eq "reader rejects an unsigned forged session" "$STATUS" "401"

# 篡改 writer 真实记录的 username（签名不再覆盖内容）同样必须失效。
FORGED_RAW=$(redis_writer get "authz-test:session:$SHARED_ADMIN_TOKEN")
FORGED_TAMPERED="${FORGED_RAW//\"username\":\"admin\"/\"username\":\"evil\"}"
[[ "$FORGED_TAMPERED" != "$FORGED_RAW" ]] || fail "tampered payload identical to original"
redis_writer setex "authz-test:session:$SHARED_ADMIN_TOKEN" 120 "$FORGED_TAMPERED" >/dev/null
STATUS=$(shared_session "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
assert_eq "reader rejects a tampered session payload" "$STATUS" "401"

redis_writer del "authz-test:session:$SHARED_ADMIN_TOKEN" >/dev/null
STATUS=$(shared_session "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
assert_eq "reader clears a session missing from Redis" "$STATUS" "401"
assert_contains "missing shared session clears browser cookie" "$(cat "$TMP_DIR/shared-headers")" \
    "authz_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
shared_login "$SHARED_A_HOST" "$SHARED_HTTP_PORT" admin admin123 "$SHARED_ADMIN_COOKIE"
STATUS=$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
assert_eq "writer admin session is valid" "$STATUS" "200"
SHARED_ADMIN_CSRF=$(jq -er '.data.csrf' "$TMP_DIR/body")

create_shared_bob() {
    local host=$1 port=$2
    curl -sS --max-time 5 --resolve "$host:$port:127.0.0.1" \
        -H "Cookie: $(cookie_header "$SHARED_ADMIN_COOKIE")" \
        -H "X-CSRF-Token: $SHARED_ADMIN_CSRF" -H 'Content-Type: application/json' \
        -o "$TMP_DIR/body" -w '%{http_code}' \
        -X POST "http://$host:$port/_authz/api/users" \
        -d '{"username":"sharedbob","password":"bob-secret-1","roles":["guest"]}'
}

STATUS=$(create_shared_bob "$SHARED_A_HOST" "$SHARED_HTTP_PORT")
assert_eq "writer has a local identity snapshot for shared user" "$STATUS" "201"
STATUS=$(create_shared_bob "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT")
assert_eq "reader has a local identity snapshot for shared user" "$STATUS" "201"

SHARED_BOB_COOKIE="$TMP_DIR/shared-bob.cookie"
shared_login "$SHARED_A_HOST" "$SHARED_HTTP_PORT" sharedbob bob-secret-1 "$SHARED_BOB_COOKIE"
SHARED_BOB_TOKEN=$(cookie_header "$SHARED_BOB_COOKIE" | sed 's/^authz_session=//')
STATUS=$(shared_session "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" "$SHARED_BOB_COOKIE")
assert_eq "writer-created user session is accepted by reader" "$STATUS" "200"
assert_json "reader derives roles from its own database" '.data.roles | join(",")' "guest"

SHARED_BOB_READER_ID=$(curl -sS --max-time 5 \
    --resolve "$SHARED_B_HOST:$SHARED_B_HTTP_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$SHARED_ADMIN_COOKIE")" \
    "http://$SHARED_B_HOST:$SHARED_B_HTTP_PORT/_authz/api/users" |
    jq -r '.data.users[] | select(.username == "sharedbob") | .id')
STATUS=$(curl -sS --max-time 5 --resolve "$SHARED_B_HOST:$SHARED_B_HTTP_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$SHARED_ADMIN_COOKIE")" \
    -H "X-CSRF-Token: $SHARED_ADMIN_CSRF" -o "$TMP_DIR/body" -w '%{http_code}' \
    -X DELETE "http://$SHARED_B_HOST:$SHARED_B_HTTP_PORT/_authz/api/users/$SHARED_BOB_READER_ID")
assert_eq "reader can remove its local identity snapshot" "$STATUS" "200"
STATUS=$(shared_session "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" "$SHARED_BOB_COOKIE")
assert_eq "missing local identity is denied on reader" "$STATUS" "401"
assert_eq "reader does not delete the global Redis token" \
    "$(redis_writer exists "authz-test:session:$SHARED_BOB_TOKEN")" "1"

STATUS=$(create_shared_bob "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT")
assert_eq "reader local identity can be restored" "$STATUS" "201"
SHARED_BOB_WRITER_ID=$(curl -sS --max-time 5 \
    --resolve "$SHARED_A_HOST:$SHARED_HTTP_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$SHARED_ADMIN_COOKIE")" \
    "http://$SHARED_A_HOST:$SHARED_HTTP_PORT/_authz/api/users" |
    jq -r '.data.users[] | select(.username == "sharedbob") | .id')
STATUS=$(curl -sS --max-time 5 --resolve "$SHARED_A_HOST:$SHARED_HTTP_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$SHARED_ADMIN_COOKIE")" \
    -H "X-CSRF-Token: $SHARED_ADMIN_CSRF" -H 'Content-Type: application/json' \
    -o "$TMP_DIR/body" -w '%{http_code}' \
    -X PUT "http://$SHARED_A_HOST:$SHARED_HTTP_PORT/_authz/api/users/$SHARED_BOB_WRITER_ID/password" \
    -d '{"password":"bob-secret-2"}')
assert_eq "writer resets shared user password" "$STATUS" "200"
assert_eq "writer revokes shared sessions globally" \
    "$(redis_writer exists "authz-test:session:$SHARED_BOB_TOKEN")" "0"
STATUS=$(shared_session "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" "$SHARED_BOB_COOKIE")
assert_eq "writer revocation is enforced by reader" "$STATUS" "401"

shared_login "$SHARED_A_HOST" "$SHARED_HTTP_PORT" admin admin123 "$SHARED_ADMIN_COOKIE"

# ══ Redis 容错降级：熔断 / 本机镜像 / 欠写重放 / 严格模式 / 配置故障 ══════════
# 故障注入 = 先给测试端口挂一条 iptables DROP、再 docker stop redis：
#   * 每次 connect 都真的吃满 connect_timeout(2s)，这正是熔断器要消灭的开销，
#     也让 (c) 的耗时断言有真实对照（否则"请求很快"可能只是假阳性）；
#   * stop 是优雅退出（存 RDB），start 回来数据完好，恢复后可以逐条核对 Redis
#     真实内容；docker stop 单独用会立刻 ECONNREFUSED（毫秒级失败，测不出等待），
#     docker pause 则会让 AUTH 阶段超时、被 classify() 判成 config 类而测不到降级。
# 探测确认 241.t 上 sudo -n iptables 可用；不可用时退回「仅 docker stop」，
# 此时会打印 INFO 提示 (c) 的强度下降（连接被拒仍是 io 类，只是不产生 2s 等待）。
#
# 每次注入后固定 sleep 12 > set_keepalive 的 10s 空闲上限：不复用故障前的旧连接，
# 保证下一次请求真的去新建连接（否则可能拿到已关闭的连接而把故障误判成 config）。
break_shared_redis() {
    SHARED_OUTAGE_BLOCKED=0
    # 先清掉可能因异常退出而残留的旧规则，避免同注释规则叠加后删不干净。
    while sudo -n iptables -w -D INPUT -p tcp -s 127.0.0.1 --dport "$SHARED_REDIS_PORT" \
        -m comment --comment "$SHARED_IPT_COMMENT" -j DROP 2>/dev/null; do :; done
    if sudo -n iptables -w -A INPUT -p tcp -s 127.0.0.1 --dport "$SHARED_REDIS_PORT" \
        -m comment --comment "$SHARED_IPT_COMMENT" -j DROP 2>/dev/null; then
        SHARED_OUTAGE_BLOCKED=1
    fi
    docker stop "$SHARED_REDIS_CONTAINER" >/dev/null
    sleep 12
}

resume_shared_redis() {
    docker start "$SHARED_REDIS_CONTAINER" >/dev/null
    if [[ "$SHARED_OUTAGE_BLOCKED" == "1" ]]; then
        sudo -n iptables -w -D INPUT -p tcp -s 127.0.0.1 --dport "$SHARED_REDIS_PORT" \
            -m comment --comment "$SHARED_IPT_COMMENT" -j DROP 2>/dev/null || true
        SHARED_OUTAGE_BLOCKED=0
    fi
    wait_shared_redis_ready
    sleep 1
}

wait_shared_redis_ready() {
    local pong=""
    for _ in $(seq 1 30); do
        pong=$(redis_writer ping 2>/dev/null || true)
        [[ "$pong" == "PONG" ]] && return 0
        sleep 0.2
    done
    fail "shared redis did not come back"
}

redis_admin() {
    docker exec "$SHARED_REDIS_CONTAINER" redis-cli -p "$SHARED_REDIS_PORT" \
        --user "$SHARED_REDIS_ADMIN_USER" -a "$SHARED_REDIS_ADMIN_PASS" \
        --no-auth-warning "$@"
}

create_shared_person() {
    local host=$1 port=$2 username=$3 password=$4
    curl -sS --max-time 10 --resolve "$host:$port:127.0.0.1" \
        -H "Cookie: $(cookie_header "$SHARED_ADMIN_COOKIE")" \
        -H "X-CSRF-Token: $SHARED_ADMIN_CSRF" -H 'Content-Type: application/json' \
        -o "$TMP_DIR/body" -w '%{http_code}' \
        -X POST "http://$host:$port/_authz/api/users" \
        -d "{\"username\":\"$username\",\"password\":\"$password\",\"roles\":[\"guest\"]}"
}

# 健康快照与欠写计数只对 admin 输出（last_error 是上游 Redis 的原始报错文本）。
# 用 x-api-key 而不是会话 Cookie：机器凭证路径不经过会话存储，Redis 配错、
# 所有会话都认证不过去时，它是唯一还读得到 shared_session 的路。
admin_health() {
    local host=$1 port=$2
    curl -sS --max-time 20 --resolve "$host:$port:127.0.0.1" \
        -H "x-api-key: $SHARED_TEST_API_KEY" -o "$TMP_DIR/body" \
        -w '%{http_code}' "http://$host:$port/_authz/api/session" || printf '000'
}

timed_shared_session() {
    local host=$1 port=$2 cookie=$3 out
    # 单次请求最坏吃满 connect+read 各 2s；curl 自身失败按超时记账
    out=$(curl -sS --max-time 20 --resolve "$host:$port:127.0.0.1" \
        -H "Cookie: $(cookie_header "$cookie")" -D "$TMP_DIR/shared-headers" \
        -o "$TMP_DIR/body" -w '%{http_code} %{time_total}' \
        "http://$host:$port/_authz/api/session" 2>/dev/null) || out="000 99.000"
    printf '%s\n' "$out"
}

assert_above() {
    local name=$1 actual=$2 floor=$3
    awk -v a="$actual" -v b="$floor" 'BEGIN { exit !(a + 0 > b + 0) }' \
        || { fail "$name (got '${actual}s', expected > ${floor}s)"; return; }
    pass "$name (got ${actual}s)"
}

assert_below() {
    local name=$1 actual=$2 limit=$3
    awk -v a="$actual" -v b="$limit" 'BEGIN { exit !(a + 0 < b + 0) }' \
        || { fail "$name (got '${actual}s', expected < ${limit}s)"; return; }
    pass "$name (got ${actual}s)"
}

# 判定"没有把已登录用户踢下线"的可靠依据：/api/session 对有效会话会走 set_cookie
# （重新下发 authz_session=<token>; Domain=<生效域>），而 fail-closed 走 clear_cookie
# （额外下发针对生效域自身的 authz_session=; ... Max-Age=0; Domain=<生效域>）。
# 注意不能只看响应里有没有 "Max-Age=0"：set_cookie 也会顺带清理 host-only 与历史
# 子域的残留 cookie，那条清理行本来就带 Max-Age=0。
SHARED_COOKIE_DOMAIN=$(awk 'BEGIN { IGNORECASE=1 } /^Set-Cookie:/ {
        if ($0 ~ /Domain=/) { sub(/.*Domain=/, ""); sub(/;.*/, ""); sub(/\r.*/, ""); print; exit }
    }' "$TMP_DIR/shared-login-headers")
[[ "$SHARED_COOKIE_DOMAIN" == ".test.example" ]] \
    || fail "unexpected cookie domain '$SHARED_COOKIE_DOMAIN'"
pass "writer issues the shared session cookie for the derived parent domain"
# 上一次 reader 清会话之后重新登录过：cookie 与 CSRF 都要按新的会话响应重新取值。
SHARED_ADMIN_TOKEN=$(cookie_header "$SHARED_ADMIN_COOKIE" | sed 's/^authz_session=//')

# 降级读的前提是本机镜像里有这一行（每次经 Redis 成功读时 upsert + verified_at）。
STATUS=$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
assert_eq "writer confirms the admin session before the outage" "$STATUS" "200"
SHARED_ADMIN_CSRF=$(jq -er '.data.csrf' "$TMP_DIR/body")
STATUS=$(shared_session "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
assert_eq "reader confirms the admin session through redis before the outage" "$STATUS" "200"

# 故障前把 shareddave 的身份快照同时建到两台实例：reader 会用本地 users 校验
# 身份，缺行时的 401 是既有语义，会把"重放没生效"和"本地没这个人"混为一谈。
STATUS=$(create_shared_person "$SHARED_A_HOST" "$SHARED_HTTP_PORT" shareddave dave-secret-1)
assert_eq "writer has the second identity before the outage" "$STATUS" "201"
STATUS=$(create_shared_person "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" shareddave dave-secret-1)
assert_eq "reader has the second identity before the outage" "$STATUS" "201"
STATUS=$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
SHARED_ADMIN_CSRF=$(jq -er '.data.csrf' "$TMP_DIR/body")
assert_eq "writer session stays valid before the outage" "$STATUS" "200"

break_shared_redis
pass "shared redis is unreachable for the gateways"
if [[ "$SHARED_OUTAGE_BLOCKED" == "1" ]]; then
    printf 'INFO: outage injected with iptables DROP + docker stop (each attempt costs the 2s connect timeout)\n'
else
    printf 'INFO: sudo iptables unavailable, outage injected with docker stop only (connection refused)\n'
fi

# 熔断建立前的第一个请求仍然要撞 Redis：它同时证明故障注入确实生效。
if [[ "$SHARED_OUTAGE_BLOCKED" == "1" ]]; then
    WARMUP=$(timed_shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
    assert_eq "the first request after the outage is still served" "${WARMUP% *}" "200"
    assert_above "the first request pays the real Redis connect timeout" "${WARMUP#* }" "1.0"
fi

# (c) 熔断生效：连续 5 次请求的总耗时明显低于「每次都吃 2s connect 超时」。
SLOW=0
SUM=0.0
TIMES=""
for _ in $(seq 1 5); do
    RESP=$(timed_shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
    assert_eq "breaker-window request stays authenticated" "${RESP% *}" "200"
    ELAPSED=${RESP#* }
    TIMES="$TIMES${ELAPSED}s "
    SLOW=$((SLOW + $(awk -v t="$ELAPSED" 'BEGIN { print (t + 0 > 1.5) ? 1 : 0 }')))
    SUM=$(awk -v a="$SUM" -v b="$ELAPSED" 'BEGIN { printf "%.3f", a + b }')
done
printf 'INFO: breaker-window request times: %s(sum %ss over 5 requests)\n' "$TIMES" "$SUM"
assert_eq "no breaker-window request pays a timeout" "$SLOW" "0"
assert_below "5 breaker-window requests stay well under 5 x 2s timeouts" "$SUM" "4"

# (a) writer 上已登录的 admin 不被踢，且不下发登出 cookie。
STATUS=$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
assert_eq "redis outage keeps the logged-in writer session alive" "$STATUS" "200"
assert_json "outage still resolves the admin identity" '.data.identity' "user:local:admin"
OUTAGE_HEADERS=$(cat "$TMP_DIR/shared-headers")
assert_contains "outage re-issues the live session cookie" "$OUTAGE_HEADERS" \
    "authz_session=$SHARED_ADMIN_TOKEN; Path=/; HttpOnly; SameSite=Lax; Max-Age="
assert_not_contains "outage never zeroes the authenticated session cookie" "$OUTAGE_HEADERS" \
    "authz_session=$SHARED_ADMIN_TOKEN; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
assert_json "writer reports the breaker as down" '.data.shared_session.state | tostring' "down"
assert_json "writer reports degraded service" '.data.shared_session.degraded | tostring' "true"
assert_json "writer reports fallback enabled" '.data.shared_session.fallback | tostring' "true"
assert_contains "writer records an io-class failure" \
    "$(jq -er '.data.shared_session.last_error' "$TMP_DIR/body")" "connect"

# (b) reader 上同一会话（本机镜像来自此前成功读）继续可用。
STATUS=$(shared_session "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
assert_eq "reader serves the session from its local mirror during outage" "$STATUS" "200"
assert_json "reader resolves the identity from the mirror" '.data.identity' "user:local:admin"
assert_json "reader reports degraded service too" '.data.shared_session.degraded | tostring' "true"

# 冷启动/陌生 token：本机镜像里没有这一行，降级期同样不认。
printf 'authz_session=%s' "$(printf 'a%.0s' {1..64})" > "$TMP_DIR/unknown.cookie"
STATUS=$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$TMP_DIR/unknown.cookie")
assert_eq "unknown token is refused while degraded" "$STATUS" "401"
STATUS=$(shared_session "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" "$TMP_DIR/unknown.cookie")
assert_eq "unknown token is refused on the reader while degraded" "$STATUS" "401"

# 冷启动即故障（跨重启兜底）：shared dict 里的 verified 记录随进程消失，降级资格
# 只能来自 SQLite sessions.verified_at。重启 writer 后立即验一次：第一次请求必然
# 重新撞 Redis（熔断器也是全新的），随后落回本机镜像。
docker restart "$SHARED_FIRST_CONTAINER" >/dev/null
wait_shared_gateway "$SHARED_A_HOST:$SHARED_HTTP_PORT"
FIRST_AFTER_RESTART=$(timed_shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
assert_eq "fresh process still serves the session during the outage" "${FIRST_AFTER_RESTART% *}" "200"
assert_json "the identity comes from the SQLite mirror" '.data.identity' "user:local:admin"
AGAIN="000 99.000"
for _ in $(seq 1 8); do
    AGAIN=$(timed_shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
    [[ "${AGAIN% *}" == "200" ]] && break
    sleep 1
done
printf 'INFO: after cold restart request=%s\n' "$AGAIN"
assert_eq "the writer stays authenticated after the breaker re-opens" "${AGAIN% *}" "200"
assert_below "re-opened breaker stops the network wait" "${AGAIN#* }" "1.5"

# (d) Redis 挂掉期间的新登录：签发落到本机镜像 + 欠写队列，不再 503。

STATUS=$(create_shared_person "$SHARED_A_HOST" "$SHARED_HTTP_PORT" sharedcarol carol-secret-1)
assert_eq "control plane still accepts writes during the outage" "$STATUS" "201"

SHARED_CAROL_COOKIE="$TMP_DIR/shared-carol.cookie"
rm -f "$SHARED_CAROL_COOKIE"
CAROL_LOGIN=$(curl -sS --max-time 20 --resolve "$SHARED_A_HOST:$SHARED_HTTP_PORT:127.0.0.1" \
    -D "$TMP_DIR/carol-login-headers" -o "$TMP_DIR/body" -w '%{http_code}' \
    -X POST "http://$SHARED_A_HOST:$SHARED_HTTP_PORT/_authz/login" \
    --data-urlencode 'username=sharedcarol' --data-urlencode 'password=carol-secret-1')
assert_eq "login succeeds while redis is down (no 503)" "$CAROL_LOGIN" "302"
# 登录失败同样是 302（回到 /_authz/login?err=），所以必须用落地地址确认是真成功。
assert_contains "the outage login lands on the app instead of the login page" \
    "$(cat "$TMP_DIR/carol-login-headers")" "Location: /_authz/apps/"
save_session_cookie "$TMP_DIR/carol-login-headers" "$SHARED_CAROL_COOKIE"
SHARED_CAROL_TOKEN=$(cookie_header "$SHARED_CAROL_COOKIE" | sed 's/^authz_session=//')
STATUS=$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_CAROL_COOKIE")
assert_eq "session issued during the outage works on its own writer" "$STATUS" "200"
# 门禁：健康段（含 pending 与 last_error）只对 admin 输出，guest 会话一律拿不到。
assert_json "the guest session is not an admin" '.data.admin | tostring' "false"
assert_json "the guest session cannot read the shared_session block" \
    '.data | has("shared_session") | tostring' "false"
printf 'INFO: guest session payload keys: %s (admin=%s)\n' \
    "$(jq -c '.data | keys' "$TMP_DIR/body")" "$(jq -r '.data.admin' "$TMP_DIR/body")"
assert_eq "the admin key can read the health snapshot during the outage" \
    "$(admin_health "$SHARED_A_HOST" "$SHARED_HTTP_PORT")" "200"
assert_json "the admin key reports the degraded service" \
    '.data.shared_session.degraded | tostring' "true"
assert_json "the deferred save sits in the pending queue" \
    '.data.shared_session.pending.save >= 1' "true"
assert_json "the queue is not empty while redis is down" \
    '.data.shared_session.pending.total >= 1' "true"
STATUS=$(shared_session "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" "$SHARED_CAROL_COOKIE")
assert_eq "the unsynced session is not yet visible on the reader" "$STATUS" "401"

# 同一场故障里再签发一个"不会被撤销"的会话：它才能证明 save 真的被重放进
# Redis（carol 的会话随后被撤销，Redis 里没有它并不能区分"没重放"与"重放后又删掉"）。
SHARED_DAVE_COOKIE="$TMP_DIR/shared-dave.cookie"
rm -f "$SHARED_DAVE_COOKIE"
DAVE_LOGIN=$(curl -sS --max-time 20 --resolve "$SHARED_A_HOST:$SHARED_HTTP_PORT:127.0.0.1" \
    -D "$TMP_DIR/dave-login-headers" -o "$TMP_DIR/body" -w '%{http_code}' \
    -X POST "http://$SHARED_A_HOST:$SHARED_HTTP_PORT/_authz/login" \
    --data-urlencode 'username=shareddave' --data-urlencode 'password=dave-secret-1')
assert_eq "the second outage login succeeds" "$DAVE_LOGIN" "302"
save_session_cookie "$TMP_DIR/dave-login-headers" "$SHARED_DAVE_COOKIE"
SHARED_DAVE_TOKEN=$(cookie_header "$SHARED_DAVE_COOKIE" | sed 's/^authz_session=//')
assert_eq "the second outage session works locally" \
    "$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_DAVE_COOKIE")" "200"
# Redis 此刻是停掉的，没法直接查它；"这条签发只进了本地队列"由欠写计数证明
# （carol 与 dave 两条 save 都还压在队列里），恢复后再核对它真的落到 Redis。
STATUS=$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
assert_eq "the admin session still works after the second outage login" "$STATUS" "200"
assert_json "both outage logins are still waiting in the save queue" \
    '.data.shared_session.pending.save >= 2' "true"

# (e) Redis 挂掉期间的撤销：本机立刻失效，撤销动作排队等重放（撤销永不丢弃）。
SHARED_CAROL_WRITER_ID=$(curl -sS --max-time 10 \
    --resolve "$SHARED_A_HOST:$SHARED_HTTP_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$SHARED_ADMIN_COOKIE")" \
    "http://$SHARED_A_HOST:$SHARED_HTTP_PORT/_authz/api/users" |
    jq -r '.data.users[] | select(.username == "sharedcarol") | .id')
STATUS=$(curl -sS --max-time 20 --resolve "$SHARED_A_HOST:$SHARED_HTTP_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$SHARED_ADMIN_COOKIE")" \
    -H "X-CSRF-Token: $SHARED_ADMIN_CSRF" -H 'Content-Type: application/json' \
    -o "$TMP_DIR/body" -w '%{http_code}' \
    -X PUT "http://$SHARED_A_HOST:$SHARED_HTTP_PORT/_authz/api/users/$SHARED_CAROL_WRITER_ID/password" \
    -d '{"password":"carol-secret-2"}')
assert_eq "password reset succeeds while redis is down" "$STATUS" "200"
STATUS=$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_CAROL_COOKIE")
assert_eq "revoked session stops working locally at once" "$STATUS" "401"
STATUS=$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
assert_eq "admin session survives the revocation round" "$STATUS" "200"
assert_json "the revocation waits in the pending queue" \
    '.data.shared_session.pending.delete_all >= 1' "true"

# 解冻：worker 0 定时器（本用例设成 1s 一轮）按 id 升序补写 —— 先 save 后
# delete_all，撤销最终落到 Redis 且晚于签发，队列清零。
resume_shared_redis
pass "shared redis is back"

PENDING_TOTAL=-1
STATUS=000
STATE=""
for _ in $(seq 1 240); do
    STATUS=$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
    PENDING_TOTAL=$(jq -er '.data.shared_session.pending.total' "$TMP_DIR/body" 2>/dev/null || echo -1)
    STATE=$(jq -er '.data.shared_session.state | tostring' "$TMP_DIR/body" 2>/dev/null || echo unknown)
    [[ "$PENDING_TOTAL" == "0" && "$STATE" == "ok" ]] && break
    sleep 1
done
printf 'INFO: after recovery pending.total=%s state=%s admin-status=%s\n' "$PENDING_TOTAL" "$STATE" "$STATUS"
assert_eq "writer is healthy again after the outage" "$STATUS" "200"
assert_json "breaker closed after recovery" '.data.shared_session.state | tostring' "ok"
assert_eq "the replay timer drained the pending queue" "$PENDING_TOTAL" "0"
assert_eq "the revoked token never lands in redis" \
    "$(redis_writer exists "authz-test:session:$SHARED_CAROL_TOKEN")" "0"
assert_eq "revoked token stays denied after recovery" \
    "$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_CAROL_COOKIE")" "401"
assert_eq "the still-valid admin session stayed shared" \
    "$(redis_writer exists "authz-test:session:$SHARED_ADMIN_TOKEN")" "1"
# 队列里那条 save 被真正补交出去（Redis 里出现签名信封），并且 reader 能读到它。
assert_eq "the replay timer pushed the deferred login into redis" \
    "$(redis_writer exists "authz-test:session:$SHARED_DAVE_TOKEN")" "1"
assert_contains "the replayed record carries the shared payload" \
    "$(redis_writer get "authz-test:session:$SHARED_DAVE_TOKEN")" '"username":"shareddave"'
# reader 的熔断窗口独立退避（最长 60s），没闭合前它读的是本机镜像，而镜像里
# 从来没有过 dave 这一行。先等它自己的半开探测成功，再验证跨实例可见性。
READER_STATE=""
READER_STATUS=000
for _ in $(seq 1 150); do
    READER_STATUS=$(shared_session "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
    READER_STATE=$(jq -er '.data.shared_session.state | tostring' "$TMP_DIR/body" 2>/dev/null || echo unknown)
    [[ "$READER_STATE" == "ok" ]] && break
    sleep 1
done
printf 'INFO: reader after recovery state=%s admin-status=%s\n' "$READER_STATE" "$READER_STATUS"
assert_eq "reader serves the admin session again after recovery" "$READER_STATUS" "200"
assert_json "reader breaker closed after recovery" '.data.shared_session.state | tostring' "ok"
assert_eq "the replayed session is readable on the reader" \
    "$(shared_session "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" "$SHARED_DAVE_COOKIE")" "200"

# ── (f) 严格模式：AUTHZ_SESSION_SHARED_FALLBACK=false 恢复 fail-closed ──────
SHARED_STRICT_CONTAINER="authz-shared-strict-test-$$"
SHARED_STRICT_HOST="shared-strict.test.example"
SHARED_EXTRA_ENVS=("AUTHZ_SESSION_SHARED_FALLBACK=false")
start_shared_gateway "$SHARED_STRICT_CONTAINER" "$SHARED_STRICT_HTTP_PORT" \
    "$SHARED_STRICT_HTTPS_PORT" read-write "$SHARED_WRITER_USER" "$SHARED_WRITER_PASS"
wait_shared_gateway "$SHARED_STRICT_HOST:$SHARED_STRICT_HTTP_PORT"
pass "strict writer with fallback disabled is ready"

SHARED_STRICT_COOKIE="$TMP_DIR/shared-strict.cookie"
shared_login "$SHARED_STRICT_HOST" "$SHARED_STRICT_HTTP_PORT" admin admin123 "$SHARED_STRICT_COOKIE"
SHARED_STRICT_TOKEN=$(cookie_header "$SHARED_STRICT_COOKIE" | sed 's/^authz_session=//')
STATUS=$(shared_session "$SHARED_STRICT_HOST" "$SHARED_STRICT_HTTP_PORT" "$SHARED_STRICT_COOKIE")
assert_eq "strict writer works while redis is healthy" "$STATUS" "200"
assert_json "strict writer reports fallback disabled" \
    '.data.shared_session.fallback | tostring' "false"
assert_json "strict writer is not degraded" '.data.shared_session.degraded | tostring' "false"

break_shared_redis
STRICT_DOWN=$(timed_shared_session "$SHARED_STRICT_HOST" "$SHARED_STRICT_HTTP_PORT" "$SHARED_STRICT_COOKIE")
assert_eq "strict writer fails closed during the redis outage" "${STRICT_DOWN% *}" "401"
STRICT_HEADERS=$(cat "$TMP_DIR/shared-headers")
assert_contains "strict outage clears the browser cookie" "$STRICT_HEADERS" \
    "authz_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
assert_contains "strict outage clears the domain-scoped cookie too" "$STRICT_HEADERS" \
    "Max-Age=0; Domain=$SHARED_COOKIE_DOMAIN"
assert_not_contains "strict outage never re-issues the live session" "$STRICT_HEADERS" \
    "authz_session=$SHARED_STRICT_TOKEN;"
# 同一次故障里默认实例（fallback=true）继续服务，两条判据互不干扰。
assert_eq "fallback writer keeps serving during the same outage" \
    "$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")" "200"
assert_eq "reader keeps serving during the same outage" \
    "$(shared_session "$SHARED_B_HOST" "$SHARED_B_HTTP_PORT" "$SHARED_ADMIN_COOKIE")" "200"
resume_shared_redis

STRICT_BACK=000
for _ in $(seq 1 240); do
    STRICT_BACK=$(shared_session "$SHARED_STRICT_HOST" "$SHARED_STRICT_HTTP_PORT" "$SHARED_STRICT_COOKIE")
    [[ "$STRICT_BACK" == "200" ]] && break
    sleep 1
done
assert_eq "strict writer recovers once redis answers again" "$STRICT_BACK" "200"
assert_eq "the strict writer session is shared in redis again" \
    "$(redis_writer exists "authz-test:session:$SHARED_STRICT_TOKEN")" "1"

# ── 配置类故障（AUTH 失败）即使 fallback=true 也一律不降级 ───────────────────
# 会话全灭时唯一的可观测面是 admin x-api-key（机器凭证不经过会话存储），
# 它同时给出 state="config"；再配「Redis 里记录其实还在」排除数据丢失的解释。
assert_eq "the admin session works right before the config fault" \
    "$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")" "200"
redis_admin ACL SETUSER "$SHARED_WRITER_USER" resetpass ">rotated-by-test" >/dev/null
sleep 12   # 让 keepalive 池里的旧连接（已 AUTH）过期，下一次请求必然重新 AUTH
STATUS=$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
assert_eq "AUTH failure never degrades even with fallback enabled" "$STATUS" "401"
assert_contains "AUTH failure clears the cookie" "$(cat "$TMP_DIR/shared-headers")" \
    "Max-Age=0"
STATUS=$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
assert_eq "AUTH failure keeps failing closed on the next request" "$STATUS" "401"
assert_eq "AUTH failure does not destroy the shared record itself" \
    "$(redis_admin exists "authz-test:session:$SHARED_ADMIN_TOKEN")" "1"
# 会话一律 401 的同时，admin Key 仍读得到健康快照，并把它标成配置类故障。
assert_eq "the admin key still authenticates while every session is denied" \
    "$(admin_health "$SHARED_A_HOST" "$SHARED_HTTP_PORT")" "200"
assert_json "the key response says it came from an api key" \
    '.data.auth_type' "api_key"
assert_json "the key is treated as admin" '.data.admin | tostring' "true"
assert_json "health snapshot labels it a config fault" \
    '.data.shared_session.state | tostring' "config"
printf 'INFO: admin key snapshot under AUTH fault: state=%s last_error=%s degraded=%s sessions-denied=401\n' \
    "$(jq -r '.data.shared_session.state' "$TMP_DIR/body")" \
    "$(jq -r '.data.shared_session.last_error' "$TMP_DIR/body")" \
    "$(jq -r '.data.shared_session.degraded' "$TMP_DIR/body")"
assert_json "config fault is never served from the local mirror" \
    '.data.shared_session.degraded | tostring' "false"
assert_contains "the snapshot carries the upstream auth error text" \
    "$(jq -er '.data.shared_session.last_error' "$TMP_DIR/body")" "auth"
# 上面几条 jq 都读同一个 curl 落盘的 body，不受熔断窗口 TTL 影响，
# 可以放心断言瞬时字段。
assert_json "the config fault opens the breaker as well" \
    '.data.shared_session.down | tostring' "true"
assert_above "the config fault is counted as a failure" \
    "$(jq -er '.data.shared_session.failures' "$TMP_DIR/body")" "0"
assert_json "the health snapshot comes from a shared-enabled instance" \
    '.data.shared_session.enabled | tostring' "true"

redis_admin ACL SETUSER "$SHARED_WRITER_USER" resetpass ">$SHARED_WRITER_PASS" >/dev/null
RECOVERED=000
for _ in $(seq 1 240); do
    RECOVERED=$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
    [[ "$RECOVERED" == "200" ]] && break
    sleep 1
done
assert_eq "writer serves again once the AUTH config is corrected" "$RECOVERED" "200"
assert_json "health snapshot returns to ok" '.data.shared_session.state | tostring' "ok"

if [[ "$KEEP_GOING" == "1" ]]; then
    printf '\nTriage run: %d passed, %d failed\n' "$PASS" "$FAILS"
    [[ "$FAILS" == "0" ]] || exit 1
else
    printf '\nAll %d shared session checks passed.\n' "$PASS"
fi
