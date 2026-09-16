# OpenResty Authz Gateway 维护手册

> 面向后续维护 Agent。本文记录截至 2026-08-25 已验证的系统设计、开发约束、测试基线与部署方式。
> 发布与测试核心步骤见根目录 `AGENTS.MD`；APP 开发示例与 klib/ctxvar/ngx.re 细节见本文
> 附录 A，Agent 控制面接入与实现细节见附录 B；涉及身份源时再读 `docs/sso-jwt-auth.md`。

## 1. 系统定位与入口

本仓库同时提供 OpenResty 基础镜像和轻量级 Authz Gateway。Gateway 负责：

- 将数字前缀域名或显式域名绑定解析到本机端口；
- 本地账户、NocoBase 密码认证及 OAuth/OIDC 关联登录；
- SQLite 服务端会话、来源感知身份和 mini-Casbin 授权；
- Vue 3 + Quasar UMD 静态管理界面。

稳定入口约定：

| 路径 | 职责 |
|---|---|
| `/_authz/apps/` | 唯一 Admin UI 入口（会话保护的静态管理端）；不要恢复 `/admin/` 或 `/_radmin_/` |
| `/_authz/login` | 密码登录页和提交端点 |
| `/_authz/oauth/start` | OAuth 登录发起 |
| `/_authz/oauth/callback` | 所有 OAuth Provider 共用回调 |
| `/_authz/api/*` | 管理端 JSON API |
| 其他路径 | 认证、授权后代理到本机应用 |

公网实例曾使用 `https://6080-241.ws.example.com:99/_authz/apps/` 映射本机 6080。部署地址可能变化，
维护时以反向代理配置和 `docker inspect` 为准，不把该域名写入通用业务逻辑。

## 2. 请求架构

```text
Browser
  ├─ /_authz/apps/*  -> 会话保护后的静态 Quasar UMD 文件（管理端）
  ├─ /_authz/*       -> resty.authz.router (klib.router("/_authz"))
  │                      ├─ /login、/oauth/* -> ui.lua 登录页与 OAuth
  │                      └─ /api/* -> guard -> api/service -> api/services
  └─ /*              -> resty.authz.access
                         -> 解析端口
                         -> 读取会话
                         -> mini-Casbin enforce
                         -> proxy_pass <target_ip>:<port>
```

两个网关入口使用相同控制面：

- HTTP 入口默认 6080，但默认模式（`AUTHZ_HTTP_MODE=redirect`）会把公网 HTTP 请求 308 到 HTTPS；`disabled` 只绑定回环，`serve` 仅供受控测试；显式绑定按记录代理到 `http://` 或 `https://<target_ip>:<port>`；
- HTTPS 入口默认 6443，在网关终止客户端 TLS 后，仍按绑定记录选择 HTTP/HTTPS 上游；HTTPS 上游默认校验证书，可按绑定关闭校验；
- 目标优先取启用的精确域名绑定，否则按请求首级标签查裸前缀索引（`<前缀>` 或 `<前缀>-<节点>` 命中即接管，见下），遗留物化域名再按 `前缀|节点` 精确回退，最后解析 `<port>-任意域名` 到 `127.0.0.1:<port>`；显式绑定还可保存绑定级 Host、Forwarded、Origin 和模拟本机访问配置；未绑定域名的动态端口入口默认启用模拟本机访问；
- 可代理端口下限强制不小于 2000；目标为网关自身端口时返回 508；
- 上游收到 `X-Authz-User`、`X-Authz-Source`、`X-Authz-Identity`；显式绑定默认 `Host` 与 `X-Forwarded-Host` 保留外部请求主机名，`<port>-任意域名` 动态入口默认模拟本机访问（Host/`X-Forwarded-Host` 为 `127.0.0.1:<port>`，`X-Real-IP`/`X-Forwarded-For` 为 `127.0.0.1`）。若最外层代理替换了端口，只在 Origin 与请求 Host 的主机名相同时恢复 Origin 中的公网端口。显式绑定可安全覆盖 `Host`、`X-Forwarded-Host/Proto/Port` 和 `Origin`，但不能改变真实 TCP peer。
- 只要请求带有 `Upgrade: websocket`，所有已解析的动态代理目标都会转发升级头，并关闭缓冲、延长读写超时。`bindings.websocket` 保留为历史兼容字段，不再阻断升级请求。

Admin 菜单应用列表不依赖 `bindings` 表：`/_authz/api/applications` 读取 `/proc/net/tcp` 和
`/proc/net/tcp6` 的监听端口，在 `AUTHZ_PORT_MIN/MAX` 范围内排除网关端口，再向 `127.0.0.1` 发送
短超时 `HEAD /`；只有返回 HTTP 状态行的端口才会列出。结果按 worker 缓存，默认 30 秒；容器需要使用
host 网络或其他方式让目标服务位于网关容器的 `127.0.0.1` 网络命名空间内。

多入口域名（一套系统适配多个 / 多级域名）：绑定只保存最后一级裸前缀（`code`）。入口域名在运行时按
当前请求 Host 拼出 `<前缀>-<节点>.<泛域>`：节点取请求首级标签最后一个 `-` 之后的片段（无 `-` 时整段），
泛域随浏览器进入的入口（`ai-t.wtvdev.com`、`ws.gatepro.cn`…）。`lualib/resty/authz/domain.lua` 的
`link()` 负责菜单/编辑器展示拼接（`code-241.ws.gatepro.cn`），`gateway/cache.lua` 建裸前缀索引、
`gateway/resolver.lua` 用请求首级标签匹配 `<前缀>` 与 `<前缀>-<节点>` 两种形态（纯数字前缀不参与带节点
后缀的回退，留给 `<端口>-域名` 动态入口）。管理界面的域名输入框因此只接受前缀；API 仍接受完整精确域名
（原样存库、只精确匹配）供非泛域入口使用。历史遗留的物化 `<前缀>-<节点>.<泛域>` 完整域名（未迁移的库）
保持原样精确匹配 + `前缀|节点` 跨 zone 回退；在管理界面把它改存为裸前缀即完成迁移（编辑表单提交裸前缀
即可，PATCH 后行为与新建一致）。

左侧菜单由存储的菜单树渲染（迁移 v7 起）：`menu_entries` 表以 `kind` 区分分组(`group`)与条目(`item`)，
条目通过 `parent_id` 挂到分组下；`builtin` 标记内置节点：内置页面条目
(`users/authorization/menuEditor/files/nginxConf`)、内置分组（迁移 v15 起 `builtin='system'`
的“系统应用”，以及 `domains`/`local` 两个动态分组）。凡 `builtin` 非空的分组与条目一律不可删除
（API `409`，编辑器不显示删除按钮）。
`/_authz/api/menu-tree` 输出两级树供左侧菜单渲染（只含启用项；编辑器通过 `/_authz/api/menu-entries` 读取全量
含停用项）。`menu-editor.html` 提供树状编辑：新增/编辑分组与条目、上移下移、显隐开关、图标选择与分组归属
调整，分组卡片两列平铺（窄屏自动回落单列）以节省纵向空间。非空分组不可删除（先移走或删除条目），
内置分组/条目不可删除。编辑器只呈现系统应用与域名服务两个分组：`builtin='local'`（本地服务）完全移出
编辑器——其条目随端口探测动态变化，不支持编辑。迁移 v7 把旧扁平布局种子化为「系统应用」分组，v13 拆出三个分组：
系统应用、`builtin='domains'`（域名服务）与 `builtin='local'`（本地服务）。后两者的条目由 `/_authz/api/applications`
在渲染时注入（已绑定域名的应用进域名服务，其余端口探测结果进本地服务），本身不落 `menu_entries`。

这类注入条目通过 `menu_overrides` 表（迁移 v14）按稳定服务键 `binding:<id>` / `port:<port>` 保存菜单定制
（label / icon / sort_order / enabled）。域名条目改名会回写 `bindings.menu_name`（与代理层共用同一事实来源），
其余字段与端口条目全部存在覆盖表里；隐藏只把条目移出左侧菜单，不改变绑定或探测本身。编辑器经
`GET /_authz/api/menu-services` 拿到含隐藏项的可编辑视图，`PATCH` 改名/图标/显隐、`PUT .../reorder` 排序、
`DELETE` 恢复默认（均为 admin + CSRF）；删除绑定会联动清理其覆盖行。键只接受 `binding:<数字>` / `port:<数字>`
（浏览器 `%3A` 编码会被安全解码后严格校验）。

Agent/API 控制面接入：原 `AUTHZ_AGENT_API_KEY`（自动 seed `agent-default`）已移除；本机自动化改用实例级 `AUTHZ_API_KEY`（`AUTHZ_API_KEY_ALLOWED_IPS` 默认仅回环）或管理界面创建 `loopback_only=1` 的数据库 Key。
Agent 侧硬性规则见 `AGENTS.MD`；认证方式全量说明与实现侧要求见本文附录 B；
接口明细见 `docs/core-api.md` 2.3 节。

