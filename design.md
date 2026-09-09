# openresty-base 设计文档 (design.md)

> 本文保留核心设计说明。当前维护入口、测试基线、部署流程和前端规则以
> [docs/maintenance-handbook.md](docs/maintenance-handbook.md) 与 `AGENTS.MD` 为准。

## 1. 项目定位

定制 OpenResty Alpine Docker 镜像，双职能：

1. **基础镜像**：源码编译的 OpenResty（最新 lua-nginx-module master）+ WebDAV/FancyIndex + JWT/HTTP 库
2. **Authz Gateway**（默认运行模式）：动态端口反向代理 + 本地会话认证授权 + 可选 NocoBase 身份源

## 2. 总体架构

```
                    ┌──────────────────────────────────────┐
 Browser ──http──▶  │ :6080 ──▶ 308 https (AUTHZ_HTTP_MODE)│
 Browser ──https─▶  │ :6443 ──▶ access_by_lua(resty.authz) │──▶ http(s)://<ip>:<port>
                    │            认证→casbin→解析目标端口   │    (上游协议由绑定决定)
                    │   /_authz/* → 统一 router (登录/OAuth/JSON API) │
                    │   /_authz/apps/ → 会话保护的静态管理端 │
                    │            │                         │
                    │   SQLite /data/authz/authz.db ◀─────│
                    │ (local/remote users, sessions, ACL) │
                    └──────────────────────────────────────┘
```

## 3. 目录结构与模块职责

```
Dockerfile                  多阶段构建; 内置 lua-resty-http/CA/sqlite-libs/SSI/ngx_brotli
docker-entrypoint.sh        ① 自签证书生成(缺失时) ② envsubst 渲染 nginx.conf ③ exec "$@"
conf/nginx.conf.template    网关主配置模板 (${HTTP_LISTEN}/${HTTP_SERVER_DIRECTIVE}/${HTTPS_PORT} 占位符, envsubst 只替换白名单变量; HTTP server 行为由 AUTHZ_HTTP_MODE 决定)
conf/openssl.cnf            最小 openssl 配置(镜像内 openssl 无默认 cnf)
lualib/resty/hmac.lua       resty.hmac 兼容垫片(OpenSSL 3.x), 供通用 resty.jwt 使用
lualib/resty/authz/         ★ Authz Gateway 核心
  init.lua                  稳定入口: init() + access() 委托
  config.lua                通用环境、会话、Redis、NocoBase 配置
  provider_config.lua       OAuth/OIDC Provider 装配
  gateway/                  access 链、解析、缓存、代理变量构造与响应改写(rewrite.lua)
  router.lua                /_authz 统一 router：登录/OAuth 页面 + /api/* JSON API
  ui.lua                    登录页与 OAuth 跳转处理
  api/guard.lua             session/admin/CSRF guard
  api/service.lua           保持公开方法名的薄门面
  api/services/             用户、绑定、策略、API Key、只读模型服务
  api/validation.lua        管理 API 领域输入校验
  repository/               按领域集中的运行时 SQL
  db.lua                    生命周期、缓存查询和事务门面
  db/                       驱动、schema、版本化迁移、seed、查询缓存
  casbin.lua                mini-casbin 执行器 (p/g 行, deny 优先)
  session.lua               服务端会话 CRUD + cookie 读写
  nocobase.lua              NocoBase signIn/check + 本地角色映射 + 远程身份快照
  oauth.lua                 OAuth2/OIDC + Google 授权码、PKCE、userinfo
  remote.lua                远程身份单向记录与本地角色覆盖
  util.lua                  密码哈希(HMAC-SHA256 迭代5000次)/随机token/HTML转义
test/run_tests.sh           基础镜像功能测试(17项断言, 不依赖 authz)
test/test_authz_gateway.sh  Gateway/API 隔离测试矩阵
test/test_shared_session.sh 共享会话 (Redis 单写多读) 独立回归
docs/sso-jwt-auth.md        SSO 集成指南
```

### 模块依赖关系

```
nginx.conf.template
  init_by_lua  → authz.init() → config/provider_config → db.init()
                                  → db/migrations(版本账本) → db/seed → close
  access_by_lua → authz.access() → gateway/access → resolver → session → casbin → proxy
  content_by_lua(/_authz) → router.lua → ui (login/OAuth) / guard → api/service → api/services
                                                    → repository → db.transaction
```

