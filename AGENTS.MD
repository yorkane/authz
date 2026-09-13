# AGENTS.MD

本文件只保留 Agent 必须遵守的核心规则与发布/测试步骤。
开发示例、框架细节与历史经验一律看 [docs/maintenance-handbook.md](docs/maintenance-handbook.md)（附录 A：klib Router/ctxvar/ngx.re；附录 B：Agent 接入与实现细节；附录 C：APP Code Review Checklist）。

按场景选择 Skill：

| 场景 | Skill |
|---|---|
| 配服务 / 域名 / 权限 / API Key / 菜单 / 改写 | `skill/authz-helper` |
| 部署 / 备份 / 升级 / 排障 / 日志 / 多实例 | `skill/authz-ops` |
| 改网关自身代码 / 模板 / 测试 | `docs/maintain_skill.md` + 维护手册 |

## 开发红线（必须遵守）

- 涉及 `ngx`、请求阶段或 worker 生命周期的实现，必须在真实 OpenResty 实例中验证，不能用系统 Lua 代替。
- APP 只有一个 Router 入口 location；`root_entry` 与 location 前缀一致；Router 模块级创建；`register`/`merge` 的错误返回值必须检查。
- 认证、授权、模板与依赖异常一律 fail-closed；无身份 401、无权限 403、不存在 404、输入错 400/422。
- 不记录密码、Cookie、token、Authorization 或完整敏感 body；不打印 API Key。
- 正则一律 `ngx.re` + `"jo"`，字面量用 `\Q...\E` 引用，替换值用回调原样插回；非法正则在保存时用 PCRE 编译探测拒绝。
- 语义疑问用一次性 nginx 配置实测，不猜。
- Admin UI 的 HTML/JS 改动：同步升级 `?v=` 版本位；热补丁 `docker cp` 时必须同时删同名 `.br` 侧车（否则 `brotli_static` 持续下发旧内容）。

## Agent 控制面接入（硬性）

- 凭证只走请求头 `x-api-key`（实例级 `AUTHZ_API_KEY`，或数据库 Key；`x-role-key` 仅数据库 Key）。Key 只从部署目录 `.env` 读取，禁止打印；401 即停，禁止猜 Key、禁止重置 admin 密码。
- 只从网关宿主机经 `127.0.0.1:<AUTHZ_HTTP_PORT>` 访问控制面；修改请求带 `Content-Type: application/json`；响应契约 `{"data":...}` / `{"error":{code,message}}`。
- 先用只读 smoke（`GET /_authz/api/session`、`GET /_authz/api/applications`）确认身份，再做变更；变更后必须复核。
- 未经任务明确要求，不提交 `response_rewrite`，不写策略放宽权限；登录界面有失败延迟与账户+IP 锁定，Agent 不使用用户名密码登录。
- 新增控制面接口：保持 guard 顺序（会话/API key → admin/roles → CSRF）与错误结构不变，同步 `docs/core-api.md`，并在真实实例回归。

## 测试步骤

```bash
# 交付前：本机镜像全量严格回归（首个 FAIL 即退出，~2 分钟）
OPENRESTY_TEST_IMAGE=authz:latest bash test/test_authz_gateway.sh
OPENRESTY_TEST_IMAGE=authz:latest bash test/test_klib_router_ctxvar.sh   # Router/ctxvar
OPENRESTY_TEST_IMAGE=authz:latest bash test/test_shared_session.sh       # 共享会话

# 分诊（结论只当线索，交付结论必须回到严格模式全量）：
KEEP_GOING=1 OPENRESTY_TEST_IMAGE=authz:latest bash test/test_authz_gateway.sh            # 跑完全部 FAIL
TEST_ONLY=guest,envkey OPENRESTY_TEST_IMAGE=authz:latest bash test/test_authz_gateway.sh  # 只跑相关段
```

- 三组脚本都占随机端口并起常驻 mock，**必须串行**；不要在脚本里用裸 `wait`。
- 行为变更必须同步增改真实 HTTP 断言。最近基线：Router 99、Authz 882、共享会话 29。
- 所有回归测试一律在 241.t 上跑；**除非用户明确要求，不向本机生产实例部署新代码或镜像**。

### 241.t 测试实例（共享会话 reader）

```bash
cd /home/aigc/ChatGPT/authz
rsync -a admin conf scripts test docker-entrypoint.sh .env.example 241.t:/data/app/authz-test/
rsync -a lualib/resty 241.t:/data/app/authz-test/lualib/   # 勿 --delete，保留对方 lfs.so
ssh 241.t 'cd /data/app/authz-test && sudo docker compose up -d --force-recreate'
ssh 241.t 'cd /data/app/authz-test && sudo OPENRESTY_TEST_IMAGE=authz:latest bash test/test_authz_gateway.sh'
```

241.t 按设计不允许本地登录（503）：控制面写操作用 x-api-key；需要已登录会话时先到本机 writer（`http://10.252.25.235:6080/_authz/login`）登录取 `authz_session` 再带 Cookie 访问；退出只在 writer 上做（跨实例撤销已验证）。

### 页面测试（playwright-cli，免认证）

playwright-cli 没有全局 `--header`，用 `run-code` 给页面上下文注入 Key（沙箱里没有 `process.env`，Key 用 shell 插值）：

```bash
KEY=$(docker exec authz printenv AUTHZ_API_KEY)
playwright-cli run-code "async page => {
  await page.setExtraHTTPHeaders({ 'x-api-key': '$KEY' });
  await page.goto('http://127.0.0.1:6080/_authz/apps/');
}"
```

- 注入后 `goto`/`click` 与全部子资源自动带 Key；`/api/session` 回 `"auth_type":"api_key"` 即成功。
- 自签 HTTPS(6443) 在已开会话里无法忽略证书错误，直接测 http 6080。
- 页面断言用 `waitForFunction`/`waitForSelector`，不要用 `networkidle`（iframe 轮询不收敛）；不要搭本地注入代理。

## 发布步骤

1. `git diff --check` + 本机全量严格回归通过（见上）；
2. `git push origin main` → GitHub Actions 自动构建并推送 `ghcr.io/yorkane/authz`（查看该 workflow 状态确认 success）；
3. 本机实例升级（仅用户要求时）：`cd /home/aigc/ChatGPT/authz && docker build -t authz:latest .`（复用缓存，秒级）→ `cd /data/app && docker compose up -d --force-recreate gateway`；
4. 模板变更注意本机挂载了 `/data/app/data/authz/conf` 作模板目录，必须同步该目录再重建，否则新镜像配旧模板静默缺项；
5. 发布后验证：登录页 200、session API、受保护代理、（若涉及）x-api-key 免登录三个入口；
6. 本地构建细节与排障见 deploy.md §8.1（builder 代理坑、多核参数在 Dockerfile `RESTY_J`）。

