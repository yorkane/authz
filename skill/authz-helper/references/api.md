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
  （仅 `/_authz/guest` 探针 + `GET /session`，代理范围可用策略另行授予）。要调控制面 API 选
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
   - `guest`（= 匿名主体）：只有 `GET /_authz/guest` 诊断页和只回显自身的
     `GET /_authz/api/session`；其余控制面 API、管理页、文件浏览一律拒绝。
     给第三方做链路自检（确认来源 IP、代理头、上游收到的头）用 guest 即可。
     无凭证请求同样按 `role:guest` 授权：给 guest 配 allow 策略即可把某个
     绑定/路径开放给**完全匿名**访客（上游收到 X-Authz-User=guest）。
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
curl -H "x-api-key: $KEY" "https://<入口>/_authz/guest?json=1"  # guest 自检链路
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
| `request_rewrite` | 请求改写（头 + 正文），对象或 JSON 字符串（见 §5） |
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
  内置应用保留前缀入口（`file-*`→100 文件浏览、`s3-*`→101 对象存储，虚拟绑定、
  不在绑定表里）也按端口授权：`/100/*`、`/101/*` 同样合法（这两个端口在
  `AUTHZ_PORT_MIN` 之下但被白名单放行），且不允许用 `/applications` 占用。
- `v2` 动作：HTTP 方法逗号/竖线或 `*`。`eft:"deny"` 优先于 allow。
- `binding_id` 可选，校验绑定存在且端口与 v1 一致（展示用，授权仍按端口+路径）。
- `ptype:"g"` 是角色分配规则（`v0=user:...`、`v1=role:staff`），管理 UI 不提供编辑，
  配置助手一般不需要动它。

`PATCH /policies/:id` 用与新建相同的完整字段；`DELETE /policies/:id` 删除。
默认拒绝：未显式 allow 的角色/用户访问任何代理目标都是 403（admin 默认 `/*` 全放行）。

## 5. 改写请求（`request_rewrite`）

结构化配置，改写发往上游的请求头与正文：

| 字段 | 说明 |
|---|---|
| `enabled` | 默认 true；false 保留配置不生效 |
| `headers` | 对象，**替换**发往上游的请求头；值 `null` = 删除该头 |
| `append_headers` | 对象，**追加**：托管头并入当前值（Cookie 用 "; "，其余用 ", "），普通头多出一行；与 `headers` 同名互斥 |
| `remove_headers` | 数组，**删除**请求头；可与追加同名并存（先删后加） |
| `body` / `body_base64` / `content_type` | 整体替换请求正文（与 `rewrites` 互斥） |
| `rewrites` | 请求正文过滤规则，同 §6 格式 |

**网关托管头可以改写**：`Host`、`Cookie`、`Origin`、`Forwarded`、`X-Forwarded-*`、
`X-Real-IP`、`X-Authz-User/Source/Identity`。网关把这些头的值写进 proxy_set_header
引用的同名变量，改写值就是上游看到的最终值（优先于网关默认值）；删除托管头
则该头不发送给上游。

不可改写（保存即 422）：分帧与 hop-by-hop 头（`Content-Length`、`Transfer-Encoding`、
`Connection`、`Upgrade`、`TE`、`Trailer`、`Keep-Alive`）、网关凭据头（`X-Authz-Key`、
`X-API-Key`、`X-Role-Key`）、其余 `X-Authz-*` 与 `Proxy-*` 前缀、CR/LF 控制字符。

规则：`body` 与 `rewrites` 不能同时给；四类全空视为未配置（存空串）；配了正文改写时
网关自动向上游声明 `Accept-Encoding: identity`（用户显式覆盖优先）。限额与响应改写
一致：名称 ≤128、值 ≤2048、≤32 条、正则 ≤512、替换 ≤4096、正文 ≤65536、JSON ≤131072。
正文改写只对文本类、Content-Length 明确的非 GET/HEAD 请求生效，分块/二进制原样透传。

典型用途：给上游固定鉴权头、伪装入口 Host，或在既有 Cookie/转发链上追加：

```json
{"headers": {"Authorization": "Bearer sk-xxx", "Host": "app.internal"},
 "append_headers": {"Cookie": "tenant=a", "X-Forwarded-For": "10.0.0.9"}}
```

