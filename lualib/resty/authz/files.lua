-- Read-only directory listing for the web file browser, built on
-- LuaFileSystem (lfs.so, built in the Dockerfile and shipped with the image;
-- linked against the shared LuaJIT runtime so it loads inside OpenResty).
-- io.popen/os.execute are unavailable in request context, so directory
-- traversal goes through the C module. The listing is confined to a single
-- root directory and only exposes metadata; file bytes are served by the
-- nginx /files/ static location.

local ok_lfs, lfs = pcall(require, "lfs")

local _M = {
    available = ok_lfs and lfs ~= nil,
    MAX_ENTRIES = 2000,
    -- Kept in sync with the nginx /_authz/files/ alias.
    default_root = "/files",
}

-- Collapse a user-supplied relative path; reject traversal and control chars.
-- Returns the cleaned path ("" for root) or nil when invalid.
function _M.normalize(rel)
    rel = tostring(rel or "")
    if rel:find("[%c\\]") then return nil end
    local segments = {}
    for segment in rel:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return nil end
        if #segment > 255 then return nil end
        segments[#segments + 1] = segment
    end
    return table.concat(segments, "/")
end

local function is_hidden(name)
    -- Dotfiles and pre-compressed sidecars are not part of the browse view.
    return name:sub(1, 1) == "." or name:match("%.br$") ~= nil
end

-- List one directory. Returns { path, items, dirs, files, bytes, truncated }.
function _M.list(root, rel)
    if not _M.available then
        return nil, "lfs 模块不可用", 503
    end
    local clean = _M.normalize(rel)
    if not clean then
        return nil, "invalid path", 400
    end
    local directory = root .. (clean == "" and "" or "/" .. clean)
    local root_attr = lfs.attributes(directory)
    if not root_attr or root_attr.mode ~= "directory" then
        return nil, "目录不存在", 404
    end

    local items = {}
    local count, dirs, files, bytes, truncated = 0, 0, 0, 0, false
    local iterator, dir_handle = lfs.dir(directory)
    for name in iterator, dir_handle do
        if name ~= "." and name ~= ".." and not is_hidden(name) then
            if count >= _M.MAX_ENTRIES then
                truncated = true
                break
            end
            local attr = lfs.attributes(directory .. "/" .. name)
            if attr then
                local is_dir = attr.mode == "directory"
                count = count + 1
                items[count] = {
                    name = name,
                    type = is_dir and "dir" or "file",
                    size = is_dir and 0 or (attr.size or 0),
                    mtime = attr.modification or 0,
                }
                if is_dir then
                    dirs = dirs + 1
                else
                    files = files + 1
                    bytes = bytes + (attr.size or 0)
                end
            end
        end
    end
    -- lfs.dir keeps the DIR* open until garbage collected; close it eagerly.
    if dir_handle then
        pcall(function() return dir_handle:close() end)
    end

    return {
        path = clean,
        items = items,
        dirs = dirs,
        files = files,
        bytes = bytes,
        truncated = truncated,
    }
end

return _M
