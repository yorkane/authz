-- Byte-stream proxy for GET /_authz/s3/<bucket>/<key>.
--
-- nginx 里这个 location 只做认证（access_by_lua 与 /_authz/files/ 同款），字节流全部
-- 走这里：流式 GetObject → ngx.print 分块透传。为什么不像 files 那样直接用静态
-- alias：对象在远端服务上，nginx 没有文件可读。
--
-- 三条必须自己扛的规矩（来自实测契约 /data/tmp/s3-probe/contract.md）：
--   * Range 原样转发：该服务返回 206 + Content-Range，视频拖进度条依赖它
--   * Content-Type 由扩展名决定：存储端不持久化 PUT 时给类型（全是 octet-stream），
--     照抄上游头的话浏览器只会下载，图片/视频/PDF 都不可能内联
--   * HTML 预览要注入 ESC 转发脚本：沙箱 iframe 里的按键不会冒泡到父页面。
--     content_by_lua 用不了 sub_filter，只能自己拼；只在 text/html +
--     ?authz_preview=1 且正文 ≤2MB 时注入，超了就退化成用预览头部的关闭按钮退出
local s3 = require "resty.authz.s3"

local _M = {}

local CHUNK_SIZE = 64 * 1024
local KEEPALIVE_POOL = 30
local HTML_INJECT_LIMIT = 2 * 1024 * 1024
local ESC_SCRIPT = "<script>document.addEventListener('keydown',function(e);" ..
    "if(e.key==='Escape'&&window.parent!==window){" ..
    "window.parent.postMessage({type:'authz-files-esc'},'*')}});</script>"

--- 从 /_authz/s3/<bucket>/<key...> 拆出 bucket 与 key。
function _M.parse_path(request_uri, script_name)
    -- 先剥掉 query：否则 ?download=1 会被当成 key 的一部分签进请求里（服务端 404）。
    local target = tostring(request_uri or ""):match("^([^?]+)") or ""
    target = target:match("^/_authz/s3/(.+)$") or (script_name
        and target:match("^" .. ngx.escape_uri(script_name) .. "/(.+)$"))
    if not target then return nil, nil end
    local raw_bucket, raw_key = target:match("^([^/]+)/(.+)$")
    if not raw_bucket then return nil, nil end
    -- key 里的 %xx 要先解出来（签名要用明文 key），但解完必须再挡一次穿越：
    -- 服务端其实会把 %2e%2e 当字面量，先挡是为了日志与签名串不出现歧义。
    local bucket = s3.normalize_bucket(ngx.unescape_uri(raw_bucket))
    local key = ngx.unescape_uri(raw_key)
    if not bucket or key == "" or key:find("[%c]") then return nil, nil end
    for segment in key:gmatch("[^/]+") do
        if segment == ".." then return nil, nil end
    end
    return bucket, key
end

local function reject(status, message)
    ngx.status = status
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

