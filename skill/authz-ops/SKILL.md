---
name: authz-ops
description: Authz Gateway 日常运维助手：部署/重建容器、健康巡检、备份与恢复、升级与回滚、日志与故障排查、多实例共享会话、改密与证书。用于"部署一套 authz""网关挂了/403/404/登录态丢失""备份恢复""升级回滚""看日志"等运维场景；不用于配置网关内的服务/域名/权限/Key（那是 authz-helper 的配置场景），也不用于修改网关代码（那是 docs/maintain_skill.md 的维护场景）。
---

# Authz Gateway 日常运维

面向已构建好的镜像做运行期操作：部署、巡检、备份、升级、排障。
三个 skill 的边界先分清，避免用错：

| 场景 | 用哪个 |
|---|---|
| 配服务/域名/权限/API Key/菜单/改写 | authz-helper（调控制面 API） |
| 部署、备份、升级、排障、日志 | 本 skill（authz-ops） |
| 改网关自身代码/模板/测试 | docs/maintain_skill.md |

工具脚本：`scripts/azops.sh` 封装巡检与备份（已在 241.t 实测通过），
优先用它而不是手写一串 curl：

```bash
scripts/azops.sh check  -c authz -p 6443        # 健康巡检（5 项）
scripts/azops.sh backup -d ./data -o /data/tmp/authz-db-backup
scripts/azops.sh logs   -c authz -n 10m         # 最近 10 分钟
```

完整部署参数与多实例细节见仓库根目录 deploy.md（本 skill 是它的速查入口）。

## 0. 关键事实（先记住，能省大量排查时间）

- 容器名是 authz（本机），241.t 测试实例是 authz-test。旧名 openresty-gateway
  已统一废弃，复制命令前留意。
- 镜像：ghcr.io/yorkane/authz:latest（本地构建也是 authz:latest）。
- 必须 host 网络：网关要访问宿主机 127.0.0.1 的被代理服务。生产用 Linux；
  Docker Desktop 的 host 网络语义不同，容器内到不了宿主业务端口。
- 改了 .env 必须重建容器：docker compose up -d --force-recreate。
  docker restart 不会重新读 env，会表现为"改了没生效/莫名 401"。
- 回归测试只在 241.t 跑，除非用户明确要求，不要在本机生产实例部署新代码或镜像。
- SQLite 数据在 DATA_DIR（默认 ./data）下的 authz/authz.db，证书在 certs/。
  备份就是复制这两个。

## 1. 健康巡检（出问题先跑这一串）

把下面当整体看，比单独看某个码更有用：

```bash
docker inspect authz --format "{{.State.Status}} {{.HostConfig.NetworkMode}}"  # running host
docker exec authz openresty -t                                                # 配置语法
curl -sS -o /dev/null -w "%{http_code}" -k https://127.0.0.1:6443/_authz/login      # 200
curl -sS -o /dev/null -w "%{http_code}" -k https://127.0.0.1:6443/_authz/api/session # 401
curl -sS -o /dev/null -w "%{http_code}" -k https://127.0.0.1:6443/_authz/apps/       # 302
docker logs --tail 50 authz   # access 走 stdout，error 走 stderr
```

解释：登录页 200 + session 未认证 401 + 管理入口 302，三个同时成立才说明
"进程在、配置对、认证链路通"。任一不对，按第 4 节排障表定位。

带 Key 的自检（确认 API 面可用，Key 值别打印出来）：

```bash
source <(grep -E "^AUTHZ_API_KEY=" /data/app/.env)
curl -sSk -o /dev/null -w "%{http_code}" -H "x-api-key: $AUTHZ_API_KEY" \
  https://127.0.0.1:6443/_authz/api/session   # 期望 200
```

## 2. 部署与变更

| 场景 | 命令 |
|---|---|
| 首次部署 | 写好 .env 与 compose 后 docker compose up -d |
| 改 .env / 挂载 / 网络 | docker compose up -d --force-recreate（必须重建） |
| 改代码 / 模板（测试实例） | rsync 代码后 docker compose up -d --force-recreate |
| 换镜像版本 | 改 compose 的 image: 后 up -d --force-recreate |
| 本地构建 | docker build --build-arg RESTY_J=8 -t authz:latest . |

改 .env 后的标准动作（漏了就踩"restart 不生效"的坑）：

```bash
cd /data/app
vi .env
docker compose up -d --force-recreate
sleep 3
curl -sSk -o /dev/null -w "%{http_code}" https://127.0.0.1:6443/_authz/login
```

管理密码忘了或要重置（只影响本机 admin，不动其他数据）：

