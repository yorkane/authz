local api_key = require "resty.authz.api_key"
local casbin = require "resty.authz.casbin"
local identity = require "resty.authz.identity"
local domain = require "resty.authz.domain"
local target = require "resty.authz.target"
local api_keys = require "resty.authz.repository.api_keys"
local bindings = require "resty.authz.repository.bindings"
local policies = require "resty.authz.repository.policies"
local remote_users = require "resty.authz.repository.remote_users"
local users = require "resty.authz.repository.users"

local _M = {}
local state = { rev = -1, enforcer = nil, bindings = nil }

local function current_revision(config)
    local dict = ngx.shared[config.cache_dict]
    return dict and (dict:get("rev") or 0) or 0
end

local function policy_lines()
    local lines = {}
    for _, row in ipairs(policies.enforcer_rows()) do
        if row.ptype == "p" then
            local actions, effect = row.v2:match("^([^|]+)|(.+)$")
            actions = actions or row.v2
            for action in actions:gmatch("[^,]+") do
                local line = "p, " .. row.v0 .. ", " .. row.v1 .. ", " .. action
                if effect then line = line .. ", " .. effect end
                lines[#lines + 1] = line
            end
        elseif row.ptype == "g" then
            lines[#lines + 1] = "g, " .. row.v0 .. ", " .. row.v1
        end
    end
    return lines
end

local function binding_map()
    local map = {}
    local function parse_header_overrides(raw)
        local blocked = { host = true, cookie = true, origin = true,
            ["x-authz-user"] = true, ["x-authz-source"] = true, ["x-authz-identity"] = true,
            ["x-authz-key"] = true, ["x-real-ip"] = true, ["x-forwarded-for"] = true,
            ["x-forwarded-host"] = true, ["x-forwarded-proto"] = true, ["x-forwarded-port"] = true,
            ["content-length"] = true, ["transfer-encoding"] = true, connection = true,
            ["keep-alive"] = true, upgrade = true, te = true, trailer = true }
        local headers = {}
        for line in (tostring(raw or "") .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
            local name, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
            if name and value ~= "" then
                local lower = name:lower()
                if not blocked[lower] and lower:sub(1, 7) ~= "x-authz-" and
                    lower:sub(1, 6) ~= "proxy-" and not value:find("%c") then
                    headers[#headers + 1] = { name = name, value = value }
                end
            end
        end
        return headers
    end
    for _, binding in ipairs(bindings.runtime_rows()) do
        map[binding.domain] = {
            target_ip = target.normalize_ip(binding.target_ip) or "127.0.0.1",
            port = binding.port,
            enabled = binding.enabled,
            websocket = binding.websocket == 1,
            upstream_host = target.normalize_authority(binding.upstream_host, true) or "",
            forwarded_host = target.normalize_authority(binding.forwarded_host, true) or "",
            forwarded_proto = (binding.forwarded_proto == "http" or binding.forwarded_proto == "https")
                and binding.forwarded_proto or "",
            forwarded_port = tonumber(binding.forwarded_port) or 0,
            origin_mode = ({ auto = true, preserve = true, rewrite = true,
                remove = true, custom = true })[binding.origin_mode] and binding.origin_mode or "auto",
            custom_origin = target.normalize_origin(binding.custom_origin, true) or "",
            simulate_local = tonumber(binding.simulate_local) == 1,
            local_ip = target.normalize_ip(binding.local_ip) or "127.0.0.1",
            upstream_scheme = binding.upstream_scheme == "https" and "https" or "http",
            upstream_ssl_verify = tonumber(binding.upstream_ssl_verify) ~= 0,
            upstream_path = target.normalize_upstream_path(binding.upstream_path) or "",
            header_overrides = parse_header_overrides(binding.header_overrides),
        }
    end
    return map
end

function _M.ensure(config)
    local revision = current_revision(config)
    if state.rev == revision and state.enforcer then return state end
    local lines = policy_lines()
    for _, user in ipairs(users.enabled_roles()) do
        local principal = assert(identity.key("local", user.username))
        for role in user.roles:gmatch("[^,%s]+") do
            lines[#lines + 1] = "g, " .. principal .. ", role:" .. role
        end
    end
    for _, user in ipairs(remote_users.enabled_roles()) do
        local principal = assert(identity.key(user.provider, user.username))
        for role in user.roles:gmatch("[^,%s]+") do
            lines[#lines + 1] = "g, " .. principal .. ", role:" .. role
        end
    end
    for _, key in ipairs(api_keys.enabled_roles()) do
        local principal, role = api_key.principal(key.id), api_key.valid_role(key.role)
        if principal and role then lines[#lines + 1] = "g, " .. principal .. ", role:" .. role end
    end
    state.enforcer = casbin.new_enforcer(lines)
    state.bindings = binding_map()
    -- 裸前缀索引：绑定只存前缀（code），resolver 用它匹配
    -- <前缀>.<任意域名> 与 <前缀>-<节点>.<任意泛域> 两种入口形态。
    local by_prefix = {}
    -- 历史遗留：改造前物化的 <前缀>-<节点>.<泛域> 完整域名（未迁移的库或
    -- 迁移时撞名的行）仍按 前缀|节点 回退，保留跨 zone 可达行为。
    local by_prefix_node = {}
    for host, binding in pairs(state.bindings) do
        if not host:find(".", 1, true) then
            by_prefix[host] = binding
        else
            local key = domain.index_key(host)
            if key and not by_prefix_node[key] then by_prefix_node[key] = binding end
        end
    end
    state.bindings_by_prefix = by_prefix
    state.bindings_by_prefix_node = by_prefix_node
    state.rev = revision
    return state
end

return _M
