-- resty.authz.discovery
-- 本机 HTTP 服务发现：把 /proc/net/tcp(+6) 里的回环 LISTEN 端口（加上 AUTHZ_DISCOVERY_PORTS
-- 显式点名的端口）中真正会说 HTTP 的那些挑出来，交给管理端菜单当"本地服务"条目。
--
-- 为什么不再是"请求路径里同步扫一遍"（实测教训）：旧实现是 per-worker Lua table 缓存，
-- 缓存过期那一刻由撞上的那个请求**串行**探测全部候选端口（本机 123 个候选，connect 100ms /
-- read 200ms 超时）——单次 /_authz/api/menu-tree 实测 9117ms（热缓存 8ms），而且 4 个 worker
-- 各自独立过期、各自重扫。现在改成：
--   1) 缓存搬进共享字典 ngx.shared.authz_cache（跨 worker 一份，键 authz:discovery:items，
--      值是 cjson 编码的 {items, ts, judged_false}）；名单语义见 scan 内注释
--   2) stale-while-revalidate：请求永远先拿旧值返回；发现 ts 过期时，只有抢到
--      authz:discovery:refreshing 锁的那个 worker 挂一个 ngx.timer.at(0) 后台重扫，其余请求
--      继续吃旧值。**只有字典完全为空**（进程刚起、还没预热过）才在请求路径里内联扫一次，
--      保证第一个请求一定能看到本机服务（管理端"加完端口立刻可见"的确定性不交给定时器）。
--   3) 候选端口分波并发探测（每波 32 个 ngx.thread），并给整轮扫描设 5s 总预算；
--   4) /proc 里最近有 ESTABLISHED/TIME_WAIT/CLOSE_WAIT 痕迹、且没被实探判过假的
--      LISTEN 端口免测直通（名单方向性与探测自反馈的处理见 scan 内注释）。
--
-- 依赖纪律：本模块同时跑在请求上下文和 ngx.timer 协程里，**禁止** require session /
-- gateway.* / api.*（会拉起整套请求期依赖并形成循环）。运行期配置表从
-- package.loaded["resty.authz"].config 取（init_by_lua 在 master 里填好、worker fork 后继承，
-- 见 config.lua 里"worker 读不到 env"那段实测说明），绝不在此处 os.getenv。
--
-- 只读约定：list() 返回的是 worker 内复用的同一张表，调用方（api/services/applications.lua）
-- 只能读、不能就地 append —— 历史上就地改缓存表把发现端口灌进过 bindings 缓存。
local cjson = require "cjson.safe"

local _M = {}

local LISTEN = "0A"
-- ESTABLISHED(01) / TIME_WAIT(06) / CLOSE_WAIT(08)：端口"最近真的被人连过"的痕迹。
local TRACED_STATES = { ["01"] = true, ["06"] = true, ["08"] = true }

local LOOPBACK = {
    ["0100007F"] = true,
    ["00000000"] = true,
}

local DICT_NAME = "authz_cache"
local ITEMS_KEY = "authz:discovery:items"
local REFRESH_KEY = "authz:discovery:refreshing"
local WARM_KEY = "authz:discovery:warm"

-- 结果在字典里的寿命远大于 TTL：TTL 只决定"该不该后台重扫"，旧值在被覆盖前一直能
-- stale 服务，避免字典条目自己先过期后又掉回请求路径内联扫描。
local ITEMS_TTL = 3600
local REFRESH_LOCK_TTL = 60
local WARM_LOCK_TTL = 300
local WARM_DELAY = 5
local PROBE_CONCURRENCY = 32
local SCAN_BUDGET_SECONDS = 5
local CONNECT_BACKOFF = { 0.001, 0.01, 0.1, 0.3 }
-- connect 一次性失败即判"这端口不是 HTTP"的错误：对它们退避重试纯属浪费预算。
local TERMINAL_CONNECT_ERRORS = {
    ["connection refused"] = true,
    ["no route to host"] = true,
    ["could not get any address"] = true,
    ["could not be resolved"] = true,
}

