local nfind, nsub, type, pcall, tostring, pairs, require = ngx.re.find, ngx.re.gsub, type, pcall, tostring, pairs, require
local nmatch, gmatch, byte, char = ngx.re.match, ngx.re.gmatch, string.byte, string.char
local sfind, ssub, lower, rep = string.find, string.sub, string.lower, string.rep
local say, print = ngx.say, ngx.print
local klass = require('klib.klass')
local sbuffer = require('klib.sbuffer')
local ins, concat, tsort = table.insert, table.concat, table.sort
local function hash(n)
	return table.new(0, n)
end
local function array(n)
	return table.new(n, 0)
end

---get_sort_keys get all keys within table and sorted by ASCII and value type
---@param hash_obj table<string, table|boolean|string|number>
---@return string[]
local function get_sort_keys(hash_obj)
	local arr = array(20)
	for key, _ in pairs(hash_obj) do
		ins(arr, key)
	end
	tsort(arr, function(a, b)
		local val1 = type(hash_obj[a])
		local val2 = type(hash_obj[b])
		if val2 == 'function' and val1 ~= 'function' then
			return true
		end
		if val1 == 'function' and val2 ~= 'function' then
			return false
		end
		if val1 == 'table' and val2 ~= 'table' then
			return false
		end
		if val2 == 'table' and val1 ~= 'table' then
			return true
		end
		val1 = type(a)
		val2 = type(b)
		if val1 == 'number' and val2 ~= 'number' then
			return true
		end

		if val1 == 'number' and val2 == 'number' then
			return b > a
		end
		if val2 == 'number' then
			return
		end
		if val1 ~= 'string' then
			return
		end
		if val2 ~= 'string' then
			return true
		end
		for i = 1, #b do
			val1 = byte(a, i, i)
			val2 = byte(b, i, i)
			if val1 then
				if val2 ~= val1 then
					return val2 > val1
				end
			else
				return true
			end
		end
	end)
	return arr
end
local key_words = { ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true, ["while"] = true, }

local wid = ngx.worker.id() or 0
local code_content_map = {}

---@class klib.dump
local _M = {}

local root = ngx.config.prefix()

if not root or #root < 5 or sfind(lower(root), 'te*mp/') then
	local ok, lfs = pcall(require, 'lfs_ffi')
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
		return text
	end
end

---dump print out all info within inputs, IF YOU WANT ALL HIERARCHY INFO, PLEASE CALL parse_hierarchy to get full detailed info
function _M.dump(...)
	local len = select('#', ...)
	for i = 1, len do
		local item = select(i, ...)
		if type(item) == 'table' then
			say(_M.dump_lua(klass.parse_hierarchy(item)))
		else
			say(_M.dump_lua(item))
		end
	end
end

function _M.dump_dict(name)
	---@type ngx.shared.DICT
	local dict = ngx.shared[name]
	local res = hash(100)
	if dict then
		local keys = dict:get_keys()
		for i = 1, #keys do
			local key = keys[i]
			res[key] = dict:get(key)
		end
	end
	return res
end

