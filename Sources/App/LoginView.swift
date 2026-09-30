import CoreKit
import SwiftUI

// REQ-2026-001 T-3（AC-2，M01.F04）：密码登录页——用户名+密码 → sessions/login
// 换 saas token（clientId 取 SessionStore 配置，VM fail-fast）。网络缝走 APIGlue
// （生成物唯一入口），状态机在 CoreKit.AuthViewModel；成功经 session.refresh()
// 进账户页。

struct LoginView: View {
    let session: AppSession

    @StateObject private var vm: AuthViewModel
    @State private var username = ""
    @State private var password = ""

    init(session: AppSession) {
        self.session = session
        let store = session.store
        _vm = StateObject(wrappedValue: AuthViewModel(
            store: store,
            seams: .init(
                login: APIGlue.login,
                logout: {
                    // 本地无 token（401 失效后重登中）就没啥可吊销的。
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
                Section("登录（\(session.store.clientId ?? "—")）") {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                }
                Section {
                    Button("登录") {
                        Task {
                            if await vm.login(
                                username: username.trimmingCharacters(in: .whitespaces),
                                password: password
                            ) {
                                session.refresh()
                            }
                        }
                    }
                    .disabled(
                        username.trimmingCharacters(in: .whitespaces).isEmpty
                            || password.isEmpty
                            || vm.phase == .busy
                    )
                }
                if case .failed(let message) = vm.phase {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("登录")
        }
    }
}
