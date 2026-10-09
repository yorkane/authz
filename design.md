# authz 设计文档 (design.md)

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
  shared_session_store.lua  ★ 共享会话（Redis）读写 + 熔断 + 降级：跨 worker 熔断器（共享字典）、
                          网络故障期改读本机 sessions 镜像（grace，默认 4 小时）、故障期动作入待写队列
  shared_session_sync.lua   ★ 待写队列重放定时器：init_worker 里启动、owner 锁保证单条重放链，每 15s 一轮
                          按 id 升序重放 session_pending；熔断 OPEN 时本轮直接返回，不做网络尝试
  nocobase.lua              NocoBase signIn/check + 本地角色映射 + 远程身份快照
  oauth.lua                 OAuth2/OIDC + Google 授权码、PKCE、userinfo
  remote.lua                远程身份单向记录与本地角色覆盖
  util.lua                  密码哈希(HMAC-SHA256 迭代5000次)/随机token/HTML转义
  s3.lua / s3_upload.lua / s3_scope.lua / s3_proxy.lua
                          S3 客户端与 multipart 中转、可写范围白名单、字节流出口
  s3_config_store.lua     ★ 多套 S3 配置的运行时枢纽：把「表行」或「env 默认项」统一成
                          与 config.s3 同构的 cfg 表；改表即生效（worker 本地派生缓存按
                          db_rev 判活，行数据经 mlcache TTL 30s）
  store.lua / store_proxy.lua
                          本机「临时保存区」文件原语（归一化/符号链接防护/原子写）
                          与只读字节流出口 /_authz/store/<rel>
  maintenance.lua         ★ 每小时后台维护：到期对象/文件清理 + 上传暂存残留扫描；
                          共享字典抢单 owner，由 init_worker_by_lua_block 里 start()
  api/services/s3_configs.lua / uploads.lua / store.lua
                          存储配置 CRUD 与校验、上传记账与清理、保存区业务层
  repository/s3_configs.lua / upload_records.lua
                          两张新表的 SQL（META 列集合在 SQL 层就不选明文密钥）
test/run_tests.sh           基础镜像功能测试(17项断言, 不依赖 authz)
test/test_authz_gateway.sh  Gateway/API 隔离测试矩阵
test/test_shared_session.sh 共享会话 (Redis 单写多读 / 容错降级 / 待写队列) 独立回归
docs/sso-jwt-auth.md        SSO 集成指南
```

### 模块依赖关系

```
nginx.conf.template
  init_by_lua  → authz.init() → config/provider_config → db.init()
                                  → db/migrations(版本账本) → db/seed → close
  init_worker   → shared_session_sync.start()（owner 锁抢单，重放 session_pending）
  access_by_lua → authz.access() → gateway/access → resolver → session → casbin → proxy
  content_by_lua(/_authz) → router.lua → ui (login/OAuth) / guard → api/service → api/services
                                                    → repository → db.transaction
