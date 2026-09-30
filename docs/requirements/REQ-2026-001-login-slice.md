# REQ-2026-001 登录直进切片（生成链 + Xcode 工程 + 密码登录/whoami/登出）

| 项 | 值 |
|---|---|
| 提出人 | zcqiand |
| 提出日期 | 2026-09-30 |
| 优先级 | P1 |
| 状态 | **开发中**（T-0 批准 2026-09-30，base sha e9b62955；提案存档 .state/tree-change.json） |
| 关联 ADR | ADR-0019（baseURL/clientId 用户显式配置，缺失 fail-fast 不兜底字面量） |
| 上游 | saas-identity-platform-shared TypeSpec SSOT（需求与 API 基线）；兄弟前端仓（react/vue/nextjs）登录实现为交互参照 |

## 1. 需求描述

**用户原话**：「saas 侧的 Swift 版需求参考 shared 就行，并且要确保 api 是生成的。」

**理解**：saas-identity-platform-swift 开工。需求面从 saas-identity-platform-shared
契约取；API 面**只认生成物**（suite 硬规则 §4：TypeSpec → OpenAPI.yaml →
openapi-generator swift5 产物，禁手写接口层）。首个切片选 **登录直进**
（家族所有前端仓的第一个功能切片同款），连带把基础设施建齐：

### 范围

| 关注点 | 内容 |
|---|---|
| 生成链 | scripts/gen-shared.sh（镜像 lab swift 配方）：shared `npm run emit:openapi` → openapi-generator swift5（library=urlsession，hideGenerationTimestamp=true）→ `Generated/Sources`（SPM 独立 target `SaasSharedGenerated`，禁手改）；ADR-0026 marker 记 api_synced_sha |
| Package.swift | 加 LabSharedGenerated 同款 target（AnyCodable 依赖视生成物需要）；CoreKit 依赖它；SWIFT_VERSION 5.0 语言模式对齐 lab swift（bootstrap 读写 static var 的 Swift 5 并发模式） |
| Xcode 工程 | project.yml（XcodeGen，镜像 lab swift 全部八坑配置：PRODUCT_NAME 显式 / Intel 排 arm64 / @testable TESTABILITY / framework Info.plist / @rpath / LD_RUNPATH 键名 / 传递嵌入二层框架 / GENERATE_INFOPLIST_FILE 分 target）+ ATS 例外（9870abc 同款，明文 http dev 后端）+ App target（登录/账户 UI 壳）；.xcodeproj 不入仓，远门 L2 每次 xcodegen generate |
| CoreKit | SessionStore（token/用户快照落账，token 进 Keychain；hydrate 恢复；logout 清理）；AuthViewModel（login/logout/whoami，缝注入生成物 API client，失败 fail-fast 不兜底） |
| App | ConfigView（baseURL + clientId，缺失拒存）→ LoginView（用户名+密码）→ AccountView（whoami 展示 + 登出）；401 拦截回登录页 |

**非范围**：租户切换（M01.F03/M00.F02，LoginResponse.currentTenantId 本期只展示不切换）；
SSO 浏览器授权码流（M01.F04 树行既定的密码登录形态先行，OAuth authorize/token 属 M04.F03）；
菜单树渲染（M04.F04）；全部 admin/tenant 配置面（M00.F0x、M04.F01/F02）。

### 澄清记录

| 疑问 | 澄清结论 | 澄清人 | 日期 |
|---|---|---|---|
| Q1 首个切片选哪个 F | **M01.F04（登录/登出）+ M01.F01（whoami）**：家族兄弟仓首个切片同款，依赖面最小（sessions + me 两个路由族），且直接复用 lab swift 已验证的壳层形态（ConfigView/LoginView/AccountView/SessionStore） | 自裁（用户「需求参考 shared」授权从契约面取，切片粒度自裁） | 2026-09-30 |
| Q2 App/工程命名 | 随 Package.swift 既名：工程 `SaaSIdentityPlatform`、App target `SaaSIdentity`、bundleId `com.zcqiand.SaaSIdentity`（bundleIdPrefix 家族惯例）、显示名「身份平台」 | 自裁（lab swift 同构命名先例） | 2026-09-30 |
| Q3 登录 clientId 从哪来 | ConfigView 用户显式配置（与 baseURL 同页，SessionStore 落账，ADR-0019 口径）；dev 惯例值 `saas-console` + `alice/dev123456`（家族 dev 种子约定，非兜底字面量） | 自裁（ADR-0019 既定口径推演） | 2026-09-30 |

