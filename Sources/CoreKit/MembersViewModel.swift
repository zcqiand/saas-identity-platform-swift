import Combine
import Foundation
import SaasSharedGenerated

// REQ-2026-003 T-1：成员角色绑定 ViewModel——成员列表（AC-1）/ 角色清单（AC-1）/
// 全量覆盖分配（AC-2/AC-3）。Seams 模式同 AuthViewModel：CoreKit 只管状态机，
// 网络实现由 App 层 APIGlue（生成物 TenantMembersAPI/TenantRolesAPI 唯一入口）
// 供（T-2），单测注入 fake 不发真网络。租户上下文复用 REQ-002 切换成果
// （SessionStore.currentTenantId，nil fail-fast 不发请求，Q1）。

@MainActor
public final class MembersViewModel: ObservableObject {

    /// 网络缝：签名对齐生成层租户成员/角色端点。九个缝都带抛错缺省——
    /// 未注入就调用 = fail-fast，不留静默兜底。
    /// REQ-2026-009 T-1 扩为生命周期九缝（原三缝 + 六缝：
    /// getMember/createMember/updateMember/changeStatus/deleteMember/inviteMember）。
    public struct Seams {
        public var listMembers: (_ tenantId: String) async throws -> TenantMembersListTenantUsers200Response
        public var listRoles: (_ tenantId: String) async throws -> TenantRolesListSysRoles200Response
        public var assignRoles: (_ tenantId: String, _ userId: String, _ roleIds: [String]) async throws -> TenantMemberUserView
        public var getMember: (_ tenantId: String, _ userId: String) async throws -> TenantMemberUserView
        public var createMember: (_ tenantId: String, _ request: CreateSysUserRequest) async throws -> TenantMemberUserView
        public var updateMember: (_ tenantId: String, _ userId: String, _ request: UpdateSysUserRequest) async throws -> TenantMemberUserView
        public var changeStatus: (_ tenantId: String, _ userId: String, _ status: TenantMemberStatus) async throws -> TenantMemberUserView
        public var deleteMember: (_ tenantId: String, _ userId: String) async throws -> Void
        public var inviteMember: (_ tenantId: String, _ request: TenantMembersInviteTenantUserRequest) async throws -> TenantMemberView

        public init(
            listMembers: @escaping (_: String) async throws -> TenantMembersListTenantUsers200Response = { _ in
                throw SessionStoreError("listMembers 缝未注入")
            },
            listRoles: @escaping (_: String) async throws -> TenantRolesListSysRoles200Response = { _ in
                throw SessionStoreError("listRoles 缝未注入")
            },
            assignRoles: @escaping (_: String, _: String, _: [String]) async throws -> TenantMemberUserView = { _, _, _ in
                throw SessionStoreError("assignRoles 缝未注入")
            },
            getMember: @escaping (_: String, _: String) async throws -> TenantMemberUserView = { _, _ in
                throw SessionStoreError("getMember 缝未注入")
            },
            createMember: @escaping (_: String, _: CreateSysUserRequest) async throws -> TenantMemberUserView = { _, _ in
                throw SessionStoreError("createMember 缝未注入")
            },
            updateMember: @escaping (_: String, _: String, _: UpdateSysUserRequest) async throws -> TenantMemberUserView = { _, _, _ in
                throw SessionStoreError("updateMember 缝未注入")
            },
            changeStatus: @escaping (_: String, _: String, _: TenantMemberStatus) async throws -> TenantMemberUserView = { _, _, _ in
                throw SessionStoreError("changeStatus 缝未注入")
            },
            deleteMember: @escaping (_: String, _: String) async throws -> Void = { _, _ in
                throw SessionStoreError("deleteMember 缝未注入")
            },
            inviteMember: @escaping (_: String, _: TenantMembersInviteTenantUserRequest) async throws -> TenantMemberView = { _, _ in
                throw SessionStoreError("inviteMember 缝未注入")
            }
        ) {
            self.listMembers = listMembers
            self.listRoles = listRoles
            self.assignRoles = assignRoles
            self.getMember = getMember
            self.createMember = createMember
            self.updateMember = updateMember
            self.changeStatus = changeStatus
            self.deleteMember = deleteMember
            self.inviteMember = inviteMember
        }
    }

    public enum Phase: Equatable {
        case idle
        case busy
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    /// 当前租户成员列表（AC-1 渲染；失败保持旧值不兜底空数组假象）。
    @Published public private(set) var members: [TenantMemberUserView] = []
    /// 当前租户角色清单（勾选数据源，AC-1）。
    @Published public private(set) var roles: [SysRole] = []

    private let store: SessionStore
    private let seams: Seams

    public init(store: SessionStore, seams: Seams) {
        self.store = store
        self.seams = seams
    }

