# 第三方系统接入 NocoBase OAuth 登录（idp-oauth 标准流程配置手册）

> 场景：**用户在 NocoBase 登录 → 授权 → 登录第三方系统**（NocoBase 是 IdP，第三方系统是 OAuth Client）
> 实例：<AUTHZ_NOCO_URL>（NocoBase 2.2.0，idp-oauth 内置已启用）
> 无需 auth-oidc（那是反方向的商业插件），本方案零付费、零实例修改。
> 以下全部内容已于 2026-08-23 实测验证通过。

---

## A. NocoBase 侧（管理员，一次性操作）

### A.1 注册 Client（关键步骤）

**推荐方式：纯 API 注册（无需碰数据库）**。`oidcStates` 是 NocoBase 标准 collection，自动暴露 REST API，已于 2026-08-23 实测：管理员 token 和 API Key（`Authorization: Bearer <apikey>`）均可直接创建/查询/删除 client，redirect_uri 支持任意公网地址，authorize 立即识别（303）。

> 为什么不用官方动态注册端点：`POST /api/idpOAuth/register` 硬编码只允许 loopback redirect_uri（源码 `assertRegistrationRedirectUris`），公网回调走不通。collection API 无此限制。

**第三方系统自助注册（仅需一个 NocoBase API Key）**：

```bash
curl -X POST <AUTHZ_NOCO_URL>/api/oidcStates:create \
  -H "Authorization: Bearer <AUTHZ_NOCO_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Client",
    "oidcId": "my-app",
    "payload": {
      "client_id": "my-app",
      "client_name": "我的第三方应用",
      "client_secret": "<openssl rand -base64 32>",
      "redirect_uris": ["https://你的第三方域名/oauth/callback"],
      "grant_types": ["authorization_code", "refresh_token"],
      "response_types": ["code"],
      "token_endpoint_auth_method": "client_secret_basic",
      "scope": "openid profile email offline_access api",
      "application_type": "web",
      "subject_type": "public",
      "id_token_signed_response_alg": "RS256",
      "client_id_issued_at": 1787479835,
      "client_secret_expires_at": 0,
      "post_logout_redirect_uris": [],
      "require_auth_time": false,
      "require_pushed_authorization_requests": false,
      "dpop_bound_access_tokens": false
    }
  }'
```

**配套管理 API**（同样 API Key 认证）：

```bash
# 列出所有已注册 client
curl "<AUTHZ_NOCO_URL>/api/oidcStates:list?filter=%7B%22model%22%3A%22Client%22%7D&fields=id,oidcId" \
  -H "Authorization: Bearer <API_KEY>"

# 删除（按主键或按条件）
curl -X DELETE "<AUTHZ_NOCO_URL>/api/oidcStates:destroy?filterByTk=<id>" -H "Authorization: Bearer <API_KEY>"
curl -X DELETE "<AUTHZ_NOCO_URL>/api/oidcStates:destroy?filter=%7B%22oidcId%22%3A%22my-app%22%7D" -H "Authorization: Bearer <API_KEY>"
```

**API Key 发放与角色授权**（管理员一次性操作）：

```bash
# 1. 创建 API Key（返回 data.token 即 Key）
curl -X POST <AUTHZ_NOCO_URL>/api/apiKeys:create \
  -H "Authorization: Bearer <ADMIN_TOKEN>" -H "Content-Type: application/json" \
  -d '{"name":"remote-system-reg","role":{"name":"member"},"expiresIn":"315360000"}'

# 2. 给角色授权 oidcStates 的 list/create/destroy（2026-08-23 实测，非 root 角色必须）
#    list 字段刻意不含 payload——payload 含所有 client 的 secret，授权后即泄露
curl -X POST <AUTHZ_NOCO_URL>/api/roles/member/dataSourceResources \
  -H "Authorization: Bearer <ADMIN_TOKEN>" -H "Content-Type: application/json" \
  -d '{"dataSourceKey":"main","name":"oidcStates","usingActionsConfig":true,
       "actions":[{"name":"list","fields":["id","model","oidcId","createdAt","updatedAt"]},
                  {"name":"create"},{"name":"destroy"}]}'

# 3. 修改已授权限（filter 必须放 query string）
curl -X POST "<AUTHZ_NOCO_URL>/api/roles/member/dataSourceResources:update?filter%5BdataSourceKey%5D=main&filter%5Bname%5D=oidcStates" \
  -H "Authorization: Bearer <ADMIN_TOKEN>" -H "Content-Type: application/json" \
  -d '{"actions":[...]}'
```

