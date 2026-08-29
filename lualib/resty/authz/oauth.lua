local cjson = require "cjson.safe"
local remote = require "resty.authz.remote"
local sha256 = require "resty.sha256"
local util = require "resty.authz.util"

local _M = {}

local function config()
    return require("resty.authz").config
end

local function base64url(value)
    return ngx.encode_base64(value):gsub("=+$", ""):gsub("+", "-"):gsub("/", "_")
end

local function sha256_digest(value)
    local digest = sha256:new()
    if not digest then return nil end
    digest:update(value)
    return digest:final()
end

local function form_encode(values)
    local parts = {}
    for _, key in ipairs({ "grant_type", "code", "client_id", "client_secret", "redirect_uri", "code_verifier" }) do
        if values[key] and values[key] ~= "" then
            parts[#parts + 1] = ngx.escape_uri(key) .. "=" .. ngx.escape_uri(values[key])
        end
    end
    return table.concat(parts, "&")
end

local function query_url(base, values, keys, fragment)
    local parts = {}
    for _, key in ipairs(keys or {}) do
        if values[key] and values[key] ~= "" then
            parts[#parts + 1] = ngx.escape_uri(key) .. "=" .. ngx.escape_uri(values[key])
        end
    end
    return base .. (base:find("?", 1, true) and "&" or "?") ..
        table.concat(parts, "&") .. (fragment or "")
end

local function provider_by_name(name)
    for _, provider in ipairs(config().oauth_providers or {}) do
        if provider.id == name then return provider end
    end
end

local function request_json(uri, options)
    local http = require "resty.http"
    local c = config()
    options.keepalive = false
    options.ssl_verify = true
    local response, err
    for attempt = 1, 2 do
        local httpc = http.new()
        httpc:set_timeouts(c.oauth_connect_timeout, c.oauth_send_timeout, c.oauth_read_timeout)
        response, err = httpc:request_uri(uri, options)
        if response then break end
        if attempt == 1 then
            ngx.log(ngx.WARN, "authz OAuth upstream transport retry: ", tostring(err))
            ngx.sleep(0.1)
        end
    end
    if not response then return nil, "request_failed:" .. tostring(err) end
    if #(response.body or "") > c.oauth_max_body_size then return nil, "response_too_large" end
    local payload = cjson.decode(response.body or "")
    if response.status < 200 or response.status >= 300 then
        return nil, "upstream_status:" .. tostring(response.status)
    end
    if type(payload) ~= "table" then return nil, "invalid_json_response" end
    return payload
end

local function mapped_roles(provider, claims)
    local selected = {}
    local source_roles = claims[provider.role_claim]
    if type(source_roles) ~= "table" then source_roles = { source_roles } end
    for _, source in ipairs(source_roles) do
        local value = type(source) == "table" and source.name or source
        for source_name in tostring(value or ""):gmatch("[^,%s]+") do
            local role = provider.role_map[source_name:lower()]
            if role then selected[role] = true end
        end
    end
    if not next(selected) then
        for _, role in ipairs(provider.default_roles) do selected[role] = true end
    end
    local roles = {}
    for _, role in ipairs({ "admin", "staff", "user", "viewer" }) do
        if selected[role] then roles[#roles + 1] = role end
    end
    return roles
end

local function stable_username(provider, subject)
    local digest = sha256_digest(provider.id .. ":" .. subject)
    if not digest then return nil end
    return provider.id .. "_" .. base64url(digest):sub(1, 32):lower()
end

local function authorization_url(provider, state, verifier)
    if provider.kind == "wechat" then
        return query_url(provider.authorize_url, {
            appid = provider.client_id,
            redirect_uri = provider.redirect_uri,
            response_type = "code",
            scope = provider.scope,
            state = state,
        }, { "appid", "redirect_uri", "response_type", "scope", "state" }, "#wechat_redirect")
    end

    local values = {
        response_type = "code",
        client_id = provider.client_id,
        redirect_uri = provider.redirect_uri,
        scope = provider.scope,
        state = state,
        access_type = provider.access_type,
        prompt = provider.prompt,
    }
    local keys = {
        "response_type", "client_id", "redirect_uri", "scope", "state",
        "access_type", "prompt"
    }
    if provider.use_pkce then
        local digest = sha256_digest(verifier)
        if not digest then return nil, "pkce_digest_failed" end
        values.code_challenge = base64url(digest)
        values.code_challenge_method = "S256"
        keys[#keys + 1] = "code_challenge"
        keys[#keys + 1] = "code_challenge_method"
    end
    return query_url(provider.authorize_url, values, keys)
end

local function exchange_token(provider, code, verifier)
    if provider.kind == "dingtalk" then
        return request_json(provider.token_url, {
            method = "POST",
            headers = {
                ["Accept"] = "application/json",
                ["Content-Type"] = "application/json",
                ["User-Agent"] = "openresty-authz/1.0",
            },
            body = cjson.encode({
                clientId = provider.client_id,
                clientSecret = provider.client_secret,
                code = code,
                grantType = "authorization_code",
            }),
        })
    end
    if provider.kind == "wechat" then
        local uri = query_url(provider.token_url, {
            appid = provider.client_id,
            secret = provider.client_secret,
            code = code,
            grant_type = "authorization_code",
        }, { "appid", "secret", "code", "grant_type" })
        return request_json(uri, {
            method = "GET",
            headers = { ["Accept"] = "application/json", ["User-Agent"] = "openresty-authz/1.0" },
        })
    end
    local headers = {
        ["Accept"] = "application/json",
        ["Content-Type"] = "application/x-www-form-urlencoded",
        ["User-Agent"] = "openresty-authz/1.0",
    }
    local client_id = provider.client_id
    local client_secret = provider.client_secret
    if provider.token_auth_method == "client_secret_basic" then
        headers["Authorization"] = "Basic " .. ngx.encode_base64(client_id .. ":" .. client_secret)
        client_id = nil
        client_secret = nil
    end
    return request_json(provider.token_url, {
        method = "POST",
        headers = headers,
        body = form_encode({
            grant_type = "authorization_code",
            code = code,
            client_id = client_id,
            client_secret = client_secret,
            redirect_uri = provider.redirect_uri,
            code_verifier = provider.use_pkce and verifier or nil,
        }),
    })
end

local function user_claims(provider, token, access_token)
    if provider.kind == "dingtalk" then
        return request_json(provider.userinfo_url, {
            method = "GET",
            headers = {
                ["Accept"] = "application/json",
                ["x-acs-dingtalk-access-token"] = access_token,
                ["User-Agent"] = "openresty-authz/1.0",
            },
        })
    end
    if provider.kind == "wechat" then
        local openid = tostring(token.openid or "")
        if openid == "" then return nil, "invalid_token_response" end
        local uri = query_url(provider.userinfo_url, {
            access_token = access_token,
            openid = openid,
            lang = "zh_CN",
        }, { "access_token", "openid", "lang" })
        return request_json(uri, {
            method = "GET",
            headers = { ["Accept"] = "application/json", ["User-Agent"] = "openresty-authz/1.0" },
        })
    end
    return request_json(provider.userinfo_url, {
        method = "GET",
        headers = {
            ["Accept"] = "application/json",
            ["Authorization"] = "Bearer " .. access_token,
            ["User-Agent"] = "openresty-authz/1.0",
        },
    })
end

function _M.public_providers()
    local providers = {}
    local configured = {}
    for _, provider in ipairs(config().oauth_providers or {}) do
        providers[#providers + 1] = { id = provider.id, title = provider.title, enabled = true }
        configured[provider.id] = true
    end
    for _, provider in ipairs({
        { id = "nocobase", title = "NocoBase" },
        { id = "google", title = "Google" },
        { id = "dingtalk", title = "钉钉" },
        { id = "wechat", title = "微信" },
    }) do
        if not configured[provider.id] then
            providers[#providers + 1] = {
                id = provider.id,
                title = provider.title,
                enabled = false,
            }
        end
    end
    return providers
end

function _M.start(provider_name, next_url)
    local c = config()
    local provider = provider_by_name(provider_name)
    if not provider then return nil, "provider_not_found" end
    local state_dict = ngx.shared[c.oauth_state_dict]
    if not state_dict then return nil, "state_store_unavailable" end

    local state = util.random_token(24)
    local verifier = util.random_token(32)
    local stored = cjson.encode({
        provider = provider.id,
        next = next_url,
        verifier = verifier,
        redirect_uri = provider.redirect_uri,
    })
    local ok, err = state_dict:set(state, stored, c.oauth_state_ttl)
    if not ok then return nil, "state_store_failed:" .. tostring(err) end

    return authorization_url(provider, state, verifier)
end

function _M.callback(args)
    local state = tostring(args.state or "")
    if state == "" or #state > 128 then return nil, "invalid_callback" end

    local state_dict = ngx.shared[config().oauth_state_dict]
    local raw = state_dict and state_dict:get(state)
    if state_dict then state_dict:delete(state) end
    local stored = raw and cjson.decode(raw)
    if type(stored) ~= "table" then return nil, "invalid_state" end
    local provider = provider_by_name(stored.provider)
    if not provider or stored.redirect_uri ~= provider.redirect_uri then
        return nil, "provider_not_found"
    end
    if provider.issuer and (type(args.iss) ~= "string" or args.iss ~= provider.issuer) then
        return nil, "invalid_issuer"
    end
    if args.error then return nil, "authorization_denied" end
    local code = tostring(args.code or args.authCode or "")
    if code == "" or #code > 8192 then return nil, "invalid_callback" end

    local token, token_err = exchange_token(provider, code, stored.verifier)
    if not token then return nil, token_err end
    local access_token = token.access_token or token.accessToken
    if type(access_token) ~= "string" or #access_token < 8 or #access_token > 8192 then
        return nil, "invalid_token_response"
    end

    local claims, claims_err = user_claims(provider, token, access_token)
    if not claims then return nil, claims_err end
    if type(claims.data) == "table" then claims = claims.data end
    if provider.require_verified_email and claims.email_verified ~= true and
        tostring(claims.email_verified) ~= "true" then
        return nil, "email_not_verified"
    end

    local subject = tostring(claims[provider.subject_claim] or
        claims.unionid or claims.unionId or claims.openid or claims.openId or "")
    local username = claims[provider.username_claim] or claims.email or claims.preferred_username
    if not remote.normalize_username(username) then
        username = stable_username(provider, subject)
    end
    local identity, identity_err = remote.save(
        provider.id, subject, username, mapped_roles(provider, claims))
    if not identity then return nil, identity_err end
    return identity, stored.next
end

return _M
