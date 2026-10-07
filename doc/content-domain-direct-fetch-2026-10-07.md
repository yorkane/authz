# 保留前缀域名的文件/对象直取 —— 交付与验证报告

日期：2026-10-07
范围：`file-<节点>.<域>` 与 `s3-<节点>.<域>` 从「只渲染管理页」扩展为「带子路径的 GET/HEAD 直接返回内容字节」。

## 1. 交付内容

### 1.1 环境变量默认开启

`.env.example` 把原先注释掉的五个变量改成显式默认（仓库根 `docker-compose.yml:44-48` 早已带同样的默认值）：

```
AUTHZ_APP_DOMAINS=1
AUTHZ_APP_PREFIX_FILES=file
AUTHZ_APP_PORT_FILES=100
AUTHZ_APP_PREFIX_S3=s3
AUTHZ_APP_PORT_S3=101
```

关闭入口只需显式写 `AUTHZ_APP_DOMAINS=0`。**注意注入方式**：那份 compose 用的是逐条列举的显式
`environment:` 清单，新增变量只进 `.env` 不进清单就不会落到容器里——这正是 241.t 上曾经
`AUTHZ_APP_*` 五行全缺的原因（其 compose 是手工副本且已漂移，现已同步；`.env` 也已显式写入）。

### 1.2 分流实现

| 文件 | 改动 |
|---|---|
| `lualib/resty/authz/gateway/app_content.lua` | **新建**（129 行）：内容路径分流、bucket 解析、400/405/503 判定 |
| `lualib/resty/authz/gateway/access.lua` | +9 行：`binding.app` 分支在渲染入口页**之前**调 `app_content.handle()`；`binding.app` 全程只读 |
| `conf/server.conf.template` | +26 行：`location /` 新增两个 Lua-only 变量；`/_authz/files/` 与 `/_authz/s3/` 的 access 门开头各加一条放行 |
| `lualib/resty/authz/s3_proxy.lua` | +10/-1：`serve()` 取源优先用 `authz_app_content_uri`（见 §3.1）；**`parse_path` 本体未动** |

分流顺序（不可调换）：根路径 `/` 与 `/_authz/` 命名空间交回入口页 → 非 GET/HEAD 回 405
（带 `Allow: GET, HEAD`）→ URI 含 `..` 段或控制字符回 400 → 其余按条目分流到
`/_authz/files/<路径>` 或 `/_authz/s3/<bucket>/<key>`。

授权落点**不变**：Casbin object 仍是 `/100<原始 uri>` / `/101<key>`，所以目录级与单文件级
分级策略照旧生效；未命中即 fail-closed（匿名 302 引导登录 / 有凭证无权 403）。

## 2. 为什么这样设计

复用既有的 `/_authz/files/`（静态 `alias`）与 `/_authz/s3/`（`resty.http` 流式代理，Range 原样
转发 206、Content-Type 按扩展名推断、沙箱预览头）两条通道，**不新写第三条字节流通道**：那两处
的语义早已在生产验证过，多一条通道就多一份漂移风险。

内容 location 的二次鉴权门用 Lua-only 变量 `authz_app_content` 放行——它只在 `location /` 里
`set` 成空串、只由 `app_content.lua` 写非空值，不从任何请求头或 `map` 派生，客户端伪造不了
（与既有 `authz_app_entry` 同一手法，二者语义分开不可复用）。裸打 `/_authz/files/`、
`/_authz/s3/`（不经网关）时该变量未初始化，仍走原有会话 / API Key 规则，**新放行没有把内部
路径变公开**。

## 3. 过程中发现并修掉的三个洞

### 3.1 `$request_uri` 不随 `set_uri` 改写（曾导致 S3 直取全部 404）

`ngx.req.set_uri()` 改 `$uri` 但不改 `$request_uri`，而 `s3_proxy.parse_path()` 恰好按
`$request_uri` 匹配，于是内部重定向后它看到的仍是客户端原始路径 `/<key>`，拆不出
bucket/key。本机文件通道没暴露这个问题，因为 nginx `alias` 匹配的是 `$uri`。

修法：`app_content` 把**已拼好的目标 URI**经 `authz_app_content_uri` 交给 `s3_proxy`，由它喂给
**同一个** `parse_path`。不用 `$uri` 兜底是因为 `$uri` 已解码，再过 `parse_path` 的
`ngx.unescape_uri` 会二次解码，key 含 `%` 时出错。

### 3.2 放行判据必须容忍 nil

内容 location 不经 `location /`，裸打时该变量是 **uninitialized(nil)** 而非空串。写成
`if ngx.var.authz_app_content ~= ""` 时 `nil ~= ""` 为真，会把裸 `/_authz/files/` 误放行。
正确写法是 `if content and content ~= ""`。

### 3.3 `%2e%2e` 编码穿越

