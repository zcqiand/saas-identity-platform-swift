# CLAUDE.md — SaaS身份平台

> 镜像仓 + harness 门禁仓双身份。入口，不是手册。L0 门强制上限 60 行。
> 本仓是 SaaS 多租户多应用身份平台的 SwiftUI iOS 变体：需求与 API 基线 = `saas-identity-platform-shared` TypeSpec SSOT（API 只用 shared 生成物，硬规则 §4）；react 仓仅为 UI/交互参照实现，不是基线；不绑书稿。

## 1. 项目定位

SaaS身份平台（`saas-identity-platform-swift`，技术栈 `generic`）。一句话定位见 README.md。

## 2. 铁律

- **TDD**：每个模块先写失败测试 → 跑确认失败 → 实现 → 跑确认绿 → commit
- **版本钉死**：依赖与 `version-lock.json` 的 `version_lock` 一致；不引入 lock 外的库
- **tag 即放行**：全量回归绿后打 `v<MAJOR>.<MINOR>.<PATCH>-<YYYYMMDD>`（如 `v0.3.54-20260826`）
- **mock-friendly**：安装 + 测试必须在无 Key、无 Docker、无网下全绿
- **功能清单是锚点**：改 `docs/functions/function-tree.md` 走 `/tree-change` 提案，由人批准；
  改功能与改功能清单必须同一个 commit；废弃只改状态，编号永不复用；禁止给 skip 的测试挂功能 ID

- **前端 only**：不实现任何后端。后端可在 saas 家族 nextjs / springboot / aspnetcore 之间切换，API 面只认 `saas-identity-platform-shared` TypeSpec 契约生成物（suite 硬规则 §4）
- **SwiftUI iOS**：基线 Xcode 16.2 + Swift 6.0 + iOS 18 SDK。构建机 = `home-mac`（100.102.99.114，Intel Air / macOS 14.5，Tailscale 局域网直连）——本机 Windows 无 Swift 工具链，编译/测试一律 `ssh home-mac` 远程跑；本机门禁当前只有 L0/L5（generic 档），L2/L4 待工具链就绪后接远程命令
- **禁止 env 默认值兜底**：env 缺失必须 fail-fast，不写 `env.X ?? 字面量`

## 3. 技术栈与版本（钉死于 version-lock.json）

任意语言占位档 `generic`（只有 suite 的 L0/L5，L1..L4 留空）。**本仓真身是 SwiftUI iOS**：基线 Xcode 16.2 + Swift 6.0 + iOS 18 SDK（受构建机 Intel Air / macOS 14.5 天花板约束，书稿 6.2/26 基线降档，见 `version-lock.json`），编译与测试只在 `home-mac` 远程跑。明细见 `version-lock.json` 与 README.md 技术栈表。

门禁命令见 `.harness/stack.json`。**不要改它来让门变松。**

## 4. 验收

- 在 **suite 根目录** 跑 `python scripts/gate.py -p saas-identity-platform-swift`；exit 0 才算完成
- 本地命令见 README.md「快速开始」

## 5. 指向别处

- 功能清单（唯一锚点） → `docs/functions/function-tree.md`
- 需求 → 任务 → 功能影响 → `docs/requirements/`
- 流程/设计 与功能对齐 → `docs/design/`（人评审，机器只查引用）
- 决策背景 → `docs/adr/`；编码细则 → `docs/conventions/`（不进主上下文）
- 待办与迭代方向 → `PLAN.md`；版本变更 → `CHANGELOG.md`

## 6. 工作循环

0. **开工前分诊**：先过 `using-skills`，把激活 skill 的清单落成 todo。
   顺序：规格(brainstorming)→计划(writing-plans)→测试先红(red-first)→实现(executing-plans)
1. 读 `.state/session.json` 恢复上下文
2. 最小改动
3. 跑 `python scripts/gate.py -p saas-identity-platform-swift`；exit 1 回到第 2 步；exit 2 停下问人
4. `/handoff` 更新 `.state/session.json`
