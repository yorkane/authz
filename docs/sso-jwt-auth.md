# OpenResty Authz × NocoBase 认证集成

Authz Gateway 可把 NocoBase 作为可选的远程身份源。NocoBase 只负责校验远程账号并返回
用户名、角色；会话 Cookie、CSRF、Casbin 授权和 SQLite 状态均由本机 OpenResty 管理。

系统只在用户成功登录时从身份源单向读取并记录身份快照。本机启用状态、角色覆盖、会话、
应用绑定和 Casbin 策略不会回写身份源，也不会同步到任何外部网关。

## 认证流程

1. 登录表单选择“本地账户”或“NocoBase”，并提交账号和密码到本机
   `POST /_authz/login`；请求中的 `source` 明确决定认证源，不做隐式回退。
2. `source=local` 只查询本地 `users`；`source=nocobase` 且
   `AUTHZ_NOCO_ENABLED=true` 时只调用 NocoBase。同名账号可分别登录。
3. OpenResty 调用 `POST <AUTHZ_NOCO_URL>/api/auth:signIn`，请求体为
   `{"account":"...","password":"..."}`，请求头包含 `X-Authenticator: basic`。
4. 登录成功后只在内存中使用 NocoBase JWT 调用 `GET /api/auth:check`，读取
   `data.username`、`data.id` 和 `data.roles[].name`。
5. 远程角色按 `AUTHZ_NOCO_ROLE_MAP` 映射到本地固定角色
   `admin/staff/user/viewer`；未知角色忽略，无任何映射时拒绝登录。
6. OpenResty 写入不含密码和 JWT 的 `remote_users` 快照，并签发自己的
   `authz_session` 服务端会话。
7. 管理员可在“用户与角色”覆盖远程账号的有效角色；成功登录只刷新 `remote_roles` 远端记录，
   但不会覆盖本地设置，直到管理员执行“恢复记录角色”。

NocoBase 官方接口参考：

