--- Private S3 (S3-compatible) client for the gateway's object-storage browser.
---
--- 签名复用 vendored 的 lua-resty-aws SigV4（resty.aws.request.signatures），其余
--- （HTTP 收发、XML 解析、目录语义）自写。为什么不整库 vendor：上游要解析 ListBuckets /
--- ListObjectsV2 就得拖进 Penlight + luatz + luaexpat（68 文件 1.4MB），而镜像里没有
--- luaexpat，整库反而跑不起来；这台服务的响应结构很简单，模式匹配解析更小更可控。
---
--- 全部实现约束来自实测契约 /data/tmp/s3-probe/contract.md（要点也写进 doc/）：
---   * path-style + 固定 region，HTTP 明文由 AUTHZ_S3_ALLOW_HTTP 显式放行
---   * 列表请求绝不能带 encoding-type=url：该服务会把 Key 里的 / 编成 %2F 且
---     delimiter 分组直接失效（还不回 EncodingType 标签），等于没有目录
---   * 上传走 UNSIGNED-PAYLOAD（定长 Content-Length），实测回读字节逐字节一致
---   * 存储端不持久化 Content-Type（永远存成 octet-stream），所以预览/下载的
---     内容类型一律由网关按扩展名给，否则浏览器不会内联渲染图片/播放视频
local http = require "resty.http"
local prepare_awsv4_request = require "resty.aws.request.signatures.v4"
local presign_awsv4_request = require "resty.aws.request.signatures.presign"
local utils = require "resty.aws.request.signatures.utils"

local _M = {}

_M.UNSIGNED_PAYLOAD = "UNSIGNED-PAYLOAD"
_M.MAX_KEYS = 1000              -- ListObjectsV2 协议单页上限
_M.DELETE_BATCH = 1000          -- DeleteObjects 协议单次上限
local KEEPALIVE_POOL = 30

-- ── 签名配置 ────────────────────────────────────────────────────────────────
local function endpoint_authority(host, port, tls)
    local default_port = tls and 443 or 80
    return port == default_port and host or (host .. ":" .. port)
end

_M.endpoint_authority = endpoint_authority

--- 静态凭证。故意不用上游的默认凭证链：它会去探测 EC2 metadata
--- （169.251.x 同理），每请求白等 5 秒，还得额外设 AWS_EC2_METADATA_DISABLED。
local function credentials(cfg)
    return {
        get = function()
            return true, cfg.access_key_id, cfg.secret_access_key, nil
        end,
    }
end

local function signer_config(cfg)
    return {
        credentials = credentials(cfg),
        endpointPrefix = "s3",      -- SigV4 credential scope 的 service 段
        region = cfg.region,
        signatureVersion = "s3",    -- 打开上游 S3 分支（携带 x-amz-content-sha256）
        tls = cfg.tls,
        ssl_verify = false,
    }
end

