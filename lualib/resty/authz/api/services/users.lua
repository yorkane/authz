local db = require "resty.authz.db"
local identity = require "resty.authz.identity"
local policies = require "resty.authz.repository.policies"
local remote_users = require "resty.authz.repository.remote_users"
local session = require "resty.authz.session"
local sessions = require "resty.authz.repository.sessions"
local users = require "resty.authz.repository.users"
local util = require "resty.authz.util"
local validation = require "resty.authz.api.validation"
local common = require "resty.authz.api.common"

local _M = {}

function _M.create(data)
    local username = tostring(data.username or ""):lower():gsub("%s+", "")
    local password = tostring(data.password or "")
    if not ngx.re.match(username, [[^[a-z0-9_-]{2,32}$]]) then
        return nil, "用户名格式不合法", 422
    end
    if #password < 6 then return nil, "密码至少 6 位", 422 end
    local roles, role_err = validation.normalize_roles(data.roles)
    if not roles then return nil, role_err, 422 end
    local salt = util.random_token(16)
    local hash, hash_err = util.hash_password(password, salt)
    if not hash then return nil, tostring(hash_err), 500 end
    local ok, err = db.authz_transaction(function()
        local inserted, insert_err = users.insert(username, hash, salt, roles, os.time())
        if not inserted then return nil, insert_err end
        return true
    end)
    if not ok then return common.db_error("创建用户失败", err) end
    return { message = "用户已创建" }, nil, 201
end

function _M.update(id, data)
    local user = users.by_id(id)
    if not user then return nil, "用户不存在", 404 end
    local enabled
    if data.enabled ~= nil then
        enabled = (data.enabled == true or data.enabled == 1) and 1 or 0
        if user.username == "admin" and enabled == 0 then return nil, "不能禁用内置管理员", 409 end
    end
    local roles
    if data.roles ~= nil then
        if user.username == "admin" then return nil, "不能修改内置管理员角色", 409 end
        local role_err
        roles, role_err = validation.normalize_roles(data.roles)
        if not roles then return nil, role_err, 422 end
    end
    local ok, err = db.authz_transaction(function()
        local updated, update_err = users.update_fields(id, enabled, roles, os.time())
        if not updated then return nil, update_err end
        if enabled == 0 then
            local deleted, delete_err = sessions.delete_all_for(user.username, "local")
            if not deleted then return nil, delete_err end
        end
        return true
    end)
    if not ok then return common.db_error("更新用户失败", err) end
    if enabled == 0 then session.delete_shared_all_for(user.username, "local") end
    return { message = "用户已更新" }
end

function _M.update_remote(provider, subject, data)
    provider = tostring(provider or ""):lower()
    subject = tostring(subject or "")
    if not provider:match("^[a-z0-9_.-]+$") or subject == "" then
        return nil, "远程身份格式不合法", 422
    end
    local user = remote_users.by_identity(provider, subject)
    if not user then return nil, "远程用户不存在", 404 end
    local roles, overridden
    if data.use_remote_roles == true then
        roles, overridden = user.remote_roles, 0
    elseif data.roles ~= nil then
        local role_err
        roles, role_err = validation.normalize_roles(data.roles)
        if not roles then return nil, role_err, 422 end
        overridden = 1
    end
    if data.enabled == nil and roles == nil then return nil, "没有可更新字段", 422 end
    local enabled = data.enabled ~= nil and
        ((data.enabled == true or data.enabled == 1) and 1 or 0) or nil
    local ok, err = db.authz_transaction(function()
        local updated, update_err = remote_users.update_fields(
            provider, subject, enabled, roles, overridden, os.time())
        if not updated then return nil, update_err end
        if enabled == 0 then
            local deleted, delete_err = sessions.delete_all_for(user.username, provider)
            if not deleted then return nil, delete_err end
        end
        return true
    end)
    if not ok then return common.db_error("更新远程用户失败", err) end
    if enabled == 0 then session.delete_shared_all_for(user.username, provider) end
    return {
        message = roles ~= nil and
            (overridden == 1 and "远程用户角色已覆盖" or "已恢复上游角色") or
            "远程用户状态已更新",
        roles = roles or user.roles,
        roles_overridden = roles ~= nil and overridden or user.roles_overridden,
    }
