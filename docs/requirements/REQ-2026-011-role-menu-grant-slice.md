# REQ-2026-011 角色菜单授权切片（role↔menu grants：list/set/clear）

| 项 | 值 |
|---|---|
| 提出人 | zcqiand（standing 指令「saas 侧的 Swift 版需求参考 shared 就行，并且要确保 api 是生成的」） |
| 提出日期 | 2026-10-02 |
| 优先级 | P1 |
| 状态 | **开发中**（T-0 免批 mirror） |
| 关联 ADR | ADR-0029（API 面只认生成物，硬规则 §4）；ADR-0025（无 TSP 端点=已废弃） |
| 上游 | saas-identity-platform-shared TypeSpec SSOT（M00.F04 BASE：tenant-role-menus.tsp I02~I04）；前置 REQ-001~010 已上线基座 |

## 1. 需求描述

M00 第四个 F：**角色权限**（BASE 已上线，Swift 侧本切片前 规划）。shared 契约
只有角色菜单授权三操作（I02 list / I03 set / I04 clear）；**I01 role↔permission
矩阵在 shared 无任何端点**（tenant-roles.tsp:39 仅注释占位）——按 ADR-0025
「无 TSP 端点=已废弃，禁加假端点凑 0 命中」，矩阵不实现，本切片范围 =
I02~I04 菜单授权，矩阵记档跳过。授权聚合形状 `RoleMenuGrant`
{roleId, tenantId, menuIds[], updatedAt}（2026-09-10 I20 对齐方案 C，不再返关系行数组）。

### 契约形状要点（live 探针实证，2026-10-02 @5105 saas-springboot saas_dev，临时角色承载写探针探毕即删 204）

- **GET 200**：聚合 RoleMenuGrant；全新角色 menuIds=[] 空、updatedAt
  RFC3339 Z 微秒（现链可解）；预设 admin 角色携 27 项授权可读
- **PUT 200**：幂等全量替换，响应即更新后 RoleMenuGrant（13 项探针）；
  readback **集合相等但顺序不保证**——App 端比较只用 Set，不依赖顺序
- **DELETE 204 空 body**；清后 GET menuIds=[] 空聚合
- **未知 menuId → 400 BAD_REQUEST**，message 泄漏 PG FK 违例 SQL 细节
  （`violates foreign key constraint sys_role_menu_menu_id_sys_menu_id_fk`）
  ——后端 wart 记档；App 端菜单 id 全部来自
  `GET /clients/{code}/menus`（REQ-008 已上线缝），天然不会产生未知 id
- **clientId 查询参**：角色本身已带 clientId（SysRole.clientId 必填）时
  过滤无观察差异（admin 角色 27=27）；App 不传该参
- **5105 库的角色 id 形态**：saas_dev 预设 admin =
  `00000000-0000-0000-0000-a00000000001`（5101 时代探针用的
  a0000000-…-0001 在 5105 库 404 NOT_FOUND）——App 不硬编码角色 id，
  一律走 list 后取行，无此坑
- **生成物齐全**：TenantRoleMenusAPI 三个 WithRequestBuilder 全在
  （list/set/clear，clientId 均为 `String? = nil` 可不传），零 shared 改动

### 范围

- CoreKit：**RolesViewModel 扩三缝**（listGrants/setGrants/clearGrants；
  授权是角色详情页内的语义，与角色 CRUD 同属「角色管理」一个 feature 面，
  授权态挂在已选角色上下文里——不再起新 VM；既有五缝与测试零改动）
- App：APIGlue 三缝（全走 TenantRoleMenusAPI WithRequestBuilder）；
  RoleDetailAdminView 加「菜单授权」段——菜单清单复用 REQ-008
  APIGlue 菜单列表缝（GET /clients/{code}/menus，role.clientId 定源），
  多选勾选 + 「保存授权」PUT + 「清空」DELETE 二次确认；顺序不敏感
  （Set 语义）
- 测试：RolesViewModelTests 追加授权三缝生命周期 + fail-fast，挂 M00.F04

### 非范围

- role↔permission 矩阵（I01）：shared 无端点，ADR-0025 判废弃，不实现不造假端点
- 租户应用订阅（M00.F05，tenant-applications.tsp，本仓最后一个 F，另切片）
- 未知 menuId 400 泄漏 SQL 细节的后端修复（后端地盘，记档待 CT 仓同步）
- clientId 查询参传递（Q3：无观察差异，不传）

## 1.1 澄清记录

