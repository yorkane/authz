--[[
License MIT
]]
local ngx, nvar, concat, ngxreq, nphase, ngsub, encode_args = ngx, ngx.var, table.concat, ngx.req, ngx.get_phase, ngx.re.gsub, ngx.encode_args
local find, sub, gsub, byte, sreverse, lower, tostring = string.find, string.sub, string.gsub, string.byte, string.reverse, string.lower, tostring
local next, setmetatable, type, rawset, tablepool = next, setmetatable, type, rawset, require("tablepool")
local empty_tb, TAG = {}, "CTXVAR"
local ngx_var = {
    -- arg_name = "", -- argument name in the request line
    args = "", -- arguments in the request line
    binary_remote_addr = "", -- client address in a binary form, value’s length is always 4 bytes for IPv4 addresses or 16 bytes for IPv6 addresses
    body_bytes_sent = false, --"0", -- number of bytes sent to a client, not counting the response header; this variable is compatible with the “%B” parameter of the mod_log_config Apache module
    bytes_sent = false, --"0", -- number of bytes sent to a client (1.3.8, 1.2.5)
    connection = "", -- connection serial number (1.3.8, 1.2.5)
    connection_requests = "", -- current number of requests made through a connection (1.3.8, 1.2.5)
    content_length = "", -- “Content-Length” request header field
    content_type = "", -- “Content-Type” request header field
    cookie_name = "", -- the name cookie
    document_root = "", -- root or alias directive’s value for the current request
    document_uri = "", -- same as $uri
    host = "", -- in this order of precedence: host name from the request line, or host name from the “Host” request header field, or the server name matching a request
    hostname = "", -- host name
    http_name = "", -- arbitrary request header field; the last part of a variable name is the field name converted to lower case with dashes replaced by underscores
    https = "", -- “on” if connection operates in SSL mode, or an empty string otherwise
    is_args = "", -- “?” if a request line has arguments, or an empty string otherwise
    limit_rate = "", -- setting this variable enables response rate limiting; see limit_rate
    msec = false, -- "0", -- current time in seconds with the milliseconds resolution (1.3.9, 1.2.6)
    nginx_version = "", -- nginx version
    pid = 1234, -- PID of the worker process
    pipe = "", -- “p” if request was pipelined, “.” otherwise (1.3.12, 1.2.7)
    proxy_protocol_addr = "", -- client address from the PROXY protocol header (1.5.12). The PROXY protocol must be previously enabled by setting the proxy_protocol parameter in the listen directive.
    proxy_protocol_port = "", -- client port from the PROXY protocol header (1.11.0). The PROXY protocol must be previously enabled by setting the proxy_protocol parameter in the listen directive.
    proxy_protocol_server_addr = "", -- server address from the PROXY protocol header (1.17.6). The PROXY protocol must be previously enabled by setting the proxy_protocol parameter in the listen directive.
    proxy_protocol_server_port = "", -- server port from the PROXY protocol header (1.17.6). The PROXY protocol must be previously enabled by setting the proxy_protocol parameter in the listen directive.
    query_string = "", -- same as $args
    realpath_root = "", -- an absolute pathname corresponding to the root or alias directive’s value for the current request, with all symbolic links resolved to real paths
    remote_addr = "127.0.0.1", -- client address
    remote_port = "", -- client port
    remote_user = "", -- user name supplied with the Basic authentication
    request = "", -- full original request line
    request_body = "", -- request body. The variable’s value is made available in locations processed by the proxy_pass, fastcgi_pass, uwsgi_pass, and scgi_pass directives when the request body was read to a memory buffer.
    request_body_file = "", -- name of a temporary file with the request body. At the end of processing, the file needs to be removed. To always write the request body to a file, client_body_in_file_only needs to be enabled. When the name of a temporary file is passed in a proxied request or in a request to a FastCGI/uwsgi/SCGI server, passing the request body should be disabled by the proxy_pass_request_body off, fastcgi_pass_request_body off, uwsgi_pass_request_body off, or scgi_pass_request_body off directives, respectively.
    request_completion = "", -- “OK” if a request has completed, or an empty string otherwise
    request_filename = "", -- file path for the current request, based on the root or alias directives, and the request URI
    request_id = false,
    --"7ced51898a63d0d25ad92b953bd20af5", -- unique request identifier generated from 16 random bytes, in hexadecimal (1.11.0)
    request_length = false, -- request length (including request line, header, and request body) (1.3.12, 1.2.7)
    request_method = "", -- request method, usually “GET” or “POST”
    request_time = false, --"123", -- request processing time in seconds with a milliseconds resolution (1.3.9, 1.2.6); time elapsed since the first bytes were read from the client
    request_uri = "/path/file", -- full original request URI (with arguments)
    scheme = "http", -- request scheme, “http” or “https”
    sent_http_name = "", -- arbitrary response header field; the last part of a variable name is the field name converted to lower case with dashes replaced by underscores
    -- sent_trailer_name = "", -- arbitrary field sent at the end of the response (1.13.2); the last part of a variable name is the field name converted to lower case with dashes replaced by underscores
    server_addr = "", -- an address of the server which accepted a request. Computing a value of this variable usually requires one system call. To avoid a system call, the listen directives must specify addresses and use the bind parameter.
    server_name = "", -- name of the server which accepted a request
    server_port = "", -- port of the server which accepted a request
    server_protocol = "", -- request protocol, usually “HTTP/1.0”, “HTTP/1.1”, or “HTTP/2.0”
    status = false, --"000", -- response status (1.3.2, 1.2.2)
    -- tcpinfo_rtt  false, --0
    -- tcpinfo_rttvar = 0,
    -- tcpinfo_snd_cwnd = 0,
    -- tcpinfo_rcv_space = "", -- information about the client TCP connection; available on systems that support the TCP_INFO socket option
    -- time_iso8601 = "", -- local time in the ISO 8601 standard format (1.3.12, 1.2.7)
    -- time_local = "", -- local time in the Common Log Format (1.3.12, 1.2.7)
    uri = "/" --current URI in request, normalized. The value of $uri may change during request processing
}
local static = {
    html = 1,
    htm = 1,
    xhtml = 1,
    shtml = 1,
    xml = 1,
    txt = 1,
    js = 1,
    jpg = 1,
    png = 1,
    gif = 1,
    webp = 1,
    mp4 = 1,
    hls = 1,
    svg = 1,
    ico = 1,
    doc = 1,
    docx = 1,
    xls = 1,
    xlsx = 1,
    avi = 1,
    mp3 = 1,
    flv = 1,
    m4v = 1,
    mpg = 1,
    ts = 1,
    av1 = 1,
    zip = 1,
    rar = 1,
    gz = 1,
    ["7z"] = 1,
    tar = 1,
    jpeg = 1,
    css = 1,
    rss = 1,
    json = 1,
    ttf = 1,
    eot = 1,
    otf = 1,
    woff = 1
}
---@class resty.ctxvar
---@field request_header table<string,string> @ keep request header
---@field resp_header table<string,string> @ keep response header
---@field ip string @ as xxx.xxx.xxx.xxx
---@field request_body string @ any phase could inject the body for next phases
---@field response_body string @ any phase could inject the body for next phases
---@field is_json boolean @ indicate current request is asking for JSON response
---@field is_timer boolean @ indicate current request is initiated from timer phase (usually by system call)
---@field is_static string @ indicate current request is asking for static content
---@field host_1 string @ level 1 host as test.com
---@field host_2 string @ level 2 host as www.test.com
---@field host_3 string @ level 3 host as js.www.test.com
local _M = {
    is_timer = false, -- just leave a key to indicate current request is from timer,
    is_static = false,
    response_body = "",
    method = "GET",
    request_header = {
        content_type = "text/json",
        connection = "keep-alive",
        accept_encoding = "gzip, deflate",
        accept_language = "zh-CN,zh;q=0.9,en;q=0.8,en-US;q=0.7",
        user_agent = "lua-resty-http",
        referer = "",
        cookie = "",
        origin = "",
        host = "",
        upgrade_insecure_requests = "1"
    },
    is_json = false,
    ___is_ctx_var = true,
    is_query_changed = false,
    is_uri_changed = false,
    resp_header = {},
    cookie = {},
    var = ngx_var,
    ip = "127.0.0.1", -- could be remote_addr
    uri_args = {},
    post_args = {},
    url = "", -- the original full url as https://sss.xxx.xx/sss/q?xx=1
    file_format = "", --html
    uri = "", --/path
    query_string = "",
    request_uri = "", -- normalized url
    host_1 = '',
    host_2 = '',
    host_3 = '',
}

