# REQ-2026-009 租户成员管理切片（成员生命周期：create/detail/update/status/delete/invite）

| 项 | 值 |
|---|---|
| 提出人 | zcqiand（standing 指令「saas 侧的 Swift 版需求参考 shared 就行，并且要确保 api 是生成的」） |
| 提出日期 | 2026-10-01 |
| 优先级 | P1 |
| 状态 | **已上线**（GA mirror 免批，人工验收 AC-1~6 通过 2026-10-02） |
| 关联 ADR | ADR-0029（API 面只认生成物，硬规则 §4） |
| 上游 | saas-identity-platform-shared TypeSpec SSOT（M00.F02 BASE：tenant-members.tsp I01~I06/I08）；前置 REQ-001~008 已上线基座 |

## 1. 需求描述

M00 第二个 F：**租户成员**（BASE 已上线，Swift 侧本切片前 规划）。M01.F02
（REQ-003）已上线「成员列表 + 角色分配」三缝（listMembers/listRoles/assignRoles），
本切片补**成员生命周期管理**六缝，API 面只认生成物（硬规则 §4）：
`TenantMembersAPI`——

- `tenantMembersListTenantUsers`（GET …/members，0-indexed 分页 `Page<TenantMemberUserView>`）——M01.F02 已上线缝复用
- `tenantMembersCreateTenantUser`（POST …/members，`CreateSysUserRequest(username:password:email:mobile:)`）— I02
- `tenantMembersGetTenantUser`（GET …/members/{userId}，扁平 TenantMemberUserView）— I03
- `tenantMembersUpdateTenantUser`（PATCH …/members/{userId}，`UpdateSysUserRequest(email:mobile:)`）— I04
- `tenantMembersDeleteTenantUser`（DELETE，204 → Void 缝）— I05
- `tenantMembersChangeTenantUserStatus`（PATCH …/members/{userId}/status，`TenantMembersChangeTenantUserStatusRequest(status:)`）— I08
- `tenantMembersInviteTenantUser`（POST …/members/invitations，嵌套 `TenantMemberView{member,user,roles}`）— I06

契约形状要点（live 探针实证，2026-10-01 @5101 saas-springboot，临时用户全生命周期探毕即清 204×3）：

- **0-indexed 分页**：`page:0&pageSize:20` 是第一页；App 侧 list 不传分页参（nil 全量），同 admin/clients 口径
- **create 的 email 后端必填**：契约 `email?` optional 但后端 400 `path:["email"] Required`——生成物形状不动，**App/UI 侧 email 当必填**（同「契约必填性≠后端 DTO」先例）
- **PUT roles 响应 status 撒谎**：挂起成员 PUT roles 返 status=active 但 GET 回读仍 suspended——角色响应体的 status 字段不可信；本切片顺带修 M01.F02 `assignRoles`：成功后 getMember 回读、以回读行原位替换（响应不再直接入列）
- **wire 日期分数位混排**：空格+08 且分数位 0/2/3/6 位混排（`18:00:00+08` / `.19+08` / `.858+08` / `.521012+08`），create 响应 ISO `.190Z`——FamilyDateFormatter 的 SSS 严格 3 位解不了 2/6 位（全链回落 ISO 也解不了 → 解码炸面），T-1 补**分数位归一化**：先试现链，全败后正则归一化分数位到 3 位重试对应格式
- **邀请双 status 口径**：TenantMemberView 里 member.status=active 与 user.status=invited 并存（membership 立即生效、被邀 user 未激活）；`memberName` 是 email local-part 派生非自填；列表行的 status = **user.status**（carol=invited 实证）

### 范围

| 关注点 | 内容 |
|---|---|
| CoreKit | MembersViewModel 扩展（家族单 VM 惯例，3 缝 → 9 缝）：createMember/getMember/updateMember/changeStatus/deleteMember/inviteMember 六缝；invite 嵌套→扁平行映射后追加；assignRoles 修缺陷（PUT 成功后回读替换）；FamilyDateFormatter 分数位归一化补强；成功=原位列表维护，失败=红字列表不动可重试 |
| App | APIGlue 六缝走生成物 builder；MembersView 增强：行 NavigationLink 改进 MemberDetailAdminView（email/mobile 编辑 + status Picker + 删除确认 + 「角色分配」链接进 RoleAssignView 不回归）；行 contextMenu 快捷挂起/恢复；工具条 Menu（新建成员/邀请成员 sheet，email 必填校验）；AC-1 列表渲染沿用 |
| 测试 | MembersViewModelTests 扩展红先行（fn 挂 M00.F02）+ assignRoles 回读缺陷回归用例 + FamilyDateFormatterTests 补 2/6 位分数形态 |

**非范围**：邀请接受流（被邀侧登录后接受，属被邀侧口径）；翻页 UI；bob 越权收紧（后端/CT 地盘）。