```

## 4. 数据模型 (SQLite)

| 表 | 关键列 | 说明 |
|----|--------|------|
| users | username(UNIQUE), password_hash, salt, roles, enabled, created_at, last_login_at, updated_at | 本地用户；认证状态仅启用/未启用，时间为 Unix 秒 |
| remote_users | provider+subject(PK), UNIQUE(provider,username), roles, remote_roles, roles_overridden, enabled, synced_at, created_at, last_login_at, updated_at | 单向身份记录；`synced_at` 为兼容存储列，API 输出 `recorded_at`；不保存密码/token |
| sessions | token(PK, 32B随机hex), username, source, csrf, expires_at, verified_at | 本机服务端会话, TTL 默认7天。共享模式下它同时是 Redis 的**降级镜像**：`verified_at` = 最近一次经 Redis 确认存在的时刻（NULL = 非共享模式本机自签发），熔断 OPEN 期间的降级读以它为判据 |
| session_pending | id(PK AUTOINCREMENT), op, token, username, source, csrf, expires_at, attempts, created_at | 共享会话待写队列（迁移 v28）：Redis 网络故障期间本该落到 Redis 的动作按发生顺序入队，`op` ∈ save/delete/delete_all；重放成功后删除该行。`session_pending_op_idx(op, id)` 支撑按序取批 |
| policies | ptype('p'/'g'), v0, v1, v2, UNIQUE(ptype,v0,v1,v2) | casbin 策略行 |
| bindings | domain(UNIQUE), port, enabled, note | 显式域名绑定 |
| bindings (代理字段) | upstream_*/forwarded_*/origin_mode/custom_origin/simulate_local/local_ip/menu_name/**request_rewrite**/**response_rewrite** | `request_rewrite`/`response_rewrite` 为改写请求/响应的规范化 JSON（结构同构：headers/append_headers/remove_headers/body/body_base64/content_type/rewrites；append 仅请求侧），空串表示未配置；header_overrides 列已由迁移 17 并入 request_rewrite |
| schema_migrations | version(PK), name, applied_at | 已应用迁移的有序版本账本 |
| s3_configs | id(PK AUTOINCREMENT), name(UNIQUE), endpoint, region(`DEFAULT 'us-east-1'`), allow_http(DEFAULT 0), access_key_id(''), **secret_access_key('')**, writable_paths(''), share_root('share'), share_bucket(''), expires_hours(0), use_bucket_lifecycle(0), default_bucket(''), local_root(''), is_default(0), enabled(1), note(''), created_at, updated_at | 多套 S3 服务配置（迁移 v23）。一行 = 一套服务；表内无可用行时回落 `AUTHZ_S3_*`。`secret_access_key` 为**明文**（见 §17.3） |
| upload_records | id(PK AUTOINCREMENT), kind(DEFAULT 's3'), cfg_id(**可空、无外键**), bucket(''), key(''), size(0), source('api'), created_by(''), created_at, expires_at(**可空**), state('active'), last_error(''), checked_at | 上传流水账 + 过期清理队列（迁移 v24）。`expires_at` NULL = 永不过期，非 NULL 必须整点对齐；`state` ∈ active/deleted/failed/skipped。`idx_upload_records_expiry(state, expires_at)` 是清理队列唯一入口 |

菜单入口由迁移 `25:menu_entry_s3_configs` seed：系统应用组下的「存储配置」
（`builtin='s3Configs'`，`admin_only=1`，sort_order=18）——该页面能编辑明文入库的
S3 凭证，与「对象存储」「Nginx配置(危险)」同级，不给 staff 看到。

迁移 `26:retire_s3_share_ttl` 为既有库执行 `ALTER TABLE s3_configs DROP COLUMN
share_ttl`（v23 建表已不含该列，因此先判存在再删，新库不受影响）。

迁移 `27:hide_menu_s3_configs` 把该菜单条目 `enabled=0`（照抄 v22 隐藏 nginxConf 的做法）：配置能力改由「对象存储」页工具栏「配置」按钮进入页内视图（s3.html 内嵌 az-s3-configs 组件，锚点 `#configs` 直达），`/_authz/apps/s3-configs.html` 保留为挂载同一组件的薄壳直链页。条目本身不删，菜单编辑器的平铺接口仍能看到并随时重新启用。

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
| AUTHZ_APP_DOMAINS | 1 | 内置应用保留前缀域名入口总开关（`0` 关闭，file/s3 域名回退 404） |
| AUTHZ_APP_PREFIX_FILES / AUTHZ_APP_PORT_FILES | file / 100 | files 应用的保留前缀与虚拟端口。根路径渲染页面，带子路径的 GET/HEAD 直取 `AUTHZ_FILES_ROOT` 下的文件字节（§5.1） |
| AUTHZ_APP_PREFIX_S3 / AUTHZ_APP_PORT_S3 | s3 / 101 | s3 应用的保留前缀与虚拟端口。根路径渲染页面，带子路径的 GET/HEAD 直取当前配置 `default_bucket` 下的对象字节（§5.1） |
| AUTHZ_DISCOVERY_PORTS | 空 | 服务发现追加探测端口（Docker Desktop 等容器监听表不可见时） |
| AUTHZ_DISCOVERY_TTL / _CONNECT_TIMEOUT_MS / _READ_TIMEOUT_MS | 30 / 100 / 200 | 本机 HTTP 服务探测缓存与超时 |

**存储与缓存**

| 变量 | 默认 | 语义 |
|------|------|------|
| AUTHZ_DB_PATH | /data/authz/authz.db | SQLite 路径 |
| AUTHZ_CERT_DIR | /data/certs | 自签证书目录（缺失自动生成 10 年期） |
| AUTHZ_FILES_ROOT | /files | 文件浏览应用只读根目录，必须与 server.conf 的 `/_authz/files/` alias 一致 |
| AUTHZ_STORE_DIR | /data/store | 本机「临时保存区」根目录（`PUT /_authz/api/store` 落点，必须可写）。与 files_root 语义分离：store 由网关自己管生命周期、不承诺长期保存；files_root 给人浏览、默认只读。落在 compose 的 `${DATA_DIR}:/data` 卷下（宿主 `${DATA_DIR}/store`），无需额外 volume |
| AUTHZ_STORE_DEFAULT_EXPIRY_HOURS | 24 | 保存区默认保留小时数，钳 0-8760；0 = 永不过期。单次请求可用 `?expires_hours=` 覆盖 |
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
| AUTHZ_SESSION_SHARED_FALLBACK | 共享会话 Redis 网络故障时是否容错降级（默认 true 降级读 SQLite 镜像 + 待写队列；false = 严格 fail-closed） |
| AUTHZ_SESSION_RETRY_INTERVAL_MS | `session_pending` 重放定时器周期，默认 15000ms（钳 1000..600000）；owner 锁保证同一时刻只有一条重放链 |
| AUTHZ_SESSION_FALLBACK_GRACE | 降级宽限期（秒，默认 14400，钳 60..604800）：会话经 Redis 确认存在的可信窗口，同时是跨实例撤销延迟上限 |

