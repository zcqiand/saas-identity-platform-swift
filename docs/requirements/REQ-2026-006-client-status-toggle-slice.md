# REQ-2026-006 应用启用/停用切片（client status 切换）

| 项 | 值 |
|---|---|
| 提出人 | zcqiand（standing 指令「saas 侧的 Swift 版需求参考 shared 就行，并且要确保 api 是生成的」） |
| 提出日期 | 2026-09-30 |
| 优先级 | P1 |
| 状态 | **开发中**（T-0 mirror 免批 --apply；GA 待人工验收后凭 REQ 验收记录免批翻转） |
| 关联 ADR | ADR-0019（显式配置口径沿用） |
| 上游 | saas-identity-platform-shared TypeSpec SSOT（M04.F02 BASE 已上线：admin-clients.tsp I06 setClientStatus）；前置 REQ-005 已上线基座（AdminClientsViewModel 五缝 + ApplicationsView） |

## 1. 需求描述

M04 第三个落地 F：**应用启用/停用**（BASE 已上线，Swift 侧 规划）。
REQ-005 切片里 status 是只读尾巴（「status 切换是 M04.F02 范围，这里只读」），
本切片把它换成真开关。API 面只认生成物（硬规则 §4）：

- `AdminClientsAPI.adminClientsSetClientStatus`（PATCH
  `/api/v1/admin/clients/{clientId}/status`，body `AdminClientsSetClientStatusRequest(status: Int)`，
  返回完整 `OAuthClient`）

契约形状要点（live 探针实证，2026-09-30 @5101 saas-springboot）：
- **路径参数是 clientId 字符串（如 `erp`）不是 UUID** —— handler
  `findByClientId(clientId)` 按 clientId 列寻址；传 UUID 反而 404
- `status` 只认 `0`（停用）/`1`（启用），其余值 400（校验层拒绝）
- 成功返完整 `OAuthClient`（status 已更新）→ 原位替换列表行，不重拉
- 未知 clientId → 404；无 token → 401
- 停用立即生效：后续 authorize/token 端点拒绝该 client（后端语义，本仓不落表）
- 观察：bob 登录同样 200（bob 疑似也是 admin；端点鉴权面是后端/契约测试范围，不属本切片）

### 范围

| 关注点 | 内容 |
|---|---|
| CoreKit | AdminClientsViewModel 增第六缝 `setClientStatus: (_ clientId: String, _ status: Int) async throws -> OAuthClient`（抛错缺省同款）；成功按返回的 OAuthClient 原位替换行（firstIndex by clientId）；失败红字列表不动可重试 |
| App | APIGlue 补 status 缝（走生成物 builder）；ClientDetailView 增「启用状态」段 Toggle（停用走确认 dialog——停用后该 client 的 OAuth/token 立即拒绝）；ApplicationsView 移除「这里只读」footer、行内状态徽标随切换刷新 |
| 测试 | AdminClientsViewModelTests 增 setStatus 用例（fn 挂 M04.F02）红先行 |

**非范围**：批量启停；停用原因/审计展示；client 密钥轮换；删除（REQ-005 已上线）。

### 澄清记录

| 疑问 | 澄清结论 | 澄清人 | 日期 |
|---|---|---|---|
| Q1 路径参数传什么 | clientId 字符串非 UUID。live 实证：UUID → 404，`erp` → 200（与 REQ-005 update/delete 寻址一致，同一 handler 家族） | 自裁（live 双探针 + springboot impl `findByClientId`） | 2026-09-30 |
| Q2 停用要不要二次确认 | 要。停用立即拒绝该 client 的 authorize/token（功能树 F02 语义），误触影响真实接入方；启用不确认（无损） | 自裁（对齐 REQ-005 删除确认惯例，危险度略低用 dialog） | 2026-09-30 |
| Q3 成功后列表怎么更新 | 用返回的 OAuthClient 原位替换（firstIndex by clientId），不重拉列表——与 create/update 家族惯例一致 | 自裁（live 返回完整 OAuthClient 实证） | 2026-09-30 |

## 2. 验收标准

| 编号 | 场景（给定） | 操作（当） | 预期（则） |
|---|---|---|---|
| AC-1 | alice 登录，应用列表就绪 | 进 erp 详情，Toggle 关（停用）→ 确认 | 状态变 0，列表行同步；再开 Toggle（启用）无确认直接生效 |
| AC-2 | client 已停用 | 用该 client 走 authorize | 后端拒绝（Swift 侧验证：详情/列表 status=0 渲染一致） |
| AC-3 | 详情页 Toggle | 切换成功 | 原位替换行，列表不重拉（无二次 list 请求） |
| AC-4 | 切换失败（403/404/断网） | — | 红字带 HTTP 码，Toggle 回弹原状态，列表不动可重试 |
| AC-5 | 任意时刻 | 检查 API 面 | status 缝唯一入口是 `AdminClientsAPI.adminClientsSetClientStatus` 生成物；grep 无手写端点串 |

## 3. 任务拆解

| 任务 ID | 任务描述 | 类型 | 负责人 | 预估 | 状态 |
|---|---|---|---|---|---|
| T-0 | tree-change 提案：M04.F02 规划→开发中（mirror 免批 --apply） | 对齐 | Claude | — | 已完成（2026-09-30） |
| T-1 | CoreKit 红先行：AdminClientsViewModel 第六缝 setStatus + 测试挂 M04.F02 | 开发 | Claude | 0.25d | 已完成（5beb8d7，48 tests 0 failures 连跑两轮；顺手修存量 flaky 21c0534） |
| T-2 | App：APIGlue status 缝 + ClientDetailView Toggle（停用确认）+ 全门绿 + push + gitlink + 模拟器验收准备 | 开发 | Claude | 0.25d | 已完成（2026-09-30，xcodebuild BUILD SUCCEEDED + 本地 7 门全绿，AC-5 grep 干净） |

## 4. 功能影响（需求与功能对齐的唯一位置）

| 功能 ID | 功能名称 | 影响类型 | 说明 | 关联任务 |
|---|---|---|---|---|
| M04.F02 | 应用启用/停用 | 变更 | 规划→开发中：client status 切换（AC-1~5） | T-0 |

## 5. 流程影响

无（本仓尚无流程文档，待人裁遗留项）。

## 6. 风险与回滚

| 风险 | 影响面 | 缓解 | 回滚方式 |
|---|---|---|---|
| 路径参数误传 UUID 致 404 假故障 | AC-1/AC-3 | live 双探针实证传 clientId 字符串；测试断言寻址参数 | 回退 commit |
| 停用误触影响真实接入方 | AC-1 | 停用走确认 dialog；启用不确认（无损） | 重新启用即恢复 |
| 逗号串/0-indexed 等旧坑复发 | — | 沿用 REQ-005 已验证的五缝实现，不动 | — |