实例级预置 API Key（免登录，`docs/core-api.md` 2.4 节）：`AUTHZ_API_KEY` 设定后用 `x-api-key`
请求头免登录访问控制面 API、管理页面与代理入口，Agent 不必手动登录取 Cookie。角色由
`AUTHZ_API_KEY_ROLE`（默认 admin）决定并走 Casbin；来源必须命中 `AUTHZ_API_KEY_ALLOWED_IPS`
（逗号分隔 IP/CIDR，默认仅 `127.0.0.1`，匹配 TCP remote_addr，XFF 不参与）。
Key 不入库（不受管理界面禁用影响）、常量时间比较、网关剥离不转发上游、呈现即不回退 Cookie；
配置非法（过短/含空白/角色非法/白名单条目非法）启动即报错；旧的
`AUTHZ_API_KEY_LOOPBACK` 已废弃，出现即报错（用 `127.0.0.0/8` 表达旧语义）。
它是实例级万能钥匙：默认白名单锁死 127.0.0.1；跨机接入逐条列 IP 或收窄角色，
泄漏等同管理员凭据泄漏。

## 3. 代码职责

| 路径 | 责任 |
|---|---|
| `conf/nginx.conf.template` | 全局配置、HTTP/HTTPS listener 与 TLS；两个 server 都 include 运行时生成的 `server.conf` |
| `conf/server.conf.template` | 生成 HTTP/HTTPS 共用的控制面 location、Admin 静态资源和动态代理配置 |
| `lualib/resty/authz/init.lua` | 稳定生命周期入口，只装配配置、数据库初始化和 access 委托 |
| `lualib/resty/authz/config.lua`、`provider_config.lua` | 通用环境配置、Provider/OAuth 装配 |
| `lualib/resty/authz/gateway/` | access 链、身份解析、授权缓存和代理请求变量构造 |
| `lualib/resty/authz/router.lua` | `/_authz` 统一 router：登录/OAuth 页面 + `/api/*` JSON API |
| `lualib/resty/authz/ui.lua` | 登录页与 OAuth 跳转处理 |
| `lualib/resty/authz/api/guard.lua` | 会话、admin、CSRF guard 和统一错误结构 |
| `lualib/resty/authz/api/service.lua` | 保持既有方法名的薄门面，不承载领域实现 |
| `lualib/resty/authz/api/services/` | 用户、远程身份、绑定、策略、API Key 和只读模型服务 |
| `lualib/resty/authz/api/validation.lua` | 管理 API 的角色、方法、策略和绑定输入校验 |
| `lualib/resty/authz/repository/` | 运行时 SQL 的唯一归属，按领域提供数据访问方法 |
| `lualib/resty/authz/db.lua` | 数据库生命周期、查询门面和事务边界 |
| `lualib/resty/authz/db/` | SQLite 驱动、schema、版本化迁移、seed 和查询缓存 |
| `lualib/resty/mlcache.lua` | vendored lua-resty-mlcache 分层缓存实现 |
| `lualib/resty/authz/session.lua` | 服务端会话与 Cookie |
| `lualib/resty/authz/identity.lua` | 来源感知身份键 |
| `lualib/resty/authz/remote.lua` | 远程身份单向记录、本地启用状态和角色覆盖 |
| `lualib/resty/authz/nocobase.lua` | NocoBase 用户名密码认证 |
| `lualib/resty/authz/oauth.lua` | OAuth Code + PKCE、token/userinfo、身份记录 |
| `lualib/resty/authz/discovery.lua` | 读取本机监听端口并用短超时 HTTP HEAD 发现本地服务 |
| `lualib/resty/authz/api/services/menu_services.lua` | 注入条目（binding:/port: 键）的菜单覆盖读写：改名/图标/排序/显隐/恢复默认 |
| `lualib/resty/authz/repository/menu_overrides.lua` | `menu_overrides` 表读写（须在事务内调用，读绕过 mlcache） |
| `admin/` | 无构建步骤的 Vue 3 + Quasar UMD Admin UI |
| `lualib/klib/` | 项目代码注册式 Router 和请求上下文框架 |

`lualib` 在镜像构建时整体复制到 `/usr/local/openresty/site/lualib`，开发部署也必须整体挂载。
只挂载 `lualib/resty/authz` 会漏掉 `klib.router`、模板等依赖，导致镜像与挂载行为不一致。

数据库查询使用 `resty.mlcache`：worker 内 L1 LRU、共享字典 L2 和 SQLite 回调 L3。缓存默认
使用 `authz_db_cache` 共享字典，TTL 由 `AUTHZ_DB_CACHE_TTL` 控制，L1 容量由
`AUTHZ_DB_CACHE_LRU_SIZE` 控制。事务外的成功写入立即递增 `authz_cache:db_rev`；事务内只在提交成功后
递增一次。授权相关服务统一使用 `db.authz_transaction()`，提交后同时发布授权 revision，回滚不发布
任何 revision。查询键包含数据库 revision，因此所有 worker 会切换到新查询键。直接改 SQLite 不会
触发 revision；生产变更必须走管理 API 或重启网关。

数据库启动时按 `db/migrations.lua` 的升序版本执行迁移，并把版本、名称和时间写入
`schema_migrations`。新增 schema 变化只能追加更高版本，不能改写已经发布的迁移。多表或多步骤写操作
必须在 service 层建立一个事务边界；repository 不自行提交，也不手工操作缓存 revision。

浏览器会话按每次请求的 Host 选择规范 Cookie 父域，而不是使用进程级固定父域：去掉入口主机的
第一个标签，例如 `6080-241.ws.example.com` 得到 `.ws.example.com`，
`code-m.w.wtvdev.com` 得到 `.w.wtvdev.com`。`AUTHZ_COOKIE_DOMAIN` 可配置一个或用逗号分隔的多个
父域提示；仅当提示匹配当前 Host 且不比请求推导结果更宽时使用。`AUTHZ_HOST_URL` 的推导结果只作为
无法从请求 Host 判断时的回退。因此同一实例可同时承载多套基础域名。

登录、OAuth 和登出响应会清除 host-only、当前完整主机、更深层旧域以及比规范域更宽一级的旧
Cookie；请求同时携带多个 `authz_session` 时选择仍有效且到期时间最新的会话，并立即重新签发到
当前请求对应的规范父域。不能再恢复“只读取第一条同名 Cookie”的行为。

## 4. 数据和身份模型

SQLite 默认位于 `/data/authz/authz.db`，`/data` 必须持久化。

| 表 | 关键约束 |
|---|---|
| `users` | 本地用户名唯一；角色、启用状态、密码摘要及创建/最近登录/修改时间 |
| `remote_users` | 主键 `(provider, subject)`；唯一 `(provider, username)`；创建/最近登录/修改时间 |
| `sessions` | token、username、source、csrf、expires_at |
| `policies` | `ptype/v0/v1/v2` 唯一；存 p/g 规则 |
| `bindings` | domain 唯一；target_ip/port、enabled、websocket、note、menu_name；upstream/forwarded/origin 代理字段；simulate_local/local_ip；request_rewrite（请求改写规范化 JSON，迁移 17 由 header_overrides 升级并入）；response_rewrite（响应改写规范化 JSON，空串表示未配置） |

`remote_users.synced_at` 是保留的内部存储列名；管理 API 只输出语义明确的 `recorded_at`，避免把
单向身份记录误解为双向同步协议。

本地和远程用户统一使用 Unix 秒级时间戳：`created_at` 保持首次创建时间，`last_login_at` 在成功
认证后更新，`updated_at` 在角色、启用状态、密码或远程身份记录变化时更新。管理端显示到秒。

身份不能只按用户名判断。规范主体是：

```text
user:<source>:<username>
user:local:kate
user:nocobase:kate
user:dingtalk:kate
```

同名不同来源必须保留独立角色、启用状态、会话和用户直授权。人类角色目录固定为
`admin`、`staff`、`user`、`guest`（旧 `viewer` 已退役，由迁移 18 就地改写为 `guest`）；
服务主体可绑定其中任一角色，另有不可分配给用户的 `api` 角色：

- `admin` 可访问用户、应用绑定和 Casbin 管理 API；
- `api-key:<id>` 继承 Key 记录中的单一角色，`admin` Key 可调用全部管理 API；
- `api` 不能修改/删除绑定，不能管理用户、角色、策略、API Key 或核心认证；
- 非 admin 只能读取自身 session/profile；
- 默认仅 `role:admin` 拥有 `/*`，其他角色默认拒绝；
- guest 就是匿名主体：无凭证的代理请求以 `role:guest` 参与授权（默认拒绝，显式放行即对
  匿名开放，上游收到 X-Authz-User=guest / Source=anonymous）；`/_authz/guest` 诊断页对
  匿名访客直接开放；guest 看不到任何控制面数据；
- 远程用户不能在本机修改密码。

