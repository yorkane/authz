#!/usr/bin/env bash
# authz 管理端 UI/控制面 API 回归测试（依据 skill/authz-helper）
# 用法: GATEWAY=http://127.0.0.1:6080 bash testcase/ui_api_tests.sh
# 可选: AUTHZ_API_KEY=xx 指定 Key; AUTHZ_ENV_FILE 指定 .env; TEST_ONLY=t01,t04; KEEP_GOING=1
set -u

GATEWAY="${GATEWAY:-https://127.0.0.1:6443}"
ENV_FILE="${AUTHZ_ENV_FILE:-/data/app/.env}"
if [ -z "${AUTHZ_API_KEY:-}" ] && [ -f "$ENV_FILE" ]; then
  AUTHZ_API_KEY=$(grep -E '^AUTHZ_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '\"' | tr -d "'")
fi
if [ -z "${AUTHZ_API_KEY:-}" ]; then echo "ERROR: no AUTHZ_API_KEY"; exit 2; fi

API="$GATEWAY/_authz/api"
TS=$(date +%s)
PASS=0; FAIL=0; FAILED=""
UP_PID=""; BID=""; POL_IDS=""; KEY_IDS=""; USER_IDS=""
ONLY="${TEST_ONLY:-}"
KEEP="${KEEP_GOING:-}"

should_run() { [ -z "$ONLY" ] && return 0; case ",$ONLY," in *",$1,"*) return 0;; *) return 1;; esac; }
ok()   { PASS=$((PASS+1)); echo "PASS $1"; }
bad() { FAIL=$((FAIL+1)); FAILED="$FAILED $1"; echo "FAIL $1 ${2:-}"; }
check() { if [ "$2" = "1" ]; then ok "$1"; else bad "$1" "${3:-}"; fi; }
die() { bad "$1" "${2:-}"; [ -z "$KEEP" ] && exit 1; }

# api <path> [curl-extra...]; 输出 body; APICODE 为状态码
api() { local p="$1"; shift; OUT=$(curl -sSk -w '\n%{http_code}' -H "x-api-key: $AUTHZ_API_KEY" "$@" "$API$p"); APICODE=$(echo "$OUT" | tail -1); BODY=$(echo "$OUT" | sed '$d'); }
# raw <url> [curl-extra...] 任意 URL
raw() { local u="$1"; shift; OUT=$(curl -sSk -w '\n%{http_code}' "$@" "$u"); APICODE=$(echo "$OUT" | tail -1); BODY=$(echo "$OUT" | sed '$d'); }
jget() { echo "$BODY" | jq -r "$1"; }
code_ok() { case "$1" in 200|201) return 0;; *) return 1;; esac; }

cleanup() {
  [ -n "${UP_PID:-}" ] && kill "$UP_PID" 2>/dev/null
  [ -n "${BID:-}" ]     && curl -sk -o /dev/null -H "x-api-key: $AUTHZ_API_KEY" -X DELETE "$API/applications/$BID"
  for id in ${POL_IDS:-}; do curl -sk -o /dev/null -H "x-api-key: $AUTHZ_API_KEY" -X DELETE "$API/policies/$id"; done
  for id in ${KEY_IDS:-}; do curl -sk -o /dev/null -H "x-api-key: $AUTHZ_API_KEY" -X DELETE "$API/api-keys/$id"; done
  for id in ${USER_IDS:-}; do curl -sk -o /dev/null -H "x-api-key: $AUTHZ_API_KEY" -X DELETE "$API/users/$id"; done
}
trap cleanup EXIT

# ── T01 会话 smoke ─────────────────────────────────────────────
t01_smoke() {
  api /session
  check t01.key_session_200 "$([ "$APICODE" = 200 ] && echo 1)" "$APICODE"
  check t01.session_admin_true "$(jget '.data.admin' | grep -qx true && echo 1)" "$(jget '.data.admin')"
  check t01.session_identity "$(jget '.data.identity' | grep -q 'api-key:' && echo 1)"
}