## 4. 数据模型 (SQLite)

| 表 | 关键列 | 说明 |
|----|--------|------|
| users | username(UNIQUE), password_hash, salt, roles, enabled, created_at, last_login_at, updated_at | 本地用户；认证状态仅启用/未启用，时间为 Unix 秒 |
| remote_users | provider+subject(PK), UNIQUE(provider,username), roles, remote_roles, roles_overridden, enabled, synced_at, created_at, last_login_at, updated_at | 单向身份记录；`synced_at` 为兼容存储列，API 输出 `recorded_at`；不保存密码/token |
| sessions | token(PK, 32B随机hex), username, source, csrf, expires_at | 本机服务端会话, TTL 默认7天 |
| policies | ptype('p'/'g'), v0, v1, v2, UNIQUE(ptype,v0,v1,v2) | casbin 策略行 |
| bindings | domain(UNIQUE), port, enabled, note | 显式域名绑定 |
| bindings (代理字段) | upstream_*/forwarded_*/origin_mode/custom_origin/simulate_local/local_ip/menu_name/header_overrides/**request_rewrite**/**response_rewrite** | `request_rewrite`/`response_rewrite` 为改写请求/响应的规范化 JSON（结构同构：headers/remove_headers/body/body_base64/content_type/rewrites），空串表示未配置 |
| schema_migrations | version(PK), name, applied_at | 已应用迁移的有序版本账本 |

**policies 编码约定**：
- `p` 行: v0=主体(`user:<source>:<username>`或`role:x`), v1=对象"/<port><path模式>", v2=HTTP方法或`*`
  - deny 编码在 v2 尾部: `"GET|deny"`（表无独立 eft 列）
- `g` 行: v0=`user:<source>:<username>`, v1=role:xxx；v2 固定 `-`
- seed 默认: 仅 `p,role:admin,/*,*` allow，其他角色默认拒绝（`guest` 无默认策略，因此代理默认拒绝）

**密码哈希**: `hex = to_hex(H(salt,...H(salt,H(salt,password))))`, H=HMAC-SHA256(key=salt), 迭代5000次。
Python 等价验证: `hmac.new(salt.encode(), prev, hashlib.sha256).digest()`。
## 4.1 环境变量完整参考

所有变量在 [`.env.example`](.env.example) 有带注释样例，此处按子系统归档语义与默认值。

**网络与解析**

| 变量 | 默认 | 语义 |
|------|------|------|
| AUTHZ_HTTP_PORT / AUTHZ_HTTPS_PORT | 6080 / 6443 | HTTP/HTTPS 入口端口 |
| AUTHZ_HTTP_MODE | redirect | `redirect`=HTTP 308 到 HTTPS；`disabled`=只监听 127.0.0.1；`serve`=明文服务（仅受控环境） |
| AUTHZ_PORT_MIN / AUTHZ_PORT_MAX | 2000 / 20000 | `<端口>-<域名>` 数字前缀动态路由允许的端口范围 |
| AUTHZ_DISCOVERY_PORTS | 空 | 服务发现追加探测端口（Docker Desktop 等容器监听表不可见时） |
| AUTHZ_DISCOVERY_TTL / _CONNECT_TIMEOUT_MS / _READ_TIMEOUT_MS | 30 / 100 / 200 | 本机 HTTP 服务探测缓存与超时 |

**存储与缓存**

| 变量 | 默认 | 语义 |
|------|------|------|
| AUTHZ_DB_PATH | /data/authz/authz.db | SQLite 路径 |
| AUTHZ_CERT_DIR | /data/certs | 自签证书目录（缺失自动生成 10 年期） |
| AUTHZ_FILES_ROOT | /files | 文件浏览应用只读根目录，必须与 server.conf 的 `/_authz/files/` alias 一致 |
| AUTHZ_DB_CACHE_TTL / _LRU_SIZE | 30 / 500 | 数据库查询缓存 |
| AUTHZ_REWRITE_BUFFER_MB | 64 | 正文改写 worker 级缓冲预算（单响应上限固定 1MB） |
| AUTHZ_NGINX_CONF_DIR / _PREFIX / _BIN / OPENRESTY_TEMPLATE_DIR | 镜像内路径 | nginx conf 在线编辑使用的运行时/模板目录与二进制 |

