-- S3 多配置的运行时枢纽：把「一行 s3_configs 记录」或「环境变量默认项」统一
-- 变成与既有 config.s3 **同构**的 cfg 表，供 s3.lua / s3_proxy.lua / 清理器消费。
--
-- 为什么存在：对象存储浏览原本只有一套凭证（AUTHZ_S3_*，进程级常量）。现在页面可以
-- 维护多套 S3 服务，运行时要按请求选一套，同时**不能**破坏老部署 —— 表里没有启用
-- 行时继续用 env 那套。于是所有「取 cfg」的入口收敛到这里。
--
-- 与 config.lua 的关键区别（务必看清）：
--   * env 路径是**启动期 fail-fast**：字段非法就 error()，容器起不来（配置写坏不许
--     带病上线）。
--   * 行路径是**运行期可失败**：字段非法返回 (nil, 原因)，绝不 error()。一行被写坏
--     （比如运维填了个非法桶名）只能让「这一个配置」不可用，不能拖垮整个网关，
--     更不能让 worker 起不来。调用方拿到 nil 时按 423/502 处理并显示原因。
--   两条路径共用 config.build_s3 做校验与派生，规则只有一份。
--
-- 缓存策略（「改表即生效」）：
--   * 行数据本身走 db.query（mlcache，跨 worker，TTL 默认 30s）。
--   * 派生结果（endpoint 解析 + s3_scope.parse）是纯计算产物，缓存在 **worker-local
--     表**里，键 `id|name`，值带建表时的 revision。
--   * 每次取用前先比 `ngx.shared.authz_cache:get("db_rev")`（任何写库都会 bump，见
--     db/query_cache.lua:62），不一致就整表作废重建。所以最坏是 mlcache 的 30s TTL，
--     通常写完下一个请求就生效。
--   * 返回给调用方的 cfg 一律是**新建表**：db.query 的返回是跨请求共享的缓存表，
--     就地 mutate 会污染别的请求（既往事故见 api/services/applications.lua:15）。
local config = require "resty.authz.config"
local s3_scope = require "resty.authz.s3_scope"
local s3_configs = require "resty.authz.repository.s3_configs"

local _M = {}

local HOUR = 3600

-- 运行时配置（env 回落项）挂在 resty.authz 的门面表上（init.lua 的 _M.config），
-- 不是 config 模块自己的字段，所以要 lazy require —— 与 router.lua:272 同一手法。
-- 用 pcall 包住：单测/脚本里直接 require 本模块时没有 ngx 生命周期也能用。
local function runtime_config()
    local ok, authz = pcall(require, "resty.authz")
    if ok and authz and authz.config then return authz.config end
    return nil
end

-- ── worker-local 派生缓存 ───────────────────────────────────────────────────
local derived = nil          -- { ["<id>|<name>"] = cfg }
local derived_rev = nil      -- 建表时的 db_rev
local lan_ip_cache           -- 探测结果（false = 探测失败，避免每请求重试）

local function revision()
    local ok, value = pcall(function()
        local dict = ngx.shared.authz_cache
        if not dict then return nil end
        return dict:get("db_rev")
    end)
    if not ok then return nil end
    if value == nil then return nil end
    return tonumber(value) or 0
end

-- LAN IP 只在需要默认 share/<IP> 条目时才探测（探测失败缓存 false，不再重试到坏掉）。
local function detect_lan_ip()
    if lan_ip_cache == nil then
        local override = config.s3_env_fields().lan_ip or ""
        if override ~= "" then
            lan_ip_cache = override
        else
            local ok, ip = pcall(s3_scope.detect_lan_ip)
            lan_ip_cache = (ok and ip) or false
        end
    end
    return lan_ip_cache or nil
end

