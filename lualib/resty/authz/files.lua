-- Read-only directory listing for the web file browser, built on
-- LuaFileSystem (lfs.so, built in the Dockerfile and shipped with the image;
-- linked against the shared LuaJIT runtime so it loads inside OpenResty).
-- io.popen/os.execute are unavailable in request context, so directory
-- traversal goes through the C module. The listing is confined to a single
-- root directory and only exposes metadata; file bytes are served by the
-- nginx /files/ static location.

-- lfs is resolved lazily: _M.preload() runs in init_by_lua and primes
-- package.loaded, so the request path only ever hits the cached module.
local lfs
local lfs_resolved = false
local available = true

local function lfs_mod()
    if not lfs_resolved then
        lfs_resolved = true
        local ok, mod = pcall(require, "lfs")
        if ok then lfs = mod end
        available = ok and mod ~= nil
    end
    return lfs
end

local _M = {
    available = true,
    MAX_ENTRIES = 2000,
    -- Kept in sync with the nginx /_authz/files/ alias.
    default_root = "/files",
}

--- Load lfs.so before any worker starts serving requests.
-- lfs.so is a plain Lua 5.1 C module: luaopen_lfs() stores the library in a
-- global, which trips lua-nginx-module's _G write guard (a per-worker warn
-- with a long stack trace) whenever the first require happens inside a
-- request. Requiring it from init_by_lua keeps the global write in the
-- master process where the guard is not installed.
function _M.preload()
    lfs_resolved = false
    local mod = lfs_mod()
    _M.available = available
    return available and mod ~= nil
end

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
    local lfs = lfs_mod()
    _M.available = available
    if not lfs then
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

-- ── 写操作（文件管理的上传 / 重命名 / 删除） ────────────────────────────────
-- 所有写路径都走 resolve_dir()：路径的每一级都必须已存在且是"真目录"
-- （用 symlinkattributes 判定：符号链接报 mode=link，一律拒绝）。因此即使
-- 根目录里被预先放置了指向外部的符号链接，写操作也不可能越出 root。
-- 名称参数只接受单段文件名：分隔符、控制字符、. 与 .. 直接拒绝。

--- lfs.symlinkattributes 的存在性探测与文件根可用性由 resolve_dir 统一处理。
function _M.is_symlink(path)
    local lfs = lfs_mod()
    if not lfs then return false end
    local attr = lfs.symlinkattributes(path)
    return attr ~= nil and attr.mode == "link"
end

function _M.path_exists(path)
    local lfs = lfs_mod()
    if not lfs then return false end
    return lfs.symlinkattributes(path) ~= nil
end

function _M.validate_name(name)
    name = tostring(name or "")
    if name == "" or name == "." or name == ".." then return nil end
    if #name > 255 then return nil end
    if name:find("[%c/\\]") then return nil end
    return name
end

-- 把相对目录解析为 root 内的绝对目录；每个中间段必须是真实目录（非符号链接）。
-- 返回绝对目录、错误、状态码、规范化后的相对路径。
function _M.resolve_dir(root, rel)
    local clean = _M.normalize(rel)
    if not clean then return nil, "invalid path", 400 end
    local lfs = lfs_mod()
    _M.available = available
    if not lfs then return nil, "lfs 模块不可用", 503 end
    local current = root
    local root_attr = lfs.symlinkattributes(current)
    if not root_attr or root_attr.mode ~= "directory" then
        return nil, "文件根目录不可用", 503
    end
    for segment in clean:gmatch("[^/]+") do
        current = current .. "/" .. segment
        local attr = lfs.symlinkattributes(current)
        if not attr then return nil, "目录不存在: " .. segment, 404 end
        if attr.mode ~= "directory" then return nil, "路径段不是目录: " .. segment, 400 end
    end
    return current, nil, nil, clean
end

function _M.rename(root, rel, old_name, new_name)
    local dir, err, status = _M.resolve_dir(root, rel)
    if not dir then return nil, err, status end
    local old = _M.validate_name(old_name)
    local new = _M.validate_name(new_name)
    if not old or not new then
        return nil, "名称不能为空且不能包含路径分隔符或控制字符", 422
    end
    if old == new then return nil, "新旧名称相同", 422 end
    local lfs = lfs_mod()
    local from = dir .. "/" .. old
    local to = dir .. "/" .. new
    local attr = lfs.symlinkattributes(from)
    if not attr then return nil, "文件或目录不存在", 404 end
    if attr.mode == "link" then return nil, "拒绝操作符号链接", 400 end
    if lfs.symlinkattributes(to) then return nil, "目标名称已存在", 409 end
    local ok, rename_err = os.rename(from, to)
    if not ok then return nil, "重命名失败: " .. tostring(rename_err), 500 end
    return { message = "已重命名", name = new }
end

-- 新建单层目录。目录名与文件同规则校验（禁止分隔符/.. /控制字符），目标已存在 409。
function _M.mkdir(root, rel, name)
    local dir, err, status = _M.resolve_dir(root, rel)
    if not dir then return nil, err, status end
    local target = _M.validate_name(name)
    if not target then
        return nil, "名称不能为空且不能包含路径分隔符或控制字符", 422
    end
    local lfs = lfs_mod()
    local to = dir .. "/" .. target
    if lfs.symlinkattributes(to) then return nil, "同名文件或目录已存在", 409 end
    local ok, mk_err = lfs.mkdir(to)
    if not ok then return nil, "创建目录失败: " .. tostring(mk_err), 500 end
    return { message = "已创建目录", name = target }
end


local function delete_tree(lfs, path, recursive)
    local attr = lfs.symlinkattributes(path)
    if not attr then return nil, "文件或目录不存在", 404 end
    if attr.mode == "link" then return nil, "拒绝删除符号链接", 400 end
    if attr.mode == "directory" then
        local names = {}
        local iterator, handle = lfs.dir(path)
        for name in iterator, handle do
            if name ~= "." and name ~= ".." then names[#names + 1] = name end
        end
        -- lfs.dir keeps the DIR* open until GC; close it eagerly.
        if handle then pcall(function() return handle:close() end) end
        if #names > 0 and not recursive then
            return nil, "目录非空：需要显式递归删除", 409
        end
        for _, name in ipairs(names) do
            local ok, child_err, child_status = delete_tree(lfs, path .. "/" .. name, true)
            if not ok then return nil, child_err, child_status end
        end
    end
    local ok, remove_err = os.remove(path)
    if not ok then return nil, "删除失败: " .. tostring(remove_err), 500 end
    return true
end

function _M.remove(root, rel, name, recursive)
    local dir, err, status = _M.resolve_dir(root, rel)
    if not dir then return nil, err, status end
    local target = _M.validate_name(name)
    if not target then
        return nil, "名称不能为空且不能包含路径分隔符或控制字符", 422
    end
    local lfs = lfs_mod()
    local ok, remove_err, remove_status = delete_tree(lfs, dir .. "/" .. target, recursive == true)
    if not ok then return nil, remove_err, remove_status or 500 end
    return { message = "已删除", name = target }
end

return _M
