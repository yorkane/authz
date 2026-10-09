# Authz Gateway 部署手册（deploy.md）

本手册自包含：只需要 **本文件 + 镜像**，即可完成一套可用的 Authz Gateway 部署。
不需要源代码、不需要构建；所有前端、Lua 库与 Nginx 模板都已内置在镜像中。

- 镜像：`ghcr.io/yorkane/authz:latest`（**只发布到 GHCR**，CI 未推送 docker.io；不要写
  `docker.io/yorkane/authz`，该仓库不存在）
- 能力：动态端口反向代理 + 本地认证授权（SQLite + mini-casbin）+ 管理界面
- 依赖：Docker Engine（生产使用 Linux；需要 host 网络）+ 可选外部 Redis（仅多实例共享会话时需要）

## 1. 架构速览

| 入口 | 端口（默认） | 行为 |
|------|--------------|------|
| HTTP | `6080` | 默认 308 重定向到 HTTPS（`AUTHZ_HTTP_MODE=redirect`）；`disabled` 仅回环；`serve` 才直接代理 |
| HTTPS | `6443` | 网关终止客户端 TLS，再按绑定配置代理 HTTP/HTTPS 上游 |
| 管理界面 | `/_authz/apps/` | 登录、用户、域名绑定、Casbin 策略、API Key |
| 登录页 | `/_authz/login` | 本地账号 + 已启用的 OAuth |

域名解析规则（由外到内优先匹配）：

1. **显式绑定**：管理界面配置的固定域名 → `target_ip:port`；
2. **内置应用保留前缀**（虚拟绑定）：`file-任意域名` → 文件浏览（虚拟端口 100）、
   `s3-任意域名` → 对象存储（虚拟端口 101）；**根路径渲染内置应用页面，带上子路径的
   GET/HEAD 直接返回文件/对象字节**（file 端取容器内 `/files` 下的路径，s3 端取当前生效
   那套存储配置 `default_bucket` 下的 key，都支持 Range/206）；不在数据库中、不占绑定端口，
   按策略对象 `/<端口><路径>` 单独授权（因此可按目录分级，如 `/100/alice/*`）；
   `AUTHZ_APP_DOMAINS=0` 可整体关闭；
3. **数字前缀子域名**（免配置）：`3000-任意域名` → 本机 `3000` 端口（范围 `AUTHZ_PORT_MIN`~`AUTHZ_PORT_MAX`）；
4. 其余域名 → 404。

所有代理流量默认要求登录 + Casbin 授权；后端会收到 `X-Authz-User` / `X-Authz-Source` / `X-Authz-Identity` 头。

## 2. 前置条件检查（部署前必须执行）

```bash
# Docker 可用
docker info >/dev/null 2>&1 || { echo "Docker 未就绪"; exit 1; }

# 拉取镜像（amd64/arm64 均已发布）
docker pull ghcr.io/yorkane/authz:latest

# 入口端口未被占用（默认 6080/6443；被占用时在 .env 中更换）
(ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -E ":(6080|6443) " && echo "端口冲突，请更换" || echo "端口可用"
```

必须使用 **host 网络**：网关需要直接访问宿主机 `127.0.0.1` 上被代理的服务。
Docker Desktop（macOS/Windows）的 host 网络语义与 Linux 不同，容器内无法到达宿主 `127.0.0.1` 的业务服务，生产请使用 Linux。

## 3. 最小部署（推荐）

统一在 `/data/app/authz/` 下以 docker-compose 方式部署：在该目录创建 `.env` 与 `docker-compose.yml`，然后 `docker compose up -d`。
这种方式**不挂载任何代码**，全部使用镜像内置文件，是最干净的生产形态。

### 3.1 `.env`（最小可用示例）

这是**开箱即用**的最小集：复制后改掉两个值即可启动。
缺 `AUTHZ_API_KEY` 会没有机器凭证（Agent/脚本无法免登录操作），务必保留。

```bash
# ── 必填 ────────────────────────────────────────────────
# 首次启动创建的 admin 密码（仅 users 表为空时生效，登录后请立即改密）
AUTHZ_ADMIN_PASSWORD=<改成强密码: openssl rand -hex 16>
# 对外访问的 Origin（OAuth 回调基准等），没有公网域名时可留空（按请求 Host 推导）
AUTHZ_HOST_URL=https://<你的入口域名>
# Cookie 父域：多个子域共享登录时设置，如 .example.com；仅 IP/localhost 访问时留空
AUTHZ_COOKIE_DOMAIN=
# 入口始终为 HTTPS（例如外层有 TLS 反代）时设 true，否则 false
AUTHZ_COOKIE_SECURE=false

# ── 机器凭证（Agent / 脚本免登录调用，开箱即用必需）────
# 实例级 Key：请求头 x-api-key 提交，免登录、免 CSRF。
# 下面是内置默认值，仅本机/测试可用；生产务必换成: openssl rand -hex 32
AUTHZ_API_KEY=eeeec9f034335f136f87ad84b625ffff
AUTHZ_API_KEY_ROLE=admin
# 来源白名单（逗号分隔 IP 或 CIDR），默认只信本机回环；跨机接入加对端 IP
AUTHZ_API_KEY_ALLOWED_IPS=127.0.0.1

# ── 可选：入口端口 ─────────────────────────────────────
AUTHZ_HTTP_PORT=6080
AUTHZ_HTTPS_PORT=6443
AUTHZ_HTTP_MODE=redirect

# ── 可选：动态端口代理范围（默认 2000-20000）────────────
AUTHZ_PORT_MIN=2000
AUTHZ_PORT_MAX=20000

# ── 数据目录（宿主机），必须持久化 ──────────────────────
DATA_DIR=./data

# ── 内置应用保留前缀域名入口（默认开启，一般无需改）──────
# file-<节点>.<域>/ 是文件浏览页，带子路径的 GET/HEAD 直取内容根下的文件字节；
# s3-<节点>.<域>/ 是对象存储页，带子路径直取当前存储配置 default_bucket 下的对象。
# 策略对象为 /100<路径> 与 /101<key>，可按目录或单文件用 Casbin 分级（见 3.6）。
# 要给这两类域名直接提供文件内容，还需在 compose 里挂 FILES_DIR（见 3.2 说明）。
AUTHZ_APP_DOMAINS=1
AUTHZ_APP_PREFIX_FILES=file
AUTHZ_APP_PORT_FILES=100
AUTHZ_APP_PREFIX_S3=s3
AUTHZ_APP_PORT_S3=101

# ── 本机临时保存区（Agent 落盘，可选）──────────────────
# PUT /_authz/api/store 的容器内根目录；compose 已把 DATA_DIR 整体挂到 /data，
# 所以宿主落在 ${DATA_DIR}/store 下，无需额外 volume。
AUTHZ_STORE_DIR=/data/store
# 默认保留小时数（0 = 永不过期）。到点后由网关每小时的后台清理器删除。
AUTHZ_STORE_DEFAULT_EXPIRY_HOURS=24
```

> 旧变量 `AUTHZ_AGENT_API_KEY` 已移除，不要再写进 `.env`；现在统一用上面的
> `AUTHZ_API_KEY`（或管理界面创建的数据库 Key）。完整变量清单见附录 A。

### 3.2 `docker-compose.yml`（最小，纯镜像）

```yaml
services:
  gateway:
    image: ghcr.io/yorkane/authz:latest
    container_name: authz
    restart: unless-stopped
    network_mode: host
    env_file:
      - .env
    environment:
      # 使用镜像内置模板（不挂载代码时的固定值）
      OPENRESTY_TEMPLATE_DIR: /usr/local/openresty/nginx/conf
    volumes:
      - ${DATA_DIR:-./data}:/data
      # 文件浏览与保留前缀 file- 域名的内容根。**不挂这行，file-<域>/ 仍能开页面，
      # 但任何带子路径的请求都取不到字节**（内容根为空 → 404）。要关掉文件浏览
      # 又想保留页面，直接不挂即可；页面本身仍可用。
      - ${FILES_DIR:-./files}:/files
```

说明：

- `env_file` 直接注入 `.env` 的全部变量；
- 镜像内置模板位于 `/usr/local/openresty/nginx/conf/`，entrypoint 每次启动自动渲染最终配置；
- `/data`（SQLite 数据库 + 自动生成的 10 年期自签证书）与 `/files`（文件浏览内容根）两个卷是
  全部必需的挂载，其余来自镜像；`FILES_DIR` 指向宿主上真实存在、你想对外暴露的目录树；
