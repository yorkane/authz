local sfind, sub, char, ins, byte = string.find, string.sub, string.char, table.insert, string.byte
local upper, lower, pcall, type, traceback = string.upper, string.lower, pcall, type, debug.traceback
local nsub = ngx.re.gsub
local new_tab = require('table.new')
local floor = math.floor
local clone_tab = require("table.clone")
local ctxvar = require('klib.ctxvar')
local print, error, pairs = ngx.print, error, pairs
local json = require("cjson.safe")
local json_decode, json_encode = json.decode, json.encode
local resty_template = require "resty.template.safe"


--{{{
--- 46 slots
local bit_full = {
    1, 3, 7, 15, 31, 63, 127, 255, 511, 1023, 2047, 4095, 8191, 16383, 32767, 65535, 131071, 262143, 524287, 1048575, 2097151, 4194303, 8388607, 16777215, 33554431, 67108863, 134217727, 268435455, 536870911, 1073741823, 2147483647, 4294967295, 8589934591, 17179869183, 34359738367, 68719476735, 137438953471, 274877906943, 549755813887, 1099511627775, 2199023255551, 4398046511103, 8796093022207, 17592186044415, 35184372088831, 70368744177663
}
--}}}

local function split(text, splitter, start_index, enable_empty_slots)
    if not text then
        return {}
    end
    start_index = start_index or 1
    splitter = splitter or ','
    local size = floor(#text / 7) + 3
    if size > 5 and size < 10 then
        size = 10
    end
    if size > 40 then
        size = 40
    end
    local arr = new_tab(size, 0)
    if #splitter == 1 then
        local len = #text
        local spb = byte(splitter)
        local last_match = start_index
        local nc, str = 1
        for i = start_index, len do
            if spb == byte(text, i, i) then
                if enable_empty_slots or (i - 1 - last_match) > -1 then
                    str = sub(text, last_match, i - 1)
                    arr[nc] = str
                    nc = nc + 1
                end
                last_match = i + 1
            end
        end
        if len >= last_match then
            arr[nc] = sub(text, last_match, len)
        end
        return arr
    end
    local temp = sub(text, start_index, #text)
    local len, width = 0, #splitter
    local nc = 1
    while true do
        len = sfind(temp, splitter, 1, true)
        if len ~= nil then
            local result = sub(temp, 1, len - 1)
            temp = sub(temp, len + width)
            --table.insert(res, result)
            arr[nc] = result
            nc = nc + 1
        else
            if #temp > 0 then
                arr[nc] = temp
            end
            break
        end
    end
    return arr
end

local escape_regex_re = [[([\.\\\[\]\$\^\*\?\+\{\}\(\)])]]
local function escape_regex(reg_str)
    return nsub(reg_str, escape_regex_re, [[\$1]], 'jo')
end



local _M = {}
local _mt = { __index = _M }
setmetatable(_M, {
    __call = function(_M, root_entry)
        return _M.new(root_entry)
    end
})

local function correct_entry(str)
    if not str or str == '' then
        return '/'
    end
    if byte(str, 1, 1) ~= 47 then
        str = '/' .. str
        --error(str .. ' : rule_string must start with `/`' .. traceback('debug', 1))
    end
    return str
end

function _M.new(root_entry, template_root)
    root_entry = correct_entry(root_entry)
    ---@class klib.router
    ---@field root_entry string @ initial entry
    ---@field start_index number @ entry length
    ---@field router_map table<number, klib.router.map[]> @ entry length
    ---@field pre_access fun(params:table<string, string>, ctx:resty.ctxvar, req):boolean @ excute this function before request, if return true to proceed
    ---@field err_handler table<number, fun(ctx:resty.ctxvar, status:number, err:table, router:klib.router)> @ custom handler for mapping to status code: 4xx 5xx
    ---@field filter table<number, fun(output:string, ...)> @ apply filter as the push order  to the output content in router.json/router.print functions, and the following parameters required you pass it manually
    local inst = {
        root_entry = root_entry,
        start_index = #root_entry,
        router_map = {},
        err_handler = {},
        filter = {},
        pre_access = nil,
        template = nil,
        template_root = template_root,
        resty_template = resty_template,
    }
    if resty_template and template_root then
        inst.resty_template = resty_template.new({ root = template_root })
    end
    setmetatable(inst, _mt)
    return inst
end

local method_map = { GET = 1, HEAD = 2, POST = 4, PUT = 8, DELETE = 16, OPTIONS = 32, PATCH = 64 }

---parse_rule_map
---@param self klib.router
---@param rule_string string
---@param method string
---@return klib.router.map, string @ map and name of current map
local function parse_rule_map(self, rule_string, method)
    local bits = method_map[method]
    if not bits then
        return nil, 'bad method input, only GET/HEAD/POST/PUT/DELETE/PATCH/OPTIONS support'
    end
    local uid_str = ''
    local arr = split(rule_string, '/')
    local len, entry_name = #arr, arr[1] or '/'
    local map
    for i = 1, len do
        local param = arr[i]
        if sfind(param, ':', 1, 'true') == 1 then
            if not map then
                map = {}
            end
            local name = sub(param, 2, 200)
            map[i - 1] = name -- ignore first element
            uid_str = uid_str .. [[/[^/]+]]
            arr[i] = false
        else
            uid_str = uid_str .. '/' .. escape_regex(param)
        end
    end
    -- reduce level when only one params exist
    table.remove(arr, 1)
    if #arr == 1 then
        arr = arr[1] or nil
        if map then
            map = map[1]
        end
    elseif #arr == 0 then
        arr = nil
    end
    bits = bits + bit_full[len + 7] - bit_full[7]
    ---@class klib.router.map
    ---@field map string[] @preserve parameter/value sequence mapping
    local map_item = {
        uid = method .. '\t' .. self.root_entry .. uid_str,
        rule = rule_string,
        map = map,
        bits = bits,
        len = len,
        method = method,
        sequence = arr,
    }
    return map_item, entry_name
end

local function remove_query(path)
    if path then
        local inx = sfind(path, '?', 1, true) -- last uri section end with `?` will accept as query
        if inx then
            path = sub(path, 1, inx - 1)
        end
    end
    return path
end

function _M:build_response(defaul_kv, mt)
    local m = clone_tab(defaul_kv)
    m.root_entry = self.root_entry
    if mt and type(mt) == 'table' then
        setmetatable(m, mt)
    end
    return m
end

---get_request
---@param self klib.router
---@param uri string
---@param method string
---@param section_array string[] @ already split url sections
---@return klib.router.map, table<string, string> @ get map and params generated with rule_string
function _M:get_request(uri, method, section_array)
    local start_index = self.start_index
    local root_uri = sub(uri, 1, start_index)
    if root_uri ~= self.root_entry then
        return nil, nil, 'do not match to the root path, wrong entry for uri'
    end
    section_array = section_array or split(uri, '/', start_index + 1) --remove the prefix path besides root
    local section_len, entry_name = #section_array
    entry_name = section_array[1] or '/'
    --if section_len == 1 and byte(section_array[1], 1, 1) == 63 then
    --    section_len = 0 -- treat /xxx?sss as /xxx
    --    entry_name = '/'
    --end
    local bits = method_map[method] -- get method + slots info
    bits = bits + (bit_full[section_len + 7]) - bit_full[7] -- ignore the first 7 bits as preserved methods slot
    local arr, params, router_map = self.router_map[bits] -- get sequence arr from router_map by bits
    if arr then
        arr = arr[entry_name]
    end
    --logs(arr, section_array, entry_name, bits)
    if arr then
        params = {}
        if section_len < 2 then
            router_map = arr --only one match in root
        elseif section_len == 2 then
            for i = 1, #arr do
                local sequence = arr[i].sequence
                local seq = section_array[2]
                if sequence and sequence == seq then
                    router_map = arr[i]
                    break
                elseif not sequence and arr[i].map then
                    router_map = arr[i]
                    params[arr[i].map] = seq
                    break
                end
            end
        else
            for i = 1, #arr do
                local map = arr[i]
                local sequence = map.sequence
                local sequence_len = #sequence
                local is_match = true
                -- ignore first section compare
                for n = 1, sequence_len do
                    local chars = sequence[n]
                    local seq = section_array[n + 1]
                    -- by comparing every section in slots
                    if chars and chars ~= seq then
                        if sequence_len == n then
                            is_match = (seq == chars) -- Test last seq of the uri
                        else
                            is_match = false
                            break
                        end
                    end
                end
                if is_match then
                    -- the first complete match will be return
                    router_map = map
                    break
                end
            end
            if router_map then
                if router_map.map then
                    for i, v in pairs(router_map.map) do
                        params[v] = section_array[i + 1] -- Cause the first entry path as itself[A] will be ignored /A/B/C
                    end
                end
            end
        end
    end
    return router_map, params
end

---register map function to router
---@param rule_string string
---@param func fun(params:table<string, string>, ctx:resty.ctxvar):table|string,number
---@param method string
---@param template string @ Nullable, template for compile output result
---@return fun, klib.router.map, string @ function injected, router.map hit the uri, error message
function _M:register(rule_string, func, method, template)
    rule_string = correct_entry(rule_string)
    local map, entry_name = parse_rule_map(self, rule_string, method)
    if not map then
        return nil, nil, entry_name
    end
    if not map then
        return nil, nil, 'Bad format, at least one param name required in :' .. rule_string
    end
    local router_map = self.router_map
    --prevent
    if router_map[map.uid] ~= nil then
        return nil, nil, 'duplicate func register in get:' .. rule_string
    end
    map.func = func
    map.template = template
    router_map[map.uid] = map
    local dic = router_map[map.bits]
    if not dic then
        dic = {}
        router_map[map.bits] = dic
    end
    if map.len < 2 then
        dic[entry_name] = map -- reduce cascade levels
    else
        local arr = dic[entry_name]
        if not arr then
            arr = { map }
            dic[entry_name] = arr
        else
            ins(arr, map)
        end
        if #arr > 1 then
            --put the /:xxx/:xxx mapped path/params type route to the tail of the array, avoid bad match with regular paths
            table.sort(arr, function(a, b)
                local c = a.map and 1 or 0
                local d = b.map and 1 or 0
                return d > c
            end)
        end

    end
    map.bits = nil --remove bits for saving memory
    return func, map
end

---html append content to nginx output buffer
---@param text string
---@param ctx resty.ctxvar @Nullable
---@param router_map klib.router.map @Nullable for applying router.filter
function _M:html(text, ctx, router_map)
    ngx.header['Content-Type'] = 'text/html; charset=UTF-8'
    if router_map then
        local filter = self.filter[router_map.uid] or self.filter
        for i = 1, #filter do
            text = filter[i](text, ctx, self)
        end
    end
    print(text)
end

---json append content to nginx output buffer
---@param luaobj table
---@param ctx resty.ctxvar @Nullable
---@param router_map klib.router.map @Nullable for applying router.filter
function _M:json(luaobj, ctx, router_map)
    local text, err
    if router_map.template then
        text, err = self.resty_template.process(router_map.template, luaobj)
        if err then
            ngx.status = 500
            ngx.header['Content-Type'] = 'text/plain; charset=UTF-8'
            print("Render ERROR:\n", self.template_root..router_map.template, '\n\n')
            print('With Data:\n', json_encode(luaobj), '\n\n')
            print('ERROR: \n',err)
            ngx.exit(500)
        end
        ngx.header['Content-Type'] = 'text/html; charset=UTF-8'
    else
        ngx.header['Content-Type'] = 'application/json; charset=UTF-8'
        text = json_encode(luaobj)
    end
    if router_map then
        local filter = self.filter[router_map.uid] or self.filter
        for i = 1, #filter do
            text = filter[i](text, ctx, self)
        end
    end
    print(text)
end

function _M:render(luaobj, template)
    ngx.header['Content-Type'] = 'text/html; charset=UTF-8'
    local text = self.resty_template.process(template, luaobj)
    print(text)
end

---default_error_handler
---@param ctx resty.ctxvar
---@param status number
---@param err table
---@param self klib.router
local function default_error_handler(ctx, status, err, params, self)
    if ctx.is_json then
        ngx.header['Content-Type'] = 'application/json; charset=UTF-8'
        if not err.err then
            err = { err = err }
        end
        err.params = params
        print(json_encode(err))
    else
        if type(err) == table then
            err = json_encode(err)
        end
        ngx.header['Content-Type'] = 'text/html; charset=UTF-8'
        print('<html><head><meta http-equiv="content-type" content="text/html;charset=utf-8" /><title>Error</title></head><body><h2>Internal error : ', status, '</h2><hr /><pre>error messages:<br />', err, '</pre></body></html>')
    end
end

---@class klib.router.request
local req = {}

function req.get_query()
    return ngx.req.get_uri_args()
end

---get_header
---@param name string
---@param ctx resty.ctxvar @Nullable
---@return string|string[]|nil
function req.get_header(name, ctx)
    if type(name) ~= "string" then return nil end
    ctx = ctxvar(ctx)
    local headers = ctx.request_header or ngx.req.get_headers()
    local value = headers[name] or headers[lower(name)]
    if value ~= nil then return value end
    local expected = lower(name)
    for key, header_value in pairs(headers) do
        if type(key) == "string" and lower(key) == expected then
            return header_value
        end
    end
end

---get_body parses API request bodies with strict Content-Type and JSON object validation.
---@param ctx resty.ctxvar @Nullable
---@return table|nil, string|nil
function req.get_body(ctx)
    ctx = ctxvar(ctx)
    ngx.req.read_body()
    local raw = ngx.req.get_body_data() or ""
    if raw == "" then return {} end

    local content_type = req.get_header("Content-Type", ctx) or ngx.var.content_type or ""
    content_type = lower(type(content_type) == "table" and content_type[1] or content_type)
    if sfind(content_type, "application/json", 1, true) then
        local data, err = json_decode(raw)
        if type(data) ~= "table" then
            return nil, "invalid JSON body: " .. tostring(err or "object required")
        end
        return data
    end

    if sfind(content_type, "application/x-www-form-urlencoded", 1, true) then
        local data, err = ngx.req.get_post_args()
        if not data then return nil, "invalid form body: " .. tostring(err or "parse failed") end
        return data
    end

    return nil, "Content-Type must be application/json"
end

---get_body_header
---@param ctx resty.ctxvar
---@return table|string, table|string|boolean @ parsed body and headers/content-type
function req.get_body_header(ctx)
    ctx = ctxvar(ctx)
    ngx.req.read_body()
    local headers = ctx.request_header
    local body = ngx.req.get_body_data() or ''
    if body == '' then
        return body, req.get_header('Content-Type', ctx)
    end
    local a, b = byte(body, 1, 2)
    if a == 123 or a == 91 then
        if b == 123 or b == 91 or b == 34 then
            body = json.decode(body)
            return body, headers
        end
    end
    local header = req.get_header('Content-Type', ctx)
    -- the post request have Content-Type header set
    if header then
        if sfind(header, "application/x-www-form-urlencoded", 1, true) then
            local post_args = ngx.req.get_post_args()
            if post_args and type(post_args) == "table" then
                body = post_args
            end
        elseif sfind(header, "json", 1, true) then
            body = json_decode(body)
            -- form-data request
            --elseif sfind(header, "multipart", 1, true) then
            -- upload request, should not invoke ngx.req.read_body()
            -- parsed as raw by default
        else
            -- body = ngx.req.get_body_data()
            -- local b = byte(body, 1, 1)
            -- if b == 123 or b == 91 then
            -- 	body = json.decode(body)
            -- end
        end
    else

    end
    return body, header
end

---handle usually put this nginx.conf location content_by_lua_block entry
---@param ctx resty.ctxvar @Nullable
function _M:handle(ctx)
    ctx = ctxvar(ctx)
    local map, params, err, status, result, ok, func, access_stop = self:get_request(ctx.uri, ctx.method)
    if map then
        if self.pre_access then
            access_stop, err = self.pre_access(func, params, ctx, req)
        end
        if not access_stop then
            func = map.func
            ok, result, status = xpcall(func, traceback, params, ctx, req)
            if not ok then
                err = result
                status = 500
            else
                -- A numeric first return value in the HTTP status range is a
                -- shorthand for `return nil, status`.
                if not status and type(result) == 'number'
                    and result >= 100 and result <= 599 and result % 1 == 0 then
                    status = result
                    result = nil
                end
                if status and type(status) == 'number' then
                    ngx.status = status
                end
                if result and result ~= '' then
                    if type(result) == 'table' then
                        self:json(result, ctx, map)
                    else
                        self:html(result, ctx, map)
                    end
                end
                return -- handler may already response, ignore response process
            end
        end
    else
        err = 'No router match to : ' .. ctx.request_uri
        status = 404
    end
    -- error handling
    status = status or 404
    ngx.status = status
    local err_handler = self.err_handler[status] or default_error_handler
    err_handler(ctx, status, err, params, self)
end

---error_handle
---@param status number
---@param func fun(ctx:resty.ctxvar, status:number, err:table, router:klib.router)
function _M:error_handle(status, func)
    local error_handler = self.err_handler
    if error_handler[status] then
        return nil, status .. ' error handler already registered!'
    end
    error_handler[status] = func
end

---merge merge other router with current router as the root entry
---@param router klib.router
---@param entry_string string @ the url entry followed with upper root
function _M:merge(router, entry_string)
    if type(router) ~= 'table' or type(router.router_map) ~= 'table' then
        return nil, 'invalid child router'
    end
    if entry_string then
        entry_string = correct_entry(entry_string)
    else
        entry_string = router.root_entry
    end
    local pending, routes = {}, {}
    for i, v in pairs(router.router_map) do
        if type(i) == 'string' then
            local rule = correct_entry(entry_string .. v.rule)
            local map, parse_err = parse_rule_map(self, rule, v.method)
            if not map then
                return nil, parse_err
            end
            if self.router_map[map.uid] or pending[map.uid] then
                return nil, 'duplicate func register in get:' .. rule
            end
            pending[map.uid] = true
            routes[#routes + 1] = { rule = rule, source = v }
        end
    end
    for i = 1, #routes do
        local item = routes[i]
        local _, map, err = self:register(item.rule, item.source.func, item.source.method)
        if err then
            return nil, err
        end
        if #router.filter > 0 then
            self.filter[map.uid] = router.filter
        end
    end
    return true, #routes
end

---add_filter append output content filter
---@param func fun(output:string, ctx:resty.ctxvar, current_router:klib.router):string @function to process content before output to nginx buffer
function _M:add_filter(func)
    ins(self.filter, func)
end

function _M:add_access(func)
    ins(self.access, func)
end

local methods = { GET = 'GET', HEAD = 'HEAD', POST = 'POST', PUT = 'PUT', DELETE = 'DELETE', OPTIONS = 'OPTIONS', PATCH = 'PATCH',
                  get = 'GET', head = 'HEAD', post = 'POST', put = 'PUT', delete = 'DELETE', options = 'OPTIONS', patch = 'PATCH',
                  'GET', 'HEAD', 'POST', 'PUT', 'DELETE', 'OPTIONS', 'PATCH'
}

---attach_module automatically register module method with router, please notice the `params` injected will be an empty table
---@param module_obj table<string, fun(params:table<string, string>, ctx:resty.ctxvar, req:klib.router.request)> @lua module / component / table
---@return table<string, table> @ return the registered method and parameters
--function _M:attach_module(module_obj)
--    local result = {}
--    for fname, func in pairs(module_obj) do
--        if type(func) == 'function' then
--            local arr = split(fname, '_')
--            local method, subname = arr[1], arr[2]
--            if methods[method] then
--                local finfo = klass.parse_func(func)
--                if finfo.params[1] == 'params' and finfo.params[2] == 'ctx' and finfo.params[3] == 'req' then
--                    result[subname] = finfo.params
--                    self:register('/' .. subname, func, method)
--                elseif #finfo.params == 4 and finfo.params[1] == 'self' and finfo.params[2] == 'params' and finfo.params[3] == 'ctx' and finfo.params[4] == 'req' then
--                    result[subname] = finfo.params
--                    self:register('/' .. subname, function(params, ctx, req)
--                        return func(module_obj, params, ctx, req) -- inject with self
--                    end, method)
--                end
--            end
--        end
--    end
--    return result
--end

---@param rule_string string
---@param func fun(params:table<string, string>, ctx:resty.ctxvar):table|string,number
---@return fun, klib.router.map, string @ function injected, router.map hit the uri, error message
function _M:get(rule_string, func, template)
    return self:register(rule_string, func, 'GET', template)   
end
---@param rule_string string
---@param func fun(params:table<string, string>, ctx:resty.ctxvar):table|string,number
---@return fun, klib.router.map, string @ function injected, router.map hit the uri, error message
function _M:post(rule_string, func, template)
    return self:register(rule_string, func, 'POST', template)
end
---@param rule_string string
---@param func fun(params:table<string, string>, ctx:resty.ctxvar):table|string,number
---@return fun, klib.router.map, string @ function injected, router.map hit the uri, error message
function _M:delete(rule_string, func, template)
    return self:register(rule_string, func, 'DELETE', template)
end
---@param rule_string string
---@param func fun(params:table<string, string>, ctx:resty.ctxvar):table|string,number
---@return fun, klib.router.map, string @ function injected, router.map hit the uri, error message
function _M:options(rule_string, func, template)
    return self:register(rule_string, func, 'OPTIONS', template)
end
---@param rule_string string
---@param func fun(params:table<string, string>, ctx:resty.ctxvar):table|string,number
---@return fun, klib.router.map, string @ function injected, router.map hit the uri, error message
function _M:put(rule_string, func, template)
    return self:register(rule_string, func, 'PUT', template)
end
---@param rule_string string
---@param func fun(params:table<string, string>, ctx:resty.ctxvar):table|string,number
---@return fun, klib.router.map, string @ function injected, router.map hit the uri, error message
function _M:head(rule_string, func, template)
    return self:register(rule_string, func, 'HEAD', template)
end
---@param rule_string string
---@param func fun(params:table<string, string>, ctx:resty.ctxvar):table|string,number
---@return fun, klib.router.map, string @ function injected, router.map hit the uri, error message
function _M:patch(rule_string, func, template)
    return self:register(rule_string, func, 'PATCH', template)
end


--GET = ngx.HTTP_GET, -- 2
--HEAD = ngx.HTTP_HEAD, -- 4
--POST = ngx.HTTP_POST, -- 8
--PUT = ngx.HTTP_PUT, --16
--DELETE = ngx.HTTP_DELETE, -- 32
--MKCOL = ngx.HTTP_MKCOL, -- 64
--COPY = ngx.HTTP_COPY, -- 128
--MOVE = ngx.HTTP_MOVE, -- 256
--OPTIONS = ngx.HTTP_OPTIONS, --512
--PATCH = ngx.HTTP_PATCH, --16384
function _M.main()
    local dump = require('klib.dump').locally()
    local r = _M.new('/test')
    r:get('/m1', function(param, ctx)
        dump(param, 'm1hit')
    end)
    r:post('/k1/:seek/:form', function(param, ctx)
        dump(param, 'seek1')
    end)

    r:post('/k1/:seek', function(param, ctx)
        dump(param, 'seek2')
    end)
    r:post('/xx1', function(param, ctx)
        dump(param, 'xx1')
    end)
    local uri = '/test/k1/xx1/'
    ngx.say(uri)
    r:handle({ uri = uri, method = 'POST' })
end

return _M

--GET = ngx.HTTP_GET, -- 2
--HEAD = ngx.HTTP_HEAD, -- 4
--POST = ngx.HTTP_POST, -- 8
--PUT = ngx.HTTP_PUT, --16
--DELETE = ngx.HTTP_DELETE, -- 32
--MKCOL = ngx.HTTP_MKCOL, -- 64
--COPY = ngx.HTTP_COPY, -- 128
--MOVE = ngx.HTTP_MOVE, -- 256
--OPTIONS = ngx.HTTP_OPTIONS, --512
--PATCH = ngx.HTTP_PATCH, --16384
