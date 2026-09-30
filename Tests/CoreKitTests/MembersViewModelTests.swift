import XCTest
import SaasSharedGenerated
@testable import CoreKit

/// REQ-2026-003 T-1：成员角色绑定 ViewModel（成员列表 + 角色全量覆盖分配）。
/// Seams 模式同 AuthViewModel：CoreKit 只管状态机，网络实现由 App 层 APIGlue
/// （生成物 TenantMembersAPI/TenantRolesAPI 唯一入口）供（T-2），单测注入 fake。
@MainActor
final class MembersViewModelTests: XCTestCase {

    private let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let bobID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let tenantA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let adminRoleID = "a0000000-0000-0000-0000-000000000001"
    private let memberRoleID = "a0000000-0000-0000-0000-000000000002"

    private func makeStore(configured: Bool, loggedIn: Bool) throws -> SessionStore {
        let suite = "MembersViewModelTests.\(UUID().uuidString)"
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
                id: UUID(), userId: userID, tenantId: tenantA,
                roleIds: [adminRoleID], status: .active,
                joinedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try store.adoptLogin(LoginResponse(
                user: user, availableTenants: [membership], userId: userID,
                currentTenantId: tenantA, accessToken: "tk-1",
                tokenType: "Bearer", expiresIn: 3600, clientId: "saas-console"
            ))
        }
        return store
    }

    private func makeMember(id: UUID, username: String, roleIds: [String]) -> TenantMemberUserView {
        TenantMemberUserView(
            id: id, tenantId: tenantA, username: username,
            status: .active, roleIds: roleIds,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeRole(id: UUID, code: String, name: String) -> SysRole {
        SysRole(
            id: id, tenantId: tenantA, clientId: "saas-console",
            roleCode: code, roleName: name, isPreset: true, status: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private var memberList: TenantMembersListTenantUsers200Response {
        TenantMembersListTenantUsers200Response(
            items: [
                makeMember(id: userID, username: "alice", roleIds: [adminRoleID]),
                makeMember(id: bobID, username: "bob", roleIds: [memberRoleID]),
            ],
            page: 1, pageSize: 20, total: 2
        )
    }

    private var roleList: TenantRolesListSysRoles200Response {
        TenantRolesListSysRoles200Response(
            items: [
                makeRole(id: UUID(uuidString: adminRoleID)!, code: "admin", name: "Administrator"),
                makeRole(id: UUID(uuidString: memberRoleID)!, code: "member", name: "Member"),
            ],
            page: 1, pageSize: 20, total: 2
        )
    }

    func testLoadWithoutCurrentTenantFailsFastAndNeverCallsSeams() async {
    // fn: M01.F02
        let store = try! makeStore(configured: true, loggedIn: false)
        XCTAssertNil(store.currentTenantId, "前置：未登录/未选租户")
        var seamCalled = false
        let vm = MembersViewModel(
            store: store,
            seams: .init(
                listMembers: { _ in seamCalled = true; return self.memberList },
                listRoles: { _ in seamCalled = true; return self.roleList },
                assignRoles: { _, _, _ in seamCalled = true; return self.makeMember(id: self.bobID, username: "bob", roleIds: []) }
            )
        )
        let ok = await vm.load()
        XCTAssertFalse(ok, "currentTenantId nil = fail-fast 不发请求（Q1）")
        XCTAssertFalse(seamCalled, "三缝都不许被碰")
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("租户"), "红字要指明缺租户上下文，实际：\(message)")
        } else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
        XCTAssertTrue(vm.members.isEmpty)
        XCTAssertTrue(vm.roles.isEmpty)
    }

    func testLoadSuccessPopulatesMembersAndRoles() async throws {
    // fn: M01.F02
        let store = try makeStore(configured: true, loggedIn: true)
        var receivedBySeam: [String] = []
        let vm = MembersViewModel(
            store: store,
            seams: .init(
                listMembers: { tenantId in
                    receivedBySeam.append("members:\(tenantId)")
                    return self.memberList
                },
                listRoles: { tenantId in
                    receivedBySeam.append("roles:\(tenantId)")
                    return self.roleList
                },
                assignRoles: { _, _, _ in throw URLError(.unsupportedURL) }
            )
        )
        let ok = await vm.load()
        XCTAssertTrue(ok)
        XCTAssertEqual(receivedBySeam.sorted(), [
            "members:\(tenantA.uuidString)", "roles:\(tenantA.uuidString)",
        ].sorted(), "两条缝都收到 store.currentTenantId（AC-1；load 是 async let 并发，到达顺序不定，比集合不比顺序——2026-09-30 远门双轮红实证的存量 flaky）")
        XCTAssertEqual(vm.members.count, 2)
        XCTAssertEqual(vm.members.first?.username, "alice")
        XCTAssertEqual(vm.roles.count, 2)
        XCTAssertEqual(vm.roles.map(\.roleCode), ["admin", "member"], "角色清单来自生成物 client（AC-1）")
        XCTAssertEqual(vm.phase, .idle)
    }

    func testAssignSuccessUpdatesMemberRowInPlace() async throws {
    // fn: M01.F02
        let store = try makeStore(configured: true, loggedIn: true)
        var assigned: (tenantId: String, userId: String, roleIds: [String])?
        let vm = MembersViewModel(
            store: store,
            seams: .init(
                listMembers: { _ in self.memberList },
                listRoles: { _ in self.roleList },
                assignRoles: { tenantId, userId, roleIds in
                    assigned = (tenantId, userId, roleIds)
                    // 全量覆盖（Q3）：提交集合就是最终角色集，返回更新后的视图
                    return self.makeMember(id: self.bobID, username: "bob", roleIds: roleIds)
                }
            )
        )
        _ = await vm.load()
        let ok = await vm.assignRoles([memberRoleID, adminRoleID], to: bobID)
        XCTAssertTrue(ok)
        XCTAssertEqual(assigned?.tenantId, tenantA.uuidString)
        XCTAssertEqual(assigned?.userId, bobID.uuidString)
        XCTAssertEqual(assigned?.roleIds, [memberRoleID, adminRoleID], "PUT 全量覆盖提交勾选集合")
        XCTAssertEqual(vm.members.first { $0.id == bobID }?.roleIds, [memberRoleID, adminRoleID],
                       "成功用返回视图原位更新 bob 行（AC-2）")
        XCTAssertEqual(vm.members.first { $0.id == userID }?.roleIds, [adminRoleID],
                       "其他成员行不动")
        XCTAssertEqual(vm.members.count, 2, "列表长度不变（原位更新非重拉）")
        XCTAssertEqual(vm.phase, .idle)
    }

    func testAssign403FailureKeepsListAndReportsRetryable() async throws {
    // fn: M01.F02
        let store = try makeStore(configured: true, loggedIn: true)
        var reject = true
        let vm = MembersViewModel(
            store: store,
            seams: .init(
                listMembers: { _ in self.memberList },
                listRoles: { _ in self.roleList },
                assignRoles: { _, _, _ in
                    if reject {
                        throw ErrorResponse.error(403, nil, nil, URLError(.userAuthenticationRequired))
                    }
                    return self.makeMember(id: self.bobID, username: "bob", roleIds: [self.adminRoleID])
                }
            )
        )
        _ = await vm.load()
        let snapshot = vm.members
        let ok = await vm.assignRoles([adminRoleID], to: bobID)
        XCTAssertFalse(ok)
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("403"), "红字带 HTTP 码（AC-3），实际：\(message)")
        } else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
        XCTAssertEqual(vm.members.map(\.id), snapshot.map(\.id), "失败列表不动（AC-3）")
        XCTAssertEqual(vm.members.first { $0.id == bobID }?.roleIds, [memberRoleID], "bob 行保持原角色")

        reject = false
        let retry = await vm.assignRoles([adminRoleID], to: bobID)
        XCTAssertTrue(retry, "同一 VM 可直接重试（AC-3 可重试）")
        XCTAssertEqual(vm.members.first { $0.id == bobID }?.roleIds, [adminRoleID])
    }

    func testLoadNetworkFailureKeepsStateAndReports() async throws {
    // fn: M01.F02
        let store = try makeStore(configured: true, loggedIn: true)
        let vm = MembersViewModel(
            store: store,
            seams: .init(
                listMembers: { _ in throw URLError(.notConnectedToInternet) },
                listRoles: { _ in self.roleList },
                assignRoles: { _, _, _ in throw URLError(.unsupportedURL) }
            )
        )
        let ok = await vm.load()
        XCTAssertFalse(ok, "网络断 = 失败（AC-4）")
        if case .failed = vm.phase {} else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
        XCTAssertTrue(vm.members.isEmpty, "失败不发假数据，列表保持空待重试")
        XCTAssertTrue(vm.roles.isEmpty)
    }
}
