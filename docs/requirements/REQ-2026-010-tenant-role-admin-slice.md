# REQ-2026-010 租户角色切片（role CRUD：create/detail/update/delete）

| 项 | 值 |
|---|---|
| 提出人 | zcqiand（standing 指令「saas 侧的 Swift 版需求参考 shared 就行，并且要确保 api 是生成的」） |
| 提出日期 | 2026-10-02 |
| 优先级 | P1 |
| 状态 | **已上线**（GA mirror 免批，人工验收 AC-1~6 通过 2026-10-02） |
| 关联 ADR | ADR-0029（API 面只认生成物，硬规则 §4） |
| 上游 | saas-identity-platform-shared TypeSpec SSOT（M00.F03 BASE：tenant-roles.tsp I01~I05）；前置 REQ-001~009 已上线基座 |

## 1. 需求描述

M00 第三个 F：**租户角色**（BASE 已上线，Swift 侧本切片前 规划）。M01.F02
（REQ-003）已上线「角色清单读取」一缝（listRoles，MembersViewModel 内），
本切片补齐角色 CRUD（I02~I05）+ 独立管理页。角色是 tenant × client 作用域
（SysRole.clientId 必填，绑定一个 OAuth client）。

### 契约形状要点（live 探针实证，2026-10-02 @5101 saas-springboot，临时角色探毕即清 204）

- **list 200**：flat `SysRole`（id/tenantId/clientId/roleCode/roleName/description?/
  isPreset/status/createdAt/updatedAt）；0-indexed 分页同族（App 不传分页参拉全量）；
  空格+08 日期 0 位分数形态——FamilyDateFormatter 现链直接可解，无需新格式
- **create 200**：flat SysRole 回显；createdAt **6 位分数空格+08**（PG 微秒去尾零，
  非 ISO——REQ-009 归一化慢路径已覆盖，无需新代码）
- **重名 roleCode → 500 空 body**：不是 409/400 也不是 family 400 收口形状——
  后端 wart（family「500-class 教训」同款）。App 侧不做前置重名校验（无查重
  端点语义，list 预检有竞态），提交撞重名时红字 `请求失败（HTTP 500）`；
  契约测试同步属后端地盘，本切片记录不修
- **缺 clientId → 400** `fieldErrors.clientId=Required`：契约必填=后端必填，
  本切片无「契约必填性≠后端 DTO」偏差；UI 侧 clientId Picker 必选
- **update 200**：PATCH partial（roleName/description/status；**roleCode 不可改**，
  UpdateSysRoleRequest 无此字段）；响应可信（readback 实证，与 REQ-009 Q2
  roles-PUT-撒谎不同源）
- **delete 204 空 body**；删后 detail 404 `{"code":"NOT_FOUND","message":"Role not found"}`
- **生成物齐全**：TenantRolesAPI 五个 WithRequestBuilder 全在（create/get/
  update/delete/list），零 shared 改动

### 范围

- CoreKit：**RolesViewModel 新建**（五缝 list/create/get/update/delete；
  Seams 模式同族，抛错缺省 fail-fast）——不并入 MembersViewModel（成员页
  角色清单是勾选数据源语义，角色管理页是 CRUD 语义，单 VM 单职责；
  MenusViewModel 六缝先例按 feature 分 VM）
- App：RolesAdminView（client Picker 过滤 + 角色列表 roleCode/roleName/
  status 徽标；工具条「新建角色」sheet：clientId Picker（复用
  APIGlue.listClients）/roleCode/roleName/description）→ RoleDetailAdminView
  （roleName/description 编辑 + status 启停 Toggle + 删除二次确认；
  roleCode/tenantId 只读展示）；AccountView 租户段加「角色管理」入口
- 测试：RolesViewModelTests 五缝生命周期 + fail-fast，挂 M00.F03

### 非范围

- role↔permission 矩阵与角色菜单授权（M00.F04，tenant-role-menus.tsp 另切片）
- 租户应用订阅（M00.F05）
- 重名 roleCode 500 的后端修复（后端地盘，记录待 CT 仓同步断言；本仓仅 UI 红字）
- isPreset 角色是否可删未探（不做前端禁删特判，删除撞后端规则时红字如实呈现）