本地用户在管理端“修改我的密码”时必须输入两次新密码，页面会在提交前检查一致性，密码修改成功后该用户的所有本地 session（包括当前 session）都会失效，必须重新登录。API
`PUT /_authz/api/me/password` 也会校验 `newpw_confirm`（或
`new_password_confirm`）。管理员忘记内置 `admin` 密码时，可执行：

```bash
docker exec <container_name> admin_password_reset
```

命令使用容器当前的 `AUTHZ_ADMIN_PASSWORD` 环境变量生成与应用一致的密码摘要，清除 admin
本地会话并 reload OpenResty 使 worker 缓存立即失效。它不会读取宿主机 `.env`；修改 `.env`
后必须先 recreate 容器。命令不接受密码参数，也不会在输出中显示密码。

所有用户只有启用和未启用两种认证状态。后续登录记录不得重新启用已被本机管理员禁用的身份。
管理员删除远程快照时，同时删除其会话和直接策略；下次远程认证会以新身份快照重新创建并默认启用。

远程角色单向记录规则：

1. 成功认证记录最近的 `remote_roles`；
2. 无本地覆盖时写入本机有效 `roles`；
3. `roles_overridden=1` 时保留本地有效角色；
4. 管理员可执行“恢复记录角色”清除覆盖；
5. 任何变更必须通过授权事务提交，由数据库门面自动发布 `authz_cache` revision。

## 5. API 与授权规则

API Router 根固定为 `/_authz`，管理 API 注册为 `/api/...`（如 `/api/session`、`/api/users`）。不要依赖 Nginx location 自动剥离 URI。

所有 API table 响应使用：

```text
Content-Type: application/json; charset=UTF-8
成功: {"data": ...}
失败: {"error":{"code":"...","message":"..."}}
```

约定状态码：无会话 401、无权限或 CSRF 失败 403、不存在 404、请求格式错误 400、业务校验
422、冲突 409。所有修改请求使用 JSON body，并从 session API 取得 CSRF，通过
`X-CSRF-Token` 发送；API Key 请求不使用 CSRF，但仍必须通过相同的角色 guard。稳定接口清单、请求体
与 Agent 调用契约见 [核心 API](core-api.md)。

API Key 安全约束：

- Header 为 `x-role-key: ak_<64 hex>`（或 `x-api-key`），显式无效 Key 不得回退浏览器 Cookie；
- 数据库 `api_keys` 只保存 SHA-256 摘要，明文只在创建响应中出现一次；
- Key 可使用固定目录中的 `admin/staff/user/guest/api` 单一角色，角色修改必须立即失效旧缓存；
- 明文只在创建/轮换响应中出现一次，另有非机密的 `token_prefix` 指纹供列表识别；
  忘记明文时用 `POST /api-keys/:id/rotate` 换新值（旧值当场失效），无法找回旧值；
- `admin` Key 可管理全部控制面；`api` Key 只额外允许新建 binding；其他角色与同角色用户边界一致；
- 代理前必须通过 `proxy_set_header X-Authz-Key ""` 清除凭据；
- `target_ip` 允许可信 admin/api 主体连接其他机器，应将其视为内网访问能力；Casbin 对象仍按
  `/<port><path>` 授权，同端口的不同目标 IP 共享策略；
- 绑定级 Host/Forwarded/Origin 字段必须经过 authority/origin 白名单校验并拒绝 CR/LF；模拟本机访问只重写
  `Host`、`Origin`、`X-Real-IP`、`X-Forwarded-For` 等 HTTP 头，不应被描述成 TCP 来源伪造；
  request_rewrite 覆盖发往上游的请求头，格式、控制字符、长度和白名单（仅禁分帧/hop-by-hop 与
  网关凭据头 X-Authz-Key/X-API-Key/X-Role-Key，其余 X-Authz-*/Proxy-* 前缀）在 validation 层校验，
  cache 层防御性二次过滤；proxy 层普通头用 ngx.req.set_header 注入，网关托管头（Host/Cookie/
  Origin/Forwarded/X-Forwarded-*/X-Real-IP/X-Authz-User|Source|Identity）写入 proxy_set_header 引用的
  $authz_* 变量，使改写值成为上游看到的最终值（改写优先于 proxy_set_header，删除=变量置空不发送）；
- 绑定级响应改写 `response_rewrite`（APISIX response-rewrite 子集：status/headers/remove_headers/
  body/body_base64/content_type/rewrites）：保存时校验字段白名单、头名与值、PCRE 编译、条数与长度上限；
  运行期在 `gateway/rewrite.lua` 再拦一道（Set-Cookie、分帧与 hop-by-hop、X-Authz-*/X-Forwarded-*/Proxy-*、
  XFO/CSP/HSTS/NOSNIFF 一律不可改写或删除）；正文改写只在“上游 200 + GET + 非压缩 + 非 Range +
  非 WebSocket +（过滤模式要求文本 Content-Type）+ 总量 ≤1MB”时缓冲，超限连同已缓冲内容原样透传，
  跳过原因写在响应头 `X-Authz-Rewrite: skipped=<reason>`；
- Key 启用、禁用、删除和策略变更都必须 bump cache revision，并有跨 worker HTTP 回归。

策略规则：

- `p`: `v0` 为 `user:<source>:<username>` 或 `role:<role>`；
- `v1` 为 `/<port><path-pattern>`，全局为 `/*`；
- Admin 新增和编辑表单只管理 `p` 访问策略，不提供 `g` 角色分配切换；历史 `g` 规则仍可列出和删除。
  表单按 binding ID 选择目标，将菜单名、域名和目标 IP:端口同时展示；路径默认 `/*`，
  绑定对象只能从下拉列表选择，选中后仅显示名称，详情在下拉项中分行展示；效果直接使用允许/拒绝 Radio；
  编辑时回填类型、主体、绑定、路径、HTTP 方法和效果，提交时组合为 `/<port><path-pattern>`；服务端的
  `POST` 与 `PATCH` 必须共享校验，确保 binding ID 存在且端口一致，失败时不得覆盖原策略；
- 策略列表通过 API 的 `binding_matches` 反查绑定详情；无匹配绑定显示为“未绑定”，同端口多个绑定显示
  为“共享策略”。Casbin 仍按端口 + 路径授权，不能把共享端口策略误显示为单一绑定专属策略；
- `v2` 支持标准 HTTP 方法多选，数据库中以逗号保存；`*` 表示全部；
- deny 通过 `v2` 的 `|deny` 后缀编码，deny 优先；
- `g`: 将来源感知用户主体分配给固定角色。

管理端可选 HTTP 方法目录包括 `GET/HEAD/POST/PUT/DELETE/OPTIONS/PATCH/CONNECT/TRACE` 和 `*`。
注意 `klib.router` 自身只注册 GET、HEAD、POST、PUT、DELETE、OPTIONS、PATCH；CONNECT/TRACE 是代理
授权策略动作，不用于管理 API 路由注册。

## 6. OAuth 与 NocoBase

通用 OAuth 流程使用 Authorization Code、一次性 state 和 PKCE S256。access token 只在回调请求
期间使用，不写入 SQLite、日志或 Cookie。公网 token/userinfo 传输失败自动重试一次，默认
connect/send/read timeout 为 10/10/15 秒；HTTP 非 2xx 不重试。

NocoBase 有两种登录方式：

- 密码认证：`POST /api/auth:signIn`，随后 `GET /api/auth:check` 获取用户名与角色；
- OAuth：与密码认证共用 `nocobase` 来源和本地角色覆盖。

NocoBase OAuth 的 `/api/idpOAuth/me` 只提供标准身份 claim，不使用 Basic 登录专用的
`/api/auth:check` 查询角色；首次角色来自 `AUTHZ_NOCO_OAUTH_DEFAULT_ROLES`，后续只由本机管理。

生产 NocoBase 为 2.2 时必须遵守：

- issuer 为 `<AUTHZ_NOCO_URL>/api`；
- authorize/token/userinfo 为 `/api/idpOAuth/authorize|token|me`；
- scope 为 `openid profile email api`；
- 回调必须精确校验 RFC 9207 `iss`；
- token 使用 `client_secret_basic`，并同时携带 PKCE verifier；
- 公网 Client 通过 `oidcStates:create` collection API 一次性注册，不安装 NocoBase 插件；
- NocoBase Client 注册 API Key 不注入运行容器，配置以 `docs/thirdparty-oauth-login.md` 为准；它与
  Authz Gateway 的 `x-api-key` 应用凭据不是同一种密钥。

同一 Client ID、Secret 和回调 URI 必须同时注入 NocoBase 与网关。环境变量改变必须重建容器，
普通 `docker restart` 不会改变容器环境。详细配置见 `docs/sso-jwt-auth.md`。

其他 Provider：

- DingTalk 使用 `authCode` 回调和专用 token/userinfo 请求头；
- Google 要求 verified email；
- 微信使用网站应用 `snsapi_login`，不是公众号或小程序流程；
- 未完整配置的 Provider 必须继续显示"待配置"，但不能发起残缺授权流程。