## 2. 验收标准

| 编号 | 场景（给定） | 操作（当） | 预期（则） |
|---|---|---|---|
| AC-1 | 冷启动无配置 | 打开 App | 进配置页只收 baseURL + clientId；两者任一为空点保存被拒（fail-fast，不发任何请求） |
| AC-2 | 配置齐 + 真后端活 | 登录页输 `alice/dev123456` 点登录 | `POST /auth/login`（clientId 取配置）换得 LoginResponse，accessToken 落 Keychain，直进账户页 |
| AC-3 | 已登录 | 看账户页 | `GET /me` whoami 渲染当前用户（用户名/当前租户上下文），数据来自生成物 client |
| AC-4 | 已登录 | 点登出 | `POST /auth/logout` + Keychain/快照清空，回登录页 |
| AC-5 | token 失效或后端停 | 任意触 API 操作 | 401 拦截回登录页，旧会话清除，无崩溃 |
| AC-6 | 任意时刻 | 检查 API 面 | 全部端点/DTO 来自 `SaasSharedGenerated` 生成物；CoreKit/App 无手写 URLSession 端点串（grep 可验） |

## 3. 任务拆解

| 任务 ID | 任务描述 | 类型 | 负责人 | 预估 | 状态 |
|---|---|---|---|---|---|
| T-0 | tree-change 提案：M01.F01 + M01.F04 规划→开发中（父行 M01 联动）；REQ 台账行 | 对齐 | Claude | — | 完成 |
| T-1 | 生成链：gen-shared.sh + Generated/SaasSharedGenerated 产物 committed + Package.swift 三 target 接线 + marker | 基建 | Claude | 0.5d | 完成（2b8bdd8，远门 build 绿含 xcodebuild App target） |
| T-2 | CoreKit 红先行：SessionStore + AuthViewModel + 测试挂 ID（trace_cmd 移植 lab swift 版） | 开发 | Claude | 1d | 完成（4c3c222，红先行：测试先红 → 实现 → L4 绿 15 测试 0 失败） |
| T-3 | App 壳：project.yml（八坑 + ATS）+ Config/Login/Account 三 View + APIGlue 缝 + 远门 build 含 App target + 全门绿 + push + gitlink | 开发 | Claude | 1d | 完成（设计映射已补；AC-6 grep 无手写端点串） |

## 4. 功能影响（需求与功能对齐的唯一位置）

| 功能 ID | 功能名称 | 影响类型 | 说明 | 关联任务 |
|---|---|---|---|---|
| M01 | 用户管理 | 变更 | 父行 规划→开发中（F01/F04 子切片开工） | T-0 |
| M01.F01 | 用户维护 | 变更 | 规划→开发中：whoami 账户页（AC-3） | T-0 |
| M01.F04 | SSO 登录 | 变更 | 规划→开发中：密码登录 UI + 登出（AC-1/2/4；OAuth 授权码流后续需求） | T-0 |

## 5. 流程影响

无（本仓尚无流程文档；与 lab swift 同款，流程账为待人裁遗留项）。

## 6. 风险与回滚

| 风险 | 影响面 | 缓解 | 回滚方式 |
|---|---|---|---|
| 生成器对 saas 契约输出漂移（符号枚举非法 case 等） | T-1 生成物编不过 | lab swift 修补①同款 sed + fail-loud 校验；漂移即停问人 | 回退 Generated/ commit |
| saas 契约 OpenAPI 尚未被 swift5 生成器消费过 | T-1 首跑即红 | emit:openapi 已有（openapi.yaml 在仓），生成器 7.24.0 与 lab 同版 | — |
| 登录响应 currentTenantId 可空（单租户/无租户） | AC-2/3 渲染 | 空值显示 —，不兜底字面量 | — |
