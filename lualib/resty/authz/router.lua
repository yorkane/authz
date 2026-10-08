--- Unified /_authz control-plane router.
-- One klib.router("/_authz") serves the login/OAuth HTML pages and every
-- JSON management API under /api/*, registered at module load time.

local cjson = require "cjson.safe"
local guard = require "resty.authz.api.guard"
local service = require "resty.authz.api.service"
local session = require "resty.authz.session"
local ui = require "resty.authz.ui"
local files = require "resty.authz.files"
local files_upload = require "resty.authz.files_upload"
local s3 = require "resty.authz.s3"
local s3_config_store = require "resty.authz.s3_config_store"
local s3_upload = require "resty.authz.s3_upload"
local s3_scope = require "resty.authz.s3_scope"
local nginxconf = require "resty.authz.nginxconf"
local guest = require "resty.authz.guest"
local domain = require "resty.authz.domain"

local router = require("klib.router").new("/_authz")

local function register(method, rule, handler)
    local _, _, err = router:register(rule, handler, method)
    assert(not err, err)
end

local function body_or_error(env, req)
    local data, err = req.get_body(env)
    if not data then
        return nil, { error = { code = "invalid_body", message = err } }, 400
    end
    return data
end

local function with_body(callback)
    return function(params, env, req, current, token)
        local data, payload, status = body_or_error(env, req)
        if not data then return payload, status end
        return guard.result(callback(params, data, current, token))
    end
end

local function array_data(rows)
    if rows and #rows > 0 then return rows end
    return cjson.empty_array
end

-- JSON 里的 null 会被 cjson 解成 cjson.null（light userdata），不是 Lua 的 nil。
-- 可选字符串字段必须先过这一层，否则 "字段传 null" 会被当成名为 "userdata" 的路径段。
local function optional_text(value)
    if value == nil or value == cjson.null then return nil end
    return value
end
-- 内容出口（file-/s3- 保留前缀域名）的绝对前缀。files 页的「新窗口打开」用它
-- 拼一条可以直接分享、能被外部程序打开的字节链接：同源的 /_authz/files/ 相对
-- 地址离开管理壳就没有上下文，也看不出内容在哪台机器上。域名沿用现有惯例，由
-- domain.link 从**当前请求 Host** 拼出 <前缀>-<节点>.<zone>（IP / 单标签主机拼
-- 不出来时回 nil，前端自动退回相对地址，行为与改造前一致）。scheme 与 Cookie 的
-- Secure 用同一判据（X-Forwarded-Proto 优先，其次 $https），免得在 TLS 入口下
-- 回吐 http:// 链接再被外层跳一次。
local function request_scheme()
    local forwarded = tostring(ngx.var.http_x_forwarded_proto or ""):lower()
    local first = forwarded:match("^%s*([^,;%s]+)")
    if first == "https" then return "https" end
    if first == "http" then return "http" end
    return ngx.var.https == "on" and "https" or "http"
end
local function content_entry_base(app_name)
    local config = require("resty.authz").config
    local entry = config.app_entries and config.app_entries[app_name]
    if not entry then return nil end
    local host = domain.link(entry.prefix, domain.display_host())
    if not host or host == "" then return nil end
    return request_scheme() .. "://" .. host .. "/"
end

-- ── Auth pages ──────────────────────────────────────────────────────────────
register("GET", "/", function()
    ngx.header["Cache-Control"] = "no-store"
    return ngx.redirect("/_authz/apps/", ngx.HTTP_MOVED_PERMANENTLY)
end)

register("GET",  "/login",         ui.login_get)
register("POST", "/login",         ui.login_post)
register("GET",  "/oauth/start",   ui.oauth_start)
register("GET",  "/oauth/callback", ui.oauth_callback)

-- ── Guest 探针 ──────────────────────────────────────────────────────────────
-- /_authz/guest：guest 是匿名用户角色，默认能力就是这条只读探针（guest 角色的
-- 数据库 API Key，或持有 guest 角色的登录会话），完整回显本次请求的全部请求头
-- （含 Cookie / Authorization / API Key，明文，调试用）、来源 IP 与代理转发信息。
-- admin 也可访问，便于核对某次请求在网关侧看到的真实信息。
-- 除探针外，guest 的可访问代理范围与其他角色一样由策略（role:guest 主体）配置。
-- 服务端渲染、逐字段 HTML 转义；?json=1 返回同一数据的 JSON 形态。
-- 认证与角色门禁内聚在 guest.handle：匿名访客直接放行（guest=匿名），
-- 非 guest/admin 的已登录会话拒绝，无效 Key 直接 401。
register("GET", "/guest", guest.handle)

-- ── Session ─────────────────────────────────────────────────────────────────
-- The SPA shell calls this on startup; re-issue the session cookie so
-- tokens created before a cookie-attribute change (SameSite=Lax to None)
-- migrate transparently. HttpOnly cookies cannot be fixed from JS, and
-- API-key calls have no session token, so they stay untouched.
-- self_service：guest 的能力面之一就是「知道自己是谁」：该端点只回显调用者自身，
-- 没有侦察价值，所以浏览器会话与 guest Key 都放行。它不含写操作；退出登录另外标了
-- session_only（它必须有真实会话可销毁，机器 Key 没有会话，故仍拒绝）。
-- 文件/对象存储的写端点不带 session_only：admin Key 免登录直连即可（CSRF 只对
-- 浏览器会话生效，见 api/guard.lua）。其余控制面端点对 guest 按各自角色门禁放行。
register("GET", "/api/session", guard.wrap(function(_, _, _, current, token)
    if token then session.set_cookie(token) end
    return { data = service.session_payload(current) }
end, { self_service = true }))


register("DELETE", "/api/session", guard.wrap(function(_, _, _, _, token)
    session.delete(token)
    session.clear_cookie()
    return { data = { message = "已退出登录" } }
end, { csrf = true, session_only = true, self_service = true }))

-- ── Users ───────────────────────────────────────────────────────────────────
register("GET", "/api/users", guard.wrap(function(_, _, _, current)
    return { data = service.list_users(current) }
end, { admin = true }))

register("POST", "/api/users", guard.wrap(with_body(function(_, data)
    return service.create_user(data)
end), { admin = true, csrf = true }))

register("PATCH", "/api/users/:id", guard.wrap(with_body(function(params, data)
    return service.update_user(tonumber(params.id), data)
end), { admin = true, csrf = true }))

register("DELETE", "/api/users/:id", guard.wrap(function(params)
    return guard.result(service.delete_user(tonumber(params.id)))
end, { admin = true, csrf = true }))

register("PUT", "/api/users/:id/password", guard.wrap(with_body(function(params, data)
    return service.reset_password(tonumber(params.id), data)
end), { admin = true, csrf = true }))

register("PUT", "/api/me/password", guard.wrap(with_body(function(_, data, current, token)
    return service.change_password(current, token, data)
end), { csrf = true, session_only = true }))

-- ── Remote users ────────────────────────────────────────────────────────────
register("PATCH", "/api/remote-users/:provider", guard.wrap(with_body(function(params, data)
    return service.update_remote_user(params.provider, data.subject, data)
end), { admin = true, csrf = true }))

register("DELETE", "/api/remote-users/:provider", guard.wrap(with_body(function(params, data)
    return service.delete_remote_user(params.provider, data.subject)
end), { admin = true, csrf = true }))

-- ── Authorization ───────────────────────────────────────────────────────────
register("GET", "/api/authorization", guard.wrap(function(_, _, _, current)
    return { data = service.authorization(current) }
end, { admin = true }))

-- ── Applications (bindings) ─────────────────────────────────────────────────
register("GET", "/api/applications", guard.wrap(function()
    return { data = array_data(service.applications()) }
end))

register("POST", "/api/applications", guard.wrap(with_body(function(_, data)
    return service.create_application(data)
end), { roles = { "admin", "api" }, csrf = true }))

register("PATCH", "/api/applications/:id", guard.wrap(with_body(function(params, data)
    return service.update_application(tonumber(params.id), data)
end), { admin = true, csrf = true }))

register("DELETE", "/api/applications/:id", guard.wrap(function(params)
    return guard.result(service.delete_application(tonumber(params.id)))
end, { admin = true, csrf = true }))

-- ── API keys ────────────────────────────────────────────────────────────────
register("GET", "/api/api-keys", guard.wrap(function()
    return { data = array_data(service.list_api_keys()) }
end, { admin = true }))

register("POST", "/api/api-keys", guard.wrap(with_body(function(_, data)
    return service.create_api_key(data)
end), { admin = true, csrf = true }))

register("PATCH", "/api/api-keys/:id", guard.wrap(with_body(function(params, data)
    return service.update_api_key(tonumber(params.id), data)
end), { admin = true, csrf = true }))

-- 轮换：生成新密钥并让旧值立即失效。明文只出现在这一次响应里，
-- 因此需要 CSRF（浏览器发起）且必须走 authz 事务以即时失效授权缓存。
register("POST", "/api/api-keys/:id/rotate", guard.wrap(function(params)
    return guard.result(service.rotate_api_key(params.id))
end, { admin = true, csrf = true }))

register("DELETE", "/api/api-keys/:id", guard.wrap(function(params)
    return guard.result(service.delete_api_key(tonumber(params.id)))
end, { admin = true, csrf = true }))

-- ── Policies ────────────────────────────────────────────────────────────────
register("POST", "/api/policies", guard.wrap(with_body(function(_, data)
    return service.create_policy(data)
end), { admin = true, csrf = true }))

register("PATCH", "/api/policies/:id", guard.wrap(with_body(function(params, data)
    return service.update_policy(tonumber(params.id), data)
end), { admin = true, csrf = true }))

register("DELETE", "/api/policies/:id", guard.wrap(function(params)
    return guard.result(service.delete_policy(tonumber(params.id)))
end, { admin = true, csrf = true }))

-- ── Menu entries ────────────────────────────────────────────────────────────
register("GET", "/api/menu-entries", guard.wrap(function()
    return { data = array_data(service.list_menu_entries()) }
end))

register("GET", "/api/menu-tree", guard.wrap(function(_, _, _, current)
    return { data = service.menu_tree(current) }
end))

-- 域名服务/本地服务两组的可编辑条目（含隐藏项），键为 binding:<id>/port:<port>。
register("GET", "/api/menu-services", guard.wrap(function()
    return { data = service.menu_service_rows() }
end))

-- /menu-services/reorder must be registered before /:key-style rules.
register("PUT", "/api/menu-services/reorder", guard.wrap(with_body(function(_, data)
    return service.reorder_menu_services(data)
end), { admin = true, csrf = true }))

register("PATCH", "/api/menu-services/:key", guard.wrap(with_body(function(params, data)
    return service.update_menu_service(params.key, data)
end), { admin = true, csrf = true }))

register("DELETE", "/api/menu-services/:key", guard.wrap(function(params)
    return guard.result(service.reset_menu_service(params.key))
end, { admin = true, csrf = true }))

-- ── File browser (read-only listing of the mounted html directory) ─────────
register("GET", "/api/files", guard.wrap(function(_, env)
    local args = type(env.uri_args) == "table" and env.uri_args or {}
    local root = require("resty.authz").config.files_root or files.default_root
    local listing, err, status = files.list(root, args.path)
    if not listing then
        return { error = {
            code = status == 404 and "not_found" or "request_failed",
            message = err or "无法读取目录",
        } }, status or 400
    end
    -- 内容出口绝对前缀；没有启用内置 files 入口、或请求 Host 不可用时整个字段
    -- 缺席（而不是回空串）：前端用「有没有这个字段」决定走绝对链接还是相对地址。
    listing.content_base = content_entry_base("files")
    return { data = listing }
end))

-- 文件管理写操作（上传 / 重命名 / 移动 / 删除）：仅 admin。浏览器会话必须带 CSRF
-- 头；机器 Key（x-api-key，角色需 admin，受来源白名单约束）天然免 CSRF，可直接调用。
-- 上传走 multipart 流式落盘（resty.authz.files_upload），不读 body、不驻留内存，
-- 因此它在 guard 里只认证与鉴权；CSRF 由 guard 读头完成，不 consume body。
register("POST", "/api/files/upload", guard.wrap(function()
    -- guard 的 CSRF 校验只读请求头，不会 consume body，流式上传仍然完整可读。
    local payload, err, status = files_upload.upload()
    if not payload then
        return { error = { code = "upload_failed", message = err or "上传失败" } }, status or 400
    end
    -- 第二个返回值是 HTTP 状态码（201 新建 / 409 全量同名冲突由 handler 内部给出）。
    return payload, status
end, { admin = true, csrf = true }))

register("PUT", "/api/files/rename", guard.wrap(with_body(function(_, data)
    -- 可选 new_path：移动到其它目录（目标目录，语义与 path 完全一致）。其合法性由
    -- files.rename 内部对新目录走的 resolve_dir 判定（含 .. → 400、目录不存在 → 404），
    -- 与源 path 同一套规则，因此这里不重复校验。
    return files.rename(require("resty.authz").config.files_root or files.default_root,
        data.path, data.name, data.new_name, optional_text(data.new_path))
end), { admin = true, csrf = true }))

-- with_body 会把 handler 的第二返回值喂给 guard.result 的 err 位，拿不到 201；
-- 这里手写 body 解析，资源创建成功显式返回 201（与上传一致）。
register("POST", "/api/files/mkdir", guard.wrap(function(params, env, req, current, token)
    local data, payload, status = body_or_error(env, req)
    if not data then return payload, status end
    local created, err, err_status = files.mkdir(
        require("resty.authz").config.files_root or files.default_root, data.path, data.name)
    if not created then return guard.result(nil, err, err_status) end
    return { data = created }, 201
end, { admin = true, csrf = true }))

register("DELETE", "/api/files/remove", guard.wrap(with_body(function(_, data)
    return files.remove(require("resty.authz").config.files_root or files.default_root,
        data.path, data.name, data.recursive == true)
end), { admin = true, csrf = true }))

-- ── Object storage browser (S3-compatible private endpoint) ─────────────────
-- 全部走「当前选中的那套配置」：未配置时 GET /api/s3 返回 enabled=false（前端显示
-- 未配置卡片），其余操作 423。凭证（AKID/SECRET）只在签名器内部使用，任何接口都
-- 不回显。
-- 多套配置（s3_configs 表）上线后，env 那套退化成**回落默认项**：取配置一律经
-- s3_config_store，禁止再直读 config.s3（那会让 ?cfg= 与页面新建的配置全部失效）。
--- 取本次请求要用的配置。ref 来自 query ?cfg= 或 JSON body 的 cfg 字段（同名字段，
--- 见 admin/api.js 的 appendCfg）：nil/空 → 默认项；数字或 cfg:N → 按 id；其余 → 按 name。
--- 返回 (cfg, 原因, kind)，kind = disabled|missing|invalid —— 调用方据此定状态码。
--- 注意 cjson.null（显式传 null）与重复参数（table）都要先归一化，否则会被当成
--- 一个叫 "userdata: 0x…" / "table: 0x…" 的配置名，把「未指定」误报成 423 不存在。
--- 0（env 回落项的虚拟 id）到 env 的映射在 s3_config_store.get() 内部完成，与
--- s3_proxy.lua 的 ?cfg= 直连路径同源，本函数只做类型归一化。
local function s3_config_by_ref(ref)
    if ref == nil or ref == cjson.null or ref == "" then return s3_config_store.get(nil) end
    if type(ref) == "table" then ref = ref[1] end
    if type(ref) ~= "string" and type(ref) ~= "number" then return s3_config_store.get(nil) end
    return s3_config_store.get(tostring(ref))
end

--- kind → (code, status)：disabled 沿用既有 code=s3_disabled/423（回归断言依赖它）；
--- missing 是「点名点到了不存在/已停用的配置」，同为 423 但消息带名字，便于前端
--- 区分「整套功能没开」与「我记的那个服务没了」（s3.html 据此回落默认项重载）；
--- invalid（行存在但字段写坏）= 配置存在而网关用不了 → 502。
local function s3_config_error(err, kind)
    if kind == "invalid" then
        return { error = { code = "s3_config_invalid", message = err or "存储配置非法" } }, 502
    end
    if kind == "missing" then
        return { error = { code = "s3_config_missing", message = err or "存储配置不存在或已禁用" } }, 423
    end
    return { error = { code = "s3_disabled", message = "对象存储未配置" } }, 423
end

-- 把 s3_context 失败时的 (payload, status) 原样透传给 router（它期待的是
-- (error_payload, status)，不能经 guard.result，否则会被包成 {"data":{"error":...}}）。
local function payload_or_error(payload, status)
    return payload, status
end

-- 可写范围外的统一 403（upload/mkdir/rename/remove 共用）：两值返回，不碰 klib.router
-- “只取前两个返回值”的坑。
local function s3_read_only(cfg)
    local hint = cfg and cfg.share_prefix
    local msg = "该路径不在可写范围内（AUTHZ_S3_WRITABLE_PATHS"
    if hint then msg = msg .. ", 默认可写前缀 " .. hint end
    msg = msg .. "）"
    return { error = { code = "s3_read_only", message = msg } }, 403
end

-- 写操作的「首建放行」：范围外目标 + 调用方显式请求 mkdir（upload 走 query
-- mkdir=1；POST /api/s3/mkdir 走 body mkdir=true；rename/remove 不支持）时，
-- 用 ensure_parents 拿到严格位于目标之上的可写条目（长度升序），逐个补建为
-- 0 字节目录标记对象（key 尾缀 /），全部成功才放行本次写。放行理由：
--   * 祖先条目必然在可写范围内（ensure_parents 只返回 scope 内条目，范围外的
--     目标不可能出现在结果里），补建不越权；
--   * 目标本身必须落在某条目内——dir_writable 或 ensure_parents 非空二者必居
--     其一（目标==条目本身时祖先链非空；目标在条目之下时 dir_writable 为真）；
--   * 典型场景：首建 share/<IP> 目录，其父 share 只读，靠本机制补建 share/<IP>。
-- 返回 (true, nil, nil) 或 (false, 原因, 状态)。
local function s3_auto_mkdir(cfg, bucket, dirpath, want_mkdir)
    if not want_mkdir or cfg.writable_all then
        return false, "not requested or all-writable", 403
    end
    if dirpath == "" then
        -- 桶根永不在任何前缀条目内；ensure_parents 对空 dirpath 返回全部条目（语义是「根之下的全部条目」而不是「根的祖先」），直接放行会让带 mkdir=1 的上传绕过只读桶根。share/<IP> 首建走目标==条目自身的 mkdir 请求，根永不需要放行。
        return false, "bucket root is never auto-creatable", 403
    end
    local ancestors = s3_scope.ensure_parents(cfg.writable, bucket, dirpath)
    if #ancestors == 0 then
        -- 目标不在任何可写条目内（含目标==条目本身但未在范围的情形）：不放行。
        if not s3_scope.dir_writable(cfg.writable, bucket, dirpath) then
            return false, "outside writable scope", 403
        end
        return true, nil, nil
    end
    for _, entry in ipairs(ancestors) do
        local ok, err, status = s3.put(cfg, bucket, entry .. "/", { body = "" })
        if not ok then
            return false, err, status or 502
        end
    end
    return true, nil, nil
end

-- 统一的“未配置/参数非法”前置校验。返回 (cfg, bucket, path) 或 (nil, payload, status)。
-- args 既可能是 uri_args（值全是字符串）也可能是解好包的 JSON body（可能有
-- cjson.null / 布尔），所以 cfg 的归一化在 s3_config_by_ref 里做。
local function s3_context(args, need_bucket)
    local cfg, err, kind = s3_config_by_ref(args.cfg)
    if not cfg then
        -- 三值返回不能直接 return（klib.router 只取前两个返回值）：调用方一律
        -- 把后两位交给 payload_or_error 原样透传。
        local payload, status = s3_config_error(err, kind)
        return nil, payload, status
    end
    local bucket = args.bucket and s3.normalize_bucket(tostring(args.bucket)) or nil
    if need_bucket and not bucket then
        return nil, { error = { code = "invalid_bucket", message = "缺少或非法的 bucket 参数" } }, 400
    end
    local path = s3.normalize_prefix(args.path)
    if path == nil then
        return nil, { error = { code = "invalid_path", message = "路径非法" } }, 400
    end
    return cfg, bucket, path
end

-- 把「本次生效的配置」与「可选配置清单」挂进响应（两者都只含安全摘要，绝不含凭证）。
-- 前端 s3.html 用它把 localStorage 里记住的 cfg 对齐到后端真实选中的那一项，并在
-- 下拉里渲染清单；configs 直接取 s3_config_store.summary()，与配置管理页同源。
local function s3_config_fields(cfg)
    local summary = service.s3_config_summary()
    -- configs 已由 service 层归一成数组或 cjson.empty_array 哨兵；这里**不能**再
    -- 套一次 array_data —— 对 empty_array（light userdata）取 # 会直接抛错。
    return {
        cfg = service.s3_config_summary_of(cfg) or cjson.null,
        configs = summary and summary.configs or cjson.empty_array,
    }
end

register("GET", "/api/s3", guard.wrap(function(_, env)
    local args = type(env.uri_args) == "table" and env.uri_args or {}
    local cfg, cfg_err, cfg_kind = s3_config_by_ref(args.cfg)
    if not cfg then
        -- 未配置不是错误：菜单点进来要能看到“未配置”提示，所以 200 + enabled=false
        -- （带 bucket 也一样降级 —— 回归里 "unconfigured bucket listing still degrades
        -- to info" 钉死了这条语义）。但**点名**了不存在/写坏的配置是另一回事：
        -- 那说明用户记的那套服务没了，必须报错让前端回落默认项，不能静默当成未配置。
        if cfg_kind == "disabled" then
            local fields = s3_config_fields(nil)
            return { data = {
                enabled = false, endpoint = "", region = "",
                buckets = cjson.empty_array,
                cfg = fields.cfg, configs = fields.configs,
            } }
        end
        return s3_config_error(cfg_err, cfg_kind)
    end
    local bucket, path = s3.normalize_bucket(tostring(args.bucket or "")), s3.normalize_prefix(args.path)
    if args.bucket and args.bucket ~= "" and not bucket then
        return { error = { code = "invalid_bucket", message = "缺少或非法的 bucket 参数" } }, 400
    end
    if not path then
        return { error = { code = "invalid_path", message = "路径非法" } }, 400
    end
    -- 多配置下 endpoint/region 必须来自**选中的那套** cfg（env 时代的
    -- config.s3_endpoint_display 只有回落时才等于它，其余配置会回显错的服务地址）。
    local fields = s3_config_fields(cfg)
    -- 不带 bucket：回桶列表（首页选择器用）。带 bucket：回目录内容。
    if not bucket then
        local buckets, err, status = s3.list_buckets(cfg)
        if not buckets then
            return { error = { code = "s3_error", message = err } }, status or 502
        end
        local bucket_rows = {}
        for index, b in ipairs(buckets) do
            bucket_rows[index] = {
                name = b.name,
                creation_date = b.creation_date,
                -- 整桶可写：全写，或存在条目==bucket（桶内前缀条目不算整桶可写）。
                writable = s3_scope.bucket_writable(cfg.writable, b.name),
            }
        end
        return { data = {
            enabled = true,
            endpoint = cfg.endpoint_display or "",
            region = cfg.region,
            buckets = array_data(bucket_rows),
            cfg = fields.cfg,
            configs = fields.configs,
            bucket = cjson.null,
            -- 可写范围回显（空时必须是 cjson.empty_array，否则前端拿到 null）。
            writable_roots = array_data(cfg.writable_roots),
            writable_all = cfg.writable_all,
            -- 默认场景的挂载根前缀（share/<IP>）；显式可写范围或探测失败时为 null。
            share_prefix = cfg.share_prefix or cjson.null,
            share_bucket = cfg.share_bucket,
        } }
    end
    local token = args.token and tostring(args.token) or nil
    local listing, err, status = s3.browse(cfg, bucket, path, token)
    if not listing then
        return { error = {
            code = status == 404 and "not_found" or "request_failed",
            message = err or "无法读取对象列表",
        } }, status or 400
    end
    -- 只读标记：每个条目按 item 语义（key = join(path, name)），目录整体按 dir 语义。
    -- 注意先遍历再 array_data：空列表时 array_data 会换成 cjson.empty_array
    --（userdata 哨兵），对它 ipairs 会直接 500。
    local rows = listing.items or {}
    for index, item in ipairs(rows) do
        item.writable = s3_scope.item_writable(cfg.writable, bucket, s3.join(path, item.name))
    end
    listing.items = array_data(rows)
    listing.writable = s3_scope.dir_writable(cfg.writable, bucket, path)
    listing.next_token = listing.next_token or cjson.null
    -- listing 是本次请求现建的表（来自 XML 解析），可安全加键；带上生效配置摘要
    -- 让「切目录」与「读信息」两条路径的响应形状一致（前端只读 info，多余字段无害）。
    listing.cfg = fields.cfg
    listing.configs = fields.configs
    return { data = listing }
end))

--- 记账用的身份名：会话取 username，机器 Key 取 Key 名（api_key 的 username 字段
--- 存的就是 row.name，env Key 为 "env-api-key"）。source 区分「浏览器上传」与
--- 「Key 直连」，前端流水页按这两值显示来源列。
local function upload_identity(current, token)
    return {
        created_by = current and tostring(current.username or "") or "",
        source = token and "upload" or "api",
    }
end

-- 上传：guard 只做认证+CSRF，body 留给流式解析（resty.upload 要求未 read_body）。
register("POST", "/api/s3/upload", guard.wrap(function(params, env, req, current, token)
    local args = type(env.uri_args) == "table" and env.uri_args or {}
    local cfg, bucket, path = s3_context(args, true)
    if not cfg then return bucket, path end
    -- 可写范围拦截（dir 语义：对象落在当前目录 path 下）。
    -- query mkdir=1（前端 URL 可带 query）：范围外时按 ensure_parents 补建
    -- 尚未存在的祖先目录后再放行，见 ensure_parents 注释。
    local want_mkdir = args.mkdir == "1"
    if not s3_scope.dir_writable(cfg.writable, bucket, path) then
        local ok_mkdir, merr, mstatus =
            s3_auto_mkdir(cfg, bucket, path, want_mkdir)
        if not ok_mkdir then
            return s3_read_only(cfg)
        end
    end
    local overwrite = args.overwrite == "1" or args.overwrite == "true"
    local payload, err, status = s3_upload.upload(cfg, bucket, path, overwrite)
    if not payload then
        return { error = { code = "upload_failed", message = err or "上传失败" } }, status or 400
    end
    -- 记账（对象已写成功才记）：payload.data.uploaded 是 {name,size} 数组，空时是
    -- cjson.empty_array 哨兵 userdata —— service 层已判 table，这里只管传。
    -- 全冲突（409）/无文件（422）时 uploaded 为空，自然记 0 条。
    -- **返回值刻意丢弃**：记账失败只落 WARN，绝不能把成功的上传改成失败响应。
    service.record_s3_writes(cfg, bucket, path, payload.data and payload.data.uploaded,
        upload_identity(current, token))
    return payload, status
end, { admin = true, csrf = true }))

register("PUT", "/api/s3/rename", guard.wrap(function(params, env, req)
    local data, payload, status = body_or_error(env, req)
    if not data then return payload, status end
    local cfg, bucket, path = s3_context(data, true)
    if not cfg then return payload_or_error(bucket, path) end
    local name = s3.normalize_name(data.name)
    local new_name = s3.normalize_name(data.new_name)
    if not name or not new_name then
        return { error = { code = "invalid_name", message = "缺少或非法的 name/new_name" } }, 400
    end
    -- 可选 new_path：移动到其它目录（桶内相对前缀）。校验与 path 完全同源：
    -- 同一个 normalize_prefix，越界（含 ..）/控制字符一律 400 invalid_path。
    -- 缺省（字段不传或为 null）= 原地改名，语义与旧版逐条一致。
    local new_path_arg = optional_text(data.new_path)
    local new_path
    if new_path_arg ~= nil then
        new_path = s3.normalize_prefix(new_path_arg)
        if new_path == nil then
            return { error = { code = "invalid_path", message = "路径非法" } }, 400
        end
    end
    -- 可写范围拦截（item 语义）：源 key 与目标 key 都要单独判一次，任一越界即 403。
    -- 目标 key 必须按 new_path 拼：移动目录时整棵子树跟着搬到目标前缀下，
    -- 若只判源前缀，就能把范围内的目录挪出范围（或反向写进只读前缀）。
    local target_key = s3.join(new_path or path, new_name)
    if not s3_scope.item_writable(cfg.writable, bucket, s3.join(path, name)) or
        not s3_scope.item_writable(cfg.writable, bucket, target_key) then
        return s3_read_only(cfg)
    end
    local renamed, rename_err, rename_status =
        s3.rename(cfg, bucket, path, name, new_name, new_path)
    if renamed then
        -- 成功后把**源** key 的流水闭账（标 deleted）。不给目标补新记录的理由写在
        -- api/services/uploads.lua 的 mark_renamed 注释里（目标字节非本网关写入、
        -- 无可信 size 与归属；补记等于造伪账）。目录形态 rename 时源前缀下的记录
        -- 也一并闭账（key_ids 会匹配 key 与 key/%）。
        service.mark_s3_renamed(cfg, bucket, s3.join(path, name))
    end
    return guard.result(renamed, rename_err, rename_status)
end, { admin = true, csrf = true }))

register("DELETE", "/api/s3/remove", guard.wrap(function(params, env, req)
    local data, payload, status = body_or_error(env, req)
    if not data then return payload, status end
    local cfg, bucket, path = s3_context(data, true)
    if not cfg then return payload_or_error(bucket, path) end
    local name = s3.normalize_name(data.name)
    if not name then
        return { error = { code = "invalid_name", message = "缺少或非法的 name" } }, 400
    end
    local key = s3.join(path, name)
    -- 可写范围拦截（item 语义；递归删除同此判定，整个前缀下任一对象越界即拒绝）。
    if not s3_scope.item_writable(cfg.writable, bucket, key) then
        return s3_read_only(cfg)
    end
    if data.recursive == true then
        -- 三值返回必须过 guard.result：klib.router 只取前两个返回值，
        -- 直接 return nil, err, status 会把 err 文案当成状态码（实测变空 200）。
        local removed, prefix_err, prefix_status = s3.delete_prefix(cfg, bucket, key)
        if removed then
            -- 递归删：整棵子树的流水都闭账（recursive=true → key 与 key/% 全标 deleted）。
            service.mark_s3_deleted(cfg, bucket, key, true)
        end
        return guard.result(removed, prefix_err, prefix_status)
    end
    -- 非递归：前缀下还有对象就拒绝，避免一个误点删掉整棵树（与 files.remove 对齐）。
    local occupied, perr, pstatus = s3.has_objects_under(cfg, bucket, key)
    if occupied == nil then
        return guard.result(nil, perr, pstatus or 502)
    end
    if occupied then
        return guard.result(nil, "目录非空，需勾选递归删除", 409)
    end
    local ok, err, status = s3.delete(cfg, bucket, key)
    if not ok then
        return guard.result(nil, err, status or 500)
    end
    -- 单对象删除成功才闭账；recursive=false 但 key 可能是「目录标记对象」，
    -- service 层的 SQL 会顺带匹配 key/ 与 key/%（同一个名字两种形态）。
    service.mark_s3_deleted(cfg, bucket, key, false)
    return { data = { removed = 1, bucket = bucket, path = path, name = name } }
end, { admin = true, csrf = true }))

-- 新建目录：S3 没有真目录，写一个以 / 结尾的 0 字节标记对象。该服务会自动生成这种
-- “幻影”条目（列表里过滤掉），但显式写一个能让空目录在别人也看得见。
register("POST", "/api/s3/mkdir", guard.wrap(function(params, env, req)
    local data, payload, status = body_or_error(env, req)
    if not data then return payload, status end
    local cfg, bucket, path = s3_context(data, true)
    if not cfg then return bucket, path end
    local name = s3.normalize_name(data.name)
    if not name then
        return { error = { code = "invalid_name", message = "缺少或非法的 name" } }, 400
    end
    -- 可写范围拦截按【目标目录自身】判定：若父目录可写，目标必然在范围内
    --（前缀语义）；父目录只读但目标本身落在可写范围内时也必须放行——否则
    -- 默认场景（范围=share/<LAN IP> 前缀）下该前缀目录永远无法被首次创建。
    -- body mkdir=true：范围外时先按 ensure_parents 补建祖先目录再放行。
    local target = s3.join(path, name)
    if not s3_scope.dir_writable(cfg.writable, bucket, target) then
        local ok_mkdir, merr, mstatus =
            s3_auto_mkdir(cfg, bucket, target, data.mkdir == true)
        if not ok_mkdir then
            return s3_read_only(cfg)
        end
    end
    local key = target .. "/"
    local ok, err, err_status = s3.put(cfg, bucket, key, { body = "" })
    if not ok then
        return { error = { code = "mkdir_failed", message = err } }, err_status or 500
    end
    return { data = { path = key, bucket = bucket } }, 201
end, { admin = true, csrf = true }))

-- ── 多套存储服务配置（s3_configs 表）───────────────────────────────────────
-- 回显永不带 secret_access_key（repository 的 META 列集合在 SQL 层就不选它），
-- 页面看到的只有 has_secret 与 access_key_id_masked，所以 PATCH 的「空 = 不改」
-- 语义才能安全成立。id=0 是 env 回落项（virtual=true）：编辑/删除 422，
-- 「设为默认」是 no-op 成功。
-- 注册顺序（红线）：字面量路由必须早于 /:id，否则 POST /api/s3-configs 会被
-- /:id 系规则先吃掉（klib.router 的 sort 只把「多段参数」路由排到尾部，
-- 同段数的字面量与 :param 仍按注册先后取第一个完整匹配）。
register("GET", "/api/s3-configs", guard.wrap(function()
    return { data = service.list_s3_configs() }
end, { admin = true }))

register("POST", "/api/s3-configs", guard.wrap(with_body(function(_, data)
    -- with_body 把 callback 的三个返回值原样喂给 guard.result，所以 service 侧
    -- 的 (item, nil, 201) 能真的落成 201（与 POST /api/users 同一手法）。
    return service.create_s3_config(data)
end), { admin = true, csrf = true }))

-- /:id/default 与 /:id/test 都是「方法 + 段数」不同的路由，但仍排在 PATCH/DELETE
-- /:id 之前注册：保持与 /api/menu-entries/reorder 相同的阅读顺序，避免以后
-- 有人把 default 改成同段数的字面量路由时踩到匹配优先级。
register("PUT", "/api/s3-configs/:id/default", guard.wrap(with_body(function(params)
    return service.set_default_s3_config(tonumber(params.id))
end), { admin = true, csrf = true }))

register("POST", "/api/s3-configs/:id/test", guard.wrap(with_body(function(params)
    -- 连通性测试：{ok=true,buckets=[名字数组]}；失败 502 + 原因（不回显任何凭证）。
    return service.test_s3_config(tonumber(params.id))
end), { admin = true, csrf = true }))

register("PATCH", "/api/s3-configs/:id", guard.wrap(with_body(function(params, data)
    return service.update_s3_config(tonumber(params.id), data)
end), { admin = true, csrf = true }))

register("DELETE", "/api/s3-configs/:id", guard.wrap(function(params)
    return guard.result(service.delete_s3_config(tonumber(params.id)))
end, { admin = true, csrf = true }))

-- ── 上传流水（upload_records）：经网关写入的对象账本 + 过期清理 ─────────────
register("GET", "/api/uploads", guard.wrap(function(_, env)
    local args = type(env.uri_args) == "table" and env.uri_args or {}
    -- 三值返回照旧经 guard.result（非法 state 要真出 422，而不是 {data:null} 200）。
    return guard.result(service.list_uploads(args))
end, { admin = true }))

-- 字面量 cleanup 必须早于 DELETE /api/uploads/:id 注册（同上红线）。
register("POST", "/api/uploads/cleanup", guard.wrap(with_body(function(_, data)
    return service.cleanup_uploads(data)
end), { admin = true, csrf = true }))

register("DELETE", "/api/uploads/:id", guard.wrap(function(params)
    -- 语义：立刻按记录去删对象/本地文件并把行标 deleted；失败回 502 + 原因，不静默。
    return guard.result(service.delete_upload(tonumber(params.id)))
end, { admin = true, csrf = true }))

-- ── 本机临时保存区（store）：给 agent 的免登录落盘接口 ───────────────────────
-- 定位：容器内 AUTHZ_STORE_DIR（默认 /data/store，宿主落在部署卷的 data/store 下）。
-- 每次写入都在 upload_records 记一条 kind='local' 流水，expires_at 由
-- s3_config_store.align_expiry 整点对齐，交给 maintenance 的每小时定时器回收；
-- 想立刻回收就调 POST /api/uploads/cleanup。**这里不承诺长期保存**，需要持久的
-- 内容走对象存储（/api/s3* + s3_configs）。
--
-- guard 一律不带 session_only（service 侧红线 R8）：本 API 的核心用途就是 agent 用
-- X-API-KEY 免登录保存/取回文件。能力面不变：admin 角色 + Key 的来源 IP 白名单。
-- 写端点保留 csrf=true —— 机器 Key 天然免 CSRF（guard 只在未出示凭证头时校验），
-- 受影响的只有浏览器会话，与其他写端点一致。
-- 注册顺序（红线）：本组全是字面量路由、无 :id；相对路径一律走 query（?path=），
-- 不放进 URL 段，避免多级路径与路由段数打架。
local function store_identity(current, token)
    return (current and tostring(current.username or current.name or "") or ""),
        (token and "upload" or "api")
end

register("GET", "/api/store/info", guard.wrap(function()
    -- 目录不可用不是错误：service 回 200 + enabled=false，前端显示提示卡片。
    return { data = service.store_info() }
end, { admin = true }))

register("GET", "/api/store/stat", guard.wrap(function(_, env)
    local args = type(env.uri_args) == "table" and env.uri_args or {}
    return guard.result(service.store_stat(args.path))
end, { admin = true }))

register("GET", "/api/store", guard.wrap(function(_, env)
    -- 列目录：?path=<rel>，省略即保存区根。只读，不需要 CSRF。
    local args = type(env.uri_args) == "table" and env.uri_args or {}
    return guard.result(service.store_list(args.path, args))
end, { admin = true }))

-- PUT 的字节来源必须先由 store_body_source() 取得：它按 Content-Length 预判体积，
-- 超限当场 413，而不是先把整个请求体写进 nginx 临时文件。注意 service 的形状是
-- put(rel, expires_hours, <字节来源>, created_by, opts) —— 第 3 个实参是字节来源，
-- 记账用的来源字符串在第 5 个实参 opts.source 里（命名撞车是 service 层既有契约，
-- 这里照用；改动会牵动 pump 的超限抛错路径）。overwrite 默认开：agent 反复保存
-- 同一路径是主用途，只有显式 overwrite=0/false 才在同名时回 409。
register("PUT", "/api/store", guard.wrap(function(params, env, req, current, token)
    local args = type(env.uri_args) == "table" and env.uri_args or {}
    local who, source = store_identity(current, token)
    local body, body_err, body_status = service.store_body_source()
    if not body then
        return { error = { code = "store_body_rejected", message = tostring(body_err) } },
            tonumber(body_status) or 400
    end
    local keep_existing = args.overwrite == "0" or args.overwrite == "false"
    return guard.result(service.store_put(args.path, args.expires_hours, body, who,
        { source = source, overwrite = not keep_existing }))
end, { admin = true, csrf = true }))

-- multipart 多文件上传：字节流由 service 内部用 resty.upload 直接解析（与
-- files/s3 上传同一手法），所以这里**不能**先 read_body。upload 的第 3 个实参
-- 在 service 里未使用（保留位），传 nil 占位。overwrite 语义与其他上传相反：
-- 默认关（同名计入 skipped / 全冲突 409），要覆盖显式带 overwrite=1。
register("POST", "/api/store/upload", guard.wrap(function(params, env, req, current, token)
    local args = type(env.uri_args) == "table" and env.uri_args or {}
    local who, source = store_identity(current, token)
    return guard.result(service.store_upload(args.path, args.expires_hours, nil, who,
        { source = source,
          overwrite = args.overwrite == "1" or args.overwrite == "true" }))
end, { admin = true, csrf = true }))

register("DELETE", "/api/store", guard.wrap(function(params, env, req, current)
    local args = type(env.uri_args) == "table" and env.uri_args or {}
    local who = store_identity(current, nil)
    return guard.result(service.store_remove(args.path,
        args.recursive == "1" or args.recursive == "true", who))
end, { admin = true, csrf = true }))

register("POST", "/api/menu-entries", guard.wrap(with_body(function(_, data)
    return service.create_menu_entry(data)
end), { admin = true, csrf = true }))

-- ── Nginx include editor (dangerous: admin-only, validate-then-save) ───────
register("GET", "/api/nginx-conf", guard.wrap(function()
    return { data = nginxconf.read_all() }
end, { admin = true }))

register("POST", "/api/nginx-conf/validate", guard.wrap(with_body(function(_, data)
    local result, err, status = nginxconf.validate(data.name, data.content)
    if not result then return nil, err, status or 400 end
    return result
end), { admin = true, csrf = true }))

register("PUT", "/api/nginx-conf", guard.wrap(with_body(function(_, data)
    local saved, err, status = nginxconf.save(data.name, data.content)
    if not saved then return nil, err, status or 400 end
    return saved
end), { admin = true, csrf = true }))

register("POST", "/api/nginx-conf/reload", guard.wrap(with_body(function()
    local reloaded, err, status = nginxconf.reload()
    if not reloaded then return nil, err, status or 500 end
    return reloaded
end), { admin = true, csrf = true }))

-- /reorder must be registered before /:id so it is not matched as an id.
register("PUT", "/api/menu-entries/reorder", guard.wrap(with_body(function(_, data)
    return service.reorder_menu_entries(data.order)
end), { admin = true, csrf = true }))

register("PATCH", "/api/menu-entries/:id", guard.wrap(with_body(function(params, data)
    return service.update_menu_entry(tonumber(params.id), data)
end), { admin = true, csrf = true }))

register("DELETE", "/api/menu-entries/:id", guard.wrap(function(params)
    return guard.result(service.delete_menu_entry(tonumber(params.id)))
end, { admin = true, csrf = true }))

-- ── Error handlers ──────────────────────────────────────────────────────────
local function error_handler(ctx, status, err, _, _)
    if status >= 500 and err then
        -- klib 用 xpcall+debug.traceback 捕获 handler 异常后交到这里；不在这里落
        -- 日志的话，线上 500 完全无法定位（error.log 一个字节都不会有）。
        ngx.log(ngx.ERR, "authz router error: ", tostring(err))
    end
    local accept_json = tostring(ngx.req.get_headers()["Accept"] or "")
        :find("application/json", 1, true) ~= nil

    if status == 404 then
        local message = "此入口不存在，请检查请求路径"
        ngx.status = ngx.HTTP_NOT_FOUND
        if accept_json then
            ngx.header["Content-Type"] = "application/json; charset=UTF-8"
            ngx.print(cjson.encode({ error = { code = "http_404", message = message } }))
        else
            ngx.header["Content-Type"] = "text/html; charset=UTF-8"
            ngx.print("<h1>404 Not Found</h1><p>" .. message .. "</p>")
        end
        return
    end

    ngx.status = ngx.HTTP_INTERNAL_SERVER_ERROR
    ngx.header["Content-Type"] = "application/json; charset=UTF-8"
    ngx.print(cjson.encode({ error = { code = "http_500", message = "Internal Server Error" } }))
end

assert(not select(2, router:error_handle(404, error_handler)))
assert(not select(2, router:error_handle(500, error_handler)))

return router
