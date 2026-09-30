# REQ-2026-005 应用维护切片（OAuth client CRUD + 公共元数据）

| 项 | 值 |
|---|---|
| 提出人 | zcqiand（standing 指令「saas 侧的 Swift 版需求参考 shared 就行，并且要确保 api 是生成的」） |
| 提出日期 | 2026-09-30 |
| 优先级 | P1 |
| 状态 | **已上线**（2026-09-30 人工验收 AC-1~5 通过；T-0 批准 base sha f22087e5，GA 免批令牌 base sha efda5bac） |
| 关联 ADR | ADR-0019（显式配置口径沿用） |
| 上游 | saas-identity-platform-shared TypeSpec SSOT（M04.F01 已上线：admin-clients.tsp I01~I05 + clients.tsp:10 公共元数据 I06）；前置 REQ-001~004 已上线基座 |

## 1. 需求描述

M04 第二个落地 F：**应用维护**（BASE 已上线，Swift 侧 规划）。平台 admin 视角
管理 OAuth client 全生命周期（对应 shared BASE 同编号 F 的 I01~I05 子项）+
公共 client 元数据（I06）。API 面只认生成物（硬规则 §4）：

- `AdminClientsAPI.adminClientsListClients`（GET /api/v1/admin/clients，
  分页；**live 探针实证分页 0-indexed**：无参/`page=0` 返全量，`page=1` 是
  第二页偏移出界 → App 侧传 nil 拉默认全量，不做翻页 UI）
- `adminClientsGetClient`（详情；密钥不返明文——生成模型 OAuthClient 本就无
  secret 字段）、`adminClientsCreateClient`、`adminClientsUpdateClient`、
  `adminClientsDeleteClient`（删除即服务端吊销该 client 名下全部 token）
- `ClientsAPI.clientsGetClient`（公共匿名元数据 clientId/name/status）

契约形状要点（live 探针实证，2026-09-30）：
- `redirectUris` / `grantTypes` / `scopes` 在模型里是 **String 逗号串**（DB
  形态直出，非数组）；UI 输入用逗号分隔文本行，展示原样
- `CreateOAuthClientRequest.clientSecret` **必填**（注册时由用户录入）
- `OAuthClient.status: Int`（1=启用 0=停用，本切片只读展示，切换是 M04.F02）
- alice 对 /admin/clients 有权（live 200，4 条种子 client）

### 范围

| 关注点 | 内容 |
|---|---|
| CoreKit | 新 AdminClientsViewModel：Seams 增 listClients/getClient/createClient/updateClient/deleteClient 五缝（抛错缺省同款）；delete 走确认流（危险操作），成功后原位移除列表行；create/update 成功用返回的 OAuthClient 原位更新；phase 红字惯例同 MembersViewModel |
| App | ApplicationsView（AccountView 新段入口：client 列表 clientId/名称/状态）→ ClientDetailView（详情只读 + 编辑表单：名称/redirectUris/grantTypes/scopes 逗号行）+ ClientCreateView（clientId/名称/secret/白名单/逗号行）+ 删除确认 AlertDialog；公共元数据段（clientsGetClient 渲染 saas-console 自身） |
| 测试 | AdminClientsViewModelTests 红先行（fn 挂 M04.F01） |

**非范围**：status 启用/停用切换 UI（M04.F02，adminClientsSetClientStatus）；
翻页 UI（数据量小，nil 全量）；client 密钥轮换/重置；logo/图标编辑；
按 client 过滤搜索。

### 澄清记录

| 疑问 | 澄清结论 | 澄清人 | 日期 |
|---|---|---|---|
| Q1 分页参数怎么传 | 不传（nil 全量）。live 实证分页 0-indexed，page=1&pageSize=20 返 0 条（偏移出界）；种子仅 4 条，翻页 UI 非范围 | 自裁（live 探针 + 家族在册指纹「分页 0-indexed+ps=20」） | 2026-09-30 |
| Q2 secret 怎么处理 | 创建时必填录入（契约形状）；详情/编辑不返不明文（生成模型无 secret 字段，天然满足「仅指纹」语义） | 自裁（生成模型推演 + BASE I03 描述） | 2026-09-30 |
| Q3 逗号串字段 UI | redirectUris/grantTypes/scopes 用逗号分隔 TextField（DB 形态直出，不发明数组转换层）；展示原样 | 自裁（live get erp 实证 String 形态） | 2026-09-30 |

## 2. 验收标准

| 编号 | 场景（给定） | 操作（当） | 预期（则） |
|---|---|---|---|
| AC-1 | alice 登录（平台 admin） | 进应用列表 | 4 条种子 client 全量渲染（clientId/名称/status） |
| AC-2 | 列表就绪 | 点开 erp 详情 | grantTypes/redirectUris/scopes 逗号串原样展示，无 secret 字段 |
| AC-3 | 详情页 | 改名称保存 | update 成功原位更新，返回列表见新名 |
| AC-4 | 列表页 | 新建 client（含 secret）→ 再删除 | 创建后列表 +1；确认删除后行消失（服务端吊销其 token） |
| AC-5 | 任意操作失败（断网/403） | — | 红字带 HTTP 码，列表/会话不动可重试 |
| AC-6 | 任意时刻 | 检查 API 面 | 全部来自 SaasSharedGenerated；grep 无手写端点串 |

## 3. 任务拆解

| 任务 ID | 任务描述 | 类型 | 负责人 | 预估 | 状态 |
|---|---|---|---|---|---|
| T-0 | tree-change 提案：M04.F01 规划→开发中 | 对齐 | Claude | — | 已完成（2026-09-30 人工批准） |
| T-1 | CoreKit 红先行：AdminClientsViewModel 五缝 + 测试挂 M04.F01 | 开发 | Claude | 0.5d | 已完成（5997a3d，45 tests 0 failures） |
| T-2 | App：ApplicationsView/ClientDetailView/ClientCreateView + 全门绿 + push + gitlink + 模拟器验收准备 | 开发 | Claude | 0.5d | 已完成（c7cc651，人工验收 AC-1~5 通过 2026-09-30） |

## 4. 功能影响（需求与功能对齐的唯一位置）

| 功能 ID | 功能名称 | 影响类型 | 说明 | 关联任务 |
|---|---|---|---|---|
| M04.F01 | 应用维护 | 变更 | 规划→开发中：OAuth client CRUD + 公共元数据（AC-1~5） | T-0 |

## 5. 流程影响

无（本仓尚无流程文档，待人裁遗留项）。

## 6. 风险与回滚

| 风险 | 影响面 | 缓解 | 回滚方式 |
|---|---|---|---|
| 分页 0-indexed 误用导致列表假空 | AC-1 | 传 nil 拉全量（live 双探针实证）；测试断言 4 条 | 回退 commit |
| 删除 client 误操作（吊销 token 不可逆） | AC-4 | 删除走确认 AlertDialog 二次确认 | — |
| 逗号串字段被当数组处理引入转换层 | AC-2 | 契约形状原样透传（Q3），不发明转换 | 回退 commit |
