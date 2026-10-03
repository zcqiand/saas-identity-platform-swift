# REQ-2026-012：M00.F05 租户应用订阅切片（swift 仓）

- 状态：已上线
- 功能：M00.F05（`tenant_application` 订阅管理，I01~I04）
- 契约依据：`saas-identity-platform-shared/tsp/routes/tenant-applications.tsp`（SSOT，零修改）
- 日期：2026-10-02

## 1. 需求与范围

Swift 侧消费租户应用订阅的 4 个端点，API 面全部来自 shared 生成物
（`TenantApplicationsAPI` + 4 个 model 已在仓内，本次 **shared 零改动**）：

| 子项 | 端点 | Swift 面 |
|---|---|---|
| I01 | GET /tenants/{t}/applications | 列表（Page\<TenantApplication\>） |
| I02 | POST 同路径 | 订阅（SubscribeTenantApplicationRequest{clientId, expireTime?}） |
| I03 | PATCH /{clientId} | 更新（UpdateTenantApplicationRequest{status, expireTime?}） |
| I04 | DELETE /{clientId} | 移除（→ void） |

寻址契约：PATCH/DELETE 用 **clientId 字符串列**，不是 UUID id。

## 2. 澄清记录

- 后端 springboot 探针（2026-10-02 @5105）发现两处与契约相悖的 wire 行为，已修：
  1. **createdAt 恒 null**：契约 REQUIRED、DB 列 NOT NULL、insert 已写值，但
     `TenantApplicationsController.toDto()` 漏 `setCreatedAt` → 严格解码端
     （swift 生成物 `createdAt: Date` 非可选）整个 list 炸。修 = 映射补一行。
     同 commit 强化 contract-test I74/I75 断言（`not.toBeNull()`，
     `toBeDefined()` 拦不住 null，硬规则 §2）。
  2. **subscribe 丢弃 expireTime**：controller 从未读 `body.getExpireTime()`
     → 订阅时填的到期日静默丢失。修 = 非空即 set。
- aspnetcore 5104 抽查（同批 CT live 2-way）：无上述两问题，
  I74/I75 REQUIRED 断言直接过——兄弟仓不带同款病。
- **wire 日期三种形态实测**（FamilyDateFormatter 需全吃）：
  - 种子行 `2026-01-15T08:00:00Z`（T 分隔零分数）
  - 新订阅 `2026-10-02T23:34:52.7575796+08:00`（7 位分数 + 冒号偏移）
  - patch 回读 `2026-10-02T15:34:52.75758Z`（5 位尾零截断 UTC）
- 探针 wart（已修，2026-10-03 家族批）：重复订阅 → 各后端 dup 预检 clean 400（springboot 原裸
  SQL 泄漏；fastapi/rails subscribe expireTime 陈旧镜像同批追平 springboot 01704a2）。CT I75
  同批强化 expireTime 回读 + dup 去泄漏断言；nextjs 409 与其余 400 的分叉登记待人裁。

## 3. 验收标准

- AC-1：CoreKit `TenantApplicationsViewModel` 提供 list/subscribe/update/remove，
  无 currentTenantId 时 fail-fast；seams 默认直连 `APIGlue`，测试可注入。
- AC-2：`FamilyDateFormatter` 解析上述三种 wire 形态 + `TenantApplication`
  种子形态端到端 decode 成功（生成模型 createdAt 非可选，null 即 throw）。
- AC-3：App 层「租户应用」管理视图：列表 + 订阅 sheet（client Picker + 到期日）+
  状态/到期更新 + 移除确认；client 清单复用 AdminClientsViewModel.listClients 模式。
- AC-4：T-1 远门（home-mac）build+test 全绿；红先行（VM 测试先红后绿）。
- AC-5：swift 仓门禁（remote_gate build/test + suite gate）全绿后 push + gitlink。
- AC-6：CT live 2-way（springboot+aspnetcore）tenant-applications 全绿
  （2026-10-02 已验，6/6）。

## 4. 任务拆解

- T-0：function-tree M00.F05 `规划`→`开发中`（免批 mirror 通道）+ 本 REQ 登记。
- T-1：CoreKit——FamilyDateFormatter 补 `isoNoFraction`（已写）+
  `TenantApplicationsViewModel`（4 seams，红先行测试）。
- T-2：App——`APIGlue` 4 seams + `TenantApplicationsAdminView` +
  AccountView 入口；门禁 + push + gitlink。
- 验收：模拟器手测 AC-3 → 人裁「通过」→ GA（M00.F05 `开发中`→`已上线`）。

## 5. 功能影响

| 功能 | 影响 | 子项 |
|---|---|---|
| M00.F05 租户应用 | 变更（规划→实现） | I01~I04 全量 |

15 F 上线 14 → 本片完成后 15/15 收口。

## 6. 验收记录

- **人工验收通过（2026-10-03）**：AC-1~3 模拟器手测（AccountView→租户应用：
  列表渲染含到期时间、订阅 sheet 提交后行追加且 expireTime 落库、详情启停/
  改期/移除二次确认全链）；AC-4~6 门禁兜底（T-1 远门红先行→绿 100 tests
  0 failures；T-2 build+test 双绿 + suite 门禁全绿；CT live 2-way
  springboot+aspnetcore 6/6）。
- 提交链：T-0 4950d60 / T-1 fa5605f / T-2 bef8e8d；后端修复 springboot
  01704a2 + CT 强化 f6e4198；suite gitlink 1f32b1f。
