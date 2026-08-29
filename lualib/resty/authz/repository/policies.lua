local db = require "resty.authz.db"

local _M = {}

function _M.enforcer_rows()
    return db.query("SELECT ptype, v0, v1, v2 FROM policies") or {}
end

function _M.list()
    return db.query("SELECT * FROM policies ORDER BY ptype, v0, id") or {}
end

function _M.exists(id)
    local rows = db.query("SELECT id FROM policies WHERE id = ?", id)
    return rows and rows[1] ~= nil
end

function _M.duplicate(ptype, v0, v1, v2, excluded_id)
    local rows
    if excluded_id then
        rows = db.query([[SELECT id FROM policies
            WHERE ptype = ? AND v0 = ? AND v1 = ? AND v2 = ? AND id != ?]],
            ptype, v0, v1, v2, excluded_id)
    else
        rows = db.query([[SELECT id FROM policies
            WHERE ptype = ? AND v0 = ? AND v1 = ? AND v2 = ?]], ptype, v0, v1, v2)
    end
    return rows and rows[1] ~= nil
end

function _M.insert(ptype, v0, v1, v2)
    return db.exec("INSERT OR IGNORE INTO policies(ptype, v0, v1, v2) VALUES(?,?,?,?)",
        ptype, v0, v1, v2)
end

function _M.update(id, ptype, v0, v1, v2)
    return db.exec("UPDATE policies SET ptype = ?, v0 = ?, v1 = ?, v2 = ? WHERE id = ?",
        ptype, v0, v1, v2, id)
end

function _M.delete(id)
    return db.exec("DELETE FROM policies WHERE id = ?", id)
end

function _M.delete_for_principal(principal)
    return db.exec("DELETE FROM policies WHERE v0 = ?", principal)
end

return _M
