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

    /// 网络缝：签名对齐生成层租户成员/角色端点。三个缝都带抛错缺省——
    /// 未注入就调用 = fail-fast，不留静默兜底。
    public struct Seams {
        public var listMembers: (_ tenantId: String) async throws -> TenantMembersListTenantUsers200Response
        public var listRoles: (_ tenantId: String) async throws -> TenantRolesListSysRoles200Response
        public var assignRoles: (_ tenantId: String, _ userId: String, _ roleIds: [String]) async throws -> TenantMemberUserView

        public init(
            listMembers: @escaping (_: String) async throws -> TenantMembersListTenantUsers200Response = { _ in
                throw SessionStoreError("listMembers 缝未注入")
            },
            listRoles: @escaping (_: String) async throws -> TenantRolesListSysRoles200Response = { _ in
                throw SessionStoreError("listRoles 缝未注入")
            },
            assignRoles: @escaping (_: String, _: String, _: [String]) async throws -> TenantMemberUserView = { _, _, _ in
                throw SessionStoreError("assignRoles 缝未注入")
            }
        ) {
            self.listMembers = listMembers
            self.listRoles = listRoles
            self.assignRoles = assignRoles
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
    /// 成功用返回的 TenantMemberUserView 原位更新成员行（不重拉列表）；
    /// 失败红字带 HTTP 码、列表不动可重试。currentTenantId nil 同样 fail-fast。
    @discardableResult
    public func assignRoles(_ roleIds: [String], to userId: UUID) async -> Bool {
        guard let tenantId = store.currentTenantId?.uuidString else {
            phase = .failed("未选择租户，无法分配角色")
            return false
        }
        phase = .busy
        do {
            let updated = try await seams.assignRoles(tenantId, userId.uuidString, roleIds)
            if let index = members.firstIndex(where: { $0.id == userId }) {
                members[index] = updated
            }
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
}
