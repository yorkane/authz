local target = require "resty.authz.target"
local rewrite = require "resty.authz.gateway.rewrite"

local _M = {}

local function authority_port(authority)
    authority = tostring(authority or "")
    return tonumber(authority:match("^%[[^%]]+%]:(%d+)$") or authority:match("^[^:]+:(%d+)$"))
end

local function forwarded_for()
    local existing = tostring(ngx.var.http_x_forwarded_for or "")
    local remote = tostring(ngx.var.remote_addr or "")
    if existing == "" then return remote end
    if remote == "" then return existing end
    return existing .. ", " .. remote
end

local function upstream_cookie()
    local filtered = {}
    for part in tostring(ngx.var.http_cookie or ""):gmatch("[^;]+") do
        local item = part:match("^%s*(.-)%s*$")
        local name = item:match("^([^=]*)") or ""
        name = name:match("^%s*(.-)%s*$")
        if name ~= "authz_session" and item ~= "" then
            filtered[#filtered + 1] = item
        end
    end
    return table.concat(filtered, "; ")
end

-- 请求改写是否显式设置了某个请求头（大小写不敏感）。用于判断网关自动
-- 声明（如正文改写的 Accept-Encoding: identity）是否应让位于用户配置。
local function request_sets_header(binding, lower_name)
    local rr = binding and binding.request_rewrite
    for _, header in ipairs(rr and rr.headers or {}) do
        if tostring(header.name or ""):lower() == lower_name then return true end
    end
    return false
end

local function apply_headers(binding, target_ip, port)
    binding = binding or {}
    local target_authority = target.url_host(target_ip) .. ":" .. tostring(port)
    local request_host = target.normalize_authority(ngx.var.authz_forwarded_host, true)
    if not request_host or request_host == "" then
        request_host = target.normalize_authority(ngx.var.http_host, true)
    end
    if not request_host or request_host == "" then request_host = target_authority end
    local simulate_local = binding.simulate_local == true
    local upstream_host = binding.upstream_host or ""
    if upstream_host == "" then upstream_host = simulate_local and target_authority or request_host end
    local forwarded_host = binding.forwarded_host or ""
    if forwarded_host == "" then forwarded_host = upstream_host end
    local forwarded_proto = binding.forwarded_proto or ""
    if forwarded_proto == "" then
        forwarded_proto = simulate_local and "http" or tostring(ngx.var.scheme or "http")
    end
    local forwarded_port = tonumber(binding.forwarded_port) or 0
    if forwarded_port < 1 or forwarded_port > 65535 then
        forwarded_port = authority_port(forwarded_host) or
            (simulate_local and port or (forwarded_proto == "https" and 443 or 80))
    end
    local incoming_origin = tostring(ngx.var.http_origin or "")
    local origin_mode = binding.origin_mode or "auto"
    local origin
    if origin_mode == "remove" then
        origin = ""
    elseif origin_mode == "custom" then
        origin = binding.custom_origin or ""
    elseif origin_mode == "rewrite" or (origin_mode == "auto" and simulate_local) then
        origin = incoming_origin ~= "" and (forwarded_proto .. "://" .. forwarded_host) or ""
    else
        origin = incoming_origin
    end
    ngx.var.authz_upstream_host = upstream_host
    ngx.var.authz_proxy_forwarded_host = forwarded_host
    ngx.var.authz_forwarded_proto = forwarded_proto
    ngx.var.authz_forwarded_port = tostring(forwarded_port)
    ngx.var.authz_origin = origin
    -- The gateway session is a bearer credential scoped to the gateway.  It
    -- must never cross the upstream trust boundary; unrelated app cookies are
    -- preserved for applications that maintain their own sessions.
    ngx.var.authz_upstream_cookie = upstream_cookie()
    if simulate_local then
        ngx.var.authz_real_ip = binding.local_ip or "127.0.0.1"
        ngx.var.authz_forwarded_for = binding.local_ip or "127.0.0.1"
        ngx.var.authz_forwarded = ""
    else
        ngx.var.authz_real_ip = tostring(ngx.var.remote_addr or "")
        ngx.var.authz_forwarded_for = forwarded_for()
        ngx.var.authz_forwarded = tostring(ngx.var.http_forwarded or "")
    end
    -- 请求改写（request_rewrite）：删除与设置都在转发前生效。删除先于设置，
    -- 同一头既删又设时以「保留设置」为准（set 显式表达了最终意图）；
    -- 而 set 之后不再做删除检查，避免配置错误导致删不掉自己刚写进去的头。
    -- Host/Cookie/X-Authz-*/X-Forwarded-* 等由 proxy_set_header 显式控制，
    -- 校验层与缓存层双重禁止改写，这里直接应用缓存里已过滤的结构。
    local rr = binding.request_rewrite
    if rr then
        for _, name in ipairs(rr.remove_headers or {}) do
            ngx.req.clear_header(name)
        end
        for _, header in ipairs(rr.headers or {}) do
            ngx.req.set_header(header.name, header.value)
        end
    end
    -- 正文改写只能在未压缩的字节上进行：上游看到 Accept-Encoding 就会自行压缩，
    -- 压缩字节无法做文本替换（网关会跳过并标记 skipped=encoded）。因此当绑定
    -- 配置了正文改写时，向上游声明不接受压缩；「改写请求」里显式写了
    -- Accept-Encoding 时以其为准，便于上游必须压缩的特殊场景自行权衡。
    if rewrite.writes_body(binding.response_rewrite)
        and not request_sets_header(binding, "accept-encoding") then
        ngx.req.set_header("Accept-Encoding", "identity")
    end
end

-- nginx hands proxy_pass the *decoded* request path (ngx.var.uri).  Raw
-- non-ASCII bytes, spaces, or other illegal request-line characters then
-- reach strict upstreams unencoded (e.g. aiohttp answers 400 "Invalid char
-- in url path").  Re-encode every path segment while keeping "/" intact;
-- a literal "%" that survived decoding round-trips correctly as %25.
local function encode_upstream_path(path)
    local segments = {}
    for segment in (path .. "/"):gmatch("([^/]*)/") do
        segments[#segments + 1] = ngx.escape_uri(segment):gsub('%%40', '@'):gsub('%%3A', ':'):gsub('%%2B', '+')
    end
    return table.concat(segments, "/")
end

function _M.prepare(binding, target_ip, port)
    local scheme = binding and binding.upstream_scheme or "http"
    local path_override = binding and binding.upstream_path or ""
    local request_path = tostring(ngx.var.uri or "/")
    local path = encode_upstream_path(path_override ~= "" and path_override or request_path)
    local query = ngx.var.args
    local query_suffix = query and query ~= "" and "?" .. query or ""
    ngx.var.authz_target = scheme .. "://" .. target.url_host(target_ip) .. ":" .. port .. path .. query_suffix
    local ssl_host = binding and binding.upstream_host ~= "" and
        target.authority_host(binding.upstream_host)
    ssl_host = ssl_host or target.authority_host(target.url_host(target_ip)) or target.url_host(target_ip)
    ngx.var.authz_upstream_ssl_name = ssl_host
    apply_headers(binding, target_ip, port)
    local requested_upgrade = tostring(ngx.var.http_upgrade or "")
    local websocket_request = requested_upgrade:lower() == "websocket"
    ngx.var.authz_websocket = websocket_request and "1" or "0"
    ngx.var.authz_upgrade = websocket_request and requested_upgrade or ""
    ngx.var.authz_connection = websocket_request and "upgrade" or ""
    -- 请求正文改写：必须在转发前、于 access 阶段完成（缓冲 -> 改写 -> 重新
    -- 设置 Content-Length）。放在 websocket 标记之后，升级请求一律跳过；
    -- 可改写性判断（方法/分帧/类型/体积）统一在 request_body_mode 内完成。
    local rr = binding and binding.request_rewrite
    if rr then
        local mode = rewrite.request_body_mode(rr)
        if mode then rewrite.body_rewrite(mode, rr) end
    end
    return scheme
end

return _M
