local db = require "resty.authz.db"

local _M = {}

function _M.insert(token, username, source, csrf, expires_at)
    return db.exec([[INSERT INTO sessions(token, username, source, csrf, expires_at)
        VALUES(?,?,?,?,?)]], token, username, source, csrf, expires_at)
end

function _M.by_token(token)
    local rows = db.query([[SELECT username, source, csrf, expires_at FROM sessions
        WHERE token = ?]], token)
    return rows and rows[1]
end

function _M.delete(token)
    return db.exec("DELETE FROM sessions WHERE token = ?", token)
end

function _M.tokens_for(username, source)
    return db.query("SELECT token FROM sessions WHERE username = ? AND source = ?",
        username, source) or {}
end

function _M.delete_all_for(username, source)
    return db.exec("DELETE FROM sessions WHERE username = ? AND source = ?", username, source)
end

return _M
