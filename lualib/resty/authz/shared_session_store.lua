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
    local red, err = _M.acquire()
    if not red then return false, err end
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
    _M.release(red)
    if not ok then
        local klass, msg = classify(set_err)
        _M.mark_bad("setex: " .. msg, klass)
        return false, klass .. ": setex failed: " .. msg
    end
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
    local red, err = _M.acquire()
    if not red then return false, err end
    local ok, del_err = red:del(_M.key(token))
    _M.release(red)
    if not ok then
        local klass, msg = classify(del_err)
        _M.mark_bad("del: " .. msg, klass)
        return false, klass .. ": del failed: " .. msg
    end
    return true
end

function _M.delete_many(tokens)
    if not tokens or #tokens == 0 then return true end
    local red, err = _M.acquire()
    if not red then return false, err end
    local keys = {}
    for _, token in ipairs(tokens) do keys[#keys + 1] = _M.key(token) end
    local ok, del_err = red:del(unpack(keys))
    _M.release(red)
    if not ok then
        local klass, msg = classify(del_err)
        _M.mark_bad("del many: " .. msg, klass)
        return false, klass .. ": del failed: " .. msg
    end
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
