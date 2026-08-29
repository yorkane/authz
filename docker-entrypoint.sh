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
AGENT_API_KEY_LINE=''
if [ -n "$AUTHZ_AGENT_API_KEY" ]; then
    AGENT_API_KEY_LINE="env AUTHZ_AGENT_API_KEY;"
fi
export AGENT_API_KEY_LINE
TEMPLATE_VARIABLES='${HTTP_LISTEN} ${HTTP_SERVER_DIRECTIVE} ${HTTPS_PORT} ${WORKER_PROCESSES} ${CERT_FILE} ${CERT_KEY} ${DNS_RESOLVER} ${AGENT_API_KEY_LINE}'

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

echo "==> rendered nginx configuration from $TEMPLATE_DIR"

echo "==> starting openresty gateway (http:$HTTP_PORT mode:$HTTP_MODE https:$HTTPS_PORT)"

exec "$@"
