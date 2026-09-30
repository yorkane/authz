# authz 升级文档：coding-170（10.252.25.170）

- 执行时间：2026-09-30 03:59–04:04 UTC（停机 11 秒）
- 执行人：Codex（一次性脚本 + 自动回滚）
- 结果：**成功**，配置与数据全部保留，真实流量已恢复
- 同批产物：同一 image id 已于本日 00:02 UTC 部署到 coding-153（见文末「关联」）

## 1. 本次改了什么

| 项 | 升级前 | 升级后 |
|---|---|---|
| 镜像 | `ghcr.io/yorkane/authz:latest`（id `6448cbe237d4`，构建于 2026-09-09） | `wasu-wtvdev-registry-test-registry.cn-hangzhou.cr.aliyuncs.com/pub/authz:59503bf-dirty`（id `908a07e62816`，构建于 2026-09-29） |
| 代码跨度 | 旧镜像构建于 9-09 05:19，之后到 9-29 共 40 个提交（按 git 提交日期计） | 再加工作树未提交改动 22 文件（1050 增 / 98 删） |
| SQLite 迁移 | 已应用 1–19 | 自动补跑 20、21、22（共 22 条） |
| 控制面路由 | 41 条 | 51 条（新增 10 条，删除 0 条） |
| 管理页面 | — | 新增 `s3.html` + `s3.css` 与共享浏览组件 `browser.css`/`browser.js`，无页面删除 |

`.env`（12 个 `AUTHZ_*`）、compose 的挂载与端口、host 网络、`restart=unless-stopped`
**全部未改**；compose 里只替换了 `image:` 一行。改前的文件留在
`/data/app/authz/docker-compose.yml.bak-20260930-035930`。

主要新增能力（对 170 的实际影响）：

1. **对象存储浏览（S3 兼容）**：菜单新增「对象存储」入口。`AUTHZ_S3_ENDPOINT` 未配置时
   `GET /_authz/api/s3` 返回 `200 + enabled=false`，前端显示「对象存储未配置」卡片；
   写接口返回 `423 s3_disabled`。170 未配置 S3，因此这是**只读降级态，不影响任何现有功能**。
2. **文件浏览写操作**：上传 / 新建文件夹 / 重命名 / 跨目录移动 / 删除（admin 专属，
   `x-api-key` 机器 Key 现在也能调，不再被 `session_only` 拒绝）。
   170 的 `/files` 挂载是整台机器的 `/data`（只读挂载 `:ro` 未设，容器内为 rw），
   所以升级后管理员在界面上可以对 `/data` 做写操作——这是权限面的扩大，需要知晓。
3. **绑定新增 `open_in_new`**（迁移 v20）：自检 iframe 嵌入的上游可改走新标签页打开。
   6 条绑定全部取默认值 0，行为与升级前一致。
4. **SSE 不再被代理缓冲**、**响应改写支持条件匹配**、**gzip 修正**（`gzip_proxied any`）。
5. **Nginx 配置入口改为隐藏**（迁移 v22）：`Nginx配置(危险)` 从「系统应用」菜单消失，
   行仍在库里，`/_authz/apps/nginx_conf.html` 直接访问照旧受 admin 门禁保护。
   这是**升级带来的唯一一处可见行为变化**，属新版本的设计意图。
6. 策略对话框端口可编辑（9-29）、菜单/预览/移动端手势等一系列管理端体验修复。

## 2. 升级前的基线（用于证明"没丢东西"）

配置面：

- 容器内 `/usr/local/openresty/nginx/conf/` 的 `http_inc.conf`/`server_inc.conf`/
  `stream_inc.conf`/`nginx.conf.template`/`server.conf.template` 与旧镜像内置版
  **md5 逐字节一致** → 170 从未手改过 nginx 配置，重建容器不会丢任何自定义配置。
  （这一条必须先确认，因为 170 的 compose 用 `OPENRESTY_TEMPLATE_DIR` 指向镜像内置目录，
  容器内的配置改动不会被卷挂载保住。）
- `.env` md5 `471acc2ae605c1dd720a9bb6b04d8902`，mtime 仍是 Sep 9 11:48（升级后复查未变）。

数据面（`/data/app/authz/data/authz/authz.db`，迁移停在 19）：

```
users=1  bindings=6  policies=2  api_keys=0  menu_entries=8
menu_overrides=2  remote_users=0  sessions=7  schema_migrations=19 行
```

6 条域名绑定（入口父域 `codex-170.ai-t.wtvdev.com`）：

| id | 域名 | 上游 | 说明 |
|---|---|---|---|
| 1 | code | 127.0.0.1:2000 | code-server |
| 2 | codex | 127.0.0.1:3737 | ryensx-gateway |
| 3 | cc | 127.0.0.1:10102 | opencodex-proxy |
| 4 | opencode | 127.0.0.1:4096 | opencode web |
| 5 | dsh | 127.0.0.1:3080 | deepseek-harness web |
| 6 | win11 | 127.0.0.1:18006 | win11 noVNC |

