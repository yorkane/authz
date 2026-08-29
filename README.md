# openresty-base

定制 OpenResty Alpine Docker 镜像，在官方源码编译基础上额外集成：

- [lua-nginx-module](https://github.com/openresty/lua-nginx-module) — master 分支最新版本（替换 OpenResty 内置捆绑版）
- [nginx-dav-ext-module](https://github.com/arut/nginx-dav-ext-module) — WebDAV PROPFIND / OPTIONS / LOCK / UNLOCK 支持
- [ngx-fancyindex](https://github.com/aperezdc/ngx-fancyindex) — 美化目录索引
- [lua-resty-jwt](https://github.com/api7/lua-resty-jwt) — 通用 JWT 签发与验证
- [lua-resty-http](https://github.com/ledgetech/lua-resty-http) — NocoBase HTTPS 身份查询客户端
- **Authz Gateway** — 动态端口代理 + 本地认证授权（SQLite + mini-casbin + 管理界面）

## Authz Gateway（动态端口代理 + 认证授权）

镜像默认以网关模式启动，两个入口：

| 入口 | 上游 | 说明 |
|------|------|------|
| `6080` (http) | `http(s)://<target_ip>:<port>` | 默认 308 到 HTTPS（`AUTHZ_HTTP_MODE=redirect`）；`serve` 模式才代理本机或其他 IP 的 HTTP/HTTPS 服务 |
| `6443` (https) | `http(s)://<target_ip>:<port>` | 网关终止客户端 TLS，再按绑定配置代理 HTTP/HTTPS 上游 |

### 域名 → 端口解析规则

1. **数字前缀子域名**（免配置）：`3000-任意域名` → 本机 `3000` 端口，
   支持多级子域名（`3000-a.b.c.example.com`），端口范围默认 `2000-20000`
2. **显式绑定**：管理界面配置固定域名到目标 IP + 端口的映射（存 SQLite，目标 IP 默认 `127.0.0.1`）
3. 其余域名 → 404

所有代理流量需登录 + Casbin 策略授权；后端收到 `X-Authz-User` 头。管理菜单会读取本机监听端口，
在配置的端口范围内用 `127.0.0.1` 和短超时 HTTP `HEAD` 探测，只列出实际 HTTP 服务；入口变化会定时刷新，
并按 `<port>-当前域名` 生成动态入口，右侧 iframe 满屏加载对应服务。扫描结果默认缓存 30 秒，网关自身端口会排除。
代理默认支持 WebSocket；只要请求带有 `Upgrade: websocket`，所有已解析的目标都会转发升级头、关闭响应缓冲并延长读写超时，可承载 code-server 等 WebSocket 应用。

管理端的“新增域名绑定”支持以下配置：

- 只填写最后一级域名前缀，例如 `name1`；当前实例为 `m.ws.example.com` 时保存为 `name1-m.ws.example.com`；
- 公网入口默认把 HTTP 永久重定向到 HTTPS（`AUTHZ_HTTP_MODE=redirect`）；需要临时暴露管理端时用防火墙白名单限制来源；
- 多实例可启用共享会话模式（Redis），但只允许一个实例 `read-write`，其余实例 `read-only`；角色/策略仍各自本地管理，详见 `docs/maintenance-handbook.md` 6.1；
- 目标 IP 默认 `127.0.0.1`，也可填写其他机器的 IPv4 或 IPv6 地址；上游协议可选择 HTTP 或 HTTPS，HTTPS 可选择是否忽略 SSL 证书校验；
- 不同前缀可以绑定同一个端口，最终域名必须唯一，重复提交返回 `409`；
- 可填写 `menu-name` 覆盖左侧菜单名称；配置绑定后，该端口不再依赖主动探测的菜单名称；
- 域名绑定的 `note` 会在左侧菜单名称下方显示；鼠标悬浮菜单时显示该菜单实际打开的完整域名地址，自动探测的 `local:<port>` 也显示生成后的地址；普通点击在右侧 iframe 打开，Ctrl/Command + 点击在新窗口打开菜单地址；
- WebSocket 默认对所有已解析目标开启；`bindings.websocket` 字段保留用于兼容历史数据，不再作为升级请求的阻断开关。
- “高级代理配置”可选择上游协议、SSL 校验和上游路径改写，并覆盖上游 `Host`、`X-Forwarded-Host`、`X-Forwarded-Proto`、`X-Forwarded-Port`，以及保持、重写、移除或自定义 `Origin`；改写路径留空时保持原路径，填写后请求统一转发到该路径。
- “模拟本机访问”默认把 `Host`/`Origin` 改为目标 HTTP 地址，并将 `X-Real-IP`、`X-Forwarded-For` 设置为 `127.0.0.1`；也可填写网关的局域网 IP。该选项只模拟 HTTP 请求头，不能改变真实 TCP 来源地址。

### 管理界面

管理界面统一从 `/_authz/apps/` 进入：

- 登录 / 登出（服务端会话，HttpOnly Cookie，CSRF 防护）
- 深色 Pollux 风格侧栏，无顶部菜单栏
- 左侧菜单通过 SSI 直接组装到管理壳，支持收起/展开、登录状态和 Logout
- 右侧通过 iframe 分别加载“用户 / 角色管理”和“授权管理”
- 管理壳使用 Vue 3 + Quasar UMD，应用页面的 Vue/Quasar 逻辑直接内联在各自 HTML 中
- 框架静态资源合并为 `vendor/quasar-umd.js` 和 `vendor/quasar-umd.css`；应用层保留独立的 `api.js`
  与入口 `app.js`
- 用户 / 角色管理统一展示本地、NocoBase、Google/OAuth 身份；支持远程角色本地覆盖与恢复
- 授权管理支持域名绑定增删/启停及 Casbin 策略编辑
- `/_authz/apps/` 由服务端会话保护，未登录自动跳转到 `/_authz/login?next=...`
- 管理端统一调用 `/_authz/api/*` JSON API
- 应用可使用 `x-authz-key` 作为服务身份；Key 可绑定固定角色，`admin` Key 可管理全部核心 API，完整
  契约见 [核心 API（Agent 使用手册）](docs/core-api.md)

首次启动自动 seed：`admin / admin123`（务必尽快改密）。默认仅
`role:admin` 对 `/*` 全放行，其他角色默认拒绝。

### 快速使用

```bash
# 方式一: 使用 GitHub Actions 已发布镜像（生产/部署推荐）
cp .env.example .env && vim .env      # 修改 AUTHZ_ADMIN_PASSWORD
docker compose pull
docker compose up -d --force-recreate --no-build

# 方式二: docker compose 本地构建（仅调试 Dockerfile 或未发布改动时）
docker compose up -d --build

# 方式三: docker run
docker run -d --name gw --network host \
  -v /data/gw:/data \
  -v "$PWD/admin:/usr/local/openresty/nginx/html/admin:ro" \
  -v "$PWD/lualib:/usr/local/openresty/site/lualib:ro" \
  -v "$PWD/conf:/etc/openresty/templates:ro" \
  -e OPENRESTY_TEMPLATE_DIR=/etc/openresty/templates \
  -e AUTHZ_ADMIN_PASSWORD=your-secret \
  ghcr.io/yorkane/authz:latest

# 浏览器打开 http://<host>:6080/_authz/apps/ 登录
# 代理本机 3000 端口: http://3000-myhost.example.com:6080/
```

如果管理员忘记密码，可在容器内执行以下命令，使用容器当前的
`AUTHZ_ADMIN_PASSWORD` 环境变量重置内置 `admin` 密码，并自动 reload OpenResty：

```bash
docker exec <container_name> admin_password_reset
```

该命令读取的是容器当前环境，不会重新读取宿主机 `.env`。修改 `.env` 后请先用
`docker compose up -d --force-recreate` 重建容器，再执行重置命令；密码至少需要 6 位。

本项目的 Compose 默认使用 `network_mode: host`，因此本机服务发现和代理目标都直接访问宿主机
网络命名空间的 `127.0.0.1`。这也是动态端口代理访问宿主机 HTTP 服务的必要配置；不要再为该服务
添加 `ports` 映射。若改为普通 bridge 网络，容器内的 `127.0.0.1` 只代表网关容器自身，无法访问
宿主机监听的端口。

### 部署与排障经验

- 修改 `.env`、`conf/nginx.conf.template` 或 `conf/server.conf.template` 后执行 `bash scripts/restart_gateway.sh`；Compose 会挂载 `conf/`，入口脚本在每次容器启动时重新生成最终配置，不需要重建镜像。
- 只修改模板时也可执行 `docker restart openresty-gateway`；只执行 `docker restart` 不会更新容器创建时的环境变量。Darwin Apple Silicon 本地构建自动使用 `linux/arm64`。
- 只有修改 Dockerfile、`docker-entrypoint.sh`、镜像依赖或原生模块时才使用 `bash scripts/restart_gateway.sh --build`。
- 修改已挂载的 `admin/` 或 `lualib/` 通常无需重建镜像，但应执行 `openresty -t`；修改挂载、网络或环境变量必须重建容器。
- `6443` 是网关的 HTTPS 入口，TLS 在网关终止；上游协议由域名绑定单独选择，HTTPS 上游可按需关闭证书校验。
- 网关向上游保留外部 `Host`；带严格 Host/Origin 校验的应用还需把绑定域名加入自身可信列表，例如 pi-web 设置 `PI_WEB_ALLOWED_HOSTS=pi-m.ws.example.com`。
- 若上游只接受内部 Host 或本地来源，可在该绑定的“高级代理配置”中精确覆盖相关头，或启用“模拟本机访问”；不要为解决单个应用兼容问题修改全局代理默认值。
- 测试本机 code-server 时先运行 `curl -i http://127.0.0.1:2077/`，返回 `200` 才说明后端 HTTP 正常；直接访问本机 `https://127.0.0.1:2077/` 失败是正常的协议不匹配。
- 未带会话访问已解析的绑定域名时返回 `302` 到 `/_authz/login` 是预期认证结果，不能用未登录 curl 判断 iframe 或 WebSocket 是否正常。
- `scripts/restart_gateway.sh` 会检查 Compose 配置、host 网络、OpenResty 配置、登录页、session API 和 Admin 入口。

镜像将项目 `lualib/` 整体复制到 `/usr/local/openresty/site/lualib/`。Compose 默认把
`${LUALIB_DIR:-./lualib}` 整目录只读挂载到同一路径，并同时挂载
`${ADMIN_UI_DIR:-./admin}` 和 `${NGINX_TEMPLATE_DIR:-./conf}`；修改 Lua 后端、管理前端或 Nginx 模板时无需重复构建镜像。
由于宿主机 `admin/` 挂载会覆盖镜像内的预生成 `.br` 文件，开发挂载场景依靠动态 Brotli；生产静态资源
应优先使用 CI 构建的镜像，以便 `brotli_static` 直接命中预压缩文件。

> 维护者先阅读 [维护手册](docs/maintenance-handbook.md) 和 [AGENTS.MD](AGENTS.MD)；
> 项目级 Skill 位于 `.codex/skills/openresty-authz-maintainer/SKILL.md`。

### 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `AUTHZ_DB_PATH` | `/data/authz/authz.db` | SQLite 路径（用户/会话/策略/绑定） |
| `AUTHZ_ADMIN_PASSWORD` | `admin123` | 首次 seed 的 admin 密码；也作为 `admin_password_reset` 的重置密码 |
| `AUTHZ_PORT_MIN` / `AUTHZ_PORT_MAX` | `2000` / `20000` | 数字前缀端口范围 |
| `AUTHZ_HTTP_PORT` / `AUTHZ_HTTPS_PORT` | `6080` / `6443` | 入口端口 |
| `AUTHZ_HTTP_MODE` | `redirect` | 公网 HTTP 行为：`redirect` 308 到 HTTPS；`disabled` 仅回环；`serve` 仅受控测试 |
| `AUTHZ_DISCOVERY_PORTS` | 空 | Docker Desktop 无法从监听表发现时，追加探测端口，例如 `2077,3080` |
| `NGINX_WORKER_PROCESSES` | `4` | Nginx worker 数量，可按 CPU 核数和并发量调整 |
| `AUTHZ_DISCOVERY_TTL` | `30` | 本机 HTTP 服务发现缓存秒数 |
| `AUTHZ_DISCOVERY_CONNECT_TIMEOUT_MS` / `AUTHZ_DISCOVERY_READ_TIMEOUT_MS` | `100` / `200` | 本机 HTTP 服务探测超时 |
| `AUTHZ_DB_CACHE_TTL` | `30` | SQLite 查询的 mlcache TTL（秒） |
| `AUTHZ_DB_CACHE_LRU_SIZE` | `500` | 每个 worker 的 mlcache L1 条目数 |
| `AUTHZ_HOST_URL` | 空 | 浏览器访问网关的 HTTPS Origin，用于生成 OAuth 回调，并在请求 Host 不可用时回退推导 Cookie 父域 |
| `AUTHZ_CERT_DIR` | `/data/certs` | 自签证书目录（10 年有效） |
| `AUTHZ_SESSION_TTL` | `604800` | 会话有效期（秒） |
| `AUTHZ_COOKIE_SECURE` | `false` | 生产入口始终为 HTTPS 时强制 Cookie `Secure` |
| `AUTHZ_COOKIE_DOMAIN` | 从请求 Host 动态推导 | 可选的 Cookie 父域提示，支持逗号分隔多个值；仅匹配当前 Host 时生效，例如 `.ws.example.com,.w.wtvdev.com` |
| `AUTHZ_LOGIN_ATTEMPTS` / `AUTHZ_LOGIN_WINDOW` / `AUTHZ_LOGIN_FAIL_DELAY_MS` | `5` / `1800` / `1000` | 登录防护：失败延迟返回，按账户名+IP 连续失败达阈值后锁定该账户组合（窗口=锁定时长） |
| `AUTHZ_AGENT_API_KEY` | 空 | 设置后自动创建仅限本机回环调用的 Agent 专用 API Key（`agent-default`，角色 admin），供本机自动化程序使用 |
| `AUTHZ_NOCO_ENABLED` | `false` | 在密码登录表单启用 NocoBase 身份来源 |
| `AUTHZ_NOCO_URL` | 空 | NocoBase 站点根地址（启用远程认证时必须为 HTTPS） |
| `AUTHZ_NOCO_API_KEY` | 空 | 仅供一次性 Client 注册脚本使用，不注入运行容器 |
| `AUTHZ_NOCO_ROLE_MAP` | `root=admin,...` | NocoBase 角色到本地四角色的映射 |
| `AUTHZ_NOCO_*_TIMEOUT_MS` | `3000/5000/5000` | NocoBase 建连/发送/读取超时 |
| `AUTHZ_NOCO_OAUTH_ENABLED` | `false` | 使用 NocoBase IdP: OAuth 提供关联登录 |
| `AUTHZ_NOCO_OAUTH_CLIENT_ID/SECRET/REDIRECT_URI` | 空 | NocoBase OAuth Web Client 配置 |
| `AUTHZ_GOOGLE_ENABLED` | `false` | 启用 Google OIDC 登录按钮 |
| `AUTHZ_GOOGLE_CLIENT_ID/SECRET/REDIRECT_URI` | 空 | Google Web OAuth client 配置 |
| `AUTHZ_DINGTALK_*` | 关闭 | 钉钉登录 Client ID、Secret、回调地址和默认角色 |
| `AUTHZ_WECHAT_*` | 关闭 | 微信开放平台网站应用 App ID、Secret、回调地址和默认角色 |
| `AUTHZ_OAUTH_ENABLED` | `false` | 启用通用 OAuth2/OIDC 登录 |
| `AUTHZ_OAUTH_*_URL` | 空 | authorize、token、userinfo 和 callback URL |
| `AUTHZ_OAUTH_*_CLAIM/ROLE_MAP` | 见 `.env.example` | 用户名、subject、角色 claim 与本地角色映射 |
| `AUTHZ_OAUTH_*_TIMEOUT_MS` | `10000/10000/15000` | OAuth 建连、发送、读取超时；传输失败自动重试一次 |
| `AUTHZ_DNS_RESOLVER` | 容器 DNS | Lua HTTPS 请求使用的 DNS 服务器 |
| `ADMIN_UI_DIR` | `./admin` | 宿主机静态管理前端目录（Compose 只读挂载） |
| `LUALIB_DIR` | `./lualib` | 宿主机项目 Lua 库目录（Compose 整目录只读挂载） |

### 核心工程约定

#### 后端与 API

- 运行时是 OpenResty + LuaJIT；项目默认不引入 Node、Vite 或前端 Router。
- 所有管理 API 位于 `/_authz/api/`，响应使用 `application/json`；登录、OAuth 与 API 统一收敛在 `/_authz/` 单一 router 入口下。
- `lualib/klib/router.lua` 是注册式 Router 的公共基础；路由注册失败必须返回并检查，默认错误响应不得回显
  请求头或请求头值。
- `lualib/resty/authz/repository/` 集中所有运行时 SQL；`db.lua` 只负责生命周期、缓存查询和事务。
  多步骤管理写入在 service 层统一提交，提交后自动递增数据库/授权 revision，回滚不失效缓存。
- Schema 变化通过 `db/migrations.lua` 追加有序版本，并记录到 `schema_migrations`；不要改写已发布迁移。
- 数字前缀动态端口默认允许 `2000` 起步；人类角色固定为 `admin`、`staff`、`user`、`viewer`，应用
  Key 可绑定这些角色或专用 `api` 角色；HTTP 方法使用完整方法目录，并支持多选策略。

#### 身份与授权

- 身份主键是“用户名 + 来源”，即 `user:<source>:<username>`；同名的 local、nocobase、google、dingtalk、
  wechat 或通用 OAuth 身份可以并存，角色和策略不能按用户名跨来源混用。
- 本地用户和本地角色优先于远程记录；远程身份只单向同步用户名、来源、角色快照和时间信息，不回写身份源。
- 启用状态由本机管理员控制，只有管理员主动删除后远程身份才会被清除；远程用户不能修改本地密码。
- 普通 `viewer` 用户只能查看自己的会话/身份信息，不能读取或修改 Casbin 授权策略。
- `api` 角色只能新建域名绑定并按 Casbin 策略请求代理目标，不能管理用户、角色、策略、API Key 或核心认证。
- 本系统不再同步 APISIX routes、用户、角色或策略；与外部系统保持松耦合、单向记录。

#### 管理前端

- 使用 Vue 3 + Quasar UMD 2.26.0、MDI v7 和本地 Roboto 字体；Quasar 中文简体与英文语言包必须同时保留。
- `admin/index.html` 是 SSI 管理壳，菜单由 `/_authz/apps/menu.html` 直接组装，不使用菜单 iframe；右侧应用仍使用
  iframe 加载 `users.html` 与 `authorization.html`（与壳同级），并隐藏 iframe 边框。
- 菜单的 CSS、模板和交互逻辑保持内联；右侧应用的业务 JavaScript 也直接内联在应用 HTML 中。
- 所有页面支持全局中英文切换；切换状态必须同步影响右侧 iframe 应用。图标统一使用 MDI v7。
- 页面设计保持轻量 Linear 风格：移动端可读字体、紧凑侧栏、40px 收起宽度、圆角卡片和大型统计卡片。

#### 构建与运行

- 发布和部署优先使用 GitHub Actions 推送到 GHCR 的镜像；本地构建仅用于调试、验证未发布改动或 CI 不可用。
- Dockerfile 使用 Buildx 多阶段构建，默认 `RESTY_J=8`；源码下载和编译层必须保持可缓存，容器内不配置代理。
- `ngx_brotli` 静态编译进 OpenResty；动态 Brotli/Gzip 默认等级均为 5，Admin 静态资源在镜像构建时使用 Brotli
  等级 11 预压缩，并通过 `brotli_static on` 提供。
- Compose 的 `/data`、`admin/`、`lualib/` 和运行时 `conf/` 模板挂载路径必须与镜像约定一致，避免镜像和开发挂载行为不一致。

### 数据持久化

挂载 `/data` 保存状态：`/data/authz/authz.db`（全部状态）+ `/data/certs/`（证书）。
`admin/` 与 `lualib/` 的开发挂载路径分别和镜像内复制路径一致。

### 功能测试

```bash
bash test/test_klib_router_ctxvar.sh  # 真实 OpenResty Router 回归
bash test/test_authz_gateway.sh      # 隔离 Authz/API/动态代理回归
bash test/test_shared_session.sh     # 共享会话 (Redis 单写多读) 回归
bash test/run_tests.sh <image>       # 镜像基础功能回归
```

基础镜像测试会按 Docker daemon 架构选择 `linux/arm64` 或 `linux/amd64`，不会在 Apple Silicon 上强制拉取
amd64 镜像覆盖本地构建标签。

验证发布镜像时显式指定镜像：

```bash
OPENRESTY_TEST_IMAGE=ghcr.io/yorkane/authz:latest bash test/test_authz_gateway.sh
OPENRESTY_TEST_IMAGE=ghcr.io/yorkane/authz:latest bash test/test_klib_router_ctxvar.sh
OPENRESTY_TEST_IMAGE=ghcr.io/yorkane/authz:latest bash test/test_shared_session.sh
bash test/run_tests.sh ghcr.io/yorkane/authz:latest
```

回归重点包括：SSI 菜单组装、Brotli/Gzip 静态资源、JSON 错误响应、CSRF、OAuth/PKCE、多来源同名身份、
远程角色覆盖、启用状态、动态端口策略及 Router 注册错误处理。

## NocoBase 与 OAuth 身份记录

Authz Gateway 可选用 NocoBase 校验远程账号，并在用户成功登录时单向记录用户名和映射角色。
登录时显式选择本地或 NocoBase；身份以 `user:<source>:<username>` 标识，因此同名多来源用户可并存，
角色和用户直授权互不影响。NocoBase JWT 和密码不落库，本机会签发自己的 SQLite 服务端会话。
管理员可在“用户与角色”中覆盖本机有效角色，也可恢复最近一次登录记录的远端角色。所有本机状态
只用于本网关认证授权，不回写身份源，也不向任何外部网关同步路由、用户、角色或策略。

```dotenv
AUTHZ_NOCO_ENABLED=true
AUTHZ_NOCO_URL=https://noco.example.com
AUTHZ_NOCO_ROLE_MAP=root=admin,admin=admin,member=user
```

也可启用 NocoBase、Google 或标准 OAuth2/OIDC Authorization Code + PKCE 登录。NocoBase OAuth
与密码认证共用 `nocobase` 身份来源，但按标准 `/api/idpOAuth/me` 只读取身份，首次登录使用本机默认
`viewer`；管理员可在本机覆盖角色，并与其他远程身份共用 Casbin 授权。

NocoBase OAuth Client 以 [docs/thirdparty-oauth-login.md](docs/thirdparty-oauth-login.md) 为唯一配置依据；
之前的 NocoBase OAuth 集成方案作废。填写 `AUTHZ_HOST_URL`、`AUTHZ_NOCO_URL` 和
`AUTHZ_NOCO_API_KEY` 后运行 `python3 scripts/register_nocobase_oauth.py`，再使用 CI 镜像重建/部署容器。
其他 OAuth 行为和维护规则见 [docs/maintenance-handbook.md](docs/maintenance-handbook.md)。

## 镜像地址

| Registry | 地址 |
|----------|------|
| GitHub Container Registry | `ghcr.io/yorkane/authz` |
| Docker Hub | `yorkane/authz` |

## 快速使用

```bash
docker pull ghcr.io/yorkane/authz:latest
# 或
docker pull yorkane/authz:latest
```

## Tag 规则

| Tag | 说明 |
|-----|------|
| `latest` | 最新构建 |
| `1.31.1.1` | OpenResty 版本号 |
| `1.31.1.1-20260315` | OpenResty 版本 + 构建日期 |

## 组件版本

| 组件 | 版本策略 |
|------|---------|
| Alpine | 3.23.5 |
| OpenResty | 自动检测官网最新稳定版 |
| LuaJIT | OpenResty 捆绑版（2.1.ROLLING） |
| lua-nginx-module | GitHub `master` 分支最新 commit |
| stream-lua-nginx-module | GitHub `master` 分支最新 commit |
| lua-resty-mlcache | vendored `2.6.1`，用于 SQLite 查询 L1/L2/L3 缓存 |
| lua-resty-core | GitHub `master` 分支最新 commit |
| lua-resty-jwt | api7 fork v0.2.6 |
| nginx-dav-ext-module | GitHub `master` 分支最新 commit |
| ngx-fancyindex | 最新 Release tag |
| LuaRocks | 3.13.0 |
| OpenSSL | 3.5.7 (patch base 3.5.5) |
| PCRE2 | 10.47 |

## 镜像特性

- **基础镜像**：`alpine:3.23`，当前运行时镜像约 **60–65 MiB**（随依赖版本变化）
- **多阶段构建**：源码/编译工具链只存在于 builder stage，最终镜像仅保留运行时文件
- **可复用缓存**：源码下载独立成层，`RESTY_J` 默认并行度为 8；GitHub Actions 使用 Buildx GHA cache
- **二进制精简**：`strip` nginx / luajit / openssl / pcre2 / *.so，去掉调试符号
- **运行时依赖最小化**：仅保留必要的 so 和 Alpine 包
- **动态模块**：geoip、image_filter、xslt 以动态 `.so` 形式保留
- **OpenSSL 独立编译**：作为共享库安装到 `/usr/local/openresty/openssl3`，并应用 OpenResty 官方补丁（`sess_set_get_cb_yield`）
- **PCRE2 独立编译**：作为共享库安装到 `/usr/local/openresty/pcre2`，启用 JIT
- **Brotli**：静态编译 `ngx_brotli`，动态压缩等级 5；镜像构建时为 Admin 静态资源生成等级 11 的 `.br` 文件
- **去掉 RDS / Mail POP3/IMAP/SMTP**：与官方 alpine 镜像保持一致

## 本地构建

日常发布和部署优先使用 GitHub Actions 构建并推送的 GHCR 镜像；只有需要本地验证、Actions 不可用或正在调试 Dockerfile 时，才执行本地构建。

```bash
# Docker CLI 需要 buildx；默认 builder 会复用本机 BuildKit 缓存
docker buildx build --load --build-arg RESTY_J=${RESTY_J:-8} \
  --tag openresty-base:local .

# Compose 同样使用 BuildKit/buildx
docker compose build
```

GitHub Actions 使用 `docker/setup-buildx-action` 和 `type=gha,mode=max` 缓存；本地不要使用
`DOCKER_BUILDKIT=0`，否则会退回已弃用的 legacy builder。

## 本地测试

```bash
# 运行完整功能测试（需要 Docker + curl）
bash test/run_tests.sh

# 指定自定义镜像
bash test/run_tests.sh ghcr.io/yorkane/authz:1.31.1.1
```

测试覆盖以下功能点：

| # | 测试项 | 验证内容 |
|---|--------|---------|
| 1 | Lua 基础 | `content_by_lua_block`，`ngx_lua_version` |
| 2 | cjson | 内置 `cjson.encode` |
| 3 | resty 库 | `resty.core` / `ngx.re` / `resty.lrucache` / `resty.string` / `resty.md5` |
| 4 | LuaJIT FFI | `ffi.arch`、`ffi.os` |
| 5 | FancyIndex | 目录浏览 HTML 响应 |
| 6 | WebDAV | OPTIONS → Allow 头、PUT 201、PROPFIND 207 |
| 7 | Error log | 确认无 `[error]` 行 |
| 8 | JWT | `resty.jwt` 模块、HS256 签发验证和错误密钥拒绝 |

## 自动构建

GitHub Actions 每周一 UTC 02:00 自动检测最新版本并构建，推送到 GHCR 和 Docker Hub。
也可在仓库 **Actions → Build and Publish → Run workflow** 手动触发（支持指定 OpenResty 版本和强制重建）。

## 平台支持

| 平台 | 支持 |
|------|------|
| `linux/amd64` | ✅ |
| `linux/arm64` | ✅ 本地 Buildx 构建；Darwin Apple Silicon 使用该架构 |

## 配置 Secrets

使用 Docker Hub 推送前，需在仓库 **Settings → Secrets and variables → Actions** 中添加：

| Secret 名称 | 说明 |
|-------------|------|
| `DOCKERHUB_USERNAME` | Docker Hub 用户名（`yorkane`） |
| `DOCKERHUB_TOKEN` | Docker Hub Access Token |

GHCR 推送使用内置 `GITHUB_TOKEN`，无需额外配置。

## 目录结构

```
.
├── Dockerfile                  # 多阶段 Alpine 构建
├── README.md
├── design.md                   # ★ 设计文档 (架构/数据模型/踩坑记录, 维护必读)
├── docker-compose.yml          # 部署编排
├── .env.example                # 环境变量模板
├── docker-entrypoint.sh        # 证书生成 + conf 渲染 + 启动
├── docs/
│   ├── thirdparty-oauth-login.md # NocoBase OAuth 唯一配置依据
│   ├── core-api.md                # 核心 API 与 Agent/API Key 使用契约
│   ├── maintenance-handbook.md  # 生产维护、测试与故障排查
│   └── sso-jwt-auth.md           # 历史 JWT/SSO 参考
├── admin/                       # Vue 3 + Quasar UMD 管理界面
│   ├── index.html               # SSI 管理壳
│   ├── menu.html                # SSI 菜单片段（仅模板）
│   ├── apps/                    # 用户/角色与授权管理页面
│   ├── vendor/                  # 合并后的 Quasar/Vue/语言包/MDI 静态资源
│   ├── api.js                   # 应用公共 API 客户端
│   └── i18n.js                  # 全局中英文状态
├── scripts/
│   └── register_nocobase_oauth.py # NocoBase Client 注册脚本
├── lualib/
│   └── resty/
│       ├── hmac.lua            # resty.hmac 适配器（基于捆绑 resty.openssl.hmac）
│       └── authz/              # Authz Gateway (动态端口代理+认证)
│           ├── init.lua        # 稳定生命周期入口
│           ├── config.lua      # 通用环境配置
│           ├── provider_config.lua # OAuth/身份 Provider 装配
│           ├── gateway/        # access/解析/缓存/代理构造
│           ├── app.lua         # 登录、管理入口跳转、旧接口退役响应
│           ├── api/            # Router、校验、薄门面和领域 services
│           ├── api_key.lua     # x-authz-key 摘要校验与服务主体
│           ├── repository/     # 用户/会话/策略/绑定/API Key SQL
│           ├── db.lua          # 生命周期、缓存查询和事务门面
│           ├── db/             # 驱动/schema/版本迁移/seed/查询缓存
│           ├── nocobase.lua    # NocoBase 登录/角色查询与身份快照
│           ├── casbin.lua      # mini-casbin (p/g, deny优先)
│           ├── session.lua     # 服务端会话
│           └── util.lua        # 密码哈希/随机token/HTML转义
├── conf/
│   ├── nginx.conf.template     # 全局配置、HTTP/HTTPS listener 与 TLS
│   ├── server.conf.template    # HTTP/HTTPS 共用 location 与代理配置
│   └── openssl.cnf             # 最小 openssl 配置(自签证书用)
└── test/
    ├── run_tests.sh            # 基础功能测试脚本
    ├── test_authz_gateway.sh   # Authz Gateway/API 隔离测试矩阵
    ├── test_klib_router_ctxvar.sh # 真实 OpenResty Router 回归
    ├── test_shared_session.sh  # 共享会话 (Redis 单写多读) 回归
    ├── conf/
    │   └── nginx.conf          # 测试用 nginx 配置
    ├── html/                   # FancyIndex 测试文件
    ├── fixtures/               # 迁移与数据库测试夹具
    ├── dav/                    # WebDAV 上传目录（运行时生成）
    └── logs/                   # nginx 日志（运行时生成）
```
