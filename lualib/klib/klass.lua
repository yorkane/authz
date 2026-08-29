local nfind, nsub, type, pcall, tostring, pairs, require = ngx.re.find, ngx.re.gsub, type, pcall, tostring, pairs, require
local nmatch, gmatch, byte, char = ngx.re.match, ngx.re.gmatch, string.byte, string.char
local sfind, ssub, lower, rep = string.find, string.sub, string.lower, string.rep
local say, print = ngx.say, ngx.print
local ins, concat = table.insert, table.concat
local sbuffer = require('klib.sbuffer')
local key_words = { ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true, ["while"] = true, }

local code_content_map = {}

---@class klib.kclass
local _M = {}

local root = ngx.config.prefix()

if not root or #root < 5 or sfind(lower(root), 'te*mp/') then
	local ok, lfs = pcall(require, 'lib.lfs_ffi')
	if ok and lfs.currentdir then
		root = nsub(lfs:currentdir() .. '/', [[\\+]], '/', 'jo')
	else
		root = '/usr/local/openresty/nginx/'
	end
end

local function read_file(filename, read_tail, is_binary)
	local file, err = io.open(filename, "r")
	if not file then
		return nil, err
	end
	local str, err
	if read_tail then
		local current = file:seek()
		local fileSize = file:seek("end")  --get file total size
		if fileSize > 200000 then
			file:seek('set', fileSize - 200000) --move cusor to last part
			str, err = file:read(200000)
		else
			file:seek('set', 0) --move cursor to head
			str, err = file:read(fileSize)
		end
	else
		str, err = file:read("*a")
	end
	file:close()
	str = str or ''
	return str, err
end

