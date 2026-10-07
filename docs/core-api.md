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
| 打开 `/_authz/guest` 诊断页（匿名即可） | 是 | 否 | 是 | 否 |
| 读取自身身份和应用入口 | 否 | 是 | 是 | 是 |
| 浏览器注销/修改自己的密码 | 仅用户会话 | 仅用户会话 | 否 |
| 新建域名与端口绑定 | 否 | 是 | 是 |
| 修改或删除绑定 | 否 | 是 | 否 |
| 管理用户、远程身份和密码 | 否 | 是 | 否 |
| 读取/修改 Casbin 策略 | 否 | 是 | 否 |
| 创建、修改、删除 API Key | 否 | 是 | 否 |
| 请求受保护的代理目标 | 匿名同样按 `role:guest` 策略 | 按 `admin` 策略 | 按 `api` 策略 |

用户会话的修改请求必须发送 CSRF；API Key 请求不使用 CSRF。`api` 是服务主体专用角色，不能分配给
本地或远程用户；`guest` 反过来只能分配给用户与 Key，且被 guard 统一拒绝全部控制面 API。角色目录
固定，不提供动态新建角色 API。`guest` 就是**匿名**主体：代理层中无任何凭证的请求以
`role:guest` 参与授权（默认仍拒绝，管理员显式放行即对匿名开放；呈现无效 Key 一律 401，
绝不回退匿名）。

## 3.1 Guest 诊断页（`/_authz/guest`）

回显**当次请求**在服务端看到的完整信息，用来自检接入链路（例如确认反向代理是否透传了真实客户端
地址、上游收到了哪些头）。**guest 就是匿名用户**：无需登录、无需 Key，任何访客直接打开；
`guest` 角色的 Key / 登录会话与 `admin` 同样可用（用于核对）。
`guest` 的能力面只有两条：本页面，以及只回显调用者自身的 `GET /api/session`（后者的 Key 变体
仍需 guest Key）；其余控制面 API、管理页面与文件浏览一律拒绝。

```bash
curl -sS -H "x-api-key: $GUEST_KEY" "https://gateway.example/_authz/guest"
curl -sS -H "x-api-key: $GUEST_KEY" "https://gateway.example/_authz/guest?json=1"
```

- 页面为服务端渲染；`?json=1` 返回同一数据的 JSON 形态（`{data: {ip, proxy, request, headers}}`）。
- 展示内容：TCP `remote_addr`、网关解析出的真实客户端、`X-Forwarded-For` 代理链（首项 = 客户端原始
  IP，末项 = 上一跳代理）、`Forwarded`/`X-Forwarded-*`/`Via`、请求行，以及全部请求头。
- 调试需求：所有请求头（含 `Cookie`/`Authorization`/`x-api-key` 等凭据类头）**明文完整回显**。
  这面向的是"请求者看自己的凭证"：跨站 iframe 里渲染的也是访客自己的头，第三方脚本受同源
  策略限制读不到帧内容，因此匿名开放不构成跨用户泄露面。
- 回显内容是天然反射面：所有字段逐条 HTML 转义，响应 `Cache-Control: no-store`（诊断内容与当次
  请求绑定，缓存等于跨请求泄露）。这些行为在回归里是固定断言，改动前先看测试。
- 未登录/无凭证访客直接放行；已登录的非 guest/admin 会话会收到 403（退出后匿名使用）；
  呈现了无效 `x-api-key` 则直接 401，绝不回退 Cookie 或匿名身份。
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
| `open_in_new` | 否 | 默认 `false`；仅影响管理端左侧菜单：点击该绑定直接新标签页打开（应用自检 iframe 嵌入时规避检测），不参与代理与授权 |
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
| `conditions` | 条件匹配（对齐 APISIX route vars）：`{logic: "all"|"any", match: [{field, name?, op, value?, negate?}]}`，也可直接给裸数组（等价 `logic: "all"`，`op` 留空默认 `regex`）。整条改写（status/headers/body/rewrites）只在条件命中时生效，不命中则完全不介入，也不会出现 `X-Authz-Rewrite`。`field` 取 `uri`（对含查询串的 `$request_uri`）、`request_header`、`response_header`、`content_type`（仅媒体类型本体，忽略 `; charset=...`）、`status`（上游状态码字符串，可用 contains/regex 做区段匹配）；`op` 取 `equals`/`contains`/`regex`/`exists`/`missing`（后两个仅 Header 可用）；`negate: true` 反转该条；`regex` 值支持 `/re/` 包裹（保存时剥掉斜杠），多条件用 `logic` 做 AND/OR 联动，≤16 条 |