**Agent / 机器凭证**

| 变量 | 默认 | 语义 |
|------|------|------|
| AUTHZ_API_KEY | eeeec9f034335f136f87ad84b625ffff | 实例级预置 Key：`x-api-key` 免登录访问控制面/管理页/代理入口；不入库、随环境变量轮换；32-256 字符；内置默认值仅适合本机/测试环境 |
| AUTHZ_API_KEY_ROLE | admin | 实例级 Key 角色（admin/staff/user/guest/api） |
| AUTHZ_API_KEY_ALLOWED_IPS | 127.0.0.1 | 来源白名单，逗号分隔 IP 或 CIDR（v4/v6）；旧变量 AUTHZ_API_KEY_LOOPBACK 直接报错逼迁移 |

**远程身份（全部默认关闭）**：AUTHZ_NOCO_*（signIn/check 直连 + OAuth Client）、
AUTHZ_GOOGLE_*、AUTHZ_DINGTALK_*（Authorization Code，钉钉默认角色 guest）、
各 provider 的 CONNECT/SEND/READ 超时与 MAX_BODY_SIZE；OAuth state 使用
`authz_oauth_state` shared dict（TTL 默认 600s）。NocoBase 强制 HTTPS，除非显式
AUTHZ_NOCO_ALLOW_HTTP。

**对象存储**：`AUTHZ_S3_*` 全套现在是**回落默认配置**（表里没有可用行时才生效），
优先级与字段继承口径见 §17；四个超时/连接池项是实例级参数，表行也复用同一份 env 取值。

**存储区**：`AUTHZ_STORE_DIR` + `AUTHZ_STORE_DEFAULT_EXPIRY_HOURS`（见上表）。
到点回收由 §17.4 的每小时定时器负责，改这两个 env 需要重建容器。

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
3. 内置应用保留前缀（虚拟绑定，config.app_prefixes）：`file`→100/files.html、
   `s3`→101/s3.html（env 可改/可关，见 §4）。**数据库真实绑定优先于虚拟入口**：
   管理员显式绑定同名前缀时在上一步就被接管。命中时返回保留端口 +
   `binding.app` 标记，认证与 Casbin 照常（对象 `/<端口><uri>`，端口虽在
   PORT_MIN 之下但策略对象白名单放行——这就是「单独配置授权」的落点）。
   此后按 URI 分流（见本节末尾「保留前缀域名的内容路径分流」）：根路径 `/` 走页面，`ngx.var.authz_app_entry`
   置位并 internal redirect 到 `/_authz/apps/<页面>`（不代理上游），页面静态
   资源在 `/_authz/apps/` 的 access 钩子（gateway/app_entry.lua）里按同一端口
   对象复用同一套策略；带子路径的内容请求改写 URI 到 `/_authz/files/` 或
   `/_authz/s3/`，复用既有 location 与其流式代理。该端口不允许被域名绑定
   占用（applications 服务拒绝 422）。
4. 数字前缀：`^(\d{1,5})-` 且端口在 PORT_MIN~MAX → 端口，且默认
   `simulate_local=true`（目标固定 127.0.0.1：上游 Host/Forwarded 头按本机访问
   构造，兼容只认本地来源的本地应用）
5. 全部未命中 → 404 页面（host 已 HTML 转义）

代理循环防护：目标 IP+端口等于网关自身监听地址时返回 508。

**保留前缀域名的内容路径分流（直取语义）**：虚拟入口命中后不再只有「渲染页面」一种出口，
gateway/access.lua 按原始 URI 分流两条路径：

- **根路径 `/`**：与既往逐字相同 —— `ngx.var.authz_app_entry` 置位 + internal redirect
  到 `/_authz/apps/<页面>`，页面与它的静态资源都靠 `gateway/app_entry.lua` 按同一端口对象
  复用同一套策略。这条保持不变是为了不让既有入口页与其资源加载因这次改动而回归。