local function parse_returns(text)
	local inx = sfind(text, 'return', 1, true)
	if inx then
		text = ssub(text, inx + 7, #text)
		--ngx.say(text)
		return text
	end
end

local function get_func_params(content, line, self_class_name)
	local it = gmatch(content, [[([^\n]*)\n]], 'ijo') -- match by lines
	local nc = 0
	local arr, temp, returns, method_name = {}
	while true do
		local m, err = it()
		if not m then
			break
		end
		nc = nc + 1 -- move to next line
		if line == nc then
			local mc = nmatch(m[1], [[\(([^\)]*)\)]], 'joi') -- hit the definition line
			local params = mc[1]
			local it2 = gmatch(params, [[([\w\.]+)[, ]*]], 'jio')
			while true do
				mc = it2()
				if not mc then
					break
				end
				ins(arr, mc[1])
			end
			if m[1] then
				local name_match = nmatch(m[1], [[function [a-zA-Z_]\w*(:|\.)([a-zA-Z]\w*)[ ]*\(]], 'jo')
				if name_match then
					method_name = name_match[2]
					if name_match[1] == ':' then
						local self_str = self_class_name and 'self' .. self_class_name or 'self'
						ins(arr, 1, self_str)
					end
				else
					name_match = nmatch(m[1], [[([a-zA-Z]\w*)\s*=function\s*\(]], 'jo')
					if name_match then
						method_name = name_match[1]
					end
				end
			end
			returns = parse_returns(temp)
		end
		temp = m[1]
	end
	return arr, returns, method_name
end

---parse_func
---@param func fun @method to parse
---@param with_self boolean @with self parameter injected
---@param code_content @ source code content to analysis or will load source code from file system
---@return function.info
function _M.parse_func(func, with_self, code_content, self_class_name)
	local fi = debug.getinfo(func)
	--fi.name = fname
	local sb = sbuffer()
	fi.short_src = nsub(fi.short_src, [[\\]], '/', 'jo')
	if sfind(fi.short_src, '/', 1, true) == 1 then
		fi.source = fi.short_src .. ':' .. fi.linedefined
		fi.lua_name = nsub(ssub(fi.short_src, #root + 1, #fi.short_src - 4), [[/]], [[.]], 'jo')
	else
		fi.lua_name = nsub(ssub(fi.short_src, 3, #fi.short_src - 4), [[(\\|/)]], [[.]], 'jo')
		fi.source = root .. ssub(fi.short_src, 3, 400) .. ':' .. fi.linedefined
	end
	local inx = sfind(fi.source, '.lua', 4, true)
	if inx then
		local code_source = fi.short_src
		code_content = code_content or code_content_map[code_source]
		if not code_content then
			code_content = read_file(code_source)
			code_content_map[code_source] = code_content
		end
		fi.params, fi.returns, fi.name = get_func_params(code_content, fi.linedefined, self_class_name)
		fi.param = concat(fi.params, ', ')
		fi.lua_name = fi.lua_name .. '/' .. (fi.name or '')
		--local match = nmatch(code_content, , 'joi')
	else
		if fi.nparams > 1 then
			fi.nparams = with_self and fi.nparams or fi.nparams - 1
			for i = 1, fi.nparams do
				sb:add('arg', i, ', ')
			end
		else
			sb:add('arg', '')
		end
		fi.param = sb:pop(1):tos()
		fi.source = 'c'
	end
	--fi.is_lua = (fi.what ~= 'C')
	return fi
end

---parse_hierarchy get the full lua object
---@param lua_obj table
---@param __depth number @use internally, please ignore this paramter
function _M.parse_hierarchy(lua_obj, __depth)
	local tp = type(lua_obj)
	if tp ~= 'table' then
		return lua_obj
	end
	__depth = __depth or 0
	local new_obj = {}
	local mt = getmetatable(lua_obj)
	if mt then
		local upper = mt.__index
		if upper then
			local base = _M.parse_hierarchy(upper, __depth)
			if type(base) == 'table' then
				for i, v in pairs(base) do
					new_obj[i] = v
				end
			end
		end
	end
	for name, val in pairs(lua_obj) do
		local tp = type(val)
		if tp == 'table' then
			if name == '__class' or name == '__index' or name == '__metatable' or name == '__base' or name == '__parent' then
				__depth = __depth + 1
				if __depth > 8 then
					return new_obj
				end
				local base = _M.parse_hierarchy(val, __depth)
				for i, v in pairs(base) do
					new_obj[i] = v
				end
			else
				new_obj[name] = val
			end
		else
			new_obj[name] = val
		end
	end
	return new_obj
end

local function get_key(key)
	if key_words[key] then
		return '["' .. key .. '"]'
	end
	return key
end


local partial_class = {}

---partial dest_class will inherit methods from source_class, and recorded in partial_class
---@param dest_class table
---@param source_class table
function _M.partial(dest_class, source_class)
	local dest_class_file, err = _M.get_source_filepath(dest_class)
	if err then
		return nil, err
	end
	local info = partial_class[dest_class_file]
	if not info then
		info = {}
		partial_class[dest_class_file] = info
	end
	local from_class_file, err = _M.get_source_filepath(source_class)
	if from_class_file then
		info[from_class_file] = true
		for key, val in pairs(source_class) do
			if type(val) == 'function' then
				dest_class[key] = val
			end
		end
	end
	return info, partial_class
end

---get_source_filepath get the full path of `class` object source, only the first matched file returned
---@param class table
---@return string @ full filepath
function _M.get_source_filepath(class)
	local filename
	if type(class) ~= 'table' then
		return nil, 'bad class input'
	end
	for key, val in pairs(class) do
		if type(val) == 'function' then
			local fi = _M.parse_func(val)
			if fi and fi.what == 'Lua' and fi.short_src then
				filename = fi.short_src
				break
			end
		end
	end
	if not filename then
		return nil, 'not a valid class, at least 1 public method definition required!'
	end
	return filename
end


---get_call_path
---@param stack_level string @ stack_level to ingore
---@param is_short_path boolean @ the result contains full path or just filename
function _M.get_call_path(stack_level, is_short_path)
	local nc, m, err, iterator = 4
	stack_level = stack_level or 2
	local msg = debug.traceback('debug', stack_level)
	if not msg then
		msg = debug.traceback('debug', stack_level - 1)
	end
	if is_short_path then
		iterator = gmatch(msg, [[(\w[\w]+\.+lua:\d+:) in function ('(\w+)'|<)]], 'jo')
	else
		iterator = gmatch(msg, [[(\w[\w\\\/\.]+\.+lua:\d+:) in function ('(\w+)'|<)]], 'jo')
	end
	local sb = sbuffer()
	while (nc > 0) do
		m, err = iterator()
		if m then
			if nc < 4 then
				sb:add(m[1], (m[3] and m[3] .. '()' or '()'), ' <= ')
			end
		else
			break
		end
		nc = nc - 1
	end
	return sb:pop():tos()
end

function _M.main()

end

return _M

---@class function.info
---@field currentline number
---@field isvararg boolean
---@field lastlinedefined number
---@field linedefined number @native
---@field lua_name string @ class_name/method_name
---@field name string @ method name
---@field namewhat string @ C/lua
---@field nparams number @native
---@field nups number @native
---@field param string @ formatted parameters string
---@field returns string @ results description to return
---@field short_src string @ the relative source code path
---@field source string @ the source code path and line
---@field what string @ code type C /Lua
---@field params string[] @parameter name list
---@field func fun @the function to call