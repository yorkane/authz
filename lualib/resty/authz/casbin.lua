-- resty.authz.casbin
-- Mini Casbin 兼容执行器 (复用 nocobase-authz 一期实现, 增加 g 角色支持)
--
-- model 语义:
--   [request_definition] r = sub, obj, act
--   [policy_definition]  p = sub, obj, act, eft(可选 allow|deny)
--   [role_definition]    g = user, role          (一层继承)
--   [policy_effect]      e = deny 优先, 默认 fail-closed
--   [matcher]            m = (p.sub==r.sub || r.sub ∈ g(p.sub))
--                            && keyMatch(r.obj, p.obj) && keyMatch(r.act, p.act)
--
-- obj 约定: "/<port><uri>" 如 "/3000/api/status"
-- act 约定: HTTP 方法 (GET/POST/...), 策略中 * 匹配全部

local _M = { _VERSION = "0.1.0" }

-- keyMatch: 支持 * 通配符匹配任意字符序列 (含空)
local function key_match(r, p)
    if r == nil or p == nil then return false end
    if p == "*" or p == "/*" then
        if p == "*" then return true end
        -- /* : 前缀为 / 的都匹配
        return type(r) == "string" and r:sub(1, 1) == "/"
    end
    local pattern = p:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
    pattern = pattern:gsub("%*", ".*")
    return type(r) == "string" and r:match("^" .. pattern .. "$") ~= nil
end

local mt = { __index = _M }

function _M.new_enforcer(policy_lines)
    policy_lines = policy_lines or {}
    local self = { ps = {}, gs = {} }
    for _, line in ipairs(policy_lines) do
        local parts = {}
        for token in tostring(line):gmatch("[^,%s]+") do
            parts[#parts + 1] = token
        end
        if parts[1] == "p" then
            self.ps[#self.ps + 1] = {
                sub = parts[2], obj = parts[3],
                act = parts[4] or "*", eft = parts[5] or "allow",
            }
        elseif parts[1] == "g" then
            self.gs[#self.gs + 1] = { user = parts[2], role = parts[3] }
        end
    end
    return setmetatable(self, mt)
end

-- 用户所属角色列表 (一层)
function _M:roles_for(user)
    local roles = {}
    for _, gr in ipairs(self.gs) do
        if gr.user == user then roles[#roles + 1] = gr.role end
    end
    return roles
end

-- enforce(sub, obj, act) → boolean; deny 优先, 默认拒绝
function _M:enforce(sub, obj, act)
    local allowed = false
    for _, pol in ipairs(self.ps) do
        local sub_ok = (pol.sub == sub)
        if not sub_ok and pol.sub and pol.sub:sub(1, 5) == "role:" then
            for _, role in ipairs(self:roles_for(sub)) do
                if role == pol.sub then sub_ok = true break end
            end
        end
        if sub_ok and key_match(obj, pol.obj) and key_match(act, pol.act) then
            if pol.eft == "deny" then return false end
            allowed = true
        end
    end
    return allowed
end

_M.keyMatch = key_match

return _M
