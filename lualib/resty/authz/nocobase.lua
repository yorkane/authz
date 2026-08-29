local cjson = require "cjson.safe"
local remote = require "resty.authz.remote"

local _M = {}

local LOCAL_ROLES = {
    admin = true,
    staff = true,
    user = true,
    viewer = true,
}

local DEFAULT_ROLE_MAP = {
    admin = "admin",
    root = "admin",
    staff = "staff",
    member = "user",
    user = "user",
    viewer = "viewer",
}

local function config()
    return require("resty.authz").config
end

local function role_map(value)
    local map = {}
    for source, target in pairs(DEFAULT_ROLE_MAP) do map[source] = target end
    for entry in tostring(value or ""):gmatch("[^,;]+") do
        local source, target = entry:match("^%s*([%w_.-]+)%s*=%s*([%w_.-]+)%s*$")
        if source and LOCAL_ROLES[target:lower()] then
            map[source:lower()] = target:lower()
        end
    end
    return map
end

local function request(path, method, body, token)
    local http = require "resty.http"
    local httpc = http.new()
    local c = config()
    httpc:set_timeouts(c.noco_connect_timeout, c.noco_send_timeout, c.noco_read_timeout)
    local headers = {
        ["Accept"] = "application/json",
        ["X-Authenticator"] = "basic",
        ["User-Agent"] = "openresty-authz/1.0",
    }
    if body then headers["Content-Type"] = "application/json" end
    if token then headers["Authorization"] = "Bearer " .. token end
    local response, err = httpc:request_uri(c.noco_base_url .. path, {
        method = method,
        body = body,
        headers = headers,
        keepalive = false,
        ssl_verify = true,
    })
    if not response then return nil, "request_failed:" .. tostring(err) end
    if #(response.body or "") > c.noco_max_body_size then
        return nil, "response_too_large"
    end
    return response
end

local function response_data(response)
    local payload = cjson.decode(response.body or "")
    if type(payload) ~= "table" or type(payload.data) ~= "table" then return nil end
    return payload.data
end

local function mapped_roles(remote_roles)
    local map = role_map(config().noco_role_map)
    local selected = {}
    for _, role in ipairs(remote_roles or {}) do
        local name = type(role) == "table" and role.name or role
        local mapped = map[tostring(name or ""):lower()]
        if mapped then selected[mapped] = true end
    end
    local roles = {}
    for _, role in ipairs({ "admin", "staff", "user", "viewer" }) do
        if selected[role] then roles[#roles + 1] = role end
    end
    return roles
end

function _M.authenticate(account, password)
    local c = config()
    if not c.noco_enabled then return nil, "disabled" end
    if account == "" or password == "" then return nil, "invalid_credentials" end

    local login_body = cjson.encode({ account = account, password = password })
    if not login_body then return nil, "request_encode_failed" end
    local login, login_err = request("/api/auth:signIn", "POST", login_body)
    if not login then return nil, login_err end
    if login.status == 400 or login.status == 401 or login.status == 403 then
        return nil, "invalid_credentials"
    end
    if login.status ~= 200 then return nil, "signin_status:" .. tostring(login.status) end

    local login_data = response_data(login)
    local token = login_data and login_data.token
    if type(token) ~= "string" or #token < 16 or #token > 8192 then
        return nil, "invalid_signin_response"
    end

    local checked, check_err = request("/api/auth:check", "GET", nil, token)
    if not checked then return nil, check_err end
    if checked.status ~= 200 then return nil, "check_status:" .. tostring(checked.status) end
    local user = response_data(checked)
    if not user then return nil, "invalid_check_response" end

    local username = remote.normalize_username(user.username)
    local subject = tostring(user.id or "")
    local roles = mapped_roles(user.roles)
    if not username or subject == "" then return nil, "invalid_remote_identity" end
    if #roles == 0 then return nil, "roles_unmapped" end

    return remote.save("nocobase", subject, username, roles)
end

return _M
