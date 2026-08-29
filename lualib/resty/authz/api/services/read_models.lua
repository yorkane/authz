local cjson = require "cjson.safe"
local identity = require "resty.authz.identity"
local api_keys = require "resty.authz.repository.api_keys"
local bindings = require "resty.authz.repository.bindings"
local menu_entries = require "resty.authz.repository.menu_entries"
local policies = require "resty.authz.repository.policies"
local remote_users = require "resty.authz.repository.remote_users"
local users = require "resty.authz.repository.users"
local applications = require "resty.authz.api.services.applications"
local common = require "resty.authz.api.common"
local validation = require "resty.authz.api.validation"

local _M = {}

local function config()
    return require("resty.authz").config
end

-- 左侧菜单布局：把 menu_entries 树按分组/条目组装，并把动态发现的本机
-- 服务注入到 builtin='local' 的分组下。内置页面（builtin 非空）由前端按
-- builtin 键映射到内嵌应用。
function _M.menu_tree(subject)
    local admin = common.is_admin(subject)
    local rows = menu_entries.list()
    local nodes = {}
    for _, row in ipairs(rows) do
        -- 该端点仅供左侧菜单渲染：只返回启用项；
        -- 编辑器另走 /menu-entries 平铺接口查看停用的条目。
        if row.enabled == 1 and (row.admin_only ~= 1 or admin) then
            nodes[#nodes + 1] = {
                id = row.id,
                kind = row.kind,
                parent_id = row.parent_id,
                label = row.label,
                url = row.url ~= "" and row.url or cjson.null,
                icon = row.icon ~= "" and row.icon or cjson.null,
                builtin = row.builtin ~= "" and row.builtin or cjson.null,
                admin_only = row.admin_only,
                enabled = row.enabled,
                sort_order = row.sort_order,
                children = cjson.empty_array,
            }
        end
    end
    -- 把动态发现的本机服务挂到 builtin='local' 分组。
    local local_group
    for _, node in ipairs(nodes) do
        if node.kind == "group" and node.builtin == "local" then local_group = node end
    end
    if local_group and local_group.enabled == 1 then
        local_group.children = {}
        for _, application in ipairs(applications.list()) do
            local label = application.binding
                and (application.label or application.menu_name or application.domain or application.note or
                    ("local:" .. application.port))
                or ("local:" .. application.port)
            local_group.children[#local_group.children + 1] = {
                kind = "item",
                label = label,
                port = application.port,
                domain = application.domain and application.domain or cjson.null,
                binding = application.binding == true or nil,
                note = application.binding and (application.note ~= "" and application.note or cjson.null) or cjson.null,
                icon = application.binding and "mdi-application-outline" or "mdi-lan-connect",
            }
        end
    end
    -- 组装两级树：条目挂到分组，分组为顶层。
    local by_id = {}
    for _, node in ipairs(nodes) do by_id[node.id] = node end
    local groups = {}
    for _, node in ipairs(nodes) do
        if node.kind == "group" then
            groups[#groups + 1] = node
        elseif node.parent_id and by_id[node.parent_id] and by_id[node.parent_id].kind == "group" then
            local parent = by_id[node.parent_id]
            if parent.children == cjson.empty_array then parent.children = {} end
            parent.children[#parent.children + 1] = node
        end
    end
    -- 给每个分组一个独立的 children 表，避免共享 cjson.empty_array 哨兵；
    -- 空分组在前端按无子项处理（children 为空表）。
    for _, group in ipairs(groups) do
        if group.children == cjson.empty_array then group.children = {} end
    end
    for _, group in ipairs(groups) do
        if #group.children > 0 then
            table.sort(group.children, function(a, b)
                return (a.sort_order or 0) < (b.sort_order or 0)
            end)
        else
            group.children = cjson.empty_array
        end
    end
    table.sort(groups, function(a, b)
        return (a.sort_order or 0) < (b.sort_order or 0)
    end)
    return { groups = common.empty_array(groups) }
end

function _M.session(subject)
    if subject.kind == "api_key" then
        return {
            authenticated = true,
            auth_type = "api_key",
            api_key_id = subject.id,
            username = subject.username,
            source = subject.source,
            identity = subject.identity,
            roles = common.empty_array(common.roles_for(subject)),
            admin = common.is_admin(subject),
            created_at = subject.created_at,
            last_login_at = cjson.null,
            updated_at = subject.updated_at,
        }
    end
    local timestamps
    if subject.source == "local" then
        timestamps = users.timestamps(subject.username)
    else
        timestamps = remote_users.timestamps(subject.source, subject.username)
    end
    timestamps = timestamps or {}
    return {
        authenticated = true,
        username = subject.username,
        source = subject.source,
        identity = identity.key(subject.source, subject.username),
        roles = common.empty_array(common.roles_for(subject)),
        admin = common.is_admin(subject),
        csrf = subject.csrf,
        created_at = timestamps.created_at,
        last_login_at = timestamps.last_login_at or cjson.null,
        updated_at = timestamps.updated_at,
    }
end

function _M.users(subject)
    local local_rows, remote_rows = users.list(), remote_users.list()
    for _, user in ipairs(local_rows) do
        user.source = "local"
        user.identity = identity.key("local", user.username)
        user.last_login_at = user.last_login_at or cjson.null
    end
    for _, user in ipairs(remote_rows) do
        user.source = user.provider
        user.identity = identity.key(user.provider, user.username)
        user.recorded_at, user.synced_at = user.synced_at, nil
        user.last_login_at = user.last_login_at or cjson.null
    end
    return {
        username = subject.username,
        source = subject.source,
        identity = common.principal_for(subject),
        roles = common.empty_array(common.roles_for(subject)),
        admin = true,
        csrf = subject.csrf,
        available_roles = common.HUMAN_ROLES,
        users = common.empty_array(local_rows),
        remote_users = common.empty_array(remote_rows),
    }
end

function _M.authorization(subject)
    local binding_rows = bindings.list()
    local bindings_by_port = {}
    for _, binding in ipairs(binding_rows) do
        local port = tonumber(binding.port)
        bindings_by_port[port] = bindings_by_port[port] or {}
        bindings_by_port[port][#bindings_by_port[port] + 1] = {
            id = binding.id, domain = binding.domain, target_ip = binding.target_ip,
            port = binding.port, menu_name = binding.menu_name, enabled = binding.enabled,
        }
    end
    local policy_rows = policies.list()
    for _, policy in ipairs(policy_rows) do
        local action, effect = tostring(policy.v2 or ""), "allow"
        if action:sub(-5) == "|deny" then action, effect = action:sub(1, -6), "deny" end
        policy.action, policy.effect = action, effect
        local source, username = identity.parse(policy.v0)
        policy.subject_label = source and (username .. " · " .. source) or policy.v0
        if policy.ptype == "p" then
            local object = validation.parse_policy_object(policy.v1)
            if object then
                policy.object_kind = object.kind
                policy.object_port = object.port or cjson.null
                policy.object_path = object.path
                policy.binding_matches = object.port and (bindings_by_port[object.port] or {}) or {}
                if object.port then
                    policy.object_kind = #policy.binding_matches == 1 and "binding" or
                        (#policy.binding_matches > 1 and "shared" or "unbound")
                end
                policy.binding_matches = common.empty_array(policy.binding_matches)
            else
                policy.object_kind = "invalid"
                policy.object_port = cjson.null
                policy.object_path = policy.v1
                policy.binding_matches = common.empty_array({})
            end
        end
    end
    local admin = common.is_admin(subject)
    local policy_users = {}
    if admin then
        for _, user in ipairs(users.enabled_names()) do
            policy_users[#policy_users + 1] = {
                username = user.username, source = "local",
                identity = identity.key("local", user.username),
            }
        end
        for _, user in ipairs(remote_users.enabled_names()) do
            policy_users[#policy_users + 1] = {
                username = user.username, source = user.provider,
                identity = identity.key(user.provider, user.username),
            }
        end
    end
    local current = config()
    return {
        username = subject.username,
        source = subject.source,
        identity = common.principal_for(subject),
        roles = common.empty_array(common.roles_for(subject)),
        admin = admin,
        csrf = subject.csrf,
        bindings = common.empty_array(binding_rows),
        policies = common.empty_array(policy_rows),
        policy_users = common.empty_array(policy_users),
        policy_roles = common.POLICY_ROLES,
        http_methods = common.HTTP_METHODS,
        port_min = current.port_min,
        port_max = current.port_max,
    }
end

function _M.api_keys()
    return api_keys.list()
end

return _M
