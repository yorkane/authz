local db = require "resty.authz.db"

local _M = {}

local function first(rows)
    return rows and rows[1]
end

function _M.by_identity(provider, subject)
    return first(db.query([[SELECT provider, subject, username, roles, remote_roles,
        roles_overridden, enabled, synced_at, created_at, last_login_at, updated_at
        FROM remote_users WHERE provider = ? AND subject = ?]], provider, subject))
end

function _M.by_username(provider, username)
    return first(db.query([[SELECT subject, roles, enabled FROM remote_users
        WHERE provider = ? AND username = ?]], provider, username))
end

function _M.roles(provider, username)
    local row = first(db.query([[SELECT roles FROM remote_users
        WHERE provider = ? AND username = ? AND enabled = 1]], provider, username))
    return row and row.roles
end

function _M.timestamps(provider, username)
    return first(db.query([[SELECT created_at, last_login_at, updated_at FROM remote_users
        WHERE provider = ? AND username = ?]], provider, username))
end

function _M.exists_enabled(provider, username)
    return first(db.query([[SELECT subject FROM remote_users
        WHERE provider = ? AND username = ? AND enabled = 1]], provider, username)) ~= nil
end

function _M.list()
    return db.query([[SELECT provider, subject, username, roles, remote_roles,
        roles_overridden, enabled, synced_at, created_at, last_login_at, updated_at
        FROM remote_users ORDER BY username, provider]]) or {}
end

function _M.enabled_names()
    return db.query([[SELECT provider, username FROM remote_users
        WHERE enabled = 1 ORDER BY username, provider]]) or {}
end

function _M.enabled_roles()
    return db.query([[SELECT provider, username, roles FROM remote_users
        WHERE enabled = 1]]) or {}
end

function _M.update_fields(provider, subject, enabled, roles, overridden, now)
    if enabled ~= nil then
        local ok, err = db.exec([[UPDATE remote_users SET enabled = ?, updated_at = ?
            WHERE provider = ? AND subject = ?]], enabled, now, provider, subject)
        if not ok then return nil, err end
    end
    if roles ~= nil then
        local ok, err = db.exec([[UPDATE remote_users
            SET roles = ?, roles_overridden = ?, updated_at = ?
            WHERE provider = ? AND subject = ?]], roles, overridden, now, provider, subject)
        if not ok then return nil, err end
    end
    return true
end

function _M.delete(provider, subject)
    return db.exec("DELETE FROM remote_users WHERE provider = ? AND subject = ?", provider, subject)
end

function _M.save(provider, subject, username, roles_csv, now)
    local inserted, insert_err = db.exec([[INSERT OR IGNORE INTO remote_users
        (provider, subject, username, roles, remote_roles, roles_overridden, enabled, synced_at,
            created_at, last_login_at, updated_at)
        VALUES(?, ?, ?, ?, ?, 0, 1, ?, ?, ?, ?)]],
        provider, subject, username, roles_csv, roles_csv, now, now, now, now)
    if not inserted then return nil, "identity_insert_failed:" .. tostring(insert_err) end
    local updated, update_err = db.exec([[UPDATE remote_users SET username = ?, remote_roles = ?,
        roles = CASE WHEN roles_overridden = 1 THEN roles ELSE ? END,
        synced_at = ?, last_login_at = ?, updated_at = ?
        WHERE provider = ? AND subject = ?]],
        username, roles_csv, roles_csv, now, now, now, provider, subject)
    if not updated then return nil, "identity_update_failed:" .. tostring(update_err) end
    local saved = first(db.query([[SELECT username, roles, enabled FROM remote_users
        WHERE provider = ? AND subject = ?]], provider, subject))
    if not saved or saved.username ~= username then return nil, "identity_conflict" end
    return saved
end

return _M