--- 端口是否落在可发现区间（与旧实现同一口径：排除网关自己的 listen 端口）。
local function in_range(port, config)
    return port ~= nil and port >= config.port_min and port <= config.port_max
        and port ~= config.http_port and port ~= config.https_port
end

local function cache_dict()
    local ok, dict = pcall(function() return ngx.shared[DICT_NAME] end)
    if ok and dict then return dict end
    return nil
end

--- 运行期配置表：init_by_lua（master）里 require("resty.authz").init() 填好后由 worker 继承。
--- 本模块还跑在 ngx.timer 协程里，那里既没有请求上下文也不能 os.getenv（nginx 会清空 worker
--- 环境块，见 config.lua 里的实测说明），所以只能取这份现成的表。取不到就本轮什么都不扫
--- （宁可不扫，也绝不拿默认端口范围去猜）。
local last_config = nil
local function runtime_config()
    local loaded = package.loaded["resty.authz"]
    if loaded and type(loaded.config) == "table" and loaded.config.port_min then
        return loaded.config
    end
    return last_config
end

local function item(port)
    return {
        port = port,
        source = "127.0.0.1",
        note = "127.0.0.1:" .. port,
        enabled = 1,
    }
end


-- ── /proc/net/tcp(+6) 一次解析出两份端口集合 ─────────────────────────────
--- listening：LISTEN(0A) 且在可发现区间内的本机端口。
--- traced：本轮快照里存在 ESTABLISHED(01)/TIME_WAIT(06)/CLOSE_WAIT(08) 行的端口，
--- 即"刚刚有人连过"的端口，供免测直通用。
local function parse_proc_tables(config)
    local listening, traced = {}, {}
    local function handle(path, trust_any_address)
        local file = io.open(path, "r")
        if not file then return end
        for line in file:lines() do
            local address, port_hex, state = line:match(
                "^%s*%d+:%s+([%x]+):([%x]+)%s+[%x]+:[%x]+%s+([%x]+)")
            local port = port_hex and tonumber(port_hex, 16) or nil
            if in_range(port, config) then
                if state == LISTEN then
                    -- 【刻意宽松】tcp6 放行任意地址：本机大量服务只 listen ::，按地址收紧
                    -- 会把它们整个漏掉（漏服务比多几个候选更糟，代价只是多一次探测）。
                    if trust_any_address or LOOPBACK[address] then
                        listening[port] = true
                    end
                elseif TRACED_STATES[state] then
                    traced[port] = true
                end
            end
        end
        file:close()
    end
    handle("/proc/net/tcp", false)
    handle("/proc/net/tcp6", true)
    return listening, traced
end

--- io.open / :lines() 在 procfs 罕见故障下可能抛错，而这一段没有任何 yield，
--- 可以安全地用 pcall 包住（可 yield 的代码绝不进 pcall，见 probe_ports 注释）。
local function read_proc_tables(config)
    local ok, listening, traced = pcall(parse_proc_tables, config)
    if not ok then
        ngx.log(ngx.WARN, "authz: discovery failed to read /proc tables")
        return nil, nil
    end
    return listening, traced
end

--- AUTHZ_DISCOVERY_PORTS 显式点名的端口（容器网络命名空间看不到宿主机监听表时用）。
--- 这些端口保持旧口径：一律实探，不享受免测直通 —— 它们是运维显式声明的意图，
--- 判定结果必须由真实 HTTP 响应说话。
local function configured_ports(config)
    local ports = {}
    for value in tostring(config.discovery_ports or ""):gmatch("[^,%s]+") do
        local port = tonumber(value)
        if in_range(port, config) then ports[port] = true end
    end
    return ports
end

