-- resty.authz.shared_session_store
-- 共享会话的 Redis 数据层：连接、HMAC 签名信封、跨 worker 熔断器与健康状态。
--
-- 为什么需要熔断器（事故驱动）：早期实现每请求直连 Redis，Redis 挂掉时
-- ① 每个请求串行吃满 connect/read 超时（默认各 2s），整站变慢；② 失败即清
-- cookie，所有人掉登录；③ writer 登录 503，完全无法登录。现在：
--   * IO 类故障（连接/读写超时、拒绝连接）→ 熔断 OPEN，窗口内所有 worker
--     直接跳过 Redis（零网络等待），指数退避 5s→60s，窗口到期由单个 worker
--     半开探测；
--   * AUTH / SELECT 失败 = 配置错误（config 类）→ 单独标记，绝不允许降级读，
--     配置错误必须被暴露而不是被静默绕过。
-- 与降级读/待写队列的分工：本模块只管"碰 Redis 的动作与其健康状态"；会话
-- 语义与 SQLite 镜像在 session.lua，重放定时器在 shared_session_sync.lua。
--
-- 依赖纪律：只允许 require cjson.safe / resty.redis / resty.authz.util。
-- 禁止 require resty.authz.config（循环）与 session.lua（彼此循环）；
-- 也禁止在这里查 SQLite —— 镜像的读写全在 session.lua / repository.*。
-- 配置由 config.configure_session 在 master 里写入 _M.{host,port,db,...}，
-- worker 继承模块状态；fallback / retry_interval 同样在这里，不能放 config.lua
-- 的 load() 返回值里（worker 里 os.getenv 拿不到未声明的 env）。
local cjson = require "cjson.safe"
local util = require "resty.authz.util"

local _M = {}

_M.dict_name = "authz_shared_session"
_M.shared_enabled = false
_M.host = ""
_M.port = 6379
_M.db = 0
_M.mode = "read-only"
_M.username = ""
_M.password = ""
_M.prefix = "authz"
_M.signing_key = ""
_M.connect_timeout = 2000
_M.read_timeout = 2000
-- 写路径熔断（2026-10-13 kvrocks WAL 损坏事故驱动，默认开）：
-- 事故形态是"读正常、写全坏"（所有写命令回 ERR Corruption: WriteBatch has
-- wrong count）。IO 熔断对此完全无感 —— GET 全部成功，闸永远不开；写侧每个
-- 请求各自吃一次 SETEX 报错，writer 的会话只进本机镜像与待写队列，reader
-- 读不到 → not_found → 清浏览器 cookie，已登录用户被踢回登录页。写熔断的
-- 作用：写侧一旦失败，窗口内 save/delete 直接短路（零网络）；到点由单个
-- worker 半开探测；writer 每次成功写顺带续期 <prefix>:health:shared 信标，
-- reader 在 not_found 冷路径上据此判断"这个 not_found 可不可信"。
-- 三个值由 config.configure_session 从 env 写入（worker 里 os.getenv 读不到）。
_M.write_breaker = true
_M.write_probe_interval = 5      -- down 期间半开探测间隔（秒，config 侧钳位 1..60）
_M.writer_beacon_enabled = true  -- read-write 实例是否写存活信标
-- 降级读开关（默认开）：false = 严格 fail-closed，Redis 挂了就一律掉登录。
_M.fallback_enabled = true
-- 降级宽限期（秒）：会话"最近一次经 Redis 确认存在"必须落在这个窗口内才允许
-- 降级服务。它同时是"跨实例撤销最迟多久后一定生效"的上限 —— 调大 = Redis 长时
-- 间不可用时更不容易掉登录，但撤销延迟也相应变长。
_M.fallback_grace = 14400

-- 熔断参数：初始 5s、按连续失败次数指数退避、60s 封顶。降级许可不看这里的常量，
-- 只看每个会话的 verified_at 是否落在 _M.fallback_grace 内 —— 超过宽限期即便
-- 镜像里有会话也不再承认，必须回登录页重新签发（"Redis 长期不可用时最迟一个
-- 宽限期后恢复强制认证"的底线）。
local VERIFIED_TTL_MIN = 60
local BASE_BACKOFF_MS = 5000
local MAX_BACKOFF_MS = 60000
local LAST_OK_TTL = 3600
local PROBE_SLOT_TTL = 3

