# 对象存储浏览（S3 兼容）集成说明

本文档描述 Authz Gateway 的「对象存储」内置应用：网关侧代签 SigV4，把私有
S3 兼容服务变成管理界面里的一个浏览器应用。行为细节与实测契约以代码
（`lualib/resty/authz/s3.lua`、`s3_proxy.lua`、`s3_upload.lua`、
`lualib/resty/aws/request/signatures/`）为准。

## 1. 目标与边界

- **凭证只在网关侧**：AKID/SECRET 有两种来源——环境变量（`config.lua` 读入）或
  `s3_configs` 表行（管理页写入，见 §3.1）。两者都只存在于签名器内部；所有 API 与
  页面都不回显凭证（表行只回 `has_secret` + 掩码 AKID）。浏览器只拿会话（或 API Key）
  访问 `/_authz/api/s3*` 与 `/_authz/s3/<bucket>/<key>`，签名发生在网关 worker 内。
- **配置优先级**：`s3_configs` 表里有「启用 + 字段合法」的行时，运行时以表为准；
  表里一行可用配置都没有时才回落 `AUTHZ_S3_*`。取配置的唯一入口是
  `s3_config_store`，任何地方都不许再直读 `config.s3`（那会让 `?cfg=` 与页面新建的
  配置全部失效）。细节见 §3.1。
- **未配置的降级语义**（表里没有可用行 **且** 未设 `AUTHZ_S3_ENDPOINT`）：
  - 菜单始终可见（迁移 `21:menu_entry_s3_browser` 无条件 seed 系统应用组下的
    「对象存储」入口，`admin_only=1`）；
  - `GET /api/s3`（含带 `bucket` 参数的列表请求）统一返回 `200` +
    `data.enabled=false`，前端据此显示「对象存储未配置」卡片——信息接口
    永远是 200，降级语义只由它表达；
  - 其余桶级接口（`upload`/`rename`/`remove`/`mkdir`）与字节流
    `/_authz/s3/...` 返回 `423`（`code=s3_disabled`）。写接口的
    认证/角色/CSRF 门禁先于 423 生效（403/401 优先）。
- **权限模型**：只读的 `GET /api/s3`（info/list）对任何已登录非 guest 会话或
  合法 API Key 开放；
  `upload`/`rename`/`remove`/`mkdir` 要求 `admin`：浏览器会话（写请求带
  `X-CSRF-Token`）**或** `admin` 角色机器 Key（`x-api-key`/`x-role-key`，
  guard 的 CSRF 判定只在「未呈现凭证头」时生效，机器 Key 天然免 CSRF）。
  这些端点不再标 `session_only`，所以 Agent 可以免登录直连；能力边界仍是
  admin 角色 + Key 的来源白名单（实例级 Key 走 `AUTHZ_API_KEY_ALLOWED_IPS`，
  数据库 Key 走 `loopback_only`），非 admin 角色 Key 一律 403。
  仍未开放给 staff。字节流 `/_authz/s3/` 的 access 门与
  `/_authz/files/` 完全同款（会话或合法非 guest API Key 放行，guest 引导到
  诊断页，匿名跳登录）。

## 2. Vendored 签名器（Kong/lua-resty-aws）

只引入上游签名子集，**不引入整套库**，因此**不需要** `AWS_EC2_METADATA_DISABLED`
（凭证链根本不存在，也不会去探测 EC2 metadata）：

| 文件 | 来源 |
|------|------|
| `lualib/resty/aws/request/signatures/v4.lua` | Kong/lua-resty-aws **1.7.2（commit a73c39c）**，Apache-2.0 |
| `lualib/resty/aws/request/signatures/utils.lua` | 同上 |
| `lualib/resty/aws/LICENSE.lua-resty-aws` | 上游 LICENSE 副本 |

不整库 vendor 的原因（`s3.lua` 文件头注释）：上游要解析 ListBuckets /
ListObjectsV2 就得拖进 Penlight + luatz + luaexpat（68 个文件约 1.4MB），
而镜像里没有 luaexpat，整库反而跑不起来；该服务的响应结构很简单，
`s3.lua` 里用模式匹配自写 XML 提取（`xml_text`/`xml_blocks`），更小更可控。

**LOCAL PATCH（相对上游的本地改动，文件头注释均有标注）：**

1. **`v4.lua` 尊重调用方传入的 `X-Amz-Content-Sha256`**（注释块标
   `LOCAL PATCH (authz)`）：流式上传以 `UNSIGNED-PAYLOAD` 字面量参与签名
   （服务端接受定长 + UNSIGNED 且回读字节逐字节一致，见 `s3.lua` 头部
   实测契约），而该字面量必须同时进入 canonical request，否则服务端
   回 `SignatureDoesNotMatch`。未传该头时行为与上游完全一致（S3 签名
   自动写入 body 摘要头）。
2. **三个文件均把上游的 `pl_string.strip` 换成纯 Lua 修剪**（每个文件头
   注释写明）：避免把 Penlight 拖进镜像。除上述两条外未改动其他逻辑。

凭证注入是 `s3.lua` 里手写的静态 `credentials(cfg)` 对象（`get()` 直接返回
AKID/SECRET），`signatureVersion="s3"`、`endpointPrefix="s3"`。

## 3. 环境变量（回落默认配置，`config.lua` 启动期校验）

本节全部变量现在只是**回落默认配置**：`s3_configs` 表里有可用行时它们不参与选路
（只有超时/连接池与 `AUTHZ_HOST_LAN_IP` 例外，见 §3.1）。表结构与管理接口见 §3.1。

