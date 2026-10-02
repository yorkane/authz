-- 字节流出口：GET/HEAD /_authz/store/<rel> → 把本机保存区里的文件流式发给客户端。
--
-- 为什么像 s3 那样用 content_by_lua，而不是像 /_authz/files/ 那样静态 alias：
-- store 区每个对象都要带「自己的」过期语义与预览/下载分支，而且必须对非法路径
-- 回 404（静态 alias 的越界防护依赖 nginx 的 $uri 归一化，这里要多挡符号链接）。
-- 认证门在 server.conf 的 access_by_lua 里（与 /_authz/files/、/_authz/s3/ 同款：
-- API Key 免登录放行 + 会话 + guest 引导到 /_authz/guest），本文件不再判身份。
--
-- 四条照抄 s3_proxy 实测契约的规矩：
--   * 支持 Range：视频拖进度条依赖 206 + Content-Range（这里是本地文件，
--     自己用 seek 实现，语义与上游返回一致）。
--   * Content-Type 由扩展名决定（resty.authz.s3.content_type）：落盘时没人记录
--     MIME，照 octet-stream 发出去浏览器只会下载，图片/视频/PDF 都不可能内联。
--   * HTML 预览（?authz_preview=1）注入 ESC 转发脚本：沙箱 iframe 里的按键不会
--     冒泡到父页面。content_by_lua 用不了 sub_filter，只能自己拼；只在
--     text/html + 正文 ≤2MB 时注入。
--   * 有意不下发 ETag / Last-Modified：nginx 的 not-modified 头过滤器会拿它们对
--     客户端的 If-None-Match / If-Modified-Since 自动改写成 304，而 content_by_lua
--     已经在流式输出 body，ngx.print 因此失败并触发「set status 500 after 304」的
--     error.log 噪音（241 实测，见 s3_proxy 同段注释）。条件请求语义上
--     200 + 完整体永远合法。
--
-- 安全红线：
--   * 路径非法 / 越界 / 含符号链接 / 不存在 → 一律 404。不能回 403：403 等于告诉
--     探测者「这一层存在但你不该进」，而保存区里有什么本身就是结构信息。
--   * 只读出口：本 location 不接受写方法（405 + Allow），写只能走 /_authz/api/store。
--   * 响应里不出现绝对路径（错误消息只有中文说明，不回显 root）。
local s3 = require "resty.authz.s3"
local store = require "resty.authz.store"

local _M = {}

local CHUNK_SIZE = 64 * 1024
local HTML_INJECT_LIMIT = 2 * 1024 * 1024
local ESC_SCRIPT = "<script>document.addEventListener('keydown',function(e);" ..
    "if(e.key==='Escape'&&window.parent!==window){" ..
    "window.parent.postMessage({type:'authz-files-esc'},'*')}});</script>"