- 若不使用 compose，等价 docker 命令：`docker run -d --name authz --network host --restart unless-stopped --env-file .env -e OPENRESTY_TEMPLATE_DIR=/usr/local/openresty/nginx/conf -v ./data:/data -v ./files:/files ghcr.io/yorkane/authz:latest`。

### 3.3 启动

```bash
mkdir -p /data/app/authz && cd /data/app/authz
# 写入 .env 与 docker-compose.yml 后:
docker compose up -d
docker compose logs --tail=20
```

首次启动会自动：建库并 seed `admin` 用户、生成自签证书（`/data/certs`）、渲染 Nginx 配置。

### 3.4 外置 include 配置（自定义 Nginx 规则）

网关在 Nginx 配置中预留了三个外置 include 文件，用于追加用户自定义规则，无需改动模板：

| 文件 | include 位置 | 典型用途 |
| --- | --- | --- |
| `conf/http_inc.conf` | `http {}` 块末尾 | 额外 `server {}`、`upstream {}`、`map`、共享内存 |
| `conf/server_inc.conf` | 网关 `server {}` 最末尾 | 额外 `location`（同路径会覆盖网关内置行为）、健康检查 |
| `conf/stream_inc.conf` | 顶层 `stream {}` 块 | 四层 TCP/UDP 代理 |

启动行为：

- 入口脚本启动时检查这三个文件：存在（哪怕为空）就用用户的版本；不存在则自动生成带注释说明的默认内容，保证 Nginx 始终可用；
- 纯镜像部署（3.2）：镜像已内置三个默认文件，位于 `/usr/local/openresty/nginx/conf/`；需要自定义时用卷覆盖单个文件即可，例如 `-v ./conf/server_inc.conf:/usr/local/openresty/nginx/conf/server_inc.conf:ro`；
- 挂载模板目录部署（宿主机 `conf/` -> `/etc/openresty/templates:ro`）：直接编辑宿主机 `conf/` 下的三个文件，入口脚本会把它们复制进容器内 Nginx 配置目录，重启容器生效；
- 修改后先验证语法再重启：`docker exec <容器> openresty -t`，语法错误会导致 Nginx 无法启动；
- 内置示例：`server_inc.conf` 默认带 `location = /favicon.ico`（`empty_gif` + 204）与 `location = /noc.gif`（200，供 SLB 健康检查），均关闭访问日志。

验证 include 已生效：

```bash
curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1:6443/favicon.ico   # 204
curl -sk -o /dev/null -w "%{http_code}\n" https://127.0.0.1:6443/noc.gif       # 200
```

### 3.5 可选：多套存储服务与本机保存区

两项能力都不需要额外的 volume 或额外的容器，但部署动作不同：

| 能力 | 开关 | 部署动作 |
|------|------|----------|
| 对象存储浏览（多套服务） | 对象存储页「配置」按钮进入的配置视图写库（独立菜单入口已在迁移 v27 隐藏）；`AUTHZ_S3_*` 只作回落 | **无需重建容器**。表里有启用行即以表为准，改表即生效（查询缓存 TTL 30s + `db_rev` 失效）；纯 env 部署零迁移即可升级 |
| 本机临时保存区（`PUT /_authz/api/store`） | 常开（entrypoint 自动 `mkdir -p ${AUTHZ_STORE_DIR:-/data/store}`） | 只需 `AUTHZ_STORE_DIR` / `AUTHZ_STORE_DEFAULT_EXPIRY_HOURS` 两个变量；改动它们要 `--force-recreate` |

保存区落盘位置：容器内 `AUTHZ_STORE_DIR`（默认 `/data/store`），宿主 `${DATA_DIR}/store`
—— `${DATA_DIR}` 相对 compose 文件所在目录解析：本机部署目录 `/data/app/authz/` 时即
`/data/app/authz/data/store`，241.t 测试机 `/data/app/authz-test/` 时即
`/data/app/authz-test/data/store`（实例若把 `DATA_DIR` 指到别处，以 `docker inspect` 的
挂载源为准）。因为 compose 已经 `${DATA_DIR:-./data}:/data` 整体挂载，**不需要为它加 volume**。

> 变量注入方式有差别（容易踩）：本文 3.2 的最小 compose 用 `env_file: .env`，`.env` 里的变量会全部
> 进容器；而仓库根目录那份 `docker-compose.yml`（开发挂载模式，与附录 B 同源）除了 `env_file` 还带一份
> **逐条列举的显式 `environment:` 清单**，每一项都写成 `${VAR:-默认值}` 的形式。显式清单优先于 `env_file`，
> 所以**清单列到的变量以清单为准**：新增变量必须同时进 `.env` 和这份清单，只在 `.env` 里加一行、清单里不写，
> 容器用的仍然是清单里 `:-` 后面那个默认值（compose 不会替你猜）；清单**没列到**的变量才由 `env_file` 直接注入。
> 两种写法混在同一份 compose 里，正是最容易看走眼的地方。核实过的现状：`AUTHZ_STORE_DIR` /
> `AUTHZ_STORE_DEFAULT_EXPIRY_HOURS` 已在清单内（`docker-compose.yml:150-151`），内置应用保留前缀那五条
> `AUTHZ_APP_DOMAINS` / `AUTHZ_APP_PREFIX_FILES` / `AUTHZ_APP_PORT_FILES` / `AUTHZ_APP_PREFIX_S3` /
> `AUTHZ_APP_PORT_S3` 也已在清单内（`docker-compose.yml:44-48`），这几项改 `.env` 就能生效；反过来，将来新增的
> 变量若只写进 `.env.example` 而没同步进清单，仓库根 compose 模式下就不生效，别按 `env_file` 的行为下结论。

```yaml
# 最小 compose 已覆盖，无需新增条目（仅作核对）
volumes:
  - ${DATA_DIR:-./data}:/data      # store 区 = 该卷下的 store/
```

**升级既有实例时必须同步模板**：本次能力依赖 `conf/nginx.conf.template` 里新增的
`init_worker_by_lua_block`（每小时清理到期对象与上传暂存残留）和
`conf/server.conf.template` 里新增的 `location ^~ /_authz/store/`（保存区取回出口）。
部署若把宿主 `conf/` 挂到 `/etc/openresty/templates`（本机与 241.t 都是这种模式），
镜像升级不会更新它，必须把模板同步过去再重建：

```bash
# 本机（部署目录 /data/app/authz/）
cp conf/nginx.conf.template conf/server.conf.template /data/app/authz/conf/
cd /data/app/authz && docker compose up -d --force-recreate

# 241.t 测试机（部署目录 /data/app/authz-test/）
rsync -a conf/ 241.t:/data/app/authz-test/conf/
ssh 241.t 'cd /data/app/authz-test && docker compose up -d --force-recreate'
```

> 241.t 那份 `docker-compose.yml` 由仓库根 compose 同步而来（AGENTS.MD 的 rsync 清单已包含它），
> 外加一份 `docker-compose.override.yml`：override 把镜像钉在本机/CI 产物 `authz:latest`
> （`pull_policy: never`），并把 `FILES_DIR -> /files` 挂成可写（浏览页要验证批量移动/删除）。
> 因此该实例同样是「显式 `environment:` 清单优先」的形态：新增变量必须进仓库根 compose 的清单，
> 只在 `.env` 里加一行不生效（见 3.5 节末尾的提示）。同步时 `conf/`、`lualib/`、`docker-compose.yml`
> 三者要一起过去，漏一个就会出现「代码新、配置旧」。

验证定时器与出口都已就位（三项都要通过）：

```bash
AUTHZ=http://127.0.0.1:6080
docker exec authz grep -c maintenance /usr/local/openresty/nginx/conf/nginx.conf   # ≥1（定时器已渲染进配置）
curl -sS -H "x-api-key: $AUTHZ_API_KEY" "$AUTHZ/_authz/api/store/info" | head -c 200   # enabled:true
curl -sS -H "x-api-key: $AUTHZ_API_KEY" "$AUTHZ/_authz/api/s3-configs" | head -c 200   # items 数组
```

**备份口径变化（重要）**：多套存储服务配置存在 SQLite 里，其中
`s3_configs.secret_access_key` 是**明文**（SigV4 要拿原文参与签名，摘要无法还原，
这是有意的决策）。因此第 6 节的备份（含 `azops backup`、`cp data/authz/authz.db`）
会连带把 S3 密钥一起复制走 —— 备份介质的保密等级由此抬升，必须按含密文件处理：
限制可读者、不进公开对象存储、不贴进工单或聊天记录。

### 3.6 可选：用保留前缀域名直取文件与对象

