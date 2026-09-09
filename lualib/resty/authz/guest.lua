-- resty.authz.guest
-- Guest 探针 /_authz/guest：以服务端视角回显「当前请求」的完整信息
-- （全部请求头、来源 IP、代理链与转发头），供 guest 角色访客或管理员
-- 调试接入链路（例如确认反代是否透传了真实客户端地址、上游实际收到的凭据头）。
--
-- guest 是匿名用户角色：默认能力就是这条探针（外加只回显自身身份的
-- GET /api/session）；管理员可以像配置其他角色一样，在策略里为
-- role:guest 追加可访问的代理目标范围。
--
-- 准入：携带 guest（或 admin）角色的 API Key（x-api-key），或以 guest/admin
-- 角色登录的浏览器会话；浏览器未登录时跳转 /_authz/login。
--
-- 安全约束：
--   * HTML 全部服务端渲染并逐字段 HTML 转义，不回显任何可执行内容；
--   * 响应禁止缓存（诊断内容与当次请求绑定，缓存等于跨请求泄露）。
--   * 调试需求：所有请求头（含 Cookie / Authorization / API Key）均明文
--     完整回显，因此该入口必须始终保持 guest/admin 角色门禁。

local cjson = require "cjson.safe"
local util = require "resty.authz.util"
local api_key = require "resty.authz.api_key"
local common = require "resty.authz.api.common"
local db = require "resty.authz.db"
local session = require "resty.authz.session"

local authz = require "resty.authz"