| 变量 | 默认 | 含义 / 约束 |
|------|------|------------|
| `AUTHZ_S3_ENDPOINT` | 空（= 功能关闭） | `http(s)://<host>[:<port>]`，**path-style、不能带路径**，尾部 `/` 自动剥除；设了它但缺 AKID/SECRET 直接启动报错 |
| `AUTHZ_S3_REGION` | `us-east-1` | SigV4 credential scope 的 region 段；不允许空白/控制字符、≤64 字符 |
| `AUTHZ_S3_ACCESS_KEY_ID` | 空 | endpoint 已设时必填（不得含空白/控制字符） |
| `AUTHZ_S3_SECRET_ACCESS_KEY` | 空 | endpoint 已设时必填（不得含空白/控制字符） |
| `AUTHZ_S3_ALLOW_HTTP` | `false` | endpoint 为明文 `http` 时必须显式置 `true`，否则**启动报错**（防止误以为在走 TLS） |
| `AUTHZ_S3_TMP_DIR` | `/data/s3tmp` | 上传中转暂存目录（容器内路径，需可写；与 `/data` 同卷最省 IO）。`docker-entrypoint.sh` 在 endpoint 已设时自动 `mkdir -p`；即使 entrypoint 是旧版或目录运行期被清掉，上传路径每次也会先逐级自建（见 §6.k） |
| `AUTHZ_S3_WRITABLE_PATHS` | 空（= 默认 `share/<本机局域网 IP>`，见 `AUTHZ_S3_SHARE_ROOT`） | **可写范围白名单**（逗号分隔）。上传/建目录/重命名/删除只允许落在范围内；范围外一律只读（仍可浏览、预览、下载）。条目语义：`noco`=整桶、`noco/rpa`=该桶内前缀、`*/docs`=任意桶内前缀、无分隔符条目（如 LAN IP）=同名整桶或任意桶内该路径前缀。`/` 或 `*` = 全部可写；条目含 `..`/控制字符/`?`/`#` 启动报错 |
| `AUTHZ_S3_SHARE_ROOT` | `/share/` | 对象存储内的**挂载根**（归一化去首尾 `/`）。默认场景的可写前缀 = `<share 根去斜杠>/<本机 LAN IP>`（如 `share/10.252.25.241`）：桶根与挂载祖先只读，该前缀及其子目录可写。LAN IP 探测失败（且 `AUTHZ_HOST_LAN_IP` 未设）时默认场景整体降级只读，该前缀不出现在 `writable_roots`，`GET /api/s3` 的 `share_prefix` 回显 `null` |
| `AUTHZ_S3_SHARE_BUCKET` | 空（= 任意桶） | 非空时 share 前缀**只在该桶**生效，其他桶不存在默认可写前缀；info 的 `share_bucket` 原样回显 |
| `AUTHZ_HOST_LAN_IP` | 空（= 自动探测） | 覆盖「本机局域网 IP」的探测值（非 host 网络或测试用）。探测用 FFI UDP connect 到保留地址选路由源地址，不发包；探测失败且未设本变量时**整体降级为只读**并告警 |
| `AUTHZ_S3_CONNECT_TIMEOUT_MS` | `2000` | 建连超时（毫秒，下限 50） |
| `AUTHZ_S3_SEND_TIMEOUT_MS` | `30000` | 发送超时（毫秒，下限 200） |
| `AUTHZ_S3_READ_TIMEOUT_MS` | `30000` | 读取超时（毫秒，下限 200）；同时作为签名器 `config.timeout` |
| `AUTHZ_S3_KEEPALIVE_MS` | `30000` | 连接池空闲超时（毫秒，下限 1000），池大小 30 |

部署另有两点（`docker-compose.yml`）：仓库的 `docker-entrypoint.sh` 以只读卷
挂进容器（`${ENTRYPOINT_FILE:-./docker-entrypoint.sh}`），否则老镜像里的
entrypoint 不认识 S3 初始化；容器名走 `${AUTHZ_CONTAINER_NAME:-authz}`，
测试实例在 `.env` 里设成自己的名字（如 `authz-test`），避免整仓 rsync 后
recreate 时改名顶掉现有实例。

compose 与 `.env.example` 已列出全部超时项；`config.lua` 对每个数值都设了
下限钳制，非法值回落默认。`AUTHZ_S3_ENDPOINT` 会回显给
管理页面（`/api/s3` 的 `endpoint` 字段，便于排障），凭证不回显。

### 3.1 env 回落 + DB 多配置（`s3_configs` 表）

一套 env 只能指向一个 S3 服务，多服务只能在页面维护。迁移 `23:s3_configs` 建表，
一行 = 一套服务；`lualib/resty/authz/s3_config_store.lua` 是唯一的取配置入口，
把「表行」与「env 默认项」统一变成与既有 `config.s3` 同构的 cfg 表交给
`s3.lua` / `s3_proxy.lua` / 清理器消费。

**优先级**（`s3_config_store.get(ref)`）：

| `ref` | 解析结果 |
|-------|----------|
| 不传 / 空 | `is_default=1` 且 `enabled=1` 的行 → id 最小的 enabled 行 → env 回落项 |
| 数字或 `cfg:<id>` | 按 id（`0` / `cfg:0` 在 router 侧翻成按名字点 `env`） |
| 其它字符串 | 按 `name`，最后再试一次 `env`（纯 env 部署里 `?cfg=env` 必须可用） |

取不到分两类，状态码不同：`missing`（无此行/已禁用）与 `disabled`（表空且 env 也没配）
→ `423`；`invalid`（行存在但字段写坏）→ `502` + 原因。**行路径永不 `error()`**：
一行被写坏只让这一套配置不可用，不像 env 路径那样启动期 fail-fast 拖垮容器。

