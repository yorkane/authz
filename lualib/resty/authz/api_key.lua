-- resty.authz.api_key
-- Service API key authentication. Only SHA-256 digests are stored in SQLite.

local repository = require "resty.authz.repository.api_keys"
local util = require "resty.authz.util"

local target = require "resty.authz.target"

local _M = {}

local TOKEN_PATTERN = [[^ak_[0-9a-f]{64}$]]
local ROLE_SET = { admin = true, staff = true, user = true, viewer = true, api = true }

function _M.valid_role(role)
    role = tostring(role or ""):lower()
    return ROLE_SET[role] and role or nil
end

function _M.principal(id)
    id = tonumber(id)
    if not id or id < 1 or id ~= math.floor(id) then return nil end
    return "api-key:" .. tostring(id)
end

function _M.authenticate(token)
    if type(token) ~= "string" or #token ~= 67 then return nil end
    if not ngx.re.match(token, TOKEN_PATTERN, "jo") then return nil end
    local token_hash = util.sha256_hex(token)
    if not token_hash then return nil end
    local row = repository.by_hash(token_hash)
    local role = row and _M.valid_role(row.role)
    if not role then return nil end
    -- loopback_only 密钥仅接受本机回环来源；非回环访问一律拒绝。
    if row.loopback_only == 1 and not target.is_loopback(ngx.var.remote_addr) then
        ngx.log(ngx.WARN, "authz: loopback-only API key rejected from ",
            tostring(ngx.var.remote_addr))
        return nil
    end
    return {
        kind = "api_key",
        id = row.id,
        name = row.name,
        username = row.name,
        source = "api-key",
        role = role,
        roles = { role },
        loopback_only = row.loopback_only == 1,
        identity = _M.principal(row.id),
        created_at = row.created_at,
        updated_at = row.updated_at,
    }
end

-- Returns presented, identity. A malformed or duplicate header is presented
-- but unauthenticated, so callers never fall back to a browser cookie.
function _M.authenticate_request()
    local headers = ngx.req.get_headers()
    local token = headers["x-authz-key"]
    if token == nil then return false, nil end
    if type(token) ~= "string" then return true, nil end
    return true, _M.authenticate(token)
end

return _M
