local cjson = require "cjson.safe"
local identity = require "resty.authz.identity"
local bindings = require "resty.authz.repository.bindings"
local remote_users = require "resty.authz.repository.remote_users"
local target = require "resty.authz.target"
local users = require "resty.authz.repository.users"

local common = require "resty.authz.api.common"
local _M = {}

local HUMAN_ROLE_SET, POLICY_ROLE_SET, HTTP_METHOD_SET = {}, {}, {}
for _, role in ipairs(common.HUMAN_ROLES) do HUMAN_ROLE_SET[role] = true end
for _, role in ipairs(common.POLICY_ROLES) do POLICY_ROLE_SET[role] = true end
for _, method in ipairs(common.HTTP_METHODS) do HTTP_METHOD_SET[method] = true end

local BINDING_PROXY_FIELDS = {
    "upstream_host", "forwarded_host", "forwarded_proto", "forwarded_port",
    "origin_mode", "custom_origin", "simulate_local", "local_ip", "upstream_scheme",
    "upstream_ssl_verify", "upstream_path",
    "request_rewrite",
    "response_rewrite",
}
local FORWARDED_PROTO_SET = { [""] = true, http = true, https = true }
local UPSTREAM_SCHEME_SET = { http = true, https = true }
local ORIGIN_MODE_SET = {
    auto = true, preserve = true, rewrite = true, remove = true, custom = true,
}

-- 响应改写（参考 APISIX response-rewrite 的 status/headers/body 子集）硬性限额：
-- 正则在网关 worker 内执行，规则数量、长度和正文体积都必须有上限，避免放大成 DoS。
local RESPONSE_REWRITE_MAX_RULES = 16
local RESPONSE_REWRITE_MAX_PATTERN = 512
local RESPONSE_REWRITE_MAX_REPLACEMENT = 4096
local RESPONSE_REWRITE_MAX_BODY = 65536
local RESPONSE_REWRITE_MAX_JSON = 131072

local function config()
    return require("resty.authz").config
end

