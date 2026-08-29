-- Ordered, idempotent SQLite migrations. A fresh database and every legacy
-- schema converge through the same version ledger.

local schema = require "resty.authz.db.schema"

local _M = {}

local function must(ok, err)
    if not ok then error(tostring(err or "database migration failed")) end
end

local function has_column(db, table_name, column_name)
    local columns = db.query("PRAGMA table_info(" .. table_name .. ")") or {}
    for _, column in ipairs(columns) do
        if column.name == column_name then return true end
    end
    return false
end

local function ensure_column(db, table_name, column_name, definition)
    if has_column(db, table_name, column_name) then return end
    must(db.exec("ALTER TABLE " .. table_name .. " ADD COLUMN " .. definition))
end

_M.list = {
    {
        version = 1,
        name = "create_current_schema",
        up = function(db)
            for statement in schema.current:gmatch("[^;]+") do
                statement = statement:match("^%s*(.-)%s*$")
                if statement and statement ~= "" then must(db.exec(statement)) end
            end
        end,
    },
    {
        version = 2,
        name = "upgrade_legacy_columns_and_timestamps",
        up = function(db)
            ensure_column(db, "sessions", "source", "source TEXT NOT NULL DEFAULT 'local'")
            ensure_column(db, "users", "last_login_at", "last_login_at INTEGER")
            ensure_column(db, "users", "updated_at", "updated_at INTEGER NOT NULL DEFAULT 0")
            ensure_column(db, "remote_users", "remote_roles", "remote_roles TEXT NOT NULL DEFAULT ''")
            ensure_column(db, "remote_users", "roles_overridden",
                "roles_overridden INTEGER NOT NULL DEFAULT 0")
            ensure_column(db, "remote_users", "created_at", "created_at INTEGER NOT NULL DEFAULT 0")
            ensure_column(db, "remote_users", "last_login_at", "last_login_at INTEGER")
            ensure_column(db, "remote_users", "updated_at", "updated_at INTEGER NOT NULL DEFAULT 0")
            ensure_column(db, "bindings", "menu_name", "menu_name TEXT NOT NULL DEFAULT ''")
            ensure_column(db, "bindings", "websocket", "websocket INTEGER NOT NULL DEFAULT 0")
            ensure_column(db, "bindings", "target_ip", "target_ip TEXT NOT NULL DEFAULT '127.0.0.1'")
            ensure_column(db, "bindings", "upstream_host", "upstream_host TEXT NOT NULL DEFAULT ''")
            ensure_column(db, "bindings", "forwarded_host", "forwarded_host TEXT NOT NULL DEFAULT ''")
            ensure_column(db, "bindings", "forwarded_proto", "forwarded_proto TEXT NOT NULL DEFAULT ''")
            ensure_column(db, "bindings", "forwarded_port", "forwarded_port INTEGER NOT NULL DEFAULT 0")
            ensure_column(db, "bindings", "origin_mode", "origin_mode TEXT NOT NULL DEFAULT 'auto'")
            ensure_column(db, "bindings", "custom_origin", "custom_origin TEXT NOT NULL DEFAULT ''")
            ensure_column(db, "bindings", "simulate_local", "simulate_local INTEGER NOT NULL DEFAULT 0")
            ensure_column(db, "bindings", "local_ip", "local_ip TEXT NOT NULL DEFAULT '127.0.0.1'")
            ensure_column(db, "bindings", "upstream_scheme", "upstream_scheme TEXT NOT NULL DEFAULT 'http'")
            ensure_column(db, "bindings", "upstream_ssl_verify",
                "upstream_ssl_verify INTEGER NOT NULL DEFAULT 1")
            local legacy_path = has_column(db, "bindings", "upstream_path_prefix")
            ensure_column(db, "bindings", "upstream_path", "upstream_path TEXT NOT NULL DEFAULT ''")
            if legacy_path then
                must(db.exec([[UPDATE bindings SET upstream_path = upstream_path_prefix
                    WHERE upstream_path = '' AND upstream_path_prefix <> '']]))
            end
            must(db.exec("UPDATE remote_users SET remote_roles = roles WHERE remote_roles = ''"))
            must(db.exec("UPDATE users SET updated_at = created_at WHERE updated_at = 0"))
            must(db.exec([[UPDATE remote_users SET
                created_at = CASE WHEN created_at = 0 THEN synced_at ELSE created_at END,
                last_login_at = COALESCE(last_login_at, synced_at),
                updated_at = CASE WHEN updated_at = 0 THEN synced_at ELSE updated_at END]]))
        end,
    },
    {
        version = 3,
        name = "expand_api_key_role_catalog",
        up = function(db)
            local rows = db.query([[SELECT sql FROM sqlite_master
                WHERE type = 'table' AND name = 'api_keys']]) or {}
            local definition = tostring(rows[1] and rows[1].sql or "")
            if not definition:match("CHECK%s*%(%s*role%s*=%s*'api'%s*%)") then return end
            must(db.exec([[CREATE TABLE api_keys_role_catalog(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT UNIQUE NOT NULL,
                token_hash TEXT UNIQUE NOT NULL,
                role TEXT NOT NULL DEFAULT 'api',
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )]]))
            must(db.exec([[INSERT INTO api_keys_role_catalog
                (id, name, token_hash, role, enabled, created_at, updated_at)
                SELECT id, name, token_hash, role, enabled, created_at, updated_at FROM api_keys]]))
            must(db.exec("DROP TABLE api_keys"))
            must(db.exec("ALTER TABLE api_keys_role_catalog RENAME TO api_keys"))
        end,
    },
    {
        version = 4,
        name = "scope_remote_username_uniqueness_by_provider",
        up = function(db)
            local username_unique = false
            local indexes = db.query("PRAGMA index_list(remote_users)") or {}
            for _, index in ipairs(indexes) do
                if index["unique"] == 1 then
                    local index_name = tostring(index.name or ""):gsub('"', '""')
                    local columns = db.query('PRAGMA index_info("' .. index_name .. '")') or {}
                    if #columns == 1 and columns[1].name == "username" then
                        username_unique = true
                        break
                    end
                end
            end
            if not username_unique then return end
            must(db.exec([[CREATE TABLE remote_users_identity(
                provider TEXT NOT NULL,
                subject TEXT NOT NULL,
                username TEXT NOT NULL,
                roles TEXT NOT NULL,
                remote_roles TEXT NOT NULL DEFAULT '',
                roles_overridden INTEGER NOT NULL DEFAULT 0,
                enabled INTEGER NOT NULL DEFAULT 1,
                synced_at INTEGER NOT NULL,
                created_at INTEGER NOT NULL,
                last_login_at INTEGER,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY(provider, subject),
                UNIQUE(provider, username)
            )]]))
            must(db.exec([[INSERT INTO remote_users_identity
                (provider, subject, username, roles, remote_roles, roles_overridden, enabled, synced_at,
                    created_at, last_login_at, updated_at)
                SELECT provider, subject, username, roles, remote_roles, roles_overridden, enabled, synced_at,
                    created_at, last_login_at, updated_at FROM remote_users]]))
            must(db.exec("DROP TABLE remote_users"))
            must(db.exec("ALTER TABLE remote_users_identity RENAME TO remote_users"))
        end,
    },
    {
        version = 5,
        name = "canonicalize_policy_principals",
        up = function(db)
            must(db.exec([[DELETE FROM policies WHERE v0 NOT LIKE 'role:%' AND v0 NOT LIKE 'user:%'
                AND v0 NOT LIKE 'api-key:%'
                AND EXISTS(SELECT 1 FROM policies existing
                    WHERE existing.ptype = policies.ptype
                    AND existing.v0 = 'user:local:' || policies.v0
                    AND existing.v1 = policies.v1 AND existing.v2 = policies.v2)]]))
            must(db.exec([[UPDATE policies SET v0 = 'user:local:' || v0
                WHERE v0 NOT LIKE 'role:%' AND v0 NOT LIKE 'user:%'
                AND v0 NOT LIKE 'api-key:%']]))
        end,
    },
    {
        version = 6,
        name = "create_menu_entries",
        up = function(db)
            must(db.exec([[CREATE TABLE IF NOT EXISTS menu_entries(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                label TEXT NOT NULL,
                url TEXT NOT NULL,
                icon TEXT NOT NULL DEFAULT '',
                sort_order INTEGER NOT NULL DEFAULT 0,
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )]]))
        end,
    },
    {
        version = 7,
        name = "treeify_menu_entries_and_seed_layout",
        up = function(db)
            local function has_col(col)
                local cols = db.query("PRAGMA table_info(menu_entries)") or {}
                for _, c in ipairs(cols) do if c.name == col then return true end end
                return false
            end
            if not has_col("kind") then
                must(db.exec("ALTER TABLE menu_entries ADD COLUMN kind TEXT NOT NULL DEFAULT 'item'"))
            end
            if not has_col("parent_id") then
                must(db.exec("ALTER TABLE menu_entries ADD COLUMN parent_id INTEGER"))
            end
            if not has_col("builtin") then
                must(db.exec("ALTER TABLE menu_entries ADD COLUMN builtin TEXT NOT NULL DEFAULT ''"))
            end
            if not has_col("admin_only") then
                must(db.exec("ALTER TABLE menu_entries ADD COLUMN admin_only INTEGER NOT NULL DEFAULT 0"))
            end
            -- 幂等：已存在分组则视为已迁移，直接返回。
            local groups = db.query("SELECT COUNT(*) AS c FROM menu_entries WHERE kind = 'group'")
            if groups and groups[1] and (tonumber(groups[1].c) or 0) > 0 then return end
            local now = os.time()
            -- 1) 系统应用分组 + 内置页面条目（内置条目由前端按 builtin 映射到内嵌页面）。
            must(db.exec([[INSERT INTO menu_entries(
                kind, parent_id, label, url, icon, builtin, admin_only, sort_order, enabled, created_at, updated_at)
                VALUES('group', NULL, '系统应用', '', 'mdi-cog-outline', '', 0, 10, 1, ?, ?)]], now, now))
            local sys_rows = db.query("SELECT id FROM menu_entries WHERE kind = 'group' ORDER BY id DESC LIMIT 1")
            local sys_id = sys_rows and sys_rows[1] and sys_rows[1].id
            local seed = {
                { label = '用户与角色', icon = 'mdi-account-group-outline', builtin = 'users', admin_only = 0, sort_order = 11 },
                { label = '授权策略', icon = 'mdi-shield-key-outline', builtin = 'authorization', admin_only = 1, sort_order = 12 },
                { label = '菜单编辑', icon = 'mdi-menu-open', builtin = 'menuEditor', admin_only = 1, sort_order = 13 },
                { label = 'OmniScript 剧本展示', icon = 'mdi-movie-open-outline', builtin = 'omniscript', admin_only = 0, sort_order = 14 },
            }
            for _, item in ipairs(seed) do
                must(db.exec([[INSERT INTO menu_entries(
                    kind, parent_id, label, url, icon, builtin, admin_only, sort_order, enabled, created_at, updated_at)
                    VALUES('item', ?, ?, '', ?, ?, ?, ?, 1, ?, ?)]],
                    sys_id, item.label, item.icon, item.builtin, item.admin_only,
                    item.sort_order, now, now))
            end
            -- 2) 本机应用分组（builtin='local' 告诉前端在此注入动态发现的服务）。
            must(db.exec([[INSERT INTO menu_entries(
                kind, parent_id, label, url, icon, builtin, admin_only, sort_order, enabled, created_at, updated_at)
                VALUES('group', NULL, '本机应用', '', 'mdi-lan-connect', 'local', 0, 100, 1, ?, ?)]], now, now))
            local local_rows = db.query("SELECT id FROM menu_entries WHERE kind = 'group' ORDER BY id DESC LIMIT 1")
            local local_id = local_rows and local_rows[1] and local_rows[1].id
            -- 3) 存量扁平自定义条目（v6 遗留，无父级）迁移进“本机应用”分组。
            if local_id then
                must(db.exec([[UPDATE menu_entries
                    SET parent_id = ?, kind = 'item'
                    WHERE kind <> 'group' AND parent_id IS NULL]], local_id))
            end
        end,
    },
    {
        version = 8,
        name = "api_keys_loopback_only",
        up = function(db)
            local cols = db.query("PRAGMA table_info(api_keys)") or {}
            for _, c in ipairs(cols) do
                if c.name == "loopback_only" then return end
            end
            must(db.exec("ALTER TABLE api_keys ADD COLUMN loopback_only INTEGER NOT NULL DEFAULT 0"))
        end,
    },
}

function _M.run(db)
    must(db.exec([[CREATE TABLE IF NOT EXISTS schema_migrations(
        version INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        applied_at INTEGER NOT NULL
    )]]))
    local rows = db.query("SELECT version FROM schema_migrations") or {}
    local applied = {}
    for _, row in ipairs(rows) do applied[tonumber(row.version)] = true end
    for _, migration in ipairs(_M.list) do
        if not applied[migration.version] then
            local ok, err = db.transaction(function()
                migration.up(db)
                must(db.exec([[INSERT INTO schema_migrations(version, name, applied_at)
                    VALUES(?,?,?)]], migration.version, migration.name, os.time()))
                return true
            end)
            if not ok then
                error("migration " .. migration.version .. " (" .. migration.name .. ") failed: " ..
                    tostring(err))
            end
        end
    end
end

return _M
