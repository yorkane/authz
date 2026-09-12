# Authz Gateway 核心 API（Agent 使用手册）

本文档描述稳定的 Authz Gateway v1 控制面 API，以及应用使用 API Key 请求受保护的 HTTP/HTTPS 服务的方式。
API 根路径固定为 `/_authz/api`。

## 1. 通用协议

- 成功响应：`{"data": ...}`
- 失败响应：`{"error":{"code":"...","message":"..."}}`
- JSON 响应类型：`application/json; charset=UTF-8`
- JSON 修改请求必须发送 `Content-Type: application/json`
- 常用状态码：`200` 成功、`201` 已创建、`400` JSON 无效、`401` 未认证或 Key 无效、`403` 无权限或
  CSRF 失败、`404` 资源不存在、`409` 冲突、`422` 参数校验失败。

所有控制面请求都通过 `/_authz/` 统一入口访问；登录页为 `/_authz/login`，管理端为 `/_authz/apps/`。

## 2. 两种认证方式

### 2.1 管理员浏览器会话

管理员通过 `POST /_authz/login` 登录，Cookie 名为 `authz_session`。先读取 session API 中的 `csrf`，再在
所有修改请求中发送 `X-CSRF-Token`。

```bash
curl -sS -c cookie.txt -X POST "${GATEWAY}/_authz/login" \
  --data-urlencode "username=${ADMIN_USER}" \
  --data-urlencode "password=${ADMIN_PASSWORD}"

CSRF=$(curl -sS -b cookie.txt "${GATEWAY}/_authz/api/session" | jq -r '.data.csrf')
```

### 2.2 应用 API Key

应用在每次请求中提交（旧 `x-authz-key` 已合并移除）：

```http
x-role-key: ak_<64 个小写十六进制字符>
```

`x-role-key` 是角色 Key 专用头，只接受数据库 Key；`x-api-key` 也接受数据库 Key（并额外接受
2.4 的实例级 Key）。两个头同时呈现时以 `x-role-key` 为准。
API Key 的主体是 `api-key:<id>`，创建或修改时可绑定一个固定目录角色：`admin`、`staff`、`user`、
`guest`、`api`，新建默认为 `guest`（仅可访问 `/_authz/guest` 诊断页）。
旧目录里的 `viewer` 已退役，由 `guest` 接管：新建时提交 `viewer` 会被拒绝（422），
存量数据由迁移 `18:retire_viewer_role_into_guest` 就地改写。
控制面权限与同角色用户一致，代理权限由对应的 `role:<role>` Casbin 策略决定。
`role:admin` 和 `role:api` 默认可访问所有已解析代理目标，管理员可用 deny 策略继续收紧。

```bash
curl -sS -H "x-api-key: ${AUTHZ_KEY}" \
  "https://2077-m.ws.example.com:99/api/status"
```

网关不会把 `x-api-key` 转发到上游。上游只会收到安全身份头：

```text
X-Authz-User: <API Key 名称>
X-Authz-Source: api-key
X-Authz-Identity: api-key:<id>
```

如果请求显式携带无效或已禁用的 `x-api-key`，网关返回 `401 invalid_api_key`，不会回退到同时携带的
浏览器 Cookie。

### 2.3 本机自动化凭证（原 Agent 专用 API Key，已移除）

`AUTHZ_AGENT_API_KEY` 环境变量与自动 seed 的 `agent-default` Key 已移除。
本机自动化的等价替代：实例级 `AUTHZ_API_KEY`（配合 `AUTHZ_API_KEY_ALLOWED_IPS=127.0.0.1`
默认仅回环）或管理界面创建 `loopback_only=1` 的数据库 Key；管理界面创建的普通 API Key
不受 loopback 限制，如需限制来源请用上述两种方式。

### 2.4 实例级预置 API Key（`x-api-key`，免登录）

设置环境变量 `AUTHZ_API_KEY`（32-256 字符，不含空格与控制字符，例如 `openssl rand -hex 32`）后，
网关接受用 `x-api-key` 请求头提交的这把 Key，**免登录**直接访问三类入口：

