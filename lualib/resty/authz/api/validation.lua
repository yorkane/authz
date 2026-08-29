local cjson = require "cjson.safe"
local identity = require "resty.authz.identity"
local bindings = require "resty.authz.repository.bindings"
local remote_users = require "resty.authz.repository.remote_users"
local target = require "resty.authz.target"
local users = require "resty.authz.repository.users"

local common = require "resty.authz.api.common"
local _M = {}

local HUMAN_ROLE_SET, POLICY_ROLE_SET, HTTP_METHOD_SET = {}, {}, {}
for _, role in ipairs(common.HUMAN_ROLES) do HUMAN_ROLE_SET[role] = true end
for _, role in ipairs(common.POLICY_ROLES) do POLICY_ROLE_SET[role] = true end
for _, method in ipairs(common.HTTP_METHODS) do HTTP_METHOD_SET[method] = true end

local BINDING_PROXY_FIELDS = {
    "upstream_host", "forwarded_host", "forwarded_proto", "forwarded_port",
    "origin_mode", "custom_origin", "simulate_local", "local_ip", "upstream_scheme",
    "upstream_ssl_verify", "upstream_path",
}
local FORWARDED_PROTO_SET = { [""] = true, http = true, https = true }
local UPSTREAM_SCHEME_SET = { http = true, https = true }
local ORIGIN_MODE_SET = {
    auto = true, preserve = true, rewrite = true, remove = true, custom = true,
}

local function config()
    return require("resty.authz").config
end

