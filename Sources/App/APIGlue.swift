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

    // MARK: - 成员角色绑定（M01.F02，REQ-2026-003）

    /// 租户成员列表（AC-1）：GET /tenants/{tenantId}/members（默认页一次拉取，
    /// 分页 UI 非范围）。
    static let listMembers: (String) async throws -> TenantMembersListTenantUsers200Response = { tenantId in
        try await run { TenantMembersAPI.tenantMembersListTenantUsersWithRequestBuilder(tenantId: tenantId) }
    }

    /// 租户角色清单（AC-1 勾选数据源）：GET /tenants/{tenantId}/roles。
    static let listRoles: (String) async throws -> TenantRolesListSysRoles200Response = { tenantId in
        try await run { TenantRolesAPI.tenantRolesListSysRolesWithRequestBuilder(tenantId: tenantId) }
    }

    /// 角色全量覆盖分配（AC-2/AC-3）：PUT /tenants/{tenantId}/members/{userId}/roles，
    /// 提交的 roleIds 集合就是该成员最终角色集（契约语义，不发明增量协议）。
    static let assignRoles: (String, String, [String]) async throws -> TenantMemberUserView = { tenantId, userId, roleIds in
        try await run {
            TenantMembersAPI.tenantMembersAssignTenantMemberRolesWithRequestBuilder(
                tenantId: tenantId,
                userId: userId,
                setTenantMemberRolesRequest: SetTenantMemberRolesRequest(roleIds: roleIds)
            )
        }
    }

    // MARK: - OAuth 授权码流（M04.F03，REQ-2026-004）

    /// 签发授权码（AC-1）：POST /oauth/authorize。state 由调用方（OAuthViewModel）
    /// 自生成并要求回传一致（CSRF）；scope 恒传（后端必填，live 实证）。
    static let oauthAuthorize: (String, String, String, String) async throws -> OAuthAuthorize200Response = { clientId, redirectUri, scope, state in
        try await run {
            OauthAPI.oAuthAuthorizeWithRequestBuilder(
                authorizeCodeRequest: AuthorizeCodeRequest(
                    clientId: clientId,
                    redirectUri: redirectUri,
                    responseType: .code,
                    scope: scope,
                    state: state
                )
            )
        }
    }

    /// 换 token（AC-2，authorization_code grant）：POST /oauth/token。
    /// 免 clientSecret（saas-console 公共 client，live 实证）。
    static let oauthExchangeCode: (String, String, String) async throws -> TokenResponse = { code, clientId, redirectUri in
        try await run {
            OauthAPI.oAuthTokenWithRequestBuilder(
                tokenRequest: TokenRequest(
                    grantType: .authorizationCode,
                    code: code,
                    clientId: clientId,
                    redirectUri: redirectUri
                )
            )
        }
    }

    /// 刷新（AC-3，refresh_token grant）：POST /oauth/token，轮换全新 token 对。
    static let oauthRefresh: (String, String) async throws -> TokenResponse = { refreshToken, clientId in
        try await run {
            OauthAPI.oAuthTokenWithRequestBuilder(
                tokenRequest: TokenRequest(
                    grantType: .refreshToken,
                    refreshToken: refreshToken,
                    clientId: clientId
                )
            )
        }
    }

    // MARK: - 应用维护（M04.F01，REQ-2026-005）

    /// client 全量清单（AC-1）：GET /admin/clients。不传分页——live 实证
    /// 分页 0-indexed（page=1 是第二页偏移出界），nil 全量，翻页 UI 非范围。
    static let listClients: () async throws -> AdminClientsListClients200Response = {
        try await run { AdminClientsAPI.adminClientsListClientsWithRequestBuilder() }
    }

    /// client 详情（AC-2）：GET /admin/clients/{clientId}（密钥不返明文，模型无此字段）。
    static let getClient: (String) async throws -> OAuthClient = { clientId in
        try await run { AdminClientsAPI.adminClientsGetClientWithRequestBuilder(clientId: clientId) }
    }

    /// 注册新 client（AC-4）：POST /admin/clients（clientSecret 必填录入）。
    static let createClient: (CreateOAuthClientRequest) async throws -> OAuthClient = { request in
        try await run { AdminClientsAPI.adminClientsCreateClientWithRequestBuilder(createOAuthClientRequest: request) }
    }

    /// 更新 client（AC-3）：PUT /admin/clients/{clientId}（partial 请求只提交改动字段）。
    static let updateClient: (String, UpdateOAuthClientRequest) async throws -> OAuthClient = { clientId, request in
        try await run { AdminClientsAPI.adminClientsUpdateClientWithRequestBuilder(clientId: clientId, updateOAuthClientRequest: request) }
    }

    /// 删除 client（AC-4，危险操作）：DELETE /admin/clients/{clientId}，服务端
    /// 吊销该 client 名下全部 token；App 层确认后才调。
    static let deleteClient: (String) async throws -> Void = { clientId in
        _ = try await run { AdminClientsAPI.adminClientsDeleteClientWithRequestBuilder(clientId: clientId) }
    }

    /// 启用/停用（REQ-2026-006，M04.F02）：PATCH /admin/clients/{clientId}/status。
    /// 路径寻址 clientId 字符串非 UUID（live 实证）；status 1=启用 0=停用，
    /// 其余 400。停用后该 client 的 authorize/token 立即被后端拒绝。
    static let setClientStatus: (String, Int) async throws -> OAuthClient = { clientId, status in
        try await run {
            AdminClientsAPI.adminClientsSetClientStatusWithRequestBuilder(
                clientId: clientId,
                adminClientsSetClientStatusRequest: AdminClientsSetClientStatusRequest(status: status)
            )
        }
    }

    /// 公共 client 元数据（I06）：GET /clients/{clientId}，匿名可读三字段。
    static let publicClient: (String) async throws -> OAuthClientPublicInfo = { clientId in
        try await run { ClientsAPI.clientsGetClientWithRequestBuilder(clientId: clientId) }
    }
}