**会话与登录防护**（默认值见 §7 安全设计表）

| 变量 | 语义 |
|------|------|
| AUTHZ_SESSION_TTL | 会话有效期秒数 |
| AUTHZ_ADMIN_PASSWORD | 首次 seed 的 admin 密码（users 表为空时才生效） |
| AUTHZ_LOGIN_ATTEMPTS / _WINDOW / _FAIL_DELAY_MS | 按「账户名+IP」锁定阈值 / 锁定秒数 / 失败延迟毫秒 |
| AUTHZ_COOKIE_SECURE | 生产 HTTPS 入口必须 true；同时决定 SameSite=None/Lax（见 §14） |
| AUTHZ_COOKIE_DOMAIN | 逗号分隔多个父域，Cookie Domain 逐个匹配当前 Host/Origin |
| AUTHZ_HOST_URL | Cookie 域缺省回退来源；公网入口地址 |
| AUTHZ_SESSION_SHARED + REDIS_* | 共享会话开关与 Redis 连接/ACL/前缀/DB |
| AUTHZ_SESSION_SIGNING_KEY | 共享会话记录 HMAC 签名（>=32 字符，全组一致；无签名记录一律失效） |

**Agent / 机器凭证**

| 变量 | 默认 | 语义 |
|------|------|------|
| AUTHZ_API_KEY | eeeec9f034335f136f87ad84b625ffff | 实例级预置 Key：`x-api-key` 免登录访问控制面/管理页/代理入口；不入库、随环境变量轮换；32-256 字符；内置默认值仅适合本机/测试环境 |
| AUTHZ_API_KEY_ROLE | admin | 实例级 Key 角色（admin/staff/user/guest/api；旧 viewer 自动映射 guest 并告警） |
| AUTHZ_API_KEY_ALLOWED_IPS | 127.0.0.1 | 来源白名单，逗号分隔 IP 或 CIDR（v4/v6）；旧变量 AUTHZ_API_KEY_LOOPBACK 直接报错逼迁移 |

**远程身份（全部默认关闭）**：AUTHZ_NOCO_*（signIn/check 直连 + OAuth Client）、
AUTHZ_GOOGLE_*、AUTHZ_DINGTALK_*（Authorization Code，钉钉默认角色 guest）、
各 provider 的 CONNECT/SEND/READ 超时与 MAX_BODY_SIZE；OAuth state 使用
`authz_oauth_state` shared dict（TTL 默认 600s）。NocoBase 强制 HTTPS，除非显式
AUTHZ_NOCO_ALLOW_HTTP。

## 5. 请求处理流程 (authz.access())

```
Host 解析 (ngx.var.host 已 lowercase 无端口):
  1. bindings 精确匹配 (enabled=1) → port
  2. 正则 ^(\d{1,5})- 且 port ∈ [PORT_MIN,PORT_MAX] → port   ← 数字前缀免配置
  3. 否则 → 404 页面
会话认证: cookie authz_session → sessions 表查 token/source (过期即删)
  呈现 x-api-key / x-role-key 的机器请求不读 Cookie（见 §12）
  local 会话必须命中 enabled 本地用户
  任意远程 provider 会话必须命中对应来源的 enabled 本地记录；后续登录记录不得覆盖管理员设置的启用状态
  失败 → 302 /_authz/login?next=<request_uri>
规范主体: principal = "user:" .. source .. ":" .. username
Casbin 授权: enforce(principal, "/<port><uri>", HTTP_METHOD)
  deny优先/fail-closed → 失败返回 403 页面
设置 ngx.var.authz_target = <binding_scheme>://<target_ip>:<port>  → proxy_pass
     代理前从 Cookie 中剥离 authz_session(网关凭据不上游), 业务 Cookie 保留
     ngx.var.authz_user   = username                 → X-Authz-User 头
     ngx.var.authz_source = source                   → X-Authz-Source 头
     ngx.var.authz_identity = principal              → X-Authz-Identity 头

响应返回阶段（header_filter / body_filter，见 gateway/rewrite.lua）:
  绑定带 response_rewrite 时 → 覆盖状态码/响应头（含删除）
                            → 正文整体替换（body/base64/content_type）
                            → 或按规则过滤正文（字面量 / PCRE 替换）
  跳过条件：非 200、HEAD、WebSocket、已压缩、Range、非文本(过滤模式)、超过 1MB 缓冲上限
  跳过时在 X-Authz-Rewrite: skipped=<reason> 中显式标记，避免静默失效难排查
```

