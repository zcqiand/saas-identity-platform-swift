import Combine
import Foundation
import SaasSharedGenerated

// REQ-2026-010 T-1：租户角色 CRUD ViewModel（M00.F03）。Seams 模式同族：
// CoreKit 只管状态机，网络实现由 App 层 APIGlue（生成物 TenantRolesAPI 唯一
// 入口）供（T-2），单测注入 fake 不发真网络。租户上下文复用 SessionStore
// .currentTenantId（nil fail-fast 不发请求）。不并入 MembersViewModel——
// 成员页的角色清单是勾选数据源语义，本 VM 是 CRUD 语义（REQ-010 Q2）。
// REQ-2026-011 T-1：扩角色菜单授权三缝（M00.F04，生成物
// TenantRoleMenusAPI list/set/clear）；授权是角色详情页内语义，与 CRUD 同属
// 「角色管理」feature 面，授权态挂在本 VM（REQ-011 Q1），不另起新 VM。

@MainActor
public final class RolesViewModel: ObservableObject {

    /// 网络缝：签名对齐生成层租户角色端点。五缝都带抛错缺省——未注入就调用
    /// = fail-fast，不留静默兜底。
    public struct Seams {
        public var listRoles: (_ tenantId: String) async throws -> TenantRolesListSysRoles200Response
        public var createRole: (_ tenantId: String, _ request: CreateSysRoleRequest) async throws -> SysRole
        public var getRole: (_ tenantId: String, _ roleId: String) async throws -> SysRole
        public var updateRole: (_ tenantId: String, _ roleId: String, _ request: UpdateSysRoleRequest) async throws -> SysRole
        public var deleteRole: (_ tenantId: String, _ roleId: String) async throws -> Void
        public var listGrants: (_ tenantId: String, _ roleId: String) async throws -> RoleMenuGrant
        public var setGrants: (_ tenantId: String, _ roleId: String, _ request: SetSysRoleMenusRequest) async throws -> RoleMenuGrant
        public var clearGrants: (_ tenantId: String, _ roleId: String) async throws -> Void

        public init(
            listRoles: @escaping (_: String) async throws -> TenantRolesListSysRoles200Response = { _ in
                throw SessionStoreError("listRoles 缝未注入")
            },
            createRole: @escaping (_: String, _: CreateSysRoleRequest) async throws -> SysRole = { _, _ in
                throw SessionStoreError("createRole 缝未注入")
            },
            getRole: @escaping (_: String, _: String) async throws -> SysRole = { _, _ in
                throw SessionStoreError("getRole 缝未注入")
            },
            updateRole: @escaping (_: String, _: String, _: UpdateSysRoleRequest) async throws -> SysRole = { _, _, _ in
                throw SessionStoreError("updateRole 缝未注入")
            },
            deleteRole: @escaping (_: String, _: String) async throws -> Void = { _, _ in
                throw SessionStoreError("deleteRole 缝未注入")
            },
            listGrants: @escaping (_: String, _: String) async throws -> RoleMenuGrant = { _, _ in
                throw SessionStoreError("listGrants 缝未注入")
            },
            setGrants: @escaping (_: String, _: String, _: SetSysRoleMenusRequest) async throws -> RoleMenuGrant = { _, _, _ in
                throw SessionStoreError("setGrants 缝未注入")
            },
            clearGrants: @escaping (_: String, _: String) async throws -> Void = { _, _ in
                throw SessionStoreError("clearGrants 缝未注入")
            }
        ) {
            self.listRoles = listRoles
            self.createRole = createRole
            self.getRole = getRole
            self.updateRole = updateRole
            self.deleteRole = deleteRole
            self.listGrants = listGrants
            self.setGrants = setGrants
            self.clearGrants = clearGrants
        }
    }

    public enum Phase: Equatable {
        case idle
        case busy
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    /// 当前租户角色清单（AC-1 渲染；失败保持旧值不兜底空数组假象）。
    @Published public private(set) var roles: [SysRole] = []
    /// 已选角色的菜单授权（M00.F04 详情页段；menuIds 后端顺序不保证——
    /// 消费端一律 Set 语义，REQ-011 探针实证）。
    @Published public private(set) var grants: RoleMenuGrant?

    private let store: SessionStore
    private let seams: Seams

    public init(store: SessionStore, seams: Seams) {
        self.store = store
        self.seams = seams
    }

