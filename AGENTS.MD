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

## 本地回归测试

执行：

```bash
test/test_klib_router_ctxvar.sh
```

可通过 `OPENRESTY_TEST_IMAGE` 覆盖默认镜像。脚本会启动临时 OpenResty 容器，执行配置检查和真实 HTTP 请求，结束后删除测试容器。

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
- [ ] Dockerfile 是否包含新增 lualib 模块？
