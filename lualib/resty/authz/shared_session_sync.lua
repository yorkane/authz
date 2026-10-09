-- resty.authz.shared_session_sync
-- session_pending 重放循环：把 Redis 不可用期间欠下的写操作补交出去。
--
-- 生命周期：nginx.conf.template 的 init_worker_by_lua_block 里调 _M.start()。
-- owner 锁用共享字典原子 add 保证同一时刻只有一条重放链；与 maintenance 不同的
-- 是这里每个 worker 都挂看守定时器，owner worker 崩溃后锁一过期就由任意 worker
-- 接管（不必等下一次 reload —— Redis 故障期间正是最需要重放的时候）。
--
-- 顺序性（安全关键）：必须严格按 id 升序重放。同一 token 的历史可能是
-- "登录→改密撤销"，乱序执行会把已撤销的会话再写回 Redis。因此一轮里逐条
-- 顺序执行，失败的那条累加 attempts 留在队列，后续条目照常处理，由下一次
-- 定时重试补位（撤销只会晚到，绝不会丢或反超）。
--
-- 依赖纪律：init_worker 链上，只允许 require resty.authz.db / config（纯函数）/
-- repository.session_pending / shared_session_store。禁止 require session /
-- gateway.* / api.*（会拉起整套请求期依赖并形成循环）。
local db = require "resty.authz.db"
local config = require "resty.authz.config"
local pending = require "resty.authz.repository.session_pending"
local store = require "resty.authz.shared_session_store"

local _M = {}

local INTERVAL_MS = 15000
local BATCH = 200
local OWNER_KEY = "authz:shared_session_sync:owner"

--- 间隔取 master 写进 shared_session_store 的值（worker 里 os.getenv 读不到 env）。
local function interval_ms()
    local value = tonumber(store.retry_interval_ms) or INTERVAL_MS
    return math.min(600000, math.max(1000, value))
end

--- 熔断是否打开：重放循环只读闸，**不能**调 store.fallback_allowed()（那会消费
-- 半开探测名额，等于重放循环替请求去探测，探测结果又不由它负责）。
local function breaker_open()
    return store.breaker_open()
end

local function owner_dict()
    local ok, dict = pcall(function() return ngx.shared.authz_cache end)
    if ok then return dict end
    return nil
end

local function owner_ttl()
    -- 锁的存活时间 = 4 个周期。owner 每轮续期；owner 崩溃后最迟 4 个周期由任意
    -- worker 接管（看守成本只是每轮一次共享字典读，N 个 worker 也值得）。
    return math.max(60, math.floor(interval_ms() / 1000) * 4)
end

--- 每个 worker 都调 start()：挂一条"看守 + 干活"的自循环。
-- 干活前先抢 owner 锁（共享字典 add 原子，同一时刻只有一个 worker 重放），
-- 抢不到就当看守：只检查锁有没有失效，失效则接管。这样 owner worker 崩溃 /
-- 被 OOM 杀掉之后，重放链最迟 4 个周期内自动恢复，而不必等下一次 reload。
function _M.start()
    if not store.shared_enabled then return false end
    if not owner_dict() then return false end
    _M.owned = false
    local armed, arm_err = ngx.timer.at(0, _M.watch)
    if not armed then
        ngx.log(ngx.WARN, "authz: shared session sync not armed: ", tostring(arm_err))
        return false
    end
    return true
end

--- 看守循环：每个 worker 一份，无条件自我续期。
function _M.watch(premature)
    if premature then return end
    local dict = owner_dict()
    if not dict then _M.owned = false return end
    if not _M.owned then
        local got = dict:add(OWNER_KEY, ngx.worker.pid(), owner_ttl())
        if not got then
            local holder = dict:get(OWNER_KEY)
            -- 锁已过期（get 返回 nil）→ 与 add 之间存在竞争，再 add 一次即可，
            -- 原子性保证同刻只有一个接管者。
            if holder == nil then
                dict:delete(OWNER_KEY)
                got = dict:add(OWNER_KEY, ngx.worker.pid(), owner_ttl())
            end
        end
        _M.owned = got and true or false
    end
    if _M.owned then
        local ok, err = pcall(_M.replay)
        if not ok then
            ngx.log(ngx.WARN, "authz: shared session sync round failed: ", tostring(err))
        end
        dict:set(OWNER_KEY, ngx.worker.pid(), owner_ttl())
    end
    local armed = ngx.timer.at(interval_ms() / 1000, _M.watch)
    if not armed then _M.owned = false end
