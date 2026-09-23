-- 对象存储可写范围判定（纯字符串逻辑 + LAN IP 探测）。
--
-- 环境变量 AUTHZ_S3_WRITABLE_PATHS（逗号分隔）决定哪些前缀可写：
--   `/` 或 `*`      → 全部可写（所有桶所有路径）
--   空/未设          → 默认：本机局域网 IP 作为一个前缀
--   `a, b/c`        → 多范围；每项按下面三条规则匹配
-- 范围外一律只读（可浏览/预览/下载/分享，禁上传/删除/重命名/建目录）。
--
-- 条目匹配语义（对 bucket 与 key 判定，item==精确命中也算命中）：
--   1. 条目 == bucket                → 整个桶
--   2. 条目以 bucket.."/" 开头        → 桶内前缀 p（key==p 或以 p.."/" 开头）
--   3. 否则条目当作任意桶内的路径前缀（key==条目 或以 条目.."/" 开头）
-- dir 可写 = 目录路径本身落在某条目内（整桶条目 p="" 时任意目录可写）。
-- 对象存储可写范围判定（纯字符串逻辑 + LAN IP 探测）。
--
-- 环境变量 AUTHZ_S3_WRITABLE_PATHS（逗号分隔）决定哪些前缀可写：
--   `/` 或 `*`       → 全部可写（所有桶所有路径）
--   空/未设           → 默认：本机局域网 IP 作为一个条目
--   `a, b/c, */docs` → 多范围，逗号分隔
-- 范围外一律只读（可浏览/预览/下载/分享，禁上传/删除/重命名/建目录）。
--
-- 条目匹配语义（对 bucket 与 key 判定，key==前缀 本身也算命中，
-- 便于「对单个文件重命名/删除」；前缀命中要求整段，rpa 不匹配 rpa2）：
--   1. 条目 == bucket           → 整个桶
--   2. `<桶名>/<前缀>`          → 仅该桶内该前缀
--   3. `*/<前缀>`               → 任意桶内该前缀
--   4. 无分隔符条目（如 LAN IP） → 整桶（规则 1）或任意桶内同名路径前缀
-- dir 可写 = 目录路径落在某条目内（整桶条目时桶内任意目录可写，桶根亦可）。
local _M = {} 

function _M.parse(spec, lan_ip)
    spec = tostring(spec or ""):gsub("%s+$", ""):gsub("^%s+", "")
    if spec == "" then spec = tostring(lan_ip or ""):gsub("%s+$", ""):gsub("^%s+", "") end
    if spec == "" then return { all = false, entries = {} }, {}, false end
    local entries, roots = {}, {}
    for raw in (spec .. ","):gmatch("([^,]*)") do
        local e = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if e == "/" or e == "*" then
            return { all = true, entries = {} }, { "/" }, true
        end
        e = e:gsub("^/+", ""):gsub("/+$", "")
        if e ~= "" then
            if e == "*" or e == "/" then
                return { all = true, entries = {} }, { "/" }, true
            end
            entries[#entries + 1] = e
            roots[#roots + 1] = e
        end
    end
    return { all = false, entries = entries }, roots, false
end

local function under(entry, key)
    if entry == "" then return true end
    return key == entry or key:sub(1, #entry + 1) == entry .. "/"
end

-- 匹配规则 1/2/3（供 item 与 dir 复用）。
local function matches(scope, bucket, key)
    if scope.all then return true end
    for _, entry in ipairs(scope.entries) do
        if entry == bucket then return true end
        local first, rest = entry:match("^([^/]+)/(.*)$")
        if first and rest then
            -- 含分隔符的条目被解析成 <桶名或*>/<前缀>：桶名必须显式对上，
            -- 不拿它兜底匹配其他桶的同名路径（否则 noco/rpa 会命中别的桶）。
            if first == "*" then
                if under(rest, key) then return true end
            elseif first == bucket and under(rest, key) then
                return true
            end
        elseif under(entry, key) then
            -- 无分隔符条目：整桶（上面已判）或任意桶内同名路径前缀。
            return true
        end
    end
    return false
end

function _M.item_writable(scope, bucket, key)
    return matches(scope, bucket, key)
end

-- dirpath 是当前目录（可为空串 = 桶根）。目录本身可写 = 落在某允许前缀内。
function _M.dir_writable(scope, bucket, dirpath)
    if scope.all then return true end
    for _, entry in ipairs(scope.entries) do
        if entry == bucket then return true end
        local first, rest = entry:match("^([^/]+)/(.*)$")
        if first and rest then
            if first == "*" then
                if under(rest, dirpath) then return true end
            elseif first == bucket and under(rest, dirpath) then
                return true
            end
        elseif dirpath ~= "" and under(entry, dirpath) then
            return true
        end
    end
    return false
end

-- 整桶可写 = 存在条目==bucket（规则 1）或全写。桶内前缀条目不算整桶可写。
function _M.bucket_writable(scope, bucket)
    if scope.all then return true end
    for _, entry in ipairs(scope.entries) do
        if entry == bucket then return true end
    end
    return false
end

-- 本机局域网 IP：UDP connect 到不可达保留地址只让内核选路由源地址，不发包。
-- 整体 pcall；失败返回 nil（调用方决定告警与全只读降级）。
function _M.detect_lan_ip()
    local ok, result = pcall(function()
        local ffi = require "ffi"
        ffi.cdef([[
            typedef struct { unsigned char s_addr[4]; } in_addr_t_s;
            struct sockaddr_in { unsigned short sin_family; unsigned short sin_port;
                unsigned int sin_addr; char sin_zero[8]; };
            int socket(int domain, int type, int protocol);
            int connect(int fd, const struct sockaddr_in *addr, int addrlen);
            int getsockname(int fd, struct sockaddr_in *addr, int *addrlen);
            int close(int fd);
        ]])
        local AF_INET, SOCK_DGRAM = 2, 2
        local fd = ffi.C.socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 then return nil end
        local addr = ffi.new("struct sockaddr_in")
        addr.sin_family = AF_INET
        addr.sin_port = 13568 -- 53:0（网络字节序）；端口值不影响内核选路
        addr.sin_addr = 0xFFFFFF0A -- 10.255.255.255 的小端 u32（保留段，不可达，仅选路）
        local rc = ffi.C.connect(fd, addr, ffi.sizeof("struct sockaddr_in"))
        if rc ~= 0 then ffi.C.close(fd); return nil end
        local out = ffi.new("struct sockaddr_in[1]")
        local len = ffi.new("int[1]")
        len[0] = ffi.sizeof("struct sockaddr_in")
        rc = ffi.C.getsockname(fd, out, len)
        ffi.C.close(fd)
        if rc ~= 0 then return nil end
        local raw = out[0].sin_addr
        return string.format("%d.%d.%d.%d",
            bit.band(raw, 0xFF), bit.band(bit.rshift(raw, 8), 0xFF),
            bit.band(bit.rshift(raw, 16), 0xFF), bit.band(bit.rshift(raw, 24), 0xFF))
    end)
    if not ok then return nil end
    return result
end

return _M