约束：`body` 与 `rewrites` 互斥；未知字段、非法正则（保存时做 PCRE 编译校验，条件里的正则同样校验）、`status` 越界、
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

策略对象格式为 `/<port><path-pattern>`，例如 `/2077/*` 或 `/2077/api/*`；管理端从下拉选择绑定或本机 HTTP 服务
（也可输入 host:端口 / 端口 / 域名前缀），端口框自动回填选中服务的端口且可改写——改端口即换目标，
端口与所选绑定不一致时不再提交 `binding_id`，落成 unbound 端口对象；路径单独编辑后组合成该对象。动作支持标准 HTTP 方法或 `*`。`p.v0` 可为
`user:<source>:<username>` 或 `role:<role>`。`deny` 优先于 `allow`。

管理端从绑定创建策略时还会提交 `binding_id`。服务端验证该绑定存在且端口与 `v1` 一致，但 Casbin
仍按兼容的端口 + 路径对象授权。`GET /authorization` 为每条 `p` 策略补充 `object_kind`、
`object_port`、`object_path` 和 `binding_matches`，供调用方展示菜单名、域名、目标 IP、端口以及
未绑定/同端口多绑定状态。`binding_matches` 多于一条意味着该策略会同时作用于这些同端口绑定。
`PATCH /policies/:id` 使用与新建相同的完整字段和校验规则；校验失败不会覆盖原策略。

### 6.1 文件管理与对象存储的写接口（`/api/files*`、`/api/s3*`）

两端写接口（upload / mkdir / rename / remove）的身份要求相同：
**admin 浏览器会话（修改请求需 `X-CSRF-Token`）或 `admin` 角色机器 Key**
（`x-api-key`，也可用 `x-role-key`；机器 Key 天然免 CSRF，见 `api/guard.lua`）。
机器 Key 的来源边界不变：实例级 Key 受 `AUTHZ_API_KEY_ALLOWED_IPS` 约束，
数据库 Key 受自身 `loopback_only` 约束；非 admin 角色的 Key 一律 403。
这两个端点组**不要求会话**，Agent 可以免登录直连。

#### 重命名与跨目录移动（可选 `new_path`）

`PUT /_authz/api/files/rename` 与 `PUT /_authz/api/s3/rename` 支持可选的 `new_path`：
**目标目录**，语义与该接口的 `path` 完全一致（files 端相对内容根 `AUTHZ_FILES_ROOT`，
s3 端相对桶根）。**字段不传或传 JSON `null` = 原地改名，行为与旧版本逐条相同**；
空串 = 内容根 / 桶根。跨目录移动与重命名共用同一端点，没有新增路由。

```json
{ "path": "src/dir", "name": "a.txt", "new_name": "b.txt", "new_path": "dst/dir" }
```

- `new_name` 仍然是单段叶子名，禁止任何路径分隔符（校验未放松）：换目录只能靠 `new_path`。
- 改名与移动可以在一次调用里同时生效。
- `new_name` 与 `name` 相同、`new_path` 指向另一个目录 = 合法的**纯移动**，
  不再判「新旧名称相同」（只保留「同目录且同名」这一种空操作拒绝）。

成功响应的 `data`：

