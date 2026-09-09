#!/bin/sh
# openresty-base gateway entrypoint
# 1. 生成自签默认证书 (如缺失)
# 2. envsubst 渲染 nginx.conf 与 server.conf
# 3. 启动 openresty

set -e

HTTP_PORT="${AUTHZ_HTTP_PORT:-6080}"
HTTPS_PORT="${AUTHZ_HTTPS_PORT:-6443}"
HTTP_MODE="${AUTHZ_HTTP_MODE:-redirect}"
WORKER_PROCESSES="${NGINX_WORKER_PROCESSES:-4}"
CERT_DIR="${AUTHZ_CERT_DIR:-/data/certs}"
DB_PATH="${AUTHZ_DB_PATH:-/data/authz/authz.db}"
DNS_RESOLVER="${AUTHZ_DNS_RESOLVER:-$(awk '/^nameserver[[:space:]]+/ { print $2; exit }' /etc/resolv.conf)}"
DNS_RESOLVER="${DNS_RESOLVER:-1.1.1.1}"
CERT_FILE="$CERT_DIR/default.crt"
CERT_KEY="$CERT_DIR/default.key"

OPENSSL_BIN="/usr/local/openresty/openssl3/bin/openssl"
OPENSSL_CONF_FILE="/usr/local/openresty/nginx/conf/openssl.cnf"
NGINX_CONF_DIR="/usr/local/openresty/nginx/conf"
TEMPLATE_DIR="${OPENRESTY_TEMPLATE_DIR:-$NGINX_CONF_DIR}"
NGINX_TEMPLATE_FILE="$TEMPLATE_DIR/nginx.conf.template"
SERVER_TEMPLATE_FILE="$TEMPLATE_DIR/server.conf.template"

case "$HTTP_PORT:$HTTPS_PORT" in
    *[!0-9:]*|:*|*:) echo "error: AUTHZ_HTTP_PORT and AUTHZ_HTTPS_PORT must be numeric" >&2; exit 1 ;;
esac
if [ "$HTTP_PORT" -lt 1 ] || [ "$HTTP_PORT" -gt 65535 ] ||
    [ "$HTTPS_PORT" -lt 1 ] || [ "$HTTPS_PORT" -gt 65535 ]; then
    echo "error: AUTHZ_HTTP_PORT and AUTHZ_HTTPS_PORT must be 1-65535" >&2
    exit 1
fi

case "$HTTP_MODE" in
    serve)
        HTTP_LISTEN="$HTTP_PORT"
        HTTP_SERVER_DIRECTIVE="include server.conf;"
        ;;
    redirect)
        HTTP_LISTEN="$HTTP_PORT"
        if [ "$HTTPS_PORT" -eq 443 ]; then
            HTTP_SERVER_DIRECTIVE='return 308 https://$host$request_uri;'
        else
            HTTP_SERVER_DIRECTIVE='return 308 https://$host:'"$HTTPS_PORT"'$request_uri;'
        fi
        ;;
    disabled)
        HTTP_LISTEN="127.0.0.1:$HTTP_PORT"
        HTTP_SERVER_DIRECTIVE="return 404;"
        ;;
    *)
        echo "error: AUTHZ_HTTP_MODE must be redirect, disabled, or serve" >&2
        exit 1
        ;;
esac

mkdir -p "$(dirname "$DB_PATH")" "$CERT_DIR" /var/log/openresty

# ── 自签默认证书 (10 年, SAN: DNS:*) ─────────────────────────────
if [ ! -s "$CERT_FILE" ] || [ ! -s "$CERT_KEY" ]; then
    echo "==> generating default self-signed certificate ..."
    OPENSSL_CONF="$OPENSSL_CONF_FILE" "$OPENSSL_BIN" req -x509 -newkey rsa:2048 -nodes \
        -keyout "$CERT_KEY" -out "$CERT_FILE" \
        -days 3650 \
        -subj "/CN=openresty-gateway" \
        -addext "subjectAltName=DNS:*" >/dev/null 2>&1
fi

# ── 渲染运行时 Nginx 配置 ──────────────────────────────────────
export HTTP_LISTEN HTTP_SERVER_DIRECTIVE HTTPS_PORT WORKER_PROCESSES CERT_FILE CERT_KEY DNS_RESOLVER
TEMPLATE_VARIABLES='${HTTP_LISTEN} ${HTTP_SERVER_DIRECTIVE} ${HTTPS_PORT} ${WORKER_PROCESSES} ${CERT_FILE} ${CERT_KEY} ${DNS_RESOLVER}'

