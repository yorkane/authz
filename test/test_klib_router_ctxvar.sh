#!/usr/bin/env bash
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${OPENRESTY_TEST_IMAGE:-ghcr.io/yorkane/authz:latest}
CONTAINER_NAME="klib-router-ctxvar-test-$$"
TMP_DIR=$(mktemp -d)
PASSED=0

cleanup() {
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    docker logs "$CONTAINER_NAME" 2>&1 | tail -n 80 >&2 || true
    exit 1
}

pass() {
    PASSED=$((PASSED + 1))
    printf 'PASS: %s\n' "$1"
}

assert_eq() {
    local name=$1 actual=$2 expected=$3
    if [[ "$actual" != "$expected" ]]; then
        fail "$name (expected '$expected', got '$actual')"
    fi
    pass "$name"
}

assert_contains() {
    local name=$1 actual=$2 expected=$3
    if [[ "$actual" != *"$expected"* ]]; then
        fail "$name (missing '$expected' in '$actual')"
    fi
    pass "$name"
}

assert_not_contains() {
    local name=$1 actual=$2 unexpected=$3
    if [[ "$actual" == *"$unexpected"* ]]; then
        fail "$name (unexpected '$unexpected' in '$actual')"
    fi
    pass "$name"
}

assert_json() {
    local name=$1 filter=$2 expected=$3 actual
    if ! actual=$(jq -er "$filter" "$TMP_DIR/body" 2>"$TMP_DIR/jq-error"); then
        fail "$name (invalid JSON/filter: $(<"$TMP_DIR/jq-error"))"
    fi
    assert_eq "$name" "$actual" "$expected"
}

request() {
    local method=$1 path=$2
    shift 2
    : >"$TMP_DIR/body"
    : >"$TMP_DIR/headers"
    if [[ "$method" == HEAD ]]; then
        STATUS=$(curl -sS --head "$BASE_URL$path" "$@" -D "$TMP_DIR/headers" -o /dev/null -w '%{http_code}')
    else
        STATUS=$(curl -sS --request "$method" "$BASE_URL$path" "$@" -D "$TMP_DIR/headers" -o "$TMP_DIR/body" -w '%{http_code}')
    fi
    BODY=$(<"$TMP_DIR/body")
    CONTENT_TYPE=$(awk 'BEGIN { IGNORECASE=1 } /^Content-Type:/ { sub(/^[^:]+:[[:space:]]*/, ""); sub(/\r$/, ""); value=$0 } END { print value }' "$TMP_DIR/headers")
}

command -v docker >/dev/null || fail "docker is required"
command -v curl >/dev/null || fail "curl is required"
command -v jq >/dev/null || fail "jq is required"

docker run --rm \
    -v "$REPO_DIR:/repo:ro" \
    "$IMAGE" \
    openresty -t -p /usr/local/openresty/nginx/ -c /repo/test/conf/nginx-klib.conf >/dev/null
pass "OpenResty configuration"

docker run -d \
    --name "$CONTAINER_NAME" \
    -p 127.0.0.1::8081 \
    -v "$REPO_DIR:/repo:ro" \
    "$IMAGE" \
    openresty -p /usr/local/openresty/nginx/ -c /repo/test/conf/nginx-klib.conf -g 'daemon off;' >/dev/null

HOST_PORT=$(docker port "$CONTAINER_NAME" 8081/tcp | awk -F: 'NR == 1 { print $NF }')
BASE_URL="http://127.0.0.1:$HOST_PORT"
for _ in $(seq 1 50); do
    if curl -fsS "$BASE_URL/klib/load" >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
curl -fsS "$BASE_URL/klib/load" >"$TMP_DIR/load" || fail "OpenResty did not become ready"
assert_contains "klib.router module load" "$(<"$TMP_DIR/load")" "klib.router: OK"
assert_contains "klib.ctxvar module load" "$(<"$TMP_DIR/load")" "klib.ctxvar: OK"