function _M.dispose(ctx)
    setmetatable(ctx, empty_tb)
    setmetatable(ctx.request_header, empty_tb)
    setmetatable(ctx.var, empty_tb)
    tablepool.release(TAG, ctx.resp_header)
    tablepool.release(TAG, ctx.request_header)
    tablepool.release(TAG, ctx.var)
    tablepool.release(TAG, ctx)
end

local valid_phase = {
    set = true,
    rewrite = true,
    balancer = true,
    access = true,
    content = true,
    header_filter = true,
    body_filter = true,
    log = true
}

function _M.get_file_suffix(url)
    local inx = find(url, "?", 1, true)
    if inx then
        url = sub(url, 1, inx - 1)
    end
    local len = #url
    if len < 2 then
        return nil
    end
    if len < 7 then
        len = 7
    end
    local c1, c2, c3, c4, c5, c6 = byte(url, len - 6, len)
    if c1 == 46 then
        return sub(url, len - 5, len)
    end
    if c2 == 46 then
        return sub(url, len - 4, len)
    end
    if c3 == 46 then
        return sub(url, len - 3, len)
    end
    if c4 == 46 then
        return sub(url, len - 2, len)
    end
    if c5 == 46 then
        return sub(url, len - 1, len)
    end
    if c6 == 46 then
        return sub(url, len, len)
    end
    return ""
