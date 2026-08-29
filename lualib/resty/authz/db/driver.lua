-- Low-level SQLite FFI driver. This module owns the worker-local connection
-- and deliberately knows nothing about schema, migrations, caching or authz.

local ffi = require "ffi"

ffi.cdef[[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef long long sqlite3_int64;
int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close_v2(sqlite3 *db);
int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte,
                       sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_step(sqlite3_stmt *stmt);
int sqlite3_finalize(sqlite3_stmt *stmt);
int sqlite3_column_count(sqlite3_stmt *stmt);
const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int iCol);
sqlite3_int64 sqlite3_column_int64(sqlite3_stmt *stmt, int iCol);
int sqlite3_column_type(sqlite3_stmt *stmt, int iCol);
const char *sqlite3_column_name(sqlite3_stmt *stmt, int iCol);
int sqlite3_bind_text(sqlite3_stmt *stmt, int idx, const char *val, int n, void (*fp)(void*));
int sqlite3_bind_int64(sqlite3_stmt *stmt, int idx, sqlite3_int64 val);
int sqlite3_bind_null(sqlite3_stmt *stmt, int idx);
int sqlite3_bind_parameter_count(sqlite3_stmt *stmt);
const char *sqlite3_errmsg(sqlite3 *db);
]]

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101
local SQLITE_INTEGER = 1
local SQLITE_NULL = 5
local SQLITE_OPEN_FLAGS = 0x02 + 0x04 + 0x10000
local TRANSIENT = ffi.cast("void (*)(void*)", -1)

local lib = ffi.load("libsqlite3.so.0")
local conn
local _M = {}

local function errmsg(db)
    local value = lib.sqlite3_errmsg(db)
    return value ~= nil and ffi.string(value) or "unknown sqlite error"
end

local function bind_params(stmt, params)
    -- 用参数总数显式遍历，nil 值绑定为 SQL NULL（ipairs 会在首个 nil 处提前截断）。
    local count = lib.sqlite3_bind_parameter_count(stmt)
    for index = 1, count do
        local value = params[index]
        if value == nil then
            lib.sqlite3_bind_null(stmt, index)
        elseif type(value) == "number" then
            lib.sqlite3_bind_int64(stmt, index, value)
        else
            local text = tostring(value)
            lib.sqlite3_bind_text(stmt, index, text, #text, TRANSIENT)
        end
    end
end

function _M.open(path)
    if conn then return conn end
    local pointer = ffi.new("sqlite3*[1]")
    local rc = lib.sqlite3_open_v2(path, pointer, SQLITE_OPEN_FLAGS, nil)
    if rc ~= SQLITE_OK then
        error("sqlite open failed: " .. path .. " rc=" .. tostring(rc))
    end
    conn = pointer[0]
    assert(_M.exec("PRAGMA journal_mode=WAL"))
    assert(_M.exec("PRAGMA busy_timeout=5000"))
    return conn
end

function _M.close()
    if conn then
        lib.sqlite3_close_v2(conn)
        conn = nil
    end
end

function _M.is_open()
    return conn ~= nil
end

function _M.exec(sql, params)
    if not conn then return nil, "db not opened" end
    local pointer = ffi.new("sqlite3_stmt*[1]")
    local rc = lib.sqlite3_prepare_v2(conn, sql, #sql, pointer, nil)
    if rc ~= SQLITE_OK then return nil, errmsg(conn) end
    local stmt = pointer[0]
    bind_params(stmt, params or {})
    rc = lib.sqlite3_step(stmt)
    lib.sqlite3_finalize(stmt)
    if rc == SQLITE_DONE or rc == SQLITE_ROW then return true end
    return nil, errmsg(conn)
end

function _M.query(sql, params)
    if not conn then return nil, "db not opened" end
    local pointer = ffi.new("sqlite3_stmt*[1]")
    local rc = lib.sqlite3_prepare_v2(conn, sql, #sql, pointer, nil)
    if rc ~= SQLITE_OK then return nil, errmsg(conn) end
    local stmt = pointer[0]
    bind_params(stmt, params or {})
    local rows = {}
    while lib.sqlite3_step(stmt) == SQLITE_ROW do
        local row = {}
        local column_count = lib.sqlite3_column_count(stmt)
        for column = 0, column_count - 1 do
            local value_type = lib.sqlite3_column_type(stmt, column)
            local name_pointer = lib.sqlite3_column_name(stmt, column)
            if value_type ~= SQLITE_NULL and name_pointer ~= nil then
                local name = ffi.string(name_pointer)
                if value_type == SQLITE_INTEGER then
                    row[name] = tonumber(lib.sqlite3_column_int64(stmt, column))
                else
                    local value_pointer = lib.sqlite3_column_text(stmt, column)
                    row[name] = value_pointer ~= nil and ffi.string(value_pointer) or ""
                end
            end
        end
        rows[#rows + 1] = row
    end
    lib.sqlite3_finalize(stmt)
    return rows
end

return _M
