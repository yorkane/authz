local cache = require "resty.authz.gateway.cache"
local domain = require "resty.authz.domain"

local _M = {}

function _M.resolve(host, config)
    local current = cache.ensure(config)
    local binding = host and current.bindings[host]
    if binding and binding.enabled == 1 then
        return binding.port, binding.websocket, binding.target_ip, binding
    end
    -- 裸前缀绑定：请求首级标签 <前缀> 或 <前缀>-<节点> 命中前缀即接管，
    -- 同一绑定在所有入口域名（zone）下可达。纯数字前缀不参与带节点
    -- 后缀的回退，留给 <端口>-域名 的动态路由。
    local label = host and domain.first_label(host)
    if label then
        local direct = current.bindings_by_prefix[label]
        if direct and direct.enabled == 1 then
            return direct.port, direct.websocket, direct.target_ip, direct
        end
        local prefix, node = label:match("^(.-)%-([^-]+)$")
        if prefix and not prefix:match("^%d+$") then
            -- 历史遗留的物化完整域名先按 前缀|节点 精确回退，避免同前缀
            -- 不同节点的旧绑定被裸前缀索引串扰。
            local legacy = current.bindings_by_prefix_node
                and current.bindings_by_prefix_node[prefix .. "|" .. node]
            if legacy and legacy.enabled == 1 then
                return legacy.port, legacy.websocket, legacy.target_ip, legacy
            end
            local fallback = current.bindings_by_prefix[prefix]
            if fallback and fallback.enabled == 1 then
                return fallback.port, fallback.websocket, fallback.target_ip, fallback
            end
        end
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
