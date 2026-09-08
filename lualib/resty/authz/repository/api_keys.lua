local db = require "resty.authz.db"

local _M = {}

-- token_prefix 是指纹（明文密钥的前 11 字符，形如 ak_1a2b3c4d）：库里只存
-- SHA-256 摘要，明文不可回看，列表页靠指纹识别「这是哪一把」。
local META = "id, name, token_prefix, role, loopback_only, enabled, created_at, updated_at"

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

function _M.insert(name, token_hash, token_prefix, role, now)
    return db.exec([[INSERT INTO api_keys(name, token_hash, token_prefix, role, loopback_only, enabled, created_at, updated_at)
        VALUES(?, ?, ?, ?, 0, 1, ?, ?)]], name, token_hash, token_prefix, role, now, now)
end

-- 轮换：整对替换摘要与指纹（两者都只在新建/轮换那一刻存在过明文）。
function _M.rehash(id, token_hash, token_prefix, now)
    return db.exec("UPDATE api_keys SET token_hash = ?, token_prefix = ?, updated_at = ? WHERE id = ?",
        token_hash, token_prefix, now, id)
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
