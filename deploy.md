# Authz Gateway 部署手册（deploy.md）

本手册自包含：只需要 **本文件 + 镜像**，即可完成一套可用的 Authz Gateway 部署。
不需要源代码、不需要构建；所有前端、Lua 库与 Nginx 模板都已内置在镜像中。

- 镜像：`ghcr.io/yorkane/authz:latest`（也发布为 `docker.io/yorkane/authz:latest`）
- 能力：动态端口反向代理 + 本地认证授权（SQLite + mini-casbin）+ 管理界面
- 依赖：Docker Engine（生产使用 Linux；需要 host 网络）+ 可选外部 Redis（仅多实例共享会话时需要）

## 1. 架构速览

| 入口 | 端口（默认） | 行为 |
|------|--------------|------|
| HTTP | `6080` | 默认 308 重定向到 HTTPS（`AUTHZ_HTTP_MODE=redirect`）；`disabled` 仅回环；`serve` 才直接代理 |
| HTTPS | `6443` | 网关终止客户端 TLS，再按绑定配置代理 HTTP/HTTPS 上游 |
| 管理界面 | `/_authz/apps/` | 登录、用户、域名绑定、Casbin 策略、API Key |
| 登录页 | `/_authz/login` | 本地账号 + 已启用的 OAuth |

域名解析规则（由外到内优先匹配）：

1. **显式绑定**：管理界面配置的固定域名 → `target_ip:port`；
2. **数字前缀子域名**（免配置）：`3000-任意域名` → 本机 `3000` 端口（范围 `AUTHZ_PORT_MIN`~`AUTHZ_PORT_MAX`）；
3. 其余域名 → 404。

所有代理流量默认要求登录 + Casbin 授权；后端会收到 `X-Authz-User` / `X-Authz-Source` / `X-Authz-Identity` 头。

## 2. 前置条件检查（部署前必须执行）

```bash
# Docker 可用
docker info >/dev/null 2>&1 || { echo "Docker 未就绪"; exit 1; }

# 拉取镜像（amd64/arm64 均已发布）
docker pull ghcr.io/yorkane/authz:latest

# 入口端口未被占用（默认 6080/6443；被占用时在 .env 中更换）
(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -E ":(6080|6443) " && echo "端口冲突，请更换" || echo "端口可用"
```

必须使用 **host 网络**：网关需要直接访问宿主机 `127.0.0.1` 上被代理的服务。
Docker Desktop（macOS/Windows）的 host 网络语义与 Linux 不同，容器内无法到达宿主 `127.0.0.1` 的业务服务，生产请使用 Linux。

## 3. 最小部署（推荐）

在工作目录（例如 `/opt/authz-gateway`）创建 `.env` 与 `docker-compose.yml`，然后 `docker compose up -d`。
这种方式**不挂载任何代码**，全部使用镜像内置文件，是最干净的生产形态。

### 3.1 `.env`（最小可用示例）

```bash
# ── 必填 ────────────────────────────────────────────────
# 首次启动创建的 admin 密码（仅 users 表为空时生效，登录后请立即改密）
AUTHZ_ADMIN_PASSWORD=change-me-strong-password
# 对外访问的 Origin（OAuth 回调基准等），没有公网域名时可留空（按请求 Host 推导）
AUTHZ_HOST_URL=https://gateway.example.com
# Cookie 父域：多个子域共享登录时设置，如 .example.com；仅 IP/localhost 访问时留空
AUTHZ_COOKIE_DOMAIN=
# 入口始终为 HTTPS（例如外层有 TLS 反代）时设 true，否则 false
AUTHZ_COOKIE_SECURE=false

# ── 可选：入口端口 ─────────────────────────────────────
AUTHZ_HTTP_PORT=6080
AUTHZ_HTTPS_PORT=6443
AUTHZ_HTTP_MODE=redirect

# ── 可选：动态端口代理范围（默认 2000-20000）────────────
AUTHZ_PORT_MIN=2000
AUTHZ_PORT_MAX=20000

# ── 数据目录（宿主机），必须持久化 ──────────────────────
DATA_DIR=./data
```

> 完整变量清单见附录 A。