**表覆盖 env 的判据是「有没有可用行」**，不是「有没有默认行」；所以只要页面上加了
一行并启用，env 那套就不再是默认项，且不再出现在对象存储页的下拉里（避免多出一个
「谁都不知道还作不作数」的幽灵选项）。列表接口（`GET /api/s3-configs`）仍会把 env
项作为 `id=0`、`virtual=true` 的只读行给出来，除「设为默认」（no-op 成功）外
编辑/删除一律 `422`。

**改表即生效，不需要 reload**：行数据走 mlcache（`AUTHZ_DB_CACHE_TTL`，默认 30s），
派生结果（endpoint 解析 + 可写范围 parse）缓存在 worker 本地表并以
`ngx.shared.authz_cache` 的 `db_rev` 判活，任何写库都会 bump revision，所以通常写完
下一个请求就生效，最坏 30 秒。

**实例级参数不从 env 继承**：`s3_config_store.from_row` 里

| 字段 | 表行的取值口径 |
|------|----------------|
| `allow_http` | 只按行自身，**不继承** env。它是「明文 http 是否可信」的安全开关，若被 env 隐式打开，等于 env 恰好用 http 时页面新增的任意配置都自动允许明文且关不掉。后果：http 部署里新增 http 配置必须显式勾选，否则该配置报错不可用（刻意的显式确认） |
| `*_TIMEOUT_MS` / `KEEPALIVE_MS` | 一律取 env（超时是实例级调优，不按配置行各来一套） |
| `region` | 行内值，留空回落 env 的 region |
| 可写范围 | 行内 `writable_paths` 留空 → 默认条目 `share/<本机 LAN IP>`（与 env 同一套语义，见 §3；探测失败降级只读并告警） |
| `expires_hours` / `use_bucket_lifecycle` / `default_bucket` / `local_root` | 纯新增列，env 侧没有对应项（回落项的这三项恒为 0 / 0 / 空 / 空） |

**凭证纪律**（本仓库首例明文密钥入库，理由见 `db/migrations.lua` v23 注释）：
SigV4 要拿 `secret_access_key` 原文参与签名，摘要无法还原，所以只能存明文。
补偿约束：

- 回显只走 `repository/s3_configs.lua` 的 META 列集合（SQL 层就不选 `secret_access_key`，
  `has_secret` 由 SQL 算出来），接口层再叠加 `mask_akid`（AKID 只留前 4 位）；
  含明文的 `*_full` / `enabled_rows` 唯一合法消费者是 `s3_config_store.build_map`；
- `PATCH` 的凭证字段「空 = 不修改」，校验时用哨兵 `unchanged` 满足 build_s3 的非空判据，
  该哨兵不会被写进任何其他地方；
- **备份会连带复制密钥**：`azops backup` / `cp data/authz/authz.db` 出来的文件含明文
  S3 密钥，必须按含密介质处理（详见 `deploy.md` 第 6 节与 `docs/maintenance-handbook.md`）。

**管理接口**：契约见 `docs/core-api.md` §6.2，页面是「系统应用 → 存储配置」
（`admin/s3-configs.html`，迁移 `25:menu_entry_s3_configs` seed，`admin_only=1`）。

**表行独有的列**（env 侧没有等价物）：`expires_hours`、`use_bucket_lifecycle`（见 §9）、
`default_bucket`（**当前只落库与回显，前端尚未消费**——浏览页记住的仍是
`localStorage authz_s3_bucket`）、`local_root`（该服务配套的本地中转目录，空 = 用全局保存区
`AUTHZ_STORE_DIR`，清理器按行取值；接口可写但回显 item 里没有该字段）、`note`。

## 4. API 一览（全部在 `router.lua` 注册，前缀 `/_authz/api`）

统一响应形状：成功 `{"data": ...}`，失败 `{"error":{"code","message"}}`。

**每个接口都多了一个选配置的入参** `cfg`（query `?cfg=<id|cfg:id|name|env>`，
JSON body 端点也可以放 body 的 `cfg` 字段——前端 `admin/api.js` 的 `appendCfg` 两个位置
都塞，服务端归一化在 `router.lua` 的 `s3_config_by_ref`）：不传 = 默认项。
URL 形态 `/_authz/s3/<bucket>/<key>` 保持不变，多配置只靠 query 区分。

写接口（upload/mkdir/rename/remove）先过 `s3_scope` 可写范围白名单（见 §3
`AUTHZ_S3_WRITABLE_PATHS`）：范围外一律 `403` + `code=s3_read_only`。
判定口径：upload 看当前目录（dir 语义）；mkdir 看目标目录自身（允许在只读
父目录下首次创建范围内的目录）；rename **源 key 与目标 key 都要单独判一次**
（跨目录移动时目标 key 按 `new_path` 拼，见下），
remove 看目标条目（item 语义）。只读接口（列表/字节流）不受影响。

**auto-mkdir（默认 share 挂载祖先的自动补建）**：默认场景下可写前缀是
`share/<本机 LAN IP>`（`AUTHZ_S3_SHARE_ROOT` + `AUTHZ_HOST_LAN_IP` 拼出），挂载
祖先目录标记（`share/`、`share/<IP>/`）在首次写入前可能尚不存在。upload 带
query `mkdir=1`、`POST /api/s3/mkdir` 带 body 字段 "mkdir": 1 时，若请求路径位于
默认 share 条目之下、但缺失的挂载祖先目录标记尚未创建，后端先逐级补建
祖先再执行本次写。auto-mkdir **只补目标之上的祖先、不扩大可写范围**：范围外
请求（含带 `mkdir=1`）仍然 `403 s3_read_only`；**桶根（空 path）永不放行**——
`ensure_parents` 对空 dirpath 返回的是「根之下的全部条目」而不是「根的祖先」，
若不显式拒绝，带 `mkdir=1` 的上传会先补建 `share/` 标记再把对象写进只读桶根
（该绕过由断言 `live upload at bucket root with auto-mkdir rejected` 把守）；
`share/<IP>` 首次创建走「目标==条目自身」的 mkdir 请求，不需要根放行。
`AUTHZ_S3_WRITABLE_PATHS` 显式设置时默认 share 条目不存在，auto-mkdir 没有作用对象。

