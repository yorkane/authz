# 对象存储浏览（S3 兼容）集成说明

本文档描述 Authz Gateway 的「对象存储」内置应用：网关侧代签 SigV4，把私有
S3 兼容服务变成管理界面里的一个浏览器应用。行为细节与实测契约以代码
（`lualib/resty/authz/s3.lua`、`s3_proxy.lua`、`s3_upload.lua`、
`lualib/resty/aws/request/signatures/`）为准。

## 1. 目标与边界

- **凭证只在网关侧**：AKID/SECRET 由 `config.lua` 从环境变量读入，仅存在于
  签名器内部；所有 API 与页面都不回显凭证。浏览器只拿会话（或 API Key）
  访问 `/_authz/api/s3*` 与 `/_authz/s3/<bucket>/<key>`，签名发生在网关 worker 内。
- **未配置的降级语义**（`config.lua` 未设 `AUTHZ_S3_ENDPOINT` 时 `config.s3 == nil`）：
  - 菜单始终可见（迁移 `21:menu_entry_s3_browser` 无条件 seed 系统应用组下的
    「对象存储」入口，`admin_only=1`）；
  - `GET /api/s3`（含带 `bucket` 参数的列表请求）统一返回 `200` +
    `data.enabled=false`，前端据此显示「对象存储未配置」卡片——信息接口
    永远是 200，降级语义只由它表达；
  - 其余桶级接口（`share`/`upload`/`rename`/`remove`/`mkdir`）与字节流
    `/_authz/s3/...` 返回 `423`（`code=s3_disabled`）。写接口的
    认证/CSRF/会话门禁先于 423 生效（403/401 优先）。
- **权限模型**：只读的 `GET /api/s3`（info/list）对任何已登录非 guest 会话或
  合法 API Key 开放；`GET /api/s3/share`（生成 presigned 链接）同样只读开放；
  `upload`/`rename`/`remove`/`mkdir` 要求 `admin + 浏览器会话 + X-CSRF-Token`
  （`session_only=true`，机器 Key 一律 403，与 nginx 配置编辑器同级，
  迁移注释里写明「不给 staff 看到」）；字节流 `/_authz/s3/` 的 access 门与
  `/_authz/files/` 完全同款（会话或合法非 guest API Key 放行，guest 引导到
  诊断页，匿名跳登录）。

## 2. Vendored 签名器（Kong/lua-resty-aws）

只引入上游签名子集，**不引入整套库**，因此**不需要** `AWS_EC2_METADATA_DISABLED`
（凭证链根本不存在，也不会去探测 EC2 metadata）：

| 文件 | 来源 |
|------|------|
| `lualib/resty/aws/request/signatures/v4.lua` | Kong/lua-resty-aws **1.7.2（commit a73c39c）**，Apache-2.0 |
| `lualib/resty/aws/request/signatures/presign.lua` | 同上 |
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

## 3. 环境变量（`config.lua`，启动期校验）

