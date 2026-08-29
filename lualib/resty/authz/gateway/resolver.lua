local cache = require "resty.authz.gateway.cache"

local _M = {}

function _M.resolve(host, config)
    local current = cache.ensure(config)
    local binding = host and current.bindings[host]
    if binding and binding.enabled == 1 then
        return binding.port, binding.websocket, binding.target_ip, binding
    end
    if host then
        local match = ngx.re.match(host, [[^(\d{1,5})-]])
        if match then
            local port = tonumber(match[1])
            if port and port >= config.port_min and port <= config.port_max then
                return port, false, "127.0.0.1", nil
            end
        end
    end
    return nil
end

return _M
