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

应用在每次请求中发送：

```http
x-authz-key: ak_<64 个小写十六进制字符>
```

API Key 的主体是 `api-key:<id>`，创建或修改时可绑定一个固定目录角色：`admin`、`staff`、`user`、
`viewer`、`api`。控制面权限与同角色用户一致，代理权限由对应的 `role:<role>` Casbin 策略决定。
`role:admin` 和 `role:api` 默认可访问所有已解析代理目标，管理员可用 deny 策略继续收紧。

```bash
curl -sS -H "x-authz-key: ${AUTHZ_KEY}" \
  "https://2077-m.ws.example.com:99/api/status"
```

网关不会把 `x-authz-key` 转发到上游。上游只会收到安全身份头：

```text
X-Authz-User: <API Key 名称>
X-Authz-Source: api-key
X-Authz-Identity: api-key:<id>
```

如果请求显式携带无效或已禁用的 `x-authz-key`，网关返回 `401 invalid_api_key`，不会回退到同时携带的
浏览器 Cookie。

### 2.3 Agent 专用 API Key（仅限本机）

设置环境变量 `AUTHZ_AGENT_API_KEY`（值为 `ak_<64 位小写 hex>`）后，网关启动时会自动创建或更新名为
`agent-default` 的 API Key：角色 `admin`、`loopback_only=1`。该 Key **只能从网关宿主机本机调用**，
非回环来源一律 401，适合本机运行的自动化程序（Agent）安全使用控制面。

```bash
curl -H "x-authz-key: $AUTHZ_AGENT_API_KEY" http://127.0.0.1:6080/_authz/api/session
```

要求与约束：

- 只能通过本机地址访问网关控制面端口，不要把控制面暴露到公网或跨机调用；
- 值只保存在部署环境（如 `.env`），不入库明文、不进 git；轮换时更换环境变量并重建容器；
- 该 Key 具备 admin 权限，自动化脚本应只调用任务所需的最小接口集合；
- 管理界面创建的普通 API Key 不受 loopback 限制，如需限制来源请使用本节方式。

## 3. 权限矩阵

| 接口能力 | 普通用户/Key | `admin` 用户/Key | `api` Key |
|---|---:|---:|---:|
| 读取自身身份和应用入口 | 是 | 是 | 是 |
| 浏览器注销/修改自己的密码 | 仅用户会话 | 仅用户会话 | 否 |
| 新建域名与端口绑定 | 否 | 是 | 是 |
| 修改或删除绑定 | 否 | 是 | 否 |
| 管理用户、远程身份和密码 | 否 | 是 | 否 |
| 读取/修改 Casbin 策略 | 否 | 是 | 否 |
| 创建、修改、删除 API Key | 否 | 是 | 否 |
| 请求受保护的代理目标 | 按绑定角色策略 | 按 `admin` 策略 | 按 `api` 策略 |

用户会话的修改请求必须发送 CSRF；API Key 请求不使用 CSRF。`api` 是服务主体专用角色，不能分配给
本地或远程用户。角色目录固定，不提供动态新建角色 API。

## 4. API Key 管理（`admin` 角色）

### `GET /api-keys`

列出 Key 元数据。响应永远不包含明文 token 或 `token_hash`。

### `POST /api-keys`

创建 Key。可使用 admin Cookie + CSRF，也可直接使用 `admin` API Key；机器请求不发送 CSRF。

```json
{"name":"deployment-agent","role":"staff"}
```

名称为 2–64 位 ASCII 字母、数字、点、下划线或连字符。`role` 可为
`admin/staff/user/viewer/api`，省略时默认 `api`。

创建响应中的 `token` 只出现一次：

```json
{
  "data": {
    "id": 12,
    "name": "deployment-agent",
    "role": "staff",
    "enabled": 1,
    "created_at": 1787580000,
    "updated_at": 1787580000,
    "token": "<仅本次返回；立即保存到密钥管理系统>"
  }
}
```

SQLite 只保存 SHA-256 摘要，丢失明文后不能恢复，应删除旧 Key 并创建新 Key。

### `PATCH /api-keys/:id`

允许字段：

```json
{"name":"deployment-agent-2","role":"viewer","enabled":false}
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
  -H "x-authz-key: ${AUTHZ_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"domain":"code","target_ip":"192.168.1.20","port":2077,"menu_name":"Code Server","enabled":true}'
```

请求字段：

| 字段 | 必填 | 说明 |
|---|---:|---|
| `domain` | 是 | 推荐只填最后一级前缀，例如 `code`；也接受完整域名 |
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
| `header_overrides` | 否 | 多行文本，每行 `Header-Name: value`，按行覆盖发往上游的透传请求头；Host、Cookie、Origin、X-Authz-*、X-Forwarded-*、X-Real-IP 与 hop-by-hop 头不可覆盖；留空表示不覆盖 |
| `upstream_scheme` | 否 | 上游协议，`http`（默认）或 `https` |
| `upstream_ssl_verify` | 否 | HTTPS 上游是否校验证书，默认 `true`；设为 `false` 忽略证书校验，仅建议用于受控内网或自签名证书 |
| `upstream_path` | 否 | 上游路径改写，默认空值表示保留请求路径；例如 `/v1/index.html` 会把任意请求转发到 `/v1/index.html`，查询参数原样保留；不接受 query、fragment、连续斜杠或 `..` |

前缀会按当前实例域名生成完整入口。例如实例基域名为 `m.ws.example.com`，`domain: "code"` 保存为
`code-m.ws.example.com`。域名必须唯一，重复返回 `409`。

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
`header_overrides` 每行一条 `Header-Name: value`，保存时做格式、控制字符、长度和白名单校验
（名称不超过 128、值不超过 1024、总量不超过 8192、最多 32 条，重复名保留首条），
只影响未在代理配置中显式控制的透传类请求头（如 `Authorization`、自定义业务头）。

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
