local util = require "resty.authz.util"

local _M = {}

local function must(ok, err)
    if not ok then error(tostring(err or "database seed failed")) end
end

-- 预置 Agent 专用 API Key：仅本机可用（loopback_only=1），角色 admin。
-- 通过 AUTHZ_AGENT_API_KEY 注入；值为 ak_ 前缀的完整 token，只在启动时
-- 哈希入库，之后不再出现。留空或不设置则不创建。
local function seed_agent_api_key(db)
    local token = os.getenv("AUTHZ_AGENT_API_KEY")
    if not token or token == "" then return end
    if not ngx.re.match(token, [[^ak_[0-9a-f]{64}$]], "jo") then
        error("AUTHZ_AGENT_API_KEY format invalid (expected ak_<64 hex>)")
    end
    local token_hash = assert(util.sha256_hex(token))
    local existing = db.query("SELECT id FROM api_keys WHERE name = 'agent-default'")
    if existing and existing[1] then
        must(db.exec([[UPDATE api_keys SET token_hash = ?, loopback_only = 1,
            enabled = 1, updated_at = ? WHERE name = 'agent-default']],
            token_hash, os.time()))
        return
    end
    must(db.exec([[INSERT INTO api_keys(
        name, token_hash, role, loopback_only, enabled, created_at, updated_at)
        VALUES('agent-default', ?, 'admin', 1, 1, ?, ?)]], token_hash, os.time(), os.time()))
    ngx.log(ngx.NOTICE, "authz: seeded loopback-only agent API key 'agent-default'")
end

function _M.run(db, options)
    options = options or {}
    local ok, err = db.transaction(function()
        must(db.exec([[INSERT OR IGNORE INTO policies(ptype, v0, v1, v2)
            VALUES('p','role:admin','/*','*')]]))
        must(db.exec([[INSERT OR IGNORE INTO policies(ptype, v0, v1, v2)
            VALUES('p','role:api','/*','*')]]))
        local users = db.query("SELECT COUNT(*) AS c FROM users")
        if users and users[1] and users[1].c == 0 then
            local salt = util.random_token(16)
            local hash = assert(util.hash_password(options.admin_password or "admin123", salt))
            local now = os.time()
            must(db.exec([[INSERT INTO users
                (username, password_hash, salt, roles, enabled, created_at, updated_at)
                VALUES(?,?,?,?,1,?,?)]], "admin", hash, salt, "admin", now, now))
            ngx.log(ngx.WARN, "authz: seeded default admin user 'admin' (change password ASAP)")
        end
        must(db.exec("DELETE FROM sessions WHERE expires_at < ?", os.time()))
        seed_agent_api_key(db)
        return true
    end, { authz = true })
    if not ok then error("database seed failed: " .. tostring(err)) end
end

return _M