function _M.logs(...)
	local len = select("#", ...)
	local sb = sbuffer()
	local ok, info = pcall(klass.get_call_path, 3)
	for i = 1, len do
		local val = select(i, ...)
		local tp = type(val)
		if tp == 'table' then
			sb:add(_M.dump_lua(val, i))
		elseif tp == 'function' then
			local fi = klass.parse_func(val, false)
			sb:add('function(' .. fi.param .. [[) end'\t\t-- ]] .. fi.source .. '\n')
		else
			sb:add(val)
		end
	end

	ngx.log(ngx.WARN, wid .. '/' .. ngx.worker.count(), '\n' .. info .. '\n', sb:tos('\n') .. '\n')
	return info
end

function _M.dump_doc(obj, class_name, sb, is_partial, is_getter_setter)
	local obj_to_parse
	class_name = class_name or 'tables'
	if is_partial then
		sb = sb or sbuffer('\n---@class ', class_name, '\n')
		obj_to_parse = obj
	else
		obj_to_parse = klass.parse_hierarchy(obj)
		sb = sb or sbuffer()
		sb:add('\n---@class ', class_name, '\n')
	end

	local tp
	if type(obj_to_parse) ~= 'table' then
		return nil, 'table object required'
	end
	local sub_class = {}
	local arr = get_sort_keys(obj_to_parse)
	for i = 1, #arr do
		local key = arr[i]
		local var = obj_to_parse[key]
		if nfind(key, [[(getter|setter)]], 'joi') then
			if not sfind(key, 'setter', 1, true) then
				_M.dump_doc(var, class_name, sb, true, true)
			end
			--ngx.say('======>', key)
		else
			sb:add('---@field ', key, ' ')
			tp = type(var)
			if tp == 'table' then
				sub_class[key] = var
				sb:add(class_name .. '.' .. key, '\n')
			else
				if tp == 'function' then
					local fi = klass.parse_func(var, nil, nil, class_name)
					if is_getter_setter then
						sb:add(' ' .. (fi.returns and fi.returns or '') .. '  @ ' .. fi.source .. '\n')
					else
						sb:add('fun (' .. fi.param .. ')' .. (fi.returns and ':' .. fi.returns or '') .. '  @ ' .. fi.source .. '\n')
					end
					--sb:add('fun (self, arg:string):string\n')
				else
					sb:add(tp, '\n')
				end
			end
		end
	end

	for i, v in pairs(sub_class) do
		_M.dump_doc(v, class_name .. '.' .. i, sb)
	end
	return sb:tos()
end

local function get_key(key)
	if key_words[key] then
		return '["' .. key .. '"]'
	end
	return key
end
function _M.dump_lua(obj, name, sb, indent_depth)
	local is_root, indent = false, ''
	if not sb then
		sb = sbuffer('\n')
		is_root = true
		indent_depth = 0

	end
	name = name or ''
	if indent_depth then
		name = get_key(name)
	end
	if indent_depth > 13 then
		-- ignore too deep object hierarchy
		return sb
	end
	--if indent_depth > 2 and sfind(name, '__', 1, true) == 1 then
	--	return sb
	--end
	if indent_depth > 0 then
		indent = string.rep('\t', indent_depth)
	end
	local obj_type = type(obj)
	if obj_type == 'table' and (name == '__class' or name == '__index' or name == '__metatable' or name == '__base' or name == '_M') then
		sb:add(indent, name, ' = "ClassHierarchy"')
		return sb
	end
	-- name = name or debug.getinfo(2).namewhat
	if (name ~= '') then
		if type(name) == 'number' then
			--sb:add(indent,'[', name, '] = {\n')
			sb:add(indent, '{\n')
		else
			sb:add(indent, name, ' = {\n')
		end
	else
		sb:add(indent, '{\n')
	end
	if obj_type ~= 'table' then
		return '\n\t' .. name .. ' = ' .. tostring(obj) .. '\n'
	end
	local arr = get_sort_keys(obj)
	for i = 1, #arr do
		local key = arr[i]
		local var = obj[key]
		local tps = type(key)
		key = tostring(key)
		if tps == 'number' then
			key = '[' .. key .. ']'
		elseif nfind(key, [[(^\d+)|(\W+)]], 'jo') or key_words[key] then
			key = '["' .. key .. '"]'
		end
		tps = type(var)
		if tps == 'function' then
			local fi = klass.parse_func(var)
			sb:add('\t', indent, key, ' = function(', fi.param, ') end,', indent, '\t\t\t-- ', fi.source, '\n')
		elseif tps == 'table' then
			_M.dump_lua(var, key, sb, indent_depth + 1)
			sb:add(',\n')
		elseif tps == 'string' then
			sb:add('\t', indent, key, ' = "', var, '",\n')
		elseif tps == 'userdata' then
			sb:add('\t', indent, key, ' = "', var, '",\n')
		else
			if key == '_char_' then
				sb:add('\t', indent, key, ' = "', var, ':', char(var), '",\n')
			else
				sb:add('\t', indent, key, ' = ', tostring(var), ',\n')
			end
		end
	end

	sb:add(indent, '}')
	if is_root then
		local str = sb:tos();
		str = nsub(str, [[\},(\s+\},)]], '}$1', 'jo') --remove it code still work
		str = nsub(str, [[,(\s+})]], '$1', 'jo') --remove it code still work
		str = nsub(str, [[([,"\w])[ \t]+([}{])]], '$1$2', 'jo') --remove it code still work
		str = nsub(str, [[\{([^\n\w]+)\[]], '{\n$1[', 'jo') --remove it code still work
		return str
	end
end

function _M.dump_class(obj, name, sb, indent_depth)
	obj = klass.parse_hierarchy(obj)
	local is_root, indent = false, ''
	if not sb then
		sb = sbuffer('\n')
		is_root = true
		indent_depth = 0
	end
	name = name or 'LUAOBJ'
	if indent_depth > 0 then
		indent = rep('\t', indent_depth)
	end
	if (name ~= '') then
		sb:add('\n---@class ', name, '\n', name, ' = {}\n')
	else
		--sb:add(indent, '{\n')
	end
	for key, var in pairs(obj) do
		if key then
			local tps = type(var)
			if tps == 'function' then
				local fi = klass.parse_func(var)
				sb:add('\n---@param arg string\n---@return string @type\n')
				sb:add('function ', name, ':', key, '(', fi.param, ') end', '\t\t\t-- ', root, fi.source, '\n')
			elseif tps == 'table' then
				if #var ~= 0 then
					if type(var[1]) == 'string' then
						sb:add(name, '.', key, ' = {"', concat(var, '", "'), '"', '}\n')
					elseif type(var[1]) == 'number' then
						sb:add(name, '.', key, ' = {', concat(var, ', '), '},\n')
					else
						sb:add(name, '.', key, ' = {\n')
						for i = 1, #var do
							sb:add('', _M.dump_lua(var[i], '', sb, indent_depth))
							sb:add(',\n')
						end
						sb:add('\t', indent, '}\n')
					end
				else
					--sb:add(name, '.')
					_M.dump_class(var, name .. '.' .. key, sb, indent_depth)
					sb:add('\n')
				end
			elseif tps == 'number' then
				--sb:add(name, '.', key, ' = ', tostring(var), '\n')
			else
				--sb:add(name, '.', key, ' = "', tostring(var), '"\n')
			end
		end
	end
	sb:add('\n')
	if is_root then
		local str = sb:tos();
		str = nsub(str, [[\},(\s+\},)]], '}$1') --remove it code still work
		str = nsub(str, [[,(\s+})]], '$1') --remove it code still work
		return str
	end
end

---dump_wrap_of generate a new class for wrapping class_obj up
---@param class_obj table
---@param class_name string
function _M.dump_wrap_of(class_obj, class_name)
	local path, err = klass.get_source_filepath(class_obj)
	if err then
		return nil, err
	end
	local txt = read_file(path)
	if not txt then
		return nil, 'source code file not exist'
	end
	--dump(root, #root)
	local lua_name = nsub(ssub(path, #root + 1, #path - 4), [[/]], [[.]], 'jo')
	class_name = class_name or lua_name
	local output
	local sb = sbuffer('local base = require("', lua_name, '")')
	sb:add('\n\n---@class ', class_name, ' @wrap of ', lua_name)
	sb:add('local _M = {}\n', 'setmetatable(_M, { __index = base })\n\n')
	local reg = [[--+([a-z]+[\w_]+)[ \t@]*([^\n\r]*)[\n\r]+(---@param[^\r\n]+[\n\r]+)*(---@return([\w\._,\[\] \|]*)[@ \t]*([^\r\n]*)[\n\r]+)*.+(function)*[^\r\n\.:]+(\.|:)?\1([\t= ]+function)*[\t ]*\(([\w, ]*)\)]]
	local it = gmatch(txt, reg, 'jio')
	if not it then
		return nil, 'no matched function found'
	end

	--return it()
	while true do
		local m, err = it()
		if not m then
			break
		end
		local code = m[0]
		--local args = nsub(m[10], [[^\w+,]], '', 'jio')

		sb:add(code, '\n\tlocal res, err = base.', m[1], '(self, ', m[10], ')\n')
		sb:add('\treturn res, err', '\nend\n', '\n')
	end
	return sb:tos()
end


---dump_yaml
---@param table
function _M.dump_yaml(obj)
	local str = _M.dump_lua(obj)
	str = ssub(str, 2, -2)
	--str = nsub(str, [[\["?([^\]"]+)"?\] =]], '$1:', 'jo')
	str = nsub(str, [[\["?([^\]"]+)"?\] = "?([^\n]+)"?\n]], '$1: $2\n', 'jo')
	str = nsub(str, [[ = "?([^\n]+)"?\n]], ': $1\n', 'jo')
	--str = nsub(str, [["? = "?]], ': ', 'jo')
	str = nsub(str, [[\t+\{ *\},|\[ *\],]], '~', 'jo')
	str = nsub(str, [[\t+[\]\}],?\n]], '', 'jo')
	str = nsub(str, [[[",\[\{]+\n]], '\n', 'jo')
	str = nsub(str, [[(\t+)(\w+\n)]], '$1- $2', 'jo')
	str = nsub(str, [[\n\t(\t*)}?]], '\n$1', 'jo')
	str = nsub(str, [[\t]], ' ', 'jo')
	return str
end

---global make dump, dump_class, dump_lua, logs, dump_dict global variable
--- WARNING this method will cause massive warning logs in openresty
function _M.global()
	if not _G['dump'] then
		rawset(_G, 'dump', _M.dump)
	end
	if not _G['dump_class'] then
		rawset(_G, 'dump_class', _M.dump_class)
	end
	if not _G['logs'] then
		rawset(_G, 'logs', _M.logs)
	end
	if not _G['dump_lua'] then
		rawset(_G, 'dump_lua', _M.dump_lua)
	end
	if not _G['dump_doc'] then
		rawset(_G, 'dump_doc', _M.dump_doc)
	end
	if not _G['dump_dict'] then
		rawset(_G, 'dump_dict', _M.dump_dict)
	end
	if not _G['dump_yaml'] then
		rawset(_G, 'dump_yaml', _M.dump_yaml)
	end
	return _M, _M.logs, _M.dump_class, _M.dump_lua, _M.dump_doc, _M.dump_dict
end

---locally `local dump, logs, dump_class,dump_lua, dump_doc, dump_dict = require('klib.dump').locally()`
---@return klib.dump,fun,fun,fun,fun,fun @ `local dump, logs, dump_class,dump_lua,dump_dict = require('klib.dump').locally()`
function _M.locally()
	return _M, _M.logs, _M.dump_class, _M.dump_lua, _M.dump_doc, _M.dump_dict, _M.dump_yaml
end

setmetatable(_M, {
	__call = function(_M, ...)
		return _M.dump(...)
	end
})

function _M.main()
	-- _M.dump({k=1, a={1,2,3,4}})
end

return _M
