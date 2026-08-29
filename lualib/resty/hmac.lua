-- resty.hmac (compat adapter)
-- Drop-in shim matching the lua-resty-hmac-ffi API consumed by
-- api7-lua-resty-jwt (resty.jwt). Backed by the bundled
-- lua-resty-openssl HMAC implementation so it works with OpenSSL 3.5.x
-- where the legacy HMAC_CTX_init symbol no longer exists.
--
-- API (identical to lua-resty-hmac-ffi):
--   local hmac = require "resty.hmac"
--   local mac  = hmac:new(key, hmac.ALGOS.SHA256)
--   local raw  = mac:final(message)              -- raw binary digest (default)
--   local hex  = mac:final(message, true)        -- hex string

local openssl_hmac = require "resty.openssl.hmac"
local str_util = require "resty.string"

local _M = { _VERSION = "0.06" }

_M.ALGOS = {
    SHA256 = "sha256",
    SHA512 = "sha512",
}

local mt = { __index = _M }

function _M.new(self, key, algo)
    -- NOTE: resty.openssl.hmac.new is a dot-call API (no self),
    -- so we must call it as openssl_hmac.new, NOT openssl_hmac:new
    local inst, err = openssl_hmac.new(key, algo or "sha1")
    if not inst then
        return nil, err
    end
    return setmetatable({ _inst = inst }, mt)
end

function _M.final(self, s, hex_output)
    local value, err = self._inst:final(s)
    if not value then
        return nil, err
    end
    -- default: raw binary digest (matches lua-resty-hmac-ffi consumed by
    -- api7-lua-resty-jwt, and is required for JWT RFC 7518 interop)
    if hex_output then
        return str_util.to_hex(value)
    end
    return value
end

return _M
