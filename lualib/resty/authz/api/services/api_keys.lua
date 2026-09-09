local api_key = require "resty.authz.api_key"
local db = require "resty.authz.db"
local repository = require "resty.authz.repository.api_keys"
local util = require "resty.authz.util"
local validation = require "resty.authz.api.validation"
local common = require "resty.authz.api.common"

local _M = {}

function _M.list()
    return repository.list()
end

function _M.create(data)
    local name = validation.valid_api_key_name(data.name)
    if not name then return nil, "名称需为 2-64 位字母、数字、点、下划线或连字符", 422 end
-- 新建 API 默认 guest 角色（只放行 /_authz/guest 只读页），可显式选其他角色。
    local role = api_key.valid_role(data.role or "guest")
    if not role then return nil, "API Key 角色仅支持 admin、staff、user、guest、api", 422 end
    local random_part = util.random_token(32)
    if not random_part then return nil, "生成 API Key 失败", 500 end
    local token = "ak_" .. random_part
    local token_hash, hash_err = util.sha256_hex(token)
    if not token_hash then return nil, tostring(hash_err), 500 end
    -- 指纹 = 明文前 11 字符（ak_ + 8 hex）。它随明文一起生成、随轮换一起更新，
    -- 只用于在列表里认出「这是哪一把」；库里其余部分仍是不可逆摘要。
    local token_prefix = token:sub(1, 11)
    local created, err, status = db.authz_transaction(function()
        if repository.name_exists(name) then return nil, "API Key 名称已存在", 409 end
        local inserted, insert_err = repository.insert(name, token_hash, token_prefix, role, os.time())
        if not inserted then return nil, insert_err end
        local row = repository.by_hash_metadata(token_hash)
        if not row then return nil, "创建 API Key 后读取失败" end
        return row
    end)
    if not created then
        if status then return nil, err, status end
        return common.db_error("创建 API Key 失败", err)
    end
    created.token = token
    return created, nil, 201
end

-- 轮换密钥：旧明文立即失效，新明文仅在本次响应里出现一次（与创建同契约）。
-- 名称与角色保持不变，调用方拿到新值后直接替换 x-api-key 即可。
function _M.rotate(id)
    id = tonumber(id)
    if not id or not repository.by_id(id) then return nil, "API Key 不存在", 404 end
    local random_part = util.random_token(32)
    if not random_part then return nil, "生成 API Key 失败", 500 end
    local token = "ak_" .. random_part
    local token_hash, hash_err = util.sha256_hex(token)
    if not token_hash then return nil, tostring(hash_err), 500 end
    local token_prefix = token:sub(1, 11)
    local rotated, err = db.authz_transaction(function()
        local updated, update_err = repository.rehash(id, token_hash, token_prefix, os.time())
        if not updated then return nil, update_err end
        return repository.by_id(id)
    end)
    if not rotated then return common.db_error("轮换 API Key 失败", err) end
    rotated.token = token
    return rotated
end

function _M.update(id, data)
    id = tonumber(id)
    if not id or not repository.by_id(id) then return nil, "API Key 不存在", 404 end
    local fields, values = {}, {}
    if data.name ~= nil then
        local name = validation.valid_api_key_name(data.name)
        if not name then return nil, "名称需为 2-64 位字母、数字、点、下划线或连字符", 422 end
        if repository.name_exists(name, id) then return nil, "API Key 名称已存在", 409 end
        fields[#fields + 1], values[#values + 1] = "name = ?", name
    end
    if data.enabled ~= nil then
        fields[#fields + 1], values[#values + 1] = "enabled = ?",
            (data.enabled == true or data.enabled == 1) and 1 or 0
    end
    if data.role ~= nil then
        local role = api_key.valid_role(data.role)
        if not role then return nil, "API Key 角色仅支持 admin、staff、user、guest、api", 422 end
        fields[#fields + 1], values[#values + 1] = "role = ?", role
    end
    if #fields == 0 then return nil, "没有可更新字段", 422 end
    fields[#fields + 1], values[#values + 1] = "updated_at = ?", os.time()
    local ok, err = db.authz_transaction(function()
        local updated, update_err = repository.update(id, fields, values)
        if not updated then return nil, update_err end
        return true
    end)
    if not ok then return common.db_error("更新 API Key 失败", err) end
    return repository.by_id(id)
end

function _M.delete(id)
    id = tonumber(id)
    if not id or not repository.by_id(id) then return nil, "API Key 不存在", 404 end
    local ok, err = db.authz_transaction(function()
        local deleted, delete_err = repository.delete(id)
        if not deleted then return nil, delete_err end
        return true
    end)
    if not ok then return common.db_error("删除 API Key 失败", err) end
    return { message = "API Key 已删除" }
end

return _M
