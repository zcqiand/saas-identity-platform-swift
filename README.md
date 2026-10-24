# SaaS身份平台 · SwiftUI iOS 前端

SaaS 多租户多应用身份平台的 SwiftUI iOS 前端。需求与 API 基线 = `saas-identity-platform-shared` TypeSpec SSOT；react 仓仅为 UI/交互参照实现。

本仓**不绑书稿**：技术栈基线（Xcode 16.2 + Swift 6.0 + iOS 18 SDK，受构建机 Intel Air / macOS 14.5 天花板约束）。API 面只认 `saas-identity-platform-shared` TypeSpec 生成物（openapi.yaml → Swift client），后端可在 nextjs / springboot / aspnetcore 之间切换。

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

- **需求与 API 基线 = `saas-identity-platform-shared` TypeSpec SSOT**：行为规格读 `tsp/*.tsp`，API client 只用 shared 仓 `generated/openapi/openapi.yaml` 生成的 Swift 代码（禁手写接口层，suite 硬规则 §4）。
- 范围：M00/M01/M04 三模块 13 F；M/F 编号沿用 react 仓功能树（同 shared BASE 双账本），便于跨仓对照。
- UI/交互参照：`../saas-identity-platform-react`（参照实现，非基线）。

## 配套书籍及章节映射

> 同一案例仓后续接入其他书籍时，在此节下新增书籍小节。

### 书一《Swift从入门到项目实践》（第二部分）

- 书稿定位：xr-know-013，第 34、35、36、37 章正文代码块挂本仓 `source=` 锚点
- 配套版本：`v0.1.2-20261004`（registry 冻结 tag，代码以此为准）

| 章 | 章题 | 对应源文件 |
| :--- | :--- | :--- |
| 34 | 登录、会话与并发安全：密码登录、whoami 与重启恢复 | `Sources/App/LoginView.swift` + `Sources/CoreKit/AuthViewModel.swift` + `Sources/App/AccountView.swift` |
| 35 | 多页面架构与导航体系：TabView、NavigationStack 与租户切换 | `Sources/App/AccountView.swift` + `Sources/CoreKit/AuthViewModel.swift` |
| 36 | 组织管理实战：租户与成员模块的 CRUD | `Sources/CoreKit/AdminTenantsViewModel.swift` + `Sources/CoreKit/MembersViewModel.swift` |
| 37 | 角色与授权矩阵：复杂表单与批量授权 | `Sources/CoreKit/RolesViewModel.swift` + `Sources/CoreKit/MenusViewModel.swift` |

## 快速链接

- [CLAUDE.md](CLAUDE.md) — 开发约定与编码规范
- [系统架构.md](docs/ARCHITECTURE.md) — 结构 / 边界 / 数据流 / 决策
- [功能规格.md](docs/functions/function-tree.md) — 功能名称、描述与验收标准
- [未来开发计划](PLAN.md) — 待办与迭代方向
- [更新日志](CHANGELOG.md) — 版本变更记录
