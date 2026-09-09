---
name: authz-helper
description: 配置 Authz Gateway 实例的助手：用 x-api-key 走控制面 API 完成加角色配权限、按本地服务名配域名入口、改写请求头/响应体、开放第三方接口、管理 API Key 与左侧菜单。用于用户要求"给 authz 网关配一个 XX 服务/域名/权限/Key/改写"时；不用于修改网关自身代码（那是 docs/maintain_skill.md 的维护场景）。
---

# Authz Gateway 配置助手

通过控制面 API（`/_authz/api/*`，X-API-KEY 认证）对已部署的 authz 实例做配置，
全程无需浏览器登录。所有端点字段、校验规则与安全约束见
[references/api.md](references/api.md)，动手前先通读一遍。

## 凭证与目标实例

默认目标：本机实例，网关地址 `http://127.0.0.1:6080`（公网入口见实例 `.env` 的
`AUTHZ_HOST_URL`）。凭证取自部署目录的 `.env`（本机为 `/data/app/.env`）：

- `AUTHZ_API_KEY` — 实例级 Key，`x-api-key` 提交，免登录、免 CSRF，来源受
  `AUTHZ_API_KEY_ALLOWED_IPS` 限制（默认仅 127.0.0.1）。默认值内置为
  `eeeec9f034335f136f87ad84b625ffff`（角色 admin），本机/测试实例开箱即可读写；
  生产实例应已更换，以部署目录 `.env` 的实际值为准。

```bash
source <(grep -E '^AUTHZ_API_KEY=' /data/app/.env)
azctl() { curl -sS -H "x-api-key: $AUTHZ_API_KEY" "http://127.0.0.1:6080/_authz/api$1"; }
```

- 换实例（如 241.t）时只改网关地址与 `.env` 路径，其余命令不变。
- 任何 Key 都不要打印到输出、日志或回复里；`echo` 变量前先脱敏。
- 兜底：`.env` 缺失或未含该行时，本机/测试实例可直接用内置默认值
  `eeeec9f034335f136f87ad84b625ffff`（仍受 ALLOWED_IPS 限制）；401 时按硬性规则停止。

## 助手脚本

`scripts/azctl.sh` 封装了最常用的读写（login smoke、绑定增删查、策略增删查、
Key 增删、菜单树读取）。优先用它，避免每次手写 curl：

```bash
scripts/azctl.sh -g http://127.0.0.1:6080 -k "$AUTHZ_API_KEY" smoke
scripts/azctl.sh ... apps-list | apps-add | apps-patch | apps-del
scripts/azctl.sh ... pol-list | pol-add | pol-del
scripts/azctl.sh ... keys-list | keys-add | keys-del
scripts/azctl.sh ... menu
```

复杂字段（`response_rewrite`、`header_overrides`、`origin_mode`）仍用 curl + JSON
直发 API，示例见 references/api.md。

管理端各页面（users/authorization/menu-editor/files/nginx_conf）的区块与功能
对照见 [references/ui.md](references/ui.md)；`testcase/ui_api_tests.sh` 是按页面
功能块组织的可执行回归（41 项，幂等自清理），改完配置可跑一遍验证。

## 常见任务速查

- 增加角色/用户：本地角色目录固定 `admin/staff/user/guest`，**没有动态新建角色的 API**；
  给用户配角色走 `POST/PATCH /users`，给 Key 配角色走 `POST/PATCH /api-keys`。
- 给某角色/用户放行某服务：`POST /policies`（ptype=p，主体 `role:staff` 或
  `user:local:alice`，对象 `/<port>/*`，方法 `*` 或具体方法）。deny 优先于 allow，
  收紧用 `eft=deny`。
- 按本地服务名配域名：`POST /applications`，`domain` 只填最后一级前缀（如 `code`），
  网关按当前请求 Host 拼 `<前缀>-<节点>.<域名>`；用户说完整域名时先确认他指的是哪个
  入口域，再决定填前缀还是精确域名。
- 改写请求头：绑定字段 `header_overrides`（多行 `Name: value`），Host/Cookie/Origin/
  X-Authz-*/X-Forwarded-*/X-Real-IP/hop-by-hop 一律拒；另有 `upstream_host`、
  `forwarded_*`、`origin_mode` 等结构字段。
- 改写响应体：绑定字段 `response_rewrite`（APISIX 语义子集：status/headers/
  remove_headers/body/body_base64/content_type/rewrites）。这是高危能力：
  只改用户明确要求的绑定，禁止改写安全响应头（CSP/HSTS/XFO 等）或注入脚本。
- 开放接口给第三方：`POST /api-keys`（名字体现用途，角色最小化：只读诊断给
  `guest`，调控制面给 `api`/`staff`/`admin`），把一次性返回的 `token` 交给用户保管；
  需要限来源时用 `AUTHZ_API_KEY_ALLOWED_IPS`（实例级 Key）或改用数据库 Key。
  创建后必须把 Key 的用法说明交给用户（携带头 `x-api-key`、三类入口、角色权限边界、
  上游身份头、保管要求），完整文案见 references/api.md §2。
- 菜单：`GET /menu-tree` 看现状；自定义分组/条目走 `menu-entries`；调整
  「域名服务/本地服务」组内项的名字、图标、顺序、隐藏走 `menu-services/:key`
  （key 形如 `binding:3` / `port:2077`）。

## 硬性规则

## 相关 skill（场景分流）

- 部署 / 备份 / 升级 / 排障 / 日志 / 多实例共享会话 → 用 `authz-ops`（运维场景）。
- 改网关自身代码、模板或测试 → 读 `docs/maintain_skill.md`（维护场景）。

本 skill 只负责"配什么"，不管"实例怎么起、怎么备份、怎么排障"。

1. 变更类操作前先读现状（`GET /applications`、`GET /policies` 等），避免重复绑定
   （409）或误删；操作后必须复核读回结果。
2. 401 停止（Key 无效/来源不在白名单，请求管理员处理），403 停止（角色或策略拒绝，
   不尝试越权），422 按 message 修参重试。
3. `POST /api-keys` 与 `POST /api-keys/:id/rotate` 的 `token` 只出现一次：立即在回复中
   完整交给用户并提醒保存，不写进日志与 git；之后无法找回，只能轮换或重建。
4. 写绑定（`target_ip` 可指向内网）与 `response_rewrite` 属高危能力，只执行用户
   明确提出的配置，不做"顺手"的批量修改。
5. 本 skill 只调 API 做配置；修改网关代码/模板/测试属于维护场景，读
   `docs/maintain_skill.md` 走维护流程。
