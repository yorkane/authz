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
    release_state(ngx.ctx.authz_request_body)
end

-- 该规则是否会改写正文（替换或过滤）。正文改写必须在未压缩的字节上进行，
-- 因此代理层要提前向上游声明不接受压缩；只看响应头/状态码则不需要。
function _M.writes_body(rule)
    if type(rule) ~= "table" or rule.enabled == false then return false end
    if type(rule.body) == "string" and rule.body ~= "" then return true end
    return type(rule.rewrites) == "table" and #rule.rewrites > 0
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

-- ── 条件匹配（对齐 APISIX route vars，字段收敛为白名单）────────────────
-- 整条响应改写只在条件命中时生效；不命中则状态码、响应头、正文一起跳过。
-- 求值放在 header_filter：这是响应头与状态码刚刚就绪、又还没写任何东西的阶段。
--
-- 取值口径（写规则时要记住）：
--   uri            $request_uri，含查询串（/a/b.js?x=1），不含 scheme/host；
--   request_header 客户端发来的请求头（多值按 ", " 连接）；
--   response_header 上游响应头（多值按 ", " 连接）；
--   content_type   只看媒体类型本体，即去掉 "; charset=..." 后的部分，
--                  因此 "text/html" 能命中 "text/html; charset=utf-8"；
--   status         上游状态码（字符串比较，可用 contains/regex 做区段匹配）。
-- 操作符全部大小写敏感、语义单一：equals 精确相等，contains 子串包含，
-- regex 走 PCRE（"jo" 编译一次全局复用；要忽略大小写写内联 (?i)）。
local function header_value(headers, name)
    local value = headers[ name:lower() ]
    if value == nil then value = headers[name] end
    if type(value) == "table" then return table.concat(value, ", ") end
    if value == nil then return nil end
    return tostring(value)
end

local function condition_subject(cond)
    if cond.field == "uri" then
        return tostring(ngx.var.request_uri or "")
    elseif cond.field == "content_type" then
        return content_type_key()
    elseif cond.field == "status" then
        return tostring(upstream_status(tonumber(ngx.status) or 0))
    end
    local headers = cond.field == "request_header"
        and (ngx.req.get_headers() or {}) or (ngx.resp.get_headers() or {})
    return header_value(headers, cond.name or "")
end

local function condition_matches(cond)
    local subject = condition_subject(cond)

    local result
    if cond.op == "exists" then
        result = subject ~= nil and subject ~= ""
    elseif cond.op == "missing" then
        result = subject == nil or subject == ""
    elseif subject == nil then
        -- 头缺失时 equals/contains/regex 一律不命中，避免 nil 参与比较。
        result = false
    elseif cond.op == "equals" then
        result = subject == (cond.value or "")
    elseif cond.op == "contains" then
        result = subject:find(cond.value or "", 1, true) ~= nil
    else
        local matched, _, err = ngx.re.find(subject, cond.value or "", "jo")
        result = err == nil and matched ~= nil and matched ~= false
    end
    if cond.negate then result = not result end
    return result
end

-- 无条件（含畸形条件）恒命中：向后兼容此前所有不带条件的规则。
function _M.conditions_match(rule)
    local conditions = type(rule) == "table" and rule.conditions or nil
    if type(conditions) ~= "table" then return true end
    local list = conditions.match
    if type(list) ~= "table" or #list == 0 then return true end
    if conditions.logic == "any" then
        for _, cond in ipairs(list) do
            if condition_matches(cond) then return true end
        end
        return false
    end
    for _, cond in ipairs(list) do
        if not condition_matches(cond) then return false end
    end
    return true
end

-- 代理阶段（请求还没有响应）能否判定条件命中。响应侧字段
-- （response_header / content_type / status）此刻还是未知数，按「可能命中」处理：
--   * all：任一已知条件为假即整条为假；
--   * any：任一已知条件为真即整条为真。
-- 用途是给 upstream_accept_encoding 做优化：条件明确不命中时就不必强制上游返回
-- 未压缩正文。命中与否的最终判定仍在 header_filter（见 conditions_match）。
local function request_phase_evaluable(cond)
    return cond.field == "uri" or cond.field == "request_header"
end

