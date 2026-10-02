-- 上传流水（upload_records）的查询与记账：列表 / 手工删除 / 手动清理，
-- 以及 S3 写路径成功后挂的那几笔记账。
--
-- 分层：router 只提供「当前身份 + 选中的 cfg + 本次写入的对象名」，事务边界在
-- 本文件，裸 SQL 一律在 repository/upload_records 里（本文件不出现 db.query）。
--
-- 记账的失败语义（关键）：对象**已经写成功**，流水只是账本。记账失败绝不能把
-- 一次成功的上传变成失败响应，所以对外入口全部 pcall + 只 ngx.log(WARN)。
local common = require "resty.authz.api.common"
local config_loader = require "resty.authz.config"
local files = require "resty.authz.files"
local maintenance = require "resty.authz.maintenance"
local s3 = require "resty.authz.s3"
local s3_config_store = require "resty.authz.s3_config_store"
local upload_records = require "resty.authz.repository.upload_records"
local validation = require "resty.authz.api.validation"

local _M = {}

local DEFAULT_LIMIT = 50
local MAX_LIMIT = 500      -- 与清理器单轮上限同量级，挡住 ?limit=100000 拖库
local MAX_OFFSET = 100000  -- 翻页深度上限（超过即视为异常请求）
-- 扫描量上限：repository 已经支持 SQL 里的 OFFSET（不再是「多取再切」），所以
-- offset 的代价回到 SQLite 的游标跳过，不再随 limit 放大；这里继续保留封顶，
-- 只是把深翻页限定在「最近 MAX_SCAN 条」之内（total 仍是全表真实总数），
-- 与改动前的可见行为一致。
local MAX_SCAN = 2000

-- 前置声明：以下三个本层原语必须在首次使用之前完成 local 定义 —— Lua 里
-- 「先使用后定义」会把它解析成全局读取（运行期 nil 调用报错），而 luajit 语法门
-- 不会报错，只有真实请求才会暴露。
--- 本地行的删除根目录：与 maintenance.local_root_resolver 同判据 —— 该 cfg 行的
--- local_root 优先，留空回落到全局「临时保存区」config.store_dir()（取模块上的
--- 记忆化访问器，不能 os.getenv：worker 里环境块被清空）。
local function local_root_for(cfg_id)
    local cfg = s3_config_store.for_record(cfg_id)
    local root = cfg and type(cfg.local_root) == "string" and cfg.local_root or ""
    if root == "" then root = config_loader.store_dir() end
    return root
end


--- 单条读取（SQL 在 repository.by_id）：拿到的是跨请求共享的缓存表行，逐字段
--- 拷进新表再用（就地改会污染别的请求，事故见 api/services/applications.lua:15）。
--- 失败语义保持不变：查库失败 (nil, 原因)，没有这行 (nil)。
local function record_by_id(id)
    local row, err = upload_records.by_id(id)
    if not row then
        if err then return nil, err end
        return nil
    end
    local out = {}
    for key, value in pairs(row) do out[key] = value end
    return out
end

--- 列表行 → 响应行：逐字段拷进新表（db.query 返回的是跨请求共享的 mlcache
--- 缓存表，把行对象交给响应序列化路径等于把缓存表交出去，事故见
--- api/services/applications.lua:15）。字段名与顺序保持改动前一致。
local function to_items(rows)
    local out = {}
    for _, row in ipairs(rows or {}) do
        out[#out + 1] = {
            id = row.id,
            kind = row.kind or "s3",
            cfg_id = row.cfg_id,
            bucket = row.bucket or "",
            key = row.key or "",
            size = row.size or 0,
            source = row.source or "",
            created_by = row.created_by or "",
            created_at = row.created_at,
            expires_at = row.expires_at,
            state = row.state or "",
            last_error = row.last_error or "",
        }
    end
    return out
end

function _M.list(args)
    args = args or {}
    local state, err, status = validation.valid_upload_state(args.state)
    if state == nil then return nil, err, status end
    local limit = tonumber(args.limit) or DEFAULT_LIMIT
    limit = math.max(1, math.min(MAX_LIMIT, limit))
    local offset = math.max(0, math.min(MAX_OFFSET, tonumber(args.offset) or 0))
    if offset + limit > MAX_SCAN then
        offset = math.max(0, MAX_SCAN - limit)
    end

    -- 分页与总数都下沉到 repository：list_page 在 SQL 里做 LIMIT/OFFSET，
    -- count_filtered 与它共用同一个判空真源（state 空串 = 不过滤）。改动前
    -- 这里要把空串显式翻成 nil 才不至于 total 恒 0，现在不必再绕。
    local rows, query_err = upload_records.list_page(state, limit, offset)
    if not rows then
        -- 与改动前一致：列表读库失败不改变响应形状（空列表 + 真实 total），
        -- 但要把原因留在 error.log 里，别让「查库挂了」看起来像「没有记录」。
        ngx.log(ngx.WARN, "authz: cannot list upload records: ", tostring(query_err))
        rows = {}
    end
    return { items = common.empty_array(to_items(rows)),
        total = upload_records.count_filtered(state) }