**上游协议由绑定记录决定**（`upstream_scheme`，默认 http）；HTTPS 上游默认校验证书，
只有绑定显式关闭校验才走内部 `@authz_proxy_insecure` 位置。HTTP 入口默认 308 到 HTTPS。

## 5.1 域名前缀与入口解析顺序

绑定表存的是**最后一级前缀**（如 `code`），完整入口域名在消费时按当前请求 Host
重组为 `<前缀>-<节点>.<域>`（节点取首级标签最后一个 `-` 段，如
`code-241.ai-t.wtvdev.com`）。同一套前缀在任意 wildcard 入口域下都可达，
管理界面永远只让用户填前缀。含点的存量值按精确域名原样匹配（历史物化域名
在同节点请求下仍可按 前缀|节点 回退）。菜单链接用 `display_host()`（优先
X-Forwarded-Host 首值）保证外层反代改写 Host 后链接仍落在用户输入的域上。

resolver（gateway/resolver.lua）按序命中：

1. bindings 精确 host 匹配（enabled=1）
2. 裸前缀索引：首级标签 `<前缀>` 或 `<前缀>-<节点>` 命中前缀绑定；纯数字前缀
   不参与带节点回退（让位给动态端口路由）；物化旧域名先按 `前缀|节点` 精确回退
3. 数字前缀：`^(\d{1,5})-` 且端口在 PORT_MIN~MAX → 端口，且默认
   `simulate_local=true`（目标固定 127.0.0.1：上游 Host/Forwarded 头按本机访问
   构造，兼容只认本地来源的本地应用）
4. 全部未命中 → 404 页面（host 已 HTML 转义）

代理循环防护：目标 IP+端口等于网关自身监听地址时返回 508。

## 5.2 上游请求构造（gateway/proxy.lua）

- `authz_session` Cookie 在代理前精确剥离，业务 Cookie 保留
- 固定头：X-Authz-User / X-Authz-Source / X-Authz-Identity；X-Forwarded-For 追加
  remote_addr；凭证头（x-api-key/x-role-key）不透传
- Host/Forwarded 链路头优先级：绑定显式 `upstream_host`/`forwarded_*` 覆盖 →
  `origin_mode`（auto/preserve/rewrite/remove/custom）→ simulate_local（本机值）→
  请求 Host
- 配了正文改写的绑定自动向上游声明 `Accept-Encoding: identity`（绑定显式覆盖
  Accept-Encoding 时以用户为准，改写随之失效）；`request_rewrite` 结构化改写在
  header_overrides 之后应用

## 6. 缓存一致性

- `lua_shared_dict authz_cache` 存授权 `rev` 和数据库 `db_rev`
- service 的多步骤写操作使用 `db.transaction()`；授权相关写操作使用 `db.authz_transaction()`
- revision 只在成功提交后由数据库门面自动递增；一次事务只递增一次，回滚不递增
- 每个 worker 维护 `{rev, enforcer, bindings}` 本地缓存，rev 变化时全量重载
- 直接改数据库不会触发失效（必须走管理界面或重启）

## 7. 安全设计

