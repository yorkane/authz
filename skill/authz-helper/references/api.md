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

第三方使用方式（把它写进给用户的说明里）：

```bash
curl -H "x-role-key: ak_xxxx" https://<入口域名>/_authz/app/guest.html   # guest 自检
curl -H "x-api-key: ak_xxxx" "https://<绑定域名>:6443/api/..."          # 代理入口
```

网关不会把 Key 头转发给上游；上游只收到 `X-Authz-User` / `X-Authz-Source` /
`X-Authz-Identity`。

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

只想改 Host/转发头/Origin 时用结构字段（`upstream_host` 等），不要用 overrides。

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