### `GET /api/s3`（info / 列表，只读）

- 查询参数：`bucket`（可选）、`path`（可选，目录前缀）、`token`（可选，翻页）。
- 不带 `bucket` → 桶列表：`data = { enabled, endpoint, region, buckets: [{name, creation_date, writable}], bucket: null, writable_roots: [...], writable_all: bool }`
  （`enabled=false` 时 `buckets` 为空数组、`endpoint`/`region` 为空串）。
- 带 `bucket` → 目录内容：`data = { items: [{name, type: "file"|"dir", size, mtime, writable}], bucket, path, truncated, next_token, writable }`（`data.writable`=当前目录可写，`items[].writable`=该条目可写，均由 `AUTHZ_S3_WRITABLE_PATHS` 判定）
  （目录在前、`type=dir` 且 `size=0/mtime=null`；`next_token` 无下一页时为 `null`）。
- 权限：任意非 guest 会话或 API Key；未配置时 200 + `enabled=false`。

### `POST /api/s3/upload`（admin 会话 + CSRF，或 admin 机器 Key）

- multipart/form-data，表单字段 `file`（可多个，单次 ≤64 个文件，单文件 ≤2GB）；
  查询参数 `bucket`、`path`、可选 `overwrite=1`、可选 `mkdir=1`（auto-mkdir，见上）。
- 201：`data = { uploaded: [{name, size}], skipped: [{name, reason}], path, bucket }`；
  同名冲突（未带 `overwrite`）的文件进 `skipped` 并计一次冲突；
  **全部文件都冲突 → 409**（前端据此弹覆盖确认，带 `overwrite=1` 重传）；
  一个文件都没收上来 → 422；非 multipart → 415。
- 实现：每个文件先落 `AUTHZ_S3_TMP_DIR` 暂存（`.s3-upload-*` 唯一名），
  `part_end` 时 HEAD 判冲突后 PUT 上 S3 并删除暂存。为什么必须落盘：
  S3 的 PUT 一旦发出就锁死 Content-Length，multipart 分段边界没法在
  「目标已存在」时给出与 files 一致的 409。

### `PUT /api/s3/rename`（admin 会话 + CSRF，或 admin 机器 Key）

- 请求体 `{ bucket, path, name, new_name, new_path? }`；200：
  `data = { renamed, new_name }`（目录改名另带 `objects` = 移动的对象数）。
  目标已存在 → 409；源 key 与目标 key 完全相同 → 400「新旧名称相同」；
  对象与同名目录都不存在 → 404；
  复制成功但原对象删除失败时明确报 502 并说明现在有两份。
- 普通对象 = CopyObject + DeleteObject；目录 = 逐对象 COPY 到新前缀 +
  整批删旧前缀（`walk_prefix` 翻页）。
- **可选 `new_path`（跨目录移动）**：目标目录，与 `path` 同语义（桶内相对前缀，
  已 `normalize_prefix`）。字段不传或为 JSON `null` = 原地改名，行为与旧版逐条相同；
  空串 = 桶根。`target = join(new_path or path, new_name)`，因此改名与移动可以在
  一次调用里同时生效；`new_name` 仍是单段叶子名（禁止 `/`），换目录只能靠 `new_path`。
  跨目录时成功响应额外带 `moved: true` 与 `new_path`（纯改名不带，保持旧形状）。
  新增的两条拒绝：
  - `new_path` 非法（含 `..`、控制字符、段过长）→ `400 invalid_path`，与 `path` 同一判定；
  - **前缀自嵌套** → `422`：目标 key 等于源 key 的目录形态或以 `key + "/"` 开头时，
    `copy_prefix` 会把整棵前缀复制进自己的子目录、数据先翻倍再删源，必须在复制前拒绝。
  写白名单是**双端点**判定（源 key + 目标 key），任一越界 → `403 s3_read_only`：
  只判源 key 就能把范围内的目录整棵挪出范围，或反向写进只读前缀。

### `POST /api/s3/mkdir`（admin 会话 + CSRF，或 admin 机器 Key）

- 请求体 `{ bucket, path, name, mkdir? }`（`mkdir: 1` = auto-mkdir，见上）；写一个 `key/` 结尾的 0 字节**目录标记对象**
  （S3 没有真目录）；201：`data = { path: <key/>, bucket }`。
  显式标记让空目录对其他人也可见（服务端的幻影标记只在它自己的列表里出现）。

### `DELETE /api/s3/remove`（admin 会话 + CSRF，或 admin 机器 Key）

- 请求体 `{ bucket, path, name, recursive? }`。
- 非递归：前缀下还有对象 → 409「目录非空，需勾选递归删除」（与 files 对齐）；
  空目录/单文件删除成功 → `data = { removed: 1, bucket, path, name }`。
- `recursive: true`：分批 DeleteObjects（每批 ≤1000）+ 目录标记逐个单 DELETE，
  200：`data = { removed: <数量>, errors: [...] }`（部分失败必须可见）。

### 字节流 `GET|HEAD /_authz/s3/<bucket>/<key>`（`s3_proxy.lua`）

- 认证与 `/_authz/files/` 同款（nginx access 门：会话或合法非 guest API Key，
  guest 引导诊断页，匿名 302 登录）。方法只允许 GET/HEAD（其他 405）。
- 查询参数：`?download=1` → `Content-Disposition: attachment`；
  `?authz_preview=1` → inline 且（仅 `text/html` 且正文 ≤2MB 时）向
  `</head>` 注入 Esc 转发脚本（沙箱 iframe 按键不冒泡，脚本 postMessage
  `authz-files-esc` 给父页面）；两个参数都缺 = 裸 URL 直读。
