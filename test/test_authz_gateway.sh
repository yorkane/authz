#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${OPENRESTY_TEST_IMAGE:-ghcr.io/yorkane/authz:latest}
CONTAINER_NAME="authz-gateway-test-$$"
REDIRECT_CONTAINER_NAME=""
ORIGIN_CONTAINER_NAME=""
TMP_DIR=$(mktemp -d)
PASS=0
MOCK_PID=""
REMOTE_PID=""
NOCO_PID=""
WS_PID=""
TLS_PID=""

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
UPSTREAM_PORT=$(free_port)
NOCO_PORT=$(free_port)
WS_PORT=$(free_port)
TLS_PORT=$(free_port)
REDIRECT_HTTP_PORT=$(free_port)
REDIRECT_HTTPS_PORT=$(free_port)
REMOTE_PORT=$(free_port)
REMOTE_IP=$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    s.connect(("192.0.2.1", 9))
    print(s.getsockname()[0])
finally:
    s.close()
PY
)
[[ "$REMOTE_IP" != 127.* ]] || { printf 'FAIL: no non-loopback IPv4 address available\n' >&2; exit 1; }
DYNAMIC_HOST="${UPSTREAM_PORT}-dynamic.test.example"
POLICY_OBJECT="/${UPSTREAM_PORT}/*"