- 控制面 API（`/_authz/api/*`，写接口免 CSRF）；
- 管理页面与静态资源（`/_authz/apps/*`、`/_authz/files/*`）——Agent 不必再手动登录取 Cookie，
  Playwright 用 `setExtraHTTPHeaders`、curl 用 `-H` 给每个请求带上该头即可；
- 代理入口（域名/端口绑定的目标服务）。

```bash
curl -sS -H "x-api-key: $AUTHZ_API_KEY" http://127.0.0.1:6080/_authz/api/session
```

配置与语义：

| 变量 | 默认 | 说明 |
|---|---|---|
| `AUTHZ_API_KEY` | 空 | Key 本体；留空即完全关闭该认证路径 |
| `AUTHZ_API_KEY_ROLE` | `admin` | 角色（admin/staff/user/guest/api），权限走同角色 Casbin 策略；旧值 `viewer` 在加载期映射为 `guest` 并告警 |
| `AUTHZ_API_KEY_ALLOWED_IPS` | `127.0.0.1` | 来源白名单：逗号分隔的 IP 或 CIDR（如 `127.0.0.1,10.0.0.0/8`），只有 `remote_addr` 命中者可用 Key |

- 主体固定为 `api-key:0`，上游收到 `X-Authz-Identity: api-key:0`；
- 不写入数据库，因此不受管理界面的禁用/删除影响；轮换方式是改环境变量并**重建**容器；
- 网关不签发也不读取会话 Cookie：只要呈现了凭证头（`x-api-key` 或 `x-role-key`）就只看 Key，
  Key 无效直接 401，绝不回退到同时携带的浏览器 Cookie；实例级 Key 在 `x-role-key` 上永远无效；
- 凭证头被网关剥离，绝不转发给上游；绑定级「改写请求」也禁止设置这些头；
- 配置非法（Key 过短/含空白、角色不在目录内、白名单条目非法）时容器**启动即失败**，不会静默降级成未启用；
- 它是实例级万能钥匙：来源边界就是 `AUTHZ_API_KEY_ALLOWED_IPS`，默认只信 `127.0.0.1`；
  跨机接入时把对端出口 IP 逐个列出（谨慎使用宽 CIDR），并考虑用 `AUTHZ_API_KEY_ROLE=guest` 收窄；
  泄漏等同于管理员凭据泄漏；
- 匹配对象是 TCP `remote_addr`：网关前有反向代理时，代理所在 IP 就是白名单要收的来源；
  `X-Forwarded-For` 不参与匹配（可伪造）。

## 3. 权限矩阵

| 接口能力 | `guest` | 普通用户/Key | `admin` 用户/Key | `api` Key |
|---|---:|---:|---:|---:|
| 打开 `/_authz/guest` 诊断页 | 是 | 否 | 是 | 否 |
| 读取自身身份和应用入口 | 否 | 是 | 是 | 是 |
| 浏览器注销/修改自己的密码 | 仅用户会话 | 仅用户会话 | 否 |
| 新建域名与端口绑定 | 否 | 是 | 是 |
| 修改或删除绑定 | 否 | 是 | 否 |
| 管理用户、远程身份和密码 | 否 | 是 | 否 |
| 读取/修改 Casbin 策略 | 否 | 是 | 否 |
| 创建、修改、删除 API Key | 否 | 是 | 否 |
| 请求受保护的代理目标 | 按绑定角色策略 | 按 `admin` 策略 | 按 `api` 策略 |

用户会话的修改请求必须发送 CSRF；API Key 请求不使用 CSRF。`api` 是服务主体专用角色，不能分配给
本地或远程用户；`guest` 反过来只能分配给用户与 Key，且被 guard 统一拒绝全部控制面 API。角色目录
固定，不提供动态新建角色 API。

## 3.1 Guest 诊断页（`/_authz/guest`）

回显**当次请求**在服务端看到的完整信息，用来自检接入链路（例如确认反向代理是否透传了真实客户端
地址、上游收到了哪些头）。`guest` 角色的 Key 或登录会话即可访问，`admin` 也可用于核对。
`guest` 的能力面只有两条：本页面，以及只回显调用者自身的 `GET /api/session`；其余控制面 API、管理页面与文件浏览一律拒绝。

