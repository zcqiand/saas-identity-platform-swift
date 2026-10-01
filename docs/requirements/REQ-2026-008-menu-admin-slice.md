# REQ-2026-008 菜单管理切片（菜单 CRUD + 组树，瘦身版）

| 项 | 值 |
|---|---|
| 提出人 | zcqiand（standing 指令「saas 侧的 Swift 版需求参考 shared 就行，并且要确保 api 是生成的」） |
| 提出日期 | 2026-10-01 |
| 优先级 | P1 |
| 状态 | **开发中**（T-0 免批 base sha eaef3e4fd29839dc） |
| 关联 ADR | ADR-0029（「本仓需要 ≠ shared」停下问人——本切片即其裁决产物） |
| 上游 | saas-identity-platform-shared TypeSpec SSOT（M04.F04 BASE：client-menus.tsp 全套 + me-menus）；前置 REQ-001~007 已上线基座 |

## 1. 需求描述

M04 最后一个 F：**菜单管理**（BASE 已上线，Swift 侧 规划）。管理 OAuth client
维度的菜单全生命周期（对应 shared BASE 同编号 F 的子项），API 面只认生成物
（硬规则 §4）：`ClientMenusAPI` 全套——

- `clientMenusListSysMenus`（GET /api/v1/clients/{clientId}/menus，平铺 `[SysMenu]`）
- `clientMenusCreateSysMenu`（POST，`CreateSysMenuRequest(title:type:parentId:…)`，
  parentId 不传 = 根）
- `clientMenusUpdateSysMenu`（PATCH partial，`UpdateSysMenuRequest` 全可选）
- `clientMenusMoveSysMenu`（PATCH …/{menuId}/parent，`ClientMenusMoveSysMenuRequest(parentId: String?)`，
  null = 移回根）
- `clientMenusReorderSysMenus`（PUT …/{menuId}/reorder，`ReorderSysMenuRequest(orderedMenuIds:)`）
- `clientMenusDeleteSysMenu`（DELETE，204 空 body → Void 缝）

契约形状要点（live 探针实证，2026-10-01 @5101 saas-springboot，含暂存菜单
create→move→update→reorder→delete 全链 + 清理回访 27 条种子原样）：

- **路径双参**：clientId 是字符串（erp/lab-management 口径，同 admin/clients）；
  menuId 生成物是 String 路径参（VM 内 `id.uuidString` 换算）
- **平铺列表根节点 parentId = 零值 UUID** `00000000-0000-0000-0000-000000000000`
  （与 `/me/menus` 的 `null` 是两套口径！）——前端组树：零值 = 根，children 按
  sortOrder 排序，树逻辑放 CoreKit 可测
- reorder 返 **200 空数组**；未知 child id **静默忽略仍 200**（宽松语义）；
  上移/下移 = 对兄弟序列重排后整段提交 orderedMenuIds
- `SysMenu.status` Int（1 启用/0 停用，同 OAuthClient 口径）；`SysMenuType`
  字符串枚举 `directory` / `menu` / `button`；名称字段是 **title** 非 name
- DELETE 返 204 空 body；saas-console 无种子（空 []），种子全在 lab-management

### 两个硬拦截与裁决（2026-10-01 人裁：先瘦身后修契约）

| 拦截 | 事实 | 裁决 |
|---|---|---|
| `/me/menus` 根节点 `parentId: null` vs 生成物 `EffectiveMenuNode.parentId: UUID` 非可选（无自定义 decoder）→ **解码必抛 valueNotFound** | shared .tsp requiredMode=REQUIRED 滞后，四后端 wire 真值是 null | 本切片 AC 排除「当前用户菜单」；shared 侧 parentId 放宽 nullable + 全家族重生成**另立提案走人工批**（消费仓禁单方面改 shared，ADR-0029） |
| `SysMenu.createdAt: Date` vs wire `2026-08-30 00:07:19.257+08`（空格分隔 + 裸 `+08`，非 RFC3339）→ 生成 `OpenISO8601DateFormatter` 三格式全解不了 → **菜单列表解码必炸** | 同款格式也命中 admin/tenants、admin/clients（潜在存量红）；`/me` 面是标准 ISO 不受影响 | 本仓用生成物**公开定制钩子** `CodableHelper.dateFormatter` 装 CoreKit 多格式 FamilyDateFormatter（`yyyy-MM-dd HH:mm:ss[.SSS]X` 优先，回落生成 ISO 格式）——不算改生成物，与 `APIClient.bootstrap` 同构 |

### 范围

| 关注点 | 内容 |
|---|---|
| CoreKit | 新 MenusViewModel：Seams 六缝 listMenus/createMenu/updateMenu/moveMenu/reorderMenus/deleteMenu（抛错缺省同款）；成功原位维护列表（追加/替换/移除，不重拉）；失败红字列表不动可重试；纯函数组树 `buildTree`（零值 UUID = 根，sortOrder 升序）；FamilyDateFormatter + APIClient.bootstrap 安装 + 解码单测 |
| App | APIGlue 六缝走生成物 builder；MenusAdminView（client Picker——复用 AdminClientsViewModel 拉列表 + OutlineGroup 菜单树）→ 新建 sheet（title/type/path/父菜单 Picker/sortOrder）+ 编辑页（改名/路径/status/移动父节点/删除二次确认）+ 兄弟上移/下移（reorder 整段提交）；AccountView 平台管理段加「菜单管理」入口 |
| 测试 | MenusViewModelTests 红先行（fn 挂 M04.F04）；FamilyDateFormatterTests 三种 wire 形态 |

