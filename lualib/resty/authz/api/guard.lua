local authz = require "resty.authz"
local api_key = require "resty.authz.api_key"
local db = require "resty.authz.db"
local service = require "resty.authz.api.service"
local session = require "resty.authz.session"

local _M = {}

local function error_payload(code, message)
    return { error = { code = code, message = message } }
end

function _M.wrap(handler, options)
    options = options or {}
    return function(params, env, req)
        db.open(authz.config.db_path)
        local key_presented, current = api_key.authenticate_request()
        local token
        if key_presented then
            if not current then
                return error_payload("invalid_api_key", "API Key 无效或已禁用"), 401
            end
            if options.session_only then
                return error_payload("forbidden", "此接口仅适用于浏览器会话"), 403
            end
        else
            token = session.get_request_token()
            current = token and session.get(token)
            if not current then
                return error_payload("unauthenticated", "请先登录"), 401
            end
        end
        -- guest 是匿名用户角色，默认能力面只有两条：只读探针 /_authz/guest
        -- （由 resty.authz.guest 自行认证）与读取「自己」的身份。控制面 API
        -- 除此之外一律拒绝（包括默认不要求角色的只读接口，避免 guest 借它们
        -- 侦察内部端口、域名与目录）；guest 的代理访问范围与其他角色相同，
        -- 由策略（role:guest 主体）配置，在网关代理阶段（gateway/access）生效。
        --
        -- options.self_service 标出的就是「只回显调用者自身」的端点：它不含任何
        -- 侦察价值，却是确认身份与在管理界面退出登录的前提，所以浏览器会话与
        -- guest Key 都放行。写操作（例如注销）另外带 session_only，机器 Key 仍进不去。
        if not options.self_service and service.is_guest(current) then
            return error_payload("forbidden",
                "guest 角色仅可访问 /_authz/guest 探针与自身的会话身份"), 403
        end
        if options.admin and not service.is_admin(current) then
            return error_payload("forbidden", "需要管理员权限"), 403
        end
        if options.roles and not service.has_any_role(current, options.roles) then
            return error_payload("forbidden", "当前角色无权调用此接口"), 403
        end
        if not key_presented and options.csrf and req.get_header("X-CSRF-Token", env) ~= current.csrf then
            return error_payload("csrf_failed", "CSRF 校验失败"), 403
        end
        return handler(params, env, req, current, token)
    end
end

function _M.result(data, err, status)
    if not data then
        return error_payload(status == 404 and "not_found" or "request_failed", err), status or 400
    end
    return { data = data }, status or 200
end

return _M
