# 测试结果记录

## 2026-09-08 · authz:latest @ 127.0.0.1:6443（235 本机实例）

- 提交：skill/authz-helper + testcase 首版（见 git log）
- 结果：**41/41 PASS，0 FAIL**（连续三轮；第二轮第三轮验证幂等）
- 残留检查：users/keys/bindings/policies 四类测试资源均为 0

覆盖：t01 会话 smoke ×3、t02 认证边界 ×2、t03 用户/登录/CSRF ×7、
t04 API Key 生命周期 ×9、t05 绑定+策略+代理+菜单注入 ×11、t06 菜单树 ×4、
t07 nginx-conf ×3、t08 文件浏览 ×1（另 1 个绑定反查断言，共 41）。

### 调试期间确认的契约（已回写 skill 文档）

- `AUTHZ_COOKIE_SECURE=true` 实例上，登录会话 Cookie 仅在 HTTPS 入口有效；
  测试统一走 `https://127.0.0.1:6443`（curl -k）。
- `POST /users`、`POST /applications`、`POST /policies` 成功响应只含 message，
  需从对应列表接口反查 id（api-keys 例外，create/rotate 直接返回）。
- users 列表 `roles` 是字符串（如 "admin"）；menu-services 行键字段名是 `menu_key`。
- 策略对象 `v1` 端口受 PORT_MIN~MAX 校验（`/1/*` 422）。
- 清理 curl 必须带 -k，否则自签 HTTPS 下静默失败造成资源残留。

### 未纳入自动化（人工场景）

- 登录连续失败 5 次锁定 30 分钟（会污染共享锁定计数，建议专用账户人工验证）。
- 响应改写/header 覆盖端到端（需要可控行为的上游，建议在 241.t 专项回归，
  仓库 test/ 目录已有 gateway 级覆盖）。