function _M.normalize_roles(value)
    local input = type(value) == "table" and value or { tostring(value or "user") }
    local roles, seen = {}, {}
    for _, item in ipairs(input) do
        for role in tostring(item):gmatch("[^,%s]+") do
            role = role:lower()
            if not HUMAN_ROLE_SET[role] then return nil, "角色仅支持 admin、staff、user、viewer" end
            if not seen[role] then
                seen[role] = true
                roles[#roles + 1] = role
            end
        end
    end
    if #roles == 0 then roles[1] = "user" end
    table.sort(roles)
    return table.concat(roles, ",")
end

function _M.normalize_http_methods(value)
    local input = type(value) == "table" and value or { tostring(value or "*") }
    local selected = {}
    for _, item in ipairs(input) do
        for method in tostring(item):gmatch("[^,%s]+") do
            method = method:upper()
            if not HTTP_METHOD_SET[method] then return nil, "动作必须是标准 HTTP 方法或 *" end
            if method == "*" then return "*" end
            selected[method] = true
        end
    end
    local methods = {}
    for _, method in ipairs(common.HTTP_METHODS) do
        if method ~= "*" and selected[method] then methods[#methods + 1] = method end
    end
    if #methods == 0 then return nil, "至少选择一个 HTTP 方法" end
    return table.concat(methods, ",")
end

function _M.parse_policy_object(value)
    local object = tostring(value or ""):gsub("%s+", "")
    if object == "" then object = "/*" end
    if #object > 512 or object:find(",", 1, true) or object:find("|", 1, true) or
        object:find("%c") then return nil, "对象格式不合法" end
    if object == "/*" then return { value = object, kind = "global", path = "/*" } end
    local port_value, path = object:match("^/(%d+)(/.*)$")
    local port = tonumber(port_value)
    local current = config()
    if not port or port < current.port_min or port > current.port_max then
        return nil, "对象必须使用 /<端口><路径> 格式，且端口在允许范围内"
    end
    return { value = "/" .. tostring(port) .. path, kind = "port", port = port, path = path }
end

local function valid_host(domain)
    return ngx.re.match(domain,
        [[^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$]]) ~= nil
end

local function valid_domain_prefix(prefix)
    return ngx.re.match(prefix, [[^[a-z0-9]([a-z0-9-]*[a-z0-9])?$]]) ~= nil
end

function _M.normalize_binding_domain(value)
    local domain = tostring(value or ""):lower():gsub("%s+", ""):gsub(":%d+$", "")
    if valid_host(domain) then return domain end
    if not valid_domain_prefix(domain) then return nil end
    local host = tostring(ngx.var.host or ""):lower():gsub("^a%-", ""):gsub("^%d+%-", "")
    local generated = domain .. "-" .. host
    return valid_host(generated) and generated or nil
end

function _M.normalize_binding_proxy(data)
    local function optional(value, default)
        if value == nil or value == cjson.null then return default end
        return value
    end
    local upstream_host = target.normalize_authority(optional(data.upstream_host, ""), true)
    if upstream_host == nil then return nil, "上游 Host 格式不合法" end
    local forwarded_host = target.normalize_authority(optional(data.forwarded_host, ""), true)
    if forwarded_host == nil then return nil, "Forwarded Host 格式不合法" end
    local forwarded_proto = tostring(optional(data.forwarded_proto, "")):lower()
        :gsub("^%s+", ""):gsub("%s+$", "")
    if not FORWARDED_PROTO_SET[forwarded_proto] then
        return nil, "Forwarded Proto 仅支持自动、http 或 https"
    end
    local forwarded_port = optional(data.forwarded_port, "")
    if forwarded_port == "" then
        forwarded_port = 0
    else
        forwarded_port = tonumber(forwarded_port)
        if forwarded_port ~= 0 and (not forwarded_port or forwarded_port % 1 ~= 0 or
            forwarded_port < 1 or forwarded_port > 65535) then
            return nil, "Forwarded Port 必须是 1-65535，留空表示自动"
        end
    end
    local origin_mode = tostring(optional(data.origin_mode, "auto")):lower()
        :gsub("^%s+", ""):gsub("%s+$", "")
    if not ORIGIN_MODE_SET[origin_mode] then return nil, "Origin 处理模式不受支持" end
    local custom_origin = target.normalize_origin(optional(data.custom_origin, ""), true)
    if custom_origin == nil then return nil, "自定义 Origin 必须是合法的 http(s) Origin" end
    if origin_mode == "custom" and custom_origin == "" then
        return nil, "自定义 Origin 模式必须填写 Origin"
    end
    local local_ip = target.normalize_ip(optional(data.local_ip, "127.0.0.1"))
    if not local_ip then return nil, "模拟本机 IP 必须是合法的 IPv4 或 IPv6 地址" end
    local upstream_scheme = tostring(optional(data.upstream_scheme, "http")):lower()
        :gsub("^%s+", ""):gsub("%s+$", "")
    if not UPSTREAM_SCHEME_SET[upstream_scheme] then return nil, "上游协议仅支持 http 或 https" end
    local upstream_path = target.normalize_upstream_path(optional(data.upstream_path, ""))
    if upstream_path == nil then
        return nil, "上游改写路径必须是合法路径，不能包含查询参数、片段、连续斜杠或 .."
    end
    local ssl_verify = optional(data.upstream_ssl_verify, true)
    if type(ssl_verify) == "string" then
        ssl_verify = ssl_verify:lower():gsub("^%s+", ""):gsub("%s+$", "")
    end
    return {
        upstream_host = upstream_host,
        forwarded_host = forwarded_host,
        forwarded_proto = forwarded_proto,
        forwarded_port = forwarded_port,
        origin_mode = origin_mode,
        custom_origin = custom_origin,
        simulate_local = (data.simulate_local == true or data.simulate_local == 1) and 1 or 0,
        local_ip = local_ip,
        upstream_scheme = upstream_scheme,
        upstream_ssl_verify = (ssl_verify == false or ssl_verify == 0 or ssl_verify == "0" or
            ssl_verify == "false") and 0 or 1,
        upstream_path = upstream_path,
    }
end

function _M.proxy_fields()
    return BINDING_PROXY_FIELDS
end

function _M.proxy_fields_present(data)
    for _, field in ipairs(BINDING_PROXY_FIELDS) do
        if data[field] ~= nil then return true end
    end
    return false
end

function _M.valid_api_key_name(value)
    local name = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not ngx.re.match(name, [[^[A-Za-z0-9][A-Za-z0-9_.-]{1,63}$]], "jo") then return nil end
    return name
end

local function valid_policy_identity(value)
    local source, username = identity.parse(value)
    if not source then return false end
    return source == "local" and users.exists_enabled(username) or
        remote_users.exists_enabled(source, username)
end

function _M.normalize_policy(data)
    local ptype = data.ptype == "g" and "g" or "p"
    local v0 = tostring(data.v0 or ""):gsub("%s+", "")
    if v0 == "" or v0:find(",", 1, true) then return nil, "主体格式不合法", 422 end
    local v1, v2
    if ptype == "p" then
        if v0:sub(1, 5) == "role:" then
            if not POLICY_ROLE_SET[v0:sub(6)] then return nil, "策略角色不受支持", 422 end
        else
            if v0:sub(1, 5) ~= "user:" then v0 = identity.key("local", v0) or "" end
            if not valid_policy_identity(v0) then return nil, "策略用户不存在或已禁用", 422 end
        end
        local object, object_err = _M.parse_policy_object(data.v1)
        if not object then return nil, object_err, 422 end
        v1 = object.value
        local binding_id = tonumber(data.binding_id)
        if data.binding_id ~= nil and tostring(data.binding_id) ~= "" then
            if not binding_id or binding_id < 1 or binding_id ~= math.floor(binding_id) then
                return nil, "绑定对象不存在", 422
            end
            if object.kind ~= "port" then return nil, "全局对象不能关联域名绑定", 422 end
            local selected = bindings.id_port(binding_id)
            if not selected then return nil, "绑定对象不存在", 422 end
            if tonumber(selected.port) ~= object.port then
                return nil, "策略对象端口与所选绑定不一致", 422
            end
        end
        local method_err
        v2, method_err = _M.normalize_http_methods(data.v2)
        if not v2 then return nil, method_err, 422 end
        if data.eft == "deny" then v2 = v2 .. "|deny" end
    else
        v1 = tostring(data.v1 or ""):gsub("%s+", "")
        if not HUMAN_ROLE_SET[v1:gsub("^role:", "")] then
            return nil, "用户角色仅支持 admin、staff、user、viewer", 422
        end
        v1 = "role:" .. v1:gsub("^role:", "")
        if v0:sub(1, 5) ~= "user:" then v0 = identity.key("local", v0) or "" end
        if not valid_policy_identity(v0) then return nil, "角色分配用户不存在或已禁用", 422 end
        v2 = "-"
    end
    return { ptype = ptype, v0 = v0, v1 = v1, v2 = v2 }
end

return _M
