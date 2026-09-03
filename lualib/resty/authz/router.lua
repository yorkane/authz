--- Unified /_authz control-plane router.
-- One klib.router("/_authz") serves the login/OAuth HTML pages and every
-- JSON management API under /api/*, registered at module load time.

local cjson = require "cjson.safe"
local guard = require "resty.authz.api.guard"
local service = require "resty.authz.api.service"
local session = require "resty.authz.session"
local ui = require "resty.authz.ui"
local files = require "resty.authz.files"

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

-- ── Session ─────────────────────────────────────────────────────────────────
register("GET", "/api/session", guard.wrap(function(_, _, _, current)
    return { data = service.session_payload(current) }
end))

register("DELETE", "/api/session", guard.wrap(function(_, _, _, _, token)
    session.delete(token)
    session.clear_cookie()
    return { data = { message = "已退出登录" } }
end, { csrf = true, session_only = true }))

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

register("POST", "/api/menu-entries", guard.wrap(with_body(function(_, data)
    return service.create_menu_entry(data)
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
local function error_handler(ctx, status, _, _, _)
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