### 6.2 共享会话模式（Redis，单写多读）

多实例部署时，用户从域名 A 登录后切换到域名 B 会因 Cookie 域不同而丢失会话。
共享会话模式把登录会话写入公共 Redis，使各实例认可同一份登录身份。

共享边界（严格遵守）：

- 只允许**一个认证主实例**使用 `AUTHZ_SESSION_REDIS_MODE=read-write`；
  其余所有实例必须使用 `read-only`（这是默认值），登录在只读实例上直接返回 503
  并提示去主实例登录；只读实例的登录页不渲染登录表单，直接显示"请在认证主实例登录"提示页；
- Redis 侧必须用 ACL 强化同一约束：writer 用户授予会话前缀下
  `GET/SETEX/DEL/SCAN/EXISTS/PING`，reader 用户只授予 `GET/PING`；
- Redis 只保存 `username`、`source` 与纯会话机制字段（`csrf`、`expires_at`）；
  **角色、Casbin 策略、绑定一律不共享**，仍由各实例本地 SQLite 管理；
- 会话命中后，实例仍用本地 `users` / `remote_users` 校验该身份存在且启用；
  本地没有或已禁用即清除登录信息（主实例删 Redis 键，只读实例仅清除本机状态）；
- Redis 中确实没有该会话（登出/过期）时，实例立即清除登录信息；
  **Redis 不可达时同样失败关闭**（清除 Cookie、返回未登录），不再回退本地 SQLite，
  避免已撤销的 bearer token 复活；
- 登录、全局登出、密码重置、用户禁用等写/撤销操作必须进入 `read-write` 主实例；
  只有主实例会执行 `SETEX/DEL/SCAN`，只读实例绝不尝试写共享键；
- 每条共享记录都是 `<JSON>.<HMAC-SHA256 hex>` 签名信封（密钥 `AUTHZ_SESSION_SIGNING_KEY`，
  HMAC 覆盖 `token + JSON`）。reader 对未签名、伪造、篡改或跨键搬运的记录一律按
  未登录处理。因此即使共享 Redis 是禁 ACL 的托管实例、其他服务也能写入，
  也无法伪造会话。签名密钥泄漏等同于会话密钥泄漏，须与其他 secret 同等保管；
- 网络隔离和传输保护落实前保持关闭（`AUTHZ_SESSION_SHARED=false`）；
  Redis 有 ACL 时仍应配置 reader 只读账号——HMAC 是叠加防线，不是 ACL 的替代。

配置（各实例 `.env`）：

```bash
AUTHZ_SESSION_SHARED=true
AUTHZ_SESSION_REDIS_URL=redis://<host>[:<port>]
AUTHZ_SESSION_REDIS_MODE=read-only            # 仅认证主实例改为 read-write
AUTHZ_SESSION_REDIS_USERNAME=authz-reader     # writer/reader 使用不同 ACL 用户
AUTHZ_SESSION_REDIS_PASSWORD=<password>
AUTHZ_SESSION_REDIS_DB=0
AUTHZ_SESSION_REDIS_PREFIX=authz              # 多套集群共用时用于隔离
AUTHZ_SESSION_SIGNING_KEY=<openssl rand -hex 32>  # >=32 字符，所有共享实例必须一致；
                                                  # 缺失或过短会在启动时直接报错
```

Redis 键格式：`<prefix>:session:<64位hex token>`，值为 JSON，TTL 与会话有效期
（`AUTHZ_SESSION_TTL`）一致。`docker-compose.yml` 已透传上述变量；修改环境变量
必须重建容器。

> 键值实际存储为签名信封 `<JSON>.<64位hex HMAC>`，人工用 `redis-cli GET` 排查时
> 看到的即为此格式，属正常现象。

真实回归覆盖：双实例 + 独立带 ACL 的 Redis 容器，验证 writer 写入、reader 只读
（登录被拒且 ACL 层面写入被 `NOPERM` 拒绝）、载荷不含角色、Redis 键删除后清除
登录、本地无身份时清除登录、密码重置跨实例撤销以及 Redis 故障失败关闭，位于
`test/test_shared_session.sh`（共享会话独立回归）。

## 7. Admin UI 规则

技术栈固定为 Vue 3 Browser Global + Quasar UMD，无用户明确要求时不加入 Node、Vite 或 Vue Router。
生产页面只加载 `admin/vendor/quasar-umd.js` 和 `admin/vendor/quasar-umd.css` 两个框架 bundle；其中已包含
Vue、Quasar、zh-CN/en-US、MDI v7、Roboto 和图标字体。

页面结构：

```text
index.html + app.js + app.css
  ├─ SSI include: menu.html（同一 Vue 壳内的菜单片段）
  └─ 右侧 iframe:
       ├─ users.html
       └─ authorization.html
共享: api.js、i18n.js、app-page.css、vendor/*
```

必须保持以下 UI 契约：

- 暗色 Pollux/Linear 风格，低对比边框、柔和紫色强调、10-16px 圆角；
- 保留大型统计卡片，但压缩页首空白，不恢复冗余大标题；
- 无顶部菜单栏；仅右侧应用使用无边框 iframe，左侧菜单由 SSI 直接组装；
- 左栏展开 220px、收起 40px；收起时图标仍可见、左对齐且状态切换图标正确；
- Logout 和语言切换在左下角；窄栏下图标/文字可换行；
- 字号使用适配规则，正文不可因桌面布局而缩小到难以阅读；
- `app.js` 只允许白名单右侧页面，所有 `postMessage` 校验同源和发送窗口；
- 页面 API 统一放 `api.js`；右侧应用页面的 Vue 初始化与页面业务 JS 内联在 HTML 底部；
- 危险操作必须确认，网络请求必须展示 Loading 和可见错误。

i18n 默认完整支持 `zh-CN` 和 `en-US`：

- 词典集中在 `admin/i18n.js`；
- 偏好键为 `localStorage.admin_locale`；
- 通过同源 `postMessage` 和 storage event 同步壳及右侧应用 iframe；菜单属于同一壳文档；
- 标题、列名、按钮、Tooltip、Dialog、Notify、校验和空状态不能残留单语言硬编码。

## 8. klib 框架规则

详细开发规范见本文附录 A，以下是不可破坏的框架契约：

- 每个 APP 一个主 Router，模块级创建；请求期间不注册或 merge；
- Router `root_entry` 必须匹配原始 URI 前缀；
- 所有 `register()` 第三个错误值必须检查；
- 所有 `merge()` 返回值必须检查；成功为 `true, route_count`，失败为 `nil, error`；
- merge 在注册前整体预检，失败不能产生半注册状态；
- table 响应为 JSON Content-Type；
- 默认错误处理不回显请求头，生产 API 仍需安装通用 404/500 handler，避免输出内部堆栈；
- handler 签名为 `function(params, env, req)`；API body 优先使用 `req.get_body(env)`；
- `req.get_body()` 只接受 JSON object 或 form；不支持的 Content-Type 必须失败；
- 子 Router merge 仍不会复制 template，模板路由保持在主 Router 或显式渲染；
- 暂不使用损坏的 `add_access()`，也不无 seed 调用 timer `ctxvar`。

## 9. 测试策略

涉及 `ngx`、请求阶段、Router、session、Cookie、OAuth 或代理行为，必须在真实 OpenResty 容器中测试，
不能只运行系统 Lua。

推荐顺序：

```bash
git diff --check

OPENRESTY_TEST_IMAGE=authz:latest \
  bash test/test_klib_router_ctxvar.sh

OPENRESTY_TEST_IMAGE=authz:latest \
  bash test/test_authz_gateway.sh

bash test/test_shared_session.sh

bash test/run_tests.sh authz:latest
```

三组测试职责：

| 脚本 | 覆盖 |
|---|---|
| `test/test_klib_router_ctxvar.sh` | Router/ctxvar、JSON、错误脱敏、merge 返回与原子性 |
| `test/test_authz_gateway.sh` | 登录、API、CSRF、身份隔离、远端记录、OAuth、动态代理、HTTPS Cookie 与绑定级响应改写 |
| `test/test_shared_session.sh` | 共享会话 (Redis 单写多读、ACL、故障关闭) |
| `test/run_tests.sh` | 镜像基础库、WebDAV、FancyIndex、JWT/旧 SSO 兼容 |

截至本文更新，最近基线为 Router 99、Authz 998（含实例级 Key、guest 套件与
TEST_ONLY/KEEP_GOING 分诊）、共享会话 29、基础镜像 17。数量不是固定契约；
任何行为变更必须增加或调整能验证真实 HTTP 结果的断言。

三个脚本都会占用随机端口并起常驻 mock，**必须串行执行**；并发跑会互相抢端口并污染日志。