| 端 | 原地改名（不带 `new_path`） | 跨目录（带 `new_path`） |
|---|---|---|
| files | `{ "message": "已重命名", "name": "<new_name>" }` | `{ "message": "已移动", "name": "<new_name>", "moved": true, "new_path": "<规范化后的目标目录>" }` |
| s3 | `{ "renamed": "<name>", "new_name": "<new_name>" }`（目录另带 `objects` = 移动的对象数） | 上述字段外加 `"moved": true, "new_path": "<new_path>"`（目录仍带 `objects`） |

不带 `new_path` 时响应形状与旧版完全一致（不会多出 `moved` / `new_path`），
调用方可用 `moved` 字段是否存在区分「移动」与「纯改名」。

#### 错误码矩阵

| 状态码 | files 端 | s3 端 |
|---|---|---|
`400` | `new_path` 非法（含 `..`、控制字符）；路径段不是目录；源条目是符号链接 | `new_path` 非法 → `invalid_path`；`name`/`new_name` 非法 → `invalid_name`；源 key 与目标 key 完全相同 → 「新旧名称相同」 |
`403` | 非 admin 身份 → `forbidden` | 非 admin → `forbidden`；**源 key 与目标 key 任一不在 `AUTHZ_S3_WRITABLE_PATHS` 范围内 → `s3_read_only`** |
`404` | 源目录或 `new_path` 目录不存在；源条目不存在 | 源对象与同名前缀都不存在 |
`409` | 目标名称已存在 | 目标 key 已存在 |
`422` | `name`/`new_name` 含路径分隔符等非法；同目录且同名（空操作）；**把目录移动到它自己的子目录下** | **把前缀移动到它自己的子树下**（目标 key 等于源 key 的目录形态，或以 `key + "/"` 开头） |
`500` | `os.rename` 失败；`FILES_DIR` 只读挂载 | — |
`502` | — | CopyObject 成功但 DeleteObject 失败：消息明确说明当前存在两份 |

两条「自嵌套」限制都是必要的：files 端 `os.rename` 把目录移动进自身子树只会返回裸
`EINVAL`（没有可展示的说明）；s3 端 `copy_prefix` 会把前缀整棵复制进自己的子目录、
造成数据翻倍后才删源。两者都在真正执行前显式拒绝。

#### 越界防护与校验顺序

files 端：源目录与目标目录**各自独立**走 `resolve_dir`（逐级要求真实目录、符号链接一律拒绝、
`..` 直接 400），所以符号链接防护与越界防护在两端同等生效——`new_path` 指向符号链接目录
同样 400。校验顺序：源目录解析 → 目标目录解析 → 名称校验 → 空操作判定 → 源存在性/符号链接 →
自嵌套 → 目标冲突 → `os.rename`。

s3 端：`new_path` 复用与 `path` 同源的 `normalize_prefix`（含 `..`/控制字符 →
`400 invalid_path`），并对**目标 key**（`join(new_path or path, new_name)`）单独再判一次
`item_writable`：只判源 key 就能把范围内的整棵目录挪出范围，或反向写入只读前缀。

### 6.2 多套存储服务配置（`/api/s3-configs`）

一行 = 一套 S3 兼容服务（endpoint + 凭证 + 可写范围 + 过期策略），存在 SQLite
`s3_configs` 表里，对象存储页（`s3.html`）工具栏「配置」按钮进入的配置视图就是这张表（原「系统应用 → 存储配置」菜单入口已在迁移 v27 隐藏，直链页 `/s3-configs.html` 仍可用）。身份要求与 6.1 相同：
admin 会话（写请求带 `X-CSRF-Token`）或 admin 机器 Key（免 CSRF）。

| Method | Path | CSRF | 用途 / 成功响应 |
|---|---|---|---|
| `GET` | `/s3-configs` | — | 列出全部行（含禁用）+ env 回落项；`{"data":{"items":[...]}}` |
| `POST` | `/s3-configs` | 是 | 新建；`201` + `{"data":{"item":{...}}}`；名称重复 `409` |
| `PATCH` | `/s3-configs/:id` | 是 | 局部更新；`{"data":{"item":{...}}}` |
| `PUT` | `/s3-configs/:id/default` | 是 | 设为默认（全表先清后设）；`{"data":{"item":{...}}}` |
| `POST` | `/s3-configs/:id/test` | 是 | 用这套配置列举桶；`{"data":{"ok":true,"buckets":["noco"]}}` |
| `DELETE` | `/s3-configs/:id` | 是 | 删除；`{"data":{"deleted":true}}` |