### 澄清记录

| 疑问 | 澄清结论 | 澄清人 | 日期 |
|---|---|---|---|
| Q1 create email 契约 optional 但后端必填 | UI 侧当必填（生成物不动）；与「契约必填性≠后端 DTO」先例同款；CT 仓同步断言属后端地盘不在此切片 | 自裁（live 400 探针） | 2026-10-01 |
| Q2 PUT roles 响应 status 撒谎 | 不信任响应体 status；assignRoles 成功后 getMember 回读替换（顺带修 M01.F02 缺陷，同页小改）；回读失败红字可重试 | 自裁（suspend→roles→GET 双探针） | 2026-10-01 |
| Q3 wire 日期分数位混排 | FamilyDateFormatter 加归一化慢路径（正则 pad/truncate 分数位到 3 位重试）；先试现链不动已上线三切片行为 | 自裁（四形态 live 对比) | 2026-10-01 |
| Q4 邀请响应嵌套→扁平行映射 | id=user.id、status=user.status、roleIds=view.roles；映射放 CoreKit 纯函数可测 | 自裁（live 探针 + 生成物源码） | 2026-10-01 |

## 2. 验收标准

| 编号 | 场景（给定） | 操作（当） | 预期（则） |
|---|---|---|---|
| AC-1 | alice 登录进成员页 | — | 列表渲染 alice/bob/carol 三行（username/status/角色数）；空格+08 与分数位混排日期解码不炸 |
| AC-2 | 成员页工具条 | 新建成员（username/password/email 必填）→ 确认删除 | 创建后列表即现（追加行）；删除 204 后行消失 |
| AC-3 | 编辑页改 email | 保存 | 原位更新返回即见新值；状态切换 suspended/active 原位生效 |
| AC-4 | 任意操作失败（403/404/400） | — | 红字带 HTTP 码，列表不动可重试 |
| AC-5 | 邀请 sheet 输入 email 提交 | — | 列表即现新行（status=invited）；memberName 派生语义记入 UI 说明 |
| AC-6 | 任意时刻 | 检查 API 面 | 全部来自 SaasSharedGenerated；grep 无手写端点串；Generated/ 零改动 |

## 3. 任务拆解

| 任务 ID | 任务描述 | 类型 | 负责人 | 预估 | 状态 |
|---|---|---|---|---|---|
| T-0 | tree-change 提案：M00.F02 规划→开发中（mirror 免批 --apply，令牌 4fba5ddabe8b1f76） | 对齐 | Claude | — | 已完成（2026-10-01） |
| T-1 | CoreKit 红先行：MembersViewModel 六缝扩展 + assignRoles 回读修复 + FamilyDateFormatter 分数位归一化 + 测试挂 M00.F02，本地 7 门绿 | 开发 | Claude | 0.5d | 已完成（远程 80 tests 绿） |
| T-2 | App：APIGlue 六缝 + MembersView 增强（详情/编辑/状态/删除 + 新建/邀请 sheet + contextMenu）+ 全门绿 + push + gitlink + 验收准备 | 开发 | Claude | 0.5d | 已完成（远门 BUILD SUCCEEDED + 本地 7 门全绿） |
| T-3 | GA：凭人工验收通过记录 --apply 免批 翻已上线 + gitlink | 对齐 | Claude | — | 已完成（人工验收 AC-1~6 通过 2026-10-02，模拟器全链演练） |

## 4. 功能影响（需求与功能对齐的唯一位置）

| 功能 ID | 功能名称 | 影响类型 | 说明 | 关联任务 |
|---|---|---|---|---|
| M00.F02 | 租户成员 | 变更 | 规划→开发中：成员生命周期六缝 + 邀请；list+roles 沿用 M01.F02 已上线缝；顺带修 assignRoles 回读缺陷 | T-0 |

## 5. 流程影响

无（本仓尚无流程文档，待人裁遗留项）。

## 6. 风险与回滚

| 风险 | 影响面 | 缓解 | 回滚方式 |
|---|---|---|---|
| FamilyDateFormatter 慢路径改全局解码行为，波及已上线三切片 | AC-1 | 慢路径仅在现链全败后触发（现链行为零变化）；单测锁 2/6 位分数形态 + 现有 6 用例回归 | 回退 commit |
| assignRoles 回读修复改变 M01.F02 行为 | 已上线切片 | 行为变化=修缺陷（挂起成员角色保存后 UI status 不再假翻 active）；MembersViewModelTests 回归锁 | 回退 commit |
| PUT roles 响应 status 撒谎在其它后端形态未知 | T-2 模拟器验收 | 只对 springboot 探针实证；其它后端（nextjs/aspnetcore）形态未探，验收时若见异常记档 | — |
