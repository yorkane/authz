local provider_config = require "resty.authz.provider_config"
local session = require "resty.authz.session"

local _M = {}

local function env_bool(name, default)
    local value = os.getenv(name)
    if value == nil or value == "" then return default end
    value = value:lower()
    return value == "1" or value == "true" or value == "yes" or value == "on"
end

local function configure_session(c)
    session.secure = env_bool("AUTHZ_COOKIE_SECURE", false)
    session.configure_cookie_domain(os.getenv("AUTHZ_COOKIE_DOMAIN"), os.getenv("AUTHZ_HOST_URL"))
    session.shared_enabled = false
    session.redis.mode = "read-only"
    session.redis.username = ""
    c.session_shared = env_bool("AUTHZ_SESSION_SHARED", false)
    if c.session_shared then
        local redis_url = tostring(os.getenv("AUTHZ_SESSION_REDIS_URL") or ""):gsub("%s+", "")
        local host, port_text = redis_url:match("^redis://([^:/]+):?(%d*)$")
        if not host then
            error("AUTHZ_SESSION_SHARED requires AUTHZ_SESSION_REDIS_URL=redis://<host>[:<port>]")
        end
        local port = port_text ~= "" and tonumber(port_text) or 6379
        if not port or port < 1 or port > 65535 then
            error("AUTHZ_SESSION_REDIS_URL port must be 1-65535")
        end
        session.redis.host = host
        session.redis.port = port
        session.redis.username = tostring(os.getenv("AUTHZ_SESSION_REDIS_USERNAME") or "")
        session.redis.password = tostring(os.getenv("AUTHZ_SESSION_REDIS_PASSWORD") or "")
        session.redis.db = tonumber(os.getenv("AUTHZ_SESSION_REDIS_DB")) or 0
        session.redis.prefix = tostring(os.getenv("AUTHZ_SESSION_REDIS_PREFIX") or "authz")
        session.redis.mode = tostring(os.getenv("AUTHZ_SESSION_REDIS_MODE") or "read-only"):lower()
        if session.redis.mode ~= "read-write" and session.redis.mode ~= "read-only" then
            error("AUTHZ_SESSION_REDIS_MODE must be read-write or read-only")
        end
        if session.redis.username:find("[%c%s]") or #session.redis.username > 128 then
            error("AUTHZ_SESSION_REDIS_USERNAME is invalid")
        end
        if session.redis.prefix == "" or #session.redis.prefix > 128 or
            not session.redis.prefix:match("^[A-Za-z0-9_.:-]+$") then
            error("AUTHZ_SESSION_REDIS_PREFIX is invalid")
        end
        if session.redis.db < 0 or session.redis.db > 15 or session.redis.db % 1 ~= 0 then
            error("AUTHZ_SESSION_REDIS_DB must be an integer from 0 to 15")
        end
        session.redis.connect_timeout = tonumber(os.getenv("AUTHZ_SESSION_REDIS_CONNECT_TIMEOUT_MS")) or 2000
        session.redis.read_timeout = tonumber(os.getenv("AUTHZ_SESSION_REDIS_READ_TIMEOUT_MS")) or 2000
        session.shared_enabled = true
        c.session_shared_mode = session.redis.mode
        ngx.log(ngx.NOTICE, "authz: shared session mode enabled (" .. session.redis.mode ..
            ", redis://" .. host .. ":" .. port .. ")")
    end
    local ttl = tonumber(os.getenv("AUTHZ_SESSION_TTL"))
    if ttl then session.ttl = ttl end
end

