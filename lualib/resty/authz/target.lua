local _M = {}

local function parse_ipv4(value)
    local parts = {}
    for part in value:gmatch("[^.]+") do
        if not part:match("^%d+$") then return nil end
        local number = tonumber(part)
        if not number or number < 0 or number > 255 then return nil end
        parts[#parts + 1] = number
    end
    if #parts ~= 4 or value:sub(1, 1) == "." or value:sub(-1) == "." then return nil end
    return parts
end

local function parse_hextets(value)
    local parts = {}
    if value == "" then return parts end
    if value:sub(1, 1) == ":" or value:sub(-1) == ":" or value:find("::", 1, true) then
        return nil
    end
    for part in value:gmatch("[^:]+") do
        if not part:match("^[0-9a-fA-F]+$") or #part > 4 then return nil end
        parts[#parts + 1] = tonumber(part, 16)
    end
    return parts
end

local function parse_ipv6(value)
    local double = value:find("::", 1, true)
    if not double then
        local parts = parse_hextets(value)
        return parts and #parts == 8 and parts or nil
    end
    if value:find("::", double + 2, true) then return nil end
    local left = parse_hextets(value:sub(1, double - 1))
    local right = parse_hextets(value:sub(double + 2))
    if not left or not right or #left + #right >= 8 then return nil end
    local parts = {}
    for _, part in ipairs(left) do parts[#parts + 1] = part end
    for _ = 1, 8 - #left - #right do parts[#parts + 1] = 0 end
    for _, part in ipairs(right) do parts[#parts + 1] = part end
    return parts
end

local function normalize_ipv6(parts)
    local best_start, best_length
    local index = 1
    while index <= 8 do
        if parts[index] == 0 then
            local stop = index
            while stop <= 8 and parts[stop] == 0 do stop = stop + 1 end
            local length = stop - index
            if length >= 2 and (not best_length or length > best_length) then
                best_start, best_length = index, length
            end
            index = stop
        else
            index = index + 1
        end
    end
    local text = {}
    for part = 1, 8 do text[part] = string.format("%x", parts[part]) end
    if not best_start then return table.concat(text, ":") end
    local left = table.concat(text, ":", 1, best_start - 1)
    local right = table.concat(text, ":", best_start + best_length, 8)
    if left == "" then return "::" .. right end
    if right == "" then return left .. "::" end
    return left .. "::" .. right
end

function _M.normalize_ip(value)
    local ip = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if ip == "" or #ip > 45 then return nil end
    local ipv4 = parse_ipv4(ip)
    if ipv4 then
        return table.concat(ipv4, ".")
    end
    local ipv6 = parse_ipv6(ip)
    return ipv6 and normalize_ipv6(ipv6) or nil
end

function _M.url_host(ip)
    return ip:find(":", 1, true) and "[" .. ip .. "]" or ip
end

function _M.is_loopback(ip)
    local ipv4 = parse_ipv4(ip)
    if ipv4 then return ipv4[1] == 127 end
    local ipv6 = parse_ipv6(ip)
    if not ipv6 then return false end
    for index = 1, 7 do
        if ipv6[index] ~= 0 then return false end
    end
    return ipv6[8] == 1
end

local function trim(value)
    return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_port(value)
    if value == nil or value == "" then return nil end
    local port = tonumber(value)
    if not port or port % 1 ~= 0 or port < 1 or port > 65535 then return nil end
    return tostring(port)
end

local function normalize_hostname(value)
    local hostname = tostring(value or ""):lower()
    if hostname == "localhost" then return hostname end
    local ip = _M.normalize_ip(hostname)
    if ip and not ip:find(":", 1, true) then return ip end
    local valid_name = hostname:match("^[a-z0-9]$") or
        hostname:match("^[a-z0-9][a-z0-9.-]*[a-z0-9]$")
    if #hostname > 253 or not valid_name then
        return nil
    end
    if hostname:find("..", 1, true) then return nil end
    for label in hostname:gmatch("[^.]+") do
        if #label > 63 or label:sub(1, 1) == "-" or label:sub(-1) == "-" then return nil end
    end
    return hostname
end

function _M.normalize_authority(value, allow_empty)
    local authority = trim(value)
    if authority == "" then return allow_empty and "" or nil end
    if #authority > 300 or authority:find("[\r\n%s/@?#]") then return nil end

    local bracket_ip, bracket_port = authority:match("^%[([^%]]+)%]:(%d+)$")
    if not bracket_ip then bracket_ip = authority:match("^%[([^%]]+)%]$") end
    if bracket_ip then
        local ip = _M.normalize_ip(bracket_ip)
        if not ip or not ip:find(":", 1, true) then return nil end
        local port = normalize_port(bracket_port)
        if bracket_port and not port then return nil end
        return "[" .. ip .. "]" .. (port and ":" .. port or "")
    end

    local colon_count = select(2, authority:gsub(":", ""))
    if colon_count > 1 then
        local ip = _M.normalize_ip(authority)
        return ip and "[" .. ip .. "]" or nil
    end
    local hostname, raw_port = authority:match("^([^:]+):(%d+)$")
    hostname = hostname or authority
    local normalized_hostname = normalize_hostname(hostname)
    if not normalized_hostname then return nil end
    local port = normalize_port(raw_port)
    if raw_port and not port then return nil end
    return normalized_hostname .. (port and ":" .. port or "")
end

function _M.normalize_origin(value, allow_empty)
    local origin = trim(value)
    if origin == "" then return allow_empty and "" or nil end
    local scheme, authority = origin:match("^(https?)://(.+)$")
    if not scheme then return nil end
    authority = _M.normalize_authority(authority, false)
    return authority and scheme:lower() .. "://" .. authority or nil
end

function _M.normalize_upstream_path(value)
    local path = trim(value)
    if path == "" then return "" end
    if #path > 512 or path:sub(1, 1) ~= "/" or path:find("[%?#%c]") or
        path:find("//", 1, true) or path:find("/../", 1, true) or path:sub(-3) == "/.." then
        return nil
    end
    return path
end

function _M.authority_host(value)
    local authority = _M.normalize_authority(value, false)
    if not authority then return nil end
    local bracket_ip = authority:match("^%[([^%]]+)%]")
    if bracket_ip then return bracket_ip end
    return authority:match("^([^:]+)")
end

-- ── IP / CIDR 白名单 ──────────────────────────────────────────────
-- 条目形式：单个 IP（v4/v6）或 CIDR（10.0.0.0/8、fd00::/64）。
-- 归一化为 { bytes = 字节序列, bits = 前缀位数, text = 规范文本 }；
-- 非法条目返回 nil，调用方据此 fail-fast（不允许静默丢弃规则）。
local function ip_bytes(value)
    local v4 = parse_ipv4(value)
    if v4 then return v4 end
    local v6 = parse_ipv6(value)
    if not v6 then return nil end
    local bytes = {}
    for _, hextet in ipairs(v6) do
        bytes[#bytes + 1] = math.floor(hextet / 256)
        bytes[#bytes + 1] = hextet % 256
    end
    return bytes
end

function _M.normalize_cidr(entry)
    local text = trim(entry)
    if text == "" or #text > 64 or text:find("[%c ]") then return nil end
    local address, prefix_text = text:match("^([^/]+)/(%d+)$")
    address = address or text
    local bytes = ip_bytes(address)
    if not bytes then return nil end
    local total_bits = #bytes * 8
    local bits = total_bits
    if prefix_text then
        bits = tonumber(prefix_text)
        if not bits or bits < 0 or bits > total_bits then return nil end
    end
    return {
        bytes = bytes,
        bits = bits,
        text = _M.normalize_ip(address) .. (prefix_text and ("/" .. tostring(bits)) or ""),
    }
end

-- 白名单条目集合：逗号分隔，逐项校验；任一条目非法返回 nil + 原因。
function _M.normalize_cidr_list(value)
    local text = trim(value)
    if text == "" then return nil, "empty list" end
    local entries = {}
    for item in text:gmatch("[^,]+") do
        local entry = _M.normalize_cidr(item)
        if not entry then return nil, "invalid IP or CIDR: " .. trim(item) end
        entries[#entries + 1] = entry
    end
    if #entries == 0 then return nil, "empty list" end
    return entries
end

local function prefix_match(entry_bytes, candidate, limit_bits)
    for index, expected in ipairs(entry_bytes) do
        local byte_bits = limit_bits - (index - 1) * 8
        if byte_bits <= 0 then return true end
        if byte_bits < 8 then
            local shift = 2 ^ (8 - byte_bits)
            return math.floor(candidate[index] / shift) == math.floor(expected / shift)
        end
        if candidate[index] ~= expected then return false end
    end
    return true
end

-- 来源 IP 是否落在白名单内（跨族条目不参与匹配，v4 不会命中 v6 规则）。
function _M.ip_in_list(ip, entries)
    local bytes = ip_bytes(trim(ip))
    if not bytes then return false end
    for _, entry in ipairs(entries or {}) do
        if #entry.bytes == #bytes and prefix_match(entry.bytes, bytes, entry.bits) then
            return true
        end
    end
    return false
end

return _M
