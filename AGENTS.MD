# AGENTS.MD

## 目的与适用范围

本文档用于指导本项目基于 `lualib/klib` 开发 OpenResty APP，重点约束代码注册式 Router、`ctxvar` 请求上下文、模板和本地验证方式。

本文不定义数据库、动态 Router DB 或数据访问规则。APP 路由必须在代码中显式注册，并随代码一起审查、测试和发布。

维护 Authz Gateway 全栈时，同时读取 `docs/maintenance-handbook.md`；项目级维护 Skill 位于
`docs/maintain_skill.md`。

涉及 `ngx`、请求阶段或 worker 生命周期的实现，必须在真实 OpenResty 实例中验证，不能只用系统 Lua 解释器代替。

## 总体设计模式

APP 统一采用“一个 location + 一个主 Router + 代码分支”的模式：

```text
Nginx APP location
  -> require("app.router"):handle()
  -> method + path 匹配
  -> Lua handler
  -> response
```

核心约定：

1. 一个 APP 只设置一个 Nginx Router 入口，不为每一个 API 编写 location。
2. 主 Router 在 Lua 模块加载时创建和注册，同一 worker 内通过 `require` 缓存复用。
3. 子模块通过 `router:merge()` 组合，不在请求期间动态注册或 merge。
4. `router.root_entry` 必须与请求进入 Router 时的 URI 前缀一致。
5. 路由、认证、参数校验、错误处理和模板行为都必须有实际 HTTP 回归测试。

## APP Router 标准示例

```lua
local collect = require "tracker.collect"
local router = require("klib.router").new("/tracker")

local function register(method, rule, handler, template)
    local _, _, err = router:register(rule, handler, method, template)
    assert(not err, err)
end

register("GET", "/", function(params, env)
    return "ok"
end)

register("POST", "/collect/:key", function(params, env, req)
    local headers = env.request_header
    local body = env.request_body
    if body == "" then
        return { err = "request body required" }, 400
    end
    return { key = params.key, accepted = true }, 202
end)

register("GET", "/day_uv/:key", function(params, env)
    local list = collect.get_day_uv(params.key, nil, true)
    return list
end)

local merged, merge_err = router:merge(require("tracker.prometheus_router"), "/p")
assert(merged, merge_err)

return router
```

对应的 Nginx 配置只保留一个 APP 入口，并让 location 前缀与 `root_entry` 一致：

```nginx
location ^~ /tracker {
    content_by_lua_block {
        require("tracker.router"):handle()
    }
}
```

不要将 `router.new("/tracker")` 直接挂到 `location /_api_/`。`ctxvar.uri` 来源于原始请求 URI，location 和普通 rewrite 不会可靠地把它变成 `/tracker`，实测会导致 Router 404。

如果公开入口必须是 `/_api_/`，主 Router 也应使用 `new("/_api_")`，并把 APP 名作为路由规则的一部分；或者在 Router 外明确构造并传入经过测试的自定义 ctx。不要假定 Nginx location 会自动剥离前缀。

## klib.router 约定

### 注册与匹配

- 支持 `GET`、`HEAD`、`POST`、`PUT`、`DELETE`、`OPTIONS`、`PATCH`。
- 路由使用字面量路径和 `:param` 段参数，不把正则、Lua 表达式或外部数据当作路由规则。
- handler 签名固定为 `function(params, env, req)`。
- 路径参数从 `params` 读取；query/body helper 从 `req` 读取；请求上下文从 `env` 读取。
- 静态路径会优先于同层参数路径，例如 `/users/me` 优先于 `/users/:id`，但仍必须补冲突测试。
- method 不匹配、root 不匹配和未知路径统一进入 404 处理。
- `/tracker` 和 `/tracker/` 均可命中注册为 `/` 的根路由，已在 OpenResty 中验证。
- 注册函数会返回第三个错误值；必须检查它。重复的 method + path 和不支持的 method 会被拒绝。