-- 共享字典键（带前缀，与 authz_cache 里的 rev / owner 锁区分开）。
local K_OPEN = "ss:open"          -- 值 = 熔断到期时间戳(ms)；靠 TTL 判定窗口结束
local K_FAILS = "ss:fails"        -- 连续失败次数
local K_ERR = "ss:last_error"
local K_CLASS = "ss:last_class"   -- io | config
local K_LASTOK = "ss:last_ok"     -- 最近一次 Redis 成功（仅健康展示用）
local K_OUTAGE = "ss:outage_start"
local K_PROBE = "ss:probe"        -- 半开探测名额（同时只有一个 worker 去探）
-- 写熔断专用键（与 IO 熔断的 K_* 完全分开：读好着的时候 IO 闸不该被写坏拉动）。
local K_WDOWN = "ss:wdown"        -- 写熔断到期时间戳(ms)；存在即 down
local K_WFAILS = "ss:wfails"      -- 连续写失败次数（展示用；退避不指数，固定探测间隔）
local K_WERR = "ss:wlast_error"   -- 最近一次写失败原因（给 status / read_models 展示）
local K_WPROBE = "ss:wprobe"      -- 写半开探测名额（同时只有一个 worker 去真写）
local K_WRECOVERED = "ss:wrecovered_at"  -- 写熔断恢复时刻（供 sync 判定立即重放）

-- 信标与探测键（真 Redis 键，带业务前缀）：
--   <prefix>:health:shared —— writer 存活信标，每次成功共享写后 SETEX 30s 续期；
--   <prefix>:health:probe  —— 写熔断半开探测用的一次性写（SETEX 10s）。
local BEACON_SUFFIX = ":health:shared"
local PROBE_KEY_SUFFIX = ":health:probe"
local BEACON_TTL = 30
local W_PROBE_SLOT_TTL = 10       -- 写探测名额的租约；必须大于一次请求能吃的最大超时

--- 降级宽限期（秒）。导出给 session.lua 复用，避免两处各算一份然后漂移。
function _M.grace_seconds()
    return math.min(604800, math.max(VERIFIED_TTL_MIN, tonumber(_M.fallback_grace) or 14400))
end

local function dict()
    local ok, store = pcall(function() return ngx.shared[_M.dict_name] end)
    if ok then return store end
    return nil
end

local function now_ms()
    return ngx.now() * 1000
end

local function backoff_ms(failures)
    local delay = BASE_BACKOFF_MS * (2 ^ math.max(0, (tonumber(failures) or 1) - 1))
    if delay > MAX_BACKOFF_MS then delay = MAX_BACKOFF_MS end
    return math.floor(delay)
end

--- 标记故障并进入/延长熔断。退避档位直接按连续失败次数指数计算（5s→10s→20s…
-- 60s 封顶），fails 只在一次成功时清零 —— 不做"扣掉已流逝时间"这类推导，
-- 那会让并发下的窗口长度不可预测。
local function breaker_open(class, err)
    local store = dict()
    if not store then return end
    class = class or "io"
    local fails = store:incr(K_FAILS, 1, 0) or 1
    local delay = backoff_ms(fails)
    store:set(K_OPEN, math.floor(now_ms() + delay), math.ceil(delay / 1000) + 1)
    store:set(K_ERR, tostring(err or ""):sub(1, 200), LAST_OK_TTL * 2)
    store:set(K_CLASS, class, LAST_OK_TTL * 2)
    if not store:get(K_OUTAGE) then
        store:set(K_OUTAGE, os.time(), LAST_OK_TTL * 4)
    end
    if class == "config" then store:delete(K_LASTOK) end
end

--- 一次成功：关闸。保留 outage_start 供事后追溯，fails 清零。
local function breaker_close()
    local store = dict()
    if not store then return end
    store:delete(K_OPEN)
    store:delete(K_FAILS)
    store:delete(K_ERR)
    store:delete(K_CLASS)
end

--- 纯读闸：只回答"现在是否处于熔断窗口内"，**不**改变任何状态。
-- 半开名额必须由真正去连 Redis 的人（acquire）消费；把它交给一个随后改读
-- SQLite 的判定函数，等于让降级判定吃掉探测名额、把 Redis 恢复往后推。
local function breaker_open_pure()
    local store = dict()
    if not store then return false end
    return store:get(K_OPEN) ~= nil