- **Content-Type 一律由网关按扩展名给**（`s3.content_type`，未识别回退
  `application/octet-stream`）：存储端不持久化 PUT 时给的类型。
- **Range 原样转发**，服务回 206 + `Content-Range`（视频拖进度条依赖它）；
  服务不回 `Accept-Ranges`，由网关补上。
- 安全头在 Lua 里下发：`Content-Security-Policy: sandbox allow-scripts
  allow-forms allow-popups allow-modals` + `X-Content-Type-Options: nosniff`
  （nginx 配置里**不能**再 `add_header`，会叠加出重复头，见 §6 j）。
- 缓存：预览（注入了脚本）`no-store`；其余 `private, max-age=3600`。
  透传 `Content-Length`/`Content-Range`/`ETag`/`Last-Modified`。
- 未配置 S3 时 423；路径解析先剥 query（否则 `?download=1` 会被签进 key），
  key 先 unescape 再挡 `..`/控制字符（`..%2F..%2Fetc` → 404）。
- 流式：64KB 块 `ngx.print` + `ngx.flush(true)`；只有干净读到 EOF 才把上游
  连接放回 keepalive 池，中途断开/读失败一律 close（防残留字节串流）。

## 5. 前端：files 与 s3 共享浏览器组件

- `admin/browser.js`（1061 行）+ `admin/browser.css` 是从 files 页面抽出的
  **共享浏览器组件**（挂载为 `window.authzBrowser`，模板 `<az-browser :adapter>`）：
  网格/列表视图、排序搜索、分页/加载下一页、图片/音频/视频/HTML/文本预览、
  键盘导航（预览浮层内 `f` 切全屏、`Backspace` 返回后焦点落在刚离开的目录上）、
  预览区手势、拖拽上传、重命名、删除、mkdir 等交互逻辑全在组件内；
  组件不引入任何新依赖，复用页面已加载的 Vue/Quasar/adminApi/adminI18n。
- 宿主页只提供 **adapter**（`list/upload/mkdir/rename/remove/itemUrl/itemPath`
  + `storagePrefix`/`i18nRoot`/`supportsMkdir`/`rootLabel`）与页面外壳：
  - `admin/files.html` 瘦身为外壳 + files 端点 adapter（`/_authz/files*`），
    `files.css` 只剩页特有规则（当前为空壳，样式全走 `browser.css`）；
  - `admin/s3.html` + `s3.css` 是 S3 外壳：未配置卡片、桶选择器（工具栏插槽，
    记住上次桶在 `localStorage authz_s3_bucket`）、**存储服务选择器**（多配置，见下条）、
    S3 adapter（`/_authz/api/s3*`，对象 URL 为 `/_authz/s3/<bucket>/<key>`）。
  - `admin/s3-configs.html` + `s3-configs.css` 是「存储配置」管理页（不在
    `browser.js` 组件之内）：上半区 `s3_configs` 行的 CRUD + 连通性测试 + 设为默认
    + 启停，下半区上传流水与「立即清理」。凭证字段只在填了才发（PATCH 空 = 不改）。
- **多配置选择器**：工具栏的「存储服务」下拉取 `GET /api/s3` 新增的 `data.configs`
  （缺失时另拉 `GET /api/s3-configs`，两个入口同源），值优先用 `id`；选中值记在
  `localStorage authz_s3_cfg`，并拼进 adapter 的**每个**请求（列表/上传/mkdir/
  rename/remove 与条目 URL 的 `?cfg=`）。info 返回后用 `data.cfg`（后端本次
  实际生效的配置）对齐本地选择，记住的 cfg 指向已删/已停用的服务时回落默认项重载一次。
  env 回落项在下拉里是 `id=0`/`virtual=true` 的只读行。
- i18n：`admin/i18n.js` 新增 `browser` 块（组件通用文案打底）与 `s3` 块
  （页面特有部分：未配置文案、桶选择），`menu.s3` = 对象存储 /
  Object Storage。文案合并规则 = browser 块打底、页面块覆盖同名键。
- 路由：`admin/app.js` 的 builtin 映射加 `s3: 's3.html?v=1'`；菜单由迁移
  `21:menu_entry_s3_browser` 写入 `menu_entries`（系统应用组，label=对象存储，
  icon=mdi-bucket，`builtin='s3'`，`admin_only=1`，sort_order=17）。
  多配置上线后再加 `s3Configs: 's3-configs.html?v=1'`，菜单入口由迁移
  `25:menu_entry_s3_configs` seed（系统应用组，label=存储配置，icon=mdi-cloud-cog，
  `builtin='s3Configs'`，`admin_only=1`，sort_order=18）：这个页面能编辑明文入库的
  S3 凭证，与「对象存储」「Nginx配置」同级，不给 staff 看到。
- **只读范围（写白名单）**：s3 adapter 声明 `supportsWritable: true` 后，
  组件按 `GET /api/s3` 的 `data.writable`（当前目录）与 `items[].writable`
  （每个条目）隐藏上传/新建目录/重命名/删除入口，只留下载/预览；
  范围外条目名旁显示 `mdi-lock`，目录只读时顶部一条 banner。files 页不声明
  该属性 → 恒可写，行为不变。后端仍独立 403（`s3_read_only`），前端只是省点击。
