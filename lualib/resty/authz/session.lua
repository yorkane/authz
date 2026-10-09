-- resty.authz.session
-- 服务端会话: SQLite 存储, Cookie 只携带随机 token

local identity = require "resty.authz.identity"
local remote_users = require "resty.authz.repository.remote_users"
local sessions = require "resty.authz.repository.sessions"
local users = require "resty.authz.repository.users"
local util = require "resty.authz.util"
local store = require "resty.authz.shared_session_store"
local pending = require "resty.authz.repository.session_pending"

local _M = {}
_M.cookie_name = "authz_session"
_M.ttl = 7 * 86400 -- 7 天
_M.secure = false
_M.cookie_domain = ""
_M.cookie_domains = {}

-- 共享会话 (Redis) 的容错策略（事故驱动的重写）：
--   * Redis IO 故障 -> 熔断器 OPEN（跨 worker，见 shared_session_store），窗口内
--     不再产生任何网络等待；指数退避 5s->60s，窗口到期由单个 worker 半开探测。
--   * 已登录用户不因 Redis 挂掉被踢：只要该会话在 grace（默认 4 小时，见
--     AUTHZ_SESSION_FALLBACK_GRACE）内经 Redis
--     确认过存在，就允许改读本机 SQLite 镜像继续服务（AUTHZ_SESSION_SHARED_FALLBACK
--     =false 可退回严格 fail-closed）。
--   * Redis 挂掉期间欠下的写（登录签发 / 撤销）按发生顺序进 SQLite session_pending
--     队列，由 shared_session_sync 的定时器重放（owner 锁保证单条重放链）。
--     撤销类永不丢弃；
--     签发类超上限则登录显式失败（宁可 503 也不静默造出不共享的会话）。
--   * AUTH / SELECT db 失败算「配置故障」，一律不降级：配置错误必须暴露。
-- Casbin 策略、绑定与角色仍在各实例本地管理; 读取共享会话时仍会用本地
-- users / remote_users 校验身份, 本地不存在或已禁用即清除登录信息。
_M.redis = store            -- 兼容旧字段访问：config 写 store.host/port/mode/...
_M.max_pending_saves = 2000 -- 待写队列里 save 类上限（撤销类不设限）

--- 该 token 是否有尚未重放的签发记录（Redis 刚恢复时不能把欠写的会话当失效删掉）。
function _M.has_pending_save(token)
    if not store.shared_enabled then return false end
    return pending.has_save(token)
end

--- 欠写计数快照（给 /_authz/api/session 与运维看）。
function _M.pending_counts()
    if not store.shared_enabled then return { total = 0 } end
    local out = { total = 0 }
    for _, row in ipairs(sessions.pending_group_counts() or {}) do
        out[tostring(row.op)] = tonumber(row.n) or 0
        out.total = out.total + (tonumber(row.n) or 0)
    end
    return out
end

local function queue_write(op, token, record)
    if op == "save" and pending.count_save() >= _M.max_pending_saves then
        ngx.log(ngx.ERR, "authz shared session: pending queue full, refusing login")
        return false, "shared_session_queue_full"
    end
    local ok, err = pending.insert(op, token,
        record and record.username or "", record and record.source or "",
        record and record.csrf or "", record and record.expires_at or 0, os.time())
    if not ok then
        ngx.log(ngx.ERR, "authz shared session: cannot queue ", op, ": ", tostring(err))
        return false, "shared_session_unavailable"
    end
    return true
end

-- 只有 IO 类故障（含熔断中）才允许降级服务；config 类错误必须显式失败。
local function degradable(err)
    local msg = tostring(err or "")
    return msg == "breaker_open" or msg:find("^io:") ~= nil
end

