-- resty.authz.gateway.app_entry
-- 内置应用保留前缀入口（files / s3）在 /_authz/apps/ 静态 location 里的授权分支。
--
-- 网关入口（location /，gateway/access.lua）完成认证 + Casbin 后 internal
-- redirect 到 /_authz/apps/<page>；页面引用的 js/css 是**独立请求**，直接命中
-- ^~ /_authz/apps/，不再经过网关 resolver。为了让"被策略放行的 guest 也能把
-- 页面连资源一起加载出来"，这里对这些请求按同一端口对象复用同一套策略：
-- principal 对 "/<app 端口><uri>" enforce，语义与 access.lua 完全一致。
-- 判定只依赖 Host 首级标签与 config 表（外加真实凭证），客户端伪造不了。
local api_key = require "resty.authz.api_key"
local cache = require "resty.authz.gateway.cache"
local domain = require "resty.authz.domain"
local identity = require "resty.authz.identity"
local session = require "resty.authz.session"
local util = require "resty.authz.util"

local _M = {}
local escape_html = util.escape_html

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
        "</b> 无权访问 <code>" .. escape_html(object) .. "</code></p></body></html>")
    return ngx.exit(ngx.HTTP_FORBIDDEN)
end

--- 返回 true 表示"已放行，调用方直接 return"；false 表示"这不是应用入口域名，
--- 走原有管理页面鉴权"。内部拒绝（302/401/403）以 ngx.exit 结束请求。

-- 静态资源后缀白名单：入口域名下被策略放行的身份（尤其是拿到 /100/* 的 guest）
-- 只应能取到页面渲染所需的脚本/样式/字体/图标，**不得**顺带取到别的管理页 HTML
-- （users.html、authorization.html 等）。那些页面虽然只是外壳（数据要过 API 层
-- 的角色门），但把整个控制面骨架交给匿名策略是白送侦察面。后缀不在白名单内时
-- 返回 false，交回 location 原有的会话鉴权（普通 admin 带 Cookie 照常可访问）。
local STATIC_EXT = {
    [".js"] = true, [".mjs"] = true, [".css"] = true, [".map"] = true,
    [".svg"] = true, [".png"] = true, [".gif"] = true, [".jpg"] = true,
    [".jpeg"] = true, [".webp"] = true, [".ico"] = true, [".woff"] = true,
    [".woff2"] = true, [".ttf"] = true, [".otf"] = true, [".eot"] = true,
}

--- 入口域名下的请求是否属于「页面资源」：只看 URI 末段后缀，大小写不敏感。
local function static_asset(uri)
    local dot = uri:match("().[^%.]*$")
    if not dot then return false end
    return STATIC_EXT[uri:sub(dot):lower()] == true
end

function _M.handle_request(config)
    local entries = config and config.app_entries
    if not entries or next(entries) == nil then return false end
    local label = domain.first_label(ngx.var.host)
    if not label then return false end
    local prefix = label:match("^(.-)%-") or label
    local name = config.app_prefixes[prefix]
    if not name then return false end
    local entry = entries[name]
    if not entry then return false end
    local uri = ngx.var.uri or ""
    -- 入口页本身：gateway/access.lua 已认证 + 授权，并通过 ngx.var.authz_app_entry
    -- 把结果带过来（internal redirect 后 ngx.ctx 不保留，只能靠变量；该变量只有
    -- Lua 能写）。等值判断防"网关放行 files 却借道渲染别的页面"。
    if uri == "/_authz/apps/" .. entry.page and ngx.var.authz_app_entry == name then
        return true
    end
    -- 页面静态资源：同一套认证 + 同一端口对象；非资源后缀（其它管理页 HTML、
    -- 无后缀路径）不在这里放行，交回 location 原有的会话鉴权。
    if not static_asset(uri) then return false end
    local machine_request, current = api_key.authenticate_request()
    if not machine_request then
        local token = session.get_request_token()
        current = token and session.get(token) or nil
    end
    local principal, anonymous
    if current then
        principal = machine_request and current.identity or identity.key(current.source, current.username)
    elseif machine_request then
        return reject_unauthenticated(true)
    else
        principal = "role:guest"
        anonymous = true
    end
    local authorization = cache.ensure(config)
    local object = "/" .. entry.port .. uri
    if not authorization.enforcer:enforce(principal, object, ngx.req.get_method()) then
        if anonymous then return reject_unauthenticated(false) end
        return reject_forbidden(machine_request, principal, object)
    end
    return true
end

return _M