- **share 挂载默认值**：info（不带 bucket 的 `GET /api/s3`）回显 `share_prefix`
  （默认可写前缀，如 `share/10.252.25.241`；LAN IP 探测失败时为 `null`）与
  `share_bucket`（空串 = 任意桶）。s3 页在 info 返回后：当前桶命中 share 条目
  （`share_bucket` 为空或等于当前桶）且用户还没有浏览路径记录（`localStorage`
  无 `authz-s3_path`，az-browser 挂载时读到的初始路径）时，把初始路径预置为
  `share_prefix`，页面直接落在默认可写目录而不是只读的桶根。写操作统一带
  auto-mkdir 标记：adapter `upload` 传 `{ mkdir: true }`（query `mkdir=1`）、
  `mkdir` body 带 `mkdir: 1`，挂载祖先缺失时由后端补建（§4）。
- **回归测试断言迁移**：「手势处理」相关断言已从 `files.html` 改指
  `/_authz/apps/browser.js`（逻辑移进了共享组件），`section s3` 同时断言
  s3 页与 files 页都挂载 `window.authzBrowser`。
- 静态资源版本号（`?v=`，改动即递增；回归按当前版本号拉文件做断言）：
  `api.js` **v23**、`i18n.js` **v54**、`app.js` **v28**、`app.css` **v13**、
  `app-page.css` **v16**、`files.css` **v10**、`s3.css` **v2**、
  `s3-configs.css` / `nginx-conf.css` / `mdi-names.js` **v1**、`browser.js` **v13**、
  `browser.css` **v4**；页面自身版本
  由 `admin/app.js` 的 builtin 映射引用：`files.html` **v19**、`s3.html` **v5**、
  `s3-configs.html` **v1**、
  `authorization.html` **v16**、`menu-editor.html` **v11**、`users.html` **v7**、
  `nginx_conf.html` **v2**。

## 6. 私有 S3 服务实测坑清单（本集成落实的全部非标准行为）

以下每条都来自对目标私有服务的实测（`/data/tmp/s3-probe/contract.md`），
已在代码里逐条落实并加注释；换服务时先过一遍这份清单。

a. **不支持 `encoding-type=url`，列表 Key 是百分号编码**：带
   `encoding-type=url` 时该服务把 Key 里的 `/` 编成 `%2F` 且 `delimiter`
   分组直接失效（还不回 `EncodingType` 标签），等于没有目录——所以列表请求
   **绝不能带**该参数；而普通列表返回的 Key 本身仍是百分号编码的，
   任何把 Key 再用于删除/比对/拼 URL 的地方必须先 unquote（客户端脚本
   如 boto3 清理残留时同样要先 `urllib.parse.unquote(k['Key'])`，
   否则一个都删不掉）。

b. **幻影目录条目**：列表里会出现以 `/` 结尾的 Contents（实测 Size=16384、
   ETag 为空，GET 它返回 400）。它不是真对象，目录一律来自 CommonPrefixes，
   所以 `list_objects` 直接丢弃 `/` 结尾的 Contents；`walk_prefix` 默认也过滤
   （对前缀整体 COPY 会把 400 复制出来），只有递归删除需要它们才保留
   （`include_markers=true`）。

c. **CommonPrefixes 回显请求 prefix 自身**：照抄会出现「套自己的同名目录」。
   只接受严格长于请求 prefix 的条目。

d. **copy-source 与 COPY 型 PUT 的 body**：`x-amz-copy-source` 用 path-style
   必须带 `/bucket` 前缀并按与规范请求相同的规则逐段转义（`canonicalise_path`
   已含前导 `/`，不能再剥，少了分隔符会被解析成不存在的双段桶名 →
   NoSuchBucket）；COPY 型 PUT 的请求体是空的，但**必须显式传 `body=""`**
   ——resty.http 对 PUT 拒绝 nil body。

e. **对「真实文件 key + `/`」做 list 返回 500 InternalError**：把某个真实
   对象 key 当目录前缀去列表（如 `objectkey/`），服务直接 500。于是
   `has_objects_under` 与 `delete_prefix` 都把 500 判为「不是目录」：前者
   返回 false，后者回退成对 prefix 单个 DELETE（404 容忍）——递归删除
   「其实是文件」的条目因此无害且幂等。另注意：非空判断**不能**用带
   delimiter 的列表探针，该服务会先回幻影标记对象 `prefix/` 和 prefix 自身
   的 CommonPrefixes，`max-keys=1` 时第一条必然被过滤掉，非空目录会被误判
   成空目录（实测踩过，会把目录删掉）。

f. **DeleteObjects 跳过 `/` 目录标记**：批量删会清掉真对象却把 marker 留下
   （服务端把它们当派生条目，不级联清），目录在列表里永远去不掉。
   `delete_prefix` 因此把 `/` 结尾的 key 单独收集，逐个走单 DELETE。

g. **bucket 列表能力探测的降级路径**：`GET /api/s3`（含带 bucket 的列表请求）
   未配置时统一 200 + `enabled=false`，**不**返回 423——前端需要
   `enabled:false` 才能渲染「未配置」卡片；423 只留给桶级操作
   （upload/rename/remove/mkdir 与字节流）。回归测试断言以该行为为准。

h. **klib.router 只转发 2 个返回值**：handler 里 `return nil, err, status`
   三值返回会把 err 文案当成状态码（实测变空 200）。三值错误必须包成
   `guard.result(...)`（成功路径 `guard.result(data)` 自动包 `{data=...}`）。
   例外：`s3_context` 的 423 payload 必须**不**经 `guard.result` 原样透传
   （router 期待 `error_payload, status` 两个值，经包装会套出
   `{"data":{"error":...}}`）。

i. **项目 patterns 正则不支持 `{n,m}` 区间量词**：写了会被当字面量，
   任何桶名都匹配不上（实测把合法桶判成非法）。桶名校验因此用
   `#bucket` 长度判断（3–63）+ 字符集模式。

j. **CSP 只在 Lua 里下发**：`/_authz/s3/` 的 location 里不能再
   `add_header` CSP/nosniff，nginx 会叠加出重复头（且 reject() 分支
   也需要这些头）；`server.conf.template` 里有注释标注。

