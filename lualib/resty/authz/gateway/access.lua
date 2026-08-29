local api_key = require "resty.authz.api_key"
local cache = require "resty.authz.gateway.cache"
local db = require "resty.authz.db"
local identity = require "resty.authz.identity"
local proxy = require "resty.authz.gateway.proxy"
local resolver = require "resty.authz.gateway.resolver"
local session = require "resty.authz.session"
local target = require "resty.authz.target"
local util = require "resty.authz.util"

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
    if prevent_loop(target_ip, port) then return end

    local machine_request, current = authenticate()
    if not current then return reject_unauthenticated(machine_request) end
    local authorization = cache.ensure(config)
    local object = "/" .. port .. (ngx.var.uri or "")
    local principal = machine_request and current.identity or identity.key(current.source, current.username)
    if not principal or not authorization.enforcer:enforce(principal, object, ngx.req.get_method()) then
        return reject_forbidden(machine_request, principal, object)
    end

    ngx.var.authz_user = current.username
    ngx.var.authz_source = current.source
    ngx.var.authz_identity = principal
    local scheme = proxy.prepare(binding, target_ip, port)
    if scheme == "https" and binding and binding.upstream_ssl_verify == false then
        return ngx.exec("@authz_proxy_insecure")
    end
end

return _M
