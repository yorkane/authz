-- Multi-domain menu links.
--
-- Bindings follow the wildcard convention <prefix>-<node>.<zone> (e.g.
-- code-241.ai-t.wtvdev.com). A deployment is usually reachable through
-- several wildcard zones (ai-t.wtvdev.com, ws.gatepro.cn, ...); the node id
-- (241) is stable while the zone depends on how the browser entered the
-- gateway. For left-menu links we therefore rebuild the domain from the
-- binding prefix plus the node/zone of the *current request host*, so one
-- binding set serves every zone without per-zone copies.
-- Anything that does not follow the convention (legacy exact domains such
-- as nas.example.com, hosts without a dash, IPs) keeps the stored domain.
local _M = {}

local HOST_PATTERN = [[^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$]]

-- "code-241.ai-t.wtvdev.com" -> prefix "code", node "241", zone "ai-t.wtvdev.com".
-- Prefix may itself contain dashes (my-app-241.zone -> my-app / 241).
function _M.split(domain)
    local label, zone = tostring(domain or ""):lower():match("^([^.]+)%.(.+)$")
    if not label then return nil end
    local prefix, node = label:match("^(.-)%-([^-]+)$")
    if not prefix or prefix == "" or not node then return nil end
    return prefix, node, zone
end

local function request_node_zone(host)
    local value = tostring(host or ""):lower():gsub("%.$", ""):gsub(":%d+$", "")
    if value == "" or value:find(":", 1, true) or value:match("^[%d%.]+$") then return nil end
    local label, zone = value:match("^([^.]+)%.(.+)$")
    if not label then return nil end
    return label:match("([^-]+)$"), zone
end

-- Rebuild a bound entry's domain for the zone the browser is currently on.
-- Returns the stored domain unchanged whenever the convention does not apply
-- (different node, plain host, IP access, non-conforming binding).
function _M.menu_domain(stored_domain, request_host)
    local stored = tostring(stored_domain or ""):lower()
    local prefix, node = _M.split(stored)
    if not prefix then return stored end
    local req_node, req_zone = request_node_zone(request_host)
    if not req_node or req_node ~= node then return stored end
    local rebuilt = prefix .. "-" .. req_node .. "." .. req_zone
    if #rebuilt > 253 or not ngx.re.match(rebuilt, HOST_PATTERN, "jo") then return stored end
    return rebuilt
end

-- Index key for the prefix+node fallback in the gateway resolver.
function _M.index_key(domain)
    local prefix, node = _M.split(domain)
    if not prefix then return nil end
    return prefix .. "|" .. node
end

-- Split a request host into (prefix, node, zone); nil when it does not follow
-- the <prefix>-<node>.<zone> convention (plain labels, IPs, bare domains).
function _M.host_parts(host)
    local value = tostring(host or ""):lower():gsub("%.$", ""):gsub(":%d+$", "")
    if value == "" or value:find(":", 1, true) or value:match("^[%d%.]+$") then return nil end
    local label, zone = value:match("^([^.]+)%.(.+)$")
    if not label then return nil end
    local prefix, node = label:match("^(.-)%-([^-]+)$")
    if not prefix or prefix == "" or not node or node == prefix then return nil end
    return prefix, node, zone
end

return _M