**优先级（env 只是回落）**：表里存在「启用 + 字段合法」的行时，运行时用表里的配置；
表里一行可用配置都没有时才回落 `AUTHZ_S3_*`。回落项在列表里是
`{"id":0,"name":"env","virtual":true,"is_default":1,"enabled":1}`（仅当 `AUTHZ_S3_ENDPOINT` 已配置时出现；整套未配置时列表只含表里的行，可能为空数组）：**只读**——
`PATCH`/`DELETE` 一律 `422`（消息「由环境变量提供」），`PUT /default` 是 no-op 成功。

**改表即生效，不需要 reload**：行数据经 mlcache（TTL 30s），派生结果在 worker 本地
按 `db_rev` 判活，任何写库都会 bump revision，所以通常下一个请求就切到新配置，
最坏 30 秒。直接改 SQLite 不触发失效（见 `design.md` §6）。

**凭证纪律**：`secret_access_key` 明文存进 SQLite（本仓库首例，SigV4 需要原文参与签名），
因此任何接口只回 `has_secret`（0/1）与 `access_key_id_masked`（AKID 前 4 位 + 掩码），
永不回显密钥原文。`PATCH` 的凭证字段是**空 = 不修改**（不传、空串、JSON `null` 三者同义）。

回显的 item 字段：

| 字段 | 说明 |
|---|---|
| `id` / `name` / `virtual` | `name` 是 `cfg=` 参数可用的引用；`virtual=true` 只属于 env 回落项（`id=0`） |
| `endpoint` / `region` / `allow_http` | endpoint 存归一化回显形态（`scheme://host[:port]`，无尾斜杠）；`allow_http` 只对 `http://` endpoint 有意义，https 落库前被压回 0 |
| `has_secret` / `access_key_id_masked` | 见上面的凭证纪律 |
| `writable_paths` / `writable_roots` / `share_prefix` | 原始白名单字符串 + 派生后的可写根数组 + 默认挂载前缀（`share/<LAN IP>`，显式白名单或探测失败时 `null`） |
| `share_root` / `share_bucket` | 挂载根与挂载桶（`share_bucket` 空 = share 前缀在任意桶生效） |
| `expires_hours` / `use_bucket_lifecycle` | 见 6.3 |
| `default_bucket` | 该服务的默认桶（可空）。当前只落库与回显，对象存储页仍用 `localStorage authz_s3_bucket` 记住上次桶，**尚未消费**这一字段 |
| `local_root` | 该服务配套的本地中转目录，空 = 用全局保存区 `AUTHZ_STORE_DIR`（清理器按行取值）。**可写不可读**：`POST`/`PATCH` 接受它，但回显的 item 里没有这个字段（`api/services/s3_configs.lua` 的 `view()` 白名单不含它） |
| `is_default` / `enabled` / `note` / `created_at` / `updated_at` | 开关与审计 |

创建必填：`name`、`endpoint`、`access_key_id`、`secret_access_key`。取值区间
（`lualib/resty/authz/api/services/s3_configs.lua:27`）：
`expires_hours` 0–8760（管理页表单只放开到 720）。表里的第一行无条件成为默认项。

```bash
AUTHZ=http://127.0.0.1:6080
# 新建一套服务并立刻可用（无需 reload）
curl -sS -H "x-api-key: $AUTHZ_API_KEY" -H 'Content-Type: application/json' \
  -d '{"name":"minio-a","endpoint":"http://10.251.14.70:30080","region":"RegionOne",
       "access_key_id":"<AKID>","secret_access_key":"<SECRET>","allow_http":true,
       "writable_paths":"agent","expires_hours":24}' \
  "$AUTHZ/_authz/api/s3-configs"
# 设为默认 + 连通性测试
curl -sS -X PUT -H "x-api-key: $AUTHZ_API_KEY" -H 'Content-Type: application/json' -d '{}' \
  "$AUTHZ/_authz/api/s3-configs/1/default"
curl -sS -X POST -H "x-api-key: $AUTHZ_API_KEY" -H 'Content-Type: application/json' -d '{}' \
  "$AUTHZ/_authz/api/s3-configs/1/test"
```