功能验证之外，`241.t`（10.252.25.241，`/data/app/authz-test`，端口 6080/6443）是长期在跑的测试实例，
作为共享会话 reader 与生产 writer（本机 235）配对。它是共享会话、跨实例撤销和绑定级响应改写的
回归现场，同步与重建命令、分段分诊（TEST_ONLY/KEEP_GOING）与 playwright 免认证页面测试
见 `AGENTS.MD`「测试步骤」。241.t 是共享会话 reader，按设计不允许本地登录（503）：控制面
写操作用 x-api-key；需要会话的验证先到本机 writer 登录取 authz_session 再带 Cookie 访问。

OAuth 测试使用 `test/mock_nocobase.py`，不得连接生产账号或把真实 token 写入测试输出。测试至少覆盖
PKCE、resource、回调 issuer、state 一次性、角色映射、同名来源隔离和禁用状态保持。

## 10. 部署与挂载

推荐 Compose；要代理宿主机 `127.0.0.1:<port>` 时使用 host network。必须持久化/挂载：

```text
宿主机 data/   -> /data
宿主机 admin/  -> /usr/local/openresty/nginx/html/admin:ro
宿主机 lualib/ -> /usr/local/openresty/site/lualib:ro
宿主机 conf/   -> /etc/openresty/templates:ro
```

`conf/` 目录中有三个外置 include 文件：`http_inc.conf`（include 到 http{} 末尾）、
`server_inc.conf`（include 到网关 server{} 最末尾，同路径 location 会覆盖内置行为）、
`stream_inc.conf`（include 到顶层 stream{} 块）。入口脚本启动时检查：存在（哪怕为空）
即采用用户版本并复制进容器 Nginx 配置目录；缺失则自动生成带注释的默认内容。
镜像内置同名的三个默认文件，纯镜像部署时也可用单文件卷覆盖。修改后先执行
`docker exec <容器> openresty -t` 验证语法，再重启容器生效；语法错误会导致 Nginx 无法启动。
默认 `server_inc.conf` 提供 `favicon.ico`（204）与 `noc.gif`（200，SLB 健康检查）两个示例 location。

管理壳的“Nginx配置(危险)”应用（`nginx_conf.html`，仅 admin）可在线编辑这三个文件：
保存前在临时前缀副本上跑 `openresty -t`（不触碰线上文件），失败时回显 nginx 原始错误；
校验通过并二次确认后才写入（保留一个 `.bak`），模板目录可写时同步镜像以便重启后保留；
“nginx 重启”按钮执行 `openresty -s reload`。对应 API 为 `/_authz/api/nginx-conf*`，
实现在 `lualib/resty/authz/nginxconf.lua`（admin + CSRF + 文件名白名单）。
这使 Lua、前端和 Nginx 模板修改无需重建镜像。镜像入口脚本每次启动都从运行时模板目录生成
`/usr/local/openresty/nginx/conf/nginx.conf` 与 `server.conf`；未挂载模板目录时回退到镜像内置模板。部署操作区分：

- 只改挂载代码/静态资源：`openresty -t` 后重启或 reload；
- 修改 `conf/nginx.conf.template` 或 `conf/server.conf.template`：重启容器，由 entrypoint 同时重新渲染两个最终配置；不需要重建镜像；
- 只修改模板且环境变量未变化时可直接 `docker restart`；`.env` 变化仍必须重新创建容器；
- 改环境变量、网络、挂载、镜像：重建容器；
- 改数据库 schema：先备份 `/data/authz/authz.db`，追加有明确版本号的迁移，不得改写已发布版本；必须重启或重建容器，让 `init_by_lua` 在 worker 接收流量前完成迁移；
- 改 vendor：重新生成 manifest 和哈希，不在页面恢复 CDN 依赖。

> **外置模板目录漂移**：部署若把宿主机目录挂载到 `/etc/openresty/templates`（如 235 的
> `/data/app/data/authz/conf`），镜像升级不会更新它。模板改动（如凭据头剥离、access 放行块）
> 必须同步到该目录再重建容器，否则新镜像配旧模板，行为静默缺项。每次发布模板变更后核对：
> `docker exec <容器> grep -c authorize_request /usr/local/openresty/nginx/conf/server.conf`。

生产检查模板：

```bash
docker inspect <container> --format '{{.Config.Image}} {{.HostConfig.NetworkMode}}'
docker inspect <container> --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
docker exec <container> openresty -t
docker restart --time 2 <container>
curl -fsS http://127.0.0.1:6080/_authz/login >/dev/null
```

不要默认容器名。历史实例用过 `authz-gw`，Compose 默认名是 `openresty-gateway`。

日常重建优先使用仓库脚本：

```bash
bash scripts/restart_gateway.sh          # 使用当前镜像，应用新的 .env 和 conf 模板
bash scripts/restart_gateway.sh --build  # 按当前 Docker 架构重建镜像后部署
```

脚本会拒绝非 `host` 网络，执行 `openresty -t`，并检查登录页、session API、Admin 入口和 HTTPS 登录页。
`.env`、网络、挂载和镜像变化都要重建容器；仅执行 `docker restart` 不会更新容器创建时的环境变量。
`conf/`、`admin/` 和 `lualib/` 是挂载目录，修改它们通常无需重新构建镜像；只有镜像源发生变化时才使用 `--build`。

### 10.1 本次代理排障经验

1. 先确认上游服务本身：`curl -i http://127.0.0.1:2077/` 返回 `200` 才说明本机 code-server HTTP 服务正常；本机 HTTPS 失败不代表网关故障。
2. 再确认网关入口：`6443` 对外提供 HTTPS，但客户端入口协议与上游协议独立；绑定可选择 HTTP 或 HTTPS。HTTPS 上游默认校验证书，使用自签名证书时需在对应绑定开启“忽略 SSL 验证”，不要放宽全局设置。
3. 未登录时，绑定已解析但返回 `302` 到 `/_authz/login` 是预期认证结果；它证明请求已经进入认证链路。
4. WebSocket 默认全局开启；不同前缀可以共用同一端口，但同一最终域名重复创建返回 `409`。验证时只需携带 `Upgrade: websocket`，不依赖绑定记录中的旧 `websocket` 值。
5. 管理菜单优先使用已配置绑定的 `menu-name`，其次是绑定域名；绑定备注只在菜单名称下方显示，鼠标悬浮菜单时显示该菜单实际打开的完整域名地址；没有绑定时才使用自动发现的 `local:<port>`，且不显示绑定备注。普通点击在右侧 iframe 打开，Ctrl/Command + 点击在新窗口打开菜单地址。
6. pi-web 会校验 API 请求的 Host 与 Origin；网关必须保留外部 Host，pi-web 启动环境需设置精确域名白名单，例如 `PI_WEB_ALLOWED_HOSTS=pi-m.ws.example.com`。公网端口被外层代理改写时，网关只对同主机名 Origin 恢复公网端口，异域 Origin 继续由上游拒绝。
7. 若应用只接受目标地址 Host 或本地来源头，优先在单条绑定上覆盖 Host/Forwarded/Origin，或启用“模拟本机访问”并填写 `127.0.0.1`/网关局域网 IP；不要放宽所有绑定的全局默认策略。
8. 外层入口是两套、端口约定不同（2026-09-07 实测）：内网 APISIX（10.252.25.252）只监听 **443**，服务 `*-235/*-241.ai-t.wtvdev.com`；公网企业边缘（218.108.76.10）只监听 **ws.gatepro.cn 的 :99**（443 不通），且转发时**把 Host 的 zone 改写成 ai-t.wtvdev.com**（首标签保留，LAN APISIX 根本不服务 ws 域）。因此经 `ws.gatepro.cn:99` 浏览时菜单域名总是物化成 ai-t，菜单链接不能照抄浏览器端口——`admin/app.js` 的 `nodeUrl` 只在目标与当前页同 zone 时继承端口，跨 zone 用默认 443，否则拼出 `*-235.ai-t.wtvdev.com:99` 这类死链。`server.conf.template` 必须保持 `absolute_redirect off`，否则访问 `/_authz/apps` 时生成的尾斜杠跳转会泄露不可达的 `:6443`，造成 Admin 入口无法访问。
9. 绑定的“上游路径改写”会把请求统一转发到填写的目标路径，不改变 Casbin 对象；例如填写 `/backend/index.html` 会把 `/path?a=1` 转发为 `/backend/index.html?a=1`。改写路径必须是安全路径，不能带 query、fragment、连续斜杠或 `..`。

## 11. 已解决故障与防回归点

- Admin UI 统一使用 `/_authz/apps/`，不要恢复 `/admin/`；旧路径曾与认证跳转和 Cookie 问题混杂。
- 登录错误 query 必须通过 `ngx.req.get_uri_args()` 解码，不能直接渲染 `ngx.var.arg_err` 的百分号编码。
- 登录页和 OAuth 的 start/callback 响应必须使用 `Cache-Control: no-store`，避免浏览器回退或 302 缓存重现旧错误。
- 右侧 iframe 必须占满壳的剩余空间；修改 drawer 时同时验证右侧内容可见。
- 40px mini drawer 下，菜单、收缩按钮、Logout、语言按钮必须分别验证“可见”和“可点击”。
- `klib.router` JSON Content-Type、默认错误请求头脱敏、`merge()` 返回/原子性均有真实回归，不能退回旧行为。
- 整体挂载 `lualib`，避免镜像内有 `klib`、挂载后却缺失的差异。
- 数据库缓存查询键包含 `authz_cache:db_rev`；service 的事务成功提交后自动发布数据库及授权 revision，
  回滚不失效缓存。直接改 SQLite 不会触发 revision，必须走 service/API，或重启进程。