```bash
docker exec -e AUTHZ_ADMIN_PASSWORD="新密码" authz admin_password_reset
```

## 3. 备份与恢复

任何可能动 schema 的操作前先备份（升级镜像、跑迁移）：

```bash
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p /data/tmp/authz-db-backup
cp ${DATA_DIR:-./data}/authz/authz.db /data/tmp/authz-db-backup/authz-$TS.db
cp -r ${DATA_DIR:-./data}/certs /data/tmp/authz-db-backup/certs-$TS 2>/dev/null || true
```

恢复 = 停容器、用备份覆盖 authz.db（-wal/-shm 一起处理或删掉让 SQLite 重建）、
启动、跑第 1 节巡检。跨版本回退要先确认迁移方向：新版写的 schema 老镜像可能读不了，
此时只能靠备份回滚，所以备份不是可选项。

## 4. 故障排查速查

| 症状 | 原因与处理 |
|---|---|
| 容器反复重启 | docker logs authz；常见端口占用（改 .env 的端口）或 .env 取值非法（非法值启动即报错，是有意 fail-fast） |
| 改了 .env 没生效 | 用了 restart 而不是 up -d --force-recreate |
| 登录页 200 但代理 403 | 正常：代理目标要登录 + 授权。先登录，再配策略（authz-helper） |
| 绑定域名访问 404 | 绑定未启用或域名拼错；管理界面、授权管理、域名绑定里核对 |
| 子域间登录态丢失 | 未设 AUTHZ_COOKIE_DOMAIN（要 . 开头的父域），或多实例需开共享会话 |
| Cookie 不生效 / 反复跳登录 | 外层 HTTPS 但 AUTHZ_COOKIE_SECURE=false，或反代没透传 X-Forwarded-Proto |
| 带 Key 仍 401 | Key 无效/禁用，或来源不在 AUTHZ_API_KEY_ALLOWED_IPS（默认仅 127.0.0.1）；401 就停，别重试越权 |
| 升级后行为异常 | 先看 docker logs 有无迁移报错；必要时用第 3 节备份回滚 |

日志定位：access 走 stdout、error 走 stderr，docker logs -f authz 都能看到；
按时间窗过滤：docker logs --since 10m authz 2>&1 | grep -i error

## 5. 多实例：共享会话（Redis）

跨域名或跨实例保持登录时才需要。只允许一个实例 read-write（认证主），其余 read-only；
角色、策略、绑定仍各实例本地管理，互不同步。

```bash
AUTHZ_SESSION_SHARED=true
AUTHZ_SESSION_REDIS_URL=redis://<host>:6379
AUTHZ_SESSION_REDIS_MODE=read-only        # 主实例改 read-write
AUTHZ_SESSION_REDIS_PASSWORD=<pwd>
AUTHZ_SESSION_REDIS_PREFIX=authz          # 多套集群共用一个 Redis 时隔离
AUTHZ_SESSION_SIGNING_KEY=<openssl rand -hex 32>   # 所有共享实例必须一致
```

要点：登录、登出、改密、禁用用户必须打到主实例；Redis 不可达时失败关闭
（不从 SQLite 恢复旧 token）；共享记录带 HMAC 签名，reader 对伪造或篡改记录按未登录
处理，所以即使 Redis 无 ACL 也难以伪造会话，但签名密钥等同会话密钥，要同等保管。
网络白名单或 TLS 就绪前保持 AUTHZ_SESSION_SHARED=false。

## 6. 回归与验证（只在 241.t）

```bash
cd /data/app/authz-test
OPENRESTY_TEST_IMAGE=authz:latest bash test/test_authz_gateway.sh   # 基线 882 项
AUTHZ_API_KEY=... bash testcase/ui_api_tests.sh                     # 控制面 41 项
```

结果判读：必须出现 All 882 authz gateway checks passed.。
出现 FAIL 先别当成偶发，用 git stash 跑一次纯净基线对比，确认是改动引入还是环境问题
（曾出现过测试 fixture 用退役角色导致实例起不来的真实回归）。

## 7. 硬性规则

1. 不在本机生产实例部署新代码或镜像，除非用户明确要求；回归一律在 241.t。
2. 任何动 schema 或换镜像的操作先备份 authz.db 与 certs/。
3. 改 .env 后必须 --force-recreate，不用 restart。
4. 容器名用 authz（本机）或 authz-test（241.t），旧名 openresty-gateway 已废弃。
5. 401 或 403 立即停止并报告，不重试、不尝试越权；Key、密码、会话 token 不写进日志、
   提交信息与回复。
6. 本 skill 只做运行期运维：配服务、权限、Key 走 authz-helper，改代码走
   docs/maintain_skill.md。
