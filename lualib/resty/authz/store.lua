-- 本机「临时保存区」(config.store_dir()) 的目录 IO 原语：路径归一化 + 读写删列。
--
-- 定位：给 agent 用的临时交换区，不承诺长期保存（TTL 由 upload_records kind='local'
-- + maintenance 每小时清理器负责）。这里只做文件系统动作，不含 HTTP、不含 SQL、
-- 不含记账——那些在 api/services/store.lua（校验+事务+记账）与 store_proxy.lua
-- （字节流出口）。
--
-- 与 files.lua 的分工：files.lua 是「给人浏览的只读内容根」的防护与列表，
-- maintenance.lua 删本地行时依赖它（files.remove），因此本模块**不** require
-- files / maintenance（依赖方向保持单向：maintenance 独立，store 也不反向依赖它），
-- 但路径防护语义与它完全一致，判据逐条对齐并在下面写明。
--
-- ── 安全红线（实现与理由，改动前必读）────────────────────────────────────
-- R1 路径归一化 _M.normalize：
--    * 拒绝绝对路径（前导 '/'）、'.' 与 '..' 段、'~'、控制字符（含 NUL，
--      "[%c]" 覆盖 \0 与 \n\r）、反斜杠；连续斜杠经 gmatch("[^/]+") 自然折叠。
--    * 与 files.normalize 的唯一区别：files 把 "/etc/passwd" 的前导斜杠丢掉
--      （变成根内的 etc/passwd），这里直接拒绝——写接口拿到绝对路径一定是
--      调用方出错，静默改写反而掩盖问题。两者都出不了根，只是错误可见性不同。
--    * 段长 ≤255（ext4 单段上限）、总长 ≤1024（给 root 前缀留出余量）。
--    * 结果可以是 ""（= 保存区根），只有 list 允许；写/删/查必须过
--      _M.normalize_target 再挡一次空结果。
-- R2 符号链接逃逸：解析时逐级 lfs.symlinkattributes（它是 lstat 语义，
--    mode=="link" 即符号链接），任一已存在的路径段是链接就拒绝，所以即使有人
--    预先在 store_dir 里放一个指向 /etc 的链接，也走不进去。落盘目标的叶子同样
--    用 symlinkattributes 判定：链接一律不覆盖、不读取。
--    刻意不用 io.popen("realpath")：io.popen 在请求上下文里被 lua-nginx-module
--    禁用，而且 fork 出的进程去解析路径等于把「谁在决定路径」交给外部程序。
--    lfs 的逐级 lstat 是同一判据的纯 in-process 版本（与 files.resolve_dir 一致）。
--    残余风险：store_dir **自身**被运维配成符号链接时，它的目标就是保存区本身，
--    这属于部署期决定，运行期不做二次解释。
-- R3 原子写：先写 store_dir **顶层**的 .upload-<pid>-<now>-<rand>，再 os.rename
--    到目标。暂存放顶层是刻意的：maintenance.cleanup_staging 对 store 目录只做
--    单层扫描（不递归），落在子目录里的中断残留永远不会被扫到（files_upload 在
--    files_root 的嵌套目录就有这个盲区），放顶层则残留最多 6 小时被清理器收走。
--    任何失败路径必须 os.remove 暂存文件；rename 失败同样清理。
-- R4 保留名：段名不得以 TMP_PREFIXES 开头（.upload- / .s3-upload- / .tmp- / tmp-，
--    与 maintenance.lua 的 TMP_PREFIXES 同一份名单）。这些前缀会被暂存清理器按
--    mtime 删掉，用户文件撞上就是无声丢数据。**名单必须在两处手工保持一致**
--    （本文件与 maintenance.lua），注释里互相指认。
-- R5 只读根保护：写/删只允许发生在 store_dir 内，且 root 不可被删除（remove_tree
--    拒绝 rel=""）。
-- R6 本模块不碰 ngx、不碰 config：root 一律由调用方传入（与 files.lua 同形状），
--    因此这些纯函数可以在裸 luajit 里跑用例（见交付报告的自检脚本）；pid/time
--    取用带 pcall 兜底，脚本环境下也能生成暂存名。
local _M = {
    MAX_ENTRIES = 2000,
    MAX_SEGMENT = 255,
    MAX_PATH = 1024,
}

-- ── lfs 取用 ────────────────────────────────────────────────────────────────
-- lfs.so 是 lua-nginx-module _G 写保护的既有坑（见 files.lua 头部）：
-- init_by_lua 的 files.preload() 已经把它放进 package.loaded，正常路径命中缓存。
local lfs
local lfs_resolved = false
_M.available = true

local function lfs_mod()
    if not lfs_resolved then
        lfs_resolved = true
        local loaded = package.loaded["lfs"]
        if loaded then
            lfs = loaded
        else
            local ok, mod = pcall(require, "lfs")
            if ok and mod then lfs = mod end
        end
        _M.available = lfs ~= nil
    end
    return lfs