| 疑问 | 澄清结论 | 澄清人 | 日期 |
|---|---|---|---|
| Q1 扩 RolesViewModel 还是新建 RoleMenuGrantsViewModel | 扩 RolesViewModel 三缝：授权是角色详情页内语义，与 CRUD 同属「角色管理」feature 面，授权态挂在已选角色上下文；新建 VM 反而要传角色上下文（REQ-010 Q2 单 VM 单 feature 惯例不破——F03/F04 同页同 feature 面） | 自裁（live 探针 + 家族惯例） | 2026-10-02 |
| Q2 I01 permission 矩阵 | 跳过：shared 无 TSP 端点，ADR-0025 判已废弃；本切片只做菜单授权 I02~I04，矩阵记档于本文档与非范围节 | 自裁（shared tenant-roles.tsp:39 注释占位实证） | 2026-10-02 |
| Q3 clientId 查询参 | 不传：live 探针实证角色已带 clientId 时过滤无差异（27=27）；生成物参数留 `nil` | 自裁（live 探针） | 2026-10-02 |
| Q4 菜单清单数据源 | 复用 REQ-008 APIGlue 菜单列表缝（GET /clients/{code}/menus 返回裸数组）；role.clientId 定 client，不发明新端点 | 自裁（REQ-008 已上线缝复用） | 2026-10-02 |

## 2. 验收标准

| 编号 | 场景（给定） | 操作（当） | 预期（则） |
|---|---|---|---|
| AC-1 | alice 登录进角色详情 | — | 「菜单授权」段渲染该 client 菜单清单，已授权项打勾（menuIds 顺序不敏感）；空授权渲染为全不勾 |
| AC-2 | 详情页勾选若干菜单 | 「保存授权」 | PUT 200 原位生效，readback 集合与勾选一致（不依赖顺序）；再进页勾选态保持 |
| AC-3 | 详情页「清空授权」 | 二次确认后执行 | DELETE 204，清单全不勾；再进页仍全不勾 |
| AC-4 | 任意时刻 | 检查菜单 id 来源 | 全部来自 GET /clients/{code}/menus 返回值，UI 不可能产生未知 id（后端 400 FK 路径不可达） |
| AC-5 | 未选租户上下文 / 缝未注入 | 触发任意授权操作 | fail-fast：不发请求、phase 落 failed 红字、缝不被调用 |
| AC-6 | 任意时刻 | 检查 API 面 | 全部来自 SaasSharedGenerated（TenantRoleMenusAPI 生成物）；grep 无手写端点串；Generated/ 零改动 |

## 3. 任务拆解

| 阶段 | 内容 | 类型 | 执行者 | 估时 | 状态 |
|---|---|---|---|---|---|
| T-0 | 树变更 M00.F04 规划→开发中（mirror 免批）+ REQ 落盘 + README/design-map 登记 | 对齐 | Claude | — | 已完成（L5 绿，commit 8c896dc） |
| T-1 | CoreKit 红先行：RolesViewModel 授权三缝 + 测试挂 M00.F04，远程 test 绿 | 开发 | Claude | 0.5d | 已完成（红 52 error → 绿 91 tests，commit a8c6dba） |
| T-2 | App：APIGlue 三缝 + RoleDetailAdminView 菜单授权段 + 全门绿 + push + gitlink + 验收准备 | 开发 | Claude | 0.5d | 已完成（7 门全绿，L2 App 编译含授权段一次过） |
| T-3 | GA：凭人工验收通过记录 --apply 免批 翻已上线 + gitlink | 对齐 | Claude | — | 规划 |

## 4. 功能影响

| 功能 ID | 功能名称 | 影响类型 | 说明 |
|---|---|---|---|
| M00.F04 | 角色权限 | 变更 | 规划→开发中；scope=菜单授权 I02~I04（I01 矩阵 shared 无端点，ADR-0025 记档跳过） |

## 5. 风险

| 风险 | 波及面 | 缓解 | 回退 |
|---|---|---|---|
| 授权 readback 顺序不保证 | UI 勾选态渲染 | 全程 Set 语义比较（Q 探针实证顺序漂移），不依赖数组序 | 回退 commit |
| 未知 menuId 后端 400 泄 SQL | 后端 wart | App 侧 id 全来自菜单清单缝（AC-4 天然不可达）；后端修复与 CT 断言另案记档 | — |
| 扩 RolesViewModel 触碰已上线 M00.F03 | 已上线代码 | 既有五缝与测试零改动，只追加三缝；T-1 远门回归兜底 | 回退 commit |
| menuIds 大清单渲染 | UI 性能 | 角色授权≈单 client 菜单量级（27 项实测），Form+Toggle 足够；无分页需求 | — |