> **实测记录（2026-08-23，member 角色 key）**：
> - 授权前 `oidcStates:*` 全部 `No permissions`（member 默认 strategy `view:own`，root 才走超管旁路）
> - 授权后 create/list/destroy 全通；注册公网回调 client 后 authorize 立即 303 接受
> - 权限隔离良好：member key 仍不能读 users 等其他表数据
> - **安全要点**：`list` 的 fields 绝不能含 `payload`（否则一个第三方可看到所有 client 的 secret）；`create/destroy` 无字段限制也无碍（create 是写入自己的，destroy 建议按需收窄）

**备选方式：直接 DB 插入**（无 API Key 场景，PG 连接信息见项目 `.env`）：

PG 连接信息见项目 `.env`（`PGHOST=64.186.236.113` 等）。

```sql
INSERT INTO "oidcStates" ("createdAt", "updatedAt", model, "oidcId", payload) VALUES (
  now(), now(), 'Client',                -- model 固定为 'Client'
  'my-app',                              -- client_id（自定义，即 oidcId）
  '{
    "application_type": "web",
    "grant_types": ["authorization_code", "refresh_token"],
    "id_token_signed_response_alg": "RS256",
    "require_auth_time": false,
    "response_types": ["code"],
    "subject_type": "public",
    "token_endpoint_auth_method": "client_secret_basic",
    "post_logout_redirect_uris": [],
    "require_pushed_authorization_requests": false,
    "dpop_bound_access_tokens": false,
    "client_id_issued_at": 1787479835,
    "client_id": "my-app",
    "client_name": "我的第三方应用",
    "client_secret_expires_at": 0,
    "client_secret": "请生成一个强随机密钥",
    "redirect_uris": ["https://你的第三方域名/oauth/callback"],
    "scope": "openid profile email offline_access api"
  }'
);
```

**字段说明**：

| 字段 | 说明 |
|------|------|
| `model` + `oidcId` | 固定 `'Client'` + client_id（两处保持一致） |
| `client_id` | 自定义，建议短横线小写（如 `my-app`） |
| `client_name` | 显示在 NocoBase 授权确认页的应用名 |
| `client_secret` | 强随机串（`openssl rand -base64 32`），第三方系统换 token 时用 |
| `redirect_uris` | 第三方回调 URL 数组，**必须精确匹配**（协议/域名/端口/路径） |
| `token_endpoint_auth_method` | `client_secret_basic`（推荐，标准 Basic Auth）或 `none`（纯 PKCE 公共客户端） |
| `grant_types` | 授权码流程必备 `authorization_code`；要刷新 token 加 `refresh_token` |
| `scope` | client 允许的 scope 白名单；含 `offline_access` 才能下发 refresh_token |

**生成随机密钥**：
```bash
openssl rand -base64 32
```

### A.2 管理 Client（DB 备选）

```sql
-- 查看所有已注册 client
SELECT "oidcId", payload->>'client_name', payload->>'redirect_uris'
FROM "oidcStates" WHERE model = 'Client';

-- 删除 client（连带授权记录）
DELETE FROM "oidcStates" WHERE model = 'Client' AND "oidcId" = 'my-app';
-- 同时清理该 client 的授权（可选）
DELETE FROM "oidcStates" WHERE payload->>'clientId' = 'my-app';
```

> 注意：删除 client 后，已签发的 access_token 到期前仍有效；如需立即失效，按 `grantId` 一并清理。

### A.3 为什么不能走官方动态注册端点（背景）

源码 `provider-dispatch.js` 中 `assertRegistrationRedirectUris` 对 `POST /idpOAuth/register` 硬校验：
`redirect_uris must only contain http loopback callback URLs with an explicit port`。
仅本地 CLI/桌面工具（`http://127.0.0.1:PORT` 回调）可用动态注册；Web 系统一律用 A.1 的 collection API（推荐）或 DB 插入方式。