**既有 S3 接口新增的选配置入参**：`/_authz/api/s3*` 全部接受 `cfg`（query `?cfg=` 或
JSON body 的 `cfg` 字段），取值 `id` / `cfg:<id>` / `name` / `env`；不传 = 默认项。
点名的配置不存在或已停用 `423`，存在但字段写坏 `502`。字节流
`/_authz/s3/<bucket>/<key>` 同样用 `?cfg=`。`GET /api/s3` 的响应新增
`data.cfg`（本次实际生效的配置摘要）与 `data.configs`（可选配置清单），两者都不含凭证。

要点 env 那套时统一写 `?cfg=env`：`cfg=0` 只在控制面 API 一侧被翻译成 `env`
（`router.lua:292`），字节流出口 `s3_proxy.lua` 直连 `s3_config_store.get(raw)`，
拿到 `0` 会按「点名的配置不存在」回 423。

### 6.3 上传流水与过期清理（`/api/uploads*`）

经网关写入的对象（S3 对象与本地保存区文件）在 `upload_records` 表记一条流水，
构成过期清理队列。为什么要自己记账：S3 官方 bucket lifecycle 只到**天**粒度且异步执行，
做不了小时级过期，所以小时级回收只能靠 DB 记账 + 每小时定时器
（`lualib/resty/authz/maintenance.lua`）。

| Method | Path | CSRF | 用途 / 成功响应 |
|---|---|---|---|
| `GET` | `/uploads?state=&limit=&offset=` | — | `{"data":{"items":[...],"total":n}}`；`state` 取 `active`/`deleted`/`failed`/`skipped`（`expired`、`pending_delete` 被放行但恒 0 行），`limit` 默认 50、上限 500 |
| `POST` | `/uploads/cleanup` | 是 | 立刻跑一轮清理（等价于定时器的一轮）；body 可选 `{"limit":n}`，响应 `{"data":{"scanned","deleted","failed","skipped","orphans","staged","updated"}}` |
| `DELETE` | `/uploads/:id` | 是 | 按记录立刻删对象/本地文件并闭账；`{"data":{"removed":true,"id":n}}`，重复删回 `already:true`，删除失败 `502` + 原因 |

流水字段：`id`、`kind`（`s3` / `local`）、`cfg_id`（NULL = 当时用的是 env 回落配置）、
`bucket`、`key`、`size`、`source`（`upload` = 浏览器会话，`api`/`multipart` = 机器 Key）、
`created_by`、`created_at`、`expires_at`（NULL = 永不过期）、`state`、`last_error`。

过期语义（三个必须记住的点）：

- `expires_hours` 单位是**小时**，`0` = 永不过期（`expires_at` 写 NULL，不入队）；
  `expires_at` 一律**整点对齐**，所以「同一小时写入的一批」在同一小时被删。
- `use_bucket_lifecycle=1` 的配置只记账不删：新流水直接落 `state='skipped'`，
  回收交给桶自己的生命周期规则；但 `DELETE /api/uploads/:id` 这类人工意志照删。
- 记账永不影响上传结果：对象已写成功，账没记上只落一条 WARN 日志，响应仍成功。

```bash
# 手工触发一轮清理
curl -sS -X POST -H "x-api-key: $AUTHZ_API_KEY" -H 'Content-Type: application/json' \
  -d '{"limit":500}' "$AUTHZ/_authz/api/uploads/cleanup"
```

### 6.4 本机临时保存区（`/api/store*`）

