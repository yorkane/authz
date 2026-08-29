local db = require "resty.authz.db"
local repository = require "resty.authz.repository.remote_users"

local _M = {}

local ROLE_SET = {
    admin = true,
    staff = true,
    user = true,
    viewer = true,
}

function _M.normalize_username(value)
    local username = tostring(value or ""):lower()
    if #username < 2 or #username > 254 or
        not ngx.re.match(username, [[^[a-z0-9][a-z0-9_.@+-]+$]], "jo") then
        return nil
    end
    return username
end

function _M.save(provider, subject, username, roles)
    provider = tostring(provider or ""):lower()
    subject = tostring(subject or "")
    username = _M.normalize_username(username)
    if not provider:match("^[a-z0-9_.-]+$") or subject == "" or #subject > 255 or
        not username then
        return nil, "invalid_remote_identity"
    end

    local selected = {}
    for _, role in ipairs(roles or {}) do
        role = tostring(role):lower()
        if ROLE_SET[role] then selected[role] = true end
    end
    local normalized_roles = {}
    for _, role in ipairs({ "admin", "staff", "user", "viewer" }) do
        if selected[role] then normalized_roles[#normalized_roles + 1] = role end
    end
    if #normalized_roles == 0 then return nil, "roles_unmapped" end

    local roles_csv = table.concat(normalized_roles, ",")
    local now = os.time()
    local saved, err = db.authz_transaction(function()
        return repository.save(provider, subject, username, roles_csv, now)
    end)
    if not saved then return nil, err end
    if saved.enabled ~= 1 then return nil, "identity_disabled" end

    local effective_roles = {}
    for role in saved.roles:gmatch("[^,%s]+") do
        effective_roles[#effective_roles + 1] = role
    end
    return {
        username = username,
        roles = effective_roles,
        source = provider,
    }
end

return _M
