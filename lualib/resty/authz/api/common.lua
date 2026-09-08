local api_key = require "resty.authz.api_key"
local cjson = require "cjson.safe"
local identity = require "resty.authz.identity"
local remote_users = require "resty.authz.repository.remote_users"
local users = require "resty.authz.repository.users"

local _M = {
    HUMAN_ROLES = { "admin", "staff", "user", "guest" },
    POLICY_ROLES = { "admin", "staff", "user", "guest", "api" },
    HTTP_METHODS = {
        "*", "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "CONNECT", "TRACE"
    },
}

function _M.empty_array(rows)
    if rows and #rows > 0 then return rows end
    return cjson.empty_array
end

function _M.db_error(message, err)
    return nil, message .. ": " .. tostring(err or "database error"), 500
end

function _M.principal_for(subject)
    if subject.kind == "api_key" then return subject.identity end
    return identity.key(subject.source, subject.username)
end

function _M.roles_for(subject)
    if type(subject) == "table" and subject.kind == "api_key" then
        local role = api_key.valid_role(subject.role)
        return role and { role } or {}
    end
    local username = type(subject) == "table" and subject.username or subject
    local source = type(subject) == "table" and subject.source or "local"
    local roles_csv = source == "local" and users.roles(username) or remote_users.roles(source, username)
    if not roles_csv then return {} end
    local roles = {}
    for role in roles_csv:gmatch("[^,%s]+") do roles[#roles + 1] = role end
    return roles
end

function _M.has_any_role(subject, allowed)
    local allowed_set = {}
    for _, role in ipairs(type(allowed) == "table" and allowed or { allowed }) do
        allowed_set[tostring(role)] = true
    end
    for _, role in ipairs(_M.roles_for(subject)) do
        if allowed_set[role] then return true end
    end
    return false
end

function _M.is_admin(subject)
    if not subject then return false end
    for _, role in ipairs(_M.roles_for(subject)) do
        if role == "admin" then return true end
    end
    return false
end

-- guest 角色：只放行只读诊断页，控制面 API、管理页面与文件浏览一律拒绝。
function _M.is_guest(subject)
    if not subject then return false end
    for _, role in ipairs(_M.roles_for(subject)) do
        if role == "guest" then return true end
    end
    return false
end

return _M
