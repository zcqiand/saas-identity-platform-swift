import XCTest
import SaasSharedGenerated
@testable import CoreKit

/// REQ-2026-010 T-1：租户角色 CRUD ViewModel（M00.F03）。
/// Seams 模式同族：CoreKit 只管状态机，网络实现由 App 层 APIGlue
/// （生成物 TenantRolesAPI 唯一入口）供（T-2），单测注入 fake 不发真网络。
/// 成功 = 原位替换/追加行；失败 = 红字列表不动可重试；无租户上下文 fail-fast。
@MainActor
final class RolesViewModelTests: XCTestCase {

    private let tenantID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let adminRoleID = UUID(uuidString: "a0000000-0000-0000-0000-000000000001")!
    private let probeRoleID = UUID(uuidString: "b0000000-0000-0000-0000-000000000002")!
    private let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func makeStore(configured: Bool, loggedIn: Bool) throws -> SessionStore {
        let suite = "RolesViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = SessionStore(defaults: defaults, secrets: InMemoryTokenStore())
        if configured {
            try store.saveConfig(baseURL: "https://api.example.invalid", clientId: "saas-console")
        }
        if loggedIn {
            let user = SysUser(
                id: userID, username: "alice", status: .active,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            let membership = TenantMembership(
                id: UUID(), userId: userID, tenantId: tenantID,
                roleIds: ["a0000000-0000-0000-0000-000000000001"], status: .active,
                joinedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try store.adoptLogin(LoginResponse(
                user: user, availableTenants: [membership], userId: userID,
                currentTenantId: tenantID, accessToken: "tk-1",
                tokenType: "Bearer", expiresIn: 3600, clientId: "saas-console"
            ))
        }
        return store
    }

    private func makeRole(id: UUID, code: String, name: String, status: Int = 1) -> SysRole {
        SysRole(
            id: id, tenantId: tenantID, clientId: "saas-console",
            roleCode: code, roleName: name, isPreset: id == adminRoleID,
            status: status,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private var roleList: TenantRolesListSysRoles200Response {
        TenantRolesListSysRoles200Response(
            items: [
                makeRole(id: adminRoleID, code: "admin", name: "Administrator"),
                makeRole(id: probeRoleID, code: "editor", name: "Editor"),
            ],
            page: 1, pageSize: 20, total: 2
        )
    }

    func testLoadPopulatesRoles() async throws {
    // fn: M00.F03
        let store = try makeStore(configured: true, loggedIn: true)
        var listed: String?
        let vm = RolesViewModel(
            store: store,
            seams: .init(
                listRoles: { tenantId in
                    listed = tenantId
                    return self.roleList
                }
            )
        )
        let ok = await vm.load()
        XCTAssertTrue(ok)
        XCTAssertEqual(listed, tenantID.uuidString)
        XCTAssertEqual(vm.roles.count, 2)
        XCTAssertEqual(vm.roles.first?.roleCode, "admin")
    }

    func testCreateAppendsRowToList() async throws {
    // fn: M00.F03
        let store = try makeStore(configured: true, loggedIn: true)
        var requested: CreateSysRoleRequest?
        let created = makeRole(id: UUID(uuidString: "c0000000-0000-0000-0000-000000000003")!,
                               code: "viewer", name: "Viewer")
        let vm = RolesViewModel(
            store: store,
            seams: .init(
                listRoles: { _ in self.roleList },
                createRole: { tenantId, request in
                    requested = request
                    return created
                }
            )
        )
        _ = await vm.load()
        let ok = await vm.create(clientId: "saas-console", roleCode: "viewer",
                                 roleName: "Viewer", description: "只读")
        XCTAssertTrue(ok)
        XCTAssertEqual(requested?.clientId, "saas-console")
        XCTAssertEqual(requested?.roleCode, "viewer")
        XCTAssertEqual(requested?.roleName, "Viewer")
        XCTAssertEqual(requested?.description, "只读")
        XCTAssertEqual(vm.roles.count, 3)
        XCTAssertEqual(vm.roles.last?.roleCode, "viewer")
    }

    func testUpdateReplacesRowInPlace() async throws {
    // fn: M00.F03
        let store = try makeStore(configured: true, loggedIn: true)
        var requested: (String, UpdateSysRoleRequest)?
        let vm = RolesViewModel(
            store: store,
            seams: .init(
                listRoles: { _ in self.roleList },
                updateRole: { tenantId, roleId, request in
                    requested = (roleId, request)
                    return self.makeRole(id: self.probeRoleID, code: "editor",
                                         name: request.roleName ?? "?", status: request.status ?? 1)
                }
            )
        )
        _ = await vm.load()
        let ok = await vm.update(roleID: probeRoleID, roleName: "Editor改", description: nil)
        XCTAssertTrue(ok)
        XCTAssertEqual(requested?.0, probeRoleID.uuidString)
        XCTAssertEqual(requested?.1.roleName, "Editor改")
        XCTAssertEqual(vm.roles.first { $0.id == probeRoleID }?.roleName, "Editor改",
                       "原位更新返回即见新值（AC-3）")
        XCTAssertEqual(vm.roles.count, 2)
    }

    func testSetStatusReplacesRowBothWays() async throws {
    // fn: M00.F03
        let store = try makeStore(configured: true, loggedIn: true)
        var current: Int = 1
        let vm = RolesViewModel(
            store: store,
            seams: .init(
                listRoles: { _ in self.roleList },
                updateRole: { tenantId, roleId, request in
                    current = request.status ?? 1
                    return self.makeRole(id: self.probeRoleID, code: "editor",
                                         name: "Editor", status: current)
                }
            )
        )
        _ = await vm.load()
        let disabled = await vm.setStatus(roleID: probeRoleID, to: 0)
        XCTAssertTrue(disabled)
        XCTAssertEqual(current, 0)
        XCTAssertEqual(vm.roles.first { $0.id == probeRoleID }?.status, 0, "停用原位生效（AC-4）")
        let enabled = await vm.setStatus(roleID: probeRoleID, to: 1)
        XCTAssertTrue(enabled)
        XCTAssertEqual(current, 1)
        XCTAssertEqual(vm.roles.first { $0.id == probeRoleID }?.status, 1, "启用原位生效")
    }

    func testRemoveDeletesRowWithoutResponseBody() async throws {
    // fn: M00.F03
        let store = try makeStore(configured: true, loggedIn: true)
        var removed: (tenantId: String, roleId: String)?
        let vm = RolesViewModel(
            store: store,
            seams: .init(
                listRoles: { _ in self.roleList },
                deleteRole: { tenantId, roleId in
                    removed = (tenantId, roleId)
                    // DELETE returns 204 empty -> the seam returns Void.
                }
            )
        )
        _ = await vm.load()
        let ok = await vm.remove(roleID: probeRoleID)
        XCTAssertTrue(ok)
        XCTAssertEqual(removed?.tenantId, tenantID.uuidString)
        XCTAssertEqual(removed?.roleId, probeRoleID.uuidString)
        XCTAssertEqual(vm.roles.map(\.id), [adminRoleID], "204 后行消失（AC-5）")
    }

    func testRefreshReplacesRowWithAuthoritativeState() async throws {
    // fn: M00.F03
        let store = try makeStore(configured: true, loggedIn: true)
        let vm = RolesViewModel(
            store: store,
            seams: .init(
                listRoles: { _ in self.roleList },
                getRole: { tenantId, roleId in
                    self.makeRole(id: self.probeRoleID, code: "editor",
                                  name: "Editor权威", status: 0)
                }
            )
        )
        _ = await vm.load()
        let ok = await vm.refresh(roleID: probeRoleID)
        XCTAssertTrue(ok)
        let row = vm.roles.first { $0.id == probeRoleID }
        XCTAssertEqual(row?.roleName, "Editor权威")
        XCTAssertEqual(row?.status, 0)
    }

    func testLifecycleOpsWithoutTenantFailFast() async throws {
    // fn: M00.F03
        let store = try makeStore(configured: true, loggedIn: false)
        var seamCalled = false
        let vm = RolesViewModel(
            store: store,
            seams: .init(
                listRoles: { _ in seamCalled = true; return self.roleList },
                createRole: { _, _ in seamCalled = true; return self.makeRole(id: self.probeRoleID, code: "x", name: "x") },
                getRole: { _, _ in seamCalled = true; return self.makeRole(id: self.probeRoleID, code: "x", name: "x") },
                updateRole: { _, _, _ in seamCalled = true; return self.makeRole(id: self.probeRoleID, code: "x", name: "x") },
                deleteRole: { _, _ in seamCalled = true }
            )
        )
        let loaded = await vm.load()
        XCTAssertFalse(loaded)
        let created = await vm.create(clientId: "saas-console", roleCode: "x", roleName: "x", description: nil)
        XCTAssertFalse(created)
        let updated = await vm.update(roleID: probeRoleID, roleName: "x", description: nil)
        XCTAssertFalse(updated)
        let removed = await vm.remove(roleID: probeRoleID)
        XCTAssertFalse(removed)
        let refreshed = await vm.refresh(roleID: probeRoleID)
        XCTAssertFalse(refreshed)
        XCTAssertFalse(seamCalled, "无租户上下文必须 fail-fast，一个缝都不许发")
        if case .failed = vm.phase {} else {
            XCTFail("无租户上下文应报红字")
        }
    }
}