### 3.2 `docker-compose.yml`（最小，纯镜像）

```yaml
services:
  gateway:
    image: ghcr.io/yorkane/authz:latest
    container_name: openresty-gateway
    restart: unless-stopped
    network_mode: host
    env_file:
      - .env
    environment:
      # 使用镜像内置模板（不挂载代码时的固定值）
      OPENRESTY_TEMPLATE_DIR: /usr/local/openresty/nginx/conf
    volumes:
      - ${DATA_DIR:-./data}:/data
```

说明：

- `env_file` 直接注入 `.env` 的全部变量；
- 镜像内置模板位于 `/usr/local/openresty/nginx/conf/`，entrypoint 每次启动自动渲染最终配置；
- 只需挂载 `/data`（SQLite 数据库 + 自动生成的 10 年期自签证书），其余全部来自镜像；
- 若不使用 compose，等价 docker 命令：`docker run -d --name openresty-gateway --network host --restart unless-stopped --env-file .env -e OPENRESTY_TEMPLATE_DIR=/usr/local/openresty/nginx/conf -v ./data:/data ghcr.io/yorkane/authz:latest`。

### 3.3 启动

```bash
mkdir -p /opt/authz-gateway && cd /opt/authz-gateway
# 写入 .env 与 docker-compose.yml 后:
docker compose up -d
docker compose logs --tail=20
```

首次启动会自动：建库并 seed `admin` 用户、生成自签证书（`/data/certs`）、渲染 Nginx 配置。

### 3.4 外置 include 配置（自定义 Nginx 规则）

网关在 Nginx 配置中预留了三个外置 include 文件，用于追加用户自定义规则，无需改动模板：

| 文件 | include 位置 | 典型用途 |
| --- | --- | --- |
| `conf/http_inc.conf` | `http {}` 块末尾 | 额外 `server {}`、`upstream {}`、`map`、共享内存 |
| `conf/server_inc.conf` | 网关 `server {}` 最末尾 | 额外 `location`（同路径会覆盖网关内置行为）、健康检查 |
| `conf/stream_inc.conf` | 顶层 `stream {}` 块 | 四层 TCP/UDP 代理 |

启动行为：

- 入口脚本启动时检查这三个文件：存在（哪怕为空）就用用户的版本；不存在则自动生成带注释说明的默认内容，保证 Nginx 始终可用；
- 纯镜像部署（3.2）：镜像已内置三个默认文件，位于 `/usr/local/openresty/nginx/conf/`；需要自定义时用卷覆盖单个文件即可，例如 `-v ./conf/server_inc.conf:/usr/local/openresty/nginx/conf/server_inc.conf:ro`；
- 挂载模板目录部署（宿主机 `conf/` -> `/etc/openresty/templates:ro`）：直接编辑宿主机 `conf/` 下的三个文件，入口脚本会把它们复制进容器内 Nginx 配置目录，重启容器生效；
- 修改后先验证语法再重启：`docker exec <容器> openresty -t`，语法错误会导致 Nginx 无法启动；
- 内置示例：`server_inc.conf` 默认带 `location = /favicon.ico`（`empty_gif` + 204）与 `location = /noc.gif`（200，供 SLB 健康检查），均关闭访问日志。

验证 include 已生效：

```bash
curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1:6443/favicon.ico   # 204
curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1:6443/noc.gif       # 200
```

## 4. 部署后验证（逐项执行，全部通过才算成功）

```bash
HTTP_PORT=6080    # 与 .env 保持一致
HTTPS_PORT=6443

# 1) HTTP 入口 → 308 重定向到 HTTPS（AUTHZ_HTTP_MODE=redirect 时）
curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:${HTTP_PORT}/_authz/login"

# 2) HTTPS 登录页 → 200（自签证书需要 -k）
curl -skS -o /dev/null -w "%{http_code}" "https://127.0.0.1:${HTTPS_PORT}/_authz/login"

# 3) 未认证 session API → 401
curl -skS -o /dev/null -w "%{http_code}" "https://127.0.0.1:${HTTPS_PORT}/_authz/api/session"

# 4) Admin 入口 → 302（未登录跳转登录页）
curl -skS -o /dev/null -w "%{http_code}" "https://127.0.0.1:${HTTPS_PORT}/_authz/apps/"

# 5) 管理员登录（用 .env 中的密码）→ 302 且响应头带 authz_session Cookie
curl -skS -D - -o /dev/null -X POST "https://127.0.0.1:${HTTPS_PORT}/_authz/login"   --data-urlencode "username=admin" --data-urlencode "password=change-me-strong-password"   | grep -i "set-cookie\|location"
```