| 机制 | 实现 |
|------|------|
| 会话 | 服务端存储, cookie 仅 32B 随机 hex, HttpOnly+SameSite=Lax |
| CSRF | 管理修改 API 校验 `X-CSRF-Token` == session.csrf（登录除外） |
| 密码 | 盐+HMAC-SHA256 迭代5000, 常量时间比较 |
| 注入 | SQL 全部参数化绑定; HTML 输出经 escape_html |
| fail-closed | casbin 无匹配策略 → 拒绝; DB 不可用 → 报错不绕过 |
| 改密 | 删除该用户其他所有会话 |
| 登录防护 | 失败登录统一延迟 `AUTHZ_LOGIN_FAIL_DELAY_MS` 后返回；按「账户名+来源 IP」计数，窗口内连续失败达 `AUTHZ_LOGIN_ATTEMPTS` 即锁定该账户组合 `AUTHZ_LOGIN_WINDOW` 秒，锁定期内即使密码正确也拒绝；不锁定同 IP 下的其他账户 |
| next 参数 | 仅接受以 `/` 开头且非 `//` 的路径；拒绝反斜杠、控制字符和超长值 |
| 网关 Cookie 隔离 | `authz_session` 代理前精确剥离，不跨信任边界；403/404/508 页动态内容全部 HTML 转义 |
| 公网入口 | `AUTHZ_HTTP_MODE` 默认 `redirect`（308 HTTPS）；`disabled` 仅回环；`serve` 仅受控测试；维护期用防火墙白名单限制管理端 |
| 共享会话 | 单写多读：仅一个实例 `read-write`（登录/登出/改密/撤销），其余 `read-only`；Redis ACL 分层授权；Redis 故障失败关闭，不回退 SQLite |
| 远程认证 | 默认关闭；登录时显式选择来源；HTTPS 证书校验；密码/JWT 不落库 |
| OAuth/OIDC | Authorization Code + PKCE；一次性 state；NocoBase 校验 issuer 并使用 Basic Client 认证；access token 不落库 |
| 身份隔离 | 用户名与来源组成身份；同名多来源的会话、角色与直授权互不影响 |
| 管理边界 | 仅 admin 可读取用户列表、应用和 Casbin 策略；非管理员只读取自身会话资料 |
| guest 收口 | `guest` 只保留两项能力：只读诊断页 `/_authz/app/guest.html`，以及只回显调用者自身的 `GET /api/session`（例外由路由上的 `self_service` 标记显式声明，新增端点默认不放开）；其余控制面 API 被 guard 统一拒绝，`authorize_request` 与 `/_authz/apps` 放行逻辑同样排除 guest。诊断页服务端渲染、逐字段 HTML 转义、凭据脱敏、禁缓存（该页把请求头回显给调用方，是天然反射面，因此转义与脱敏在测试中作为固定断言） |
| 远程密码 | NocoBase、Google、钉钉、微信等远程身份不能在本机修改密码 |
| 远程生命周期 | 登录记录不覆盖本机启用状态；仅管理员删除记录后，下次认证才按新身份重新创建 |
| 响应改写 | 绑定级 response_rewrite 仅覆盖透传类响应头：Set-Cookie、Content-Length/Transfer-Encoding 等分帧与 hop-by-hop、X-Authz-*/X-Forwarded-*/Proxy-*、以及 XFO/CSP/HSTS/NOSNIFF 等安全头在 validation 与运行期双层拒绝；正则保存时做 PCRE 编译校验并限长（16 条/512/4096/64KB），正文改写只在 200 文本响应上缓冲且上限 1MB，超限原样透传，不改写 WebSocket/Range/压缩流 |

## 8. 关键实现约束 / 踩坑记录 ⚠

后续维护必读：

1. **Lua 模式不支持 `(组)?`、`(组)+`、`{n,m}` 量词** — 一律用 `ngx.re.match`(PCRE)
2. **LuaJIT FFI**: 必须显式 `ffi.load("libsqlite3.so.0")`（Alpine 运行包无 `.so` 软链,
   且 libsqlite3 不在 nginx 全局符号表）
3. **位运算**: 不要用 `|`/`~`（依赖 LUA52COMPAT 编译选项）, 用算术替代
4. **SQLite 并发**: WAL + busy_timeout=5000; master 进程 init 后必须 close,
   worker 各自懒加载重开（fd 跨 fork 共享会导致状态错乱）
5. **nginx worker 用户**: 模板中 `user root;` 是必须的, 否则 worker(nobody) 无权写挂载卷中的 db
6. **envsubst 只认 `${VAR}`**, 模板不要用 `@@VAR@@`; nginx 自身的 `$host` 等变量靠
   白名单(SHELL-FORMAT)保护不被替换
7. **镜像内 openssl CLI 无默认 cnf** → 必须 `OPENSSL_CONF=conf/openssl.cnf`
8. **cookie 与域名绑定**: 测试时同一会话必须访问同一 Host（curl 自定义 Host 头会干扰
   cookie 匹配, 用 `--resolve` 而非 `-H "Host:"`）