**非范围**：`/me/menus` 当前用户菜单渲染（契约修正提案另行）；菜单翻页 UI；
按钮级菜单的权限码联动（M00.F04 角色菜单授权的地盘）。

### 澄清记录

| 疑问 | 澄清结论 | 澄清人 | 日期 |
|---|---|---|---|
| Q1 /me/menus 解码必炸怎么办 | 人裁三选一：先瘦身后修契约（本切片排除 me/menus，shared requiredMode 修正另立提案）/ 一次到位先修 shared / 后端改零值口径。裁决 = **先瘦身后修契约** | 人（zcqiand） | 2026-10-01 |
| Q2 CRUD 平铺的 parentId 形态 | 零值 UUID 非 null（live 27 条种子 + 暂存菜单实证），SysMenu 合成解码安全 → 树在前端组 | 自裁（live 探针） | 2026-10-01 |
| Q3 Date 解码炸面 | 空格+08 非 RFC3339，生成 formatter 解不了；用 CodableHelper.dateFormatter 公开钩子装多格式 formatter；admin/tenants、admin/clients 同款受益；遗留：REQ-005~007 验收模拟器的 baseURL 待人确认（若打 5101 当时列表应已红） | 自裁（生成物源码 + live 三端点格式对比）→ 遗留项人裁 | 2026-10-01 |
| Q4 reorder 语义 | PUT 父 menuId 下整段兄弟序列 orderedMenuIds；返 200 空数组；未知 id 静默忽略 | 自裁（live 暂存子双探针） | 2026-10-01 |

## 2. 验收标准

| 编号 | 场景（给定） | 操作（当） | 预期（则） |
|---|---|---|---|
| AC-1 | alice 登录，进菜单管理 | 选 client lab-management | 种子平铺渲染成树：零值 UUID 为根、children 按 sortOrder 排序（仪表盘 / 资源管理→合同管理 等层级正确） |
| AC-2 | 树就绪 | 新建菜单（title+type，父可留空=根）→ 再删除 | 创建后树即现；确认删除后节点消失 |
| AC-3 | 编辑页 | 改 title/path、切 status、移动父节点 | 原位更新返回即见新值；兄弟上移/下移后顺序生效（重进仍在） |
| AC-4 | 任意操作失败（断网/403/404） | — | 红字带 HTTP 码，树不动可重试 |
| AC-5 | 5101 空格+08 wire | 打开菜单/租户/应用三个列表 | 三面均正常渲染（FamilyDateFormatter 生效，无「请求失败」解码红） |
| AC-6 | 任意时刻 | 检查 API 面 | 全部来自 SaasSharedGenerated；grep 无手写端点串；Generated/ 目录零改动 |

## 3. 任务拆解

| 任务 ID | 任务描述 | 类型 | 负责人 | 预估 | 状态 |
|---|---|---|---|---|---|
| T-0 | tree-change 提案：M04.F04 规划→开发中（mirror 免批 --apply，令牌 eaef3e4fd29839dc） | 对齐 | Claude | — | 已完成（2026-10-01） |
| T-1 | CoreKit 红先行：MenusViewModel 六缝 + buildTree + FamilyDateFormatter + 测试挂 M04.F04 | 开发 | Claude | 0.5d | 已完成（红实证：首轮远门红 menus setter 不可达 → fixture 改制后绿；70 tests 0 failures，本地 7 门全绿） |
| T-2 | App：APIGlue 六缝 + MenusAdminView（client Picker + 树 + 新建/编辑/移动/排序/删除）+ AccountView 入口 + bootstrap 装 formatter + 全门绿 + push + gitlink + 模拟器验收准备 | 开发 | Claude | 0.5d | 已完成（远门 BUILD SUCCEEDED + 本地 7 门全绿；首轮红 OutlineGroup 需要 Identifiable/可选 children——MenuNode 补 id/childNodes 后绿） |

## 4. 功能影响（需求与功能对齐的唯一位置）

| 功能 ID | 功能名称 | 影响类型 | 说明 | 关联任务 |
|---|---|---|---|---|
| M04.F04 | 菜单管理 | 变更 | 规划→开发中：菜单 CRUD + 结构（组树/移动/排序）瘦身版；「当前用户菜单」随 shared requiredMode 修正提案补齐 | T-0 |

## 5. 流程影响

无（本仓尚无流程文档，待人裁遗留项）。

## 6. 风险与回滚

| 风险 | 影响面 | 缓解 | 回滚方式 |
|---|---|---|---|
| 平铺 parentId 两套口径混淆（CRUD 零值 vs me/menus null） | AC-1 | VM 注释钉死口径；buildTree 单测锁零值=根语义 | 回退 commit |
| FamilyDateFormatter 改全局解码行为，波及已上线三切片 | AC-5 | 格式链先试 ISO 回落空格+08，/me 面（标准 ISO）零影响；单测锁三形态 | bootstrap 移除安装行即回默认 |
| reorder 未知 id 静默 200 掩盖 UI bug | AC-3 | 上移/下移在提交前本地组好整段序列，不依赖服务端校验 | 回退 commit |
| /me/menus 修正提案与 shared 排期冲突 | 非范围 | F04 主体不阻塞；提案走人工批独立推进 | — |