# ── T02 认证边界（无 Key / 坏 Key 一律 401，不回退）────────────
t02_authz_boundary() {
  raw "$API/users"
  check t02.no_key_401 "$([ "$APICODE" = 401 ] && echo 1)" "$APICODE"
  raw "$API/users" -H 'x-api-key: ak_0000000000000000000000000000000000000000000000000000000000000000'
  check t02.bad_key_401 "$([ "$APICODE" = 401 ] && echo 1)" "$APICODE"
}

# ── T03 用户 CRUD + 登录 + CSRF ───────────────────────────────
t03_users_lifecycle() {
  local u="tcase$TS"
  api /users -X POST -H 'Content-Type: application/json' -d "{\"username\":\"$u\",\"password\":\"Tcase-pass-1\",\"roles\":[\"user\"]}"
  check t03.create_user "$(code_ok "$APICODE" && echo 1)" "$APICODE $BODY"
  api /users
  local uid; uid=$(jget ".data.users[] | select(.username==\"$u\") | .id"); USER_IDS="$USER_IDS $uid"
  api "/users/$uid" -X PATCH -H 'Content-Type: application/json' -d '{"roles":["admin"]}'
  api /users
  check t03.patch_roles "$(jget ".data.users[] | select(.id==$uid) | .roles" | grep -q admin && echo 1)" "$uid roles"
  api "/users/$uid/password" -X PUT -H 'Content-Type: application/json' -d '{"password":"Tcase-pass-2"}'
  check t03.reset_password "$(code_ok "$APICODE" && echo 1)" "$APICODE"
  # 表单登录拿会话 Cookie
  local JAR; JAR=$(mktemp /data/tmp/tcase-jar.XXXXXX)
  raw "$GATEWAY/_authz/login" -c "$JAR" -o /dev/null \
      --data-urlencode "username=$u" --data-urlencode 'password=Tcase-pass-2' --data-urlencode 'next=/'
  check t03.login_302 "$([ "$APICODE" = 302 ] && echo 1)" "$APICODE"
  raw "$API/session" -b "$JAR"
  local csrf; csrf=$(jget '.data.csrf')
  check t03.cookie_session "$(jget '.data.username' | grep -qx "$u" && echo 1)"
  # Cookie 会话写操作无 CSRF → 403；带 CSRF → 200
  raw "$API/policies" -b "$JAR" -X POST -H 'Content-Type: application/json' -d '{"ptype":"p","v0":"role:guest","v1":"/1/*","v2":"GET"}'
  check t03.csrf_missing_403 "$([ "$APICODE" = 403 ] && echo 1)" "$APICODE"
  raw "$API/policies" -b "$JAR" -X POST -H "X-CSRF-Token: $csrf" -H 'Content-Type: application/json' -d '{"ptype":"p","v0":"role:guest","v1":"/2000/*","v2":"GET"}'
  check t03.csrf_ok_200 "$(code_ok "$APICODE" && echo 1)" "$APICODE"
  api /authorization
  local pid; pid=$(jget '.data.policies[] | select(.v0=="role:guest" and .v1=="/2000/*") | .id' | head -1)
  [ -n "$pid" ] && POL_IDS="$POL_IDS $pid"
  rm -f "$JAR"
}

