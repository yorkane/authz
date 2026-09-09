# Authz Gateway 控制面 API 速查（配置助手用）

所有端点都在 `/_authz/api` 下。机器请求一律 `x-api-key: <Key>` 头，免 CSRF、免登录。
成功 `{"data": ...}`，失败 `{"error":{"code","message"}}`；修改类请求必须
`Content-Type: application/json`。状态码：401 未认证/Key 无效、403 无权限、404 不存在、
409 冲突、422 参数校验失败。

## 0. 会话与身份

- `GET /session` — 当前身份、角色、来源。先跑它做 smoke。

## 1. 角色与用户

本地角色目录固定：`admin` / `staff` / `user` / `guest`（`viewer` 已退役，提交返回 422；
`api` 仅能作为 API Key 角色，不能分配给人类用户）。没有动态新建角色的 API。

- `GET /users` — 本地 + 远程身份列表、可分配角色目录。
- `POST /users` — `{"username","password","roles":["user"]}`（roles 可多选，逗号或数组）。
- `PATCH /users/:id` — `{"roles":[...], "enabled":true}`。
- `DELETE /users/:id`
- `PUT /users/:id/password` — `{"password":"..."}` 重置他人密码。

## 2. API Key（开放接口给第三方）

- `GET /api-keys` — 元数据列表，永不含明文；`token_prefix`（前 11 字符）是识别指纹。
- `POST /api-keys` — `{"name":"ci-agent","role":"guest"}`；角色省略默认 `guest`
  （仅 `/_authz/app/guest.html` 诊断页 + `GET /session`）。要调控制面 API 选
  `api`/`staff`/`admin`。响应里的 `token`（`ak_<64hex>`）**只出现一次**。
- `POST /api-keys/:id/rotate` — 轮换，旧值当场失效，新 `token` 同样只出现一次。
- `PATCH /api-keys/:id` — `{"name","role","enabled":false}`，立即生效。
- `DELETE /api-keys/:id` — 不可恢复。

**用户创建的 Key 怎么用**（创建后应把以下用法完整交给用户）：

1. **携带方式**：请求头 `x-api-key: ak_xxx`（推荐）。数据库 Key 也可用专用头
   `x-role-key` 提交；两个头同时出现时以 `x-role-key` 为准。只要呈现了任一凭证头，
   Key 无效就直接 401，绝不回退到浏览器 Cookie。
2. **能打开哪三类入口**（同一把 Key）：
   - 控制面 API：`https://<入口>/_authz/api/*`，机器请求免 CSRF；
   - 管理页面与静态资源：`/_authz/apps/*`、`/_authz/files/*`（浏览器/Playwright 用
     `setExtraHTTPHeaders` 逐请求附带该头，不必登录取 Cookie）；
   - 代理入口：域名/端口绑定与 `<port>-域名` 动态入口，如
     `https://code-235.ai-t.wtvdev.com:6443/api/...`。
3. **权限边界 = 角色 + Casbin 策略**：
   - `guest`：只有 `GET /_authz/app/guest.html` 诊断页和只回显自身的
     `GET /_authz/api/session`；其余控制面 API、管理页、文件浏览一律拒绝。
     给第三方做链路自检（确认来源 IP、代理头、上游收到的头）用 guest 即可。
   - `user`/`staff`/`admin`：按角色的 Casbin 策略决定控制面与代理目标权限；
     需要调控制面 API 但只做业务读取时用 `staff`，完全控制面管理用 `admin`。
   - `api`：服务主体角色，默认可访问所有已解析代理目标（admin 可用 deny 收紧），
     适合纯代理场景的第三方后端。
4. **上游看到什么**：网关剥离凭证头，绝不转发 Key；上游只收到
   `X-Authz-User: <Key名称>`、`X-Authz-Source: api-key`、`X-Authz-Identity: api-key:<id>`，
   第三方可据此区分身份（Key 名称建 Key 时就定好，见名知用途）。
5. **来源限制**：数据库 Key 本身不限来源，安全边界是"谁拿着 Key"。需要限定来源时：
   跨机固定出口 IP 或本机自动化的场景优先改用实例级 `AUTHZ_API_KEY`（配
   `AUTHZ_API_KEY_ALLOWED_IPS` 白名单，默认 127.0.0.1，只认 `x-api-key` 头）；
   也可创建 `loopback_only=1` 的数据库 Key（原 AUTHZ_AGENT_API_KEY 自动 seed 已移除）。
    实例级 Key 的内置默认值为 `eeeec9f034335f136f87ad84b625ffff`（角色 admin），
    仅适合本机/测试实例；生产实例应已在部署 `.env` 中更换。
