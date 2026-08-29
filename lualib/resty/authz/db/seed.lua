local util = require "resty.authz.util"

local _M = {}

local function must(ok, err)
    if not ok then error(tostring(err or "database seed failed")) end
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
        return true
    end, { authz = true })
    if not ok then error("database seed failed: " .. tostring(err)) end
end

return _M