推荐使用小型注册包装器统一检查错误，或逐项断言：

```lua
local _, _, err = router:get("/users/:id", handler)
assert(not err, err)
```

### handler 返回值

- `return table`：Router 序列化为 JSON 文本。
- `return string`：Router 按 HTML/text 输出。
- `return status`：100—599 的整数作为 HTTP 状态码快捷返回，不输出 body。
- `return table_or_string, status`：第二个 number 才会设置 HTTP 状态码。
- `return nil, status`：只设置状态码，不输出 body。
- handler 抛错会被 `xpcall` 捕获，并进入 500 错误处理。

以下写法等价：

```lua
return 404
-- 等价于
return nil, 404
-- 需要响应内容时
return { err = "not found" }, 404
```

table 响应的 Content-Type 固定为 `application/json; charset=UTF-8`，HTML/字符串响应为
`text/html; charset=UTF-8`。这个契约由真实 OpenResty Router 回归覆盖，API 客户端可以据此解析。

### 子 Router、filter 与模板

```lua
-- tracker/router.lua
local router = require("klib.router").new("/tracker")
router:merge(require("tracker.collect_router"), "/collect")
router:merge(require("tracker.prometheus_router"), "/p")
return router
```

- 子 Router 只声明自己的相对规则，主 Router 负责最终路径空间。
- merge 后必须测试完整 URI，例如 `/tracker/p/metrics`。
- `merge()` 成功返回 `true, route_count`，失败返回 `nil, error`；调用方必须检查返回值。
- merge 会先预检全部路由，重复路由或非法注册失败时不会留下部分注册结果。
- 子 Router 的 filter 会复制到 merge 后的对应路由，实测有效。
- 当前 `merge()` 不传递子路由注册时的 `template` 参数；merge 后会输出序列化 table，而不是渲染模板。模板路由应暂时注册在主 Router，或在 handler 中显式调用受控模板渲染，直到框架修复并有测试覆盖。
- `resty.template.safe` 只提供安全的错误返回方式，不是模板沙箱。只渲染代码库内受信任的模板。

### access hook 限制

当前版本不要使用 `router:add_access()`：实例没有初始化 `self.access`，实测调用会立即报错。

`router.pre_access` 可以执行，但当前实现调用它时第一个 `func` 参数仍为 `nil`。不要依赖该参数，也不要把完整认证授权体系建立在这个未完成的 hook 上。认证和授权优先放在经过测试的 `access_by_lua`、handler wrapper 或明确的业务入口中，并保持 fail-closed。

## klib.ctxvar 约定

`ctxvar` 是请求级上下文适配层。正常请求中 `ctxvar.new()` 把对象保存在 `ngx.ctx._env`，同一请求重复调用会得到同一个对象。

常用字段：

- `env.uri`：规范化、无 query 的 URI，也是 Router 默认匹配输入。
- `env.request_uri`：ctxvar 重建的 URI，通常包含 query，但有下述短 query 限制。
- `env.var.request_uri`：需要原始请求 URI 时优先使用。
- `env.method`：HTTP method。
- `env.host`、`env.host_1`、`env.host_2`、`env.host_3`：Host 和域名层级。
- `env.request_header`、`env.cookie`、`env.var`：懒加载请求头、Cookie 和 Nginx 变量。
- `env.uri_args`、`env.post_args`、`env.request_body`：query、form 和原始 body。
- `env.file_format`、`env.is_static`：文件后缀和静态资源判断。
- `env.is_json`：请求 Content-Type 是否包含 `json`。

注意标准字段名是 `env.request_header`，不是 `env.header`。自定义 header 可按原名读取，例如 `env.request_header["X-Request-Id"]`。

### ctxvar 使用规则

