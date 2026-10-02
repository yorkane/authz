-- 每小时跑一次的后台维护：清理到期上传对象 + 扫掉上传暂存残留。
--
-- 生命周期：nginx.conf.template 的 init_worker_by_lua_block 里调 _M.start()。
-- 多个 worker 同时跑会把同一批对象删两遍（第二遍全是 404 噪音 + 无谓的 HTTP），
-- 所以用共享字典原子 add 抢「owner」锁：抢到的人负责跑，其余 worker 直接 return。
-- 锁 TTL = GC_INTERVAL 且每轮续期；owner 所在 worker 崩掉后锁自然过期，由下一次
-- init_worker（reload/重启）重新认领，最坏空转一小时。
--
-- 依赖纪律（硬性）：本模块在 init_worker 链上执行，**禁止 require 上层模块**
-- （session / api / router 会拉起一堆请求期依赖且彼此循环）。只允许 require
-- resty.authz.db / config / s3* / files / repository.* / cjson.safe。
-- 其中 config 走的是 resty.authz.config 模块本身（不是 require "resty.authz" 拿
-- 那张运行时配置表——那会连带拉起 gateway.access），而且只调它的**纯 env 函数**
-- config.store_dir() / config.store_expiry_hours()：与 load() 读同一个环境变量、
-- 同一份归一化和默认值，避免 "/data/store" 这种路径在两处各写一遍然后漂移。
--
-- 事务纪律：所有 HTTP 删除都在事务**之外**做，状态回填攒到最后一次性
-- db.transaction 提交。原因有二：① 事务里持有写锁跨网络请求 = 长事务，会把
-- 别的 worker 的写操作卡在 busy_timeout 上；② db.exec 每跑一次就 bump 一次
-- db_rev，逐行 UPDATE 会把 mlcache 的键刷爆（500 行 = 500 次 revision 变更）。
local db = require "resty.authz.db"
local s3 = require "resty.authz.s3"
local s3_config_store = require "resty.authz.s3_config_store"
local s3_configs = require "resty.authz.repository.s3_configs"
local upload_records = require "resty.authz.repository.upload_records"
local files = require "resty.authz.files"
local config = require "resty.authz.config"

local _M = {}

local GC_INTERVAL = 3600          -- 每小时一轮
local GC_DELAY = 60               -- 启动后 60s 跑第一轮（避开启动风暴）
local OWNER_KEY = "authz:maintenance:owner"
local OWNER_TTL = GC_INTERVAL
-- 单轮上限：挡住「过期时长从 0 改成 1 小时、队列里躺着十万行」时一轮跑不完。
-- 剩下的下一轮继续（队列按 state+expires_at 索引扫，代价与总量无关）。
local MAX_PER_ROUND = 500
-- 暂存残留判定：mtime 超过 6 小时才算残留（正常上传几分钟内自己就清掉了）。
local STALE_TMP_SECONDS = 6 * 3600
--- lfs 取用：init_by_lua 的 files.preload() 已经把 lfs 放进 package.loaded，
--- 正常路径不会再触发 require（首次 require lfs.so 会写一个全局，撞上
--- lua-nginx-module 的 _G 写保护告警，files.lua 头部注释记过这件事）。
--- 兜底的 pcall(require) 仍然保留：timer 协程里 lfs 是否真的可用**已实测**
--- （见 doc/ 交付说明），可用时才走这一路。
local function lfs_module()
    local loaded = package.loaded["lfs"]
    if loaded then return loaded end
    local ok, mod = pcall(require, "lfs")
    if ok and mod then return mod end
    return nil
end

local function owner_dict()
    local ok, dict = pcall(function() return ngx.shared.authz_cache end)
    if ok then return dict end
    return nil
end

--- owner 记录里的 pid 是否还活着。
-- reload 的场景：老 worker 退出后锁并不会立刻消失（TTL 一小时），新 worker 抢不到
-- 锁 → 清理器最坏空转一小时。所以先看锁里的 pid 还在不在：不在就接管，把空窗压缩到
-- 一次 init_worker。判活用 /proc/<pid>（容器里 procfs 可读，且已实测 timer 里 lfs 可用）。
-- pid 复用理论上可能，但 pid 复用 + 恰好是原来那个 owner worker 的概率极低，且后果
-- 只是同一小时多跑一轮清理（幂等：对象已删则 404 → 标 failed，不会误删别的对象）。
local function owner_alive(pid)
    pid = tonumber(pid)
    if not pid or pid <= 0 then return false end
    local lfs = lfs_module()
    if not lfs then
        -- 判活工具不可用时保守认为「还活着」：宁可空转一小时，也不要两个 worker 同删。
        return true
    end
    local attr = lfs.attributes("/proc/" .. pid)
    return attr ~= nil and attr.mode == "directory"
