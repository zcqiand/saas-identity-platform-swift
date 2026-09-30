# 设计与功能对齐 — SaaS身份平台

> 人填、人评审。机器只检查功能 ID 存在性。
> 回答一个问题：**这个功能子项，落到哪段代码、哪张表、哪个权限码上？**
> 答不上来的行，说明设计没做完，别开工。

## 映射表

| 功能子项 ID | 页面/组件 | 接口 | 数据表 | 权限码 | 设计稿 | 状态 |
|---|---|---|---|---|---|---|
| M01.F01 | AccountView（whoami 渲染 + 成员关系数） | GET /api/v1/me（MeAPI.meWhoami 生成物） | sys_user / tenant_membership（只读） | M01.F01 | — | 已上线 |
| M01.F02 | MembersView（成员列表）/ RoleAssignView（角色勾选全量覆盖） | GET /api/v1/tenants/{tenantId}/members、GET /api/v1/tenants/{tenantId}/roles、PUT /api/v1/tenants/{tenantId}/members/{userId}/roles（TenantMembersAPI/TenantRolesAPI 生成物） | sys_role / sys_user_role / tenant_membership（只读；分配落账在后端） | M01.F02 | — | 开发中 |
| M01.F03 | AccountView 租户段（成员关系列表 + ✓ 当前标记 + 点选切换） | GET /api/v1/me/tenants、POST /api/v1/me/tenants/{tenantId}/switch（MeAPI.meListMyTenants/meSwitchTenant 生成物） | tenant_membership（只读；切换换发 token 对不落表） | M01.F03 | — | 已上线 |
| M01.F04 | ConfigView（baseURL+clientId）/ LoginView（密码登录）/ AccountView（登出） | POST /api/v1/auth/login、POST /api/v1/auth/logout（AuthAPI.sessionsLogin/sessionsLogout 生成物） | oauth_client / sys_user（后端账，本仓不落表） | M01.F04 | — | 已上线 |

## 约定

1. **权限码 = 功能子项 ID。** 前端按钮的权限判断直接写 ID。
2. 一个接口服务多个子项时，多行重复写。不要为表好看而合并 —— 合并后看不清接口还有没有别的调用方。
3. 状态列必须与功能清单一致。不一致以功能清单为准。

## 评审时问这三个问题

1. 有没有子项没有权限码？→ 那它就是任何人都能点的按钮
2. 有没有一张表被三个以上模块直接写入？→ 边界破了
3. 「开发中」的行里接口和表填了吗？→ 没填就是还在纸上，别报进度
