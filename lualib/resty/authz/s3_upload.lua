-- Multipart uploader for the object browser (POST /_authz/api/s3/upload).
--
-- 与 files_upload.lua 同构：resty.upload 流式读 multipart，每个文件**先落暂存文件**，
-- part_end 时再 PUT 上 S3。为什么不边收边 PUT：S3 的 PUT 一旦发出就锁死了
-- Content-Length，而 multipart 的分段边界会打断字节流，两者拼在一起就没法在
-- “目标已存在”时给出与 files 一致的 409（必须先完整收到文件名+大小才知道冲突）。
-- 代价是一次磁盘写，换来 201/409/422 语义与前端逻辑完全复用。
--
-- 覆盖策略也和 files 一致：目标已存在且未带 overwrite=1 → 该文件跳过并计一次冲突。
local upload = require "resty.upload"
local s3 = require "resty.authz.s3"

local _M = {}

local CHUNK_SIZE = 64 * 1024
local MAX_FILES = 64
-- 单文件上限与 files 上传对齐。该服务实测 100MB 单次 PUT 0.5s，更大文件理论可用
-- multipart upload，本版先不做，超限直接跳过并说明原因。
local MAX_FILE_BYTES = 2 * 1024 * 1024 * 1024

local function tmp_dir()
    return tostring(os.getenv("AUTHZ_S3_TMP_DIR") or "/data/s3tmp")
end

-- 暂存目录兜底：镜像 entrypoint 只在容器启动时 mkdir 一次；运行期目录被清掉、
-- 或镜像内 entrypoint 早于该特性（如 241 只读挂载仓库代码但不挂 entrypoint，
-- 用的还是旧镜像）时，上传会整批以「暂存目录不可写」失败。每个文件开暂存前
-- 先逐级 mkdir -p：常驻场景就是一两条 EEXIST(17) 的 mkdir 系统调用，相对落盘
-- 开销可忽略；也因此不缓存“成功”，目录再被删掉时下一次上传仍然自愈。
local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then
    pcall(ffi.cdef, "int mkdir(const char *path, unsigned long mode);")
end

local function ensure_tmp_dir()
    local dir = tmp_dir()
    if not ffi_ok or dir:sub(1, 1) ~= "/" then return false end
    local cursor = ""
    for segment in dir:gmatch("[^/]+") do
        cursor = cursor .. "/" .. segment
        local ok_call, rc = pcall(function() return tonumber(ffi.C.mkdir(cursor, 493)) end)
        if not (ok_call and (rc == 0 or ffi.errno() == 17)) then
            ngx.log(ngx.WARN, "authz: cannot create S3 staging dir ", cursor, " (",
                tostring(ok_call and ffi.errno() or rc), ")")
            return false
        end
    end
    return true
end

-- 从 Content-Disposition 取文件名，优先 RFC 5987 的 filename*=UTF-8''。
local function part_filename(value)
    if type(value) ~= "string" then return nil end
    local ext = value:match("filename%*%s*=%s*[Uu][Tt][Ff]%-8''([^\r\n;]+)")
    if ext then
        return s3.normalize_name(ngx.unescape_uri(ext))
    end
    local plain = value:match('filename%s*=%s*"([^"]*)"') or value:match("filename%s*=%s*([^;]+)")
    if not plain then return nil end
    return s3.normalize_name(plain:gsub("%s+$", ""))
end

--- Handle one multipart upload. Returns (payload, err, status).
function _M.upload(cfg, bucket, prefix, overwrite)
    local content_type = ngx.req.get_headers()["content-type"] or ""
    if type(content_type) == "table" then content_type = content_type[1] end
    if not content_type:lower():find("multipart/form-data", 1, true) then
        return nil, "上传必须使用 multipart/form-data", 415
    end

    local form, new_err = upload.new(CHUNK_SIZE)
    if not form then return nil, "无法解析 multipart: " .. tostring(new_err), 400 end
    form:set_timeout(30000)

    local written, skipped = {}, {}
    local handle, staging, file_name, file_bytes, overflow
    local file_count, conflicts = 0, 0

    local function open_sink(name)
        ensure_tmp_dir()
        -- 唯一暂存名：并发上传互不覆盖，中断的流留下 .s3-upload-* 而不是半成品。
        local path = tmp_dir() .. "/.s3-upload-" .. ngx.worker.pid() .. "-" ..
            tostring(ngx.now()):gsub("%.", "-") .. "-" .. tostring(math.random(100000, 999999))
        local fd, err = io.open(path, "wb")
        if not fd then
            return nil, "暂存目录不可写 " .. tmp_dir() .. ": " .. tostring(err)
        end
        handle, staging, file_name, file_bytes, overflow = fd, path, name, 0, false
        return true
    end

    local function close_sink(discard)
        local fd, path, name, size = handle, staging, file_name, file_bytes
        handle, staging, file_name = nil, nil, nil
        if fd then fd:close() end
        if not path then return end
        if discard or overflow then
            os.remove(path)
            return
        end
        local key = s3.join(prefix, name)
        if not overwrite and s3.head(cfg, bucket, key) then
            os.remove(path)
            conflicts = conflicts + 1
            skipped[#skipped + 1] = { name = name, reason = "对象已存在: " .. name }
            return
        end
        local ok, put_err = s3.put(cfg, bucket, key,
            { file = path, size = size }, s3.content_type(name))
        os.remove(path)
        if not ok then
            skipped[#skipped + 1] = { name = name, reason = put_err }
            return
        end
        written[#written + 1] = { name = name, size = size or 0 }
    end

    while true do
        local part_type, data = form:read()
        if part_type == "eof" then break end

        if part_type == "header" then
            if type(data) == "table" then
                if tostring(data[1]):lower() == "content-disposition" then
                    close_sink(true)
                    if file_count >= MAX_FILES then
                        overflow = true
                    else
                        local disposition = tostring(data[2])
                        if disposition:find('name="file"', 1, true)
                            or disposition:find("name=file[;]", 1, false) then
                            file_count = file_count + 1
                            local name = part_filename(disposition)
                            if not name then
                                overflow = true
                                skipped[#skipped + 1] = {
                                    name = "(invalid)",
                                    reason = "文件名非法（不能含路径分隔符或为空）",
                                }
                            else
                                local ok, err = open_sink(name)
                                if not ok then
                                    overflow = true
                                    skipped[#skipped + 1] = { name = name, reason = err }
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
                    skipped[#skipped + 1] = { name = file_name, reason = "单文件超过上限 2GB" }
                elseif handle then
                    local ok, write_err = handle:write(data)
                    if not ok then
                        overflow = true
                        skipped[#skipped + 1] = { name = file_name, reason = "写入失败: " .. tostring(write_err) }
                    end
                end
            end
        elseif part_type == "part_end" then
            close_sink(file_name == nil or overflow)
        end
    end
    close_sink(true)

    if #written == 0 and #skipped == 0 then
        return nil, "没有找到上传文件（表单需包含 file 字段）", 422
    end
    local status = 201
    if #written == 0 then
        -- 全是同名冲突 → 409（前端据此弹覆盖确认，再带 overwrite=1 重传）。
        status = conflicts > 0 and conflicts == #skipped and 409 or 422
    end
    local cjson = require "cjson.safe"
    return { data = {
        uploaded = #written > 0 and written or cjson.empty_array,
        skipped = #skipped > 0 and skipped or cjson.empty_array,
        path = prefix,
        bucket = bucket,
    } }, nil, status
end

return _M