给 Agent 的免登录文件落盘/取回接口。定位是**临时交换区**（默认 24 小时后自动删除），
**不是持久存储**：需要长期保存的内容走对象存储（6.2 + `/api/s3*`）。
根目录由 `AUTHZ_STORE_DIR` 决定（容器内默认 `/data/store`，落在 compose 的
`${DATA_DIR}:/data` 卷下，无需额外 volume）；默认 TTL 由 `AUTHZ_STORE_DEFAULT_EXPIRY_HOURS`
决定（24，`0` = 不过期）。

这一组路由**刻意不带 `session_only`**：核心用途就是 Agent 用 `x-api-key` 直传直取。
能力面不变（admin 角色 + Key 来源白名单），写端点仍标 `csrf`，机器 Key 天然免 CSRF。

| Method | Path | CSRF | 用途 / 成功响应 |
|---|---|---|---|
| `GET` | `/store/info` | — | `{"data":{"enabled","store_dir","writable","default_expiry_hours","max_bytes","max_files","message","counts":{"active","deleted","failed","skipped"}}}`；目录不可用不是错误，回 `200` + `enabled:false` |
| `GET` | `/store?path=&raw=1` | — | 单层列目录（省略 `path` = 保存区根）；`{"data":{"items":[{name,type,size,mtime,expires_at,state}],"path","truncated"}}`；`raw=1` 跳过流水关联 |
| `GET` | `/store/stat?path=` | — | 单对象元信息；`{"data":{"name","type","size","mtime","path","url","expires_at","state"}}` |
| `PUT` | `/store?path=&expires_hours=&overwrite=0` | 是 | 写单个对象（`path` 可多级，缺失祖先目录在保存区内逐级创建）；`201` + `{"data":{"path","size","url","expires_at","expires_in","state"}}` |
| `POST` | `/store/upload?path=&expires_hours=&overwrite=1` | 是 | multipart 多文件（表单字段名 `file`）；`201` + `{"data":{"uploaded":[{name,size}],"skipped":[{name,reason}],"path"}}` |
| `DELETE` | `/store?path=&recursive=1` | 是 | 删文件或目录树并闭账；`{"data":{"message","path","removed":{"files","dirs"},"records"}}` |

相对路径一律走 query（`?path=`），不放进 URL 段。`PUT` 的 `overwrite` **默认开**
（Agent 反复保存同一路径是主用途，显式 `overwrite=0`/`false` 才在同名时 `409`）；
`upload` 相反，`overwrite` **默认关**（同名计入 `skipped`，全冲突回 `409`）。
`expires_hours` 不传 = 用默认 TTL，`0` = 永不过期。

限制：单对象 `max_bytes` = 512MB（超限 `413`，nginx 侧 `location ^~ /_authz/` 的
`client_max_body_size 2048m` 是外层硬闸）、单请求 `max_files` = 64（超出计入 `skipped`）、
目录深度 ≤32。路径非法（绝对路径、`.`/`..`、`~`、控制字符、反斜杠，或以 `.upload-`
等暂存保留名前缀开头）→ `400`；非 multipart → `415`；表单里没有 `file` 字段 → `422`；
保存区目录不可用 → `503`。

`url` 是**同源相对**入口（形如 `/_authz/store/<rel>`，逐段转义），配合
`?download=1`（强制下载）与 `?authz_preview=1`（HTML 沙箱预览）、`Range` 请求头可用；
该出口只读（其他方法 `405`），非法/越界/含符号链接/不存在一律 `404`。
取回侧的身份要求与写入侧一致（安全审查 P2 收口）：**admin 机器 Key 或 admin 会话**；
其他角色的 Key、普通登录会话一律 `403`，未登录 `302` 到登录页。store 是 agent 中转区，
不是给人浏览的共享目录（那是 `/files` 与对象存储的职责），取回 URL 又能按路径推算，
所以不向普通用户开放。

