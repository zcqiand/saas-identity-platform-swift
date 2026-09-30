# REQ-2026-004 OAuth 授权码切片（authorize + token 双 grant + refresh）

| 项 | 值 |
|---|---|
| 提出人 | zcqiand（standing 指令「saas 侧的 Swift 版需求参考 shared 就行，并且要确保 api 是生成的」） |
| 提出日期 | 2026-09-30 |
| 优先级 | P1 |
| 状态 | **开发中**（T-0 批准 2026-09-30，base sha 721f4a17；提案存档 .state/tree-change.json） |
| 关联 ADR | ADR-0019（显式配置口径沿用：clientId 来自 SessionStore 配置） |
| 上游 | saas-identity-platform-shared TypeSpec SSOT（M04.F03 已上线：oauth.tsp:10 authorize + oauth.tsp:15 token 双 grant）；REQ-001/002/003 已上线基座；前置依赖：shared 种子修复 873c9d3（saas-console 三件套）+ saas_dev 重灌已落地 |

## 1. 需求描述

M04 第一个落地 F：**身份认证**（OAuth authorize + token + refresh，BASE 已上线，
Swift 侧 规划）。saas 后端的 authorize/token 是 **JSON API**（Bearer 会话直接
POST，非浏览器跳板）——Swift 侧不需要 ASWebAuthenticationSession/WebView，
整个授权码流纯应用内完成（live 探针实证四步全绿）。API 面只认生成物（硬规则 §4）：

- `OauthAPI.oAuthAuthorize`（POST /api/v1/oauth/authorize，请求体
  AuthorizeCodeRequest{clientId, redirectUri, responseType: .code, scope, state}
  → OAuthAuthorize200Response{code, state}）
- `OauthAPI.oAuthToken`（POST /api/v1/oauth/token，TokenRequest 双 grant：
  .authorizationCode{code, redirectUri} / .refreshToken{refreshToken}
  → TokenResponse{accessToken, refreshToken, tokenType, expiresIn, scope?, userId, clientId, tenantId: UUID}）

契约形状要点（live 探针实证，2026-09-30）：
- **authorize 的 scope 后端必填**（生成模型 optional——契约 requiredMode 滞后，
  缺 scope 422/400 INVALID_REQUEST）
- **token 免 clientSecret**（saas-console 公共 client 语义，secret 可不传）
- refresh_token grant 轮换返回全新 token 对（scope/tenantId 回传）
- state 必须回传校验一致（CSRF fail-fast）

### 范围

| 关注点 | 内容 |
|---|---|
| CoreKit | 新 OAuthViewModel：Seams 增 authorize(clientId,redirectUri,scope,state)/exchangeCode(...)/refreshToken(...) 三缝（抛错缺省同款）；state 自生成 + 回传校验不一致 fail-fast；exchange/refresh 成功用 SessionStore.adoptOAuthToken 入账（token 对换新 + tenantId/expiresAt 记录，复用 adoptSwitch fail-fast 惯例：state 非 ready 或 accessToken 空 = 不动原会话） |
| App | OAuthView（AccountView 新段入口）：签发授权码按钮（code + state 回显）→ 换 token（token 对/scope/tenantId/expiresIn 显示）→ 刷新按钮（refresh 轮换入账）；redirectUri/scope 固定默认值（saasidentity://oauth/callback / openid），失败红字 |
| 测试 | OAuthViewModelTests + SessionStore adoptOAuthToken 测试 红先行（fn 挂 M04.F03） |

**非范围**：ASWebAuthenticationSession 浏览器跳板（JSON API 不需要）；
client_credentials grant；token 撤销/内省；多 client 管理 UI（M04.F01/F02）；
redirectUri/scope 的用户可编辑 UI（固定默认值，后续需求再放开）。

### 澄清记录

| 疑问 | 澄清结论 | 澄清人 | 日期 |
|---|---|---|---|
| Q1 用哪个 client 走流 | saas-console（本 app 自身身份）。前置修复已落地：shared 种子 873c9d3 补 saasidentity://oauth/callback + openid/profile + 双 grant，saas_dev 重灌，live 四步链路全绿 | 人裁（AskUserQuestion 选「先修 shared 种子」） | 2026-09-30 |
| Q2 clientSecret 传不传 | 不传。live 探针实证 saas-console 免 secret（公共 client）；TokenRequest.clientSecret 保持 optional 不用 | 自裁（live 实证 + 生成模型 optional） | 2026-09-30 |
| Q3 token 入账后租户上下文 | TokenResponse.tenantId 非可选 UUID——adopt 时与 currentTenantId 对齐记录（同 adoptSwitch 惯例），expiresAt = now + expiresIn | 自裁（生成形状推演 + REQ-002 先例） | 2026-09-30 |

## 2. 验收标准

| 编号 | 场景（给定） | 操作（当） | 预期（则） |
|---|---|---|---|
| AC-1 | alice 登录（saas-console 会话 ready） | 点签发授权码 | code 回显，返回 state 与自生成 state 一致 |
| AC-2 | 有有效 code | 点换 token | TokenResponse 入账：token 对换新，scope/tenantId/expiresIn 渲染 |
| AC-3 | 有有效 refresh token | 点刷新 | refresh_token 轮换成功，新 token 对入账，会话仍 ready |
| AC-4 | 断网/后端拒（错误 scope） | 任意操作 | 红字带 HTTP 码，原会话 token 对不动可重试 |
| AC-5 | 任意时刻 | 检查 API 面 | authorize/token 全来自 SaasSharedGenerated；grep 无手写端点串 |

## 3. 任务拆解

| 任务 ID | 任务描述 | 类型 | 负责人 | 预估 | 状态 |
|---|---|---|---|---|---|
| T-0 | tree-change 提案：M04.F03 规划→开发中 | 对齐 | Claude | — | 已完成（2026-09-30 人工批准） |
| T-1 | CoreKit 红先行：OAuthViewModel 三缝 + SessionStore.adoptOAuthToken + 测试挂 M04.F03 | 开发 | Claude | 0.5d | 待开始 |
| T-2 | App：OAuthView + AccountView 入口 + 全门绿 + push + gitlink + 模拟器验收准备 | 开发 | Claude | 0.5d | 待开始 |

## 4. 功能影响（需求与功能对齐的唯一位置）

| 功能 ID | 功能名称 | 影响类型 | 说明 | 关联任务 |
|---|---|---|---|---|
| M04.F03 | 身份认证 | 变更 | 规划→开发中：OAuth authorize + token 双 grant + refresh（AC-1~4） | T-0 |

## 5. 流程影响

无（本仓尚无流程文档，待人裁遗留项）。

## 6. 风险与回滚

| 风险 | 影响面 | 缓解 | 回滚方式 |
|---|---|---|---|
| 生成模型 scope optional 与后端必填的契约滞后 | AC-1 | 请求侧恒传 scope（默认 openid），不依赖 optional 缺省 | 回退 commit |
| adoptOAuthToken 半途失败留下脏 token 对 | T-1 | fail-fast 校验在所有写操作之前（adoptSwitch 同款先例）；测试覆盖 | 回退 commit |
| shared 种子重灌影响其他 saas 后端 dev 会话 | dev 环境 | 种子全量重灌是设计幂等（TRUNCATE+灌）；lab URI 白名单未动 | git revert 873c9d3 + 重灌 |