- 一个请求只传递一个 env，不把 env 或其子 table 放入跨请求全局缓存。
- 路由参数从 `params` 取，query 从 `req.get_query()` 或 `env.uri_args` 取。
- `env.request_body` 没有 body 时安全返回空字符串，可先用它检查是否为空。
- `env.ip` 会读取转发头。只有可信反向代理已经清洗这些 header 时才能把它当作客户端 IP。
- 不直接修改不存在的 `env.var` 字段；可写 Nginx 变量必须先在配置中用 `set` 声明。
- ctxvar 使用 tablepool；业务 handler 不手工 `dispose()` 或跨请求复用内部 table。

### 已验证限制

1. 当 query string 长度不超过 3 个字符时，例如 `a=1`，`env.query_string` 和 `env.uri_args` 正确，但 `env.request_uri` 会省略 query。需要精确原始值时使用 `env.var.request_uri`。
2. `normalize_url()` 只可靠用于 URI path。绝对 URL 会重复第 9 个字符，例如 `http://example.test` 变成 `http://exxample.test`。
3. `req.get_body_header(env)` 对空 body 返回空字符串，不再抛出异常；对 JSON body 的第二个返回值是 headers table，对 form/空 body 则是 Content-Type string 或 `false`，不要依赖统一类型。
4. timer 模式必须传入 `request_header`：`ctxvar.new({ request_header = {} }, true)`。实测 `ctxvar.new({}, true)` 会把模块级 header 原型设为自引用 metatable，随后读取自定义 header 会出现 `loop in gettable`。在该问题修复前，不允许无 seed 使用 timer ctxvar。

## APP 代码组织

```text
lualib/tracker/
  router.lua                 -- 唯一主 Router
  collect_router.lua         -- collect 子 Router
  prometheus_router.lua      -- prometheus 子 Router
  handlers.lua               -- 输入适配和响应转换
  service.lua                -- 业务规则
  views/                     -- 受信任模板
```

- `router.lua`：创建主 Router、组合子 Router、安装公共行为。
- `*_router.lua`：注册相对路径、method 和 handler。
- `handlers.lua`：读取 `params/env/req`，执行输入校验并调用 service。
- `service.lua`：实现业务规则，不依赖 Nginx location 分支。
- `views/`：只保存受信任模板。

模块拆分使用 Router 和 `merge`，不增加 API 专属 location。

## ngx.re 正则约定

所有匹配、替换、校验一律使用 OpenResty 内置 `ngx.re`（PCRE 标准正则），不使用 Lua 原生
模式（string.find/gsub/match 的 `%d`、`()` 一类）承载业务语义。Lua 原生查找仅允许用于
固定字符串判断（如 `:find("%c")` 控制字符探测）。

- 标志位统一 `"jo"`：PCRE 语法 + `ngx.re` 编译缓存。
- 输入校验：保存前用 `ngx.re.find("authz-probe", source, "jo")` 做 PCRE 编译探测，第三个
  返回值非 nil 即非法正则，直接 422 拒绝。
- 字面量匹配也交给 `ngx.re`：源文本用 `\Q...\E` 逐字引用（文本自带 \E 时按
  「结束引用 + \\E（引用外两个反斜杠=匹配一个字面反斜杠）+ E + \E 重新进入引用」
  规范化）。已在目标引擎（OpenResty 1.31.1.1 / PCRE2）实测：a.b 不匹配 axb，a|b、
  a\Eb 逐字命中。
- 字面量规则的替换值必须经回调原样插回：`ngx.re.gsub(body, quoted, function() return
  replacement end, "jo")`。字符串形式的替换目标会展开 `$N`，写进替换值里的 `$1` 会被吃掉。
- 正则规则用字符串替换目标，`$N` 为捕获组引用（APISIX/nginx 语义），未定义的组展开为空
  串；这是标准行为，文档和 UI 提示里要写明。
- `ngx.re.gsub` 返回 `value, substitutions, err` 三个值：取错误必须接满三个返回值；无匹配
  时返回原文、`substitutions=0`、`err=nil`，不是错误。