end

--- 最近一次故障是不是配置类（AUTH / SELECT db）。配置错误一律不降级。
local function config_fault()
    local store = dict()
    return store ~= nil and store:get(K_CLASS) == "config"
end

--- 熔断是否打开。半开时只放行一个 worker 去探测，其余继续走降级路径，
-- 否则 Redis 挂着的时候每个 worker 都会各自卡一遍超时。
local function breaker_open_now()
    if not _M.shared_enabled then return false end
    local store = dict()
    if not store then return false end
    if store:get(K_OPEN) then return true end
    local fails = store:get(K_FAILS)
    if not fails or fails <= 0 then return false end
    -- 窗口刚过期：抢一个探测名额；抢不到的人继续当作 OPEN。
    -- 必须用 add（键已存在即失败）而不是 safe_set：后者会覆盖，等于每个 worker
    -- 都能"抢到"，Redis 挂着时又变回所有 worker 各自去撞超时。
    local ok = store:add(K_PROBE, ngx.worker.pid(), PROBE_SLOT_TTL)
    if ok then
        store:delete(K_OPEN)
        return false
    end
    return true
end

--- 是否进入"允许改读本机镜像"的状态。
-- 判据只有三条：启用共享会话 + 开了降级开关 + 熔断 OPEN 且不是配置类故障。
-- 【不要在这里加"Redis 曾经成功过"这类全局门槛】：容器重启 / 首次部署时
-- Redis 恰好不可用是常态，那种门槛会让实例连正常登录都做不到（本次要修的
-- 正是这个）。单个 token 是否可信由该会话的 verified_at 宽限期判定
-- （session.lua 走 repository.sessions.verified_recent），陌生 token 在 SQLite
-- 镜像里根本没有行，自然过不了。
function _M.fallback_allowed()
    if not _M.shared_enabled or not _M.fallback_enabled then return false end
    return breaker_open_pure() and not config_fault()
end

local function classify(err)
    local msg = tostring(err or "")
    if msg:find("auth", 1, true) or msg:find("NOAUTH", 1, true)
        or msg:find("invalid password", 1, true) or msg:find("select db", 1, true) then
        return "config", msg
    end
    return "io", msg
end

-- ── 写路径熔断（read 正常 / write 全坏 的形态只有这套判据能发现）──────────────

--- 写熔断是否启用：需要共享会话开启 + 总开关打开。
local function write_breaker_enabled()
    return _M.shared_enabled and _M.write_breaker == true
end

local function write_probe_ms()
    local sec = tonumber(_M.write_probe_interval) or 5
    return math.floor(math.min(60, math.max(1, sec)) * 1000)
end

local function beacon_key()
    return _M.prefix .. BEACON_SUFFIX
end

--- 纯读写熔断闸：只回答"当前是否处于写熔断窗口内"，不改变任何状态。
-- 与 IO 侧 breaker_open_pure 同理：探测名额必须交给真正去写的人消费。
local function write_open_pure()
    local store = dict()
    if not store then return false end
    return store:get(K_WDOWN) ~= nil
end

--- 写闸（带半开）：窗口内 true；窗口到期时只放行一个 worker 去真写探测，
-- 抢不到名额的一律继续按 down 处理（短路零网络，这正是本需求的核心）。
local function write_open_now()
    if not write_breaker_enabled() then return false end
    local store = dict()
    if not store then return false end
    if store:get(K_WDOWN) then return true end
    local fails = store:get(K_WFAILS)
    if not fails or fails <= 0 then return false end
    -- 必须用 add（键存在即失败）；safe_set 会让每个 worker 都"抢到"探测名额。
    local ok = store:add(K_WPROBE, ngx.worker.pid(), W_PROBE_SLOT_TTL)
    if ok then
        store:delete(K_WDOWN)
        return false
    end
    return true
end

