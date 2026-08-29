-- Reset the built-in admin password from AUTHZ_ADMIN_PASSWORD.
--
-- This file intentionally does not require resty.authz.db: that module uses
-- ngx.shared and is only valid inside an OpenResty worker.  The container
-- command must be able to update the same SQLite database from `docker exec`.

local ffi = require "ffi"
local hmac = require "resty.hmac"

ffi.cdef[=[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
typedef long long sqlite3_int64;
int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close_v2(sqlite3 *db);
int sqlite3_busy_timeout(sqlite3 *db, int ms);
int sqlite3_exec(sqlite3 *db, const char *sql,
                 int (*callback)(void*, int, char**, char**),
                 void *, char **errmsg);
int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte,
                       sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_step(sqlite3_stmt *stmt);
int sqlite3_finalize(sqlite3_stmt *stmt);
int sqlite3_bind_text(sqlite3_stmt *stmt, int idx, const char *value, int length,
                     void (*destructor)(void*));
int sqlite3_bind_int64(sqlite3_stmt *stmt, int idx, sqlite3_int64 value);
int sqlite3_column_int64(sqlite3_stmt *stmt, int col);
int sqlite3_changes(sqlite3 *db);
const char *sqlite3_errmsg(sqlite3 *db);
]=]

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101
local SQLITE_OPEN_READWRITE = 0x02
local SQLITE_OPEN_CREATE = 0x04
local SQLITE_OPEN_FULLMUTEX = 0x10000
local TRANSIENT = ffi.cast("void (*)(void*)", -1)
local sqlite = ffi.load("libsqlite3.so.0")

local function fail(message)
    io.stderr:write("admin_password_reset: " .. message .. "\n")
    os.exit(1)
end

local function db_error(db, prefix)
    return prefix .. ": " .. ffi.string(sqlite.sqlite3_errmsg(db))
end

local function exec(db, sql)
    local error_message = ffi.new("char *[1]")
    local rc = sqlite.sqlite3_exec(db, sql, nil, nil, error_message)
    if rc ~= SQLITE_OK then
        local message = error_message[0] ~= nil and ffi.string(error_message[0]) or
            ffi.string(sqlite.sqlite3_errmsg(db))
        return nil, message
    end
    return true
end

local function bind_text(statement, index, value)
    return sqlite.sqlite3_bind_text(statement, index, value, #value, TRANSIENT) == SQLITE_OK
end

local function hash_password(password, salt)
    local function hex(value)
        return (value:gsub(".", function(byte)
            return string.format("%02x", string.byte(byte))
        end))
    end

    local mac = hmac:new(salt, hmac.ALGOS.SHA256)
    if not mac then return nil, "hmac init failed" end
    local digest = mac:final(password)
    if not digest then return nil, "hmac failed" end
    for _ = 2, 5000 do
        local next_mac = hmac:new(salt, hmac.ALGOS.SHA256)
        if not next_mac then return nil, "hmac init failed" end
        digest = next_mac:final(digest)
        if not digest then return nil, "hmac failed" end
    end
    return hex(digest)
end

local function random_hex(bytes)
    local file, err = io.open("/dev/urandom", "rb")
    if not file then return nil, err end
    local value = file:read(bytes)
    file:close()
    if not value or #value ~= bytes then return nil, "unable to read random bytes" end
    return (value:gsub(".", function(byte)
        return string.format("%02x", string.byte(byte))
    end))
end

local database_path = os.getenv("AUTHZ_DB_PATH") or "/data/authz/authz.db"
local password = os.getenv("AUTHZ_ADMIN_PASSWORD")
if not password or password == "" then fail("AUTHZ_ADMIN_PASSWORD is not set") end
if #password < 6 then fail("AUTHZ_ADMIN_PASSWORD must contain at least 6 characters") end

local database = ffi.new("sqlite3 *[1]")
local rc = sqlite.sqlite3_open_v2(
    database_path, database,
    SQLITE_OPEN_READWRITE + SQLITE_OPEN_CREATE + SQLITE_OPEN_FULLMUTEX,
    nil)
if rc ~= SQLITE_OK then fail("cannot open database " .. database_path) end
local db = database[0]
sqlite.sqlite3_busy_timeout(db, 5000)

local function close_and_fail(message)
    sqlite.sqlite3_close_v2(db)
    fail(message)
end

local statement = ffi.new("sqlite3_stmt *[1]")
rc = sqlite.sqlite3_prepare_v2(db, "SELECT id FROM users WHERE username = 'admin'", -1, statement, nil)
if rc ~= SQLITE_OK then close_and_fail(db_error(db, "cannot inspect admin account")) end
local step_rc = sqlite.sqlite3_step(statement[0])
local admin_exists = step_rc == SQLITE_ROW
sqlite.sqlite3_finalize(statement[0])
if not admin_exists then close_and_fail("admin account does not exist") end

local salt, salt_err = random_hex(16)
if not salt then close_and_fail("cannot generate password salt: " .. tostring(salt_err)) end
local password_hash, hash_err = hash_password(password, salt)
if not password_hash then close_and_fail("cannot hash password: " .. tostring(hash_err)) end

local ok, err = exec(db, "BEGIN IMMEDIATE")
if not ok then close_and_fail(db_error(db, "cannot lock database")) end

local function rollback_and_fail(message)
    exec(db, "ROLLBACK")
    close_and_fail(message)
end

rc = sqlite.sqlite3_prepare_v2(db, [[UPDATE users
    SET password_hash = ?, salt = ?, updated_at = strftime('%s', 'now')
    WHERE username = 'admin']], -1, statement, nil)
if rc ~= SQLITE_OK then rollback_and_fail(db_error(db, "cannot prepare password update")) end
if not bind_text(statement[0], 1, password_hash) or not bind_text(statement[0], 2, salt) then
    sqlite.sqlite3_finalize(statement[0])
    rollback_and_fail("cannot bind password update")
end
step_rc = sqlite.sqlite3_step(statement[0])
sqlite.sqlite3_finalize(statement[0])
if step_rc ~= SQLITE_DONE or sqlite.sqlite3_changes(db) ~= 1 then
    rollback_and_fail(db_error(db, "password update failed"))
end

ok, err = exec(db, "DELETE FROM sessions WHERE username = 'admin' AND source = 'local'")
if not ok then rollback_and_fail(db_error(db, "cannot invalidate admin sessions")) end
ok, err = exec(db, "COMMIT")
if not ok then rollback_and_fail(db_error(db, "cannot commit password update")) end

sqlite.sqlite3_close_v2(db)
io.stdout:write("admin password reset from AUTHZ_ADMIN_PASSWORD\n")
