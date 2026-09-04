-- resty.authz.session
-- 服务端会话: SQLite 存储, Cookie 只携带随机 token

local identity = require "resty.authz.identity"
local remote_users = require "resty.authz.repository.remote_users"
local sessions = require "resty.authz.repository.sessions"
local users = require "resty.authz.repository.users"
local util = require "resty.authz.util"

local _M = {}
_M.cookie_name = "authz_session"
_M.ttl = 7 * 86400 -- 7 天
_M.secure = false
_M.cookie_domain = ""
_M.cookie_domains = {}

-- 共享会话 (Redis): 一个明确指定的 writer 创建和撤销共享会话, 其余
-- 实例只读取共享身份。
-- Casbin 策略、绑定与角色仍在各实例本地管理; 读取共享会话时仍会用本地
-- users / remote_users 校验身份, 本地不存在或已禁用即清除登录信息。
_M.redis = {
    configured = false,
    host = "",
    port = 6379,
    db = 0,
    mode = "read-only",
    username = "",
    password = "",
    prefix = "authz",
    connect_timeout = 2000,
    read_timeout = 2000,
}
_M.shared_enabled = false

local function redis_log(level, ...)
    ngx.log(level, "authz redis session: ", ...)
end

local function redis_acquire()
    local redis = require "resty.redis"
    local red = redis:new()
    red:set_timeouts(_M.redis.connect_timeout, _M.redis.read_timeout, _M.redis.read_timeout)
    local ok, err = red:connect(_M.redis.host, _M.redis.port)
    if not ok then
        return nil, "connect failed: " .. tostring(err)
    end
    if _M.redis.username ~= "" or _M.redis.password ~= "" then
        local auth_ok, auth_err
        if _M.redis.username ~= "" then
            auth_ok, auth_err = red:auth(_M.redis.username, _M.redis.password)
        else
            auth_ok, auth_err = red:auth(_M.redis.password)
        end
        if not auth_ok then
            red:close()
            return nil, "auth failed: " .. tostring(auth_err)
        end
    end
    if _M.redis.db ~= 0 then
        local sel_ok, sel_err = red:select(_M.redis.db)
        if not sel_ok then
            red:close()
            return nil, "select db failed: " .. tostring(sel_err)
        end
    end
    return red
end

local function redis_release(red)
    local ok, err = red:set_keepalive(10000, 32)
    if not ok then redis_log(ngx.DEBUG, "keepalive failed: ", tostring(err)) end
end

local function redis_key(token)
    return _M.redis.prefix .. ":session:" .. token
end

local function redis_save(token, record)
    if not _M.shared_enabled then return true end
    if _M.redis.mode ~= "read-write" then return false, "shared_session_read_only" end
    local red, err = redis_acquire()
    if not red then
        redis_log(ngx.ERR, err)
        return false, "shared_session_unavailable"
    end
    local cjson = require "cjson.safe"
    -- Redis 只共享用户 ID 与来源; 角色、策略不共享, 由各实例本地管理。
    -- csrf / expires_at 是会话机制字段, 不属于权限数据。
    local ok, set_err = red:setex(redis_key(token), _M.ttl,
        cjson.encode({
            username = record.username,
            source = record.source,
            csrf = record.csrf,
            expires_at = record.expires_at,
        }))
    redis_release(red)
    if not ok then
        redis_log(ngx.ERR, "setex failed: ", tostring(set_err))
        return false, "shared_session_unavailable"
    end
    return true
end

