local _M = {}

function _M.source(value)
    local source = tostring(value or "local"):lower()
    if source == "" or not source:match("^[a-z0-9_.-]+$") then return nil end
    return source
end

function _M.key(source, username)
    source = _M.source(source)
    username = tostring(username or ""):lower()
    if not source or username == "" or username:find("[,%s:]") then return nil end
    return "user:" .. source .. ":" .. username
end

function _M.parse(value)
    local source, username = tostring(value or ""):match("^user:([a-z0-9_.-]+):([^,%s:]+)$")
    if not source or not username then return nil end
    return source, username
end

return _M