--- 记一次写侧失败：置/延长写熔断窗口并留原因。
-- 退避不做指数：写熔断的语义是"共享存储的写能力没了"，固定几秒的探测代价
-- 只是一次 SETEX，远小于每个请求各打一次网络；把窗口拉长只会推迟恢复。
local function write_breaker_open(err)
    local store = dict()
    if not store then return end
    -- 熔断未启用（共享关闭 / 总开关关掉）时不落任何键：write_state 恒为 off，
    -- 状态快照里也不该冒出 write_down=true 这种无法行动的噪音。
    if not write_breaker_enabled() then return end
    store:incr(K_WFAILS, 1, 0)
    local delay = write_probe_ms()
    store:set(K_WDOWN, math.floor(now_ms() + delay), math.ceil(delay / 1000) + 1)
    store:set(K_WERR, tostring(err or ""):sub(1, 200), LAST_OK_TTL * 2)
end

--- 写侧恢复：关闸 + 记恢复时间戳。
-- wrecovered_at 是给 shared_session_sync 的协作钩子：sync 侧已有定时重放，
-- 它每轮比较该时间戳就能发现"熔断刚恢复"，从而立刻补写欠下的队列，不必等满
-- 一个周期。本模块不 require sync（会形成循环依赖），只负责写这个键。
local function write_breaker_close()
    local store = dict()
    if not store then return end
    store:delete(K_WDOWN)
    store:delete(K_WFAILS)
    store:delete(K_WERR)
    store:delete(K_WPROBE)
    store:set(K_WRECOVERED, os.time(), LAST_OK_TTL)
end

--- 恢复后立即催一次待写队列重放（事故驱动：降级期欠下的签发/撤销要尽快补上，
-- 否则 reader 实例上的老用户在最长一个 retry 周期（默认 15s）内仍读不到会话）。
-- 只能在 timer 里跑：重放要开 SQLite、按 owner 锁串行，不能在请求协程里做同步
-- 网络与写库。用**惰性 require** 取 sync —— sync 已经 require 本模块，顶层反向
-- 依赖会在加载期形成循环 require；恢复路径上惰性取就是一次普通的模块加载。
-- 【只在 owner worker 上催】sync.run 是"显式跑一轮"入口，自己不抢 owner 锁。重放
-- 的保序保证依赖"同一时刻只有一条链"（同一 token 的 save 必须早于其后的 delete），
-- 非 owner 直接跑就会和 owner 的看守循环并行，两条链各自推进到不同条目时存在
-- "delete 先落、save 后落"的窗口 —— 已撤销的会话复活，正是 sync 里"第一条失败即
-- 停止本轮"要防的那类事故。所以本 worker 不是 owner 时**什么都不做**：owner 的看守
-- 循环到点自然会重放（最迟一个 retry 周期，与 IO 熔断恢复时的既有行为同量级），
-- 熔断恢复时刻也已经写进 ss:wrecovered_at，sync 侧要提前重放由它自己判定。
local function nudge_replay()
    local ok, timer_err = pcall(function()
        return ngx.timer.at(0, function(premature)
            if premature then return end
            local loaded, sync = pcall(require, "resty.authz.shared_session_sync")
            if loaded and type(sync) == "table" and sync.owned
                and type(sync.run) == "function" then
                local ran, run_err = pcall(sync.run, { force = true })
                if not ran then
                    ngx.log(ngx.WARN, "authz shared session: post-recovery replay failed: ",
                        tostring(run_err))
                end
            end
        end)
    end)
    if not ok then
        ngx.log(ngx.WARN, "authz shared session: cannot arm post-recovery replay: ",
            tostring(timer_err))
    end
end

--- writer 存活信标：每次成功的共享写操作后 SETEX 30s 续期。
-- 只在写成功这条路上顺带发一次（登录/撤销/重放都是低频动作），不给常态读路径
-- 增加开销；reader 也只在 not_found 冷路径上读它。
local function beat_beacon(red)
    if not _M.writer_beacon_enabled then return end
    if _M.mode ~= "read-write" then return end
    local ok, err = red:setex(beacon_key(), BEACON_TTL, tostring(os.time()))
    if not ok then
        ngx.log(ngx.WARN, "authz shared session: writer beacon failed: ", tostring(err))
    end
end

--- 写熔断状态：off = 未启用共享会话或未开写熔断；ok / down = 实时闸位。
function _M.write_state()
    if not write_breaker_enabled() then return "off" end
    return write_open_pure() and "down" or "ok"
end