function _M.load()
    local c = {}
    c.db_path = os.getenv("AUTHZ_DB_PATH") or "/data/authz/authz.db"
    c.admin_password = os.getenv("AUTHZ_ADMIN_PASSWORD") or "admin123"
    c.port_min = math.max(2000, tonumber(os.getenv("AUTHZ_PORT_MIN")) or 2000)
    c.port_max = math.min(65535, tonumber(os.getenv("AUTHZ_PORT_MAX")) or 20000)
    if c.port_max < c.port_min then c.port_max = c.port_min end
    c.http_port = tonumber(os.getenv("AUTHZ_HTTP_PORT")) or 6080
    c.https_port = tonumber(os.getenv("AUTHZ_HTTPS_PORT")) or 6443
    c.discovery_ttl = math.max(5, tonumber(os.getenv("AUTHZ_DISCOVERY_TTL")) or 30)
    c.discovery_connect_timeout = math.max(20,
        tonumber(os.getenv("AUTHZ_DISCOVERY_CONNECT_TIMEOUT_MS")) or 100)
    c.discovery_read_timeout = math.max(20,
        tonumber(os.getenv("AUTHZ_DISCOVERY_READ_TIMEOUT_MS")) or 200)
    c.discovery_ports = tostring(os.getenv("AUTHZ_DISCOVERY_PORTS") or "")
    c.db_cache_ttl = math.max(1, tonumber(os.getenv("AUTHZ_DB_CACHE_TTL")) or 30)
    c.db_cache_lru_size = math.max(50, tonumber(os.getenv("AUTHZ_DB_CACHE_LRU_SIZE")) or 500)
    c.cache_dict = "authz_cache"
    c.login_limit_dict = "authz_login_limit"
    -- 文件浏览器根目录；默认容器内 /files（部署时把宿主目录挂载到 /files）。
    -- 必须与 server.conf 里 /_authz/files/ 的 alias 保持一致。
    c.files_root = os.getenv("AUTHZ_FILES_ROOT") or "/files"
    -- Nginx 配置编辑页（/_authz/api/nginx-conf*）使用的运行时路径。
    -- conf 目录存放渲染后的 nginx.conf/server.conf 与三个用户 include；
    -- template 目录是启动时 include 的来源（compose 里只读挂载）。
    c.nginx_conf_dir = os.getenv("AUTHZ_NGINX_CONF_DIR") or "/usr/local/openresty/nginx/conf"
    c.nginx_prefix = os.getenv("AUTHZ_NGINX_PREFIX") or "/usr/local/openresty/nginx"
    c.nginx_bin = os.getenv("AUTHZ_NGINX_BIN") or "/usr/local/openresty/bin/openresty"
    c.nginx_template_dir = os.getenv("OPENRESTY_TEMPLATE_DIR") or ""
    c.login_attempts = math.max(1, tonumber(os.getenv("AUTHZ_LOGIN_ATTEMPTS")) or 5)
    c.login_window = math.max(60, tonumber(os.getenv("AUTHZ_LOGIN_WINDOW")) or 1800)
    c.login_fail_delay_ms = math.min(10000, math.max(0,
        tonumber(os.getenv("AUTHZ_LOGIN_FAIL_DELAY_MS")) or 1000))
    configure_session(c)

    c.noco_enabled = env_bool("AUTHZ_NOCO_ENABLED", false)
    c.noco_oauth_enabled = env_bool("AUTHZ_NOCO_OAUTH_ENABLED", false)
    c.noco_base_url = tostring(os.getenv("AUTHZ_NOCO_URL") or ""):gsub("/+$", "")
    c.noco_role_map = os.getenv("AUTHZ_NOCO_ROLE_MAP") or ""
    c.noco_connect_timeout = tonumber(os.getenv("AUTHZ_NOCO_CONNECT_TIMEOUT_MS")) or 3000
    c.noco_send_timeout = tonumber(os.getenv("AUTHZ_NOCO_SEND_TIMEOUT_MS")) or 5000
    c.noco_read_timeout = tonumber(os.getenv("AUTHZ_NOCO_READ_TIMEOUT_MS")) or 5000
    c.noco_max_body_size = tonumber(os.getenv("AUTHZ_NOCO_MAX_BODY_SIZE")) or 1048576
    if c.noco_enabled or c.noco_oauth_enabled then
        local scheme = c.noco_base_url:match("^(https?)://")
        if not scheme or c.noco_base_url:find("[?#]") then
            error("NocoBase authentication requires a valid AUTHZ_NOCO_URL")
        end
        if scheme ~= "https" and not env_bool("AUTHZ_NOCO_ALLOW_HTTP", false) then
            error("AUTHZ_NOCO_URL must use https unless AUTHZ_NOCO_ALLOW_HTTP is enabled")
        end
    end

    c.oauth_state_dict = "authz_oauth_state"
    c.oauth_state_ttl = math.max(60, tonumber(os.getenv("AUTHZ_OAUTH_STATE_TTL")) or 600)
    c.oauth_connect_timeout = tonumber(os.getenv("AUTHZ_OAUTH_CONNECT_TIMEOUT_MS")) or 10000
    c.oauth_send_timeout = tonumber(os.getenv("AUTHZ_OAUTH_SEND_TIMEOUT_MS")) or 10000
    c.oauth_read_timeout = tonumber(os.getenv("AUTHZ_OAUTH_READ_TIMEOUT_MS")) or 15000
    c.oauth_max_body_size = tonumber(os.getenv("AUTHZ_OAUTH_MAX_BODY_SIZE")) or 1048576
    provider_config.configure(c)
    return c
end

return _M
