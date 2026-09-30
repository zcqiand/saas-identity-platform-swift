# REQ-2026-002 租户成员与切换切片（成员关系列表 + 点选切换租户）

| 项 | 值 |
|---|---|
| 提出人 | zcqiand（standing 指令「saas 侧的 Swift 版需求参考 shared 就行，并且要确保 api 是生成的」） |
| 提出日期 | 2026-09-30 |
| 优先级 | P1 |
| 状态 | **开发中**（T-0 批准 2026-09-30，base sha 4fecd857；提案存档 .state/tree-change.json） |
| 关联 ADR | ADR-0019（baseURL/clientId 显式配置口径沿用）；ADR-0026（marker） |
| 上游 | saas-identity-platform-shared TypeSpec SSOT；REQ-2026-001 已上线基座（SessionStore 三态 / AuthViewModel 缝 / APIGlue） |

## 1. 需求描述

REQ-2026-001 验收时 currentTenantId 只展示不切换（当时明确留作非范围）。本切片补上
M01.F03 的另一半：**当前用户的跨租户成员关系 + 切换**。API 面只认生成物：

- `MeAPI.meListMyTenants`（GET /api/v1/me/tenants → [TenantMembership]）
- `MeAPI.meSwitchTenant`（POST /api/v1/me/tenants/{tenantId}/switch →
  **SwitchTenantResponse{accessToken, refreshToken, expiresAt, tenantId}**）

契约形状要点：切换换发的是**新 token 对**（不是 LoginResponse，与 lab 的
switch-tenant 不同形）——SessionStore 需新增 adoptSwitch 入账路径：token/refresh
换新落 Keychain、currentTenantId 更新、快照重写、Bearer 重注，state 保持 ready。

### 范围

| 关注点 | 内容 |
|---|---|
| CoreKit | SessionStore.adoptSwitch(_:)（缺 accessToken fail-fast 不入账）+ refreshTenants(_:)（列表刷新落快照）；AuthViewModel.switchTenant(to:) + listTenants()，缝注入不变 |
| App | AccountView 租户段升级：成员关系列表（tenantId + roleIds + status）+ 当前租户标记 + 点选切换；切换成功 whoami 重拉；失败红字保会话 |
| 测试 | SessionStoreTests/AuthViewModelTests 增 switch/list 用例（fn 挂 M01.F03）；红先行 |

**非范围**：租户名富化（memberships 只带 tenantId，显示 UUID；家族前端拉
admin/tenants 富化是既有人裁缝，Swift 侧如做属后续需求）；M00.F02 tenant-admin
成员管理面；菜单树（M04.F04）；token 刷新（/oauth/token，M04.F03）。

### 澄清记录

| 疑问 | 澄清结论 | 澄清人 | 日期 |
|---|---|---|---|
| Q1 列表数据源 | 进页先用快照渲染（离线可见），同时 meListMyTenants 拉真值覆盖（refreshTenants）；不一致以后端为准 | 自裁（生成物已有该端点，slice 最小诚实口径） | 2026-09-30 |
| Q2 切换响应怎么入账 | SwitchTenantResponse 四字段全用：token 对落密态缝、tenantId 进 currentTenantId + 快照、expiresAt 随快照记录（本期不做过期主动刷新，仅展示依据） | 自裁（契约形状推演） | 2026-09-30 |
| Q3 目标租户非法（不在成员关系里） | 直接发后端，由后端 4xx 拒；本地不清会话可重试（lab 同款「失败保持原会话」） | 自裁（lab swift 先例） | 2026-09-30 |

## 2. 验收标准

| 编号 | 场景（给定） | 操作（当） | 预期（则） |
|---|---|---|---|
| AC-1 | 已登录 | 看账户页租户段 | 成员关系列表渲染（tenantId/角色/状态），当前租户有标记，数据来自生成物 client |
| AC-2 | 已登录多租户 | 点选另一个租户 | POST switch 换发 token 落 Keychain，currentTenantId 更新为新租户，whoami 重拉反映新上下文 |
| AC-3 | 切换时后端拒绝或网络断 | 确认切换 | 红字带 HTTP 码，原 token/currentTenantId 不变，可重试 |
| AC-4 | 切换成功后杀 App 重开 | 看账户页 | 快照恢复新租户上下文（currentTenantId = 切换后租户） |
| AC-5 | 任意时刻 | 检查 API 面 | switch/list 端点全来自 SaasSharedGenerated；grep 无手写端点串 |

## 3. 任务拆解

| 任务 ID | 任务描述 | 类型 | 负责人 | 预估 | 状态 |
|---|---|---|---|---|---|
| T-0 | tree-change 提案：M01.F03 规划→开发中 | 对齐 | Claude | — | 已完成（2026-09-30 人工批准） |
| T-1 | CoreKit 红先行：adoptSwitch/refreshTenants + VM switchTenant/listTenants + 测试挂 M01.F03 | 开发 | Claude | 0.5d | 待开始 |
| T-2 | App：AccountView 租户段列表+切换交互 + APIGlue 两缝 + 全门绿 + push + gitlink | 开发 | Claude | 0.5d | 待开始 |

## 4. 功能影响（需求与功能对齐的唯一位置）

| 功能 ID | 功能名称 | 影响类型 | 说明 | 关联任务 |
|---|---|---|---|---|
| M01.F03 | 租户成员 | 变更 | 规划→开发中：成员关系列表 + 切换（AC-1~4） | T-0 |

## 5. 流程影响

无（本仓尚无流程文档，待人裁遗留项）。

## 6. 风险与回滚

| 风险 | 影响面 | 缓解 | 回滚方式 |
|---|---|---|---|
| SwitchTenantResponse 与 lab LoginResponse 形状不同，照抄 lab switchTenant 会编不过 | T-1 | 已核生成物（四字段 token 对），adoptSwitch 独立实现不复用 adoptLogin | 回退 commit |
| 切换后快照 user/tenants 未变但 currentTenantId 变了，快照重写遗漏会话错乱 | AC-4 | 测试盖重生分支（同 REQ-001 rebirth 套路） | 回退 commit |
| dev 种子 alice 只有单租户 → AC-2 无从点选 | 验收 | 已探活：alice availableTenants 含 2 条 membership（多租户种子在库）；验收前再探一次 | — |