--- 从 /_authz/store/<rel...> 取出相对路径（已百分号解码）。非法返回 nil。
--- 用 request_uri 而不是 $uri：$uri 已被 nginx 解码并归一化过（折叠斜杠、解 %2e%2e），
--- 归一化之后的字符串不再是我们签发的形状；这里要自己拿到原始字节再判定一次。
---
--- 有意**不**在读出口挡 `.upload-` 等暂存保留名：能走到这里说明已过认证门，而半截
--- 暂存文件被读到也只是它此刻的真实长度，不构成额外泄漏。保留名只在**写/删侧**禁止
--- 占用（store.normalize_target，红线 R5：避免与暂存命名冲突或被清理器误删），列表
--- 侧也隐藏它们（store.list）。
function _M.parse_path(request_uri, script_name)
    local uri = tostring(request_uri or "")
    local target = uri:match("^([^?]+)") or ""
    -- 前缀必须**逐字命中**才继续：否则会拿任意 URI 去拼相对路径。
    -- 当前模板里这个 location 没有 alias，$request_uri 的前缀恒等于 /_authz/store/；
    -- script_name 分支只为将来真的加 alias 时留口（s3_proxy.lua:46 同形态）。
    local head = "/_authz/store/"
    local matched = target:sub(1, #head) == head
    if not matched then
        local alt = tostring(script_name or "")
        if alt ~= "" and alt ~= "/" then
            if alt:sub(-1) ~= "/" then alt = alt .. "/" end
            if target:sub(1, #alt) == alt then
                head, matched = alt, true
            end
        end
    end
    if not matched then return nil end
    target = target:sub(#head + 1)
    if target == "" then return nil end
    -- URL 层先吃掉多余的前导斜杠：nginx 匹配 location 用的是归一化后的 $uri（相邻
    -- 斜杠已合并），而这里读原始 $request_uri，`/_authz/store//a.txt` 会留下一个前导
    -- '/'。吃掉它不引入穿越（'/' 不是段，'..' 仍由归一化拦），只让 `//` 与单斜杠
    -- 指向同一对象；API 入参那一侧（store.normalize）照旧拒绝绝对路径。
    local rel = (ngx.unescape_uri(target):gsub("^/+", ""))
    -- 先解码再归一化：'%2e%2e' 解码后就是 '..'，必须由归一化拦住。顺序不能反，
    -- 先归一化的话 '%2e%2e/x' 会以字面量通过（s3_proxy.lua:51 同一条理由）。
    local clean = store.normalize(rel)
    if not clean or clean == "" then return nil end
    return clean
end

local function reject(status, message)
    ngx.status = status
    -- nosniff 在错误分支也要有：错误页正文同样不该被嗅探成 HTML。
    ngx.header["X-Content-Type-Options"] = "nosniff"
    if ngx.req.get_method() == "HEAD" then
        return ngx.exit(status)
    end
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    local cjson = require "cjson.safe"
    ngx.say(cjson.encode({ error = {
        code = status == 404 and "not_found" or "request_failed",
        message = message,
    } }))
    return ngx.exit(status)
end

_M.reject = reject

--- 解析单个 Range（"bytes=a-b" / "bytes=a-" / "bytes=-n"）。
--- 多区间（含逗号）不支持：返回 nil 表示「按整个对象发 200」，与 RFC 允许的实现一致。
--- 返回 { start, finish } 或 nil（无 Range / 语法不认）。
local function parse_range(header, size)
    if type(header) ~= "string" then return nil end
    local spec = header:match("^%s*bytes%s*=%s*(.+)%s*$")
    if not spec or spec:find(",", 1, true) then return nil end
    local first, last = spec:match("^(-?%d*)%s*-%s*(-?%d*)$")
    if not first then return nil end
    local start_byte, finish_byte
    if first == "" then
        -- 后缀形式：最后 N 字节。N=0 是非法区间（RFC 9110 §14.1.2）。
        local suffix = tonumber(last)
        if not suffix or suffix <= 0 then return nil, true end
        start_byte = math.max(0, size - suffix)
        finish_byte = size - 1
    else
        start_byte = tonumber(first) or 0
        if start_byte >= size then return nil, true end
        finish_byte = (last ~= "" and tonumber(last)) or (size - 1)
        if finish_byte > size - 1 then finish_byte = size - 1 end
    end
    if start_byte < 0 or finish_byte < start_byte then return nil, true end
    return { start = start_byte, finish = finish_byte }
end

_M.parse_range = parse_range

local function send_file(abs_path, content_type, size, range, download, preview, filename)
    local handle, open_err = io.open(abs_path, "rb")
    if not handle then
        -- 到这里文件还在（刚 stat 过），打不开通常是并发删除 / 权限变化。
        return reject(404, "文件不可读: " .. tostring(open_err))
    end

    local start_byte, length, status = 0, size, 200
    if range then
        start_byte, length, status = range.start, range.finish - range.start + 1, 206
    end
    if start_byte > 0 then handle:seek("set", start_byte) end

    ngx.status = status
    ngx.header["Content-Type"] = content_type
    -- 与 /_authz/files/、/_authz/s3/ 同款安全头：被浏览的 HTML 在独立沙箱源里运行，
    -- 脚本可执行但拿不到网关会话 Cookie，访问不了 /_authz/api/*。
    ngx.header["Content-Security-Policy"] =
        "sandbox allow-scripts allow-forms allow-popups allow-modals"
    ngx.header["X-Content-Type-Options"] = "nosniff"
    ngx.header["Accept-Ranges"] = "bytes"
    -- 保存区不承诺长期保存（TTL 到点就删）：任何强缓存都会让「已删的文件仍能
    -- 从浏览器缓存里读出来」，所以固定 no-store（与 s3 的 max-age=3600 不同，那
    -- 里对象由桶自己管生命周期，网关不背这个语义）。
    ngx.header["Cache-Control"] = "no-store"
    if download then
        ngx.header["Content-Disposition"] =
            'attachment; filename="' .. ngx.escape_uri(filename) .. '"'
    elseif preview then
        ngx.header["Content-Disposition"] = "inline"
    end
    ngx.header["Content-Length"] = length
    if range then
        ngx.header["Content-Range"] =
            "bytes " .. start_byte .. "-" .. (start_byte + length - 1) .. "/" .. size
    end

    if ngx.req.get_method() == "HEAD" then
        handle:close()
        return ngx.exit(status)
    end

    -- 预览注入：整个正文进内存（≤2MB），没有 </head>（含大小写变体）就不注入。
    if preview and not range and content_type:find("text/html", 1, true)
        and size <= HTML_INJECT_LIMIT then
        local text = handle:read(size) or ""
        handle:close()
        local injected, count = text:gsub("</head>", ESC_SCRIPT .. "</head>", 1)
        if count == 0 then
            injected, count = ngx.re.gsub(text, "(?i)</head>",
                ESC_SCRIPT .. "</head>", "jo", 1)
        end
        if count > 0 then
            ngx.header["Content-Length"] = #injected
            ngx.print(injected)
            return ngx.exit(status)
        end
    end

    -- 分块发送。慢客户端在这里逐块推，不占 worker。
    local remaining = length
    while remaining > 0 do
        local chunk = handle:read(math.min(CHUNK_SIZE, remaining))
        if chunk == nil or chunk == "" then
            -- 读到文件尾之前断掉 = 并发删除或截断。头已发出，只能就地收尾
            -- （再 ngx.exit 会往 error.log 塞「after sending out head」噪音）。
            handle:close()
            return
        end
        if not ngx.print(chunk) then
            -- 多半是客户端断开（拖进度条 seek 时很常见）。
            handle:close()
            return
        end
        local ok, flush_err = ngx.flush(true)
        if not ok and tostring(flush_err):find("closed", 1, true) then
            handle:close()
            return
        end
        remaining = remaining - #chunk
    end
    handle:close()
    return ngx.exit(status)
end

--- Handle the request. Terminates with ngx.exit.
function _M.serve()
    local method = ngx.req.get_method()
    if method ~= "GET" and method ~= "HEAD" then
        ngx.header["Allow"] = "GET, HEAD"
        return reject(405, "只支持 GET 与 HEAD")
    end

    local clean = _M.parse_path(ngx.var.request_uri, ngx.var.script_name)
    if not clean then return reject(404, "文件路径无效") end

    local root = require("resty.authz").config.store_dir
    local available, err, status = store.check_root(root)
    if not available then return reject(status or 503, err or "保存区不可用") end

    local abs, resolve_err, resolve_status = store.resolve(root, clean)
    -- 一律 404（含「路径里有符号链接」这种 resolve 回 400 的情况）：这个出口面向
    -- 任意可猜测的 URL，400/403 都会把「存在但被规则挡住」这件事泄漏给探测者，
    -- 而保存区里有什么本身就是结构信息。具体原因只进日志，不进响应。
    if not abs then
        ngx.log(ngx.WARN, "authz: store byte-stream request refused: ",
            tostring(resolve_err))
        return reject(404, "文件不存在")
    end

    -- symlinkattributes 不跟随链接：链接 / 目录 / 不存在统统 404（目录不做列目录，
    -- 列表在 /_authz/api/store，那里有角色门禁）。
    local attr = store.lstat(abs)
    if not attr or attr.mode ~= "file" then return reject(404, "文件不存在") end

    local args = ngx.req.get_uri_args()
    local download = args.download == "1" or args.download == "true"
    local preview = args.authz_preview == "1" or args.authz_preview == "true"
    local filename = clean:match("([^/]+)$") or "file"
    local size = attr.size or 0

    local range_header = ngx.req.get_headers()["range"]
    if type(range_header) == "table" then range_header = range_header[1] end
    local range, unsatisfiable = parse_range(range_header, size)
    if unsatisfiable then
        ngx.header["Content-Range"] = "bytes */" .. size
        return reject(416, "范围超出文件大小")
    end

    return send_file(abs, s3.content_type(clean), size, range, download, preview, filename)
end

return _M