- **带子路径**（GET/HEAD）：改写 URI 到 `/_authz/files/<路径>`（files 入口）或
  `/_authz/s3/<bucket>/<key>`（s3 入口，bucket 取当前生效那套存储配置的 `default_bucket`，
  `?cfg=<id|name>` 换一套时取被选中那套），再 `ngx.exec` 进**既有**的那两条 location。
  这是本设计的关键取舍：Range 206 分段、Content-Type 推断、`?download=1` 的
  `Content-Disposition`、`?authz_preview=1` 的沙箱 CSP + nosniff、s3 的 SigV4 代签与
  连接复用，全部已经在 `/_authz/files/`（静态 alias + `open_file_cache`）与
  `/_authz/s3/`（`content_by_lua` + `s3_proxy.lua`）里被真实回归覆盖。另写一条字节流通道
  等于把同一套语义在两个地方各自漂移一遍，收益只是省一次内部跳转。

内容路径上的三类拒绝各自说清一件事：非 GET/HEAD → 405 + `Allow: GET, HEAD` —— 直取是只读
语义，写操作永远走控制面那组接口，回 405 而不是 404 是让调用方一眼看清「这条路不支持写」，
而不是以为路径写错了；URI 含 `..` 段或控制字符 → 400（在进文件系统与签名器之前就拒，与
`store_proxy.lua`、`s3_proxy.lua` 同口径）；
路径不存在 → 404 而不是回落成 200 的 SPA 页面 —— 直取端点是给 `<video src>` 和外部系统
当链接用的，一个 200 的 HTML 会让播放器报「格式不支持」而不是「文件不存在」，把排障引到
错误方向；s3 端取不到存储配置或该配置 `default_bucket` 为空 → 503 + JSON，消息区分
「对象存储未配置」与「未设置默认 bucket」，两者运维动作不同（前者去配一套服务，后者只需补一个桶名）。

**为什么授权落点完全不变**：分流只改 URI 的去向，Casbin 的 enforce 仍发生在改写之前、
用的仍是 `/<虚拟端口><原始 uri>`（`/100/alice/pub/a.txt`、`/101/share/pub/v.mp4`）。于是
「按目录分级」自然成立：管理员给 `/100/alice/*` 放行就能匿名读 alice 的公开目录，不写
`/100/bob/*` 则 bob 目录继续 fail-closed（匿名 302 到登录页，已登录或带 Key 但无权 403）。
内部路径 `/_authz/files/...`、`/_authz/s3/...` 自身的鉴权门一字未改（仍要会话或合法非 guest
API Key），新放行只对「经保留前缀域名进来且已过 Casbin」的请求生效 —— 否则等于给内部路径
开了第二条绕过会话的后门。数据库里存在同名前缀的真实绑定时仍然优先（第 2 步就 return），
管理员显式接管虚拟入口的能力保留。

**内容出口零符号链接信任**：内容根在部署里通常是宿主真实可写的目录树，而静态 alias 自身不做
realpath（nginx 只把 URI 剩余段拼到 alias 后 open()，符号链接直接跟随），于是「一条目录级放行
策略 + 树里一个指向 /etc 的链接」就是任意文件读；何况内容根所在的 /data 正是 authz 自己的
状态库（用户、API Key、会话都在 SQLite 里），绝不能从内容出口外泄。所以 files 端在 internal
redirect 之前对每条候选形态（归一化 $uri、原始未解码串、逐层 unescape 梯）逐级 realpath，
要求解析结果与刚拼接出的路径**逐字相等** —— 父级是上一轮实测过的实体，这一判据恰好等价于
「该级不是指向别处的符号链接」，即只认实体目录：出根、入根、指向 /etc 或 /data、指向挂载点、
根内相对链接，一视同仁在该级 400，消息「路径含符号链接，内容出口只信任实体目录」。realpath
解不出来但对象确实存在（ELOOP/EACCES/悬空链接）同样拒绝，报「无法解析真实路径」；该级不存在
则交回 nginx 走 404；连 root 自身都解析不出来才退成放行交给 nginx 404。校验比对的是 alias
真正 open 的 /files（files.default_root 常量），不是 AUTHZ_FILES_ROOT —— 后者只影响控制面
浏览与写接口，改它不改 alias，拿它校验会校验到一个不相干的目录。

这里没有落点豁免：不存在任何形式的符号链接白名单，也没有「碰巧是挂载点就放行」的自动放行。
一旦允许某条链接被跟随，「逐字相等」这条判据就不再闭合，配置会沿「先放一条、再放一片」漂移，
最终退化成任意文件读的反面教材。外部目录（NFS、宿主大盘）要经 file 域名放行，唯一正确姿势是
把它作为**实体 bind** 挂进内容根下的子目录：挂载落点本身是真实目录，realpath 原地不动，照常
通过，链接本身则应从内容根里去掉。worker 内只缓存「已实测为实体」的中间目录以省去重复 syscall，
叶子不缓存 —— 链接可以事后被换成指向别处的目标，缓存叶子等于把判据变成 TTL。