request GET /_api_/tracker
assert_eq "mismatched location and router root" "$STATUS" "404"
request GET /tracker
assert_eq "root route without trailing slash status" "$STATUS" "200"
assert_eq "root route without trailing slash body" "$BODY" "ok"
request GET /tracker/
assert_eq "root route with trailing slash" "$BODY" "ok"

request GET /tracker/users/me
assert_json "static route precedence" '.route' "static"
assert_eq "table response JSON content type" "$CONTENT_TYPE" "application/json; charset=UTF-8"
request GET /tracker/users/42
assert_json "parameter route" '.id' "42"
request GET /tracker/pair/left-value/fixed/right-value
assert_json "multi-parameter route left" '.left' "left-value"
assert_json "multi-parameter route right" '.right' "right-value"

for method in GET POST PUT DELETE OPTIONS PATCH; do
    request "$method" /tracker/method
    assert_eq "$method route status" "$STATUS" "200"
    assert_json "$method route dispatch" '.method' "$method"
done
request HEAD /tracker/method
assert_eq "HEAD route status" "$STATUS" "200"
assert_eq "HEAD response body suppressed" "$BODY" ""
request POST /tracker/users/me
assert_eq "method mismatch" "$STATUS" "404"

request GET '/tracker/query?foo=bar&multi=one&multi=two'
assert_json "query argument" '.query.foo' "bar"
assert_json "multi-value query argument" '.query.multi | join(",")' "one,two"
assert_json "request URI with normal query" '.request_uri' "/tracker/query?foo=bar&multi=one&multi=two"
request GET '/tracker/query?a=1'
assert_json "known short-query request_uri behavior" '.request_uri' "/tracker/query"
assert_json "short query remains available as query_string" '.query_string' "a=1"

request POST /tracker/body -H 'Content-Type: application/json' --data '{"a":1}'
assert_json "JSON request body" '.body.a' "1"
assert_json "JSON request detection" '.is_json | tostring' "true"
assert_json "JSON helper header return type" '.helper_header_type' "table"
request POST /tracker/body -H 'Content-Type: application/x-www-form-urlencoded' --data 'a=1&b=two'
assert_json "form request body" '.body.b' "two"
assert_json "form helper header return type" '.helper_header_type' "string"
request POST /tracker/body
assert_eq "empty-body helper status" "$STATUS" "200"
assert_json "empty-body helper result" '.body' ""

request POST /tracker/api-body -H 'Content-Type: application/json' -H 'x-csrf-token: router-csrf' --data '{"a":1}'
assert_eq "strict JSON body status" "$STATUS" "200"
assert_json "strict JSON body value" '.body.a' "1"
assert_json "case-insensitive request header" '.csrf' "router-csrf"
request POST /tracker/api-body -H 'Content-Type: application/x-www-form-urlencoded' --data 'a=1&b=two'
assert_json "strict form body" '.body.b' "two"
request POST /tracker/api-body -H 'Content-Type: application/json' --data '{bad-json'
assert_eq "malformed JSON body status" "$STATUS" "400"
assert_contains "malformed JSON body error" "$BODY" "invalid JSON body"
request POST /tracker/api-body -H 'Content-Type: application/json' --data '1'
assert_eq "scalar JSON body status" "$STATUS" "400"
assert_contains "scalar JSON body requires object" "$BODY" "object required"
request POST /tracker/api-body -H 'Content-Type: text/plain' --data 'plain'
assert_eq "unsupported body type status" "$STATUS" "400"
assert_json "unsupported body type error" '.error' "Content-Type must be application/json"
request POST /tracker/api-body
assert_eq "strict empty body status" "$STATUS" "200"
assert_json "strict empty body object" '.body | length' "0"

request GET '/tracker/context?long=123' \
    -H 'Host: api.l2.example.com' \
    -H 'X-Klib-Test: header-ok' \
    -H 'Cookie: klib_cookie=cookie-ok' \
    -H 'X-Forwarded-For: 203.0.113.9'
