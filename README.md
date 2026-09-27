# SaaS身份平台 · SwiftUI iOS 前端

SaaS 多租户多应用身份平台的 SwiftUI iOS 前端 —— 需求与功能基线跟随 `../saas-identity-platform-react`（同契约异实现镜像仓），前端 only。

本仓**不绑书稿**：需求按 react 仓走；技术栈基线（Xcode 16.2 + Swift 6.0 + iOS 18 SDK，受构建机 Intel Air / macOS 14.5 天花板约束）。API 面只认 `saas-identity-platform-shared` TypeSpec SSOT，后端可在 nextjs / springboot / aspnetcore 之间切换。

## 快速开始

```bash
# 本机 Windows：无 Swift 工具链，只有 suite 门禁（L0/L5）
python scripts/gate.py -p saas-identity-platform-swift   # 在 suite 根目录跑

# 真构建在构建机 home-mac（Tailscale）：Xcode 16.2 + Swift 6.0
git push && ssh home-mac "git -C <仓路径> pull && swift build && swift test"
```

## 功能特性

镜像 react 仓 M00/M01/M04 三模块 13 功能（见 `docs/functions/function-tree.md`，全部 `规划`）。

## 技术栈

| 技术 | 版本 |
| :--- | :--- |
| Xcode | 16.2（构建机 home-mac，Intel Air / macOS 14.5） |
| Swift | 6.0 |
| SwiftUI | iOS 18 SDK |
| 门禁档 | generic（L0/L5；L2/L4 待接 home-mac 远程命令） |

> 依赖版本与 `version-lock.json` 的 `version_lock` 一致，不引入 lock 外的库。

## 需求基线

跟随 `../saas-identity-platform-react`：M/F 编号与 react 仓功能树逐条对齐（shared BASE 双账本），需求变更以 react 仓为上游。

## 快速链接

- [CLAUDE.md](CLAUDE.md) — 开发约定与编码规范
- [系统架构.md](docs/ARCHITECTURE.md) — 结构 / 边界 / 数据流 / 决策
- [功能规格.md](docs/functions/function-tree.md) — 功能名称、描述与验收标准
- [未来开发计划](PLAN.md) — 待办与迭代方向
- [更新日志](CHANGELOG.md) — 版本变更记录
