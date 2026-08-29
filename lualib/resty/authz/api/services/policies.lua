local db = require "resty.authz.db"
local repository = require "resty.authz.repository.policies"
local validation = require "resty.authz.api.validation"
local common = require "resty.authz.api.common"

local _M = {}

function _M.create(data)
    local policy, err, status = validation.normalize_policy(data)
    if not policy then return nil, err, status end
    local ok, write_err = db.authz_transaction(function()
        local inserted, insert_err = repository.insert(policy.ptype, policy.v0, policy.v1, policy.v2)
        if not inserted then return nil, insert_err end
        return true
    end)
    if not ok then return common.db_error("创建策略失败", write_err) end
    return { message = "策略已创建" }, nil, 201
end

function _M.update(id, data)
    if not id or not repository.exists(id) then return nil, "策略不存在", 404 end
    local policy, err, status = validation.normalize_policy(data)
    if not policy then return nil, err, status end
    if repository.duplicate(policy.ptype, policy.v0, policy.v1, policy.v2, id) then
        return nil, "相同策略已存在", 409
    end
    local ok, write_err = db.authz_transaction(function()
        local updated, update_err = repository.update(id, policy.ptype, policy.v0, policy.v1, policy.v2)
        if not updated then return nil, update_err end
        return true
    end)
    if not ok then return common.db_error("更新策略失败", write_err) end
    return { message = "策略已更新" }
end

function _M.delete(id)
    local ok, err = db.authz_transaction(function()
        local deleted, delete_err = repository.delete(id)
        if not deleted then return nil, delete_err end
        return true
    end)
    if not ok then return common.db_error("删除策略失败", err) end
    return { message = "策略已删除" }
end

return _M