浏览器访问 `https://<host>:6443/_authz/apps/`（公网会自动从 HTTP 跳到 HTTPS），用 `admin` + `.env` 密码登录，**登录后立即在个人资料页改密**。

临时维护提示：若必须短暂开放 HTTP 或限制管理端来源，用防火墙白名单（例如 `ufw allow from 203.0.113.5 to any port 6080` 或 `iptables -A INPUT -p tcp --dport 6080 -s 203.0.113.5 -j ACCEPT`），完成后恢复默认；不要在生产长期保留明文入口。

## 5. 域名与对外接入（通用指引）

网关自带 10 年期自签证书（SAN: DNS:*），按以下任一方式暴露：

1. **直接暴露 6443**：浏览器会告警自签证书，适合内网/测试；
2. **外层 TLS 反代**（推荐）：把 `*.your-domain.com:443` 通配域名指到网关的 `6443`（或 `6080`），并在 `.env` 设置：

   ```bash
   AUTHZ_HOST_URL=https://your-domain.com          # 实际对外 Origin（带端口则写端口，如 :99）
   AUTHZ_COOKIE_DOMAIN=.your-domain.com            # 子域共享登录必需（去掉首个 label 的父域）
   AUTHZ_COOKIE_SECURE=true                        # 反代终止 TLS 时必须，否则 Cookie 不下发 Secure
   ```

外层反代（APISIX/Nginx 等）建议：开启 WebSocket（`enable_websocket=true`）、透传 `Host`、正确设置 `X-Forwarded-Proto`（网关依据它决定 Cookie Secure）。

典型用法：配置通配路由 `*-your-domain.com` → 网关；之后 `3000-xxx.your-domain.com` 自动代理本机 3000 端口，管理界面新增的域名绑定即刻生效，无需改反代。

## 6. 常用运维操作

| 场景 | 命令 |
|------|------|
| 改了 `.env` / 挂载 / 网络 | `docker compose up -d --force-recreate`（必须**重建**容器，`restart` 不会读取新环境变量） |
| 检查容器内配置 | `docker exec openresty-gateway openresty -t` |
| 忘记 admin 密码 / 恢复初始密码 | `docker exec -e AUTHZ_ADMIN_PASSWORD="新密码" openresty-gateway admin_password_reset` |
| 备份 | 复制 `${DATA_DIR}`（含 `authz/authz.db` 与 `certs/`） |
| 查看日志 | `docker logs -f openresty-gateway`（access 走 stdout，error 走 stderr） |
| 容器状态核对 | `docker inspect openresty-gateway --format "{{.State.Status}} {{.HostConfig.NetworkMode}}"` 应为 `running host` |

## 7. 多实例部署（可选）

多个网关实例共存时，有两个相互独立的机制：

### 7.1 共享会话（Redis）—— 跨域名不丢登录

共享 Redis 可以让用户在实例间保持登录。**只允许一个认证主实例写入**；其他实例只读。
只共享用户 ID 与来源，角色、Casbin 策略、域名绑定仍由各实例本地管理、互不同步。

每个实例的 `.env` 追加：

```bash
AUTHZ_SESSION_SHARED=true
AUTHZ_SESSION_REDIS_URL=redis://<redis-host>:6379
AUTHZ_SESSION_REDIS_MODE=read-only       # 仅认证主实例改为 read-write
AUTHZ_SESSION_REDIS_USERNAME=authz-reader
AUTHZ_SESSION_REDIS_PASSWORD=<redis-password>
AUTHZ_SESSION_REDIS_DB=0
AUTHZ_SESSION_REDIS_PREFIX=authz    # 多套集群共用同一 Redis 时用于隔离，如 authz-cluster1
# 共享记录 HMAC-SHA256 签名密钥（>=32 字符，所有共享实例必须一致）。
# 生成: openssl rand -hex 32
AUTHZ_SESSION_SIGNING_KEY=<openssl rand -hex 32>
```

