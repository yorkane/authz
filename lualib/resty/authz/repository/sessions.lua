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

--- 写入/刷新本机镜像（共享会话的降级读来源，也是"最近经 Redis 确认存在"的凭据）。
-- INSERT OR REPLACE 会重置 verified_at：每次成功经 Redis 读到都算重新确认，
-- 降级宽限期因此从最后一次确认时刻起算。
function _M.upsert(token, username, source, csrf, expires_at)
    return db.exec([[INSERT OR REPLACE INTO sessions(token, username, source, csrf,
        expires_at, verified_at) VALUES(?,?,?,?,?,?)]],
        token, username, source, csrf, tonumber(expires_at) or 0, os.time())
end

--- 降级读资格查库（共享字典快路之外、跨 worker 重启的兜底）。
function _M.verified_recent(token, cutoff)
    if not token or token == "" then return nil end
    -- raw：降级读紧接着本会话的写（upsert），走缓存会读到滞后副本。
    local rows = db.raw_query([[SELECT username, source, csrf, expires_at FROM sessions
        WHERE token = ? AND verified_at IS NOT NULL AND verified_at >= ?]],
        { token, tonumber(cutoff) or 0 }) or {}
    return rows[1]
end

--- 待写队列按 op 分组计数（给 /_authz/api/session 与运维看）。
function _M.pending_group_counts()
    return db.raw_query("SELECT op, COUNT(*) AS n FROM session_pending GROUP BY op", {}) or {}
end

return _M