**决策记录：为什么最终一条链接也不跟随**（记在这里，防止这条路被重开）。零链接判据落地当天，
为了让常见的外部大盘少改一次配置就能用，先后实现过两套放松机制，两套都写完、都过了当时的测
试，最终都在同一天删除：其一是 `AUTHZ_APP_TRUSTED_ROOTS`（已删除的机制）—— 由运维手工列举一
组可信根前缀，命中前缀即跳过该前缀下的链接判定；其二也是已删除的机制 —— 由系统挂载表推导的
「运维挂载点自动可信」，fstype 命中白名单的挂载点被当作实体对待、允许链接指向它，另配一份反
向排除名单把 `/data` 这类敏感前缀挡回去。删它们不是因为实现有缺陷，而是裁决本身：信任只以实
体目录为准，软链接一律不跟随。

判据必须是「逐字相等」，而不是「解析后仍在 root 内」。后者允许链接存在、只限制它能去哪里，
安全性取决于合法落点枚举是否完备；前者不问去向，只要这一级是链接就拒，判据成立与否与配置无
关。它之所以闭合，全靠对每一类链接给出同一个答案：出根、入根、指向 /etc 或 /data、指向挂载
点、根内相对链接，同为 400。一旦允许其中一条被跟随，判据就从「是不是链接」退化成「这条链接
配没配上白名单」，而配置面天然是增量的：先放一条、再放一片，第三次有人把整棵外部树纳进来，
就回到「一条目录级策略 + 一个链接 = 任意文件读」的原点。反向排除名单那一侧的风险更硬：`/data`
是 authz 自己的凭据库（用户、API Key、会话都在其中的 SQLite 里），自动可信等于要求每新增一
类 fstype、每新挂一卷，都有人记得补一条排除；漏一条的后果不是功能不可用，而是凭据从内容出口
外泄。这套判据宁可把「不可用」暴露得响亮（400 带段名），也不把「外泄」隐藏得安静。今后不要
再以「配一个白名单」的方式放松这条，无论白名单写在配置里还是从系统事实里推导出来。

外部目录（公共 NFS、宿主大盘）经 file 域名放行的唯一姿势是**实体 bind**：把目标树直接挂进内
容根下的子目录，挂载落点本身是真实目录，realpath 原地不动，照常通过，不需要任何豁免（具体挂
载写法与本机实况见 `deploy.md` §3.6）。

**双通道不对称是刻意的**。同一个内容根，两条通道的判据不同：保留前缀域名的直取通道（本节）
逐级要求 realpath 与拼接串逐字相等；管理界面 `/_authz/files/` 走静态 alias，既不 realpath
也不校验落点，符号链接照常跟随。两者可以不同，是因为信任前提不同 —— 管理界面那侧的调用方已
经用会话或 API Key 证明过身份，可读范围由控制面的 root 与可写范围约束，链接跟随带来的增量暴
露落在「已授权者本就能浏览这棵树」的假设之内；直取那侧的调用方可以是匿名 guest，唯一的门是
一条目录级 Casbin 放行，粒度远粗于目录树里可能存在的链接形状，所以判据必须退回文件系统自身
的事实：只认实体。记下这点是为了拦住两类误判：拿「管理界面读得到」论证直取也该读到；或者反
过来给管理界面补一套 realpath 校验去「统一行为」—— 后者会打断既有部署里靠链接组织的浏览树，
又不消除任何真实威胁，因为那侧的门本来就不建立在路径形状上。


## 5.2 上游请求构造（gateway/proxy.lua）

- `authz_session` Cookie 在代理前精确剥离，业务 Cookie 保留
- 固定头：X-Authz-User / X-Authz-Source / X-Authz-Identity；X-Forwarded-For 追加
  remote_addr；凭证头（x-api-key/x-role-key）不透传
- Host/Forwarded 链路头优先级：绑定显式 `upstream_host`/`forwarded_*` 覆盖 →
  `origin_mode`（auto/preserve/rewrite/remove/custom）→ simulate_local（本机值）→
  请求 Host
- 配了正文改写的绑定自动向上游声明 `Accept-Encoding: identity`（绑定显式覆盖
  Accept-Encoding 时以用户为准，改写随之失效）