# ── T04 API Key 生命周期（token 只出现一次 / guest 边界 / 轮换禁用）
t04_api_keys() {
  api /api-keys -X POST -H 'Content-Type: application/json' -d "{\"name\":\"tcase-guest-$TS\",\"role\":\"guest\"}"
  check t04.create_returns_token_once "$(jget '.data.token' | grep -qE '^ak_[0-9a-f]{64}$' && echo 1)" "$BODY"
  local gk; gk=$(jget '.data.token'); local kid; kid=$(jget '.data.id'); KEY_IDS="$KEY_IDS $kid"
  api /api-keys
  check t04.list_never_has_token "$(jget '[.data[]|select(has("token"))]|length' | grep -qx 0 && echo 1)" "$BODY"
  raw "$API/session" -H "x-api-key: $gk"
  check t04.guest_session_ok "$([ "$APICODE" = 200 ] && echo 1)" "$APICODE"
  check t04.guest_not_admin "$(jget '.data.admin' | grep -qx false && echo 1)"
  raw "$API/users" -H "x-api-key: $gk"
  check t04.guest_users_403 "$([ "$APICODE" = 403 ] && echo 1)" "$APICODE"
  raw "$GATEWAY/_authz/app/guest.html" -H "x-api-key: $gk"
  check t04.guest_diag_200 "$([ "$APICODE" = 200 ] && echo 1)" "$APICODE"
  api "/api-keys/$kid" -X PATCH -H 'Content-Type: application/json' -d '{"enabled":false}'
  raw "$API/session" -H "x-api-key: $gk"
  check t04.disabled_401 "$([ "$APICODE" = 401 ] && echo 1)" "$APICODE"
  api "/api-keys/$kid/rotate" -X POST
  local gk2; gk2=$(jget '.data.token'); check t04.rotate_new_token "$(echo "$gk2" | grep -qE '^ak_[0-9a-f]{64}$' && echo 1)" "$BODY"
  raw "$API/session" -H "x-api-key: $gk"
  check t04.old_token_dead "$([ "$APICODE" = 401 ] && echo 1)" "$APICODE"
  api "/api-keys/$kid" -X DELETE
  check t04.delete_key "$(code_ok "$APICODE" && echo 1)" "$APICODE"
  KEY_IDS=""
}

# ── T05 绑定 + 策略 + 代理链路（含 deny 优先）────────────────
t05_binding_policy_proxy() {
  local PORT ROOT; PORT=18765; ROOT=$(mktemp -d /data/tmp/tcase-root.XXXXXX)
  echo 'authz-ui-test-ok' > "$ROOT/index.html"; echo 'secret' > "$ROOT/secret.html"
  python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT" >/dev/null 2>&1 & UP_PID=$!
  sleep 0.5
  local dom="tcase$TS"
  api /applications -X POST -H 'Content-Type: application/json' -d "{\"domain\":\"$dom\",\"port\":$PORT,\"menu_name\":\"TCASE\"}"
  check t05.create_binding "$(code_ok "$APICODE" && echo 1)" "$APICODE $BODY"
  api /applications
  BID=$(jget ".data[] | select(.domain==\"$dom\") | .id")
  check t05.binding_lookup "$(echo "$BID" | grep -qE '^[0-9]+$' && echo 1)" "BID=$BID"
  api /applications -X POST -H 'Content-Type: application/json' -d "{\"domain\":\"$dom\",\"port\":$PORT}"
  check t05.duplicate_409 "$([ "$APICODE" = 409 ] && echo 1)" "$APICODE"
  api /policies -X POST -H 'Content-Type: application/json' -d "{\"ptype\":\"p\",\"v0\":\"role:guest\",\"v1\":\"/$PORT/*\",\"v2\":\"GET\"}"
  api /authorization
  local p1; p1=$(jget ".data.policies[] | select(.v0==\"role:guest\" and .v1==\"/$PORT/*\") | .id" | head -1); POL_IDS="$POL_IDS $p1"
  check t05.allow_policy "$(code_ok "$APICODE" && echo 1)" "$APICODE"
  api /policies -X POST -H 'Content-Type: application/json' -d "{\"ptype\":\"p\",\"v0\":\"role:guest\",\"v1\":\"/$PORT/secret.html\",\"v2\":\"*\",\"eft\":\"deny\"}"
  api /authorization
  local p2; p2=$(jget ".data.policies[] | select(.v0==\"role:guest\" and .v1==\"/$PORT/secret.html\") | .id" | head -1); POL_IDS="$POL_IDS $p2"
  check t05.deny_policy "$(code_ok "$APICODE" && echo 1)" "$APICODE"
  api /api-keys -X POST -H 'Content-Type: application/json' -d "{\"name\":\"tcase-proxy-$TS\",\"role\":\"guest\"}"
  local gk kid2; gk=$(jget '.data.token'); kid2=$(jget '.data.id'); KEY_IDS="$KEY_IDS $kid2"
  # 代理：数字前缀动态入口 + guest Key
  raw "$GATEWAY/" -H "x-api-key: $gk" -H "Host: ${PORT}-tcase.local"
  check t05.proxy_200_body "$(echo "$BODY" | grep -q 'authz-ui-test-ok' && echo 1)" "$APICODE"
  raw "$GATEWAY/secret.html" -H "x-api-key: $gk" -H "Host: ${PORT}-tcase.local"
  check t05.deny_priority_403 "$([ "$APICODE" = 403 ] && echo 1)" "$APICODE"
  raw "$GATEWAY/" -H "Host: ${PORT}-tcase.local"
  check t05.proxy_unauth_302 "$([ "$APICODE" = 302 ] && echo 1)" "$APICODE"
  # 菜单注入项编辑（binding key）
  api "/menu-services/binding:$BID" -X PATCH -H 'Content-Type: application/json' -d '{"label":"TCASE-RENAMED"}'
  api /menu-services
  check t05.menu_service_patch "$(jget ".data.domains[] | select(.menu_key==\"binding:$BID\") | .label" | grep -qx 'TCASE-RENAMED' && echo 1)" "$BODY"
  api "/menu-services/binding:$BID" -X DELETE
  check t05.menu_service_reset "$(code_ok "$APICODE" && echo 1)" "$APICODE"
  api "/applications/$BID" -X DELETE; check t05.delete_binding "$(code_ok "$APICODE" && echo 1)" "$APICODE"
  api "/api-keys/$kid2" -X DELETE
  api "/policies/$p1" -X DELETE; api "/policies/$p2" -X DELETE
  KEY_IDS=""; BID=""
  kill "$UP_PID" 2>/dev/null; UP_PID=""; rm -rf "$ROOT"
}