--- writer 存活信标是否新鲜。返回 true / false（缺失或过期）/ nil（读取失败）。
-- 关键区分：nil = "不知道"（连不上、超时、命令报错），此时调用方必须按保守分支
-- 处理（保留 cookie）；false = 连上了、键确实不存在 = writer 超过 TTL 没写过任何东西。
function _M.writer_beacon()
    if not _M.shared_enabled then return nil end
    if not _M.writer_beacon_enabled then return nil end
    local red, err = _M.acquire()
    if not red then
        ngx.log(ngx.WARN, "authz shared session: beacon read unavailable: ", tostring(err))
        return nil
    end
    local raw, get_err = red:get(beacon_key())
    _M.release(red)
    if get_err then
        ngx.log(ngx.WARN, "authz shared session: beacon read failed: ", tostring(get_err))
        return nil
    end
    return type(raw) == "string" and raw ~= ""
end

--- 最近一次写侧失败原因（写熔断 down 时给 read_models / status 展示）。
function _M.write_last_error()
    local store = dict()
    if not store then return "" end
    return tostring(store:get(K_WERR) or "")
end

--- 写熔断最近一次恢复时刻（os.time 秒；无记录返回 nil）。
--- 给 shared_session_sync 的协作钩子：sync 每轮比较它和自己的 last_wrecovered，
--- 发现刚恢复就立刻重放待写队列，不必等满一个 retry 周期。本模块不 require
--- sync（sync 已经 require 本模块，反向依赖会在加载期形成循环 require）。
function _M.wrecovered_at()
    local store = dict()
    if not store then return nil end
    local value = store:get(K_WRECOVERED)
    return value and tonumber(value) or nil
end

--- 写侧统一准入（save / delete / delete_many 共用）。返回 (proceed, err, probed)：
---   * proceed=false：写熔断窗口内，调用方**直接返回 err 且不碰网络**（核心诉求：
---     写坏之后不再每请求打 Redis）；
---   * probed=true：本次调用抢到了半开名额，写出前先做一次探测写。
local function allow_write()
    if not write_breaker_enabled() then return true, nil, false end
    if write_open_now() then
        local reason = _M.write_last_error()
        if reason == "" then reason = "write breaker open" end
        return false, "shared_write_unavailable: " .. reason, false
    end
    local store = dict()
    local probed = store ~= nil and store:get(K_WPROBE) == ngx.worker.pid()
    return true, nil, probed
end

--- 连接/鉴权阶段失败同样算"写侧失败"（契约：任何写侧失败都要计入写熔断）。
--- 返回给调用方的错误串带 shared_write_unavailable 前缀，**除了** config 类
--- （AUTH / SELECT 失败）：那类必须原样暴露，session.lua 的 degradable() 按前缀
--- 判降级，给 config 类加前缀等于把配置错误变成可降级，登录会静默进本机镜像 ——
--- 这正是本文件顶部注释明令禁止的事。
local function write_acquire_err(err)
    local msg = tostring(err or "")
    write_breaker_open("acquire: " .. msg)
    if msg:find("^config:") then return msg end
    return "shared_write_unavailable: " .. msg
end

--- 半开探测：写一个专用的短 TTL 键，成功即认为写能力恢复。
--- 返回 (true) 或 (false, err)。
local function probe_shared_write(red)
    local ok, err = red:setex(_M.prefix .. PROBE_KEY_SUFFIX, 10, "ok")
    if not ok then
        local klass, msg = classify(err)
        write_breaker_open("probe setex: " .. msg)
        return false, "shared_write_unavailable: probe setex failed: " .. klass .. ": " .. msg
    end
    write_breaker_close()
    nudge_replay()
    ngx.log(ngx.NOTICE, "authz shared session: write breaker recovered (probe setex ok), "
        .. "nudging pending replay")
    return true
end