local function request_phase_match(conditions)
    if type(conditions) ~= "table" then return true end
    local list = conditions.match
    if type(list) ~= "table" or #list == 0 then return true end
    local unknown = false
    if conditions.logic == "any" then
        for _, cond in ipairs(list) do
            if request_phase_evaluable(cond) and condition_matches(cond) then return true end
            if not request_phase_evaluable(cond) then unknown = true end
        end
        return unknown or false
    end
    for _, cond in ipairs(list) do
        if request_phase_evaluable(cond) then
            if not condition_matches(cond) then return false end
        else
            unknown = true
        end
    end
    return unknown or true
end

-- 代理层询问：这条规则会不会真的改写正文（考虑请求期能判定的条件）。
function _M.body_rewrite_applies(rule)
    if not _M.writes_body(rule) then return false end
    return request_phase_match(type(rule) == "table" and rule.conditions or nil)
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

-- PCRE 逐字引用：把任意文本包成 \Q...\E，元字符全部失去模式含义。
-- 文本自带 \E 时无法在引用内表达（PCRE 规范），以「结束引用 + \E
-- （引用外写两个反斜杠 = 匹配一个字面反斜杠）+ E + 重新进入引用」规范化。
-- 已在目标 OpenResty（PCRE2）上验证：a.b 不再匹配 axb，a\\Eb、a|b 均逐字命中。
local B = string.char(92)
local function quote_literal(text)
    return B .. "Q" .. text:gsub(B .. "E", B .. "E" .. B .. B .. "E" .. B .. "E") .. B .. "E"
end

local function apply_rewrites(rules, body)
    for _, rule in ipairs(rules or {}) do
        if rule.regex then
            -- ngx.re.gsub 返回 value, substitutions, err。
            local replaced, _, err = ngx.re.gsub(body, rule.source, rule.target, "jo")
            if replaced and not err then body = replaced end
        elseif rule.source ~= "" then
            -- 字面量匹配同样交给 ngx.re（PCRE）执行而不是 Lua 原生字符串查找：
            -- 替换文本经回调原样插回，$1 之类的引用不会在替换值里被二次展开。
            local replacement = rule.target
            local replaced, _, err = ngx.re.gsub(body, quote_literal(rule.source),
                function() return replacement end, "jo")
            if replaced and not err then body = replaced end
        end
    end
    return body
end

-- 请求正文改写的安全范围：请求没有响应那样的“跳过标记”可看（改写发生在
-- 转发前，客户端看不到 X-Authz-Rewrite），所以条件收紧：
--   * GET/HEAD 等无正文方法直接跳过；
--   * Content-Length 缺失（分块传输）或超过缓冲上限时跳过——分块请求体
--     无法安全地整体缓冲后重放；
--   * filter 模式下非文本类 Content-Type 或声明了压缩的请求跳过，避免破坏
--     二进制/上传内容（replace 模式整体替换，对原类型无要求）；
--   * WebSocket 升级请求跳过。
-- 复用与响应侧相同的 worker 级缓冲预算（release_buffer 在 log 阶段统一归还）。
function _M.request_body_mode(rule)
    if type(rule) ~= "table" or rule.enabled == false then return nil end
    local method = ngx.req.get_method()
    if method == "GET" or method == "HEAD" then return nil end
    if tostring(ngx.var.authz_websocket or "") == "1" then return nil end
    local length = tonumber(ngx.var.http_content_length or "") or -1
    if length < 0 then return nil end
    if length > MAX_BODY_BYTES then return nil end
    local mode
    if type(rule.body) == "string" and rule.body ~= "" then
        mode = "replace"
    elseif type(rule.rewrites) == "table" and #rule.rewrites > 0 then
        mode = "filter"
    else
        return nil
    end
    if mode == "filter" then
        local encoding = first_header_value(ngx.var.http_content_encoding):lower()
        if encoding ~= "" and encoding ~= "identity" then return nil end
        local key = first_header_value(ngx.var.http_content_type):lower():match("^[^;%s]+") or ""
        if not TEXTUAL_CONTENT_TYPES[key] then return nil end
    end
    return mode
end

