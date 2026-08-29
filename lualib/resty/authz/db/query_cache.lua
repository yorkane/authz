-- L1/L2 query cache keyed by the cross-worker database revision.

local mlcache = require "resty.mlcache"

local _M = {}
local cache
local disabled = false
local ttl = 30
local lru_size = 500
local cache_dict = "authz_db_cache"
local revision_dict = "authz_cache"

local function in_master()
    return ngx.worker and ngx.worker.in_master and ngx.worker.in_master()
end

local function revision()
    local dict = ngx.shared[revision_dict]
    return dict and (dict:get("db_rev") or 0) or 0
end

local function instance()
    if cache or disabled or in_master() then return cache end
    local created, err = mlcache.new("authz_db", cache_dict, {
        lru_size = lru_size,
        ttl = ttl,
        neg_ttl = 5,
    })
    if not created then
        disabled = true
        ngx.log(ngx.WARN, "authz: database cache disabled: ", tostring(err))
        return nil
    end
    cache = created
    return cache
end

local function key(sql, params)
    local parts = { tostring(revision()), sql }
    for index, value in ipairs(params) do
        parts[#parts + 1] = tostring(index)
        parts[#parts + 1] = type(value)
        parts[#parts + 1] = tostring(value)
    end
    return ngx.encode_base64(table.concat(parts, "\0"))
end

function _M.configure(options)
    options = options or {}
    ttl = math.max(1, tonumber(options.db_cache_ttl) or 30)
    lru_size = math.max(50, tonumber(options.db_cache_lru_size) or 500)
    cache_dict = options.db_cache_dict or "authz_db_cache"
    revision_dict = options.cache_dict or "authz_cache"
    _M.reset()
end

function _M.reset()
    cache = nil
    disabled = false
end

function _M.bump_revision()
    local dict = ngx.shared[revision_dict]
    if dict then dict:incr("db_rev", 1, 0) end
end

function _M.get(sql, params, loader)
    local current = instance()
    if not current then return loader(sql, params) end
    local rows, err = current:get(key(sql, params), nil, loader, sql, params)
    if not err then return rows end
    ngx.log(ngx.WARN, "authz: database cache read failed: ", tostring(err))
    return loader(sql, params)
end

return _M