--- AKID 掩码：只保留前 4 位。AKID 本身算半机密（配 secret 才能用），
--- 管理页面只要能分辨「是哪一把」即可。
function _M.mask_akid(akid)
    local text = tostring(akid or "")
    if text == "" then return "" end
    if #text <= 4 then return string.rep("*", #text) end
    return text:sub(1, 4) .. string.rep("*", math.min(12, #text - 4))
end

--- 整点对齐的过期时间戳：清理器每小时跑一次，只有对齐到整点才能保证
-- 「同一小时上传的东西同一小时被删」，也不会让 expires_at 索引区间扫退化成
-- 一堆毫秒级散布的边界行。hours<=0 表示永不过期（返回 nil）。
function _M.align_expiry(now, hours)
    local n = tonumber(hours) or 0
    if n <= 0 then return nil end
    local base = math.floor((tonumber(now) or 0) / HOUR) * HOUR
    return base + n * HOUR
end

-- ── 构造 ────────────────────────────────────────────────────────────────────
--- env 回落项（= 现有 config.s3，可能是 nil）。返回的是共享的 config 表本身，
--- 只读；需要持有或改写请走 _M.get()。
function _M.env_cfg()
    local c = runtime_config()
    return c and c.s3
end

--- 一行 s3_configs → cfg。字段非法时返回 (nil, 原因)，**不 error()**。
--- row 必须是含 secret_access_key 的完整行（repository.s3_configs 的 FULL 查询）。
--- 除既有 cfg 字段外再带上本方案新增的：
---   id / name / is_default / expires_hours / use_bucket_lifecycle / default_bucket
---   endpoint_display（回显用，派生自 endpoint）
function _M.from_row(row)
    if type(row) ~= "table" then return nil, "配置记录不存在" end
    local env = config.s3_env_fields()
    local lan_ip = ""
    local writable_paths = tostring(row.writable_paths or "")
    if writable_paths == "" then
        -- 行内未显式给可写范围 → 用默认条目 share/<本机 LAN IP>。探测失败时退化成
        -- 只读（s3_scope.parse 拿 nil ip 返回空条目），并告警说明原因。
        lan_ip = detect_lan_ip() or ""
        if lan_ip == "" then
            ngx.log(ngx.WARN, "authz: s3 config ", tostring(row.name or row.id),
                " cannot detect LAN IP; default share/<LAN IP> prefix unavailable," ..
                " this config is read-only")
        end
    end
    local cfg, display = config.build_s3({
        endpoint = row.endpoint,
        -- region 留空时回落 env 的 region（列有 DEFAULT 'us-east-1'，正常不会空）。
        region = tostring(row.region or "") ~= "" and tostring(row.region) or env.region,
        access_key_id = row.access_key_id,
        secret_access_key = row.secret_access_key,
        -- allow_http 只按行自身取值，**不**从 env 继承：它是「明文 http 是否可信」
        -- 的安全开关，若被 env 隐式打开，就等于「env 恰好用了 http endpoint」时页面
        -- 新增的任意一套配置都自动允许明文（且页面上取消勾选也不生效）。
        -- 后果：在 http 部署里新增 http 配置必须显式勾选 allow_http，否则该配置报
        -- 错不可用 —— 这是刻意的显式确认。二阶段若做「把 env 导入成表行」，必须
        -- 连同 allow_http=1 一起写进去。
        allow_http = tonumber(row.allow_http) == 1,
        writable_paths = writable_paths,
        share_root = row.share_root,
        share_bucket = row.share_bucket,
        default_bucket = row.default_bucket,
        read_timeout_ms = env.read_timeout_ms,
        connect_timeout_ms = env.connect_timeout_ms,
        send_timeout_ms = env.send_timeout_ms,
        keepalive_ms = env.keepalive_ms,
        lan_ip = lan_ip,
    }, {
        source = "row",
        strict = false,
        prefix = "存储配置 " .. tostring(row.name or row.id) .. ": ",
    })
    if not cfg then return nil, display or "配置字段非法" end
    cfg.id = tonumber(row.id)
    cfg.name = tostring(row.name or "")
    cfg.is_default = tonumber(row.is_default) == 1
    cfg.endpoint_display = display
    -- 0 = 永不过期；上限 1 年，挡住误填 999999 导致 expires_at 溢出成荒谬时间戳。
    cfg.expires_hours = math.max(0, math.min(8760, tonumber(row.expires_hours) or 0))
    cfg.use_bucket_lifecycle = tonumber(row.use_bucket_lifecycle) == 1
    -- 本地中转/暂存目录：留空表示用全局「临时保存区」（config.store_dir）。
    cfg.local_root = tostring(row.local_root or "")
    cfg.note = tostring(row.note or "")
    return cfg
end

-- ── 内部：整表重建 / 取用 ───────────────────────────────────────────────────
-- 非法行也留在表里（id -> 原因）：调用方要能区分「这一行不存在」与「这一行写坏了」，
-- 前者是 423/404 语义，后者是 502 语义（配置存在但网关用不了）。
local invalid = nil          -- { ["<id>|<name>"] = reason }，与 derived 同生命周期

local function build_map()
    local map, bad = {}, {}
    for _, row in ipairs(s3_configs.enabled_rows()) do
        -- row 是 mlcache 共享表：只读，不 mutate。
        local cfg, reason = _M.from_row(row)
        local key = tostring(row.id) .. "|" .. tostring(row.name or "")
        if cfg then
            map[key] = cfg
        else
            bad[key] = tostring(reason)
            -- 单行坏掉不影响其他配置：记一条 WARN，让它从可用列表里消失。
            ngx.log(ngx.WARN, "authz: s3 config ", tostring(row.id), " unusable: ",
                tostring(reason))
        end
    end
    return map, bad
end

--- 拷贝一份 cfg 交给调用方（writable 一并复制，避免调用方改到共享结构）。
local function own(cfg)
    if not cfg then return nil end
    local out = {}
    for key, value in pairs(cfg) do out[key] = value end
    if cfg.writable then
        local entries = {}
        for index, entry in ipairs(cfg.writable.entries or {}) do entries[index] = entry end
        out.writable = { all = cfg.writable.all == true, entries = entries }
    end
    if cfg.writable_roots then
        local roots = {}
        for index, root in ipairs(cfg.writable_roots) do roots[index] = root end
        out.writable_roots = roots
    end
    return out
end

--- env 回落项的虚拟 cfg。id=0（真行 AUTOINCREMENT 从 1 起，永不冲突），name='env'。
local function env_virtual()
    local c = runtime_config()
    local cfg = c and c.s3
    if not cfg then return nil end
    local out = own(cfg)
    out.id = 0
    out.name = "env"
    out.virtual = true
    out.is_default = true
    out.expires_hours = 0
    out.use_bucket_lifecycle = false
    out.default_bucket = ""
    out.local_root = ""
    out.endpoint_display = (c and c.s3_endpoint_display) or ""
    out.note = "环境变量默认配置（AUTHZ_S3_*）"
    return out
end

local function current_map()
    local rev = revision()
    -- revision 取不到（shared dict 缺失 / master 阶段）时不做缓存：每次直查，宁慢不脏。
    if rev == nil then return build_map() end
    if derived and derived_rev == rev then return derived, invalid end
    local map, bad = build_map()
    derived = map
    invalid = bad
    derived_rev = rev
    return map, bad
end

local function ordered(map)
    local list = {}
    for _, cfg in pairs(map) do list[#list + 1] = cfg end
    table.sort(list, function(a, b) return (a.id or 0) < (b.id or 0) end)
    return list
end

-- ── 对外查询 ────────────────────────────────────────────────────────────────
--- 全部**可用**的启用配置（前端下拉 / 管理列表用）。返回新建表，调用方可安全持有。
--- 语义（明确写给第二阶段的接口层，别猜）：
---   * 只含「行存在 + enabled=1 + 字段合法」的配置；字段非法的行会被剔除
---     （它出现在 get() 的 kind="invalid" 里，不在 list 里）。
---   * 表内没有任何可用行时才追加 env 回落项（virtual=true、name='env'、id=0）。
---     表里有可用行时 env 不进列表 —— 否则下拉里会多出一个「谁都不知道还作不作数」的
---     幽灵选项；要显式点 env 请用 get("env")（它始终可用）。
---   * opts.include_env=true 时无论有没有行都把 env 项加上（前端想要「env」这一
---     栏做对照时用）。
function _M.list(opts)
    opts = opts or {}
    local out = {}
    for _, cfg in ipairs(ordered(current_map())) do out[#out + 1] = own(cfg) end
    local env = env_virtual()
    if #out == 0 then
        if env then out[#out + 1] = env end
    elseif opts.include_env and env then
        out[#out + 1] = env
    end
    return out
end

--- 按 ref 取一套配置。ref:
---   nil           → 默认项：is_default=1 且 enabled=1 的行 → id 最小的 enabled 行
---                   → env 回落项（virtual=true）
---   数字/数字串    → 按 id；**0（含 "0" 与 "cfg:0"）= env 回落项**，见下方注释
---   "cfg:<id>"    → 按 id（前端与上传记录里的形态）
---   其它字符串     → 按 name
--- 取不到返回 (nil, 简明原因)；**永不 error()**（运行期可失败）。
function _M.get(ref)
    local map, bad = current_map()
    local list = ordered(map)
    local text = ref == nil and "" or tostring(ref)
    if text == "" then
        for _, cfg in ipairs(list) do
            if cfg.is_default then return own(cfg) end
        end
        if #list > 0 then return own(list[1]) end
        local env = env_virtual()
        if env then return env end
        -- 表里没行、env 也没配：整体未配置（调用方 423）。
        return nil, "对象存储未配置", "disabled"
    end
    -- ref 形态归一化：允许 7 / "7" / "cfg:7" 三种写法指向同一行。
    local requested = tonumber(text:match("^cfg:(.+)$")) or tonumber(text)
    -- 0 是 env 回落项的**虚拟 id**：summary() 给 env 虚拟项的就是 id=0、name='env'，
    -- 前端 s3.html 也照它把 ?cfg=0 拼回请求里；而真行是 AUTOINCREMENT，id 从 1
    -- 起，所以 0 永远命中不到真行。在这里把它翻成 env 项，「按 0 取」与「summary
    -- 说 0 是默认项」两件事才同源。
    -- 为什么必须坐在 get() 里而不是调用方：s3_proxy.lua 的 ?cfg= 直连本函数（不经
    -- router 的 s3_config_by_ref），纯 env 部署下 ?cfg=0 会在下面的数字分支里查到
    -- kind="missing" → 页面刚把 cfg 对齐完就吃 423。router.lua:280 那段 0→get("env")
    -- 翻译现在可以去掉（留着也无害：两条路结果完全一致）。
    if requested == 0 then
        local env = env_virtual()
        if env then return env end
        -- env 那套没配（AUTHZ_S3_ENDPOINT 为空）：0 指向的东西不存在。按「整套功能
        -- 没开」回 disabled（调用方 423），而不是 missing —— 与 text == "" 分支的
        -- 未配置语义一致，前端才不会把它误判成「我记的那套服务没了」而反复重载。
        return nil, "环境变量默认配置未启用（AUTHZ_S3_ENDPOINT 未配置）", "disabled"
    end
    -- 命中非法行时把原因带回去（kind="invalid"）：调用方按 502 处理。
    local function bad_reason(id, name)
        if not bad then return nil end
        if name ~= nil then
            local reason = bad[tostring(id) .. "|" .. name]
            if reason then return reason end
        end
        for key, reason in pairs(bad) do
            local head = key:match("^(.-)|")
            if head == tostring(id) then return reason end
        end
        return nil
    end
    local id = requested
    if id then
        for _, cfg in ipairs(list) do
            if cfg.id == id then return own(cfg) end
        end
        local reason = bad_reason(id, nil)
        if reason then
            return nil, "存储配置 " .. tostring(id) .. " 配置非法: " .. reason, "invalid"
        end
        return nil, "存储配置 " .. tostring(id) .. " 不存在或已禁用", "missing"
    end
    for _, cfg in ipairs(list) do
        if cfg.name == text then return own(cfg) end
    end
    -- 按名字点名时也要区分「行写坏了」：非法行不在 list 里，但 bad 表里有它，
    -- 否则按 name 取一个字段非法的配置会被误报成「不存在」（502 语义丢成 423）。
    do
        local suffix = "|" .. text
        for key, reason in pairs(bad or {}) do
            if key:sub(-#suffix) == suffix then
                return nil, "存储配置 " .. text .. " 配置非法: " .. reason, "invalid"
            end
        end
    end
    local env = env_virtual()
    -- 名字最后再试一次 env：?cfg=env 在纯 env 部署里应当可用。
    if env and env.name == text then return env end
    return nil, "存储配置 " .. text .. " 不存在或已禁用", "missing"
end

--- 上传流水的 cfg_id → cfg。cfg_id 为 NULL 表示当时用的是 env 回落配置，
--- 这时**不能**退回「当前默认项」（对象可能在另一套服务上），必须回 env。
function _M.for_record(cfg_id)
    local id = tonumber(cfg_id)
    if not id then
        local env = env_virtual()
        if env then return env end
        return nil, "环境变量回落配置已失效（AUTHZ_S3_ENDPOINT 未配置）", "missing"
    end
    return _M.get(id)
end

--- 给前端/管理接口的安全概览：**只含 id/name/endpoint/开关，绝不含任何凭证**。
--- default_id = _M.get(nil) 实际命中的那行（纯 env 部署时为 0）。
function _M.summary()
    local configs = {}
    local default_id = nil
    for _, cfg in ipairs(ordered(current_map())) do
        configs[#configs + 1] = {
            id = cfg.id,
            name = cfg.name,
            endpoint = cfg.endpoint_display,
            region = cfg.region,
            is_default = cfg.is_default and 1 or 0,
            enabled = 1,
            virtual = false,
            expires_hours = cfg.expires_hours,
            use_bucket_lifecycle = cfg.use_bucket_lifecycle and 1 or 0,
            default_bucket = cfg.default_bucket,
        }
        if default_id == nil and cfg.is_default then default_id = cfg.id end
    end
    if #configs == 0 then
        local env = env_virtual()
        if env then
            configs[#configs + 1] = {
                id = 0, name = "env", endpoint = env.endpoint_display,
                region = env.region, is_default = 1, enabled = 1, virtual = true,
                expires_hours = 0, use_bucket_lifecycle = 0, default_bucket = "",
            }
            default_id = 0
        end
    end
    if default_id == nil and configs[1] then default_id = configs[1].id end
    return { configs = configs, default_id = default_id }
end

--- 让 worker-local 派生缓存立即作废（写接口在事务提交后调用；不调也会被 db_rev
--- 在下一次取用时自动作废，这个函数只为「同一次请求内写完立刻读」准备）。
function _M.invalidate()
    derived = nil
    invalid = nil
    derived_rev = nil
end

return _M
