# authz 登录后弹回登录页 — 现场取证报告（235.t / 2026-10-13）

结论：会话签发正常，cookie 下发逻辑正常，第三方 cookie 不是原因。

根因是共享会话存储 kvrocks（10.252.25.241:6379）RocksDB WAL 损坏，所有写命令返回
`ERR Corruption: WriteBatch has wrong count`，读命令正常。于是 235.t 每次登录只能把会话
落在本机 SQLite 镜像 + 待写队列（session_pending, op=save），永远进不了 Redis。APISIX 边缘
在 235.t(read-write) 与 241.t(read-only) 之间轮询，241.t 无本机镜像、只能读 Redis，判
not_found 后 401 并下发一组 Max-Age=0 清理 Set-Cookie，浏览器会话被删除，admin/app.js 的
401 分支 window.location.replace 到 /_authz/login。因为边缘轮询，症状表现为间歇性弹回。

## 关键证据

- kvrocks 写故障（20 次 SETEX 探测）：OK=0 FAIL=20。redis_last_ok_at 每次成功 GET 后刷新，
  所以 authz 侧 shared_session.state=ok：健康探测只覆盖读路径，写故障被掩盖。
- 235.t session_pending 15 条 op=save 全部未重放，最早一条 attempts=2577。
- kvrocks 容器 StartedAt 2026-10-13T12:00:14Z，最早入队登录 12:27:05Z，时间点吻合。
- Redis 现存 21 个 authz:session 键（故障前遗留），新会话进不去。

## 复现（同一 token，仅切换上游）

token = 235.t 本机签发且未进 Redis（前缀 56cbd3c5, attempts=2577）：

| 目标 | 结果 |
|---|---|
| 235.t:6080 直连 | 200（pending-queue 命中本机镜像） |
| 241.t:6080 直连 | 401 {code:unauthenticated} |
| APISIX 边缘 x40 | 401 x40 |

对照组 IN-REDIS token（前缀 18299b1a）：235 200 / 241 200 / 边缘 x30 全 200。

浏览器端到端：注入该 cookie，访问 /_authz/apps/，2s 内跳 /_authz/login，cookie 数 1 到 0。

## 排除项

- cookie 下发：4 个 Host（a-235 / codex-235 / file-235 / ws.gatepro.cn）Domain 属性均正确，
  清理用 Max-Age=0 只打 legacy 域，不会删掉刚签发的会话（IP 访问走 host-only，无清理头）。
- 第三方 cookie / iframe：跨站 iframe 场景 200 通过，CDP 显示 cookie 保留，
  sameSite=None、无 partitionKey。
- 空闲过期：t+5/30/90/210s 全 200，TTL 604800s。
- 凭据吊销：users 表 admin enabled=1 roles=admin。

## 附带发现（与本次故障无关，需单独处理）

1. /data/app/.env 的 AUTHZ_ADMIN_PASSWORD 已失效：按 util.hash_password 语义
   （HMAC-SHA256 迭代 5000，salt 作 key）离线校验不通过；该离线实现已用容器内真实 Lua
   实现校准过。DB 里 admin 行 updated_at=2026-09-13，即改过密码但 .env 未同步。
2. admin vhost access_log off（conf/server_inc.conf:21,26），所以 docker logs 里看不到真实
   浏览器 401：147 条 401 全是 curl/7.81.0、referer=-。故障期间无访问日志可查。
3. 241.t AUTHZ_SESSION_REDIS_MODE=read-only 且 AUTHZ_COOKIE_SECURE=false，与 235.t
   read-write/true 不一致，属配置漂移。

## 修复方向（未执行，现场只读取证）

- 优先：重建/修复 kvrocks 241 实例（RocksDB WAL 损坏通常需清理损坏 WAL 后重开，或从快照
  重建）；恢复后 15 条 session_pending 会被 shared_session_sync 重放。
- 止血：把边缘上游收敛到 235.t 单实例，或将 241.t 从该域轮询池摘掉。
- 加固：authz 健康探测应覆盖写路径（SETEX 哨兵键），写故障要能从 state=ok 里暴露出来。

取证脚本与原始响应头归档在 /data/.trash/px-authz-forensic-*/。