第一版只查原始字面 `..`，而 nginx 会把 `/a/../b` 归一化、把 `%2e%2e` 解码，归一化后的 uri
看不出穿越意图，实测返回了本该拒绝的另一个目录的内容。现对**原始串 / `ngx.unescape_uri` /
归一化 uri** 三形态统一逐段比对 `..` 与 `%c`，编码形式也回 400。

## 4. 验证（241.t，带真实对象存储凭据）

### 4.1 回归（三套全绿）

| 套件 | 结果 |
|---|---|
| `test_authz_gateway.sh`（全量，含 `s3-live`） | **All 1413 checks passed**，EXIT=0 |
| `test_klib_router_ctxvar.sh` | **All 99 checks passed**，EXIT=0 |
| `test_shared_session.sh` | **All 119 checks passed**，EXIT=0 |

新增断言 237 行（`app-domains` 段 59 条本机文件直取/分级断言 + `s3-live` 段约 30 条 s3 域名
直取断言，含新的 `s3host_req` helper）。`app-domains` 段基线由 208 → 267；全量本机 1278、
241.t 上 1413（多出的是 `s3-live` 段在本机无凭据时跳过的部分）。

### 4.2 行为矩阵（现场 curl，非回归脚本）

身份：匿名 / guest 角色 Key / admin 角色 Key（admin 有 `/*` 兜底，**不能**用它证明授权）。

| 场景 | 结果 |
|---|---|
| `file-<域>/` 与 `s3-<域>/` | 200，仍是内置应用页 |
| `file-<域>/<存在的文件>` | 200 + 精确字节 + 按扩展名推断 Content-Type |
| `file-<域>/<不存在的路径>` | **404**，正文不含 `<title>Files</title>`（不再回落成 200 的 SPA 页） |
| HEAD | 200，`Content-Length` 正确，`size_download=0` |
| `Range: bytes=0-3` | **206** + `Content-Range` |
| 非 GET/HEAD | Casbin 放行该方法时 **405** + `Allow: GET, HEAD`；方法未授权时先被 Casbin 拒成 **403** |
| `..` 原始 / `%2e%2e` 编码穿越 | **400** |
| s3 域名取对象（真实桶 `agent`） | 200 + 精确字节；Range 206；`?download=1` 带 `Content-Disposition: attachment` |
| s3 未配置 / 未设默认桶 | **503** + JSON，message 区分「未配置」与「无可用 bucket」，**非 500**、不回显 secret |
| 裸打 `/_authz/files/`、`/_authz/s3/` | 匿名 302、guest Key 302、admin Key 200 —— 未变公开 |

### 4.3 分级授权（不同目录 × 不同身份）

fixture 建了属主不同的 `acl-alice/`(uid 1000)、`acl-bob/`(uid 1001)、`shared/`(uid 1002)。

| 策略 | alice 的文件 | 同目录另一个文件 | 别的目录 |
|---|---|---|---|
| 无任何策略 | 403 | 403 | 403 |
| `/100/acl-alice/only.txt`（单文件） | **200** | **403** | 403 |
| 再加 `/100/acl-alice/second.txt` | 200 | **200** | 403 |
| 换成 `/100/acl-alice/*`（目录通配） | 200 | 200 | **403** |
| `/100/acl-alice/pub/*` | `pub/p.txt` 200 | `pub/deep/d.txt` **200** | `acl-alice/only.txt` 403 |

结论：`*` **会跨斜杠**（`pub/*` 同时覆盖两层子目录），因此目录级授权是「该前缀及其全部后代」；
要真正只放行单个文件必须写完整路径。同一策略下匿名与 guest Key 表现一致（匿名主体就是
`role:guest`），越权时匿名被引导登录（302）、带凭证者得 403。

属主不同不影响判定——网关以 root 读文件，权限判定**完全来自 Casbin 而非文件 uid**，这点已实测确认。

## 5. 遗留与注意事项

1. **凭据泄露**：验证过程中一条 `pgrep -fa` 把运行中进程的环境变量打印了出来，其中含对象存储
   的 AccessKey Secret。该 secret 已出现在会话记录里，**建议轮换**。
2. **桶内空目录残留**：回归的 `s3-live` 段会在桶里留下 `share/10.254.253.252/…` 空前缀目录。
   该配置的可写范围是 `agent/verify`，网关按设计拒绝删除（403），故未强行绕过——无对象，纯前缀残留。
3. **key 含 `%` 的编码口径**：直取通道的目标 URI 源自已解码的 `$uri`，字面量含 `%` 的对象名
   走 s3 域名直取与走内部老通道存在差异。非本次引入，未改动。
4. **未覆盖**：大文件吞吐未压测（只验了 300KB fixture 的 Range/206）；`d2.test.com` 在公网与
   内网均无 DNS 记录，验证用的是 `--resolve` + 自造 Host。网关两个 server 都是 `server_name _;`
   所以任意 Host 都生效——真要在浏览器里用需要 DNS/权威区记录。
5. **本机生产未部署**：235.t 生产容器的渲染配置里不含新变量（已核实），按仓库约定未向生产发布；
   本次只在 241.t 测试实例部署验证。