## 1.1 澄清记录

| 疑问 | 澄清结论 | 澄清人 | 日期 |
|---|---|---|---|
| Q1 重名 roleCode 500 空 body 是否前置重名校验 | 不做（无查重端点语义 + list 预检竞态）；提交撞名红字如实呈现，后端 wart 记档 | 自裁（live 500 探针） | 2026-10-02 |
| Q2 新 VM 还是并入 MembersViewModel | 新建 RolesViewModel：勾选数据源与 CRUD 是两种语义，按 feature 分 VM（MenusViewModel 先例）；MembersViewModel.listRoles 缝不动（已上线 M01.F02 行为零变化） | 自裁（家族单 VM 单 feature 惯例） | 2026-10-02 |
| Q3 clientId 来源 | UI Picker 复用 APIGlue.listClients（admin 面，alice 已验证 200）；不发明自由输入 | 自裁（MenusAdminView client Picker 同款先例） | 2026-10-02 |

## 2. 验收标准

| 编号 | 场景（给定） | 操作（当） | 预期（则） |
|---|---|---|---|
| AC-1 | alice 登录进角色管理页 | — | 角色列表渲染（roleCode/roleName/状态徽标），client Picker 可切换过滤；空格+08 日期解码不炸 |
| AC-2 | 工具条「新建角色」 | 填 clientId/roleCode/roleName 提交 | 列表即现新行；重名 roleCode 提交红字（HTTP 500）列表不动 |
| AC-3 | 进角色详情改 roleName/description | 保存 | 原位更新返回即见；roleCode 只读不可改 |
| AC-4 | 详情页状态启停 | Toggle 切换 | status 0/1 原位生效 |
| AC-5 | 详情页删除 | 二次确认 | 204 后行消失；再进 404 红字 |
| AC-6 | 任意时刻 | 检查 API 面 | 全部来自 SaasSharedGenerated（TenantRolesAPI 生成物）；grep 无手写端点串；Generated/ 零改动 |

## 3. 任务拆解

| 阶段 | 内容 | 类型 | 执行者 | 估时 | 状态 |
|---|---|---|---|---|---|
| T-0 | 树变更 M00.F03 规划→开发中（mirror 免批）+ REQ 落盘 + README/design-map 登记 | 对齐 | Claude | — | 已完成 |
| T-1 | CoreKit 红先行：RolesViewModel 五缝 + 测试挂 M00.F03，远程 test 绿 | 开发 | Claude | 0.5d | 已完成（远程 87 tests 绿） |
| T-2 | App：APIGlue 四缝 + RolesAdminView/RoleDetailAdminView/RoleCreateSheet + AccountView 入口 + 全门绿 + push + gitlink + 验收准备 | 开发 | Claude | 0.5d | 已完成（远门 BUILD SUCCEEDED 一次过 + 本地 7 门全绿） |
| T-3 | GA：凭人工验收通过记录 --apply 免批 翻已上线 + gitlink | 对齐 | Claude | — | 已完成（人工验收 AC-1~6 通过 2026-10-02） |

## 4. 功能影响

| 功能 ID | 功能名称 | 影响类型 | 说明 |
|---|---|---|---|
| M00.F03 | 租户角色 | 变更 | 规划→开发中；list 已随 M01.F02 上线，本切片补 CRUD 四缝 + 管理页 |

## 5. 风险

| 风险 | 波及面 | 缓解 | 回退 |
|---|---|---|---|
| 重名 roleCode 后端 500 空 body | UI 提交路径 | AC-2 红字口径如实呈现；不前置重名校验（Q1）；后端修复与 CT 断言另案 | 回退 commit |
| 新 RolesViewModel 与 MembersViewModel.listRoles 并存 | 已上线 M01.F02 | 不动 MembersViewModel 任何代码（Q2 裁决）；RolesVM 独立五缝 | 回退 commit |
| isPreset 角色可删性未知 | 删除路径 | 不做前端特判（非范围节），后端规则拦截时红字如实呈现 | — |