end

local reg_dashes = [[\-]]
local header_mt = {
    __index = function(self, key)
        if _M.request_header[key] == nil then
            key = lower(ngsub(key, reg_dashes, "_", "jo"))
        end
        local data = nvar["http_" .. key] or false
        rawset(self, key, data)
        return data
    end
}

local cookie_mt = {
    __index = function(self, key)
        local data
        data = ngx.var['cookie_' .. key] or ''
        rawset(self, key, data)
        return data
    end
}

local nvar_mt = {
    __metatable = "No access to ngx-system-context metatable", --prevent from metable modifying
    __newindex = function(self, key, val)
        if not ngx_var[key] then
            error("ngx.var." .. key .. " could not be modified!")
        end
        ngx.var[key] = val
        rawset(self, key, val)
    end,
    __index = function(self, key)
        local data
        --local data = rawget(self, key)
        --if data ~= nil then
        --    return data
        --end
        if not ngx_var[key] then
            return nvar[key]
        elseif key == "host" then
            data = nvar.host
        elseif key == "request_uri" then
            data = nvar.request_uri
            local b1, b2, b3 = byte(data, 2, 4) -- try to remove url-head 3-2 flashes
            if b1 == 47 and b1 == b2 and b2 == b3 then
                data = sub(data, 4, -1)
            elseif b1 == 47 and b1 == b2 then
                data = sub(data, 3, -1)
            elseif b1 == 47 then
                data = sub(data, 2, -1)
            end
        elseif key == "port" or key == "server_port" then
            data = nvar.server_port
        elseif key == "method" or key == "request_method" then
            data = ngx.req.get_method()
        elseif key == "remote_addr" then
            data = nvar.remote_addr
        elseif key == "scheme" then
            data = nvar.scheme
        elseif key == "query_string" or key == "args" then
            data = self.request_uri
            local inx = find(data, "?", 2, true)
            if inx then
                rawset(self, "uri", _M.normalize_url(sub(data, 1, inx - 1)))
                data = sub(data, inx + 1, -1)
            else
                rawset(self, "uri", data)
                data = ""
            end
        elseif key == "uri" then
            data = self.request_uri
            local inx = find(data, "?", 2, true)
            if inx then
                rawset(self, "query_string", sub(data, inx + 1, -1))
                data = sub(data, 1, inx - 1)
            else
                rawset(self, "query_string", "")
            end
            data = _M.normalize_url(data)
        else
            data = nvar[key] or ""
        end
        rawset(self, key, data) -- prevent costy empty ngx.var visit
        return data
    end
}