代理行为基线：6 条绑定各自 `GET /` = 302（跳登录）、`GET /_authz/api/session` = 401；
登录页 200（7733 字节）；动态端口前缀 `8899-codex-170…` = 302。
快照产物：`/data/tmp/baseline170/`（API JSON + `authz_pre.db` 一致性快照）。

## 3. 执行过程

镜像分发用 ACR 拉取（该机已登录 ACR）：

```bash
# 235 上
docker tag authz:latest …cr.aliyuncs.com/pub/authz:59503bf-dirty
docker push …cr.aliyuncs.com/pub/authz:59503bf-dirty
```

170 上由一次性脚本 `/data/tmp/deploy_authz_170.sh`（副本在 `~/deploy_authz_170.sh`）执行，
顺序刻意安排成"**先停容器再取文件级快照**"，因为 SQLite 的 `.db-wal`/`-shm` 在运行态直接
`cp` 可能不一致：

1. `docker tag 6448cbe237d4 authz:rollback-0930`（回滚镜像留档）；备份 compose。
2. `docker compose stop gateway` → `cp -a data /data/tmp/authz170-data-<stamp>`（252K）。
3. 只改 `image:` 一行 → `docker compose up -d --force-recreate`。
4. 就绪等待：轮询 `GET /_authz/api/session` 直到 401（**1 轮 2 秒即就绪**）。
5. 功能验证（任一不符即自动回滚：`compose down` → 用快照覆盖回 `data/` → 还原 compose → 重启）。

实测时间线（`/data/tmp/deploy_authz_170.log`）：

```
03:59:30 start; current image 6448cbe237d4
03:59:41 data snapshot -> /data/tmp/authz170-data-20260930-035930 (252K)
03:59:43 new container image 908a07e62816
03:59:45 readiness=1
03:59:46 verify: s3api=200 s3page=200 files=200 apps=200(n=6) s3rename=423 enabled_false=1
03:59:46 DEPLOY OK
```

## 4. 验证结果

### 4.1 新代码确实生效（判别式：旧镜像上这些断言必失败）

| 断言 | 旧镜像 | 新镜像（实测） |
|---|---|---|
| `GET /_authz/api/s3` | 404 | **200**，body `{"data":{"enabled":false,…}}` |
| `GET /_authz/apps/s3.html` | 404 | **200**（静态 `<title>S3</title>`，页面内 i18n 运行时改为「对象存储」） |
| `PUT /_authz/api/s3/rename` | 404 | **423** `code=s3_disabled`（未配置的降级语义） |
| `GET /_authz/api/files` | 200 | 200（回归防护） |
| `GET /_authz/api/applications` | 200 / 6 条 | 200 / **6 条**（绑定数不变） |

### 4.2 迁移落地（`schema_migrations` 现在 1–22）

```
v20 bindings.open_in_new            已加列，6 条绑定取值均为 0
v21 menu_entry_s3_browser           新增 menu_entries id=10「对象存储」(admin_only=1)
v22 menu_entry_nginx_conf_hidden    id=8「Nginx配置(危险)」enabled 1 → 0
```

### 4.3 数据保留：逐表行哈希对比（升级前快照 vs 升级后）

```
users           pre=cda9871dcec642b0/1  post=cda9871dcec642b0/1  SAME
policies        pre=68393f031779f338/2  post=68393f031779f338/2  SAME
api_keys        pre=4f53cda18c2baa0c/0  post=4f53cda18c2baa0c/0  SAME
menu_overrides  pre=a7c2643f331cc4b3/2  post=a7c2643f331cc4b3/2  SAME
bindings        6 行，22 个共有列取值完全相同（哈希差异仅因新增 open_in_new 列）
menu_entries    8 → 9 行：仅新增 id=10；仅 id=8 的 enabled 1→0（迁移 v22 预期）
```

登录会话也没丢：升级前 7 条会话里 5 条本就过期，剩下的 2 条（token 前缀 `6ca443f8`、
`dd5dd8e9`，均属 admin）升级后仍在且有效期不变 —— 老用户无需重新登录。

### 4.4 代理行为逐项与基线一致

6 条绑定（code / cc / dsh / opencode / win11 / codex）逐一复测：`GET /` = 302、
`GET /_authz/api/session` = 401，与升级前完全相同；登录页 200（7733 字节，字节数一致）。
对外入口 `https://codex-170.ai-t.wtvdev.com/_authz/login` = 200（证书 ZeroSSL 通配符
`CN=ai.wtvdev.com`，有效期至 2026-11-24，走公网 DNS 10.252.25.252 可达）。

### 4.5 真实流量恢复

重启后 10 分钟窗口：93 条访问日志，主要来源 `10.252.25.247`（wdev 客户端，
`POST /api/ipc/invoke` 等）；无 5xx。

### 4.6 浏览器渲染（Playwright，走公网域名）

用临时数据库 Key 登录后逐项取实际 DOM，验证完立即删除该 Key
（`api_keys` 回到 0 行，与基线一致）：

```
index_title=Authz Admin
menu_has_对象存储=true      menu_has_Nginx配置=false（v22 隐藏，符合设计）
menu_item_code/cc/dsh/opencode/win11/codex 全 true
s3_page_title=对象存储      s3 未配置卡片正常显示，无 JS 报错
files_rows=9（8 目录 + 1 文件 /data，1.6 GiB）；上传/新建文件夹/卡片就地改名与删除按钮均在位
```