for template_file in "$NGINX_TEMPLATE_FILE" "$SERVER_TEMPLATE_FILE"; do
    if [ ! -s "$template_file" ]; then
        echo "error: missing runtime template: $template_file" >&2
        exit 1
    fi
done

render_template() {
    input_file="$1"
    output_file="$2"
    temporary_file="${output_file}.tmp.$$"
    envsubst "$TEMPLATE_VARIABLES" < "$input_file" > "$temporary_file"
    mv "$temporary_file" "$output_file"
}

render_template "$SERVER_TEMPLATE_FILE" "$NGINX_CONF_DIR/server.conf"
render_template "$NGINX_TEMPLATE_FILE" "$NGINX_CONF_DIR/nginx.conf"

# ── 外置用户自定义 include 文件（缺失时动态生成默认内容）──────
# 三个文件由用户在挂载的 conf/（TEMPLATE_DIR）目录中编辑；
# 启动时若缺失，则自动生成带注释的默认内容，保证 nginx 可用。
HTTP_INC_FILE="$TEMPLATE_DIR/http_inc.conf"
SERVER_INC_FILE="$TEMPLATE_DIR/server_inc.conf"
STREAM_INC_FILE="$TEMPLATE_DIR/stream_inc.conf"

default_http_inc() {
    cat <<'EOF'
# ============================================================
# http_inc.conf — 用户自定义 http{} 层附加配置
#
# 本文件由入口脚本在缺失时自动生成，可自由编辑。
# 它会被 include 到 nginx.conf 的 http{} 块末尾，可在此添加：
#   - server { ... }         自定义站点/端口
#   - upstream { ... }       后端池
#   - map / lua_shared_dict  等 http 级指令
#
# 修改后重建或重启容器生效；语法错误会导致 nginx 无法启动，
# 可先执行: docker exec <容器> openresty -t 验证。
# ============================================================
EOF
}

default_server_inc() {
    cat <<'EOF'
# ============================================================
# server_inc.conf — 用户自定义 server 级附加配置
#
# 本文件由入口脚本在缺失时自动生成，可自由编辑。
# 它会被 include 到网关 server 配置（server.conf）的最末尾，
# 对 HTTP 与 HTTPS 入口同时生效。可在此追加 location、
# 覆盖网关行为，例如健康检查、静态缓存规则、额外反代入口。
#
# 注意：本文件位于网关配置末尾，同路径的 location 会覆盖
# 网关内置行为。修改后重建或重启容器生效，可先执行
# docker exec <容器> openresty -t 验证。
# ============================================================

location = /favicon.ico {
	empty_gif;
	expires 2y;
	return 204;
	access_log     off;
}

#slb heatbeat testing
location = /noc.gif {
    access_log     off;
	return 200;
}
EOF
}

default_stream_inc() {
    cat <<'EOF'
# ============================================================
# stream_inc.conf — 用户自定义 stream{} 层附加配置
#
# 本文件由入口脚本在缺失时自动生成，可自由编辑。
# 它会被 include 到 nginx.conf 的 stream{} 块，可在此添加
# 四层（TCP/UDP）代理，例如：
#
#   server {
#       listen 13306;
#       proxy_pass db.example.com:3306;
#   }
#
# 修改后重建或重启容器生效；语法错误会导致 nginx 无法启动，
# 可先执行: docker exec <容器> openresty -t 验证。
# ============================================================
EOF
}

# 用户在 TEMPLATE_DIR 中存在该文件（哪怕为空，视为“我特意清空了自定义”）
# 即采用用户版本；只有文件完全不存在时才生成默认内容。
install_include() {
    source_file="$1"
    target_file="$2"
    generator="$3"
    if [ -e "$source_file" ]; then
        echo "==> using user-provided $(basename "$source_file")"
        # TEMPLATE_DIR 与 NGINX_CONF_DIR 相同（镜像内置模式）时无需复制
        if [ "$(readlink -f "$source_file")" != "$(readlink -f "$target_file")" ]; then
            cp "$source_file" "$target_file"
        fi
    else
        echo "==> generating default $(basename "$target_file")"
        "$generator" > "$target_file"
    fi
}

install_include "$HTTP_INC_FILE"   "$NGINX_CONF_DIR/http_inc.conf"   default_http_inc
install_include "$SERVER_INC_FILE" "$NGINX_CONF_DIR/server_inc.conf" default_server_inc
install_include "$STREAM_INC_FILE" "$NGINX_CONF_DIR/stream_inc.conf" default_stream_inc

echo "==> rendered nginx configuration from $TEMPLATE_DIR"

echo "==> starting openresty gateway (http:$HTTP_PORT mode:$HTTP_MODE https:$HTTPS_PORT)"

exec "$@"
