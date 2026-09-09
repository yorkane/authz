# authz 管理端 UI/API 回归测试用例

依据 `skill/authz-helper`（SKILL.md + references/ui.md + references/api.md）编写，
用例按管理端页面/功能块组织，全部通过控制面 API 与 HTTP 入口验证，幂等可重复，
失败也自动清理创建的资源（用户/Key/绑定/策略/上游进程）。

## 运行

```bash
# 默认目标本机实例（/data/app/.env 提供 AUTHZ_API_KEY）
bash testcase/ui_api_tests.sh

# 指定实例 / Key / 子集 / 失败不中断
GATEWAY=https://a-241.ai-t.wtvdev.com:6443 \
AUTHZ_ENV_FILE=/data/app/authz-test/.env \
TEST_ONLY=t01,t04,t05 KEEP_GOING=1 bash testcase/ui_api_tests.sh
```

依赖：curl、jq、python3（T05 起本地上游服务用）。

## 用例清单

| 编号 | 页面/功能块 | 验证点 |
|---|---|---|
| t01 | 框架/会话 | 实例 Key 建立会话；`GET /api/session` 返回 admin 身份与 `api-key:` identity |
| t02 | 认证边界 | 无 Key 与无效 Key 访问控制面一律 401，绝不回退 Cookie（api.md §0） |
| t03 | users.html 账户区块 | 建用户（默认角色）→ 改角色（user→staff）→ 重置密码 → 表单登录 302 → Cookie 会话生效 → 写操作缺 CSRF 403、带 X-CSRF-Token 200 |
| t04 | users.html API 管理区块 | 建 guest Key（token 明文只出现一次、格式 ak_+64hex）→ 列表永不含明文 → guest 可 `GET /session`、可开 `/_authz/guest` 探针、控制面 403 → 禁用即 401 → rotate 后旧 token 失效 → 删除 |
| t05 | authorization.html 绑定/策略 + 代理链路 | 建前缀绑定 → 重复 409 → allow 策略放行 guest → deny 策略挡 `/secret.html` → `<port>-<域名>` 动态入口代理 200 且内容命中 → deny 优先返回 403 → 未认证 302 登录页 → menu-services 改名/重置 → 删绑定 |
| t06 | menu-editor.html 菜单结构 | menu-tree 含 builtin `domains`/`local` 两组；menu-services 返回 binding 注入行 |
| t07 | nginx_conf.html | 读三个 include 文件；非法配置 validate 被拒（staging，不落盘） |
| t08 | files.html | 文件列表接口 200 |

## 设计约束

- 全部断言基于 references/api.md 记录的契约（401/403/409 状态码、token 单次出现、
  deny 优先、CSRF 门禁、guest 能力面、数字前缀动态入口 simulate_local）。
- 不改动任何存量配置：用例内创建的资源用 `trap cleanup EXIT` 统一回收；
  T07 只 validate 不保存；登录失败锁定等破坏性场景未纳入（见下）。
- 锁定阈值（5 次/30 分钟）会污染共享计数状态，建议人工在测试实例验证：对专用
  账户连续错 5 次密码 → 第 6 次即使密码正确也 423/403（以 ui 实现为准）。

## 结果记录

每次运行后把 pass/fail 汇总追加到本目录 `RESULTS.md`（含日期、目标实例、git 提交）。