`file-<节点>.<域>/<路径>` 与 `s3-<节点>.<域>/<key>` 把内置应用的两个域名变成内容出口：
根路径仍是应用页面，带子路径的 GET/HEAD 直接吐字节（Range/206、`?download=1`、`?authz_preview=1` 都可用）。
这条能力默认开启、不需要额外开关，但**两个部署前提**要落到 compose 上，缺一个就只有页面能用：

| 端 | 前提 | 不满足时的表现 |
|------|------|----------------|
| file | 内容根要有真实数据：`FILES_DIR -> /files` 卷 | 目录里没有那个文件 → 404 |
| s3 | 当前生效那套存储服务配置（`s3_configs`，对象存储页「配置」里维护）的 `default_bucket` 非空 | 503 + JSON，消息区分「对象存储未配置」与「未设置默认 bucket」；`?cfg=<id\|name>` 换一套时取被选中那套的 `default_bucket` |

还有一条**内容根的形状约束**：直取路径逐级做 realpath，要求每一级的解析结果与拼接串**逐字相等**
—— 也就是**内容出口不跟随任何符号链接，只信任实体目录**。出根、入根、指向 `/etc`、指向
`/data`、指向挂载点、根内相对链接，只要路径任一级是链接就在该级 400，消息「路径含符号链接，
内容出口只信任实体目录: <段>」；该级存在但 realpath 解不出来（悬空链接、ELOOP、EACCES）报
「无法解析真实路径」；该级不存在则交回 nginx 走 404。这是刻意的——静态 `alias` 本身不做 realpath
（nginx 只是把 URI 剩余段拼到 alias 后 `open()`，符号链接直接跟随），而内容根在部署里通常是
宿主真实可写的目录树；一条 `/100/<目录>/*` 策略加上目录里一个指向 `/etc` 的链接就是任意文件读，
而 `/data` 正是 authz 自己的凭据库（用户、API Key、会话都在其中的 SQLite 里），绝不能从内容出口外泄。

```bash
# 体检：列出内容根下的符号链接及其解析目标（部署后跑一次）
cd <compose 所在目录>            # .env 里没写 FILES_DIR 时，compose 用默认值 ./files
FILES_DIR=$(grep -m1 '^FILES_DIR=' .env | cut -d= -f2-); FILES_DIR=${FILES_DIR:-./files}
find "$FILES_DIR" -maxdepth 2 -type l -ls
```

（输出自带链接目标；要递归整棵树就把 `-maxdepth 2` 去掉。）体检列出的链接**现在全部会在
`file-<域>` 下 400** —— 管理界面的文件浏览走另一条通道，不受这条判据影响。需要经 file 域名浏览的，
一律改成实体 bind 挂载，链接本身从内容根里删掉。

**没有符号链接白名单，也没有「挂载点自动放行」**：这两套曾经的机制都已取消。只要允许某一条链接
被跟随，「逐字相等」这条判据就不再闭合，配置会沿「先放一条、再放一片」漂移，最终又回到任意文件读。
想让 `file-<域>` 浏览内容根以外的目录，唯一正确姿势是把目标树作为**实体 bind 直接挂进 `/files` 下的
一个子目录**：挂载落点本身是真实目录，realpath 原地不动，照常通过。

NFS/外部大盘的完整正例（本机把公共 NFS `/nas2` 经 file 域名浏览）：宿主先把 `/nas2` 正常挂载好，
compose 里把它原样 bind 进内容根下的子目录：

```yaml
# docker-compose.yml（volumes）
      - /data:/files                # 内容根（宿主 /data）
      - /nas2/:/files/nas2data:ro   # 目标树实体 bind 进内容根下的子目录
      - /home/aigc/ChatGPT:/files/chatgpt:ro   # 第二路外部树，同一姿势
```

两个要点：容器内的 `/files/nas2data` 必须是**真实目录**（bind 的落点天然是实体，不能是软链接），
所以内容根 `/data` 里**不要**预先放 `nas2 -> /nas2/` 这类链接 —— 它既会被 docker 解析成宿主路径去挂，
内容出口也拒绝跟随任何链接；放行的目录只以实体 bind 的形式出现在 `/files` 下。

**本机实况（235.t）**：现网 /data/app/docker-compose.yml 的 volumes 共三行 ——
`- ${FILES_DIR:-./files}:/files`（`.env` 里 `FILES_DIR=/data/`，即内容根是宿主 `/data`）、
`- /nas2/:/files/nas2`（**当前为 rw 直挂**的 NFS 大盘，建议评估加 `:ro`，见本段末运维提醒）、
`- /home/aigc/ChatGPT:/files/chatgpt:ro`。与上面通用示例的出入有两处：NFS 卷的容器内目录名
就叫 `nas2`（不是 nas2data），且没挂 `:ro`。容器 mountinfo 证实 `/files/nas2` 是实体 NFS bind
（kernel 视角 `nfs4 10.251.14.57:/ptjszx_ai01 rw`）。file 域名
（file-235.ai-t.wtvdev.com；本机探针用 Host 头打 `127.0.0.1:6080`，不依赖 DNS）的实测入口：

| URL 前缀 | 对应卷 / 内容根里的形状 | 实测 |
|----------|--------------------------|------|
| `/nas2/...` | `/nas2/ -> /files/nas2`（rw 直挂的实体 NFS bind） | 200 / 206 |
| `/chatgpt/...` | `/home/aigc/ChatGPT -> /files/chatgpt:ro` | 200 / 206 |
| `/nas2data/...` | 无对应卷；内容根里只剩 04:08 重建留下的**空目录残留**（历史实验产物） | 404 |
| `/ChatGPT/...`（旧写法） | 宿主 `/data/ChatGPT -> /home/aigc/ChatGPT/` 同名软链接未删 | 400（预期） |

`/nas2data` 是 06:0x 版记录的旧入口：当时 NFS 卷挂在 `/files/nas2data:ro`，后来换绑成
`/files/nas2` 直挂，`/data/nas2data` 这个空目录没人清理，纯残留——请求它只会 404。

旧前缀 400 的根因就是那条内容出口判据：路径任一级是链接即拒，与卷配没配无关。
还有一个和它咬合的 docker 坑：compose 的 bind 如果源或目标父路径上有软链接（本机当时宿主
`/data/nas2 -> /nas2/` 存在），docker 会解析链接、把卷实际挂到链接落点（容器 `/nas2`），
`/files/nas2` 仍是出根软链接 —— 这就是「配了卷却仍 400」的典型根因。所以内容根里不要预放
软链接、卷目标用不与任何链接同名的新目录（通用示例里 nas2data/chatgpt 两个名字即由此而来），
新增 bind 前后都跑一次上面的体检命令 `find "$FILES_DIR" -maxdepth 2 -type l -ls`：
与卷目标同名的残留链接出现在清单里，就先把链接删掉再重建容器。
点题一句：`/files` 下的名字可以随便叫（`nas2`、`nas2data` 皆可），判据只有一条——该级
realpath 与拼接串**逐字相等**（即实体目录）。当年 `/files/nas2` 是宿主软链接所以 400，
今天同名路径是实体 bind 所以 200：换名字不改变结果，实体与否才决定结果。

运维提醒：`/nas2/:/files/nas2` 目前是 rw 直挂。file 域名内容出口只做 GET/HEAD 读，不受影响；
但管理界面的文件写接口（上传/重命名/删除，仅 admin；对象存储侧写范围另由
`AUTHZ_S3_WRITABLE_PATHS` 约束）理论上能沿这条 rw 卷写进 NFS 大盘。若不需要经 authz 写
`/nas2`，建议在该行末尾加 `:ro` 后 `docker compose up -d --force-recreate` 收紧（仅为建议，
本文档未对容器做任何操作）。

改过 `.env` 或 compose 后 `docker compose up -d --force-recreate` 才生效，再用 file 域名直取该子目录下
的一个真实文件核验应回 200（目录本身无 autoindex，回 403 属正常）。若同名路径上旧的链接还留着，
第一次请求就会在链接那一级 400，按消息里的段名把链接删掉即可。

注意 `AUTHZ_FILES_ROOT` **改不动内容出口的落盘目录**：`/_authz/files/` 的 `alias /files/` 写死在
`conf/server.conf.template` 里，容器内恒为 `/files`，要换目录只能换挂载点（`${FILES_DIR}:/files`）。
`AUTHZ_FILES_ROOT` 只影响控制面的目录浏览与写接口；直取通道的符号链接校验比对的是 `/files`
（`files.default_root`），两者必须一致才不会出现「校验一个目录、实际读另一个目录」。

