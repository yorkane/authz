-- 存储配置（多套 S3 服务）的管理接口：CRUD + 连通性测试 + 设为默认。
--
-- 分层：router → api/service.lua → 本文件（校验 + 事务）→ repository/s3_configs
-- 与 s3_config_store（裸 SQL / cfg 派生）。本文件不写 SQL、不签 S3 请求。
--
-- 凭证纪律（本仓库首例明文密钥入库，见 migrations v23 的说明）：
--   * 回显只走 repository 的 META 系查询（all/by_id：含 access_key_id 与 SQL 里
--     算出来的 has_secret，**不含 secret_access_key**），再叠加 mask_akid；
--   * 本文件绝不碰 *_full 查询，也不把 s3_config_store 的 cfg 表往外传
--     （cfg 带明文 secret，序列化即泄漏）——只摘 id/writable_roots/share_prefix/
--     endpoint_display 这类显示字段。
local db = require "resty.authz.db"
local cjson = require "cjson.safe"
local common = require "resty.authz.api.common"
local config_loader = require "resty.authz.config"
local s3 = require "resty.authz.s3"
local s3_scope = require "resty.authz.s3_scope"
local s3_config_store = require "resty.authz.s3_config_store"
local repository = require "resty.authz.repository.s3_configs"
local upload_records = require "resty.authz.repository.upload_records"
local validation = require "resty.authz.api.validation"

local _M = {}

-- 表单区间（与 admin/s3-configs.html 一致）。
local EXPIRES_HOURS_MIN, EXPIRES_HOURS_MAX = 0, 8760

local function flag(value)
    if value == true or value == 1 or value == "1" or value == "true" then return 1 end
    return 0
end

local function text(value)
    if value == nil or value == cjson.null then return "" end
    return tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
end

-- 「未提供 = 不修改」判定：前端编辑态只在字段非空时才把它塞进 payload，但也要
-- 容忍显式的空串与 JSON null（三者都按保持原值处理）。
local function provided(value)
    if value == nil or value == cjson.null then return false end
    return text(value) ~= ""
end

--- 三态布尔：字段给了就按它，没给用旧值（不能写成 `flag(x) == 1 or old`，
--- 那样显式 false 会被吞成旧值）。
local function pick_flag(field, old_value)
    if field == nil or field == cjson.null then return tonumber(old_value) or 0 end
    return flag(field)
end

--- 明文开关归一化：allow_http 只对 http endpoint 有意义（build_s3 也只在 scheme
--- 非 https 时读它 —— https + allow_http=false 同样合法）。
--- 若允许「https endpoint + allow_http=1」入库，页面的勾选框会因为
--- :disable="!isPlainHttp"（只看 endpoint）显示成「已勾选但改不动」，运维会以为
--- 明文被强制打开了、且关不掉。所以落库前压回 0，语义无损失。
--- （注意：env 那套的 allow_http **不会**继承到表行 —— s3_config_store.from_row
--- 只按行自身取值，所以表单默认值必须保持 false，不能替用户打开明文。）
local function normalize_allow_http(endpoint, value)
    if tostring(endpoint or ""):lower():sub(1, 8) == "https://" then return 0 end
    return value
end

local function norm_share_root(value)
    local root = text(value):gsub("^/+", ""):gsub("/+$", "")
    if root == "" then root = "share" end
    return root
end

--- 清掉全表的默认标记（表很小，逐行 UPDATE 足够，且只用 repository 原语 ——
--- 本层不写 SQL）。只在事务内调用。
local function clear_default_flag()
    for _, row in ipairs(repository.all()) do
        if tonumber(row.is_default) == 1 then
            local ok, err = repository.update(row.id, { "is_default = ?" }, { 0 })
            if not ok then return nil, err end
        end
    end
    return true
end

