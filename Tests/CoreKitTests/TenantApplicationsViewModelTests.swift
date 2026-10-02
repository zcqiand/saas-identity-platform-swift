import XCTest
import SaasSharedGenerated
@testable import CoreKit

/// REQ-2026-012 T-1：租户应用订阅 ViewModel（M00.F05）。
/// Seams 模式同族：CoreKit 只管状态机，网络实现由 App 层 APIGlue
/// （生成物 TenantApplicationsAPI 唯一入口）供（T-2），单测注入 fake 不发真
/// 网络。寻址契约：PATCH/DELETE 用 clientId 字符串列。
@MainActor
final class TenantApplicationsViewModelTests: XCTestCase {

    private let tenantID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    private func makeStore(configured: Bool, loggedIn: Bool) throws -> SessionStore {
        let suite = "TenantApplicationsViewModelTests.\(UUID().uuidString)"
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

    private func makeApp(clientId: String, status: Int = 1,
                         expireTime: Date? = nil) -> TenantApplication {
        TenantApplication(
            id: UUID(), tenantId: tenantID, clientId: clientId, status: status,
            expireTime: expireTime,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private var appList: TenantApplicationsListTenantApplications200Response {
        TenantApplicationsListTenantApplications200Response(
            items: [
                makeApp(clientId: "lab-management",
                        expireTime: Date(timeIntervalSince1970: 1_800_000_000)),
                makeApp(clientId: "lab-vue", status: 0),
            ],
            page: 1, pageSize: 20, total: 2
        )
    }

    func testLoadPopulatesApplications() async throws {
    // fn: M00.F05
        let store = try makeStore(configured: true, loggedIn: true)
        var listed: String?
        let vm = TenantApplicationsViewModel(
            store: store,
            seams: .init(
                list: { tenantId in
                    listed = tenantId
                    return self.appList
                }
            )
        )
        let ok = await vm.load()
        XCTAssertTrue(ok)
        XCTAssertEqual(listed, tenantID.uuidString)
        XCTAssertEqual(vm.applications.count, 2)
        XCTAssertEqual(vm.applications.first?.clientId, "lab-management")
    }

    func testSubscribeAppendsRowAndCarriesExpireTime() async throws {
    // fn: M00.F05
        let store = try makeStore(configured: true, loggedIn: true)
        var requested: SubscribeTenantApplicationRequest?
        let created = makeApp(clientId: "lab-react",
                              expireTime: Date(timeIntervalSince1970: 1_830_000_000))
        let vm = TenantApplicationsViewModel(
            store: store,
            seams: .init(
                list: { _ in self.appList },
                subscribe: { _, request in
                    requested = request
                    return created
                }
            )
        )
        _ = await vm.load()
        let expire = Date(timeIntervalSince1970: 1_830_000_000)
        let ok = await vm.subscribe(clientId: "lab-react", expireTime: expire)
        XCTAssertTrue(ok)
        XCTAssertEqual(requested?.clientId, "lab-react")
        XCTAssertEqual(requested?.expireTime, expire, "订阅带的到期日必须原样上送（后端曾丢弃）")
        XCTAssertEqual(vm.applications.count, 3)
        XCTAssertEqual(vm.applications.last?.clientId, "lab-react")
    }

    func testSubscribeWithoutExpireTimeSendsNil() async throws {
    // fn: M00.F05
        let store = try makeStore(configured: true, loggedIn: true)
        var requested: SubscribeTenantApplicationRequest?
        let vm = TenantApplicationsViewModel(
            store: store,
            seams: .init(
                subscribe: { _, request in
                    requested = request
                    return self.makeApp(clientId: "lab-react")
                }
            )
        )
        let ok = await vm.subscribe(clientId: "lab-react", expireTime: nil)
        XCTAssertTrue(ok)
        XCTAssertNil(requested?.expireTime, "expireTime 契约可空，nil 必须原样上送不兜底")
    }

    func testUpdateReplacesRowInPlace() async throws {
    // fn: M00.F05
        let store = try makeStore(configured: true, loggedIn: true)
        var requested: (clientId: String, request: UpdateTenantApplicationRequest)?
        let expire = Date(timeIntervalSince1970: 1_830_000_000)
        let vm = TenantApplicationsViewModel(
            store: store,
            seams: .init(
                list: { _ in self.appList },
                update: { tenantId, clientId, request in
                    requested = (clientId, request)
                    return self.makeApp(clientId: "lab-vue", status: 1, expireTime: expire)
                }
            )
        )
        _ = await vm.load()
        let ok = await vm.update(clientId: "lab-vue", status: 1, expireTime: expire)
        XCTAssertTrue(ok)
        XCTAssertEqual(requested?.clientId, "lab-vue", "寻址 clientId 字符串列非 UUID id")
        XCTAssertEqual(requested?.request.status, 1)
        XCTAssertEqual(requested?.request.expireTime, expire)
        let row = vm.applications.first { $0.clientId == "lab-vue" }
        XCTAssertEqual(row?.status, 1, "成功以响应原位替换行")
        XCTAssertEqual(row?.expireTime, expire)
    }

    func testRemoveDeletesRowByClientId() async throws {
    // fn: M00.F05
        let store = try makeStore(configured: true, loggedIn: true)
        var removed: (tenantId: String, clientId: String)?
        let vm = TenantApplicationsViewModel(
            store: store,
            seams: .init(
                list: { _ in self.appList },
                remove: { tenantId, clientId in
                    removed = (tenantId, clientId)
                }
            )
        )
        _ = await vm.load()
        let ok = await vm.remove(clientId: "lab-vue")
        XCTAssertTrue(ok)
        XCTAssertEqual(removed?.clientId, "lab-vue")
        XCTAssertNil(vm.applications.first { $0.clientId == "lab-vue" }, "DELETE 后本地行按 clientId 移除")
        XCTAssertEqual(vm.applications.count, 1)
    }

    func testLifecycleOpsWithoutTenantFailFast() async throws {
    // fn: M00.F05
        let store = try makeStore(configured: true, loggedIn: false)
        var seamCalled = false
        let vm = TenantApplicationsViewModel(
            store: store,
            seams: .init(
                list: { _ in seamCalled = true; return self.appList },
                subscribe: { _, _ in seamCalled = true; return self.makeApp(clientId: "x") },
                update: { _, _, _ in seamCalled = true; return self.makeApp(clientId: "x") },
                remove: { _, _ in seamCalled = true }
            )
        )
        let loaded = await vm.load()
        XCTAssertFalse(loaded)
        let subscribed = await vm.subscribe(clientId: "x", expireTime: nil)
        XCTAssertFalse(subscribed)
        let updated = await vm.update(clientId: "x", status: 1, expireTime: nil)
        XCTAssertFalse(updated)
        let removed = await vm.remove(clientId: "x")
        XCTAssertFalse(removed)
        XCTAssertFalse(seamCalled, "无租户上下文必须 fail-fast，一个缝都不许发")
        if case .failed = vm.phase {} else {
            XCTFail("无租户上下文应报红字")
        }
    }
}