--- Handle the request. Terminates with ngx.exit.
function _M.serve()
    local cfg = require("resty.authz").config.s3
    if not cfg then return reject(423, "对象存储未配置") end

    local bucket, key = _M.parse_path(ngx.var.request_uri, ngx.var.script_name)
    if not bucket then return reject(404, "对象路径无效") end

    local method = ngx.req.get_method()
    if method ~= "GET" and method ~= "HEAD" then
        ngx.header["Allow"] = "GET, HEAD"
        return reject(405, "只支持 GET 与 HEAD")
    end

    local args = ngx.req.get_uri_args()
    local download = args.download == "1" or args.download == "true"
    local preview = args.authz_preview == "1" or args.authz_preview == "true"

    local range = ngx.req.get_headers()["range"]
    if type(range) == "table" then range = range[1] end

    local httpc, res, err = s3.open_get(cfg, bucket, key, range)
    if not httpc then return reject(502, "连接对象存储失败: " .. tostring(err)) end

    -- 连接要么把 body 读空后回池，要么直接 close；带着残留字节回池会让下一个
    -- 请求读到上一个对象的尾巴。
    local function release(keepalive)
        if not keepalive then
            httpc:close()
            return
        end
        if res.has_body and res.body_reader then
            local reader = res.body_reader
            while true do
                local chunk = reader(CHUNK_SIZE)
                if chunk == nil or chunk == false then break end
            end
        end
        httpc:set_keepalive(cfg.keepalive_idle, KEEPALIVE_POOL)
    end

    local status = res.status
    if status ~= 200 and status ~= 206 then
        local body = res.has_body and res:read_body() or ""
        httpc:close()
        local _, message = s3.error_from_response(status, type(body) == "string" and body or "")
        return reject(status >= 400 and status <= 599 and status or 502, message)
    end

    local content_type = s3.content_type(key)
    ngx.status = status
    ngx.header["Content-Type"] = content_type
    -- 与 /_authz/files/ 同款安全头：被浏览的 HTML 在独立沙箱源里运行，
    -- 脚本可执行但拿不到网关会话 Cookie，访问不了 /_authz/api/*。
    ngx.header["Content-Security-Policy"] =
        "sandbox allow-scripts allow-forms allow-popups allow-modals"
    ngx.header["X-Content-Type-Options"] = "nosniff"
    -- 该服务自己不回 Accept-Ranges（非标准），但 Range 实测有效，由网关补上。
    ngx.header["Accept-Ranges"] = "bytes"
    -- 预览与裸 URL 是两种字节（是否注入脚本），必须分开缓存键；no-store 最省事。
    ngx.header["Cache-Control"] = preview and "no-store" or "private, max-age=3600"
    if download then
        local filename = key:match("([^/]+)$") or "file"
        ngx.header["Content-Disposition"] = 'attachment; filename="' .. ngx.escape_uri(filename) .. '"'
    elseif preview then
        ngx.header["Content-Disposition"] = "inline"
    end
    -- 有意不转发 ETag / Last-Modified：nginx 的 not-modified 头过滤器会拿它们对
    -- 客户端的 If-None-Match / If-Modified-Since 自动改写出 304，而 content_by_lua
    -- 已经在流式输出 body，ngx.print 因此失败并触发「set status 500 after 304」的
    -- error.log 噪音（241 实测）。条件请求语义上 200+完整体永远合法；缓存命中靠
    -- 上面的 max-age。Content-Length/Range 必须照抄（播放器拖进度条依赖 206）。
    for _, name in ipairs({ "Content-Length", "Content-Range" }) do
        local value = res.headers[string.lower(name)]
        if value then ngx.header[name] = value end
    end

    if method == "HEAD" then
        release(true)
        return ngx.exit(status)
    end

    local declared = tonumber(res.headers["content-length"])
    local inject = preview and content_type:find("text/html", 1, true)
        and declared and declared <= HTML_INJECT_LIMIT
    if inject then
        local body = res:read_body()
        release(false)
        local text = type(body) == "string" and body or ""
        -- 与 nginx 侧 map 的行为对齐：没有 </head>（含大小写变体）就不注入。
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
        ngx.print(text)
        return ngx.exit(status)
    end

    -- 流式透传。客户端中途断开时 ngx.print 返回 false：连接没读空，直接 close。
    local reader = res.body_reader
    local eof = false
    while true do
        local chunk, read_err = reader(CHUNK_SIZE)
        if chunk == nil or chunk == false then
            eof = read_err == nil
            break
        end
        if #chunk > 0 then
            if not ngx.print(chunk) then
                httpc:close()
                -- 多半是客户端断开：响应头早已发出，再 ngx.exit(500) 只会往
                -- error.log 里塞「after sending out」噪音。直接 return 收尾。
                return
            end
            local ok, flush_err = ngx.flush(true)
            if not ok and tostring(flush_err):find("closed", 1, true) then
                httpc:close()
                return
            end
        end
    end
    -- 只有干净地读到 EOF 才能把连接放回池里（上面已把 body 读空，这里不能再走
    -- release()：它的 drain 循环会再次驱动已结束的 reader 协程）。读失败的连接
    -- 状态未知，必须 close。
    if eof then
        httpc:set_keepalive(cfg.keepalive_idle, KEEPALIVE_POOL)
    else
        httpc:close()
    end
    return ngx.exit(status)
end

return _M