授权不设第二套门：策略对象仍是 `/<虚拟端口><原始 uri>`（`/100/alice/pub/a.txt`、`/101/share/pub/v.mp4`），
管理员按目录写 `p, role:guest, /100/alice/*, GET` 就是分级；未命中策略一律 fail-closed（匿名 302 登录、
已登录或带 Key 但无权 403）。之所以不为直取另立一套鉴权：内容端点和页面端点共用同一个策略命名空间，
管理员在管理界面看到的授权面就是实际生效的授权面，少一处需要记住的例外。直取只对「经保留前缀域名进来」
的请求生效，直接打内部路径 `/_authz/files/...`、`/_authz/s3/...` 的门完全不变（仍要会话或 API Key）。

```bash
# 根路径 = 页面；带路径 = 直取字节。两者都要求该身份对相应策略对象放行
curl -sS -o /dev/null -w "%{http_code} %{content_type}\n" -H "Host: file-235.example.com" \
  -H "Cookie: $AUTHZ_COOKIE" "http://127.0.0.1:6080/alice/pub/a.txt"   # 200 text/plain
curl -sS -o /dev/null -w "%{http_code}\n" -H "Host: file-235.example.com" \
  -H "Cookie: $AUTHZ_COOKIE" -H "Range: bytes=0-1023" \
  "http://127.0.0.1:6080/alice/pub/a.txt"                              # 206
```

上面的 `-H "Host: ..."` 只是本机验证手段（入口端口不区分域名时靠它指定虚拟入口）；真实访问由 DNS 把
`file-<节点>.<域>` 指到网关。给外部系统当下载链接时不要把凭证塞进 URL——认证走会话 Cookie 或
`x-api-key` 请求头，契约见 `docs/core-api.md` §6.6。

## 4. 部署后验证（逐项执行，全部通过才算成功）

```bash
HTTP_PORT=6080    # 与 .env 保持一致
HTTPS_PORT=6443

# 1) HTTP 入口 → 308 重定向到 HTTPS（AUTHZ_HTTP_MODE=redirect 时）
curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:${HTTP_PORT}/_authz/login"

# 2) HTTPS 登录页 → 200（自签证书需要 -k）
curl -skS -o /dev/null -w "%{http_code}" "https://127.0.0.1:${HTTPS_PORT}/_authz/login"

# 3) 未认证 session API → 401
curl -skS -o /dev/null -w "%{http_code}" "https://127.0.0.1:${HTTPS_PORT}/_authz/api/session"

# 4) Admin 入口 → 302（未登录跳转登录页）
curl -skS -o /dev/null -w "%{http_code}" "https://127.0.0.1:${HTTPS_PORT}/_authz/apps/"

# 5) 管理员登录（用 .env 中的密码）→ 302 且响应头带 authz_session Cookie
curl -skS -D - -o /dev/null -X POST "https://127.0.0.1:${HTTPS_PORT}/_authz/login"   --data-urlencode "username=admin" --data-urlencode "password=change-me-strong-password"   | grep -i "set-cookie\|location"
```

浏览器访问 `https://<host>:6443/_authz/apps/`（公网会自动从 HTTP 跳到 HTTPS），用 `admin` + `.env` 密码登录，**登录后立即在个人资料页改密**。

若部署包含保留前缀域名（`AUTHZ_APP_DOMAINS=1`，默认），再核对这三项——它们与上面的通用检查
互相独立，全绿也不代表内容出口可用：

```bash
KEY=$(docker exec authz printenv AUTHZ_API_KEY)   # 实例级预置 Key；没有就用管理员会话 Cookie
H='Host: file-prod.example.com'                 # 本机验证靠 Host 头指定虚拟入口，不依赖 DNS

curl -sS -o /dev/null -w "%{http_code}\n" -H "$H" -H "x-api-key: $KEY" \
  "http://127.0.0.1:${HTTP_PORT}/"                                    # 200：根路径仍是文件浏览页
curl -sS -o /dev/null -w "%{http_code}\n" -H "$H" -H "x-api-key: $KEY" \
  "http://127.0.0.1:${HTTP_PORT}/<一个确实存在的文件>"                # 200：带子路径直取字节
curl -sS -o /dev/null -w "%{http_code}\n" -H "$H" -H "x-api-key: $KEY" \
  "http://127.0.0.1:${HTTP_PORT}/definitely-missing.mp4"              # 404：不存在不回落到页面
docker exec authz grep -c authz_app_content /usr/local/openresty/nginx/conf/server.conf  # >=1：模板已渲染
curl -sS -o /dev/null -w "%{http_code} %{content_type}\n" -H "$H" -H "x-api-key: $KEY" \
  "http://127.0.0.1:${HTTP_PORT}/<实体bind子目录>/<一个真实文件>"                # 200：实体 bind 入口（本机 235.t 即 /nas2/...、/chatgpt/...，见 3.6）
```

临时维护提示：若必须短暂开放 HTTP 或限制管理端来源，用防火墙白名单（例如 `ufw allow from 203.0.113.5 to any port 6080` 或 `iptables -A INPUT -p tcp --dport 6080 -s 203.0.113.5 -j ACCEPT`），完成后恢复默认；不要在生产长期保留明文入口。

## 5. 域名与对外接入（通用指引）

网关自带 10 年期自签证书（SAN: DNS:*），按以下任一方式暴露：

1. **直接暴露 6443**：浏览器会告警自签证书，适合内网/测试；
2. **外层 TLS 反代**（推荐）：把 `*.your-domain.com:443` 通配域名指到网关的 `6443`（或 `6080`），并在 `.env` 设置：

   ```bash
   AUTHZ_HOST_URL=https://your-domain.com          # 实际对外 Origin（带端口则写端口，如 :99）
   AUTHZ_COOKIE_DOMAIN=.your-domain.com            # 子域共享登录必需（去掉首个 label 的父域）
   AUTHZ_COOKIE_SECURE=true                        # 反代终止 TLS 时必须，否则 Cookie 不下发 Secure
   ```

外层反代（APISIX/Nginx 等）建议：开启 WebSocket（`enable_websocket=true`）、透传 `Host`、正确设置 `X-Forwarded-Proto`（网关依据它决定 Cookie Secure）。

典型用法：配置通配路由 `*-your-domain.com` → 网关；之后 `3000-xxx.your-domain.com` 自动代理本机 3000 端口，管理界面新增的域名绑定即刻生效，无需改反代。

## 6. 常用运维操作

| 场景 | 命令 |
|------|------|
| 改了 `.env` / 挂载 / 网络 | `docker compose up -d --force-recreate`（必须**重建**容器，`restart` 不会读取新环境变量） |
| 检查容器内配置 | `docker exec authz openresty -t` |
| 忘记 admin 密码 / 恢复初始密码 | `docker exec -e AUTHZ_ADMIN_PASSWORD="新密码" authz admin_password_reset` |
| 备份 | 复制 `${DATA_DIR}`（含 `authz/authz.db` 与 `certs/`）。**数据库里的 `s3_configs.secret_access_key` 是明文**（SigV4 需要原文签名），备份文件必须按含密介质处理：限制读取者、不要进公开的对象存储或工单附件 |
| 查看日志 | `docker logs -f authz`（access 走 stdout，error 走 stderr） |
| 容器状态核对 | `docker inspect authz --format "{{.State.Status}} {{.HostConfig.NetworkMode}}"` 应为 `running host` |

## 7. 多实例部署（可选）

多个网关实例共存时，有两个相互独立的机制：

### 7.1 共享会话（Redis）—— 跨域名不丢登录

共享 Redis 可以让用户在实例间保持登录。**只允许一个认证主实例写入**；其他实例只读。
只共享用户 ID 与来源，角色、Casbin 策略、域名绑定仍由各实例本地管理、互不同步。

每个实例的 `.env` 追加：

```bash
AUTHZ_SESSION_SHARED=true
AUTHZ_SESSION_REDIS_URL=redis://<redis-host>:6379
AUTHZ_SESSION_REDIS_MODE=read-only       # 仅认证主实例改为 read-write
AUTHZ_SESSION_REDIS_USERNAME=authz-reader
AUTHZ_SESSION_REDIS_PASSWORD=<redis-password>
AUTHZ_SESSION_REDIS_DB=0
AUTHZ_SESSION_REDIS_PREFIX=authz    # 多套集群共用同一 Redis 时用于隔离，如 authz-cluster1
# 共享记录 HMAC-SHA256 签名密钥（>=32 字符，所有共享实例必须一致）。
# 生成: openssl rand -hex 32
AUTHZ_SESSION_SIGNING_KEY=<openssl rand -hex 32>
# 可选：Redis 网络故障时的容错降级、降级宽限期与待写队列重放周期
AUTHZ_SESSION_SHARED_FALLBACK=true          # false = 严格 fail-closed（Redis 不可用即清 Cookie、writer 登录 503）
AUTHZ_SESSION_RETRY_INTERVAL_MS=15000       # 待写队列重放定时器周期（毫秒，钳制 1000..600000）
AUTHZ_SESSION_FALLBACK_GRACE=14400          # 降级宽限期（秒，钳 60..604800）：也是跨实例撤销生效的最大延迟
```