local function redis_save(token, record)
    if not store.shared_enabled then return true end
    if store.mode ~= "read-write" then return false, "shared_session_read_only" end
    record.ttl = _M.ttl
    local ok, err = store.save(token, record)
    if ok then
        -- 签发是一次性动作，镜像**无条件**写：verified_at 同时被写上，本机刚登录
        -- 的会话因此立刻具备降级读资格（否则 Redis 抖动时"登录成功却立刻回登录页"）。
        -- 节流只用在读取路径（redis_load 每请求都跑），不要照搬到这里。
        sessions.upsert(token, record.username, record.source, record.csrf, record.expires_at)
        store.mark_verified(token)
        return true
    end
    if not degradable(err) then
        ngx.log(ngx.ERR, "authz shared session: save refused (", tostring(err), ")")
        return false, "shared_session_unavailable"
    end
    local queued, qerr = queue_write("save", token, record)
    if not queued then return false, qerr end
    -- 欠写期间会话仍在本机 SQLite 生效，避免 Redis 抖动把登录做成 503。
    sessions.upsert(token, record.username, record.source, record.csrf, record.expires_at)
    return true
end

-- 返回 record 或 (nil, "redis_unreachable"|"not_found", detail)
local function redis_load(token)
    if not store.shared_enabled then return nil, "not_found" end
    local record, why, detail = store.load(token)
    if record then
        -- reader 也维护本机镜像：Redis 挂掉时才有东西可降级读。
        -- mark_verified 返回 true 才回写（每个会话每个节流周期最多一次，
        -- 避免已登录请求变成每请求一次写库）。
        if store.mark_verified(token) then
            sessions.upsert(token, record.username, record.source, record.csrf,
                record.expires_at)
        end
        return record, "ok"
    end
    return nil, why, detail
end

local function redis_delete(token)
    if not store.shared_enabled or store.mode ~= "read-write" then return end
    local ok, err = store.delete(token)
    if not ok and degradable(err) then
        queue_write("delete", token, nil)
    elseif not ok then
        ngx.log(ngx.WARN, "authz shared session: delete failed (", tostring(err), ")")
    end
end

local function redis_delete_many(tokens)
    if not store.shared_enabled or store.mode ~= "read-write" or not tokens or #tokens == 0 then
        return
    end
    local ok, err = store.delete_many(tokens)
    if ok then return end
    if degradable(err) then
        for _, token in ipairs(tokens) do queue_write("delete", token, nil) end
    else
        ngx.log(ngx.WARN, "authz shared session: delete many failed (", tostring(err), ")")
    end
end

-- 共享模式下撤销某身份的全部会话: 扫描 Redis 中所有会话键,
-- 命中相同 username + source 的一并删除 (覆盖其他实例创建的会话)。
-- 撤销是安全动作：Redis 不可达时入队等重放，绝不静默跳过。
local function redis_delete_all_for(username, source)
    if not store.shared_enabled or store.mode ~= "read-write" then return end
    local ok, err = store.delete_all_for(username, source)
    if ok then return end
    if degradable(err) then
        queue_write("delete_all", nil, { username = username, source = source })
    else
        ngx.log(ngx.WARN, "authz shared session: delete all failed (", tostring(err), ")")
    end
end

local function normalize_domain(value)
    local domain = tostring(value or ""):lower()
        :gsub("^%s+", ""):gsub("%s+$", ""):gsub("^%.*", ""):gsub("%.$", "")
    if domain == "" or #domain > 253 or not domain:find("%.") or
        not domain:match("^[a-z0-9][a-z0-9.-]*[a-z0-9]$") or
        domain:find("..", 1, true) then
        return ""
    end
    for label in domain:gmatch("[^.]+") do
        if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then return "" end
    end
    return "." .. domain
end

local function host_from_url(value)
    local authority = tostring(value or ""):match("^https?://([^/%?#]+)")
    if not authority then return "" end
    if authority:sub(1, 1) == "[" then return "" end
    return authority:gsub(":%d+$", ""):lower()
end

local function label_count(domain)
    local count = 0
    for _ in tostring(domain or ""):gsub("^%.", ""):gmatch("[^.]+") do count = count + 1 end
    return count
end