- 引用 `\Q`/`\E` 等 Lua 5.1 不认识的转义序列时用 `string.char(92)` 拼接，避免
  `invalid escape sequence` 编译错误。
- 语义疑问用一次性 nginx 配置实测而不是猜：`http { init_worker_by_lua_file ... }` +
  `ngx.timer.at(0, ...)` + `error_log /dev/stderr info`，`--entrypoint openresty` 直跑
  （authz 镜像的 `resty` 缺 perl shebang，镜像 entrypoint 会接管命令）。

已验证实现：`lualib/resty/authz/gateway/rewrite.lua` 的 `apply_rewrites`（请求/响应正文
改写共用），回归用例在 `test/test_authz_gateway.sh`（关键词 `rewrite-pcre`）。

## 请求、安全与错误处理

推荐处理顺序：

```text
读取 env
  -> 输入类型与范围校验
  -> 身份认证
  -> 路由/资源授权
  -> service 业务校验
  -> 业务调用
  -> 统一响应
```

- 无身份返回 401，无权限返回 403，资源不存在返回 404，输入错误返回 400/422。
- 认证、授权、模板和依赖异常必须 fail-closed，不能因异常放行。
- 不记录密码、Cookie、token、Authorization header 或完整敏感 body。
- 默认错误处理不再回显请求 header，但 500 的内部错误文本仍可能包含堆栈。生产 API 必须安装经过测试的 404/500 错误处理器，只返回稳定错误码和通用消息。

## OpenResty 生命周期和配置

- Router 必须在模块级创建。禁止在 `content_by_lua_block` 中每个请求重新 `new()` 和注册。
- `init_by_lua` 只做 master-safe 初始化，不读取请求级 `ngx.var`、`ngx.req` 或 `ngx.ctx`。
- APP location 只调用 `require("app.router"):handle()`，不实现 API 分支。
- Lua 模块路径必须包含项目 `lualib/?.lua`、`lualib/?/init.lua` 和 OpenResty 自带 lualib。
- 新增 vendored Lua 库时同步检查 Dockerfile COPY 路径和容器内 `require`。
- 阻塞式外部 IO 不放入高频请求路径。

## Authz Gateway 的 API 控制（Agent 接入要求）

本仓库自身就是一个 Authz Gateway。Agent（自动化程序）在本机对网关控制面的访问必须遵守以下约定，
不得为绕过认证而修改代码或数据库。

### 认证方式（四选一，按优先级）

1. **实例级预置 API Key（推荐，免登录）**：环境变量 `AUTHZ_API_KEY`（32-256 字符，
   `openssl rand -hex 32` 即可）设定实例的机器 Key，请求头 `x-api-key: <Key>` 提交。
   免登录直接覆盖三类入口：控制面 API（免 CSRF 写操作）、管理页面与静态资源
   （`/_authz/apps/*`，Playwright 用 `setExtraHTTPHeaders` 逐请求附带）、代理入口。
   主体固定 `api-key:0`，角色由 `AUTHZ_API_KEY_ROLE`（默认 admin）决定并走 Casbin 策略；
   来源必须命中 `AUTHZ_API_KEY_ALLOWED_IPS`（逗号分隔 IP/CIDR，默认仅 `127.0.0.1`）。
   不入库、不受管理界面禁用影响，
   随环境变量轮换；配置非法时容器启动即失败。

   ```bash
   curl -H "x-api-key: $AUTHZ_API_KEY" http://127.0.0.1:6080/_authz/api/...
   ```

2. **Agent 专用 API Key**：环境变量 `AUTHZ_AGENT_API_KEY` 指定一个 `ak_<64 hex>` token，
   启动时 seed 为 `agent-default` key（角色 admin、`loopback_only=1`）。使用方式：

   ```bash
   curl -H "x-api-key: $AUTHZ_AGENT_API_KEY" http://127.0.0.1:6080/_authz/api/...
   ```

   该 key **只能从本机回环地址调用**，非回环来源一律 401。值保存在部署目录（如 `/data/app/.env`），
   不入库、不进 git；轮换时改环境变量并重建容器。