| 变量 | 默认 | 含义 / 约束 |
|------|------|------------|
| `AUTHZ_S3_ENDPOINT` | 空（= 功能关闭） | `http(s)://<host>[:<port>]`，**path-style、不能带路径**，尾部 `/` 自动剥除；设了它但缺 AKID/SECRET 直接启动报错 |
| `AUTHZ_S3_REGION` | `us-east-1` | SigV4 credential scope 的 region 段；不允许空白/控制字符、≤64 字符 |
| `AUTHZ_S3_ACCESS_KEY_ID` | 空 | endpoint 已设时必填（不得含空白/控制字符） |
| `AUTHZ_S3_SECRET_ACCESS_KEY` | 空 | endpoint 已设时必填（不得含空白/控制字符） |
| `AUTHZ_S3_ALLOW_HTTP` | `false` | endpoint 为明文 `http` 时必须显式置 `true`，否则**启动报错**（防止误以为在走 TLS） |
| `AUTHZ_S3_TMP_DIR` | `/data/s3tmp` | 上传中转暂存目录（容器内路径，需可写；与 `/data` 同卷最省 IO）。`docker-entrypoint.sh` 在 endpoint 已设时自动 `mkdir -p`；即使 entrypoint 是旧版或目录运行期被清掉，上传路径每次也会先逐级自建（见 §6.k） |
| `AUTHZ_S3_WRITABLE_PATHS` | 空（= 默认本机局域网 IP） | **可写范围白名单**（逗号分隔）。上传/建目录/重命名/删除只允许落在范围内；范围外一律只读（仍可浏览、预览、下载、分享）。条目语义：`noco`=整桶、`noco/rpa`=该桶内前缀、`*/docs`=任意桶内前缀、无分隔符条目（如 LAN IP）=同名整桶或任意桶内该路径前缀。`/` 或 `*` = 全部可写；条目含 `..`/控制字符/`?`/`#` 启动报错 |
| `AUTHZ_HOST_LAN_IP` | 空（= 自动探测） | 覆盖「本机局域网 IP」的探测值（非 host 网络或测试用）。探测用 FFI UDP connect 到保留地址选路由源地址，不发包；探测失败且未设本变量时**整体降级为只读**并告警 |

| `AUTHZ_S3_SHARE_TTL` | `3600` | 分享 presigned URL 有效期（秒），钳制在 **60–604800** |
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

## 4. API 一览（全部在 `router.lua` 注册，前缀 `/_authz/api`）

统一响应形状：成功 `{"data": ...}`，失败 `{"error":{"code","message"}}`。

写接口（upload/mkdir/rename/remove）先过 `s3_scope` 可写范围白名单（见 §3
`AUTHZ_S3_WRITABLE_PATHS`）：范围外一律 `403` + `code=s3_read_only`。
判定口径：upload 看当前目录（dir 语义）；mkdir 看目标目录自身（允许在只读
父目录下首次创建范围内的目录）；rename 源与目标都要可写，
remove 看目标条目（item 语义）。只读接口（列表/share/字节流）不受影响。

### `GET /api/s3`（info / 列表，只读）

- 查询参数：`bucket`（可选）、`path`（可选，目录前缀）、`token`（可选，翻页）。
- 不带 `bucket` → 桶列表：`data = { enabled, endpoint, region, buckets: [{name, creation_date, writable}], bucket: null, writable_roots: [...], writable_all: bool }`
  （`enabled=false` 时 `buckets` 为空数组、`endpoint`/`region` 为空串）。
- 带 `bucket` → 目录内容：`data = { items: [{name, type: "file"|"dir", size, mtime, writable}], bucket, path, truncated, next_token, writable }`（`data.writable`=当前目录可写，`items[].writable`=该条目可写，均由 `AUTHZ_S3_WRITABLE_PATHS` 判定）
  （目录在前、`type=dir` 且 `size=0/mtime=null`；`next_token` 无下一页时为 `null`）。
- 权限：任意非 guest 会话或 API Key；未配置时 200 + `enabled=false`。

### `POST /api/s3/upload`（admin + 会话 + CSRF）

- multipart/form-data，表单字段 `file`（可多个，单次 ≤64 个文件，单文件 ≤2GB）；
  查询参数 `bucket`、`path`、可选 `overwrite=1`。
- 201：`data = { uploaded: [{name, size}], skipped: [{name, reason}], path, bucket }`；
  同名冲突（未带 `overwrite`）的文件进 `skipped` 并计一次冲突；
  **全部文件都冲突 → 409**（前端据此弹覆盖确认，带 `overwrite=1` 重传）；
  一个文件都没收上来 → 422；非 multipart → 415。
- 实现：每个文件先落 `AUTHZ_S3_TMP_DIR` 暂存（`.s3-upload-*` 唯一名），
  `part_end` 时 HEAD 判冲突后 PUT 上 S3 并删除暂存。为什么必须落盘：
  S3 的 PUT 一旦发出就锁死 Content-Length，multipart 分段边界没法在
  「目标已存在」时给出与 files 一致的 409。