end

--- 手工删除一条流水指向的对象（或本地文件），并把行标 deleted。
--- 语义与清理器一致，但由 admin 显式触发：失败必须回 502 + 原因，不静默。
function _M.remove(id)
    id = tonumber(id)
    if not id then return nil, "记录 id 非法", 422 end
    local row, query_err = record_by_id(id)
    if not row then
        if query_err then return nil, query_err, 500 end
        return nil, "上传记录不存在", 404
    end
    if row.state == "deleted" then
        -- 幂等：已删过的行再点一次不报错（前端列表可能停留在旧快照上）。
        return { removed = true, id = id, already = true }
    end

    local now = os.time()
    local kind = tostring(row.kind or "s3")
    if kind == "local" then
        -- 本地行：key 是「删除根目录」下的相对路径（store 区或该配置的 local_root）。
        -- 目录/叶子拆分后交给 files.remove，穿越与符号链接防护由它内部两道关卡
        -- 负责（与 maintenance.remove_local 同一手法），本层不重复实现校验。
        local root = local_root_for(row.cfg_id)
        local clean = files.normalize(row.key)
        if not clean or clean == "" then return nil, "记录里的相对路径非法", 502 end
        local name = clean:match("([^/]+)$")
        local dir = clean:match("^(.*)/[^/]+$") or ""
        if not name then return nil, "记录里的文件名非法", 502 end
        local _, remove_err, remove_status = files.remove(root, dir, name, false)
        if remove_err then
            return nil, "删除本地文件失败: " .. tostring(remove_err), remove_status or 502
        end
    else
        local cfg, cfg_err, cfg_kind = s3_config_store.for_record(row.cfg_id)
        if not cfg then
            -- 凭证无从取得（行被删）或字段写坏：对象删不掉，必须看得见（不静默）。
            return nil, cfg_err or "无法取回该记录对应的存储配置",
                cfg_kind == "invalid" and 502 or 423
        end
        local bucket = tostring(row.bucket or "")
        local key = tostring(row.key or "")
        if bucket == "" or key == "" then return nil, "记录里没有桶名或对象 key", 502 end
        -- use_bucket_lifecycle 的行这里**照删**：勾选生命周期只是让定时清理器不去
        -- 和桶规则打架，admin 点「立即删除」是明确意志，不能拿它当拒绝理由。
        local ok, del_err, del_status = s3.delete(cfg, bucket, key)
        if not ok then
            return nil, "删除对象失败: " .. tostring(del_err), del_status or 502
        end
    end

    local marked, mark_err = upload_records.mark(id, "deleted", "", now)
    if not marked then
        -- 对象已删但账没落上：回 502 说清楚（下一轮清理会把它当 active 再删一次，
        -- 届时 404 → failed，仍然是可见的，不会悄悄积累）。
        return nil, "对象已删除，但流水状态写入失败: " .. tostring(mark_err), 502
    end
    return { removed = true, id = id }
end

--- 手动跑一轮清理（前端「立即清理」按钮）。直接透传 maintenance.cleanup 的统计，
--- 里面已含前端要的 scanned/deleted/failed/skipped（另带 orphans/staged/updated）。
--- 注意调的是 cleanup 而不是 tick：tick 是定时器自己的 owner 判定 + 自我续期。
function _M.cleanup(args)
    args = args or {}
    local limit = tonumber(args.limit)
    if limit ~= nil then limit = math.max(1, math.min(MAX_LIMIT * 4, limit)) end
    local ok, stats, err = pcall(maintenance.cleanup, {
        now = os.time(),
        limit = limit,
        -- store_dir 不覆盖：清理器按行取 local_root / 全局 config.store_dir()，
        -- 让手动与定时两条路走完全相同的解析（见 maintenance.local_root_resolver）。
    })
    if not ok then
        return nil, "清理执行异常: " .. tostring(stats or err), 500
    end
    if type(stats) ~= "table" then return nil, "清理未返回统计", 500 end
    return {
        scanned = stats.scanned or 0,
        deleted = stats.deleted or 0,
        failed = stats.failed or 0,
        skipped = stats.skipped or 0,
        orphans = stats.orphans or 0,
        staged = stats.staged or 0,
        updated = stats.updated or 0,
    }
