local provider_config = require "resty.authz.provider_config"
local session = require "resty.authz.session"
local shared_store = require "resty.authz.shared_session_store"
local api_key = require "resty.authz.api_key"
local target = require "resty.authz.target"
local s3_scope = require "resty.authz.s3_scope"

local _M = {}

local function env_bool(name, default)
    local value = os.getenv(name)
    if value == nil or value == "" then return default end
    value = value:lower()
    return value == "1" or value == "true" or value == "yes" or value == "on"
end

-- 实例级预置 API Key（Agent 免登录入口）：以 `x-api-key` 请求头提交，
-- 允许直接调用控制面 API、访问管理页面与代理入口，省去手动登录取 Cookie。
-- 默认 admin 角色（沿用既有 role:admin 策略），可用 AUTHZ_API_KEY_ROLE 收窄；
-- 来源限定在 AUTHZ_API_KEY_ALLOWED_IPS 白名单内：逗号分隔的 IP 或 CIDR
-- （如 127.0.0.1,10.0.0.0/8），默认只允许 127.0.0.1；放开公网来源前必须三思。
local function configure_api_key(c)
    local token = tostring(os.getenv("AUTHZ_API_KEY") or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local role = tostring(os.getenv("AUTHZ_API_KEY_ROLE") or "admin"):lower()
    if token == "" then
        c.env_api_key = nil
        api_key.configure_env({})
        return
    end
    if not api_key.valid_role(role) then
        error("AUTHZ_API_KEY_ROLE must be one of admin, staff, user, guest, api")
    end
    if #token < 32 or #token > 256 or token:find("[%c%s]") then
        error("AUTHZ_API_KEY must be 32-256 characters without spaces or control characters")
    end
    -- 旧开关已被白名单取代：静默忽略会让旧部署悄悄改变来源边界，直接报错逼迁移。
    local legacy = os.getenv("AUTHZ_API_KEY_LOOPBACK")
    if legacy ~= nil and legacy ~= "" then
        error("AUTHZ_API_KEY_LOOPBACK was replaced by AUTHZ_API_KEY_ALLOWED_IPS " ..
            "(default 127.0.0.1; use 127.0.0.0/8 to keep the old loopback-wide scope)")
    end
    local allowed_text = tostring(os.getenv("AUTHZ_API_KEY_ALLOWED_IPS") or "127.0.0.1")
    local allowed_ips, list_err = target.normalize_cidr_list(allowed_text)
    if not allowed_ips then
        error("AUTHZ_API_KEY_ALLOWED_IPS " .. tostring(list_err))
    end
    c.env_api_key = { role = role, allowed_ips = allowed_text }
    api_key.configure_env({
        token = token, role = role,
        allowed_ips = allowed_ips, allowed_text = allowed_text,
    })
    ngx.log(ngx.NOTICE, "authz: env API key enabled (role=", role,
        ", allowed from ", allowed_text, ")")
end

local function configure_session(c)
    session.secure = env_bool("AUTHZ_COOKIE_SECURE", false)
    session.configure_cookie_domain(os.getenv("AUTHZ_COOKIE_DOMAIN"), os.getenv("AUTHZ_HOST_URL"))
    shared_store.shared_enabled = false
    shared_store.fallback_enabled = env_bool("AUTHZ_SESSION_SHARED_FALLBACK", true)
    -- 重放定时器间隔：钳到 1s..10min（worker 里读不到 env，必须由 master 写进
    -- shared_session_store，sync 再从 store 取）。
    shared_store.retry_interval_ms = math.min(600000, math.max(1000,
        tonumber(os.getenv("AUTHZ_SESSION_RETRY_INTERVAL_MS")) or 15000))
    shared_store.session_ttl = session.ttl
    -- 降级宽限期（秒），默认 4 小时；钳到 60s..7天。
    shared_store.fallback_grace = math.min(604800, math.max(60,
        tonumber(os.getenv("AUTHZ_SESSION_FALLBACK_GRACE")) or 14400))
    shared_store.mode = "read-only"
    shared_store.username = ""
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
        shared_store.host = host
        shared_store.port = port
        shared_store.username = tostring(os.getenv("AUTHZ_SESSION_REDIS_USERNAME") or "")
        shared_store.password = tostring(os.getenv("AUTHZ_SESSION_REDIS_PASSWORD") or "")
        shared_store.db = tonumber(os.getenv("AUTHZ_SESSION_REDIS_DB")) or 0
        shared_store.prefix = tostring(os.getenv("AUTHZ_SESSION_REDIS_PREFIX") or "authz")
        shared_store.mode = tostring(os.getenv("AUTHZ_SESSION_REDIS_MODE") or "read-only"):lower()
        if shared_store.mode ~= "read-write" and shared_store.mode ~= "read-only" then
            error("AUTHZ_SESSION_REDIS_MODE must be read-write or read-only")
        end
        if shared_store.username:find("[%c%s]") or #shared_store.username > 128 then
            error("AUTHZ_SESSION_REDIS_USERNAME is invalid")
        end
        if shared_store.prefix == "" or #shared_store.prefix > 128 or
            not shared_store.prefix:match("^[A-Za-z0-9_.:-]+$") then
            error("AUTHZ_SESSION_REDIS_PREFIX is invalid")
        end
       if shared_store.db < 0 or shared_store.db > 15 or shared_store.db % 1 ~= 0 then
           error("AUTHZ_SESSION_REDIS_DB must be an integer from 0 to 15")
       end
        -- 共享 Redis 常常是多套服务公用的存储：会话记录必须携带 HMAC 签名，
        -- 未签名或签名不符的记录一律失效，防止拥有 Redis 写权限的其他方伪造会话。
        shared_store.signing_key = tostring(os.getenv("AUTHZ_SESSION_SIGNING_KEY") or "")
        if #shared_store.signing_key < 32 then
            error("AUTHZ_SESSION_SHARED requires AUTHZ_SESSION_SIGNING_KEY of at least 32 characters")
        end
       shared_store.connect_timeout = tonumber(os.getenv("AUTHZ_SESSION_REDIS_CONNECT_TIMEOUT_MS")) or 2000
        shared_store.read_timeout = tonumber(os.getenv("AUTHZ_SESSION_REDIS_READ_TIMEOUT_MS")) or 2000
        shared_store.shared_enabled = true
        c.session_shared_mode = shared_store.mode
        ngx.log(ngx.NOTICE, "authz: shared session mode enabled (" .. shared_store.mode ..
            ", redis://" .. host .. ":" .. port
            .. ", fallback=" .. tostring(shared_store.fallback_enabled) .. ")")
    end
    local ttl = tonumber(os.getenv("AUTHZ_SESSION_TTL"))
    if ttl then
        session.ttl = ttl
        shared_store.session_ttl = ttl
    end
    c.session_shared_fallback = shared_store.fallback_enabled
end

-- ── 运行期 env 取值：只在 master 阶段读一次并记忆 ───────────────────────────
-- 【为什么必须记忆（实测结论，别改回 os.getenv 直读）】nginx 会清空 worker 的环境
-- 块，只有 nginx.conf 里用顶层 `env NAME;` 显式声明过的变量在 worker / timer 协程
-- 里还能读到。本仓库模板没有 env 指令，所以 init_worker / ngx.timer 里
-- os.getenv("AUTHZ_*") 一律返回 nil（实测：master 里 /tmp/w/store，worker 里 nil）。
-- 于是 init_by_lua（master）里 config_loader.load() 读到的才是真值，worker 里再
-- os.getenv 会静默退回默认值 —— 清理器与 API 层就会指向两个不同目录。
-- 对策：所有跨阶段共享的运行期路径都经 memo_env 在**首次调用**（发生在 master 的
-- load() 里）取真值并记住；worker 继承 fork 时的模块状态，后续调用拿到同一份。
-- 需要按新 env 重算（单测/脚本里改了环境变量）就调 _M.reset_env_cache()。
local env_cache = {}

local function memo_env(name, default, normalize)
    local hit = env_cache[name]
    if hit ~= nil then return hit end
    local raw = os.getenv(name)
    -- 必须先各自判 nil / 空串再取默认值。**不能**写成
    -- `raw == nil or raw == "" and default or raw`：Lua 里 and 优先于 or，那行会被
    -- 解析成 `(raw == nil) or ((raw == "") and default) or raw`，于是变量未设置时
    -- 返回**布尔 true**（实测 store_dir() 得到字符串 "true"，等于凭空造出一个相对
    -- 目录）。nil 与 "" 都按「未设置」处理。
    if raw == nil or raw == "" then raw = default end
    local value = normalize(raw)
    env_cache[name] = value
    return value
end

--- 丢弃记忆值（只给脚本/单测用；线上 env 不会在运行期变化）
function _M.reset_env_cache()
    env_cache = {}
    s3_env_cache = nil
end

local function norm_path(value)
    local dir = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("/+$", "")
    return dir
end

--- 数据库路径：maintenance 的 timer 协程必须与 master 用同一个库，否则会去开一个
--- 凭空的 sqlite 文件（表现为「表不存在」而不是「配置没生效」）。
function _M.db_path()
    local dir = memo_env("AUTHZ_DB_PATH", "/data/authz/authz.db", norm_path)
    if dir == "" then return "/data/authz/authz.db" end
    return dir
end

--- 人浏览用的文件根目录（与 server.conf 的 /_authz/files/ alias 一致，默认只读）。
function _M.files_root()
    local dir = memo_env("AUTHZ_FILES_ROOT", "/files", norm_path)
    if dir == "" then return "/files" end
    return dir
end

--- S3 上传暂存目录（s3_upload 写 .s3-upload-* 的地方）。
function _M.s3_tmp_dir()
    local dir = memo_env("AUTHZ_S3_TMP_DIR", "/data/s3tmp", norm_path)
    if dir == "" then return "/data/s3tmp" end
    return dir
end

--- 本机「临时保存区」根目录（agent 文件保存 API 的落盘处，必须可写）。
--- 与 files_root 是两回事：store 由网关自己管生命周期（upload_records
--- kind='local' + 每小时清理），不承诺长期保存；files_root 给人浏览、默认只读。
function _M.store_dir()
    local dir = memo_env("AUTHZ_STORE_DIR", "/data/store", norm_path)
    if dir == "" then return "/data/store" end
    return dir
end

--- 默认过期小时数：0 = 不过期；钳到 0..8760（一年），挡住误填超大值把 expires_at
--- 撑成荒谬时间戳（与 s3_config_store.align_expiry 用同一上限）。
function _M.store_expiry_hours()
    return memo_env("AUTHZ_STORE_DEFAULT_EXPIRY_HOURS", 24, function(value)
        return math.max(0, math.min(8760, tonumber(value) or 24))
    end)
end

-- ── S3 配置构造（env 与 s3_configs 表行共用）────────────────────────────────
--- 桶名合法性：与 s3.lua 的 normalize_bucket 同款判据（长度用 #name 显式判 +
--- 字符集模式 + 首尾字符单独判）。
--- 【修复】此前这里是 `share_bucket:match("^[a-z0-9][a-z0-9.-]{1,61}$")`：
--- Lua 模式不支持 {n,m} 区间量词，"{1,61}" 被当作字面量去匹配，于是**任何**合法
--- 非空桶名都判成非法，只要设了 AUTHZ_S3_SHARE_BUCKET 容器就启动失败。
local function valid_bucket_name(name)
    if #name < 3 or #name > 63 then return false end
    return name:match("^[a-z0-9][a-z0-9%.%-]*[a-z0-9]$") ~= nil
end

_M.valid_bucket_name = valid_bucket_name

--- 读取环境变量里的 S3 取值（只取值、不校验）。env 是**回落默认配置**：
--- s3_configs 表里有启用行时运行时优先用表里的配置，表空时才用这里的值。
--- 之所以单独导出：s3_config_store 给表行派生 cfg 时也要复用同一份超时/TTL
--- 的 env 取值（超时是实例级调优，不该按配置行各来一套），校验与钳制统一在
--- _M.build_s3 里做，这里不复制。
---
--- 【记忆化】同样必须走 memo_env / master 首读：表行派生发生在 worker 里，
--- 直读 os.getenv 会把超时/TTL/LAN IP 静默退成默认值（与 env 那套不一致）。
--- 首次调用发生在 master 的 load() 里，因此缓存住的是真值。返回**浅拷贝**，
--- 让调用方（load 会补探测到的 lan_ip）可以放心改字段而不污染缓存。
local s3_env_cache = nil

function _M.s3_env_fields()
    if not s3_env_cache then
        s3_env_cache = _M.read_s3_env()
    end
    local out = {}
    for key, value in pairs(s3_env_cache) do out[key] = value end
    return out
end

function _M.read_s3_env()
    return {
        endpoint = tostring(os.getenv("AUTHZ_S3_ENDPOINT") or ""):gsub("/+$", ""),
        region = tostring(os.getenv("AUTHZ_S3_REGION") or "us-east-1"),
        access_key_id = tostring(os.getenv("AUTHZ_S3_ACCESS_KEY_ID") or ""),
        secret_access_key = tostring(os.getenv("AUTHZ_S3_SECRET_ACCESS_KEY") or ""),
        allow_http = env_bool("AUTHZ_S3_ALLOW_HTTP", false),
        writable_paths = tostring(os.getenv("AUTHZ_S3_WRITABLE_PATHS") or ""),
        share_root = tostring(os.getenv("AUTHZ_S3_SHARE_ROOT") or "/share/"),
        share_bucket = tostring(os.getenv("AUTHZ_S3_SHARE_BUCKET") or ""),
        read_timeout_ms = tonumber(os.getenv("AUTHZ_S3_READ_TIMEOUT_MS")),
        connect_timeout_ms = tonumber(os.getenv("AUTHZ_S3_CONNECT_TIMEOUT_MS")),
        send_timeout_ms = tonumber(os.getenv("AUTHZ_S3_SEND_TIMEOUT_MS")),
        keepalive_ms = tonumber(os.getenv("AUTHZ_S3_KEEPALIVE_MS")),
        -- 显式指定 LAN IP（留空则由调用方探测）：默认只写范围 share/<LAN IP> 时靠它。
        lan_ip = tostring(os.getenv("AUTHZ_HOST_LAN_IP") or "")
            :gsub("^%s+", ""):gsub("%s+$", ""),
    }
end

--- 把「已取值的明文 S3 字段」构造成运行时 cfg。校验规则、默认值、超时钳制、
--- share_prefix 计算只此一份，env 与表行两条路径共用（禁止复制两份后各自漂移）。
--- fields 的键见 _M.s3_env_fields（外加 default_bucket）；opts:
---   source="env"|"row"  仅用于错误信息措辞
---   strict=true         非法即 error()（env 路径保持启动期 fail-fast 原语义）
---   strict=false        非法返回 nil, msg（运行期可失败：一行写坏不能拖垮网关）
---   prefix=string       错误信息前缀（表行用它带上配置名，便于定位是哪一行）
--- 返回 (cfg, endpoint_display)；失败时 (nil, msg)。cfg 的字段形状是既有契约
--- （s3.lua / s3_upload.lua / router.lua 都在读），不要增删改名。
function _M.build_s3(fields, opts)
    opts = opts or {}
    fields = fields or {}
    local prefix = opts.prefix or ""
    local function fail(message)
        if opts.strict then error(prefix .. message) end
        return nil, prefix .. message
    end
    -- 错误信息里的名字：env 路径沿用真实环境变量名（运维只认这个）；行路径的
    -- 字段来自页面表单，同样借用这个名字，配合 prefix 里的配置名足够定位。
    local function label(name)
        return "AUTHZ_S3_" .. name
    end
    -- 【上面 label() 只管环境变量名】但「明文 http 需要显式允许」这一条例外：
    -- 表行的开关是表单里的 allow_http 勾选框，环境变量对行完全无效。
    -- env 措辞保持不变（回归钉的是整句），行措辞指向真实开关，否则运维照提示
    -- 去改 .env 会白折腾一次（实测同一 endpoint 带 allow_http=true 立刻 201）。
    local function plaintext_msg()
        if opts.source == "row" then
            return "endpoint uses plaintext http; enable the allow_http option of this "
                .. "storage configuration explicitly after confirming the network is trusted"
        end
        return label("ENDPOINT") .. " uses plaintext http; set " .. label("ALLOW_HTTP") ..
            "=true explicitly after confirming the network is trusted"
    end

    local s3_endpoint = tostring(fields.endpoint or ""):gsub("/+$", "")
    local scheme, authority = s3_endpoint:match("^(https?)://([^/]+)$")
    if not scheme or authority == "" or authority:find("[?#]") then
        return fail(label("ENDPOINT") .. " must be http(s)://<host>[:<port>] without a path")
    end
    local host, port_text = authority:match("^([^:]+):(%d+)$")
    if not host then host, port_text = authority, nil end
    local port = port_text and tonumber(port_text) or (scheme == "https" and 443 or 80)
    if not port or port < 1 or port > 65535 then
        return fail(label("ENDPOINT") .. " port must be 1-65535")
    end
    if scheme ~= "https" and fields.allow_http ~= true then
        return fail(plaintext_msg())
    end
    local region = tostring(fields.region or "us-east-1")
    local akid = tostring(fields.access_key_id or "")
    local secret = tostring(fields.secret_access_key or "")
    if region == "" or region:find("[%c%s]") or #region > 64 then
        return fail(label("REGION") .. " is invalid")
    end
    if akid == "" or secret == "" or akid:find("[%c%s]") or secret:find("[%c%s]") then
        return fail(label("ENDPOINT") .. " requires " .. label("ACCESS_KEY_ID") .. " / " ..
            label("SECRET_ACCESS_KEY"))
    end
    -- 挂载根目录名：默认 share；归一化去首尾空白与 /，禁止 .. 与控制字符。
    local share_root = tostring(fields.share_root or "/share/")
        :gsub("^%s+", ""):gsub("%s+$", "")
        :gsub("^/+", ""):gsub("/+$", "")
    if share_root == "" then
        return fail(label("SHARE_ROOT") .. " must not be empty")
    end
    -- 【修复】字符集误写成 "[%%c\\?#]"：Lua 字符串里 %% 是**两个字面 %**（没有
    -- string.format 的转义语义），于是集合实际是 {% , c , \ , ? , #} —— 任何含字母
    -- c 或 % 的路径都被判非法，例如 AUTHZ_S3_WRITABLE_PATHS="code/docs" 会让容器
    -- 起不来。文档（doc/s3-integration.md）约定的非法集是「控制字符 / ? / # / \ / ..」，
    -- 正确写法是单 % 的 "[%c\\?#]"。
    if share_root:find("..", 1, true) or share_root:find("[%c\\?#]") then
        return fail(label("SHARE_ROOT") .. " is illegal (no '..'/control/?/#): " .. share_root)
    end
    -- 可写范围（写操作白名单）：留空 = 默认挂载根条目 share/<本机 LAN IP>；
    -- "/" 或 "*" = 全部可写；逗号分隔多个范围。
    local s3_spec = tostring(fields.writable_paths or "")
    -- 可选地把默认 share/<IP> 前缀绑定到指定桶；空 = 不绑定（任意桶内该前缀可写）。
    local share_bucket = tostring(fields.share_bucket or "")
        :gsub("^%s+", ""):gsub("%s+$", "")
    if share_bucket ~= "" and not valid_bucket_name(share_bucket) then
        return fail(label("SHARE_BUCKET") .. " is an invalid bucket name: " .. share_bucket)
    end
    -- 预选上传桶（页面「上传到这里」的默认桶）；空 = 不预选。与 share_bucket 同判据。
    local default_bucket = tostring(fields.default_bucket or "")
        :gsub("^%s+", ""):gsub("%s+$", "")
    if default_bucket ~= "" and not valid_bucket_name(default_bucket) then
        return fail("default_bucket is an invalid bucket name: " .. default_bucket)
    end
    -- 条目校验（与 endpoint 等现有风格一致）：出现 ".."、控制字符、反斜杠、?、#
    -- 一律判非法（env 路径 = 启动失败；行路径 = 该配置整体不可用），不静默降级。
    for raw in (s3_spec .. ","):gmatch("([^,]*)") do
        local e = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if e ~= "" and e ~= "/" and e ~= "*"
            and (e:find("..", 1, true) or e:find("[%c\\?#]")) then
            return fail(label("WRITABLE_PATHS") .. " entry is illegal (no '..'/control/?/#): " ..
                tostring(raw))
        end
    end
    -- LAN IP 由调用方决定怎么拿（env 路径 = 显式值或本 worker 探测；表行路径见
    -- s3_config_store），这里只做纯计算，不探测、不 require 上层模块。
    local lan_ip = tostring(fields.lan_ip or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local writable, writable_roots, writable_all =
        s3_scope.parse(s3_spec, lan_ip ~= "" and lan_ip or nil, share_root, share_bucket)
    -- 默认场景的完整可写前缀（回显 + auto-mkdir 放行判定用）；未探测到 IP 时 nil。
    local share_prefix = lan_ip ~= "" and (share_root .. "/" .. lan_ip) or nil
    return {
        enabled = true,
        host = host,
        port = port,
        tls = scheme == "https",
        region = region,
        access_key_id = akid,
        secret_access_key = secret,
        -- 可写范围（s3_scope 契约）：内部结构 / 全可写标志 / 回显用归一化条目。
        writable = writable,
        writable_all = writable_all,
        writable_roots = writable_roots,
        -- 默认场景：挂载根条目 share/<IP> 的完整前缀（auto-mkdir 放行判定），
        -- 显式 AUTHZ_S3_WRITABLE_PATHS 或探测失败时为 nil；share_bucket 可为 ""。
        share_prefix = share_prefix,
        share_bucket = share_bucket,
        default_bucket = default_bucket,
        -- 给签名器（vendored 上游读 config.timeout）与自设超时两侧共用的值。
        timeout = math.max(200, tonumber(fields.read_timeout_ms) or 30000),
        connect_timeout = math.max(50, tonumber(fields.connect_timeout_ms) or 2000),
        send_timeout = math.max(200, tonumber(fields.send_timeout_ms) or 30000),
        read_timeout = math.max(200, tonumber(fields.read_timeout_ms) or 30000),
        keepalive_idle = math.max(1000, tonumber(fields.keepalive_ms) or 30000),
    }, scheme .. "://" .. authority
end

function _M.load()
    local c = {}
    -- 下面几个路径都走 _M.* 的记忆化取值：worker 里 os.getenv 读不到（见 memo_env
    -- 注释），必须保证 load() 之后各阶段拿到的是同一个值。
    c.db_path = _M.db_path()
    c.admin_password = os.getenv("AUTHZ_ADMIN_PASSWORD") or "admin123"
    c.port_min = math.max(2000, tonumber(os.getenv("AUTHZ_PORT_MIN")) or 2000)
    c.port_max = math.min(65535, tonumber(os.getenv("AUTHZ_PORT_MAX")) or 20000)
    if c.port_max < c.port_min then c.port_max = c.port_min end
    c.http_port = tonumber(os.getenv("AUTHZ_HTTP_PORT")) or 6080
    c.https_port = tonumber(os.getenv("AUTHZ_HTTPS_PORT")) or 6443
    -- ── 内置应用保留前缀域名入口（files / s3）─────────────────────────────
    -- <前缀>-<节点>.<任意域>（或裸 <前缀>.<任意域>）不查数据库，直接映射到
    -- 本机管理页面（虚拟绑定）。绑定值与端口可在策略里单独授权（对象 /<端口>/*，
    -- 见 api/validation.lua 对 app_ports 的放行），因此这两个端口**不允许**再被
    -- 域名绑定占用（api/services/applications.lua 拒绝）。默认 file→100、s3→101，
    -- 都在 port_min(>=2000) 之下，不会被数字前缀路由或服务发现扫到。
    -- 前缀非法（不符合域名前缀字符集）或端口与 http/https 入口冲突 → 该项禁用
    -- （只警告不 error，避免一个拼写错误拖垮网关）；总开关 AUTHZ_APP_DOMAINS=0
    -- 时三个表都空，file-x 之类域名回退到 404。
    c.app_entries = {}
    c.app_ports = {}
    c.app_prefixes = {}
    if env_bool("AUTHZ_APP_DOMAINS", true) then
        for _, def in ipairs({
            { name = "files", page = "files.html", title = "文件浏览",
              prefix = "file", port = 100 },
            { name = "s3", page = "s3.html", title = "对象存储",
              prefix = "s3", port = 101 },
        }) do
            local prefix = tostring(os.getenv(def.name == "files"
                and "AUTHZ_APP_PREFIX_FILES" or "AUTHZ_APP_PREFIX_S3") or "")
                :lower():gsub("^%s+", ""):gsub("%s+$", "")
            if prefix == "" then prefix = def.prefix end
            local port_raw = tostring(os.getenv(def.name == "files"
                and "AUTHZ_APP_PORT_FILES" or "AUTHZ_APP_PORT_S3") or "")
            local port = def.port
            local reason
            -- Lua 原生 match 没有 ? 量词（(..)? 里的 ? 按字面量匹配，与
            -- valid_bucket_name 注释里 {n,m} 的坑同款）；长度 1 与 >=2 分开判。
            local prefix_ok = prefix:match("^[a-z0-9]$") ~= nil
                or prefix:match("^[a-z0-9][a-z0-9%-]*[a-z0-9]$") ~= nil
            if not prefix_ok then
                reason = "invalid prefix (use [a-z0-9-], no leading/trailing dash)"
            elseif port_raw ~= "" then
                port = tonumber(port_raw)
                if not port or port ~= math.floor(port) or port < 1 or port > 65535 then
                    reason = "port must be an integer 1-65535"
                end
            end
            if not reason and (port == c.http_port or port == c.https_port) then
                reason = "port conflicts with the gateway listen port"
            elseif c.app_ports[port] then
                reason = "port already taken by another app entry"
            elseif c.app_prefixes[prefix] then
                reason = "prefix already taken by another app entry"
            end
            if reason then
                ngx.log(ngx.WARN, "authz: app entry ", def.name, " disabled: ", reason)
            else
                c.app_entries[def.name] = {
                    name = def.name, prefix = prefix, port = port,
                    page = def.page, title = def.title,
                }
                c.app_ports[port] = true
                c.app_prefixes[prefix] = def.name
            end
        end
    end
    c.discovery_ttl = math.max(5, tonumber(os.getenv("AUTHZ_DISCOVERY_TTL")) or 30)
    c.discovery_connect_timeout = math.max(20,
        tonumber(os.getenv("AUTHZ_DISCOVERY_CONNECT_TIMEOUT_MS")) or 100)
    c.discovery_read_timeout = math.max(20,
        tonumber(os.getenv("AUTHZ_DISCOVERY_READ_TIMEOUT_MS")) or 200)
    c.discovery_ports = tostring(os.getenv("AUTHZ_DISCOVERY_PORTS") or "")
    c.db_cache_ttl = math.max(1, tonumber(os.getenv("AUTHZ_DB_CACHE_TTL")) or 30)
    -- 响应改写正文缓冲的单 worker 预留预算（MB）：默认 64MB ≈ 64 个并发正文改写。
    c.rewrite_buffer_mb = math.min(512, math.max(8,
        tonumber(os.getenv("AUTHZ_REWRITE_BUFFER_MB")) or 64))
    c.db_cache_lru_size = math.max(50, tonumber(os.getenv("AUTHZ_DB_CACHE_LRU_SIZE")) or 500)
    c.cache_dict = "authz_cache"
    c.login_limit_dict = "authz_login_limit"
    -- 文件浏览器根目录；默认容器内 /files（部署时把宿主目录挂载到 /files）。
    -- 必须与 server.conf 里 /_authz/files/ 的 alias 保持一致。
    c.files_root = _M.files_root()
    -- S3 上传暂存目录（maintenance 扫残留时要与上传写入处一致；这里读一次是为了
    -- 在 master 阶段把真值记忆住 —— 没人调用的话首读会落在 worker 里，记忆成默认值）。
    c.s3_tmp_dir = _M.s3_tmp_dir()
    -- Nginx 配置编辑页（/_authz/api/nginx-conf*）使用的运行时路径。
    -- conf 目录存放渲染后的 nginx.conf/server.conf 与三个用户 include；
    -- template 目录是启动时 include 的来源（compose 里只读挂载）。
    c.nginx_conf_dir = os.getenv("AUTHZ_NGINX_CONF_DIR") or "/usr/local/openresty/nginx/conf"
    c.nginx_prefix = os.getenv("AUTHZ_NGINX_PREFIX") or "/usr/local/openresty/nginx"
    c.nginx_bin = os.getenv("AUTHZ_NGINX_BIN") or "/usr/local/openresty/bin/openresty"
    c.nginx_template_dir = os.getenv("OPENRESTY_TEMPLATE_DIR") or ""
    -- 对象存储（S3 兼容）浏览器：私有 endpoint + SigV4 静态凭证。
    -- 未设 AUTHZ_S3_ENDPOINT 时功能整体关闭（菜单可见但页面显示未配置卡片），
    -- 因此 SECRET 缺失只警告不报错——和 NocoBase 的渐进启用一致。
    -- 字段校验与派生全在 _M.build_s3（与 s3_configs 表行共用同一个构造函数）；
    -- env 这一路继续 fail-fast：配置写坏就让容器起不来，不带病上线。
    -- env 现在只是**回落默认配置**：s3_configs 表里有启用行时运行时优先取表里的
    -- 配置（见 s3_config_store），而 c.s3 / c.s3_endpoint_display /
    -- c.s3_region_display 的对外形状保持不变（消费方与回归断言依赖它）。
    local s3_fields = _M.s3_env_fields()
    c.s3 = nil
    if s3_fields.endpoint ~= "" then
        -- LAN IP 探测只在 env 这一路做（保持原语义：探测走 UDP connect 选路由源地址，
        -- 不发包）；表行的探测在 s3_config_store 里按需做。
        if s3_fields.lan_ip == "" then
            s3_fields.lan_ip = s3_scope.detect_lan_ip() or ""
        end
        if s3_fields.writable_paths == "" and s3_fields.lan_ip == "" then
            ngx.log(ngx.WARN, "authz: cannot detect LAN IP; default share/<LAN IP> " ..
                "writable prefix unavailable, S3 browser is read-only")
        end
        local cfg, display = _M.build_s3(s3_fields, { source = "env", strict = true })
        c.s3 = cfg
        -- endpoint 会回显给管理页面（帮助排障），凭证只在签名器内部使用。
        c.s3_endpoint_display = display
        c.s3_region_display = cfg.region
        ngx.log(ngx.NOTICE, "authz: S3 browser enabled (", c.s3_endpoint_display,
            ", region ", cfg.region, ")")
    end
    -- ── 本机「临时保存区」（agent 文件保存 API 的落盘根目录）──────────────────
    -- 与 AUTHZ_FILES_ROOT（/files，给人浏览、默认只读）是两回事：
    --   * store_dir 是给机器用的写入区，必须可写，由网关自己管生命周期
    --     （upload_records kind='local' + maintenance 每小时按 expires_at 删）；
    --   * 它**不承诺长期保存**——文件随时可能被清理器或运维按 TTL 收回，需要长期
    --     保存的内容应走对象存储（s3_configs）。
    -- 部署提醒：容器要在 entrypoint 里 mkdir -p 这个目录（见交付报告），否则会
    -- 以「目录不可写」失败。
    c.store_dir = _M.store_dir()
    c.store_default_expiry_hours = _M.store_expiry_hours()
    c.login_attempts = math.max(1, tonumber(os.getenv("AUTHZ_LOGIN_ATTEMPTS")) or 5)
    c.login_window = math.max(60, tonumber(os.getenv("AUTHZ_LOGIN_WINDOW")) or 1800)
    c.login_fail_delay_ms = math.min(10000, math.max(0,
        tonumber(os.getenv("AUTHZ_LOGIN_FAIL_DELAY_MS")) or 1000))
    configure_session(c)
    configure_api_key(c)

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
