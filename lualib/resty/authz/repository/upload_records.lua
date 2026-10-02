-- upload_records 表的数据访问层（上传流水账 + 过期清理队列）。
-- 形状照 repository/bindings.lua：只做 SQL，不做业务判断，也不开事务
-- （事务边界在 service 层：本模块的函数都可能在别人的事务里被调用）。
--
-- 同 s3_configs：db.query 返回跨请求共享的 mlcache 缓存表，本模块原样返回、
-- 绝不就地 mutate；清理器需要改字段时只用这里的 exec 系函数写库。
--
-- ── state 的全部合法取值（写入侧只有这四个，见 db/migrations.lua v24 与
--    api/services/uploads.lua 的记账入口）────────────────────────────────
--   active   待清理：对象仍在，expires_at 到点后由清理器删除。active 且
--            expires_at 为 NULL = 永不过期，不进清理队列。
--   deleted  已删成功的终态（清理器删除成功、admin 手工删除、rename 的源
--            key 闭账都写这个值）。
--   failed   删除报错，或配置行已被删（孤儿）：对象可能仍在，last_error 记
--            原因。同样是终态，清理器不再重试 —— 它是「要人工看一眼」的信号。
--   skipped  该配置勾了 use_bucket_lifecycle：只记账不删，回收交给桶生命周期
--            规则，所以它**不进** due() 队列；admin 手工删除照样能删。
--
-- 查询侧对未知取值的取舍：api/validation.lua 的 valid_upload_state 会放行
-- expired / pending_delete 两个库里永远不会出现的值（前端的下拉项）。本模块
-- 按值等值匹配、不在 SQL 层再校验一遍 —— 未知值自然匹配 0 行，页面显示空列表；
-- 若在这里报错，等于让一个纯过滤条件把列表接口打成 500，代价收益不对称。
-- 真正的拼写错误（state=xxx）仍由 validation 层按枚举拦下，不会漏到这里。
--
-- 空值口径（全模块唯一的判空真源 = filtered()）：state 为 nil 或空串都表示
-- 「不按状态过滤」。既往事故：count() 用 `if state then` 判空，而 Lua 里空串为
-- 真，于是前端选「全部」时 total 恒 0（recent() 自己判了空串，两条 SQL 口径
-- 不一致）。现在 count / count_filtered / recent / list_page 一律走 filtered()。
local db = require "resty.authz.db"

local _M = {}

--- 「要不要按 state 过滤」的唯一判据：nil 与空串都不过滤。
-- 空串是 valid_upload_state 把「全部」归一化后的产物（state="" 与 state="all"
-- 都返回空串），所以它是合法的「不过滤」输入，而不是一个状态值。
local function filtered(state)
    return state ~= nil and state ~= ""
end

-- 列表页与单条读取共用的列集合（不含任何凭证字段）。
local COLS = [[id, kind, cfg_id, bucket, key, size, source, created_by,
    created_at, expires_at, state, last_error, checked_at]]

function _M.insert(values)
    return db.exec([[INSERT INTO upload_records(
        kind, cfg_id, bucket, key, size, source, created_by, created_at,
        expires_at, state)
        VALUES(?,?,?,?,?,?,?,?,?,?)]],
        values.kind or "s3", values.cfg_id, values.bucket or "", values.key or "",
        values.size or 0, values.source or "api", values.created_by or "",
        values.created_at, values.expires_at, values.state or "active")
end

--- 到期队列：按 (cfg_id, bucket) 聚好、带行 id 列表，供清理器批量 DeleteObjects。
-- 单轮上限 limit 避免长事务（一小时最多处理这么多行，剩下的下一轮继续）。
-- 排序用 cfg_id/bucket 而非 expires_at：同一批要能拼进同一次 DeleteObjects。
function _M.due(now, limit)
    return db.query([[SELECT id, kind, cfg_id, bucket, key, expires_at FROM upload_records
        WHERE state = 'active' AND expires_at IS NOT NULL AND expires_at <= ?
        ORDER BY cfg_id, bucket, id LIMIT ?]], now, limit or 500) or {}