- [Auth SDK](https://docs.nocobase.com/api/sdk/auth/)
- [BaseAuth](https://docs.nocobase.com/api/auth/base-auth)
- [角色与多角色](https://docs.nocobase.com/users-permissions/acl/role)

## 来源感知身份

用户名不是全局身份键。网关以 `用户名 + 来源` 标识身份，并生成稳定的 Casbin 主体：

```text
user:<source>:<username>
user:local:kate
user:nocobase:kate
user:google:kate@example.com
```

- 本地与任意远程来源的同名用户可以同时存在、登录并保持独立会话。
- 角色覆盖、用户直授权、角色分配和会话撤销都精确作用于该来源的身份。
- 管理页的用户选择项同时显示用户名与来源，策略库存储规范身份键。
- 只有 `admin` 可以读取用户列表、应用绑定和 Casbin 策略；其他角色的管理首页只显示当前会话身份与角色。
- 旧版裸用户名策略在数据库初始化时迁移为 `user:local:<username>`。
- 角色主体仍使用 `role:admin`、`role:staff`、`role:user`、`role:viewer`。
- 远程用户不能在本地修改密码，必须回对应身份源修改。
- 本地与远程用户的认证状态都只有“启用/未启用”；管理员设为未启用后会立即撤销该身份的现有会话，后续登录记录不会自动重新启用。
- 只有管理员主动删除用户快照时才清除本机状态、会话和该身份的直接授权；远程身份再次认证后会作为新快照重新创建并默认启用。

## 环境变量

```dotenv
AUTHZ_NOCO_ENABLED=true
AUTHZ_NOCO_URL=https://noco.example.com

# source=target，多个映射用逗号分隔；目标只能是本地四个角色。
AUTHZ_NOCO_ROLE_MAP=root=admin,admin=admin,staff=staff,member=user,user=user,viewer=viewer

AUTHZ_NOCO_CONNECT_TIMEOUT_MS=3000
AUTHZ_NOCO_SEND_TIMEOUT_MS=5000
AUTHZ_NOCO_READ_TIMEOUT_MS=5000
```

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `AUTHZ_NOCO_ENABLED` | `false` | 是否在密码登录表单提供 NocoBase 身份源 |
| `AUTHZ_NOCO_URL` | 空 | NocoBase 站点根地址；开启远程认证时必须配置 |
| `AUTHZ_NOCO_API_KEY` | 空 | 仅供一次性 OAuth Client 注册使用，不注入运行容器 |
| `AUTHZ_NOCO_ROLE_MAP` | 内置安全映射 | 远程角色到本地角色映射 |
| `AUTHZ_NOCO_CONNECT_TIMEOUT_MS` | `3000` | 建连超时 |
| `AUTHZ_NOCO_SEND_TIMEOUT_MS` | `5000` | 发送超时 |
| `AUTHZ_NOCO_READ_TIMEOUT_MS` | `5000` | 响应读取超时 |
| `AUTHZ_NOCO_MAX_BODY_SIZE` | `1048576` | NocoBase JSON 响应最大字节数 |
| `AUTHZ_NOCO_OAUTH_ENABLED` | `false` | 启用 NocoBase OAuth 2.1/OIDC 关联登录 |
| `AUTHZ_NOCO_OAUTH_CLIENT_ID` / `SECRET` | 空 | NocoBase IdP 注册的 Web Client 凭据 |
| `AUTHZ_NOCO_OAUTH_REDIRECT_URI` | 空 | 网关 `/_authz/oauth/callback` 的完整 HTTPS 地址 |
| `AUTHZ_DNS_RESOLVER` | 容器 resolv.conf 首项 | 生产环境需要指定内部 DNS 时覆盖 |
| `AUTHZ_LOGIN_ATTEMPTS` / `AUTHZ_LOGIN_WINDOW` | `10` / `60` | 单 IP 登录尝试次数和窗口秒数 |
| `AUTHZ_COOKIE_SECURE` | `false` | TLS 在上游终止且不传协议头时强制会话 Cookie `Secure` |

## NocoBase 2.2 OAuth 2.1/OIDC

本节以 `docs/thirdparty-oauth-login.md` 的实测流程为唯一依据。NocoBase `2.2.0` 内置
`@nocobase/plugin-idp-oauth`，网关使用 Authorization Code、PKCE S256、一次性 state，
并访问以下协议端点：

```text
<AUTHZ_NOCO_URL>/api/.well-known/openid-configuration
<AUTHZ_NOCO_URL>/api/idpOAuth/authorize
<AUTHZ_NOCO_URL>/api/idpOAuth/token
<AUTHZ_NOCO_URL>/api/idpOAuth/me
```

官方动态注册端点只接受 loopback 回调，公网 Client 通过 `oidcStates:create` collection API
注册，不安装 NocoBase 本地插件，也不直接修改数据库。一次性注册脚本会生成随机 Secret，
使用 `client_secret_basic`、`authorization_code` 和精确 HTTPS 回调，并把运行时凭据写回 `.env`：

```dotenv
AUTHZ_HOST_URL=https://gateway.example.com
AUTHZ_NOCO_URL=https://noco.example.com
AUTHZ_NOCO_API_KEY=<仅具备 oidcStates list/create 权限的 API Key>

# 运行 python3 scripts/register_nocobase_oauth.py 后自动写入：
AUTHZ_NOCO_OAUTH_ENABLED=true
AUTHZ_NOCO_OAUTH_TITLE=NocoBase
AUTHZ_NOCO_OAUTH_CLIENT_ID=openresty-authz-xxxxxxxxxxxx
AUTHZ_NOCO_OAUTH_CLIENT_SECRET=client-secret
AUTHZ_NOCO_OAUTH_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_NOCO_OAUTH_DEFAULT_ROLES=viewer
```

OAuth 与密码登录都使用 `user:nocobase:<username>` 身份键。网关使用 OAuth access token 调用
`/api/idpOAuth/me` 读取标准身份；该端点不返回角色，OAuth 首次登录使用
`AUTHZ_NOCO_OAUTH_DEFAULT_ROLES`，之后由本机管理员覆盖。Token 请求使用 HTTP Basic Client 认证，Client ID/Secret 不放在表单；
回调严格校验 `iss=<AUTHZ_NOCO_URL>/api`。access token 只存在于当前回调请求内存。
未配置 Client 时，登录页显示“NocoBase 登录（待配置）”，不会发起不完整流程。

## Google 与通用 OAuth2/OIDC

网关可直接执行标准 Authorization Code + PKCE 登录，不依赖 NocoBase 安装商业 OIDC 插件。
登录使用一次性 shared-dict `state`，token 仅在请求内存中用于拉取 userinfo，不写入 SQLite、
Cookie 或日志。Google 预设要求 `email_verified=true`。公网 token/userinfo 请求发生连接、断连或
超时等传输失败时自动重试一次；默认建连、发送和读取超时分别为 10、10、15 秒。

Google Cloud Console 中创建 Web application OAuth client，并精确注册回调地址：

```dotenv
AUTHZ_GOOGLE_ENABLED=true
AUTHZ_GOOGLE_CLIENT_ID=example.apps.googleusercontent.com
AUTHZ_GOOGLE_CLIENT_SECRET=replace-me
AUTHZ_GOOGLE_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_GOOGLE_DEFAULT_ROLES=viewer
```

以当前网关入口为例，Google Cloud Console 的 **Authorized redirect URIs** 应填写：

```text
https://6080-241.ws.example.com:99/_authz/oauth/callback
```

配置步骤：

1. 在 Google Cloud Console 配置 OAuth consent screen。
2. 创建 **OAuth client ID → Web application**。
3. 添加上述精确回调 URI，复制 Client ID 与 Client Secret。
4. 写入 `.env` 后使用 `docker compose up -d --force-recreate`；仅 `docker restart` 不会注入新环境变量。

### 钉钉登录

在钉钉开放平台创建应用，启用“钉钉登录与分享”，将同一回调 URI 配入应用，并申请读取
通讯录个人信息所需权限。网关按官方新版流程调用 JSON `userAccessToken` 接口，再使用
`x-acs-dingtalk-access-token` 请求当前用户 `me`：

```dotenv
AUTHZ_DINGTALK_ENABLED=true
AUTHZ_DINGTALK_CLIENT_ID=dingxxxxxxxx
AUTHZ_DINGTALK_CLIENT_SECRET=replace-me
AUTHZ_DINGTALK_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_DINGTALK_DEFAULT_ROLES=viewer
```

若钉钉没有返回个人邮箱，网关使用 `unionId` 的不可逆摘要生成稳定本地用户名；真实
`unionId` 仍作为远程 subject 保存，角色可在用户管理中覆盖。

### 微信开放平台网站登录

微信实现针对**开放平台网站应用微信登录**，不是公众号 `snsapi_base/snsapi_userinfo` 网页授权，
也不是小程序 `code2Session`。应用审核通过并开通微信登录后，配置授权回调域及以下变量：

```dotenv
AUTHZ_WECHAT_ENABLED=true
AUTHZ_WECHAT_APP_ID=wx1234567890
AUTHZ_WECHAT_APP_SECRET=replace-me
AUTHZ_WECHAT_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_WECHAT_DEFAULT_ROLES=viewer
```

网关使用 `snsapi_login`、`qrconnect`、`sns/oauth2/access_token` 和 `sns/userinfo`；用户名由
`unionid/openid` 的不可逆摘要生成。微信开放平台通常要求稳定、已备案的回调域，建议正式部署
使用自有 HTTPS 域名，不使用临时工作区域名。

通用 OAuth2/OIDC provider 必须提供兼容 JSON 的 token 与 userinfo 端点：

```dotenv
AUTHZ_OAUTH_ENABLED=true
AUTHZ_OAUTH_PROVIDER=company
AUTHZ_OAUTH_TITLE=Company SSO
AUTHZ_OAUTH_CLIENT_ID=client-id
AUTHZ_OAUTH_CLIENT_SECRET=client-secret
AUTHZ_OAUTH_AUTHORIZE_URL=https://id.example.com/oauth2/authorize
AUTHZ_OAUTH_TOKEN_URL=https://id.example.com/oauth2/token
AUTHZ_OAUTH_USERINFO_URL=https://id.example.com/oauth2/userinfo
AUTHZ_OAUTH_REDIRECT_URI=https://gateway.example.com/_authz/oauth/callback
AUTHZ_OAUTH_SCOPE=openid email profile
AUTHZ_OAUTH_SUBJECT_CLAIM=sub
AUTHZ_OAUTH_USERNAME_CLAIM=email
AUTHZ_OAUTH_ROLE_CLAIM=roles
AUTHZ_OAUTH_ROLE_MAP=admins=admin,employees=staff,members=user,guests=viewer
AUTHZ_OAUTH_DEFAULT_ROLES=viewer
AUTHZ_OAUTH_REQUIRE_VERIFIED_EMAIL=false
```

`AUTHZ_OAUTH_PROVIDER` 会写入会话和 `remote_users.provider`，只能使用小写字母、数字、点、
下划线或连字符，且不能为 `local`、`nocobase`、`google`。生产 authorize/token/userinfo/
redirect URL 必须使用 HTTPS；`AUTHZ_OAUTH_ALLOW_HTTP=true` 仅供隔离测试。

协议与 Google 配置参考：

- [Google OAuth 2.0 for Web Server Applications](https://developers.google.com/identity/protocols/oauth2/web-server)
- [Google OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect)
- [RFC 7636: PKCE](https://datatracker.ietf.org/doc/html/rfc7636)
- [钉钉：获取用户个人信息教程](https://open.dingtalk.com/document/orgapp/tutorial-obtaining-user-personal-information)
- [钉钉：获取用户 token](https://open.dingtalk.com/document/orgapp/obtain-user-token)
- [微信开放平台：网站应用微信登录](https://developers.weixin.qq.com/doc/oplatform/Website_App/WeChat_Login/Wechat_Login.html)

每个用户的密码只在其登录请求期间转发给 NocoBase，不写入日志或数据库。运行时不接受固定
远端账号，也不需要任何外部网关 Admin API 地址或密钥。

## Docker Compose

```bash
cp .env.example .env
# 编辑 AUTHZ_ADMIN_PASSWORD、AUTHZ_NOCO_ENABLED、AUTHZ_NOCO_URL 和角色映射
docker compose up -d --build
```

启用远程认证后必须使用 HTTPS 的 `AUTHZ_NOCO_URL`。仅隔离测试可以显式设置
`AUTHZ_NOCO_ALLOW_HTTP=true`；生产环境不要设置该变量。镜像内置 CA 证书并启用上游 TLS
证书和主机名校验。

成功登录后，本机会清零该 IP 的登录失败计数；超过窗口阈值返回 429。通过 HTTPS 入口签发的
`authz_session` 自动带 `Secure`；受信任 TLS 终止代理传入 `X-Forwarded-Proto: https` 时同样
生效。如果生产代理不传该头，必须设置 `AUTHZ_COOKIE_SECURE=true`。HTTP 入口仍可用于受控
内网开发。

## 数据边界

| 数据 | 本地是否保存 | 位置 |
|------|--------------|------|
| NocoBase 密码 | 否 | 仅登录请求内存 |
| NocoBase JWT | 否 | 仅 `auth:check` 请求内存 |
| 远程 provider、subject、用户名、最近记录角色、有效角色与覆盖状态 | 是 | SQLite `remote_users` |
| OpenResty 会话 token、CSRF、来源 | 是 | SQLite `sessions` |
| Casbin 策略、应用绑定 | 是 | SQLite `policies`、`bindings` |

远程身份记录只在该用户成功登录时刷新。未设置本地覆盖时，NocoBase/OAuth 角色会在下次登录
记录到本机有效角色；设置覆盖后只更新最近远端角色记录，不改变本机有效角色。整个流程单向，
不会修改 NocoBase 用户或角色。

## 验证

隔离回归测试使用本地 mock NocoBase，不连接生产环境：

```bash
bash test/test_authz_gateway.sh
```

测试覆盖远程登录、`auth:check`、多角色映射、同名多来源身份隔离、旧策略迁移、远端角色记录/本地覆盖、
OAuth state + PKCE + callback、来源级用户直授权、上游身份头，以及本地会话签发。