6. **保管要求**：Key 放环境变量或密钥管理系统，不写 URL query、Cookie、日志、git；
   明文只在创建/轮换响应里出现一次，丢了只能轮换或重建。停用第三方时
   `PATCH {"enabled":false}` 立即失效，比删除温和。

最小示例：

```bash
KEY=ak_xxx   # 创建时一次性返回的 token
curl -H "x-api-key: $KEY" "https://<入口>/_authz/app/guest.html?json=1"  # guest 自检链路
curl -H "x-api-key: $KEY" "https://<绑定域名>/api/status"                # 代理入口
curl -H "x-api-key: $KEY" "https://<入口>/_authz/api/applications"       # 控制面（按角色）
```

## 3. 域名/端口绑定（按本地服务名配域名）

`GET /applications` — 显式绑定 + 探测到的本机 HTTP 服务（`binding:false`、
label `local:<port>`）。

`POST /applications` 核心字段：

| 字段 | 说明 |
|---|---|
| `domain` | 必填。**只填最后一级前缀**（`code`）；运行时按当前请求 Host 拼 `<前缀>-<节点>.<域名>`。非泛域场景也可传完整精确域名。重复 409 |
| `port` | 必填，须在 `AUTHZ_PORT_MIN..AUTHZ_PORT_MAX`（默认 2000-20000） |
| `target_ip` | 默认 `127.0.0.1`，只接受 IP 字面量。指向内网 = 内网访问能力，高危 |
| `menu_name` / `note` | 菜单显示名 / 悬浮备注 |
| `enabled` | 默认 true |
| `simulate_local` | 默认 false；true 时 Host/Origin/来源头模拟本机（数字前缀免配置入口恒为 true） |
| `local_ip` | 模拟来源 IP，默认 127.0.0.1 |
| `upstream_scheme` | `http`(默认)/`https` |
| `upstream_ssl_verify` | 默认 true；false 仅用于自签名/受控内网 |
| `upstream_path` | 固定上游路径改写，空=保留原路径；只接受纯 path |
| `upstream_host` / `forwarded_host` / `forwarded_proto` / `forwarded_port` | 显式覆盖上游 Host 与转发头 |
| `origin_mode` | `auto`(默认)/`preserve`/`rewrite`/`remove`/`custom`；custom 配 `custom_origin`（`http(s)://authority`） |
| `header_overrides` | 多行文本，每行 `Header-Name: value`，覆盖透传请求头（见 §5） |
| `request_rewrite` | 结构化请求改写，对象或 JSON 字符串（见 §5.1） |
| `response_rewrite` | 对象或 JSON 字符串（见 §6） |

`PATCH /applications/:id` 可改全部字段（仅 admin）。`DELETE /applications/:id` 删绑定。

注意：未绑定域名的 `<port>-任意域名` 动态入口永远可用且指向本机，默认模拟本机访问；
显式绑定只用于自定义菜单名、转发头、改写或指向非本机 IP。

## 4. Casbin 策略（配权限）

`GET /authorization` — 绑定、策略、主体、角色与方法目录（含 `binding_matches`）。

`POST /policies`（ptype=p）：

```json
{"ptype":"p","v0":"role:staff","v1":"/2077/*","v2":"*"}
{"ptype":"p","v0":"user:local:alice","v1":"/3000/api/*","v2":"GET|POST","eft":"deny"}
{"ptype":"p","v0":"role:user","v1":"/2077/*","v2":"*","binding_id":3}
```

- `v0` 主体：`role:<admin|staff|user|guest|api>` 或 `user:<source>:<username>`
  （本地用户可省略 `user:local:` 前缀直接传用户名）。
- `v1` 对象：`/<port><path>`，如 `/2077/*`、`/2077/api/*`；不同 IP 上同端口共享策略。
- `v2` 动作：HTTP 方法逗号/竖线或 `*`。`eft:"deny"` 优先于 allow。
- `binding_id` 可选，校验绑定存在且端口与 v1 一致（展示用，授权仍按端口+路径）。
- `ptype:"g"` 是角色分配规则（`v0=user:...`、`v1=role:staff`），管理 UI 不提供编辑，
  配置助手一般不需要动它。

`PATCH /policies/:id` 用与新建相同的完整字段；`DELETE /policies/:id` 删除。
默认拒绝：未显式 allow 的角色/用户访问任何代理目标都是 403（admin 默认 `/*` 全放行）。

## 5. 改写请求头（`header_overrides`）