cleanup() {
    docker exec "$CONTAINER_NAME" chmod -R a+rwx /data >/dev/null 2>&1 || true
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    if [[ -n "$REDIRECT_CONTAINER_NAME" ]]; then
        docker exec "$REDIRECT_CONTAINER_NAME" chmod -R a+rwx /data >/dev/null 2>&1 || true
        docker rm -f "$REDIRECT_CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -n "$ORIGIN_CONTAINER_NAME" ]]; then
        docker exec "$ORIGIN_CONTAINER_NAME" chmod -R a+rwx /data >/dev/null 2>&1 || true
        docker rm -f "$ORIGIN_CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -n "$MOCK_PID" ]]; then kill "$MOCK_PID" >/dev/null 2>&1 || true; fi
    if [[ -n "$REMOTE_PID" ]]; then kill "$REMOTE_PID" >/dev/null 2>&1 || true; fi
    if [[ -n "$NOCO_PID" ]]; then kill "$NOCO_PID" >/dev/null 2>&1 || true; fi
    if [[ -n "$WS_PID" ]]; then kill "$WS_PID" >/dev/null 2>&1 || true; fi
    if [[ -n "$TLS_PID" ]]; then kill "$TLS_PID" >/dev/null 2>&1 || true; fi
    rm -rf "$TMP_DIR" || true
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    [[ -f "$TMP_DIR/body" ]] && cat "$TMP_DIR/body" >&2 || true
    [[ -f "$TMP_DIR/nocobase.log" ]] && tail -n 40 "$TMP_DIR/nocobase.log" >&2 || true
    docker logs "$CONTAINER_NAME" 2>&1 | tail -n 100 >&2 || true
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

assert_contains_all() {
    local name=$1 actual=$2 pattern
    shift 2
    for pattern in "$@"; do
        [[ "$actual" == *"$pattern"* ]] || fail "$name (missing '$pattern')"
    done
    pass "$name"
}

assert_contains_none() {
    local name=$1 actual=$2 pattern
    shift 2
    for pattern in "$@"; do
        [[ "$actual" != *"$pattern"* ]] || fail "$name (unexpected '$pattern')"
    done
    pass "$name"
}

TLS_CERT="$TMP_DIR/mock-upstream-cert.pem"
TLS_KEY="$TMP_DIR/mock-upstream-key.pem"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TLS_KEY" -out "$TLS_CERT" \
    -days 1 -subj '/CN=127.0.0.1' >/dev/null 2>&1 || fail "unable to create TLS mock certificate"
python3 "$REPO_DIR/test/mock_http.py" "$UPSTREAM_PORT" >"$TMP_DIR/mock.log" 2>&1 &
MOCK_PID=$!
python3 "$REPO_DIR/test/mock_http.py" "$REMOTE_PORT" 0.0.0.0 hello-from-remote-ip >"$TMP_DIR/remote.log" 2>&1 &
REMOTE_PID=$!
python3 "$REPO_DIR/test/mock_nocobase.py" "$NOCO_PORT" \
    "http://admin.test.example:$HTTP_PORT/_authz/oauth/callback" >"$TMP_DIR/nocobase.log" 2>&1 &
NOCO_PID=$!
python3 "$REPO_DIR/test/mock_websocket.py" "$WS_PORT" >"$TMP_DIR/websocket.log" 2>&1 &
WS_PID=$!
python3 "$REPO_DIR/test/mock_https.py" "$TLS_PORT" "$TLS_CERT" "$TLS_KEY" >"$TMP_DIR/https-mock.log" 2>&1 &
TLS_PID=$!
for _ in $(seq 1 30); do
    curl -kfsS --max-time 1 "https://127.0.0.1:$TLS_PORT/" >/dev/null 2>&1 && break
    sleep 0.1
done
curl -kfsS --max-time 2 "https://127.0.0.1:$TLS_PORT/" >/dev/null \
    || fail "mock HTTPS upstream did not start"
for _ in $(seq 1 30); do
    curl -fsS --max-time 1 "http://127.0.0.1:$UPSTREAM_PORT/" >/dev/null 2>&1 && break
    sleep 0.1
done
curl -fsS --max-time 2 "http://127.0.0.1:$UPSTREAM_PORT/" >/dev/null || fail "mock upstream did not start"
MOCK_BODY=$(curl -fsS --max-time 2 "http://127.0.0.1:$UPSTREAM_PORT/")
for _ in $(seq 1 30); do
    curl -fsS --max-time 1 "http://$REMOTE_IP:$REMOTE_PORT/" >/dev/null 2>&1 && break
    sleep 0.1
done
REMOTE_BODY=$(curl -fsS --max-time 2 "http://$REMOTE_IP:$REMOTE_PORT/") || fail "remote IP mock upstream did not start"
for _ in $(seq 1 30); do
    STATUS=$(curl -sS --max-time 1 -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:$NOCO_PORT/api/auth:check" 2>/dev/null || true)
    [[ "$STATUS" == "401" ]] && break
    sleep 0.1
done
[[ "$STATUS" == "401" ]] || fail "mock NocoBase did not start"

OPENRESTY_BUILD_ARGS=$(docker run --rm "$IMAGE" openresty -V 2>&1)
assert_contains "OpenResty includes Brotli module" "$OPENRESTY_BUILD_ARGS" "--add-module=/tmp/ngx_brotli"
docker run --rm "$IMAGE" sh -c \
    'test -s /usr/local/openresty/nginx/html/admin/api.js.br' \
    || fail "image does not contain Brotli static sidecar"
pass "admin assets have Brotli static sidecars"
docker run --rm "$IMAGE" sh -c \
    '! test -e /usr/local/openresty/nginx/html/admin/index.html.br' \
    || fail "SSI admin entrypoint must not have a Brotli static sidecar"
pass "SSI admin entrypoint is excluded from Brotli sidecars"
docker run --rm "$IMAGE" sh -c \
    'test -s /usr/local/openresty/site/lualib/resty/mlcache.lua' \
    || fail "image does not contain vendored lua-resty-mlcache"
pass "lua-resty-mlcache is vendored in the image"

SERVER_TEMPLATE=$(cat "$REPO_DIR/conf/server.conf.template")
assert_contains "HTTPS serves the shared server template" \
    "$(cat "$REPO_DIR/conf/nginx.conf.template")" "include server.conf;"
ENTRYPOINT_SOURCE=$(cat "$REPO_DIR/docker-entrypoint.sh")
assert_contains "entrypoint renders shared server configuration" "$ENTRYPOINT_SOURCE" \
    'render_template "$SERVER_TEMPLATE_FILE" "$NGINX_CONF_DIR/server.conf"'
assert_contains_all "server template forwards proxy and identity headers" "$SERVER_TEMPLATE" \
    'proxy_set_header X-Forwarded-Host  $authz_proxy_forwarded_host;' \
    'proxy_set_header Host              $authz_upstream_host;' \
    'proxy_set_header X-Forwarded-Proto $authz_forwarded_proto;' \
    'proxy_set_header X-Forwarded-Port  $authz_forwarded_port;' \
    'proxy_set_header Origin            $authz_origin;' \
    'proxy_set_header X-Authz-Key       "";' \
    'proxy_set_header Cookie            $authz_upstream_cookie;'
assert_contains_none "server template avoids unsafe proxy defaults" "$SERVER_TEMPLATE" \
    'proxy_set_header Host              $proxy_host;'
assert_contains_all "server template hardens WebSocket and upstream TLS" "$SERVER_TEMPLATE" \
    'proxy_buffering off;' \
    'proxy_read_timeout 3600s;' \
    'proxy_ssl_verify on;' \
    'location @authz_proxy_insecure {' \
    'proxy_ssl_name $authz_upstream_ssl_name;' \
    'proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;'
NGINX_TEMPLATE=$(cat "$REPO_DIR/conf/nginx.conf.template")
assert_contains "database cache shared dictionary configured" "$NGINX_TEMPLATE" \
    'lua_shared_dict authz_db_cache 10m;'
USERS_SOURCE=$(cat "$REPO_DIR/admin/users.html")
assert_contains "password form asks for confirmation" "$USERS_SOURCE" 'passwordForm.newpw_confirm'
assert_contains "password form validates confirmation" "$USERS_SOURCE" 'matchingPassword'
cat >"$TMP_DIR/nocobase.env" <<EOF
AUTHZ_HOST_URL=http://admin.test.example:$HTTP_PORT
AUTHZ_NOCO_URL=http://127.0.0.1:$NOCO_PORT
AUTHZ_NOCO_API_KEY=registration-api-key
AUTHZ_NOCO_OAUTH_ENABLED=false
AUTHZ_NOCO_OAUTH_CLIENT_ID=noco-client
AUTHZ_NOCO_OAUTH_CLIENT_SECRET=noco-secret
EOF
python3 "$REPO_DIR/scripts/register_nocobase_oauth.py" \
    --allow-http --env-file "$TMP_DIR/nocobase.env" >/dev/null || fail "NocoBase OAuth registration failed"
assert_eq "NocoBase OAuth registration enables provider" \
    "$(grep '^AUTHZ_NOCO_OAUTH_ENABLED=' "$TMP_DIR/nocobase.env")" "AUTHZ_NOCO_OAUTH_ENABLED=true"
assert_eq "NocoBase OAuth registration writes exact callback" \
    "$(grep '^AUTHZ_NOCO_OAUTH_REDIRECT_URI=' "$TMP_DIR/nocobase.env")" \
    "AUTHZ_NOCO_OAUTH_REDIRECT_URI=http://admin.test.example:$HTTP_PORT/_authz/oauth/callback"
python3 "$REPO_DIR/scripts/register_nocobase_oauth.py" \
    --allow-http --env-file "$TMP_DIR/nocobase.env" >/dev/null || fail "NocoBase OAuth registration is not idempotent"
pass "NocoBase OAuth registration reuses existing client"

mkdir -p "$TMP_DIR/data/authz"
python3 - "$TMP_DIR/data/authz/authz.db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute("""CREATE TABLE users(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    salt TEXT NOT NULL,
    roles TEXT NOT NULL DEFAULT 'user',
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL
)""")
connection.execute("""CREATE TABLE sessions(
    token TEXT PRIMARY KEY,
    username TEXT NOT NULL,
    csrf TEXT NOT NULL,
    expires_at INTEGER NOT NULL
)""")
connection.execute("""CREATE TABLE remote_users(
    provider TEXT NOT NULL,
    subject TEXT NOT NULL,
    username TEXT UNIQUE NOT NULL,
    roles TEXT NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    synced_at INTEGER NOT NULL,
    PRIMARY KEY(provider, subject)
)""")
connection.execute("""INSERT INTO remote_users
    (provider, subject, username, roles, enabled, synced_at)
    VALUES ('legacy', 'legacy-subject', 'legacy_remote', 'viewer', 1, 1)
""")
connection.execute("""CREATE TABLE policies(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ptype TEXT NOT NULL,
    v0 TEXT NOT NULL,
    v1 TEXT NOT NULL DEFAULT '*',
    v2 TEXT NOT NULL DEFAULT '*',
    UNIQUE(ptype, v0, v1, v2)
)""")
connection.execute("""INSERT INTO policies(ptype, v0, v1, v2)
    VALUES ('p', 'legacy_user', '/2999/*', 'GET')
""")
connection.execute("""CREATE TABLE bindings(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    domain TEXT UNIQUE NOT NULL,
    port INTEGER NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1,
    websocket INTEGER NOT NULL DEFAULT 0,
    note TEXT NOT NULL DEFAULT '',
    menu_name TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL
)""")
connection.execute("""INSERT INTO bindings(domain, port, enabled, created_at)
    VALUES ('legacy.test.example', 2998, 0, 1)
""")
connection.execute("""CREATE TABLE api_keys(
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    token_hash TEXT UNIQUE NOT NULL,
    role TEXT NOT NULL DEFAULT 'api' CHECK(role = 'api'),
    enabled INTEGER NOT NULL DEFAULT 1,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
)""")
connection.commit()
connection.close()
PY
mkdir -p "$TMP_DIR/templates"
cp "$REPO_DIR/conf/nginx.conf.template" "$TMP_DIR/templates/nginx.conf.template"
{
    printf '# runtime-template-v1\n'
    cat "$REPO_DIR/conf/server.conf.template"
} > "$TMP_DIR/templates/server.conf.template"
docker run -d \
    --name "$CONTAINER_NAME" \
    --network host \
    -e NGINX_WORKER_PROCESSES=1 \
    -e AUTHZ_HTTP_PORT="$HTTP_PORT" \
    -e AUTHZ_HTTPS_PORT="$HTTPS_PORT" \
    -e AUTHZ_HTTP_MODE=serve \
    -e "AUTHZ_HOST_URL=http://admin.test.example:$HTTP_PORT" \
    -e AUTHZ_ADMIN_PASSWORD=admin123 \
    -e AUTHZ_DB_CACHE_TTL=30 \
    -e AUTHZ_DB_CACHE_LRU_SIZE=500 \
    -e AUTHZ_PORT_MIN=1000 \
    -e AUTHZ_PORT_MAX=65535 \
    -e AUTHZ_DISCOVERY_PORTS="$UPSTREAM_PORT,$WS_PORT" \
    -e AUTHZ_NOCO_ENABLED=true \
    -e AUTHZ_NOCO_URL="http://127.0.0.1:$NOCO_PORT" \
    -e AUTHZ_NOCO_ALLOW_HTTP=true \
    -e AUTHZ_NOCO_ROLE_MAP='member=user,operator=staff,root=admin' \
    -e AUTHZ_NOCO_OAUTH_ENABLED=true \
    -e AUTHZ_NOCO_OAUTH_CLIENT_ID=noco-client \
    -e AUTHZ_NOCO_OAUTH_CLIENT_SECRET=noco-secret \
    -e AUTHZ_NOCO_OAUTH_REDIRECT_URI="http://admin.test.example:$HTTP_PORT/_authz/oauth/callback" \
    -e AUTHZ_OAUTH_ENABLED=true \
    -e AUTHZ_OAUTH_PROVIDER=testid \
    -e 'AUTHZ_OAUTH_TITLE=Test Identity' \
    -e AUTHZ_OAUTH_CLIENT_ID=test-client \
    -e AUTHZ_OAUTH_CLIENT_SECRET=test-secret \
    -e AUTHZ_OAUTH_AUTHORIZE_URL="http://127.0.0.1:$NOCO_PORT/oauth/authorize" \
    -e AUTHZ_OAUTH_TOKEN_URL="http://127.0.0.1:$NOCO_PORT/oauth/token" \
    -e AUTHZ_OAUTH_USERINFO_URL="http://127.0.0.1:$NOCO_PORT/oauth/userinfo" \
    -e AUTHZ_OAUTH_REDIRECT_URI="http://admin.test.example:$HTTP_PORT/_authz/oauth/callback" \
    -e AUTHZ_OAUTH_ROLE_MAP='employees=staff' \
    -e AUTHZ_OAUTH_ALLOW_HTTP=true \
    -e AUTHZ_DINGTALK_ENABLED=true \
    -e AUTHZ_DINGTALK_CLIENT_ID=ding-client \
    -e AUTHZ_DINGTALK_CLIENT_SECRET=ding-secret \
    -e AUTHZ_DINGTALK_REDIRECT_URI="http://admin.test.example:$HTTP_PORT/_authz/oauth/callback" \
    -e AUTHZ_DINGTALK_AUTHORIZE_URL="http://127.0.0.1:$NOCO_PORT/dingtalk/authorize" \
    -e AUTHZ_DINGTALK_TOKEN_URL="http://127.0.0.1:$NOCO_PORT/dingtalk/token" \
    -e AUTHZ_DINGTALK_USERINFO_URL="http://127.0.0.1:$NOCO_PORT/dingtalk/userinfo" \
    -e AUTHZ_WECHAT_ENABLED=true \
    -e AUTHZ_WECHAT_APP_ID=wechat-app \
    -e AUTHZ_WECHAT_APP_SECRET=wechat-secret \
    -e AUTHZ_WECHAT_REDIRECT_URI="http://admin.test.example:$HTTP_PORT/_authz/oauth/callback" \
    -e AUTHZ_WECHAT_AUTHORIZE_URL="http://127.0.0.1:$NOCO_PORT/wechat/authorize" \
    -e AUTHZ_WECHAT_TOKEN_URL="http://127.0.0.1:$NOCO_PORT/wechat/token" \
    -e AUTHZ_WECHAT_USERINFO_URL="http://127.0.0.1:$NOCO_PORT/wechat/userinfo" \
    -e OPENRESTY_TEMPLATE_DIR=/etc/openresty/templates \
    -v "$TMP_DIR/data:/data" \
    -v "$REPO_DIR/admin:/usr/local/openresty/nginx/html/admin:ro" \
    -v "$REPO_DIR/admin:/files:ro" \
    -v "$TMP_DIR/templates:/etc/openresty/templates:ro" \
    -v "$REPO_DIR/docker-entrypoint.sh:/docker-entrypoint.sh:ro" \
    -v "$REPO_DIR/lualib:/usr/local/openresty/site/lualib:ro" \
    "$IMAGE" >/dev/null

for _ in $(seq 1 80); do
    STATUS=$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HTTP_PORT/_authz/api/session" 2>/dev/null || true)
    [[ "$STATUS" == "401" ]] && break
    sleep 0.1
done
[[ "$STATUS" == "401" ]] || fail "gateway did not become ready"
docker exec "$CONTAINER_NAME" grep -q '^# runtime-template-v1$' \
    /usr/local/openresty/nginx/conf/server.conf || fail "entrypoint did not render mounted server template"
pass "entrypoint renders mounted server template"

{
    printf '# runtime-template-v2\n'
    cat "$REPO_DIR/conf/server.conf.template"
} > "$TMP_DIR/templates/server.conf.template.next"
mv "$TMP_DIR/templates/server.conf.template.next" "$TMP_DIR/templates/server.conf.template"
docker restart "$CONTAINER_NAME" >/dev/null
for _ in $(seq 1 80); do
    STATUS=$(curl -sS --max-time 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HTTP_PORT/_authz/api/session" 2>/dev/null || true)
    [[ "$STATUS" == "401" ]] && break
    sleep 0.1
done
[[ "$STATUS" == "401" ]] || fail "gateway did not become ready after runtime template change"
docker exec "$CONTAINER_NAME" grep -q '^# runtime-template-v2$' \
    /usr/local/openresty/nginx/conf/server.conf || fail "server template was not re-rendered after restart"
pass "server template changes apply without rebuilding the image"
MIGRATION_REPORT=$(python3 - "$TMP_DIR/data/authz/authz.db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
def columns(table):
    return {row[1] for row in connection.execute("PRAGMA table_info(" + table + ")")}

# sessions: source column added
print("sessions=" + ("yes" if "source" in columns("sessions") else "no"))

# remote_users: new columns, provider-scoped unique, legacy timestamps
rc = columns("remote_users")
unique_indexes = [row[1] for row in connection.execute("PRAGMA index_list(remote_users)") if row[2]]
unique_columns = [tuple(item[2] for item in connection.execute(f"PRAGMA index_info({index})"))
                  for index in unique_indexes]
remote_valid = {"remote_roles", "roles_overridden", "created_at", "last_login_at", "updated_at"}.issubset(rc)
remote_valid = remote_valid and ("provider", "username") in unique_columns and ("username",) not in unique_columns
legacy = connection.execute("""SELECT created_at, last_login_at, updated_at
    FROM remote_users WHERE provider = 'legacy'""").fetchone()
remote_valid = remote_valid and legacy == (1, 1, 1)
print("remote=" + ("yes" if remote_valid else "no"))

# users: timestamps migrated and seeded
uc = columns("users")
row = connection.execute("SELECT created_at, last_login_at, updated_at FROM users WHERE username = 'admin'").fetchone()
user_valid = {"created_at", "last_login_at", "updated_at"}.issubset(uc)
user_valid = user_valid and row and row[0] > 0 and row[1] is None and row[2] == row[0]
print("users=" + ("yes" if user_valid else "no"))

# bindings: safe proxy defaults backfilled
bc = columns("bindings")
expected = {"target_ip", "upstream_host", "forwarded_host", "forwarded_proto",
            "forwarded_port", "origin_mode", "custom_origin", "simulate_local", "local_ip",
            "upstream_scheme", "upstream_ssl_verify", "upstream_path"}
row = connection.execute("""SELECT target_ip, upstream_host, forwarded_host, forwarded_proto,
    forwarded_port, origin_mode, custom_origin, simulate_local, local_ip,
    upstream_scheme, upstream_ssl_verify, upstream_path
    FROM bindings WHERE domain = 'legacy.test.example'""").fetchone()
defaults = ("127.0.0.1", "", "", "", 0, "auto", "", 0, "127.0.0.1", "http", 1, "")
print("bindings=" + ("yes" if expected.issubset(bc) and row == defaults else "no"))

# api_keys: final schema, seeded policy, CHECK removed
ac = columns("api_keys")
schema = connection.execute("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'api_keys'").fetchone()[0]
policy = connection.execute("""SELECT 1 FROM policies
    WHERE ptype = 'p' AND v0 = 'role:api' AND v1 = '/*' AND v2 = '*'""").fetchone()
api_valid = ac == {"id", "name", "token_hash", "role", "loopback_only", "enabled", "created_at", "updated_at"}
print("api_keys=" + ("yes" if api_valid and policy and "CHECK" not in schema.upper() else "no"))

# legacy policy migrated to local identity
row = connection.execute("SELECT v0 FROM policies WHERE v1 = '/2999/*'").fetchone()
print("legacy_policy=" + (row[0] if row else "missing"))

# ordered migration ledger
rows = connection.execute(
    "SELECT version, name FROM schema_migrations ORDER BY version"
).fetchall()
print("ledger=" + "|".join(f"{version}:{name}" for version, name in rows))
connection.close()
PY
)
report_get() { printf '%s' "$MIGRATION_REPORT" | awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, "", $0); print $0; exit }'; }
assert_eq "legacy sessions schema migrated" "$(report_get sessions)" "yes"
assert_eq "remote identity and timestamps migrated" "$(report_get remote)" "yes"
assert_eq "local user timestamps migrated and seeded" "$(report_get users)" "yes"
assert_eq "legacy bindings receive safe proxy defaults" "$(report_get bindings)" "yes"
assert_eq "API key schema and api role policy seeded" "$(report_get api_keys)" "yes"
assert_eq "legacy user policy migrated to local identity" "$(report_get legacy_policy)" "user:local:legacy_user"
assert_eq "database migrations have an ordered version ledger" "$(report_get ledger)" \
    "1:create_current_schema|2:upgrade_legacy_columns_and_timestamps|3:expand_api_key_role_catalog|4:scope_remote_username_uniqueness_by_provider|5:canonicalize_policy_principals|6:create_menu_entries|7:treeify_menu_entries_and_seed_layout|8:api_keys_loopback_only|9:bindings_header_overrides|10:menu_entry_files_browser|11:remove_omniscript_fix_files_icon|12:menu_entry_nginx_conf|13:menu_group_domain_services"

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

request() {
    local method=$1 host=$2 path=$3 cookie=${4:-} csrf=${5:-} data=${6:-} api_key=${7:-}
    local args=(--silent --show-error --max-time 5 --request "$method" --resolve "$host:$HTTP_PORT:127.0.0.1" -H 'Accept: application/json' -D "$TMP_DIR/headers" -o "$TMP_DIR/body" -w '%{http_code}')
    [[ -n "$cookie" ]] && args+=(-H "Cookie: $(cookie_header "$cookie")")
    [[ -n "$csrf" ]] && args+=(-H "X-CSRF-Token: $csrf")
    [[ -n "$api_key" ]] && args+=(-H "x-authz-key: $api_key")
    if [[ -n "$data" ]]; then args+=(-H 'Content-Type: application/json' --data "$data"); fi
    STATUS=$(curl "${args[@]}" "http://$host:$HTTP_PORT$path")
    BODY=$(<"$TMP_DIR/body")
    CONTENT_TYPE=$(awk 'BEGIN { IGNORECASE=1 } /^Content-Type:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0 } END { print value }' "$TMP_DIR/headers")
}

login() {
    local host=$1 username=$2 password=$3 cookie=$4 source=${5:-local} expect_session=${6:-true}
    rm -f "$cookie"
    STATUS=$(curl -sS --max-time 5 --resolve "$host:$HTTP_PORT:127.0.0.1" -D "$TMP_DIR/login-headers" -o /dev/null -w '%{http_code}' \
        -X POST "http://$host:$HTTP_PORT/_authz/login" \
        --data-urlencode "username=$username" --data-urlencode "password=$password" \
        --data-urlencode "source=$source")
    assert_eq "login $username from $source" "$STATUS" "302"
    if [[ "$expect_session" == "true" ]]; then
        save_session_cookie "$TMP_DIR/login-headers" "$cookie"
    else
        if awk 'BEGIN { IGNORECASE=1; found=0 } /^Set-Cookie:[[:space:]]*authz_session=/ { found=1 } END { exit found ? 0 : 1 }' "$TMP_DIR/login-headers"; then
            fail "rejected login unexpectedly set a session cookie"
        fi
        printf '' > "$cookie"
    fi
}

ADMIN_HOST=admin.test.example
SECOND_BASE_HOST=app-m.w.wtvdev.com
ADMIN_COOKIE="$TMP_DIR/admin.cookie"
SECOND_BASE_COOKIE="$TMP_DIR/second-base.cookie"
BOB_COOKIE="$TMP_DIR/bob.cookie"
DYNAMIC_COOKIE="$TMP_DIR/dynamic.cookie"
APP_COOKIE="$TMP_DIR/app.cookie"
REMOTE_COOKIE="$TMP_DIR/remote.cookie"
REMOTE_DYNAMIC_COOKIE="$TMP_DIR/remote-dynamic.cookie"
SHADOW_COOKIE="$TMP_DIR/shadow.cookie"
SHADOW_DYNAMIC_COOKIE="$TMP_DIR/shadow-dynamic.cookie"
RESET_COOKIE="$TMP_DIR/reset.cookie"
OAUTH_COOKIE="$TMP_DIR/oauth.cookie"
NOCO_OAUTH_COOKIE="$TMP_DIR/noco-oauth.cookie"
NOCO_OAUTH_SECOND_COOKIE="$TMP_DIR/noco-oauth-second.cookie"
NOCO_BAD_ISSUER_COOKIE="$TMP_DIR/noco-bad-issuer.cookie"
DINGTALK_COOKIE="$TMP_DIR/dingtalk.cookie"
WECHAT_COOKIE="$TMP_DIR/wechat.cookie"

request GET "$ADMIN_HOST" /_authz/api/session
assert_eq "unauthenticated API status" "$STATUS" "401"
assert_eq "unauthenticated API JSON type" "$CONTENT_TYPE" "application/json; charset=UTF-8"
assert_json "unauthenticated API error" '.error.code' "unauthenticated"
request GET "$ADMIN_HOST" /_authz/apps/
assert_eq "unauthenticated admin UI redirects" "$STATUS" "302"
request GET "$ADMIN_HOST" /_authz/apps
assert_eq "admin URL without slash redirects" "$STATUS" "301"
ADMIN_SLASH_LOCATION=$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/headers")
assert_eq "admin slash redirect stays relative" "$ADMIN_SLASH_LOCATION" "/_authz/apps/"

request GET "$ADMIN_HOST" '/_authz/login?next=%2F%5Cevil.example'
assert_eq "login page rejects backslash redirect target" "$STATUS" "200"
assert_contains "unsafe redirect falls back to admin" "$BODY" 'name="next" value="/_authz/apps/"'
assert_not_contains "unsafe redirect host is not reflected" "$BODY" "evil.example"

request GET "$ADMIN_HOST" '/_authz/oauth/relay/start'
assert_eq "removed OAuth relay endpoint is gone" "$STATUS" "404"

login "$ADMIN_HOST" admin admin123 "$ADMIN_COOKIE"
HTTP_LOGIN_COOKIE=$(awk 'BEGIN { IGNORECASE=1 } /^Set-Cookie:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/^[^;]+/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/login-headers")
assert_not_contains "HTTP session cookie is not Secure" "$HTTP_LOGIN_COOKIE" "; Secure"
LOGIN_COOKIES=$(cat "$TMP_DIR/login-headers")
assert_contains "cookie domain derives from request host" "$LOGIN_COOKIES" "; Domain=.test.example"
assert_contains "login clears legacy host-only session cookie" "$LOGIN_COOKIES" "authz_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
assert_contains "login clears deeper legacy domain cookie" "$LOGIN_COOKIES" "; Domain=.admin.test.example"

# IP 访问 (典型: 新部署的 linux 主机直接用内网 IP 打开管理端):
# 登录响应不得下发 Domain=.<ip> 清理头, 否则浏览器会删除刚写入的 host-only 会话。
IP_LOGIN_HEADERS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -D - -o /dev/null -X POST "http://127.0.0.1:$HTTP_PORT/_authz/login" \
    --data-urlencode 'username=admin' --data-urlencode 'password=admin123')
assert_not_contains "IP login does not clear the new host-only cookie" "$IP_LOGIN_HEADERS" "Domain=.127.0.0.1"
IP_LOGIN_TOKEN=$(printf '%s' "$IP_LOGIN_HEADERS" | grep -oE 'authz_session=[a-f0-9]{64}' | head -1 | cut -d= -f2)
IP_SESSION_STATUS=$(curl -sS --max-time 5 -H "Cookie: authz_session=$IP_LOGIN_TOKEN" \
    -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HTTP_PORT/_authz/api/session")
assert_eq "IP login session survives the redirect" "$IP_SESSION_STATUS" "200"

login "$SECOND_BASE_HOST" admin admin123 "$SECOND_BASE_COOKIE"
SECOND_BASE_ACTIVE_COOKIE=$(awk 'BEGIN { IGNORECASE=1 } /^Set-Cookie:/ { sub(/\r$/, ""); print; exit }' "$TMP_DIR/login-headers")
SECOND_BASE_COOKIES=$(cat "$TMP_DIR/login-headers")
assert_contains "second base domain uses its request-scoped cookie parent" "$SECOND_BASE_ACTIVE_COOKIE" "; Domain=.w.wtvdev.com"
assert_not_contains "configured fallback does not override another base domain" "$SECOND_BASE_ACTIVE_COOKIE" "; Domain=.test.example"
assert_contains "second base login clears its deeper legacy domain" "$SECOND_BASE_COOKIES" "; Domain=.app-m.w.wtvdev.com"
assert_contains "second base login clears its broader legacy parent" "$SECOND_BASE_COOKIES" "; Domain=.wtvdev.com"
for _ in $(seq 1 20); do
    request GET "$ADMIN_HOST" /_authz/api/session "$ADMIN_COOKIE"
    [[ "$STATUS" == "200" ]] && break
    sleep 0.05
done
assert_eq "session becomes available after login" "$STATUS" "200"

DUPLICATE_STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -H "Cookie: authz_session=0000000000000000000000000000000000000000000000000000000000000000; $(cookie_header "$ADMIN_COOKIE")" \
    -D "$TMP_DIR/duplicate-cookie-headers" -o "$TMP_DIR/duplicate-cookie-body" -w '%{http_code}' \
    "http://$ADMIN_HOST:$HTTP_PORT/_authz/api/session")
assert_eq "duplicate session cookies select the valid session" "$DUPLICATE_STATUS" "200"
DUPLICATE_COOKIES=$(cat "$TMP_DIR/duplicate-cookie-headers")
assert_contains "duplicate session cookies are normalized to root domain" "$DUPLICATE_COOKIES" "; Domain=.test.example"
assert_contains "duplicate session cleanup expires host-only cookie" "$DUPLICATE_COOKIES" "authz_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
assert_contains "duplicate session cleanup expires deeper domain" "$DUPLICATE_COOKIES" "; Domain=.admin.test.example"

request GET "$ADMIN_HOST" /_authz/apps/ "$ADMIN_COOKIE"
assert_eq "authenticated admin UI" "$STATUS" "200"
assert_contains_all "admin shell loads SSI menu rendered from the stored tree" "$BODY" \
    "app-frame" \
    "id=\"admin-menu\"" \
    '<span v-if="child.note" class="menu-item-note">{{ child.note }}</span>' \
    'v-for="group in groups"' \
    'v-for="child in (group.children || [])"' \
    ':name="group.icon' \
    '{{ group.label }}' \
    'v-show="groupOpen[group.id]"' \
    'http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate"' \
    'http-equiv="Pragma" content="no-cache"' \
    'http-equiv="Expires" content="0"'
assert_contains_none "admin shell avoids SSI leaks and inline style" "$BODY" \
    '<!--# include virtual="/_authz/apps/menu.html" -->' \
    "<style>" \
    "menu-frame"
assert_not_contains "admin shell has no no-store HTTP header" "$(cat "$TMP_DIR/headers")" "Cache-Control: no-store"
request GET "$ADMIN_HOST" '/_authz/apps/app.css?v=6' "$ADMIN_COOKIE"
assert_eq "admin shared CSS asset" "$STATUS" "200"
assert_contains_all "shared CSS covers menu and mini drawer styles" "$BODY" \
    "#admin-menu .menu-shell" \
    ".admin-drawer-mini #admin-menu"
request GET "$ADMIN_HOST" '/_authz/apps/api.js?v=7' "$ADMIN_COOKIE"
assert_eq "admin API client asset" "$STATUS" "200"
assert_contains_all "admin API client exposes CRUD actions" "$BODY" \
    "/_authz/api" \
    "error.status = response.status" \
    "values.action === 'edit'" \
    'mutation('\''PATCH'\'', `/policies/${values.id}`'
STATIC_STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -H 'Accept-Encoding: gzip' -H "Cookie: $(cookie_header "$ADMIN_COOKIE")" -D "$TMP_DIR/static-headers" \
    -o /dev/null -w '%{http_code}' "http://$ADMIN_HOST:$HTTP_PORT/_authz/apps/api.js?v=7")
assert_eq "admin static asset status" "$STATIC_STATUS" "200"
assert_eq "admin static asset gzip encoding" \
    "$(awk 'BEGIN { IGNORECASE=1 } /^Content-Encoding:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/static-headers")" "gzip"
BR_STATIC_STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -H 'Accept-Encoding: br' -H "Cookie: $(cookie_header "$ADMIN_COOKIE")" -D "$TMP_DIR/br-static-headers" \
    -o /dev/null -w '%{http_code}' "http://$ADMIN_HOST:$HTTP_PORT/_authz/apps/api.js?v=7")
assert_eq "admin static asset Brotli status" "$BR_STATIC_STATUS" "200"
assert_eq "admin static asset Brotli encoding" \
    "$(awk 'BEGIN { IGNORECASE=1 } /^Content-Encoding:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/br-static-headers")" "br"
assert_contains "admin static asset permanent cache" \
    "$(awk 'BEGIN { IGNORECASE=1 } /^Cache-Control:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/static-headers")" "max-age=315360000"
assert_contains "admin static asset expires max" \
    "$(awk 'BEGIN { IGNORECASE=1 } /^Expires:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/static-headers")" "2037"
request GET "$ADMIN_HOST" '/_authz/apps/app.js?v=9' "$ADMIN_COOKIE"
assert_contains_all "app.js renders the stored menu tree" "$BODY" \
    "error?.status === 401" \
    "isAdmin.value = Boolean(session.admin)" \
    "window.adminApi.menuTree()" \
    "setInterval(loadTree, 30000)" \
    'event?.ctrlKey || event?.metaKey' \
    "window.open(url, '_blank', 'noopener,noreferrer')" \
    "authorization.html?v=15" \
    "menuEditor: 'menu-editor.html" \
    "function nodeUrl (node)" \
    "groupOpen[group.id]"
request GET "$ADMIN_HOST" '/_authz/apps/i18n.js?v=26' "$ADMIN_COOKIE"
assert_contains_all "i18n exposes menu group labels and hints" "$BODY" \
    "localApps: '本地服务'" \
    "自动发现的本机 HTTP 端口（未绑定域名）" \
    "Discovered local HTTP ports (no domain binding)" \
    "systemApps: '系统应用'" \
    "menuEditor: '菜单编辑'"
request GET "$ADMIN_HOST" /_authz/apps/menu-editor.html "$ADMIN_COOKIE"
assert_eq "menu editor page loads" "$STATUS" "200"
assert_contains_all "menu editor page edits the tree and offers icon configuration" "$BODY" \
    "const { createApp, computed, onBeforeUnmount, onMounted, reactive, ref } = Vue" \
    'v-model="form.icon"' \
    "iconOptions" \
    "function pickIcon (opt) { form.icon = opt }" \
    'class="icon-picker"' \
    'v-for="group in groups"' \
    'v-for="(child, idx) in group.children"' \
    "openCreateGroup" \
    "window.adminApi.menuEntries()" \
    "window.adminApi.saveMenuEntry" \
    "urlValid" \
    "Quasar.Dialog.create"
request GET "$ADMIN_HOST" /_authz/apps/users.html "$ADMIN_COOKIE"
assert_contains_all "users page has role select, remote rows and timestamps" "$BODY" \
    'multiple use-chips emit-value map-options' \
    "['admin', 'staff', 'user', 'viewer']" \
    "data.remote_users" \
    "restoreRemoteRoles" \
    'v-if="isAdmin" :model-value="props.row.enabled === 1"' \
    "window.adminApi.saveRemoteUser" \
    "t.enabled : t.disabled" \
    "name: 'last_login_at'" \
    "name: 'updated_at'" \
    "second: '2-digit'" \
    "const current = await window.adminApi.session()" \
    "if (!current.admin)"
request GET "$ADMIN_HOST" /_authz/apps/authorization.html "$ADMIN_COOKIE"
assert_not_contains "admin application has no no-store HTTP header" "$(cat "$TMP_DIR/headers")" "Cache-Control: no-store"
assert_contains "admin application declares browser no-cache" "$BODY" 'http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate"'
assert_contains_none "authorization page removes free-form policy input" "$BODY" \
    'v-model="policyForm.ptype"' \
    'roleAssignment' \
    'v-model="policyForm.objectTarget" dark dense outlined use-input' \
    '@new-value="addPolicyObjectTarget"'
assert_contains_all "authorization page policy and binding forms" "$BODY" \
    "reactive({ ptype: 'p'" \
    'policySubjectOptions' \
    'policyObjectOptions' \
    'v-model.trim="policyForm.objectPath"' \
    'v1: policyObjectValue.value' \
    'value: `port:${port}`' \
    'value: `binding:${binding.id}`' \
    'values.binding_id = selected.bindingId' \
    'class="policy-object-target"' \
    "props.row.object_kind === 'shared'" \
    '@click="openEditPolicy(props.row)"' \
    "isAdmin && props.row.ptype === 'p'" \
    'function openEditPolicy (policy)' \
    ':options="httpActions"' \
    'multiple use-chips emit-value map-options :options="httpActions"' \
    'v-model="policyForm.eft" val="allow"' \
    'v-model="policyForm.eft" val="deny"' \
    "'CONNECT'" \
    "'TRACE'" \
    "openEditBinding" \
    "saveBindingForm" \
    "target_ip: '127.0.0.1'" \
    'body-cell-target_ip' \
    'bindingForm.upstream_host' \
    'bindingForm.forwarded_host' \
    'bindingForm.origin_mode' \
    'bindingForm.simulate_local' \
    'bindingForm.upstream_scheme' \
    'bindingForm.upstream_ssl_verify' \
    'bindingForm.upstream_path'
assert_contains "binding form keeps proxy settings compact" "$BODY" 'q-expansion-item v-model="bindingAdvancedOpen"'
request GET "$ADMIN_HOST" /_authz/api/session "$ADMIN_COOKIE"
assert_eq "session API" "$STATUS" "200"
assert_json "session username" '.data.username' "admin"
assert_json "session canonical identity" '.data.identity' "user:local:admin"
assert_json "session admin flag" '.data.admin | tostring' "true"
assert_json "session exposes creation time" '.data.created_at > 0 | tostring' "true"
assert_json "session exposes last login time" '.data.last_login_at > 0 | tostring' "true"
assert_json "session exposes updated time" '.data.updated_at > 0 | tostring' "true"
CSRF=$(jq -er '.data.csrf' "$TMP_DIR/body")
request GET "$ADMIN_HOST" /_authz/api/applications "$ADMIN_COOKIE"
assert_eq "applications API" "$STATUS" "200"
assert_json "applications API returns a list" '.data | type' "array"
assert_json "applications API discovers local HTTP service" ".data | map(select(.port == $UPSTREAM_PORT)) | length" "1"

request GET "$ADMIN_HOST" /_authz/api/api-keys
assert_eq "API key management requires a session" "$STATUS" "401"
request POST "$ADMIN_HOST" /_authz/api/api-keys "$ADMIN_COOKIE" "$CSRF" '{"name":"agent-test"}'
assert_eq "admin creates an API key" "$STATUS" "201"
API_KEY_ID=$(jq -er '.data.id' "$TMP_DIR/body")
API_KEY_TOKEN=$(jq -er '.data.token' "$TMP_DIR/body")
jq '.data.token = "[REDACTED]"' "$TMP_DIR/body" >"$TMP_DIR/body-redacted"
mv "$TMP_DIR/body-redacted" "$TMP_DIR/body"
BODY=$(<"$TMP_DIR/body")
[[ "$API_KEY_TOKEN" =~ ^ak_[a-f0-9]{64}$ ]] || fail "created API key has an invalid format"
pass "raw API key is returned once with a stable format"
assert_json "API key defaults to the api role" '.data.role' "api"

request GET "$ADMIN_HOST" /_authz/api/api-keys "$ADMIN_COOKIE"
assert_eq "admin lists API keys" "$STATUS" "200"
assert_json "API key list never returns raw token" '.data[0] | has("token") | tostring' "false"
assert_json "API key list never returns token hash" '.data[0] | has("token_hash") | tostring' "false"
request POST "$ADMIN_HOST" /_authz/api/api-keys "$ADMIN_COOKIE" "$CSRF" \
    '{"name":"invalid-role-agent","role":"root"}'
assert_eq "unsupported API key role is rejected" "$STATUS" "422"
request GET "$ADMIN_HOST" /_authz/api/session "" "" "" "$API_KEY_TOKEN"
assert_eq "API key reads its service identity" "$STATUS" "200"
assert_json "API key session identifies machine authentication" '.data.auth_type' "api_key"
assert_json "API key session exposes assigned role" '.data.roles | join(",")' "api"
assert_json "api role is not admin" '.data.admin | tostring' "false"
request DELETE "$ADMIN_HOST" /_authz/api/session "" "" "" "$API_KEY_TOKEN"
assert_eq "API key cannot perform browser logout" "$STATUS" "403"
request GET "$ADMIN_HOST" /_authz/api/applications "" "" "" "$API_KEY_TOKEN"
assert_eq "API role can read application entries" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/users "" "" "" "$API_KEY_TOKEN"
assert_eq "API role cannot manage users or roles" "$STATUS" "403"
request POST "$ADMIN_HOST" /_authz/api/policies "" "" '{"ptype":"p","v0":"role:api","v1":"/*","v2":"*"}' "$API_KEY_TOKEN"
assert_eq "API role cannot modify core authorization" "$STATUS" "403"
request GET "$ADMIN_HOST" /_authz/api/api-keys "" "" "" "$API_KEY_TOKEN"
assert_eq "API role cannot manage API keys" "$STATUS" "403"
request GET "$ADMIN_HOST" /_authz/api/session "$ADMIN_COOKIE" "" "" "ak_invalid"
assert_eq "invalid API key never falls back to an admin cookie" "$STATUS" "401"

request POST "$ADMIN_HOST" /_authz/api/applications "" "" \
    "{\"domain\":\"agent.test.example\",\"port\":$UPSTREAM_PORT,\"menu_name\":\"Agent test\"}" "$API_KEY_TOKEN"
assert_eq "API role creates a domain binding without CSRF" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
API_BINDING_ID=$(jq -er '.data.bindings[] | select(.domain == "agent.test.example") | .id' "$TMP_DIR/body")
request GET agent.test.example /identity "" "" "" "$API_KEY_TOKEN"
assert_eq "API key accesses a proxied HTTP service" "$STATUS" "200"
assert_json "upstream receives API key display name" '.user' "agent-test"
assert_json "upstream receives API key source" '.source' "api-key"
assert_json "upstream receives API key principal" ".identity" "api-key:$API_KEY_ID"
assert_json "raw API key is stripped from upstream" '.authz_key == null | tostring' "true"
request POST "$ADMIN_HOST" /_authz/api/policies "$ADMIN_COOKIE" "$CSRF" \
    "{\"ptype\":\"p\",\"v0\":\"role:api\",\"v1\":\"/$UPSTREAM_PORT/blocked\",\"v2\":\"GET\",\"eft\":\"deny\"}"
assert_eq "admin can constrain the API role with a deny policy" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
API_DENY_POLICY_ID=$(jq -er --arg object "/$UPSTREAM_PORT/blocked" \
    '.data.policies[] | select(.v0 == "role:api" and .v1 == $object) | .id' "$TMP_DIR/body")
request GET agent.test.example /blocked "" "" "" "$API_KEY_TOKEN"
assert_eq "API key obeys role:api Casbin deny policy" "$STATUS" "403"
request DELETE "$ADMIN_HOST" "/_authz/api/policies/$API_DENY_POLICY_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "admin removes the API role deny policy" "$STATUS" "200"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$API_BINDING_ID" "" "" \
    '{"menu_name":"forbidden"}' "$API_KEY_TOKEN"
assert_eq "API role cannot modify an existing binding" "$STATUS" "403"

request PATCH "$ADMIN_HOST" "/_authz/api/api-keys/$API_KEY_ID" "$ADMIN_COOKIE" "$CSRF" '{"role":"viewer"}'
assert_eq "admin changes an API key role" "$STATUS" "200"
request GET agent.test.example / "" "" "" "$API_KEY_TOKEN"
assert_eq "viewer API key loses api proxy permission immediately" "$STATUS" "403"
request POST "$ADMIN_HOST" /_authz/api/applications "" "" \
    "{\"domain\":\"viewer-denied.test.example\",\"port\":$UPSTREAM_PORT}" "$API_KEY_TOKEN"
assert_eq "viewer API key cannot create a binding" "$STATUS" "403"
request PATCH "$ADMIN_HOST" "/_authz/api/api-keys/$API_KEY_ID" "$ADMIN_COOKIE" "$CSRF" '{"role":"api"}'
assert_eq "admin restores the API key role" "$STATUS" "200"
request GET agent.test.example / "" "" "" "$API_KEY_TOKEN"
assert_eq "restored api role invalidates proxy authorization cache" "$STATUS" "200"

request PATCH "$ADMIN_HOST" "/_authz/api/api-keys/$API_KEY_ID" "$ADMIN_COOKIE" "$CSRF" '{"enabled":false}'
assert_eq "admin disables an API key" "$STATUS" "200"
request GET agent.test.example /identity "" "" "" "$API_KEY_TOKEN"
assert_eq "disabled API key is rejected immediately" "$STATUS" "401"
request PATCH "$ADMIN_HOST" "/_authz/api/api-keys/$API_KEY_ID" "$ADMIN_COOKIE" "$CSRF" '{"enabled":true}'
assert_eq "admin re-enables an API key" "$STATUS" "200"
request GET agent.test.example / "" "" "" "$API_KEY_TOKEN"
assert_eq "re-enabled API key invalidates authorization cache" "$STATUS" "200"
request DELETE "$ADMIN_HOST" "/_authz/api/api-keys/$API_KEY_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "admin deletes an API key" "$STATUS" "200"
request GET agent.test.example / "" "" "" "$API_KEY_TOKEN"
assert_eq "deleted API key is rejected immediately" "$STATUS" "401"
request DELETE "$ADMIN_HOST" "/_authz/api/applications/$API_BINDING_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "admin removes the API-created binding" "$STATUS" "200"
unset API_KEY_TOKEN

request POST "$ADMIN_HOST" /_authz/api/api-keys "$ADMIN_COOKIE" "$CSRF" \
    '{"name":"admin-agent","role":"admin"}'
assert_eq "admin creates an admin-role API key" "$STATUS" "201"
ADMIN_API_KEY_ID=$(jq -er '.data.id' "$TMP_DIR/body")
ADMIN_API_KEY_TOKEN=$(jq -er '.data.token' "$TMP_DIR/body")
jq '.data.token = "[REDACTED]"' "$TMP_DIR/body" >"$TMP_DIR/body-redacted"
mv "$TMP_DIR/body-redacted" "$TMP_DIR/body"
BODY=$(<"$TMP_DIR/body")
[[ "$ADMIN_API_KEY_TOKEN" =~ ^ak_[a-f0-9]{64}$ ]] || fail "created admin API key has an invalid format"
pass "admin-role API key is returned once"

request GET "$ADMIN_HOST" /_authz/api/session "" "" "" "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key reads its identity" "$STATUS" "200"
assert_json "admin API key exposes admin role" '.data.roles | join(",")' "admin"
assert_json "admin API key exposes admin capability" '.data.admin | tostring' "true"
assert_json "admin API key uses canonical service principal" ".data.identity" "api-key:$ADMIN_API_KEY_ID"
request GET "$ADMIN_HOST" /_authz/api/users "" "" "" "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key reads user management" "$STATUS" "200"
request POST "$ADMIN_HOST" /_authz/api/users "" "" \
    '{"username":"api-managed","password":"password123","roles":["user"]}' "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key creates a user without CSRF" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/users "" "" "" "$ADMIN_API_KEY_TOKEN"
API_MANAGED_USER_ID=$(jq -er '.data.users[] | select(.username == "api-managed") | .id' "$TMP_DIR/body")
request PATCH "$ADMIN_HOST" "/_authz/api/users/$API_MANAGED_USER_ID" "" "" \
    '{"roles":["viewer"]}' "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key updates a user" "$STATUS" "200"
request PUT "$ADMIN_HOST" "/_authz/api/users/$API_MANAGED_USER_ID/password" "" "" \
    '{"password":"password456"}' "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key resets a user password" "$STATUS" "200"
request DELETE "$ADMIN_HOST" "/_authz/api/users/$API_MANAGED_USER_ID" "" "" "" "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key deletes a user" "$STATUS" "200"

request POST "$ADMIN_HOST" /_authz/api/applications "" "" \
    "{\"domain\":\"admin-agent.test.example\",\"port\":$UPSTREAM_PORT}" "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key creates a binding" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/authorization "" "" "" "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key reads core authorization" "$STATUS" "200"
ADMIN_API_BINDING_ID=$(jq -er '.data.bindings[] | select(.domain == "admin-agent.test.example") | .id' "$TMP_DIR/body")
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$ADMIN_API_BINDING_ID" "" "" \
    '{"menu_name":"Admin agent"}' "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key updates a binding" "$STATUS" "200"
request GET admin-agent.test.example /identity "" "" "" "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key accesses proxy targets through role:admin" "$STATUS" "200"
request POST "$ADMIN_HOST" /_authz/api/policies "" "" \
    "{\"ptype\":\"p\",\"v0\":\"role:viewer\",\"v1\":\"/$UPSTREAM_PORT/admin-agent\",\"v2\":\"GET\",\"eft\":\"allow\"}" "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key creates an authorization policy" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/authorization "" "" "" "$ADMIN_API_KEY_TOKEN"
ADMIN_API_POLICY_ID=$(jq -er --arg object "/$UPSTREAM_PORT/admin-agent" \
    '.data.policies[] | select(.v0 == "role:viewer" and .v1 == $object) | .id' "$TMP_DIR/body")
request DELETE "$ADMIN_HOST" "/_authz/api/policies/$ADMIN_API_POLICY_ID" "" "" "" "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key deletes an authorization policy" "$STATUS" "200"
request DELETE "$ADMIN_HOST" "/_authz/api/applications/$ADMIN_API_BINDING_ID" "" "" "" "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key deletes a binding" "$STATUS" "200"

request POST "$ADMIN_HOST" /_authz/api/api-keys "" "" \
    '{"name":"viewer-agent","role":"viewer"}' "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key creates another role-scoped key" "$STATUS" "201"
VIEWER_API_KEY_ID=$(jq -er '.data.id' "$TMP_DIR/body")
VIEWER_API_KEY_TOKEN=$(jq -er '.data.token' "$TMP_DIR/body")
jq '.data.token = "[REDACTED]"' "$TMP_DIR/body" >"$TMP_DIR/body-redacted"
mv "$TMP_DIR/body-redacted" "$TMP_DIR/body"
BODY=$(<"$TMP_DIR/body")
request GET "$ADMIN_HOST" /_authz/api/session "" "" "" "$VIEWER_API_KEY_TOKEN"
assert_json "viewer API key receives viewer role" '.data.roles | join(",")' "viewer"
request GET "$ADMIN_HOST" /_authz/api/users "" "" "" "$VIEWER_API_KEY_TOKEN"
assert_eq "viewer API key cannot use admin APIs" "$STATUS" "403"
request PATCH "$ADMIN_HOST" "/_authz/api/api-keys/$VIEWER_API_KEY_ID" "" "" \
    '{"role":"user"}' "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key changes another key role" "$STATUS" "200"
request PATCH "$ADMIN_HOST" "/_authz/api/api-keys/$VIEWER_API_KEY_ID" "" "" \
    '{"role":"root"}' "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key cannot assign an unknown role" "$STATUS" "422"
request GET "$ADMIN_HOST" /_authz/api/session "" "" "" "$VIEWER_API_KEY_TOKEN"
assert_json "API key role update is immediately visible" '.data.roles | join(",")' "user"
request DELETE "$ADMIN_HOST" "/_authz/api/api-keys/$VIEWER_API_KEY_ID" "" "" "" "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key deletes another key" "$STATUS" "200"
unset VIEWER_API_KEY_TOKEN

request PUT "$ADMIN_HOST" /_authz/api/me/password "" "" \
    '{"old_password":"ignored","new_password":"ignored"}' "$ADMIN_API_KEY_TOKEN"
assert_eq "API key cannot use personal password endpoint" "$STATUS" "403"
request DELETE "$ADMIN_HOST" "/_authz/api/api-keys/$ADMIN_API_KEY_ID" "" "" "" "$ADMIN_API_KEY_TOKEN"
assert_eq "admin API key can revoke itself" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/users "" "" "" "$ADMIN_API_KEY_TOKEN"
assert_eq "self-revoked admin API key is rejected" "$STATUS" "401"
unset ADMIN_API_KEY_TOKEN

request GET "$ADMIN_HOST" '/_authz/login?next=/_authz/apps/'
assert_eq "login page with OAuth provider" "$STATUS" "200"
assert_contains "login page disables browser cache" "$(cat "$TMP_DIR/headers")" "Cache-Control: no-store"
assert_contains_all "login page shows providers, source select and two-column layout" "$BODY" \
    "Test Identity" \
    'name="source"' \
    'width:min(720px' \
    'grid-template-columns:1fr 1fr' \
    'grid-template-columns:repeat(2,minmax(0,1fr))' \
    'class="oauth brand-nocobase"' \
    'class="oauth brand-google disabled"' \
    'class="oauth brand-dingtalk"' \
    'class="oauth brand-wechat"' \
    'class="brand-icon"'
assert_not_contains "OAuth buttons remove action wording" "$BODY" "使用 NocoBase 登录"
STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -D "$TMP_DIR/headers" -o /dev/null -w '%{http_code}' -X POST \
    "http://$ADMIN_HOST:$HTTP_PORT/_authz/login" \
    --data-urlencode 'username=invalid-user' --data-urlencode 'password=invalid-password' \
    --data-urlencode 'source=local' --data-urlencode 'next=/_authz/apps/')
assert_eq "invalid login redirects" "$STATUS" "302"
LOGIN_ERROR_LOCATION=$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/headers")
request GET "$ADMIN_HOST" "$LOGIN_ERROR_LOCATION"
assert_contains "login error is decoded UTF-8" "$BODY" "用户名或密码错误"
assert_contains "login return path is decoded" "$BODY" 'name="next" value="/_authz/apps/"'
if [[ "$BODY" == *'%E7%94%A8%E6%88%B7'* ]]; then fail "login error must not expose percent encoding"; fi
pass "login error hides percent encoding"
request GET "$ADMIN_HOST" '/_authz/oauth/start?provider=testid&next=/_authz/apps/'
assert_eq "OAuth start redirects to provider" "$STATUS" "302"
OAUTH_AUTHORIZE_URL=$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/headers")
assert_contains "OAuth start uses PKCE" "$OAUTH_AUTHORIZE_URL" "code_challenge_method=S256"
OAUTH_CALLBACK_URL=$(curl -sS --max-time 5 -D - -o /dev/null "$OAUTH_AUTHORIZE_URL" | awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }')
OAUTH_CALLBACK_PATH=$(python3 - "$OAUTH_CALLBACK_URL" <<'PY'
import sys
from urllib.parse import urlsplit

value = urlsplit(sys.argv[1])
print(value.path + ("?" + value.query if value.query else ""))
PY
)
STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -D "$TMP_DIR/headers" -o /dev/null -w '%{http_code}' \
    "http://$ADMIN_HOST:$HTTP_PORT$OAUTH_CALLBACK_PATH")
assert_eq "OAuth callback creates local session" "$STATUS" "302"
save_session_cookie "$TMP_DIR/headers" "$OAUTH_COOKIE"
request GET "$ADMIN_HOST" /_authz/api/session "$OAUTH_COOKIE"
assert_eq "OAuth session API" "$STATUS" "200"
assert_json "OAuth session source" '.data.source' "testid"
assert_json "OAuth canonical identity" '.data.identity' "user:testid:oauth.user@example.test"
assert_json "OAuth userinfo username" '.data.username' "oauth.user@example.test"
assert_json "OAuth claim maps local role" '.data.roles | join(",")' "staff"
OAUTH_TOKEN_ATTEMPTS=$(curl -fsS --max-time 5 \
    "http://127.0.0.1:$NOCO_PORT/test/oauth-token-attempts" | jq -r '.attempts')
assert_eq "OAuth retries first transport failure" "$OAUTH_TOKEN_ATTEMPTS" "2"
STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -o /dev/null -w '%{http_code}' "http://$ADMIN_HOST:$HTTP_PORT$OAUTH_CALLBACK_PATH")
assert_eq "OAuth callback replay is rejected" "$STATUS" "302"
request GET "$ADMIN_HOST" /_authz/api/session
assert_eq "replayed OAuth callback creates no session" "$STATUS" "401"

request GET "$ADMIN_HOST" '/_authz/oauth/start?provider=nocobase&next=/_authz/apps/'
assert_eq "NocoBase OAuth start redirects to provider" "$STATUS" "302"
assert_contains "NocoBase OAuth start disables browser cache" "$(cat "$TMP_DIR/headers")" "Cache-Control: no-store"
NOCO_OAUTH_AUTHORIZE_URL=$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/headers")
assert_contains "NocoBase OAuth uses PKCE" "$NOCO_OAUTH_AUTHORIZE_URL" "code_challenge_method=S256"
assert_contains "NocoBase OAuth requests API scope" "$NOCO_OAUTH_AUTHORIZE_URL" "api"
assert_not_contains "NocoBase OAuth omits obsolete resource" "$NOCO_OAUTH_AUTHORIZE_URL" "resource="
NOCO_OAUTH_CALLBACK_URL=$(curl -sS --max-time 5 -D - -o /dev/null "$NOCO_OAUTH_AUTHORIZE_URL" | awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }')
assert_contains "NocoBase OAuth callback includes issuer" "$NOCO_OAUTH_CALLBACK_URL" "iss="
NOCO_OAUTH_CALLBACK_PATH=$(python3 - "$NOCO_OAUTH_CALLBACK_URL" <<'PY'
import sys
from urllib.parse import urlsplit
value = urlsplit(sys.argv[1])
print(value.path + "?" + value.query)
PY
)
STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -D "$TMP_DIR/headers" -o /dev/null -w '%{http_code}' \
    "http://$ADMIN_HOST:$HTTP_PORT$NOCO_OAUTH_CALLBACK_PATH")
assert_eq "NocoBase OAuth callback creates session" "$STATUS" "302"
assert_contains "NocoBase OAuth callback disables browser cache" "$(cat "$TMP_DIR/headers")" "Cache-Control: no-store"
save_session_cookie "$TMP_DIR/headers" "$NOCO_OAUTH_COOKIE"
request GET "$ADMIN_HOST" /_authz/api/session "$NOCO_OAUTH_COOKIE"
assert_eq "NocoBase OAuth session API" "$STATUS" "200"
assert_json "NocoBase OAuth shares source" '.data.source' "nocobase"
assert_json "NocoBase OAuth username" '.data.username' "remote_user"
assert_json "NocoBase OAuth uses local default role" '.data.roles | join(",")' "viewer"

request GET "$ADMIN_HOST" '/_authz/oauth/start?provider=nocobase&next=/_authz/apps/'
assert_eq "second NocoBase OAuth start" "$STATUS" "302"
NOCO_SECOND_AUTHORIZE_URL=$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/headers")
NOCO_SECOND_CALLBACK_URL=$(curl -sS --max-time 5 -D - -o /dev/null "$NOCO_SECOND_AUTHORIZE_URL" | awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }')
NOCO_SECOND_CALLBACK_PATH=$(python3 - "$NOCO_SECOND_CALLBACK_URL" <<'PY'
import sys
from urllib.parse import urlsplit
value = urlsplit(sys.argv[1])
print(value.path + "?" + value.query)
PY
)
STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -D "$TMP_DIR/headers" -o /dev/null -w '%{http_code}' \
    "http://$ADMIN_HOST:$HTTP_PORT$NOCO_SECOND_CALLBACK_PATH")
assert_eq "second NocoBase OAuth callback succeeds" "$STATUS" "302"
assert_eq "second NocoBase OAuth skips stale login error" \
    "$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/headers")" \
    "/_authz/apps/"
save_session_cookie "$TMP_DIR/headers" "$NOCO_OAUTH_SECOND_COOKIE"
request GET "$ADMIN_HOST" /_authz/api/session "$NOCO_OAUTH_SECOND_COOKIE"
assert_eq "second NocoBase OAuth creates session" "$STATUS" "200"
assert_json "second NocoBase OAuth keeps source" '.data.source' "nocobase"

request GET "$ADMIN_HOST" '/_authz/oauth/start?provider=nocobase&next=/_authz/apps/'
NOCO_BAD_ISSUER_AUTHORIZE_URL=$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/headers")
NOCO_BAD_ISSUER_CALLBACK_URL=$(curl -sS --max-time 5 -D - -o /dev/null "$NOCO_BAD_ISSUER_AUTHORIZE_URL" | awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }')
NOCO_BAD_ISSUER_CALLBACK_PATH=$(python3 - "$NOCO_BAD_ISSUER_CALLBACK_URL" <<'PY'
import sys
from urllib.parse import parse_qsl, urlencode, urlsplit

value = urlsplit(sys.argv[1])
query = dict(parse_qsl(value.query, keep_blank_values=True))
query["iss"] = "https://attacker.example/api"
print(value.path + "?" + urlencode(query))
PY
)
STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -c "$NOCO_BAD_ISSUER_COOKIE" -o /dev/null -w '%{http_code}' \
    "http://$ADMIN_HOST:$HTTP_PORT$NOCO_BAD_ISSUER_CALLBACK_PATH")
assert_eq "NocoBase OAuth rejects mismatched issuer" "$STATUS" "302"
request GET "$ADMIN_HOST" /_authz/api/session "$NOCO_BAD_ISSUER_COOKIE"
assert_eq "mismatched NocoBase issuer creates no session" "$STATUS" "401"

request GET "$ADMIN_HOST" '/_authz/oauth/start?provider=dingtalk&next=/_authz/apps/'
assert_eq "DingTalk start redirects to provider" "$STATUS" "302"
DINGTALK_AUTHORIZE_URL=$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/headers")
assert_contains "DingTalk authorization scope" "$DINGTALK_AUTHORIZE_URL" "scope=openid"
DINGTALK_CALLBACK_URL=$(curl -sS --max-time 5 -D - -o /dev/null "$DINGTALK_AUTHORIZE_URL" | awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }')
DINGTALK_CALLBACK_PATH=$(python3 - "$DINGTALK_CALLBACK_URL" <<'PY'
import sys
from urllib.parse import urlsplit
value = urlsplit(sys.argv[1])
print(value.path + "?" + value.query)
PY
)
STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -D "$TMP_DIR/headers" -o /dev/null -w '%{http_code}' \
    "http://$ADMIN_HOST:$HTTP_PORT$DINGTALK_CALLBACK_PATH")
assert_eq "DingTalk callback creates session" "$STATUS" "302"
save_session_cookie "$TMP_DIR/headers" "$DINGTALK_COOKIE"
request GET "$ADMIN_HOST" /_authz/api/session "$DINGTALK_COOKIE"
assert_json "DingTalk session source" '.data.source' "dingtalk"
assert_json "DingTalk missing email uses stable username" '.data.username | startswith("dingtalk_") | tostring' "true"
assert_json "DingTalk default role" '.data.roles | join(",")' "viewer"
request GET "$ADMIN_HOST" /_authz/api/authorization "$DINGTALK_COOKIE"
assert_eq "remote viewer authorization API denied" "$STATUS" "403"

request GET "$ADMIN_HOST" '/_authz/oauth/start?provider=wechat&next=/_authz/apps/'
assert_eq "WeChat start redirects to provider" "$STATUS" "302"
WECHAT_AUTHORIZE_URL=$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/headers")
assert_contains "WeChat website login scope" "$WECHAT_AUTHORIZE_URL" "scope=snsapi_login"
assert_contains "WeChat authorization fragment" "$WECHAT_AUTHORIZE_URL" "#wechat_redirect"
WECHAT_CALLBACK_URL=$(curl -sS --max-time 5 -D - -o /dev/null "$WECHAT_AUTHORIZE_URL" | awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }')
WECHAT_CALLBACK_PATH=$(python3 - "$WECHAT_CALLBACK_URL" <<'PY'
import sys
from urllib.parse import urlsplit
value = urlsplit(sys.argv[1])
print(value.path + "?" + value.query)
PY
)
STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -D "$TMP_DIR/headers" -o /dev/null -w '%{http_code}' \
    "http://$ADMIN_HOST:$HTTP_PORT$WECHAT_CALLBACK_PATH")
assert_eq "WeChat callback creates session" "$STATUS" "302"
save_session_cookie "$TMP_DIR/headers" "$WECHAT_COOKIE"
request GET "$ADMIN_HOST" /_authz/api/session "$WECHAT_COOKIE"
assert_json "WeChat session source" '.data.source' "wechat"
assert_json "WeChat identity uses stable username" '.data.username | startswith("wechat_") | tostring' "true"
assert_json "WeChat default role" '.data.roles | join(",")' "viewer"

request GET "$ADMIN_HOST" /_authz/api/users "$ADMIN_COOKIE"
assert_eq "users API" "$STATUS" "200"
assert_json "seeded admin user" '.data.users[0].username' "admin"
assert_json "fixed role catalog" '.data.available_roles | join(",")' "admin,staff,user,viewer"

request POST "$ADMIN_HOST" /_authz/api/users "$ADMIN_COOKIE" "" '{"username":"bob","password":"bob123456","roles":"user"}'
assert_eq "mutation without CSRF" "$STATUS" "403"
assert_json "CSRF error code" '.error.code' "csrf_failed"

request POST "$ADMIN_HOST" /_authz/api/users "$ADMIN_COOKIE" "$CSRF" '{bad-json'
assert_eq "invalid JSON body" "$STATUS" "400"
assert_json "invalid JSON error code" '.error.code' "invalid_body"

request POST "$ADMIN_HOST" /_authz/api/users "$ADMIN_COOKIE" "$CSRF" '{"username":"invalid-role","password":"password123","roles":["auditor"]}'
assert_eq "unknown user role rejected" "$STATUS" "422"
request POST "$ADMIN_HOST" /_authz/api/users "$ADMIN_COOKIE" "$CSRF" '{"username":"api-human","password":"password123","roles":["api"]}'
assert_eq "api role cannot be assigned to a human user" "$STATUS" "422"

request POST "$ADMIN_HOST" /_authz/api/users "$ADMIN_COOKIE" "$CSRF" '{"username":"bob","password":"bob123456","roles":["user"]}'
assert_eq "create user" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/users "$ADMIN_COOKIE"
BOB_ID=$(jq -er '.data.users[] | select(.username == "bob") | .id' "$TMP_DIR/body")
[[ -n "$BOB_ID" ]] || fail "created user not found"
pass "created user appears in list"
assert_json "cached user list starts with original role" '.data.users[] | select(.username == "bob") | .roles' "user"
assert_json "new user exposes nullable last login field" '.data.users[] | select(.username == "bob") | has("last_login_at") | tostring' "true"
assert_json "new user has no login time before first login" '.data.users[] | select(.username == "bob") | .last_login_at == null | tostring' "true"
assert_json "columns after null remain readable" '.data.users[] | select(.username == "bob") | .updated_at == .created_at | tostring' "true"

request POST "$ADMIN_HOST" /_authz/api/policies "$ADMIN_COOKIE" "$CSRF" \
    '{"ptype":"p","v0":"user:local:bob","v1":"/2999/transaction-test","v2":"GET","eft":"allow"}'
assert_eq "create policy used by transaction rollback test" "$STATUS" "201"
python3 - "$TMP_DIR/data/authz/authz.db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute("""CREATE TRIGGER fail_bob_policy_delete
    BEFORE DELETE ON policies
    WHEN OLD.v0 = 'user:local:bob'
    BEGIN SELECT RAISE(ABORT, 'forced transaction rollback'); END""")
connection.commit()
connection.close()
PY
request DELETE "$ADMIN_HOST" "/_authz/api/users/$BOB_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "multi-step delete reports the forced database failure" "$STATUS" "500"
python3 - "$TMP_DIR/data/authz/authz.db" <<'PY'
import sqlite3
import sys

connection = sqlite3.connect(sys.argv[1])
connection.execute("DROP TRIGGER fail_bob_policy_delete")
connection.commit()
connection.close()
PY
ROLLBACK_COOKIE="$TMP_DIR/rollback.cookie"
login "$ADMIN_HOST" bob bob123456 "$ROLLBACK_COOKIE"
request GET "$ADMIN_HOST" /_authz/api/session "$ROLLBACK_COOKIE"
assert_eq "failed multi-step delete rolls the user deletion back" "$STATUS" "200"

request PATCH "$ADMIN_HOST" "/_authz/api/users/$BOB_ID" "$ADMIN_COOKIE" "$CSRF" '{"roles":["staff","user"]}'
assert_eq "update user roles" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/users "$ADMIN_COOKIE"
assert_json "cached user list invalidates after write" '.data.users[] | select(.username == "bob") | .roles' "staff,user"
request PUT "$ADMIN_HOST" "/_authz/api/users/$BOB_ID/password" "$ADMIN_COOKIE" "$CSRF" '{"password":"bob654321"}'
assert_eq "reset user password" "$STATUS" "200"

login "$ADMIN_HOST" bob bob654321 "$BOB_COOKIE"
request GET "$ADMIN_HOST" /_authz/api/session "$BOB_COOKIE"
assert_eq "non-admin can read own session profile" "$STATUS" "200"
assert_json "non-admin own identity" '.data.identity' "user:local:bob"
BOB_CSRF=$(jq -er '.data.csrf' "$TMP_DIR/body")
login "$DYNAMIC_HOST" bob bob654321 "$DYNAMIC_COOKIE"
request PUT "$ADMIN_HOST" /_authz/api/me/password "$BOB_COOKIE" "$BOB_CSRF" \
    '{"oldpw":"bob654321","newpw":"changed123","newpw_confirm":"different123"}'
assert_eq "mismatched password confirmation rejected" "$STATUS" "422"
assert_json "password mismatch error" '.error.message' "两次输入的新密码不一致"
request PUT "$ADMIN_HOST" /_authz/api/me/password "$BOB_COOKIE" "$BOB_CSRF" \
    '{"oldpw":"bob654321","newpw":"changed123","newpw_confirm":"changed123"}'
assert_eq "password change succeeds with matching confirmation" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/session "$BOB_COOKIE"
assert_eq "password change invalidates current session" "$STATUS" "401"
request GET "$DYNAMIC_HOST" /_authz/api/session "$DYNAMIC_COOKIE"
assert_eq "password change invalidates other sessions" "$STATUS" "401"
login "$ADMIN_HOST" bob changed123 "$BOB_COOKIE"
request GET "$ADMIN_HOST" /_authz/api/users "$BOB_COOKIE"
assert_eq "non-admin users API denied" "$STATUS" "403"
request GET "$ADMIN_HOST" /_authz/api/authorization "$BOB_COOKIE"
assert_eq "non-admin authorization API denied" "$STATUS" "403"

login "$DYNAMIC_HOST" bob changed123 "$DYNAMIC_COOKIE"
request GET "$DYNAMIC_HOST" / "$DYNAMIC_COOKIE"
assert_eq "default deny for ordinary user" "$STATUS" "403"
request GET "$DYNAMIC_HOST" '/%3Cscript%3Ealert(1)%3C/script%3E' "$DYNAMIC_COOKIE"
assert_eq "forbidden page keeps real 403 status" "$STATUS" "403"
assert_not_contains "forbidden page does not render injected script" "$BODY" "<script>"
assert_contains "forbidden page escapes denied object" "$BODY" "&lt;script&gt;"

login "$ADMIN_HOST" remote@example.test remote123 "$REMOTE_COOKIE" nocobase
request GET "$ADMIN_HOST" /_authz/api/session "$REMOTE_COOKIE"
assert_eq "remote NocoBase session" "$STATUS" "200"
assert_json "remote session source" '.data.source' "nocobase"
assert_json "remote username comes from NocoBase" '.data.username' "remote_user"
assert_json "remote canonical identity" '.data.identity' "user:nocobase:remote_user"
assert_json "remote roles map to local catalog" '.data.roles | join(",")' "staff,user"
REMOTE_CSRF=$(jq -er '.data.csrf' "$TMP_DIR/body")
request PUT "$ADMIN_HOST" /_authz/api/me/password "$REMOTE_COOKIE" "$REMOTE_CSRF" '{"old_password":"remote123","new_password":"changed123"}'
assert_eq "remote password changes stay in NocoBase" "$STATUS" "409"

request GET "$ADMIN_HOST" /_authz/api/users "$ADMIN_COOKIE"
assert_json "remote user appears in management" '.data.remote_users[] | select(.username == "remote_user") | .provider' "nocobase"
assert_json "remote identity exposes record and lifecycle timestamps" '.data.remote_users[] | select(.username == "remote_user") | (.recorded_at > 0 and .created_at > 0 and .last_login_at > 0 and .updated_at > 0 and .synced_at == null) | tostring' "true"
assert_json "remote management row exposes canonical identity" '.data.remote_users[] | select(.username == "remote_user") | .identity' "user:nocobase:remote_user"
assert_json "recorded remote roles are exposed" '.data.remote_users[] | select(.username == "remote_user") | .remote_roles' "staff,user"
assert_json "local management row exposes identity and timestamps" '.data.users[] | select(.username == "bob") | (.identity == "user:local:bob" and .created_at > 0 and .last_login_at > 0 and .updated_at > 0) | tostring' "true"
request PATCH "$ADMIN_HOST" /_authz/api/remote-users/nocobase "$ADMIN_COOKIE" "$CSRF" '{"subject":"42","roles":["viewer"]}'
assert_eq "admin overrides remote roles" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/session "$REMOTE_COOKIE"
assert_json "remote session sees role override immediately" '.data.roles | join(",")' "viewer"
login "$ADMIN_HOST" remote@example.test remote123 "$REMOTE_COOKIE" nocobase
request GET "$ADMIN_HOST" /_authz/api/session "$REMOTE_COOKIE"
assert_json "remote login preserves local role override" '.data.roles | join(",")' "viewer"
request GET "$ADMIN_HOST" /_authz/api/users "$ADMIN_COOKIE"
assert_json "remote override flag is visible" '.data.remote_users[] | select(.username == "remote_user") | .roles_overridden | tostring' "1"
assert_json "next login refreshes recorded remote roles" '.data.remote_users[] | select(.username == "remote_user") | .remote_roles' "staff,user"
request PATCH "$ADMIN_HOST" /_authz/api/remote-users/nocobase "$ADMIN_COOKIE" "$CSRF" '{"subject":"42","use_remote_roles":true}'
assert_eq "admin restores recorded remote roles" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/session "$REMOTE_COOKIE"
assert_json "restored remote roles apply immediately" '.data.roles | join(",")' "staff,user"

request PATCH "$ADMIN_HOST" /_authz/api/remote-users/nocobase "$ADMIN_COOKIE" "$CSRF" '{"subject":"42","enabled":false}'
assert_eq "admin disables remote identity" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/session "$REMOTE_COOKIE"
assert_eq "disabled remote identity session revoked" "$STATUS" "401"
login "$ADMIN_HOST" remote@example.test remote123 "$REMOTE_COOKIE" nocobase false
request GET "$ADMIN_HOST" /_authz/api/session "$REMOTE_COOKIE"
assert_eq "disabled remote identity cannot sign in again" "$STATUS" "401"
request GET "$ADMIN_HOST" /_authz/api/users "$ADMIN_COOKIE"
assert_json "remote authentication preserves disabled state" '.data.remote_users[] | select(.provider == "nocobase" and .subject == "42") | .enabled | tostring' "0"
request PATCH "$ADMIN_HOST" /_authz/api/remote-users/nocobase "$ADMIN_COOKIE" "$CSRF" '{"subject":"42","enabled":true}'
assert_eq "admin enables remote identity" "$STATUS" "200"
login "$ADMIN_HOST" remote@example.test remote123 "$REMOTE_COOKIE" nocobase
request GET "$ADMIN_HOST" /_authz/api/session "$REMOTE_COOKIE"
assert_eq "enabled remote identity can sign in" "$STATUS" "200"

login "$ADMIN_HOST" shadow@example.test remote123 "$SHADOW_COOKIE" nocobase
request GET "$ADMIN_HOST" /_authz/api/session "$SHADOW_COOKIE"
assert_eq "same username from NocoBase gets a session" "$STATUS" "200"
assert_json "same username keeps remote source" '.data.source' "nocobase"
assert_json "same username keeps remote canonical identity" '.data.identity' "user:nocobase:bob"
assert_json "same username keeps source-specific roles" '.data.roles | join(",")' "viewer"
login "$DYNAMIC_HOST" shadow@example.test remote123 "$SHADOW_DYNAMIC_COOKIE" nocobase
request GET "$DYNAMIC_HOST" / "$SHADOW_DYNAMIC_COOKIE"
assert_eq "remote same-name identity denied before direct policy" "$STATUS" "403"

request POST "$ADMIN_HOST" /_authz/api/policies "$ADMIN_COOKIE" "$CSRF" "{\"ptype\":\"p\",\"v0\":\"user:nocobase:bob\",\"v1\":\"$POLICY_OBJECT\",\"v2\":[\"GET\"],\"eft\":\"allow\"}"
assert_eq "create source-specific user policy" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
SOURCE_POLICY_ID=$(jq -er --arg object "$POLICY_OBJECT" '.data.policies[] | select(.v0 == "user:nocobase:bob" and .v1 == $object) | .id' "$TMP_DIR/body")
request GET "$DYNAMIC_HOST" / "$SHADOW_DYNAMIC_COOKIE"
assert_eq "direct policy authorizes matching remote identity" "$STATUS" "200"
request GET "$DYNAMIC_HOST" / "$DYNAMIC_COOKIE"
assert_eq "direct remote policy does not authorize local same-name identity" "$STATUS" "403"
request DELETE "$ADMIN_HOST" "/_authz/api/policies/$SOURCE_POLICY_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "delete source-specific user policy" "$STATUS" "200"

request POST "$ADMIN_HOST" /_authz/api/policies "$ADMIN_COOKIE" "$CSRF" "{\"ptype\":\"p\",\"v0\":\"role:user\",\"v1\":\"$POLICY_OBJECT\",\"v2\":[\"POST\",\"GET\"],\"eft\":\"allow\"}"
assert_eq "create access policy" "$STATUS" "201"
CUSTOM_PATH_OBJECT="/$UPSTREAM_PORT/api/*"
request POST "$ADMIN_HOST" /_authz/api/policies "$ADMIN_COOKIE" "$CSRF" "{\"ptype\":\"p\",\"v0\":\"role:viewer\",\"v1\":\"$CUSTOM_PATH_OBJECT\",\"v2\":[\"GET\"],\"eft\":\"allow\"}"
assert_eq "create access policy with an editable binding path" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
assert_json "custom binding path is stored as the final policy object" ".data.policies[] | select(.v0 == \"role:viewer\" and .v1 == \"$CUSTOM_PATH_OBJECT\") | .v1" "$CUSTOM_PATH_OBJECT"
CUSTOM_PATH_POLICY_ID=$(jq -er --arg object "$CUSTOM_PATH_OBJECT" '.data.policies[] | select(.v0 == "role:viewer" and .v1 == $object) | .id' "$TMP_DIR/body")
request DELETE "$ADMIN_HOST" "/_authz/api/policies/$CUSTOM_PATH_POLICY_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "delete custom binding path policy" "$STATUS" "200"
request POST "$ADMIN_HOST" /_authz/api/policies "$ADMIN_COOKIE" "$CSRF" "{\"ptype\":\"p\",\"v0\":\"role:user\",\"v1\":\"$POLICY_OBJECT\",\"v2\":[\"GET\",\"BREW\"],\"eft\":\"allow\"}"
assert_eq "unknown HTTP method rejected" "$STATUS" "422"
request POST "$ADMIN_HOST" /_authz/api/policies "$ADMIN_COOKIE" "$CSRF" "{\"ptype\":\"p\",\"v0\":\"role:auditor\",\"v1\":\"$POLICY_OBJECT\",\"v2\":\"GET\",\"eft\":\"allow\"}"
assert_eq "unknown policy role rejected" "$STATUS" "422"
request POST "$ADMIN_HOST" /_authz/api/policies "$ADMIN_COOKIE" "$CSRF" '{"ptype":"p","v0":"role:user","v1":"/not-a-port/public/*","v2":"GET","eft":"allow"}'
assert_eq "malformed policy object is rejected" "$STATUS" "422"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
assert_eq "authorization API" "$STATUS" "200"
assert_json "minimum dynamic port clamped" '.data.port_min | tostring' "2000"
assert_json "local user policy identity option" '.data.policy_users[] | select(.username == "admin" and .source == "local") | .identity' "user:local:admin"
assert_json "policy role options" '.data.policy_roles | index("user") != null | tostring' "true"
assert_json "policy role catalog includes service api role" '.data.policy_roles | join(",")' "admin,staff,user,viewer,api"
assert_json "remote identity is a policy subject" '.data.policy_users[] | select(.username == "remote_user" and .source == "nocobase") | .identity' "user:nocobase:remote_user"
assert_json "local same-name identity is listed separately" '.data.policy_users[] | select(.username == "bob" and .source == "local") | .identity' "user:local:bob"
assert_json "remote same-name identity is listed separately" '.data.policy_users[] | select(.username == "bob" and .source == "nocobase") | .identity' "user:nocobase:bob"
assert_json "HTTP method catalog includes CONNECT" '.data.http_methods | index("CONNECT") != null | tostring' "true"
assert_json "HTTP method catalog includes TRACE" '.data.http_methods | index("TRACE") != null | tostring' "true"
assert_json "multi-method policy normalized" ".data.policies[] | select(.v0 == \"role:user\" and .v1 == \"$POLICY_OBJECT\") | .action" "GET,POST"
POLICY_ID=$(jq -er --arg object "$POLICY_OBJECT" '.data.policies[] | select(.v0 == "role:user" and .v1 == $object) | .id' "$TMP_DIR/body")

request GET "$DYNAMIC_HOST" / "$DYNAMIC_COOKIE"
assert_eq "dynamic port allowed by policy" "$STATUS" "200"
assert_eq "dynamic proxy body" "$BODY" "$MOCK_BODY"
request GET "$ADMIN_HOST" /_authz/api/applications "$ADMIN_COOKIE"
assert_json "HTTP service discovery finds mock port" ".data[] | select(.port == $UPSTREAM_PORT and .source == \"127.0.0.1\") | .port | tostring" "$UPSTREAM_PORT"
request POST "$DYNAMIC_HOST" / "$DYNAMIC_COOKIE"
assert_eq "second selected method allowed" "$STATUS" "200"
assert_eq "multi-method proxy body" "$BODY" "$MOCK_BODY"
request GET "$DYNAMIC_HOST" /identity "$DYNAMIC_COOKIE"
assert_json "upstream receives raw username" '.user' "bob"
assert_json "upstream receives identity source" '.source' "local"
assert_json "upstream receives canonical identity" '.identity' "user:local:bob"
assert_json "dynamic port access defaults to simulate-local Host" '.host' "127.0.0.1:$UPSTREAM_PORT"
assert_json "dynamic port access defaults to simulate-local forwarded host" '.forwarded_host' "127.0.0.1:$UPSTREAM_PORT"
assert_json "dynamic port access defaults to http forwarded proto" '.forwarded_proto' "http"
assert_json "dynamic port access defaults to local real IP" '.real_ip' "127.0.0.1"
assert_json "dynamic port access defaults to local forwarded-for" '.forwarded_for' "127.0.0.1"
assert_json "dynamic port access drops client Forwarded header" '.forwarded | tostring' "null"
AUTHZ_COOKIE_HEADER=$(cookie_header "$DYNAMIC_COOKIE")
STATUS=$(curl -sS --max-time 5 --resolve "$DYNAMIC_HOST:$HTTP_PORT:127.0.0.1" \
    -H "Cookie: $AUTHZ_COOKIE_HEADER; app_session=keep-me" \
    -o "$TMP_DIR/body" -w '%{http_code}' "http://$DYNAMIC_HOST:$HTTP_PORT/identity")
assert_eq "proxy request with mixed cookies succeeds" "$STATUS" "200"
assert_json "gateway session is not forwarded upstream" '.cookie' "app_session=keep-me"
login "$DYNAMIC_HOST" remote@example.test remote123 "$REMOTE_DYNAMIC_COOKIE" nocobase
request GET "$DYNAMIC_HOST" / "$REMOTE_DYNAMIC_COOKIE"
assert_eq "mapped remote role authorizes application" "$STATUS" "200"

request DELETE "$ADMIN_HOST" /_authz/api/remote-users/nocobase "$ADMIN_COOKIE" "$CSRF" '{"subject":"42"}'
assert_eq "admin deletes recorded remote identity" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/session "$REMOTE_DYNAMIC_COOKIE"
assert_eq "deleting remote identity revokes sessions" "$STATUS" "401"
login "$ADMIN_HOST" remote@example.test remote123 "$REMOTE_COOKIE" nocobase
request GET "$ADMIN_HOST" /_authz/api/session "$REMOTE_COOKIE"
assert_eq "deleted remote identity is recreated by authentication" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/users "$ADMIN_COOKIE"
assert_json "recreated remote identity starts enabled" '.data.remote_users[] | select(.provider == "nocobase" and .subject == "42") | .enabled | tostring' "1"

request POST "$ADMIN_HOST" /_authz/api/applications "$ADMIN_COOKIE" "$CSRF" "{\"domain\":\"invalid-target.test.example\",\"target_ip\":\"http://127.0.0.1\",\"port\":$UPSTREAM_PORT}"
assert_eq "binding rejects a URL as target IP" "$STATUS" "422"
request POST "$ADMIN_HOST" /_authz/api/applications "$ADMIN_COOKIE" "$CSRF" "{\"domain\":\"fixed.test.example\",\"port\":$UPSTREAM_PORT,\"enabled\":true,\"note\":\"test\"}"
assert_eq "create application" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/applications "$ADMIN_COOKIE"
assert_json "binding application keeps its menu label" '.data[] | select(.domain == "fixed.test.example") | .label' "fixed.test.example"
assert_json "binding application exposes its note" '.data[] | select(.domain == "fixed.test.example") | .note' "test"
assert_json "binding application is marked explicit" '.data[] | select(.domain == "fixed.test.example") | .binding | tostring' "true"
request GET "$ADMIN_HOST" /_authz/api/applications "$ADMIN_COOKIE"
assert_json "applications API exposes target IP" '.data[] | select(.domain == "fixed.test.example") | .target_ip' "127.0.0.1"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
APP_ID=$(jq -er '.data.bindings[] | select(.domain == "fixed.test.example") | .id' "$TMP_DIR/body")
assert_json "binding defaults to the local target IP" '.data.bindings[] | select(.domain == "fixed.test.example") | .target_ip' "127.0.0.1"
assert_json "binding defaults to request Host forwarding" '.data.bindings[] | select(.domain == "fixed.test.example") | .upstream_host' ""
assert_json "binding defaults to automatic Origin handling" '.data.bindings[] | select(.domain == "fixed.test.example") | .origin_mode' "auto"
assert_json "binding defaults to normal client identity" '.data.bindings[] | select(.domain == "fixed.test.example") | .simulate_local | tostring' "0"
assert_json "binding defaults to HTTP upstream" '.data.bindings[] | select(.domain == "fixed.test.example") | .upstream_scheme' "http"
assert_json "binding defaults to SSL verification" '.data.bindings[] | select(.domain == "fixed.test.example") | .upstream_ssl_verify | tostring' "1"
assert_json "binding defaults to original upstream path" '.data.bindings[] | select(.domain == "fixed.test.example") | .upstream_path' ""
assert_json "existing port policy is associated with its binding" ".data.policies[] | select(.v0 == \"role:user\" and .v1 == \"$POLICY_OBJECT\") | .object_kind" "binding"
assert_json "associated policy exposes the binding domain" ".data.policies[] | select(.v0 == \"role:user\" and .v1 == \"$POLICY_OBJECT\") | .binding_matches[0].domain" "fixed.test.example"
assert_json "associated policy exposes the binding target" ".data.policies[] | select(.v0 == \"role:user\" and .v1 == \"$POLICY_OBJECT\") | .binding_matches[0].target_ip" "127.0.0.1"
request POST "$ADMIN_HOST" /_authz/api/policies "$ADMIN_COOKIE" "$CSRF" "{\"ptype\":\"p\",\"v0\":\"role:viewer\",\"v1\":\"/$REMOTE_PORT/public/*\",\"binding_id\":$APP_ID,\"v2\":\"GET\",\"eft\":\"allow\"}"
assert_eq "policy binding and object port mismatch is rejected" "$STATUS" "422"
BOUND_PATH_OBJECT="/$UPSTREAM_PORT/public/*"
request POST "$ADMIN_HOST" /_authz/api/policies "$ADMIN_COOKIE" "$CSRF" "{\"ptype\":\"p\",\"v0\":\"role:viewer\",\"v1\":\"$BOUND_PATH_OBJECT\",\"binding_id\":$APP_ID,\"v2\":\"GET\",\"eft\":\"allow\"}"
assert_eq "create policy for the selected binding" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
assert_json "selected binding policy keeps its path" ".data.policies[] | select(.v0 == \"role:viewer\" and .v1 == \"$BOUND_PATH_OBJECT\") | .object_path" "/public/*"
assert_json "selected binding policy resolves to one binding" ".data.policies[] | select(.v0 == \"role:viewer\" and .v1 == \"$BOUND_PATH_OBJECT\") | .binding_matches | length | tostring" "1"
assert_json "selected binding policy exposes target address" ".data.policies[] | select(.v0 == \"role:viewer\" and .v1 == \"$BOUND_PATH_OBJECT\") | .binding_matches[0] | \"\(.target_ip):\(.port)\"" "127.0.0.1:$UPSTREAM_PORT"
BOUND_PATH_POLICY_ID=$(jq -er --arg object "$BOUND_PATH_OBJECT" '.data.policies[] | select(.v0 == "role:viewer" and .v1 == $object) | .id' "$TMP_DIR/body")
UPDATED_BOUND_PATH_OBJECT="/$UPSTREAM_PORT/private/*"
request PATCH "$ADMIN_HOST" "/_authz/api/policies/$BOUND_PATH_POLICY_ID" "$ADMIN_COOKIE" "$CSRF" "{\"ptype\":\"p\",\"v0\":\"role:viewer\",\"v1\":\"$UPDATED_BOUND_PATH_OBJECT\",\"binding_id\":$APP_ID,\"v2\":[\"PATCH\",\"POST\"],\"eft\":\"deny\"}"
assert_eq "update selected binding policy" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
assert_json "updated policy stores the new path" ".data.policies[] | select(.id == $BOUND_PATH_POLICY_ID) | .v1" "$UPDATED_BOUND_PATH_OBJECT"
assert_json "updated policy normalizes methods" ".data.policies[] | select(.id == $BOUND_PATH_POLICY_ID) | .action" "POST,PATCH"
assert_json "updated policy stores deny effect" ".data.policies[] | select(.id == $BOUND_PATH_POLICY_ID) | .effect" "deny"
assert_json "updated policy retains binding details" ".data.policies[] | select(.id == $BOUND_PATH_POLICY_ID) | .binding_matches[0].domain" "fixed.test.example"
request PATCH "$ADMIN_HOST" "/_authz/api/policies/$BOUND_PATH_POLICY_ID" "$ADMIN_COOKIE" "$CSRF" "{\"ptype\":\"p\",\"v0\":\"role:viewer\",\"v1\":\"/$REMOTE_PORT/private/*\",\"binding_id\":$APP_ID,\"v2\":\"GET\",\"eft\":\"allow\"}"
assert_eq "policy edit rejects binding and port mismatch" "$STATUS" "422"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
assert_json "rejected policy edit preserves previous object" ".data.policies[] | select(.id == $BOUND_PATH_POLICY_ID) | .v1" "$UPDATED_BOUND_PATH_OBJECT"
request DELETE "$ADMIN_HOST" "/_authz/api/policies/$BOUND_PATH_POLICY_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "delete selected binding policy" "$STATUS" "200"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" "{\"domain\":\"edited.test.example\",\"target_ip\":\"$REMOTE_IP\",\"port\":$REMOTE_PORT,\"enabled\":true,\"note\":\"edited\"}"
assert_eq "edit binding fields" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
assert_json "edited binding domain" '.data.bindings[] | select(.domain == "edited.test.example") | .domain' "edited.test.example"
assert_json "edited binding target IP" '.data.bindings[] | select(.domain == "edited.test.example") | .target_ip' "$REMOTE_IP"
assert_json "edited binding port" '.data.bindings[] | select(.domain == "edited.test.example") | .port | tostring' "$REMOTE_PORT"
assert_json "edited binding note" '.data.bindings[] | select(.domain == "edited.test.example") | .note' "edited"
request GET edited.test.example / "$ADMIN_COOKIE"
assert_eq "binding proxies another IP" "$STATUS" "200"
assert_eq "remote IP proxy body" "$BODY" "$REMOTE_BODY"
request GET edited.test.example /identity "$ADMIN_COOKIE"
assert_json "remote upstream receives external binding Host" '.host' "edited.test.example:$HTTP_PORT"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"target_ip":"999.1.1.1"}'
assert_eq "edit binding rejects invalid target IP" "$STATUS" "422"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" "{\"port\":1999}"
assert_eq "edit binding rejects port below minimum" "$STATUS" "422"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" "{\"domain\":\"fixed.test.example\",\"target_ip\":\"127.0.0.1\",\"port\":$UPSTREAM_PORT,\"enabled\":true,\"note\":\"test\"}"
assert_eq "restore edited binding" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
APP_ID=$(jq -er '.data.bindings[] | select(.domain == "fixed.test.example") | .id' "$TMP_DIR/body")

request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"upstream_path":"/backend"}'
assert_eq "save upstream path rewrite" "$STATUS" "200"
request GET fixed.test.example '/path-probe?check=1' "$ADMIN_COOKIE"
assert_eq "upstream path rewrite reaches service" "$STATUS" "200"
assert_eq "upstream path rewrite replaces path and keeps query" "$BODY" "/backend?check=1"

request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"upstream_host":null,"forwarded_host":null,"forwarded_proto":null,"forwarded_port":null,"origin_mode":null,"custom_origin":null,"simulate_local":null,"local_ip":null,"upstream_path":null}'
assert_eq "binding accepts null as an automatic proxy value" "$STATUS" "200"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"upstream_host":"http://bad.example"}'
assert_eq "binding rejects URL syntax in upstream Host" "$STATUS" "422"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"upstream_host":"safe.example\nX-Bad: yes"}'
assert_eq "binding rejects header injection in upstream Host" "$STATUS" "422"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"forwarded_proto":"ftp"}'
assert_eq "binding rejects unsupported forwarded protocol" "$STATUS" "422"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"upstream_scheme":"ftp"}'
assert_eq "binding rejects unsupported upstream scheme" "$STATUS" "422"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"upstream_path":"https://backend.example"}'
assert_eq "binding rejects URL as upstream path rewrite" "$STATUS" "422"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"forwarded_port":70000}'
assert_eq "binding rejects invalid forwarded port" "$STATUS" "422"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"origin_mode":"custom","custom_origin":""}'
assert_eq "custom Origin mode requires a value" "$STATUS" "422"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"origin_mode":"custom","custom_origin":"https://public.example/path"}'
assert_eq "binding rejects Origin paths" "$STATUS" "422"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"simulate_local":true,"local_ip":"local-machine"}'
assert_eq "local simulation rejects invalid source IP" "$STATUS" "422"

request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"upstream_host":"app.internal:2078","forwarded_host":"public.example:99","forwarded_proto":"https","forwarded_port":99,"origin_mode":"custom","custom_origin":"https://public.example:99","simulate_local":false,"upstream_path":""}'
assert_eq "save custom proxy headers" "$STATUS" "200"
request GET fixed.test.example /identity "$ADMIN_COOKIE"
assert_eq "custom proxy request reaches upstream" "$STATUS" "200"
assert_json "custom upstream Host reaches service" '.host' "app.internal:2078"
assert_json "custom forwarded Host reaches service" '.forwarded_host' "public.example:99"
assert_json "custom forwarded protocol reaches service" '.forwarded_proto' "https"
assert_json "custom forwarded port reaches service" '.forwarded_port' "99"
assert_json "custom Origin reaches service" '.origin' "https://public.example:99"

request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"upstream_host":"","forwarded_host":"","forwarded_proto":"","forwarded_port":0,"origin_mode":"auto","custom_origin":"","simulate_local":true,"local_ip":"192.168.50.10"}'
assert_eq "enable local request simulation" "$STATUS" "200"
STATUS=$(curl -sS --max-time 5 --resolve "fixed.test.example:$HTTP_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$ADMIN_COOKIE")" \
    -H "Origin: http://fixed.test.example:$HTTP_PORT" \
    -o "$TMP_DIR/body" -w '%{http_code}' "http://fixed.test.example:$HTTP_PORT/identity")
assert_eq "local simulation request reaches upstream" "$STATUS" "200"
assert_json "local simulation uses target Host" '.host' "127.0.0.1:$UPSTREAM_PORT"
assert_json "local simulation uses target forwarded Host" '.forwarded_host' "127.0.0.1:$UPSTREAM_PORT"
assert_json "local simulation reports HTTP upstream protocol" '.forwarded_proto' "http"
assert_json "local simulation reports target port" '.forwarded_port' "$UPSTREAM_PORT"
assert_json "local simulation rewrites Origin" '.origin' "http://127.0.0.1:$UPSTREAM_PORT"
assert_json "local simulation replaces real IP" '.real_ip' "192.168.50.10"
assert_json "local simulation replaces forwarded chain" '.forwarded_for' "192.168.50.10"
assert_json "local simulation removes standard Forwarded" '.forwarded == null | tostring' "true"

request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"upstream_host":"","forwarded_host":"","forwarded_proto":"","forwarded_port":0,"origin_mode":"auto","custom_origin":"","simulate_local":false,"local_ip":"127.0.0.1"}'
assert_eq "restore default proxy behavior" "$STATUS" "200"
login fixed.test.example bob changed123 "$APP_COOKIE"
request GET fixed.test.example / "$APP_COOKIE"
assert_eq "fixed application proxy" "$STATUS" "200"

STATUS=$(curl -sS --max-time 5 --resolve "fixed.test.example:$HTTP_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$ADMIN_COOKIE")" \
    -H "Origin: http://fixed.test.example:$HTTP_PORT" \
    -H 'Content-Type: application/json' \
    --data '{"cwd":"/tmp"}' \
    -o "$TMP_DIR/trusted-origin-body" -w '%{http_code}' \
    "http://fixed.test.example:$HTTP_PORT/trusted-origin")
assert_eq "same-origin POST survives reverse proxy host forwarding" "$STATUS" "200"
assert_eq "same-origin POST reaches upstream unchanged" \
    "$(jq -r '.origin' "$TMP_DIR/trusted-origin-body")" "http://fixed.test.example:$HTTP_PORT"
STATUS=$(curl -sS --max-time 5 --resolve "fixed.test.example:$HTTP_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$ADMIN_COOKIE")" \
    -H 'Origin: http://fixed.test.example:99' \
    -H 'Content-Type: application/json' \
    --data '{"cwd":"/tmp"}' \
    -o "$TMP_DIR/public-port-origin-body" -w '%{http_code}' \
    "http://fixed.test.example:$HTTP_PORT/trusted-origin")
assert_eq "same-host public Origin port survives outer proxy port mapping" "$STATUS" "200"
assert_eq "upstream Host restores the same-host public Origin port" \
    "$(jq -r '.expected_origin' "$TMP_DIR/public-port-origin-body")" "http://fixed.test.example:99"
STATUS=$(curl -sS --max-time 5 --resolve "fixed.test.example:$HTTP_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$ADMIN_COOKIE")" \
    -H 'Origin: https://cross-origin.test' \
    -H 'Content-Type: application/json' \
    --data '{"cwd":"/tmp"}' \
    -o "$TMP_DIR/untrusted-origin-body" -w '%{http_code}' \
    "http://fixed.test.example:$HTTP_PORT/trusted-origin")
assert_eq "cross-origin POST remains rejected by upstream" "$STATUS" "403"

STATUS=$(curl -skS --max-time 5 --resolve "fixed.test.example:$HTTPS_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$APP_COOKIE")" -o "$TMP_DIR/https-proxy-body" -w '%{http_code}' \
    "https://fixed.test.example:$HTTPS_PORT/")
assert_eq "HTTPS gateway proxies to HTTP upstream" "$STATUS" "200"
assert_eq "HTTPS HTTP-upstream proxy body" "$(<"$TMP_DIR/https-proxy-body")" "$MOCK_BODY"

request POST "$ADMIN_HOST" /_authz/api/applications "$ADMIN_COOKIE" "$CSRF" "{\"domain\":\"ws-fixed.test.example\",\"port\":$WS_PORT,\"enabled\":true,\"websocket\":false,\"note\":\"websocket default test\"}"
assert_eq "create WebSocket application" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
assert_json "WebSocket compatibility field is stored" '.data.bindings[] | select(.domain == "ws-fixed.test.example") | .websocket | tostring' "0"
WS_STATUS=$(curl -sS --max-time 5 --http1.1 --resolve "ws-fixed.test.example:$HTTP_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$ADMIN_COOKIE")" -D "$TMP_DIR/websocket-headers" -o "$TMP_DIR/websocket-body" -w '%{http_code}' \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "http://ws-fixed.test.example:$HTTP_PORT/" || true)
assert_eq "WebSocket handshake through default binding" "$WS_STATUS" "101"
assert_contains "WebSocket upgrade response" "$(cat "$TMP_DIR/websocket-headers")" "101 Switching Protocols"
WS_STATUS=$(curl -skS --max-time 5 --http1.1 --resolve "ws-fixed.test.example:$HTTPS_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$ADMIN_COOKIE")" -D "$TMP_DIR/https-websocket-headers" -o /dev/null -w '%{http_code}' \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    "https://ws-fixed.test.example:$HTTPS_PORT/" || true)
assert_eq "HTTPS default WebSocket proxy" "$WS_STATUS" "101"
assert_contains "HTTPS WebSocket upgrade response" \
    "$(cat "$TMP_DIR/https-websocket-headers")" "101 Switching Protocols"

# ── 绑定级 header 覆盖（多行输入，逐行覆盖透传请求头）──
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" \
    '{"header_overrides":"X-Probe-Header: from-binding\nAuthorization: Bearer fixed-token"}'
assert_eq "save binding header overrides" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
assert_json "header overrides normalize to one entry per line" \
    '.data.bindings[] | select(.domain == "fixed.test.example") | .header_overrides' \
    $'Authorization: Bearer fixed-token\nX-Probe-Header: from-binding'
request GET fixed.test.example /identity "$ADMIN_COOKIE"
assert_json "header override reaches upstream" '.probe' "from-binding"
assert_json "Authorization override reaches upstream" '.authorization' "Bearer fixed-token"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"header_overrides":"JustAName"}'
assert_eq "header override without colon is rejected" "$STATUS" "422"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"header_overrides":"X-Authz-User: evil"}'
assert_eq "header override cannot touch gateway identity headers" "$STATUS" "422"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"header_overrides":"X-Bad: bad\rvalue"}'
assert_eq "header override rejects control characters" "$STATUS" "422"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"header_overrides":"X-Empty:"}'
assert_eq "header override rejects empty values" "$STATUS" "422"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"header_overrides":null}'
assert_eq "clear binding header overrides" "$STATUS" "200"
request GET fixed.test.example /identity "$ADMIN_COOKIE"
assert_json "cleared header overrides stop overriding" '.probe | tostring' "null"
request POST "$ADMIN_HOST" /_authz/api/applications "$ADMIN_COOKIE" "$CSRF" \
    '{"domain":"https-override.test.example","target_ip":"127.0.0.1","port":'$TLS_PORT',"upstream_scheme":"https","upstream_ssl_verify":false,"header_overrides":"X-Probe-Header: from-https-binding"}'
assert_eq "create HTTPS binding with header overrides" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
HTTPS_OVERRIDE_ID=$(jq -er '.data.bindings[] | select(.domain == "https-override.test.example") | .id' "$TMP_DIR/body")
STATUS=$(curl -sS --max-time 5 --resolve "https-override.test.example:$HTTP_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$ADMIN_COOKIE")" \
    -o "$TMP_DIR/https-override-body" -w '%{http_code}' \
    "http://https-override.test.example:$HTTP_PORT/")
assert_eq "HTTPS upstream with header override reaches insecure proxy path" "$STATUS" "200"
assert_contains "header override survives internal redirect to insecure proxy" \
    "$(cat "$TMP_DIR/https-override-body")" "from-https-binding"
request DELETE "$ADMIN_HOST" "/_authz/api/applications/$HTTPS_OVERRIDE_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "delete HTTPS header override binding" "$STATUS" "200"

request POST "$ADMIN_HOST" /_authz/api/applications "$ADMIN_COOKIE" "$CSRF" \
    "{\"domain\":\"https-fixed.test.example\",\"target_ip\":\"127.0.0.1\",\"port\":$TLS_PORT,\"upstream_scheme\":\"https\",\"upstream_ssl_verify\":false}"
assert_eq "create HTTPS upstream binding" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/authorization "$ADMIN_COOKIE"
HTTPS_APP_ID=$(jq -er '.data.bindings[] | select(.domain == "https-fixed.test.example") | .id' "$TMP_DIR/body")
assert_json "HTTPS binding stores upstream scheme" '.data.bindings[] | select(.domain == "https-fixed.test.example") | .upstream_scheme' "https"
assert_json "HTTPS binding can ignore SSL verification" '.data.bindings[] | select(.domain == "https-fixed.test.example") | .upstream_ssl_verify | tostring' "0"
request GET https-fixed.test.example / "$ADMIN_COOKIE"
assert_eq "HTTPS upstream works with ignored certificate" "$STATUS" "200"
assert_eq "HTTPS upstream response body" "$BODY" "/"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$HTTPS_APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"upstream_ssl_verify":true}'
assert_eq "enable HTTPS upstream SSL verification" "$STATUS" "200"
request GET https-fixed.test.example / "$ADMIN_COOKIE"
assert_eq "self-signed HTTPS upstream is rejected when verification is enabled" "$STATUS" "502"
request DELETE "$ADMIN_HOST" "/_authz/api/applications/$HTTPS_APP_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "delete HTTPS upstream binding" "$STATUS" "200"

request POST "$ADMIN_HOST" /_authz/api/applications "$ADMIN_COOKIE" "$CSRF" "{\"domain\":\"ws-fixed.test.example\",\"port\":$WS_PORT,\"enabled\":true}"
assert_eq "duplicate domain binding rejected clearly" "$STATUS" "409"
assert_json "duplicate domain binding error" '.error.code' "request_failed"

request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"enabled":false}'
assert_eq "disable application" "$STATUS" "200"
request GET fixed.test.example / "$APP_COOKIE"
assert_eq "disabled application no longer resolves" "$STATUS" "404"
request PATCH "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF" '{"enabled":true}'
assert_eq "enable application" "$STATUS" "200"

request DELETE "$ADMIN_HOST" "/_authz/api/policies/$POLICY_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "delete access policy" "$STATUS" "200"
request GET "$DYNAMIC_HOST" / "$DYNAMIC_COOKIE"
assert_eq "policy deletion invalidates cache" "$STATUS" "403"

request PATCH "$ADMIN_HOST" "/_authz/api/users/$BOB_ID" "$ADMIN_COOKIE" "$CSRF" '{"enabled":false}'
assert_eq "disable user" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/session "$BOB_COOKIE"
assert_eq "disabled user session revoked" "$STATUS" "401"
login "$ADMIN_HOST" bob changed123 "$BOB_COOKIE" local false
request GET "$ADMIN_HOST" /_authz/api/session "$BOB_COOKIE"
assert_eq "disabled local user cannot sign in again" "$STATUS" "401"

request PATCH "$ADMIN_HOST" /_authz/api/users/1 "$ADMIN_COOKIE" "$CSRF" '{"enabled":false}'
assert_eq "built-in admin cannot be disabled" "$STATUS" "409"
request DELETE "$ADMIN_HOST" "/_authz/api/users/$BOB_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "delete user" "$STATUS" "200"
request DELETE "$ADMIN_HOST" "/_authz/api/applications/$APP_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "delete application" "$STATUS" "200"

request GET "$ADMIN_HOST" /_authz/api/missing "$ADMIN_COOKIE"
assert_eq "unknown API status" "$STATUS" "404"
assert_eq "unknown API JSON type" "$CONTENT_TYPE" "application/json; charset=UTF-8"
assert_json "unknown API error" '.error.code' "http_404"

# ── 菜单树管理 /_authz/api/menu-tree + /menu-entries ────────────
request GET "$ADMIN_HOST" /_authz/api/menu-tree "$ADMIN_COOKIE"
assert_eq "menu tree loads" "$STATUS" "200"
assert_json "menu tree seeds three groups" '.data.groups | length' "3"
assert_json "first seeded group is system apps" '.data.groups[0].label' "系统应用"
assert_json "system group carries five built-in pages" '.data.groups[0].children | length' "5"
assert_json "file browser built-in is seeded" '[.data.groups[0].children[] | select(.builtin == "files")] | length' "1"
assert_json "built-in item maps to internal page" '.data.groups[0].children[0].builtin' "users"
assert_json "second seeded group is domain services" '.data.groups[1].builtin' "domains"
assert_json "third seeded group is local services" '.data.groups[2].builtin' "local"
assert_json "discovered services land in domain or local groups" '(.data.groups[1].children | length) + (.data.groups[2].children | length) > 0 | tostring' "true"

request GET "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE"
assert_eq "menu entries list" "$STATUS" "200"
assert_json "menu entries expose kind and parent" '.data[0] | has("kind") and has("sort_order") | tostring' "true"
MENU_GROUP_ID=$(jq -er '.data[] | select(.kind == "group" and .label == "系统应用") | .id' "$TMP_DIR/body")
assert_json "menu entries expose parent linkage" '[.data[] | select(.kind == "item")] | map(has("parent_id")) | all | tostring' "true"
[[ -n "$MENU_GROUP_ID" ]] || fail "seeded system group not found"
pass "seeded system group id resolved"

request POST "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE" "$CSRF" '{"kind":"group","label":"工具集","icon":"mdi-toolbox"}'
assert_eq "create menu group" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE"
MENU_NEW_GROUP_ID=$(jq -er '.data[] | select(.label == "工具集") | .id' "$TMP_DIR/body")
[[ -n "$MENU_NEW_GROUP_ID" ]] || fail "created menu group not found"
pass "created menu group appears in list"
assert_json "new group kind persisted" '.data[] | select(.id == '$MENU_NEW_GROUP_ID') | .kind' "group"

request POST "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE" "$CSRF" '{"kind":"item","parent_id":'$MENU_NEW_GROUP_ID',"label":"监控面板","url":"/monitor/","icon":"mdi-monitor"}'
assert_eq "create menu entry under group" "$STATUS" "201"
request GET "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE"
MENU_ENTRY_ID=$(jq -er '.data[] | select(.label == "监控面板") | .id' "$TMP_DIR/body")
[[ -n "$MENU_ENTRY_ID" ]] || fail "created menu entry not found"
pass "created menu entry appears in list"
assert_json "menu entry links to its parent group" '.data[] | select(.id == '$MENU_ENTRY_ID') | .parent_id' "$MENU_NEW_GROUP_ID"
assert_json "menu entry is enabled by default" '.data[] | select(.id == '$MENU_ENTRY_ID') | .enabled' "1"

request POST "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE" "" '{"kind":"item","parent_id":'$MENU_NEW_GROUP_ID',"label":"no-csrf","url":"/x"}'
assert_eq "menu entry without CSRF rejected" "$STATUS" "403"
request POST "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE" "$CSRF" '{"kind":"item","parent_id":'$MENU_NEW_GROUP_ID',"label":"","url":"/x"}'
assert_eq "empty menu label rejected" "$STATUS" "422"
request POST "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE" "$CSRF" '{"kind":"item","label":"orphan","url":"/x"}'
assert_eq "item without parent group rejected" "$STATUS" "422"
request POST "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE" "$CSRF" '{"kind":"item","parent_id":'$MENU_NEW_GROUP_ID',"label":"bad","url":"javascript:alert(1)"}'
assert_eq "non-http URL rejected" "$STATUS" "422"
request POST "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE" "$CSRF" '{"kind":"item","parent_id":'$MENU_NEW_GROUP_ID',"label":"bad","url":"//evil.example/x"}'
assert_eq "protocol-relative URL rejected" "$STATUS" "422"
request POST "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE" "$CSRF" '{"kind":"bad","label":"bad","url":"/x"}'
assert_eq "unknown node kind rejected" "$STATUS" "422"

request PATCH "$ADMIN_HOST" "/_authz/api/menu-entries/$MENU_ENTRY_ID" "$ADMIN_COOKIE" "$CSRF" '{"label":"监控","icon":"mdi-chart-line"}'
assert_eq "edit menu entry" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE"
assert_json "edited menu label persisted" '.data[] | select(.id == '$MENU_ENTRY_ID') | .label' "监控"
request PATCH "$ADMIN_HOST" "/_authz/api/menu-entries/$MENU_ENTRY_ID" "$ADMIN_COOKIE" "$CSRF" '{"parent_id":'$MENU_GROUP_ID'}'
assert_eq "move menu entry to another group" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE"
assert_json "moved entry parent updated" '.data[] | select(.id == '$MENU_ENTRY_ID') | .parent_id' "$MENU_GROUP_ID"

request PATCH "$ADMIN_HOST" "/_authz/api/menu-entries/$MENU_ENTRY_ID" "$ADMIN_COOKIE" "$CSRF" '{"enabled":false}'
assert_eq "hide menu entry" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE"
assert_json "hidden menu entry persists disabled" '.data[] | select(.id == '$MENU_ENTRY_ID') | .enabled' "0"
request GET "$ADMIN_HOST" /_authz/api/menu-tree "$ADMIN_COOKIE"
assert_json "hidden entry is absent from rendered tree" '[.data.groups[].children[]? | select(.label == "监控")] | length' "0"

request PATCH "$ADMIN_HOST" "/_authz/api/menu-entries/$MENU_ENTRY_ID" "$ADMIN_COOKIE" "$CSRF" '{"enabled":true}'
assert_eq "re-enable menu entry" "$STATUS" "200"
request PUT "$ADMIN_HOST" /_authz/api/menu-entries/reorder "$ADMIN_COOKIE" "$CSRF" '{"order":[{"id":'$MENU_NEW_GROUP_ID'}]}'
assert_eq "reorder menu groups" "$STATUS" "200"
# 把条目移回新分组，验证“非空分组不可删除”
request PATCH "$ADMIN_HOST" "/_authz/api/menu-entries/$MENU_ENTRY_ID" "$ADMIN_COOKIE" "$CSRF" '{"parent_id":'$MENU_NEW_GROUP_ID'}'
assert_eq "move menu entry back to its group" "$STATUS" "200"
request DELETE "$ADMIN_HOST" "/_authz/api/menu-entries/$MENU_NEW_GROUP_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "delete non-empty group rejected" "$STATUS" "409"
request DELETE "$ADMIN_HOST" "/_authz/api/menu-entries/$MENU_ENTRY_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "delete menu entry" "$STATUS" "200"
request GET "$ADMIN_HOST" /_authz/api/menu-entries "$ADMIN_COOKIE"
assert_json "deleted menu entry removed" '[.data[] | select(.id == '$MENU_ENTRY_ID')] | length' "0"
request DELETE "$ADMIN_HOST" "/_authz/api/menu-entries/$MENU_NEW_GROUP_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "delete emptied group" "$STATUS" "200"
request DELETE "$ADMIN_HOST" "/_authz/api/menu-entries/$MENU_NEW_GROUP_ID" "$ADMIN_COOKIE" "$CSRF"
assert_eq "delete missing menu entry 404" "$STATUS" "404"

# ── 文件浏览 API /_authz/api/files ─────────────────────────────
request GET "$ADMIN_HOST" /_authz/api/files "$ADMIN_COOKIE"
assert_eq "file listing loads" "$STATUS" "200"
assert_json "file listing path is root" '.data.path' ""
assert_json "file listing carries entries" '.data.items | length > 0 | tostring' "true"
assert_json "file listing hides brotli sidecars" '[.data.items[] | select(.name | endswith(".br"))] | length' "0"
request GET "$ADMIN_HOST" "/_authz/api/files?path=vendor" "$ADMIN_COOKIE"
assert_eq "file subdirectory listing" "$STATUS" "200"
assert_json "file subdirectory path echoed" '.data.path' "vendor"
request GET "$ADMIN_HOST" "/_authz/api/files?path=..%2F..%2Fetc" "$ADMIN_COOKIE"
assert_eq "file listing rejects traversal" "$STATUS" "400"
request GET "$ADMIN_HOST" "/_authz/api/files?path=missing-dir" "$ADMIN_COOKIE"
assert_eq "file listing missing directory 404" "$STATUS" "404"
request GET "$ADMIN_HOST" /_authz/api/files
assert_eq "file listing requires session" "$STATUS" "401"


# ── Nginx include 编辑 API /_authz/api/nginx-conf ──────────────
request GET "$ADMIN_HOST" /_authz/api/nginx-conf "$ADMIN_COOKIE"
assert_eq "nginx conf listing loads" "$STATUS" "200"
assert_json "nginx conf exposes three includes" '.data.files | length' "3"
assert_json "nginx conf include names" '[.data.files[].name] | join(",")' \
    "http_inc.conf,server_inc.conf,stream_inc.conf"
request POST "$ADMIN_HOST" /_authz/api/nginx-conf/validate "$ADMIN_COOKIE" "$CSRF" \
    '{"name":"server_inc.conf","content":"broken directive without semicolon"}'
assert_eq "nginx conf validation reports broken content" "$STATUS" "200"
assert_json "broken validation reports ok=false" '.data.ok | tostring' "false"
assert_json "broken validation returns nginx -t output" '.data.output | length > 0 | tostring' "true"
request POST "$ADMIN_HOST" /_authz/api/nginx-conf/validate "$ADMIN_COOKIE" "$CSRF" \
    '{"name":"../nginx.conf","content":"x"}'
assert_eq "nginx conf validation rejects unknown file" "$STATUS" "400"
request GET "$ADMIN_HOST" /_authz/api/nginx-conf
assert_eq "nginx conf listing requires session" "$STATUS" "401"

request DELETE "$ADMIN_HOST" /_authz/api/session "$ADMIN_COOKIE" "$CSRF"
assert_eq "logout API" "$STATUS" "200"
LOGOUT_COOKIES=$(cat "$TMP_DIR/headers")
assert_contains "logout clears configured root-domain cookie" "$LOGOUT_COOKIES" "; Domain=.test.example"
assert_contains "logout clears host-only cookie" "$LOGOUT_COOKIES" "authz_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"
assert_contains "logout clears deeper legacy domain cookie" "$LOGOUT_COOKIES" "; Domain=.admin.test.example"
request GET "$ADMIN_HOST" /_authz/api/session "$ADMIN_COOKIE"
assert_eq "logged-out session rejected" "$STATUS" "401"

RESET_OUTPUT=$(docker exec "$CONTAINER_NAME" env AUTHZ_ADMIN_PASSWORD=reset123 admin_password_reset)
assert_contains "admin password reset command runs" "$RESET_OUTPUT" "admin password reset from AUTHZ_ADMIN_PASSWORD"
sleep 1
login "$ADMIN_HOST" admin reset123 "$RESET_COOKIE"
request GET "$ADMIN_HOST" /_authz/api/session "$RESET_COOKIE"
assert_eq "reset admin password is immediately usable" "$STATUS" "200"
# ── Agent 专用 API Key（仅本机可用）────────────────────────────
AGENT_CSRF=$(jq -er '.data.csrf' "$TMP_DIR/body")
STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -H "Cookie: $(cookie_header "$RESET_COOKIE")" \
    -H "X-CSRF-Token: $AGENT_CSRF" -H 'Content-Type: application/json' \
    -o "$TMP_DIR/body" -w '%{http_code}' \
    -X POST "http://$ADMIN_HOST:$HTTP_PORT/_authz/api/api-keys" \
    -d '{"name":"agent-loopback","role":"admin"}')
assert_eq "create loopback-only api key" "$STATUS" "201"
AGENT_LOOPBACK_TOKEN=$(jq -er '.data.token' "$TMP_DIR/body")
STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -o "$TMP_DIR/body" -w '%{http_code}' \
    "http://$ADMIN_HOST:$HTTP_PORT/_authz/api/session" \
    -H "x-authz-key: $AGENT_LOOPBACK_TOKEN")
assert_eq "loopback api key works from loopback" "$STATUS" "200"

docker exec "$CONTAINER_NAME" env AUTHZ_ADMIN_PASSWORD=admin123 admin_password_reset >/dev/null
sleep 1
login "$ADMIN_HOST" admin admin123 "$ADMIN_COOKIE"

STATUS=$(curl -skS --max-time 5 --resolve "$ADMIN_HOST:$HTTPS_PORT:127.0.0.1" \
    -D "$TMP_DIR/secure-headers" -o /dev/null -w '%{http_code}' \
    -X POST "https://$ADMIN_HOST:$HTTPS_PORT/_authz/login" \
    --data-urlencode 'username=admin' --data-urlencode 'password=admin123')
assert_eq "HTTPS login succeeds" "$STATUS" "302"
SECURE_COOKIE=$(awk 'BEGIN { IGNORECASE=1 } /^Set-Cookie:/ { print }' "$TMP_DIR/secure-headers")
assert_contains "HTTPS session cookie is Secure" "$SECURE_COOKIE" "; Secure"
assert_contains "session cookie uses root domain" "$SECURE_COOKIE" "; Domain=.test.example"

STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -H 'X-Forwarded-Proto: https' -D "$TMP_DIR/forwarded-secure-headers" \
    -o /dev/null -w '%{http_code}' -X POST "http://$ADMIN_HOST:$HTTP_PORT/_authz/login" \
    --data-urlencode 'username=admin' --data-urlencode 'password=admin123')
assert_eq "forwarded HTTPS login succeeds" "$STATUS" "302"
FORWARDED_SECURE_COOKIE=$(awk 'BEGIN { IGNORECASE=1 } /^Set-Cookie:/ { print }' "$TMP_DIR/forwarded-secure-headers")
assert_contains "forwarded HTTPS cookie is Secure" "$FORWARDED_SECURE_COOKIE" "; Secure"

# ── 登录失败延迟与账户锁定（账户名+IP）──────────────────────────
LOCK_ACCOUNT="lockme"
FAIL_START_MS=$(date +%s%3N)
for _ in $(seq 1 4); do
    STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
        -o /dev/null -w '%{http_code}' -X POST "http://$ADMIN_HOST:$HTTP_PORT/_authz/login" \
        --data-urlencode "username=$LOCK_ACCOUNT" --data-urlencode 'password=incorrect')
    [[ "$STATUS" == "302" ]] || fail "failed login before lock threshold (got $STATUS)"
done
FAIL_ELAPSED_MS=$(( $(date +%s%3N) - FAIL_START_MS ))
[[ "$FAIL_ELAPSED_MS" -ge 3600 ]] || fail "4 failed logins should each wait ~1s (total ${FAIL_ELAPSED_MS}ms < 3600ms)"
pass "failed login responses are delayed at least one second each"
STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -o /dev/null -w '%{http_code}' -X POST "http://$ADMIN_HOST:$HTTP_PORT/_authz/login" \
    --data-urlencode "username=$LOCK_ACCOUNT" --data-urlencode 'password=incorrect')
assert_eq "fifth failed login locks the account on this IP" "$STATUS" "429"
STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -o /dev/null -w '%{http_code}' -X POST "http://$ADMIN_HOST:$HTTP_PORT/_authz/login" \
    --data-urlencode "username=$LOCK_ACCOUNT" --data-urlencode 'password=correct-horse')
assert_eq "locked account is rejected even with any password" "$STATUS" "429"
STATUS=$(curl -sS --max-time 5 --resolve "$ADMIN_HOST:$HTTP_PORT:127.0.0.1" \
    -o /dev/null -w '%{http_code}' -X POST "http://$ADMIN_HOST:$HTTP_PORT/_authz/login" \
    --data-urlencode 'username=admin' --data-urlencode 'password=admin123')
assert_eq "another account from the same IP is not locked" "$STATUS" "302"

# ── 公网 HTTP 默认只重定向到 HTTPS ─────────────────────────────
REDIRECT_CONTAINER_NAME="authz-gateway-redirect-test-$$"
mkdir -p "$TMP_DIR/redirect-data/authz"
docker run -d \
    --name "$REDIRECT_CONTAINER_NAME" \
    --network host \
    -e NGINX_WORKER_PROCESSES=1 \
    -e AUTHZ_HTTP_PORT="$REDIRECT_HTTP_PORT" \
    -e AUTHZ_HTTPS_PORT="$REDIRECT_HTTPS_PORT" \
    -e AUTHZ_ADMIN_PASSWORD=admin123 \
    -e OPENRESTY_TEMPLATE_DIR=/etc/openresty/templates \
    -v "$TMP_DIR/redirect-data:/data" \
    -v "$REPO_DIR/admin:/usr/local/openresty/nginx/html/admin:ro" \
    -v "$REPO_DIR/admin:/files:ro" \
    -v "$TMP_DIR/templates:/etc/openresty/templates:ro" \
    -v "$REPO_DIR/docker-entrypoint.sh:/docker-entrypoint.sh:ro" \
    -v "$REPO_DIR/lualib:/usr/local/openresty/site/lualib:ro" \
    "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
    STATUS=$(curl -sS --max-time 2 --resolve "redirect.test.example:$REDIRECT_HTTP_PORT:127.0.0.1" \
        -D "$TMP_DIR/redirect-headers" -o /dev/null -w '%{http_code}' \
        "http://redirect.test.example:$REDIRECT_HTTP_PORT/_authz/login?next=%2Fdemo" 2>/dev/null || true)
    [[ "$STATUS" == "308" ]] && break
    sleep 0.2
done
assert_eq "public HTTP defaults to permanent HTTPS redirect" "$STATUS" "308"
REDIRECT_LOCATION=$(awk 'BEGIN { IGNORECASE=1 } /^Location:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit }' "$TMP_DIR/redirect-headers")
assert_eq "HTTPS redirect preserves host port path and query" "$REDIRECT_LOCATION" \
    "https://redirect.test.example:$REDIRECT_HTTPS_PORT/_authz/login?next=%2Fdemo"

# ── Cookie 域选择：Origin 与 Host 不一致时以 Origin 匹配的父域为准 ──
ORIGIN_CONTAINER_NAME="authz-gateway-origin-test-$$"
ORIGIN_HTTP_PORT=$(free_port)
ORIGIN_HTTPS_PORT=$(free_port)
mkdir -p "$TMP_DIR/origin-data/authz"
docker run -d \
    --name "$ORIGIN_CONTAINER_NAME" \
    --network host \
    -e NGINX_WORKER_PROCESSES=1 \
    -e AUTHZ_HTTP_PORT="$ORIGIN_HTTP_PORT" \
    -e AUTHZ_HTTPS_PORT="$ORIGIN_HTTPS_PORT" \
    -e AUTHZ_HTTP_MODE=serve \
    -e AUTHZ_ADMIN_PASSWORD=admin123 \
    -e AUTHZ_COOKIE_DOMAIN=".one.example.com,.two.example.net" \
    -e OPENRESTY_TEMPLATE_DIR=/etc/openresty/templates \
    -v "$TMP_DIR/origin-data:/data" \
    -v "$REPO_DIR/admin:/usr/local/openresty/nginx/html/admin:ro" \
    -v "$TMP_DIR/templates:/etc/openresty/templates:ro" \
    -v "$REPO_DIR/docker-entrypoint.sh:/docker-entrypoint.sh:ro" \
    -v "$REPO_DIR/lualib:/usr/local/openresty/site/lualib:ro" \
    "$IMAGE" >/dev/null
for _ in $(seq 1 60); do
    STATUS=$(curl -sS --max-time 2 --resolve "a.one.example.com:$ORIGIN_HTTP_PORT:127.0.0.1" \
        -o /dev/null -w '%{http_code}' \
        "http://a.one.example.com:$ORIGIN_HTTP_PORT/_authz/login" 2>/dev/null || true)
    [[ "$STATUS" == "200" ]] && break
    sleep 0.2
done
[[ "$STATUS" == "200" ]] || fail "origin-select gateway did not become ready"

origin_login_cookie_domain() {
    local host="$1" origin_header="${2:-}"
    local extra_args=()
    if [[ -n "$origin_header" ]]; then
        extra_args=(-H "origin: $origin_header")
    fi
    curl -sS --max-time 5 --resolve "$host:$ORIGIN_HTTP_PORT:127.0.0.1" \
        -D "$TMP_DIR/origin-headers" -o /dev/null \
        "${extra_args[@]}" \
        -X POST "http://$host:$ORIGIN_HTTP_PORT/_authz/login" \
        --data-urlencode 'username=admin' --data-urlencode 'password=admin123' >/dev/null
    awk 'BEGIN { IGNORECASE=1 } /^Set-Cookie:/ && /Max-Age=[1-9]/ { match($0, /Domain=[^;\r]+/); print substr($0, RSTART+7, RLENGTH-7); exit }' "$TMP_DIR/origin-headers"
}

assert_eq "login without origin uses host domain" \
    "$(origin_login_cookie_domain a.one.example.com)" ".one.example.com"
assert_eq "mismatched origin in configured list wins" \
    "$(origin_login_cookie_domain a.one.example.com https://b.two.example.net:99)" ".two.example.net"
assert_eq "matching origin keeps host domain" \
    "$(origin_login_cookie_domain a.one.example.com https://a.one.example.com)" ".one.example.com"
assert_eq "unknown origin falls back to host domain" \
    "$(origin_login_cookie_domain a.one.example.com https://other.example.org)" ".one.example.com"

printf '\nAll %d authz gateway checks passed.\n' "$PASS"