local ctvmt = {
    __index = function(self, key)
        local data
        --ngx.log(ngx.WARN,key ,'------------------------')
        if key == "ip" then
            local header = self.request_header
            data = header["remoteip"] or header["X-real-ip"] or header["x-forwarded-for"] or nvar.remote_addr
        elseif key == 'var' then
            data = tablepool.fetch(TAG, 0, 11)
            setmetatable(data, nvar_mt)
        elseif key == "request_body" then
            ngx.req.read_body()
            data = ngx.req.get_body_data() or ""
        elseif key == "file_format" then
            data = _M.get_file_suffix(self.uri)
        elseif key == "uri_args" then
            data = ngx.req.get_uri_args()
        elseif key == "post_args" then
            ngx.req.read_body()
            data = ngx.req.get_post_args()
        elseif key == "is_json" then
            data = self.var.content_type
            if data and find(data, "json", 1, true) then
                data = true
            else
                data = false
            end
        elseif key == "url" then
            local var = self.var
            data = self.request_uri
            local host, port, scheme, port_str = var.host, var.server_port, var.scheme
            if port == "443" and scheme == "https" then
                port_str = ""
            elseif port == "80" and scheme == "http" then
                port_str = ""
            else
                port_str = ":" .. port
            end
            data = scheme .. "://" .. host .. port_str .. data
        elseif key == 'request_header' then
            data = tablepool.fetch(TAG, 0, 7)
            setmetatable(data, header_mt)
        elseif key == 'var' then
            data = tablepool.fetch(TAG, 0, 11)
            setmetatable(data, nvar_mt)
        elseif key == "cookie" then
            data = tablepool.fetch(TAG, 0, 7)
            setmetatable(data, cookie_mt)
        elseif key == "host" then
            data = self.var.host
        elseif key == "uri" then
            data = self.var.uri
        elseif key == "query_string" then
            if self.is_query_changed then
                local args = self.uri_args
                if next(args) then
                    data = encode_args(args)
                    self.is_query_changed = false
                end
            else
                data = self.var.query_string
            end
        elseif key == "method" then
            data = ngxreq.get_method()
        elseif key == "is_static" then
            data = static[self.file_format] == 1
        elseif key == "request_uri" then
            if self.is_query_changed then
                local args = self.uri_args
                if next(args) then
                    local query_string = encode_args(args)
                    self.query_string = query_string
                    return self.uri .. "?" .. query_string
                else
                    self.query_string = ""
                    return self.uri
                end
            end
            if #self.query_string > 3 then
                return self.uri .. "?" .. self.query_string
            else
                return self.uri
            end
        elseif key == 'resp_header' then
            data = tablepool.fetch(TAG, 0, 7)
        elseif key == 'host_1' then
            data = _M.get_domain(self.host, 1)
        elseif key == 'host_2' then
            data = _M.get_domain(self.host, 2)
        elseif key == 'host_3' then
            data = _M.get_domain(self.host, 3)
        else
            data = false
        end
        rawset(self, key, data)
        return data
    end
}

local timer_ngx = {
    status = 200,
    header = {}
}
setmetatable(timer_ngx, { __index = ngx })

local timer_ctx_mt = { __index = _M }
local timer_var_mt = { __index = ngx_var }
local timer_request_header_mt = { __index = _M.request_header }

---new boost performance for ngx.ctx._env, and avoid phase call failures, and always return string
---@return resty.ctxvar
function _M.new(tb, is_timer)
    if not tb then
        tb = ngx.ctx._env
        if not tb then
            tb = tablepool.fetch(TAG, 0, 17)
            ngx.ctx._env = tb
        end
    elseif tb and type(tb) ~= "table" then
        return nil, "table type required"
    end
    if not tb.___is_ctx_var then
        tb.___is_ctx_var = true
        --if not tb.var then
        --    tb.var = tablepool.fetch(TAG, 0, 17)
        --end
        --if not tb.request_header then
        --    tb.request_header = tablepool.fetch(TAG, 0, 11)
        --end
        --if not tb.resp_header then
        -- tb.resp_header = tablepool.fetch(TAG, 0, 11)
        --end
        if is_timer == nil then
            is_timer = ngx.get_phase() == "timer"
        end
        if is_timer then
            tb.var = tablepool.fetch(TAG, 0, 11)
            tb.is_timer = true
            setmetatable(tb, timer_ctx_mt)
            setmetatable(tb.var, timer_var_mt)
            setmetatable(tb.request_header, timer_request_header_mt)
        else
            tb.is_timer = false
            setmetatable(tb, ctvmt)
            --setmetatable(tb.var, nvar_mt)
            --setmetatable(tb.request_header, header_mt)
            ngx.ctx._ctxvar = tb
        end
    end
    return tb
