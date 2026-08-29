local _M = {}

_M.current = [[
CREATE TABLE IF NOT EXISTS users(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  salt TEXT NOT NULL,
  roles TEXT NOT NULL DEFAULT 'user',
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  last_login_at INTEGER,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions(
  token TEXT PRIMARY KEY,
  username TEXT NOT NULL,
  source TEXT NOT NULL DEFAULT 'local',
  csrf TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS remote_users(
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
);
CREATE TABLE IF NOT EXISTS policies(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  ptype TEXT NOT NULL,
  v0 TEXT NOT NULL,
  v1 TEXT NOT NULL DEFAULT '*',
  v2 TEXT NOT NULL DEFAULT '*',
  UNIQUE(ptype, v0, v1, v2)
);
CREATE TABLE IF NOT EXISTS bindings(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  domain TEXT UNIQUE NOT NULL,
  target_ip TEXT NOT NULL DEFAULT '127.0.0.1',
  port INTEGER NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  websocket INTEGER NOT NULL DEFAULT 0,
  note TEXT NOT NULL DEFAULT '',
  menu_name TEXT NOT NULL DEFAULT '',
  upstream_host TEXT NOT NULL DEFAULT '',
  forwarded_host TEXT NOT NULL DEFAULT '',
  forwarded_proto TEXT NOT NULL DEFAULT '',
  forwarded_port INTEGER NOT NULL DEFAULT 0,
  origin_mode TEXT NOT NULL DEFAULT 'auto',
  custom_origin TEXT NOT NULL DEFAULT '',
  simulate_local INTEGER NOT NULL DEFAULT 0,
  local_ip TEXT NOT NULL DEFAULT '127.0.0.1',
  upstream_scheme TEXT NOT NULL DEFAULT 'http',
  upstream_ssl_verify INTEGER NOT NULL DEFAULT 1,
  upstream_path TEXT NOT NULL DEFAULT '',
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS api_keys(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT UNIQUE NOT NULL,
  token_hash TEXT UNIQUE NOT NULL,
  role TEXT NOT NULL DEFAULT 'api',
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS menu_entries(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL DEFAULT 'item',
  parent_id INTEGER,
  label TEXT NOT NULL,
  url TEXT NOT NULL,
  icon TEXT NOT NULL DEFAULT '',
  builtin TEXT NOT NULL DEFAULT '',
  admin_only INTEGER NOT NULL DEFAULT 0,
  sort_order INTEGER NOT NULL DEFAULT 0,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
]]

return _M
