local db = require "resty.authz.db"

local _M = {}

local function first(rows)
    return rows and rows[1]
end

function _M.by_id(id)
    return first(db.query([[SELECT id, username, roles, enabled, created_at, last_login_at, updated_at
        FROM users WHERE id = ?]], id))
end

function _M.credentials(username)
    return first(db.query([[SELECT password_hash, salt, enabled FROM users
        WHERE username = ?]], username))
end

function _M.password(username)
    return first(db.query("SELECT password_hash, salt FROM users WHERE username = ?", username))
end

function _M.timestamps(username)
    return first(db.query([[SELECT created_at, last_login_at, updated_at FROM users
        WHERE username = ?]], username))
end

function _M.roles(username)
    local row = first(db.query("SELECT roles FROM users WHERE username = ? AND enabled = 1", username))
    return row and row.roles
end

function _M.exists_enabled(username)
    return first(db.query("SELECT id FROM users WHERE username = ? AND enabled = 1", username)) ~= nil
end

function _M.list()
    return db.query([[SELECT id, username, roles, enabled, created_at, last_login_at, updated_at
        FROM users ORDER BY id]]) or {}
end

function _M.enabled_names()
    return db.query("SELECT username FROM users WHERE enabled = 1 ORDER BY username") or {}
end

function _M.enabled_roles()
    return db.query("SELECT username, roles FROM users WHERE enabled = 1") or {}
end

function _M.insert(username, hash, salt, roles, now)
    return db.exec([[INSERT INTO users(username, password_hash, salt, roles, enabled, created_at, updated_at)
        VALUES(?,?,?,?,1,?,?)]], username, hash, salt, roles, now, now)
end

function _M.update_fields(id, enabled, roles, now)
    if enabled ~= nil then
        local ok, err = db.exec("UPDATE users SET enabled = ?, updated_at = ? WHERE id = ?",
            enabled, now, id)
        if not ok then return nil, err end
    end
    if roles ~= nil then
        local ok, err = db.exec("UPDATE users SET roles = ?, updated_at = ? WHERE id = ?", roles, now, id)
        if not ok then return nil, err end
    end
    return true
end

function _M.delete(id)
    return db.exec("DELETE FROM users WHERE id = ?", id)
end

function _M.update_password_by_id(id, hash, salt, now)
    return db.exec([[UPDATE users SET password_hash = ?, salt = ?, updated_at = ?
        WHERE id = ?]], hash, salt, now, id)
end

function _M.update_password(username, hash, salt, now)
    return db.exec([[UPDATE users SET password_hash = ?, salt = ?, updated_at = ?
        WHERE username = ?]], hash, salt, now, username)
end

function _M.record_login(username, now)
    return db.exec("UPDATE users SET last_login_at = ? WHERE username = ?", now, username)
end

return _M
