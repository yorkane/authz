-- resty.authz.api_key
-- Service API key authentication. Only SHA-256 digests are stored in SQLite.
--
-- 两类 Key：
--   1. 数据库 Key：管理界面创建，用 `x-authz-key` 提交，可选 loopback_only；
--   2. 环境变量 Key（AUTHZ_API_KEY）：用 `x-api-key` 提交的实例级预置 Key，
--      免登录直接调用控制面 API、管理页面与代理入口，专供 Agent 使用。
--      配置由 config.load() 通过 configure_env 注入（本模块不 require 上层模块，
--      避免 init_by_lua 加载链上的 require 循环），权限仍走 Casbin 角色模型。

local repository = require "resty.authz.repository.api_keys"
local util = require "resty.authz.util"

local target = require "resty.authz.target"

local _M = {}

local TOKEN_PATTERN = [[^ak_[0-9a-f]{64}$]]
local ROLE_SET = { admin = true, staff = true, user = true, viewer = true, api = true }

-- 环境变量 Key 的固定 principal（Casbin g 线用）与运行期配置；token 为空即未启用。
_M.env_identity = "api-key:0"
_M.env = { token = "", role = "admin", loopback_only = false }

function _M.configure_env(options)
    options = options or {}
    _M.env.token = tostring(options.token or "")
    _M.env.role = _M.valid_role(options.role) or "admin"
    _M.env.loopback_only = options.loopback_only == true
end

function _M.valid_role(role)
    role = tostring(role or ""):lower()
    return ROLE_SET[role] and role or nil
end

function _M.principal(id)
    id = tonumber(id)
    if not id or id < 1 or id ~= math.floor(id) then return nil end
    return "api-key:" .. tostring(id)
end

function _M.authenticate(token)
    if type(token) ~= "string" or #token ~= 67 then return nil end
    if not ngx.re.match(token, TOKEN_PATTERN, "jo") then return nil end
    local token_hash = util.sha256_hex(token)
    if not token_hash then return nil end
    local row = repository.by_hash(token_hash)
    local role = row and _M.valid_role(row.role)
    if not role then return nil end
    -- loopback_only 密钥仅接受本机回环来源；非回环访问一律拒绝。
    if row.loopback_only == 1 and not target.is_loopback(ngx.var.remote_addr) then
        ngx.log(ngx.WARN, "authz: loopback-only API key rejected from ",
            tostring(ngx.var.remote_addr))
        return nil
    end
    return {
        kind = "api_key",
        id = row.id,
        name = row.name,
        username = row.name,
        source = "api-key",
        role = role,
        roles = { role },
        loopback_only = row.loopback_only == 1,
        identity = _M.principal(row.id),
        created_at = row.created_at,
        updated_at = row.updated_at,
    }
end

-- Returns presented, identity. A malformed or duplicate header is presented
-- but unauthenticated, so callers never fall back to a browser cookie.
-- `x-authz-key` 优先：一旦呈现就只认它，绝不因 Key 无效而回退到 Cookie 或其他头。
function _M.authenticate_request()
    local headers = ngx.req.get_headers()
    local token = headers["x-authz-key"]
    if token == nil then
        token = headers["x-api-key"]
        if token == nil then return false, nil end
        if type(token) ~= "string" then return true, nil end
        return true, _M.authenticate_env(token)
    end
    if type(token) ~= "string" then return true, nil end
    return true, _M.authenticate(token)
end

-- 环境变量 Key（`x-api-key`）：常量时间比较，可选仅回环来源。不查库、不签发
-- 会话 Cookie，因此不受管理界面禁用/删除影响，随容器环境变量轮换。
function _M.authenticate_env(token)
    local configured = _M.env.token
    if configured == "" then return nil end
    if type(token) ~= "string" then return nil end
    if not util.constant_time_equals(token, configured) then return nil end
    if _M.env.loopback_only and not target.is_loopback(ngx.var.remote_addr) then
        ngx.log(ngx.WARN, "authz: loopback-only env API key rejected from ",
            tostring(ngx.var.remote_addr))
        return nil
    end
    local role = _M.valid_role(_M.env.role) or "admin"
    return {
        kind = "api_key",
        env_key = true,
        id = 0,
        name = "env-api-key",
        username = "env-api-key",
        source = "api-key",
        role = role,
        roles = { role },
        loopback_only = _M.env.loopback_only,
        identity = _M.env_identity,
        created_at = 0,
        updated_at = 0,
    }
end

-- 管理页面 / 文件浏览的免登录放行：合法 Key（数据库 Key 或环境变量 Key）直接
-- 取页面与静态资源，不签发会话 Cookie。Agent 只需给每个请求带上 `x-api-key`
-- （Playwright 用 setExtraHTTPHeaders，curl 用 -H），页面内 JS 对 /_authz/api/*
-- 的调用也会沿用同一请求头。
function _M.authorize_request()
    local presented, current = _M.authenticate_request()
    return presented and current ~= nil
end

return _M