- 反向代理终止 TLS 时正确传递 `X-Forwarded-Proto`，或设置 `AUTHZ_COOKIE_SECURE=true`。
- `authz_session` 必须统一使用规范父域；多条同名 Cookie 不能按首条盲选，登录/登出必须同时清理
  host-only、旧子域和旧宽域作用域。当前实例规范域为 `.ws.example.com`。
- `/_authz/apps/` 静态资源默认启用 Brotli/Gzip，Brotli 动态等级 5、Gzip 等级 5；镜像构建为普通资源生成 Brotli 等级 11 的 `.br` 侧车文件，并通过 `brotli_static on` 优先提供。含 SSI 菜单入口的 `admin/index.html` 必须排除 `.br` 生成，否则 Brotli 请求会绕过 SSI 过滤器，导致登录后左侧菜单消失。
- Admin 入口启用 SSI；`index.html`、`users.html`、`authorization.html` 在页面内声明 `no-cache/no-store`，HTTP 响应不再添加这两个缓存控制头；普通静态资源通过 `expires max` 输出长期缓存头。
- 公共代理响应默认压缩且**不注入任何缓存控制头**：`Cache-Control`、`ETag`、`Last-Modified` 由上游决定，网关只透传，终端因此可以正常启用浏览器缓存。防回归点：
  1. `gzip_proxied` 必须显式写成 `any`。默认值 `off` 的判据是请求是否带 `Via`（不是 `X-Forwarded-For`），而 ngx_brotli 没有这层门控；保持默认会让经 SLB/边缘 nginx（带 `Via` 转发）进来的请求拿到未压缩正文，同一条链上 Gzip 与 Brotli 行为不一致。已在目标镜像实测：带 `Via` 时 gzip 完全不生效，写 `any` 之后恢复。
  2. `text/event-stream` 绝不能进 `gzip_types`/`brotli_types`：压缩器会攒住事件，SSE 的逐块语义失效；流式响应靠 `X-Accel-Buffering: no` 声明下游不缓冲。
  3. 正文改写（`response_rewrite`）除撤 `Content-Length` 外必须撤 `ETag` 与 `Last-Modified`（见 `gateway.rewrite.header_filter`）。正文已变而校验器仍是上游旧指纹时，浏览器条件请求命中 304，把未改写的上游正文当成最新内容。gzip 会把强校验器弱化成 `W/"..."`，断言按弱化形式写。
  4. 给上游的 `Accept-Encoding: identity` 必须走独立变量（`$authz_accept_encoding` + `proxy_set_header`），不能用 `ngx.req.set_header`。nginx 的 gzip 模块按**同一张请求头表**判定是否压缩下游响应，写进表里会让所有配了正文改写的绑定整体丢掉网关压缩（实测：改写响应从 77 字节gzip 退回 743 字节明文）。
  5. `response_rewrite.conditions`（对齐 APISIX route vars 的条件匹配）在 header_filter 阶段对整条规则求值：URI 用含查询串的 `$request_uri`，`content_type` 条件只比媒体类型本体；不命中即整条规则（状态码/头/正文）完全不介入，也不打 `X-Authz-Rewrite` 标记。代理阶段向上游声明 `identity` 前要先过 `body_rewrite_applies`：条件里凡是请求期可判定的字段明确不命中时保留客户端压缩协商。注意 Lua local 可见性：`request_phase_match` 必须定义在 `condition_matches` 之后，否则运行期 attempt to call a nil value。
- Dockerfile 使用 Buildx 多阶段构建，`RESTY_J` 默认 8；源码下载单独缓存，GitHub Actions 使用 GHA cache。不要退回 `DOCKER_BUILDKIT=0`。
- 发布或部署镜像时优先使用 GitHub Actions 推送到 GHCR 的镜像；只有调试 Dockerfile、验证未发布改动或 CI 不可用时才本地构建。
- Docker Desktop for Mac 必须开启 Host Networking；否则容器内的 `127.0.0.1` 不代表宿主机端口，自动发现和代理测试都会产生误导性结果。

## 12. 维护交付清单

- [ ] 未改变稳定入口和 API 根路径；
- [ ] 身份始终按来源 + 用户名处理；
- [ ] 非 admin 无法读取用户列表和授权策略；
- [ ] 远程禁用状态不会被后续登录记录重新启用；
- [ ] Router register/merge 错误全部检查；
- [ ] 新增 API 有真实 OpenResty HTTP 测试；
- [ ] Admin UI 中英文、移动宽度、mini drawer、SSI 菜单和右侧 iframe 都验证；
- [ ] 没有记录密码、Cookie、Client Secret、Authorization 或 access token；
- [ ] `git diff --check` 和相关三组测试通过；
- [ ] 生产先 `openresty -t`，再部署，并验证登录页、session API 和一个受保护应用。

---

## 附录 A：APP 开发详细规范（klib Router / ctxvar / ngx.re）


> 自 AGENTS.MD 并入（AGENTS.MD 仅保留发布与测试核心步骤）。

### 总体设计模式

APP 统一采用“一个 location + 一个主 Router + 代码分支”的模式：

```text
Nginx APP location
  -> require("app.router"):handle()
  -> method + path 匹配
  -> Lua handler
  -> response
```

核心约定：

1. 一个 APP 只设置一个 Nginx Router 入口，不为每一个 API 编写 location。
2. 主 Router 在 Lua 模块加载时创建和注册，同一 worker 内通过 `require` 缓存复用。
3. 子模块通过 `router:merge()` 组合，不在请求期间动态注册或 merge。
4. `router.root_entry` 必须与请求进入 Router 时的 URI 前缀一致。
5. 路由、认证、参数校验、错误处理和模板行为都必须有实际 HTTP 回归测试。

### APP Router 标准示例

```lua
local collect = require "tracker.collect"
local router = require("klib.router").new("/tracker")

local function register(method, rule, handler, template)
    local _, _, err = router:register(rule, handler, method, template)
    assert(not err, err)
end

register("GET", "/", function(params, env)
    return "ok"
end)

register("POST", "/collect/:key", function(params, env, req)
    local headers = env.request_header
    local body = env.request_body
    if body == "" then
        return { err = "request body required" }, 400
    end
    return { key = params.key, accepted = true }, 202
end)

register("GET", "/day_uv/:key", function(params, env)
    local list = collect.get_day_uv(params.key, nil, true)
    return list
end)

local merged, merge_err = router:merge(require("tracker.prometheus_router"), "/p")
assert(merged, merge_err)

return router
```

对应的 Nginx 配置只保留一个 APP 入口，并让 location 前缀与 `root_entry` 一致：

```nginx
location ^~ /tracker {
    content_by_lua_block {
        require("tracker.router"):handle()
    }
}
```

不要将 `router.new("/tracker")` 直接挂到 `location /_api_/`。`ctxvar.uri` 来源于原始请求 URI，location 和普通 rewrite 不会可靠地把它变成 `/tracker`，实测会导致 Router 404。

如果公开入口必须是 `/_api_/`，主 Router 也应使用 `new("/_api_")`，并把 APP 名作为路由规则的一部分；或者在 Router 外明确构造并传入经过测试的自定义 ctx。不要假定 Nginx location 会自动剥离前缀。

### klib.router 约定

#### 注册与匹配

- 支持 `GET`、`HEAD`、`POST`、`PUT`、`DELETE`、`OPTIONS`、`PATCH`。
- 路由使用字面量路径和 `:param` 段参数，不把正则、Lua 表达式或外部数据当作路由规则。
- handler 签名固定为 `function(params, env, req)`。
- 路径参数从 `params` 读取；query/body helper 从 `req` 读取；请求上下文从 `env` 读取。
- 静态路径会优先于同层参数路径，例如 `/users/me` 优先于 `/users/:id`，但仍必须补冲突测试。
- method 不匹配、root 不匹配和未知路径统一进入 404 处理。
- `/tracker` 和 `/tracker/` 均可命中注册为 `/` 的根路由，已在 OpenResty 中验证。
- 注册函数会返回第三个错误值；必须检查它。重复的 method + path 和不支持的 method 会被拒绝。

推荐使用小型注册包装器统一检查错误，或逐项断言：

```lua
local _, _, err = router:get("/users/:id", handler)
assert(not err, err)
```

#### handler 返回值

