--- Nginx include editor for the three user-editable hook files.
--
-- The gateway renders nginx.conf/server.conf from templates at start and
-- includes three operator-authored files (http_inc.conf, server_inc.conf and
-- stream_inc.conf). This module reads them, validates a candidate version in
-- a throwaway staging tree via "openresty -t", saves only on success, and
-- can trigger "openresty -s reload".
--
-- Validation never touches the live files: the whole runtime conf directory
-- is copied into a temporary prefix and only the edited include is replaced,
-- so a broken candidate can never be picked up by a concurrent reload.

local lfs = require "lfs"

local _M = {
    MAX_BYTES = 256 * 1024,
    -- Fixed whitelist: the editor can never reach an arbitrary path.
    FILES = {
        { name = "http_inc.conf",   scope = "http{}" },
        { name = "server_inc.conf", scope = "server{}" },
        { name = "stream_inc.conf", scope = "stream{}" },
    },
}

local by_name = {}
for _, entry in ipairs(_M.FILES) do by_name[entry.name] = entry end

local function cfg()
    return require("resty.authz").config
end

local function conf_dir()
    return (cfg().nginx_conf_dir or "/usr/local/openresty/nginx/conf"):gsub("/+$", "")
end

local function prefix_dir()
    return (cfg().nginx_prefix or "/usr/local/openresty/nginx"):gsub("/+$", "")
end

local function nginx_bin()
    return cfg().nginx_bin or "/usr/local/openresty/bin/openresty"
end

local function quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

-- Run a shell command capturing stdout+stderr. io.popen is verified to work
-- inside this image's worker processes (see test suite).
local function capture(command)
    local pipe, err = io.popen(command .. " 2>&1")
    if not pipe then
        return nil, tostring(err or "无法启动子进程")
    end
    local output = pipe:read("*a") or ""
    local ok, _, code = pipe:close()
    local code_num = tonumber(code) or 0
    if ok == false or code_num ~= 0 then
        return nil, output
    end
    return output, nil
end

function _M.known(name)
    return by_name[name] ~= nil
end

-- Where start-time include copies come from (docker-compose mounts it ro).
function _M.template_dir()
    return cfg().nginx_template_dir or ""
end

-- Edits survive a container restart only when the runtime conf directory is
-- the template directory itself (image-builtin mode) or the template
-- directory is writable.
function _M.persistent()
    local dir = conf_dir()
    local template = _M.template_dir()
    if template == "" then return true end
    if template == dir then return true end
    local probe = template .. "/.authz-write-probe"
    local handle = io.open(probe, "wb")
    if not handle then return false end
    handle:close()
    os.remove(probe)
    return true
end

local function read_file(path, limit)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local content = handle:read((limit or _M.MAX_BYTES) + 1)
    handle:close()
    return content
end

-- Read every editable include. Missing files read as empty (the entrypoint
-- generates defaults on start, but a stripped image may not have them yet).
function _M.read_all()
    local dir = conf_dir()
    local files = {}
    for _, entry in ipairs(_M.FILES) do
        local path = dir .. "/" .. entry.name
        local content = read_file(path)
        local attr = lfs.attributes(path)
        local truncated = content ~= nil and #content > _M.MAX_BYTES
        if truncated then content = content:sub(1, _M.MAX_BYTES) end
        files[#files + 1] = {
            name = entry.name,
            scope = entry.scope,
            content = content or "",
            truncated = truncated,
            size = attr and attr.size or 0,
            mtime = attr and attr.modification or 0,
            exists = attr ~= nil,
        }
    end
    return {
        conf_dir = dir,
        template_dir = _M.template_dir(),
        persistent = _M.persistent(),
        files = files,
    }
end

-- Reject control characters other than tab/newline/CR.
local function control_char_position(content)
    for i = 1, #content do
        local b = content:byte(i)
        if b < 9 or (b > 10 and b < 13) or b == 12 or (b > 13 and b < 32) or b == 127 then
            return i
        end
    end
    return nil
end

