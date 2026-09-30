# REQ-2026-007 租户维护切片（平台 admin 租户 CRUD + 租户名富化）

| 项 | 值 |
|---|---|
| 提出人 | zcqiand（standing 指令「saas 侧的 Swift 版需求参考 shared 就行，并且要确保 api 是生成的」） |
| 提出日期 | 2026-09-30 |
| 优先级 | P1 |
| 状态 | **开发中**（T-0 mirror 免批 --apply；GA 待人工验收后凭 REQ 验收记录免批翻转） |
| 关联 ADR | ADR-0019（显式配置口径沿用） |
| 上游 | saas-identity-platform-shared TypeSpec SSOT（M00.F01 BASE 已上线：admin-tenants.tsp I01~I05）；前置 REQ-001~006 已上线基座 |

## 1. 需求描述

M00 第一个落地 F：**租户维护**（BASE 已上线，Swift 侧 规划）。平台 admin 视角
管理租户全生命周期（对应 shared BASE 同编号 F 的 I01~I05 子项），顺带清掉
M01.F03 的遗留：AccountView 租户段显示 tenantId UUID → 富化成真名。API 面
只认生成物（硬规则 §4）：`AdminTenantsAPI` 全套——

- `adminTenantsListTenants`（GET /api/v1/admin/tenants，分页同族 0-indexed，
  App 传 nil 拉全量不做翻页 UI）
- `adminTenantsCreateTenant`（POST，`CreateTenantRequest(tenantKey:name:)`，
  服务端默认 status=active）
- `adminTenantsUpdateTenant`（PATCH partial `UpdateTenantRequest(name:status:)`）
- `adminTenantsDeleteTenant`（DELETE，204 空 body）
- `adminTenantsGetTenant`（GET 详情；本切片 UI 行内即编辑，不单开详情拉取，
  缝不进 ViewModel——AC 不含）

契约形状要点（live 探针实证，2026-09-30 @5101 saas-springboot）：
- **路径寻址是 UUID id**（与 admin/clients 的 clientId 字符串相反），未知 404
- `TenantStatus` 是字符串枚举 `active` / `suspended`（OAuthClient.status 是
  Int，两套口径并存）；非法值 400
- `tenantKey` 重复创建 → **409 CONFLICT**（Tenant key already exists）
- DELETE 返 204 空 body（解码按 Void 缝走）
- 种子 3 租户：acme / globex / initech（live 回显 name 分别 ACME Corp /
  Globex Industries / Initech）

### 范围

| 关注点 | 内容 |
|---|---|
| CoreKit | 新 AdminTenantsViewModel：Seams 四缝 listTenants/createTenant/updateTenant/deleteTenant（抛错缺省同款）；成功原位维护列表（追加/替换/移除，不重拉）；失败红字列表不动可重试 |
| App | APIGlue 四缝走生成物 builder；TenantsAdminView（AccountView 新段入口：列表 name/key/status 徽标）→ TenantEditView（改名 + status Picker + 删除二次确认——删除租户是级联危险操作）+ TenantCreateView（tenantKey/name）；AccountView 租户段富化：.task 拉 admin/tenants 建 id→name 映射渲染真名，403/失败降级显示 UUID（非 admin 用户不炸） |
| 测试 | AdminTenantsViewModelTests 红先行（fn 挂 M00.F01） |

**非范围**：M00.F02~F05（成员/角色/权限/应用订阅）；租户翻页 UI；
租户删除的级联预览（服务端语义，确认框文字提示即可）。

### 澄清记录

| 疑问 | 澄清结论 | 澄清人 | 日期 |
|---|---|---|---|
| Q1 寻址与分页 | 寻址 UUID id 非 key/字符串（live：未知 UUID 404）；分页 0-indexed 同族（page=0/不传全量，返 page=0）→ 传 nil 不做翻页 UI | 自裁（live 双探针 + 家族在册指纹） | 2026-09-30 |
| Q2 status 口径 | 字符串枚举 active/suspended（生成物 TenantStatus）；与 OAuthClient 的 Int status 并存不混用，UI 用 Picker 两态 | 自裁（生成模型 + live patch 实证） | 2026-09-30 |
| Q3 富化怎么做 | AccountView .task 拉 admin/tenants 建 id→name 字典，403/失败静默降级显示 UUID（不阻塞、不重试轰炸）；admin/tenants 是唯一带 name 的面（/me/tenants 只有 tenantId，家族在册） | 自裁（live 探针 + 家族在册「租户显示名富化走 admin/tenants」） | 2026-09-30 |

## 2. 验收标准

| 编号 | 场景（给定） | 操作（当） | 预期（则） |
|---|---|---|---|
| AC-1 | alice 登录（平台 admin） | 进租户管理 | 3 条种子租户全量渲染（name/tenantKey/status 徽标） |
| AC-2 | 列表就绪 | 新建租户（tenantKey+name）→ 再删除 | 创建后列表 +1 且 active；确认删除后行消失 |
| AC-3 | 详情编辑页 | 改名保存 / 切 status | 原位更新返回列表即见新值；tenantKey 重复创建红字 409 可重试 |
| AC-4 | 任意操作失败（断网/403/404） | — | 红字带 HTTP 码，列表不动可重试 |
| AC-5 | AccountView 租户段 | 登录后看成员关系 | 有权时显示真名（acme 等），无权/失败降级显示 tenantId UUID，不阻塞页面 |
| AC-6 | 任意时刻 | 检查 API 面 | 全部来自 SaasSharedGenerated；grep 无手写端点串 |

## 3. 任务拆解

| 任务 ID | 任务描述 | 类型 | 负责人 | 预估 | 状态 |
|---|---|---|---|---|---|
| T-0 | tree-change 提案：M00.F01 规划→开发中（mirror 免批 --apply） | 对齐 | Claude | — | 已完成（2026-09-30） |
| T-1 | CoreKit 红先行：AdminTenantsViewModel 四缝 + 测试挂 M00.F01 | 开发 | Claude | 0.25d | 进行中 |
| T-2 | App：APIGlue 四缝 + TenantsAdminView/TenantEditView/TenantCreateView + AccountView 入口与富化 + 全门绿 + push + gitlink + 模拟器验收准备 | 开发 | Claude | 0.5d | 待开始 |

## 4. 功能影响（需求与功能对齐的唯一位置）

| 功能 ID | 功能名称 | 影响类型 | 说明 | 关联任务 |
|---|---|---|---|---|
| M00.F01 | 租户维护 | 变更 | 规划→开发中：平台 admin 租户 CRUD + 租户名富化（AC-1~6） | T-0 |

## 5. 流程影响

无（本仓尚无流程文档，待人裁遗留项）。

## 6. 风险与回滚

| 风险 | 影响面 | 缓解 | 回滚方式 |
|---|---|---|---|
| 寻址口径与 admin/clients 混淆（那边是 clientId 字符串这边是 UUID） | AC-2/AC-4 | live 双探针实证；两个 VM 各自注释钉死口径 | 回退 commit |
| 删除租户级联影响成员/订阅 | AC-2 | 删除二次确认 + 文字警示级联语义 | 重建租户（dev 种子可重放） |
| 富化拉 admin/tenants 对非 admin 用户 403 轰炸 | AC-5 | 失败静默降级 UUID，只拉一次不重试 | 回退 commit |