`upstream_host` / `forwarded_*` / `origin_mode` / `simulate_local` 是同一批头的结构化字段；
二者并存时 `request_rewrite` 后生效（以改写值为准）。

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
| 本机保存区位置 | `AUTHZ_STORE_DIR`（容器内，默认 `/data/store`，宿主 `${DATA_DIR}/store`，无需额外 volume） |
| 保存区默认 TTL | `AUTHZ_STORE_DEFAULT_EXPIRY_HOURS`（默认 24，0 = 永不过期；单次请求可用 `?expires_hours=` 覆盖） |
| 对象存储回落项 | `AUTHZ_S3_*` 整套现在只是**回落默认配置**：`/api/s3-configs` 表里有任何启用行就以表为准，改表即生效不用重建容器。只有想改实例级超时/连接池（`AUTHZ_S3_*_TIMEOUT_MS`、`AUTHZ_S3_KEEPALIVE_MS`）或 LAN IP（`AUTHZ_HOST_LAN_IP`）才需要动 .env |
| 登录防爆破 | `AUTHZ_LOGIN_ATTEMPTS`(5) / `AUTHZ_LOGIN_WINDOW`(1800s) / `AUTHZ_LOGIN_FAIL_DELAY_MS`(1000)，按「账户名+IP」锁定 |
| 端口发现 | `AUTHZ_DISCOVERY_PORTS`（容器监听表不可见时追加）、`AUTHZ_DISCOVERY_TTL` |
| HTTP 入口策略 | `AUTHZ_HTTP_MODE`=redirect/disabled/serve |
| Cookie 安全 | `AUTHZ_COOKIE_SECURE`（HTTPS 入口必须 true；决定 SameSite=None/Lax） |

注意：数据库类配置（用户/策略/绑定/菜单/Key）走 API 即时生效，不要改库；
环境类配置走 .env，两层不要混。
S3 服务配置属于**数据库类**（见 §12），不要在 .env 里加第二套凭证。

## 11. 其他端点与语义速查

 - `GET /_authz/guest?json=1` — 请求探针（明文完整回显请求头/来源/代理链，
   服务端转义）；**匿名即可访问**，guest/admin Key 与会话同样可用。
- `GET /api/files?path=` — 列 `AUTHZ_FILES_ROOT` 目录（登录或非 guest Key）。
- 文件管理写操作（全部 **admin**；浏览器会话另需 CSRF 头。机器 Key 用 `x-api-key` 免登录直连即可
  它天然跳过 CSRF，但仍要求 Key 角色为 admin 且来源 IP 在 `AUTHZ_API_KEY_ALLOWED_IPS` 内）：
  - `POST /api/files/upload?path=<rel>&overwrite=1` — multipart（字段名 `file`，可多文件）流式落盘；
    同名不带 overwrite 返回 409；响应 `{uploaded:[{name,size}], skipped:[{name,reason}]}`。
  - `PUT /api/files/rename` — `{path,name,new_name}`；目标已存在 409。可选 `new_path`＝移动到该目录（校验与 `path` 同源：含 `..` 400、目录不存在 404）；`new_name` 传原名即纯移动
    目录不得移入自身子目录（422），跨目录成功时响应多回 `{moved:true,new_path}`。前端多选的批量移动就是逐条调它。
  - `DELETE /api/files/remove` — `{path,name,recursive}`；目录非空不带 recursive 返回 409。
  安全边界：路径逐级要求真实目录、名称禁止分隔符/`..`、符号链接读不到也写不动；
  上传先写 `.upload-*` 临时名再原子改名，中断不会留半截目标文件。
- `PUT /api/me/password` — 改自己密码（session_only；改完其他会话全部下线）。
- `PUT /api/users/:id/password` — admin 重置他人密码。
- `PATCH/DELETE /api/remote-users/:provider` — 管理远程身份记录（角色覆盖/删除，
  `{provider, subject, ...}`，删除后下次登录按新身份重建）。
- nginx-conf 编辑：文件白名单 `http_inc.conf`/`server_inc.conf`/`stream_inc.conf`，
  单文件 256KB 上限；validate/PUT 都是 staging + `openresty -t` 通过才落盘；
  reload 失败看返回 message；模板目录只读时 API 会标 `persistent:false`。
