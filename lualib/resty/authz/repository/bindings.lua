local db = require "resty.authz.db"

local _M = {}

function _M.list()
    return db.query("SELECT * FROM bindings ORDER BY domain") or {}
end

function _M.enabled_applications()
    return db.query([[SELECT id, domain, target_ip, port, note, menu_name, websocket,
        upstream_host, forwarded_host, forwarded_proto, forwarded_port, origin_mode,
        custom_origin, simulate_local, local_ip, upstream_scheme, upstream_ssl_verify,
        upstream_path FROM bindings WHERE enabled = 1 ORDER BY domain]]) or {}
end

function _M.runtime_rows()
    return db.query([[SELECT domain, target_ip, port, enabled, websocket,
        upstream_host, forwarded_host, forwarded_proto, forwarded_port, origin_mode,
        custom_origin, simulate_local, local_ip, upstream_scheme, upstream_ssl_verify,
        upstream_path, header_overrides FROM bindings]]) or {}
end

function _M.by_id(id)
    local rows = db.query("SELECT * FROM bindings WHERE id = ?", id)
    return rows and rows[1]
end

function _M.id_port(id)
    local rows = db.query("SELECT id, port FROM bindings WHERE id = ?", id)
    return rows and rows[1]
end

function _M.domain_exists(domain, excluded_id)
    local rows
    if excluded_id then
        rows = db.query("SELECT id FROM bindings WHERE domain = ? AND id != ?", domain, excluded_id)
    else
        rows = db.query("SELECT id FROM bindings WHERE domain = ?", domain)
    end
    return rows and rows[1] ~= nil
end

function _M.insert(values)
    return db.exec([[INSERT INTO bindings(
        domain, target_ip, port, enabled, websocket, note, menu_name,
        upstream_host, forwarded_host, forwarded_proto, forwarded_port,
        origin_mode, custom_origin, simulate_local, local_ip,
        upstream_scheme, upstream_ssl_verify, upstream_path, header_overrides, created_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)]],
        values.domain, values.target_ip, values.port, values.enabled, values.websocket,
        values.note, values.menu_name, values.upstream_host, values.forwarded_host,
        values.forwarded_proto, values.forwarded_port, values.origin_mode,
        values.custom_origin, values.simulate_local, values.local_ip,
        values.upstream_scheme, values.upstream_ssl_verify, values.upstream_path,
        values.header_overrides,
        values.created_at)
end

function _M.update(id, fields, values)
    values[#values + 1] = id
    return db.exec("UPDATE bindings SET " .. table.concat(fields, ", ") .. " WHERE id = ?",
        unpack(values))
end

function _M.delete(id)
    return db.exec("DELETE FROM bindings WHERE id = ?", id)
end

return _M
