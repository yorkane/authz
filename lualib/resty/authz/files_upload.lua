-- Multipart uploader for the file manager (POST /_authz/api/files/upload).
--
-- Streams the request body with resty.upload straight to disk: the body is
-- never buffered into memory or into the nginx temp file (ngx.req.read_body
-- must NOT have run, so the CSRF header is read first and no size-1MB memory
-- copy happens). Files land under files_root through resty.authz.files
-- guards: every path segment must be an existing real directory (symlinks
-- rejected), names are single segments only, and an existing target is only
-- replaced when the caller explicitly asked for it (?overwrite=1).

local upload = require "resty.upload"
local files = require "resty.authz.files"

local _M = {}

local CHUNK_SIZE = 64 * 1024

local MAX_FILES = 64
-- Per-file quota only: a request can legitimately carry many large files, so
-- the total is unbounded beyond the disk itself; each file is capped so one
-- stream cannot fill the volume by accident.
local MAX_FILE_BYTES = 2 * 1024 * 1024 * 1024

local function config()
    return require("resty.authz").config
end

-- Pull the file name out of a Content-Disposition header value.
-- Prefer the RFC 5987 extended form (filename*=UTF-8''...) over the plain one.
local function part_filename(value)
    if type(value) ~= "string" then return nil end
    local ext = value:match("filename%*%s*=%s*[Uu][Tt][Ff]%-8''([^\r\n;]+)")
    if ext then
        local decoded = ngx.unescape_uri(ext)
        return files.validate_name(decoded)
    end
    local plain = value:match('filename%s*=%s*"([^"]*)"') or value:match("filename%s*=%s*([^;]+)")
    if not plain then return nil end
    return files.validate_name(plain:gsub("%s+$", ""))
end

local function open_sink(dir, name, overwrite)
    local path = dir .. "/" .. name
    if files.path_exists(path) then
        -- Covers files, dirs and symlinks alike: refuse to clobber anything
        -- unless overwrite was requested; overwrite still never follows a
        -- symlink (checked again below).
        if not overwrite then return nil, nil, "文件已存在: " .. name, 409 end
        if files.is_symlink(path) then
            return nil, nil, "拒绝覆盖符号链接: " .. name, 400
        end
    end
    -- Unique staging name: a concurrent upload of the same target can never
    -- collide, and an interrupted stream leaves a .upload-* file, not a
    -- half-written target.
    local tmp = dir .. "/.upload-" .. ngx.worker.pid() .. "-" ..
        tostring(ngx.now()):gsub("%.", "-") .. "-" .. tostring(math.random(100000, 999999))
    local handle, err = io.open(tmp, "wb")
    if not handle then return nil, nil, "无法写入: " .. tostring(err), 500 end
    return handle, tmp
end

--- Handle one multipart upload. Returns (payload, err, status).
function _M.upload()
    local args = ngx.req.get_uri_args()
    local rel = tostring(args.path or "")
    local overwrite = args.overwrite == "1" or args.overwrite == "true"

    local content_type = ngx.req.get_headers()["content-type"] or ""
    if type(content_type) == "table" then content_type = content_type[1] end
    if not content_type:lower():find("multipart/form-data", 1, true) then
        return nil, "上传必须使用 multipart/form-data", 415
    end

    local dir, dir_err, dir_status, clean = files.resolve_dir(config().files_root or files.default_root, rel)
    if not dir then return nil, dir_err, dir_status or 400 end

    local form, new_err = upload.new(CHUNK_SIZE)
    if not form then return nil, "无法解析 multipart: " .. tostring(new_err), 400 end
    form:set_timeout(30000)

    local written, skipped = {}, {}
    local handle, target_path, file_name, file_bytes, overflow
    local file_count = 0
    -- 同名冲突单独计数：全部跳过都是冲突时整体返回 409，
    -- 前端据此弹出「是否覆盖」并以 overwrite=1 重传。
    local conflicts = 0

    local function close_sink(discard)
        if not handle then return end
        handle:close()
        handle = nil
        if discard or overflow then
            os.remove(target_path)
        else
            local ok, rename_err = os.rename(target_path, dir .. "/" .. file_name)
            if not ok then
                os.remove(target_path)
                skipped[#skipped + 1] = { name = file_name, reason = "保存失败: " .. tostring(rename_err) }
            end
        end
        target_path, file_name = nil, nil
    end

    while true do
        local part_type, data = form:read()
        if part_type == "eof" then break end

        if part_type == "header" then
            if type(data) == "table" then
                local key = tostring(data[1]):lower()
                if key == "content-disposition" then
                    close_sink(true)
                    if file_count >= MAX_FILES then
                        overflow = true
                    else
                        local disposition = tostring(data[2])
                        if disposition:find('name="file"', 1, true)
                            or disposition:find("name=file[;]", 1, false) then
                            file_count = file_count + 1
                            file_name = part_filename(disposition)
                            file_bytes, overflow = 0, false
                            if not file_name then
                                overflow = true
                                skipped[#skipped + 1] = {
                                    name = "(invalid)",
                                    reason = "文件名非法（不能含路径分隔符或为空）",
                                }
                            else
                                local sink, sink_tmp, sink_err, sink_status =
                                    open_sink(dir, file_name, overwrite)
                                if sink then
                                    handle, target_path = sink, sink_tmp
                                else
                                    overflow = true
                                    if sink_status == 409 then conflicts = conflicts + 1 end
                                    skipped[#skipped + 1] = { name = file_name, reason = sink_err }
                                end
                            end
                        else
                            overflow = true -- non-file field: ignore
                        end
                    end
                end
            end
            file_bytes = file_bytes or 0
        elseif part_type == "body" then
            if file_name and not overflow then
                file_bytes = file_bytes + #data
                if file_bytes > MAX_FILE_BYTES then
                    overflow = true
                    skipped[#skipped + 1] = { name = file_name, reason = "单文件超过上限" }
                else
                    if handle then
                        local ok, write_err = handle:write(data)
                        if not ok then
                            overflow = true
                            skipped[#skipped + 1] = { name = file_name, reason = "写入失败: " .. tostring(write_err) }
                        end
                    end
                end
            end
        elseif part_type == "part_end" then
            if file_name and not overflow then
                local done_name = file_name
                close_sink(false)
                written[#written + 1] = { name = done_name, size = file_bytes or 0 }
            else
                close_sink(true)
            end
        end
    end
    close_sink(true)

    if #written == 0 and #skipped == 0 then
        return nil, "没有找到上传文件（表单需包含 file 字段）", 422
    end
    local status = 201
    if #written == 0 then
        -- 全是同名冲突 → 409（前端弹覆盖确认）；其余原因统一 422。
        status = #skipped > 0 and conflicts == #skipped and 409 or 422
    end
    local cjson = require "cjson.safe"
    return { data = {
        uploaded = #written > 0 and written or cjson.empty_array,
        skipped = #skipped > 0 and skipped or cjson.empty_array,
        path = clean,
    } }, nil, status
end

return _M
