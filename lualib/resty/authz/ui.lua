-- Authz login/OAuth HTML pages served by the unified /_authz router.

local authz = require "resty.authz"
local db = require "resty.authz.db"
local users = require "resty.authz.repository.users"
local nocobase = require "resty.authz.nocobase"
local oauth = require "resty.authz.oauth"
local session = require "resty.authz.session"
local util = require "resty.authz.util"

local _M = {}
local escape_html = util.escape_html

local oauth_brands = {
    nocobase = {
        class = "brand-nocobase",
        icon = [[<img class="brand-icon nocobase-icon" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAC30lEQVRYR73XW6hVVRQG4O9k0cUoFQrJiowCkwTJF8N6yQcj6KHIkii6KIEm5t0uRISGWml2QaIoSnoJpAgi8aGoXsLozUAisiiqh5AoocAo44e5YLvZe6+59/GcCRs2a405/n+NOcc/xhhzetYFeBaXYhOO1LodqzUcYHcT1uFJ/ITncRh78F+b//EQOA/P4C88jRMdYHfirhKNo4NIjErgejxRCHzRB2AmduNTvI6TveyGJXA2nsK5hUC+vm3tLPZrxktgPrbiBXzShoop2ICrcQaWj0rgTGzBZdiMPyvAr8Jz2If38QpWj0JgDhLCnOGHFcA50lVYiPX4rewZicD9WIy1OFYBfjl24QO802U/NIErsB+/lhT7qoVAyN5czvznHrZDEVhR0idfPQ87SgS24Z8u50m1fPVng1Kt9g5cUpzcUkB+wOzyfwkexuP4ujxbimXYiO9bItQagbvxMmZ0OOokkMfTys0OWG555PbFGrlti8C7iHR2r24CzfvtOIDPKy5mTKaWS3kH/u3ek7TpKZHoR+ARfIRvKwgswlslYodwH77p3DdRBCLZUc1oQRSxWX/jMbzUfPhEELgOb+PaARFKgXogUT6dBCLZqZD5nVVxPMfTRwwiEB85vyjhHx0Oe92BuUX3F1QAn2LSRiDGP+JBfFx2dhJIlcs557zPGRY89jUEYpdM2VuqYpQyWZB2KxG6YRTgZk8tgcY+qfclfsFKnD8e8GEiMF6cvvsTgTQN904YQovjpie8Ha/ioskm0tmUXlxI3DaZJHp1xfcUqZw+GUT6teWz8AbSB9SuVLqoW8p27fpu0FyQdw+VUast3ZKeqXTpFV7DrS0Moiux21gzmFxZBOfGHk7jKN3Oo2VEa0xSaDI/XNhjT3rGzAgHGx2oCVckNzUhs2AjuZHoAPUbUtIlv1k66wYj3XImpN87lbCGQGNzTSm1accyEbcNKYlweslMSPm91w32P9FanGOjb4sgAAAAAElFTkSuQmCC">]],
    },
    google = {
        class = "brand-google",
        icon = [[<svg class="brand-icon" aria-hidden="true" viewBox="0 0 24 24"><path d="M12.48 10.92v3.28h7.84c-.24 1.84-.853 3.187-1.787 4.133-1.147 1.147-2.933 2.4-6.053 2.4-4.827 0-8.6-3.893-8.6-8.72s3.773-8.72 8.6-8.72c2.6 0 4.507 1.027 5.907 2.347l2.307-2.307C18.747 1.44 16.133 0 12.48 0 5.867 0 .307 5.387.307 12s5.56 12 12.173 12c3.573 0 6.267-1.173 8.373-3.36 2.16-2.16 2.84-5.213 2.84-7.667 0-.76-.053-1.467-.173-2.053H12.48z"/></svg>]],
    },
    dingtalk = {
        class = "brand-dingtalk",
        icon = [[<svg class="brand-icon" aria-hidden="true" viewBox="64 64 896 896"><path d="M573.7 252.5C422.5 197.4 201.3 96.7 201.3 96.7c-15.7-4.1-17.9 11.1-17.9 11.1-5 61.1 33.6 160.5 53.6 182.8 19.9 22.3 319.1 113.7 319.1 113.7S326 357.9 270.5 341.9c-55.6-16-37.9 17.8-37.9 17.8 11.4 61.7 64.9 131.8 107.2 138.4 42.2 6.6 220.1 4 220.1 4s-35.5 4.1-93.2 11.9c-42.7 5.8-97 12.5-111.1 17.8-33.1 12.5 24 62.6 24 62.6 84.7 76.8 129.7 50.5 129.7 50.5 33.3-10.7 61.4-18.5 85.2-24.2L565 743.1h84.6L603 928l205.3-271.9H700.8l22.3-38.7c.3.5.4.8.4.8S799.8 496.1 829 433.8l.6-1h-.1c5-10.8 8.6-19.7 10-25.8 17-71.3-114.5-99.4-265.8-154.5z"/></svg>]],
    },
    wechat = {
        class = "brand-wechat",
        icon = [[<svg class="brand-icon" aria-hidden="true" viewBox="0 0 24 24"><path d="M8.691 2.188C3.891 2.188 0 5.476 0 9.53c0 2.212 1.17 4.203 3.002 5.55a.59.59 0 0 1 .213.665l-.39 1.48c-.019.07-.048.141-.048.213 0 .163.13.295.29.295a.326.326 0 0 0 .167-.054l1.903-1.114a.864.864 0 0 1 .717-.098 10.16 10.16 0 0 0 2.837.403c.276 0 .543-.027.811-.05-.857-2.578.157-4.972 1.932-6.446 1.703-1.415 3.882-1.98 5.853-1.838-.576-3.583-4.196-6.348-8.596-6.348zM5.785 5.991c.642 0 1.162.529 1.162 1.18a1.17 1.17 0 0 1-1.162 1.178A1.17 1.17 0 0 1 4.623 7.17c0-.651.52-1.18 1.162-1.18zm5.813 0c.642 0 1.162.529 1.162 1.18a1.17 1.17 0 0 1-1.162 1.178 1.17 1.17 0 0 1-1.162-1.178c0-.651.52-1.18 1.162-1.18zm5.34 2.867c-1.797-.052-3.746.512-5.28 1.786-1.72 1.428-2.687 3.72-1.78 6.22.942 2.453 3.666 4.229 6.884 4.229.826 0 1.622-.12 2.361-.336a.722.722 0 0 1 .598.082l1.584.926a.272.272 0 0 0 .14.047c.134 0 .24-.111.24-.247 0-.06-.023-.12-.038-.177l-.327-1.233a.582.582 0 0 1-.023-.156.49.49 0 0 1 .201-.398C23.024 18.48 24 16.82 24 14.98c0-3.21-2.931-5.837-6.656-6.088V8.89c-.135-.01-.27-.027-.407-.03zm-2.53 3.274c.535 0 .969.44.969.982a.976.976 0 0 1-.969.983.976.976 0 0 1-.969-.983c0-.542.434-.982.97-.982zm4.844 0c.535 0 .969.44.969.982a.976.976 0 0 1-.969.983.976.976 0 0 1-.969-.983c0-.542.434-.982.969-.982z"/></svg>]],
    },
}

local default_oauth_brand = {
    class = "brand-oauth",
    icon = [[<svg class="brand-icon" aria-hidden="true" viewBox="0 0 24 24"><path d="M12 2a5 5 0 0 0-5 5v2H6a3 3 0 0 0-3 3v7a3 3 0 0 0 3 3h12a3 3 0 0 0 3-3v-7a3 3 0 0 0-3-3h-1V7a5 5 0 0 0-5-5zm-3 7V7a3 3 0 0 1 6 0v2H9zm3 4a2 2 0 0 1 1 3.73V19h-2v-2.27A2 2 0 0 1 12 13z"/></svg>]],
}

local function disable_cache()
    ngx.header["Cache-Control"] = "no-store, no-cache, must-revalidate"
    ngx.header["Pragma"] = "no-cache"
    ngx.header["Expires"] = "0"
end

local function sleep_seconds(seconds)
    ngx.sleep(seconds)
end

local function redirect(location)
    disable_cache()
    return ngx.redirect(location, ngx.HTTP_MOVED_TEMPORARILY)
end

local function current_session()
    local token = session.get_request_token()
    return token and session.get(token) or nil
end

local function safe_next(value)
    value = tostring(value or "")
    if #value <= 2048 and value:sub(1, 1) == "/" and value:sub(2, 2) ~= "/" and
        not value:find("\\", 1, true) and not value:find("%c") then
        return value
    end
    return "/_authz/apps/"
end

local function html_response(body, status)
    ngx.status = status or ngx.HTTP_OK
    disable_cache()
    ngx.header.content_type = "text/html; charset=utf-8"
    ngx.say(body)
    return ngx.exit(ngx.status)
end

local function session_create_error(context, err)
    ngx.log(ngx.ERR, context, ": ", tostring(err))
    if err == "shared_session_read_only" then
        return html_response(
            "<h1>此实例仅提供共享会话读取</h1><p>请在认证主实例完成登录。</p>",
            ngx.HTTP_SERVICE_UNAVAILABLE)
    end
    return html_response("<h1>会话创建失败</h1>", ngx.HTTP_INTERNAL_SERVER_ERROR)
end

local function login_page(error_message, next_url)
    local error_html = error_message and
        ("<div class='error'>" .. escape_html(error_message) .. "</div>") or ""
    local provider_links = {}
    for _, provider in ipairs(oauth.public_providers()) do
        local brand = oauth_brands[provider.id] or default_oauth_brand
        local content = brand.icon .. [[<span class="oauth-name">]] ..
            escape_html(provider.title) .. [[</span>]]
        if provider.enabled then
            provider_links[#provider_links + 1] = [[<a class="oauth ]] .. brand.class ..
                [[" aria-label="]] .. escape_html(provider.title) ..
                [[" href="/_authz/oauth/start?provider=]] .. ngx.escape_uri(provider.id) ..
                [[&amp;next=]] .. ngx.escape_uri(next_url) .. [[">]] .. content .. [[</a>]]
        else
            provider_links[#provider_links + 1] = [[<span class="oauth ]] .. brand.class ..
                [[ disabled" aria-label="]] .. escape_html(provider.title .. "（待配置）") ..
                [[" title="需要配置 OAuth Client ID、Secret 和回调地址">]] .. content ..
                [[<small>待配置</small></span>]]
        end
    end
    local oauth_html = #provider_links > 0 and
        ([[<section class="login-panel oauth-panel"><h2>关联登录</h2>
<p class="panel-copy">使用已关联的身份服务继续登录</p><div class="oauth-grid">]] ..
            table.concat(provider_links) .. [[</div></section>]]) or ""
    local source_html = ""
    if authz.config.noco_enabled then
        source_html = [[<label class="field"><span>身份来源</span><select name="source">
<option value="local">本地账户</option><option value="nocobase">NocoBase</option>
</select></label>]]
    end
    return [[<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>登录</title><style>
:root{color-scheme:dark}*{box-sizing:border-box}body{display:grid;min-height:100vh;margin:0;padding:16px;place-items:center;background:#191b2b;color:#f1f2f8;font:14px Roboto,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
.card{width:min(720px,calc(100vw - 32px));padding:28px;border:1px solid rgba(139,145,184,.18);border-radius:16px;background:#202337;box-shadow:0 24px 70px rgba(5,7,18,.35)}
h1{margin:0 0 6px;font-size:22px;font-weight:600}.copy{margin:0 0 22px;color:#969aaf}.login-layout{display:grid;grid-template-columns:1fr 1fr;gap:0}.login-panel{min-width:0;padding-right:28px}.oauth-panel{padding:0 0 0 28px;border-left:1px solid rgba(139,145,184,.18)}h2{margin:0 0 6px;font-size:16px;font-weight:600}.panel-copy{min-height:20px;margin:0 0 14px;color:#969aaf;line-height:1.45}.field{display:grid;gap:7px;margin-top:14px}input,select{width:100%;height:42px;padding:0 12px;border:1px solid rgba(139,145,184,.28);border-radius:10px;outline:none;background:#191c2d;color:#fff}input:focus,select:focus{border-color:#9564ed}button,.oauth{width:100%;min-height:46px;padding:9px 12px;border:0;border-radius:11px;color:#fff;font-weight:600;line-height:1.25;cursor:pointer;text-align:center;text-decoration:none}.password-submit{display:grid;margin-top:20px;place-items:center;background:linear-gradient(135deg,#9564ed,#7356d8)}.oauth-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}.oauth{display:flex;align-items:center;justify-content:center;gap:9px;border:1px solid transparent;background:#7654d8;box-shadow:0 6px 18px rgba(0,0,0,.14);transition:transform .16s ease,filter .16s ease,box-shadow .16s ease}.oauth:hover{filter:brightness(1.08);transform:translateY(-1px);box-shadow:0 9px 22px rgba(0,0,0,.2)}.brand-icon{width:20px;height:20px;flex:0 0 20px;fill:currentColor}.nocobase-icon{object-fit:contain;filter:invert(1)}.oauth-name{white-space:nowrap}.oauth small{font-size:10px;font-weight:500;opacity:.72}.brand-nocobase{background:#6f56d9}.brand-google{background:#fff;color:#202124}.brand-google .brand-icon{fill:#4285f4}.brand-dingtalk{background:#1677ff}.brand-wechat{background:#07c160}.brand-oauth{background:#7654d8}.oauth.disabled{cursor:not-allowed;filter:saturate(.45);opacity:.48}.oauth.disabled:hover{filter:saturate(.45);transform:none;box-shadow:0 6px 18px rgba(0,0,0,.14)}.error{margin-bottom:18px;padding:10px 12px;border:1px solid rgba(240,107,130,.25);border-radius:9px;background:rgba(240,107,130,.1);color:#ffb4c0}@media(max-width:680px){.card{padding:22px}.login-layout{grid-template-columns:1fr;gap:24px}.login-panel{padding-right:0}.oauth-panel{padding:24px 0 0;border-top:1px solid rgba(139,145,184,.18);border-left:0}}@media(max-width:420px){.oauth-grid{grid-template-columns:1fr}}
</style></head><body><main class="card"><h1>登录</h1><p class="copy">OpenResty 认证与权限管理</p>]] ..
        error_html .. [[<div class="login-layout"><section class="login-panel"><h2>账户登录</h2>
<p class="panel-copy">使用本地或远程账户密码登录</p><form method="post" action="/_authz/login">
<input type="hidden" name="next" value="]] .. escape_html(next_url) .. [[">
]] .. source_html .. [[
<label class="field"><span>用户名</span><input name="username" autocomplete="username" autofocus required></label>
<label class="field"><span>密码</span><input name="password" type="password" autocomplete="current-password" required></label>
<button class="password-submit" type="submit">登录</button></form></section>]] .. oauth_html .. [[</div></main></body></html>]]
end

function _M.login_get()
    db.open(authz.config.db_path)
    if current_session() then return redirect("/_authz/apps/") end
    local args = ngx.req.get_uri_args(10)
    local error_message = type(args.err) == "string" and args.err or nil
    local next_url = type(args.next) == "string" and safe_next(args.next) or "/_authz/apps/"
    if error_message and #error_message > 256 then error_message = "登录失败" end
    return html_response(login_page(error_message, next_url))
end

function _M.login_post()
    db.open(authz.config.db_path)
    ngx.req.read_body()
    local args = ngx.req.get_post_args() or {}
    local account = tostring(args.username or "")
    local username = account:lower():gsub("%s+", "")
    local password = tostring(args.password or "")
    local source = tostring(args.source or "local"):lower()
    -- 按「账户名 + 来源 IP」计数与锁定：只锁被攻击的账户组合，
    -- 不影响同一 IP 下其他账户的正常登录。
    local limit_dict = ngx.shared[authz.config.login_limit_dict]
    local lock_scope = (username ~= "" and username or "_") ..
        "@" .. tostring(ngx.var.remote_addr or "unknown")
    local limit_key = "login:" .. lock_scope
    local lock_key = "lock:" .. lock_scope
    if limit_dict and limit_dict:get(lock_key) then
        return html_response("<h1>429 Too Many Requests</h1><p>该账户登录失败次数过多，已被临时锁定，请 30 分钟后再试。</p>",
            ngx.HTTP_TOO_MANY_REQUESTS)
    end

    -- 登录失败统一处理：延迟返回（防暴力枚举计时探测）并累计失败次数；
    -- 窗口内达到阈值后锁定该账户组合，锁定期内不再尝试认证。
    local function login_failed(message)
        sleep_seconds(authz.config.login_fail_delay_ms / 1000)
        if limit_dict then
            local attempts = limit_dict:incr(limit_key, 1, 0, authz.config.login_window)
            if attempts and attempts >= authz.config.login_attempts then
                limit_dict:set(lock_key, os.time(), authz.config.login_window)
                return html_response("<h1>429 Too Many Requests</h1><p>该账户连续登录失败次数过多，已被临时锁定，请 30 分钟后再试。</p>",
                    ngx.HTTP_TOO_MANY_REQUESTS)
            end
        end
        return redirect("/_authz/login?err=" .. ngx.escape_uri(message) ..
            "&next=" .. ngx.escape_uri(args.next or ""))
    end

    local identity
    if source == "local" then
        local user = users.credentials(username)
        if user and user.enabled == 1 and
            util.verify_password(password, user.salt, user.password_hash) then
            local ok, update_err = users.record_login(username, os.time())
            if not ok then
                ngx.log(ngx.ERR, "authz local login timestamp failed: ", update_err)
                return html_response("<h1>登录状态保存失败</h1>", ngx.HTTP_INTERNAL_SERVER_ERROR)
            end
            identity = { username = username, source = "local" }
        end
    elseif source == "nocobase" and authz.config.noco_enabled then
        local remote, remote_err = nocobase.authenticate(account, password)
        if remote then
            identity = remote
        elseif remote_err == "identity_disabled" then
            return login_failed("账户未启用，请联系管理员")
        elseif remote_err ~= "invalid_credentials" then
            ngx.log(ngx.ERR, "authz NocoBase login failed: ", remote_err)
            return login_failed("远程认证服务暂时不可用")
        end
    else
        return login_failed("身份来源不受支持")
    end
    if not identity then
        return login_failed("用户名或密码错误")
    end
    if limit_dict then
        limit_dict:delete(limit_key)
        limit_dict:delete(lock_key)
    end
    local token, err = session.create(identity.username, identity.source)
    if not token then
        return session_create_error("authz session create failed", err)
    end
    session.set_cookie(token)
    return redirect(safe_next(args.next))
end

function _M.oauth_start()
    db.open(authz.config.db_path)
    if current_session() then return redirect("/_authz/apps/") end
    local location, err = oauth.start(
        tostring(ngx.var.arg_provider or ""), safe_next(ngx.var.arg_next))
    if not location then
        ngx.log(ngx.WARN, "authz OAuth start rejected: ", err)
        return redirect("/_authz/login?err=" .. ngx.escape_uri("身份登录配置不可用"))
    end
    return redirect(location)
end

function _M.oauth_callback()
    db.open(authz.config.db_path)
    local args = ngx.req.get_uri_args() or {}
    local identity, next_or_err = oauth.callback(args)
    if not identity then
        ngx.log(ngx.WARN, "authz OAuth callback failed: ", next_or_err)
        local message = next_or_err == "identity_disabled" and
            "账户未启用，请联系管理员" or "身份登录失败，请重试"
        return redirect("/_authz/login?err=" .. ngx.escape_uri(message))
    end

    local token, err = session.create(identity.username, identity.source)
    if not token then
        return session_create_error("authz OAuth session create failed", err)
    end
    session.set_cookie(token)
    return redirect(safe_next(next_or_err))
end

return _M
