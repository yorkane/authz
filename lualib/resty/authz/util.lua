-- resty.authz.util
-- 通用工具: 随机 token / 密码哈希 / HTML 转义

local hmac_mod = require "resty.hmac"
local sha256 = require "resty.sha256"
local str_util = require "resty.string"
local random = require "resty.random"

local _M = {}

-- 密码哈希: HMAC-SHA256 迭代 (salt 为 key)
-- hash = H(salt, ...H(salt, H(salt, password))...)  迭代 ITER 次
local ITER = 5000

function _M.hash_password(password, salt)
    local mac = hmac_mod:new(salt, hmac_mod.ALGOS.SHA256)
    if not mac then return nil, "hmac init failed" end
    local h = mac:final(password) -- raw binary
    for _ = 2, ITER do
        local m = hmac_mod:new(salt, hmac_mod.ALGOS.SHA256)
        h = m:final(h)
    end
    return str_util.to_hex(h)
end

function _M.verify_password(password, salt, expected_hex)
    local hex, err = _M.hash_password(password, salt)
    if not hex then return false, err end
    -- 常量时间比较
    if #hex ~= #expected_hex then return false end
    local diff = 0
    for i = 1, #hex do
        local a, b = string.byte(hex, i), string.byte(expected_hex, i)
        local d = a - b
        diff = diff + d * d
    end
    return diff == 0
end

function _M.random_token(nbytes)
    -- nbytes 默认 32; resty.random.bytes 在熵不足时可能回退伪随机
    local t = random.bytes(nbytes or 32, true)
    if not t or #t < (nbytes or 32) then
        t = random.bytes(nbytes or 32)
    end
    return str_util.to_hex(t)
end

function _M.sha256_hex(value)
    if type(value) ~= "string" then return nil, "value must be a string" end
    local digest = sha256:new()
    if not digest then return nil, "sha256 init failed" end
    local ok = digest:update(value)
    if not ok then return nil, "sha256 update failed" end
    local result = digest:final()
    if not result then return nil, "sha256 final failed" end
    return str_util.to_hex(result)
end

function _M.escape_html(s)
    if s == nil then return "" end
    s = tostring(s)
    s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
    s = s:gsub('"', "&quot;"):gsub("'", "&#39;")
    return s
end

return _M
