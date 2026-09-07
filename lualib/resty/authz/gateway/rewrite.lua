-- 绑定级响应改写（对齐 APISIX response-rewrite 的 status/headers/body 子集）。
--
-- 网关在 header_filter / body_filter 阶段按当前 Host 命中的绑定改写上游响应。
-- 这里是校验层之外的第二道防线：即使数据库被手工改过，也不会放开危险响应头。
--   * 网关身份头、hop-by-hop、分帧头、Set-Cookie 与安全响应头不可被改写或删除；
--   * 正文改写需要缓冲整个响应，因此只作用于有限范围：HEAD 之外、上游 200、
--     未压缩、无 Content-Range、非 WebSocket、且体积在缓冲上限之内；
--   * 正文“过滤”（rewrites）额外要求文本类 Content-Type，避免破坏二进制内容；
--   * 超出缓冲上限时连同已缓冲内容原样放行，宁可放弃改写也不截断响应。

local cjson = require "cjson.safe"

local _M = {}

-- cache -> rewrite -> resolver 会构成模块环（resolver 已 require cache），
-- 因此 resolver 与 authz 门面都在调用时惰性加载。
local resolver, authz
local function resolve_rule()
    if not resolver then resolver = require "resty.authz.gateway.resolver" end
    if not authz then authz = require "resty.authz" end
    -- resolver.resolve 返回 port, websocket, target_ip, binding（pcall 前置 ok）。
    local ok, _, _, _, binding = pcall(resolver.resolve, ngx.var.host, authz.config)
    if not ok or not binding then return nil end
    return binding.response_rewrite
end

local MAX_BODY_BYTES = 1024 * 1024

-- 正文改写需要在 worker 内缓冲整个响应。除单响应上限外，再加一层 worker 级预算：
-- 每个正在改写的响应按上限整块预留，预算耗尽时新响应直接跳过改写（原样流式透传），
-- 避免大量并发大响应把 worker 内存吃满。预留随 log 阶段兜底释放（见 release_buffer），
-- 客户端中途断开也不会泄漏配额。
-- 预算在首次使用时才解析：本模块经 init.lua 在 init_by_lua 期就被 require，
-- 那时 config.load() 还没跑，直接读 env/config 会拿到 nil。
local buffer = { reserved = 0, budget = nil }

local function budget_bytes()
    if not buffer.budget then
        local config = require("resty.authz").config or {}
        buffer.budget = (config.rewrite_buffer_mb or 64) * 1024 * 1024
    end
    return buffer.budget
end

local function try_reserve(bytes)
    if buffer.reserved + bytes > budget_bytes() then return false end
    buffer.reserved = buffer.reserved + bytes
    return true
end

local function release_state(state)
    if not state or state.released then return end
    state.released = true
    buffer.reserved = math.max(0, buffer.reserved - (state.reserved or 0))
end

-- 由 log_by_lua 调用：请求结束（含客户端断开、上游报错）时归还预留。
function _M.release_buffer()
    release_state(ngx.ctx.authz_response_body)
end

local BLOCKED_HEADERS = {
    ["content-length"] = true, ["transfer-encoding"] = true,
    connection = true, ["keep-alive"] = true, upgrade = true,
    te = true, trailer = true,
    ["set-cookie"] = true, ["content-encoding"] = true,
    ["x-frame-options"] = true, ["content-security-policy"] = true,
    ["strict-transport-security"] = true, ["x-content-type-options"] = true,
    ["permissions-policy"] = true,
}

-- 只做“文本类内容”的正文过滤；其余（图片、音视频、下载流）一律跳过。
local TEXTUAL_CONTENT_TYPES = {
    ["text/html"] = true, ["text/plain"] = true, ["text/css"] = true,
    ["text/xml"] = true, ["text/javascript"] = true, ["text/event-stream"] = false,
    ["application/javascript"] = true, ["application/json"] = true,
    ["application/xml"] = true, ["application/xhtml+xml"] = true,
    ["application/manifest+json"] = true, ["application/x-www-form-urlencoded"] = true,
    ["image/svg+xml"] = true,
}