    /// 进页加载（AC-1/AC-4）：并发拉成员 + 角色。currentTenantId nil =
    /// fail-fast 报「未选择租户」不发请求（Q1）；任一失败整批报红可重试。
    @discardableResult
    public func load() async -> Bool {
        guard let tenantId = store.currentTenantId?.uuidString else {
            phase = .failed("未选择租户，无法加载成员")
            return false
        }
        phase = .busy
        do {
            async let membersResponse = seams.listMembers(tenantId)
            async let rolesResponse = seams.listRoles(tenantId)
            let (m, r) = try await (membersResponse, rolesResponse)
            members = m.items
            roles = r.items
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 全量覆盖分配（AC-2/AC-3，Q3）：提交的 roleIds 就是该成员最终角色集。
    /// REQ-2026-009 Q2 修复：roles PUT 响应体的 status 字段在 wire 上不可信
    /// （挂起成员 PUT 后响应假报 active，服务端仍 suspended）——成功后必须
    /// getMember 回读，以回读行原位替换；回读失败 = 红字列表不动可重试。
    @discardableResult
    public func assignRoles(_ roleIds: [String], to userId: UUID) async -> Bool {
        guard let tenantId = store.currentTenantId?.uuidString else {
            phase = .failed("未选择租户，无法分配角色")
            return false
        }
        phase = .busy
        do {
            _ = try await seams.assignRoles(tenantId, userId.uuidString, roleIds)
            let authoritative = try await seams.getMember(tenantId, userId.uuidString)
            replaceRow(authoritative)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    private static func message(of error: Error) -> String {
        if case ErrorResponse.error(let code, _, _, _) = error {
            return "请求失败（HTTP \(code)）"
        }
        return String(describing: error)
    }

    // MARK: - M00.F02 member lifecycle (REQ-2026-009)

    /// 新建成员（I02）。email 在契约上是 optional 但后端必填（live 400 实证，
    /// REQ-009 Q1）——必填校验归 App/UI 层，VM 按生成物形状透传。
    /// 成功追加行（AC-2）；失败红字列表不动可重试。
    @discardableResult
    public func create(username: String, password: String,
                       email: String?, mobile: String?) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法新建成员") else { return false }
        phase = .busy
        do {
            let request = CreateSysUserRequest(username: username, password: password,
                                               email: email, mobile: mobile)
            let created = try await seams.createMember(tenantId, request)
            members.append(created)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 编辑成员 email/mobile（I04）：PATCH partial，成功以响应原位替换行（AC-3）。
    @discardableResult
    public func update(memberID: UUID, email: String?, mobile: String?) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法编辑成员") else { return false }
        phase = .busy
        do {
            let request = UpdateSysUserRequest(email: email, mobile: mobile)
            let updated = try await seams.updateMember(tenantId, memberID.uuidString, request)
            replaceRow(updated)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 状态切换（I08，suspended/active）：成功以响应原位替换行（AC-3）。
    @discardableResult
    public func changeStatus(memberID: UUID, to status: TenantMemberStatus) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法切换成员状态") else { return false }
        phase = .busy
        do {
            let updated = try await seams.changeStatus(tenantId, memberID.uuidString, status)
            replaceRow(updated)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 移除成员（I05）：DELETE 204 空 body → 直接移除本地行（AC-2）。
    /// 语义：只摘 tenant_membership，全局 sys_user 保留（契约注释口径）。
    @discardableResult
    public func remove(memberID: UUID) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法移除成员") else { return false }
        phase = .busy
        do {
            try await seams.deleteMember(tenantId, memberID.uuidString)
            members.removeAll { $0.id == memberID }
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 邀请（I06）：响应是嵌套 TenantMemberView，映射为扁平行追加（Q4）。
    @discardableResult
    public func invite(email: String?, mobile: String?) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法邀请成员") else { return false }
        phase = .busy
        do {
            let request = TenantMembersInviteTenantUserRequest(email: email, mobile: mobile)
            let view = try await seams.inviteMember(tenantId, request)
            guard let row = Self.flatRow(from: view) else {
                phase = .failed("邀请响应 status 无法映射到成员口径")
                return false
            }
            members.append(row)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 回读单成员（I03）：详情页刷新 + roles 分配回读共用。
    /// 成功以权威行原位替换（AC-1/AC-3）。
    @discardableResult
    public func refresh(memberID: UUID) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法刷新成员") else { return false }
        phase = .busy
        do {
            let authoritative = try await seams.getMember(tenantId, memberID.uuidString)
            replaceRow(authoritative)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 邀请响应嵌套 → 列表扁平行映射（Q4 纯函数）：id/username/email/status/
    /// 时间戳取 user.*，tenantId 取 member.tenantId，roleIds 取 view.roles。
    /// 列表行 status = user.status（member.status=active 是 membership 侧口径，
    /// 被邀 user 未激活时两者并存——live 实证）。两个 status 枚举 case 集
    /// 不同（SysUserStatus 无 suspended），rawValue 对不上 = 返回 nil fail-fast，
    /// 不做静默兜底。
    public static func flatRow(from view: TenantMemberView) -> TenantMemberUserView? {
        guard let status = TenantMemberStatus(rawValue: view.user.status.rawValue) else {
            return nil
        }
        return TenantMemberUserView(
            id: view.user.id,
            tenantId: view.member.tenantId,
            username: view.user.username,
            email: view.user.email,
            status: status,
            roleIds: view.roles,
            createdAt: view.user.createdAt,
            updatedAt: view.user.updatedAt
        )
    }

    private func replaceRow(_ row: TenantMemberUserView) {
        if let index = members.firstIndex(where: { $0.id == row.id }) {
            members[index] = row
        }
    }

    private func currentTenantIdOrPerform(_ action: String) -> String? {
        guard let tenantId = store.currentTenantId?.uuidString else {
            phase = .failed("未选择租户，\(action)")
            return nil
        }
        return tenantId
    }
}
