import XCTest
import SaasSharedGenerated
@testable import CoreKit

/// REQ-2026-001 T-2：认证流 ViewModel（登录 / whoami / 登出）。
/// 网络缝 Seams 注入（lab swift 同款）：CoreKit 只管状态机，网络实现由 App 层
/// APIGlue（生成物 AuthAPI/MeAPI 唯一入口）供（T-3），单测注入 fake 不发真网络。
@MainActor
final class AuthViewModelTests: XCTestCase {

    private let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let tenantA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    private func makeStore(configured: Bool) throws -> (UserDefaults, InMemoryTokenStore, SessionStore) {
        let suite = "AuthViewModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let secrets = InMemoryTokenStore()
        let store = SessionStore(defaults: defaults, secrets: secrets)
        if configured {
            try store.saveConfig(baseURL: "https://api.example.invalid", clientId: "saas-console")
        }
        return (defaults, secrets, store)
    }

    private func makeLoginResponse(accessToken: String? = "tk-1") -> LoginResponse {
        let user = SysUser(
            id: userID, username: "alice", status: .active,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let membership = TenantMembership(
            id: UUID(), userId: userID, tenantId: tenantA,
            roleIds: ["tenant-admin"], status: .active,
            joinedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        return LoginResponse(
            user: user, availableTenants: [membership], userId: userID,
            currentTenantId: tenantA, accessToken: accessToken,
            tokenType: "Bearer", expiresIn: 3600, clientId: "saas-console"
        )
    }

    private func makeWhoami() -> CurrentUser {
        CurrentUser(id: userID, email: "alice@example.invalid", memberships: [], currentTenantId: tenantA)
    }

    func testLoginWithoutConfigFailsFastAndNeverCallsSeam() async {
    // fn: M01.F04
        let (_, _, store) = try! makeStore(configured: false)
        var seamCalled = false
        let vm = AuthViewModel(
            store: store,
            seams: .init(
                login: { _, _, _ in seamCalled = true; return self.makeLoginResponse() },
                logout: {},
                whoami: { self.makeWhoami() }
            )
        )
        let ok = await vm.login(username: "alice", password: "dev123456")
        XCTAssertFalse(ok, "clientId 未配置 = fail-fast 不发请求（ADR-0019）")
        XCTAssertFalse(seamCalled, "缝不许被碰")
        if case .failed = vm.phase {} else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
        XCTAssertEqual(store.state, .needsSetup)
    }

    func testLoginSuccessAdoptsIntoStore() async throws {
    // fn: M01.F04
        let (_, secrets, store) = try makeStore(configured: true)
        var receivedClientId: String?
        let vm = AuthViewModel(
            store: store,
            seams: .init(
                login: { username, password, clientId in
                    receivedClientId = clientId
                    XCTAssertEqual(username, "alice")
                    XCTAssertEqual(password, "dev123456")
                    return self.makeLoginResponse()
                },
                logout: {},
                whoami: { self.makeWhoami() }
            )
        )
        let ok = await vm.login(username: "alice", password: "dev123456")
        XCTAssertTrue(ok)
        XCTAssertEqual(receivedClientId, "saas-console", "clientId 取自 SessionStore 配置")
        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.token, "tk-1")
        XCTAssertEqual(secrets.read("corekit.token"), "tk-1")
        XCTAssertEqual(vm.phase, .idle)
    }

    func testLoginFailureReportsAndKeepsStoreUntouched() async throws {
    // fn: M01.F04
        let (_, secrets, store) = try makeStore(configured: true)
        let vm = AuthViewModel(
            store: store,
            seams: .init(
                login: { _, _, _ in
                    throw ErrorResponse.error(401, nil, nil, URLError(.userAuthenticationRequired))
                },
                logout: {},
                whoami: { self.makeWhoami() }
            )
        )
        let ok = await vm.login(username: "alice", password: "wrong")
        XCTAssertFalse(ok)
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("401"), "错误消息要带 HTTP 码，实际：\(message)")
        } else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
        XCTAssertEqual(store.state, .needsLogin, "失败登录不动会话状态")
        XCTAssertNil(secrets.read("corekit.token"))
    }

    func testLogoutClearsStoreEvenWhenServerCallFails() async throws {
    // fn: M01.F04
        let (_, secrets, store) = try makeStore(configured: true)
        try store.adoptLogin(makeLoginResponse())
        let vm = AuthViewModel(
            store: store,
            seams: .init(
                login: { _, _, _ in self.makeLoginResponse() },
                logout: { throw URLError(.badServerResponse) },
                whoami: { self.makeWhoami() }
            )
        )
        await vm.logout()
        XCTAssertEqual(store.state, .needsLogin, "服务端通知尽力而为，本地清空必达")
        XCTAssertNil(store.token)
        XCTAssertNil(secrets.read("corekit.token"))
    }

    func testWhoamiPublishesCurrentUser() async throws {
    // fn: M01.F01
        let (_, _, store) = try makeStore(configured: true)
        let vm = AuthViewModel(
            store: store,
            seams: .init(
                login: { _, _, _ in self.makeLoginResponse() },
                logout: {},
                whoami: { self.makeWhoami() }
            )
        )
        XCTAssertNil(vm.currentUser)
        let who = await vm.whoami()
        XCTAssertEqual(who?.id, userID)
        XCTAssertEqual(vm.currentUser?.email, "alice@example.invalid")
        XCTAssertEqual(vm.phase, .idle)
    }

    func testWhoami401SurfacesFailureForIntercept() async throws {
    // fn: M01.F01
        let (_, _, store) = try makeStore(configured: true)
        let vm = AuthViewModel(
            store: store,
            seams: .init(
                login: { _, _, _ in self.makeLoginResponse() },
                logout: {},
                whoami: { throw ErrorResponse.error(401, nil, nil, URLError(.userAuthenticationRequired)) }
            )
        )
        let who = await vm.whoami()
        XCTAssertNil(who)
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("401"), "401 拦截（AC-5）靠 phase.failed 判别，实际：\(message)")
        } else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
    }
}