9. **ui.lua 中 local 函数有顺序依赖**（如 login_page 在 login_get 前定义）, 调整位置需注意
10. **docker exec 在容器启动早期可能挂起**, entrypoint 的 apk 重试循环期间网关不可达
11. **ngx.re.find/gsub 的返回值位次**: `find` 返回 `from, to, err`、`gsub` 返回
    `value, substitutions, err`；写成 `local _, err = ngx.re.find(...)` 永远拿到 nil，
    正则编译校验与替换错误会被静默吞掉
12. **cjson.decode 是 C 函数且严格检查参数个数**: `cjson.decode(s:gsub(...))` 会把 gsub 的
    替换计数当第二个参数传入并直接抛错（safe 版也不例外），必须用括号截断多返回值
13. **pcall(f, ...) 的返回值整体右移一位**: `local ok, a, b, c = pcall(f)`；少写一个占位
    就会把第一个业务返回值当成 ok 之后的值，导致静默取错字段
14. **字符串前缀比较按实际长度**: `"x-authz-"` 是 8 字符、`"x-forwarded-"` 是 12 字符，
    按 7/13 位比较会让黑名单静默失效（header 覆盖与响应改写都踩过）
15. **正文改写必须先拿到未压缩正文**: 上游看到 `Accept-Encoding: gzip` 就自行压缩，
    压缩字节上做文本替换没有意义，网关只能跳过（`X-Authz-Rewrite: skipped=encoded`），
    表现为"替换没生效"。配了正文改写的绑定由 `proxy.apply_headers` 向上游声明
    `Accept-Encoding: identity`；绑定里显式写了 Accept-Encoding 覆盖时以用户为准
    （代价是改写失效，二者不可兼得）。`Content-Encoding: identity` 视为未压缩，不跳过。
16. **规范化输出必须能被重新校验**: `response_rewrite.status` 规范化后写 `0`（= 不改状态码），
    若校验只接受 200-999，则规则一旦保存过，该绑定后续任何 PATCH 都会 422——
    用户改别的字段也保存不进去，排查方向极易被带偏到缓存/压缩上。
17. **`.q-dialog > div` 是 Quasar 的全屏居中容器**: 给它设 `max-width` 会让 `inset:0`
    的绝对定位失去 `right` 约束，容器从 left:0 起算，弹窗整体贴左。解除 560px 上限
    只能作用于卡片本身（`.q-dialog__inner--minimized > .xxx-card`）。

## 9. 构建与发布

- GitHub Actions (.github/workflows/build.yml): push main / 每周一 UTC 02:00 / 手动触发
- 推送 ghcr.io/yorkane/authz 与 docker.io/yorkane/authz
- Tag: latest / `<openresty版本>` / `<版本>-<日期>`
- 镜像发布和部署默认优先使用 GitHub Actions 产出的 GHCR 镜像；本地构建仅用于调试、验证或 CI 不可用时的回退。
- 本地构建使用 Docker CLI `buildx`：`docker buildx build --load --build-arg RESTY_J=${RESTY_J:-8} -t openresty-base:local .`。
  Dockerfile 将 Brotli 源码下载、OpenResty builder 和 runtime 分层；源码层、BuildKit 缓存和并行编译可复用。
  GitHub Actions 通过 `docker/setup-buildx-action` 与 `type=gha,mode=max` 保持同一构建路径。

## 10. 测试

```bash
# Router/ctxvar 真实 OpenResty 回归
OPENRESTY_TEST_IMAGE=openresty-base:nocobase-test bash test/test_klib_router_ctxvar.sh

# Authz Gateway/API/OAuth/代理隔离矩阵
OPENRESTY_TEST_IMAGE=openresty-base:nocobase-test bash test/test_authz_gateway.sh

# 共享会话 (Redis) 独立回归
OPENRESTY_TEST_IMAGE=openresty-base:nocobase-test bash test/test_shared_session.sh

# 基础镜像功能
bash test/run_tests.sh openresty-base:nocobase-test
```