多行文本，每行 `Header-Name: value`，保存时逐行校验（名称 ≤128、值 ≤1024、
总量 ≤8192、≤32 条、重名保留首条），按行覆盖发往上游的透传头。

不可覆盖（保存即 422）：`Host`、`Cookie`、`Origin`、`X-Authz-*`、`X-Forwarded-*`、
`X-Real-IP`、hop-by-hop 与分帧头、CR/LF。

典型用途：给上游固定一个 `Authorization: Bearer ...` 或业务头：

```json
{"header_overrides": "Authorization: Bearer sk-xxx\nX-Biz-Env: prod"}
```


### 5.1 结构化请求改写（`request_rewrite`）

与 `header_overrides` 相比能力更全，结构与 `response_rewrite` 同构：

| 字段 | 说明 |
|---|---|
| `headers` / `remove_headers` | 同 §6 语义，改写/删除发往上游的请求头（同样的禁止名单） |
| `body` / `body_base64` / `content_type` | 整体替换请求正文（与 `rewrites` 互斥） |
| `rewrites` | 请求正文过滤规则，同 §6 格式 |

规则：`body` 与 `rewrites` 不能同时给；四类全空视为未配置；配了正文改写时网关
自动声明 `Accept-Encoding: identity`（用户显式覆盖优先）。简单改一两个头优先用
`header_overrides`，需要改正文或删头用本字段。两者同时存在时 `request_rewrite`
在 `header_overrides` 之后应用。

## 6. 改写响应体（`response_rewrite`，APISIX 语义子集）

| 字段 | 说明 |
|---|---|
| `enabled` | 默认 true；false 保留配置不生效 |
| `status` | 覆盖状态码 200-999；0/空=保持上游 |
| `headers` | 对象，覆盖响应头；值 `null` = 删除该头 |
| `remove_headers` | 数组，删除响应头 |
| `body` | 整体替换正文（文本或 JSON 对象）；与 `rewrites` 互斥 |
| `body_base64` | true 时 body 按 Base64 解码（二进制） |
| `content_type` | 替换正文时回写的 Content-Type |
| `rewrites` | `[{source,target,regex}]` 正文过滤；`source` 以 `~` 开头或 `regex:true` 按 PCRE，替换支持 `$1`；字面量自动转义 |

限制：≤16 条规则、正则 ≤512、替换 ≤4096、正文 ≤65536、整体 JSON ≤131072 字节；
非法正则在保存时 PCRE 编译探测即 422。

安全头在保存与运行期两层拒绝改写/删除：`Set-Cookie`、`Content-Length`、
`Transfer-Encoding`、hop-by-hop、`X-Authz-*`/`X-Forwarded-*`/`Proxy-*`、
`X-Frame-Options`、`Content-Security-Policy`、`Strict-Transport-Security`、
`X-Content-Type-Options`、`Permissions-Policy`。

运行条件：只在上游 200 的 GET 响应生效；HEAD/WebSocket/已压缩/含 Content-Range/
过滤模式下非文本 Content-Type/超 1MB 缓冲上限会跳过，响应头
`X-Authz-Rewrite: skipped=<原因>` 标明原因。配置了 body 改写的绑定会自动向上游声明
`Accept-Encoding: identity`（绑定的显式 Accept-Encoding 覆盖优先）。

示例（把上游返回的绝对地址换成本机入口）：

```json
{"rewrites":[{"source":"https://upstream.internal","target":"https://code-235.ai-t.wtvdev.com"}]}
```

## 7. 菜单

- `GET /menu-tree` — 渲染用完整树（分组 + 系统应用 + 域名服务 + 本地服务）。
- `GET /menu-entries` — 可编辑条目表（分组与自定义 item；`builtin` 非空的不可删/改保护项）。
- `POST /menu-entries` — `{"kind":"group","label":"我的分组"}` 或
  `{"kind":"item","parent_id":<分组id>,"label":"入口","url":"/_authz/apps/xxx.html 或 http(s)://...","icon":"mdi-xxx"}`。
- `PATCH /menu-entries/:id` — `label`/`url`/`icon`/`parent_id`/`sort_order`/`enabled`。
- `PUT /menu-entries/reorder` — `{"order":[{"id":1},{"id":2}]}` 顺序赋 sort_order。
- `DELETE /menu-entries/:id` — builtin 项 409。
- `GET /menu-services` — 「域名服务/本地服务」组内运行时注入项的编辑行（key：`binding:<id>` / `port:<port>`）。
- `PATCH /menu-services/:key` — `{"label","icon","enabled","sort_order"}`；隐藏条目只影响菜单显示，不影响服务本身；改绑定菜单名建议走 `PATCH /applications/:id` 的 `menu_name`（单一数据源）。
- `PUT /menu-services/reorder` — `{"order":[key,...]}`；`DELETE /menu-services/:key` 重置该项覆盖。
- 图标用 MDI v7 名称（如 `mdi-key-outline`）；不确定时从 `admin/vendor/mdi-names.js` 查。

