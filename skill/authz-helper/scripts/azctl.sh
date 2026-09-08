#!/usr/bin/env bash
# azctl.sh — Authz Gateway 控制面 API 小助手（只读 + 最小写操作）
# 用法: azctl.sh -g <网关地址> -k <x-api-key值> <命令> [参数...]
#   网关地址默认 http://127.0.0.1:6080；key 可省略 -k，改用环境变量 AUTHZ_API_KEY。
# 命令:
#   smoke                     读 /session 自检（凭证 + 连通性 + 角色）
#   menu                      读 /menu-tree
#   apps-list                 读 /applications
#   apps-add  <domain> <port> [menu_name] [target_ip]   新建绑定（domain 只填前缀）
#   apps-patch <id> <json>    按 JSON 部分更新绑定，如 '{"enabled":false}'
#   apps-del   <id>
#   pol-list                  读 /authorization（策略 + 绑定 + 主体）
#   pol-add  <v0> <v1> <v2> [deny]   新建 p 策略，如 role:staff /2077/* *
#   pol-del  <id>
#   keys-list                 读 /api-keys
#   keys-add  <name> [role]   新建 API Key（默认 guest）；token 只打印一次
#   keys-patch <id> <json>    部分更新 Key，如 '{"enabled":false}'
#   keys-del   <id>
set -euo pipefail

GATEWAY="http://127.0.0.1:6080"
KEY=""

usage() { sed -n '2,19p' "$0"; exit 64; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g) GATEWAY="$2"; shift 2 ;;
    -k) KEY="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) break ;;
  esac
done
[[ $# -ge 1 ]] || usage
[[ -n "$KEY" || -n "${AUTHZ_API_KEY:-}" ]] || { echo "缺少 key：-k 或环境变量 AUTHZ_API_KEY" >&2; exit 64; }
KEY="${KEY:-$AUTHZ_API_KEY}"

api() { # method path [json-body]
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS -X "$method" -H "x-api-key: $KEY" "${GATEWAY}/_authz/api${path}")
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" -d "$body")
  fi
  curl "${args[@]}" | (command -v jq >/dev/null && jq . || cat)
}

cmd="$1"; shift || true
case "$cmd" in
  smoke)      api GET /session ;;
  menu)       api GET /menu-tree ;;
  apps-list)  api GET /applications ;;
  apps-add)   # domain port [menu_name] [target_ip]
    [[ $# -ge 2 ]] || usage
    domain="$1"; port="$2"; menu_name="${3:-}"; target_ip="${4:-}"
    body=$(jq -n --arg d "$domain" --argjson p "$port" \
      --arg m "$menu_name" --arg t "$target_ip" \
      '{domain:$d, port:$p} + (if $m != "" then {menu_name:$m} else {} end)
       + (if $t != "" then {target_ip:$t} else {} end)')
    api POST /applications "$body" ;;
  apps-patch) [[ $# -ge 2 ]] || usage
    api PATCH "/applications/$1" "$2" ;;
  apps-del)   [[ $# -ge 1 ]] || usage
    api DELETE "/applications/$1" ;;
  pol-list)   api GET /authorization ;;
  pol-add)    # v0 v1 v2 [deny]
    [[ $# -ge 3 ]] || usage
    eft="allow"
    [[ "${4:-}" == "deny" ]] && eft="deny"
    body=$(jq -n --arg v0 "$1" --arg v1 "$2" --arg v2 "$3" --arg eft "$eft" \
      '{ptype:"p", v0:$v0, v1:$v1, v2:$v2} + (if $eft == "deny" then {eft:"deny"} else {} end)')
    api POST /policies "$body" ;;
  pol-del)    [[ $# -ge 1 ]] || usage
    api DELETE "/policies/$1" ;;
  keys-list)  api GET /api-keys ;;
  keys-add)   # name [role]
    [[ $# -ge 1 ]] || usage
    body=$(jq -n --arg n "$1" --arg r "${2:-guest}" '{name:$n, role:$r}')
    api POST /api-keys "$body"
    echo ">> 上面的 token 只出现这一次，请立即保存。" ;;
  keys-patch) [[ $# -ge 2 ]] || usage
    api PATCH "/api-keys/$1" "$2" ;;
  keys-del)   [[ $# -ge 1 ]] || usage
    api DELETE "/api-keys/$1" ;;
  *) usage ;;
esac
