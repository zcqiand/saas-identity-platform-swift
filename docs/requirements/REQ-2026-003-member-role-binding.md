# REQ-2026-003 成员角色绑定切片（成员列表 + 角色全量覆盖分配）

| 项 | 值 |
|---|---|
| 提出人 | zcqiand（standing 指令「saas 侧的 Swift 版需求参考 shared 就行，并且要确保 api 是生成的」） |
| 提出日期 | 2026-09-30 |
| 优先级 | P1 |
| 状态 | **开发中**（T-0 批准 2026-09-30，base sha dc61332a；提案存档 .state/tree-change.json，mirror 类） |
| 关联 ADR | ADR-0019（显式配置口径沿用）；ADR-0042（mirror 免批通道，若补丁已落盘可 --apply） |
| 上游 | saas-identity-platform-shared TypeSpec SSOT（tenant-members.tsp:43）；REQ-001/002 已上线基座（SessionStore 三态 / Seams 缝模式 / APIGlue） |

## 1. 需求描述

M01 最后一个未落地的 F：**给 member 分配角色**（member→role binding，对应 shared
BASE 同编号 F 的 assign 子项，`tenant-members.tsp:43`）。与 M00.F02 的字段维护/邀请是不同维度——
本切片只管「一个成员当前挂着哪些角色」的全量覆盖。API 面只认生成物（硬规则 §4）：

- `TenantMembersAPI.tenantMembersListTenantUsers`（GET /api/v1/tenants/{tenantId}/members
  → {items: [TenantMemberUserView], page, pageSize, total}）
- `TenantMembersAPI.tenantMembersAssignTenantMemberRoles`
  （PUT /api/v1/tenants/{tenantId}/members/{userId}/roles，请求体
  SetTenantMemberRolesRequest{roleIds: [String]} → TenantMemberUserView）
- `TenantRolesAPI.tenantRolesListSysRoles`（GET /api/v1/tenants/{tenantId}/roles
  → {items: [SysRole], ...}，供角色勾选清单）

契约形状要点：租户上下文取 SessionStore.currentTenantId（切换切片的成果直接复用）；
分配是**全量覆盖**语义（提交的 roleIds 集合就是该成员的最终角色集）。

### 范围

| 关注点 | 内容 |
|---|---|
| CoreKit | 新 MembersViewModel：Seams 增 listMembers(tenantId)/listRoles(tenantId)/assignRoles(tenantId,userId,roleIds) 三缝（抛错缺省同款）；进页并发拉成员+角色；assign 成功用返回的 TenantMemberUserView 原位更新成员行，失败红字列表不动；tenantId 取 store.currentTenantId，nil fail-fast 不发请求 |
| App | MembersView（AccountView 租户段 NavigationLink 进入）：成员列表（username/status/角色数）+ 点选成员进角色编辑（勾选清单来自后端角色列表）+ 保存全量覆盖 + 失败红字 |
| 测试 | MembersViewModelTests 红先行（fn 挂 M01.F02） |

**非范围**：成员邀请/状态/删除（M00.F02 字段维护维度）；角色 CRUD（M00.F03）；
角色↔菜单授权（M00.F04）；分页 UI（列表按后端默认页一次拉取，翻页留后续）。

### 澄清记录

| 疑问 | 澄清结论 | 澄清人 | 日期 |
|---|---|---|---|
| Q1 租户上下文哪来 | SessionStore.currentTenantId（REQ-002 切换成果复用）；nil = fail-fast 报「未选择租户」不发请求 | 自裁（生成物路径必带 tenantId） | 2026-09-30 |
| Q2 分配权限不足怎么表现 | 直接发后端由其 403 拒；红字带 HTTP 码、列表不动可重试（REQ-002 AC-3 同口径）。dev 种子天然有正反用例：alice@001 是 admin、@002 是普通 member | 自裁（lab 先例 + 种子探活实证） | 2026-09-30 |
| Q3 全量覆盖 vs 增量 | 生成契约就是全量覆盖（SetTenantMemberRolesRequest.roleIds 即最终集合），UI 按「勾选即最终态」设计，不发明增量协议 | 自裁（契约形状推演） | 2026-09-30 |

## 2. 验收标准

| 编号 | 场景（给定） | 操作（当） | 预期（则） |
|---|---|---|---|
| AC-1 | alice 登录且当前租户 001（admin） | 进成员页 | 成员列表渲染（username/status/角色），角色清单来自生成物 client |
| AC-2 | 成员页点选 bob | 勾选角色保存 | PUT assign 全量覆盖成功，返回视图原位更新 bob 行 roleIds |
| AC-3 | 切到租户 002（alice 普通成员） | 对任意成员保存角色 | 后端 403 拒，红字带 HTTP 码，列表不动可重试 |
| AC-4 | 网络断/后端不可达 | 任意操作 | 红字报错，本地状态不变 |
| AC-5 | 任意时刻 | 检查 API 面 | members/roles 端点全来自 SaasSharedGenerated；grep 无手写端点串 |

## 3. 任务拆解

| 任务 ID | 任务描述 | 类型 | 负责人 | 预估 | 状态 |
|---|---|---|---|---|---|
| T-0 | tree-change 提案：M01.F02 规划→开发中 | 对齐 | Claude | — | 已完成（2026-09-30 人工批准） |
| T-1 | CoreKit 红先行：MembersViewModel 三缝 + 测试挂 M01.F02 | 开发 | Claude | 0.5d | 待开始 |
| T-2 | App：MembersView + AccountView 入口 + 全门绿 + push + gitlink + 模拟器验收准备 | 开发 | Claude | 0.5d | 待开始 |

## 4. 功能影响（需求与功能对齐的唯一位置）

| 功能 ID | 功能名称 | 影响类型 | 说明 | 关联任务 |
|---|---|---|---|---|
| M01.F02 | 角色成员 | 变更 | 规划→开发中：成员角色全量覆盖分配（AC-1~4） | T-0 |

## 5. 流程影响

无（本仓尚无流程文档，待人裁遗留项）。

## 6. 风险与回滚

| 风险 | 影响面 | 缓解 | 回滚方式 |
|---|---|---|---|
| assign 端点权限语义（tenant-admin only）误判导致 AC-3 无从验证 | 验收 | 已探活 dev：alice@001 roles 含 admin、@002 不含；正反用例都在 | 回退 commit |
| MembersViewModel 引入第三处 Seams 模式漂移 | T-1 | 完全复用 REQ-002 的 Seams 构造惯例（抛错缺省 + `_ in`） | 回退 commit |
| 全量覆盖 UI 误操作清掉成员全部角色 | AC-2 | 勾选清单以成员当前 roleIds 预勾选；保存前用户显式动作；dev 种子可随时改回 | 回退 commit |
