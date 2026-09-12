# 管理端 UI 页面/区块参考（对照 admin/ 源码）

管理端是 Vue3 + Quasar UMD 多页应用（无构建步骤），由左侧菜单（SSl include 的
`menu.html`）+ iframe 内容页组成。本文按页面归纳区块与功能，配置助手据此把
用户口述的 UI 操作翻译成 references/api.md 里的 API 调用。

## 0. 框架：index.html + menu.html（左侧菜单）

| 区块 | 功能 | 数据来源 |
|---|---|---|
| 品牌行 | 实例名 + 折叠按钮（收起后仅剩图标，分组仍可点开） | `GET /api/session`（displayName） |
| 菜单列表 | 分组可折叠；子项含图标/标签/备注，当前项高亮；最多两级 | `GET /api/menu-tree` |
| 系统应用组（builtin=domains 同级） | users.html / authorization.html / menu-editor.html 等内嵌页 | menu_entries（builtin 非空受保护） |
| 域名服务组 / 本地服务组 | 运行时注入项（绑定域名 / 自动发现的 HTTP 端口） | menu-services + discovery |
| 页脚 | 退出登录（DELETE /api/session）、中英切换（i18n.js） | — |

前端壳通过 iframe 加载 `/_authz/apps/*.html`；页面内 JS 调 `/_authz/api/*`，
Cookie 会话或 `x-api-key` 头（Playwright setExtraHTTPHeaders）均可认证。

## 1. users.html — 账户与 API Key 管理

| 区块 | 功能 | API |
|---|---|---|
| 统计卡 | 账户数 / 启用数 / 角色数 | `GET /api/users` |
| 账户表 | 本地+远程身份列表；来源徽标；启用开关（admin 自身禁改）；角色徽标 | `GET /api/users` |
| 新建账户对话框 | 用户名+初始密码+多选角色（admin/staff/user/guest） | `POST /api/users` |
| 角色编辑对话框 | 多选角色；远程身份显示 remote_roles 与恢复入口 | `PATCH /api/users/:id` |
| 禁用/删除确认 | 禁用立即断会话；远程记录删除后下次登录重建 | `PATCH`/`DELETE /api/users/:id`、`DELETE /api/remote-users/:provider` |
| 重置密码对话框 | admin 重置他人密码 | `PUT /api/users/:id/password` |
| API 管理卡片（admin） | Key 列表（名称/角色/前缀/状态）、新建（默认 guest）、改角色、轮换、删除 | `GET/POST/PATCH/DELETE /api/api-keys(/:id/rotate)` |
| token 弹窗 | 明文只出现一次，带复制按钮 | rotate/create 响应 |
| 修改密码卡片 | 旧密码+新密码+确认；改完其他会话全下线 | `PUT /api/me/password` |

## 2. authorization.html — 域名绑定与策略

| 区块 | 功能 | API |
|---|---|---|
| 统计卡 | 绑定数 / allow 策略数 / deny 策略数 | `GET /api/authorization` |
| 域名绑定表 | 前缀、端口、协议、目标 IP、菜单名、启停；域名只填最后一级前缀 | `GET/POST/PATCH/DELETE /api/applications` |
| 新增/编辑绑定对话框 | 端口范围提示（PORT_MIN–MAX）、target_ip、upstream_scheme/ssl_verify、origin_mode、simulate_local | 同上 |
| 请求改写子对话框 | request_rewrite 结构化编辑（headers/remove/body/rewrites） | `PATCH /api/applications/:id` |
| 响应改写子对话框 | response_rewrite 编辑（status/headers/body/rewrites，安全头禁改） | 同上 |
| 策略表（带搜索） | 主体/对象/方法/eft，deny 红色标记 | `GET /api/authorization` |
| 新增/编辑策略对话框 | 主体（role:xxx 或用户名）、对象 /<port><path>、方法、deny 开关 | `POST/PATCH/DELETE /api/policies` |

## 3. menu-editor.html — 左侧菜单编辑

| 区块 | 功能 | API |
|---|---|---|
| 分组卡列表 | 系统应用/域名服务两列并排，可折叠；卡片显示类型与子项数 | `GET /api/menu-entries` |
| 条目行 | 图标（MDI 选择器）、标签、URL、显隐开关、排序按钮、编辑/删除 | `PATCH /api/menu-entries/:id`、`PUT /api/menu-entries/reorder` |
| 新增条目对话框 | kind（group/item）、父分组、label、url、icon | `POST /api/menu-entries` |
| 域名/本地服务编辑 | key=`binding:<id>`/`port:<port>`；改名/图标/隐藏/排序；本地服务不可编辑 URL；DELETE=重置覆盖 | `GET /api/menu-services`、`PATCH/DELETE /api/menu-services/:key`、`PUT /api/menu-services/reorder` |
| 保护规则 | 系统应用/域名服务两个 builtin 分组不可删除（409） | — |

## 4. files.html — 文件浏览

| 区块 | 功能 | API |
|---|---|---|
| 工具栏 | 路径导航、刷新 | `GET /api/files?path=` |
| 列表 | 只读列 AUTHZ_FILES_ROOT 目录；沙箱预览依赖 SameSite=None Cookie | 同上 |

## 5. nginx_conf.html — Nginx include 编辑

| 区块 | 功能 | API |
|---|---|---|
| 文件页签 | http_inc.conf / server_inc.conf / stream_inc.conf | `GET /api/nginx-conf` |
| 编辑器 | 256KB 上限；Validate 按钮（staging + openresty -t） | `POST /api/nginx-conf/validate` |
| 保存/重载 | 保存成功才落盘；reload 失败显示 nginx 报错 | `PUT /api/nginx-conf`、`POST /api/nginx-conf/reload` |
| 持久化提示 | 模板目录只读时提示重启丢失 | 响应 `persistent:false` |

 ## 6. /_authz/guest — 访客探针

无管理入口，直接访问 `/_authz/guest`；guest 角色 Key/会话可打开，admin 也可。
 明文完整回显调用者的请求头（含凭据头）/来源 IP/代理转发链（服务端转义）；`?json=1` 返回 JSON。
用于第三方/Agent 链路自检。

## 7. 登录页（ui.lua 服务端渲染）

`GET /_authz/login?next=<路径>`；用户名+密码（或远程身份源按钮）。失败延迟 1s 返回；
同「账户名+IP」连续 5 次失败锁 30 分钟。登录成功后按 Origin/Host 选择 Cookie 域。
