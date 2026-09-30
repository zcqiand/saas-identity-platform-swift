import CoreKit
import SaasSharedGenerated

// REQ-2026-001 T-3：App 层 API 胶水——生成层 completion 回调 → async 桥，
// 供给 CoreKit ViewModel 的网络缝。API 面只认生成物（硬规则 §4）：
// 登录/登出 = AuthAPI.sessionsLogin/sessionsLogout，whoami = MeAPI.meWhoami，
// 本层无任何手写端点串（AC-6 grep 可验）。

enum APIGlue {

    /// 401 拦截缝（AC-5）：App 层注入（清会话回登录页）；
    /// 本层只识别 401，不感知 SwiftUI / SessionStore。
    static var onUnauthorized: (() -> Void)?

    /// RequestBuilder.execute completion → async/await（取 Response.body）。
    /// 401 统一在这层拦截：先触发回调再原样上抛，调用方照常收到失败。
    static func run<T>(_ build: () -> RequestBuilder<T>) async throws -> T {
        do {
            let builder = build()
            let response: Response<T> = try await withCheckedThrowingContinuation { continuation in
                _ = builder.execute { continuation.resume(with: $0) }
            }
            return response.body
        } catch let error as ErrorResponse {
            if case .error(401, _, _, _) = error {
                onUnauthorized?()
            }
            throw error
        }
    }

    // MARK: - 会话（M01.F04 / M01.F01）

    /// 密码登录（AC-2）：用户名+密码+clientId 换 saas token。
    static let login: (String, String, String) async throws -> LoginResponse = { username, password, clientId in
        try await run {
            AuthAPI.sessionsLoginWithRequestBuilder(
                loginRequest: LoginRequest(username: username, password: password, clientId: clientId)
            )
        }
    }

    /// 登出（AC-4）：服务端吊销当前 token（Bearer 在头里，无请求体）。
    static let logout: () async throws -> Void = {
        _ = try await run { AuthAPI.sessionsLogoutWithRequestBuilder() }
    }

    /// whoami（AC-3）：当前用户 + 租户成员关系。
    static let whoami: () async throws -> CurrentUser = {
        try await run { MeAPI.meWhoamiWithRequestBuilder() }
    }

    // MARK: - 租户成员（M01.F03，REQ-2026-002）

    /// 当前用户跨租户成员关系（AC-1）：GET /me/tenants → [TenantMembership]。
    static let listTenants: () async throws -> [TenantMembership] = {
        try await run { MeAPI.meListMyTenantsWithRequestBuilder() }
    }

    /// 切换租户（AC-2）：POST /me/tenants/{tenantId}/switch → 换发新 token 对。
    static let switchTenant: (String) async throws -> SwitchTenantResponse = { tenantId in
        try await run { MeAPI.meSwitchTenantWithRequestBuilder(tenantId: tenantId) }
    }
}