k. **上传 422「没有找到上传文件」= 暂存目录缺失**：镜像 entrypoint 只在
   容器启动时 `mkdir -p` 一次；如果实例用的镜像 entrypoint 早于该特性
   （典型：只读挂载仓库 lualib 但不挂 entrypoint 的测试实例），或运行期
   目录被清掉，`open_sink` 全部失败 → `written=0 && conflicts=0` → 整批
   422，skipped 理由「暂存目录不可写 /data/s3tmp」——mkdir 不经暂存目录
   所以照常成功，症状就是「能建目录、不能传文件」。修复：`s3_upload.lua`
   的 `ensure_tmp_dir()` 用 FFI `mkdir(2)` 逐级自建（EEXIST 视为成功），
   每次上传都检查、不缓存成功，目录再被删仍自愈；回归里有「删目录后
   上传仍 201 且目录被重建」的断言。

l. **不支持条件请求，网关不得转发 ETag/Last-Modified**：该服务对带
   `If-None-Match`/`If-Modified-Since` 的 GET 一律回 200 全量体。但如果
   网关把上游的 ETag/Last-Modified 抄进响应，nginx 的 not-modified
   过滤器会拿它们对客户端把 200 自动改写成 304——而 `content_by_lua`
   此刻已在流式输出，后续 `ngx.print` 全部失败（error.log 刷
   「attempt to set status 500 via ngx.exit after sending out 304」）。
   现在字节流响应只抄 `Content-Length`/`Content-Range`，写失败即收尾。

## 7. 活体测试（`test/test_authz_gateway.sh`）

- `section s3`（**始终运行**）：未配置降级语义
  （info 200+enabled=false、带 bucket 同样降级、字节流 423）、
  未登录 401/302、无 CSRF 403、**admin 机器 Key 免会话抵达写接口**（未配置时
  表现为 423 s3_disabled，证明门禁放行）、**非 admin 角色 Key 仍 403**、
  菜单 seed（builtin=s3、label=对象存储）、s3.html 与 files.html
  都挂载共享组件。
- `section s3-live`（需真实服务）：临时起一个带 S3 env 的
  网关容器，跑完整生命周期——info/桶列表、上传 201、列表命中、字节回读
  （含 Content-Type 与 sandbox CSP）、Range 206、`?download=1` 的
  Content-Disposition、路径穿越 404、同名 409、
  覆盖 201、rename、mkdir 显示为目录、子目录上传、非空目录删 409、
  递归删除、清理后前缀为空（空前缀列表必须 200：array_data 把空 items 换成 cjson.empty_array 后不能再 ipairs，否则整个请求 500）、字节响应不带 ETag/Last-Modified
  - **跨目录移动（`new_path`）**：纯移动（`new_name`=`name`）与「移动 + 改名」各自
    200 并回读校验（源 404、目标 200）；**目标 key 越出可写范围（桶根）→
    `403 s3_read_only`，且源对象仍在原地**（证明目标 key 单独判了 item_writable）；
    前缀移入自身子树 → 422 且没有留下翻倍副本；`new_path` 含 `..` →
    `400 invalid_path`；目标同名 → 409 且不覆盖；不带 `new_path` 的旧改名调用
    响应形状不变（无 `moved`/`new_path`）；`new_path: null` 等价于不传
    （否则会被拼成名为 `null` 的目录段）。
  - **机器 Key 免登录链路**：admin Key 无 Cookie 无 CSRF 直接完成移动；无凭证 → 401；
    guest 角色 Key → 403。
  （防 nginx 伪造 304）、`rm -rf` 暂存目录后上传仍 201 且目录被重建（自愈）。（默认可写范围=share/<AUTHZ_HOST_LAN_IP>：share 根 mkdir 403（含带 `mkdir:1`）、范围内首建 201、范围外写 403 s3_read_only、**桶根带 mkdir=1 的上传仍 403（防 auto-mkdir 绕过）**、列表/桶/info 的 writable 标记与 writable_roots 回显、info 的 share_prefix/share_bucket 回显、auto-mkdir：upload `mkdir=1` 补建缺失挂载祖先 201 且目录可列可写、范围外带 `mkdir=1` 仍 403、mkdir 接口 `mkdir` 字段被接受）
  凭据只从环境注入（绝不进仓库）：
  `AUTHZ_S3_TEST_ENDPOINT` / `AUTHZ_S3_TEST_BUCKET` / `AUTHZ_S3_TEST_KEY` /
  `AUTHZ_S3_TEST_SECRET` / 可选 `AUTHZ_S3_TEST_REGION`；缺任一即跳过（计 1 pass）。

跑法（全量含 s3-live 一次通过；实测计数见仓库回归记录，日志
`/data/tmp/move_gw2.log` 在 241.t）：

```bash
export OPENRESTY_TEST_IMAGE=authz:latest
export AUTHZ_S3_TEST_ENDPOINT=http://<s3-host>:<port>
export AUTHZ_S3_TEST_BUCKET=<bucket>
export AUTHZ_S3_TEST_KEY=<akid>
export AUTHZ_S3_TEST_SECRET=<secret>
# export AUTHZ_S3_TEST_REGION=RegionOne   # 默认 us-east-1
bash test/test_authz_gateway.sh
```

## 8. 已知限制与风险

- **明文 HTTP 内网**：实测环境走 `http://`（需 `AUTHZ_S3_ALLOW_HTTP=true`
  显式放行），AKID/SECRET 以 header 签名形式在内网传输，公网不可用。
- **上传经容器 `AUTHZ_S3_TMP_DIR` 中转**：每个文件先完整落盘再 PUT；
  暂存目录与 `/data` 同卷时最省 IO，独立小盘会先爆盘再报错。
  单文件 2GB 上限、单次 64 个文件；更大文件理论可走 S3 multipart upload，
  本版未实现（直接跳过并说明原因）。