```bash
curl -sS -H "x-api-key: $GUEST_KEY" "https://gateway.example/_authz/guest"
curl -sS -H "x-api-key: $GUEST_KEY" "https://gateway.example/_authz/guest?json=1"
```

- 页面为服务端渲染；`?json=1` 返回同一数据的 JSON 形态（`{data: {ip, proxy, request, headers}}`）。
- 展示内容：TCP `remote_addr`、网关解析出的真实客户端、`X-Forwarded-For` 代理链（首项 = 客户端原始
  IP，末项 = 上一跳代理）、`Forwarded`/`X-Forwarded-*`/`Via`、请求行，以及全部请求头。
 - 调试需求：所有请求头（含 `Cookie`/`Authorization`/`x-api-key` 等凭据类头）**明文完整回显**，
   因此该入口必须始终保持 guest/admin 角色门禁，不得放开给匿名访问。
- 回显内容是天然反射面：所有字段逐条 HTML 转义，响应 `Cache-Control: no-store`（诊断内容与当次
  请求绑定，缓存等于跨请求泄露）。这些行为在回归里是固定断言，改动前先看测试。
- 浏览器直接访问且未登录时会跳 `/_authz/login`；呈现了无效 `x-api-key` 则直接 401，不回退 Cookie。
- guest 拿不到除上述两条以外的任何控制面 API、管理页面与文件浏览：访问 /_authz/apps/* 会被引导到登录页（机器 Key）或本页（浏览器会话）。例外端点由路由上的 self_service 标记显式声明，新增端点默认不在 guest 的能力面内。

## 4. API Key 管理（`admin` 角色）

### `GET /api-keys`

列出 Key 元数据。响应永远不包含明文 token 或 `token_hash`。

### `POST /api-keys`

创建 Key。可使用 admin Cookie + CSRF，也可直接使用 `admin` API Key；机器请求不发送 CSRF。

```json
{"name":"deployment-agent","role":"staff"}
```

名称为 2–64 位 ASCII 字母、数字、点、下划线或连字符。`role` 可为
`admin/staff/user/guest/api`，省略时默认 `guest`（最小权限：只能访问
`/_authz/guest` 请求诊断页，见「Guest 诊断页」一节）。需要调用控制面 API 时，
再改成 `api` 或 `admin`。

创建响应中的 `token` 只出现一次；同时返回 `token_prefix`（明文前 11 字符，形如 `ak_1a2b3c4d`）
作为指纹，供列表页识别「这是哪一把」。指纹不是机密，也无法反推出密钥：
库里除它以外只存 SHA-256 摘要。

```json
{
  "data": {
    "id": 12,
    "name": "deployment-agent",
    "role": "staff",
    "token_prefix": "ak_1a2b3c4d",
    "enabled": 1,
    "created_at": 1787580000,
    "updated_at": 1787580000,
    "token": "<仅本次返回；立即保存到密钥管理系统>"
  }
}
```

SQLite 只保存 SHA-256 摘要，丢失明文后不能恢复。此时有两种收尾方式：
`POST /api-keys/:id/rotate` 轮换出新密钥（名称与角色不变，旧值当场失效，
新明文同样只在这一次响应里出现，需要 CSRF），或直接删除旧 Key 再创建新 Key。

### `POST /api-keys/:id/rotate`

轮换密钥。请求体为空，响应与创建同形（含一次性 `token` 与新 `token_prefix`）。
轮换立即失效旧明文，因此调用方必须在同一变更窗口内更新它持有的 Key。

### `PATCH /api-keys/:id`

允许字段：

```json
{"name":"deployment-agent-2","role":"guest","enabled":false}
```

角色、名称或启用状态修改后立即作用于控制面与代理授权缓存。

### `DELETE /api-keys/:id`

删除后立即失效，不能恢复。

## 5. 应用/域名绑定 API

### `GET /applications`

会话用户读取已启用绑定与发现到的本机 HTTP 服务。显式绑定除 `id`、`domain`、`target_ip`、`port`、
`menu_name`、`note`、`enabled`、`websocket` 外，还返回下表中的绑定级代理字段；主动探测项还包含 `source`。
应用列表同时返回 `label` 与 `binding`：显式绑定的 `label` 为 `menu_name`（未配置时回退为域名），
`binding` 为 `true`，`note` 保留绑定备注；主动探测项的 `label` 为 `local:<port>`，`binding` 为 `false`。
Admin 左侧菜单悬浮在显式绑定名称上时显示 `note`，不会把主动探测项的连接信息当作绑定备注。

### `POST /applications`

`admin` 用户/Key 或 `api` Key 均可调用。API Key 不使用 CSRF。

```bash
curl -sS -X POST "${GATEWAY}/_authz/api/applications" \
  -H "x-api-key: ${AUTHZ_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"domain":"code","target_ip":"192.168.1.20","port":2077,"menu_name":"Code Server","enabled":true}'
```

请求字段：

| 字段 | 必填 | 说明 |
|---|---:|---|
| `domain` | 是 | 填最后一级前缀（如 `code`），入口域名按请求 Host 动态拼接；API 也接受完整精确域名（非泛域场景） |
| `target_ip` | 否 | 上游服务的 IPv4 或 IPv6 地址，默认 `127.0.0.1`；不接受 URL、协议或主机名 |
| `port` | 是 | 上游服务端口，必须位于配置的允许范围 |
| `menu_name` | 否 | 左侧菜单显示名称，最多 128 字符 |
| `note` | 否 | 备注，最多 256 字符 |
| `enabled` | 否 | 默认 `true` |
| `websocket` | 否 | 兼容字段；当前所有已解析目标默认支持 WebSocket 升级 |
| `upstream_host` | 否 | 发送给上游的 `Host`；留空时使用外部请求 Host，模拟本机时使用目标 IP + 端口 |
| `forwarded_host` | 否 | `X-Forwarded-Host`；留空时跟随有效上游 Host |
| `forwarded_proto` | 否 | `""`（自动）、`http` 或 `https` |
| `forwarded_port` | 否 | `0`/留空表示自动，否则为 1-65535 |
| `origin_mode` | 否 | `auto`（默认）、`preserve`、`rewrite`、`remove` 或 `custom` |
| `custom_origin` | 否 | `origin_mode=custom` 时必填，只接受无 path/query 的 `http(s)://authority` |
| `simulate_local` | 否 | 默认 `false`；启用本机 HTTP 请求头模拟 |
| `local_ip` | 否 | 模拟来源 IP，默认 `127.0.0.1`，也可使用网关局域网 IPv4/IPv6 |
| `request_rewrite` | 否 | 请求改写配置（对象或 JSON 字符串）：`enabled`、`headers`、`remove_headers`、`body`、`body_base64`、`content_type`、`rewrites`；可改写上表各代理字段默认算出的请求头（Host/Cookie/Origin/X-Forwarded-* 等同样可改写，改写值即上游看到的最终值）；留空或 `null` 表示不改写，保存后返回规范化 JSON |
| `upstream_scheme` | 否 | 上游协议，`http`（默认）或 `https` |
| `upstream_ssl_verify` | 否 | HTTPS 上游是否校验证书，默认 `true`；设为 `false` 忽略证书校验，仅建议用于受控内网或自签名证书 |
| `upstream_path` | 否 | 上游路径改写，默认空值表示保留请求路径；例如 `/v1/index.html` 会把任意请求转发到 `/v1/index.html`，查询参数原样保留；不接受 query、fragment、连续斜杠或 `..` |
| `response_rewrite` | 否 | 响应改写配置（对象或 JSON 字符串，语义参考 APISIX `response-rewrite`）：`enabled`、`status`、`headers`、`remove_headers`、`body`、`body_base64`、`content_type`、`rewrites`；留空或 `null` 表示不改写，保存后返回规范化 JSON |

前缀按约定原样存库（`domain: "code"` 保存 `code`）；代理与菜单在运行时按当前请求 Host 拼出
`<前缀>-<节点>.<请求域>`（如经 `a-241.ai-t.wtvdev.com` 访问时解析 `code-241.ai-t.wtvdev.com`，
经 `a-241.ws.gatepro.cn` 访问时解析 `code-241.ws.gatepro.cn`）。域名必须唯一，重复返回 `409`。

### `PATCH /applications/:id`

仅 `admin` 角色。可修改创建接口中的全部字段。

显式绑定按 `upstream_scheme` 代理到 `http(s)://<target_ip>:<port>`；HTTPS 上游默认校验证书，只有绑定显式设置
-`upstream_ssl_verify=false` 时才进入忽略校验的内部代理路径。数字前缀免配置入口仍固定使用
-`http://127.0.0.1:<port>`，并默认启用模拟本机请求头；主动发现也只扫描本机 `127.0.0.1`。
-客户端访问网关的 HTTP/HTTPS 协议与上游绑定协议相互独立。

`target_ip` 不改变现有 Casbin 对象格式，授权仍按 `/<port><path>` 判断；不同 IP 上相同端口的绑定共享同一端口策略。
`admin`/`api` Key 能创建指向内网地址的绑定，应只发放给允许访问目标网络的可信应用。

上游路径改写只改变发往上游的 URI，不改变 Casbin 授权对象；权限仍按客户端请求的原始路径检查。改写路径为空时保留原路径；填写后使用固定目标路径，查询参数仍原样保留。

代理头字段拒绝 CR/LF、URL path 和非法 authority，避免 Header 注入。`simulate_local` 会把默认 Host/Origin
指向 `http://<target_ip>:<port>`，把 `X-Real-IP` 与 `X-Forwarded-For` 改为 `local_ip`，并移除客户端
`Forwarded`；显式填写的 Host/Forwarded/Origin 配置优先。它不会伪造 TCP peer，远端上游实际看到的
TCP 来源仍是网关主机地址。
`request_rewrite` 改写发往上游的请求：`headers`（对象，值 `null` = 删除）与 `remove_headers`
覆盖/删除请求头，`body`/`body_base64`/`content_type` 整体替换正文，`rewrites` 做正文过滤
（格式同 `response_rewrite`，两者互斥；仅文本类、Content-Length 明确的非 GET/HEAD 请求生效）。
Host、Cookie、Origin、Forwarded、X-Forwarded-*、X-Real-IP、X-Authz-User/Source/Identity 等
网关托管头可以改写：网关把改写值写进 proxy_set_header 引用的同名变量，上游看到的就是
改写后的最终值（改写优先于网关默认值；删除托管头则该头不发送）。仍不可改写（保存即 422）：
分帧与 hop-by-hop 头（Content-Length、Transfer-Encoding、Connection、Upgrade、TE、Trailer、
Keep-Alive）、网关凭据头（X-Authz-Key、X-API-Key、X-Role-Key）、其余 X-Authz-* 与 Proxy-* 前缀。
名称/条数/长度限制与响应改写一致（名称 ≤128、值 ≤2048、≤32 条、整体 JSON ≤131072 字节）。

`response_rewrite` 改写的是返回给客户端的上游响应，字段语义：

| 字段 | 说明 |
|---|---|
| `enabled` | 默认 `true`；`false` 时保留配置但不生效 |
| `status` | 覆盖响应状态码，200-999；`0`/留空保持上游状态 |
| `headers` | 对象，覆盖响应头；值置 `null` 等价于删除该头 |
| `remove_headers` | 数组，显式删除响应头 |
| `body` | 整体替换响应正文（文本或 JSON 对象） |
| `body_base64` | `true` 时 `body` 按 Base64 解码后返回（二进制内容） |
| `content_type` | 替换正文时写回的 Content-Type，留空保持上游类型 |
| `rewrites` | 正文过滤规则数组：`{source, target, regex}`；`source` 以 `~` 开头或 `regex=true` 时按 PCRE 处理，替换支持 `$1` 捕获组 |

约束：`body` 与 `rewrites` 互斥；未知字段、非法正则（保存时做 PCRE 编译校验）、`status` 越界、
条数/长度超限（≤16 条规则、正则 ≤512、替换 ≤4096、正文 ≤65536、整体 JSON ≤131072 字节）均返回 `422`。
`Set-Cookie`、`Content-Length`/`Transfer-Encoding` 等分帧与 hop-by-hop 头、`X-Authz-*`、`X-Forwarded-*`、
`Proxy-*` 以及 `X-Frame-Options`、`Content-Security-Policy`、`Strict-Transport-Security`、
`X-Content-Type-Options`、`Permissions-Policy` 一律不可改写或删除（校验层拒绝，运行期再拦一道）。
改写只在上游返回 200 的 GET 响应上生效：HEAD、WebSocket、已压缩、含 `Content-Range`、
非文本 Content-Type（过滤模式）以及超过 1MB 缓冲上限的响应会跳过，
响应头 `X-Authz-Rewrite: skipped=<status|head|websocket|encoded|range|type>` 标明原因。

### `DELETE /applications/:id`

仅 `admin` 角色，删除绑定。

## 6. 其他核心 API

| Method | Path | 身份 | 用途 |
|---|---|---|---|
| `GET` | `/session` | 会话或 Key | 当前身份、来源、角色、admin 与时间信息；用户会话另含 CSRF |
| `DELETE` | `/session` | 会话 + CSRF | 退出当前会话 |
| `GET` | `/users` | admin 用户/Key | 本地与远程身份列表、可分配的人类角色目录 |
| `POST` | `/users` | admin 用户/Key | 创建本地用户；`username/password/roles` |
| `PATCH` | `/users/:id` | admin 用户/Key | 修改本地用户 `roles` 或 `enabled` |
| `DELETE` | `/users/:id` | admin 用户/Key | 删除本地用户 |
| `PUT` | `/users/:id/password` | admin 用户/Key | 重置本地用户密码；`password` |
| `PUT` | `/me/password` | 本地会话 + CSRF | 修改自己的密码并使该用户所有本地 session 失效；`old_password/new_password`，管理端同时提交 `new_password_confirm`（也支持 `newpw_confirm`） |
| `PATCH` | `/remote-users/:provider` | admin 用户/Key | 按 body 中 `subject` 修改远程身份角色/启用状态 |
| `DELETE` | `/remote-users/:provider` | admin 用户/Key | 按 body 中 `subject` 删除远程身份快照 |
| `GET` | `/authorization` | admin 用户/Key | 绑定、策略、策略主体、角色与 HTTP 方法目录 |
| `POST` | `/policies` | admin 用户/Key | 新建 Casbin `p` 或人类用户的 `g` 规则 |
| `PATCH` | `/policies/:id` | admin 用户/Key | 完整更新已有 Casbin `p` 或 `g` 规则 |
| `DELETE` | `/policies/:id` | admin 用户/Key | 删除策略 |

表中 admin 用户执行修改时仍需 CSRF，admin Key 不需要。`DELETE /session` 和 `PUT /me/password` 是
浏览器用户会话专用接口；admin Key 可通过 `/users/:id/password` 管理本地用户密码。

策略对象格式为 `/<port><path-pattern>`，例如 `/2077/*` 或 `/2077/api/*`；管理端先选择绑定端口，
再单独编辑路径并组合成该对象。动作支持标准 HTTP 方法或 `*`。`p.v0` 可为
`user:<source>:<username>` 或 `role:<role>`。`deny` 优先于 `allow`。

管理端从绑定创建策略时还会提交 `binding_id`。服务端验证该绑定存在且端口与 `v1` 一致，但 Casbin
仍按兼容的端口 + 路径对象授权。`GET /authorization` 为每条 `p` 策略补充 `object_kind`、
`object_port`、`object_path` 和 `binding_matches`，供调用方展示菜单名、域名、目标 IP、端口以及
未绑定/同端口多绑定状态。`binding_matches` 多于一条意味着该策略会同时作用于这些同端口绑定。
`PATCH /policies/:id` 使用与新建相同的完整字段和校验规则；校验失败不会覆盖原策略。

## 7. Agent 安全要求

- 不在日志、终端输出、任务结果或错误信息中打印 API Key。
- Key 放入进程环境变量或密钥管理系统，不提交到 `.env` 模板、Git 或普通配置文件。
- 每个应用/Agent 使用独立 Key，名称可追踪用途；停用优先于共享或复用 Key。
- 仅把 Key 发给受信任的网关 Origin；不要把 Key 放进 URL、query、Cookie 或请求 body。
- 自动化遇到 `401` 时停止并请求管理员轮换/启用 Key；不要尝试回退用户密码。
- 自动化遇到 `403` 时视为角色或策略拒绝，不要尝试越权；需要完整管理能力时由管理员签发独立
  `admin` Key，而不是复用用户密码。