---

## B. 第三方系统侧（标准 OIDC Client 配置）

### B.1 端点配置（填入你的 OIDC 库 / 手工对接均可）

| 配置项 | 值 |
|--------|-----|
| Issuer | `<AUTHZ_NOCO_URL>/api` |
| Authorization endpoint | `<AUTHZ_NOCO_URL>/api/idpOAuth/authorize` |
| Token endpoint | `<AUTHZ_NOCO_URL>/api/idpOAuth/token` |
| UserInfo endpoint | `<AUTHZ_NOCO_URL>/api/idpOAuth/me` |
| JWKS | `<AUTHZ_NOCO_URL>/api/idpOAuth/jwks` |
| Revocation | `<AUTHZ_NOCO_URL>/api/idpOAuth/revoke` |
| End session | `<AUTHZ_NOCO_URL>/api/idpOAuth/end-session` |
| Client ID / Secret | A.1 中设定的值 |
| Redirect URI | A.1 中注册的值（精确匹配） |
| Scopes | `openid profile email`（调 API 再加 `api`；要刷新加 `offline_access`） |
| PKCE | **强制 S256**（源码 `required: () => true`，不可关闭） |
| Client auth | `client_secret_basic`（Header: `Authorization: Basic base64(id:secret)`） |

Discovery 可自动读取：
```bash
curl -s <AUTHZ_NOCO_URL>/api/.well-known/openid-configuration | python3 -m json.tool
```

通用 OIDC 库（如 `openid-client`、passport-oidc 等）用 issuer 地址即可自动完成配置。

### B.2 时效与令牌

| 项 | 值 | 说明 |
|----|-----|------|
| authorization code | 60s | 用后即毁，需立即换 token |
| access_token | 86400s（默认） | JWT，RS256 签名 |
| id_token | 3600s | **只含 sub 等标准字段，email/name 必须从 userinfo 获取** |
| refresh_token | 会话策略周期 | 需满足 3 个条件：① client 注册 `refresh_token` grant ② scope 含 `offline_access` ③ **authorize 请求带 `prompt=consent`**（OIDC 规范要求，缺省则 offline_access 被服务端静默剥离，实测确认） |
| state/iss 校验 | 必须 | 回调 `iss` 恒为 `<AUTHZ_NOCO_URL>/api` |

---

## C. 完整流程（含可直接运行的代码）

### C.1 登录入口（第三方系统 → 浏览器重定向到 NocoBase）

```js
// Node.js 生成授权 URL
const crypto = require('crypto');

const codeVerifier = crypto.randomBytes(48).toString('base64url'); // 存入会话
const codeChallenge = crypto.createHash('sha256').update(codeVerifier)
  .digest('base64').replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
const state = crypto.randomBytes(16).toString('hex');              // 存入会话

const authUrl = '<AUTHZ_NOCO_URL>/api/idpOAuth/authorize?' + new URLSearchParams({
  client_id: 'my-app',
  redirect_uri: 'https://你的第三方域名/oauth/callback',
  response_type: 'code',
  scope: 'openid profile email',        // 按需加 api / offline_access
  prompt: 'consent',   // 请求 offline_access 时必须带，否则 refresh_token 不下发（OIDC 规范）
  state,
  code_challenge: codeChallenge,
  code_challenge_method: 'S256',
});
res.redirect(authUrl);
```

用户看到的体验：
1. NocoBase 登录页（输邮箱/密码）——未登录时自动出现
2. 授权确认页：`"我的第三方应用" requests access to your account` + 请求的权限列表 + `Continue / Cancel` 按钮
3. 点 Continue → 浏览器被重定向回第三方 `redirect_uri`

### C.2 回调处理（第三方后端）

