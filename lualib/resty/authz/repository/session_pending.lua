-- resty.authz.repository.session_pending
-- 共享会话待写队列：Redis 不可达期间把"本该落到 Redis 的动作"记在本地，
-- 恢复后按 id 升序重放。只做 SQL，不做业务判断，也不开事务（同其它 repository）。
--
-- op 的全部合法取值（写入侧只有这三个）：
--   save        需要 SETEX 一份签名信封（token + csrf + expires_at）
--   delete      需要 DEL 单个 token
--   delete_all  需要 SCAN 后删掉该身份（username + source）的全部键
--
-- 为什么 save 有行数上限而 delete / delete_all 没有：丢掉一次"撤销"比放过
-- 一次"登录"危险得多。队列爆满时宁可让登录失败（运维看得见的 503），也不能
-- 悄悄丢撤销记录。上限判断在 session.lua 里做，这里只提供计数。
local db = require "resty.authz.db"

local _M = {}

--- 只读查询走 raw（直连 driver），共三种读法共用。
-- 为什么不能用 db.query 的 mlcache：重放定时器在**同一个 worker** 里
-- 「删已重放行 → 立刻读下一批」，缓存还没失效就会把刚删掉的行再读出来重放
-- 一遍。save 重放一遍无害（幂等 SETEX），但 delete 重放会把新登录刚写进 Redis
-- 的同名 token 再删一次 —— 表现为"登录后随机掉线"，比省下一次查询贵得多。
-- 队列只在共享会话降级期有量（常态为空），每次直接扫表代价可以忽略。
local function raw(sql, params)
    local rows, err = db.raw_query(sql, params)
    if not rows then
        ngx.log(ngx.WARN, "authz shared session: queue read failed: ", tostring(err))
        return {}
    end
    return rows
end

function _M.insert(op, token, username, source, csrf, expires_at, now)
    return db.exec([[INSERT INTO session_pending(op, token, username, source, csrf,
        expires_at, attempts, created_at) VALUES(?,?,?,?,?,?,0,?)]],
        op, tostring(token or ""), tostring(username or ""), tostring(source or ""),
        tostring(csrf or ""), tonumber(expires_at) or 0, tonumber(now) or os.time())
end

function _M.count()
    local rows = raw("SELECT COUNT(*) AS n FROM session_pending")
    return tonumber(rows[1] and rows[1].n) or 0
end

--- 队列里 save 类行数（签发类上限判断用；撤销类不计入，永不丢弃）。
function _M.count_save()
    local rows = raw("SELECT COUNT(*) AS n FROM session_pending WHERE op = ?", { "save" })
    return tonumber(rows[1] and rows[1].n) or 0
end

--- 未重放的 save 是否包含该 token。降级读用它区分"本机刚创建、还没同步出去"
--- 与"根本不存在"，否则 Redis 恢复的一瞬间会把这类会话当失效删掉。
function _M.has_save(token)
    if not token or token == "" then return false end
    local rows = raw(
        "SELECT 1 AS hit FROM session_pending WHERE op = ? AND token = ? LIMIT 1",
        { "save", token })
    return rows[1] ~= nil
end

--- 该 token 在"签发之后"是否已被撤销（队列里存在 id 更大的撤销行）。
-- 【为什么必须有这一半】降级读允许"本机有未重放的 save"就承认会话（否则 Redis
-- 刚恢复、重放还没跑的那几秒会把刚登录的人踢下线）。但如果撤销动作（op=delete /
-- delete_all）也还排在队列里，只判 save 存在就会让一个**已经撤销**的会话复活到
-- 重放完成为止 —— 撤销是安全动作，必须优先于"避免抖动"。按 id 比较即按发生顺序
-- 比较：撤销在签发之后 → 认定失效；撤销在签发之前（不可能是同一 token 的真撤销）
-- → 维持签发。
function _M.revoked_after_save(token, username, source)
    if not token or token == "" then return false end
    local rows = raw([[SELECT MAX(id) AS save_id FROM session_pending
        WHERE op = 'save' AND token = ?]], { token })
    local save_id = tonumber(rows[1] and rows[1].save_id)
    if not save_id then return false end
    local later = raw([[SELECT 1 AS hit FROM session_pending WHERE id > ?
        AND ((op = 'delete' AND token = ?)
          OR (op = 'delete_all' AND username = ? AND source = ?)) LIMIT 1]],
        { save_id, token, tostring(username or ""), tostring(source or "") })
    return later[1] ~= nil
end

--- 待重放行（按 id 升序 = 按发生顺序，保证 save 先于其后的 delete 重放）。
function _M.due(limit)
    return raw([[SELECT id, op, token, username, source, csrf, expires_at, attempts
        FROM session_pending ORDER BY id ASC LIMIT ?]],
        { tonumber(limit) or 200 })
end

--- 批量清理已重放行。调用方必须包在 db.transaction 里（一次 bump_revision）。
function _M.delete_ids(ids)
    if not ids or #ids == 0 then return true end
    local marks = {}
    local args = {}
    for i, id in ipairs(ids) do
        marks[i] = "?"
        args[#args + 1] = tonumber(id)
    end
    return db.exec("DELETE FROM session_pending WHERE id IN (" ..
        table.concat(marks, ",") .. ")", unpack(args))
end

--- 重放失败时累加尝试次数（只观测不丢弃：队列里的行被丢掉就等于永久不一致）。
function _M.bump_attempts(ids)
    if not ids or #ids == 0 then return true end
    local marks = {}
    local args = {}
    for i, id in ipairs(ids) do
        marks[i] = "?"
        args[#args + 1] = tonumber(id)
    end
    return db.exec("UPDATE session_pending SET attempts = attempts + 1 WHERE id IN (" ..
        table.concat(marks, ",") .. ")", unpack(args))
end

return _M