3. **普通 API Key**：管理员通过 `POST /_authz/api/api-keys` 创建（新建默认角色 `guest`，
   仅可访问 `/_authz/app/guest.html` 请求诊断页），角色决定控制面与代理权限，
   不限来源但无 CSRF 豁免差异（API key 本身免 CSRF）。
4. **浏览器会话**：人用，修改请求需 `X-CSRF-Token`。Agent 不应使用会话方式，避免 CSRF 与 Cookie 管理。

机器凭证头有两个：`x-role-key`（只认数据库 API Key）与 `x-api-key`（先按 `ak_` 格式查库，
未命中再比对实例级环境变量 Key）；旧 `x-authz-key` 已合并移除。只要呈现了任一凭证头，Key
无效就直接 401，绝不回退到同时携带的 Cookie；这些头被网关剥离，绝不转发上游，绑定级改写
请求也禁止设置它们。

### 控制面路径（全部在 `/_authz` 下）

- 会话：`GET|DELETE /_authz/api/session`
- 用户：`GET|POST /_authz/api/users`、`PATCH|DELETE /_authz/api/users/:id`、`PUT /_authz/api/users/:id/password`
- 绑定（应用）：`GET|POST /_authz/api/applications`、`PATCH|DELETE /_authz/api/applications/:id`
  （`response_rewrite` 字段配置绑定级响应改写，字段与限制见 `docs/core-api.md`）
- 策略：`GET /_authz/api/authorization`、`POST /_authz/api/policies`、`PATCH|DELETE /_authz/api/policies/:id`
- API Key：`GET|POST /_authz/api/api-keys`、`PATCH|DELETE /_authz/api/api-keys/:id`
- Guest 诊断页：`GET /_authz/app/guest.html`（guest/admin 角色；加 `?json=1` 返回 JSON）
  ——回显当次请求的全部请求头、来源 IP 与代理转发头，凭据类头自动脱敏。
- 菜单树：`GET /_authz/api/menu-tree`（渲染用）；`GET|POST /_authz/api/menu-entries`、
  `PUT /_authz/api/menu-entries/reorder`、`PATCH|DELETE /_authz/api/menu-entries/:id`（编辑用）

完整字段与示例见 `docs/core-api.md`。

### 硬性要求

- **只走本机**：Agent 必须在网关宿主机上运行，通过 `127.0.0.1:<AUTHZ_HTTP_PORT>` 访问；
  禁止把控制面端口暴露到公网或跨机访问。
- **请求头**：修改类请求必须带 `Content-Type: application/json`；API key 放 `x-api-key`
  （数据库 Key 也可用 `x-role-key`），不用 Cookie、不用 `Authorization: Bearer`。
- **响应契约**：成功 `{"data": ...}`，失败 `{"error":{"code","message"}}`，JSON 为 UTF-8。
  状态码语义：401 未认证/Key 无效、403 无权限或 CSRF 失败、404 不存在、409 冲突、422 参数校验失败。
- **最小权限**：Agent 用 `AUTHZ_AGENT_API_KEY` 时拥有 admin 权限，只应调用其任务所需的最小接口集合；
  不要把该 key 写入日志、代码或 git。
  写绑定（`POST/PATCH /_authz/api/applications`）时要意识到它包含两条高危能力：
  `target_ip` 等同内网访问能力，`response_rewrite` 会改写返回给浏览器的响应；
  除非任务明确要求，Agent 不得提交 `response_rewrite`，也不得用它改写安全响应头或注入脚本。
- **登录防护**：控制面登录有失败延迟与 `账户名+IP` 锁定（默认 5 次 → 30 分钟）。Agent 不应使用
  用户名密码登录，避免触发锁定。
- **验证义务**：任何依赖这些接口的自动化脚本，必须在真实实例上先做一次 smoke（读 session、列 applications）
  再执行变更；变更类操作后必须复核结果。

