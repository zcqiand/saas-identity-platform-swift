import CoreKit
import SaasSharedGenerated
import SwiftUI

// REQ-2026-001 T-3（AC-3/AC-4，M01.F01）：账户页——whoami 渲染当前用户
//（GET /me，数据来自生成物 client），登出清会话回登录页。401 拦截在 APIGlue
// 层触发 expire（AC-5），state 变了根路由自动切登录页。
// REQ-2026-002（M01.F03）：租户段升级为成员关系列表 + 点选切换。数据源 Q1：
// 先用登录快照渲染（离线可见），进页 meListMyTenants 拉真值覆盖；点选发
// switch（换发 token 对入账），成功 whoami 重拉，失败红字保会话可重试（AC-3）。

struct AccountView: View {
    let session: AppSession

    @StateObject private var vm: AuthViewModel

    /// REQ-2026-007（AC-5）租户名富化：admin/tenants 的 id→name 映射，进页拉
    /// 一次。403/失败静默降级显示 UUID（非 admin 用户不炸、不重试轰炸）。
    @State private var tenantNames: [UUID: String] = [:]

    init(session: AppSession) {
        self.session = session
        let store = session.store
        _vm = StateObject(wrappedValue: AuthViewModel(
            store: store,
            seams: .init(
                login: APIGlue.login,
                logout: {
                    if store.token != nil {
                        try await APIGlue.logout()
                    }
                },
                whoami: APIGlue.whoami,
                switchTenant: APIGlue.switchTenant,
                listTenants: APIGlue.listTenants
            )
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("当前用户") {
                    LabeledContent("用户名", value: session.store.user?.username ?? "—")
                    LabeledContent("邮箱", value: vm.currentUser?.email ?? "—")
                    LabeledContent(
                        "当前租户",
                        value: (vm.currentUser?.currentTenantId ?? session.store.currentTenantId)
                            .map { $0.uuidString } ?? "—"
                    )
                    LabeledContent("成员关系数", value: "\(session.store.tenants.count)")
                }
                tenantsSection
                // M04.F01（REQ-2026-005）入口：平台 admin 视角管理 OAuth client。
                Section {
                    NavigationLink("应用维护（OAuth client 管理）") {
                        ApplicationsView()
                    }
                    // M00.F01（REQ-2026-007）入口：平台 admin 视角管理租户。
                    NavigationLink("租户管理（平台 admin）") {
                        TenantsAdminView()
                    }
                    // M04.F04（REQ-2026-008）入口：菜单 CRUD + 组树（client 维度）。
                    NavigationLink("菜单管理（client 维度树）") {
                        MenusAdminView()
                    }
                } header: {
                    Text("平台管理")
                }
                Section {
                    LabeledContent("后端", value: session.store.baseURL ?? "—")
                    LabeledContent("应用", value: session.store.clientId ?? "—")
                } header: {
                    Text("连接")
                } footer: {
                    Text("租户段显示真名（admin/tenants 富化；无权限时显示 tenantId）")
                }
                Section {
                    Button("登出", role: .destructive) {
                        Task {
                            await vm.logout()
                            session.refresh()
                        }
                    }
                    .disabled(vm.phase == .busy)
                }
                if case .failed(let message) = vm.phase {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("身份平台")
            .task {
                // AC-3：进页拉 whoami；401 时 APIGlue 已触发 expire 换页，失败
                // 消息照常显示。AC-1：同时拉成员关系真值覆盖快照（Q1）。
                _ = await vm.whoami()
                _ = await vm.listTenants()
                session.refresh()
                // AC-5 富化：拉一次 admin/tenants 建 id→name；403/失败静默降级
                // UUID（非 admin 用户、断网都不炸不重试）。
                if let page = try? await APIGlue.listAllTenants() {
                    tenantNames = Dictionary(uniqueKeysWithValues: page.items.map { ($0.id, $0.name) })
                }
            }
        }
    }

    /// 租户段（M01.F03 AC-1/AC-2/AC-3）：成员关系列表，当前租户 ✓ 标记，
    /// 点选切换；busy 禁点防连击。
    @ViewBuilder
    private var tenantsSection: some View {
        Section {
            ForEach(session.store.tenants) { membership in
                let isCurrent = membership.tenantId == session.store.currentTenantId
                Button {
                    guard isCurrent == false else { return }
                    Task {
                        // 成功：换发 token 入账 + whoami 重拉（VM 内）；失败：
                        // 红字报 HTTP 码，store 未被触碰（adoptSwitch fail-fast 在前）。
                        // refresh() 重渲列表（✓ 跟随新 currentTenantId，AC-2/AC-3）。
                        _ = await vm.switchTenant(to: membership.tenantId.uuidString)
                        session.refresh()
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tenantNames[membership.tenantId] ?? membership.tenantId.uuidString)
                                .font(.footnote.monospaced())
                            Text("角色 \(membership.roleIds.joined(separator: "、")) · \(membership.status.rawValue)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isCurrent {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .disabled(vm.phase == .busy)
            }
            if session.store.tenants.isEmpty {
                Text("无成员关系").foregroundStyle(.secondary)
            }
            // M01.F02（REQ-2026-003）入口：选定租户上下文后才能管成员角色。
            if session.store.currentTenantId != nil {
                NavigationLink("成员角色（列表 + 分配）") {
                    MembersView(session: session)
                }
            }
            // M04.F03（REQ-2026-004）入口：OAuth 授权码流（authorize → token → refresh）。
            NavigationLink("OAuth 授权码（签发 / 换 token / 刷新）") {
                OAuthView(session: session)
            }
        } header: {
            Text("租户成员")
        } footer: {
            Text("点选其他租户即切换（换发 token，当前租户带 ✓）")
        }
    }
}
