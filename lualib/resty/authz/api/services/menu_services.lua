-- Editable menu rows for runtime-injected services.
--
-- The 域名服务 / 本地服务 groups get their children at render time (bindings and
-- port discovery), so those rows are not in menu_entries. Menu customisation is
-- stored per stable service key in menu_overrides:
--   binding:<id>  -- label lives on bindings.menu_name (single source of truth,
--                    also used by the proxy layer); icon/order/hidden here
--   port:<port>   -- everything (label/icon/order/hidden) lives here
-- Hiding an entry never changes the binding itself: the domain keeps serving,
-- it just disappears from the left menu.
local db = require "resty.authz.db"
local bindings = require "resty.authz.repository.bindings"
local menu_overrides = require "resty.authz.repository.menu_overrides"
local common = require "resty.authz.api.common"
local domain = require "resty.authz.domain"

local _M = {}

local MAX_KEY_LEN = 64

function _M.normalize_key(menu_key)
    menu_key = tostring(menu_key or "")
    -- 浏览器把冒号编成 %3A；解码后仍要求严格匹配，拒绝双重编码与路径穿越。
    if menu_key:find("%", 1, true) then
        menu_key = ngx.unescape_uri(menu_key)
    end
    if #menu_key > MAX_KEY_LEN then return nil end
    if menu_key:match("^binding:%d+$") or menu_key:match("^port:%d+$") then return menu_key end
    return nil
end

local function clean(value, max_len)
    value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #value > max_len then value = string.sub(value, 1, max_len) end
    return value
end

-- Resolve a service key to something the UI can render; nil when the service
-- no longer exists (binding deleted or port gone).
function _M.resolve(menu_key)
    local binding_id = menu_key:match("^binding:(%d+)$")
    if binding_id then
        local row = bindings.by_id(tonumber(binding_id))
        if not row then return nil end
        -- 编辑器与菜单一致：显示按当前请求域名拼接出的入口域名。
        local shown = domain.link(row.domain, ngx.var.host) or row.domain
        return {
            kind = "binding",
            id = tonumber(binding_id),
            domain = shown,
            port = tonumber(row.port),
            label = row.menu_name ~= "" and row.menu_name or shown,
            note = row.note,
            target_ip = row.target_ip,
        }
    end
    local port = menu_key:match("^port:(%d+)$")
    if port then return { kind = "port", port = tonumber(port) } end
    return nil
end

function _M.update(menu_key, data)
    local key = _M.normalize_key(menu_key)
    if not key then return nil, "服务菜单项标识不合法", 422 end
    local target = _M.resolve(key)
    if not target then return nil, "对应的服务已不存在", 404 end
    local now = os.time()

    local override_values = {}
    if data.icon ~= nil then override_values.icon = clean(data.icon, 128) end
    if data.enabled ~= nil then
        override_values.enabled = (data.enabled == true or data.enabled == 1) and 1 or 0
    end
    if data.sort_order ~= nil then
        local sort_order = tonumber(data.sort_order)
        if not sort_order then return nil, "排序值必须是数字", 422 end
        override_values.sort_order = sort_order
    end

    if data.label ~= nil then
        -- 空串表示清除自定义名称：域名条目回落到域名，端口条目回落到 local:<port>。
        local label = clean(data.label, 128)
        if target.kind == "binding" then
            -- 域名服务条目：名称回写绑定，保持与代理层同一事实来源。
            local ok, db_err = db.authz_transaction(function()
                local updated, update_err = bindings.update(target.id, { "menu_name = ?" }, { label })
                if not updated then return nil, update_err end
                return true
            end)
            if not ok then return common.db_error("更新菜单名称失败", db_err) end
        else
            override_values.label = label
        end
    end

    if next(override_values) then
        local ok, db_err = db.authz_transaction(function()
            local saved, save_err = menu_overrides.upsert(key, override_values, now)
            if not saved then return nil, save_err end
            return true
        end)
        if not ok then return common.db_error("更新菜单失败", db_err) end
    end
    return { message = "菜单已更新" }
end

function _M.reset(menu_key)
    local key = _M.normalize_key(menu_key)
    if not key then return nil, "服务菜单项标识不合法", 422 end
    local target = _M.resolve(key)
    if not target then return nil, "对应的服务已不存在", 404 end
    local ok, err = db.authz_transaction(function()
        -- 域名条目的名称事实来源在绑定侧，恢复默认 = 清空 menu_name。
        if target.kind == "binding" then
            local cleared, clear_err = bindings.update(target.id, { "menu_name = ?" }, { "" })
            if not cleared then return nil, clear_err end
        end
        local deleted, delete_err = menu_overrides.delete(key)
        if not deleted then return nil, delete_err end
        return true
    end)
    if not ok then return common.db_error("恢复菜单默认失败", err) end
    return { message = "已恢复默认菜单项" }
end

-- Persist the order of one dynamic group: {order = {"port:8080", ...}}.
-- Keys that are not (or no longer) resolvable are skipped, unknown keys 422.
function _M.reorder(data)
    local order = data and data.order
    if type(order) ~= "table" or #order == 0 then return nil, "排序列表不能为空", 422 end
    local now = os.time()
    local ok, err = db.authz_transaction(function()
        for index, item in ipairs(order) do
            local key = _M.normalize_key(type(item) == "table" and item.id or item)
            if not key then return nil, "排序项标识不合法", 422 end
            if not _M.resolve(key) then return nil, "排序项对应的服务已不存在: " .. key, 409 end
            local saved, save_err = menu_overrides.upsert(key, { sort_order = index }, now)
            if not saved then return nil, save_err end
        end
        return true
    end)
    if not ok then return common.db_error("菜单排序失败", err) end
    return { message = "菜单顺序已保存" }
end

return _M