-- ── 单端口 HTTP 判定 ─────────────────────────────────────────────────────
--- connect 带退避：端口刚进 LISTEN / 半连接队列抖动时，一次失败就判死会造成条目抖动，
--- 因此按 CONNECT_BACKOFF 重试几轮；永久性错误（拒连、无路由、地址解不出）立刻放弃，
--- 对它们退避纯属烧预算。
local function permanent_connect_error(err)
    local reason = tostring(err or ""):lower()
    for pattern in pairs(TERMINAL_CONNECT_ERRORS) do
        if reason:find(pattern, 1, true) then return true end
    end
    return false
end

local function connect_with_backoff(socket, port)
    for attempt = 1, #CONNECT_BACKOFF + 1 do
        local ok, err = socket:connect("127.0.0.1", port)
        if ok then return true end
        if attempt > #CONNECT_BACKOFF or permanent_connect_error(err) then return false end
        ngx.sleep(CONNECT_BACKOFF[attempt])
    end
    return false
end

--- 与旧实现同一判据：HEAD / 的首行响应必须是 "HTTP/x.y <三个数字>"。
local function is_http_service(port, config)
    local socket = ngx.socket.tcp()
    socket:settimeouts(config.discovery_connect_timeout, config.discovery_read_timeout,
        config.discovery_read_timeout)
    if not connect_with_backoff(socket, port) then
        socket:close()
        return false
    end
    local sent = socket:send(
        "HEAD / HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
    if not sent then
        socket:close()
        return false
    end
    local line = socket:receive("*l")
    socket:close()
    return line and line:match("^HTTP/%d+%.%d+%s+%d%d%d") ~= nil
end

-- ── 并发探测 ─────────────────────────────────────────────────────────────
--- cosocket 只能在请求协程 / ngx.timer 协程 / 由 ngx.thread.spawn 出来的 user -co-thread 里 yield，
--- 所以这里用 ngx.thread 而不是手写 coroutine.wrap：后者跨 C 边界 yield 会直接报
--- "attempt to yield across C-call boundary"。每波最多 PROBE_CONCURRENCY 路并发，
--- 波与波之间检查总预算；预算到点就停，剩下的端口既不判真也不判假（results 里没有键），
--- 由上层决定怎么处理。results[port] = true/false 是唯一的产出（不依赖 user -co-thread 返回值）。
local function probe_ports(ports, config, deadline, results, stats)
    -- ngx.thread 只在请求/定时器上下文里取（init_by_lua 的 master 阶段它可能还没就绪），
    -- 探测本身也只可能跑在 timer 协程里，所以在这里解析最稳。
    local ok, thread_util = pcall(require, "ngx.thread")
    if not ok or type(thread_util) ~= "table" then thread_util = ngx.thread end
    local spawn, wait = thread_util.spawn, thread_util.wait
    local index = 1
    local total = #ports
    while index <= total do
        if ngx.now() > deadline then
            return index
        end
        local stop = math.min(index + PROBE_CONCURRENCY - 1, total)
        local threads = {}
        for offset = index, stop do
            local port = ports[offset]
            local ok, spawned = pcall(function()
                return spawn(function()
                    results[port] = is_http_service(port, config) and true or false
                    return true
                end)
            end)
            if ok and spawned then threads[#threads + 1] = spawned end
        end
        for _, spawned in ipairs(threads) do
            -- 单路探测内部报错（极端超时组合、socket 内部错误）不能带走整轮。
            -- wait 本身就以 ok=false 报告"线程内报错"、不抛异常，因此这里绝不用
            -- pcall 包住 —— pcall 可 yield 的调用是雷区。失败的端口留在"未判定"
            -- 状态（results 无键），下一轮 TTL 自然补齐。
            local lived, waited = wait(spawned)
            if not lived or not waited then
                stats.failed = stats.failed + 1
            end
        end
        index = stop + 1
    end
    return index
end

-- ── 共享字典读写 ─────────────────────────────────────────────────────────

local worker_fallback = { expires_at = 0, items = nil }

local function by_port_sort(left, right) return left.port < right.port end
-- worker 侧记忆：同一份编码串只 decode 一次（菜单每屏都要读，热路径上避免重复解析）。
local worker_memo_raw, worker_memo_stored = nil, nil

local function stored_items(raw)
    if raw == nil or raw == false then return nil end
    if raw == worker_memo_raw then return worker_memo_stored end
    local decoded = cjson.decode(raw)
    if type(decoded) ~= "table" then return nil end
    local list = decoded.items
    if type(list) ~= "table" then return nil end
    -- judged_false：上一轮（或更早、至今未被翻案）实探**判为假**的端口集合。免测直通
    -- 必须避开它们：探测本身就在 /proc 里留下痕迹（见 scan 里的自反馈说明），否则刚被
    -- 判假的端口会靠自己的痕迹在下一轮混进列表。判真的端口不在名单里，继续吃直通加速。
    local judged_false = {}
    if type(decoded.judged_false) == "table" then
        for _, port in ipairs(decoded.judged_false) do judged_false[tonumber(port)] = true end
    end
    local stored = { items = list, ts = tonumber(decoded.ts) or 0, judged_false = judged_false }
    worker_memo_raw, worker_memo_stored = raw, stored
    return stored
end

local function store_items(dict, items, judged_false)
    if not dict then return end
    local encoded = cjson.encode({ items = items, ts = ngx.now(), judged_false = judged_false })
    if not encoded then return end
    -- forcible：字典被别的键挤满时宁可挤掉最老的，也不能让发现结果写不进去。
    local ok = dict:set(ITEMS_KEY, encoded, ITEMS_TTL, true)
    if not ok then
        ngx.log(ngx.WARN, "authz: discovery cache set failed")
    end
    -- 无论写成功与否都必须作废 worker 记忆：本 worker 刚算出的 items 与字典里
    -- 的（旧）值不是同一份，留着旧记忆会让下一次请求读到过期结果。
    worker_memo_raw, worker_memo_stored = nil, nil
end

--- 整轮扫描：解析 /proc → 免测直通 → 分波并发探测 → 写回共享字典，返回本轮统计。
--- scan() 约定：成功返回统计 table；/proc 读不出来时返回 nil，且**绝不**在失败轮次
--- 覆盖字典里的旧值（保 stale 可用）。
--- 预算到点仍未判定的端口沿用上一轮结论（上轮有就继续留、没有就继续缺）：截断只
--- 影响"没来得及看"的端口，已确认的服务不会因预算甩没；下一轮 TTL 后台重扫自然修正。
local function scan(config, dict)
    local started = ngx.now()
    local deadline = started + SCAN_BUDGET_SECONDS
    local listening, traced = read_proc_tables(config)
    if not listening then return nil end
    local declared = configured_ports(config)

    -- 【免测直通，方向性】：LISTEN 端口在本轮 /proc 快照里有任何 ESTABLISHED /
    -- TIME_WAIT / CLOSE_WAIT 痕迹 → 直接视为 HTTP 服务、跳过 HEAD 探测（正在被使用的
    -- 本机服务几乎必然秒级可用，没必要再排队探测）。这条**只放行、不排除**：没有痕迹
    -- 的静默 LISTEN 端口照常进探测队列，低频服务不会被误杀。显式声明（discovery_ports）
    -- 的端口不享受直通、一律实探 —— 那是运维点名的意图，必须由真实响应说话（旧口径）。
    --
    -- 【自反馈补丁（实测踩到）】探测本身就会在 /proc 里留下 ESTABLISHED/CLOSE_WAIT 痕迹
    -- （本机服务与网关同机，两边的行都在同一张表里）。上一轮实探**判假**的端口若凭痕迹
    -- 享受直通，就会「探测留痕 → 下轮被自己的痕迹放进列表 → 再探测再留痕」地反复进出。
    -- 因此直通还要求「它没被判过假」：判过假的端口继续每轮走探测、由真实响应说话（只是
    -- 没有加速，永远不会因为这条被排除）；判过真 / 从没探过的端口凭痕迹走直通。
    local previous, previous_judged_false = {}, {}
    local judged_false_prev = 0
    local stored_previous = stored_items(dict and dict:get(ITEMS_KEY))
    if stored_previous then
        for port in pairs(stored_previous.judged_false) do
            previous_judged_false[port] = true
            judged_false_prev = judged_false_prev + 1
        end
        for _, entry in ipairs(stored_previous.items) do
            local port = tonumber(entry.port)
            if port then previous[port] = true end
        end
    end

    local hits = {}
    local candidates, in_candidates = {}, {}
    local passthrough = 0
    local function need_probe(port)
        if not in_candidates[port] then
            in_candidates[port] = true
            candidates[#candidates + 1] = port
        end
    end
    local silent = 0
    for port in pairs(declared) do
        need_probe(port)
    end
    for port in pairs(listening) do
        if traced[port] and not declared[port] and not previous_judged_false[port] then
            hits[port] = true
            passthrough = passthrough + 1
        elseif not hits[port] then
            need_probe(port)
        end
    end
    -- 探测顺序：显式声明端口在最前（预算被截断时也要先判它们），其余按端口升序。
    table.sort(candidates, function(left, right)
        local declared_left = declared[left] and 1 or 0
        local declared_right = declared[right] and 1 or 0
        if declared_left ~= declared_right then return declared_left > declared_right end
        return left < right
    end)

    local results, stats = {}, { failed = 0 }
    probe_ports(candidates, config, deadline, results, stats)
    for port in pairs(results) do
        if results[port] then hits[port] = true end
    end
    -- 预算到点没轮到判定的端口：沿用上轮的结论（在旧列表里就继续留、不在就继续缺），
    -- 只有"本轮真的探过且判假"的端口才会出局 —— 截断只该少掉没来得及看的，
    -- 不该把上一轮确认过的服务甩没（否则条目每轮抖动，菜单闪进闪出）。
    for _, port in ipairs(candidates) do
        if results[port] == nil and previous[port] then
            hits[port] = true
            silent = silent + 1
        end
    end
    local items = {}
    for port in pairs(hits) do items[#items + 1] = item(port) end
    table.sort(items, by_port_sort)

    -- judged_false 名单只装「实探判假」的端口，并**跨轮累积**（仅保留仍在本轮
    -- 候选/监听里的）：被预算截断没探到的判假端口不能从名单里掉出去，否则会凭上一轮
    -- 探测痕迹走直通混进列表。本轮判真的端口翻案出局（回到直通快车道）。
    local judged, judged_list = 0, {}
    local judged_false_now = {}
    for _, port in ipairs(candidates) do
        if results[port] ~= nil then
            judged = judged + 1
            if results[port] == false then judged_false_now[port] = true end
        end
    end
    for port in pairs(previous_judged_false) do
        local rejudged_true = results[port] == true
        if (not rejudged_true) and (listening[port] or declared[port]) then
            judged_false_now[port] = true
        end
    end
    for port in pairs(judged_false_now) do judged_list[#judged_list + 1] = port end
    pcall(store_items, dict, items, judged_list)
    ngx.log(ngx.INFO, "authz: discovery scan done: items=", #items,
        " passthrough=", passthrough, " probed=", judged, " failed=", stats.failed,
        " judged_false_kept=", judged_false_prev,
        " deferred_kept=", silent,
        " elapsed_ms=", math.floor((ngx.now() - started) * 1000))
    return { items = items, passthrough = passthrough, probed = judged,
        deferred_kept = silent, elapsed_ms = math.floor((ngx.now() - started) * 1000) }
end

-- ── 请求路径入口 ─────────────────────────────────────────────────────────
local function schedule_refresh(dict)
    -- add 原子：同一时刻只有一个 worker 挂后台重扫（其余继续吃旧值）。锁靠自身
    -- TTL 兜底回收：扫描**成功**后立即 delete（让下一轮过期能马上再触发），
    -- 失败时保留 60s 当作退避窗口，防止坏端口把 worker 拖进无休止的重扫。
    if dict:get(REFRESH_KEY) then return false end
    local got = dict:add(REFRESH_KEY, ngx.worker.pid(), REFRESH_LOCK_TTL)
    if not got then return false end
    local armed, err = ngx.timer.at(0, function(premature)
        if premature then return end
        local cfg = runtime_config()
        local live = cache_dict()
        if not cfg or not live then return end
        local result = scan(cfg, live)
        if result then
            live:delete(REFRESH_KEY)
        else
            ngx.log(ngx.WARN, "authz: discovery background refresh incomplete")
        end
    end)
    if not armed then
        dict:delete(REFRESH_KEY)
        ngx.log(ngx.WARN, "authz: discovery refresh timer not armed: ", tostring(err))
        return false
    end
    return true
end

--- 本机服务条目。返回形状与旧实现逐字段一致：[{port, source, note, enabled}]。
--- 注意：这是 worker 内复用的共享表，调用方不得就地修改（见文件头"只读约定"）。
function _M.list(config)
    if type(config) == "table" and config.port_min then last_config = config end
    local dict = cache_dict()
    if not dict then
        -- 理论上不可达（模板里 authz_cache 一定存在）；兜底仍然内联扫，
        -- 并用 worker 级 TTL 记忆挡住"每请求重扫"的退化。
        local now = ngx.now()
        if worker_fallback.items and worker_fallback.expires_at > now then
            return worker_fallback.items
        end
        local result = scan(config, nil)
        local items = result and result.items or (worker_fallback.items or {})
        worker_fallback.items = items
        worker_fallback.expires_at = now + config.discovery_ttl
        return items
    end
    local stored = stored_items(dict:get(ITEMS_KEY))
    if stored then
        if stored.ts + config.discovery_ttl > ngx.now() then
            return stored.items
        end
        schedule_refresh(dict)
        return stored.items
    end
    -- 字典里完全没有可用结果（冷启动 / 值损坏）：请求路径内联扫一次，
    -- 保证第一个请求就能看到本机服务 —— 首请求确定性不交给定时器。
    -- 扫描中途报错时把重试节流到每秒一次（worker_fallback 兼当节流闸），
    -- 避免坏状态把每个请求都拖成一次全量扫描。
    local now = ngx.now()
    if worker_fallback.expires_at > now then return worker_fallback.items or {} end
    local result = scan(config, dict)
    if result then return result.items end
    ngx.log(ngx.WARN, "authz: discovery inline scan failed")
    worker_fallback.items = worker_fallback.items or {}
    worker_fallback.expires_at = now + 1
    return worker_fallback.items
end

-- ── init_worker 预热 ─────────────────────────────────────────────────────
--- 每个 worker 都调 warm_start()：抢 authz:discovery:warm 锁，只有抢到的那个 worker
--- 挂一次延时预热扫描（把首轮全量探测的成本挪出请求路径；锁 TTL 远大于延时，其余
--- worker 启动窗口内不会重复挂）。返回 false/true 的语义与 shared_session_sync.start()
--- 一致：false = 没挂（无字典 / 没抢到 / 定时器挂不上），true = 本 worker 负责预热。
function _M.warm_start()
    local dict = cache_dict()
    if not dict then return false end
    if not runtime_config() then return false end
    local got = dict:add(WARM_KEY, ngx.worker.pid(), WARM_LOCK_TTL)
    if not got then return false end
    local armed, err = ngx.timer.at(WARM_DELAY, function(premature)
        if premature then return end
        local cfg = runtime_config()
        local live = cache_dict()
        if not cfg or not live then return end
        -- 预热挂上后若已有请求抢先内联扫过（ts 新鲜），直接跳过，避免开局双扫。
        local stored = stored_items(live:get(ITEMS_KEY))
        if stored and stored.ts + cfg.discovery_ttl > ngx.now() then return end
        scan(cfg, live)
    end)
    if not armed then
        dict:delete(WARM_KEY)
        ngx.log(ngx.WARN, "authz: discovery warm timer not armed: ", tostring(err))
        return false
    end
    return true
end


return _M