### 实现侧要求（修改网关代码时）

- API Key 认证逻辑在 `lualib/resty/authz/api_key.lua`（含 `loopback_only` 强制），
  种子逻辑在 `lualib/resty/authz/db/seed.lua`；改动后必须在真实实例上同时验证
  “回环可用 + 非回环拒绝”两个方向，并更新 `test/test_authz_gateway.sh`。
  实例级 Key（`AUTHZ_API_KEY` / `x-api-key`）由 `config.lua` 的 `configure_api_key` 校验并注入
  `api_key.configure_env`（本模块禁止 require 上层模块，避免 init_by_lua 加载链上的 require 环）；
  比较必须走 `util.constant_time_equals`，角色线在 `gateway/cache.lua` 以 `api-key:0` 注入 Casbin，
  页面免登录放行在 `conf/server.conf.template` 的 access 块（`api_key.authorize_request()`）。
- 新增控制面接口时保持：guard 顺序（会话/API key → admin/roles → CSRF）不变、
  错误结构不变、并同步 `docs/core-api.md` 与本节路径清单。


## 本地回归测试

执行：

```bash
OPENRESTY_TEST_IMAGE=authz:latest bash test/test_klib_router_ctxvar.sh   # Router/ctxvar
OPENRESTY_TEST_IMAGE=authz:latest bash test/test_shared_session.sh       # 共享会话
OPENRESTY_TEST_IMAGE=authz:latest bash test/test_authz_gateway.sh      # authz 网关全量（严格模式，交付前跑这个）
```

改断言口径或只看某一子系统时，别用全量严格跑试错（一轮 ~2 分钟，首个 FAIL 即退出）：

```bash
# 分诊：失败只记一行并继续，末尾汇总全部 FAIL（实测 41s 一轮，注入 2 个坏断言
# 会一次全部暴露）。期间关掉 errexit/nounset，可能出现虚假 PASS，结论只当线索。
KEEP_GOING=1 OPENRESTY_TEST_IMAGE=authz:latest bash test/test_authz_gateway.sh

# 只跑相关段（实测 16s）：段名见脚本内 section 清单
TEST_ONLY=guest,envkey TEST_DEBUG=1 OPENRESTY_TEST_IMAGE=authz:latest bash test/test_authz_gateway.sh
```

段名：`guest` `domain-prefix` `request-rewrite` `body-rewrite` `gzip-negotiation`
`complex-rewrite` `response-rewrite-xss` `menu-tree` `files` `files-legacy`
`nginx-conf` `agent-key` `login-lock` `http-redirect` `cookie-domain`
`rewrite-budget` `envkey`。前缀部分（登录、迁移、绑定、OAuth、远程身份）是共享
前置，任何 TEST_ONLY 都会跑。KEEP_GOING/TEST_ONLY 的结果不能当作交付结论 ——
收尾必须用默认严格模式全量复跑。

可通过 `OPENRESTY_TEST_IMAGE` 覆盖默认镜像。脚本会启动临时 OpenResty 容器，执行配置检查和真实 HTTP 请求，结束后删除测试容器。
三个脚本都会占用随机端口并起常驻 mock，**不要并发跑**（会互相污染日志与端口），也不要在脚本里用裸
`wait` 等待后台请求——常驻 mock 会让 `wait` 永不返回。

最近基线：Router 99、共享会话 29、authz 网关 882（含实例级 API Key x-api-key 免登录、IP/CIDR 白名单、
以及 guest 角色与 `/_authz/app/guest.html` 诊断页套件：默认角色 guest、诊断页 + 只回显自身的
`GET /api/session` 之外的控制面/管理页/文件浏览全拒、回显转义与凭据脱敏、角色升降即时生效、
密钥指纹 `token_prefix` 与 `POST /api/api-keys/:id/rotate` 轮换（旧明文当场失效）。
viewer 角色已退役（迁移 18 把存量 viewer 就地改写为 guest，旧配置里的 `viewer` 值在加载期映射为
guest 并告警，新建时提交 `viewer` 返回 422）。