--- 建立/复用 Redis 连接。失败时返回 nil + "<类>: <原因>" 并驱动熔断器。
function _M.acquire()
    if _M.shared_enabled and breaker_open_now() then return nil, "breaker_open" end
    local redis = require "resty.redis"
    local red = redis:new()
    red:set_timeouts(_M.connect_timeout, _M.read_timeout, _M.read_timeout)
    local ok, err = red:connect(_M.host, _M.port)
    if not ok then
        local klass, msg = classify(err)
        if _M.shared_enabled then breaker_open(klass, "connect: " .. msg) end
        ngx.log(ngx.WARN, "authz shared session: connect failed: ", msg)
        return nil, klass .. ": connect failed: " .. msg
    end
    if _M.username ~= "" or _M.password ~= "" then
        local auth_ok, auth_err
        if _M.username ~= "" then
            auth_ok, auth_err = red:auth(_M.username, _M.password)
        else
            auth_ok, auth_err = red:auth(_M.password)
        end
        if not auth_ok then
            red:close()
            local klass, msg = classify("auth failed: " .. tostring(auth_err))
            if _M.shared_enabled then breaker_open("config", msg) end
            return nil, "config: auth failed: " .. msg
        end
    end
    if _M.db ~= 0 then
        local sel_ok, sel_err = red:select(_M.db)
        if not sel_ok then
            red:close()
            if _M.shared_enabled then breaker_open("config", "select db: " .. tostring(sel_err)) end
            return nil, "config: select db failed: " .. tostring(sel_err)
        end
    end
    if _M.shared_enabled then
        local store = dict()
        if store then
            store:set(K_LASTOK, os.time(), LAST_OK_TTL)
            breaker_close()
            store:delete(K_PROBE)
        end
    end
    return red
end

--- 探测连接失败后把闸重新拉上，避免窗口过期后每个请求都去撞超时。
function _M.mark_bad(err, klass)
    if not _M.shared_enabled then return end
    if not klass then klass = select(2, classify(err)) or "io" end
    breaker_open(klass, err)
end

function _M.release(red)
    local ok, err = red:set_keepalive(10000, 32)
    if not ok then
        ngx.log(ngx.DEBUG, "authz shared session: keepalive failed: ", tostring(err))
    end
end

function _M.key(token)
    return _M.prefix .. ":session:" .. token
end

-- 签名信封：<json>.<hex(hmac-sha256(signing_key, token .. json))>。
-- 签名覆盖 token，跨键搬运记录同样失效。
local function pack_shared(token, payload)
    local mac, err = util.hmac_hex(_M.signing_key, token .. payload)
    if not mac then return nil, err end
    return payload .. "." .. mac
end