end

--- 按 (kind, cfg_id, bucket, key) 精确回填一条流水的状态。
-- cfg_id 为 NULL（env 回落配置）时不能写 cfg_id = NULL —— 那是恒不成立的比较，
-- 必须用 IS NULL，所以两条 SQL 分开。
function _M.mark(id, state, err, checked_at)
    local ok, exec_err = db.exec([[UPDATE upload_records SET state = ?, last_error = ?,
        checked_at = ? WHERE id = ?]], state, tostring(err or ""), checked_at, id)
    if not ok then return nil, exec_err end
    return true
end

--- 待清理队列里出现过的 cfg_id（去重用），供孤儿判定取反集。
function _M.due_cfg_ids(now, limit)
    return db.query([[SELECT DISTINCT cfg_id FROM upload_records
        WHERE state = 'active' AND expires_at IS NOT NULL AND expires_at <= ?
        LIMIT ?]], now, limit or 500) or {}
end

--- 孤儿记录：配置行已被删除（cfg_id 不在 s3_configs 里）且仍在 active 队列中。
-- 只查不改，写状态由 maintenance.cleanup 决定（保留 last_error 供审计）。
function _M.orphan_ids(now, limit)
    return db.query([[SELECT id FROM upload_records
        WHERE state = 'active' AND expires_at IS NOT NULL AND expires_at <= ?
        AND cfg_id IS NOT NULL AND cfg_id NOT IN (SELECT id FROM s3_configs)
        LIMIT ?]], now, limit or 500) or {}
end

--- 统计（给管理接口/清理器返回用）。state 传 nil 统计全部。
function _M.count(state)
    -- 判空走 filtered()：以前这里是 `if state then`，空串在 Lua 里为真，于是
    -- 「全部」会被拼成 WHERE state = ''，total 恒 0。
    return _M.count_filtered(state)
end

--- 带过滤的总数。state 为 nil / 空串 = 统计全表（与 list_page 的过滤口径同源，
--- 前端「加载更多」要靠它算总页数，两边必须一致）。
function _M.count_filtered(state)
    local rows
    if filtered(state) then
        rows = db.query("SELECT COUNT(*) AS c FROM upload_records WHERE state = ?", state)
    else
        rows = db.query("SELECT COUNT(*) AS c FROM upload_records")
    end
    return rows and rows[1] and tonumber(rows[1].c) or 0
end

--- 列表页：最近的流水（按 id 倒序，含 key/bucket，不含任何凭证）。
--- 翻页交给 list_page（SQL 里直接 OFFSET），这里保留为「取最近 N 条」的便捷别名。
function _M.recent(limit, state)
    -- 保持本函数改动前的契约：查询失败也返回空表（不把 (nil, err) 漏给老调用方）。
    -- 需要区分「没记录」与「查库挂了」请直接用 list_page。
    return _M.list_page(state, limit or 100, 0) or {}
end