end

function _M.delete(id)
    local user = users.by_id(id)
    if not user then return nil, "用户不存在", 404 end
    if user.username == "admin" then return nil, "不能删除内置管理员", 409 end
    local principal = identity.key("local", user.username)
    local ok, err = db.authz_transaction(function()
        local deleted, delete_err = users.delete(id)
        if not deleted then return nil, delete_err end
        local policies_deleted, policy_err = policies.delete_for_principal(principal)
        if not policies_deleted then return nil, policy_err end
        local sessions_deleted, session_err = sessions.delete_all_for(user.username, "local")
        if not sessions_deleted then return nil, session_err end
        return true
    end)
    if not ok then return common.db_error("删除用户失败", err) end
    session.delete_shared_all_for(user.username, "local")
    return { message = "用户已删除" }
end

function _M.delete_remote(provider, subject)
    provider = tostring(provider or ""):lower()
    subject = tostring(subject or "")
    if not provider:match("^[a-z0-9_.-]+$") or subject == "" then
        return nil, "远程身份格式不合法", 422
    end
    local user = remote_users.by_identity(provider, subject)
    if not user then return nil, "远程用户不存在", 404 end
    local principal = identity.key(provider, user.username)
    local ok, err = db.authz_transaction(function()
        local deleted, delete_err = remote_users.delete(provider, subject)
        if not deleted then return nil, delete_err end
        local policies_deleted, policy_err = policies.delete_for_principal(principal)
        if not policies_deleted then return nil, policy_err end
        local sessions_deleted, session_err = sessions.delete_all_for(user.username, provider)
        if not sessions_deleted then return nil, session_err end
        return true
    end)
    if not ok then return common.db_error("删除远程用户失败", err) end
    session.delete_shared_all_for(user.username, provider)
    return { message = "远程用户已删除" }
end

function _M.reset_password(id, data)
    local user = users.by_id(id)
    if not user then return nil, "用户不存在", 404 end
    local password = tostring(data.password or data.newpw or "")
    if #password < 6 then return nil, "密码至少 6 位", 422 end
    local salt = util.random_token(16)
    local hash, hash_err = util.hash_password(password, salt)
    if not hash then return nil, tostring(hash_err), 500 end
    local ok, err = db.transaction(function()
        local updated, update_err = users.update_password_by_id(id, hash, salt, os.time())
        if not updated then return nil, update_err end
        local deleted, delete_err = sessions.delete_all_for(user.username, "local")
        if not deleted then return nil, delete_err end
        return true
    end)
    if not ok then return common.db_error("重置密码失败", err) end
    session.delete_shared_all_for(user.username, "local")
    return { message = "密码已重置" }
end

function _M.change_password(subject, _, data)
    if subject.source ~= "local" then return nil, "远程用户请在 NocoBase 修改密码", 409 end
    local old_password = tostring(data.old_password or data.oldpw or "")
    local new_password = tostring(data.new_password or data.newpw or "")
    local confirmation = tostring(data.new_password_confirm or data.newpw_confirm or "")
    local user = users.password(subject.username)
    if not user or not util.verify_password(old_password, user.salt, user.password_hash) then
        return nil, "当前密码错误", 422
    end
    if #new_password < 6 then return nil, "新密码至少 6 位", 422 end
    if confirmation ~= "" and confirmation ~= new_password then
        return nil, "两次输入的新密码不一致", 422
    end
    local salt = util.random_token(16)
    local hash, hash_err = util.hash_password(new_password, salt)
    if not hash then return nil, tostring(hash_err), 500 end
    local ok, err = db.transaction(function()
        local updated, update_err = users.update_password(subject.username, hash, salt, os.time())
        if not updated then return nil, update_err end
        local deleted, delete_err = sessions.delete_all_for(subject.username, "local")
        if not deleted then return nil, delete_err end
        return true
    end)
    if not ok then return common.db_error("修改密码失败", err) end
    session.delete_shared_all_for(subject.username, "local")
    return { message = "密码已修改" }
end

return _M