function _M.normalize_roles(value)
    local input = type(value) == "table" and value or { tostring(value or "user") }
    local roles, seen = {}, {}
    for _, item in ipairs(input) do
        for role in tostring(item):gmatch("[^,%s]+") do
            role = role:lower()
            if not HUMAN_ROLE_SET[role] then return nil, "角色仅支持 admin、staff、user、viewer" end
            if not seen[role] then
                seen[role] = true
                roles[#roles + 1] = role
            end
        end
    end
    if #roles == 0 then roles[1] = "user" end
    table.sort(roles)
    return table.concat(roles, ",")
end

function _M.normalize_http_methods(value)
    local input = type(value) == "table" and value or { tostring(value or "*") }
    local selected = {}
    for _, item in ipairs(input) do
        for method in tostring(item):gmatch("[^,%s]+") do
            method = method:upper()
            if not HTTP_METHOD_SET[method] then return nil, "动作必须是标准 HTTP 方法或 *" end
            if method == "*" then return "*" end
            selected[method] = true
        end
    end
    local methods = {}
    for _, method in ipairs(common.HTTP_METHODS) do
        if method ~= "*" and selected[method] then methods[#methods + 1] = method end
    end
    if #methods == 0 then return nil, "至少选择一个 HTTP 方法" end
    return table.concat(methods, ",")
end

function _M.parse_policy_object(value)
    local object = tostring(value or ""):gsub("%s+", "")
    if object == "" then object = "/*" end
    if #object > 512 or object:find(",", 1, true) or object:find("|", 1, true) or
        object:find("%c") then return nil, "对象格式不合法" end
    if object == "/*" then return { value = object, kind = "global", path = "/*" } end
    local port_value, path = object:match("^/(%d+)(/.*)$")
    local port = tonumber(port_value)
    local current = config()
    if not port or port < current.port_min or port > current.port_max then
        return nil, "对象必须使用 /<端口><路径> 格式，且端口在允许范围内"
    end
    return { value = "/" .. tostring(port) .. path, kind = "port", port = port, path = path }
end

local function valid_host(domain)
    return ngx.re.match(domain,
        [[^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$]]) ~= nil
end

local function valid_domain_prefix(prefix)
    return ngx.re.match(prefix, [[^[a-z0-9]([a-z0-9-]*[a-z0-9])?$]]) ~= nil
end

-- 请求改写：这些请求头由 server.conf 的 proxy_set_header 或绑定专属字段
-- （upstream_host/forwarded_*/origin 等）统一管控，改写请求不允许触碰，
-- 否则会出现「保存成功但永不生效」的幽灵配置。hop-by-hop 与分帧头
-- （keep-alive/te/trailer）同样禁止，避免破坏代理语义。
-- Accept-Encoding 特意不禁止：正文改写需要上游返回未压缩字节，而个别
-- 上游只接受特定压缩协商时，允许用户显式覆盖。
local REQUEST_HEADER_BLOCKED = {
    host = true, cookie = true, origin = true, forwarded = true,
    ["x-authz-user"] = true, ["x-authz-source"] = true, ["x-authz-identity"] = true,
    ["x-authz-key"] = true, ["x-real-ip"] = true,
    ["x-forwarded-for"] = true, ["x-forwarded-host"] = true,
    ["x-forwarded-proto"] = true, ["x-forwarded-port"] = true,
    ["content-length"] = true, ["transfer-encoding"] = true,
    connection = true, ["keep-alive"] = true, upgrade = true,
    te = true, trailer = true,
}

local function request_header_allowed(name)
    local lower = name:lower()
    if REQUEST_HEADER_BLOCKED[lower] then return false end
    if lower:sub(1, 8) == "x-authz-" then return false end
    if lower:sub(1, 12) == "x-forwarded-" then return false end
    if lower:sub(1, 6) == "proxy-" then return false end
    return true
end

-- 域名前缀是绑定的推荐（管理界面唯一）填法：只存最后一级前缀（如 code），
-- 入口域名由菜单和代理层按当前请求 Host 动态拼出 <前缀>-<节点>.<泛域>，
-- 保存时不依赖请求域名，同一套绑定天然适配所有 / 多级入口域名。
-- API 仍接受完整的精确域名（不物化、只精确匹配），供非泛域入口和存量数据
-- 使用；编辑时允许把与库中一致的原值原样提交。
function _M.normalize_binding_domain(value, existing_domain)
    local domain = tostring(value or ""):lower():gsub("%s+", ""):gsub(":%d+$", "")
    if existing_domain and domain == tostring(existing_domain):lower() then
        return domain
    end
    if valid_host(domain) then return domain end
    if not valid_domain_prefix(domain) then return nil end
    return domain
end

-- 通用 JSON 解码：请求/响应改写共用。输入可以是 JSON 对象（管理 UI 提交），
-- 容忍尾随逗号等宽松写法：先严格解码，失败时剥离尾随逗号重试；仍失败即拒绝。
local function decode_response_rewrite(value)
    if type(value) == "table" then return value end
    local raw = tostring(value)
    if raw:gsub("^%s+", ""):gsub("%s+$", "") == "" then return {} end
    local decoded = cjson.decode(raw)
    if type(decoded) == "table" then return decoded end
    -- 括号必要：gsub 返回两个值，cjson.decode 的 C 检查会因多余参数直接抛错。
    decoded = cjson.decode((raw:gsub(",(%s*[%]}])", "%1")))
    if type(decoded) == "table" then return decoded end
    return nil
end

-- 请求改写配置字段：改写到上游的请求头，JSON 结构与 response_rewrite 的
-- headers 子集对齐。
--   enabled         是否启用改写
--   headers         请求头改写（对象，值为 null 表示删除）
--   remove_headers 显式删除列表（数组）
--   body            整体替换请求正文（仅对文本类请求生效，见网关实现）
--   body_base64     body 以 base64 提供
--   content_type    替换正文时写回上游的 Content-Type
--   rewrites        正文过滤规则（与 response_rewrite 的 rewrites 同构）
-- 没有 status 改写：请求侧不存在状态码语义。
local REQUEST_REWRITE_FIELDS = {
    enabled = true, headers = true, remove_headers = true,
    body = true, body_base64 = true, content_type = true, rewrites = true,
}

-- 前向声明：正文规范化与 Content-Type 校验定义在响应改写一节，
-- 请求/响应两侧共用（Lua local 可见性要求先声明后引用）。
local normalize_rewrites, valid_content_type

function _M.normalize_request_rewrite(value)
    if value == nil or value == cjson.null then return "" end
    if type(value) == "string" and #value > RESPONSE_REWRITE_MAX_JSON then
        return nil, "请求改写配置过大", 422
    end
    local config = decode_response_rewrite(value)
    if not config then return nil, "请求改写配置必须是合法的 JSON 对象", 422 end
    for key in pairs(config) do
        if not REQUEST_REWRITE_FIELDS[key] then
            return nil, "请求改写不支持字段 「" .. tostring(key) .. "」", 422
        end
    end
    local enabled = config.enabled
    enabled = not (enabled == false or enabled == 0 or enabled == "false")

    local set, remove, seen = {}, {}, {}
    local function reject_name(name)
        if #name < 1 or #name > 128 or
            not ngx.re.match(name, [[^[A-Za-z0-9][A-Za-z0-9_-]*$]]) then
            return "请求改写 Header 名称只能包含字母、数字、下划线和中划线"
        end
        if not request_header_allowed(name) then
            return "请求改写不允许修改 Header 「" .. name .. "」（由网关控制）"
        end
        return nil
    end
    if config.headers ~= nil and config.headers ~= cjson.null then
        if type(config.headers) ~= "table" then
            return nil, "请求改写 headers 必须是对象", 422
        end
        for raw_name, raw_value in pairs(config.headers) do
            local name = tostring(raw_name):gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" then
                local err = reject_name(name)
                if err then return nil, err, 422 end
                local lower = name:lower()
                if raw_value == nil or raw_value == cjson.null then
                    -- 显式删除语义（等价于 remove_headers 里列出该头）。
                    if not seen[lower] then seen[lower] = { name = name, value = nil } end
                else
                    local header_value = tostring(raw_value)
                    if #header_value > 2048 then
                        return nil, "请求改写 Header 「" .. name .. "」的值不能超过 2048 字符", 422
                    end
                    if header_value:find("%c") then
                        return nil, "请求改写 Header 「" .. name .. "」的值不能包含控制字符", 422
                    end
                    seen[lower] = { name = name, value = header_value }
                end
            end
        end
    end
    if config.remove_headers ~= nil and config.remove_headers ~= cjson.null then
        if type(config.remove_headers) ~= "table" then
            return nil, "请求改写 remove_headers 必须是数组", 422
        end
        for _, raw_name in ipairs(config.remove_headers) do
            local name = tostring(raw_name or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" then
                local err = reject_name(name)
                if err then return nil, err, 422 end
                seen[name:lower()] = { name = name, value = nil }
            end
        end
    end
    local total = 0
    for _, item in pairs(seen) do
        total = total + 1
        if item.value == nil then
            remove[#remove + 1] = item.name
        else
            set[#set + 1] = { name = item.name, value = item.value }
        end
    end
    if total > 32 then return nil, "请求改写 Header 不能超过 32 条", 422 end

    -- 正文改写：与 response_rewrite 的 body/rewrites 子集同构（复用同一套
    -- 规范化与 PCRE 编译校验），语义换成「发往上游前生效」。
    local body_base64 = config.body_base64 == true or config.body_base64 == 1
    local body_text, body_is_json = nil, false
    local body = config.body
    if body ~= nil and body ~= cjson.null and body ~= "" then
        if type(body) == "table" then
            local encoded_body = cjson.encode(body)
            if not encoded_body then return nil, "请求改写 body 无法编码为 JSON", 422 end
            body_text, body_is_json = encoded_body, true
            if body_base64 then return nil, "JSON body 不能同时标记 base64", 422 end
        elseif type(body) == "string" then
            if body_base64 then
                if not ngx.decode_base64(body) then
                    return nil, "请求改写 body 不是合法的 base64", 422
                end
            elseif #body > RESPONSE_REWRITE_MAX_BODY then
                return nil, "请求改写 body 不能超过 " .. RESPONSE_REWRITE_MAX_BODY .. " 字符", 422
            end
            body_text = body
        else
            return nil, "请求改写 body 必须是文本、JSON 或留空", 422
        end
        -- 允许制表与换行；其余控制字符（含 NUL/ESC）一律拒绝，防止注入分帧字符。
        if body_text ~= nil and body_text:gsub("[\r\n\t]", ""):find("%c") then
            return nil, "请求改写 body 不能包含控制字符", 422
        end
    elseif body_base64 then
        return nil, "请求改写 base64 需要同时提供 body", 422
    end

    local content_type = config.content_type
    if content_type ~= nil and content_type ~= cjson.null then
        content_type = tostring(content_type):gsub("^%s+", ""):gsub("%s+$", "")
        if content_type ~= "" then
            if #content_type > 128 or not valid_content_type(content_type) then
                return nil, "请求改写 Content-Type 格式不合法", 422
            end
            if body_text == nil then
                return nil, "请求改写 Content-Type 需要同时提供 body", 422
            end
        end
    else
        content_type = nil
    end
    if body_is_json and not content_type then content_type = "application/json; charset=utf-8" end

    local rewrites, rewrites_err = normalize_rewrites(config.rewrites)
    if not rewrites then return nil, rewrites_err, 422 end
    if body_text ~= nil and #rewrites > 0 then
        return nil, "请求改写 body 与 rewrites 不能同时使用", 422
    end

    if #set == 0 and #remove == 0 and body_text == nil and #rewrites == 0 then
        return ""
    end
    table.sort(set, function(a, b) return a.name:lower() < b.name:lower() end)
    table.sort(remove)
    local out = {
        enabled = enabled,
        headers = set,
        remove_headers = #remove > 0 and remove or cjson.empty_array,
    }
    if body_text ~= nil then
        out.body = body_text
        out.body_base64 = body_base64 or nil
        out.content_type = content_type
    end
    if #rewrites > 0 then out.rewrites = rewrites end
    local encoded = cjson.encode(out)
    if not encoded then return nil, "请求改写配置编码失败", 422 end
    if #encoded > RESPONSE_REWRITE_MAX_JSON then return nil, "请求改写配置过大", 422 end
    return encoded
end

-- 响应改写：只允许覆盖“透传类”响应头。网关身份头、hop-by-hop 与分帧头一律拒绝，
-- Set-Cookie 也禁止（跨站植入会话 Cookie 是明确的攻击面），Location 由 status 3xx
-- 配合使用但同样禁止把用户输入直接拼进跳转目标以外的语义，这里保持仅允许普通头。
local RESPONSE_HEADER_BLOCKED = {
    ["content-length"] = true, ["transfer-encoding"] = true,
    connection = true, ["keep-alive"] = true, upgrade = true,
    te = true, trailer = true,
    ["set-cookie"] = true, ["content-encoding"] = true,
    ["x-frame-options"] = true, ["content-security-policy"] = true,
    ["strict-transport-security"] = true, ["x-content-type-options"] = true,
    ["permissions-policy"] = true,
}

local function response_header_allowed(name)
    local lower = name:lower()
    if RESPONSE_HEADER_BLOCKED[lower] then return false end
    if lower:sub(1, 8) == "x-authz-" then return false end
    if lower:sub(1, 12) == "x-forwarded-" then return false end
    if lower:sub(1, 6) == "proxy-" then return false end
    return true
end

-- 对齐 APISIX response-rewrite：headers 为改写（值为 null/空串表示删除），
-- remove_headers 为显式删除列表。两者都归一化成 set / remove 两个有序数组。
local function normalize_rewrite_headers(headers, remove_headers)
    local set, remove, seen = {}, {}, {}
    local function reject_name(name)
        if #name < 1 or #name > 128 or
            not ngx.re.match(name, [[^[A-Za-z0-9][A-Za-z0-9_-]*$]]) then
            return "响应改写 Header 名称只能包含字母、数字、下划线和中划线"
        end
        if not response_header_allowed(name) then
            return "响应改写不允许修改 Header 「" .. name .. "」"
        end
        return nil
    end
    if headers ~= nil and headers ~= cjson.null then
        if type(headers) ~= "table" then return nil, "响应改写 headers 必须是对象" end
        for raw_name, raw_value in pairs(headers) do
            local name = tostring(raw_name):gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" then
                local err = reject_name(name)
                if err then return nil, err end
                local lower = name:lower()
                if raw_value == nil or raw_value == cjson.null then
                    -- 显式删除语义（等价于 remove_headers 里列出该头）。
                    if not seen[lower] then seen[lower] = { name = name, value = nil } end
                else
                    local value = tostring(raw_value)
                    if #value > 2048 then
                        return nil, "响应改写 Header 「" .. name .. "」的值不能超过 2048 字符"
                    end
                    if value:find("%c") then
                        return nil, "响应改写 Header 「" .. name .. "」的值不能包含控制字符"
                    end
                    seen[lower] = { name = name, value = value }
                end
            end
        end
    end
    if remove_headers ~= nil and remove_headers ~= cjson.null then
        if type(remove_headers) ~= "table" then
            return nil, "响应改写 remove_headers 必须是数组"
        end
        for _, raw_name in ipairs(remove_headers) do
            local name = tostring(raw_name or ""):gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" then
                local err = reject_name(name)
                if err then return nil, err end
                seen[name:lower()] = { name = name, value = nil }
            end
        end
    end
    local total = 0
    for _, item in pairs(seen) do
        total = total + 1
        if item.value == nil then
            remove[#remove + 1] = item.name
        else
            set[#set + 1] = { name = item.name, value = item.value }
        end
    end
    if total > 32 then return nil, "响应改写 Header 不能超过 32 条" end
    table.sort(set, function(a, b) return a.name:lower() < b.name:lower() end)
    table.sort(remove)
    return set, remove
end

normalize_rewrites = function(value)
    if value == nil or value == cjson.null then return {} end
    if type(value) ~= "table" then return nil, "响应改写 body 规则必须是数组" end
    local rules = {}
    for _, item in ipairs(value) do
        if type(item) ~= "table" then return nil, "响应改写 body 规则必须是对象数组" end
        local source = item.source
        local target = item.target
        if type(source) ~= "string" or source == "" then
            return nil, "响应改写 body 规则必须提供 source"
        end
        if target ~= nil and target ~= cjson.null and type(target) ~= "string" then
            return nil, "响应改写 body 规则的 target 必须是字符串"
        end
        target = target or ""
        -- APISIX 习惯：source 以 ~ 开头表示正则；此处同时接受 regex 标记。
        local regex = item.regex == true or item.regex == 1
        if source:sub(1, 1) == "~" then
            source = source:sub(2)
            regex = true
        end
        if source == "" then return nil, "响应改写 body 规则的匹配内容不能为空" end
        if #source > RESPONSE_REWRITE_MAX_PATTERN then
            return nil, "响应改写正则不能超过 " .. RESPONSE_REWRITE_MAX_PATTERN .. " 字符"
        end
        if #target > RESPONSE_REWRITE_MAX_REPLACEMENT then
            return nil, "响应改写替换文本不能超过 " .. RESPONSE_REWRITE_MAX_REPLACEMENT .. " 字符"
        end
        -- PCRE 编译校验：非法正则直接拒绝，避免请求期才报错。
        if regex then
            -- ngx.re.find 返回 from, to, err（err 为 pcre2_compile 的错误信息）。
            local _, _, compile_err = ngx.re.find("authz-probe", source, "jo")
            if compile_err then return nil, "响应改写正则不合法: " .. tostring(compile_err) end
        end
        if source:find("%c") or target:find("%c") then
            return nil, "响应改写 body 规则不能包含控制字符"
        end
        rules[#rules + 1] = { source = source, target = target, regex = regex }
    end
    if #rules > RESPONSE_REWRITE_MAX_RULES then
        return nil, "响应改写 body 规则不能超过 " .. RESPONSE_REWRITE_MAX_RULES .. " 条"
    end
    return rules
end

-- 响应改写字段（对齐 APISIX response-rewrite 的常用子集）：
--   enabled         总开关（关闭时保留配置但不生效）
--   status          覆盖响应状态码（0/留空表示保持上游）
--   headers         覆盖响应头（值置 null 或空串 = 删除）
--   remove_headers  显式删除的响应头列表
--   body            整体替换响应正文（文本或 JSON 对象）
--   body_base64     body 以 base64 提供（用于二进制内容）
--   content_type    替换正文时写回的 Content-Type
--   rewrites        正文过滤规则（source/target，~ 前缀或 regex=true 走 PCRE）
-- 返回规范化后的 JSON 字符串（空配置返回 ""），与 request_rewrite 同构落库。
local RESPONSE_REWRITE_FIELDS = {
    enabled = true, status = true, headers = true, remove_headers = true,
    body = true, body_base64 = true, content_type = true, rewrites = true,
}

valid_content_type = function(value)
    return ngx.re.match(value,
        [[^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+([;,][^,;]*)*$]]) ~= nil
end

function _M.normalize_response_rewrite(value)
    if value == nil or value == cjson.null then return "" end
    if type(value) == "string" and #value > RESPONSE_REWRITE_MAX_JSON then
        return nil, "响应改写配置过大", 422
    end
    local config = decode_response_rewrite(value)
    if not config then return nil, "响应改写配置必须是合法的 JSON 对象", 422 end
    for key in pairs(config) do
        if not RESPONSE_REWRITE_FIELDS[key] then
            return nil, "响应改写不支持字段 「" .. tostring(key) .. "」", 422
        end
    end

    local enabled = config.enabled
    enabled = not (enabled == false or enabled == 0 or enabled == "false")

    local status = config.status
    -- 0 = 不改写状态码，与 UI/规范化输出一致。若在这里拒绝 0，任何已经保存过
    -- 改写规则的绑定都会在后续 PATCH（哪怕只改别的字段）时被自己拒绝，
    -- 表现为「改不动、替换不生效」。
    if status == nil or status == cjson.null or status == "" or status == 0 or status == "0" then
        status = 0
    else
        status = tonumber(status)
        if not status or status % 1 ~= 0 or status < 200 or status > 999 then
            return nil, "响应改写 status 必须是 0（不改写）或 200-999 的整数", 422
        end
        status = math.floor(status)
    end

    local set_headers, remove_headers, header_err =
        normalize_rewrite_headers(config.headers, config.remove_headers)
    if not set_headers then return nil, header_err, 422 end

    local body_base64 = config.body_base64 == true or config.body_base64 == 1
    local body_text, body_is_json = nil, false
    local body = config.body
    if body ~= nil and body ~= cjson.null and body ~= "" then
        if type(body) == "table" then
            local encoded = cjson.encode(body)
            if not encoded then return nil, "响应改写 body 无法编码为 JSON", 422 end
            body_text, body_is_json = encoded, true
            if body_base64 then return nil, "JSON body 不能同时标记 base64", 422 end
        elseif type(body) == "string" then
            if body_base64 then
                local decoded = ngx.decode_base64(body)
                if not decoded then return nil, "响应改写 body 不是合法的 base64", 422 end
                body_text = body
            else
                body_text = body
            end
            if #body > RESPONSE_REWRITE_MAX_BODY then
                return nil, "响应改写 body 不能超过 " .. RESPONSE_REWRITE_MAX_BODY .. " 字符", 422
            end
        else
            return nil, "响应改写 body 必须是文本、JSON 或留空", 422
        end
    elseif body_base64 then
        return nil, "响应改写 base64 需要同时提供 body", 422
    end

    local content_type = config.content_type
    if content_type ~= nil and content_type ~= cjson.null then
        content_type = tostring(content_type):gsub("^%s+", ""):gsub("%s+$", "")
        if content_type == "" then
            content_type = ""
        elseif #content_type > 128 or not valid_content_type(content_type) then
            return nil, "响应改写 Content-Type 格式不合法", 422
        end
        if body_text == nil then
            return nil, "响应改写 Content-Type 需要同时提供 body", 422
        end
    else
        content_type = nil
    end
    if body_is_json and not content_type then content_type = "application/json; charset=utf-8" end
    if body_text ~= nil and not body_is_json and not body_base64 and
        body_text:find("[\r\n]") == nil and #body_text > 0 then
        -- 文本正文允许任意可打印内容；控制字符（除换行/制表）在此拒绝。
        if body_text:gsub("[\t]", ""):find("%c") then
            return nil, "响应改写 body 不能包含控制字符", 422
        end
    end

    local rewrites, rewrite_err = normalize_rewrites(config.rewrites)
    if not rewrites then return nil, rewrite_err, 422 end
    -- 对齐 APISIX：body（整体替换）与 rewrites（正文过滤）互斥，二者语义冲突。
    if body_text ~= nil and #rewrites > 0 then
        return nil, "响应改写 body 与 rewrites 不能同时使用", 422
    end

    if #set_headers == 0 and #remove_headers == 0 and status == 0 and
        body_text == nil and #rewrites == 0 then
        return ""
    end

    local out = {
        enabled = enabled,
        status = status,
        headers = #set_headers > 0 and set_headers or cjson.empty_array,
        remove_headers = #remove_headers > 0 and remove_headers or cjson.empty_array,
    }
    if body_text ~= nil then
        out.body = body_text
        out.body_base64 = body_base64 or nil
        out.content_type = content_type
    end
    if #rewrites > 0 then out.rewrites = rewrites end
    local encoded = cjson.encode(out)
    if not encoded then return nil, "响应改写配置编码失败", 422 end
    if #encoded > RESPONSE_REWRITE_MAX_JSON then return nil, "响应改写配置过大", 422 end
    return encoded
end

function _M.normalize_binding_proxy(data)
    local function optional(value, default)
        if value == nil or value == cjson.null then return default end
        return value
    end
    local upstream_host = target.normalize_authority(optional(data.upstream_host, ""), true)
    if upstream_host == nil then return nil, "上游 Host 格式不合法" end
    local forwarded_host = target.normalize_authority(optional(data.forwarded_host, ""), true)
    if forwarded_host == nil then return nil, "Forwarded Host 格式不合法" end
    local forwarded_proto = tostring(optional(data.forwarded_proto, "")):lower()
        :gsub("^%s+", ""):gsub("%s+$", "")
    if not FORWARDED_PROTO_SET[forwarded_proto] then
        return nil, "Forwarded Proto 仅支持自动、http 或 https"
    end
    local forwarded_port = optional(data.forwarded_port, "")
    if forwarded_port == "" then
        forwarded_port = 0
    else
        forwarded_port = tonumber(forwarded_port)
        if forwarded_port ~= 0 and (not forwarded_port or forwarded_port % 1 ~= 0 or
            forwarded_port < 1 or forwarded_port > 65535) then
            return nil, "Forwarded Port 必须是 1-65535，留空表示自动"
        end
    end
    local origin_mode = tostring(optional(data.origin_mode, "auto")):lower()
        :gsub("^%s+", ""):gsub("%s+$", "")
    if not ORIGIN_MODE_SET[origin_mode] then return nil, "Origin 处理模式不受支持" end
    local custom_origin = target.normalize_origin(optional(data.custom_origin, ""), true)
    if custom_origin == nil then return nil, "自定义 Origin 必须是合法的 http(s) Origin" end
    if origin_mode == "custom" and custom_origin == "" then
        return nil, "自定义 Origin 模式必须填写 Origin"
    end
    local local_ip = target.normalize_ip(optional(data.local_ip, "127.0.0.1"))
    if not local_ip then return nil, "模拟本机 IP 必须是合法的 IPv4 或 IPv6 地址" end
    local upstream_scheme = tostring(optional(data.upstream_scheme, "http")):lower()
        :gsub("^%s+", ""):gsub("%s+$", "")
    if not UPSTREAM_SCHEME_SET[upstream_scheme] then return nil, "上游协议仅支持 http 或 https" end
    local upstream_path = target.normalize_upstream_path(optional(data.upstream_path, ""))
    if upstream_path == nil then
        return nil, "上游改写路径必须是合法路径，不能包含查询参数、片段、连续斜杠或 .."
    end
    local request_rewrite, rewrite_req_err =
        _M.normalize_request_rewrite(optional(data.request_rewrite, ""))
    if not request_rewrite then return nil, rewrite_req_err, 422 end
    local response_rewrite, rewrite_err, rewrite_status =
        _M.normalize_response_rewrite(optional(data.response_rewrite, ""))
    if not response_rewrite then return nil, rewrite_err, rewrite_status or 422 end
    local ssl_verify = optional(data.upstream_ssl_verify, true)
    if type(ssl_verify) == "string" then
        ssl_verify = ssl_verify:lower():gsub("^%s+", ""):gsub("%s+$", "")
    end
    return {
        upstream_host = upstream_host,
        forwarded_host = forwarded_host,
        forwarded_proto = forwarded_proto,
        forwarded_port = forwarded_port,
        origin_mode = origin_mode,
        custom_origin = custom_origin,
        simulate_local = (data.simulate_local == true or data.simulate_local == 1) and 1 or 0,
        local_ip = local_ip,
        upstream_scheme = upstream_scheme,
        upstream_ssl_verify = (ssl_verify == false or ssl_verify == 0 or ssl_verify == "0" or
            ssl_verify == "false") and 0 or 1,
        upstream_path = upstream_path,
        request_rewrite = request_rewrite,
        response_rewrite = response_rewrite,
    }
end

function _M.proxy_fields()
    return BINDING_PROXY_FIELDS
end

function _M.proxy_fields_present(data)
    for _, field in ipairs(BINDING_PROXY_FIELDS) do
        if data[field] ~= nil then return true end
    end
    return false
end

function _M.valid_api_key_name(value)
    local name = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not ngx.re.match(name, [[^[A-Za-z0-9][A-Za-z0-9_.-]{1,63}$]], "jo") then return nil end
    return name
end

local function valid_policy_identity(value)
    local source, username = identity.parse(value)
    if not source then return false end
    return source == "local" and users.exists_enabled(username) or
        remote_users.exists_enabled(source, username)
end

function _M.normalize_policy(data)
    local ptype = data.ptype == "g" and "g" or "p"
    local v0 = tostring(data.v0 or ""):gsub("%s+", "")
    if v0 == "" or v0:find(",", 1, true) then return nil, "主体格式不合法", 422 end
    local v1, v2
    if ptype == "p" then
        if v0:sub(1, 5) == "role:" then
            if not POLICY_ROLE_SET[v0:sub(6)] then return nil, "策略角色不受支持", 422 end
        else
            if v0:sub(1, 5) ~= "user:" then v0 = identity.key("local", v0) or "" end
            if not valid_policy_identity(v0) then return nil, "策略用户不存在或已禁用", 422 end
        end
        local object, object_err = _M.parse_policy_object(data.v1)
        if not object then return nil, object_err, 422 end
        v1 = object.value
        local binding_id = tonumber(data.binding_id)
        if data.binding_id ~= nil and tostring(data.binding_id) ~= "" then
            if not binding_id or binding_id < 1 or binding_id ~= math.floor(binding_id) then
                return nil, "绑定对象不存在", 422
            end
            if object.kind ~= "port" then return nil, "全局对象不能关联域名绑定", 422 end
            local selected = bindings.id_port(binding_id)
            if not selected then return nil, "绑定对象不存在", 422 end
            if tonumber(selected.port) ~= object.port then
                return nil, "策略对象端口与所选绑定不一致", 422
            end
        end
        local method_err
        v2, method_err = _M.normalize_http_methods(data.v2)
        if not v2 then return nil, method_err, 422 end
        if data.eft == "deny" then v2 = v2 .. "|deny" end
    else
        v1 = tostring(data.v1 or ""):gsub("%s+", "")
        if not HUMAN_ROLE_SET[v1:gsub("^role:", "")] then
            return nil, "用户角色仅支持 admin、staff、user、viewer", 422
        end
        v1 = "role:" .. v1:gsub("^role:", "")
        if v0:sub(1, 5) ~= "user:" then v0 = identity.key("local", v0) or "" end
        if not valid_policy_identity(v0) then return nil, "角色分配用户不存在或已禁用", 422 end
        v2 = "-"
    end
    return { ptype = ptype, v0 = v0, v1 = v1, v2 = v2 }
end

return _M
