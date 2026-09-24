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
local s3_upload = require "resty.authz.s3_upload"
local s3_scope = require "resty.authz.s3_scope"
local nginxconf = require "resty.authz.nginxconf"
local guest = require "resty.authz.guest"

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
-- session_only，机器 Key 依然进不去。其余控制面端点对 guest 按各自角色门禁放行。
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
    return { data = listing }
end))

-- 文件管理写操作（上传 / 重命名 / 删除）：仅 admin，浏览器会话必须带 CSRF。
-- 上传走 multipart 流式落盘（resty.authz.files_upload），不读 body、不驻留内存，
-- 因此它在 guard 里只认证与鉴权；CSRF 头由 handler 自己比对（见下）。
register("POST", "/api/files/upload", guard.wrap(function()
    -- guard 的 CSRF 校验只读请求头，不会 consume body，流式上传仍然完整可读。
    local payload, err, status = files_upload.upload()
    if not payload then
        return { error = { code = "upload_failed", message = err or "上传失败" } }, status or 400
    end
    -- 第二个返回值是 HTTP 状态码（201 新建 / 409 全量同名冲突由 handler 内部给出）。
    return payload, status
end, { admin = true, csrf = true, session_only = true }))

register("PUT", "/api/files/rename", guard.wrap(with_body(function(_, data)
    return files.rename(require("resty.authz").config.files_root or files.default_root,
        data.path, data.name, data.new_name)
end), { admin = true, csrf = true, session_only = true }))

-- with_body 会把 handler 的第二返回值喂给 guard.result 的 err 位，拿不到 201；
-- 这里手写 body 解析，资源创建成功显式返回 201（与上传一致）。
register("POST", "/api/files/mkdir", guard.wrap(function(params, env, req, current, token)
    local data, payload, status = body_or_error(env, req)
    if not data then return payload, status end
    local created, err, err_status = files.mkdir(
        require("resty.authz").config.files_root or files.default_root, data.path, data.name)
    if not created then return guard.result(nil, err, err_status) end
    return { data = created }, 201
end, { admin = true, csrf = true, session_only = true }))

register("DELETE", "/api/files/remove", guard.wrap(with_body(function(_, data)
    return files.remove(require("resty.authz").config.files_root or files.default_root,
        data.path, data.name, data.recursive == true)
end), { admin = true, csrf = true, session_only = true }))

-- ── Object storage browser (S3-compatible private endpoint) ─────────────────
-- 全部走 config.s3：未配置时 GET /api/s3 返回 enabled=false（前端显示未配置卡片），
-- 其余操作 423。凭证（AKID/SECRET）只在签名器内部使用，任何接口都不回显。
local function s3_cfg()
    return require("resty.authz").config.s3
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
local function s3_context(args, need_bucket)
    local cfg = s3_cfg()
    if not cfg then
        return nil, { error = { code = "s3_disabled", message = "对象存储未配置" } }, 423
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

register("GET", "/api/s3", guard.wrap(function(_, env)
    local args = type(env.uri_args) == "table" and env.uri_args or {}
    local cfg = s3_cfg()
    if not cfg then
        -- 未配置不是错误：菜单点进来要能看到“未配置”提示，所以 200 + enabled=false。
        return { data = { enabled = false, endpoint = "", region = "", buckets = cjson.empty_array } }
    end
    local bucket, path = s3.normalize_bucket(tostring(args.bucket or "")), s3.normalize_prefix(args.path)
    if args.bucket and args.bucket ~= "" and not bucket then
        return { error = { code = "invalid_bucket", message = "缺少或非法的 bucket 参数" } }, 400
    end
    if not path then
        return { error = { code = "invalid_path", message = "路径非法" } }, 400
    end
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
            endpoint = require("resty.authz").config.s3_endpoint_display,
            region = require("resty.authz").config.s3_region_display,
            buckets = array_data(bucket_rows),
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
    return { data = listing }
end))

-- 分享链接：presigned GET。凭证不外泄，签名在 query 里，到期自动失效。
register("GET", "/api/s3/share", guard.wrap(function(_, env)
    local args = type(env.uri_args) == "table" and env.uri_args or {}
    local cfg, bucket, path = s3_context(args, true)
    if not cfg then return bucket, path end
    local name = s3.normalize_name(args.name)
    if not name then
        return { error = { code = "invalid_name", message = "缺少或非法的 name 参数" } }, 400
    end
    local url, err = s3.presign_get(cfg, bucket, s3.join(path, name),
        cfg.share_ttl, args.download == "1")
    if not url then
        return { error = { code = "s3_error", message = err } }, 502
    end
    return { data = { url = url, expires_in = cfg.share_ttl } }
end))

-- 上传：guard 只做认证+CSRF，body 留给流式解析（resty.upload 要求未 read_body）。
register("POST", "/api/s3/upload", guard.wrap(function(params, env)
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
    return payload, status
end, { admin = true, csrf = true, session_only = true }))

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
    -- 可写范围拦截（item 语义：源与目标对象 key 都必须在范围内）。
    if not s3_scope.item_writable(cfg.writable, bucket, s3.join(path, name)) or
        not s3_scope.item_writable(cfg.writable, bucket, s3.join(path, new_name)) then
        return s3_read_only(cfg)
    end
    return guard.result(s3.rename(cfg, bucket, path, name, new_name))
end, { admin = true, csrf = true, session_only = true }))

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
        return guard.result(s3.delete_prefix(cfg, bucket, key))
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
    return { data = { removed = 1, bucket = bucket, path = path, name = name } }
end, { admin = true, csrf = true, session_only = true }))

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
end, { admin = true, csrf = true, session_only = true }))

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