### `PUT /api/s3/rename`（admin + 会话 + CSRF）

- 请求体 `{ bucket, path, name, new_name }`；200：`data = { renamed, new_name }`
  （目录改名另带 `objects` = 移动的对象数）。目标已存在 → 409；
  新旧同名 → 400；对象与同名目录都不存在 → 404；
  复制成功但原对象删除失败时明确报 502 并说明现在有两份。
- 普通对象 = CopyObject + DeleteObject；目录 = 逐对象 COPY 到新前缀 +
  整批删旧前缀（`walk_prefix` 翻页）。

### `POST /api/s3/mkdir`（admin + 会话 + CSRF）

- 请求体 `{ bucket, path, name }`；写一个 `key/` 结尾的 0 字节**目录标记对象**
  （S3 没有真目录）；201：`data = { path: <key/>, bucket }`。
  显式标记让空目录对其他人也可见（服务端的幻影标记只在它自己的列表里出现）。

### `DELETE /api/s3/remove`（admin + 会话 + CSRF）

- 请求体 `{ bucket, path, name, recursive? }`。
- 非递归：前缀下还有对象 → 409「目录非空，需勾选递归删除」（与 files 对齐）；
  空目录/单文件删除成功 → `data = { removed: 1, bucket, path, name }`。
- `recursive: true`：分批 DeleteObjects（每批 ≤1000）+ 目录标记逐个单 DELETE，
  200：`data = { removed: <数量>, errors: [...] }`（部分失败必须可见）。

### `GET /api/s3/share`（只读）

- 查询参数 `bucket`、`path`、`name`、可选 `download=1`。
- 200：`data = { url, expires_in }`；`url` 是 presigned GET（签名在 query，
  到期自动失效），有效期 = `AUTHZ_S3_SHARE_TTL`。
- 永远带 `response-content-type` + `response-content-disposition`：
  存储端不持久化 Content-Type（全是 octet-stream），不覆盖的话浏览器
  只会当二进制下载，图片/视频无法内联。`download=1` 时 disposition=attachment、
  type=octet-stream，否则 inline + 按扩展名推断的类型。

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
  键盘导航、预览区手势、拖拽上传、重命名、删除、mkdir、分享等交互逻辑全在组件内；
  组件不引入任何新依赖，复用页面已加载的 Vue/Quasar/adminApi/adminI18n。
- 宿主页只提供 **adapter**（`list/upload/mkdir/rename/remove/itemUrl/itemPath/shareUrl`
  + `storagePrefix`/`i18nRoot`/`supportsMkdir`/`rootLabel`）与页面外壳：
  - `admin/files.html` 瘦身为外壳 + files 端点 adapter（`/_authz/files*`），
    `files.css` 只剩页特有规则（当前为空壳，样式全走 `browser.css`）；
  - `admin/s3.html` + `s3.css` 是 S3 外壳：未配置卡片、桶选择器（工具栏插槽，
    记住上次桶在 `localStorage authz_s3_bucket`）、S3 adapter
    （`/_authz/api/s3*`，对象 URL 为 `/_authz/s3/<bucket>/<key>`）。
- i18n：`admin/i18n.js` 新增 `browser` 块（组件通用文案打底）与 `s3` 块
  （页面特有部分：未配置文案、桶选择、分享），`menu.s3` = 对象存储 /
  Object Storage。文案合并规则 = browser 块打底、页面块覆盖同名键。
- 路由：`admin/app.js` 的 builtin 映射加 `s3: 's3.html?v=1'`；菜单由迁移
  `21:menu_entry_s3_browser` 写入 `menu_entries`（系统应用组，label=对象存储，
  icon=mdi-bucket，`builtin='s3'`，`admin_only=1`，sort_order=17）。