local _M = {}
local escape_html = util.escape_html
local function sorted_header_names(headers)
    local names = {}
    for name in pairs(headers) do
        if type(name) == "string" then names[#names + 1] = name end
    end
    table.sort(names, function(a, b) return string.lower(a) < string.lower(b) end)
    return names
end

-- realip_remote_addr 仅在 realip 模块编译且生效时可读；个别构建里读取会抛错，
-- 用 pcall 兜底为 remote_addr。
local function real_ip_or_remote()
    local ok, value = pcall(function() return ngx.var.realip_remote_addr end)
    if ok and value and value ~= "" then return value end
    return ngx.var.remote_addr or ""
end

-- 把 XFF 拆为代理链（第一项 = 客户端原始 IP，最后一项 = 上一跳代理）。
local function split_chain(value)
    local chain = {}
    for item in tostring(value or ""):gmatch("[^,]+") do
        item = item:match("^%s*(.-)%s*$")
        if item ~= "" then chain[#chain + 1] = item end
    end
    return chain
end

-- 结构化请求信息（JSON API 与 HTML 页共用）。
function _M.request_info()
    local headers = ngx.req.get_headers()
    local header_rows = {}
    for _, name in ipairs(sorted_header_names(headers)) do
        local raw = headers[name]
        local list = type(raw) == "table" and raw or { raw }
        for _, item in ipairs(list) do
            if type(item) ~= "string" then item = tostring(item) end
            header_rows[#header_rows + 1] = { name = name, value = item }
        end
    end

    local xff = split_chain(headers["x-forwarded-for"])
    local uri_args = ngx.req.get_uri_args(64) or {}

    return {
        ip = {
            remote_addr = ngx.var.remote_addr or "",
            server_addr = ngx.var.server_addr or "",
            server_port = tonumber(ngx.var.server_port) or 0,
            real_ip = real_ip_or_remote(),
        },
        proxy = {
            forwarded_for = headers["x-forwarded-for"] or "",
            forwarded_for_chain = xff,
            client_original_ip = xff[1] or "",
            last_hop = xff[#xff] or "",
            forwarded = headers["forwarded"] or "",
            forwarded_proto = headers["x-forwarded-proto"] or "",
            forwarded_host = headers["x-forwarded-host"] or "",
            forwarded_port = headers["x-forwarded-port"] or "",
            via = headers["via"] or "",
        },
        request = {
            method = ngx.req.get_method(),
            scheme = ngx.var.scheme or "",
            host = ngx.var.host or "",
            uri = ngx.var.request_uri or ngx.var.uri or "",
            server_protocol = ngx.var.server_protocol or "",
            args = uri_args,
        },
        headers = header_rows,
    }
end

-- 入口：/_authz/guest。认证在此内聚：
--   * 呈现 x-api-key：必须是合法 Key（数据库 Key 或环境变量 Key），无效直接
--     401，绝不回退 Cookie；
--   * 未呈现 Key：按浏览器会话处理，未登录跳登录页；
--   * 角色门禁：仅 guest / admin（会话角色实时查库，改角色立即生效）。
function _M.handle()
    db.open(authz.config.db_path)
    local presented, current = api_key.authenticate_request()
    if presented then
        if not current then
            ngx.status = ngx.HTTP_UNAUTHORIZED
            ngx.header["Content-Type"] = "application/json; charset=UTF-8"
            ngx.say(cjson.encode({ error = { code = "invalid_api_key", message = "API Key 无效或已禁用" } }))
            return ngx.exit(ngx.HTTP_UNAUTHORIZED)
        end
    else
        local token = session.get_request_token()
        current = token and session.get(token) or nil
        if not current then
            return ngx.redirect("/_authz/login?next=" ..
                ngx.escape_uri(ngx.var.request_uri or "/_authz/guest"),
                ngx.HTTP_MOVED_TEMPORARILY)
        end
    end

    -- 会话角色实时查库（common.roles_for），改角色立即生效。
    if not common.has_any_role(current, { "guest", "admin" }) then
        ngx.status = ngx.HTTP_FORBIDDEN
        local machine = presented or
            tostring(ngx.req.get_headers()["Accept"] or ""):find("application/json", 1, true) ~= nil
        if machine then
            ngx.header["Content-Type"] = "application/json; charset=UTF-8"
            ngx.say(cjson.encode({ error = { code = "forbidden", message = "仅 guest 角色可访问该页面" } }))
        else
            ngx.header["Content-Type"] = "text/html; charset=utf-8"
            ngx.say([[<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<title>403</title><body style="font-family:sans-serif;text-align:center;padding-top:80px">
<h1>403</h1><p>当前登录身份不是 guest 角色，无法访问该诊断页。</p>
<p><a href="/_authz/apps/">返回控制台</a></p></body></html>]])
        end
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end

    return _M.page()
end

local function row_html(label, value)
    if value == nil or value == "" then value = "—" end
    return "<tr><th>" .. escape_html(label) .. "</th><td>" .. escape_html(tostring(value)) .. "</td></tr>"
end

local function chain_html(list)
    if #list == 0 then return "—" end
    local parts = {}
    for index, item in ipairs(list) do
        parts[index] = escape_html(item)
    end
    return table.concat(parts, " <span class='arrow'>&rarr;</span> ")
end

local function header_table_html(rows)
    local lines = {}
    for _, row in ipairs(rows) do
        lines[#lines + 1] = "<tr><th>" .. escape_html(row.name) .. "</th><td>" ..
            escape_html(row.value) .. "</td></tr>"
    end
    if #lines == 0 then lines[1] = "<tr><td>—</td></tr>" end
    return table.concat(lines, "")
end

local function proxy_chain_html(list, raw)
    local html = chain_html(list)
    if raw ~= "" then
        html = html .. "<br><code>" .. escape_html(raw) .. "</code>"
    end
    return "<tr><th>X-Forwarded-For 代理链</th><td>" .. html .. "</td></tr>"
end

-- GET /_authz/guest —— server-side 渲染，不做任何客户端注入。
function _M.page()
    local info = _M.request_info()
    local args = info.request.args
    if tostring(args.json or "") == "1" then
        ngx.header["Content-Type"] = "application/json; charset=UTF-8"
        ngx.header["Cache-Control"] = "no-store"
        ngx.say(cjson.encode({ data = info }))
        return ngx.exit(ngx.HTTP_OK)
    end

    local html = [[<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Cache-Control" content="no-cache, no-store, must-revalidate">
<title>Guest 请求诊断</title>
<style>
:root{color-scheme:dark}
body{margin:0;padding:24px;background:#191b2b;color:#f1f2f8;font:14px/1.6 Roboto,system-ui,sans-serif}
main{max-width:960px;margin:0 auto}
h1{font-size:18px;margin:0 0 4px}
.sub{color:#a7abc6;margin:0 0 20px}
section{background:#202337;border:1px solid rgba(139,145,184,.18);border-radius:14px;padding:18px 20px;margin:0 0 16px}
h2{font-size:14px;margin:0 0 12px;color:#b7a6ff}
table{border-collapse:collapse;width:100%;table-layout:fixed}
th,td{text-align:left;vertical-align:top;padding:6px 10px;border-bottom:1px solid rgba(139,145,184,.12);word-break:break-all}
th{width:220px;color:#8f96b8;font-weight:500}
tr:last-child th,tr:last-child td{border-bottom:0}
.arrow{color:#6d7394}
code{background:rgba(139,145,184,.15);padding:1px 6px;border-radius:6px}
</style></head><body><main>
<h1>Guest 请求诊断</h1>
<p class="sub">以下信息来自网关收到的<b>本次请求</b>本身（服务端视角）。全部请求头均明文回显（该入口仅限 guest/admin 角色）。</p>
<section><h2>来源 IP</h2><table>
]] .. row_html("TCP 来源地址 (remote_addr)", info.ip.remote_addr)
    .. row_html("网关解析的真实客户端 (real_ip)", info.ip.real_ip)
    .. row_html("网关接收地址 (server_addr:port)", info.ip.server_addr .. ":" .. info.ip.server_port)
    .. [[</table></section>
<section><h2>代理 / 转发来源</h2><table>
]] .. proxy_chain_html(info.proxy.forwarded_for_chain, info.proxy.forwarded_for)
    .. row_html("Forwarded", info.proxy.forwarded)
    .. row_html("X-Forwarded-Proto", info.proxy.forwarded_proto)
    .. row_html("X-Forwarded-Host", info.proxy.forwarded_host)
    .. row_html("X-Forwarded-Port", info.proxy.forwarded_port)
    .. row_html("Via", info.proxy.via)
    .. [[</table></section>
<section><h2>请求行</h2><table>
]] .. row_html("方法 / 协议", info.request.method .. " " .. info.request.server_protocol)
    .. row_html("协议 (scheme)", info.request.scheme)
    .. row_html("Host", info.request.host)
    .. row_html("请求 URI", info.request.uri)
    .. [[</table></section>
<section><h2>全部请求头</h2><table>
]] .. header_table_html(info.headers)
    .. [[</table></section>
</main></body></html>]]

    ngx.header["Cache-Control"] = "no-store"
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.say(html)
    return ngx.exit(ngx.HTTP_OK)
end

return _M
