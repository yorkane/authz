---@class _M
---@field buffer string[] @ buffer array for string
local _M = {}
local new_tab = require("table.new")
local ins, concat, remove, tsort, tostring = table.insert, table.concat, table.remove, table.sort, tostring
local select, type, setmetatable = select, type, setmetatable

local function merge_arr(buffer, obj)
    local tp = type(obj)
    if tp == "table" then
        if obj.buffer and obj.buffer[1] then
            for n = 1, #obj.buffer do
                ins(buffer, obj.buffer[n])
            end
        elseif obj[1] then
            for n = 1, #obj do
                ins(buffer, obj[n])
            end
        end
    elseif tp ~= "function" and tp ~= "cdata" then
        ins(buffer, obj)
    end
end

---to_array convert a dictionary or bad array to a well formatted array
---@param tab table@ dictionary or bad array
---@return table<number, table|string>
local function to_array(...)
    local len = select("#", ...)
    local tb = new_tab(len, 0)
    for i = 1, len do
        local val = select(i, ...)
        merge_arr(tb, val)
    end
    return tb
end

_M.to_array = to_array
local function tos(self, splitor)
    return concat(self.buffer, splitor)
end

---add @add multiple string args. :add(1,2,nil,'4',5) =1,2
---@return _M
local function add(self, ...)
    local len = select("#", ...)
    for i = 1, len do
        local val = select(i, ...)
        merge_arr(self.buffer, tostring(val))
    end
    return self
end

local mt = {__index = _M, __call = add, __tostring = tos}

---new @create new stringbuffer
---@return _M
function _M.new(...)
    local sbs = {
        buffer = to_array(...)
    }
    setmetatable(sbs, mt)
    return sbs
end

setmetatable(
    _M,
    {
        __call = function(self, ...)
            return _M.new(...)
        end
    }
)


_M.add = add
_M.tos = tos

---pop @remove buffer elements at tail poistion
---@param count number @element count to remove at tail position
---@return _M
function _M:pop(count)
    count = count or 1
    local len = #self.buffer
    for i = 1, count do
        remove(self.buffer, len)
        len = len - 1
    end
    return self
end



function _M.main()
    local sb = _M("1", 2, 3, 4)
    sb:add('5',6,7,8,'90')
    sb('a',1,2,3)
    sb:pop(2)
    assert(tostring(sb) == '1234567890a1')
    local sb1 = _M.new('abc',sb)
    sb1(2,34)
    assert(tostring(sb1) == 'abc1234567890a1234')
    -- require('lib.klib.dump').dump_lua({1,2,3,4})
end
return _M