- **只读范围（写白名单）**：s3 adapter 声明 `supportsWritable: true` 后，
  组件按 `GET /api/s3` 的 `data.writable`（当前目录）与 `items[].writable`
  （每个条目）隐藏上传/新建目录/重命名/删除入口，只留下载/分享/预览；
  范围外条目名旁显示 `mdi-lock`，目录只读时顶部一条 banner。files 页不声明
  该属性 → 恒可写，行为不变。后端仍独立 403（`s3_read_only`），前端只是省点击。
- **回归测试断言迁移**：「手势处理」相关断言已从 `files.html` 改指
  `/_authz/apps/browser.js`（逻辑移进了共享组件），`section s3` 同时断言
  s3 页与 files 页都挂载 `window.authzBrowser`。
- 静态资源版本号（`?v=`）：`api.js` **v21**、`i18n.js` **v45**、`app.js` **v27**、
  `app-page.css` **v16**、`files.css` **v10**、`files.html` **v17**；新增
  `browser.js` / `browser.css` / `s3.html` / `s3.css` 均为 **v1**。

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
   （share/upload/rename/remove/mkdir 与字节流）。回归测试断言以该行为为准。

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

- `section s3`（**始终运行**，18 项断言）：未配置降级语义
  （info 200+enabled=false、带 bucket 同样降级、share/字节流 423）、
  未登录 401/302、无 CSRF 403、机器 Key 拒绝写接口 403、
  菜单 seed（builtin=s3、label=对象存储）、s3.html 与 files.html
  都挂载共享组件。
- `section s3-live`（52 项断言，需真实服务）：临时起一个带 S3 env 的
  网关容器，跑完整生命周期——info/桶列表、上传 201、列表命中、字节回读
  （含 Content-Type 与 sandbox CSP）、Range 206、`?download=1` 的
  Content-Disposition、路径穿越 404、presign 链接可直取 200、同名 409、
  覆盖 201、rename、mkdir 显示为目录、子目录上传、非空目录删 409、
  递归删除、清理后前缀为空（空前缀列表必须 200：array_data 把空 items 换成 cjson.empty_array 后不能再 ipairs，否则整个请求 500）、机器 Key 403、字节响应不带 ETag/Last-Modified
  （防 nginx 伪造 304）、`rm -rf` 暂存目录后上传仍 201 且目录被重建（自愈）。（默认可写范围=容器内 AUTHZ_HOST_LAN_IP 前缀：范围外写 403 s3_read_only、列表/桶/info 的 writable 标记与 writable_roots 回显）
  凭据只从环境注入（绝不进仓库）：
  `AUTHZ_S3_TEST_ENDPOINT` / `AUTHZ_S3_TEST_BUCKET` / `AUTHZ_S3_TEST_KEY` /
  `AUTHZ_S3_TEST_SECRET` / 可选 `AUTHZ_S3_TEST_REGION`；缺任一即跳过（计 1 pass）。

跑法（当前全量 **1131 项**检查通过，日志 `/data/tmp/s3-wr/full-run9.log`）：

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
- **无版本化 / 无生命周期**：重命名 = Copy + Delete，复制成功但删除失败时
  会留两份并明确报错；删除不可恢复（递归删除前必须显式勾选）。
- **presign 链接最长 7 天**（`AUTHZ_S3_SHARE_TTL` 钳制 60–604800），
  且链接是明文 HTTP 的直链，有效期内任何拿到 URL 的人可读该对象
  （不带网关认证）；分享即等于交出该对象。
- **不做服务端加密**：网关不做额外加密层，对象以服务端原样存储。
- **存储端不持久化 Content-Type**：永远存成 octet-stream，预览/下载的类型
  全靠网关按扩展名推断；上传时给的 `Content-Type` 头只是装饰。
- 换用标准 AWS S3 时，§6 的坑大多不适用，但 vendored 签名器、
  UNSIGNED-PAYLOAD 补丁与本服务的 list/delete 语义仍按本服务的契约实现，
  直接互换 endpoint 前应先重跑一遍 probe 契约。
