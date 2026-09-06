-- Domain prefixes and per-request entry-domain rebuilding.
--
-- Bindings store only the last-level prefix (e.g. "code"). The full entry
-- domain is composed at consumption time from the *current request host*:
-- <prefix>-<node>.<zone> (e.g. code-241.ai-t.wtvdev.com). The node is the
-- trailing "-" segment of the first request label (the whole first label
-- when it has no dash) and the zone follows the Host the browser entered
-- through, so one prefix set serves every wildcard entry domain without
-- per-zone copies and the admin UI never asks for a full domain.
-- Legacy exact domains (a stored value that still contains dots, such as
-- nas.example.com) keep matching verbatim and are never rebuilt.
local _M = {}

local HOST_PATTERN = [[^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$]]

-- First label + zone of a usable request host; nil for IPs, empty values,
-- or single-label hosts (localhost, bare panel domains).
local function host_parts(host)
    local value = tostring(host or ""):lower():gsub("%.$", ""):gsub(":%d+$", "")
    if value == "" or value:find(":", 1, true) or value:match("^[%d%.]+$") then return nil end
    local label, zone = value:match("^([^.]+)%.(.+)$")
    if not label then return nil end
    return label, zone
end

-- Build the entry domain for a stored value plus the current request host.
-- Bare prefixes are rebuilt against the current host; legacy dotted domains
-- that still follow the <prefix>-<node>.<zone> convention are rebuilt when
-- the request arrives on the same node (cross-zone menus keep working for
-- databases that were never migrated); genuine exact domains return verbatim.
-- An unusable request host (IP access, single label) yields nil so callers
-- can decide the fallback display.
function _M.link(stored_domain, request_host)
    local stored = tostring(stored_domain or ""):lower()
    if stored == "" then return stored end
    local rebuilt
    if stored:find(".", 1, true) then
        local prefix, node, _ = _M.split(stored)
        if not prefix then return stored end
        local label, zone = host_parts(request_host)
        if not label then return stored end
        local req_node = label:match("([^-]+)$")
        if req_node ~= node then return stored end
        rebuilt = prefix .. "-" .. node .. "." .. zone
    else
        local label, zone = host_parts(request_host)
        if not label then return nil end
        -- Already standing on the entry itself (<prefix>.<zone>): keep it as is.
        rebuilt = label == stored
            and (stored .. "." .. zone)
            or (stored .. "-" .. label:match("([^-]+)$") .. "." .. zone)
    end
    if #rebuilt > 253 or not ngx.re.match(rebuilt, HOST_PATTERN, "jo") then return stored end
    return rebuilt
end

-- First label of a request host (lowercase, port/trailing dot stripped);
-- nil for IPs, empty values, or single-label hosts. The proxy resolver uses
-- it to look up the bare-prefix index so <prefix>-<node>.<any zone> and
-- <prefix>.<any zone> both resolve to the stored prefix binding.
function _M.first_label(host)
    local value = tostring(host or ""):lower():gsub("%.$", ""):gsub(":%d+$", "")
    if value == "" or value:find(":", 1, true) or value:match("^[%d%.]+$") then return nil end
    return value:match("^([^.]+)%.")
end

-- Legacy compatibility: bindings created before bare-prefix storage still
-- hold materialized <prefix>-<node>.<zone> domains (or genuine exact
-- domains). Split a materialized wildcard domain into prefix/node/zone so
-- the resolver and the menu can keep cross-zone behaviour for them.
-- Exact domains without a dashed first label return nil.
function _M.split(domain)
    local label, zone = tostring(domain or ""):lower():match("^([^.]+)%.(.+)$")
    if not label then return nil end
    local prefix, node = label:match("^(.-)%-([^-]+)$")
    if not prefix or prefix == "" or not node then return nil end
    return prefix, node, zone
end

-- Index key for the legacy prefix+node fallback in the gateway resolver.
function _M.index_key(stored_domain)
    if stored_domain:find(".", 1, true) then
        local prefix, node = _M.split(stored_domain)
        if not prefix then return nil end
        return prefix .. "|" .. node
    end
    -- Bare prefixes answer for every node: the resolver indexes them under
    -- the prefix itself and matches <prefix> / <prefix>-<node> labels.
    return nil
end

return _M