--- 分页列表：按 id 倒序（新记录在前），offset 在 SQL 里做。
-- 为什么必须由 SQL 翻页：service 层以前是「多取 offset+limit 行再切掉前
-- offset 行」，代价 O(offset+limit)，所以只能把扫描量硬封顶在 MAX_SCAN 行，
-- 深翻页会返回空列表。改成 OFFSET 之后 service 不再需要那个封顶。
-- 返回共享缓存表（只读，调用方逐字段拷贝后再用）；查询失败返回 (nil, 原因)。
function _M.list_page(state, limit, offset)
    local sql = "SELECT " .. COLS .. " FROM upload_records"
    local args = {}
    if filtered(state) then
        sql = sql .. " WHERE state = ?"
        args[#args + 1] = state
    end
    sql = sql .. " ORDER BY id DESC LIMIT ?"
    args[#args + 1] = tonumber(limit) or 100
    -- offset 只在正数时拼进 SQL：LIMIT ? OFFSET 0 与不写 OFFSET 等价，但少一种
    -- SQL 文本就少一个 mlcache 键，也方便直查 sqlite 复核。
    local skip = tonumber(offset) or 0
    if skip > 0 then
        sql = sql .. " OFFSET ?"
        args[#args + 1] = skip
    end
    local rows, err = db.query(sql, unpack(args))
    if not rows then return nil, err or "读取上传记录失败" end
    return rows
end

--- 按 (kind='s3', cfg_id, bucket, key) 定位仍在 active 队列里的流水 id。
-- 删除对象成功后用它找要闭账的行：
--   * cfg_id 为 nil（当年用的是 env 回落配置）必须写 cfg_id IS NULL —— 与 NULL
--     做等值比较恒不成立，一条都匹配不到；
--   * recursive=true 按前缀匹配整棵子树（key = X 或 X/...）；
--   * recursive=false 也接受 X/ 这一层「目录」本身（S3 没有真目录，0 字节占位
--     对象的 key 就是带斜杠的形态）。
-- LIKE 一律带 ESCAPE（转义见 escape_like）：key 里的 % / _ 是合法字符，不转义就
-- 会被当通配符 —— 删 a% 时连 aXb 的 active 行一起闭账，那些文件从此不进清理队列。
-- 单批上限 500 与清理器同量级：一次目录删除匹配到上万行时，宁可少闭几笔账
-- （下一轮清理仍会扫到）也不要让一个 DELETE 请求打满时间片。

--- LIKE 模式里的字面量转义（SQLite：LIKE 'x' ESCAPE '\'，默认无 escape 字符）。
-- 不做转义的后果（安全审查 P2）：key 里的 % 会被当通配符，删 a% 会连带把 aXb
-- 之类无关 key 的 active 行标成 deleted，清理器从此再也不会回收那些文件（磁盘
-- 只增不减，TTL 承诺失效）。转义集就是 LIKE 的两个元字符加上 escape 字符本身。
function _M.escape_like(text)
    if type(text) ~= "string" then return nil end
    return (text:gsub("([%%_\\])", "\\%1"))
end

function _M.ids_by_key(cfg_id, bucket, key, recursive)
    local sql = [[SELECT id FROM upload_records WHERE kind = 's3' AND state = 'active']]
    local args = {}
    if cfg_id == nil then
        sql = sql .. [[ AND cfg_id IS NULL]]
    else
        sql = sql .. [[ AND cfg_id = ?]]
        args[#args + 1] = cfg_id
    end
    sql = sql .. [[ AND bucket = ?]]
    args[#args + 1] = bucket or ""
    if recursive then
        sql = sql .. [[ AND (key = ? OR key LIKE ? ESCAPE '\')]]
        args[#args + 1] = key
        args[#args + 1] = _M.escape_like(key or "") .. "/%"
    else
        sql = sql .. [[ AND (key = ? OR key = ? OR key LIKE ? ESCAPE '\')]]
        args[#args + 1] = key
        args[#args + 1] = (key or "") .. "/"
        args[#args + 1] = _M.escape_like(key or "") .. "/%"
    end
    local rows, err = db.query(sql .. " LIMIT 500", unpack(args))
    if not rows then return nil, err or "读取上传记录失败" end
    local ids = {}
    for _, row in ipairs(rows) do ids[#ids + 1] = tonumber(row.id) end
    return ids
end

--- 某配置（cfg_id）下所有仍在 active 队列的 s3 流水整批改状态。
-- 用途：删除配置行时把这些行标 failed + 原因（凭证没了，清理器再也删不到对象，
-- 必须留下可见的痕迹）。WHERE 里带 state = 'active'：已经是 deleted / failed /
-- skipped 的行不受影响，重复调用也幂等。
-- 一条 UPDATE 做完，不再「SELECT 出 id 再逐行 mark」：同一事务里少 N 次往返，
-- 也少一个「查到一半别人插了新行」的窗口。checked_at 由调用方给（缺省 NULL，
-- 与 mark() 一致）。不开事务 —— 事务边界在 service 层。
function _M.mark_by_cfg(cfg_id, state, err, checked_at)
    local id = tonumber(cfg_id)
    if not id then return nil, "配置 id 非法" end
    return db.exec([[UPDATE upload_records SET state = ?, last_error = ?,
        checked_at = ? WHERE kind = 's3' AND state = 'active' AND cfg_id = ?]],
        state, tostring(err or ""), checked_at, id)
end

--- 单条读取（不含任何凭证）。返回共享缓存表的一行，只读；要改字段或长期持有
--- 请逐字段拷贝（既往事故见 api/services/applications.lua:15）。
--- 区分「查库失败」与「没有这行」：前者返回 (nil, 原因)，后者返回 (nil)。
function _M.by_id(id)
    local rows, err = db.query("SELECT " .. COLS .. " FROM upload_records WHERE id = ?", id)
    if not rows then return nil, err or "读取上传记录失败" end
    return rows[1]
end

--- 手工清理到期项之外的兜底：把某配置下仍在 active 的记录整批改期（延长 TTL）。
-- 保留给第二阶段的管理接口用；这里只提供原语，不做权限判断。
function _M.extend_expiry(ids, expires_at)
    if type(ids) ~= "table" or #ids == 0 then return nil, "没有要改期的记录", 400 end
    local marks = {}
    local args = { expires_at }
    for index, id in ipairs(ids) do
        if index > 500 then break end
        marks[#marks + 1] = "?"
        args[#args + 1] = id
    end
    return db.exec("UPDATE upload_records SET expires_at = ? WHERE id IN (" ..
        table.concat(marks, ",") .. ")", unpack(args))
end

--- 本机保存区（kind='local'）在某 key 上仍在 active 队列的流水 id。
-- 与 ids_by_key 同一套 LIKE 转义口径（escape_like + ESCAPE '\'），差别只有
-- kind='local' 且不比较 bucket（本地行的 bucket 恒为 ''）。
function _M.local_ids_by_key(key, recursive)
    local sql = [[SELECT id FROM upload_records WHERE kind = 'local' AND state = 'active']]
    local args
    if recursive then
        sql = sql .. [[ AND (key = ? OR key LIKE ? ESCAPE '\')]]
        args = { key, _M.escape_like(key or "") .. "/%" }
    else
        sql = sql .. [[ AND key = ?]]
        args = { key }
    end
    local rows, err = db.query(sql .. " LIMIT 500", unpack(args))
    if not rows then return nil, err or "读取上传记录失败" end
    local ids = {}
    for _, row in ipairs(rows) do ids[#ids + 1] = tonumber(row.id) end
    return ids
end

--- 某目录（含子树）下仍在 active 队列的本地流水，按 id 倒序，供列表/stat 补
-- expires_at。同样走 escape_like：dir 里含 % 时不能把无关 key 的到期时间贴过来。
function _M.local_expiry_rows(dir, limit)
    -- 等值参数用 dir 本身（dir 为 "" 时匹配根级流水）；LIKE 侧补一个斜杠再通配，
    -- 转义后拼 "%"：dir 里自带的 % / _ 必须是字面量，否则会把无关 key 的到期时间贴过来。
    local prefix = (dir == "" and "" or dir .. "/")
    local rows, err = db.query([[SELECT key, expires_at, created_at FROM upload_records
        WHERE kind = 'local' AND state = 'active' AND (key = ? OR key LIKE ? ESCAPE '\')
        ORDER BY id DESC LIMIT ?]], dir, _M.escape_like(prefix) .. "%", limit)
    if not rows then return nil, err or "读取上传记录失败" end
    return rows
end

return _M
