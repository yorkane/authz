-- resty.authz.api_key
-- Service API key authentication. Only SHA-256 digests are stored in SQLite.
--
-- 两类 Key：
--   1. 数据库 Key：管理界面创建（ak_ + 64 hex），可选 loopback_only。可用
--      `x-role-key`（角色 Key 专用头）或 `x-api-key` 提交；
--   2. 环境变量 Key（AUTHZ_API_KEY）：实例级预置 Key，只能用 `x-api-key` 提交，
--      配置由 config.load() 通过 configure_env 注入（本模块不 require 上层模块，
--      避免 init_by_lua 加载链上的 require 循环）。
-- `x-api-key` 的认证顺序：先按 ak_ 格式查库，未命中再与环境变量 Key 常量时间比较。
-- 权限统一走 Casbin 角色模型。旧 `x-authz-key` 已合并移除，不再接受。

local repository = require "resty.authz.repository.api_keys"
local util = require "resty.authz.util"

local target = require "resty.authz.target"

local _M = {}

local TOKEN_PATTERN = [[^ak_[0-9a-f]{64}$]]
local ROLE_SET = { admin = true, staff = true, user = true, viewer = true, guest = true, api = true }

-- 环境变量 Key 的固定 principal（Casbin g 线用）与运行期配置；token 为空即未启用。
-- allowed_ips 是来源白名单（target.normalize_cidr_list 的条目集合），config.load() 已保证非空。
_M.env_identity = "api-key:0"
_M.env = { token = "", role = "admin", allowed_ips = {}, allowed_text = "127.0.0.1" }

function _M.configure_env(options)
    options = options or {}
    _M.env.token = tostring(options.token or "")
    _M.env.role = _M.valid_role(options.role) or "admin"
    _M.env.allowed_ips = options.allowed_ips or {}
    _M.env.allowed_text = tostring(options.allowed_text or "127.0.0.1")
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

-- 机器凭证头：`x-role-key`（仅数据库 Key）与 `x-api-key`（数据库 Key 或环境变量 Key）。
-- 旧 `x-authz-key` 已合并进 `x-api-key`。
_M.headers = { "x-role-key", "x-api-key" }

-- Returns presented, identity. A malformed or duplicate header is presented
-- but unauthenticated, so callers never fall back to a browser cookie.
-- 只要呈现了任一凭证头就只认它，绝不因 Key 无效而回退到 Cookie。两个头同时
-- 呈现时以 `x-role-key` 为准（更具体的头优先）。
function _M.authenticate_request()
    local headers = ngx.req.get_headers()
    local role_token = headers["x-role-key"]
    if role_token ~= nil then
        if type(role_token) ~= "string" then return true, nil end
        return true, _M.authenticate(role_token)
    end
    local token = headers["x-api-key"]
    if token == nil then return false, nil end
    if type(token) ~= "string" then return true, nil end
    return true, _M.authenticate(token) or _M.authenticate_env(token)
end

-- 环境变量 Key（`x-api-key`）：常量时间比较 + 来源 IP/CIDR 白名单。
-- 不查库、不签发会话 Cookie，因此不受管理界面禁用/删除影响，随容器环境变量轮换。
function _M.authenticate_env(token)
    local configured = _M.env.token
    if configured == "" then return nil end
    if type(token) ~= "string" then return nil end
    if not util.constant_time_equals(token, configured) then return nil end
    -- 白名单为空（配置异常）时 fail-closed：拒绝一切来源。
    if not target.ip_in_list(ngx.var.remote_addr, _M.env.allowed_ips) then
        ngx.log(ngx.WARN, "authz: env API key rejected from ",
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
        allowed_ips = _M.env.allowed_text,
        identity = _M.env_identity,
        created_at = 0,
        updated_at = 0,
    }
end

-- 管理页面 / 文件浏览的免登录放行：合法 Key 直接取页面与静态资源，不签发会话
-- Cookie。Agent 只需给每个请求带上 `x-api-key`（Playwright 用
-- setExtraHTTPHeaders，curl 用 -H），页面内 JS 对 /_authz/api/* 的调用也会
-- 沿用同一请求头。
--
-- guest 是唯一被排除在外的角色：它只能访问只读诊断页 /_authz/app/guest.html
-- （由 resty.authz.guest 自行认证），拿不到管理页面、静态资源与文件浏览。
function _M.authorize_request()
    local presented, current = _M.authenticate_request()
    if not presented or not current then return false end
    if current.role == "guest" then return false end
    return true
end

return _M
