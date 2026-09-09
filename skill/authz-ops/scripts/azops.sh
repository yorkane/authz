#!/usr/bin/env bash
# authz 日常运维助手：健康巡检 / 备份 / 日志。只读操作，不改动实例状态。
# 用法:
#   azops.sh check  [-c 容器名] [-p https端口]
#   azops.sh backup [-d 数据目录] [-o 备份目录]
#   azops.sh logs   [-c 容器名] [-n 行数或分钟如10m]
set -u

CONTAINER="${CONTAINER:-authz}"
HTTPS_PORT="${HTTPS_PORT:-6443}"
DATA_DIR="${DATA_DIR:-./data}"
BACKUP_DIR="${BACKUP_DIR:-/data/tmp/authz-db-backup}"
N="${N:-50}"

usage() {
    echo "用法: $0 {check|backup|logs} [选项]" >&2
    echo "  check  健康巡检 -c 容器名(默认authz) -p 端口(默认6443)" >&2
    echo "  backup 备份SQLite与证书 -d 数据目录(默认./data) -o 备份目录" >&2
    echo "  logs   查看日志 -c 容器名 -n 行数或分钟(默认50)" >&2
    exit 2
}

ok=0; bad=0
pass() { printf "PASS %s\n" "$1"; ok=$((ok + 1)); }
fail() { printf "FAIL %s (%s)\n" "$1" "${2:-}"; bad=$((bad + 1)); }

cmd="${1:-}"; shift || true
while getopts ":c:p:d:o:n:" opt; do
    case "$opt" in
        c) CONTAINER="$OPTARG" ;;
        p) HTTPS_PORT="$OPTARG" ;;
        d) DATA_DIR="$OPTARG" ;;
        o) BACKUP_DIR="$OPTARG" ;;
        n) N="$OPTARG" ;;
        *) usage ;;
    esac
done

do_check() {
    local base="https://127.0.0.1:${HTTPS_PORT}" state net code
    state=$(docker inspect "$CONTAINER" --format "{{.State.Status}}" 2>/dev/null || echo missing)
    net=$(docker inspect "$CONTAINER" --format "{{.HostConfig.NetworkMode}}" 2>/dev/null || echo unknown)
    if [ "$state" = "running" ] && [ "$net" = "host" ]; then
        pass "容器 running + host 网络"
    else
        fail "容器状态" "state=$state network=$net (期望 running host)"
    fi
    if docker exec "$CONTAINER" openresty -t >/dev/null 2>&1; then
        pass "nginx 配置语法"
    else
        fail "nginx 配置语法" "docker exec $CONTAINER openresty -t"
    fi
    code=$(curl -sSk -o /dev/null -w "%{http_code}" --max-time 5 "$base/_authz/login" 2>/dev/null || echo 000)
    [ "$code" = "200" ] && pass "登录页 200" || fail "登录页" "got $code 期望 200"
    code=$(curl -sSk -o /dev/null -w "%{http_code}" --max-time 5 "$base/_authz/api/session" 2>/dev/null || echo 000)
    [ "$code" = "401" ] && pass "未认证 session 401" || fail "未认证 session" "got $code 期望 401"
    code=$(curl -sSk -o /dev/null -w "%{http_code}" --max-time 5 "$base/_authz/apps/" 2>/dev/null || echo 000)
    [ "$code" = "302" ] && pass "管理入口 302" || fail "管理入口" "got $code 期望 302"
    printf "\n巡检结果: pass=%d fail=%d\n" "$ok" "$bad"
    [ "$bad" -eq 0 ]
}

do_backup() {
    local ts db dest
    ts=$(date +%Y%m%d-%H%M%S)
    db="$DATA_DIR/authz/authz.db"
    if [ ! -f "$db" ]; then echo "错误: 未找到数据库 $db" >&2; exit 1; fi
    mkdir -p "$BACKUP_DIR"
    cp "$db" "$BACKUP_DIR/authz-$ts.db" || { echo "备份失败" >&2; exit 1; }
    echo "数据库已备份: $BACKUP_DIR/authz-$ts.db"
    if [ -d "$DATA_DIR/certs" ]; then
        dest="$BACKUP_DIR/certs-$ts"
        # 证书私钥常为 0600 且属 root，读不到是预期情况：提示但不算备份失败，
        # 数据库才是恢复的关键资产。
        if cp -r "$DATA_DIR/certs" "$dest" 2>/dev/null; then
            echo "证书已备份: $dest"
        else
            echo "提示: 证书目录读取受限（私钥受保护），已跳过；数据库已备份完整" >&2
            rm -rf "$dest" 2>/dev/null || true
        fi
    fi
}

do_logs() {
    if [[ "$N" == *m ]]; then
        docker logs --since "$N" "$CONTAINER" 2>&1 | tail -60
    else
        docker logs --tail "$N" "$CONTAINER" 2>&1
    fi
}

case "$cmd" in
    check)  do_check ;;
    backup) do_backup ;;
    logs)   do_logs ;;
    *)      usage ;;
esac