语义：

- 会话命中后仍会用本地 `users` / `remote_users` 校验身份，本地不存在或已禁用即仅清除本机登录；
- Redis 网络故障（连接失败/读写超时/拒绝连接）**不再拖垮网关**：熔断器（跨 worker，状态放在
  `ngx.shared.authz_shared_session` 共享字典）进入 OPEN 窗口，初始 5s、按连续失败次数指数退避、上限 60s；
  OPEN 期间完全不尝试连 Redis（零网络等待，不再像以前那样每个请求串行等 connect/read 超时），
  窗口到期后半开放行一次探测。AUTH 失败与 SELECT db 失败归类为**配置错误**，不参与降级读——
  配置错误必须暴露，不能被静默绕过；
- **降级读**（`AUTHZ_SESSION_SHARED_FALLBACK=true`，默认）：熔断 OPEN 且属网络故障时，会话校验改读本机
  SQLite `sessions` 镜像（每次成功从 Redis 读到共享会话时按节流窗口 upsert，本机签发与其他实例签发
  都有镜像），已登录用户继续可用；判据是该行的 `verified_at`（最近一次经 Redis 确认存在的时刻）落在
  grace（降级宽限期，`AUTHZ_SESSION_FALLBACK_GRACE`，默认 4 小时）之内；Redis 一直不恢复则自动停止
  降级、退回登录页；
- **待写重试队列**：Redis 不可达期间，本该落到 Redis 的动作按发生顺序入 SQLite 表 `session_pending`
  （`op=save/delete/delete_all`，字段含 `token`/`username`/`source`/`csrf`/`expires_at`/`attempts`/`created_at`）。
  撤销类（`delete`/`delete_all`）永不丢弃；`save` 类有行数上限，超限则登录返回 503——宁可显式失败，
  也不静默丢共享会话。重放定时器 `lualib/resty/authz/shared_session_sync.lua` 在 `init_worker`
  里启动：每个 worker 都挂看守定时器，owner 锁保证同一时刻只有一个 worker 重放，owner 崩溃后
  锁一过期即由其他 worker 接管（不等 reload）。默认每 15s 一轮按 id 升序重放（`save`→SETEX
  签名信封、`delete`→DEL、`delete_all`→SCAN 后按身份删），成功后在同一事务里批量删除已重放的
  行；碰到第一条失败就累加 `attempts` 并停止本轮以保持顺序（撤销只会晚到，不会乱序反超）。
  熔断 OPEN 时本轮直接返回，不做网络尝试；
- reader（只读）实例在 Redis 故障期间**仍拒绝创建新登录**，保持单 writer 不变量；writer 实例登录可用，
  会话先在本机生效、Redis 恢复后自动补齐到 Redis；
- **已知限制**：Redis 故障期间 A 实例上的撤销（登出、改密、删用户）在 B 实例上不会即时生效，
  最长受 grace（降级宽限期，`AUTHZ_SESSION_FALLBACK_GRACE`，默认 4 小时）约束；本地禁用用户/角色
  仍立即生效（共享会话命中后仍查本地 `users` / `remote_users`）。
  对撤销时效要求更高的部署应设 `AUTHZ_SESSION_SHARED_FALLBACK=false`，恢复严格 fail-closed；
- 登录、全局登出、密码重置和用户禁用必须进入 `read-write` 主实例；reader 的 Redis ACL 只授予 `GET`/`PING`；
- 共享记录以 `<JSON>.<HMAC-SHA256 hex>` 信封存储，HMAC 覆盖 `token + JSON`；
  reader 对未签名、伪造或篡改的记录一律按未登录处理。因此即使共享 Redis
  没有 ACL（托管实例无法限制写入方），其他写入方也无法伪造会话；
  签名密钥泄漏等同于会话密钥泄漏，与其他 secret 同等保管；
- 网络白名单和传输保护（TLS 或内网）完成前保持 `AUTHZ_SESSION_SHARED=false`；
  有 ACL 时仍应配置 reader 只读账号，HMAC 是叠加防线而非 ACL 的替代。

Redis 健康状况不用猜：共享模式启用时 `GET /_authz/api/session` 的响应带 `shared_session` 段，给出
`state`（`ok`/`down`/`config`，另有 `unknown` = 共享字典缺失）、`down_remaining_ms`、`failures`、`last_error`、
`fallback` 与 `degraded`（当前是否正在降级服务），字段含义见 `docs/core-api.md` §6.5。

**升级既有实例时必须同步模板**：本能力依赖 `conf/nginx.conf.template` 里新增的
`lua_shared_dict authz_shared_session 1m`（跨 worker 的熔断状态与降级 grace 键）和
`init_worker_by_lua_block` 里的 `shared_session_sync.start()`（待写队列重放定时器）。
生产部署把宿主机 `conf/` 目录挂到 `/etc/openresty/templates`（本机 `NGINX_TEMPLATE_DIR=/data/app/data/authz/conf`，
241.t 同理），**只改仓库模板或换镜像都不会更新它**，必须把两个 template 一并同步过去再重启容器：

```bash
# 本机（宿主机模板目录 /data/app/data/authz/conf）
# 注意 /data/app/data 是 root:root 0755，非 root 用户穿不过去，cp 要带 sudo
sudo cp conf/nginx.conf.template conf/server.conf.template /data/app/data/authz/conf/
docker restart authz

# 241.t 测试机（部署目录 /data/app/authz-test/）
rsync -a conf/ 241.t:/data/app/authz-test/conf/
ssh 241.t 'cd /data/app/authz-test && docker restart authz-test'
```

`/data/app/data/authz/conf/` 里不止两个 template：该目录还有用户自维护的本机定制 `http_inc.conf`
（本机它承载着自定义的 21.k upstream，`listen 2001`）。同步模板只像上面那样逐个 `cp` 两个
`*.template`，**勿整目录 rsync 覆盖 `conf/`** —— 整目录覆盖会连带抹掉本机定制，症状是 2001 入口
直接消失而不是网关报错，很容易被误判成代码回归。

同一台机器还要顺带核对 `docker-compose.yml`：241.t 那份是仓库根 compose 的手工副本且已漂移（缺
`AUTHZ_APP_*` 五行），只同步 `conf/` 不会把新变量带进容器，原因见 3.5 节末尾的提示。

两个模板都要同步：缺 `lua_shared_dict` 则熔断状态与 grace 键无处存放，缺 `start()` 则待写队列
永远不会被重放（Redis 恢复后 pending 一直堆在库里）。模板改动只需 `docker restart`；同时改了
`.env` 才需要 `docker compose up -d --force-recreate`。验证两处都已渲染进配置：

```bash
docker exec authz grep -c authz_shared_session /usr/local/openresty/nginx/conf/nginx.conf   # >=1
docker exec authz grep -c shared_session_sync /usr/local/openresty/nginx/conf/nginx.conf    # >=1
```

## 8. 故障排查速查

