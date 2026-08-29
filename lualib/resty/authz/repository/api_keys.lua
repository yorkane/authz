local db = require "resty.authz.db"

local _M = {}

local META = "id, name, role, loopback_only, enabled, created_at, updated_at"

function _M.by_id(id)
    local rows = db.query("SELECT " .. META .. " FROM api_keys WHERE id = ?", id)
    return rows and rows[1]
end

function _M.by_hash(token_hash)
    local rows = db.query([[SELECT id, name, role, loopback_only, created_at, updated_at FROM api_keys
        WHERE token_hash = ? AND enabled = 1]], token_hash)
    return rows and rows[1]
end

function _M.by_hash_metadata(token_hash)
    local rows = db.query("SELECT " .. META .. " FROM api_keys WHERE token_hash = ?", token_hash)
    return rows and rows[1]
end

function _M.list()
    return db.query("SELECT " .. META .. " FROM api_keys ORDER BY id") or {}
end

function _M.enabled_roles()
    return db.query("SELECT id, role FROM api_keys WHERE enabled = 1") or {}
end

function _M.name_exists(name, excluded_id)
    local rows
    if excluded_id then
        rows = db.query("SELECT id FROM api_keys WHERE name = ? AND id != ?", name, excluded_id)
    else
        rows = db.query("SELECT id FROM api_keys WHERE name = ?", name)
    end
    return rows and rows[1] ~= nil
end

function _M.insert(name, token_hash, role, now)
    return db.exec([[INSERT INTO api_keys(name, token_hash, role, loopback_only, enabled, created_at, updated_at)
        VALUES(?, ?, ?, 0, 1, ?, ?)]], name, token_hash, role, now, now)
end

function _M.update(id, fields, values)
    values[#values + 1] = id
    return db.exec("UPDATE api_keys SET " .. table.concat(fields, ", ") .. " WHERE id = ?",
        unpack(values))
end

function _M.delete(id)
    return db.exec("DELETE FROM api_keys WHERE id = ?", id)
end

return _M
