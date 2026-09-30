import CoreKit
import SaasSharedGenerated
import SwiftUI

// REQ-2026-004 T-2（M04.F03，AC-1~AC-4）：OAuth 授权码流页——AccountView 新段
// NavigationLink 进入。三步：签发授权码（code + state 回显）→ 换 token（入账
// SessionStore）→ 刷新（refresh_token 轮换入账）。token 对/scope/tenantId/
// expiresAt 渲染自 SessionStore（入账后自然刷新）；失败红字、原会话不动可重试。
// redirectUri/scope 固定默认值（非范围：可编辑 UI）；API 面只认生成物（硬规则 §4）。

struct OAuthView: View {
    let session: AppSession

    @StateObject private var vm: OAuthViewModel

    init(session: AppSession) {
        self.session = session
        _vm = StateObject(wrappedValue: OAuthViewModel(
            store: session.store,
            seams: .init(
                authorize: APIGlue.oauthAuthorize,
                exchangeCode: APIGlue.oauthExchangeCode,
                refreshToken: APIGlue.oauthRefresh
            )
        ))
    }

    var body: some View {
        Form {
            Section {
                Button("签发授权码") {
                    Task {
                        _ = await vm.authorize()
                        session.refresh()
                    }
                }
                .disabled(vm.phase == .busy)
                if let code = vm.lastCode {
                    LabeledContent("授权码", value: code)
                        .font(.footnote.monospaced())
                    LabeledContent("state（回传一致）", value: vm.lastState ?? "—")
                        .font(.footnote.monospaced())
                } else {
                    Text("尚未签发").foregroundStyle(.secondary)
                }
            } header: {
                Text("第一步 · authorize")
            } footer: {
                Text("state 自生成并要求后端回传一致（CSRF）；scope 恒传 openid")
            }

            Section {
                Button("换 token") {
                    Task {
                        _ = await vm.exchangeCode()
                        session.refresh()
                    }
                }
                .disabled(vm.phase == .busy || vm.lastCode == nil)
                tokenRows
            } header: {
                Text("第二步 · token（authorization_code）")
            } footer: {
                Text("免 clientSecret（saas-console 公共 client）")
            }

            Section {
                Button("刷新") {
                    Task {
                        _ = await vm.refresh()
                        session.refresh()
                    }
                }
                .disabled(vm.phase == .busy || session.store.refreshToken?.isEmpty != false)
            } header: {
                Text("第三步 · refresh（轮换）")
            } footer: {
                Text("refresh_token grant 返回全新 token 对并入账")
            }

            if case .failed(let message) = vm.phase {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("OAuth 授权码")
    }

    /// token 对与租户上下文渲染自 SessionStore（AC-2）：入账成功后 store 已换新。
    @ViewBuilder
    private var tokenRows: some View {
        if let token = session.store.token {
            LabeledContent("accessToken", value: token)
                .font(.footnote.monospaced())
            if let refresh = session.store.refreshToken {
                LabeledContent("refreshToken", value: refresh)
                    .font(.footnote.monospaced())
            }
            LabeledContent("scope", value: OAuthViewModel.defaultScope)
            LabeledContent("tenantId", value: session.store.currentTenantId?.uuidString ?? "—")
                .font(.footnote.monospaced())
            LabeledContent(
                "expiresAt",
                value: session.store.expiresAt.map {
                    $0.formatted(date: .abbreviated, time: .standard)
                } ?? "—"
            )
        } else {
            Text("尚未入账").foregroundStyle(.secondary)
        }
    }
}