```js
// GET /oauth/callback?code=...&state=...&iss=...
async function oauthCallback(req, res) {
  const { code, state, iss } = req.query;

  // 1. 校验 state（防 CSRF）与 iss
  if (state !== req.session.oauthState) return res.status(401).send('state mismatch');
  if (iss !== '<AUTHZ_NOCO_URL>/api') return res.status(401).send('iss mismatch');

  // 2. 换 token（client_secret_basic + PKCE verifier）
  const basic = Buffer.from(`my-app:${CLIENT_SECRET}`).toString('base64');
  const tokenRes = await fetch('<AUTHZ_NOCO_URL>/api/idpOAuth/token', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Authorization': `Basic ${basic}`,
    },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      code,
      redirect_uri: 'https://你的第三方域名/oauth/callback',
      code_verifier: req.session.codeVerifier,
    }),
  });
  const tokens = await tokenRes.json();
  // tokens: { access_token, id_token, expires_in, scope, token_type [, refresh_token] }

  // 3. 拉取用户信息（claims 在这里，不在 id_token 里）
  const meRes = await fetch('<AUTHZ_NOCO_URL>/api/idpOAuth/me', {
    headers: { 'Authorization': `Bearer ${tokens.access_token}` },
  });
  const me = await meRes.json();
  // me: { sub, name, preferred_username, email, email_verified }

  // 4. 用 me.sub 或 me.email 关联/创建本地账号，建立自己的会话
  const user = await findOrCreateUserByOidc(me.sub, me.email, me.name);
  req.session.userId = user.id;
  res.redirect('/dashboard');
}
```

### C.3 刷新 / 撤销 / 登出（可选）

```js
// 刷新（需 refresh_token grant + offline_access scope + authorize 时带过 prompt=consent）
await fetch('<AUTHZ_NOCO_URL>/api/idpOAuth/token', {
  method: 'POST',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Authorization': basic },
  body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: rt }),
});

// 撤销（204；之后该 token 立即 401）
await fetch('<AUTHZ_NOCO_URL>/api/idpOAuth/revoke', {
  method: 'POST',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({ token: at, client_id: 'my-app' }),
});

// RP-initiated 登出（引导浏览器访问）
// <AUTHZ_NOCO_URL>/api/idpOAuth/end-session?post_logout_redirect_uri=<你的登出后跳转地址>
```

### C.4 附加能力：用 access_token 调 NocoBase API

如果第三方系统还要读写 NocoBase 数据（授权 scope 含 `api`）：

```bash
curl "<AUTHZ_NOCO_URL>/api/eh_page-260604:list?pageSize=10" \
  -H "Authorization: Bearer <access_token>"
```

服务端自动将 OAuth token 桥接为 NocoBase 用户身份（权限 = 该用户在 NocoBase 的角色权限）。

### C.5 验证 id_token 签名（可选，标准 RS256）

```js
const jwks = await fetch('<AUTHZ_NOCO_URL>/api/idpOAuth/jwks').then(r => r.json());
// 用 jwks.keys[] (kid=idp-oauth-rs256) 按 RS256 验签；aud=client_id，iss=issuer
```

---

## D. 上线前验证清单

```bash
# 1. client 已插入且能被发现（authorize 不报 invalid_client 即可，应 303 到交互页）
curl -s -o /dev/null -w "%{http_code} -> %{redirect_url}\n" \
  "<AUTHZ_NOCO_URL>/api/idpOAuth/authorize?client_id=my-app&redirect_uri=https%3A%2F%2F你的第三方域名%2Foauth%2Fcallback&response_type=code&scope=openid&state=x&code_challenge=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0&code_challenge_method=S256"

# 2. 回调 URL 不匹配会立刻暴露（redirect_uri 错误时此请求报错而非 303）
# 3. 浏览器完整走一遍：登录 → 授权 → 回调 → 换 token → userinfo
# 4. id_token 验签 + state/iss 校验
# 5. revoke 后确认原 token 访问 /me 返回 401
```

**常见故障**：

| 现象 | 原因 |
|------|------|
| authorize 报 `invalid_client_target` / `unknown client` | DB 未插入成功，检查 `model='Client'` 且 oidcId=client_id |
| 报 `redirect_uri mismatch` | 回调 URL 与注册值不精确一致（协议/端口/路径） |
| 无 refresh_token | 三缺一：① client 未加 `refresh_token` grant ② scope 无 `offline_access` ③ authorize 未带 `prompt=consent`（最易漏，服务端静默剥离无报错） |
| token 换取 401 | Basic Auth 格式错，或 client_secret 与 DB 不符 |
| id_token 里没有 email | 正常行为，claims 在 userinfo |
| introspection 404 | 正常，未启用；用 /me 校验 token |