```bash
AUTHZ=http://127.0.0.1:6080
# 保存 → 拿回可访问的相对 URL → 取回 → 立即清理（一条链路）
URL=$(curl -sS -X PUT -H "x-api-key: $AUTHZ_API_KEY" \
  --data-binary @report.md "$AUTHZ/_authz/api/store?path=reports/report.md&expires_hours=6" \
  | jq -r .data.url)                       # → /_authz/store/reports/report.md
curl -sS -H "x-api-key: $AUTHZ_API_KEY" "$AUTHZ$URL" -o /tmp/back.md
curl -sS -X DELETE -H "x-api-key: $AUTHZ_API_KEY" \
  "$AUTHZ/_authz/api/store?path=reports/report.md"
# 不想等删除接口，也可以直接催一轮清理
curl -sS -X POST -H "x-api-key: $AUTHZ_API_KEY" -H 'Content-Type: application/json' -d '{}' \
  "$AUTHZ/_authz/api/uploads/cleanup"
```

每个文件都写 `.upload-*` 暂存名再原子改名，中断不会留下半截目标文件；超过 6 小时的
暂存残留由同一个每小时定时器扫掉。

### 6.6 保留前缀域名的文件与对象直取（内容出口，非控制面 API）

这不是控制面 API，而是一条**内容出口**：网关的两个内置应用保留前缀域名（虚拟端口 100/101，
默认开启，部署侧前提见 `deploy.md` §3.6）除了渲染内置应用页面，还能直接吐文件与对象字节。
Agent 可以把它当成一条带鉴权的静态资源链接来用，不需要先进管理壳，也不需要额外的 API Key 角色。
规则是「根路径 = 页面，带子路径 = 字节」：

| 域名形态 | 根路径 | 带子路径的 GET/HEAD |
|---|---|---|
| `file-<节点>.example.com`（虚拟端口 100） | 文件浏览页 | `AUTHZ_FILES_ROOT`（默认容器内 `/files`）下该路径的字节 |
| `s3-<节点>.example.com`（虚拟端口 101） | 对象存储页 | 当前生效那套存储配置的 `default_bucket` 下该 key 的字节 |

```text
https://file-235.example.com/alice/pub/a.txt          # 本机文件
https://s3-235.example.com/share/pub/data/v.mp4       # S3 对象
```

**认证**与代理流量走同一套：浏览器带 `authz_session` Cookie，脚本带 `x-api-key` 请求头
（实例级 Key 或数据库 Key，见 §2.2）。完全不带凭证时以 `role:guest` 参与授权 —— 命中策略就
匿名放行，没命中就 302 到登录页。之所以复用网关那套身份、而不是给内容单开一条匿名通道：
匿名可读的边界必须由管理员显式画，否则保留前缀域名会变成整个内容根的公开镜像。

**授权**：Casbin 的策略对象是 `/<虚拟端口><原始 uri>`，与页面入口共用同一个命名空间，
因此分级粒度自然落在**目录**上。下面这组策略的效果是「alice 的公开目录对匿名开放、bob 的不开」：

```bash
# 放行 file 域下 alice/pub 整棵子树（匿名 GET）
curl -sS -X POST -H "x-api-key: $AUTHZ_API_KEY" -H "Content-Type: application/json" \
  "$AUTHZ/_authz/api/policies" \
  -d '{"ptype":"p","v0":"role:guest","v1":"/100/alice/pub/*","v2":"GET","eft":"allow"}'
# bob 目录不放行 = 不写 /100/bob/* 这条（默认 fail-closed）；要显式拒绝再加一条 eft=deny
# 对象存储同理，按 key 前缀分级
curl -sS -X POST -H "x-api-key: $AUTHZ_API_KEY" -H "Content-Type: application/json" \
  "$AUTHZ/_authz/api/policies" \
  -d '{"ptype":"p","v0":"role:guest","v1":"/101/share/pub/*","v2":"GET","eft":"allow"}'
```

`v1` 里带的是**虚拟端口**而不是 6080/6443：100/101 不允许被域名绑定占用
（`POST /applications` 返回 422，见 §5），它们只作为策略对象的前缀存在。

**状态码**（以下都是直取路径、即带子路径的请求；根路径仍按页面返回 200/302）：