测试矩阵覆盖: Router、端口解析、未认证重定向、本地用户、NocoBase mock 登录与角色查询、
OAuth state/PKCE/callback、同名多来源身份隔离、旧身份策略迁移、远端角色记录与本地覆盖、
来源级直授权、上游身份头、远程改密拒绝、绑定 CRUD、CSRF、Casbin 多方法授权和缓存失效、
网关 Cookie 不上游、403 转义与真实状态码、反斜杠开放跳转拒绝、HTTP→HTTPS 308、
Redis ACL 单写多读与故障失败关闭、Relay 退役 410。

## 11. API Key 子系统（api_key.lua）

两类 Key，权限统一走 Casbin 角色模型：

1. **数据库 Key**：管理界面创建（`ak_` + 64 hex），SQLite 只存 SHA-256 摘要；
   可选 `loopback_only`（仅回环来源可用）。可用 `x-api-key` 或专用头 `x-role-key`
   提交，两头同现以 `x-role-key` 为准；支持 rotate（旧值当场失效）与禁用。
2. **环境变量 Key**（AUTHZ_API_KEY）：实例级，只认 `x-api-key`；常量时间比较 +
   来源 IP/CIDR 白名单（`AUTHZ_API_KEY_ALLOWED_IPS`，v4/v6 皆可，跨族不匹配）；
   不入库、不签发会话 Cookie，因此不受管理界面禁用影响，随容器环境变量轮换。

`x-api-key` 认证顺序：先按 `ak_` 格式查库，未命中再与环境变量 Key 比较。
**只要呈现了任一凭证头就只认它**：Key 无效直接 401，绝不回退浏览器 Cookie。
凭证头不透传上游；代理/管理页的机器请求 401/403 返回 JSON 而非重定向。
`authorize_request`（管理页/静态资源/文件浏览免登录放行）唯一排除 guest——
guest 只能走 `/_authz/app/guest.html` 诊断页。

上游身份头：数据库 Key 收到 `X-Authz-User: <Key名>`、`X-Authz-Source: api-key`、
`X-Authz-Identity: api-key:<id>`；环境变量 Key 固定 id=0（identity `api-key:0`）。

## 12. Cookie 域选择与多域名会话（session.lua）

- `AUTHZ_COOKIE_DOMAIN` 支持逗号分隔多个父域；启动时归一化为有序列表。
- 每次下发 Cookie 时 `current_cookie_domain()` 按序选择：
  1. IP/IPv6 Host → 不带 Domain 属性（host-only；Domain=.IP 会被浏览器归一化，
     造成登录后立刻丢会话）；
  2. Origin 头优先：反向代理改写 Host、请求 Origin 与实际 Host 不一致时，若 Origin
     主机命中已配置父域，则以该配置域下发（例：Origin `*.ws.gatepro.cn`、Host 被改成
     `*.ai-t.wtvdev.com` → Cookie 落在 `.ws.gatepro.cn`）；
  3. 否则按当前 Host 匹配父域，取标签数最多的配置域，且不窄于 Host 自身派生域；
  4. 配置域与 Host 不匹配时退回 host-only，绝不下发浏览器会拒绝的 Domain。
- Secure 标志：AUTHZ_COOKIE_SECURE、TLS 入口或 X-Forwarded-Proto=https 任一满足即
  Secure；Secure 时 SameSite=None（沙箱页面/文件预览需要），纯 HTTP 部署保持 Lax。
- 登录/登出同时清理历史遗留 Domain 变体（旧父域链、host-only），避免旧 Cookie 残留
  造成反复跳登录页。
- 不同注册域之间不能靠 Cookie Domain 互通：各入口各自承载 Cookie + 共享 Redis 会话
  （单写多读 + HMAC 签名，见 §7）。

## 13. 左侧菜单与服务发现

菜单由两部分合成（api/services/read_models.lua）：

- **menu_entries**（自定义树）：kind=group/item，支持 parent_id 两级嵌套、icon、
  url、admin_only、enabled、sort_order、builtin（`local`/`domains` 两个内置分组
  受 409 保护不可删）；reorder 在 `/:id` 路由之前注册。
- **menu_services**（运行时注入项）：键为 `binding:<id>`（域名服务组）或
  `port:<port>`（本地服务组），覆盖数据存 menu_overrides 表，显示名单一数据源是
  `bindings.menu_name`；支持改名/图标/排序/隐藏，DELETE 是重置回默认而非删除。