end

--- 重放一批。返回统计 {replayed, failed, deferred}。
-- 熔断 OPEN 时直接返回，不做任何网络尝试（"忽略重试"就是字面意思）。
function _M.replay(opts)
    opts = opts or {}
    local stats = { replayed = 0, failed = 0, deferred = 0, skipped = 0 }
    if not store.shared_enabled or store.mode ~= "read-write" then
        return stats
    end
    -- reader 实例没有写权限，也永远不该有欠写；出现欠写说明配置把 reader 当成了
    -- writer（或被手工改过库），这里不报错打断轮询，交给 status 暴露。
    -- 只看熔断闸（纯读共享字典）。这里**不能**调 store.fallback_allowed()：
    -- 它会消费半开探测名额，把闸偷偷打开，等于重放循环替请求去探测，
    -- 探测结果又不由它负责，状态会互相打脸。
    if not opts.force and breaker_open() then
        stats.deferred = pending.count()
        return stats
    end
    -- timer 协程里没有 access 阶段那次 lazy db.open，必须自己开（driver.open 幂等）。
    -- 路径必须走 config.db_path() 的记忆值：worker 里 os.getenv 读不到未声明的 env，
    -- 直读会去开一个凭空的 sqlite 文件，表现为"表不存在"。
    db.open(config.db_path())
    local now = os.time()
    local rows = pending.due(tonumber(opts.limit) or BATCH)
    local done_ids, failed_ids = {}, {}
    for _, row in ipairs(rows) do
        local op = tostring(row.op or "")
        local ok
        if op == "save" and tonumber(row.expires_at) and tonumber(row.expires_at) <= now then
            -- 会话在 Redis 恢复前就已自然过期：补写一个死会话毫无意义。
            ok = true
            stats.skipped = stats.skipped + 1
        elseif op == "save" then
            ok = store.save(row.token, {
                username = row.username, source = row.source,
                csrf = row.csrf, expires_at = tonumber(row.expires_at) or (now + 86400),
                ttl = store.session_ttl or 604800,
            })
        elseif op == "delete" then
            ok = store.delete(row.token)
        elseif op == "delete_all" then
            ok = store.delete_all_for(row.username, row.source)
        else
            ok = nil -- 未知 op：留在队列里并记 attempts，等人来看
        end
        if ok then
            done_ids[#done_ids + 1] = row.id
            stats.replayed = stats.replayed + 1
        else
            failed_ids[#failed_ids + 1] = row.id
            stats.failed = stats.failed + 1
            -- 【保序硬约束】碰到第一条失败就停止本轮，后面的条目一律不碰。
            -- 若继续跑：save(id=1) 失败、其后的 delete(id=2) 成功，下一轮就会把
            -- 这条**已被撤销**的会话重新写回 Redis —— 表现成"改密后旧会话又活了"。
            -- 宁可整条队列晚到，也不能乱序。（Redis 恢复后第一条自然先成功，
            -- 后续条目随后几轮依次跟上。）
            break
        end
    end
    if #done_ids > 0 or #failed_ids > 0 then
        local _, err = db.transaction(function()
            if #done_ids > 0 then pending.delete_ids(done_ids) end
            if #failed_ids > 0 then pending.bump_attempts(failed_ids) end
            return true
        end)
        if not err then
            ngx.log(ngx.NOTICE, "authz: shared session sync replayed=", tostring(stats.replayed),
                " failed=", tostring(stats.failed))
        end
    end
    return stats
end

--- 手动触发一轮（管理接口/测试用）。opts: force=true 跳过熔断检查。
function _M.run(opts)
    db.open(config.db_path())
    return _M.replay(opts)
end

return _M