-- access 阶段执行请求正文改写（须在 proxy 转发前完成）：
-- 缓冲整个请求体 -> 应用替换/过滤 -> 写回并同步 Content-Length。
-- 与响应侧同样的“超限放弃”策略：宁可原样转发也不截断请求体。
function _M.body_rewrite(mode, rule)
    if not try_reserve(MAX_BODY_BYTES) then return false end
    local state = { reserved = MAX_BODY_BYTES }
    ngx.ctx.authz_request_body = state
    local ok, err = pcall(function()
        ngx.req.read_body()
        local original = ngx.req.get_body_data()
        if original == nil then
            local file = ngx.req.get_body_file()
            if file then
                local handle = io.open(file, "rb")
                if handle then
                    original = handle:read(MAX_BODY_BYTES + 1)
                    handle:close()
                end
            end
        end
        original = original or ""
        if #original > MAX_BODY_BYTES then return end
        local replacement
        if mode == "replace" then
            replacement = rule.body
        else
            local replaced = apply_rewrites(rule.rewrites, original)
            -- 过滤结果为空回退原文，防止正则写错把请求体抹掉。
            replacement = replaced ~= "" and replaced or original
        end
        if replacement == nil then return end
        if replacement ~= original then
            ngx.req.set_body_data(replacement)
            ngx.req.set_header("Content-Length", tostring(#replacement))
            if type(rule.content_type) == "string" and rule.content_type ~= "" then
                ngx.req.set_header("Content-Type", rule.content_type)
            end
        end
    end)
    release_state(state)
    return ok
end


function _M.header_filter()
    local rule = current_rule()
    if not rule then return end

    -- 条件不命中：整条规则当作没配置，不改状态码、不动响应头、不缓冲正文。
    -- 不写 X-Authz-Rewrite 跳过标记：无条件规则也走同一条路径，标记只用于
    -- 「本该改写但被安全限制拦下」的场景，否则每条正常响应都会多一个噪声头。
    if not _M.conditions_match(rule) then return end

    local original_status = tonumber(ngx.status) or 0
    if tonumber(rule.status) and tonumber(rule.status) > 0 then
        ngx.status = tonumber(rule.status)
    end
    -- 防御语义：先写 headers 再执行 remove_headers，保证「删除优先」。
    -- 若同一规则既 set 又 strip 同名头（配置错误），删除在后生效，
    -- 该头最终不会出现在响应里——宁可漏掉一次改写也不让敏感值泄露。
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
    local encoding = first_header_value(ngx.header.content_encoding):lower()
    -- identity 只是显式声明“未压缩”，正文仍是明文，可以安全改写。
    local compressed = encoding ~= "" and encoding ~= "identity"
    if status ~= 200 then
        skip_reason = "status"
    elseif ngx.req.get_method() == "HEAD" then
        skip_reason = "head"
    elseif tostring(ngx.var.authz_websocket or "") == "1" then
        skip_reason = "websocket"
    elseif compressed then
        -- 上游已压缩：改写压缩字节没有意义。让上游返回未压缩内容才会生效
        -- （配了正文改写的绑定由 proxy 自动把上游请求改成 identity，
        --   见 proxy.apply_headers；显式的 Header 覆盖优先级更高）。
        skip_reason = "encoded"
    elseif first_header_value(ngx.header.content_range) ~= "" then
        skip_reason = "range"
    elseif mode == "filter" and first_header_value(ngx.header.content_length) == "0" then
        -- filter 模式下空响应没有可过滤的正文：直接透传并保留 Content-Length: 0，
        -- 避免「无匹配回退原文」路径撤掉分帧头。replace 模式不受影响。
        skip_reason = "empty"
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
    -- 同一原因要撤掉上游的校验器：正文已经变了，ETag / Last-Modified 仍是上游
    -- 旧内容的指纹。终端一旦启用浏览器缓存（网关不注入 no-store，缓存头由上游
    -- 决定），浏览器会拿旧校验器做条件请求，nginx 据上游 ETag 直接回 304，
    -- 客户端于是把未改写的上游正文当成最新内容。撤掉后浏览器退回整包回源。
    ngx.header.etag = nil
    ngx.header.last_modified = nil
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
    -- 条件匹配：运行期第二道防线（保存侧已做过 PCRE 探测与字段白名单）。
    -- 任何畸形条件条目直接丢弃；全部条目无效时整条 conditions 置空 = 恒命中，
    -- 与不带条件的历史配置保持一致。
    local conditions = decoded.conditions
    if type(conditions) == "table" then
        local list = conditions.match
        if list == nil then list = conditions end
        if type(list) == "table" then
            local match = {}
            for _, item in ipairs(list) do
                if type(item) == "table" then
                    local field = tostring(item.field or "")
                    local op = tostring(item.op or "regex")
                    local cond_value = tostring(item.value or "")
                    local name = tostring(item.name or "")
                    local ok_field = field == "uri" or field == "request_header"
                        or field == "response_header" or field == "content_type"
                        or field == "status"
                    local ok_op = op == "equals" or op == "contains" or op == "regex"
                        or op == "exists" or op == "missing"
                    local needs_value = op ~= "exists" and op ~= "missing"
                    local needs_name = field == "request_header" or field == "response_header"
                    if ok_field and ok_op and
                        (not needs_value or (cond_value ~= "" and not cond_value:find("%c"))) and
                        (not needs_name or (name ~= "" and not name:find("%c"))) then
                        match[#match + 1] = {
                            field = field,
                            name = needs_name and name or nil,
                            op = op,
                            value = cond_value ~= "" and cond_value or nil,
                            negate = item.negate == true,
                        }
                    end
                end
            end
            if #match > 0 then
                rule.conditions = {
                    logic = tostring(conditions.logic or "all"):lower() == "any" and "any" or "all",
                    match = match,
                }
            end
        end
    end
    return rule
end

-- 运行期兜底名单：与 validation 的 REQUEST_HEADER_BLOCKED 保持同一口径
-- （校验层保存时已拒一次，这里防手工改库绕过）。托管头（Host/Cookie/
-- Origin/Forwarded/X-Forwarded-*/X-Real-IP/X-Authz-User|Source|Identity）
-- 已开放改写，由 proxy.lua 写入 $authz_* 变量后随 proxy_set_header 下发。
-- 仍禁止：分帧与 hop-by-hop 头，以及网关自身凭据头（X-Authz-Key/X-API-Key/
-- X-Role-Key，proxy_set_header 已置空，开放改写等于把网关钥匙递给上游）。
local REQUEST_BLOCKED = {
    ["content-length"] = true, ["transfer-encoding"] = true,
    connection = true, ["keep-alive"] = true, upgrade = true,
    te = true, trailer = true,
    ["x-authz-key"] = true, ["x-api-key"] = true, ["x-role-key"] = true,
}

-- 网关身份断言头：X-Authz-* 前缀默认拦截，只有这三个显式放行。
local REQUEST_IDENTITY_OK = {
    ["x-authz-user"] = true, ["x-authz-source"] = true, ["x-authz-identity"] = true,
}

local function request_header_ok(name)
    local lower = tostring(name or ""):lower()
    if REQUEST_BLOCKED[lower] then return false end
    if REQUEST_IDENTITY_OK[lower] then return true end
    if lower:sub(1, 8) == "x-authz-" then return false end
    if lower:sub(1, 6) == "proxy-" then return false end
    return true
end

-- 绑定缓存里的 request_rewrite 同样是 JSON 文本；解码 + 白名单过滤 +
-- base64 正文解出，与响应侧 parse 对称。无有效内容时返回 nil。
function _M.parse_request(raw)
    local text = tostring(raw or "")
    if text == "" then return nil end
    local decoded = cjson.decode(text)
    if type(decoded) ~= "table" or decoded.enabled == false then return nil end
    local rule = { headers = {}, append_headers = {}, remove_headers = {}, rewrites = {} }
    for _, item in ipairs(type(decoded.headers) == "table" and decoded.headers or {}) do
        local name = tostring(type(item) == "table" and item.name or "")
        local value = type(item) == "table" and tostring(item.value or "") or ""
        if name ~= "" and value ~= "" and request_header_ok(name) and not value:find("%c") then
            rule.headers[#rule.headers + 1] = { name = name, value = value }
        end
    end
    for _, item in ipairs(type(decoded.append_headers) == "table" and decoded.append_headers or {}) do
        local name = tostring(type(item) == "table" and item.name or "")
        local value = type(item) == "table" and tostring(item.value or "") or ""
        if name ~= "" and value ~= "" and request_header_ok(name) and not value:find("%c") then
            rule.append_headers[#rule.append_headers + 1] = { name = name, value = value }
        end
    end
    for _, name in ipairs(type(decoded.remove_headers) == "table" and decoded.remove_headers or {}) do
        local clean = tostring(name)
        if clean ~= "" and request_header_ok(clean) then
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
    if type(decoded.content_type) == "string" and decoded.content_type ~= "" then
        rule.content_type = decoded.content_type
    end
    if #rule.headers == 0 and #rule.append_headers == 0
        and #rule.remove_headers == 0 and not rule.body
        and #rule.rewrites == 0 then
        return nil
    end
    return rule
end

return _M
