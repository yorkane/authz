-- s3_configs 表的数据访问层（多套 S3 服务配置）。
--
-- 形状照 repository/bindings.lua：只做 SQL，不做业务校验，不 require 上层模块。
-- 运行时消费方是 s3_config_store（把行变成 cfg），管理接口（第二阶段）走这里。
--
-- 注意 db.query 返回的是**跨请求共享的 mlcache 缓存表**：本模块一律原样返回，
-- 绝不在这里就地增删字段（既往事故见 api/services/applications.lua:15 的注释）。
-- 需要改字段的调用方（s3_config_store）自己拷贝。
local db = require "resty.authz.db"

local _M = {}

-- META 故意不含 secret_access_key：列表/回显路径永远拿不到明文。密钥只在显式命名
-- 为 *_full / enabled_rows 的三条路子里（消费者：s3_config_store 派生 cfg 需要
-- 原文参与 SigV4 签名）。管理接口/前端回显一律走 META 系（配 mask_akid + has_secret）。
-- 末列 has_secret 是**算出来的布尔**（明文 secret 不进结果集）：管理页要显示
-- 「已配置密钥 / 未配置」，但绝不允许把密钥原文取到接口层，所以判空这一步下沉到 SQL。
local SECRET_FLAG = [[CASE WHEN secret_access_key = '' THEN 0 ELSE 1 END AS has_secret]]
local META = [[id, name, endpoint, region, allow_http, access_key_id, writable_paths,
    share_root, share_bucket, expires_hours, use_bucket_lifecycle,
    default_bucket, local_root, is_default, enabled, note, created_at, updated_at,
    ]] .. SECRET_FLAG

local FULL = META .. ", secret_access_key"

--- 全部配置行（含禁用），按 id 升序。**不含明文 secret**：这是管理页/回显的正路。
--- 返回共享缓存表，只读。
function _M.all()
    return db.query("SELECT " .. META .. " FROM s3_configs ORDER BY id") or {}
end

--- 启用中的配置行，按 id 升序（「表内 id 最小的 enabled 行」是默认项兜底判据）。
--- 【含明文 secret】唯一合法消费者是 s3_config_store.build_map（要拿原文签 SigV4）；
--- 管理/前端接口请改用 all() 或 options()，绝不把这里的行直接序列化出去。
function _M.enabled_rows()
    return db.query("SELECT " .. FULL .. " FROM s3_configs WHERE enabled = 1 ORDER BY id") or {}
end

--- 安全读取（不含 secret）：管理接口按 id/name 回显单行用这两个。
function _M.by_id(id)
    local rows = db.query("SELECT " .. META .. " FROM s3_configs WHERE id = ?", id)
    return rows and rows[1]
end

function _M.by_name(name)
    local rows = db.query("SELECT " .. META .. " FROM s3_configs WHERE name = ?", name)
    return rows and rows[1]
end

--- 显式命名的「含明文密钥」读取：只有确实要签名/派生 cfg 时才准用，
--- 严禁把结果直接序列化给前端。
function _M.by_id_full(id)
    local rows = db.query("SELECT " .. FULL .. " FROM s3_configs WHERE id = ?", id)
    return rows and rows[1]
end

function _M.by_name_full(name)
    local rows = db.query("SELECT " .. FULL .. " FROM s3_configs WHERE name = ?", name)
    return rows and rows[1]
end

--- 显式默认行（is_default=1 且 enabled=1）。**不含 secret**（回显/概览用）。
function _M.default_row()
    local rows = db.query([[SELECT ]] .. META .. [[ FROM s3_configs
        WHERE enabled = 1 AND is_default = 1 ORDER BY id LIMIT 1]])
    return rows and rows[1]
end

--- 需要原文密钥才能签名的消费者用这一条（命名里带 _full 是刻意的提醒）。
function _M.default_row_full()
    local rows = db.query([[SELECT ]] .. FULL .. [[ FROM s3_configs
        WHERE enabled = 1 AND is_default = 1 ORDER BY id LIMIT 1]])
    return rows and rows[1]
end

--- 表里存在过的 id 集合（含禁用行）：清理器用它区分「配置被禁用」与「配置被删除」。
function _M.known_ids()
    return db.query("SELECT id FROM s3_configs") or {}
end

function _M.name_exists(name, excluded_id)
    local rows
    if excluded_id then
        rows = db.query("SELECT id FROM s3_configs WHERE name = ? AND id != ?", name, excluded_id)
    else
        rows = db.query("SELECT id FROM s3_configs WHERE name = ?", name)
    end
    return rows and rows[1] ~= nil
end

--- 只回 id/name 的清单（给 summary 之外的轻量下拉用，绝不含密钥）。
--- 需要 access_key_id 掩码 / has_secret 时请从 all()（META）取，再调
--- s3_config_store.mask_akid；不要在这里加 secret 列。
function _M.options()
    return db.query([[SELECT id, name, endpoint, is_default, enabled, expires_hours,
        use_bucket_lifecycle, default_bucket FROM s3_configs ORDER BY id]]) or {}
end

function _M.insert(values)
    return db.exec([[INSERT INTO s3_configs(
        name, endpoint, region, allow_http, access_key_id, secret_access_key,
        writable_paths, share_root, share_bucket, expires_hours,
        use_bucket_lifecycle, default_bucket, local_root, is_default, enabled,
        note, created_at, updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)]],
        values.name, values.endpoint, values.region, values.allow_http,
        values.access_key_id, values.secret_access_key, values.writable_paths,
        values.share_root, values.share_bucket, values.expires_hours,
        values.use_bucket_lifecycle, values.default_bucket, values.local_root or "",
        values.is_default, values.enabled, values.note, values.created_at,
        values.updated_at)
end

--- 插入并回自增 id。
-- 为什么必须包在事务里：db.query 走 mlcache，键只由「SQL 文本 + 参数 + db_rev」
-- 决定，裸查 last_insert_rowid() 会被缓存成上一条插入的 id（同一条 SQL 文本、
-- 同一次 revision）。db.query 在事务内直接走 raw_query（db.lua:47），既绕过缓存
-- 又保证与 INSERT 是同一个连接。
function _M.insert_returning_id(values)
    return db.transaction(function()
        local ok, err = _M.insert(values)
        if not ok then return nil, err end
        local rows = db.query("SELECT last_insert_rowid() AS id")
        local id = rows and rows[1] and tonumber(rows[1].id)
        if not id then return nil, "读取新配置 id 失败" end
        return id
    end)
end

function _M.update(id, fields, values)
    values[#values + 1] = id
    return db.exec("UPDATE s3_configs SET " .. table.concat(fields, ", ") .. " WHERE id = ?",
        unpack(values))
end

function _M.delete(id)
    return db.exec("DELETE FROM s3_configs WHERE id = ?", id)
end

return _M
