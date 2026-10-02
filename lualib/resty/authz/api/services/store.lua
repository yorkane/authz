-- 本机「临时保存区」业务层：校验 + 落盘 + 记账。router 只提供「当前身份 + 参数」，
-- 文件系统动作全在 resty.authz.store，SQL 全在 repository/upload_records。
--
-- 定位（与 config.lua 的注释同一口径）：store_dir 是给 agent 用的临时交换区，
-- 默认 24 小时后自动删除（AUTHZ_STORE_DEFAULT_EXPIRY_HOURS，0 = 不过期）。
-- 需要长期保存的内容走对象存储（s3_configs），别指望这里。
--
-- 记账复用 s3 那张表（upload_records），区别只有三条：
--   * kind = 'local'、bucket = ''、cfg_id = NULL
--     → maintenance.local_root_resolver 对 cfg_id=NULL 的行按「行内没配 local_root」
--       处理，最终退回 config.store_dir()，正好是这里的落盘根；
--   * expires_at 必须经 s3_config_store.align_expiry 整点对齐（清理器每小时整点跑，
--     不对齐就会错过当轮），不要自己加秒数；
--   * 覆盖写会先把同 key 的旧 active 行闭账（见 close_prior_records），保证
--     「每个 key 只有一条 active 流水」——否则最早那条到期会提前把新文件删掉。
-- 记账失败语义（照 api/services/uploads.lua）：文件**已经写成功**，流水只是账本，
-- 记账失败绝不能把一次成功的保存变成失败响应 → 整段 pcall + ngx.log(WARN)。
--
-- 安全红线（与 store.lua 头部逐条对应）：
--   R1 归一化：拒绝绝对路径 / '..' / '~' / 控制字符（含 NUL）/ 反斜杠，折叠连续斜杠；
--      写、删、stat 的目标不允许为空（空 = 保存区根，只有 list 允许）。
--   R2 符号链接：逐级 symlinkattributes 判定，任一段是链接即拒（store.resolve /
--      store.ensure_parents）；覆盖同名目标前也先判链接，绝不跟随、绝不覆盖。
--   R3 原子写：暂存 .upload-<pid>-<now>-<rand> → os.rename；任何失败路径清暂存。
--   R4 上限：单对象 MAX_BYTES（512MB）、单请求文件数 MAX_FILES（64）。前者超限 413，
--      后者计入 skipped；location 里的 client_max_body_size 是外层硬闸（见 server.conf）。
--   R5 保留名：rel 的任一段不得以 .upload-/.s3-upload-/.tmp-/tmp- 开头
--      （store.is_reserved），否则会被暂存清理器按 mtime 当残留删掉。
--   R7 响应只给相对 path 与同源相对 url；绝对路径只在 info 里回显 store_dir 本身
--      （它由部署期 env 决定，不是运行时发现的内部结构）。
--   R8 本 API 的**核心用途是 agent 用 X-API-KEY 免登录落文件**，因此 router 注册
--      绝不能带 session_only（见交付报告的注册片段）。
local cjson = require "cjson.safe"
local db = require "resty.authz.db"
local config_loader = require "resty.authz.config"
local s3_config_store = require "resty.authz.s3_config_store"
local store = require "resty.authz.store"
local upload = require "resty.upload"
local upload_records = require "resty.authz.repository.upload_records"

local _M = {}

-- 默认 512MB：agent 落一篇报告 / 一段音视频切片够用，又不至于一次请求写满磁盘。
-- 改这个常量时必须同步 conf/server.conf.template 里 /_authz/store/ 的
-- client_max_body_size（外层 nginx 值要 ≥ 本常量，否则 nginx 先回 413 空正文，
-- Lua 层这句中文错误永远到不了调用方）。
_M.MAX_BYTES = 512 * 1024 * 1024
-- 单请求文件数：与 files_upload / s3_upload 同值（前端与脚本可复用同一套逻辑）。
_M.MAX_FILES = 64
_M.MAX_EXPIRY_HOURS = 8760   -- 一年：挡住误填把 expires_at 撑成荒谬时间戳
_M.MAX_DIR_DEPTH = 32        -- 逐级建目录的深度上限（挡住 a/b/a/b/... 造深树）