local function domain_matches_host(domain, host)
    domain = tostring(domain or ""):gsub("^%.", "")
    return domain ~= "" and (host == domain or host:sub(-#domain - 1) == "." .. domain)
end

local function domain_from_host(host)
    host = tostring(host or ""):lower():gsub("%.$", "")
    if host == "" or host:match("^%d+%.%d+%.%d+%.%d+$") or host:find(":", 1, true) then
        return ""
    end
    local normalized = normalize_domain(host)
    if normalized == "" then return "" end
    local labels = {}
    for label in host:gmatch("[^.]+") do labels[#labels + 1] = label end
    if #labels == 2 then return normalized end
    return normalize_domain(table.concat(labels, ".", 2))
end

function _M.default_cookie_domain(host_url)
    return domain_from_host(host_from_url(host_url))
end

function _M.configure_cookie_domain(value, host_url)
    local domains, seen = {}, {}
    for candidate in tostring(value or ""):gmatch("[^,;%s]+") do
        local domain = normalize_domain(candidate)
        if domain ~= "" and not seen[domain] then
            seen[domain] = true
            domains[#domains + 1] = domain
        end
    end
    if #domains == 0 then
        local fallback = _M.default_cookie_domain(host_url)
        if fallback ~= "" then domains[1] = fallback end
    end
    _M.cookie_domains = domains
    _M.cookie_domain = domains[1] or ""
    return _M.cookie_domain
end

local function current_cookie_domain()
    local host = tostring(ngx.var.host or ""):lower():gsub("%.$", "")
    -- IP 访问 (典型: 新部署的 linux 主机直接用内网 IP 打开管理端):
    -- Domain 属性对 IP 主机无效, 且 Chromium 会把 Domain=.<ip> 归一到该 IP,
    -- 清理头会顺手删掉刚下发的 host-only 会话, 造成"登录成功却立刻跳回登录页"。
    if host == "" or host:match("^%d+%.%d+%.%d+%.%d+$") or host:find(":", 1, true) then
        return ""
    end
    -- Origin 优先: 当反向代理改写了 Host、请求 Origin 与实际 Host 不一致时,
    -- 浏览器的真实地址以 Origin 为准; 若 Origin 主机命中已配置的父域,
    -- 则以该配置域下发 Cookie (例如 Origin 为 *.ws.gatepro.cn,
    -- 而 Host 被边缘改写成 *.ai-t.wtvdev.com)。
    local origin_value = tostring(ngx.var.http_origin or ""):match("^%s*([^,]+)")
    local origin_host = host_from_url(origin_value)
    if origin_host ~= "" and origin_host ~= host:gsub(":%d+$", "") then
        local origin_selected, origin_labels = "", 0
        for _, configured in ipairs(_M.cookie_domains or {}) do
            local labels = label_count(configured)
            if domain_matches_host(configured, origin_host) and labels > origin_labels then
                origin_selected, origin_labels = configured, labels
            end
        end
        if origin_selected ~= "" then return origin_selected end
    end
    local derived = domain_from_host(host)
    local selected, selected_labels = "", 0
    for _, configured in ipairs(_M.cookie_domains or {}) do
        local labels = label_count(configured)
        if domain_matches_host(configured, host) and labels > selected_labels then
            selected, selected_labels = configured, labels
        end
    end
    if selected ~= "" and selected_labels >= label_count(derived) then return selected end
    if derived ~= "" then return derived end
    -- 配置的父域与当前请求 Host 不匹配时不能下发 Domain 属性,
    -- 否则浏览器直接拒绝该 Cookie, 登录同样不可用; 退回 host-only。
    return ""
end

local function secure_flag()
    local forwarded = tostring(ngx.var.http_x_forwarded_proto or ""):lower()
    local first_forwarded = forwarded:match("^%s*([^,;]+)")
    local forwarded_https = first_forwarded and first_forwarded:match("^https%s*$") ~= nil
    return (_M.secure or ngx.var.https == "on" or forwarded_https) and "; Secure" or ""
end

-- Sandboxed pages (CSP sandbox without allow-same-origin, e.g. HTML files
-- browsed under /_authz/files/) are treated as cross-site, so Chrome strips
-- SameSite=Lax cookies from their <video>/<img>/fetch subrequests and those
-- media requests get 302'd to the login page. SameSite=None keeps the
-- session available there; browsers only accept it together with Secure,
-- so plain-HTTP deployments must stay on Lax.
local function cookie_line(value, max_age, domain)
    local secure = secure_flag()
    local same_site = secure ~= "" and "; SameSite=None" or "; SameSite=Lax"
    local line = _M.cookie_name .. "=" .. tostring(value or "") ..
        "; Path=/; HttpOnly" .. same_site .. "; Max-Age=" .. tostring(max_age)
    if domain and domain ~= "" then line = line .. "; Domain=" .. domain end
    return line .. secure
end

local function legacy_cookie_domains(desired_domain)
    local domains, seen = {}, {}
    local desired = normalize_domain(desired_domain):gsub("^%.", "")
    local host = tostring(ngx.var.host or ""):lower():gsub("%.$", "")
    local function add(domain)
        domain = normalize_domain(domain)
        if domain ~= "" and domain:gsub("^%.", "") ~= desired and not seen[domain] then
            seen[domain] = true
            domains[#domains + 1] = domain
        end
    end

    if host ~= "" and host:match("^[a-z0-9][a-z0-9.-]*[a-z0-9]$") then
        if desired ~= "" and (host == desired or host:sub(-#desired - 1) == "." .. desired) then
            local cursor = host
            while cursor ~= desired do
                add(cursor)
                cursor = cursor:match("^[^.]+%.(.+)$") or desired
            end
        else
            -- desired 为空时, 新下发的会话本身就是该 host 上的 host-only Cookie;
            -- 此时清理 Domain=.<host> 会在浏览器中把刚写入的会话一并删除,
            -- 导致 IP 访问时登录成功却立即跳回登录页。
            if desired ~= "" then add(host) end
        end
    end

    local parent = desired
    while parent ~= "" do
        parent = parent:match("^[^.]+%.(.+)$") or ""
        if parent ~= "" and parent:find("%.") then add(parent) else break end
    end
    return domains
end

local function cleanup_cookie_lines(include_desired, include_host_only, desired_domain)
    local lines = {}
    if include_host_only then lines[#lines + 1] = cookie_line("", 0, "") end
    local desired = normalize_domain(desired_domain)
    if include_desired and desired ~= "" then
        lines[#lines + 1] = cookie_line("", 0, desired)
    end
    for _, domain in ipairs(legacy_cookie_domains(desired)) do
        lines[#lines + 1] = cookie_line("", 0, domain)
    end
    return lines
end

-- 创建本机会话，username + source 共同标识身份
function _M.create(username, source)
    source = identity.source(source)
    local principal = source and identity.key(source, username)
    if not principal then
        return nil, "invalid session identity"
    end
    source, username = identity.parse(principal)
    if store.shared_enabled and store.mode ~= "read-write" then
        return nil, "shared_session_read_only"
    end
    local token = util.random_token(32)
    local csrf = util.random_token(16)
    local saved, save_err = redis_save(token, {
        username = username,
        source = source,
        csrf = csrf,
        expires_at = os.time() + _M.ttl,
    })
    if not saved then
        return nil, save_err or "shared_session_unavailable"
    end
    -- 共享模式下 redis_save 已经把会话写进本机镜像（upsert），这里不能再
    -- INSERT：token 已存在会撞主键，等于把刚成功的登录判成失败。
    if not store.shared_enabled then
        local ok, err = sessions.insert(token, username, source, csrf, os.time() + _M.ttl)
        if not ok then return nil, err end
    end
    return token
end

-- 按 cookie token 取会话, 过期返回 nil (顺带清理)
function _M.get(token)
    if not token or #token < 16 or #token > 128 then return nil end
    local s
    if store.shared_enabled then
        local load_err
        s, load_err = redis_load(token)
        if s then
            if s.expires_at < os.time() then
                redis_delete(token)
                _M.clear_cookie()
                return nil
            end
        elseif load_err == "redis_unreachable" then
            -- Redis 不可达：允许在宽限期内改读本机镜像，避免整个实例因为
            -- 会话存储抖动就把已登录的用户全部踢下线。宽限期从"最近一次经
            -- Redis 确认存在"起算，超时即强制重新登录（fail-closed 的底线）。
            if not store.fallback_allowed() then
                _M.clear_cookie()
                return nil
            end
            -- 单次 raw 查询同时拿行 + 判宽限（verified_recent 内部按 verified_at
            -- 过滤）。分两次读会让 mlcache 里的旧行和库里的新时间戳拼成一条
            -- "看起来刚确认过"的会话。
            s = sessions.verified_recent(token, os.time() - store.grace_seconds())
            if not s or (tonumber(s.expires_at) or 0) < os.time() then
                _M.clear_cookie()
                return nil
            end
        elseif _M.has_pending_save(token) then
            -- Redis 里查不到，但本机还有未重放的签发记录（刚恢复、重放还没跑）：
            -- 按本机镜像继续服务，等定时器补齐，不能把它当失效删掉。
            s = sessions.by_token(token)
            if not s or (tonumber(s.expires_at) or 0) < os.time() then
                _M.clear_cookie()
                return nil
            end
            -- 撤销也排在队列里时不放过：否则"降级期登录 → 随后撤销"的会话会在
            -- 重放追上之前复活（by_token 走 mlcache，还可能读到已删除的旧镜像行）。
            if pending.revoked_after_save(token, s.username, s.source) then
                _M.clear_cookie()
                return nil
            end
        else
            -- Redis 中确实没有该会话: 按约定清除登录信息。
            sessions.delete(token)
            _M.clear_cookie()
            return nil
        end
    else
        s = sessions.by_token(token)
        if not s then return nil end
        if s.expires_at < os.time() then
            sessions.delete(token)
            return nil
        end
    end
    if not s then
        _M.clear_cookie()
        return nil
    end
    if s.source == "local" then
        if not users.exists_enabled(s.username) then
            redis_delete(token)
            sessions.delete(token)
            _M.clear_cookie()
            return nil
        end
    else
        if not remote_users.exists_enabled(s.source, s.username) then
            -- 本地没有该身份(或已禁用): 按约定清除登录信息。
            redis_delete(token)
            sessions.delete(token)
            _M.clear_cookie()
            return nil
        end
    end
    return s
end

function _M.delete(token)
    redis_delete(token)
    return sessions.delete(token)
end

function _M.delete_all_for(username, source)
    local normalized_source = identity.source(source) or "local"
    local rows = sessions.tokens_for(username, normalized_source)
    local tokens = {}
    for _, row in ipairs(rows) do tokens[#tokens + 1] = row.token end
    redis_delete_many(tokens)
    redis_delete_all_for(username, normalized_source)
    return sessions.delete_all_for(username, normalized_source)
end

-- SQLite session rows can participate in the caller's transaction. Redis is
-- external and cannot be rolled back, so services call this only after commit.
function _M.delete_shared_all_for(username, source)
    redis_delete_all_for(username, identity.source(source) or "local")
end

--- Redis 健康快照 + 降级状态。仅在共享模式启用时由 /_authz/api/session 输出。
function _M.shared_status()
    if not store.shared_enabled then return nil end
    local status = store.status()
    status.degraded = store.fallback_allowed() and true or false
    status.pending = _M.pending_counts()
    return status
end

function _M.can_write_shared()
    return not store.shared_enabled or store.mode == "read-write"
end

-- 从请求头解析 cookie token
function _M.get_request_token()
    local cookie = ngx.var.http_cookie
    if not cookie then return nil end
    local tokens, occurrences, seen = {}, 0, {}
    for pair in cookie:gmatch("[^;]+") do
        local name, token = pair:match("^%s*([^=]+)=([A-Za-z0-9]+)%s*$")
        if name == _M.cookie_name then
            occurrences = occurrences + 1
            if not seen[token] then
                seen[token] = true
                tokens[#tokens + 1] = token
            end
        end
    end
    if #tokens == 0 then return nil end

    local selected, latest_expiry
    for _, token in ipairs(tokens) do
        local current = _M.get(token)
        if current and (not latest_expiry or tonumber(current.expires_at) >= latest_expiry) then
            selected = token
            latest_expiry = tonumber(current.expires_at)
        end
    end
    selected = selected or tokens[1]
    if occurrences > 1 and latest_expiry then _M.set_cookie(selected) end
    return selected
end

-- 设置/清除 Set-Cookie 头
function _M.set_cookie(token)
    local desired = current_cookie_domain()
    local lines = { cookie_line(token, _M.ttl, desired) }
    for _, line in ipairs(cleanup_cookie_lines(false, desired ~= "", desired)) do lines[#lines + 1] = line end
    ngx.header["Set-Cookie"] = lines
end

function _M.clear_cookie()
    local desired = current_cookie_domain()
    ngx.header["Set-Cookie"] = cleanup_cookie_lines(true, true, desired)
end

return _M