语义：

- 会话命中后仍会用本地 `users` / `remote_users` 校验身份，本地不存在或已禁用即仅清除本机登录；
- Redis 中会话不存在或 Redis 不可达时立即失败关闭，不从 SQLite 恢复旧 token；
- 登录、全局登出、密码重置和用户禁用必须进入 `read-write` 主实例；reader 的 Redis ACL 只授予 `GET`/`PING`；
- 共享记录以 `<JSON>.<HMAC-SHA256 hex>` 信封存储，HMAC 覆盖 `token + JSON`；
  reader 对未签名、伪造或篡改的记录一律按未登录处理。因此即使共享 Redis
  没有 ACL（托管实例无法限制写入方），其他写入方也无法伪造会话；
  签名密钥泄漏等同于会话密钥泄漏，与其他 secret 同等保管；
- 网络白名单和传输保护（TLS 或内网）完成前保持 `AUTHZ_SESSION_SHARED=false`；
  有 ACL 时仍应配置 reader 只读账号，HMAC 是叠加防线而非 ACL 的替代。

## 8. 故障排查速查

| 症状 | 排查 |
|------|------|
| 容器反复重启 | `docker logs openresty-gateway`，常见为端口被占用或 `.env` 取值非法（非法值会在启动时直接报错） |
| 登录页 200 但代理 403 | 正常：代理目标需要登录 + 授权；先登录，再在管理界面配置策略 |
| 代理 404（绑定域名） | 绑定未启用或域名拼写不一致；管理界面 → 授权管理 → 域名绑定 |
| 子域之间登录态丢失 | 未设置 `AUTHZ_COOKIE_DOMAIN`（注意以 `.` 开头的父域），或需要启用 7.1 共享会话 |
| Cookie 不生效 / 反复跳登录 | 外层是 HTTPS 但 `AUTHZ_COOKIE_SECURE=false`，或反代未透传 `X-Forwarded-Proto` |
| 上游是 HTTPS 自签证书 | 在对应域名绑定的高级代理中关闭"验证 SSL 证书" |
| 绑定的"改写响应"没生效 | 看响应头 `X-Authz-Rewrite: skipped=<原因>`：`encoded` 上游返回了压缩正文、`range` 分片下载、`type` 非文本、`status` 上游非 200、`websocket`/`head` 不支持；正文改写还有 1MB 缓冲上限，超限自动原样透传。正文改写会由网关自动向上游声明 `Accept-Encoding: identity`（该链路不再压缩）；若绑定里显式写了 `Accept-Encoding` 覆盖则以其为准，上游压缩时改写按设计跳过 |
| 改绑定保存时报 `响应改写 status 必须是…` | 旧版本把规范化后的 `status:0`（= 不改状态码）当非法值拒绝，导致保存过改写规则的绑定再也 PATCH 不动；现已接受 0 |
| 忘记 admin 密码 | 见第 6 节 `admin_password_reset` |
| 容器内访问不到宿主服务 | 确认 `network_mode: host` 且宿主是 Linux；Docker Desktop 下容器 `127.0.0.1` 不是宿主 |
| 用 IP 访问时登录成功却反复跳回登录页 | 老版本缺陷（已在当前镜像修复）：升级到最新镜像即可；根因是登录响应错误下发了 `Domain=.<ip>` 清理头 |
| 管理界面报 `map is not a function` | 老版本缺陷（已在当前镜像修复）：空数据表被编码成 JSON 对象 `{}`；升级到最新镜像即可 |

## 附录 A：`.env` 全量示例（含注释）

