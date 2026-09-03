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
                -- 未绑定域名的动态端口入口默认按"模拟本机访问"处理：目标固定是
                -- 本机 127.0.0.1，向上游发送目标地址 Host 与本机来源头，
                -- 兼容只接受本地 Host/来源的本地应用（proxy.apply_headers 消费）。
                return port, false, "127.0.0.1", { simulate_local = true }
            end
        end
    end
    return nil
end

return _M
