local db = require "resty.authz.db"

local _M = {}

function _M.list()
    return db.query([[SELECT id, kind, parent_id, label, url, icon, builtin,
        admin_only, sort_order, enabled, created_at, updated_at
        FROM menu_entries ORDER BY sort_order, id]]) or {}
end

function _M.by_id(id)
    local rows = db.query("SELECT * FROM menu_entries WHERE id = ?", id)
    return rows and rows[1]
end

function _M.insert(values)
    return db.exec([[INSERT INTO menu_entries(
        kind, parent_id, label, url, icon, builtin, admin_only,
        sort_order, enabled, created_at, updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?)]],
        values.kind or 'item', values.parent_id, values.label, values.url,
        values.icon or '', values.builtin or '', values.admin_only or 0,
        values.sort_order, values.enabled, values.created_at, values.updated_at)
end

function _M.update(id, fields, values)
    values[#values + 1] = id
    return db.exec("UPDATE menu_entries SET " .. table.concat(fields, ", ") .. " WHERE id = ?",
        unpack(values))
end

function _M.delete(id)
    return db.exec("DELETE FROM menu_entries WHERE id = ?", id)
end

return _M
