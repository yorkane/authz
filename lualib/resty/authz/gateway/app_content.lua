-- resty.authz.gateway.app_content
-- 内置应用保留前缀域名（file-<节点>.<域> / s3-<节点>.<域>）上的**内容出口**分流。
--
-- 网关入口（location /，gateway/access.lua）在认证 + Casbin 通过后，原本对所有
-- 保留前缀域名一律 internal redirect 到入口页（files.html / s3.html）。本模块把
-- 其中「带子路径的内容请求」改道到已有的内容 location，真正吐出本机文件 / S3
-- 对象字节：
--   * files 条目 -> ^~ /_authz/files/<相对路径>（静态 alias /files/）
--   * s3   条目 -> ^~ /_authz/s3/<bucket>/<key>（s3_proxy 流式代理，逐段已拒 .. 与控制字符）
-- 根路径 "/" 与 /_authz/ 命名空间仍交回 access.lua 渲染入口页（语义不变）。
--
-- 为什么安全（务必看清，这是放行的依据）：
--   * Casbin enforce 已经在 gateway/access.lua 用 object "/<端口><原始 uri>"
--     （files=/100<uri>、s3=/101<uri>，含完整路径）过了一遍，因此
--     p, role:guest, /100/share/pub/*, GET 这类策略能对**目录**做分级；未命中
--     就是 fail-closed。本模块只在放行之后决定「渲染页面」还是「吐内容字节」。
--   * 目标内容 location 的 access 门据此标记直放（不再重复鉴权、不做 guest 降级），
--     那扇门本身仍防「绕过网关裸打 /_authz/files/」（裸打时标记未初始化，走原
--     会话 / API Key 规则）。标记是 Lua-only 变量 authz_app_content：只在
--     location / 里 set 成空串、只由本模块写非空值，不从任何请求头或 map 派生，
--     客户端伪造不了（与 authz_app_entry 同一手法；二者语义分开，不可复用）。
--   * **静态 alias 自身没有任何越界防护**：nginx 对 alias 只是把 URI 剩余部分拼到
--     alias 后面再 open()，全程不 realpath、不校验落点，符号链接被直接跟随。而
--     files root 在部署里 bind 的是宿主上真实可写的目录树（本机 /data 与
--     /home/aigc/ChatGPT），「目录里被放一个指向 /etc 的符号链接」是必须防的现实
--     威胁：本功能正是按目录给 guest 放行（p, role:guest, /100/<目录前缀>/*, GET），
--     一条规则 + 一个链接 = 任意文件读。所以直取路径的每一级都必须 realpath 后**与
--     拼接串逐字相等**（不跟随任何符号链接，只认实体目录；实体 bind 进 root 自然
--     放行），见 _M.confined_to_root（判据与 files.resolve_dir、
--     store.ensure_parents 同源；那两处保护的分别是写路径与保存区写路径）。
local cjson = require "cjson.safe"
local s3_config_store = require "resty.authz.s3_config_store"
local files = require "resty.authz.files"

local _M = {}

-- ── realpath（glibc）：符号链接逃逸判定的唯一可靠依据 ────────────────────────
-- lua-nginx-module 没有 realpath 的原生绑定，仓库既有的同类需求（db/driver.lua、
-- s3_upload.lua）都走 ffi，这里保持一致。ffi 不可用 / 声明失败 / 连 "/" 都解析
-- 不出来时 realpath 为 nil，此时 confined_to_root 一律拒绝（fail-closed），不存在
-- "校验不可用就放行"的分支。
local realpath = (function()
    local ok_ffi, ffi = pcall(require, "ffi")
    if not ok_ffi then return nil end
    -- pcall 包住 cdef：同 worker 里重复声明会抛，声明成功与否随后用探测调用判定。
    pcall(ffi.cdef, "char *realpath(const char *path, char *resolved_path);")
    local ok_new, buf = pcall(ffi.new, "char[4096]")
    if not ok_new then return nil end
    -- buf 在 worker 内复用是安全的：resolve 从调用到 ffi.string 复制之间不出现
    -- 协程 yield（realpath 是纯 syscall），并发请求不会互相覆写缓冲。
    local function resolve(path)
        local got = ffi.C.realpath(path, buf)
        if got == nil then return nil end
        return ffi.string(got)
    end
    if not resolve("/") then return nil end
    return resolve
end)()

-- worker 级「已确认落在 root 内的目录」集合。命中即跳过该级的 realpath（每级
-- 一到两次 syscall，是这条防护的全部开销；open_file_cache 只缓存 nginx 自己的
-- stat/open，不会替 Lua 侧的校验兜底）。叶子**不**缓存：链接可以事后被换成指向
-- root 外的目标，缓存叶子等于把防护变成 TTL。目录不设过期是本功能的既定取舍
-- （root 内的目录不会被运维原地换成指向外部的链接；真换了，换名后的目录第一次
-- 命中时仍会实测），上限处整体清空，避免 worker 无界增长。
local validated_dirs = {}
local validated_dirs_count = 0
local VALIDATED_DIRS_MAX = 8192

local function remember_dir(path)
    if validated_dirs[path] then return end
    validated_dirs_count = validated_dirs_count + 1
    validated_dirs[path] = true
    if validated_dirs_count > VALIDATED_DIRS_MAX then
        validated_dirs = {}
        validated_dirs_count = 1
        validated_dirs[path] = true
    end
end

--- 相对路径（不含前导 /）解析出的磁盘落点是否始终留在 root 内。
--- 返回 true；或 (false, 原因)；或 (nil, 原因) 表示 root 本身不可用（此时下游
--- 必然 404，没有可跟随的链接，调用方按 404 语义放行即可）。
--- 逐段推进（与 files.resolve_dir 同一形状）：每一级都 realpath 后要求仍在
--- root 内 —— 中间段是指向 root 外的链接时，即使叶子还不存在也先拒，不给
--- 「先埋链接再猜文件名」留窗口。realpath 失败分两种：该级不存在（交回 nginx
--- 走 404，前面各级已校验过）与存在但解析不出来（ELOOP/EACCES/悬空链接，
--- 一律 fail-closed 拒绝）。
--- **信任只以实体为准，一律不跟随符号链接**：每一级的 realpath 结果必须与刚拼接出的
--- probe 逐字相等（父级 current 是上一轮实测过的实体路径，probe==realpath(probe) 恰好
--- 等价于「segment 本身不是指向别处的符号链接」）。只要路径任一级是链接——无论指向 root
--- 内、root 外、还是一个挂载点——都在这一级拒绝。运维想放行的目录应作为**实体 bind 挂进
--- /files**：挂载落点本身是实体目录，realpath 原地不动，照常通过。
function _M.confined_to_root(root, rel)
    if realpath == nil then
        -- ffi/realpath 在 OpenResty（LuaJIT 内建 ffi）里必然可用；真取不到时
        -- 宁可整条内容出口 400，也绝不退成"不校验"。退化到 lfs 逐级 lstat会把根内
        -- 合法的相对链接（部署里存在，如 /data/tmp/** 里的同目录链接）一律误杀，
        -- 所以只保留 realpath 一条判据。
        return false, "内容出口校验不可用"
    end
    local root_real = realpath(root)
    if not root_real then return nil, "文件根目录不可用" end
    local segments = {}
    for segment in rel:gmatch("[^/]+") do segments[#segments + 1] = segment end
    local current = root_real
    for index, segment in ipairs(segments) do
        local probe = current .. "/" .. segment
        if index < #segments and validated_dirs[probe] then
            current = probe
        else
            local resolved = realpath(probe)
            if not resolved then
                if files.path_exists(probe) then
                    -- 存在但 realpath 解不出来：ELOOP / EACCES / 悬空链接。
                    return false, "无法解析真实路径: " .. segment
                end
                -- 该级不存在：后面的段无从解析，nginx 会回 404。
                return true
            end
            -- 严格实体判定：这一级的 realpath 必须与拼接串 probe 逐字相等，即 segment
            -- 不是指向别处的符号链接（current 已是上一轮实测的实体）。root 内、root 外、
            -- 指向挂载点，一视同仁：凡链接一律拒。只缓存已实测为实体的中间目录。
            if resolved ~= probe then
                return false, "路径含符号链接，内容出口只信任实体目录: " .. segment
            end
            if index < #segments then remember_dir(probe) end
            -- realpath 可能折叠了 . 与 .. 或换出链接名；统一用解析结果推进，
            -- 保证下一级 stat 的是真实路径而不是还没解析的拼接串。
            current = resolved
        end
    end
    return true
end

local function json_error(status, code, message)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.header["X-Content-Type-Options"] = "nosniff"
    -- HEAD 也照常写 body：nginx 会在输出阶段丢弃 body 字节，但保留 Content-Type
    -- 与 Content-Length。若这里对 HEAD 提前 ngx.exit(status)，nginx 会用内置默认
    -- 错误页覆盖 Content-Type（text/html），与 GET 的 JSON 口径不一致。
    ngx.say(cjson.encode({ error = { code = code, message = message } }))
    return ngx.exit(status)
end

-- 原始路径里出现这三种编码形态一律 400。只查**原始串**是刻意的：合法文件名里
-- 要真是带字面 %2f（名字里的 %2f 要写成 %252f），原始串不含裸 %2f，不会被误伤
-- （回归用例「literal percent in the name」锁住这条）。
local ENCODED_SEPARATORS = { "%2f", "%5c", "%00" }

--- 把路径逐层 unescape 成候选形态（含自身），用于「每种解码结果都要过一遍」的
--- 判定。最多两层：内容直取的磁盘路径最多经历两次解码（网关一次 + 内部重定向
--- 一次），第三层再解出来的东西不参与落点。
--- 返回数组；某一层的 unescape 抛异常时返回 nil（调用方按非法处理）。
--- 不含 % 的串直接停在第一层：普通路径不为校验付额外解码的代价。
local function decode_ladder(path)
    local out = { path }
    local current = path
    for _ = 1, 2 do
        if not current:find("%", 1, true) then break end
        local ok, decoded = pcall(ngx.unescape_uri, current)
        if not ok then return nil end
        decoded = tostring(decoded)
        if decoded == current then break end
        out[#out + 1] = decoded
        current = decoded
    end
    return out
end

--- 内容路径是否非法：对原始 request_uri（切掉 query）与其 d1/d2 解码形态，
--- 外加归一化后的 uri，都逐段比 ".." 并拒绝任何控制字符；原始串另单独挡下
--- 编码形态的分隔符（见 ENCODED_SEPARATORS）。
--- 为什么必须查到 d2（解两次）：直取路径上的解码不止一次 —— ngx.var.uri 已把
--- 原始串解了一次，ngx.exec 的内部重定向还会再解一次（实测：原始串
--- pct%2520name.txt 经两层解码命中的是名字带空格的那个文件）。只查 raw 与 d1
--- 时，两层编码的 ../ 在网关层看起来完全无害，最后是下游 nginx 的 unsafe URI
--- 防护把它掐掉的：状态码 500，而且以 worker 协程抛未捕获异常的形式失败
--- （error.log: lua entry thread aborted）。fail-closed 虽然成立，但 design.md
--- 规定这类意图必须在网关层回 400，且不许炸协程。
--- 原始串必须查：nginx 会把 /a/../b 归一化成 /b、把 %2e%2e 解码，归一化后看不出
--- 穿越意图；网关层的 Casbin object 又用的是归一化 uri，若在此放行归一化结果
--- 就等于把「谁都能借 .. 上溯」的判定推给了下游 alias / s3_proxy。
local function unsafe_path(uri)
    local raw = ngx.var.request_uri or uri
    local raw_path = raw:match("^([^?#]+)") or raw
    local lowered = raw_path:lower()
    for _, needle in ipairs(ENCODED_SEPARATORS) do
        if lowered:find(needle, 1, true) then return true end
    end
    local candidates = decode_ladder(raw_path)
    if not candidates then return true end
    candidates[#candidates + 1] = uri
    for _, candidate in ipairs(candidates) do
        if candidate:find("%c") then return true end
        for segment in candidate:gmatch("[^/]+") do
            if segment == ".." then return true end
        end
    end
    return false
end

--- 解析 s3 内容出口用的 bucket：按 ?cfg=<id|name>（可切配置）取那套配置，取值链
--- cfg.default_bucket -> 空则 cfg.share_bucket（env 回落项 default_bucket 恒为
--- ""，但 share_bucket 来自 AUTHZ_S3_SHARE_BUCKET，纯 env 部署据此即可用）。
--- 取不到配置 / 配置非法 / 两个 bucket 都空 -> 返回 (nil, status, code, message)，
--- 交调用方直接回 503 JSON；绝不因取不到 bucket 而 500，也绝不回显任何 secret。
local function resolve_bucket()
    local cfg_ref = ngx.req.get_uri_args().cfg
    if type(cfg_ref) == "table" then cfg_ref = cfg_ref[1] end
    local cfg, _, kind = s3_config_store.get(cfg_ref)
    if not cfg then
        if kind == "invalid" then
            return nil, 503, "s3_config_invalid",
                "对象存储配置非法，无法用于内容访问（请在存储配置页修正该配置）"
        end
        return nil, 503, "s3_not_configured",
            "对象存储未配置（存储配置里没有启用的配置，环境变量 AUTHZ_S3_ENDPOINT 也未设置）"
    end
    local bucket = tostring(cfg.default_bucket or "")
    if bucket == "" then bucket = tostring(cfg.share_bucket or "") end
    if bucket == "" then
        return nil, 503, "s3_bucket_unset",
            "对象存储已配置但没有可用 bucket（请在对象存储页设置默认 bucket，或设置 AUTHZ_S3_SHARE_BUCKET）"
    end
    return bucket
end

--- 保留前缀域名上带子路径的内容请求分流。
--- 返回 false 表示「交回入口页渲染」（根路径与 /_authz/ 命名空间）；
--- 其余分支一律以 ngx.exec（内容出口）或 ngx.exit（405/400/503）终止请求，不返回。
--- 分流顺序不可调换：先判根路径、再判 /_authz/ 命名空间，之后才是方法白名单、
--- 路径合法性、符号链接校验、内容出口。binding.app 全程只读不改（丢失它会撞
--- prevent_loop 的 508）。
function _M.handle(binding, config)
    local uri = ngx.var.uri or "/"
    if uri == "/" then return false end
    if uri:sub(1, 8) == "/_authz/" then return false end

    local method = ngx.req.get_method()
    if method ~= "GET" and method ~= "HEAD" then
        ngx.header["Allow"] = "GET, HEAD"
        return json_error(405, "method_not_allowed", "内容域名只支持 GET 与 HEAD")
    end

    if unsafe_path(uri) then
        return json_error(400, "bad_request", "路径非法：禁止 .. 段与控制字符")
    end

    -- 内容出口拼 target 用**原始未解码**路径（切掉 query）：nginx 对 internal
    -- redirect 的新 URI 还会再解一次码，拿 $uri（已解过一次）去拼等于让字节被
    -- 解码两次 —— 文件名里带字面 %20 / % 时会打开错误的那个文件（实测原始串
    -- pct%2520name.txt 会命中名字带空格的文件）。原始串经下游那一次解码恰好
    -- 等于客户端的意图，也与 s3_proxy.parse_path 按 $request_uri 取 key 一致。
    local raw = ngx.var.request_uri or uri
    local raw_path = raw:match("^([^?#]+)") or raw
    local raw_rest = raw_path:gsub("^/+", "")
    local target
    if binding.app == "s3" then
        local bucket, status, code, message = resolve_bucket()
        if not bucket then return json_error(status, code, message) end
        target = "/_authz/s3/" .. bucket .. "/" .. raw_rest
    else
        -- 符号链接逃逸防护（原因见文件头）。校验对象是**最终会被 open 的那条
        -- 路径**及其所有中间解码形态：nginx 归一化出的 $uri 相对部分、原始串、
        -- 原始串逐层 unescape 的结果，任意一种能跳出 root 就拒（取最紧的口径；
        -- 去重后普通路径只跑一条候选）。
        -- root 用 files.default_root（常量 "/files"）而不是 config.files_root()：
        -- alias 是写死在 server.conf.template 里的 alias /files/，那才是 nginx
        -- 真正去 open 的目录，校验对象必须与它一致（AUTHZ_FILES_ROOT 只影响控制
        -- 面浏览与写接口，改它不会改 alias，拿它校验会校验到一个不相干的目录）。
        local root = files.default_root
        local seen = {}
        local candidates = {}
        local function add(candidate)
            if candidate and candidate ~= "" and not seen[candidate] then
                seen[candidate] = true
                candidates[#candidates + 1] = candidate
            end
        end
        add(uri:gsub("^/+", ""))
        local ladder = decode_ladder(raw_rest)
        if not ladder then
            return json_error(400, "bad_request", "路径非法：无法解码")
        end
        for _, candidate in ipairs(ladder) do add(candidate) end
        for _, candidate in ipairs(candidates) do
            local confined, reason = _M.confined_to_root(root, candidate)
            if confined == false then
                return json_error(400, "bad_request", "路径非法：" .. tostring(reason))
            end
            -- confined == nil：root 本身解析不出来（挂载丢失）。此时所有候选路径
            -- 都会自然 404，不存在可被跟随的链接，交给下游即可，不误报 400。
        end
        target = "/_authz/files/" .. raw_rest
    end
    -- query 显式拼接透传（?download / ?authz_preview / ?cfg 等）：内部重定向不带
    -- 原 query，必须自己跟过去。ngx.var.args 无 query 时是 nil 而非空串。
    local args = ngx.var.args
    if args and args ~= "" then target = target .. "?" .. args end

    -- 兜住 ngx.exec 的 unsafe uri 抛异常：走到这里 target 已过 raw/d1/d2 三段式
    -- 检查，理论上不会再有 .. 或控制字符；这条自检把「异常炸掉 worker 协程」变成
    -- 一条可测的 400，代价是几次字符串扫描（无 syscall）。
    local target_path = target:match("^([^?#]+)") or target
    if target_path:find("%c") then
        return json_error(400, "bad_request", "路径非法：目标含控制字符")
    end
    for segment in target_path:gmatch("[^/]+") do
        if segment == ".." then
            return json_error(400, "bad_request", "路径非法：目标含 .. 段")
        end
    end

    ngx.var.authz_app_content = binding.app
    -- 把拼好的目标 URI（含 query）显式带给下游：ngx.req.set_uri 只改 $uri，
    -- 不改 $request_uri，而 s3_proxy.parse_path 按 $request_uri 匹配，内部重定向
    -- 后仍看到客户端原始路径，导致 s3 直取全部 404「对象路径无效」。变量只在
    -- location / 声明（见 conf/server.conf.template），普通请求不经这里是 nil。
    ngx.var.authz_app_content_uri = target
    ngx.req.set_uri(target, false)
    return ngx.exec(target)
end

return _M