- **改写优先于 proxy_set_header**：nginx 语义里 proxy_set_header 会覆盖 access 阶段
  `ngx.req.set_header` 的同名头，因此 Host/Cookie/Origin/Forwarded/X-Forwarded-*/
  X-Real-IP/X-Authz-User|Source|Identity 这些由 `$authz_*` 变量下发的托管头，绑定级
  改写写入的是**变量本身**（`MANAGED_REQUEST_VARS` 映射），proxy_set_header 携带
  改写后的最终值发往上游；删除托管头 = 变量置空串（proxy_set_header 对空值不发送该头）。
  普通业务头仍走 set_header/clear_header
- 请求改写支持三种操作（对齐 APISIX request-rewrite）：`headers` 替换（值 null=删除）、
  `append_headers` 追加、`remove_headers` 删除。执行顺序 remove → append → set；
  同名替换与追加互斥（422），删除可与任一叠加（先删后加/先删后设）。追加语义：
  托管头并入变量现值（Cookie 用 "; " 拼 cookie 对，其余用 ", " 拼列表），普通头经
  `ngx.req.set_header` 传数组生成多行请求头（目标镜像实测上游收到独立两行）
- 请求改写最终禁止名单（validation 与 rewrite.parse_request 同一口径）只剩两类：
  分帧/hop-by-hop 头（Content-Length、Transfer-Encoding、Connection、Upgrade、TE、
  Trailer、Keep-Alive）与网关凭据头（X-Authz-Key/X-API-Key/X-Role-Key，proxy_set_header
  已置空，开放改写等于把网关钥匙递给上游）；X-Authz-* 前缀仅放行三个身份断言头，
  Proxy-* 前缀保留拦截

## 6. 缓存一致性

- `lua_shared_dict authz_cache` 存授权 `rev` 和数据库 `db_rev`
- `lua_shared_dict authz_shared_session`（1m）存共享会话的跨 worker 熔断状态（OPEN 窗口到期时刻、
  连续失败次数、故障类别）与 `ss:seen:<token>` 节流键（带 TTL，限制镜像回写频率）；熔断放共享字典
  而非 worker 局部，是为了让任一 worker 探测到的 Redis 故障立刻对所有 worker 生效，避免每个 worker
  各自重复付一次 connect/read 超时。降级判据本身是 SQLite `sessions.verified_at`（跨 worker、跨重启
  的权威凭据），共享字典里的 seen 键只是节流阀。
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
| 共享会话 | 单写多读：仅一个实例 `read-write`（登录/登出/改密/撤销），其余 `read-only`；Redis ACL 分层授权。Redis **网络故障**走容错降级：跨 worker 熔断（OPEN 期零网络等待，指数退避 5s→60s）+ 读本机 SQLite 会话镜像（该会话在 grace 内经 Redis 确认过才承认，`AUTHZ_SESSION_FALLBACK_GRACE` 默认 4 小时）+ `session_pending` 待写队列恢复后按序重放；`AUTHZ_SESSION_SHARED_FALLBACK=false` 恢复严格 fail-closed。AUTH/SELECT 失败属配置错误，不降级。已知限制：故障期其他实例的撤销最长延迟一个 grace 才生效 |
| 远程认证 | 默认关闭；登录时显式选择来源；HTTPS 证书校验；密码/JWT 不落库 |
| OAuth/OIDC | Authorization Code + PKCE；一次性 state；NocoBase 校验 issuer 并使用 Basic Client 认证；access token 不落库 |
| 身份隔离 | 用户名与来源组成身份；同名多来源的会话、角色与直授权互不影响 |
| 管理边界 | 仅 admin 可读取用户列表、应用和 Casbin 策略；非管理员只读取自身会话资料 |
| guest 收口 | `guest` 是匿名用户角色，默认只保留两项能力：只读探针 `/_authz/guest`，以及只回显调用者自身的 `GET /api/session`（例外由路由上的 `self_service` 标记显式声明，新增端点默认不放开）；其余控制面 API 被 guard 统一拒绝，`authorize_request` 与 `/_authz/apps` 放行逻辑同样排除 guest。guest 的代理访问范围与其他角色一样由策略（`role:guest` 主体）配置。探针页服务端渲染、逐字段 HTML 转义、禁缓存，但**全部请求头明文回显（含 Cookie/Authorization/API Key）**——调试需求，因此 guest/admin 门禁是不可拆除的兜底（转义与完整回显在测试中作为固定断言） |
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
- 本地构建使用 Docker CLI `buildx`：`docker buildx build --load --build-arg RESTY_J=${RESTY_J:-8} -t authz:latest .`。
  Dockerfile 将 Brotli 源码下载、OpenResty builder 和 runtime 分层；源码层、BuildKit 缓存和并行编译可复用。
  GitHub Actions 通过 `docker/setup-buildx-action` 与 `type=gha,mode=max` 保持同一构建路径。

## 10. 测试