local function header_allowed(name)
    local lower = tostring(name or ""):lower()
    if lower == "" or BLOCKED_HEADERS[lower] then return false end
    if lower:sub(1, 8) == "x-authz-" then return false end
    if lower:sub(1, 12) == "x-forwarded-" then return false end
    if lower:sub(1, 6) == "proxy-" then return false end
    return true
end

local function first_header_value(value)
    if type(value) == "table" then value = value[1] end
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function content_type_key()
    return first_header_value(ngx.header.content_type):lower():match("^[^;%s]+") or ""
end

local function upstream_status(fallback)
    local raw = tostring(ngx.var.upstream_status or "")
    return tonumber(raw:match("([^,%s]+)$")) or fallback
end

-- header_filter 与 body_filter 分处两个阶段，且代理可能经 ngx.exec 跳转，
-- 因此 header_filter 重新命中绑定，正文改写状态记在 ngx.ctx 供 body_filter 使用。
local function current_rule()
    local target = ngx.var.authz_target
    if not target or target == "" then return nil end
    local rule = resolve_rule()
    if type(rule) ~= "table" or rule.enabled == false then return nil end
    return rule
end

local function literal_replace_all(haystack, needle, replacement)
    if needle == "" then return haystack end
    local out, from, found = {}, 1, false
    while true do
        local start_index, end_index = haystack:find(needle, from, true)
        if not start_index then
            out[#out + 1] = haystack:sub(from)
            break
        end
        found = true
        out[#out + 1] = haystack:sub(from, start_index - 1)
        out[#out + 1] = replacement
        from = end_index + 1
    end
    return table.concat(out), found
end

local function apply_rewrites(rules, body)
    for _, rule in ipairs(rules or {}) do
        if rule.regex then
            -- ngx.re.gsub 返回 value, substitutions, err。
            local replaced, _, err = ngx.re.gsub(body, rule.source, rule.target, "jo")
            if replaced and not err then body = replaced end
        else
            body = (literal_replace_all(body, rule.source, rule.target))
        end
    end
    return body
end

function _M.header_filter()
    local rule = current_rule()
    if not rule then return end

    local original_status = tonumber(ngx.status) or 0
    if tonumber(rule.status) and tonumber(rule.status) > 0 then
        ngx.status = tonumber(rule.status)
    end
    for _, header in ipairs(rule.headers or {}) do
        if header_allowed(header.name) then
            ngx.header[header.name] = header.value
        end
    end
    for _, name in ipairs(rule.remove_headers or {}) do
        if header_allowed(name) then ngx.header[name] = nil end
    end

    local rewrites = type(rule.rewrites) == "table" and rule.rewrites or {}
    local mode
    if type(rule.body) == "string" and rule.body ~= "" then
        mode = "replace"
    elseif #rewrites > 0 then
        mode = "filter"
    end
    if not mode then return end

    -- 以下情形无法安全缓冲或改写正文：只保留状态码与响应头改写。
    local status = upstream_status(original_status)
    local skip_reason
    if status ~= 200 then
        skip_reason = "status"
    elseif ngx.req.get_method() == "HEAD" then
        skip_reason = "head"
    elseif tostring(ngx.var.authz_websocket or "") == "1" then
        skip_reason = "websocket"
    elseif first_header_value(ngx.header.content_encoding) ~= "" then
        -- 上游已压缩：改写压缩字节没有意义。让上游返回未压缩内容才会生效
        -- （可在绑定的 Header 覆盖里把请求的 Accept-Encoding 置空）。
        skip_reason = "encoded"
    elseif first_header_value(ngx.header.content_range) ~= "" then
        skip_reason = "range"
    elseif mode == "filter" and not TEXTUAL_CONTENT_TYPES[content_type_key()] then
        skip_reason = "type"
    end
    if skip_reason then
        -- 静默失效比报错更难排查，这里显式标记跳过原因供运维核对。
        ngx.header["X-Authz-Rewrite"] = "skipped=" .. skip_reason
        return
    end
    if not try_reserve(MAX_BODY_BYTES) then
        ngx.header["X-Authz-Rewrite"] = "skipped=memory"
        return
    end

    -- 改写后长度必然变化，取消 Content-Length 交给分块编码，避免分帧不一致。
    ngx.header.content_length = nil
    if first_header_value(rule.content_type) ~= "" then
        ngx.header.content_type = rule.content_type
    end
    ngx.ctx.authz_response_body = {
        mode = mode,
        body = mode == "replace" and rule.body or nil,
        rewrites = rewrites,
        chunks = {},
        total = 0,
        reserved = MAX_BODY_BYTES,
    }
end

function _M.body_filter()
    local state = ngx.ctx.authz_response_body
    if not state then return end
    local chunk = tostring(ngx.arg[1] or "")
    local eof = ngx.arg[2] == true

    if state.dropped then return end
    if state.total + #chunk > MAX_BODY_BYTES then
        local pending = table.concat(state.chunks, "")
        state.dropped = true
        state.chunks = {}
        state.total = 0
        -- 已确认超限：立刻归还预留，后续分片继续流式透传。
        release_state(state)
        -- 超限放弃改写：把已缓冲内容与本片一起原样发出。
        ngx.arg[1] = pending .. chunk
        return
    end
    if #chunk > 0 then
        state.chunks[#state.chunks + 1] = chunk
        state.total = state.total + #chunk
    end
    if not eof then
        ngx.arg[1] = ""
        return
    end

    if state.mode == "replace" then
        ngx.arg[1] = state.body or ""
        release_state(state)
        return
    end
    local original = table.concat(state.chunks, "")
    local replaced = apply_rewrites(state.rewrites, original)
    -- 过滤结果为空时回退原文，避免正则写错把整个页面抹掉。
    ngx.arg[1] = replaced ~= "" and replaced or original
    release_state(state)
end

-- 绑定缓存里的 response_rewrite 是 JSON 文本；这里解码并做运行期整形，
-- base64 正文在此解出真实字节，避免每个响应重复解码。
function _M.parse(raw)
    local text = tostring(raw or "")
    if text == "" then return nil end
    local decoded = cjson.decode(text)
    if type(decoded) ~= "table" then return nil end
    local rule = {
        enabled = decoded.enabled ~= false,
        status = tonumber(decoded.status) or 0,
        headers = {},
        remove_headers = {},
        rewrites = {},
    }
    for _, header in ipairs(type(decoded.headers) == "table" and decoded.headers or {}) do
        local name = tostring(type(header) == "table" and header.name or "")
        local value = tostring(type(header) == "table" and header.value or "")
        if name ~= "" and value ~= "" and header_allowed(name) and not value:find("%c") then
            rule.headers[#rule.headers + 1] = { name = name, value = value }
        end
    end
    for _, name in ipairs(type(decoded.remove_headers) == "table" and decoded.remove_headers or {}) do
        local clean = tostring(name)
        if clean ~= "" and header_allowed(clean) then
            rule.remove_headers[#rule.remove_headers + 1] = clean
        end
    end
    for _, item in ipairs(type(decoded.rewrites) == "table" and decoded.rewrites or {}) do
        if type(item) == "table" then
            local source = tostring(item.source or "")
            local target = tostring(item.target or "")
            if source ~= "" and not source:find("%c") and not target:find("%c") then
                rule.rewrites[#rule.rewrites + 1] = {
                    source = source, target = target, regex = item.regex == true,
                }
            end
        end
    end
    if type(decoded.body) == "string" and decoded.body ~= "" then
        if decoded.body_base64 == true then
            local decoded_body = ngx.decode_base64(decoded.body)
            if decoded_body then rule.body = decoded_body end
        else
            rule.body = decoded.body
        end
    end
    if type(decoded.content_type) == "string" then
        rule.content_type = decoded.content_type
    end
    return rule
end

return _M