local CHUNK_SIZE = 64 * 1024
local MAX_RECORD_SCAN = 1000 -- 一次列表最多关联多少条流水（超出的行不显示 expires_at）

local function runtime_config()
    local ok, authz = pcall(require, "resty.authz")
    if ok and authz and authz.config then return authz.config end
    return nil
end

--- 保存区根目录。运行期配置表（init_by_lua 里 config.load() 的产物）优先，取不到
--- 再退回 config.store_dir() 的记忆化访问器。**绝不能 os.getenv**：nginx exec 后
--- 清空 worker 环境块，未在 nginx.conf 里 env 声明的变量在 worker 里一定是 nil
--- （实测结论，见 config.lua 的 memo_env 注释），直读会退成默认路径而与实际部署错位。
function _M.root()
    local c = runtime_config()
    local root = c and c.store_dir
    if type(root) ~= "string" or root == "" then root = config_loader.store_dir() end
    return root
end

local function default_hours()
    local c = runtime_config()
    local hours = c and c.store_default_expiry_hours
    if hours == nil then hours = config_loader.store_expiry_hours() end
    return tonumber(hours) or 24
end

--- 归一化 expires_hours：缺省 → 默认 TTL；0 或负数 → 0（永不过期，expires_at=NULL）；
--- 上限一年。返回小时数（number）。
function _M.expiry_hours(value)
    if value == nil or value == cjson.null or value == "" then return default_hours() end
    local hours = tonumber(value)
    if not hours or hours <= 0 then return 0 end
    return math.min(_M.MAX_EXPIRY_HOURS, math.floor(hours))
end