end

--- 认领 owner 并跑第一轮；非 owner 返回 false。
function _M.start()
    local dict = owner_dict()
    if not dict then return false end
    -- add 只在键不存在时成功（共享字典里跨 worker 原子）：这就是单 owner 的全部依据。
    local ok, err = dict:add(OWNER_KEY, ngx.worker.pid(), OWNER_TTL)
    if not ok then
        -- 抢不到时**只有 worker 0** 有资格接管「持有者已死」的锁。
        -- 为什么必须限定单一候选者：共享字典没有 CAS，「delete + add」不是原子操作，
        -- 两个 worker 同时接管会各自 delete 掉对方的 add 并都成功（实测双份 owner
        -- → 两条每小时清理链）。限定 worker 0 之后同一时刻只有一个候选者，天然无竞争；
        -- worker 0 在每次启动/reload 后必然存在，所以接管能力不会缺失。
        if (ngx.worker.id and ngx.worker.id()) ~= 0 then return false end
        local holder = dict:get(OWNER_KEY)
        if owner_alive(holder) then return false end
        dict:delete(OWNER_KEY)
        local added = dict:add(OWNER_KEY, ngx.worker.pid(), OWNER_TTL)
        if not added then return false end
        ngx.log(ngx.NOTICE, "authz: maintenance ownership taken over from dead worker ",
            tostring(holder))
    end
    _M.owned = true
    local armed, arm_err = ngx.timer.at(GC_DELAY, _M.tick)
    if not armed then
        ngx.log(ngx.WARN, "authz: maintenance timer not armed: ", tostring(arm_err))
    end
    return true
end

--- 单轮定时器回调（只有 owner worker 会挂它）。整段 pcall 包住，并且**无条件**自我
--- 续期：一次失败不能把定时器弄丢。手动清理请调 _M.cleanup()，不要调这个函数。
function _M.tick(premature)
    -- premature=true 表示 nginx 正在退出/reload，此时不许再创建新定时器。
    if premature then return end
    local ok, err = pcall(function()
        -- worker 的 sqlite 连接原本是 access 阶段 lazy 打开的；timer 协程里没有
        -- 那一步，必须自己开（driver.open 幂等，已开就复用同一个 handle）。
        -- 路径一律走 config 的记忆化取值：worker / timer 协程里 os.getenv 读不到
        -- 未在 nginx.conf 里用 env 指令声明的变量（实测返回 nil），直读会去开一
        -- 个凭空的 sqlite 文件，表现成「表不存在」这种误导性的错误。
        db.open(config.db_path())
        local stats = _M.cleanup({})
        ngx.log(ngx.NOTICE, "authz: maintenance round scanned=", tostring(stats.scanned),
            " deleted=", tostring(stats.deleted), " failed=", tostring(stats.failed),
            " skipped=", tostring(stats.skipped), " orphans=", tostring(stats.orphans),
            " staged=", tostring(stats.staged))
    end)
    if not ok then
        ngx.log(ngx.WARN, "authz: maintenance round failed: ", tostring(err))
    end
    -- 续期 owner 锁（TTL 一小时），再排下一轮。
    -- 【_M.owned 守卫】只有 owner 才续锁、才自我续期。少了这道守卫，任何非 owner
    -- 的人（比如第二阶段的接口层图省事直接调 tick 做「立即清理」）都会在本 worker
    -- 里种下一个每小时循环 —— 于是多个 worker 各跑一份清理，同一批对象被删两遍。
    -- 手动触发清理请调 _M.cleanup(opts)，它是纯函数、不碰定时器。
    if not _M.owned then return end
    local dict = owner_dict()
    if dict then
        dict:set(OWNER_KEY, ngx.worker.pid(), OWNER_TTL)
    end
    local armed, arm_err = ngx.timer.at(GC_INTERVAL, _M.tick)
    if not armed then
        _M.owned = false
        ngx.log(ngx.WARN, "authz: maintenance reschedule failed: ", tostring(arm_err))
    end
end

-- ── 状态回填（攒齐再一次提交）──────────────────────────────────────────────
local function new_pending()
    return { updates = {}, count = 0 }
end