- 登录页：`GET /_authz/login?next=<path>`；`next` 只接受以 `/` 开头的本站路径。

## 12. 存储服务配置（多套 S3 + 过期策略）

一行 = 一套 S3 兼容服务。管理入口是对象存储页（`s3.html`）工具栏的「配置」按钮（仅 admin）；独立菜单已在迁移 v27 隐藏，直链 `s3-configs.html` 仍可用。

- `GET /s3-configs` — `{"data":{"items":[...]}}`，含禁用行 + env 回落项。
- `POST /s3-configs` — 必填 `name`/`endpoint`/`access_key_id`/`secret_access_key`；
  可选 `region`、`allow_http`、`writable_paths`（逗号分隔多条，留空 = 默认 `share/<本机 LAN IP>`）、
  `share_root`、`share_bucket`、`expires_hours`(0-8760，0 = 永不过期)、
  `use_bucket_lifecycle`、`default_bucket`、`note`、`enabled`、`is_default`。成功 201 + `{"item":{...}}`；名称重复 409。
- `PATCH /s3-configs/:id` — 局部更新；**凭证字段留空/不传/传 `null` 都等于不修改**（回显只有掩码，拿不到原文）。
- `PUT /s3-configs/:id/default` — 设为默认（全表先清后设，不会出现两个默认）。
- `POST /s3-configs/:id/test` — 用这套配置列举桶：`{"ok":true,"buckets":["noco",...]}`；失败 502 + 原因（不回显凭证）。
- `DELETE /s3-configs/:id` — 删除；该配置下未闭账的流水当场标 `failed` + `config removed`（保留可审计）。

语义要点（用户会踩的四条）：

1. **优先级**：表里有「启用 + 字段合法」的行 → 表覆盖 env；一行可用配置都没有 → 回落
   `AUTHZ_S3_*`。回落项在列表里是 `{"id":0,"name":"env","virtual":true}`：**只读**，
   PATCH/DELETE 一律 422，只有「设为默认」是 no-op 成功。
2. **改表即生效，不需要 reload**：查询缓存 TTL 30s + `db_rev` 失效，通常下一个请求就切过去。
3. **凭证明文入库**（SigV4 要原文签名，有意决策）：任何接口只回 `has_secret` 与
   `access_key_id_masked`。绝不把 secret 回显给用户，也不要写进日志/工单；
   提醒用户备份 `authz.db` 等于备份密钥。
4. `expires_hours` 单位是**小时**、整点对齐、0 = 永不过期；`use_bucket_lifecycle=1`
   表示「只记账不删，回收交给桶生命周期规则」。见 §13。

既有对象存储接口全部多了一个选配置的入参 `cfg`（`?cfg=<id|name|env>`，JSON 端点也可放 body）：
不传 = 默认项；点名到不存在/已停用 423，行存在但字段写坏 502。

```bash
AUTHZ=http://127.0.0.1:6080
# 新增一套服务并设为默认（明文 http 内网必须显式 allow_http）
curl -sS -H "x-api-key: $AUTHZ_API_KEY" -H 'Content-Type: application/json' \
  -d '{"name":"minio-a","endpoint":"http://10.251.14.70:30080","region":"RegionOne",
       "access_key_id":"<AKID>","secret_access_key":"<SECRET>","allow_http":true,
       "writable_paths":"agent","expires_hours":24}' \
  "$AUTHZ/_authz/api/s3-configs" | jq '.data.item | {id,name,has_secret}'
curl -sS -X PUT -H "x-api-key: $AUTHZ_API_KEY" -H 'Content-Type: application/json' -d '{}' \
  "$AUTHZ/_authz/api/s3-configs/1/default" | jq '.data.item.is_default'
curl -sS -X POST -H "x-api-key: $AUTHZ_API_KEY" -H 'Content-Type: application/json' -d '{}' \
  "$AUTHZ/_authz/api/s3-configs/1/test" | jq '.data'
```

## 13. 上传流水与过期清理

经网关写入的对象（S3 对象 + 本机保存区文件）都记在 `upload_records` 里，构成清理队列。
为什么要自己记账：S3 官方 bucket lifecycle 只到**天**粒度且异步，做不了小时级过期。

- `GET /uploads?state=&limit=&offset=` — `{"data":{"items":[...],"total":n}}`；
  `state` ∈ `active`/`deleted`/`failed`/`skipped`（省略或 `all` = 全部），`limit` 默认 50、上限 500。