- `return table`：Router 序列化为 JSON 文本。
- `return string`：Router 按 HTML/text 输出。
- `return status`：100—599 的整数作为 HTTP 状态码快捷返回，不输出 body。
- `return table_or_string, status`：第二个 number 才会设置 HTTP 状态码。
- `return nil, status`：只设置状态码，不输出 body。
- handler 抛错会被 `xpcall` 捕获，并进入 500 错误处理。

以下写法等价：

```lua
return 404
-- 等价于
return nil, 404
-- 需要响应内容时
return { err = "not found" }, 404
```

table 响应的 Content-Type 固定为 `application/json; charset=UTF-8`，HTML/字符串响应为
`text/html; charset=UTF-8`。这个契约由真实 OpenResty Router 回归覆盖，API 客户端可以据此解析。

#### 子 Router、filter 与模板

```lua
-- tracker/router.lua
local router = require("klib.router").new("/tracker")
router:merge(require("tracker.collect_router"), "/collect")
router:merge(require("tracker.prometheus_router"), "/p")
return router
```

- 子 Router 只声明自己的相对规则，主 Router 负责最终路径空间。
- merge 后必须测试完整 URI，例如 `/tracker/p/metrics`。
- `merge()` 成功返回 `true, route_count`，失败返回 `nil, error`；调用方必须检查返回值。
- merge 会先预检全部路由，重复路由或非法注册失败时不会留下部分注册结果。
- 子 Router 的 filter 会复制到 merge 后的对应路由，实测有效。
- 当前 `merge()` 不传递子路由注册时的 `template` 参数；merge 后会输出序列化 table，而不是渲染模板。模板路由应暂时注册在主 Router，或在 handler 中显式调用受控模板渲染，直到框架修复并有测试覆盖。
- `resty.template.safe` 只提供安全的错误返回方式，不是模板沙箱。只渲染代码库内受信任的模板。

#### access hook 限制

当前版本不要使用 `router:add_access()`：实例没有初始化 `self.access`，实测调用会立即报错。

`router.pre_access` 可以执行，但当前实现调用它时第一个 `func` 参数仍为 `nil`。不要依赖该参数，也不要把完整认证授权体系建立在这个未完成的 hook 上。认证和授权优先放在经过测试的 `access_by_lua`、handler wrapper 或明确的业务入口中，并保持 fail-closed。

### klib.ctxvar 约定

`ctxvar` 是请求级上下文适配层。正常请求中 `ctxvar.new()` 把对象保存在 `ngx.ctx._env`，同一请求重复调用会得到同一个对象。

常用字段：

- `env.uri`：规范化、无 query 的 URI，也是 Router 默认匹配输入。
- `env.request_uri`：ctxvar 重建的 URI，通常包含 query，但有下述短 query 限制。
- `env.var.request_uri`：需要原始请求 URI 时优先使用。
- `env.method`：HTTP method。
- `env.host`、`env.host_1`、`env.host_2`、`env.host_3`：Host 和域名层级。
- `env.request_header`、`env.cookie`、`env.var`：懒加载请求头、Cookie 和 Nginx 变量。
- `env.uri_args`、`env.post_args`、`env.request_body`：query、form 和原始 body。
- `env.file_format`、`env.is_static`：文件后缀和静态资源判断。
- `env.is_json`：请求 Content-Type 是否包含 `json`。

注意标准字段名是 `env.request_header`，不是 `env.header`。自定义 header 可按原名读取，例如 `env.request_header["X-Request-Id"]`。

#### ctxvar 使用规则

- 一个请求只传递一个 env，不把 env 或其子 table 放入跨请求全局缓存。
- 路由参数从 `params` 取，query 从 `req.get_query()` 或 `env.uri_args` 取。
- `env.request_body` 没有 body 时安全返回空字符串，可先用它检查是否为空。
- `env.ip` 会读取转发头。只有可信反向代理已经清洗这些 header 时才能把它当作客户端 IP。
- 不直接修改不存在的 `env.var` 字段；可写 Nginx 变量必须先在配置中用 `set` 声明。
- ctxvar 使用 tablepool；业务 handler 不手工 `dispose()` 或跨请求复用内部 table。

#### 已验证限制

1. 当 query string 长度不超过 3 个字符时，例如 `a=1`，`env.query_string` 和 `env.uri_args` 正确，但 `env.request_uri` 会省略 query。需要精确原始值时使用 `env.var.request_uri`。
2. `normalize_url()` 只可靠用于 URI path。绝对 URL 会重复第 9 个字符，例如 `http://example.test` 变成 `http://exxample.test`。
3. `req.get_body_header(env)` 对空 body 返回空字符串，不再抛出异常；对 JSON body 的第二个返回值是 headers table，对 form/空 body 则是 Content-Type string 或 `false`，不要依赖统一类型。
4. timer 模式必须传入 `request_header`：`ctxvar.new({ request_header = {} }, true)`。实测 `ctxvar.new({}, true)` 会把模块级 header 原型设为自引用 metatable，随后读取自定义 header 会出现 `loop in gettable`。在该问题修复前，不允许无 seed 使用 timer ctxvar。

### APP 代码组织

```text
lualib/tracker/
  router.lua                 -- 唯一主 Router
  collect_router.lua         -- collect 子 Router
  prometheus_router.lua      -- prometheus 子 Router
  handlers.lua               -- 输入适配和响应转换
  service.lua                -- 业务规则
  views/                     -- 受信任模板
```

- `router.lua`：创建主 Router、组合子 Router、安装公共行为。
- `*_router.lua`：注册相对路径、method 和 handler。
- `handlers.lua`：读取 `params/env/req`，执行输入校验并调用 service。
- `service.lua`：实现业务规则，不依赖 Nginx location 分支。
- `views/`：只保存受信任模板。

模块拆分使用 Router 和 `merge`，不增加 API 专属 location。

### ngx.re 正则约定

所有匹配、替换、校验一律使用 OpenResty 内置 `ngx.re`（PCRE 标准正则），不使用 Lua 原生
模式（string.find/gsub/match 的 `%d`、`()` 一类）承载业务语义。Lua 原生查找仅允许用于
固定字符串判断（如 `:find("%c")` 控制字符探测）。

- 标志位统一 `"jo"`：PCRE 语法 + `ngx.re` 编译缓存。
- 输入校验：保存前用 `ngx.re.find("authz-probe", source, "jo")` 做 PCRE 编译探测，第三个
  返回值非 nil 即非法正则，直接 422 拒绝。
- 字面量匹配也交给 `ngx.re`：源文本用 `\Q...\E` 逐字引用（文本自带 \E 时按
  「结束引用 + \\E（引用外两个反斜杠=匹配一个字面反斜杠）+ E + \E 重新进入引用」
  规范化）。已在目标引擎（OpenResty 1.31.1.1 / PCRE2）实测：a.b 不匹配 axb，a|b、
  a\Eb 逐字命中。
- 字面量规则的替换值必须经回调原样插回：`ngx.re.gsub(body, quoted, function() return
  replacement end, "jo")`。字符串形式的替换目标会展开 `$N`，写进替换值里的 `$1` 会被吃掉。
- 正则规则用字符串替换目标，`$N` 为捕获组引用（APISIX/nginx 语义），未定义的组展开为空
  串；这是标准行为，文档和 UI 提示里要写明。
- `ngx.re.gsub` 返回 `value, substitutions, err` 三个值：取错误必须接满三个返回值；无匹配
  时返回原文、`substitutions=0`、`err=nil`，不是错误。
- 引用 `\Q`/`\E` 等 Lua 5.1 不认识的转义序列时用 `string.char(92)` 拼接，避免
  `invalid escape sequence` 编译错误。
- 语义疑问用一次性 nginx 配置实测而不是猜：`http { init_worker_by_lua_file ... }` +
  `ngx.timer.at(0, ...)` + `error_log /dev/stderr info`，`--entrypoint openresty` 直跑
  （authz 镜像的 `resty` 缺 perl shebang，镜像 entrypoint 会接管命令）。

已验证实现：`lualib/resty/authz/gateway/rewrite.lua` 的 `apply_rewrites`（请求/响应正文
改写共用），回归用例在 `test/test_authz_gateway.sh`（关键词 `rewrite-pcre`）。

### 请求、安全与错误处理

推荐处理顺序：

```text
读取 env
  -> 输入类型与范围校验
  -> 身份认证
  -> 路由/资源授权
  -> service 业务校验
  -> 业务调用
  -> 统一响应
```

- 无身份返回 401，无权限返回 403，资源不存在返回 404，输入错误返回 400/422。
- 认证、授权、模板和依赖异常必须 fail-closed，不能因异常放行。
- 不记录密码、Cookie、token、Authorization header 或完整敏感 body。
- 默认错误处理不再回显请求 header，但 500 的内部错误文本仍可能包含堆栈。生产 API 必须安装经过测试的 404/500 错误处理器，只返回稳定错误码和通用消息。

### OpenResty 生命周期和配置