local function remember(pending, ids, state, reason)
    for _, id in ipairs(ids) do
        pending.updates[#pending.updates + 1] = {
            id = id, state = state, reason = tostring(reason or ""),
        }
        pending.count = pending.count + 1
    end
end

--- 一次性提交所有状态回填。返回真正写库的行数。
-- 回调必须返回非 nil 才提交（db.lua:54）；返回值即回填行数。
local function flush_pending(pending, now)
    if pending.count == 0 then return 0 end
    local written, err = db.transaction(function()
        for _, update in ipairs(pending.updates) do
            local ok = upload_records.mark(update.id, update.state, update.reason, now)
            if not ok then return nil, tostring(err or update.id) end
        end
        return pending.count
    end)
    if not written then
        -- 整轮回填一起回滚（对象其实已经删掉了）：下一轮会重新扫到这些行，
        -- DeleteObjects 对不存在的 key 回 404 → 标 failed，不会重复误删。
        ngx.log(ngx.WARN, "authz: cannot write back upload record state: ",
            tostring(err))
        return 0
    end
    return written
end

-- ── 分类与批量删除 ──────────────────────────────────────────────────────────
--- 孤儿判定：cfg_id 非空但 s3_configs 里已无此行 → 凭证无从取得，对象不可达。
-- 不静默删流水行（保留可审计），标 failed + 固定 last_error='config removed'。
-- 只是被禁用（enabled=0）不算孤儿：重新启用后仍能删，标 'config disabled'。
local function known_id_set()
    local set = {}
    for _, row in ipairs(s3_configs.known_ids()) do set[tonumber(row.id)] = true end
    return set
end

--- local 项：key 是「删除根目录」下的相对路径（store 区或该配置行的 local_root）。
--- 拆成「目录 + 叶子名」交给 files.remove，多级相对 key 的安全性由两道关卡保证：
---   ① files.normalize：拒绝 .. / 控制字符 / 反斜杠，绝对路径的前导斜杠被丢掉
---      （于是 /etc/passwd 只会变成根目录下的 etc/passwd，永远出不了 root）；
---   ② files.remove → resolve_dir：逐级 symlinkattributes 校验必须是「真目录」
---      （符号链接 mode=link 直接拒），叶子名再单独过 validate_name。
--- 所以这里不重复实现校验，只做「根目录是否可用」这一层判断。
local function remove_local(root, key)
    if type(root) ~= "string" or root == "" then return nil, "删除根目录未配置" end
    if root:sub(1, 1) ~= "/" then return nil, "删除根目录必须是绝对路径" end
    local clean = files.normalize(key)
    if not clean or clean == "" then return nil, "记录里的路径非法" end
    local name = clean:match("([^/]+)$")
    if not name then return nil, "记录里的文件名非法" end
    local dir = clean:match("^(.*)/[^/]+$") or ""
    return files.remove(root, dir, name, false)
end

--- local 行的删除根目录：优先该行的配置里的 local_root（页面可填），留空 → 全局
--- 「临时保存区」config.store_dir()。opts.store_dir 可整体覆盖（测试/手动接口用）。
--- 注意：cfg_id 指向的行被删了也**不**当孤儿处理 —— 本地文件删除不需要凭证，
--- 退回全局 store 目录仍然删得掉；真删不到会在下一轮以 failed 暴露出来。
--- 本轮内同 cfg_id 只解析一次（避免每行都过一遍 store）。
local function local_root_resolver(opts)
    local override = opts and opts.store_dir
    local cache = {}
    return function(cfg_id)
        local key = tostring(cfg_id or "")
        local hit = cache[key]
        if hit then return hit end
        local resolved = override
        if not resolved then
            local root = ""
            local cfg = s3_config_store.for_record(cfg_id)
            if cfg and type(cfg.local_root) == "string" and cfg.local_root ~= "" then
                root = cfg.local_root
            end
            -- 行里没配 local_root（或压根没有行）→ 全局「临时保存区」
            if root == "" then root = config.store_dir() end
            resolved = root
        end
        cache[key] = resolved
        return resolved
    end
end