local function unpack_shared(token, raw)
    -- hex HMAC-SHA256 固定 64 字符，分隔点在倒数第 65 位。
    if #raw <= 65 or raw:byte(#raw - 64) ~= string.byte(".") then return nil end
    local payload = raw:sub(1, #raw - 65)
    local mac = raw:sub(#raw - 63)
    local expected, err = util.hmac_hex(_M.signing_key, token .. payload)
    if not expected then
        ngx.log(ngx.ERR, "authz shared session: signing unavailable: ", tostring(err))
        return nil
    end
    return util.constant_time_equals(mac, expected) and payload or nil
end

function _M.save(token, record)
    -- 写熔断优先于任何网络动作：down 且未到探测时间 → 零网络直接失败。
    local proceed, block_err, probed = allow_write()
    if not proceed then return false, block_err end
    local red, err = _M.acquire()
    if not red then
        return false, write_acquire_err(err)
    end
    if probed then
        local ok, probe_err = probe_shared_write(red)
        if not ok then
            _M.release(red)
            return false, probe_err
        end
    end
    local envelope, pack_err = pack_shared(token, cjson.encode({
        username = record.username,
        source = record.source,
        csrf = record.csrf,
        expires_at = record.expires_at,
    }))
    if not envelope then
        _M.release(red)
        return false, "signing failed: " .. tostring(pack_err)
    end
    local ok, set_err = red:setex(_M.key(token), tonumber(record.ttl) or 604800, envelope)
    if not ok then
        _M.release(red)
        -- 写侧命令失败（含 ERR Corruption / NOPERM / 读超时）只计入**写**熔断，
        -- 不去拉动 IO 熔断闸：此刻读路径是好的，开 IO 闸会让所有 reader 连 GET
        -- 都跳过、集体进降级镜像，把"写坏"放大成"读写全坏"。
        local klass, msg = classify(set_err)
        write_breaker_open("setex: " .. msg)
        ngx.log(ngx.WARN, "authz shared session: shared write failed (", klass, "): ", msg)
        return false, "shared_write_unavailable: setex failed: " .. klass .. ": " .. msg
    end
    -- 只有写成功才续信标：信标的语义是"writer 刚成功写过共享存储"。
    beat_beacon(red)
    _M.release(red)
    return true
end

--- 读取共享会话。返回 (record|nil, why)，why ∈ redis_unreachable / not_found。
-- 只认 Redis；降级镜像的读取在 session.lua（它同时管 grace 与待写队列）。
function _M.load(token)
    local red, err = _M.acquire()
    if not red then return nil, "redis_unreachable", err end
    local raw, get_err = red:get(_M.key(token))
    if get_err then
        _M.release(red)
        local klass, msg = classify(get_err)
        _M.mark_bad("get: " .. msg, klass)
        return nil, "redis_unreachable", klass .. ": get failed: " .. msg
    end
    _M.release(red)
    if type(raw) ~= "string" or raw == "" then
        return nil, "not_found"
    end
    -- 公共 Redis 不是可信边界：未签名、伪造或被篡改的记录一律拒绝。
    local payload = unpack_shared(token, raw)
    if not payload then
        ngx.log(ngx.WARN, "authz shared session: rejected unsigned or forged record")
        return nil, "not_found"
    end
    local record = cjson.decode(payload)
    if type(record) ~= "table" then return nil, "not_found" end
    return {
        username = tostring(record.username or ""),
        source = tostring(record.source or "local"),
        csrf = tostring(record.csrf or ""),
        expires_at = tonumber(record.expires_at) or 0,
    }, "ok"
end

function _M.delete(token)
    local proceed, block_err, probed = allow_write()
    if not proceed then return false, block_err end
    local red, err = _M.acquire()
    if not red then
        return false, write_acquire_err(err)
    end
    if probed then
        local ok, probe_err = probe_shared_write(red)
        if not ok then
            _M.release(red)
            return false, probe_err
        end
    end
    local ok, del_err = red:del(_M.key(token))
    if not ok then
        _M.release(red)
        -- 登出/撤销的清理语义不变：调用方（session.lua）照旧把 delete 入队重放，
        -- 这里只负责把写侧故障计入写熔断，绝不据此清浏览器 cookie。
        local klass, msg = classify(del_err)
        write_breaker_open("del: " .. msg)
        return false, "shared_write_unavailable: del failed: " .. klass .. ": " .. msg
    end
    beat_beacon(red)
    _M.release(red)
    return true
end

function _M.delete_many(tokens)
    if not tokens or #tokens == 0 then return true end
    local proceed, block_err, probed = allow_write()
    if not proceed then return false, block_err end
    local red, err = _M.acquire()
    if not red then
        return false, write_acquire_err(err)
    end
    if probed then
        local ok, probe_err = probe_shared_write(red)
        if not ok then
            _M.release(red)
            return false, probe_err
        end
    end
    local keys = {}
    for _, token in ipairs(tokens) do keys[#keys + 1] = _M.key(token) end
    local ok, del_err = red:del(unpack(keys))
    if not ok then
        _M.release(red)
        local klass, msg = classify(del_err)
        write_breaker_open("del many: " .. msg)
        return false, "shared_write_unavailable: del failed: " .. klass .. ": " .. msg
    end
    beat_beacon(red)
    _M.release(red)
    return true
end

--- 撤销某身份的全部共享会话：SCAN 全部会话键，签名解出身份后命中即删。
-- 单次最多扫 100 轮 * COUNT 500；扫不完由 session.lua 再入队重试（幂等）。
function _M.delete_all_for(username, source)
    local red, err = _M.acquire()
    if not red then return false, err end
    local cursor = "0"
    local pattern = _M.prefix .. ":session:*"
    local matched = {}
    for _ = 1, 100 do
        local res = red:scan(cursor, "MATCH", pattern, "COUNT", 500)
        if type(res) ~= "table" or type(res[1]) ~= "string" or type(res[2]) ~= "table" then
            _M.release(red)
            _M.mark_bad("scan failed", "io")
            return false, "io: scan failed"
        end
        cursor = res[1]
        for _, key in ipairs(res[2]) do
            local raw = red:get(key)
            if type(raw) == "string" then
                local token = key:match("[a-f0-9]+$")
                local payload = token and unpack_shared(token, raw) or nil
                local record = payload and cjson.decode(payload) or nil
                if type(record) == "table" and record.username == username
                    and record.source == source then
                    matched[#matched + 1] = key
                end
            end
        end
        if cursor == "0" then break end
    end
    if #matched > 0 then
        local ok, del_err = red:del(unpack(matched))
        if not ok then
            _M.release(red)
            local klass, msg = classify(del_err)
            _M.mark_bad("del all: " .. msg, klass)
            return false, klass .. ": del failed: " .. msg
        end
    end
    -- 成功走完一轮 SCAN + DEL 就续信标：它同样是"writer 刚成功写过共享存储"的证据，
    -- 只靠登录刷信标会让"只发生撤销"的 writer 被 reader 判成缺席。
    beat_beacon(red)
    _M.release(red)
    return true
end

--- 熔断闸是否打开（纯读，不消费半开名额）。给重放循环与状态展示用。
function _M.breaker_open()
    return breaker_open_pure()
end

--- 供 /_authz/api/session 展示的 Redis 健康快照。
function _M.status()
    local store = dict()
    local open = store and store:get(K_OPEN) or nil
    local outage = store and store:get(K_OUTAGE) or nil
    local wdown = store and store:get(K_WDOWN) or nil
    local wstate = _M.write_state()
    return {
        enabled = _M.shared_enabled and true or false,
        mode = _M.mode,
        state = (not store) and "unknown"
            or ((store:get(K_CLASS) == "config") and "config"
                or (open and "down" or "ok")),
        down = open ~= nil,
        down_remaining_ms = open and math.max(0, math.floor(tonumber(open) - now_ms())) or 0,
        failures = store and (store:get(K_FAILS) or 0) or 0,
        last_error = store and (store:get(K_ERR) or "") or "",
        outage_started_at = outage and tonumber(outage) or nil,
        redis_last_ok_at = store and (store:get(K_LASTOK) or nil),
        fallback = _M.fallback_enabled and true or false,
        fallback_grace = _M.grace_seconds(),
        -- 写侧健康（2026-10-13 事故的新增维度）："读好写坏"时上面的 state 会是 ok，
        -- 只有这一组字段能暴露真相；read_models 直接取这里的 write_state。
        write_state = wstate,
        write_down = wdown ~= nil,
        write_down_remaining_ms = wdown
            and math.max(0, math.floor(tonumber(wdown) - now_ms())) or 0,
        write_failures = store and (store:get(K_WFAILS) or 0) or 0,
        last_write_error = store and (store:get(K_WERR) or "") or "",
        writer_beacon_enabled = _M.writer_beacon_enabled and true or false,
        write_recovered_at = store and (store:get(K_WRECOVERED) or nil),
    }
end

--- 会话"最近经 Redis 确认存在"的登记处。两个来源配合使用：
--   * worker 级 ss:seen:<token>（TTL 键）= 节流阀，决定多久回写一次 SQLite；
--   * SQLite sessions.verified_at = 跨 worker / 跨重启的权威凭据，降级读判据。
--- 记录"这个会话刚经 Redis 确认存在"，返回 true 表示本 worker 在节流窗口内的
-- 第一次确认（调用方据此决定要不要回写 SQLite 镜像）。少了这层节流，"每次成功读
-- 都 upsert 镜像"等于**每个已登录请求一次写库**，而 db.exec 每次都 bump 查询缓存
-- revision —— 全站缓存会被刷爆。节流窗口 = grace/4，因此镜像里的 verified_at 最多
-- 落后 grace/4，仍稳稳落在降级读的 grace 判据之内。
function _M.mark_verified(token)
    local store = dict()
    if not store or not token or token == "" then return false end
    local ttl = _M.grace_seconds()
    -- 节流窗口取宽限期的 1/4：既压住写放大，又保证 verified_at 相对 grace 够新。
    local throttle = math.max(VERIFIED_TTL_MIN, math.floor(ttl / 4))
    local added, add_err = store:add("ss:seen:" .. token, os.time(), throttle)
    if added then return true end
    -- 字典写满时放行写库（fail-open）：reader 实例的降级镜像**只**由这个返回值
    -- 驱动，卡住它就等于 Redis 挂掉时该实例无镜像可读、所有人掉登录。多写一次
    -- SQLite 的代价远小于这个后果。
    if add_err and tostring(add_err):find("no memory", 1, true) then
        ngx.log(ngx.WARN, "authz shared session: breaker dict full, mirror write un-throttled")
        return true
    end
    return false
end

return _M
