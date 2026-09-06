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
local menu_overrides = require "resty.authz.repository.menu_overrides"

local _M = {}

-- 未被用户手动排序（sort_order=0）的条目用大基数排序，排在手动排序区之后。
local UNORDERED_BASE = 1000000000

local function config()
    return require("resty.authz").config
end

-- 运行时注入的服务条目（域名绑定 / 端口探测）合并菜单覆盖后的行。
-- 返回数组，每项带 bound 标记；调用方决定挂到哪个分组、是否过滤隐藏项。
-- menu_key 是稳定标识（binding:<id> / port:<port>），编辑器据此调用
-- /menu-services 接口改名、换图标、排序、显隐。
function _M.service_entries()
    local overrides = {}
    for _, row in ipairs(menu_overrides.all()) do
        overrides[row.menu_key] = row
    end
    local entries = {}
    for index, application in ipairs(applications.list()) do
        local bound = application.binding == true
        local menu_key = bound and application.id and ("binding:" .. tostring(application.id))
            or ("port:" .. tostring(application.port))
        local override = overrides[menu_key]
        local label = bound
            and (application.label or application.menu_name or application.domain or application.note or
                ("local:" .. application.port))
            or ("local:" .. application.port)
        entries[#entries + 1] = {
            kind = "item",
            menu_key = menu_key,
            bound = bound,
            label = (override and override.label ~= "" and override.label) or label,
            port = application.port,
            domain = application.domain and application.domain or cjson.null,
            binding = bound or nil,
            note = bound and (application.note ~= "" and application.note or cjson.null) or cjson.null,
            icon = (override and override.icon ~= "" and override.icon)
                or (bound and "mdi-web-box" or "mdi-lan-connect"),
            -- 未被用户排序过的条目（sort_order 为默认 0 时视为未排序）排在
            -- 手动排序区（1..n）之后，并保持应用列表自身顺序。
            sort_order = (override and (tonumber(override.sort_order) or 0) > 0
                and override.sort_order) or (UNORDERED_BASE + index),
            hidden = override and tonumber(override.enabled) == 0 or false,
        }
    end
    return entries
end

-- 编辑器视图：域名服务/本地服务两组的完整条目（含隐藏项）。
function _M.menu_service_rows()
    local domain_services, local_services = {}, {}
    for _, entry in ipairs(_M.service_entries()) do
        local row = {}
        for key, value in pairs(entry) do row[key] = value end
        row.bound = nil
        if entry.bound then domain_services[#domain_services + 1] = row
        else local_services[#local_services + 1] = row end
    end
    -- 与左侧菜单一致：按覆盖后的 sort_order 排列，编辑器所见即所得。
    local function by_order(left, right)
        return (left.sort_order or 0) < (right.sort_order or 0)
    end
    table.sort(domain_services, by_order)
    table.sort(local_services, by_order)
    -- "local" 是 Lua 保留字，必须用方括号键（JSON 输出仍为 "local"）。
    return { domains = domain_services, ["local"] = local_services }
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
    -- 域名绑定条目注入 builtin='domains'（域名服务），端口自动发现条目注入
    -- builtin='local'（本地服务）；applications.list() 已排除绑定占用的端口，
    -- 两个分组天然不重复。分组缺失或被禁用时对应条目不展示。
    local local_group
    local domain_group
    for _, node in ipairs(nodes) do
        if node.kind == "group" then
            if node.builtin == "local" then local_group = node
            elseif node.builtin == "domains" then domain_group = node end
        end
    end
    local targets = {}
    if local_group and local_group.enabled == 1 then
        local_group.children = {}
        targets["local"] = local_group.children
    end
    if domain_group and domain_group.enabled == 1 then
        domain_group.children = {}
        targets["domains"] = domain_group.children
    end
    if targets["local"] or targets["domains"] then
        for _, entry in ipairs(_M.service_entries()) do
            if not entry.hidden then
                local bucket = (entry.bound and targets["domains"] or targets["local"])
                    or (entry.bound and targets["local"] or targets["domains"])
                if bucket then
                    local row = {}
                    for key, value in pairs(entry) do row[key] = value end
                    row.bound = nil
                    row.hidden = nil
                    bucket[#bucket + 1] = row
                end
            end
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