# ── T06 菜单树结构 ───────────────────────────────────────────
t06_menu_tree() {
  api /menu-tree
  check t06.tree_200 "$([ "$APICODE" = 200 ] && echo 1)" "$APICODE"
  check t06.builtin_domains_group "$(jget '.data.groups[] | select(.builtin=="domains") | .id' | grep -qE '^[0-9]+$' && echo 1)"
  check t06.builtin_local_group "$(jget '.data.groups[] | select(.builtin=="local") | .id' | grep -qE '^[0-9]+$' && echo 1)"
  api /menu-services
  check t06.services_rows "$(jget '.data.domains' | grep -q binding: && echo 1)"
}

# ── T07 nginx conf 读取与校验（只读，不落盘）─────────────────
t07_nginx_conf() {
  api /nginx-conf
  check t07.read_200 "$([ "$APICODE" = 200 ] && echo 1)" "$APICODE"
  check t07.three_files "$(echo "$BODY" | grep -q stream_inc.conf && echo "$BODY" | grep -q server_inc.conf && echo "$BODY" | grep -q http_inc.conf && echo 1)"
  api /nginx-conf/validate -X POST -H 'Content-Type: application/json' -d '{"name":"server_inc.conf","content":"this is not nginx config {"}'
  check t07.validate_rejects_bad "$(jget '.data.ok' | grep -qx false && echo 1)" "$BODY"
}

# ── T08 文件浏览 ─────────────────────────────────────────────
t08_files() {
  api '/files?path='
  check t08.list_200 "$([ "$APICODE" = 200 ] && echo 1)" "$APICODE"
}

run() { local f="$1"; shift; should_run "${f%%_*}" || return 0; echo "── $f"; "$f" || true; }
run t01_smoke; run t02_authz_boundary; run t03_users_lifecycle; run t04_api_keys
run t05_binding_policy_proxy; run t06_menu_tree; run t07_nginx_conf; run t08_files

echo
echo "RESULT: pass=$PASS fail=$FAIL"
[ -n "$FAILED" ] && echo "failed:$FAILED"
[ "$FAIL" = 0 ]
