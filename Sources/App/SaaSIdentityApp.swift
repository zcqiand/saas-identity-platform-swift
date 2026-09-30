import CoreKit
import SwiftUI

// REQ-2026-001 T-3：App 入口三态路由。
// needsSetup → 配置页（baseURL + clientId，AC-1：零 API 调用）；
// needsLogin → 登录页（AC-2 密码登录；401 失效/登出也落这，AC-4/5）；
// ready → 账户页（AC-3 whoami）。CoreKit.SessionStore 管状态，本层只做 SwiftUI 绑定。

@main
struct SaaSIdentityApp: App {
    @StateObject private var session = AppSession()

    var body: some Scene {
        WindowGroup {
            switch session.state {
            case .needsSetup:
                ConfigView(session: session)
            case .needsLogin:
                LoginView(session: session)
            case .ready:
                AccountView(session: session)
            }
        }
    }
}

/// SessionStore 的 SwiftUI 壳：state 变化驱动根视图切换。
final class AppSession: ObservableObject {
    let store: SessionStore
    @Published private(set) var state: SessionStore.SessionState

    init(store: SessionStore = SessionStore(defaults: .standard, secrets: KeychainTokenStore())) {
        self.store = store
        state = store.state
        // 重启恢复（ready）：hydrate 只回了内存态，basePath/Bearer 还没注入
        // 生成层——这里补 bootstrap，否则冷启直接调 /me 会打到默认路径。
        if state == .ready, let baseURL = store.baseURL, let token = store.token {
            _ = try? APIClient.bootstrap(baseURL: baseURL, token: token)
        }
        // 401 拦截缝（AC-5）：与登出同语义——清会话留配置回登录页。
        APIGlue.onUnauthorized = { [weak self] in self?.expire() }
    }

    /// 配置页保存（AC-1：baseURL + clientId 任一空拒存，CoreKit 校验）。
    func saveConfig(baseURL: String, clientId: String) throws {
        try store.saveConfig(baseURL: baseURL, clientId: clientId)
        state = store.state
    }

    /// 登录/登出后由页面调：重读 store 三态驱动根路由。
    func refresh() {
        state = store.state
    }

    /// 401 失效缝（AC-5）。
    func expire() {
        store.logout()
        state = store.state
    }
}
