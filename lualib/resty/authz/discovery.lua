local _M = {}

local LISTEN = "0A"
local LOOPBACK = {
    ["0100007F"] = true,
    ["00000000"] = true,
}

local cache = {
    expires_at = 0,
    items = nil,
}

local function add_listening_ports(path, config, ports)
    local file = io.open(path, "r")
    if not file then return end
    for line in file:lines() do
        local address, port_hex, state = line:match(
            "^%s*%d+:%s+([%x]+):([%x]+)%s+[%x]+:[%x]+%s+([%x]+)")
        local port = port_hex and tonumber(port_hex, 16) or nil
        if address and (LOOPBACK[address] or path:match("tcp6$")) and state == LISTEN and port
            and port >= config.port_min and port <= config.port_max
            and port ~= config.http_port and port ~= config.https_port then
            ports[port] = true
        end
    end
    file:close()
end

local function listening_ports(config)
    local ports = {}
    add_listening_ports("/proc/net/tcp", config, ports)
    add_listening_ports("/proc/net/tcp6", config, ports)
    local result = {}
    for port in pairs(ports) do result[#result + 1] = port end
    table.sort(result)
    return result
end

local function is_http_service(port, config)
    local socket = ngx.socket.tcp()
    socket:settimeouts(config.discovery_connect_timeout, config.discovery_read_timeout, config.discovery_read_timeout)
    local ok = socket:connect("127.0.0.1", port)
    if not ok then
        socket:close()
        return false
    end
    local sent = socket:send("HEAD / HTTP/1.0\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
    if not sent then
        socket:close()
        return false
    end
    local line = socket:receive("*l")
    socket:close()
    return line and line:match("^HTTP/%d+%.%d+%s+%d%d%d") ~= nil
end

local function item(port)
    return {
        port = port,
        source = "127.0.0.1",
        note = "127.0.0.1:" .. port,
        enabled = 1,
    }
end

function _M.list(config)
    local now = ngx.now()
    if cache.items and cache.expires_at > now then return cache.items end

    local ports = {}
    for value in tostring(config.discovery_ports or ""):gmatch("[^,%s]+") do
        local port = tonumber(value)
        if port and port >= config.port_min and port <= config.port_max
            and port ~= config.http_port and port ~= config.https_port then
            ports[port] = true
        end
    end
    for _, port in ipairs(listening_ports(config)) do ports[port] = true end

    local items = {}
    local sorted_ports = {}
    for port in pairs(ports) do sorted_ports[#sorted_ports + 1] = port end
    table.sort(sorted_ports)
    for _, port in ipairs(sorted_ports) do
        if is_http_service(port, config) then items[#items + 1] = item(port) end
    end
    cache.items = items
    cache.expires_at = now + config.discovery_ttl
    return items
end

return _M