end

---get_ngx
---@param env system.env
---@return ngx_mock
function _M.get_ngx(env)
    env = _M.new(env)
    if env.is_timer then
        return timer_ngx
    end
    return ngx
end

local reg_slash = [[\/+]]
function _M.normalize_url(url)
    if not url then
        return
    end
    if byte(url, 1, 1) == 47 then
        return ngsub(url, reg_slash, "/", "jo")
    end
    local p1 = sub(url, 9, -1)
    p1 = ngsub(p1, reg_slash, "/", "jo")
    return sub(url, 1, 9) .. p1
end

setmetatable(_M, {
    __call = function(self, tab, is_timer)
        return _M.new(tab, is_timer) -- make it callable as ctxvar(ctx)
    end
})

local n_dot = byte('.')
function _M.get_domain(str, level)
    if type(str) ~= 'string' or #str < 3 then
        return nil, 'bad domain'
    end
    local len, dot_count, last_dot_position = #str, 0, 0
    for i = len, 1, -1 do
        local nchar = byte(str, i, i)
        if nchar == n_dot then
            dot_count = dot_count + 1
            last_dot_position = i
            if level == dot_count - 1 then
                return sub(str, i + 1, len), dot_count
            end
        end
    end
    return str, dot_count
end

local regex_env1 = '$([a-z][a-z_0-9]+)'
---
---@param template_str string @with $XXX variable
---@param ctx table<string, any>|resty.ctxvar
---@return string
function _M.format_var(template_str, ctx)
    if not template_str then
        return template_str
    end
    local from = find(template_str, "$")
    if not from then
        return template_str
    end
    --avoid creating temporary function
    ctx = ctx or _M.new()
    return gsub(template_str, regex_env1, function(m)
        return tostring(ctx[m] or '')
    end)
end

function _M.test()
    local test_domain = 'l5.l4.l3.l2.test.com'
    assert(_M.get_domain(test_domain, 1), 'test.com')
    assert(_M.get_domain(test_domain, 2), 'l2.test.com')
    assert(_M.get_domain(test_domain, 3), 'l3.l2.test.com')
    assert(_M.get_domain(test_domain, 4), 'l4.l3.l2.test.com')
    assert(_M.get_domain(test_domain, 5), 'l5.l4.l3.l2.test.com')
    local ctv = _M.new()
    for key, val in pairs(ngx_var) do
        if key ~= "request_id" then
            local v1, v2 = ngx.var[key], ctv.var[key]
            if v1 ~= v2 and (v2 ~= "" and v2 ~= empty_tb) then
                error(key .. " with ngx.var: " .. (v1 or "") .. " not match in ctxvar: " .. (v2 or ""))
            end
        end
    end
    for key, val in pairs(_M) do
        if type(val) ~= "function" then
            local _ = ctv[key]
        end
    end
    assert(ctv.query_string == ctv.var.query_string)
    assert(ctv.uri == ctv.var.uri)
    local phase = ngx.get_phase()
    if phase == "content" then
        ctv.response_body = phase
        ngx.say("url=", ctv.url)
        ngx.say("body=", ctv.request_body)
        ngx.say("content_length=", ctv.request_header.content_length)
        ngx.say('header.accept-encoding=', ctv.request_header['accept-encoding'])
        ngx.say('header.user-agent=', ctv.request_header['user-agent'])
    elseif phase == "log" then
        assert(ctv.response_body == "content", ctv.response_body)
    end

    local uri = "/12//34///i/56/78//d//////////////////////f/90?q=1"
end

function _M.main()
    local c = _M.new()
    local t = c.ip
    local dump = require("klib.dump").global()


end
return _M