当前回归覆盖 Router/ctxvar、请求体 helper、框架错误处理和 merge 原子性。最近维护基线为
99 项检查；测试数量会随覆盖增长，应以脚本最终输出为准，包括：

- klib 模块加载和 Nginx 配置检查；
- location/root 前缀不一致、根、静态、单参数、多参数和 method 分发；
- GET/HEAD/POST/PUT/DELETE/OPTIONS/PATCH；
- query、JSON/form/空 body、header、Cookie、IP 和域名层级；
- ctxvar 请求级缓存、URL helper、静态后缀和 timer adapter；
- inline `resty.template` 渲染；
- 状态码、404、500 和 JSON 错误响应；
- merge、子 Router filter、模块级 Router 复用；
- 重复路由和非法 method；
- 本文列出的已知限制。

新增或修改 Router/ctxvar 行为时，必须更新测试夹具和断言，并在真实 OpenResty 中复跑。

## 测试实例（241.t）

`241.t`（10.252.25.241）是本项目专用测试/回归实例，生产实例跑在本机（writer）。

```text
/data/app/authz-test/        # docker-compose.yml + .env + rsync 进来的代码
├── docker-compose.yml       # authz:latest，network_mode: host，端口 6080/6443
├── .env                     # AUTHZ_SESSION_REDIS_MODE=read-only
├── admin/ lualib/ conf/     # 从仓库 rsync（勿 --delete，保留对方 lualib/lfs.so）
```

同步并重建：

```bash
cd /home/aigc/ChatGPT/authz
rsync -a admin conf scripts test docker-entrypoint.sh .env.example 241.t:/data/app/authz-test/
rsync -a lualib/resty 241.t:/data/app/authz-test/lualib/
ssh 241.t 'cd /data/app/authz-test && sudo docker compose up -d --force-recreate'
```

241.t 是共享会话 **reader**，按设计不允许本地登录（本地创建会话返回 503）。在它上面做控制面验证：

- 控制面写操作：用实例自带的 loopback-only Agent Key，请求头 `x-api-key: <key>`；
- 需要已登录会话的代理入口：先在本机 writer（`http://10.252.25.235:6080/_authz/login`）登录，
  取 `authz_session` token 后带 `Cookie: authz_session=<token>` 访问 241.t；
- 退出登录只在 writer 上做，reader 会在下一次请求立刻拒绝该 token（已验证跨实例撤销生效）。

## Code Review Checklist

- [ ] APP 是否只有一个 Router 入口 location？
- [ ] location 前缀是否与 `root_entry` 一致？
- [ ] Router 是否在模块级创建并由 worker 复用？
- [ ] 所有注册错误是否被检查？
- [ ] handler 是否遵循 `params/env/req` 签名？
- [ ] 是否正确使用 `return 404`、`return nil, 404` 或带 body 的状态返回？
- [ ] 是否覆盖静态/参数冲突和 method 不匹配？
- [ ] 子 Router merge 后的完整路径和 filter 是否有测试？
- [ ] 所有 `merge()` 返回错误是否被检查，失败是否保持原子性？
- [ ] 是否避开 merge 模板、`add_access` 和无 seed timer ctxvar 的已知问题？
- [ ] 空 body 和不同 Content-Type 的解析结果是否有测试？
- [ ] 认证、授权和异常是否 fail-closed？
- [ ] 模板是否来自受信任代码？
- [ ] 是否通过 `test/test_klib_router_ctxvar.sh`？
- [ ] 正则/替换是否全部走 `ngx.re`（"jo"），字面量是否 \Q 引用、替换值是否回调插入？
- [ ] 非法正则是否在保存时以 PCRE 编译探测拒绝（而不是运行期才失败）？
- [ ] Dockerfile 是否包含新增 lualib 模块？
