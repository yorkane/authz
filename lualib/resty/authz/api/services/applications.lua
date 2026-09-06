local db = require "resty.authz.db"
local discovery = require "resty.authz.discovery"
local bindings = require "resty.authz.repository.bindings"
local target = require "resty.authz.target"
local validation = require "resty.authz.api.validation"
local common = require "resty.authz.api.common"

local _M = {}

local function config()
    return require("resty.authz").config
end

function _M.list()
    -- db.query (mlcache) and discovery.list return worker-shared cached tables.
    -- Never mutate or append to them in place: doing so pushed discovered ports
    -- into the cached bindings array, so on the next call the binding loop stamped
    -- them binding=true and every local service looked like a domain binding.
    local applications = {}
    local known_ports = {}
    for _, row in ipairs(bindings.enabled_applications()) do
        local application = {}
        for key, value in pairs(row) do application[key] = value end
        application.label = application.menu_name ~= "" and application.menu_name or application.domain
        application.binding = true
        known_ports[tonumber(application.port)] = true
        applications[#applications + 1] = application
    end
    local taken = {}
    for _, item in ipairs(discovery.list(config())) do
        local port = tonumber(item.port)
        if port and not known_ports[port] and not taken[port] then
            taken[port] = true
            applications[#applications + 1] = {
                port = port,
                source = item.source,
                note = item.note,
                enabled = item.enabled,
                label = "local:" .. tostring(port),
                binding = false,
            }
        end
    end
    table.sort(applications, function(left, right)
        if tonumber(left.port) == tonumber(right.port) then
            return tostring(left.domain or "") < tostring(right.domain or "")
        end
        return tonumber(left.port) < tonumber(right.port)
    end)
    return applications
end

function _M.create(data)
    local domain = validation.normalize_binding_domain(data.domain)
    local target_ip = target.normalize_ip(data.target_ip == nil and "127.0.0.1" or data.target_ip)
    local port = tonumber(data.port)
    local current = config()
    if not domain then return nil, "请输入最后一级域名前缀，例如 name1", 422 end
    if not target_ip then return nil, "目标 IP 必须是合法的 IPv4 或 IPv6 地址", 422 end
    if not port or port < current.port_min or port > current.port_max then
        return nil, "端口必须在 " .. current.port_min .. "-" .. current.port_max, 422
    end
    local proxy, proxy_err = validation.normalize_binding_proxy(data)
    if not proxy then return nil, proxy_err, 422 end
    local note, menu_name = tostring(data.note or ""), tostring(data.menu_name or "")
    if #note > 256 then return nil, "备注不能超过 256 个字符", 422 end
    if #menu_name > 128 then return nil, "菜单名称不能超过 128 个字符", 422 end
    local ok, err, status = db.authz_transaction(function()
        if bindings.domain_exists(domain) then return nil, "域名绑定已存在: " .. domain, 409 end
        local values = {
            domain = domain, target_ip = target_ip, port = port,
            enabled = data.enabled == false and 0 or 1,
            websocket = data.websocket == true and 1 or 0,
            note = note, menu_name = menu_name, created_at = os.time(),
        }
        for key, value in pairs(proxy) do values[key] = value end
        local inserted, insert_err = bindings.insert(values)
        if not inserted then return nil, insert_err end
        return true
    end)
    if not ok then
        if status then return nil, err, status end
        return common.db_error("创建应用失败", err)
    end
    return { message = "应用已创建" }, nil, 201
end

function _M.update(id, data)
    local existing = bindings.by_id(id)
    if not existing then return nil, "应用不存在", 404 end
    local fields, values = {}, {}
    if data.domain ~= nil then
        local domain = validation.normalize_binding_domain(data.domain)
        if not domain then return nil, "请输入最后一级域名前缀，例如 name1", 422 end
        if bindings.domain_exists(domain, id) then return nil, "域名已存在", 409 end
        fields[#fields + 1], values[#values + 1] = "domain = ?", domain
    end
    local current = config()
    if data.port ~= nil then
        local port = tonumber(data.port)
        if not port or port < current.port_min or port > current.port_max then
            return nil, "端口必须在 " .. current.port_min .. "-" .. current.port_max, 422
        end
        fields[#fields + 1], values[#values + 1] = "port = ?", port
    end
    if data.target_ip ~= nil then
        local target_ip = target.normalize_ip(data.target_ip)
        if not target_ip then return nil, "目标 IP 必须是合法的 IPv4 或 IPv6 地址", 422 end
        fields[#fields + 1], values[#values + 1] = "target_ip = ?", target_ip
    end
    if data.note ~= nil then
        local note = tostring(data.note)
        if #note > 256 then return nil, "备注不能超过 256 个字符", 422 end
        fields[#fields + 1], values[#values + 1] = "note = ?", note
    end
    if data.menu_name ~= nil then
        local menu_name = tostring(data.menu_name)
        if #menu_name > 128 then return nil, "菜单名称不能超过 128 个字符", 422 end
        fields[#fields + 1], values[#values + 1] = "menu_name = ?", menu_name
    end
    if data.enabled ~= nil then
        fields[#fields + 1], values[#values + 1] = "enabled = ?",
            (data.enabled == true or data.enabled == 1) and 1 or 0
    end
    if data.websocket ~= nil then
        fields[#fields + 1], values[#values + 1] = "websocket = ?",
            (data.websocket == true or data.websocket == 1) and 1 or 0
    end
    if validation.proxy_fields_present(data) then
        local merged = {}
        for _, field in ipairs(validation.proxy_fields()) do
            if data[field] ~= nil then
                merged[field] = data[field]
            else
                merged[field] = existing[field]
            end
        end
        local proxy, proxy_err = validation.normalize_binding_proxy(merged)
        if not proxy then return nil, proxy_err, 422 end
        for _, field in ipairs(validation.proxy_fields()) do
            fields[#fields + 1], values[#values + 1] = field .. " = ?", proxy[field]
        end
    end
    if #fields == 0 then return nil, "没有可更新字段", 422 end
    local ok, err = db.authz_transaction(function()
        local updated, update_err = bindings.update(id, fields, values)
        if not updated then return nil, update_err end
        return true
    end)
    if not ok then return common.db_error("更新应用失败", err) end
    return { message = "应用已更新" }
end

function _M.delete(id)
    local ok, err = db.authz_transaction(function()
        -- 菜单覆盖跟随绑定一起消失，避免残留孤儿键。
        local menu_overrides = require "resty.authz.repository.menu_overrides"
        menu_overrides.delete("binding:" .. tostring(id))
        local deleted, delete_err = bindings.delete(id)
        if not deleted then return nil, delete_err end
        return true
    end)
    if not ok then return common.db_error("删除应用失败", err) end
    return { message = "应用已删除" }
end

return _M