```bash
# Router/ctxvar 真实 OpenResty 回归
OPENRESTY_TEST_IMAGE=authz:latest bash test/test_klib_router_ctxvar.sh

# Authz Gateway/API/OAuth/代理隔离矩阵
OPENRESTY_TEST_IMAGE=authz:latest bash test/test_authz_gateway.sh

# 共享会话 (Redis) 独立回归
OPENRESTY_TEST_IMAGE=authz:latest bash test/test_shared_session.sh

# 基础镜像功能
bash test/run_tests.sh authz:latest
```

测试矩阵覆盖: Router、端口解析、未认证重定向、本地用户、NocoBase mock 登录与角色查询、
OAuth state/PKCE/callback、同名多来源身份隔离、旧身份策略迁移、远端角色记录与本地覆盖、
来源级直授权、上游身份头、远程改密拒绝、绑定 CRUD、CSRF、Casbin 多方法授权和缓存失效、
网关 Cookie 不上游、403 转义与真实状态码、反斜杠开放跳转拒绝、HTTP→HTTPS 308、
Redis ACL 单写多读与故障容错降级（熔断 + SQLite 镜像降级读 + 待写队列重放）、严格 fail-closed
（`AUTHZ_SESSION_SHARED_FALLBACK=false`）、Relay 退役 410。

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
guest 只能走 `/_authz/guest` 探针（以及策略另行放行的代理目标）。

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
- guest 诊断页 `/_authz/guest`（guest.lua 自含认证）：guest 角色的数据库
  Key 或 guest 会话可访问，admin 也可；服务端渲染回显调用者全部请求头（明文完整，
  含凭据类头）/来源 IP/代理转发链，逐字段 HTML 转义 + 禁缓存；`?json=1` 返回同数据
  JSON。该页是天然反射面，转义与完整回显是回归测试固定断言。

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
| 存储配置 | `GET/POST /api/s3-configs`、`PATCH/DELETE /:id`、`PUT /:id/default`、`POST /:id/test` | admin（写 CSRF） |
| 上传流水 | `GET /api/uploads`、`POST /api/uploads/cleanup`、`DELETE /api/uploads/:id` | admin（写 CSRF） |
| 保存区 | `GET /api/store/info|/api/store|/api/store/stat`、`PUT /api/store`、`POST /api/store/upload`、`DELETE /api/store` | admin（写 CSRF，**不带 session_only**：Agent 用 Key 免登录直传直取） |
| 保存区出口 | `GET /_authz/store/<rel>`（只读字节流，独立 location） | admin Key 或 admin 会话；其他角色 403、未登录 302（与写入侧同一道门，理由见 §17.5） |

**注册顺序红线**：字面量路由必须早于同段数的 `/:id` 注册（`klib.router` 的 sort 只把
「多段参数」路由排到尾部，同段数的字面量与 `:param` 仍按注册先后取第一个完整匹配）。
因此 `POST /api/s3-configs` 必须早于 `PATCH/DELETE /api/s3-configs/:id`、
`POST /api/uploads/cleanup` 必须早于 `DELETE /api/uploads/:id`。

guard 语义：`admin=true` 要求 admin；`roles` 白名单；`csrf=true` 校验
`X-CSRF-Token == session.csrf`（机器 Key 请求免）；`session_only` 拒绝 Key；
`self_service` 放行 guest 的只读自身端点。错误统一 `{error:{code,message}}`，
404/500 按 Accept 头回 JSON 或 HTML。

## 17. 多存储配置枢纽与过期回收（设计原则）

### 17.1 单一枢纽：`s3_config_store` 是唯一的「取配置」入口

原本对象存储只有一套进程级凭证（`config.s3`）。多配置上线后，所有取 cfg 的路径
（`router.lua` 的接口、`s3_proxy.lua` 的字节流、清理器按 `cfg_id` 回查）一律收敛到
`s3_config_store`，**禁止再直读 `config.s3`**——那会让 `?cfg=` 与页面新建的配置全部失效。

枢纽输出与既有 `config.s3` 同构的 cfg 表，因此 `s3.lua`/`s3_upload.lua`/`s3_scope.lua`
不需要知道「配置从哪来」。给调用方的 cfg 一律是**新建表**（`db.query` 的返回是跨请求
共享的 mlcache 缓存表，就地 mutate 会污染别的请求）。

### 17.2 表覆盖 env 的优先级，与两条路径的失败语义不对称

| | env 路径 | 表行路径 |
|---|---|---|
| 生效条件 | 表内没有任何「启用 + 字段合法」的行 | 有可用行时优先；按 `is_default` → id 最小 enabled 行 |
| 字段非法 | **启动期 fail-fast**：`error()`，容器起不来（配置写坏不许带病上线） | **运行期可失败**：返回 `(nil, 原因)`，绝不 `error()`。一行写坏只让这一套配置不可用，不拖垮网关 |
| 调用方处理 | — | `missing`/`disabled` → 423，`invalid` → 502 + 原因 |