| 症状 | 排查 |
|------|------|
| 容器反复重启 | `docker logs authz`，常见为端口被占用或 `.env` 取值非法（非法值会在启动时直接报错） |
| 登录页 200 但代理 403 | 正常：代理目标需要登录 + 授权；先登录，再在管理界面配置策略 |
| 代理 404（绑定域名） | 绑定未启用或域名拼写不一致；管理界面 → 授权管理 → 域名绑定 |
| 子域之间登录态丢失 | 未设置 `AUTHZ_COOKIE_DOMAIN`（注意以 `.` 开头的父域），或需要启用 7.1 共享会话 |
| 共享会话模式下集体掉登录 / writer 登录 503 | 先看 `GET /_authz/api/session` 的 `shared_session.state`：`down` = Redis 网络故障（默认配置下已自动降级，不该掉登录；若仍掉登录说明降级被 `AUTHZ_SESSION_SHARED_FALLBACK=false` 关闭，或该会话已超出 grace——Redis 挂了太久，默认 4 小时），`config` = AUTH/SELECT db 失败（密码、ACL 或 `AUTHZ_SESSION_REDIS_DB` 配错，需人工修），`unknown` = 共享字典缺失（模板未同步，见 7.1）；`pending.total` 非 0 表示有待写动作等重放 |
| Cookie 不生效 / 反复跳登录 | 外层是 HTTPS 但 `AUTHZ_COOKIE_SECURE=false`，或反代未透传 `X-Forwarded-Proto` |
| 上游是 HTTPS 自签证书 | 在对应域名绑定的高级代理中关闭"验证 SSL 证书" |
| 绑定的"改写请求"没生效 | 三种操作按 remove → append → set 顺序生效。Host、Cookie、Origin、X-Forwarded-\*、X-Authz-User/Source/Identity 等托管头可以改写（网关把改写值写进 proxy_set_header 引用的变量，上游看到的就是最终值）；替换与追加同名互斥（保存 422），删除+追加=先删后加。追加 Cookie 用 "; " 并入透传值（网关自身的 authz_session 永远先被剥离），追加普通头产生第二行请求头。分帧/hop-by-hop 头与网关凭据头（X-Authz-Key/X-API-Key/X-Role-Key）保存即 422 |
| 绑定的"改写响应"没生效 | 看响应头 `X-Authz-Rewrite: skipped=<原因>`：`encoded` 上游返回了压缩正文、`range` 分片下载、`type` 非文本、`status` 上游非 200、`websocket`/`head` 不支持；正文改写还有 1MB 缓冲上限，超限自动原样透传。正文改写会由网关自动向上游声明 `Accept-Encoding: identity`（该链路不再压缩）；若绑定里显式写了 `Accept-Encoding` 覆盖则以其为准，上游压缩时改写按设计跳过 |
| 改绑定保存时报 `响应改写 status 必须是…` | 旧版本把规范化后的 `status:0`（= 不改状态码）当非法值拒绝，导致保存过改写规则的绑定再也 PATCH 不动；现已接受 0 |
| 忘记 admin 密码 | 见第 6 节 `admin_password_reset` |
| 容器内访问不到宿主服务 | 确认 `network_mode: host` 且宿主是 Linux；Docker Desktop 下容器 `127.0.0.1` 不是宿主 |
| 用 IP 访问时登录成功却反复跳回登录页 | 老版本缺陷（已在当前镜像修复）：升级到最新镜像即可；根因是登录响应错误下发了 `Domain=.<ip>` 清理头 |
| 管理界面报 `map is not a function` | 老版本缺陷（已在当前镜像修复）：空数据表被编码成 JSON 对象 `{}`；升级到最新镜像即可 |
| `docker cp` 覆盖 HTML/JS 后浏览器仍是旧页面 | 镜像里每个文本资产有预压缩 `.br` 旁文件，`brotli_static on` 时它优先于明文文件被下发（`docker cp` 不会同步它）。同名 `.br`（及 `.gz`）一并删除或覆盖即可；正式修复始终走镜像重建 |
| `file-<域>/<路径>` 返回 404 但文件确实存在 | 内容根没挂：compose 里缺 `${FILES_DIR}:/files` 这行（见 3.2）。页面能开不代表内容根已挂，这两件事独立 |
| `file-<域>/<路径>` 返回 400「路径含符号链接，内容出口只信任实体目录: <段>」 | 路径上有符号链接：内容出口不跟随任何链接（出根、入根、指向 `/etc`、指向 `/data`、指向挂载点、根内相对链接都算），3.6 有体检命令。解法=把该链接的目标树作为**实体 bind** 挂进 `/files` 下的子目录，并去掉链接本身；报「无法解析真实路径」是同一条解法（该级是断链或解析不出来） |
| `file-<域>/<路径>` 返回 400「路径非法：禁止 .. 段与控制字符」 | URL 里带了 `..` 段或 `%2e%2e`/`%2f`/`%5c`/`%00` 编码形态（含双层编码）。这是刻意的 fail-closed，客户端拼 URL 时要做规范化，别把用户输入直接拼进路径 |
| `s3-<域>/<key>` 返回 503 | 对象存储页「配置」里那套（或 `?cfg=` 选中的那套）没有非空 `default_bucket`。表里没启用行且 env 也没配时消息是「对象存储未配置」，配了但没设默认桶是另一条消息 |
| 内容域名所有请求都 302 到登录页 | 该身份没有命中任何策略。匿名主体是 `role:guest`，要在管理界面给 `/100<路径>` 或 `/101<key>` 写 Casbin 策略才会放行 |
| 内容域名取到了字节但状态码是 404/403，不是 405 | 方法判定顺序是 **Casbin 先、405 后**：策略没授该方法时先被拒成 403（匿名 302）；只有 Casbin 放行了该方法，非 GET/HEAD 才回 405 |

## 8.1 从源码构建镜像（维护者）

生产部署不需要构建（镜像自包含）；改了 `lualib/`、`admin/`、`conf/` 想出本地镜像时：

**先问一句：这次改动 CI 是不是已经在构建了？** push 到 `main` 会自动触发
`.github/workflows/build-and-push.yml`，产出并推送 `ghcr.io/yorkane/authz:latest`。验证通过的
改动，生产直接 `docker pull` 拿那个产物即可——既省掉本机几十分钟的全量编译，也保证生产跑的
就是 CI 验证过的那份。**只在本机调试、还没 push 时才需要下面的本地构建。**

```bash
# 首选：拿 CI 产物（构建成功后 ghcr 上就是最新 main）
docker pull ghcr.io/yorkane/authz:latest
docker run --rm --entrypoint sh ghcr.io/yorkane/authz:latest -c \
  'grep -c <新代码标记> /usr/local/openresty/site/lualib/resty/authz/...'  # 确认内容
```

确实要本地构建时：

```bash
cd <仓库>
# 用 daemon 内置 builder（走 docker daemon 的代理配置）；
# buildx 的 docker-container builder（如 local-builder）是不继承 daemon 代理的独立容器，
# 解析 docker.io 基础镜像会被墙掉且日志无进度，卡住时先检查它。
docker build --progress=plain -t authz:latest .
```

- OpenResty 全家桶编译层都有缓存，日常只改代码时构建只需几秒；
- **不要随手加 `--build-arg`（如 `RESTY_J`）**。该 ARG 参与 openresty-builder 那条巨型 `RUN` 的
  命令行，任何与上次不同的取值都会让这一层缓存失效，触发 PCRE2 / OpenSSL / OpenResty 全量重编
  （本机实测十几分钟），且重编可能因环境差异失败——报的是 `openssl/macros.h` 里
  `OPENSSL_API_COMPAT expresses an impossible API compatibility level` 加一大片 `Error 1`，看起来
  像代码坏了，其实只是缓存没命中后的重编失败。CI 不传任何 build-arg，本地要复现就用默认构建；
  确实要调并行度，先确认这一层缓存已经命中再改；
- 构建耗时较长时用 `setsid nohup docker build ... > /data/tmp/build.log 2>&1 &` 脱离会话，
  避免会话被打断连带杀掉构建；
- 代码变更打进镜像后需 `docker compose up -d --force-recreate`（或 restart）生效；
  若用开发挂载（附录 B）则改代码只需 restart，无需重建镜像；
- 验证镜像内容：`docker exec <c> grep -c <新代码标记> /usr/local/openresty/site/lualib/...`。

## 附录 A：`.env` 全量示例（含注释）

