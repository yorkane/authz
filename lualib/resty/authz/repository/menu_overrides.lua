-- Menu overrides for runtime-injected service entries (domain bindings and
-- auto-discovered local ports). Those rows do not live in menu_entries, so
-- per-entry menu customisation (label/icon/order/visibility) is keyed by a
-- stable service key: "binding:<id>" or "port:<port>".
-- upsert/delete must run inside a transaction: reads there bypass mlcache.
local db = require "resty.authz.db"

local _M = {}

function _M.all()
    return db.query([[SELECT menu_key, label, icon, sort_order, enabled, updated_at
        FROM menu_overrides ORDER BY sort_order, menu_key]]) or {}
end

function _M.by_key(menu_key)
    local rows = db.query("SELECT * FROM menu_overrides WHERE menu_key = ?", menu_key)
    return rows and rows[1]
end

-- Columns this repository owns, in a fixed order; the service layer decides
-- which of them to send.
local COLUMNS = { "label", "icon", "sort_order", "enabled" }

function _M.upsert(menu_key, values, now)
    local sets, params = {}, {}
    for _, column in ipairs(COLUMNS) do
        local value = values[column]
        if value ~= nil then
            sets[#sets + 1] = column .. " = ?"
            params[#params + 1] = value
        end
    end
    if #sets == 0 then return true end
    sets[#sets + 1] = "updated_at = ?"
    params[#params + 1] = now
    if _M.by_key(menu_key) then
        params[#params + 1] = menu_key
        return db.exec("UPDATE menu_overrides SET " .. table.concat(sets, ", ")
            .. " WHERE menu_key = ?", unpack(params))
    end
    local cols, placeholders, insert_values = { "menu_key" }, { "?" }, { menu_key }
    local param_index = 0
    for _, column in ipairs(COLUMNS) do
        if values[column] ~= nil then
            param_index = param_index + 1
            cols[#cols + 1] = column
            placeholders[#placeholders + 1] = "?"
            insert_values[#insert_values + 1] = params[param_index]
        end
    end
    cols[#cols + 1] = "updated_at"
    placeholders[#placeholders + 1] = "?"
    insert_values[#insert_values + 1] = now
    return db.exec("INSERT INTO menu_overrides(" .. table.concat(cols, ", ")
        .. ") VALUES(" .. table.concat(placeholders, ", ") .. ")", unpack(insert_values))
end

function _M.delete(menu_key)
    return db.exec("DELETE FROM menu_overrides WHERE menu_key = ?", menu_key)
end

return _M
