import CoreKit
import SwiftUI

// REQ-2026-001 T-3（AC-3/AC-4，M01.F01）：账户页——whoami 渲染当前用户
//（GET /me，数据来自生成物 client），登出清会话回登录页。401 拦截在 APIGlue
// 层触发 expire（AC-5），state 变了根路由自动切登录页。

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
                whoami: APIGlue.whoami
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
                    LabeledContent("成员关系数", value: "\(vm.currentUser?.memberships.count ?? session.store.tenants.count)")
                }
                Section {
                    LabeledContent("后端", value: session.store.baseURL ?? "—")
                    LabeledContent("应用", value: session.store.clientId ?? "—")
                } header: {
                    Text("连接")
                } footer: {
                    Text("currentTenantId 本期只展示不切换（REQ-2026-001 非范围）")
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
                // 消息照常显示。
                _ = await vm.whoami()
            }
        }
    }
}
