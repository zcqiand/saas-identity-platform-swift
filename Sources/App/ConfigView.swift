import SwiftUI

// REQ-2026-001 T-3（AC-1）：配置页——baseURL + clientId 都由用户显式配置
// （ADR-0019，dev 惯例值 saas-console 是文档不是兜底）。任一空点保存被拒
// （按钮禁用 + CoreKit 校验双保险），不发生任何网络请求。

struct ConfigView: View {
    let session: AppSession

    @State private var baseURL = ""
    @State private var clientId = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("后端地址") {
                    TextField("http://100.x.y.z:5101（家族 dev）或 https://…", text: $baseURL)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                Section {
                    TextField("OAuth client_id（如 saas-console）", text: $clientId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("应用标识")
                } footer: {
                    Text("clientId 须与后端 oauth_client.client_id 一致（是字符串不是行 UUID）")
                }
                Section {
                    Button("保存并进入") {
                        do {
                            errorMessage = nil
                            try session.saveConfig(
                                baseURL: baseURL,
                                clientId: clientId.trimmingCharacters(in: .whitespaces)
                            )
                        } catch {
                            errorMessage = String(describing: error)
                        }
                    }
                    .disabled(
                        baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                            || clientId.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("连接配置")
            .onAppear {
                baseURL = session.store.baseURL ?? ""
                clientId = session.store.clientId ?? ""
            }
        }
    }
}
