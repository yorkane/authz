-- OAuth/OIDC provider configuration assembly.

local _M = {}

local function env_bool(name, default)
    local value = os.getenv(name)
    if value == nil or value == "" then return default end
    value = value:lower()
    return value == "1" or value == "true" or value == "yes" or value == "on"
end

-- viewer 已退役为 guest：旧环境变量里写 viewer 的部署继续可用，按 guest 处理。
local function normalize_role(role)
    role = role:lower()
    return role == "viewer" and "guest" or role
end

local function parse_roles(value, default)
    local allowed = { admin = true, staff = true, user = true, guest = true }
    local roles, selected = {}, {}
    for role in tostring(value or default or "guest"):gmatch("[^,%s]+") do
        role = normalize_role(role)
        if allowed[role] then selected[role] = true end
    end
    for _, role in ipairs({ "admin", "staff", "user", "guest" }) do
        if selected[role] then roles[#roles + 1] = role end
    end
    if #roles == 0 then roles[1] = "guest" end
    return roles
end

local function parse_role_map(value)
    local allowed = { admin = true, staff = true, user = true, guest = true }
    local map = {}
    for entry in tostring(value or ""):gmatch("[^,;]+") do
        local source, target = entry:match("^%s*([%w_.-]+)%s*=%s*([%w_.-]+)%s*$")
        if source and allowed[normalize_role(target)] then map[source:lower()] = normalize_role(target) end
    end
    return map
end

local function validate_provider(provider, allow_http)
    if provider.client_id == "" or provider.redirect_uri == "" then
        error("OAuth provider " .. provider.id .. " requires client id and redirect URI")
    end
    if provider.token_auth_method == "client_secret_basic" and provider.client_secret == "" then
        error("OAuth provider " .. provider.id .. " requires client secret")
    end
    local fields = { "authorize_url", "token_url", "userinfo_url", "redirect_uri" }
    if provider.issuer then fields[#fields + 1] = "issuer" end
    for _, field in ipairs(fields) do
        local value = provider[field]
        local scheme = value:match("^(https?)://")
        if not scheme or value:find("[#]", 1) or (scheme ~= "https" and not allow_http) then
            error("OAuth provider " .. provider.id .. " has invalid " .. field)
        end
    end
end

function _M.configure(c)
    local allow_http = env_bool("AUTHZ_OAUTH_ALLOW_HTTP", false)
    c.oauth_providers = {}
    if c.noco_oauth_enabled then
        local provider = {
            id = "nocobase", kind = "nocobase",
            title = os.getenv("AUTHZ_NOCO_OAUTH_TITLE") or "NocoBase",
            client_id = os.getenv("AUTHZ_NOCO_OAUTH_CLIENT_ID") or "",
            client_secret = os.getenv("AUTHZ_NOCO_OAUTH_CLIENT_SECRET") or "",
            authorize_url = c.noco_base_url .. "/api/idpOAuth/authorize",
            token_url = c.noco_base_url .. "/api/idpOAuth/token",
            userinfo_url = c.noco_base_url .. "/api/idpOAuth/me",
            issuer = c.noco_base_url .. "/api",
            redirect_uri = os.getenv("AUTHZ_NOCO_OAUTH_REDIRECT_URI") or "",
            scope = "openid profile email api", subject_claim = "sub",
            username_claim = "preferred_username", role_claim = "roles",
            role_map = parse_role_map(c.noco_role_map),
            default_roles = parse_roles(os.getenv("AUTHZ_NOCO_OAUTH_DEFAULT_ROLES"), "guest"),
            require_verified_email = false, use_pkce = true,
            token_auth_method = "client_secret_basic",
        }
        validate_provider(provider, allow_http)
        c.oauth_providers[#c.oauth_providers + 1] = provider
    end
    if env_bool("AUTHZ_GOOGLE_ENABLED", false) then
        local provider = {
            id = "google", kind = "standard", title = os.getenv("AUTHZ_GOOGLE_TITLE") or "Google",
            client_id = os.getenv("AUTHZ_GOOGLE_CLIENT_ID") or "",
            client_secret = os.getenv("AUTHZ_GOOGLE_CLIENT_SECRET") or "",
            authorize_url = "https://accounts.google.com/o/oauth2/v2/auth",
            token_url = "https://oauth2.googleapis.com/token",
            userinfo_url = "https://openidconnect.googleapis.com/v1/userinfo",
            redirect_uri = os.getenv("AUTHZ_GOOGLE_REDIRECT_URI") or "",
            scope = "openid email profile", subject_claim = "sub", username_claim = "email",
            role_claim = "roles", role_map = {},
            default_roles = parse_roles(os.getenv("AUTHZ_GOOGLE_DEFAULT_ROLES"), "guest"),
            access_type = "online", prompt = "select_account",
            require_verified_email = true, use_pkce = true,
        }
        validate_provider(provider, false)
        c.oauth_providers[#c.oauth_providers + 1] = provider
    end
    if env_bool("AUTHZ_DINGTALK_ENABLED", false) then
        local provider = {
            id = "dingtalk", kind = "dingtalk", title = os.getenv("AUTHZ_DINGTALK_TITLE") or "钉钉",
            client_id = os.getenv("AUTHZ_DINGTALK_CLIENT_ID") or "",
            client_secret = os.getenv("AUTHZ_DINGTALK_CLIENT_SECRET") or "",
            authorize_url = os.getenv("AUTHZ_DINGTALK_AUTHORIZE_URL") or
                "https://login.dingtalk.com/oauth2/auth",
            token_url = os.getenv("AUTHZ_DINGTALK_TOKEN_URL") or
                "https://api.dingtalk.com/v1.0/oauth2/userAccessToken",
            userinfo_url = os.getenv("AUTHZ_DINGTALK_USERINFO_URL") or
                "https://api.dingtalk.com/v1.0/contact/users/me",
            redirect_uri = os.getenv("AUTHZ_DINGTALK_REDIRECT_URI") or "",
            scope = os.getenv("AUTHZ_DINGTALK_SCOPE") or "openid",
            subject_claim = "unionId", username_claim = "email", role_claim = "roles", role_map = {},
            default_roles = parse_roles(os.getenv("AUTHZ_DINGTALK_DEFAULT_ROLES"), "guest"),
            prompt = "consent", require_verified_email = false, use_pkce = false,
        }
        validate_provider(provider, allow_http)
        c.oauth_providers[#c.oauth_providers + 1] = provider
    end
    if env_bool("AUTHZ_WECHAT_ENABLED", false) then
        local provider = {
            id = "wechat", kind = "wechat", title = os.getenv("AUTHZ_WECHAT_TITLE") or "微信",
            client_id = os.getenv("AUTHZ_WECHAT_APP_ID") or "",
            client_secret = os.getenv("AUTHZ_WECHAT_APP_SECRET") or "",
            authorize_url = os.getenv("AUTHZ_WECHAT_AUTHORIZE_URL") or
                "https://open.weixin.qq.com/connect/qrconnect",
            token_url = os.getenv("AUTHZ_WECHAT_TOKEN_URL") or
                "https://api.weixin.qq.com/sns/oauth2/access_token",
            userinfo_url = os.getenv("AUTHZ_WECHAT_USERINFO_URL") or
                "https://api.weixin.qq.com/sns/userinfo",
            redirect_uri = os.getenv("AUTHZ_WECHAT_REDIRECT_URI") or "", scope = "snsapi_login",
            subject_claim = "unionid", username_claim = "email", role_claim = "roles", role_map = {},
            default_roles = parse_roles(os.getenv("AUTHZ_WECHAT_DEFAULT_ROLES"), "guest"),
            require_verified_email = false, use_pkce = false,
        }
        validate_provider(provider, allow_http)
        c.oauth_providers[#c.oauth_providers + 1] = provider
    end
    if env_bool("AUTHZ_OAUTH_ENABLED", false) then
        local id = tostring(os.getenv("AUTHZ_OAUTH_PROVIDER") or "oauth"):lower()
        local reserved = { ["local"] = true, nocobase = true, google = true,
            dingtalk = true, wechat = true }
        if not id:match("^[a-z0-9_.-]+$") or reserved[id] then
            error("AUTHZ_OAUTH_PROVIDER is invalid or reserved")
        end
        local provider = {
            id = id, kind = "standard", title = os.getenv("AUTHZ_OAUTH_TITLE") or "OAuth",
            client_id = os.getenv("AUTHZ_OAUTH_CLIENT_ID") or "",
            client_secret = os.getenv("AUTHZ_OAUTH_CLIENT_SECRET") or "",
            authorize_url = os.getenv("AUTHZ_OAUTH_AUTHORIZE_URL") or "",
            token_url = os.getenv("AUTHZ_OAUTH_TOKEN_URL") or "",
            userinfo_url = os.getenv("AUTHZ_OAUTH_USERINFO_URL") or "",
            redirect_uri = os.getenv("AUTHZ_OAUTH_REDIRECT_URI") or "",
            scope = os.getenv("AUTHZ_OAUTH_SCOPE") or "openid email profile",
            subject_claim = os.getenv("AUTHZ_OAUTH_SUBJECT_CLAIM") or "sub",
            username_claim = os.getenv("AUTHZ_OAUTH_USERNAME_CLAIM") or "email",
            role_claim = os.getenv("AUTHZ_OAUTH_ROLE_CLAIM") or "roles",
            role_map = parse_role_map(os.getenv("AUTHZ_OAUTH_ROLE_MAP")),
            default_roles = parse_roles(os.getenv("AUTHZ_OAUTH_DEFAULT_ROLES"), "guest"),
            require_verified_email = env_bool("AUTHZ_OAUTH_REQUIRE_VERIFIED_EMAIL", false),
            use_pkce = true,
        }
        validate_provider(provider, allow_http)
        c.oauth_providers[#c.oauth_providers + 1] = provider
    end
end

return _M
