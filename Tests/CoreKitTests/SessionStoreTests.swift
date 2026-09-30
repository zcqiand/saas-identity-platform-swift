import XCTest
import SaasSharedGenerated
@testable import CoreKit

/// REQ-2026-001 T-2：SessionStore 状态机（配置 baseURL+clientId → 登录 → ready）。
/// 存储缝 TokenStoring 注入（lab swift 同款）：swift test 只用 InMemoryTokenStore
/// fake，KeychainTokenStore 实现在 App target 绑定层（T-3），单测不碰 Keychain。
/// fail-fast 口径（ADR-0019）：baseURL/clientId 用户显式配置，任一空拒存；
/// accessToken/refreshToken 走密态缝，会话快照（SysUser/memberships，非密）走
/// UserDefaults——都是用户显式登录的持久化，不是代码默认值兜底。
final class SessionStoreTests: XCTestCase {

    private func makeDeps() -> (UserDefaults, InMemoryTokenStore) {
        let suite = "SessionStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, InMemoryTokenStore())
    }

    private let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let tenantA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let tenantB = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    private func makeUser() -> SysUser {
        SysUser(
            id: userID, username: "alice", status: .active,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeMembership(tenantId: UUID) -> TenantMembership {
        TenantMembership(
            id: UUID(), userId: userID, tenantId: tenantId,
            roleIds: ["tenant-admin"], status: .active,
            joinedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeLoginResponse(
        accessToken: String? = "tk-1", refreshToken: String? = "rt-tk-1"
    ) -> LoginResponse {
        LoginResponse(
            user: makeUser(),
            availableTenants: [makeMembership(tenantId: tenantA), makeMembership(tenantId: tenantB)],
            userId: userID,
            currentTenantId: tenantA,
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: "Bearer",
            expiresIn: 3600,
            clientId: "saas-console"
        )
    }

    private func configure(_ store: SessionStore) throws {
        try store.saveConfig(baseURL: "https://api.example.invalid/", clientId: "saas-console")
    }

    func testFreshStoreNeedsSetupWithNothingPersisted() {
        let (defaults, secrets) = makeDeps()
        let store = SessionStore(defaults: defaults, secrets: secrets)
        XCTAssertEqual(store.state, .needsSetup)
        XCTAssertNil(store.baseURL)
        XCTAssertNil(store.clientId)
        XCTAssertNil(store.token)
        XCTAssertNil(store.user)
        XCTAssertTrue(store.tenants.isEmpty)
    }

    func testSaveConfigValidatesFailFastThenNeedsLogin() throws {
    // fn: M01.F04
        let (defaults, secrets) = makeDeps()
        let store = SessionStore(defaults: defaults, secrets: secrets)
        XCTAssertThrowsError(try store.saveConfig(baseURL: "   ", clientId: "saas-console"))
        XCTAssertThrowsError(try store.saveConfig(baseURL: "not a url", clientId: "saas-console"))
        XCTAssertThrowsError(try store.saveConfig(baseURL: "https://api.example.invalid", clientId: "  "),
                             "clientId 空 = 拒存（ADR-0019，不兜底字面量）")
        XCTAssertEqual(store.state, .needsSetup, "失败保存不许改状态")

        try configure(store)
        XCTAssertEqual(store.state, .needsLogin, "配置齐没登录 = needsLogin")
        XCTAssertEqual(store.baseURL, "https://api.example.invalid", "尾斜杠归一")
        XCTAssertEqual(store.clientId, "saas-console")
        XCTAssertNil(store.token)

        // 重启恢复：配置从 UserDefaults 回来，仍 needsLogin
        let reborn = SessionStore(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reborn.state, .needsLogin)
        XCTAssertEqual(reborn.baseURL, "https://api.example.invalid")
        XCTAssertEqual(reborn.clientId, "saas-console")
    }

    func testAdoptLoginPersistsSecretsAndReadiesAcrossRebirth() throws {
    // fn: M01.F04
        let (defaults, secrets) = makeDeps()
        let store = SessionStore(defaults: defaults, secrets: secrets)
        try configure(store)
        try store.adoptLogin(makeLoginResponse(accessToken: "tk-1"))

        XCTAssertEqual(store.state, .ready)
        XCTAssertEqual(store.token, "tk-1")
        XCTAssertEqual(store.refreshToken, "rt-tk-1")
        // 密态真落在注入缝里（Keychain 化的缝契约），不是 UserDefaults
        XCTAssertEqual(secrets.read("corekit.token"), "tk-1")
        XCTAssertNil(defaults.string(forKey: "corekit.token"), "token 不许落 UserDefaults")

        // 重启恢复：token + 会话快照齐活，直接 ready
        let reborn = SessionStore(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reborn.state, .ready)
        XCTAssertEqual(reborn.token, "tk-1")
        XCTAssertEqual(reborn.user?.username, "alice")
        XCTAssertEqual(reborn.tenants.count, 2)
    }

    func testAdoptLoginMissingAccessTokenFailsFast() throws {
    // fn: M01.F04
        let (defaults, secrets) = makeDeps()
        let store = SessionStore(defaults: defaults, secrets: secrets)
        try configure(store)
        XCTAssertThrowsError(try store.adoptLogin(makeLoginResponse(accessToken: nil)),
                             "登录响应缺 accessToken = 不入账（fail-fast，不留半会话）")
        XCTAssertEqual(store.state, .needsLogin, "失败 adopt 不许改状态")
        XCTAssertNil(secrets.read("corekit.token"))
        XCTAssertNil(store.user)
    }

    func testAdoptLoginSnapshotRoundTripSurvivesRebirth() throws {
    // fn: M01.F01
        let (defaults, secrets) = makeDeps()
        let store = SessionStore(defaults: defaults, secrets: secrets)
        try configure(store)
        try store.adoptLogin(makeLoginResponse(accessToken: "tk-2"))

        let reborn = SessionStore(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reborn.user?.id, userID)
        XCTAssertEqual(reborn.user?.username, "alice")
        XCTAssertEqual(reborn.tenants.first?.tenantId, tenantA)
        XCTAssertEqual(reborn.tenants.first?.roleIds, ["tenant-admin"])
        XCTAssertEqual(reborn.currentTenantId, tenantA, "currentTenantId 本期只展示不切换（REQ 非范围）")
    }

    func testLogoutClearsSecretsKeepsConfigAndSurvivesRebirth() throws {
    // fn: M01.F04
        let (defaults, secrets) = makeDeps()
        let store = SessionStore(defaults: defaults, secrets: secrets)
        try configure(store)
        try store.adoptLogin(makeLoginResponse(accessToken: "tk-3"))
        store.logout()

        XCTAssertEqual(store.state, .needsLogin, "登出只清会话，留配置直接回登录页")
        XCTAssertNil(store.token)
        XCTAssertNil(store.refreshToken)
        XCTAssertNil(store.user)
        XCTAssertTrue(store.tenants.isEmpty)
        XCTAssertNil(store.currentTenantId)
        XCTAssertEqual(store.clientId, "saas-console", "clientId 生命周期同 baseURL：logout 留，clear 清")
        XCTAssertNil(secrets.read("corekit.token"), "密态必须真删")

        let reborn = SessionStore(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reborn.state, .needsLogin)
        XCTAssertNil(reborn.token)
    }

    func testClearWipesEverythingBackToNeedsSetup() throws {
    // fn: M01.F04
        let (defaults, secrets) = makeDeps()
        let store = SessionStore(defaults: defaults, secrets: secrets)
        try configure(store)
        try store.adoptLogin(makeLoginResponse(accessToken: "tk-4"))
        store.clear()
        XCTAssertEqual(store.state, .needsSetup)
        XCTAssertNil(store.baseURL)
        XCTAssertNil(store.clientId)
        XCTAssertNil(secrets.read("corekit.token"))
    }

    func testExpirePathEqualsLogoutSemanticsOnRebirth() throws {
    // fn: M01.F04
        // 401 拦截缝与登出共用本地清空语义：token 没了就回登录页，配置留着。
        let (defaults, secrets) = makeDeps()
        let store = SessionStore(defaults: defaults, secrets: secrets)
        try configure(store)
        try store.adoptLogin(makeLoginResponse(accessToken: "tk-5"))
        secrets.delete("corekit.token")
        secrets.delete("corekit.refreshToken")

        let reborn = SessionStore(defaults: defaults, secrets: secrets)
        XCTAssertEqual(reborn.state, .needsLogin, "密态缺失但配置在 = 回登录页而非配置页")
        XCTAssertNil(reborn.token)
        XCTAssertNil(reborn.user, "无 token 时不许呈现上一任会话快照")
        XCTAssertTrue(reborn.tenants.isEmpty)
    }
}