服务发现（discovery.lua）：读 `/proc/net/tcp{,6}` 的 LISTEN 条目（回环 + tcp6），
过滤端口范围与网关自身端口，合并 AUTHZ_DISCOVERY_PORTS，再对每个端口向
127.0.0.1 发 HEAD 探测是否 HTTP 服务；结果按 `AUTHZ_DISCOVERY_TTL`（默认 30s）
worker 内缓存。域名绑定占用的端口不会重复出现在本地服务组。menu-tree 只返回
启用项（admin_only 按 subject 过滤），编辑器走 `GET /menu-services` 看含隐藏项全量。

## 14. Nginx conf 外置 include 与在线编辑（nginxconf.lua）

三个用户可编辑文件在启动时由 entrypoint 动态生成（缺省带注释内容）：
`http_inc.conf`（http{} 尾部）、`server_inc.conf`（server{} 尾部，默认含
favicon/noc.gif 心跳 location）、`stream_inc.conf`（stream{}）。运行时由 nginx.conf
template include；compose 可把模板目录只读挂载实现外置。

在线编辑 API（`/_authz/api/nginx-conf*`，admin-only）：

- `GET /nginx-conf` 读取三个文件（单文件上限 256KB，超限截断标记）；
- `POST /nginx-conf/validate` 与 `PUT /nginx-conf` 先把整个运行时 conf 目录复制到
  一次性 staging 前缀、只替换被编辑文件、跑 `openresty -t`，成功才落盘——校验失败
  永远碰不到在线文件，不会卡住并发 reload；
- `POST /nginx-conf/reload` 触发 `openresty -s reload`。
- 持久化规则：模板目录未设置或等于运行时目录，或模板目录可写时编辑可持久；否则
  API 返回 `persistent:false` 提示重启后丢失。

## 15. 文件浏览与 guest 诊断页

- 文件浏览：`GET /api/files?path=` 只读列目录（root=AUTHZ_FILES_ROOT），前端
  `files.html`；会话或合法 Key 均可访问， guest 除外。
- guest 诊断页 `/_authz/app/guest.html`（guest.lua 自含认证）：guest 角色的数据库
  Key 或 guest 会话可访问，admin 也可；服务端渲染回显调用者请求头/来源 IP/代理转发
  链，逐字段 HTML 转义 + 敏感头脱敏 + 禁缓存；`?json=1` 返回同数据 JSON。该页是
  天然反射面，转义与脱敏是回归测试固定断言。

## 16. 控制面 API 概览（router.lua 注册序）

| 域 | 端点 | 门禁 |
|----|------|------|
| 页面 | `GET /_authz/login`、`POST /login`、`/oauth/start|callback` | 公开 |
| 会话 | `GET/DELETE /api/session` | self_service（guest 可读自身）；DELETE session_only+CSRF |
| 用户 | `GET/POST /api/users`、`PATCH/DELETE /api/users/:id`、`PUT /users/:id/password` | admin（改自己密码除外，session_only） |
| 远程用户 | `PATCH/DELETE /api/remote-users/:provider` | admin |
| 授权视图 | `GET /api/authorization` | admin |
| 绑定 | `GET /api/applications`（登录即可读）、`POST`（admin+api 角色）、`PATCH/DELETE`（admin） | CSRF |
| API Key | `GET/POST /api/api-keys`、`PATCH/DELETE /:id`、`POST /:id/rotate` | admin；rotate 走 authz 事务 |
| 策略 | `POST/PATCH/DELETE /api/policies` | admin |
| 菜单 | `GET /api/menu-entries|menu-tree|menu-services`、`POST/PATCH/DELETE menu-entries`、`PUT menu-entries/reorder`、`PATCH/DELETE menu-services/:key`、`PUT menu-services/reorder` | 读取登录即可；写 admin |
| 文件 | `GET /api/files` | 登录/Key，guest 除外 |
| conf | `GET /api/nginx-conf`、`POST validate`、`PUT`、`POST reload` | admin |

guard 语义：`admin=true` 要求 admin；`roles` 白名单；`csrf=true` 校验
`X-CSRF-Token == session.csrf`（机器 Key 请求免）；`session_only` 拒绝 Key；
`self_service` 放行 guest 的只读自身端点。错误统一 `{error:{code,message}}`，
404/500 按 Accept 头回 JSON 或 HTML。
