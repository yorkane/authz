#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$REPO_DIR/test/support_lualib.sh"
IMAGE=${OPENRESTY_TEST_IMAGE:-ghcr.io/yorkane/authz:latest}
SHARED_REDIS_CONTAINER=""
SHARED_FIRST_CONTAINER=""
SHARED_SECOND_CONTAINER=""
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
SHARED_WRITER_USER="authz-writer"
SHARED_READER_USER="authz-reader"
SHARED_WRITER_PASS="shared-writer-test-secret"
SHARED_READER_PASS="shared-reader-test-secret"
SHARED_SIGNING_KEY="shared-session-signing-key-for-tests-0123456789abcdef"

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
        docker rm -f "$SHARED_REDIS_CONTAINER" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR" || true
}
trap cleanup EXIT

fail() {
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
    [[ "$actual" == "$expected" ]] || fail "$name (expected '$expected', got '$actual')"
    pass "$name"
}

assert_contains() {
    local name=$1 actual=$2 expected=$3
    [[ "$actual" == *"$expected"* ]] || fail "$name (missing '$expected')"
    pass "$name"
}

assert_not_contains() {
    local name=$1 actual=$2 unexpected=$3
    [[ "$actual" != *"$unexpected"* ]] || fail "$name (unexpected '$unexpected')"
    pass "$name"
}

assert_json() {
    local name=$1 filter=$2 expected=$3 actual
    actual=$(jq -er "$filter" "$TMP_DIR/body") || fail "$name (invalid JSON or filter)"
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

# ── 共享会话 (Redis): 单写多读、ACL 隔离、故障关闭 ──────────────
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
        +get +ping >/dev/null

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
docker stop "$SHARED_REDIS_CONTAINER" >/dev/null
STATUS=$(shared_session "$SHARED_A_HOST" "$SHARED_HTTP_PORT" "$SHARED_ADMIN_COOKIE")
assert_eq "Redis outage fails closed despite writer SQLite row" "$STATUS" "401"
assert_contains "Redis outage clears browser cookie" "$(cat "$TMP_DIR/shared-headers")" \
    "authz_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"


printf '\nAll %d shared session checks passed.\n' "$PASS"