-- ── 路径 / 名称校验 ─────────────────────────────────────────────────────────
--- “目录”前缀清洗：拒绝穿越与控制字符；返回 "" 表示桶根。语义与 files.normalize 对齐。
function _M.normalize_prefix(rel)
    rel = tostring(rel or "")
    if rel:find("[%c\\]") then return nil end
    local segments = {}
    for segment in rel:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return nil end
        if #segment > 1023 then return nil end
        segments[#segments + 1] = segment
    end
    return table.concat(segments, "/")
end

--- 叶子名：不允许含 /（目录段一律走 path 参数），否则可以越界删改别的对象。
function _M.normalize_name(name)
    name = tostring(name or "")
    if name == "" or #name > 1023 then return nil end
    if name:find("[%c\\]") or name:find("/", 1, true) then return nil end
    return name
end

--- 桶名：S3 规则的小写子集，够挡住注入与超长。
--- 长度不用 Lua 模式里的 {n,m} 表达：LuaPatterns 不支持区间量词，写了会当字面量，
--- 结果任何桶名都匹配不上（实测把合法桶判成非法）。
function _M.normalize_bucket(bucket)
    bucket = tostring(bucket or "")
    if #bucket < 3 or #bucket > 63 then return nil end
    if not bucket:match("^[a-z0-9][a-z0-9%.%-]*[a-z0-9]$") then return nil end
    return bucket
end

--- 拼 key：path 与 name 均已清洗。
function _M.join(path, name)
    path = tostring(path or "")
    if path == "" then return tostring(name or "") end
    if name == nil or name == "" then return path end
    return path .. "/" .. name
end

-- ── 极简 XML 读取 ───────────────────────────────────────────────────────────
-- 只提取“标签内文本”并还原实体。这台服务的响应无命名空间、无嵌套同名标签，
-- 模式匹配足够；luaexpat 不在镜像里，装它要重编镜像。
local ENTITIES = {
    ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">", ["&quot;"] = '"', ["&apos;"] = "'",
}

local function xml_unescape(text)
    if not text then return nil end
    text = text:gsub("&[a-z]+;", ENTITIES)
    text = text:gsub("&#(%d+);", function(code)
        local byte = tonumber(code)
        return byte and byte <= 255 and string.char(byte) or ""
    end)
    return text
end

local function xml_text(body, tag)
    return body:match("<" .. tag .. ">(.-)</" .. tag .. ">")
end

local function xml_blocks(body, tag)
    local out = {}
    for block in body:gmatch("<" .. tag .. ">(.-)</" .. tag .. ">") do
        out[#out + 1] = block
    end
    return out
end

local function xml_escape(text)
    text = tostring(text or "")
    return text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end

_M.xml_text, _M.xml_blocks, _M.xml_unescape, _M.xml_escape =
    xml_text, xml_blocks, xml_unescape, xml_escape

-- ── 时间戳 ──────────────────────────────────────────────────────────────────
-- ISO8601（2026-09-23T03:45:12.000Z）→ Unix 秒。自己算 civil days 而不用 os.time：
-- luajit 的 os.time 把字段表按本地时区解释，容器时区一变列表时间就整体漂移。
local function days_from_civil(y, m, d)
    y = m <= 2 and y - 1 or y
    local era = math.floor((y >= 0 and y or y - 399) / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function iso8601_to_epoch(text)
    local y, mo, d, h, mi, s = tostring(text or ""):match(
        "^(%d%d%d%d)%-(%d%d)%-(%d%d)T?(%d?%d):?(%d?%d):?(%d?%d)")
    if not y then return nil end
    return days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
        + (tonumber(h) or 0) * 3600 + (tonumber(mi) or 0) * 60 + (tonumber(s) or 0)
end

_M.iso8601_to_epoch = iso8601_to_epoch

-- ── Content-Type ────────────────────────────────────────────────────────────
local MIME = {
    png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg", gif = "image/gif",
    webp = "image/webp", svg = "image/svg+xml", avif = "image/avif", bmp = "image/bmp",
    ico = "image/x-icon", heic = "image/heic",
    mp4 = "video/mp4", m4v = "video/mp4", mov = "video/quicktime", mkv = "video/x-matroska",
    webm = "video/webm", avi = "video/x-msvideo", ts = "video/mp2t",
    mp3 = "audio/mpeg", m4a = "audio/mp4", aac = "audio/aac", ogg = "audio/ogg",
    opus = "audio/opus", wav = "audio/wav", flac = "audio/flac",
    html = "text/html; charset=utf-8", htm = "text/html; charset=utf-8",
    css = "text/css; charset=utf-8", js = "text/javascript; charset=utf-8",
    mjs = "text/javascript; charset=utf-8", json = "application/json; charset=utf-8",
    jsonl = "application/x-ndjson", xml = "text/xml; charset=utf-8",
    txt = "text/plain; charset=utf-8", md = "text/plain; charset=utf-8",
    csv = "text/csv; charset=utf-8", tsv = "text/tab-separated-values; charset=utf-8",
    log = "text/plain; charset=utf-8", yaml = "text/plain; charset=utf-8",
    yml = "text/plain; charset=utf-8", ini = "text/plain; charset=utf-8",
    conf = "text/plain; charset=utf-8", sh = "text/plain; charset=utf-8",
    pdf = "application/pdf", zip = "application/zip", gz = "application/gzip",
    tgz = "application/gzip", bz2 = "application/x-bzip2", xz = "application/x-xz",
    tar = "application/x-tar", ["7z"] = "application/x-7z-compressed",
    rar = "application/vnd.rar", wasm = "application/wasm",
    woff = "font/woff", woff2 = "font/woff2", ttf = "font/ttf", otf = "font/otf",
    epub = "application/epub+zip",
    docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    pptx = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    doc = "application/msword", xls = "application/vnd.ms-excel",
    ppt = "application/vnd.ms-powerpoint",
}

function _M.content_type(key)
    local ext = tostring(key or ""):match("%.([%w]+)$")
    return ext and MIME[ext:lower()] or "application/octet-stream"
end

-- ── 请求构造与传输 ──────────────────────────────────────────────────────────
--- 组装并签名一个请求。opts:
---   method / bucket / key / query(table) / headers(table)
---   body(string) / unsigned(true=上传,payload 以 UNSIGNED-PAYLOAD 参与签名)
function _M.prepare(cfg, opts)
    local key = opts.key or ""
    local raw_path = "/" .. (opts.bucket or "") .. (key == "" and "" or "/" .. key)
    -- 交给上游逐段 percent-encode：path-style 下 key 里的 / 必须保留，空格等要转义，
    -- 且“参与签名的请求行”与“实际发出的请求行”必须逐字节一致，所以这里不能走
    -- ngx.encode_args（它把空格编成 +，签名即失效）。
    local canonical_uri = utils.canonicalise_path(raw_path)
    local headers = opts.headers or {}
    if opts.unsigned then
        -- 覆盖 v4.lua 默认写入的 body 摘要，见那里的 LOCAL PATCH 注释。
        headers["X-Amz-Content-Sha256"] = _M.UNSIGNED_PAYLOAD
    end
    local canonical_query
    if opts.query and next(opts.query) then
        canonical_query = utils.canonicalise_query_string(opts.query)
    end
    local prepared, err = prepare_awsv4_request(signer_config(cfg), {
        method = opts.method,
        canonicalURI = canonical_uri,
        -- 只喂 canonical_querystring（已排序、已编码的字符串），避免上游把 table
        -- 原样带回、再由 resty.http 用 ngx.encode_args 二次编码改写字节。
        canonical_querystring = canonical_query,
        headers = headers,
        host = endpoint_authority(cfg.host, cfg.port, cfg.tls),
        port = cfg.port,
        body = opts.body,
    })
    if not prepared then return nil, "签名失败: " .. tostring(err) end
    return prepared
end

local function new_client(cfg)
    local httpc, err = http:new()
    if not httpc then return nil, err end
    httpc:set_timeouts(cfg.connect_timeout, cfg.send_timeout, cfg.read_timeout)
    local ok, conn_err = httpc:connect({
        scheme = cfg.tls and "https" or "http",
        host = cfg.host,
        port = cfg.port,
        ssl_verify = false,
    })
    if not ok then return nil, conn_err end
    return httpc
end

-- 发一个请求并读完整个响应体。body 读完才允许回连接池，否则下一个请求会读到残留字节。
function _M.exchange(cfg, prepared, body)
    local httpc, err = new_client(cfg)
    if not httpc then return nil, nil, err end
    local res, req_err = httpc:request({
        method = prepared.method,
        path = prepared.path,
        query = prepared.query,
        headers = prepared.headers,
        body = body,
    })
    if not res then
        httpc:close()
        -- 调用方一律按 (status, headers, body_or_err) 三元组取返回值，所以传输错误
        -- 放在第三位；放第四位的话所有 "连接 S3 失败: nil" 都丢了原因。
        return nil, nil, req_err
    end
    local payload = res.has_body and res:read_body() or ""
    if type(payload) ~= "string" then payload = "" end
    httpc:set_keepalive(cfg.keepalive_idle, KEEPALIVE_POOL)
    return res.status, res.headers, payload
end

-- ── 错误语义 ────────────────────────────────────────────────────────────────
-- 该服务的 <Code> 有非标准之处（HEAD 404 的 Code 是字面量 "404"），所以以状态码为主、
-- Code 只用于挑一句人话。返回 (code, message, http_status)。
local ERROR_HINTS = {
    AccessDenied = "存储桶拒绝访问（检查 AKID/SECRET 与桶权限）",
    InvalidAccessKeyId = "AKID 不存在",
    SignatureDoesNotMatch = "SECRET 不正确，或签名头在链路上被改写",
    NoSuchKey = "对象不存在",
    NoSuchBucket = "存储桶不存在",
    BucketAlreadyExists = "存储桶已存在",
    InvalidRequest = "该服务只接受 AWS4-HMAC-SHA256 签名",
    InvalidArgument = "对象名非法（该服务拒绝以 / 结尾的 key）",
}

function _M.error_from_response(status, body)
    local code = xml_unescape(xml_text(body or "", "Code"))
    local message = xml_unescape(xml_text(body or "", "Message"))
    local hint = code and ERROR_HINTS[code]
    if status == 404 then return "not_found", hint or "对象不存在", 404 end
    if status == 403 then return "s3_forbidden", hint or (message or "存储桶拒绝访问"), 403 end
    if status == 409 then return "s3_conflict", hint or (message or "资源冲突"), 409 end
    if hint then return "s3_error", hint, 502 end
    return "s3_error",
        (message and ((code or "S3") .. ": " .. message)) or ("S3 服务返回 " .. tostring(status)),
        (status >= 400 and status <= 599) and status or 502
end

-- ── 读操作 ──────────────────────────────────────────────────────────────────
--- ListBuckets → { { name, creation_date } }
function _M.list_buckets(cfg)
    local prepared, err = _M.prepare(cfg, { method = "GET", headers = {} })
    if not prepared then return nil, err, 500 end
    local status, _, body = _M.exchange(cfg, prepared)
    if not status then return nil, "连接 S3 失败: " .. tostring(body), 502 end
    if status ~= 200 then
        local _, message, http_status = _M.error_from_response(status, body)
        return nil, message, http_status
    end
    local buckets = {}
    for _, block in ipairs(xml_blocks(body, "Bucket")) do
        local name = xml_unescape(xml_text(block, "Name"))
        if name then
            buckets[#buckets + 1] = {
                name = name,
                creation_date = iso8601_to_epoch(xml_text(block, "CreationDate")),
            }
        end
    end
    return buckets
end

--- ListObjectsV2，带 delimiter=/ 的“目录”视图，归一化成前端 adapter 的 items。
--- 返回 { items, path, truncated, next_token }。
function _M.list_objects(cfg, bucket, prefix, token, max_keys)
    local clean = _M.normalize_prefix(prefix)
    if not clean then return nil, "invalid path", 400 end
    -- 固定不发 encoding-type=url：该服务在这种模式下把 Key 里的 / 编成 %2F，
    -- 并且 CommonPrefixes 直接消失（实测契约 A 节），等于没有目录。
    local query = {
        ["list-type"] = "2",
        delimiter = "/",
        ["max-keys"] = tostring(math.min(max_keys or _M.MAX_KEYS, _M.MAX_KEYS)),
    }
    if clean ~= "" then query.prefix = clean .. "/" end
    if token and token ~= "" then query["continuation-token"] = tostring(token) end

    local prepared, err = _M.prepare(cfg, { method = "GET", bucket = bucket, query = query })
    if not prepared then return nil, err, 500 end
    local status, _, body = _M.exchange(cfg, prepared)
    if not status then return nil, "连接 S3 失败: " .. tostring(body), 502 end
    if status ~= 200 then
        local _, message, http_status = _M.error_from_response(status, body)
        return nil, message, http_status
    end

    local items = {}
    for _, block in ipairs(xml_blocks(body, "Contents")) do
        local key = xml_unescape(xml_text(block, "Key") or "")
        -- “幻影目录”条目：以 / 结尾、Size=16384、ETag 为空，GET 它返回 400。
        -- 它不是真对象；目录一律来自 CommonPrefixes，所以这里直接丢弃。
        if key ~= "" and not key:match("/$") then
            items[#items + 1] = {
                name = key:match("([^/]+)$") or key,
                key = key,
                type = "file",
                size = tonumber(xml_text(block, "Size")) or 0,
                mtime = iso8601_to_epoch(xml_text(block, "LastModified")),
            }
        end
    end
    for _, block in ipairs(xml_blocks(body, "CommonPrefixes")) do
        local p = xml_unescape(xml_text(block, "Prefix") or "")
        -- 该服务会把“请求 prefix 自身”也当成一个 CommonPrefix 回显（实测），照抄
        -- 就变成一个套自己的同名目录，所以只接受严格长于 prefix 的条目。
        local name = p ~= clean .. "/" and p:match("([^/]+)/?$") or nil
        if name then
            -- 目录排在文件之前：与 files.lua 的 listing 顺序习惯一致。
            table.insert(items, 1, {
                name = name, key = p, type = "dir", size = 0, mtime = nil,
            })
        end
    end
    return {
        items = items,
        path = clean,
        truncated = xml_text(body, "IsTruncated") == "true",
        -- token 是 base64(该页最后一个 key)，对我们不透明，原样透传即可。
        next_token = xml_unescape(xml_text(body, "NextContinuationToken")),
    }
end

--- 桶内列表（adapter 视角：不带 key，只给展示字段）。
function _M.browse(cfg, bucket, prefix, token)
    local page, err, status = _M.list_objects(cfg, bucket, prefix, token)
    if not page then return nil, err, status end
    local items = {}
    for index, item in ipairs(page.items) do
        items[index] = { name = item.name, type = item.type, size = item.size, mtime = item.mtime }
    end
    return {
        items = items, bucket = bucket, path = page.path,
        truncated = page.truncated, next_token = page.next_token,
    }
end

--- HeadObject → { size, etag, last_modified, content_type }。
function _M.head(cfg, bucket, key)
    local prepared, err = _M.prepare(cfg, { method = "HEAD", bucket = bucket, key = key })
    if not prepared then return nil, err, 500 end
    local httpc, conn_err = new_client(cfg)
    if not httpc then return nil, "连接 S3 失败: " .. tostring(conn_err), 502 end
    local res, req_err = httpc:request({
        method = "HEAD", path = prepared.path, query = prepared.query,
        headers = prepared.headers,
    })
    if not res then
        httpc:close()
        return nil, "连接 S3 失败: " .. tostring(req_err), 502
    end
    -- HEAD 无响应体，读完（0 字节）后才能回池。
    if res.has_body then res:read_body() end
    httpc:set_keepalive(cfg.keepalive_idle, KEEPALIVE_POOL)
    if res.status == 404 then return nil, "对象不存在", 404 end
    if res.status ~= 200 then
        local _, message, http_status = _M.error_from_response(res.status, "")
        return nil, message, http_status
    end
    return {
        size = tonumber(res.headers["Content-Length"]) or 0,
        etag = res.headers["ETag"],
        last_modified = res.headers["Last-Modified"],
        content_type = res.headers["Content-Type"],
    }
end

--- 打开流式 GetObject，供 /_authz/s3/ 透传字节。返回 (httpc, res)；
--- 调用方必须把 res.body_reader 读空，然后 set_keepalive 或 close。
function _M.open_get(cfg, bucket, key, range_header)
    local headers = {}
    if range_header then headers["Range"] = tostring(range_header) end
    local prepared, err = _M.prepare(cfg, {
        method = "GET", bucket = bucket, key = key, headers = headers,
    })
    if not prepared then return nil, nil, err end
    local httpc, conn_err = new_client(cfg)
    if not httpc then return nil, nil, "连接 S3 失败: " .. tostring(conn_err) end
    local sent, send_err = httpc:send_request({
        method = "GET", path = prepared.path, query = prepared.query,
        headers = prepared.headers,
    })
    if not sent then
        httpc:close()
        return nil, nil, "请求 S3 失败: " .. tostring(send_err)
    end
    -- read_response 会读 params.headers["Expect"]，缺 headers 直接抛 nil 索引，
    -- 所以把请求头一起传进去（它只用这一个字段判断 100-continue）。
    local res, read_err = httpc:read_response({
        method = "GET", path = prepared.path, query = prepared.query,
        headers = prepared.headers,
    })
    if not res then
        httpc:close()
        return nil, nil, "读取 S3 响应失败: " .. tostring(read_err)
    end
    return httpc, res
end

-- ── 写操作 ──────────────────────────────────────────────────────────────────
--- 上传。source = { body = <string> } 或 { file = <绝对路径>, size = <字节数> }。
--- UNSIGNED-PAYLOAD 让网关不必先读一遍文件算摘要（multipart 边界的长度/摘要在
--- 校验和之前就得知道），实测服务端接受定长 + UNSIGNED 且回读字节一致。
function _M.put(cfg, bucket, key, source, content_type)
    local body, content_length
    if source.file then
        content_length = tonumber(source.size)
        if not content_length then return nil, "缺少待上传文件的大小", 500 end
        local handle, open_err = io.open(source.file, "rb")
        if not handle then return nil, "无法读取临时文件: " .. tostring(open_err), 500 end
        local CHUNK = 64 * 1024
        local pending = content_length
        body = function()
            if pending <= 0 then
                handle:close()
                return nil
            end
            local chunk = handle:read(math.min(CHUNK, pending))
            if not chunk then
                handle:close()
                return nil
            end
            pending = pending - #chunk
            return chunk
        end
    else
        body = source.body or ""
    end

    local prepared, err = _M.prepare(cfg, {
        method = "PUT", bucket = bucket, key = key,
        headers = {},
        body = source.file and "" or body,   -- 只有空体/未签名两种哈希会进签名
        unsigned = source.file and true or nil,
    })
    if not prepared then return nil, err, 500 end
    if content_length then
        -- 函数式 body 必须自己给 Content-Length：resty.http 对函数 body 不加
        -- chunked 帧（它要求显式 length 或 chunked），服务端也才能存出正确大小。
        prepared.headers["Content-Length"] = content_length
    end
    -- Content-Type 只是装饰（服务端不持久化），但顺手给上，便于别的 S3 实现复用。
    if content_type then prepared.headers["Content-Type"] = content_type end

    local status, res_headers, payload = _M.exchange(cfg, prepared, body)
    if not status then return nil, "连接 S3 失败: " .. tostring(res_headers), 502 end
    if status ~= 200 then
        local code, message, http_status = _M.error_from_response(status, payload)
        return nil, message, http_status, code
    end
    return {
        etag = res_headers and res_headers["ETag"],
        size = content_length or #(source.body or ""),
    }
end

--- CopyObject（同桶）。rename 用它 + 删原对象；REPLACE 指令让“拷给自己”也产生新对象。
function _M.copy(cfg, bucket, source_key, target_key)
    -- x-amz-copy-source 用 path-style，并按与规范请求相同的规则逐段转义。
    -- path-style 的 copy source 形如 /bucket/key：canonicalise_path 已经带前导 /，
    -- 不能再剥掉它（实测少了分隔符会被解析成不存在的双段桶名，返回 NoSuchBucket）。
    local source_header = "/" .. bucket .. utils.canonicalise_path("/" .. source_key)
    local prepared, err = _M.prepare(cfg, {
        method = "PUT", bucket = bucket, key = target_key, body = "",
        headers = {
            ["x-amz-copy-source"] = source_header,
            ["x-amz-metadata-directive"] = "REPLACE",
        },
    })
    if not prepared then return nil, err, 500 end
    -- COPY 的请求体是空的，但必须显式给 ""：resty.http 对 PUT 拒绝 nil body。
    local status, _, body = _M.exchange(cfg, prepared, "")
    if not status then return nil, "连接 S3 失败: " .. tostring(body), 502 end
    if status ~= 200 then
        local _, message, http_status = _M.error_from_response(status, body)
        return nil, message, http_status
    end
    return { etag = xml_unescape(xml_text(body, "ETag")) }
end

--- DeleteObject。对不存在的 key 也返回 204，语义幂等。
function _M.delete(cfg, bucket, key)
    local prepared, err = _M.prepare(cfg, { method = "DELETE", bucket = bucket, key = key })
    if not prepared then return nil, err, 500 end
    local status, _, body = _M.exchange(cfg, prepared)
    if not status then return nil, "连接 S3 失败: " .. tostring(body), 502 end
    if status ~= 200 and status ~= 204 then
        local _, message, http_status = _M.error_from_response(status, body)
        return nil, message, http_status
    end
    return true
end

--- DeleteObjects 批量删除（单次上限 1000，协议规定）。
function _M.delete_many(cfg, bucket, keys)
    if type(keys) ~= "table" or #keys == 0 then return nil, "没有要删除的对象", 400 end
    local parts = { '<?xml version="1.0" encoding="UTF-8"?>', "<Delete><Quiet>true</Quiet>" }
    for index, key in ipairs(keys) do
        if index > _M.DELETE_BATCH then break end
        parts[#parts + 1] = "<Object><Key>" .. xml_escape(key) .. "</Key></Object>"
    end
    parts[#parts + 1] = "</Delete>"
    local body = table.concat(parts)
    -- delete 子资源必须以 query 传（服务端不认 header），空值参与签名即 "delete="。
    local prepared, err = _M.prepare(cfg, {
        method = "POST", bucket = bucket, query = { delete = "" }, body = body,
    })
    if not prepared then return nil, err, 500 end
    prepared.headers["Content-Type"] = "application/xml"
    local status, _, payload = _M.exchange(cfg, prepared, body)
    if not status then return nil, "连接 S3 失败: " .. tostring(payload), 502 end
    if status ~= 200 then
        local _, message, http_status = _M.error_from_response(status, payload)
        return nil, message, http_status
    end
    -- Quiet 模式仍会回 Errors；逐条收集，调用方据此判断有没有漏删。
    local errors = {}
    for _, block in ipairs(xml_blocks(payload, "Error")) do
        errors[#errors + 1] = {
            key = xml_unescape(xml_text(block, "Key")),
            code = xml_unescape(xml_text(block, "Code")),
            message = xml_unescape(xml_text(block, "Message")),
        }
    end
    return { requested = math.min(#keys, _M.DELETE_BATCH), errors = errors }
end

--- 列出前缀下全部对象（扁平、不带 delimiter），用于递归改名/删除。
--- include_markers=true 时保留以 / 结尾的“目录标记”对象——只有递归删除需要它们，
--- 否则删完真对象后标记还在，目录在列表里永远去不掉（实测踩过）。
function _M.walk_prefix(cfg, bucket, prefix, include_markers)
    local keys, token = {}, nil
    repeat
        local query = {
            ["list-type"] = "2",
            ["max-keys"] = tostring(_M.MAX_KEYS),
            prefix = prefix .. "/",
        }
        if token and token ~= "" then query["continuation-token"] = tostring(token) end
        local prepared, err = _M.prepare(cfg, { method = "GET", bucket = bucket, query = query })
        if not prepared then return nil, err, 500 end
        local status, _, body = _M.exchange(cfg, prepared)
        if not status then return nil, "连接 S3 失败: " .. tostring(body), 502 end
        if status ~= 200 then
            local _, message, http_status = _M.error_from_response(status, body)
            return nil, message, http_status
        end
        for _, block in ipairs(xml_blocks(body, "Contents")) do
            local key = xml_unescape(xml_text(block, "Key") or "")
            -- 默认过滤幻影目录条目：对前缀整体做 COPY 会把 400 复制出来。
            if key ~= "" and (include_markers or not key:match("/$")) then
                keys[#keys + 1] = key
            end
        end
        token = xml_text(body, "IsTruncated") == "true"
            and xml_unescape(xml_text(body, "NextContinuationToken")) or nil
    until not token
    return keys
end

--- 前缀下是否存在“真”对象（早退）。不能用带 delimiter 的列表探针：该服务会先回
--- 幻影标记对象 "prefix/" 和 prefix 自身的 CommonPrefixes，max-keys=1 时第一条
--- 必然被过滤掉，于是有内容的目录被误判成空目录（实测把非空目录删掉了）。
--- 这里用扁平列表 + 过滤 / 结尾条目，命中第一个真对象就返回。
function _M.has_objects_under(cfg, bucket, prefix)
    local token = nil
    repeat
        local query = {
            ["list-type"] = "2",
            ["max-keys"] = tostring(_M.MAX_KEYS),
            prefix = prefix .. "/",
        }
        if token and token ~= "" then query["continuation-token"] = tostring(token) end
        local prepared, err = _M.prepare(cfg, { method = "GET", bucket = bucket, query = query })
        if not prepared then return nil, err, 500 end
        local status, _, body = _M.exchange(cfg, prepared)
        if not status then return nil, "连接 S3 失败: " .. tostring(body), 502 end
        -- 404（桶/前缀不存在）与 500 都当“此 prefix 不是目录”：实测把某个真实对象
        -- key 当目录前缀去列表（key + "/"），该服务直接回 500 InternalError。
        if status == 404 or status == 500 then return false end
        if status ~= 200 then
            local _, message, http_status = _M.error_from_response(status, body)
            return nil, message, http_status
        end
        for _, block in ipairs(xml_blocks(body, "Contents")) do
            local key = xml_unescape(xml_text(block, "Key") or "")
            if key ~= "" and not key:match("/$") then return true end
        end
        token = xml_text(body, "IsTruncated") == "true"
            and xml_unescape(xml_text(body, "NextContinuationToken")) or nil
    until not token
    return false
end

--- 递归删除整个前缀：分批 DeleteObjects，避免一个对象一次 HTTP。
function _M.delete_prefix(cfg, bucket, prefix)
    local removed, errors = 0, {}
    local batch = {}
    local function flush()
        if #batch == 0 then return true end
        local result, err, status = _M.delete_many(cfg, bucket, batch)
        if not result then return nil, err, status end
        removed = removed + (#batch - #result.errors)
        for _, item in ipairs(result.errors) do errors[#errors + 1] = item end
        batch = {}
        return true
    end
    -- walk_prefix 自己翻页。真对象走批量 DeleteObjects；“目录标记”（以 / 结尾）
    -- 单独走 DELETE：实测批量删会清掉真对象却把 marker 留下（服务端把它们当派生条目，
    -- DeleteObjects 不级联清 marker），必须单个 DELETE 才消失，否则递归删完目录仍在。
    local keys, err, status = _M.walk_prefix(cfg, bucket, prefix, true)
    if not keys then
        -- 该服务对“真实对象 key + /”的列表回 500 InternalError（见 has_objects_under
        -- 同款判定）：此时 prefix 本身就是个文件，递归标记对文件无害，直接单删。
        if status == 500 then
            local ok, del_err, del_status = _M.delete(cfg, bucket, prefix)
            if not ok and del_status ~= 404 then return nil, del_err, del_status end
            local cjson0 = require "cjson.safe"
            return { removed = ok and 1 or 0, errors = cjson0.empty_array }
        end
        return nil, err, status
    end
    local markers = {}
    for _, key in ipairs(keys) do
        if key:match("/$") then
            markers[#markers + 1] = key
        else
            batch[#batch + 1] = key
            if #batch >= _M.DELETE_BATCH then
                local ok, flush_err, flush_status = flush()
                if not ok then return nil, flush_err, flush_status end
            end
        end
    end
    local ok, flush_err, flush_status = flush()
    if not ok then return nil, flush_err, flush_status end
    for _, marker in ipairs(markers) do
        local _, del_err, del_status = _M.delete(cfg, bucket, marker)
        if del_err and del_status ~= 404 then return nil, del_err, del_status end
        removed = removed + 1
    end
    -- 返回表而不是裸数字：router 直接把它放进 {data=...}，
    -- 前端需要 {removed, errors} 两个字段（部分删除失败时必须看得见）。
    local cjson = require "cjson.safe"
    return { removed = removed, errors = #errors > 0 and errors or cjson.empty_array }
end

--- 前缀改名：逐个 COPY 到新前缀，再整批删旧前缀。
function _M.copy_prefix(cfg, bucket, source_prefix, target_prefix)
    local keys, err, status = _M.walk_prefix(cfg, bucket, source_prefix)
    if not keys then return nil, err, status end
    for _, key in ipairs(keys) do
        local suffix = key:sub(#source_prefix + 2)   -- 剥掉 "source_prefix/"
        local _, copy_err, copy_status =
            _M.copy(cfg, bucket, key, _M.join(target_prefix, suffix))
        if copy_err then return nil, copy_err, copy_status end
    end
    return #keys
end

--- 重命名 = Copy + Delete。目标已存在先拒绝，避免静默留两份。
--- name 指向“目录”时（对象不存在但前缀有内容）走前缀改名。
function _M.rename(cfg, bucket, path, name, new_name)
    local key = _M.join(path, name)
    local target = _M.join(path, new_name)
    if key == target then return nil, "新旧名称相同", 400 end
    if _M.head(cfg, bucket, target) then
        return nil, "目标名称已存在: " .. new_name, 409
    end
    -- 先 HEAD 精确对象：普通改名一次请求就够，也不会触发“对象 key 当目录前缀”的
    -- 500。只有对象不存在时才探测它是不是目录（前缀下有真对象）。
    local is_object = _M.head(cfg, bucket, key) ~= nil
    local is_dir = false
    if not is_object then
        local probe, probe_err, probe_status = _M.has_objects_under(cfg, bucket, key)
        if probe == nil then return nil, probe_err, probe_status end
        is_dir = probe
        if not is_dir then return nil, "对象不存在", 404 end
    end
    if is_dir then
        local moved, copy_err, copy_status = _M.copy_prefix(cfg, bucket, key, target)
        if not moved then return nil, copy_err, copy_status end
        local _, del_err, del_status = _M.delete_prefix(cfg, bucket, key)
        if del_err then return nil, del_err, del_status end
        return { renamed = name, new_name = new_name, objects = moved }
    end
    local _, err, status = _M.copy(cfg, bucket, key, target)
    if err then return nil, err, status or 502 end
    local _, del_err, del_status = _M.delete(cfg, bucket, key)
    if del_err then
        -- 复制成功但原对象没删掉：目标已经存在，必须说清楚现在有两份，
        -- 不能谎报成功（否则用户以为改完了，实际多了一份副本）。
        return nil, "已复制为 " .. new_name .. "，但原对象删除失败：" .. del_err, 502
    end
    return { renamed = name, new_name = new_name }
end

--- presigned GET（分享链接）。永远带 response-content-type：存储端存的类型是
--- octet-stream，不覆盖的话浏览器只会当二进制下载，图片/视频无法内联。
function _M.presign_get(cfg, bucket, key, expires, download)
    expires = math.max(60, math.min(tonumber(expires) or 3600, 604800))
    local filename = tostring(key):match("([^/]+)$") or "file"
    local canonical_query = utils.canonicalise_query_string({
        ["response-content-type"] = download
            and "application/octet-stream" or _M.content_type(key),
        ["response-content-disposition"] =
            (download and "attachment" or "inline") .. '; filename="' .. filename .. '"',
    })
    local authority = endpoint_authority(cfg.host, cfg.port, cfg.tls)
    local presigned, err = presign_awsv4_request(signer_config(cfg), {
        method = "GET",
        canonicalURI = utils.canonicalise_path("/" .. bucket .. "/" .. key),
        canonical_querystring = canonical_query,
        host = authority,
        port = cfg.port,
        -- presign 只需 host 参与签名；实测未签名的 Range 头也放行。
        headers = { host = authority },
    }, "s3", cfg.region, expires)
    if not presigned then return nil, "生成分享链接失败: " .. tostring(err) end
    return (cfg.tls and "https://" or "http://") .. authority .. presigned.path
        .. "?" .. presigned.query
end

return _M