--- 一个桶一批对象：走 DeleteObjects（s3.delete_many 已处理 Quiet 与 Errors 解析）。
-- 注意 s3.lua:687 附近文档记录的坑：DeleteObjects 不会级联清掉以 / 结尾的目录标记
-- 对象。这里的 key 都是上传记录里的真对象，不涉及 marker；将来若要删前缀，
-- 必须改走 s3.delete_prefix（它对 marker 单独发 DELETE）。
-- 逐行状态由 result.errors 决定（部分漏删必须看得见，不能整批算成功）。
local function flush_s3(stats, pending, cfg, bucket, rows, now)
    local keys = {}
    for _, row in ipairs(rows) do
        local key = tostring(row.key or "")
        if key ~= "" then keys[#keys + 1] = key end
    end
    if #keys == 0 then
        local ids = {}
        for _, row in ipairs(rows) do ids[#ids + 1] = row.id end
        remember(pending, ids, "failed", "记录里没有对象 key")
        stats.failed = stats.failed + #ids
        return
    end
    local result, err = s3.delete_many(cfg, bucket, keys)
    if not result then
        local ids = {}
        for _, row in ipairs(rows) do ids[#ids + 1] = row.id end
        remember(pending, ids, "failed", err)
        stats.failed = stats.failed + #ids
        return
    end
    local failed_reason = {}
    for _, item in ipairs(result.errors or {}) do
        if item.key then
            failed_reason[item.key] = tostring(item.code or item.message or "delete error")
        end
    end
    for _, row in ipairs(rows) do
        local key = tostring(row.key or "")
        if key == "" then
            remember(pending, { row.id }, "failed", "记录里没有对象 key")
            stats.failed = stats.failed + 1
        elseif failed_reason[key] then
            remember(pending, { row.id }, "failed", failed_reason[key])
            stats.failed = stats.failed + 1
        else
            remember(pending, { row.id }, "deleted", "")
            stats.deleted = stats.deleted + 1
        end
    end
end

--- 一轮清理。也供管理接口手动调用。opts: now / limit / stale_seconds / store_dir
--- （store_dir 只覆盖 kind='local' 行的删除根目录，缺省按行取 local_root 或全局值）。
--- 返回统计 table：scanned/deleted/failed/skipped/orphans/staged/updated。
function _M.cleanup(opts)
    opts = opts or {}
    local now = tonumber(opts.now) or os.time()
    local limit = tonumber(opts.limit) or MAX_PER_ROUND
    local stats = {
        scanned = 0, deleted = 0, failed = 0, skipped = 0, orphans = 0, staged = 0,
        updated = 0,
    }
    local pending = new_pending()

    local due = upload_records.due(now, limit)
    stats.scanned = #due

    -- 同 cfg 同桶的行攒成一批（一次 DeleteObjects）；local 项逐条删（无批量接口）。
    local groups, group_order = {}, {}
    local local_rows = {}
    for _, row in ipairs(due) do
        if tostring(row.kind or "s3") == "local" then
            local_rows[#local_rows + 1] = row
        else
            local bucket = tostring(row.bucket or "")
            local key = table.concat({ tostring(row.cfg_id or ""), bucket }, "\1")
            local group = groups[key]
            if not group then
                group = { cfg_id = row.cfg_id, bucket = bucket, rows = {} }
                groups[key] = group
                group_order[#group_order + 1] = key
            end
            group.rows[#group.rows + 1] = row
        end
    end

    local known = known_id_set()
    for _, key in ipairs(group_order) do
        local group = groups[key]
        local ids = {}
        for _, row in ipairs(group.rows) do ids[#ids + 1] = row.id end
        local cfg_id = tonumber(group.cfg_id)
        if cfg_id and not known[cfg_id] then
            stats.orphans = stats.orphans + #ids
            stats.failed = stats.failed + #ids
            remember(pending, ids, "failed", "config removed")
        else
            -- cfg_id 为 NULL → 当年用的是 env 回落配置，必须回 env（不能退到当前
            -- 默认项：对象可能在另一套服务上）。
            -- store 的 third value 区分 missing / invalid，两类的 last_error 措辞
            -- 由 store 给（它知道是「行不存在/已禁用」还是「行里字段非法」）。
            local cfg, cfg_err = s3_config_store.for_record(group.cfg_id)
            if not cfg then
                stats.failed = stats.failed + #ids
                remember(pending, ids, "failed", cfg_err)
            elseif cfg.use_bucket_lifecycle then
                -- 桶自己配了生命周期规则：网关只记账不删（重复删反而与存储端打架）。
                stats.skipped = stats.skipped + #ids
                remember(pending, ids, "skipped", "deferred to bucket lifecycle")
            elseif group.bucket == "" then
                stats.failed = stats.failed + #ids
                remember(pending, ids, "failed", "记录里没有桶名")
            else
                flush_s3(stats, pending, cfg, group.bucket, group.rows, now)
            end
        end
    end

    if #local_rows > 0 then
        local root_for = local_root_resolver(opts)
        for _, row in ipairs(local_rows) do
            local ok, err = remove_local(root_for(row.cfg_id), tostring(row.key or ""))
            if ok then
                stats.deleted = stats.deleted + 1
                remember(pending, { row.id }, "deleted", "")
            else
                stats.failed = stats.failed + 1
                remember(pending, { row.id }, "failed", err)
            end
        end
    end

    stats.updated = flush_pending(pending, now)
    stats.staged = _M.cleanup_staging({ max_age = tonumber(opts.stale_seconds)
        or STALE_TMP_SECONDS })
    return stats
end

-- ── 上传暂存残留 ────────────────────────────────────────────────────────────
-- 上传中断会留下半成品：files_upload 写 .upload-*，s3_upload 写 .s3-upload-*
-- （两处命名约定各自的文件头注释里写明）。进程被杀时不会自己消失，按 mtime 判残留。
-- 只遍历单层目录、不递归、不跟随符号链接。
local TMP_PREFIXES = { ".upload-", ".s3-upload-", ".tmp-", "tmp-" }

local function looks_like_staging(name)
    for _, prefix in ipairs(TMP_PREFIXES) do
        if name:sub(1, #prefix) == prefix then return true end
    end
    return false
end

--- 清理一个目录里的暂存残留。返回删除的文件数（目录不存在返回 0）。
function _M.cleanup_dir(directory, max_age, now)
    local lfs = lfs_module()
    if not lfs then
        ngx.log(ngx.WARN, "authz: lfs unavailable, staging sweep skipped")
        return 0
    end
    local attr = lfs.attributes(directory)
    if not attr or attr.mode ~= "directory" then return 0 end
    now = tonumber(now) or os.time()
    max_age = tonumber(max_age) or STALE_TMP_SECONDS
    local removed = 0
    local iterator, handle = lfs.dir(directory)
    if not iterator then return 0 end
    for name in iterator, handle do
        if name ~= "." and name ~= ".." and looks_like_staging(name) then
            local path = directory .. "/" .. name
            -- symlinkattributes：符号链接（mode=="link"）指向的目标一律不碰，
            -- 防止有人在 files_root 里放个链接把清理引到目录外。
            local item = (lfs.symlinkattributes and lfs.symlinkattributes(path))
                or lfs.attributes(path)
            if item and item.mode == "file" and (now - (item.modification or 0)) >= max_age then
                if os.remove(path) then removed = removed + 1 end
            end
        end
    end
    -- lfs.dir 的 DIR* 要显式关（files.lua:131 同款）。
    if handle and handle.close then pcall(function() return handle:close() end) end
    return removed
end

--- 三处都扫：S3 上传暂存目录、人浏览用的 files_root、机器用的 store 区。
--- 三个路径都取 config 的记忆化值（理由同 tick 里的注释：worker 里 os.getenv 拿
--- 不到 → 会退化成默认路径，与真实部署目录错位，扫了个空目录还以为清干净了）。
--- 都是单层扫描 + 前缀白名单，不递归。返回删除总数。
--- opts.dirs 传数组时覆盖默认三处（手动接口/测试用）。
function _M.cleanup_staging(opts)
    opts = opts or {}
    local max_age = tonumber(opts.max_age) or STALE_TMP_SECONDS
    local directories = opts.dirs or {
        config.s3_tmp_dir(),
        -- 字面默认值也扫一遍：s3_upload.lua:22 在请求上下文里直读 os.getenv，
        -- worker 里那一定是 nil，于是它实际永远写 "/data/s3tmp"。当
        -- AUTHZ_S3_TMP_DIR 指到别处时，只扫记忆值会漏掉真实落点（同一份去重表
        -- 保证默认部署下这行不产生第二次遍历）。
        "/data/s3tmp",
        config.files_root(),
        opts.store_dir or config.store_dir(),
    }
    local removed = 0
    local seen = {}
    for _, directory in ipairs(directories) do
        directory = tostring(directory or "")
        -- 同一目录只扫一次（常见：AUTHZ_FILES_ROOT 与 store 指到同一处）；
        -- 空串与根目录一律跳过，防止误扫。
        if directory == "" or directory == "/" or directory == "." then
            goto continue
        end
        if seen[directory] then goto continue end
        seen[directory] = true
        do
            local ok, count = pcall(_M.cleanup_dir, directory, max_age)
            if ok then removed = removed + (tonumber(count) or 0) end
        end
        ::continue::
    end
    return removed
end

return _M
