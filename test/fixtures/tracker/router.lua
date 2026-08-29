local ctxvar = require "klib.ctxvar"
local router = require("klib.router").new("/tracker")

local shared = ngx.shared.klib_test
shared:incr("router_module_loads", 1, 0)

router.pre_access = function(func, params, env)
    -- The current router invokes pre_access before resolving map.func.
    env.pre_access_func_is_nil = func == nil
    return false
end

router:get("/", function()
    return "ok"
end)

local function method_handler(params, env)
    return { method = env.method }
end

router:get("/method", method_handler)
router:head("/method", method_handler)
router:post("/method", method_handler)
router:put("/method", method_handler)
router:delete("/method", method_handler)
router:options("/method", method_handler)
router:patch("/method", method_handler)

router:post("/collect/:key", function(params, env)
    return { key = params.key, body = env.request_body, method = env.method }
end)

router:get("/day_uv/:key", function(params)
    return { key = params.key, list = { 1, 2, 3 } }
end)

router:get("/users/:id", function(params)
    return { route = "param", id = params.id }
end)

router:get("/users/me", function()
    return { route = "static", id = "me" }
end)

router:get("/pair/:left/fixed/:right", function(params)
    return { left = params.left, right = params.right }
end)

router:get("/query", function(params, env, req)
    return {
        query = req.get_query(),
        uri_args = env.uri_args,
        query_string = env.query_string,
        request_uri = env.request_uri,
    }
end)

router:post("/body", function(params, env, req)
    local body, header = req.get_body_header(env)
    return {
        body = body,
        helper_header_type = type(header),
        content_type = env.request_header["Content-Type"],
        is_json = env.is_json,
    }
end)

router:post("/api-body", function(params, env, req)
    local body, err = req.get_body(env)
    if not body then return { error = err }, 400 end
    return {
        body = body,
        csrf = req.get_header("X-CSRF-Token", env),
    }
end)

router:get("/context", function(params, env)
    local timer_seeded_ok, timer_env = pcall(ctxvar.new, { request_header = {} }, true)
    local timer_ngx_ok = false
    if timer_seeded_ok then
        timer_ngx_ok = ctxvar.get_ngx(timer_env).status == 200
    end

    return {
        same_env = ctxvar.new() == env,
        method = env.method,
        uri = env.uri,
        request_uri = env.request_uri,
        query_string = env.query_string,
        host = env.host,
        host_1 = env.host_1,
        host_2 = env.host_2,
        url = env.url,
        header = env.request_header["X-Klib-Test"],
        cookie = env.cookie.klib_cookie,
        ip = env.ip,
        formatted = ctxvar.format_var("$host:$method", env),
        normalized_path = ctxvar.normalize_url("/a//b///c"),
        normalized_absolute = ctxvar.normalize_url("http://example.test//a///b"),
        domain_1 = ctxvar.get_domain("l3.l2.example.com", 1),
        suffix = ctxvar.get_file_suffix("/asset/app.min.js?x=1"),
        pre_access_func_is_nil = env.pre_access_func_is_nil,
        timer_seeded_ok = timer_seeded_ok,
        timer_ngx_ok = timer_ngx_ok,
    }
end)

router:get("/asset.js", function(params, env)
    return { file_format = env.file_format, is_static = env.is_static }
end)

router:get("/template", function()
    return { name = "klib" }
end, "<h1>{{name}}</h1>")

router:get("/created", function()
    return { created = true }, 201
end)

router:get("/empty-created", function()
    return nil, 201
end)

router:get("/numeric-return", function()
    return 404
end)

router:get("/boom", function()
    error("router boom")
end)

router:get("/module-loads", function()
    return { loads = shared:get("router_module_loads") }
end)

local _, _, duplicate_error = router:get("/users/me", function()
    return "duplicate"
end)
local _, _, method_error = router:register("/trace", function()
    return "trace"
end, "TRACE")
local add_access_ok, add_access_error = pcall(function()
    router:add_access(function()
        return false
    end)
end)

local merge_ok, merge_count = router:merge(require("tracker.prometheus_router"), "/p")
local duplicate_child = require("klib.router").new("/duplicate")
duplicate_child:get("/metrics", function()
    return "duplicate"
end)
local duplicate_merge_ok, duplicate_merge_error = router:merge(duplicate_child, "/p")

router:get("/registration", function()
    return {
        duplicate_error = duplicate_error,
        method_error = method_error,
        add_access_ok = add_access_ok,
        add_access_error = tostring(add_access_error),
        merge_ok = merge_ok,
        merge_count = merge_count,
        duplicate_merge_ok = duplicate_merge_ok,
        duplicate_merge_error = duplicate_merge_error,
    }
end)

return router