两条路径共用 `config.build_s3` 做校验与派生，**规则只有一份**。
`cfg_id=NULL` 的流水必须回 env 项，**不能**退回「当前默认项」——对象可能在另一套服务上。

### 17.3 明文密钥入库是本仓库首例，属于有意决策

既有敏感数据都不落明文（`api_keys` 只存 SHA-256 摘要）。`s3_configs.secret_access_key`
必须存明文，因为 SigV4 要拿原文参与签名（`s3.lua` 的 `credentials(cfg)`），摘要无法还原。
换来的三条硬约束：

1. 回显只允许 `has_secret` + `access_key_id_masked`，且 `has_secret` 由 SQL 算出
   （META 列集合根本不选明文列）；含明文的查询只被命名为 `*_full` / `enabled_rows`，
   唯一合法消费者是 `s3_config_store.build_map`；
2. 写侧「空 = 不修改」，校验时用哨兵值满足非空判据且该哨兵不落库、不外传；
3. **备份即含密**：`azops backup` / 复制 `authz.db` 会连带复制密钥，备份介质的
   保密等级由此抬升（`deploy.md` §6、`docs/maintenance-handbook.md` 有告警）。

### 17.4 过期回收：DB 记账 + 单 owner 定时器，而不是桶生命周期

S3 官方 bucket lifecycle 只到**天**粒度且异步执行，满足不了小时级过期；而桶规则与网关
删除同时生效会互相打架。因此分成两层：

- **默认（网关负责）**：写入时在 `upload_records` 记账，`expires_at` 由
  `s3_config_store.align_expiry` **整点对齐**（清理器每小时跑，不对齐就会错过当轮，
  且索引区间扫会退化成一堆毫秒散布的边界行；0 = 永不过期写 NULL）。
- **委托桶（`use_bucket_lifecycle=1`）**：只记账不删，新流水直接落 `state='skipped'`，
  清理器也跳过；人工 `DELETE /api/uploads/:id` 仍照删（明确意志不算越权）。

定时器纪律（`maintenance.lua`）：

- **单 owner**：每个 worker 都调 `start()`，用共享字典原子 `add` 抢锁（TTL = 一轮，
  每轮续期），只有 owner 挂定时器；owner 死亡后**只允许 worker 0** 判活接管
  （共享字典没有 CAS，`delete + add` 不原子，不限定单一候选者会出现双 owner 双清理链）。
- `tick` 无条件自我续期（一次失败不能把定时器弄丢），但只有 `_M.owned` 为真才续锁续期；
  接口层要「立即清理」必须调纯函数 `cleanup(opts)`，**不得**调 `tick`。
- 所有 HTTP 删除在事务**之外**，状态回填攒到最后一次事务提交（避免长事务持写锁跨网络
  请求，也避免逐行 `db.exec` 把 `db_rev` 刷爆打穿 mlcache）。
- 依赖纪律：本模块在 `init_worker` 链上，禁止 require 上层模块（session/api/router 会
  拉起请求期依赖并彼此循环）；路径一律走 `config` 的记忆化访问器，**绝不能 `os.getenv`**
  （nginx exec 后清空 worker 环境块，直读会去开一个凭空的 sqlite 文件，表现成
  「表不存在」这种误导性错误）。

### 17.5 保存区是临时交换区，不是第四个存储层

`AUTHZ_STORE_DIR` 的定位是 Agent 落盘 → 换一条可取回链接 → 默认 24h 后自动删除。
设计取舍：

- 复用 `upload_records` 记账（`kind='local'`、`bucket=''`、`cfg_id=NULL`），
  清理器对 NULL 行退回 `config.store_dir()`，与写入根目录同一判据，不新增表；
- 覆盖写会先把同 key 的旧 active 行闭账，保证「一个 key 只有一条 active 流水」——
  否则最早那条到期会提前把新文件删掉；
- 不额外加 volume：根目录就在 `${DATA_DIR}:/data` 里，宿主路径可预期；
- 字节流出口独立 location（`client_max_body_size 1m` 当写方法栅栏），
  非法/越界/含符号链接一律 404（403 会把「存在但被挡」泄漏给探测者）；
- 需要长期保存的内容一律走对象存储（§17.1 那套），API 层不做承诺。

可写范围（`writable_paths` → `share/<本机 LAN IP>` 默认条目）的语义**照旧**，
只是现在每套配置各自一份、各自探测/派生，互不影响。