```bash
# ══════════════ 基础 ══════════════
AUTHZ_ADMIN_PASSWORD=change-me-strong-password   # 首次 seed admin 密码（仅建表时生效；之后用管理界面改密或 admin_password_reset）
AUTHZ_HOST_URL=https://gateway.example.com        # 对外 Origin；OAuth 回调基准；可留空由请求 Host 推导
AUTHZ_COOKIE_DOMAIN=.example.com                  # Cookie 父域（可逗号分隔多个）；跨子域共享登录必需；留空按请求 Host 推导（去掉首个 label）
AUTHZ_COOKIE_SECURE=false                         # 入口始终 HTTPS 时设 true（含外层反代终止 TLS）
NGINX_WORKER_PROCESSES=4                          # worker 数量，按 CPU 调整；1 便于调试日志

# ══════════════ 入口与代理范围 ══════════════
AUTHZ_HTTP_PORT=6080                              # HTTP 入口
AUTHZ_HTTPS_PORT=6443                             # HTTPS 入口（网关终止 TLS）
AUTHZ_HTTP_MODE=redirect                          # 默认 308 到 HTTPS；disabled 仅回环；serve 仅受控测试
AUTHZ_PORT_MIN=2000                               # 数字前缀子域名最小端口（强制 >=2000 防回环）
AUTHZ_PORT_MAX=20000                              # 最大端口；目标为网关自身端口返回 508 防循环
AUTHZ_APP_DOMAINS=1                               # 内置应用保留前缀入口总开关（file→100、s3→101；0 关闭后这两类域名回退 404）
AUTHZ_APP_PREFIX_FILES=file                       # files 保留前缀：file-<节点>.<域>/ 渲染文件浏览页，带子路径的 GET/HEAD 直取容器内 /files 下的文件字节（换目录改 FILES_DIR 挂载，不是这个变量）
AUTHZ_APP_PORT_FILES=100                          # files 虚拟端口：策略对象为 /100<原始 uri>（如 /100/alice/* 可按目录分级）；该端口不允许被域名绑定占用
AUTHZ_APP_PREFIX_S3=s3                            # s3 保留前缀：s3-<节点>.<域>/ 渲染对象存储页，带子路径的 GET/HEAD 直取当前生效那套配置 default_bucket 下的对象字节（?cfg= 切换配置）
AUTHZ_APP_PORT_S3=101                             # s3 虚拟端口：策略对象为 /101<key>（如 /101/share/pub/*）；未配置存储或 default_bucket 为空回 503
AUTHZ_DISCOVERY_PORTS=                            # 追加探测端口（逗号分隔），容器读不到宿主监听表时用，如 3080,8082
AUTHZ_DISCOVERY_TTL=30                            # 菜单服务发现缓存秒数（1-300）
AUTHZ_DISCOVERY_CONNECT_TIMEOUT_MS=100            # 探测连接超时（10-5000ms）
AUTHZ_DISCOVERY_READ_TIMEOUT_MS=200               # 探测读取超时（10-5000ms）
AUTHZ_DNS_RESOLVER=                               # 自定义 DNS（如 8.8.8.8）；留空读容器 /etc/resolv.conf

# ══════════════ 存储 ══════════════
DATA_DIR=./data                                   # 宿主机数据目录（SQLite + 自签证书），必须持久化；改挂载需重建容器；Docker Desktop 的 ./ 相对 compose 文件所在目录解析，请确认实际宿主路径。
AUTHZ_DB_PATH=/data/authz/authz.db                # 容器内 SQLite 路径（勿改，除非同时改挂载）
AUTHZ_CERT_DIR=/data/certs                        # 容器内证书目录，缺失自动生成 10 年期自签证书（SAN: DNS:*）
AUTHZ_DB_CACHE_TTL=30                             # SQLite 查询缓存秒数（1-300）
AUTHZ_DB_CACHE_LRU_SIZE=500                       # 查询缓存条目数（50-5000）
AUTHZ_STORE_DIR=/data/store                       # 本机「临时保存区」根目录（容器内），PUT /_authz/api/store 的落点。宿主落在 ${DATA_DIR}/store（compose 整体挂 /data，无需额外 volume）。必须可写
AUTHZ_STORE_DEFAULT_EXPIRY_HOURS=24               # 保存区默认保留小时数（0-8760，0 = 永不过期）。到点由每小时后台清理器删除；单次请求可用 ?expires_hours= 覆盖
# ══════════════ 对象存储（S3 兼容）══════════════
# 完整变量与约束见 .env.example 与 doc/s3-integration.md §3。注意这一整套现在只是
# 【回落默认配置】：对象存储页「配置」视图在 s3_configs 表里加一行启用配置，
# 就以表为准（改表即生效，不需要重建容器）；表空时才用这里的 AUTHZ_S3_*。
# 只有实例级调优（AUTHZ_S3_*_TIMEOUT_MS / AUTHZ_S3_KEEPALIVE_MS / AUTHZ_HOST_LAN_IP）
# 仍然只能靠环境变量。
# AUTHZ_S3_ENDPOINT=                              # http(s)://<host>[:<port>]，path-style、不能带路径；留空 = 回落项不存在（表里也没行时整体功能关闭）
# AUTHZ_S3_REGION=us-east-1                       # SigV4 region
# AUTHZ_S3_ACCESS_KEY_ID=                         # endpoint 已设时必填
# AUTHZ_S3_SECRET_ACCESS_KEY=                     # endpoint 已设时必填（表里的那一行是明文入库，见含密告警）
# AUTHZ_S3_ALLOW_HTTP=false                       # endpoint 是明文 http 时必须显式 true，否则启动即报错
# AUTHZ_S3_TMP_DIR=/data/s3tmp                    # 上传中转暂存目录（容器内，与 /data 同卷最省 IO）
# AUTHZ_S3_CONNECT_TIMEOUT_MS=2000                # 以下为实例级调优，表里的所有配置共用同一份
# AUTHZ_S3_READ_TIMEOUT_MS=30000
# AUTHZ_S3_SEND_TIMEOUT_MS=30000
# AUTHZ_S3_KEEPALIVE_MS=30000
# AUTHZ_S3_WRITABLE_PATHS=                        # 回落项的可写范围白名单：留空 = 默认 share/<本机 LAN IP>；"/" 或 "*" = 全部可写
# AUTHZ_S3_SHARE_ROOT=/share/                     # 默认 share 挂载根
# AUTHZ_S3_SHARE_BUCKET=                          # 非空 = share 前缀只在该桶生效
# AUTHZ_HOST_LAN_IP=                              # 显式覆盖本机 LAN IP（非 host 网络/测试用）；探测失败且未设 = 整体降级只读

# ══════════════ 会话 ══════════════
AUTHZ_SESSION_TTL=604800                          # 会话有效期秒数，默认 7 天；管理界面修改密码后该用户全部会话失效（管理端需输入两次新密码确认）
AUTHZ_LOGIN_ATTEMPTS=5                            # 同一账户（账户名+IP）连续失败多少次后锁定（>=1）
AUTHZ_LOGIN_WINDOW=1800                           # 失败计数窗口 = 锁定时长（秒，>=60，默认 1800=30 分钟）
AUTHZ_LOGIN_FAIL_DELAY_MS=1000                    # 登录失败后延迟多少毫秒再返回（0-10000，防暴力枚举计时）；按「账户名+IP」锁定，不影响同 IP 其他账户

# ══════════════ 共享会话（Redis，可选）══════════════
AUTHZ_SESSION_SHARED=false                        # 多实例共享登录身份；只共享用户 ID 与来源，角色/策略仍各实例本地管理；需重建容器生效。
AUTHZ_SESSION_REDIS_URL=redis://127.0.0.1:6379    # redis://<host>[:<port>]，默认端口 6379，仅支持 redis:// 明文地址，不支持 URL 内嵌账号或 db 号。
AUTHZ_SESSION_REDIS_MODE=read-only                # 主实例 read-write；其他实例 read-only
AUTHZ_SESSION_REDIS_USERNAME=authz-reader         # 为 writer/reader 配置不同 ACL 用户
AUTHZ_SESSION_REDIS_PASSWORD=                     # 对应 ACL 用户密码
AUTHZ_SESSION_REDIS_DB=0                          # Redis 逻辑库（0-15）
AUTHZ_SESSION_REDIS_PREFIX=authz                  # 键前缀，多套集群共用时隔离，如 authz-cluster1；键格式 <prefix>:session:<token>，TTL 与会话有效期一致。
AUTHZ_SESSION_SIGNING_KEY=                        # 共享记录 HMAC-SHA256 签名密钥（>=32 字符，所有共享实例必须一致）；未签名/签名不符的记录一律拒绝。生成: openssl rand -hex 32
AUTHZ_SESSION_SHARED_FALLBACK=true                # Redis 网络故障时容错降级：熔断 OPEN 期间会话校验改读本机 SQLite 镜像（该会话在 grace 内经 Redis 确认过才承认），本该写 Redis 的动作进 session_pending 待写队列，恢复后自动重放。false = 严格 fail-closed（清 Cookie、writer 登录 503）；代价是故障期间其他实例的撤销最长一个 grace 后才生效。AUTH/SELECT 失败属配置错误，不降级。
AUTHZ_SESSION_FALLBACK_GRACE=14400                # 降级宽限期（秒，钳 60..604800）：会话「最近一次经 Redis 确认存在」必须落在窗口内才允许降级服务，也是跨实例撤销延迟的上限。调大 = Redis 长时间不可用更不易掉登录但撤销更晚生效。
AUTHZ_SESSION_RETRY_INTERVAL_MS=15000              # session_pending 重放定时器周期（毫秒，钳制 1000..600000），owner 锁保证同一时刻只有一条重放链；调小可缩短恢复后的补齐延迟。需重建容器生效。

# ══════════════ 响应改写缓冲（可选）══════════════
AUTHZ_REWRITE_BUFFER_MB=64                        # 正文改写的 worker 级缓冲预算（MB）。单响应上限固定 1MB 并按此整块预留；预算耗尽的新响应跳过改写、原样流式透传（响应头 X-Authz-Rewrite: skipped=memory）。仅影响 body/rewrites，状态码与响应头改写不占预算。

# ══════════════ 实例级预置 API Key（Agent 免登录，可选）══════════════
AUTHZ_API_KEY=                                    # 留空即关闭。设置后用 `x-api-key: <值>` 免登录访问控制面 API、管理页面与代理入口；32-256 字符（如 openssl rand -hex 32）。不入库，随环境变量轮换；配置非法启动即失败。内置默认值 eeeec9f034335f136f87ad84b625ffff（角色 admin、仅回环），仅本机/测试可直接用，生产必须更换。
AUTHZ_API_KEY_ROLE=admin                          # 该 Key 的角色（admin/staff/user/guest/api），权限走同角色 Casbin 策略
AUTHZ_API_KEY_ALLOWED_IPS=127.0.0.1               # 来源白名单：逗号分隔的 IP 或 CIDR（如 127.0.0.1,10.0.0.0/8），匹配 TCP remote_addr（XFF 不参与）。默认只信 127.0.0.1；跨机接入显式加对端 IP

# ══════════════ OAuth：Google（可选）══════════════
AUTHZ_GOOGLE_ENABLED=false
AUTHZ_GOOGLE_CLIENT_ID=your-google-client-id
AUTHZ_GOOGLE_CLIENT_SECRET=your-google-client-secret
AUTHZ_GOOGLE_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_GOOGLE_DEFAULT_ROLES=guest                 # 首次登录默认角色：admin,staff,user,guest 组合（逗号分隔）

# ══════════════ OAuth：钉钉（可选）══════════════
AUTHZ_DINGTALK_ENABLED=false
AUTHZ_DINGTALK_CLIENT_ID=your-dingtalk-client-id
AUTHZ_DINGTALK_CLIENT_SECRET=your-dingtalk-client-secret
AUTHZ_DINGTALK_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_DINGTALK_DEFAULT_ROLES=guest

# ══════════════ OAuth：微信（可选）══════════════
AUTHZ_WECHAT_ENABLED=false
AUTHZ_WECHAT_APP_ID=your-wechat-app-id
AUTHZ_WECHAT_APP_SECRET=your-wechat-app-secret
AUTHZ_WECHAT_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_WECHAT_DEFAULT_ROLES=guest

# ══════════════ NocoBase 密码登录源（可选）══════════════
AUTHZ_NOCO_ENABLED=false                          # 允许在登录表单选择 NocoBase 账号密码；AUTHZ_NOCO_URL 必须 https
AUTHZ_NOCO_URL=https://your-nocobase.example/
AUTHZ_NOCO_ROLE_MAP=root=admin,admin=admin,staff=staff,member=user,user=user,viewer=guest
AUTHZ_NOCO_CONNECT_TIMEOUT_MS=3000
AUTHZ_NOCO_SEND_TIMEOUT_MS=5000
AUTHZ_NOCO_READ_TIMEOUT_MS=5000

# ══════════════ NocoBase OAuth（可选）══════════════
# NocoBase 2.2 要求：回调必须精确校验 iss，token 使用 client_secret_basic + PKCE；
# 公网 Client 用仓库脚本 scripts/register_nocobase_oauth.py 一次性注册（需要源码树）。
AUTHZ_NOCO_OAUTH_ENABLED=false
AUTHZ_NOCO_OAUTH_CLIENT_ID=your-nocobase-client-id
AUTHZ_NOCO_OAUTH_CLIENT_SECRET=your-nocobase-client-secret
AUTHZ_NOCO_OAUTH_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_NOCO_OAUTH_DEFAULT_ROLES=guest

# ══════════════ 通用 OAuth/OIDC Provider（可选）══════════════
AUTHZ_OAUTH_ENABLED=false
AUTHZ_OAUTH_PROVIDER=oauth                        # provider id（小写字母/数字/点/下划线/连字符，勿用保留名）
AUTHZ_OAUTH_TITLE=OAuth                           # 登录页显示名称（支持中文）
AUTHZ_OAUTH_CLIENT_ID=
AUTHZ_OAUTH_CLIENT_SECRET=
AUTHZ_OAUTH_AUTHORIZE_URL=                        # authorize 端点
AUTHZ_OAUTH_TOKEN_URL=                            # token 端点（PKCE + client_secret_basic）
AUTHZ_OAUTH_USERINFO_URL=                         # userinfo 端点（Bearer）
AUTHZ_OAUTH_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_OAUTH_SCOPE=openid email profile
AUTHZ_OAUTH_SUBJECT_CLAIM=sub                     # 唯一身份 claim（默认 sub）
AUTHZ_OAUTH_USERNAME_CLAIM=email                  # 用户名 claim（默认 email，回退 preferred_username）
AUTHZ_OAUTH_ROLE_CLAIM=roles                      # 角色 claim（逗号分隔或数组）
AUTHZ_OAUTH_ROLE_MAP=                             # 源角色→本地角色映射，如 employees=staff
AUTHZ_OAUTH_DEFAULT_ROLES=guest
AUTHZ_OAUTH_REQUIRE_VERIFIED_EMAIL=false
AUTHZ_OAUTH_STATE_TTL=600                         # 授权 state 有效期秒数（>=60）

```