assert_eq "ctxvar context route status" "$STATUS" "200"
assert_json "request-scoped ctxvar cache" '.same_env | tostring' "true"
assert_json "ctxvar request header" '.header' "header-ok"
assert_json "ctxvar cookie" '.cookie' "cookie-ok"
assert_json "ctxvar forwarded IP" '.ip' "203.0.113.9"
assert_json "ctxvar level-1 domain" '.host_1' "example.com"
assert_json "ctxvar level-2 domain" '.host_2' "l2.example.com"
assert_json "ctxvar variable formatter" '.formatted' "api.l2.example.com:GET"
assert_json "ctxvar path normalization" '.normalized_path' "/a/b/c"
assert_json "known absolute URL normalization behavior" '.normalized_absolute' "http://exxample.test/a/b"
assert_json "ctxvar file suffix" '.suffix' "min.js"
assert_json "seeded timer ctxvar" '.timer_seeded_ok | tostring' "true"
assert_json "timer ngx adapter" '.timer_ngx_ok | tostring' "true"
assert_json "known pre_access callback argument" '.pre_access_func_is_nil | tostring' "true"

request GET /tracker/asset.js
assert_json "static file suffix" '.file_format' "js"
assert_json "static request detection" '.is_static | tostring' "true"
request GET /tracker/template
assert_eq "inline resty.template rendering" "$BODY" '<h1>klib</h1>'
assert_contains "template content type" "$CONTENT_TYPE" "text/html"

request GET /tracker/created
assert_eq "handler status return" "$STATUS" "201"
assert_json "handler status response body" '.created | tostring' "true"
request GET /tracker/empty-created
assert_eq "empty handler status return" "$STATUS" "201"
assert_eq "empty handler response body" "$BODY" ""
request GET /tracker/numeric-return
assert_eq "numeric-only return status" "$STATUS" "404"
assert_eq "numeric-only return body" "$BODY" ""

request GET /tracker/boom -H 'X-Router-Secret: must-not-leak'
assert_eq "handler exception status" "$STATUS" "500"
assert_contains "handler exception body" "$BODY" "router boom"
assert_not_contains "error response hides request header name" "$BODY" "X-Router-Secret"
assert_not_contains "error response hides request header value" "$BODY" "must-not-leak"
request GET /tracker/missing -H 'Content-Type: application/json'
assert_eq "unknown route status" "$STATUS" "404"
assert_eq "JSON error content type" "$CONTENT_TYPE" "application/json; charset=UTF-8"
assert_json "JSON error response" '.err' "No router match to : /tracker/missing"

request GET /tracker/p/metrics
assert_contains "merged child route" "$BODY" "tracker_metric 1"
assert_contains "merged child filter" "$BODY" "filtered:"
request GET /tracker/p/view
assert_eq "known merge template loss content type" "$CONTENT_TYPE" "application/json; charset=UTF-8"
assert_contains "known merge template loss body" "$BODY" 'filtered:{"name":"child"}'

request GET /tracker/module-loads
assert_json "router module initial load count" '.loads' "1"
request GET /tracker/module-loads
assert_json "router reused in worker" '.loads' "1"
request GET /tracker/registration
assert_contains "duplicate route rejected" "$BODY" "duplicate func register"
assert_contains "unsupported method rejected" "$BODY" "bad method input"
assert_json "known add_access failure" '.add_access_ok | tostring' "false"
assert_json "child router merge succeeds" '.merge_ok | tostring' "true"
assert_json "child router merge route count" '.merge_count | tostring' "2"
assert_json "duplicate child merge rejected" '.duplicate_merge_ok == null | tostring' "true"
assert_contains "duplicate child merge error returned" "$BODY" "duplicate func register"

# Run this destructive ctxvar timer regression last: unseeded timer mode mutates
# the module-level request-header prototype in the current worker.
request GET /klib/timer-unseeded
assert_eq "unseeded timer ctxvar initially returns" "$STATUS" "200"
assert_eq "unseeded timer ctxvar mode" "$BODY" "is_timer=true"
request GET '/tracker/context?long=123' -H 'X-Klib-Test: after-unseeded-timer'
assert_eq "known unseeded timer header corruption" "$STATUS" "500"
assert_contains "unseeded timer corruption source" "$BODY" "loop in gettable"

printf '\nAll %d klib router/ctxvar checks passed.\n' "$PASSED"