```bash
# ══════════════ 基础 ══════════════
AUTHZ_ADMIN_PASSWORD=change-me-strong-password   # 首次 seed admin 密码（仅建表时生效；之后用管理界面改密或 admin_password_reset）
AUTHZ_HOST_URL=https://gateway.example.com        # 对外 Origin；OAuth 回调基准；可留空由请求 Host 推导
AUTHZ_COOKIE_DOMAIN=.example.com                  # Cookie 父域（可逗号分隔多个）；跨子域共享登录必需；留空按请求 Host 推导（去掉首个 label）
AUTHZ_COOKIE_SECURE=false                         # 入口始终 HTTPS 时设 true（含外层反代终止 TLS）
NGINX_WORKER_PROCESSES=4                          # worker 数量，按 CPU 调整；1 便于调试日志

# ══════════════ 入口与代理范围 ══════════════
AUTHZ_HTTP_PORT=6080                              # HTTP 入口
AUTHZ_HTTPS_PORT=6443                             # HTTPS 入口（网关终止 TLS）
AUTHZ_HTTP_MODE=redirect                          # 默认 308 到 HTTPS；disabled 仅回环；serve 仅受控测试
AUTHZ_PORT_MIN=2000                               # 数字前缀子域名最小端口（强制 >=2000 防回环）
AUTHZ_PORT_MAX=20000                              # 最大端口；目标为网关自身端口返回 508 防循环
AUTHZ_DISCOVERY_PORTS=                            # 追加探测端口（逗号分隔），容器读不到宿主监听表时用，如 3080,8082
AUTHZ_DISCOVERY_TTL=30                            # 菜单服务发现缓存秒数（1-300）
AUTHZ_DISCOVERY_CONNECT_TIMEOUT_MS=100            # 探测连接超时（10-5000ms）
AUTHZ_DISCOVERY_READ_TIMEOUT_MS=200               # 探测读取超时（10-5000ms）
AUTHZ_DNS_RESOLVER=                               # 自定义 DNS（如 8.8.8.8）；留空读容器 /etc/resolv.conf

# ══════════════ 存储 ══════════════
DATA_DIR=./data                                   # 宿主机数据目录（SQLite + 自签证书），必须持久化；改挂载需重建容器；Docker Desktop 的 ./ 相对 compose 文件所在目录解析，请确认实际宿主路径。
AUTHZ_DB_PATH=/data/authz/authz.db                # 容器内 SQLite 路径（勿改，除非同时改挂载）
AUTHZ_CERT_DIR=/data/certs                        # 容器内证书目录，缺失自动生成 10 年期自签证书（SAN: DNS:*）
AUTHZ_DB_CACHE_TTL=30                             # SQLite 查询缓存秒数（1-300）
AUTHZ_DB_CACHE_LRU_SIZE=500                       # 查询缓存条目数（50-5000）

# ══════════════ 会话 ══════════════
AUTHZ_SESSION_TTL=604800                          # 会话有效期秒数，默认 7 天；管理界面修改密码后该用户全部会话失效（管理端需输入两次新密码确认）
AUTHZ_LOGIN_ATTEMPTS=5                            # 同一账户（账户名+IP）连续失败多少次后锁定（>=1）
AUTHZ_LOGIN_WINDOW=1800                           # 失败计数窗口 = 锁定时长（秒，>=60，默认 1800=30 分钟）
AUTHZ_LOGIN_FAIL_DELAY_MS=1000                    # 登录失败后延迟多少毫秒再返回（0-10000，防暴力枚举计时）；按「账户名+IP」锁定，不影响同 IP 其他账户

# ══════════════ 共享会话（Redis，可选）══════════════
AUTHZ_SESSION_SHARED=false                        # 多实例共享登录身份；只共享用户 ID 与来源，角色/策略仍各实例本地管理；需重建容器生效。
AUTHZ_SESSION_REDIS_URL=redis://127.0.0.1:6379    # redis://<host>[:<port>]，默认端口 6379，仅支持 redis:// 明文地址，不支持 URL 内嵌账号或 db 号。
AUTHZ_SESSION_REDIS_MODE=read-only                # 主实例 read-write；其他实例 read-only
AUTHZ_SESSION_REDIS_USERNAME=authz-reader         # 为 writer/reader 配置不同 ACL 用户
AUTHZ_SESSION_REDIS_PASSWORD=                     # 对应 ACL 用户密码
AUTHZ_SESSION_REDIS_DB=0                          # Redis 逻辑库（0-15）
AUTHZ_SESSION_REDIS_PREFIX=authz                  # 键前缀，多套集群共用时隔离，如 authz-cluster1；键格式 <prefix>:session:<token>，TTL 与会话有效期一致。
AUTHZ_SESSION_SIGNING_KEY=                        # 共享记录 HMAC-SHA256 签名密钥（>=32 字符，所有共享实例必须一致）；未签名/签名不符的记录一律拒绝。生成: openssl rand -hex 32

# ══════════════ 响应改写缓冲（可选）══════════════
AUTHZ_REWRITE_BUFFER_MB=64                        # 正文改写的 worker 级缓冲预算（MB）。单响应上限固定 1MB 并按此整块预留；预算耗尽的新响应跳过改写、原样流式透传（响应头 X-Authz-Rewrite: skipped=memory）。仅影响 body/rewrites，状态码与响应头改写不占预算。

# ══════════════ 实例级预置 API Key（Agent 免登录，可选）══════════════
AUTHZ_API_KEY=                                    # 留空即关闭。设置后用 `x-api-key: <值>` 免登录访问控制面 API、管理页面与代理入口；32-256 字符（如 openssl rand -hex 32）。不入库，随环境变量轮换；配置非法启动即失败。
AUTHZ_API_KEY_ROLE=admin                          # 该 Key 的角色（admin/staff/user/guest/api），权限走同角色 Casbin 策略
AUTHZ_API_KEY_ALLOWED_IPS=127.0.0.1               # 来源白名单：逗号分隔的 IP 或 CIDR（如 127.0.0.1,10.0.0.0/8），匹配 TCP remote_addr（XFF 不参与）。默认只信 127.0.0.1；跨机接入显式加对端 IP

# ══════════════ OAuth：Google（可选）══════════════
AUTHZ_GOOGLE_ENABLED=false
AUTHZ_GOOGLE_CLIENT_ID=your-google-client-id
AUTHZ_GOOGLE_CLIENT_SECRET=your-google-client-secret
AUTHZ_GOOGLE_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_GOOGLE_DEFAULT_ROLES=guest                 # 首次登录默认角色：admin,staff,user,guest 组合（逗号分隔）

# ══════════════ OAuth：钉钉（可选）══════════════
AUTHZ_DINGTALK_ENABLED=false
AUTHZ_DINGTALK_CLIENT_ID=your-dingtalk-client-id
AUTHZ_DINGTALK_CLIENT_SECRET=your-dingtalk-client-secret
AUTHZ_DINGTALK_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_DINGTALK_DEFAULT_ROLES=guest

# ══════════════ OAuth：微信（可选）══════════════
AUTHZ_WECHAT_ENABLED=false
AUTHZ_WECHAT_APP_ID=your-wechat-app-id
AUTHZ_WECHAT_APP_SECRET=your-wechat-app-secret
AUTHZ_WECHAT_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_WECHAT_DEFAULT_ROLES=guest

# ══════════════ NocoBase 密码登录源（可选）══════════════
AUTHZ_NOCO_ENABLED=false                          # 允许在登录表单选择 NocoBase 账号密码；AUTHZ_NOCO_URL 必须 https
AUTHZ_NOCO_URL=https://your-nocobase.example/
AUTHZ_NOCO_ROLE_MAP=root=admin,admin=admin,staff=staff,member=user,user=user,viewer=guest
AUTHZ_NOCO_CONNECT_TIMEOUT_MS=3000
AUTHZ_NOCO_SEND_TIMEOUT_MS=5000
AUTHZ_NOCO_READ_TIMEOUT_MS=5000

# ══════════════ NocoBase OAuth（可选）══════════════
# NocoBase 2.2 要求：回调必须精确校验 iss，token 使用 client_secret_basic + PKCE；
# 公网 Client 用仓库脚本 scripts/register_nocobase_oauth.py 一次性注册（需要源码树）。
AUTHZ_NOCO_OAUTH_ENABLED=false
AUTHZ_NOCO_OAUTH_CLIENT_ID=your-nocobase-client-id
AUTHZ_NOCO_OAUTH_CLIENT_SECRET=your-nocobase-client-secret
AUTHZ_NOCO_OAUTH_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_NOCO_OAUTH_DEFAULT_ROLES=guest

# ══════════════ 通用 OAuth/OIDC Provider（可选）══════════════
AUTHZ_OAUTH_ENABLED=false
AUTHZ_OAUTH_PROVIDER=oauth                        # provider id（小写字母/数字/点/下划线/连字符，勿用保留名）
AUTHZ_OAUTH_TITLE=OAuth                           # 登录页显示名称（支持中文）
AUTHZ_OAUTH_CLIENT_ID=
AUTHZ_OAUTH_CLIENT_SECRET=
AUTHZ_OAUTH_AUTHORIZE_URL=                        # authorize 端点
AUTHZ_OAUTH_TOKEN_URL=                            # token 端点（PKCE + client_secret_basic）
AUTHZ_OAUTH_USERINFO_URL=                         # userinfo 端点（Bearer）
AUTHZ_OAUTH_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_OAUTH_SCOPE=openid email profile
AUTHZ_OAUTH_SUBJECT_CLAIM=sub                     # 唯一身份 claim（默认 sub）
AUTHZ_OAUTH_USERNAME_CLAIM=email                  # 用户名 claim（默认 email，回退 preferred_username）
AUTHZ_OAUTH_ROLE_CLAIM=roles                      # 角色 claim（逗号分隔或数组）
AUTHZ_OAUTH_ROLE_MAP=                             # 源角色→本地角色映射，如 employees=staff
AUTHZ_OAUTH_DEFAULT_ROLES=guest
AUTHZ_OAUTH_REQUIRE_VERIFIED_EMAIL=false
AUTHZ_OAUTH_STATE_TTL=600                         # 授权 state 有效期秒数（>=60）

```

