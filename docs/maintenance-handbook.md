# OpenResty Authz Gateway 维护手册

> 面向后续维护 Agent。本文记录截至 2026-08-25 已验证的系统设计、开发约束、测试基线与部署方式。
> 修改前先读根目录 `AGENTS.MD`；涉及身份源时再读 `docs/sso-jwt-auth.md`。

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

Agent/API 控制面接入：设置 `AUTHZ_AGENT_API_KEY` 环境变量后启动，会 seed 名为 `agent-default` 的
API Key（角色 admin、`loopback_only=1`），只能从网关宿主机本机调用 `/_authz/api/*`，非回环来源 401。
轮换时更换该环境变量并重建容器。接入约定与硬性要求见 `AGENTS.MD` 的「Authz Gateway 的 API 控制」章节；
接口明细见 `docs/core-api.md` 2.3 节。

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
| `bindings` | domain 唯一；target_ip/port、enabled、websocket、note、menu_name；upstream/forwarded/origin 代理字段；simulate_local/local_ip；header_overrides（多行 Header 覆盖，逐条校验后存储）；response_rewrite（响应改写规范化 JSON，空串表示未配置） |

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
`admin`、`staff`、`user`、`viewer`；服务主体可绑定其中任一角色，另有不可分配给用户的 `api` 角色：

- `admin` 可访问用户、应用绑定和 Casbin 管理 API；
- `api-key:<id>` 继承 Key 记录中的单一角色，`admin` Key 可调用全部管理 API；
- `api` 不能修改/删除绑定，不能管理用户、角色、策略、API Key 或核心认证；
- 非 admin 只能读取自身 session/profile；
- 默认仅 `role:admin` 拥有 `/*`，其他角色默认拒绝；
- viewer 不得看到 Authorization/Casbin 数据；
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

- Header 固定为 `x-authz-key: ak_<64 hex>`，显式无效 Key 不得回退浏览器 Cookie；
- 数据库 `api_keys` 只保存 SHA-256 摘要，明文只在创建响应中出现一次；
- Key 可使用固定目录中的 `admin/staff/user/viewer/api` 单一角色，角色修改必须立即失效旧缓存；
- `admin` Key 可管理全部控制面；`api` Key 只额外允许新建 binding；其他角色与同角色用户边界一致；
- 代理前必须通过 `proxy_set_header X-Authz-Key ""` 清除凭据；
- `target_ip` 允许可信 admin/api 主体连接其他机器，应将其视为内网访问能力；Casbin 对象仍按
  `/<port><path>` 授权，同端口的不同目标 IP 共享策略；
- 绑定级 Host/Forwarded/Origin 字段必须经过 authority/origin 白名单校验并拒绝 CR/LF；模拟本机访问只重写
  `Host`、`Origin`、`X-Real-IP`、`X-Forwarded-For` 等 HTTP 头，不应被描述成 TCP 来源伪造；
  header_overrides 只覆盖透传类请求头，格式、控制字符、长度和白名单（禁 Host/Cookie/Origin/X-Authz-*/X-Forwarded-*/hop-by-hop）
  在 validation 层校验，cache 层防御性二次过滤，proxy 层用 ngx.req.set_header 注入；
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
  Authz Gateway 的 `x-authz-key` 应用凭据不是同一种密钥。

同一 Client ID、Secret 和回调 URI 必须同时注入 NocoBase 与网关。环境变量改变必须重建容器，
普通 `docker restart` 不会改变容器环境。详细配置见 `docs/sso-jwt-auth.md`。

其他 Provider：

- DingTalk 使用 `authCode` 回调和专用 token/userinfo 请求头；
- Google 要求 verified email；
- 微信使用网站应用 `snsapi_login`，不是公众号或小程序流程；
- 未完整配置的 Provider 必须继续显示"待配置"，但不能发起残缺授权流程。

### 6.1 多实例 OAuth 两级中继（已移除）

该架构已于本轮安全整改中整体移除：`relay.lua`、中继配置、断言签发/验签与对应回归
全部删除；`/_authz/oauth/relay/start` 现在返回 410。多实例之间不再通过网关
转发 OAuth 授权流程。各实例如需登录入口，应各自配置 Provider 或通过外部
负载均衡把登录入口收敛到单一实例；跨实例登录态保持使用 6.2 的共享 Redis 会话。
历史说明仅保留在 git 记录中，不要在代码里恢复 `AUTHZ_OAUTH_RELAY_*` 相关变量。

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

`AGENTS.MD` 是详细规范，以下是不可破坏的框架契约：

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

OPENRESTY_TEST_IMAGE=openresty-base:nocobase-test \
  bash test/test_klib_router_ctxvar.sh

OPENRESTY_TEST_IMAGE=openresty-base:nocobase-test \
  bash test/test_authz_gateway.sh

bash test/test_shared_session.sh

bash test/run_tests.sh openresty-base:nocobase-test
```

三组测试职责：

| 脚本 | 覆盖 |
|---|---|
| `test/test_klib_router_ctxvar.sh` | Router/ctxvar、JSON、错误脱敏、merge 返回与原子性 |
| `test/test_authz_gateway.sh` | 登录、API、CSRF、身份隔离、远端记录、OAuth、动态代理、HTTPS Cookie 与绑定级响应改写 |
| `test/test_shared_session.sh` | 共享会话 (Redis 单写多读、ACL、故障关闭) |
| `test/run_tests.sh` | 镜像基础库、WebDAV、FancyIndex、JWT/旧 SSO 兼容 |

截至本文更新，最近基线为 Router 99、Authz 635、共享会话 29、基础镜像 17。数量不是固定契约；
任何行为变更必须增加或调整能验证真实 HTTP 结果的断言。

三个脚本都会占用随机端口并起常驻 mock，**必须串行执行**；并发跑会互相抢端口并污染日志。

功能验证之外，`241.t`（10.252.25.241，`/data/app/authz-test`，端口 6080/6443）是长期在跑的测试实例，
作为共享会话 reader 与生产 writer（本机 235）配对。它是共享会话、跨实例撤销和绑定级响应改写的
回归现场，同步与验证方式见 `AGENTS.MD` 的「测试实例」一节。

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