--- 派生缓存里的显示字段：id → {writable_roots, share_prefix, endpoint_display}。
--- 只为回显服务：只摘显示键，cfg 本身（含明文 secret）不出这个函数。
local function derived_map()
    local out = {}
    local ok, list = pcall(s3_config_store.list, { include_env = false })
    if not ok or type(list) ~= "table" then return out end
    for _, cfg in ipairs(list) do
        out[tostring(cfg.id)] = {
            writable_roots = cfg.writable_roots,
            share_prefix = cfg.share_prefix,
            endpoint_display = cfg.endpoint_display,
        }
    end
    return out
end

--- 行未显式给可写范围（或该行被禁用 → 不在派生缓存里）时，退化解析一次逻辑条目，
--- 只为让页面看见 share_root 这个逻辑根。默认条目要按本机 LAN IP 展开，那一步
--- 属于 s3_config_store 的职责，这里重复实现校验规则（s3_scope.parse 是纯函数）。
local function fallback_roots(row)
    local roots = select(2, s3_scope.parse(text(row.writable_paths), nil,
        norm_share_root(row.share_root), text(row.share_bucket)))
    return roots or {}
end

--- META 行 → 前端 cfg（**永不回显 secret**）。逐字段拷进新表：db.query 的返回是
--- 跨请求共享的 mlcache 缓存表，就地改字段会污染别的请求（事故见
--- api/services/applications.lua:15 的注释）。
local function view(row, derived)
    if not row then return nil end
    local extra = derived and derived[tostring(row.id)]
    local roots = extra and extra.writable_roots or fallback_roots(row)
    return {
        id = row.id,
        name = row.name,
        endpoint = (extra and extra.endpoint_display) or text(row.endpoint),
        region = row.region,
        allow_http = tonumber(row.allow_http) or 0,
        has_secret = tonumber(row.has_secret) or 0,
        access_key_id_masked = s3_config_store.mask_akid(row.access_key_id),
        writable_paths = text(row.writable_paths),
        share_root = norm_share_root(row.share_root),
        share_bucket = text(row.share_bucket),
        expires_hours = tonumber(row.expires_hours) or 0,
        use_bucket_lifecycle = tonumber(row.use_bucket_lifecycle) or 0,
        default_bucket = text(row.default_bucket),
        is_default = tonumber(row.is_default) or 0,
        enabled = tonumber(row.enabled) or 0,
        note = text(row.note),
        writable_roots = common.empty_array(roots),
        share_prefix = (extra and extra.share_prefix) or cjson.null,
        virtual = false,
        created_at = row.created_at,
        updated_at = row.updated_at,
    }
end

--- env 回落项的只读视图（id=0、virtual=true）。它的凭证来自环境变量，页面改不了，
--- 所以除「设为默认」（no-op 成功）外，编辑/删除一律 422 并说明「由环境变量提供」。
local function env_row()
    local cfg = s3_config_store.env_cfg()
    if not cfg then return nil end
    local runtime
    local ok, authz = pcall(require, "resty.authz")
    if ok and authz and authz.config then runtime = authz.config end
    return {
        id = 0,
        name = "env",
        endpoint = (runtime and runtime.s3_endpoint_display) or "",
        region = cfg.region,
        -- env 那套能不能用明文 http 由 AUTHZ_S3_ALLOW_HTTP 决定；cfg 里没留这个
        -- 位（build_s3 只校验不落字段），用 tls=false 反推等价语义回显。
        allow_http = cfg.tls and 0 or 1,
        has_secret = text(cfg.secret_access_key) ~= "" and 1 or 0,
        access_key_id_masked = s3_config_store.mask_akid(cfg.access_key_id),
        writable_paths = "",
        share_root = "share",
        share_bucket = text(cfg.share_bucket),
        expires_hours = 0,
        use_bucket_lifecycle = 0,
        default_bucket = "",
        is_default = 1,
        enabled = 1,
        note = "由环境变量提供（AUTHZ_S3_*），不可在此页面编辑",
        writable_roots = common.empty_array(cfg.writable_roots),
        share_prefix = cfg.share_prefix or cjson.null,
        virtual = true,
        created_at = 0,
        updated_at = 0,
    }
