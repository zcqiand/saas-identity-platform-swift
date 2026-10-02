import CoreKit
import Foundation
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

    // MARK: - 成员生命周期（M00.F02，REQ-2026-009）

    /// 成员详情（I03）：GET /tenants/{tenantId}/members/{userId}。
    /// userId = sys_user.id 字符串（生成物路径参口径）。
    static let getMember: (String, String) async throws -> TenantMemberUserView = { tenantId, userId in
        try await run { TenantMembersAPI.tenantMembersGetTenantUserWithRequestBuilder(tenantId: tenantId, userId: userId) }
    }

    /// 新建成员（I02）：POST /tenants/{tenantId}/members。email 契约 optional
    /// 但后端必填（live 400 实证，REQ-009 Q1）——必填校验归 UI 层。
    static let createMember: (String, CreateSysUserRequest) async throws -> TenantMemberUserView = { tenantId, request in
        try await run {
            TenantMembersAPI.tenantMembersCreateTenantUserWithRequestBuilder(tenantId: tenantId, createSysUserRequest: request)
        }
    }

    /// 编辑成员（I04）：PATCH …/members/{userId} partial，只提交改动字段。
    static let updateMember: (String, String, UpdateSysUserRequest) async throws -> TenantMemberUserView = { tenantId, userId, request in
        try await run {
            TenantMembersAPI.tenantMembersUpdateTenantUserWithRequestBuilder(tenantId: tenantId, userId: userId, updateSysUserRequest: request)
        }
    }

    /// 状态切换（I08）：PATCH …/members/{userId}/status（active/suspended）。
    /// 注意 PUT roles 响应的 status 不可信（REQ-009 Q2），status 端点响应可信。
    static let changeStatus: (String, String, TenantMemberStatus) async throws -> TenantMemberUserView = { tenantId, userId, status in
        try await run {
            TenantMembersAPI.tenantMembersChangeTenantUserStatusWithRequestBuilder(
                tenantId: tenantId,
                userId: userId,
                tenantMembersChangeTenantUserStatusRequest: TenantMembersChangeTenantUserStatusRequest(status: status)
            )
        }
    }

    /// 移除成员（I05，危险操作）：DELETE …/members/{userId}，204 空 body；
    /// 只摘 tenant_membership，全局 sys_user 保留（契约注释口径）。
    static let deleteMember: (String, String) async throws -> Void = { tenantId, userId in
        _ = try await run { TenantMembersAPI.tenantMembersDeleteTenantUserWithRequestBuilder(tenantId: tenantId, userId: userId) }
    }

    /// 邀请成员（I06）：POST …/members/invite，响应嵌套 TenantMemberView
    /// （邀请例外保持嵌套——live 契约裁决 1），扁平行映射在 CoreKit flatRow。
    static let inviteMember: (String, TenantMembersInviteTenantUserRequest) async throws -> TenantMemberView = { tenantId, request in
        try await run {
            TenantMembersAPI.tenantMembersInviteTenantUserWithRequestBuilder(tenantId: tenantId, tenantMembersInviteTenantUserRequest: request)
        }
    }

    // MARK: - 角色生命周期（M00.F03，REQ-2026-010）

    /// 角色详情（I03）：GET /tenants/{tenantId}/roles/{roleId}。
    static let getRole: (String, String) async throws -> SysRole = { tenantId, roleId in
        try await run { TenantRolesAPI.tenantRolesGetSysRoleWithRequestBuilder(tenantId: tenantId, roleId: roleId) }
    }

    /// 新建角色（I02）：POST /tenants/{tenantId}/roles。重名 roleCode 后端
    /// 500 空 body（live 实证，REQ-010 Q1）——App 不前置校验，红字如实呈现。
    static let createRole: (String, CreateSysRoleRequest) async throws -> SysRole = { tenantId, request in
        try await run {
            TenantRolesAPI.tenantRolesCreateSysRoleWithRequestBuilder(tenantId: tenantId, createSysRoleRequest: request)
        }
    }

    /// 编辑角色（I04）：PATCH …/roles/{roleId} partial（roleName/description/status；
    /// roleCode 契约不可改）。响应可信（REQ-010 探针 readback 实证）。
    static let updateRole: (String, String, UpdateSysRoleRequest) async throws -> SysRole = { tenantId, roleId, request in
        try await run {
            TenantRolesAPI.tenantRolesUpdateSysRoleWithRequestBuilder(tenantId: tenantId, roleId: roleId, updateSysRoleRequest: request)
        }
    }

    /// 移除角色（I05，危险操作）：DELETE …/roles/{roleId}，204 空 body；
    /// App 层确认后才调。
    static let deleteRole: (String, String) async throws -> Void = { tenantId, roleId in
        _ = try await run { TenantRolesAPI.tenantRolesDeleteSysRoleWithRequestBuilder(tenantId: tenantId, roleId: roleId) }
    }

    // MARK: - 角色菜单授权（M00.F04，REQ-2026-011）

    /// 角色授权（I02）：GET …/roles/{roleId}/menus → RoleMenuGrant 聚合。
    /// clientId 查询参不传（REQ-011 Q3：角色已带 client 时无观察差异）。
    static let listGrants: (String, String) async throws -> RoleMenuGrant = { tenantId, roleId in
        try await run {
            TenantRoleMenusAPI.tenantRoleMenusListSysRoleMenusWithRequestBuilder(tenantId: tenantId, roleId: roleId)
        }
    }

    /// 保存授权（I03）：PUT …/roles/{roleId}/menus 幂等全量替换；响应即更新后
    /// 聚合（readback 顺序不保证，VM 端 Set 语义）。
    static let setGrants: (String, String, SetSysRoleMenusRequest) async throws -> RoleMenuGrant = { tenantId, roleId, request in
        try await run {
            TenantRoleMenusAPI.tenantRoleMenusSetSysRoleMenusWithRequestBuilder(tenantId: tenantId, roleId: roleId, setSysRoleMenusRequest: request)
        }
    }

    /// 清空授权（I04，危险操作）：DELETE …/roles/{roleId}/menus，204 空 body；
    /// App 层二次确认后才调。
    static let clearGrants: (String, String) async throws -> Void = { tenantId, roleId in
        _ = try await run {
            TenantRoleMenusAPI.tenantRoleMenusClearSysRoleMenusWithRequestBuilder(tenantId: tenantId, roleId: roleId)
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

    // MARK: - 租户维护（M00.F01，REQ-2026-007）

    /// 租户全量清单（AC-1）：GET /admin/tenants。不传分页——分页 0-indexed
    /// 同族（live 实证 page=0/不传全量），nil 拉，翻页 UI 非范围。
    /// 名字带 All 区别于 M01.F03 的 listTenants（meListMyTenants 成员关系）。
    static let listAllTenants: () async throws -> AdminTenantsListTenants200Response = {
        try await run { AdminTenantsAPI.adminTenantsListTenantsWithRequestBuilder() }
    }

    /// 新建租户（AC-2）：POST /admin/tenants（tenantKey 重复 409）。
    static let createTenant: (CreateTenantRequest) async throws -> Tenant = { request in
        try await run { AdminTenantsAPI.adminTenantsCreateTenantWithRequestBuilder(createTenantRequest: request) }
    }

    /// 更新租户（AC-3）：PATCH /admin/tenants/{id}（partial；status 字符串枚举）。
    /// 路径寻址 UUID id 非 key（live 实证，与 admin/clients 口径相反）。
    static let updateTenant: (UUID, UpdateTenantRequest) async throws -> Tenant = { id, request in
        try await run { AdminTenantsAPI.adminTenantsUpdateTenantWithRequestBuilder(id: id.uuidString, updateTenantRequest: request) }
    }

    /// 删除租户（AC-2，级联危险操作）：DELETE /admin/tenants/{id}，204 空 body；
    /// App 层确认后才调。
    static let deleteTenant: (UUID) async throws -> Void = { id in
        _ = try await run { AdminTenantsAPI.adminTenantsDeleteTenantWithRequestBuilder(id: id.uuidString) }
    }

    // MARK: - 菜单管理（M04.F04，REQ-2026-008）

    /// 菜单平铺清单（AC-1）：GET /clients/{clientId}/menus。clientId 字符串寻址
    /// （同 admin/clients 口径）；平铺列表根 parentId=零值 UUID，树由 CoreKit
    /// buildMenuTree 组（/me/menus 的 null 口径不在本切片）。
    static let listMenus: (String) async throws -> [SysMenu] = { clientId in
        try await run { ClientMenusAPI.clientMenusListSysMenusWithRequestBuilder(clientId: clientId) }
    }

    /// 新建菜单（AC-2）：POST /clients/{clientId}/menus（parentId 不传 = 根）。
    static let createMenu: (String, CreateSysMenuRequest) async throws -> SysMenu = { clientId, request in
        try await run {
            ClientMenusAPI.clientMenusCreateSysMenuWithRequestBuilder(clientId: clientId, createSysMenuRequest: request)
        }
    }

    /// 更新菜单（AC-3）：PATCH /clients/{clientId}/menus/{menuId}（partial 提交改动字段）。
    /// menuId 生成物路径参是 String（uuidString 换算在 VM 侧）。
    static let updateMenu: (String, String, UpdateSysMenuRequest) async throws -> SysMenu = { clientId, menuId, request in
        try await run {
            ClientMenusAPI.clientMenusUpdateSysMenuWithRequestBuilder(clientId: clientId, menuId: menuId, updateSysMenuRequest: request)
        }
    }

    /// 移动父节点：PATCH …/{menuId}/parent，parentId String?（nil = 移回根）。
    static let moveMenu: (String, String, String?) async throws -> SysMenu = { clientId, menuId, parentId in
        try await run {
            ClientMenusAPI.clientMenusMoveSysMenuWithRequestBuilder(
                clientId: clientId,
                menuId: menuId,
                clientMenusMoveSysMenuRequest: ClientMenusMoveSysMenuRequest(parentId: parentId)
            )
        }
    }

    /// 兄弟重排序（AC-3）：PUT …/{menuId}/reorder，整段 orderedMenuIds 提交；
    /// 服务端返 200 空数组、未知 id 静默忽略（Q4），顺序真相在提交序列。
    static let reorderMenus: (String, String, [String]) async throws -> [SysMenu] = { clientId, menuId, orderedMenuIds in
        try await run {
            ClientMenusAPI.clientMenusReorderSysMenusWithRequestBuilder(
                clientId: clientId,
                menuId: menuId,
                reorderSysMenuRequest: ReorderSysMenuRequest(orderedMenuIds: orderedMenuIds)
            )
        }
    }

    /// 删除菜单（AC-2，危险操作）：DELETE …/{menuId}，204 空 body；App 层确认后才调。
    static let deleteMenu: (String, String) async throws -> Void = { clientId, menuId in
        _ = try await run { ClientMenusAPI.clientMenusDeleteSysMenuWithRequestBuilder(clientId: clientId, menuId: menuId) }
    }

    /// 公共 client 元数据（I06）：GET /clients/{clientId}，匿名可读三字段。
    static let publicClient: (String) async throws -> OAuthClientPublicInfo = { clientId in
        try await run { ClientsAPI.clientsGetClientWithRequestBuilder(clientId: clientId) }
    }
}