end

-- ── 记账入口（给 router 的写端点调用）──────────────────────────────────────

--- 一批写入对象记流水。written 是 s3_upload 的 {name,size} 数组（也可能是
--- cjson.empty_array 哨兵 userdata，必须先判 table）。
--- 记账**永不**让上传失败：整段 pcall，逐行失败只记 WARN，返回成功条数。
function _M.record_writes(cfg, bucket, path, written, opts)
    opts = opts or {}
    if type(written) ~= "table" then return 0 end
    local ok, count = pcall(function()
        local now = os.time()
        -- env 回落项的 id 是虚拟的 0：入库必须写 NULL（cfg_id=0 指向不存在的行，
        -- 会让清理器把记录判成孤儿）。
        local cfg_id = cfg and tonumber(cfg.id)
        if cfg_id == 0 then cfg_id = nil end
        -- 整点对齐（s3_config_store.align_expiry 的契约）：清理器每小时跑一次，
        -- 只有对齐才能保证「同一小时上传的同一小时删」，也不让索引区间扫退化。
        local expires_at = s3_config_store.align_expiry(now, cfg and cfg.expires_hours)
        -- 桶自己管生命周期的配置：只记账不删（state='skipped'，清理器也会跳过）。
        local state = (cfg and cfg.use_bucket_lifecycle) and "skipped" or "active"
        local total = 0
        for _, item in ipairs(written) do
            local key = s3.join(path, item and item.name)
            if key ~= "" then
                local inserted, insert_err = upload_records.insert({
                    kind = opts.kind or "s3",
                    cfg_id = cfg_id,
                    bucket = bucket or "",
                    key = key,
                    size = tonumber(item and item.size) or 0,
                    source = opts.source or "api",
                    created_by = opts.created_by or "",
                    created_at = now,
                    expires_at = expires_at,
                    state = state,
                })
                if inserted then
                    total = total + 1
                else
                    ngx.log(ngx.WARN, "authz: upload record failed for ",
                        tostring(bucket), "/", tostring(key), ": ", tostring(insert_err))
                end
            end
        end
        return total
    end)
    if not ok then
        ngx.log(ngx.WARN, "authz: upload record pass failed: ", tostring(count))
        return 0
    end
    return count
end

--- 删除对象成功后把对应流水标 deleted。recursive=true 时按前缀匹配（目录形态
--- 一次删掉整棵子树，其下所有记录都该闭账）。同样「失败不影响本次响应」：
--- 返回错误字符串由调用方决定记日志还是忽略。
function _M.mark_deleted(cfg, bucket, key, recursive)
    local ok, count = pcall(function()
        local cfg_id = cfg and tonumber(cfg.id)
        if cfg_id == 0 then cfg_id = nil end
        local ids = upload_records.ids_by_key(cfg_id, bucket, key, recursive)
        local now = os.time()
        for _, id in ipairs(ids or {}) do
            local marked, mark_err = upload_records.mark(id, "deleted", "", now)
            if not marked then
                ngx.log(ngx.WARN, "authz: cannot mark upload record ", tostring(id),
                    " deleted: ", tostring(mark_err))
            end
        end
        -- ids_by_key 查库失败时返回 (nil, err)：这里必须挡住 nil（`#nil` 会在
        -- pcall 里抛错，把「账没闭上」的可见性降成一条笼统的 WARN）。
        return ids and #ids or 0
    end)
    if not ok then
        ngx.log(ngx.WARN, "authz: upload record close-out failed: ", tostring(count))
        return nil, tostring(count)
    end
    return count or 0
end

--- rename/move 成功后把**源** key 的流水标 deleted。
--- 为什么不给目标 key 补一条新记录：
---   1. 目标的字节不是本网关写入的（S3 侧 copy），既没有可信的 size 也没有
---      source/created_by 归属，补记会往账里塞一条来源不明的行；
---   2. rename 在 S3 上等价于「copy + delete 源」，把源记成 deleted 与真实发生的
---      删除一致，账不会留下指向不存在对象的 active 行（那才是清理器要踩的坑）；
---   3. 目标对象的回收交给桶生命周期或下一次经本网关的上传记账，TTL 缺口写进
---      交付报告的风险项，而不是在这里造伪账。
function _M.mark_renamed(cfg, bucket, source_key)
    return _M.mark_deleted(cfg, bucket, source_key, false)
end
return _M