- Router 必须在模块级创建。禁止在 `content_by_lua_block` 中每个请求重新 `new()` 和注册。
- `init_by_lua` 只做 master-safe 初始化，不读取请求级 `ngx.var`、`ngx.req` 或 `ngx.ctx`。
- APP location 只调用 `require("app.router"):handle()`，不实现 API 分支。
- Lua 模块路径必须包含项目 `lualib/?.lua`、`lualib/?/init.lua` 和 OpenResty 自带 lualib。
- 新增 vendored Lua 库时同步检查 Dockerfile COPY 路径和容器内 `require`。
- 阻塞式外部 IO 不放入高频请求路径。
---

## 附录 B：Agent 控制面接入与实现细节


> 自 AGENTS.MD 并入；Agent 侧硬性规则的精简版保留在 AGENTS.MD。

### Authz Gateway 的 API 控制（Agent 接入要求）

本仓库自身就是一个 Authz Gateway。Agent（自动化程序）在本机对网关控制面的访问必须遵守以下约定，
不得为绕过认证而修改代码或数据库。

#### 认证方式（四选一，按优先级）

1. **实例级预置 API Key（推荐，免登录）**：环境变量 `AUTHZ_API_KEY`（32-256 字符，
   `openssl rand -hex 32` 即可）设定实例的机器 Key，请求头 `x-api-key: <Key>` 提交。
   免登录直接覆盖三类入口：控制面 API（免 CSRF 写操作）、管理页面与静态资源
   （`/_authz/apps/*`，Playwright 用 `setExtraHTTPHeaders` 逐请求附带）、代理入口。
   主体固定 `api-key:0`，角色由 `AUTHZ_API_KEY_ROLE`（默认 admin）决定并走 Casbin 策略；
   来源必须命中 `AUTHZ_API_KEY_ALLOWED_IPS`（逗号分隔 IP/CIDR，默认仅 `127.0.0.1`）。
   不入库、不受管理界面禁用影响，
   随环境变量轮换；配置非法时容器启动即失败。

   ```bash
   curl -H "x-api-key: $AUTHZ_API_KEY" http://127.0.0.1:6080/_authz/api/...
   ```

2. **本机自动化**：原 `AUTHZ_AGENT_API_KEY`（自动 seed 的 `agent-default` Key）已移除。
   等价替代：实例级 `AUTHZ_API_KEY`（`AUTHZ_API_KEY_ALLOWED_IPS` 默认仅 127.0.0.1）
   或管理界面创建 `loopback_only=1` 的数据库 Key，均用 `x-api-key` 头提交：

   ```bash
   curl -H "x-api-key: $AUTHZ_API_KEY" http://127.0.0.1:6080/_authz/api/...
   ```


3. **普通 API Key**：管理员通过 `POST /_authz/api/api-keys` 创建（新建默认角色 `guest`，
   仅可访问 `/_authz/guest` 请求诊断页），角色决定控制面与代理权限，
   不限来源但无 CSRF 豁免差异（API key 本身免 CSRF）。
4. **浏览器会话**：人用，修改请求需 `X-CSRF-Token`。Agent 不应使用会话方式，避免 CSRF 与 Cookie 管理。

机器凭证头有两个：`x-role-key`（只认数据库 API Key）与 `x-api-key`（先按 `ak_` 格式查库，
未命中再比对实例级环境变量 Key）；旧 `x-authz-key` 已合并移除。只要呈现了任一凭证头，Key
无效就直接 401，绝不回退到同时携带的 Cookie；这些头被网关剥离，绝不转发上游，绑定级改写
请求也禁止设置它们。

#### 控制面路径（全部在 `/_authz` 下）

- 会话：`GET|DELETE /_authz/api/session`
- 用户：`GET|POST /_authz/api/users`、`PATCH|DELETE /_authz/api/users/:id`、`PUT /_authz/api/users/:id/password`
- 绑定（应用）：`GET|POST /_authz/api/applications`、`PATCH|DELETE /_authz/api/applications/:id`
  （`response_rewrite` 字段配置绑定级响应改写，字段与限制见 `docs/core-api.md`）
- 策略：`GET /_authz/api/authorization`、`POST /_authz/api/policies`、`PATCH|DELETE /_authz/api/policies/:id`
- API Key：`GET|POST /_authz/api/api-keys`、`PATCH|DELETE /_authz/api/api-keys/:id`
- Guest 诊断页：`GET /_authz/guest`（匿名即可访问；guest/admin 的 Key 与会话同样可用；加 `?json=1` 返回 JSON）
  ——**明文完整**回显当次请求的全部请求头（含 Cookie/Authorization/API Key）、来源 IP
  与代理转发头，用于 debug；guest 的代理访问范围可像其他角色一样用策略配置。
- 菜单树：`GET /_authz/api/menu-tree`（渲染用）；`GET|POST /_authz/api/menu-entries`、
  `PUT /_authz/api/menu-entries/reorder`、`PATCH|DELETE /_authz/api/menu-entries/:id`（编辑用）

完整字段与示例见 `docs/core-api.md`。

#### 硬性要求

- **只走本机**：Agent 必须在网关宿主机上运行，通过 `127.0.0.1:<AUTHZ_HTTP_PORT>` 访问；
  禁止把控制面端口暴露到公网或跨机访问。
- **请求头**：修改类请求必须带 `Content-Type: application/json`；API key 放 `x-api-key`
  （数据库 Key 也可用 `x-role-key`），不用 Cookie、不用 `Authorization: Bearer`。
- **响应契约**：成功 `{"data": ...}`，失败 `{"error":{"code","message"}}`，JSON 为 UTF-8。
  状态码语义：401 未认证/Key 无效、403 无权限或 CSRF 失败、404 不存在、409 冲突、422 参数校验失败。
- **最小权限**：Agent 凭证（实例级 `AUTHZ_API_KEY` 或数据库 Key）权限按角色而定，只应调用其任务
  所需的最小接口集合；不要把 key 写入日志、代码或 git。
  写绑定（`POST/PATCH /_authz/api/applications`）时要意识到它包含两条高危能力：
  `target_ip` 等同内网访问能力，`response_rewrite` 会改写返回给浏览器的响应；
  除非任务明确要求，Agent 不得提交 `response_rewrite`，也不得用它改写安全响应头或注入脚本。
- **登录防护**：控制面登录有失败延迟与 `账户名+IP` 锁定（默认 5 次 → 30 分钟）。Agent 不应使用
  用户名密码登录，避免触发锁定。
- **验证义务**：任何依赖这些接口的自动化脚本，必须在真实实例上先做一次 smoke（读 session、列 applications）
  再执行变更；变更类操作后必须复核结果。

#### 实现侧要求（修改网关代码时）

- API Key 认证逻辑在 `lualib/resty/authz/api_key.lua`（含 `loopback_only` 强制），
  种子逻辑在 `lualib/resty/authz/db/seed.lua`；改动后必须在真实实例上同时验证
  “回环可用 + 非回环拒绝”两个方向，并更新 `test/test_authz_gateway.sh`。
  实例级 Key（`AUTHZ_API_KEY` / `x-api-key`）由 `config.lua` 的 `configure_api_key` 校验并注入
  `api_key.configure_env`（本模块禁止 require 上层模块，避免 init_by_lua 加载链上的 require 环）；
  比较必须走 `util.constant_time_equals`，角色线在 `gateway/cache.lua` 以 `api-key:0` 注入 Casbin，
  页面免登录放行在 `conf/server.conf.template` 的 access 块（`api_key.authorize_request()`）。
- 新增控制面接口时保持：guard 顺序（会话/API key → admin/roles → CSRF）不变、
  错误结构不变、并同步 `docs/core-api.md` 与本节路径清单。

---

## 附录 C：klib APP Code Review Checklist

- [ ] APP 是否只有一个 Router 入口 location？
- [ ] location 前缀是否与 `root_entry` 一致？
- [ ] Router 是否在模块级创建并由 worker 复用？
- [ ] 所有注册错误是否被检查？
- [ ] handler 是否遵循 `params/env/req` 签名？
- [ ] 是否正确使用 `return 404`、`return nil, 404` 或带 body 的状态返回？
- [ ] 是否覆盖静态/参数冲突和 method 不匹配？
- [ ] 子 Router merge 后的完整路径和 filter 是否有测试？
- [ ] 所有 `merge()` 返回错误是否被检查，失败是否保持原子性？
- [ ] 是否避开 merge 模板、`add_access` 和无 seed timer ctxvar 的已知问题？
- [ ] 空 body 和不同 Content-Type 的解析结果是否有测试？
- [ ] 认证、授权和异常是否 fail-closed？
- [ ] 模板是否来自受信任代码？
- [ ] 是否通过 `test/test_klib_router_ctxvar.sh`？
- [ ] 正则/替换是否全部走 `ngx.re`（"jo"），字面量是否 \Q 引用、替换值是否回调插入？
- [ ] 非法正则是否在保存时以 PCRE 编译探测拒绝（而不是运行期才失败）？
- [ ] Dockerfile 是否包含新增 lualib 模块？