## 附录 B：完整 `docker-compose.yml`（含开发挂载模式）

生产推荐第 3.2 节的最小版本。若需要同步修改前端/Lua/模板并热加载（开发机），使用完整版：

```yaml
services:
  gateway:
    image: ghcr.io/yorkane/authz:latest
    container_name: openresty-gateway
    restart: unless-stopped
    network_mode: host
    env_file:
      - .env
    environment:
      # 指向挂载的模板目录；不挂载模板时改为 /usr/local/openresty/nginx/conf
      OPENRESTY_TEMPLATE_DIR: /etc/openresty/templates
    volumes:
      - ${DATA_DIR:-./data}:/data
      # 以下三项为开发挂载，需要与镜像同版本的源代码树；生产可全部删除（删除后把 OPENRESTY_TEMPLATE_DIR 改回内置目录）
      - ./admin:/usr/local/openresty/nginx/html/admin:ro
      - ./lualib:/usr/local/openresty/site/lualib:ro
      - ./conf:/etc/openresty/templates:ro
```

注意：开发挂载要求代码树与镜像版本匹配，否则会引入行为差异；纯镜像部署不存在这个问题。修改挂载的模板/代码后用 `openresty -t` 检查再重启；修改 `.env` 必须重建容器。

## 附录 C：部署完成检查单（供自动化核对）

```bash
HTTP_PORT=${AUTHZ_HTTP_PORT:-6080}
HTTPS_PORT=${AUTHZ_HTTPS_PORT:-6443}

docker inspect openresty-gateway --format "{{.State.Status}}"                    # running
docker inspect openresty-gateway --format "{{.HostConfig.NetworkMode}}"          # host
curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:${HTTP_PORT}/_authz/login"            # 308 (redirect 模式)
curl -skS -o /dev/null -w "%{http_code}" "https://127.0.0.1:${HTTPS_PORT}/_authz/api/session"  # 401
curl -skS -o /dev/null -w "%{http_code}" "https://127.0.0.1:${HTTPS_PORT}/_authz/apps/"               # 302
curl -skS -o /dev/null -w "%{http_code}" "https://127.0.0.1:${HTTPS_PORT}/_authz/login"         # 200
docker exec openresty-gateway test -s /data/authz/authz.db && echo db-ok                          # db-ok
```