## 附录 B：完整 `docker-compose.yml`（含开发挂载模式）

生产推荐第 3.2 节的最小版本。若需要同步修改前端/Lua/模板并热加载（开发机），使用完整版：

```yaml
services:
  gateway:
    image: ghcr.io/yorkane/authz:latest
    container_name: authz
    restart: unless-stopped
    network_mode: host
    env_file:
      - .env
    environment:
      # 指向挂载的模板目录；不挂载模板时改为 /usr/local/openresty/nginx/conf
      OPENRESTY_TEMPLATE_DIR: /etc/openresty/templates
    volumes:
      - ${DATA_DIR:-./data}:/data
      # 以下三项为开发挂载，需要与镜像同版本的源代码树；生产可全部删除（删除后把 OPENRESTY_TEMPLATE_DIR 改回内置目录）
      - ./admin:/usr/local/openresty/nginx/html/admin:ro
      - ./lualib:/usr/local/openresty/site/lualib:ro
      - ./conf:/etc/openresty/templates:ro
```

注意：开发挂载要求代码树与镜像版本匹配，否则会引入行为差异；纯镜像部署不存在这个问题。其中 ./lualib 挂载会整体覆盖 site/lualib，宿主目录缺 lfs.so 时文件浏览会报「lfs 模块不可用」。部署前补一次：docker run --rm --entrypoint sh <image> -c "cat /usr/local/openresty/site/lualib/lfs.so" > ./lualib/lfs.so；新镜像已把 lfs.so 同时烘入内置 /usr/local/openresty/lualib/ 作 cpath 兜底，即使遗漏也不再复发。修改挂载的模板/代码后用 `openresty -t` 检查再重启；修改 `.env` 必须重建容器。

## 附录 C：部署完成检查单（供自动化核对）

```bash
HTTP_PORT=${AUTHZ_HTTP_PORT:-6080}
HTTPS_PORT=${AUTHZ_HTTPS_PORT:-6443}

docker inspect authz --format "{{.State.Status}}"                    # running
docker inspect authz --format "{{.HostConfig.NetworkMode}}"          # host
curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:${HTTP_PORT}/_authz/login"            # 308 (redirect 模式)
curl -skS -o /dev/null -w "%{http_code}" "https://127.0.0.1:${HTTPS_PORT}/_authz/api/session"  # 401
curl -skS -o /dev/null -w "%{http_code}" "https://127.0.0.1:${HTTPS_PORT}/_authz/apps/"               # 302
curl -skS -o /dev/null -w "%{http_code}" "https://127.0.0.1:${HTTPS_PORT}/_authz/login"         # 200
docker exec authz test -s /data/authz/authz.db && echo db-ok                          # db-ok
# 保留前缀域名默认开启，这三项要与上面的通用检查分开看
KEY=$(docker exec authz printenv AUTHZ_API_KEY)                                      # 有预置 Key 才跑
curl -sS -o /dev/null -w "%{http_code}\n" -H 'Host: file-check.example.com' -H "x-api-key: $KEY" "http://127.0.0.1:${HTTP_PORT}/"                    # 200 页面
curl -sS -o /dev/null -w "%{http_code}\n" -H 'Host: file-check.example.com' -H "x-api-key: $KEY" "http://127.0.0.1:${HTTP_PORT}/no-such-file"             # 404 不回落
docker exec authz grep -c authz_app_content /usr/local/openresty/nginx/conf/server.conf                                                          # >=1 模板已渲染
```
