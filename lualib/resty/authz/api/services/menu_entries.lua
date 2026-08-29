-- Menu tree service. The left-menu layout is a two-level tree:
-- group nodes (kind='group') and item nodes (kind='item', parent_id -> group).
-- builtin='local' marks the group where dynamically discovered local services
-- are injected by the read model at render time.

local db = require "resty.authz.db"
local menu_entries = require "resty.authz.repository.menu_entries"
local common = require "resty.authz.api.common"

local _M = {}

local BUILTIN_KINDS = { item = true, group = true }

local function clean(value, max_len)
    value = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if #value > max_len then value = value:sub(1, max_len) end
    return value
end

local function valid_url(url, kind)
    if kind == "group" then return "" end
    if url == "" then return nil, "入口地址不能为空" end
    if url:find("%c") or url:match("^//") then return nil, "入口地址格式不合法" end
    if url:sub(1, 1) == "/" then return url end
    local scheme = url:match("^(https?)://")
    if not scheme then return nil, "入口地址必须以 / 或 http://、https:// 开头" end
    return url
end

local function parent_exists_and_is_group(parent_id)
    local parent = menu_entries.by_id(parent_id)
    return parent and parent.kind == "group"
end

function _M.list()
    return menu_entries.list()
end

function _M.create(data)
    local kind = tostring(data.kind or "item")
    if not BUILTIN_KINDS[kind] then return nil, "菜单类型必须是 group 或 item", 422 end
    local label = clean(data.label, 128)
    local icon = clean(data.icon, 128)
    if label == "" then return nil, "菜单名称不能为空", 422 end
    local parent_id
    if kind == "item" then
        parent_id = tonumber(data.parent_id)
        if not parent_id or not parent_exists_and_is_group(parent_id) then
            return nil, "条目必须挂在一个分组下", 422
        end
    end
    local normalized_url, url_err = valid_url(clean(data.url, 2048), kind)
    if not normalized_url then return nil, url_err, 422 end
    local now = os.time()
    local rows = menu_entries.list()
    local max_order = 0
    for _, row in ipairs(rows) do
        if (tonumber(row.sort_order) or 0) > max_order then max_order = tonumber(row.sort_order) end
    end
    local ok, err = db.authz_transaction(function()
        local inserted, insert_err = menu_entries.insert({
            kind = kind, parent_id = parent_id, label = label,
            url = normalized_url, icon = icon, builtin = "", admin_only = 0,
            sort_order = max_order + 1, enabled = 1,
            created_at = now, updated_at = now,
        })
        if not inserted then return nil, insert_err end
        return true
    end)
    if not ok then return common.db_error("创建菜单失败", err) end
    return { message = "菜单已创建" }, nil, 201
end

function _M.update(id, data)
    local existing = menu_entries.by_id(id)
    if not existing then return nil, "菜单不存在", 404 end
    local fields, values = {}, {}
    if data.label ~= nil then
        local label = clean(data.label, 128)
        if label == "" then return nil, "菜单名称不能为空", 422 end
        fields[#fields + 1], values[#values + 1] = "label = ?", label
    end
    if data.url ~= nil and existing.kind == "item" then
        local normalized_url, url_err = valid_url(clean(data.url, 2048), "item")
        if not normalized_url then return nil, url_err, 422 end
        fields[#fields + 1], values[#values + 1] = "url = ?", normalized_url
    end
    if data.icon ~= nil then
        fields[#fields + 1], values[#values + 1] = "icon = ?", clean(data.icon, 128)
    end
    if data.parent_id ~= nil and existing.kind == "item" then
        local parent_id = tonumber(data.parent_id)
        if not parent_id or not parent_exists_and_is_group(parent_id) then
            return nil, "条目必须挂在一个分组下", 422
        end
        if parent_id == id then return nil, "分组不能挂在自己下面", 422 end
        fields[#fields + 1], values[#values + 1] = "parent_id = ?", parent_id
    end
    if data.sort_order ~= nil then
        local order = tonumber(data.sort_order)
        if not order then return nil, "排序值必须是数字", 422 end
        fields[#fields + 1], values[#values + 1] = "sort_order = ?", order
    end
    if data.enabled ~= nil then
        fields[#fields + 1], values[#values + 1] = "enabled = ?",
            (data.enabled == true or data.enabled == 1) and 1 or 0
    end
    if #fields == 0 then return nil, "没有可更新字段", 422 end
    fields[#fields + 1], values[#values + 1] = "updated_at = ?", os.time()
    local ok, err = db.authz_transaction(function()
        local updated, update_err = menu_entries.update(id, fields, values)
        if not updated then return nil, update_err end
        return true
    end)
    if not ok then return common.db_error("更新菜单失败", err) end
    return { message = "菜单已更新" }
end

-- reorder accepts [{id, parent_id(optional)}]; assigns sequential sort_order.
function _M.reorder(order_list)
    if type(order_list) ~= "table" or #order_list == 0 then
        return nil, "排序列表不能为空", 422
    end
    local now = os.time()
    local ok, err = db.authz_transaction(function()
        for index, item in ipairs(order_list) do
            local id = tonumber(item.id)
            if not id then return nil, "排序项缺少有效 id", 422 end
            local fields = { "sort_order = ?", "updated_at = ?" }
            local values = { index, now }
            if item.parent_id ~= nil then
                local parent_id = tonumber(item.parent_id)
                if not parent_id or not parent_exists_and_is_group(parent_id) then
                    return nil, "排序项的父分组不存在", 422
                end
                fields[#fields + 1] = "parent_id = ?"
                values[#values + 1] = parent_id
            end
            local updated, update_err = menu_entries.update(id, fields, values)
            if not updated then return nil, update_err end
        end
        return true
    end)
    if not ok then return common.db_error("菜单排序失败", err) end
    return { message = "菜单顺序已保存" }
end

function _M.delete(id)
    local existing = menu_entries.by_id(id)
    if not existing then return nil, "菜单不存在", 404 end
    if existing.kind == "group" then
        local children = db.query(
            "SELECT COUNT(*) AS c FROM menu_entries WHERE parent_id = ?", id)
        if children and children[1] and (tonumber(children[1].c) or 0) > 0 then
            return nil, "分组下仍有条目，不能直接删除", 409
        end
    end
    local ok, err = db.authz_transaction(function()
        local deleted, delete_err = menu_entries.delete(id)
        if not deleted then return nil, delete_err end
        return true
    end)
    if not ok then return common.db_error("删除菜单失败", err) end
    return { message = "菜单已删除" }
end

return _M

