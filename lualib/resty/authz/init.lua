-- Public Authz Gateway lifecycle facade.

local config_loader = require "resty.authz.config"
local db = require "resty.authz.db"
local gateway = require "resty.authz.gateway.access"

local _M = { config = {} }

function _M.init()
    _M.config = config_loader.load()
    db.init(_M.config)
    -- init_by_lua runs in master; workers must lazily open independent handles.
    db.close()
    ngx.log(ngx.NOTICE, "authz: initialized (db=" .. _M.config.db_path ..
        ", port range " .. _M.config.port_min .. "-" .. _M.config.port_max .. ")")
end

function _M.access()
    return gateway.handle(_M.config)
end

return _M
