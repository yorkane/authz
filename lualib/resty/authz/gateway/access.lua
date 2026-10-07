local api_key = require "resty.authz.api_key"
local cache = require "resty.authz.gateway.cache"
local db = require "resty.authz.db"
local identity = require "resty.authz.identity"
local proxy = require "resty.authz.gateway.proxy"
local resolver = require "resty.authz.gateway.resolver"
local session = require "resty.authz.session"
local target = require "resty.authz.target"
local util = require "resty.authz.util"
local app_content = require "resty.authz.gateway.app_content"

local _M = {}
local escape_html = util.escape_html

local function serve_not_found(host)
    ngx.status = ngx.HTTP_NOT_FOUND
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say([[<!doctype html><html lang="zh"><head><meta charset="utf-8">
<title>404</title><style>body{font-family:sans-serif;background:#f4f6f8;
display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
.box{text-align:center}.box h1{font-size:64px;margin:0;color:#94a3b8}</style></head>
<body><div class="box"><h1>404</h1><p>未找到 <b>]] .. escape_html(host or "") .. [[</b> 对应的服务</p>
<p style="color:#888">用法: <code>&lt;端口&gt;-任意域名</code> 访问本机对应端口<br>
或 <a href="/_authz/">登录控制台</a> 配置域名绑定</p></div></body></html>]])
    return ngx.exit(ngx.HTTP_OK)
end

local function prevent_loop(target_ip, port)
    local server_ip = target.normalize_ip(ngx.var.server_addr)
    if tonumber(ngx.var.server_port) ~= port or
        (not target.is_loopback(target_ip) and (not server_ip or server_ip ~= target_ip)) then
        return false
    end
    ngx.status = 508
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say([[<!doctype html><html lang="zh"><head><meta charset="utf-8">
<title>508 Loop Detected</title></head><body style="font-family:sans-serif;text-align:center;padding-top:80px">
<h1>508</h1><p>目标 ]] .. escape_html(target_ip) .. ":" .. escape_html(port) .. [[ 是网关自身监听地址，已阻止循环代理。</p>
<p>管理界面请访问 <code>/_authz/apps/</code>。</p></body></html>]])
    ngx.exit(508)
    return true
end

local function authenticate()
    local key_presented, current = api_key.authenticate_request()
    if not key_presented then
        local token = session.get_request_token()
        current = token and session.get(token) or nil
    end
    return key_presented, current
end

local function reject_unauthenticated(machine_request)
    if machine_request then
        ngx.status = ngx.HTTP_UNAUTHORIZED
        ngx.header.content_type = "application/json; charset=UTF-8"
        ngx.say('{"error":{"code":"invalid_api_key","message":"API key is invalid or disabled"}}')
        return ngx.exit(ngx.HTTP_UNAUTHORIZED)
    end
    ngx.status = ngx.HTTP_MOVED_TEMPORARILY
    ngx.header["Location"] = "/_authz/login?next=" .. ngx.escape_uri(ngx.var.request_uri or "/")
    return ngx.exit(ngx.HTTP_MOVED_TEMPORARILY)
end

local function reject_forbidden(machine_request, principal, object)
    ngx.status = ngx.HTTP_FORBIDDEN
    if machine_request then
        ngx.header.content_type = "application/json; charset=UTF-8"
        ngx.say('{"error":{"code":"forbidden","message":"API role is not allowed to access this target"}}')
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say("<html><body style='font-family:sans-serif;text-align:center;padding-top:80px'>" ..
        "<h1>403</h1><p>身份 <b>" .. escape_html(principal or "invalid") ..
        "</b> 无权访问 <code>" .. escape_html(object) .. "</code></p>" ..
        "<p><a href='/_authz/'>控制台</a></p></body></html>")
    return ngx.exit(ngx.HTTP_FORBIDDEN)
end

function _M.handle(config)
    db.open(config.db_path)
    local host = ngx.var.host
    local port, _, target_ip, binding = resolver.resolve(host, config)
    if not port then return serve_not_found(host) end
    -- 内置应用保留前缀入口不代理上游（目标是网关自己的页面），没有循环风险。
    if not (binding and binding.app) and prevent_loop(target_ip, port) then return end

    local machine_request, current = authenticate()
    local authorization = cache.ensure(config)
    local object = "/" .. port .. (ngx.var.uri or "")
    local principal, anonymous
    if current then
        principal = machine_request and current.identity or identity.key(current.source, current.username)
    elseif machine_request then
        -- 呈现了 Key 但无效：绝不回退匿名身份（保持 401，不泄露"匿名也能进"的边界）。
        return reject_unauthenticated(true)
    else
        -- guest 就是匿名用户：无凭证请求以 role:guest 主体参与授权。
        -- 默认拒绝不变——只有管理员显式给 role:guest 放行过的目标才对匿名开放；
        -- 未命中策略时仍引导登录（也许换个身份就有权限）。
        principal = "role:guest"
        anonymous = true
    end
    if not authorization.enforcer:enforce(principal, object, ngx.req.get_method()) then
        if anonymous then return reject_unauthenticated(false) end
        return reject_forbidden(machine_request, principal, object)
    end

    ngx.var.authz_user = current and current.username or "guest"
    ngx.var.authz_source = current and current.source or "anonymous"
    ngx.var.authz_identity = principal
    if binding and binding.app then
        -- 保留前缀入口：认证 + Casbin（object 仍是 /<端口><uri>，这就是"单独
        -- 配置授权"的落点）都通过后，直接渲染内置应用页面。internal redirect
        -- 之后 ngx.ctx 不保留，跨 location 只能靠 ngx.var：authz_app_entry 由
        -- Lua 写入，客户端伪造不了，/_authz/apps/ 的三个 location 据此放行
        -- 「URI 精确等于入口页」的请求（详见 conf/server.conf.template）。
        --
        -- 内容出口：带子路径的 GET/HEAD 请求（非根、非 /_authz/ 命名空间）改道
        -- 到 /_authz/files/ 或 /_authz/s3/ 真正吐文件/对象字节；根路径与 /_authz/
        -- 前缀仍交回这里渲染入口页。分流细节见 gateway/app_content.lua——它复用
        -- 上面这次 Casbin（object 含完整路径，可做目录级分级），并以 Lua-only 变量
        -- authz_app_content 通知内容 location 免二次鉴权。binding.app 全程不改，
        -- 否则会撞上面 prevent_loop 的 508。
        if app_content.handle(binding, config) ~= false then return end
        ngx.var.authz_app_entry = binding.app
        ngx.req.set_uri("/_authz/apps/" .. binding.app_page, false)
        return ngx.exec("/_authz/apps/" .. binding.app_page)
    end
    local scheme = proxy.prepare(binding, target_ip, port)
    if scheme == "https" and binding and binding.upstream_ssl_verify == false then
        return ngx.exec("@authz_proxy_insecure")
    end
end

return _M