- `POST /uploads/cleanup` — 立刻跑一轮清理（等价定时器的一轮，另有每小时自动跑）；
  body 可选 `{"limit":n}`；响应 `{"scanned","deleted","failed","skipped","orphans","staged","updated"}`。
- `DELETE /uploads/:id` — 按记录立刻删对象/本地文件并闭账；已删过的行幂等回 `already:true`；
  删除失败 502 + 原因（不静默）。勾了 `use_bucket_lifecycle` 的行这里**照删**（人工意志优先）。

排障口径：`state=failed` + `last_error='config removed'` = 配置行被删导致对象不可达（要人工处理，
清理器不会重试）；`config disabled` = 配置只是停用，重新启用后仍能删。

```bash
curl -sS -X POST -H "x-api-key: $AUTHZ_API_KEY" -H 'Content-Type: application/json' \
  -d '{"limit":500}' "$AUTHZ/_authz/api/uploads/cleanup" | jq .data
```

## 14. 本机保存区（Agent 落盘 → 换一条取回链接）

定位是**临时交换区**（默认 24 小时后自动删除），**不是持久存储**：需要长期保存的走 §12 的对象存储。
根目录 `AUTHZ_STORE_DIR`（容器内 `/data/store`，宿主 `${DATA_DIR}/store`）。这一组端点
刻意允许机器 Key 免登录，正是为 Agent 直传直取设计（仍要求 admin 角色 + 来源 IP 白名单）。

- `GET /store/info` — `{enabled, store_dir, writable, default_expiry_hours, max_bytes(512MB), max_files(64), counts}`；
  目录不可用不是错误，回 200 + `enabled:false`。
- `GET /store?path=<rel>` — 单层列目录（省略 = 根；`raw=1` 跳过 TTL 关联）。
- `GET /store/stat?path=<rel>` — 单对象元信息 + `expires_at`。
- `PUT /store?path=<rel>&expires_hours=<h>&overwrite=0` — 请求体即文件字节；
  `path` 可多级（祖先目录自动创建）；`overwrite` **默认开**；成功 201
  `{path,size,url,expires_at,expires_in}`。
- `POST /store/upload?path=<dir>&expires_hours=<h>&overwrite=1` — multipart，表单字段名 `file`
  （可多个，单请求 ≤64 个）；`overwrite` **默认关**，全同名冲突回 409。
- `DELETE /store?path=<rel>&recursive=1` — 删除并闭账。

限制：单对象 512MB（超限 413）、单请求 64 个文件（超出计入 `skipped`）、目录深度 ≤32。
路径非法（绝对路径、`..`、`~`、控制字符、以 `.upload-` 等暂存保留名开头）→ 400。
`url` 是**同源相对**入口（`/_authz/store/<rel>`），带 `?download=1` 强制下载、
`?authz_preview=1` 沙箱预览，支持 Range；该出口只读，非法/越界/含符号链接一律 404。身份与写入侧一致：**admin 机器 Key 或
admin 会话**才可取回（其他角色 403、未登录 302 登录页）。

```bash
AUTHZ=http://127.0.0.1:6080
# 保存 → 取回 URL → 立即清理（一条链路跑完）
URL=$(curl -sS -X PUT -H "x-api-key: $AUTHZ_API_KEY" \
  --data-binary @report.md \
  "$AUTHZ/_authz/api/store?path=reports/report.md&expires_hours=6" | jq -r .data.url)
echo "取回地址：$AUTHZ$URL"                                # → /_authz/store/reports/report.md
curl -sS -H "x-api-key: $AUTHZ_API_KEY" "$AUTHZ$URL" -o /tmp/back.md   # admin Key 直取（浏览器打开要先登录 admin）
curl -sS -X DELETE -H "x-api-key: $AUTHZ_API_KEY" \
  "$AUTHZ/_authz/api/store?path=reports/report.md" | jq .data
```

注意 `url` 只有路径没有主机名：交付给用户时要拼上实例地址（`AUTHZ_HOST_URL` 或
`http://127.0.0.1:6080`），并说明打开它需要 **admin** 会话或 admin 角色的 `x-api-key`
（保存区是 agent 中转区，不对普通登录用户开放）。
