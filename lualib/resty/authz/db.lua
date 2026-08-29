-- SQLite facade: connection lifecycle, cached reads, transactions and
-- versioned initialization. Runtime SQL belongs in repository/* modules.

local driver = require "resty.authz.db.driver"
local query_cache = require "resty.authz.db.query_cache"

local _M = {}
local transaction_depth = 0
local transaction_dirty = false
local transaction_authz_dirty = false
local authz_revision_dict = "authz_cache"

local function bump_authz_revision()
    local dict = ngx.shared[authz_revision_dict]
    if dict then dict:incr("rev", 1, 0) end
end

local function raw_query(sql, params)
    return driver.query(sql, params)
end

function _M.open(path)
    return driver.open(path)
end

function _M.close()
    driver.close()
    query_cache.reset()
    transaction_depth = 0
    transaction_dirty = false
    transaction_authz_dirty = false
end

function _M.exec(sql, ...)
    local ok, err = driver.exec(sql, { ... })
    if not ok then return nil, err end
    if transaction_depth > 0 then
        transaction_dirty = true
    else
        query_cache.bump_revision()
    end
    return true
end

function _M.query(sql, ...)
    local params = { ... }
    if transaction_depth > 0 then return raw_query(sql, params) end
    return query_cache.get(sql, params, raw_query)
end

-- The callback must return a non-nil first value to commit. Returning nil or
-- raising rolls back. authz=true publishes the policy/binding revision only
-- after a successful commit.
function _M.transaction(callback, options)
    options = options or {}
    if transaction_depth > 0 then
        if options.authz then transaction_authz_dirty = true end
        return callback()
    end

    local begun, begin_err = driver.exec("BEGIN IMMEDIATE", {})
    if not begun then return nil, begin_err end
    transaction_depth = 1
    transaction_dirty = false
    transaction_authz_dirty = options.authz == true

    local called, first, second, third, fourth = xpcall(callback, debug.traceback)
    if not called or first == nil then
        driver.exec("ROLLBACK", {})
        transaction_depth = 0
        transaction_dirty = false
        transaction_authz_dirty = false
        return nil, called and second or first, third, fourth
    end

    local committed, commit_err = driver.exec("COMMIT", {})
    if not committed then
        driver.exec("ROLLBACK", {})
        transaction_depth = 0
        transaction_dirty = false
        transaction_authz_dirty = false
        return nil, commit_err
    end

    local dirty = transaction_dirty
    local authz_dirty = transaction_authz_dirty
    transaction_depth = 0
    transaction_dirty = false
    transaction_authz_dirty = false
    if dirty then query_cache.bump_revision() end
    if dirty and authz_dirty then bump_authz_revision() end
    return first, second, third, fourth
end

function _M.authz_transaction(callback)
    return _M.transaction(callback, { authz = true })
end

function _M.init(options)
    options = options or {}
    authz_revision_dict = options.cache_dict or "authz_cache"
    query_cache.configure(options)
    _M.open(options.path or options.db_path or "/data/authz/authz.db")
    require("resty.authz.db.migrations").run(_M)
    require("resty.authz.db.seed").run(_M, options)
    return true
end

return _M