## 8. Nginx 配置（谨慎）

`GET /nginx-conf` / `PUT /nginx-conf` / `POST /nginx-conf/validate` /
`POST /nginx-conf/reload`，文件名白名单 `http_inc.conf` / `server_inc.conf` /
`stream_inc.conf`（用户自维护的外置 include）。配置助手仅在用户明确要求时操作：
先 validate，再 PUT，最后 reload；失败保留 `.bak`。

## 9. 错误处理惯例

- 401：Key 无效或来源不在白名单 → 停止，提示管理员检查 `AUTHZ_API_KEY_ALLOWED_IPS`
  或轮换 Key；绝不回退到用户名密码登录（会触发 账户+IP 锁定：5 次/30 分钟）。
- 403：角色或策略拒绝 → 停止，按用户意图补策略而不是提权。
- 409：域名重复/内置菜单保护 → 换前缀或改用已有条目。
- 422：按 message 修参；常见：角色名非法（viewer）、端口越界、正则非法、
  改写安全头、header 名不可覆盖。

完整契约与更多字段见仓库 `docs/core-api.md`（本文件是它的操作速查，冲突时以
core-api.md 与代码为准）。

## 10. 实例环境配置（.env，需重启容器生效）

有些配置不在数据库里，而在部署目录 `.env`（本机 `/data/app/.env`）。修改后
`docker compose up -d` 重建生效。语义全表见仓库 `design.md` §4.1，常用项：

| 任务 | 变量 |
|---|---|
| 多域名共享登录 | `AUTHZ_COOKIE_DOMAIN=.a.com,.b.com` + 共享 Redis 会话（`AUTHZ_SESSION_SHARED`、`AUTHZ_SESSION_REDIS_*`、`AUTHZ_SESSION_SIGNING_KEY`，仅一个实例 read-write） |
| Agent 免登录 Key | `AUTHZ_API_KEY`（32-256 字符）+ `AUTHZ_API_KEY_ROLE` + `AUTHZ_API_KEY_ALLOWED_IPS`（IP/CIDR 逗号分隔，默认 127.0.0.1） |
| 登录防爆破 | `AUTHZ_LOGIN_ATTEMPTS`(5) / `AUTHZ_LOGIN_WINDOW`(1800s) / `AUTHZ_LOGIN_FAIL_DELAY_MS`(1000)，按「账户名+IP」锁定 |
| 端口发现 | `AUTHZ_DISCOVERY_PORTS`（容器监听表不可见时追加）、`AUTHZ_DISCOVERY_TTL` |
| HTTP 入口策略 | `AUTHZ_HTTP_MODE`=redirect/disabled/serve |
| Cookie 安全 | `AUTHZ_COOKIE_SECURE`（HTTPS 入口必须 true；决定 SameSite=None/Lax） |

注意：数据库类配置（用户/策略/绑定/菜单/Key）走 API 即时生效，不要改库；
环境类配置走 .env，两层不要混。

## 11. 其他端点与语义速查

- `GET /_authz/app/guest.html?json=1` — guest 角色诊断页（回显请求头/来源/代理链，
  服务端转义+脱敏）；guest Key 只能访问它和 `GET /session`，admin 也可看。
- `GET /api/files?path=` — 只读列 `AUTHZ_FILES_ROOT` 目录（登录或非 guest Key）。
- `PUT /api/me/password` — 改自己密码（session_only；改完其他会话全部下线）。
- `PUT /api/users/:id/password` — admin 重置他人密码。
- `PATCH/DELETE /api/remote-users/:provider` — 管理远程身份记录（角色覆盖/删除，
  `{provider, subject, ...}`，删除后下次登录按新身份重建）。
- nginx-conf 编辑：文件白名单 `http_inc.conf`/`server_inc.conf`/`stream_inc.conf`，
  单文件 256KB 上限；validate/PUT 都是 staging + `openresty -t` 通过才落盘；
  reload 失败看返回 message；模板目录只读时 API 会标 `persistent:false`。
- 登录页：`GET /_authz/login?next=<path>`；`next` 只接受以 `/` 开头的本站路径。