end

-- ── 路径归一化 ──────────────────────────────────────────────────────────────
--- maintenance.lua TMP_PREFIXES 的同款名单（见 R4）：这些前缀属于上传暂存文件，
--- 清理器会按 mtime 直接删，用户不得占用。
local TMP_PREFIXES = { ".upload-", ".s3-upload-", ".tmp-", "tmp-" }

function _M.is_reserved(name)
    name = tostring(name or "")
    for _, prefix in ipairs(TMP_PREFIXES) do
        if name:sub(1, #prefix) == prefix then return true end
    end
    return false
end

--- 清洗相对路径。返回归一化后的相对路径（"" = 保存区根），非法返回 nil。
function _M.normalize(rel)
    local text = tostring(rel or "")
    if text == "" then return "" end
    -- 控制字符（含 NUL）与反斜杠：Windows 分隔符与转义注入都在这里挡掉。
    if text:find("[%c\\]") then return nil end
    -- '~' 一律拒绝：家目录展开由 shell 做，路径里出现它就是探测行为。
    if text:find("~", 1, true) then return nil end
    -- 绝对路径直接拒绝（files.lua 是丢弃前导斜杠，理由见 R1）。
    if text:sub(1, 1) == "/" then return nil end
    local segments = {}
    local length = 0
    for segment in text:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return nil end
        if #segment > _M.MAX_SEGMENT then return nil end
        length = length + #segment + 1
        segments[#segments + 1] = segment
    end
    if length > _M.MAX_PATH then return nil end
    return table.concat(segments, "/")
end

--- 单段名字（multipart 的文件名、将来的单层目录名）。含分隔符即拒绝。
function _M.validate_name(name)
    local text = tostring(name or "")
    if text == "" or text == "." or text == ".." then return nil end
    if #text > _M.MAX_SEGMENT then return nil end
    if text:find("[%c/\\]") or text:find("~", 1, true) then return nil end
    if _M.is_reserved(text) then return nil end
    return text
end

--- 写/删/查用的目标路径：归一化 + 非空 + 任一段不占用暂存前缀。
function _M.normalize_target(rel)
    local clean = _M.normalize(rel)
    if not clean or clean == "" then return nil end
    for segment in clean:gmatch("[^/]+") do
        if _M.is_reserved(segment) then return nil end
    end
    return clean
end

-- ── 根目录可用性 ────────────────────────────────────────────────────────────
--- 绝对路径的逐级 mkdir（只给「建保存区根」用：根目录本身由 env 决定，可信）。
local function make_path(abs)
    local lfs = lfs_mod()
    if not lfs then return nil, "lfs 模块不可用" end
    local current = ""
    for segment in tostring(abs):gmatch("[^/]+") do
        current = current .. "/" .. segment
        local attr = lfs.symlinkattributes(current)
        if attr then
            if attr.mode ~= "directory" then return nil, "路径段不是目录: " .. segment end
        else
            local created, err = lfs.mkdir(current)
            if not created then return nil, tostring(err) end
        end
    end
    return true
end

--- 保存区根是否可用（缺失就地建出来）。返回 true 或 (nil, 原因, 状态码)。
function _M.check_root(root)
    root = tostring(root or "")
    if root == "" or root:sub(1, 1) ~= "/" then return nil, "保存区目录未配置", 503 end
    local lfs = lfs_mod()
    if not lfs then return nil, "lfs 模块不可用", 503 end
    local attr = lfs.symlinkattributes(root)
    if attr then
        if attr.mode ~= "directory" then return nil, "保存区根目录不是目录", 503 end
        return true
    end
    local created, err = make_path(root)
    if not created then return nil, "无法创建保存区目录: " .. tostring(err), 503 end
    return true
end

--- 可写探针：真开一次文件再改名删除（只看权限位不算数，挂载可能是 ro）。
--- 探针文件名用 .upload- 前缀：进程被杀留下的残留由清理器按 mtime 收走。
function _M.writable(root)
    local ok, err, status = _M.check_root(root)
    if not ok then return false, err, status end
    local probe = tostring(root) .. "/" .. _M.staging_name()
    local handle, open_err = io.open(probe, "wb")
    if not handle then return false, "目录不可写: " .. tostring(open_err), 503 end
    handle:write("ok")
    handle:close()
    os.remove(probe)
    return true
end

-- ── 解析 ────────────────────────────────────────────────────────────────────
--- rel → root 内的绝对路径（只解析，不创建）。
--- 返回 abs, err, status, clean。合法路径即使尚未存在也返回 abs（写路径要用）。
function _M.resolve(root, rel)
    local clean = _M.normalize(rel)
    if not clean then return nil, "invalid path", 400 end
    local lfs = lfs_mod()
    if not lfs then return nil, "lfs 模块不可用", 503 end
    local current = root
    for segment in clean:gmatch("[^/]+") do
        current = current .. "/" .. segment
        local attr = lfs.symlinkattributes(current)
        -- R2：已存在的中间段是符号链接就停在这里（不跟随、不报错细节）。
        if attr and attr.mode == "link" then
            return nil, "路径中含符号链接，拒绝访问", 400
        end
    end
    -- 兜底断言：normalize 已保证结果在根内，这一步只为「以后有人改了 normalize」兜住。
    if clean ~= "" and current:sub(1, #root + 1) ~= root .. "/" then
        return nil, "路径越出保存区", 400
    end
    return current, nil, nil, clean
end

--- 写路径专用：保证 rel 的**祖先目录**都在根内存在（缺则逐级创建），叶子不碰。
--- keep_dirs=true 时把最后一段也当目录创建（上传的目录前缀用）。
--- 返回「放叶子的目录」绝对路径，或 (nil, 原因, 状态码, clean)。
--- R2 在这里同样生效：已存在的每一段都用 symlinkattributes（lstat 语义）判定，
--- 符号链接一律拒绝，所以预先埋在保存区里的外链既进不去也写不穿。
function _M.ensure_parents(root, rel, keep_dirs)
    local clean = _M.normalize_target(rel)
    if not clean then return nil, "invalid path", 400 end
    local lfs = lfs_mod()
    if not lfs then return nil, "lfs 模块不可用", 503 end
    -- 先把段全部取出来：Lua 的 gmatch 无法「只看最后一段不处理」，显式数组最清楚。
    local segments = {}
    for segment in clean:gmatch("[^/]+") do segments[#segments + 1] = segment end

    local current = root
    for index, segment in ipairs(segments) do
        current = current .. "/" .. segment
        local is_leaf = index == #segments and not keep_dirs
        local attr = lfs.symlinkattributes(current)
        if attr and attr.mode == "link" then
            return nil, "路径中含符号链接，拒绝写入: " .. segment, 400
        end
        if not is_leaf then
            if attr then
                if attr.mode ~= "directory" then
                    return nil, "路径段已存在且不是目录: " .. segment, 409
                end
            else
                local created, err = lfs.mkdir(current)
                if not created then return nil, "创建目录失败: " .. tostring(err), 500 end
            end
        end
    end
    -- 只有一段（rel = "x.txt"）时叶子不校验：它要么被 rename 覆盖、要么新建，
    -- 两种情况都不会跟随已存在的符号链接（put 在覆盖前用 lstat 单独判 link）。
    return segments[#segments] and current:match("^(.*)/[^/]+$") or root,
        nil, nil, clean
end

--- 不跟随符号链接的属性（mode 可能是 "file"/"directory"/"link"）。
function _M.lstat(path)
    local lfs = lfs_mod()
    if not lfs then return nil end
    return lfs.symlinkattributes(path)
end

-- ── 列目录 ──────────────────────────────────────────────────────────────────
--- 单层列表。返回 { path, items, truncated }，items 每项 {name,type,size,mtime}。
--- 暂存前缀（R4）不展示：它们是写入中间态，出现在列表里只会误导。
function _M.list(root, rel)
    local clean = _M.normalize(rel)
    if not clean then return nil, "invalid path", 400 end
    local available, err, status = _M.check_root(root)
    if not available then return nil, err, status end
    local lfs = lfs_mod()
    local directory = root .. (clean == "" and "" or "/" .. clean)
    local attr = lfs.symlinkattributes(directory)
    if not attr or attr.mode == "link" or attr.mode ~= "directory" then
        return nil, "目录不存在", 404
    end
    local items = {}
    local count, truncated = 0, false
    local iterator, handle = lfs.dir(directory)
    if not iterator then return nil, "无法读取目录", 500 end
    for name in iterator, handle do
        if name ~= "." and name ~= ".." and not _M.is_reserved(name) then
            if count >= _M.MAX_ENTRIES then
                truncated = true
                break
            end
            local item = lfs.symlinkattributes(directory .. "/" .. name)
            if item then
                count = count + 1
                -- 符号链接以 type="link" 如实报出（列表本身限 admin），但删/写都不认它。
                local kind = item.mode == "directory" and "dir"
                    or (item.mode == "link" and "link" or "file")
                items[count] = {
                    name = name,
                    type = kind,
                    size = kind == "file" and (item.size or 0) or 0,
                    mtime = item.modification or 0,
                }
            end
        end
    end
    -- lfs.dir 的 DIR* 要显式关（files.lua:110 同款，否则等 GC）。
    if handle and handle.close then pcall(function() return handle:close() end) end
    return { path = clean, items = items, truncated = truncated }
end

-- ── 写 ──────────────────────────────────────────────────────────────────────
--- 暂存文件唯一名（R3）。pid/时间取用带 pcall：裸 luajit 脚本里也能跑。
function _M.staging_name()
    -- ngx 在（真实请求 / timer 协程）时用 worker 的 pid 与高精度时间；纯 luajit
    -- 用例里没有 ngx 表，退到 os.time + "0" 占位（名字唯一性由随机段保证）。
    local pid, stamp = "0", tostring(os.time())
    local ok, first, second = pcall(function() return ngx.worker.pid(), ngx.now() end)
    if ok then
        if first then pid = tostring(first) end
        if second then stamp = tostring(second) end
    end
    return ".upload-" .. pid .. "-" .. stamp:gsub("%.", "-") .. "-"
        .. tostring(math.random(100000, 999999))
end

--- 在保存区**顶层**开暂存文件。返回 handle, path 或 (nil, err)。
function _M.open_staging(root)
    local available, err = _M.check_root(root)
    if not available then return nil, err end
    local path = tostring(root) .. "/" .. _M.staging_name()
    local handle, open_err = io.open(path, "wb")
    if not handle then return nil, "暂存文件不可写: " .. tostring(open_err) end
    return handle, path
end

--- 丢弃暂存（所有失败路径必须走这里）。日志走 safe_log：本模块的纯函数要能在
--- 裸 luajit 用例里跑（脚本环境没有 ngx 表）。
local function safe_log(message)
    local ok = pcall(function() ngx.log(ngx.WARN, "authz: ", message) end)
    if ok then return end
    pcall(function() io.stderr:write("authz store: ", message, "\n") end)
end

function _M.discard(handle, staging)
    if handle then
        local ok, err = pcall(function() handle:close() end)
        if not ok then safe_log("cannot close store staging handle: " .. tostring(err)) end
    end
    if staging then
        local removed, err = os.remove(staging)
        if not removed then safe_log("cannot remove store staging file: " .. tostring(err)) end
    end
end

--- 提交暂存 → 目标。关闭句柄后 rename，并回读落盘大小（rename 覆盖同名文件原子）。
--- 返回 { size = 实际字节 } 或 (nil, 原因)。失败已清暂存。
function _M.publish(handle, staging, target)
    if handle then
        local ok, err = pcall(function() handle:close() end)
        if not ok then
            _M.discard(nil, staging)
            return nil, "写入失败: " .. tostring(err)
        end
    end
    local renamed, rename_err = os.rename(staging, target)
    if not renamed then
        os.remove(staging)
        return nil, "保存失败: " .. tostring(rename_err)
    end
    local attr = _M.lstat(target)
    return { size = attr and (attr.size or 0) or 0 }
end

-- ── 删 ──────────────────────────────────────────────────────────────────────
--- 删文件（或 recursive=true 时删整棵子树）。符号链接一律拒（它指向根外的东西）。
--- 返回 { files = n, dirs = n } 或 (nil, 原因, 状态码)。
function _M.remove_tree(root, rel, recursive)
    local clean = _M.normalize_target(rel)
    if not clean then return nil, "invalid path", 400 end
    local available = _M.check_root(root)
    if not available then return nil, "保存区目录不可用", 503 end
    local lfs = lfs_mod()
    local abs, err, status = _M.resolve(root, clean)
    if not abs then return nil, err, status or 400 end

    local stats = { files = 0, dirs = 0 }
    local function walk(path, depth)
        local attr = lfs.symlinkattributes(path)
        if not attr then return nil, "文件或目录不存在", 404 end
        if attr.mode == "link" then return nil, "拒绝删除符号链接", 400 end
        if attr.mode == "directory" then
            if depth > 32 then return nil, "目录层级过深，拒绝递归删除", 400 end
            local names = {}
            local iterator, handle = lfs.dir(path)
            if not iterator then return nil, "无法读取目录", 500 end
            for name in iterator, handle do
                if name ~= "." and name ~= ".." then names[#names + 1] = name end
            end
            if handle and handle.close then pcall(function() return handle:close() end) end
            if #names > 0 and not recursive then
                return nil, "目录非空：需要显式递归删除", 409
            end
            for _, name in ipairs(names) do
                local ok, child_err, child_status = walk(path .. "/" .. name, depth + 1)
                if not ok then return nil, child_err, child_status end
            end
        end
        local removed, remove_err = os.remove(path)
        if not removed then return nil, "删除失败: " .. tostring(remove_err), 500 end
        if attr.mode == "directory" then
            stats.dirs = stats.dirs + 1
        else
            stats.files = stats.files + 1
        end
        return true
    end

    local ok, walk_err, walk_status = walk(abs, 1)
    if not ok then return nil, walk_err, walk_status or 500 end
    return stats
end

return _M