--- url：可直接打开/分享的**同源相对**入口（不带主机名，经任意入口域名与端口都成立）。
--- 逐段转义（空格等），分隔符保持字面量，与 store_proxy.parse_path 的解码对称。
local function public_url(rel)
    local parts = {}
    for segment in tostring(rel or ""):gmatch("[^/]+") do
        parts[#parts + 1] = ngx.escape_uri(segment)
    end
    return "/_authz/store/" .. table.concat(parts, "/")
end

local function megabytes(limit)
    return tostring(math.floor((tonumber(limit) or 0) / 1048576))
end

local function count_segments(clean)
    local count = 0
    for _ in tostring(clean or ""):gmatch("[^/]+") do count = count + 1 end
    return count
end

--- created_by 归一化：router 传进来的是身份表（会话或 API Key），流水里只要一个
--- 可审计的主体名。表 → username/name；字符串原样；其他一律空（不 stringify 表地址）。
local function principal_name(subject)
    if type(subject) == "table" then
        return tostring(subject.username or subject.name or "")
    end
    if type(subject) == "string" then return subject end
    return ""
end

--- 目标相对路径的公共校验。返回 clean 或 (nil, 原因, 状态码)。
local function require_target(rel)
    local clean = store.normalize_target(rel)
    if not clean then
        return nil, "路径非法：不允许绝对路径、'.'/'..'、'~'、控制字符或暂存保留名前缀", 400
    end
    if count_segments(clean) > _M.MAX_DIR_DEPTH then
        return nil, "目录层级过深", 400
    end
    return clean
end

-- ── 记账（失败一律不影响响应）────────────────────────────────────────────────
--- written = { {name=相对路径, size=n}, ... }。返回成功记账条数。
function _M.record_local(written, expires_at, source, created_by)
    if type(written) ~= "table" or #written == 0 then return 0 end
    local ok, count = pcall(function()
        local now = os.time()
        local total = 0
        for _, item in ipairs(written) do
            local key = tostring(item and item.name or "")
            if key ~= "" then
                local inserted, err = upload_records.insert({
                    kind = "local",
                    cfg_id = nil,   -- 本地删除不需要凭证：NULL → 清理器退回 store_dir
                    bucket = "",
                    key = key,
                    size = tonumber(item and item.size) or 0,
                    source = source or "api",
                    created_by = principal_name(created_by),
                    created_at = now,
                    expires_at = expires_at,
                    state = "active",
                })
                if inserted then
                    total = total + 1
                else
                    ngx.log(ngx.WARN, "authz: store record failed for ", key, ": ",
                        tostring(err))
                end
            end
        end
        return total
    end)
    if not ok then
        ngx.log(ngx.WARN, "authz: store record pass failed: ", tostring(count))
        return 0
    end
    return count or 0
end

--- 某 key 上仍在 active 队列里的本地流水 id（覆盖写闭旧账、删除闭账共用）。
--- 与 uploads.lua 的 key_ids 同形，但 kind='local' 且不带 bucket。
local function local_key_ids(key, recursive)
    -- SQL 下沉到 repository（LIKE 转义的唯一真源也在那里）；nil 与原因照原样透传，
    -- 调用方保持既有 nil 判断。
    return upload_records.local_ids_by_key(key, recursive)
end

local function mark_rows(ids, reason)
    local now = os.time()
    for _, id in ipairs(ids or {}) do
        local marked, mark_err = upload_records.mark(id, "deleted", reason, now)
        if not marked then
            ngx.log(ngx.WARN, "authz: cannot mark store record ", tostring(id),
                " deleted: ", tostring(mark_err))
        end
    end
    return #ids or 0
end

--- 覆盖写之前把同 key 的旧 active 行闭账。
--- 为什么必须做：旧行的 expires_at 更早，清理器只看「有没有到期行」，会把刚写好的
--- 新文件一起删掉；而且旧行删成功一次之后，剩下的重复行每轮都会以 404 变成 failed
--- 噪音。一个 key 同时只保留一条 active 流水，TTL 就是最后一次写入的 TTL。
local function close_prior_records(key)
    local ok, count = pcall(function()
        local ids, err = local_key_ids(key, false)
        if not ids then
            ngx.log(ngx.WARN, "authz: cannot look up previous store records for ", key,
                ": ", tostring(err))
            return 0
        end
        return mark_rows(ids, "replaced by a newer upload")
    end)
    if not ok then
        ngx.log(ngx.WARN, "authz: store prior-record close-out failed: ", tostring(count))
        return 0
    end
    return count or 0
end

--- 删除成功后闭账（recursive=true 时连子树里的记录一起闭）。返回闭账条数。
local function close_records(key, recursive)
    local ok, count = pcall(function()
        local ids, err = local_key_ids(key, recursive)
        if not ids then
            ngx.log(ngx.WARN, "authz: cannot look up store records for ", tostring(key),
                ": ", tostring(err))
            return 0
        end
        return mark_rows(ids, "")
    end)
    if not ok then
        ngx.log(ngx.WARN, "authz: store close-out failed: ", tostring(count))
        return 0
    end
    return count or 0
end

--- 目录（含自身子树）下的 active 流水 → key 索引。列表与 stat 用它补 expires_at。
--- 逐字段拷进新表：db.query 返回的是跨请求共享的 mlcache 缓存表，就地改会污染别的请求。
local function expiry_map(dir)
    local map = {}
    local rows, err = upload_records.local_expiry_rows(dir, MAX_RECORD_SCAN)
    if not rows then
        ngx.log(ngx.WARN, "authz: cannot read store records: ", tostring(err))
        return map
    end
    for _, row in ipairs(rows) do
        local key = tostring(row.key or "")
        -- 按 id 倒序，第一条即最新一条（覆盖写已保证同 key 只有一条 active，这里仍
        -- 保留「只认第一条」的写法，挡住历史遗留的重复行）。
        if key ~= "" and map[key] == nil then
            local expires_at = tonumber(row.expires_at)
            map[key] = {
                expires_at = expires_at or cjson.null,
                created_at = tonumber(row.created_at),
            }
        end
    end
    return map
end

local function state_counts()
    local out = { active = 0, deleted = 0, failed = 0, skipped = 0 }
    local rows, err = db.query([[SELECT state, COUNT(*) AS c FROM upload_records
        GROUP BY state]])
    if not rows then
        ngx.log(ngx.WARN, "authz: cannot count upload records: ", tostring(err))
        return out
    end
    for _, row in ipairs(rows) do
        local state = tostring(row.state or "")
        if out[state] ~= nil then out[state] = tonumber(row.c) or 0 end
    end
    return out
end

-- ── 请求体取字节 ────────────────────────────────────────────────────────────
-- 两种来源（router 用 _M.body_source() 拿到其一）：
--   { body = <string> }          正文在内存里（nginx 的 client_body_buffer_size 之内）
--   { file = <绝对路径> }         正文已被 nginx 写进临时文件（大请求的常态）
-- 返回 { body = ... } 或 { file = ... }，或 (nil, 原因, 状态码)。
--
-- 【为什么不走 ngx.req.socket(true) 直读原始 body（实测结论，别改回去）】
-- 一次性探针（/data/tmp/authz-store/probe）量到：在 content_by_lua 里用 raw socket
-- 能把 11 字节的正文读全（DIAG 里 chunk=11），但**响应发不出去** —— 换 resty.http
-- 客户端得到连接错误，换 wget 得到「error getting response」，并且 error.log 里出现
-- 「attempt to set ngx.status after sending out response headers」。原因是 raw socket
-- 绕过了 nginx 的请求体过滤器链，请求收尾时 nginx 仍认为 body 没读完，于是直接断链。
-- 对照：files_upload / s3_upload 用的 resty.upload 取的是**非 raw** socket
-- （resty/upload.lua 的 req_socket_body_collector 会把读到的字节用
-- ngx.req.append_body/finish_body 回填给 nginx 的 body 收集器），所以它能流式解析
-- multipart 而响应照常。也就是说 multipart 那条路已经有可用先例，raw socket 这条路
-- 在本项目的 content 阶段没有可用形态。
-- 代价与边界：nginx 默认 client_body_buffer_size 只有 8k/16k，正文超过它就会落到
-- 临时文件（磁盘满 500 由 nginx 自己回），于是**内存占用不随请求体大小增长**；
-- 我们再把该临时文件分块拷进保存区的暂存文件（nginx 负责在请求结束时删它）。
-- 峰值磁盘占用约 2 倍请求体（nginx 临时文件 + 我们的暂存文件），由
-- client_max_body_size（外层 2048m）与 MAX_BYTES（本层 512MB）双重夹住。
function _M.body_source(opts)
    opts = opts or {}
    local limit = tonumber(opts.max_bytes) or _M.MAX_BYTES
    -- 先判体积再决定读法：Content-Length 已知且超限就当场拒，避免为一个注定失败的
    -- 请求把 512MB 写进临时文件（chunked 时没有这个信息，只能读完再判）。
    local headers = ngx.req.get_headers()
    local length = tonumber(headers["content-length"])
    if length and length > limit then
        return nil, "请求体超过单对象上限 " .. megabytes(limit) .. "MB", 413
    end
    if length == 0 then return { body = "" } end
    ngx.req.read_body()
    local data = ngx.req.get_body_data()
    if data then
        if #data > limit then
            return nil, "请求体超过单对象上限 " .. megabytes(limit) .. "MB", 413
        end
        return { body = data }
    end
    local file = ngx.req.get_body_file()
    if not file then return { body = "" } end
    return { file = file }
end

--- 把 source 里的字节灌进已打开的暂存句柄。返回写入字节数；超限/出错以 error()
--- 抛出（消息里带固定标记 "body too large"），由 _M.put 统一清暂存并转 413/400。
function _M.pump(source, handle)
    source = source or {}
    if type(source) == "string" then
        handle:write(source)
        return #source
    end
    local limit = tonumber(source.limit) or _M.MAX_BYTES

    if type(source.body) == "string" then
        if #source.body > limit then error("body too large") end
        local ok, err = handle:write(source.body)
        if not ok then error("写入失败: " .. tostring(err)) end
        return #source.body
    end

    if source.file then
        local from, open_err = io.open(tostring(source.file), "rb")
        if not from then error("无法读取请求体临时文件: " .. tostring(open_err)) end
        local written = 0
        while true do
            local chunk = from:read(CHUNK_SIZE)
            if chunk == nil or chunk == "" then break end
            written = written + #chunk
            if written > limit then
                from:close()
                error("body too large")
            end
            local ok, write_err = handle:write(chunk)
            if not ok then
                from:close()
                error("写入失败: " .. tostring(write_err))
            end
        end
        from:close()
        return written
    end

    error("未知的请求体来源")
end

-- ── 对外能力（router 直接映射）──────────────────────────────────────────────
--- 保存区概览。目录不可用不是错误：给 200 + enabled=false（前端显示提示卡片），
--- 与 GET /api/s3 的「未配置」语义一致。
function _M.info()
    local root = _M.root()
    local available, err, status = store.check_root(root)
    local writable = false
    if available then writable = store.writable(root) and true or false end
    return {
        enabled = available and true or false,
        -- 唯一的绝对路径回显：值就是部署期 env 决定的保存区根本身（响应里不出现
        -- 根之外的任何路径），管理页面需要一个「文件落在哪」的答案来排障。
        store_dir = root,
        writable = writable,
        default_expiry_hours = default_hours(),
        max_bytes = _M.MAX_BYTES,
        max_files = _M.MAX_FILES,
        message = available and cjson.null or (err or "保存区不可用"),
        counts = state_counts(),
    }
end

--- 目录列表。rel 可以是 ""（保存区根）。返回 { items, path, truncated }。
function _M.list(rel, args)
    local clean = store.normalize(rel)
    if not clean then return nil, "invalid path", 400 end
    local root = _M.root()
    local listing, err, status = store.list(root, clean)
    if not listing then return nil, err, status or 400 end
    local expiries = expiry_map(clean)
    local with_expiry = not (type(args) == "table" and args.raw == "1")
    local items = {}
    for index, item in ipairs(listing.items) do
        local key = clean == "" and item.name or (clean .. "/" .. item.name)
        local record = expiries[key]
        -- 目录本身不做记账（这里只登记对象），expires_at=null 即「不自动清理」。
        item.expires_at = with_expiry and (record and record.expires_at or cjson.null)
            or cjson.null
        item.state = record and "active" or cjson.null
        items[index] = item
    end
    return {
        items = #items > 0 and items or cjson.empty_array,
        path = clean,
        truncated = listing.truncated,
    }
end

--- 单对象元信息 + expires_at。返回 { name,type,size,mtime,path,url,expires_at,state }。
function _M.stat(rel)
    local clean, err, status = require_target(rel)
    if not clean then return nil, err, status or 400 end
    local root = _M.root()
    local available, unavailable_err = store.check_root(root)
    if not available then return nil, unavailable_err or "保存区目录不可用", 503 end
    local abs = store.resolve(root, clean)
    if not abs then return nil, "文件不存在", 404 end
    local attr = store.lstat(abs)
    if not attr or attr.mode == "link" then return nil, "文件不存在", 404 end
    local dir = clean:match("^(.*)/[^/]+$") or ""
    local record = expiry_map(dir)[clean]
    local is_dir = attr.mode == "directory"
    return {
        name = clean:match("([^/]+)$"),
        type = is_dir and "dir" or "file",
        size = is_dir and 0 or (attr.size or 0),
        mtime = attr.modification or 0,
        path = clean,
        url = is_dir and cjson.null or public_url(clean),
        expires_at = record and record.expires_at or cjson.null,
        state = record and "active" or cjson.null,
    }
end

--- 写单个对象。rel 允许多级（缺失的祖先目录在保存区内逐级创建）；
--- opts.overwrite 缺省 true（agent 反复保存同一路径是主用途），false 时同名 409。
--- 返回 { path, size, url, expires_at, expires_in }。
function _M.put(rel, expires_hours, source, created_by, opts)
    opts = opts or {}
    local clean, err, status = require_target(rel)
    if not clean then return nil, err, status or 400 end
    local root = _M.root()
    local available, unavailable_err = store.check_root(root)
    if not available then return nil, unavailable_err or "保存区目录不可用", 503 end

    -- keep_dirs 必须为假：put 的 rel 最后一段是**文件**，只建它的祖先目录。
    -- 写成 true 会把叶子也 mkdir 出来，随后被「目标已是目录」409 挡死（实测踩过）。
    local dir, parent_err, parent_status = store.ensure_parents(root, clean)
    if not dir then return nil, parent_err, parent_status or 400 end
    local target = dir .. "/" .. clean:match("([^/]+)$")

    -- R2：目标已存在时先判符号链接（绝不跟随、绝不覆盖），再按 overwrite 决定去留。
    local replaced = false
    local existing = store.lstat(target)
    if existing then
        if existing.mode == "link" then return nil, "拒绝覆盖符号链接", 400 end
        if existing.mode == "directory" then return nil, "目标已是目录，不能当文件写", 409 end
        if opts.overwrite == false then
            return nil, "文件已存在（需要 overwrite=1 覆盖）", 409
        end
        replaced = true
    end

    local handle, staging = store.open_staging(root)
    if not handle then return nil, staging or "保存区不可写", 503 end

    local limit = tonumber(opts.max_bytes) or _M.MAX_BYTES
    if type(source) == "table" then source.limit = limit end
    local ok, written, pump_err = pcall(_M.pump, source or {}, handle)
    if not ok then
        -- pcall 失败时 error 的消息在第二个返回值上。
        local reason = tostring(written)
        store.discard(handle, staging)
        if reason:find("body too large", 1, true) then
            return nil, "请求体超过单对象上限 " .. megabytes(limit) .. "MB", 413
        end
        return nil, reason, 400
    end
    if written > limit then
        store.discard(handle, staging)
        return nil, "请求体超过单对象上限 " .. megabytes(limit) .. "MB", 413
    end

    local published, publish_err = store.publish(handle, staging, target)
    if not published then return nil, publish_err, 500 end

    local now = os.time()
    local expires_at = s3_config_store.align_expiry(now, _M.expiry_hours(expires_hours))
    if replaced then close_prior_records(clean) end
    _M.record_local({ { name = clean, size = written } }, expires_at,
        opts.source or "api", created_by)
    return {
        path = clean,
        size = published.size or written,
        url = public_url(clean),
        expires_at = expires_at or cjson.null,
        expires_in = expires_at and (expires_at - now) or cjson.null,
        state = "active",
    }, nil, 201
end

-- 从 Content-Disposition 取文件名，优先 RFC 5987 的 filename*=UTF-8''（中文文件名）。
local function part_filename(value)
    if type(value) ~= "string" then return nil end
    local ext = value:match("filename%*%s*=%s*[Uu][Tt][Ff]%-8''([^\r\n;]+)")
    if ext then
        return store.validate_name(ngx.unescape_uri(ext))
    end
    local plain = value:match('filename%s*=%s*"([^"]*)"') or value:match("filename%s*=%s*([^;]+)")
    if not plain then return nil end
    return store.validate_name(plain:gsub("%s+$", ""))
end

--- multipart 多文件逐个落盘 + 记账（形状照 s3_upload / files_upload）。
--- prefix_dir：保存区内的目录前缀（可为 ""= 根）。文件名只允许单段名
--- （store.validate_name 拒分隔符），落点 = prefix_dir/<name>。
--- opts: overwrite（缺省 false，与 files/s3 一致：同名冲突计入 skipped）/ source /
---       max_bytes。返回 { uploaded, skipped, path }。
function _M.upload(prefix_dir, expires_hours, source, created_by, opts)
    opts = opts or {}
    local clean_dir = store.normalize(prefix_dir)
    if not clean_dir then return nil, "invalid path", 400 end
    local root = _M.root()
    local available, unavailable_err = store.check_root(root)
    if not available then return nil, unavailable_err or "保存区目录不可用", 503 end

    local request_type = ngx.req.get_headers()["content-type"] or ""
    if type(request_type) == "table" then request_type = request_type[1] end
    if not request_type:lower():find("multipart/form-data", 1, true) then
        return nil, "上传必须使用 multipart/form-data", 415
    end

    -- 目录先建好（与 put 同一条 ensure_parents，符号链接逐级拒绝）：否则空上传会留下
    -- 「目录没建、状态未知」的中间态，且每个文件都要重复走一遍建目录。
    if clean_dir ~= "" then
        -- keep_dirs=true：clean_dir 的每一段（含最后一段）都是目录，全部建出来。
        local _, dir_err, dir_status = store.ensure_parents(root, clean_dir, true)
        if dir_err then return nil, dir_err, dir_status or 400 end
    end

    local form, new_err = upload.new(CHUNK_SIZE)
    if not form then return nil, "无法解析 multipart: " .. tostring(new_err), 400 end
    form:set_timeout(30000)

    local limit = tonumber(opts.max_bytes) or _M.MAX_BYTES
    local written, skipped = {}, {}
    local handle, staging, file_name, file_bytes, overflow
    local file_count, conflicts = 0, 0
    local target_root = root .. (clean_dir == "" and "" or "/" .. clean_dir)

    local function open_sink(name)
        -- 暂存固定在保存区**顶层**（store.open_staging）：清理器对 store 只做单层
        -- 扫描，落在嵌套目录里的残留永远扫不到（files_upload 在 files_root 就有这个盲区）。
        local fd, path = store.open_staging(root)
        if not fd then return nil, path or "保存区不可写" end
        local rejection
        local existing = store.lstat(target_root .. "/" .. name)
        if existing then
            if existing.mode == "link" then
                rejection = "拒绝覆盖符号链接: " .. name
            elseif existing.mode == "directory" then
                rejection = "同名目录已存在: " .. name
            elseif opts.overwrite ~= true then
                conflicts = conflicts + 1
                rejection = "文件已存在: " .. name
            end
        end
        if rejection then
            fd:close()
            os.remove(path)
            return nil, rejection
        end
        handle, staging, file_name, file_bytes, overflow = fd, path, name, 0, false
        return true
    end

    local function close_sink(discard)
        local fd, path, name, size = handle, staging, file_name, file_bytes
        handle, staging, file_name = nil, nil, nil
        if not path then return end
        if discard or overflow then
            store.discard(fd, path)
            return
        end
        local published, publish_err = store.publish(fd, path, target_root .. "/" .. name)
        if not published then
            skipped[#skipped + 1] = { name = name, reason = publish_err }
            return
        end
        written[#written + 1] = { name = name, size = published.size or size or 0 }
    end

    while true do
        local part_type, data = form:read()
        if part_type == "eof" then break end

        if part_type == "header" then
            if type(data) == "table" then
                if tostring(data[1]):lower() == "content-disposition" then
                    close_sink(true)
                    if file_count >= _M.MAX_FILES then
                        -- 溢出必须留下可见的原因：只回一个 422/201 + 空 skipped，
                        -- 调用方会以为表单写错了。名字在这里已知，直接点名。
                        overflow = true
                        local spilled = part_filename(tostring(data[2]))
                        skipped[#skipped + 1] = {
                            name = spilled or "(unnamed)",
                            reason = "单请求文件数超过上限 " .. tostring(_M.MAX_FILES),
                        }
                    else
                        local disposition = tostring(data[2])
                        if disposition:find('name="file"', 1, true)
                            or disposition:find("name=file[;]", 1, false) then
                            file_count = file_count + 1
                            local name = part_filename(disposition)
                            if not name then
                                overflow = true
                                skipped[#skipped + 1] = {
                                    name = "(invalid)",
                                    reason = "文件名非法（不能含路径分隔符、'~' 或暂存保留前缀）",
                                }
                            else
                                local ok_sink, sink_err = open_sink(name)
                                if not ok_sink then
                                    overflow = true
                                    skipped[#skipped + 1] = { name = name, reason = sink_err }
                                end
                            end
                        else
                            overflow = true -- 非 file 字段：忽略
                        end
                    end
                end
            end
            file_bytes = file_bytes or 0
        elseif part_type == "body" then
            if file_name and not overflow then
                file_bytes = file_bytes + #data
                if file_bytes > limit then
                    overflow = true
                    skipped[#skipped + 1] = {
                        name = file_name,
                        reason = "单文件超过上限 " .. megabytes(limit) .. "MB",
                    }
                elseif handle then
                    local ok_write, write_err = handle:write(data)
                    if not ok_write then
                        overflow = true
                        skipped[#skipped + 1] = {
                            name = file_name, reason = "写入失败: " .. tostring(write_err),
                        }
                    end
                end
            end
        elseif part_type == "part_end" then
            close_sink(file_name == nil or overflow)
        end
    end
    close_sink(true)

    if #written == 0 and #skipped == 0 then
        return nil, "没有找到上传文件（表单需包含 file 字段）", 422
    end
    local status = 201
    if #written == 0 then
        -- 全是同名冲突 → 409（前端据此弹「是否覆盖」并带 overwrite=1 重传）。
        status = conflicts > 0 and conflicts == #skipped and 409 or 422
    end
    if #written > 0 then
        local now = os.time()
        local expires_at = s3_config_store.align_expiry(now, _M.expiry_hours(expires_hours))
        local rows = {}
        for _, item in ipairs(written) do
            -- 记账 key 用「保存区相对路径」，清理器按它删文件（maintenance.remove_local）。
            rows[#rows + 1] = {
                name = clean_dir == "" and item.name or (clean_dir .. "/" .. item.name),
                size = item.size,
            }
        end
        for _, row in ipairs(rows) do close_prior_records(row.name) end
        _M.record_local(rows, expires_at, opts.source or "multipart", created_by)
    end
    return {
        uploaded = #written > 0 and written or cjson.empty_array,
        skipped = #skipped > 0 and skipped or cjson.empty_array,
        path = clean_dir,
    }, nil, status
end

--- 删除文件（recursive=true 时连目录一起删），并把对应流水标 deleted。
--- created_by 只进日志（谁删的），不入库：闭账沿用原行的 created_by。
function _M.remove(rel, recursive, created_by)
    local clean, err, status = require_target(rel)
    if not clean then return nil, err, status or 400 end
    local root = _M.root()
    local available, unavailable_err = store.check_root(root)
    if not available then return nil, unavailable_err or "保存区目录不可用", 503 end
    local removed, remove_err, remove_status = store.remove_tree(root, clean, recursive == true)
    if not removed then return nil, remove_err, remove_status or 500 end
    local closed = close_records(clean, recursive == true)
    ngx.log(ngx.NOTICE, "authz: store remove ", clean, " by ", tostring(created_by or ""),
        " files=", tostring(removed.files), " dirs=", tostring(removed.dirs),
        " records=", tostring(closed))
    return {
        message = "已删除",
        path = clean,
        removed = { files = removed.files, dirs = removed.dirs },
        records = closed,
    }
end

return _M