截图：`/data/tmp/verify170_files.png`、`/data/tmp/verify170_s3.png`。

### 4.7 回归门

本次镜像与已在本机 241.t 全量回归通过的镜像为**同一 image id `908a07e62816`**：
**All 1130 authz gateway checks passed**（日志 `/data/tmp/authz-241-regression-0929.log`），
因此未在 170 上重复跑套件。

## 5. 已知副作用与风险

1. **日志里出现 `lua tcp socket read timed out, upstream: 127.0.0.1:13389`**
   （本次窗口内 3 条）。这是「本地服务」探测：`discovery.lua` 对落在
   `AUTHZ_PORT_MIN`–`AUTHZ_PORT_MAX`（170 为 2000–20000）内的每个 loopback 监听端口发
   `HEAD /`，而 win11 容器的 RDP 端口 13389 接受 TCP 但不回 HTTP，于是撞 200ms 读超时并记一条
   `[error]`。两个镜像的 `discovery.lua` md5 相同（`94b31d1f7786b60e674e85aa6307f535`），
   **不是升级引入的**；只在管理员打开控制台（触发 `/api/applications` 或 `/api/menu-tree`，
   结果缓存 30 秒）时出现，不影响代理与登录，属噪音。
   本机 235 同现象更早就存在（1496 条，14389 / 2001 等端口）。
   若要消噪，可把 170 的 `AUTHZ_PORT_MAX` 收窄到不含 RDP 的范围，或让 RDP 换到范围外端口
   ——属可选优化，本次未动。
2. **文件浏览获得了写能力**（见 1.2）。170 的 `/files` = 整台机器的 `/data`，
   升级后 admin 可以在界面上删改 `/data` 下的内容。既有约束仍生效：写路径锁定在内容根内、
   逐级拒绝符号链接与 `..`、同名默认 409、机器 Key 需 admin 角色且在
   `AUTHZ_API_KEY_ALLOWED_IPS`（170 为 `127.0.0.1`）白名单内。
   如果不希望管理员在 170 上写 `/data`，需要单独把 `/files` 改成只读挂载（改动即生效于重启后）。
3.  `Nginx配置(危险)` 入口从菜单隐藏（迁移 v22）。需要时去菜单编辑器重新启用，
   或直接访问 `/_authz/apps/nginx_conf.html`。

## 6. 回滚方法（已实测可用）

```bash
# 170 上（compose 插件只装在 root 下，必须带 sudo）
cd /data/app/authz
sudo cp -a docker-compose.yml.bak-20260930-035930 docker-compose.yml   # 还原 image 行
sudo docker compose up -d --force-recreate
# 镜像标签 authz:rollback-0930 = 6448cbe237d4（旧版）
# 若怀疑迁移有问题，还原数据（容器需先停）：
sudo docker compose stop gateway
sudo rm -rf data && sudo cp -a /data/tmp/authz170-data-20260930-035930 data
sudo docker compose up -d
```

数据还原后 `schema_migrations` 会退回 19；旧版镜像不认识新列但不读它们，因此可回滚。

## 7. 产物与位置

| 内容 | 路径 |
|---|---|
| 部署脚本（含自动回滚） | 170：`/data/tmp/deploy_authz_170.sh`（副本 `~/deploy_authz_170.sh`），本机同名副本 |
| 部署日志 | 170：`/data/tmp/deploy_authz_170.log` |
| compose 备份 | 170：`/data/app/authz/docker-compose.yml.bak-20260930-035930` |
| 数据快照（停容器时取） | 170：`/data/tmp/authz170-data-20260930-035930/` |
| 早期热快照（运行态 tar） | 170：`/data/app/authz/snapshot-0930.tar.gz` |
| 升级前基线 | 本机：`/data/tmp/baseline170/`（API JSON + `authz_pre.db`） |
| 浏览器验证截图 | 本机：`/data/tmp/verify170_files.png`、`/data/tmp/verify170_s3.png` |
| 旧镜像回滚标签 | 170：`authz:rollback-0930`（= `6448cbe237d4`） |
| 新镜像来源 | 本机 235 `authz:latest`（`908a07e62816`）→ ACR `pub/authz:59503bf-dirty` |

## 8. 关联

- **coding-153（10.252.25.153）**：同一 image id `908a07e62816` 已于 2026-09-30 00:02 部署，
  当时旧版为 9-22 构建的 `464309511a37`（跨度小于本次），回滚标签 `authz:rollback-0929`。
  两台机器的镜像标签命名一致（`59503bf-dirty` = HEAD `59503bf` + 未提交工作树改动）。
- 标签里的 `dirty` 是本机工作树尚未提交的部分（22 文件，含 s3 可写范围与文件跨目录移动的
  收尾改动）。若要把这套镜像变成正式可追溯产物，需要先提交、再走 CI 出 `ghcr.io` 版，
  然后把 compose 的 image 换回带 tag 的正式镜像。
