# 设计与功能对齐 — SaaS身份平台

> 人填、人评审。机器只检查功能 ID 存在性。
> 回答一个问题：**这个功能子项，落到哪段代码、哪张表、哪个权限码上？**
> 答不上来的行，说明设计没做完，别开工。

## 映射表

| 功能子项 ID | 页面/组件 | 接口 | 数据表 | 权限码 | 设计稿 | 状态 |
|---|---|---|---|---|---|---|
| M01.F01 | AccountView（whoami 渲染 + 成员关系数） | GET /api/v1/me（MeAPI.meWhoami 生成物） | sys_user / tenant_membership（只读） | M01.F01 | — | 已上线 |
| M01.F02 | MembersView（成员列表）/ RoleAssignView（角色勾选全量覆盖） | GET /api/v1/tenants/{tenantId}/members、GET /api/v1/tenants/{tenantId}/roles、PUT /api/v1/tenants/{tenantId}/members/{userId}/roles（TenantMembersAPI/TenantRolesAPI 生成物） | sys_role / sys_user_role / tenant_membership（只读；分配落账在后端） | M01.F02 | — | 已上线 |
| M01.F03 | AccountView 租户段（成员关系列表 + ✓ 当前标记 + 点选切换） | GET /api/v1/me/tenants、POST /api/v1/me/tenants/{tenantId}/switch（MeAPI.meListMyTenants/meSwitchTenant 生成物） | tenant_membership（只读；切换换发 token 对不落表） | M01.F03 | — | 已上线 |
| M01.F04 | ConfigView（baseURL+clientId）/ LoginView（密码登录）/ AccountView（登出） | POST /api/v1/auth/login、POST /api/v1/auth/logout（AuthAPI.sessionsLogin/sessionsLogout 生成物） | oauth_client / sys_user（后端账，本仓不落表） | M01.F04 | — | 已上线 |
| M04.F03 | OAuthView（签发授权码 → 换 token → 刷新；code/state 回显，token 对/scope/tenantId/expiresAt 渲染）/ AccountView OAuth 段入口 | POST /api/v1/oauth/authorize、POST /api/v1/oauth/token（OauthAPI.oAuthAuthorize/oAuthToken 生成物，双 grant authorization_code + refresh_token） | oauth_client / oauth 授权码与 token 台账（后端账，本仓不落表；token 对入 SessionStore/Keychain） | M04.F03 | — | 已上线 |
| M04.F01 | ApplicationsView（client 列表 + 新建 sheet）/ ClientDetailView（详情只读 + 编辑 + 删除二次确认）/ ClientCreateView（注册，secret 必填）/ AccountView 应用管理段入口 | GET/POST /api/v1/admin/clients、GET/PUT/DELETE /api/v1/admin/clients/{clientId}、GET /api/v1/clients/{clientId}（AdminClientsAPI/ClientsAPI 生成物；分页 0-indexed 传 nil 全量） | oauth_client（后端账，本仓不落表；删除吊销 token 由后端落账） | M04.F01 | — | 已上线 |
| M04.F02 | ClientDetailView 启用状态段（Toggle 停用二次确认、启用直通）/ ApplicationsView 状态徽标随切换刷新 | PATCH /api/v1/admin/clients/{clientId}/status（AdminClientsAPI.adminClientsSetClientStatus 生成物；路径寻址 clientId 字符串非 UUID） | oauth_client（后端账，本仓不落表；停用即 authorize/token 立即拒绝由后端落账） | M04.F02 | — | 已上线 |
| M00.F01 | TenantsAdminView（租户列表 + 新建 sheet）/ TenantEditView（改名 + status Picker + 删除二次确认）/ AccountView 租户段富化（admin/tenants id→name 映射，403 降级 UUID） | GET/POST /api/v1/admin/tenants、PATCH/DELETE /api/v1/admin/tenants/{id}（AdminTenantsAPI 生成物；分页 0-indexed 传 nil 全量；路径寻址 UUID id 非 key） | sys_tenant（后端账，本仓不落表；删除级联语义由后端落账） | M00.F01 | — | 已上线 |
| M04.F04 | MenusAdminView（client Picker + OutlineGroup 菜单树）/ 新建菜单 sheet（title/type/父 Picker）/ 编辑页（改名 + status + 移动父节点 + 删除二次确认）/ 兄弟上移下移（reorder 整段提交）/ AccountView 平台管理段入口 | GET/POST /api/v1/clients/{clientId}/menus、GET/PATCH/DELETE …/menus/{menuId}、PATCH …/{menuId}/parent、PUT …/{menuId}/reorder（ClientMenusAPI 生成物；clientId 字符串寻址 + menuId String 路径参；平铺列表根 parentId=零值 UUID 前端组树；/me/menus 待 PLAN-2026-004 契约修正后补角） | sys_menu（后端账，本仓不落表） | M04.F04 | — | 已上线 |
| M00.F02 | MembersView 增强（行进 MemberDetailAdminView 详情/编辑 email/mobile + status Picker + 删除确认 + 角色分配链接；行 contextMenu 快捷挂起/恢复；工具条 Menu 新建成员/邀请成员 sheet）/ RoleAssignView 沿用 | POST /api/v1/tenants/{tenantId}/members、GET/PATCH/DELETE /api/v1/tenants/{tenantId}/members/{userId}、PATCH …/{userId}/status、POST …/members/invitations（TenantMembersAPI 生成物；create email 后端必填 UI 校验；PUT roles 响应 status 不可信改回读） | sys_user / tenant_membership / tenant_member_role（后端账，本仓不落表；邀请落 sys_user invited 行） | M00.F02 | — | 已上线 |
| M00.F03 | RolesAdminView（client Picker 过滤 + 角色列表 roleCode/roleName/status 徽标 + 工具条新建 sheet：clientId Picker/roleCode/roleName/description）→ RoleDetailAdminView（roleName/description 编辑 + status 启停 Toggle + 删除二次确认；roleCode 只读） | GET/POST /api/v1/tenants/{tenantId}/roles、GET/PATCH/DELETE …/roles/{roleId}（TenantRolesAPI 生成物；重名 roleCode 后端 500 空 body UI 红字如实呈现；roleCode 不可改） | sys_role（后端账，本仓不落表） | M00.F03 | — | 已上线 |
| M00.F04 | RoleDetailAdminView「菜单授权」段（client 菜单清单多选勾选 + 保存授权 PUT + 清空 DELETE 二次确认；menuIds 全程 Set 语义，顺序不敏感） | GET/PUT/DELETE /api/v1/tenants/{tenantId}/roles/{roleId}/menus（TenantRoleMenusAPI 生成物；RoleMenuGrant 聚合形状；clientId 查询参不传——探针实证角色已带 client 时无差异）；菜单清单复用 GET /api/v1/clients/{clientId}/menus（REQ-008 缝） | sys_role_menu（后端账，本仓不落表） | M00.F04 | — | 开发中 |

## 约定

1. **权限码 = 功能子项 ID。** 前端按钮的权限判断直接写 ID。
2. 一个接口服务多个子项时，多行重复写。不要为表好看而合并 —— 合并后看不清接口还有没有别的调用方。
3. 状态列必须与功能清单一致。不一致以功能清单为准。

## 评审时问这三个问题

1. 有没有子项没有权限码？→ 那它就是任何人都能点的按钮
2. 有没有一张表被三个以上模块直接写入？→ 边界破了
3. 「开发中」的行里接口和表填了吗？→ 没填就是还在纸上，别报进度