end

-- ── 读 ──────────────────────────────────────────────────────────────────────

--- 列表：库里全部行（含禁用）+ env 回落项（配了才给）。空表时 items 是
--- cjson.empty_array（前端按数组读，不能是 null）。
function _M.list()
    local derived = derived_map()
    local items = {}
    for _, row in ipairs(repository.all()) do
        items[#items + 1] = view(row, derived)
    end
    local env = env_row()
    if env then items[#items + 1] = env end
    return { items = common.empty_array(items) }
end

--- 给 GET /api/s3 用：全部可选配置摘要 + 默认 id（都不含凭证）。直接透传
--- s3_config_store.summary()，与前端下拉的单项形状同源。
function _M.summary()
    local ok, result = pcall(s3_config_store.summary)
    if not ok or type(result) ~= "table" then
        return { configs = common.empty_array({}), default_id = cjson.null }
    end
    result.configs = common.empty_array(result.configs)
    if result.default_id == nil then result.default_id = cjson.null end
    return result
end

--- 摘要单项（与 summary().configs 里的元素同形，**绝不含凭证**）：直接从运行时
--- cfg 表摘安全字段。给 GET /api/s3 回显「本次请求实际用的是哪一套配置」用 ——
--- 那里已经按 ref 选好了 cfg，再回头查摘要会在「点名的配置没进 summary 列表」
--- （例如纯 env 部署里点名 cfg=env，而 summary 只列表内行）时错报成 null。
--- cfg 是带明文 secret 的表，所以这里逐字段白名单拷贝，禁止整体外传。
function _M.summary_of(cfg)
    if type(cfg) ~= "table" then return nil end
    return {
        id = cfg.id,
        name = cfg.name,
        endpoint = cfg.endpoint_display or "",
        region = cfg.region,
        is_default = cfg.is_default and 1 or 0,
        enabled = 1,
        -- 与 summary().configs 的单项逐键同形（那边 virtual 是布尔）：前端
        -- isOn() 两种都认，但形状不一致会让「下拉对照」出现假差异。
        virtual = cfg.virtual == true,
        expires_hours = tonumber(cfg.expires_hours) or 0,
        use_bucket_lifecycle = cfg.use_bucket_lifecycle and 1 or 0,
        default_bucket = cfg.default_bucket or "",
    }
end

-- ── 校验并落库 ──────────────────────────────────────────────────────────────
--- endpoint / region / 凭证 / writable_paths 条目的校验**只走 config.build_s3**
--- （env 与表行共用的唯一入口），本层不重写任何正则。
--- merged 是「已合并旧值后的明文字段」；返回 (built, nil) 或 (nil, 原因)。
local function build_checked(merged)
    local fields = {
        endpoint = merged.endpoint,
        region = merged.region,
        access_key_id = merged.access_key_id,
        secret_access_key = merged.secret_access_key,
        allow_http = merged.allow_http == 1,
        writable_paths = merged.writable_paths,
        share_root = merged.share_root,
        share_bucket = merged.share_bucket,
        default_bucket = merged.default_bucket,
        -- 校验用 LAN IP 固定留空：可写范围条目的合法性与 IP 无关（默认条目
        -- share/<IP> 在 s3_config_store 派生时才展开），这里只需挡非法字符与桶名。
        lan_ip = "",
    }
    if fields.secret_access_key == "" then
        -- 更新时未重新填密钥：用哨兵满足 build_s3 的「凭证非空」判据。哨兵不含
        -- 空白与控制字符，校验结果与真实密钥一致（该校验只看字符集与空值），
        -- 且它**不会**被写进 fields 之外的任何地方。
        fields.secret_access_key = "unchanged"
    end
    local cfg, display = config_loader.build_s3(fields, { source = "row", strict = false })
    if not cfg then return nil, tostring(display or "字段非法") end
    return { cfg = cfg, display = display }
end

function _M.create(data)
    data = data or {}
    local name, err, status = validation.valid_s3_config_name(data.name)
    if not name then return nil, err, status end

    local expires_hours
    expires_hours, err, status = validation.valid_int_range(data.expires_hours,
        EXPIRES_HOURS_MIN, EXPIRES_HOURS_MAX, 0, "对象保留小时数")
    if expires_hours == nil then return nil, err, status end

    local share_bucket
    share_bucket, err, status = validation.valid_s3_bucket_field(data.share_bucket, "share_bucket")
    if share_bucket == nil then return nil, err, status end
    local default_bucket
    default_bucket, err, status = validation.valid_s3_bucket_field(data.default_bucket, "default_bucket")
    if default_bucket == nil then return nil, err, status end
    local note
    note, err, status = validation.valid_s3_note(data.note)
    if note == nil then return nil, err, status end
    local local_root
    local_root, err, status = validation.valid_local_root(data.local_root)
    if local_root == nil then return nil, err, status end

    -- 创建必须给全套凭证（build_s3 也会判空，这里先给中文消息）。
    local access_key_id = text(data.access_key_id)
    local secret_access_key = text(data.secret_access_key)
    if access_key_id == "" then return nil, "Access Key ID 不能为空", 422 end
    if secret_access_key == "" then return nil, "Secret Access Key 不能为空", 422 end

    local merged = {
        endpoint = text(data.endpoint),
        region = text(data.region),
        access_key_id = access_key_id,
        secret_access_key = secret_access_key,
        allow_http = normalize_allow_http(data.endpoint, flag(data.allow_http)),
        writable_paths = text(data.writable_paths),
        share_root = norm_share_root(data.share_root),
        share_bucket = share_bucket,
        default_bucket = default_bucket,
    }
    local built
    built, err = build_checked(merged)
    if not built then return nil, "配置非法：" .. tostring(err), 422 end

    local now = os.time()
    local values = {
        name = name,
        -- endpoint 存归一化后的回显形态（scheme://host[:port]，无尾斜杠）：与
        -- from_row / 页面回填同一写法，避免同一配置出现两种字符串。
        endpoint = built.display,
        region = built.cfg.region,
        allow_http = merged.allow_http,
        access_key_id = access_key_id,
        secret_access_key = secret_access_key,
        writable_paths = merged.writable_paths,
        share_root = merged.share_root,
        share_bucket = share_bucket,
        expires_hours = expires_hours,
        use_bucket_lifecycle = flag(data.use_bucket_lifecycle),
        default_bucket = default_bucket,
        local_root = local_root,
        is_default = flag(data.is_default),
        enabled = data.enabled == nil and 1 or flag(data.enabled),
        note = note,
        created_at = now,
        updated_at = now,
    }

    local created, transaction_err = db.transaction(function()
        if repository.name_exists(name) then return nil, "配置名称已存在: " .. name end
        -- 表里的第一行无条件成为默认项：否则全新部署没有 is_default=1 的行，
        -- 运行时靠「id 最小的启用行」兜底，页面却不显示默认标记，两边口径不一致。
        if not repository.default_row() then values.is_default = 1 end
        if values.is_default == 1 then
            local cleared, clear_err = clear_default_flag()
            if not cleared then return nil, clear_err end
        end
        return repository.insert_returning_id(values)
    end)
    if not created then
        if tostring(transaction_err or ""):find("已存在", 1, true) then
            return nil, transaction_err, 409
        end
        return common.db_error("创建存储配置失败", transaction_err)
    end
    s3_config_store.invalidate()
    return { item = view(repository.by_id(created), derived_map()) }, nil, 201
end

function _M.update(id, data)
    data = data or {}
    id = tonumber(id)
    if not id then return nil, "配置 id 非法", 422 end
    if id == 0 then return nil, "环境变量默认配置由环境变量提供，不能在此编辑", 422 end
    local existing = repository.by_id(id)
    if not existing then return nil, "存储配置不存在", 404 end

    local err, status
    local name = existing.name
    if provided(data.name) then
        name, err, status = validation.valid_s3_config_name(data.name)
        if not name then return nil, err, status end
    end

    local expires_hours = tonumber(existing.expires_hours) or 0
    if data.expires_hours ~= nil and data.expires_hours ~= cjson.null and data.expires_hours ~= "" then
        expires_hours, err, status = validation.valid_int_range(data.expires_hours,
            EXPIRES_HOURS_MIN, EXPIRES_HOURS_MAX, expires_hours, "对象保留小时数")
        if expires_hours == nil then return nil, err, status end
    end
    local share_bucket = text(existing.share_bucket)
    if data.share_bucket ~= nil and data.share_bucket ~= cjson.null then
        share_bucket, err, status = validation.valid_s3_bucket_field(data.share_bucket, "share_bucket")
        if share_bucket == nil then return nil, err, status end
    end
    local default_bucket = text(existing.default_bucket)
    if data.default_bucket ~= nil and data.default_bucket ~= cjson.null then
        default_bucket, err, status = validation.valid_s3_bucket_field(data.default_bucket, "default_bucket")
        if default_bucket == nil then return nil, err, status end
    end
    local note = text(existing.note)
    if data.note ~= nil and data.note ~= cjson.null then
        note, err, status = validation.valid_s3_note(data.note)
        if note == nil then return nil, err, status end
    end

    -- 凭证：空 = 不改。AKID 与 secret 各自独立（前端只在非空时发字段）。
    local access_key_id = text(existing.access_key_id)
    if provided(data.access_key_id) then access_key_id = text(data.access_key_id) end
    local secret_provided = provided(data.secret_access_key)
    local writable_paths = text(existing.writable_paths)
    if data.writable_paths ~= nil and data.writable_paths ~= cjson.null then
        writable_paths = text(data.writable_paths)
    end

    local merged = {
        endpoint = provided(data.endpoint) and text(data.endpoint) or text(existing.endpoint),
        region = provided(data.region) and text(data.region) or text(existing.region),
        access_key_id = access_key_id,
        secret_access_key = secret_provided and text(data.secret_access_key) or "",
        allow_http = normalize_allow_http(
            provided(data.endpoint) and data.endpoint or existing.endpoint,
            pick_flag(data.allow_http, existing.allow_http)),
        writable_paths = writable_paths,
        share_root = norm_share_root(provided(data.share_root)
            and data.share_root or existing.share_root),
        share_bucket = share_bucket,
        default_bucket = default_bucket,
    }
    local built
    built, err = build_checked(merged)
    if not built then return nil, "配置非法：" .. tostring(err), 422 end

    -- fields 与 values 一一对应（repository.update 直接把数组拼进 SET 子句）。
    local fields, values = {}, {}
    local function push(column, value)
        fields[#fields + 1] = column .. " = ?"
        values[#values + 1] = value
    end
    push("name", name)
    push("endpoint", built.display)
    push("region", built.cfg.region)
    push("allow_http", merged.allow_http)
    push("access_key_id", access_key_id)
    if secret_provided then push("secret_access_key", text(data.secret_access_key)) end
    push("writable_paths", merged.writable_paths)
    push("share_root", merged.share_root)
    push("share_bucket", share_bucket)
    push("expires_hours", expires_hours)
    push("use_bucket_lifecycle", pick_flag(data.use_bucket_lifecycle, existing.use_bucket_lifecycle))
    push("default_bucket", default_bucket)
    if provided(data.local_root) then
        local lr, lr_err = validation.valid_local_root(data.local_root)
        if lr == nil then return nil, lr_err, 422 end
        push("local_root", lr)
    end
    push("note", note)
    push("enabled", pick_flag(data.enabled, existing.enabled))
    push("updated_at", os.time())

    local want_default = data.is_default ~= nil and flag(data.is_default) == 1
    local updated, transaction_err = db.transaction(function()
        if name ~= existing.name and repository.name_exists(name, id) then
            return nil, "配置名称已存在: " .. name
        end
        if want_default then
            local cleared, clear_err = clear_default_flag()
            if not cleared then return nil, clear_err end
            push("is_default", 1)
        end
        return repository.update(id, fields, values)
    end)
    if not updated then
        if tostring(transaction_err or ""):find("已存在", 1, true) then
            return nil, transaction_err, 409
        end
        return common.db_error("更新存储配置失败", transaction_err)
    end
    s3_config_store.invalidate()
    return { item = view(repository.by_id(id), derived_map()) }
end

function _M.delete(id)
    id = tonumber(id)
    if not id then return nil, "配置 id 非法", 422 end
    if id == 0 then return nil, "环境变量默认配置由环境变量提供，不能在此删除", 422 end
    if not repository.by_id(id) then return nil, "存储配置不存在", 404 end

    local now = os.time()
    local removed, err = db.transaction(function()
        local ok, exec_err = repository.delete(id)
        if not ok then return nil, exec_err end
        -- 该配置下的活跃流水不能留成悬案（凭证已消失，清理器再也删不到对象）：
        -- 当场标 failed + 原因，记录本身保留（可审计），不静默删行。
        -- 批量置状态一条 UPDATE 做完（SQL 在 repository.mark_by_cfg，只影响
        -- kind='s3' 且 state='active' 的行）：以前是 SELECT 出 id 再逐行 mark，
        -- 同一事务里多 N 次往返，且查到写之间还有别人插行的窗口。
        local marked, mark_err = upload_records.mark_by_cfg(id, "failed", "config removed", now)
        if not marked then return nil, mark_err end
        return true
    end)
    if not removed then return common.db_error("删除存储配置失败", err) end
    s3_config_store.invalidate()
    return { deleted = true }
end

--- 设为默认：事务内先把全表置 0、再把目标置 1（避免出现两个默认项的中间态）。
--- id=0（env 虚拟项）是 no-op 成功：它本来就是「表里没有启用行时生效」那套。
function _M.set_default(id)
    id = tonumber(id)
    if not id then return nil, "配置 id 非法", 422 end
    if id == 0 then
        local env = env_row()
        if not env then return nil, "环境变量默认配置未启用", 423 end
        return { item = env }
    end
    if not repository.by_id(id) then return nil, "存储配置不存在", 404 end
    local ok, err = db.transaction(function()
        local cleared, clear_err = clear_default_flag()
        if not cleared then return nil, clear_err end
        return repository.update(id, { "is_default = ?", "updated_at = ?" }, { 1, os.time() })
    end)
    if not ok then return common.db_error("设为默认失败", err) end
    s3_config_store.invalidate()
    return { item = view(repository.by_id(id), derived_map()) }
end

--- 连通性测试：用这套配置列举桶。成功只回桶名数组，**不回显任何凭证**。
--- id=0 要显式走 env_cfg（真行 id 从 1 起，get(0) 取不到）。
function _M.test(id)
    id = tonumber(id)
    if not id then return nil, "配置 id 非法", 422 end
    local cfg
    if id == 0 then
        cfg = s3_config_store.env_cfg()
        if not cfg then return nil, "环境变量默认配置未启用", 423 end
    else
        local cfg_err, kind
        cfg, cfg_err, kind = s3_config_store.get(id)
        if not cfg then
            -- missing → 423（无此行/已禁用）；invalid → 502（行在但字段写坏）。
            if kind == "invalid" then return nil, cfg_err, 502 end
            return nil, cfg_err, 423
        end
    end
    local buckets, bucket_err, bucket_status = s3.list_buckets(cfg)
    if not buckets then
        return nil, tostring(bucket_err or "列举桶失败"), bucket_status or 502
    end
    local names = {}
    for _, bucket in ipairs(buckets) do names[#names + 1] = bucket.name end
    return { ok = true, buckets = common.empty_array(names) }
end

return _M