-- 返回 record 或 (nil, "redis_unreachable") / (nil, "not_found")
local function redis_load(token)
    if not _M.shared_enabled then return nil, "not_found" end
    local red, err = redis_acquire()
    if not red then
        redis_log(ngx.WARN, err)
        return nil, "redis_unreachable"
    end
    local raw, get_err = red:get(redis_key(token))
    if get_err then
        redis_release(red)
        redis_log(ngx.WARN, "get failed: ", tostring(get_err))
        return nil, "redis_unreachable"
    end
    redis_release(red)
    if type(raw) ~= "string" or raw == "" then
        return nil, "not_found"
    end
    local cjson = require "cjson.safe"
    local record = cjson.decode(raw)
    if type(record) ~= "table" then return nil, "not_found" end
    return {
        username = tostring(record.username or ""),
        source = tostring(record.source or "local"),
        csrf = tostring(record.csrf or ""),
        expires_at = tonumber(record.expires_at) or 0,
    }
end

local function redis_delete(token)
    if not _M.shared_enabled or _M.redis.mode ~= "read-write" then return end
    local red, err = redis_acquire()
    if not red then
        redis_log(ngx.WARN, err)
        return
    end
    local ok, del_err = red:del(redis_key(token))
    redis_release(red)
    if not ok then redis_log(ngx.WARN, "del failed: ", tostring(del_err)) end
end

local function redis_delete_many(tokens)
    if not _M.shared_enabled or _M.redis.mode ~= "read-write" or #tokens == 0 then return end
    local red, err = redis_acquire()
    if not red then
        redis_log(ngx.WARN, err)
        return
    end
    local keys = {}
    for _, token in ipairs(tokens) do keys[#keys + 1] = redis_key(token) end
    local ok, del_err = red:del(unpack(keys))
    redis_release(red)
    if not ok then redis_log(ngx.WARN, "del failed: ", tostring(del_err)) end
end

-- 共享模式下撤销某身份的全部会话: 扫描 Redis 中所有会话键,
-- 命中相同 username + source 的一并删除 (覆盖其他实例创建的会话)。
local function redis_delete_all_for(username, source)
    if not _M.shared_enabled or _M.redis.mode ~= "read-write" then return end
    local red, err = redis_acquire()
    if not red then
        redis_log(ngx.WARN, err)
        return
    end
    local cjson = require "cjson.safe"
    local cursor = "0"
    local pattern = _M.redis.prefix .. ":session:*"
    local matched = {}
    for _ = 1, 100 do
        local res = red:scan(cursor, "MATCH", pattern, "COUNT", 500)
        if type(res) ~= "table" or type(res[1]) ~= "string" or type(res[2]) ~= "table" then
            redis_log(ngx.WARN, "scan failed")
            break
        end
        cursor = res[1]
        for _, key in ipairs(res[2]) do
            local raw = red:get(key)
            if type(raw) == "string" then
                local record = cjson.decode(raw)
                if type(record) == "table" and record.username == username and
                    record.source == source then
                    matched[#matched + 1] = key
                end
            end
        end
        if cursor == "0" then break end
    end
    if #matched > 0 then
        local ok, del_err = red:del(unpack(matched))
        if not ok then redis_log(ngx.WARN, "del failed: ", tostring(del_err)) end
    end
    redis_release(red)
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
    if _M.shared_enabled and _M.redis.mode ~= "read-write" then
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
    local ok, err = sessions.insert(token, username, source, csrf, os.time() + _M.ttl)
    if not ok then
        redis_delete(token)
        return nil, err
    end
    return token
end

-- 按 cookie token 取会话, 过期返回 nil (顺带清理)
function _M.get(token)
    if not token or #token < 16 or #token > 128 then return nil end
    local s
    if _M.shared_enabled then
        local load_err
        s, load_err = redis_load(token)
        if s then
            if s.expires_at < os.time() then
                redis_delete(token)
                _M.clear_cookie()
                return nil
            end
        elseif load_err == "redis_unreachable" then
            -- 共享会话存储是唯一事实源。故障时失败关闭，绝不从 SQLite
            -- 复活可能已在其他实例撤销的 bearer token。
            _M.clear_cookie()
            return nil
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

function _M.can_write_shared()
    return not _M.shared_enabled or _M.redis.mode == "read-write"
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