local function staging_dir()
    local out, err = capture("mktemp -d /tmp/authz-ngxcheck.XXXXXX")
    if not out then return nil, err end
    local path = (out:gsub("%s+$", ""))
    if not path:match("^/tmp/authz%-ngxcheck%.") then
        return nil, "临时目录创建异常"
    end
    return path
end

local function remove_staging(path)
    if path and path:match("^/tmp/authz%-ngxcheck%.") and #path > 24 then
        capture("rm -rf " .. quote(path))
    end
end

-- Validate one candidate include without touching live state.
-- Returns { ok = boolean, output = string } or nil + message + status.
function _M.validate(name, content)
    local entry = by_name[name]
    if not entry then return nil, "未知的配置文件", 400 end
    content = tostring(content or "")
    if #content > _M.MAX_BYTES then
        return nil, "内容超过 " .. math.floor(_M.MAX_BYTES / 1024) .. " KiB 上限", 413
    end
    local bad = control_char_position(content)
    if bad then
        return nil, "内容包含控制字符（位置 " .. bad .. "）", 400
    end

    local dir = conf_dir()
    local stage, err = staging_dir()
    if not stage then return nil, err end

    -- The staging directory doubles as the nginx prefix for the check, so
    -- relative includes (http_inc.conf, server.conf, mime.types) resolve
    -- inside the copy and log/pid paths (logs/...) stay writable there.
    local _, copy_err = capture("cp -a " .. quote(dir .. "/.") .. " " .. quote(stage) .. "/"
        .. " && mkdir -p " .. quote(stage .. "/logs"))
    if copy_err then
        remove_staging(stage)
        return { ok = false, output = "无法复制配置目录：" .. tostring(copy_err) }
    end
    local handle = io.open(stage .. "/" .. entry.name, "wb")
    if not handle then
        remove_staging(stage)
        return nil, "无法写入临时文件", 500
    end
    handle:write(content)
    handle:close()

    local check_out, check_err = capture(string.format(
        "%s -t -p %s -c %s",
        quote(nginx_bin()), quote(stage), quote(stage .. "/nginx.conf")))
    remove_staging(stage)

    local output = tostring(check_err or check_out or "nginx -t 无输出")
    -- Map staging paths back to the real conf dir so messages stay readable
    -- and never leak the temporary prefix.
    output = (output:gsub("/tmp/authz%-ngxcheck%.[^%' :/]+", dir))
    if not check_err then
        return { ok = true, output = output }
    end
    return { ok = false, output = output }
end

-- Persist a validated candidate (re-validated here so a direct API call can
-- never write a broken config). Keeps one .bak copy of the previous file.
function _M.save(name, content)
    local result, err, status = _M.validate(name, content)
    if not result then return nil, err, status end
    if not result.ok then
        return nil, result.output, 422
    end
    local path = conf_dir() .. "/" .. name
    local existed = lfs.attributes(path) ~= nil
    if existed then
        os.remove(path .. ".bak")
        os.rename(path, path .. ".bak")
    end
    local handle, open_err = io.open(path, "wb")
    if not handle then
        if existed then os.rename(path .. ".bak", path) end
        return nil, "无法写入 " .. path .. "：" .. tostring(open_err), 500
    end
    handle:write(content)
    handle:close()

    -- Best-effort mirror into the template directory so the edit also
    -- survives a container restart when that directory is writable.
    local mirrored = false
    local template = _M.template_dir()
    if template ~= "" and template ~= conf_dir() then
        local mirror = io.open(template .. "/" .. name, "wb")
        if mirror then
            mirror:write(content)
            mirror:close()
            mirrored = true
        end
    end
    return { ok = true, output = result.output, mirrored = mirrored,
        persistent = _M.persistent() }
end

-- Graceful "nginx -s reload" against the live master process.
function _M.reload()
    local output, err = capture(string.format(
        "%s -s reload -p %s -c %s",
        quote(nginx_bin()), quote(prefix_dir()), quote(conf_dir() .. "/nginx.conf")))
    if err then
        return nil, "reload 失败：" .. tostring(err), 500
    end
    return { ok = true, output = ((output or ""):gsub("^%s+", ""):gsub("%s+$", "")) }
end

return _M