| 状态码 | 触发条件 |
|---|---|
| `200` | 命中策略且内容存在，整体返回 |
| `206` | 带 `Range` 请求头的分段返回 |
| `400` | JSON 错误：URI 含 `..` 段或控制字符 |
| `403` | 已登录或带合法 Key，但该身份对 `/100<路径>`、`/101<key>` 无策略 |
| `404` | 本机文件不存在 / S3 对象不存在。**不会**回落成 200 的页面 —— 播放器与外部系统需要明确的「文件不存在」，一条 200 的 HTML 只会把排障引向「格式不支持」 |
| `405` | 方法不是 GET/HEAD，响应头带 `Allow: GET, HEAD`（写操作只走 §6.1 那组控制面接口） |
| `503` | 仅 s3 域，JSON：取不到生效的存储配置（消息「对象存储未配置」），或该配置的 `default_bucket` 为空（消息点名未设置默认 bucket） |

匿名（完全无凭证）未命中策略时是 `302` 跳登录页而不是 403，与其它网关入口保持一致。

**s3 域的 bucket 语义**：路径第一段是 **key**，不是桶名 —— 桶取当前生效那套存储配置
（`s3_configs`，见 §6.2）的 `default_bucket`；带 `?cfg=<id|name>` 时改用另一套配置，
桶取**被选中那套**的 `default_bucket`。这样 URL 里永远不出现桶名，换一套服务不必改链接；
两者都没配就 503，不会静默换一个桶。

**query 参数**：

| 参数 | 作用 |
|---|---|
| `?download=1` | `Content-Disposition: attachment`，强制下载 |
| `?authz_preview=1` | inline 预览；HTML 正文在沙箱 CSP + nosniff 下渲染（与 `/_authz/store/`、`/_authz/s3/` 同款） |
| `?cfg=<id 或 name>` | 仅 s3 域：切换存储服务配置，桶随之取被选中那套的 `default_bucket` |
| `Range: bytes=...` | 请求头（不是 query），支持 206 分段，视频拖动依赖它 |

```bash
# 带 Key 分段取对象，并核对状态码
curl -sS -o /dev/null -w "%{http_code}\n" -H "x-api-key: $AUTHZ_API_KEY" \
  -H "Range: bytes=0-1023" "https://s3-235.example.com/share/pub/data/v.mp4?cfg=backup"
```

**Agent 安全提醒**：

- 不要把 URL 路径当可信输入。它直接决定读哪个文件、哪个 key，拼进 `<video src>` 或写进工单
  前先做前缀白名单校验 —— 网关会拒掉 `..`，但拒不掉「用户本来就该读那个目录」的越权读取意图，
  边界由 Casbin 策略与调用方的拼接逻辑共同守。
- 不要在 URL 里塞凭证。认证只走 `x-api-key` 请求头或会话 Cookie；Key 写进 query 会进访问日志、
  Referer 和浏览历史，等同于泄露。要对外分发长效公开链接，应由管理员用 `role:guest` 策略对
  具体目录放行后产生，而不是发一条带凭证的 URL。
- 这条直取**不是新增的控制面 API**：不新增路由、不需要额外 API Key 角色，非 `admin` 的 Key
  能否取到内容完全由同一套 Casbin 策略决定，不要为它申请或签发新凭证。

## 7. Agent 安全要求

- 不在日志、终端输出、任务结果或错误信息中打印 API Key。
- Key 放入进程环境变量或密钥管理系统，不提交到 `.env` 模板、Git 或普通配置文件。
- 每个应用/Agent 使用独立 Key，名称可追踪用途；停用优先于共享或复用 Key。
- 仅把 Key 发给受信任的网关 Origin；不要把 Key 放进 URL、query、Cookie 或请求 body。
- 自动化遇到 `401` 时停止并请求管理员轮换/启用 Key；不要尝试回退用户密码。
- 自动化遇到 `403` 时视为角色或策略拒绝，不要尝试越权；需要完整管理能力时由管理员签发独立
  `admin` Key，而不是复用用户密码。