    // @impl M00.F03.I01 — 角色列表
    /// 进页加载（AC-1）：拉角色全量（list 不传分页参，0-indexed 同族口径）。
    @discardableResult
    public func load() async -> Bool {
        guard let tenantId = store.currentTenantId?.uuidString else {
            phase = .failed("未选择租户，无法加载角色")
            return false
        }
        phase = .busy
        do {
            roles = try await seams.listRoles(tenantId).items
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    // MARK: - M00.F03 role lifecycle (REQ-2026-010)

    // @impl M00.F03.I02 — 创建角色（成功追加行）
    /// 新建角色（I02）：clientId/roleCode/roleName 必填（契约=后端口径一致，
    /// live 实证缺 clientId 400）。重名 roleCode 后端 500 空 body（REQ-010 Q1）——
    /// 红字如实呈现，不做前置重名校验。成功追加行（AC-2）。
    @discardableResult
    public func create(clientId: String, roleCode: String, roleName: String,
                       description: String?) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法新建角色") else { return false }
        phase = .busy
        do {
            let request = CreateSysRoleRequest(clientId: clientId, roleCode: roleCode,
                                               roleName: roleName, description: description)
            let created = try await seams.createRole(tenantId, request)
            roles.append(created)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 编辑角色（I04）：PATCH partial 只提交改动字段；roleCode 契约上不可改。
    /// 响应可信（REQ-010 探针 readback 实证，与 REQ-009 Q2 不同源）。
    /// 成功以响应原位替换行（AC-3）。
    @discardableResult
    public func update(roleID: UUID, roleName: String?, description: String?) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法编辑角色") else { return false }
        phase = .busy
        do {
            let request = UpdateSysRoleRequest(roleName: roleName, description: description)
            let updated = try await seams.updateRole(tenantId, roleID.uuidString, request)
            replaceRow(updated)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 状态启停（AC-4）：status 1=启用 0=停用（Int 契约口径，同 sys_role）。
    @discardableResult
    public func setStatus(roleID: UUID, to status: Int) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法切换角色状态") else { return false }
        phase = .busy
        do {
            let request = UpdateSysRoleRequest(roleName: nil, description: nil, status: status)
            let updated = try await seams.updateRole(tenantId, roleID.uuidString, request)
            replaceRow(updated)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 移除角色（I05，危险操作）：DELETE 204 空 body → 直接移除本地行（AC-5）。
    /// isPreset 角色可删性后端规则未探——拦截时红字如实呈现（REQ-010 非范围）。
    @discardableResult
    public func remove(roleID: UUID) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法移除角色") else { return false }
        phase = .busy
        do {
            try await seams.deleteRole(tenantId, roleID.uuidString)
            roles.removeAll { $0.id == roleID }
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 回读单角色（I03）：详情页刷新共用，成功以权威行原位替换。
    @discardableResult
    public func refresh(roleID: UUID) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法刷新角色") else { return false }
        phase = .busy
        do {
            let authoritative = try await seams.getRole(tenantId, roleID.uuidString)
            replaceRow(authoritative)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    // MARK: - M00.F04 role menu grants (REQ-2026-011)

    // @impl M00.F04.I02 — 角色已授权菜单查询（授权聚合）
    /// 读角色授权（I02）：GET …/roles/{roleId}/menus → RoleMenuGrant 聚合。
    /// 进详情页授权段时调用；menuIds 顺序不保证（消费端 Set 语义）。
    @discardableResult
    public func loadGrants(roleID: UUID) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法加载菜单授权") else { return false }
        phase = .busy
        do {
            grants = try await seams.listGrants(tenantId, roleID.uuidString)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    // @impl M00.F04.I03 — 整批设置角色菜单（PUT 幂等全量替换）
    /// 保存授权（I03）：PUT 幂等全量替换，授权态以响应为准（响应顺序不保证
    /// 照存不重排——REQ-011 探针实证 readback 顺序漂移）。
    @discardableResult
    public func saveGrants(roleID: UUID, menuIds: [String]) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法保存菜单授权") else { return false }
        phase = .busy
        do {
            let request = SetSysRoleMenusRequest(menuIds: menuIds)
            grants = try await seams.setGrants(tenantId, roleID.uuidString, request)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 清空授权（I04，危险操作）：DELETE 204 空 body——本地聚合落地为空
    /// （同后端 GET 语义 menuIds=[]；updatedAt 本地时钟仅作占位，无消费方）。
    @discardableResult
    public func clearGrants(roleID: UUID) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法清空菜单授权") else { return false }
        phase = .busy
        do {
            try await seams.clearGrants(tenantId, roleID.uuidString)
            if let tenantUUID = store.currentTenantId {
                grants = RoleMenuGrant(roleId: roleID, tenantId: tenantUUID,
                                       menuIds: [], updatedAt: Date())
            }
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    private func replaceRow(_ row: SysRole) {
        if let index = roles.firstIndex(where: { $0.id == row.id }) {
            roles[index] = row
        }
    }

    private func currentTenantIdOrPerform(_ action: String) -> String? {
        guard let tenantId = store.currentTenantId?.uuidString else {
            phase = .failed("未选择租户，\(action)")
            return nil
        }
        return tenantId
    }

    private static func message(of error: Error) -> String {
        if case ErrorResponse.error(let code, _, _, _) = error {
            return "请求失败（HTTP \(code)）"
        }
        return String(describing: error)
    }
}