- **无版本化**：重命名 = Copy + Delete，复制成功但删除失败时
  会留两份并明确报错；删除不可恢复（递归删除前必须显式勾选）。
  「无生命周期」这条已经不再成立：网关侧有 DB 记账 + 每小时定时清理器（§9），
  存储端 lifecycle 仍然只在显式勾选 `use_bucket_lifecycle` 时才由桶规则负责。
  注意 rename/move 只给**源** key 闭账，不给目标 key 补新流水（目标的字节不是本
  网关写入的，没有可信 size/归属）——目标对象因此不在 TTL 队列里，回收交给桶生命周期
  或下一次经本网关的上传记账，这是已知缺口。
- **不做服务端加密**：网关不做额外加密层，对象以服务端原样存储。
- **存储端不持久化 Content-Type**：永远存成 octet-stream，预览/下载的类型
  全靠网关按扩展名推断；上传时给的 `Content-Type` 头只是装饰。
- 换用标准 AWS S3 时，§6 的坑大多不适用，但 vendored 签名器、
  UNSIGNED-PAYLOAD 补丁与本服务的 list/delete 语义仍按本服务的契约实现，
  直接互换 endpoint 前应先重跑一遍 probe 契约。

## 9. 上传记账与小时级过期清理（`upload_records` + `maintenance.lua`）

**为什么要自己记账**：S3 官方 bucket lifecycle 的粒度只到**天**，而且执行是异步的
（规则命中后由存储端在不确定时间后台删），做不了「上传 6 小时后必须消失」这种需求。
所以小时级过期只能走 DB 记账 + 网关自己的定时器；存储端生命周期规则仍然可用，
两种模式由每套配置各自勾选，互不打架。

迁移 `24:upload_records` 建流水账表，每次经网关写入都记一行：

| 列 | 口径 |
|----|------|
| `kind` | `s3` = 对象存储对象（按 `cfg_id` 找回配置删对象）；`local` = 本机保存区文件（`key` 存相对路径） |
| `cfg_id` | 关联 `s3_configs.id`；**NULL = 当时用的是 env 回落配置**（不加外键：配置行删了流水必须留着可审计，且记账时 env 项的虚拟 id=0 必须写 NULL，否则 `cfg_id=0` 指向不存在的行会被判孤儿） |
| `expires_at` | NULL = 永不过期（不入队）；非 NULL 必须**整点对齐**（`s3_config_store.align_expiry`：`floor(now/3600)*3600 + n*3600`）。对齐才能保证「同一小时写入的一批在同一小时被删」，不让索引区间扫退化成一堆边界行 |
| `state` | `active`（待删）→ `deleted`（删成功）→ `failed`（删除报错或成孤儿，`last_error` 记原因，**不再重试**，是「要人工看一眼」的信号）；`skipped` = 该配置勾了 `use_bucket_lifecycle`，只记账不删，不进队列 |
| `source` / `created_by` | 浏览器会话上传记 `upload`、机器 Key 记 `api`/`multipart`；`created_by` 存身份名，可审计 |

清理器 `lualib/resty/authz/maintenance.lua` 每小时跑一轮（`GC_INTERVAL=3600`，
启动后 `GC_DELAY=60` 跑第一轮，单轮上限 `MAX_PER_ROUND=500` 行，剩下下一轮继续）：

- **单 owner**：`init_worker_by_lua_block` 里每个 worker 都调 `start()`，用共享字典
  `authz_cache` 的原子 `add` 抢 owner 锁（TTL = 一轮间隔，每轮续期），只有抢到的 worker
  挂定时器。owner worker 崩掉后由 **worker 0** 检查 `/proc/<pid>` 判活并接管（限定单一
  候选者是因为共享字典没有 CAS，`delete + add` 不原子，两个 worker 同时接管会各跑一份）；
  接管不了就最坏空转一小时。手动触发清理调 `cleanup()`（纯函数），**不要调 `tick()`**
  （它会种下第二个每小时循环）。
- HTTP 删除全部在事务**之外**做，状态回填攒到最后一次 `db.transaction` 提交
  （事务里持有写锁跨网络请求 = 长事务；且每跑一次 `db.exec` 就 bump 一次 `db_rev`，
  逐行 UPDATE 会把 mlcache 键刷爆）。
- 同配置同桶的行攒成一批走 `DeleteObjects`；`local` 行逐条删（无批量接口）。
- 顺带扫上传暂存残留（`.upload-` / `.s3-upload-` / `.tmp-` / `tmp-` 前缀，
  mtime 超过 6 小时才算残留；`AUTHZ_S3_TMP_DIR`、`/data/s3tmp` 字面值、
  `AUTHZ_FILES_ROOT`、保存区四处都扫，单层、不跟随符号链接）。

`expires_hours` 与 `use_bucket_lifecycle` 都是**每套配置各自一份**的字段：
前者是小时数（0 = 永不过期，上限 8760）；后者为真时新流水一出生就是 `skipped`，
清理器也会跳过它（重复删反而和桶规则打架），但 `DELETE /api/uploads/:id` 这类
明确的人工意志照删。

**记账永不改变上传结果**：对象已经写成功，流水只是账本，所以记账整段 `pcall` +
失败只 `ngx.log(WARN)`。反过来「账没闭上」是可见的（`502` + 原因），不静默。

配置行被删除时的处理：该配置下仍处于 `active` 的流水当场标 `failed` +
`last_error='config removed'`（凭证已消失，对象再也删不到，但记录保留可审计）；
只是被禁用（`enabled=0`）不算孤儿，重新启用后仍能删。

接口与手动触发方式见 `docs/core-api.md` §6.3。
