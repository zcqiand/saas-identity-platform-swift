import CoreKit
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
                Section {
                    LabeledContent("后端", value: session.store.baseURL ?? "—")
                    LabeledContent("应用", value: session.store.clientId ?? "—")
                } header: {
                    Text("连接")
                } footer: {
                    // memberships 只带 tenantId；租户名富化（admin/tenants）是家族
                    // 既有人裁缝，Swift 侧留后续需求，这里显示 UUID 不兜底字面量。
                    Text("租户显示为 tenantId（租户名富化留后续需求）")
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
                            Text(membership.tenantId.uuidString)
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
