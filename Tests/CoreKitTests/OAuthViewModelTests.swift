import XCTest
import SaasSharedGenerated
@testable import CoreKit

/// REQ-2026-004 T-1：OAuth 授权码切片（authorize + token 双 grant + refresh）。
/// Seams 模式同 AuthViewModel/MembersViewModel：CoreKit 只管状态机，网络实现由
/// App 层 APIGlue（生成物 OauthAPI 唯一入口）供（T-2），单测注入 fake。
/// CSRF：state 自生成 + 回传校验，不一致 fail-fast 丢弃授权码（AC-1）。
/// 入账走 SessionStore.adoptOAuthToken（adoptSwitch fail-fast 同款：坏响应不动原会话，AC-4）。
@MainActor
final class OAuthViewModelTests: XCTestCase {

    private let userID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let tenantA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let tenantB = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!

    private func makeStore(configured: Bool, loggedIn: Bool, withRefresh: Bool = true) throws -> SessionStore {
        let suite = "OAuthViewModelTests.\(UUID().uuidString)"
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
                roleIds: [], status: .active,
                joinedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try store.adoptLogin(LoginResponse(
                user: user, availableTenants: [membership], userId: userID,
                currentTenantId: tenantA, accessToken: "tk-1",
                refreshToken: withRefresh ? "rt-1" : nil,
                tokenType: "Bearer", expiresIn: 3600, clientId: "saas-console"
            ))
        }
        return store
    }

    private func makeToken(
        access: String, refresh: String, tenantId: UUID, expiresIn: Int = 3600
    ) -> TokenResponse {
        TokenResponse(
            accessToken: access, refreshToken: refresh, tokenType: "Bearer",
            expiresIn: expiresIn, scope: "openid", userId: userID.uuidString,
            clientId: "saas-console", tenantId: tenantId
        )
    }

    // MARK: - SessionStore.adoptOAuthToken

    func testAdoptOAuthTokenSwapsPairAlignsTenantAndExpiresAt() throws {
    // fn: M04.F03
        let store = try makeStore(configured: true, loggedIn: true)
        let before = Date()
        try store.adoptOAuthToken(makeToken(access: "tk-2", refresh: "rt-2", tenantId: tenantB, expiresIn: 7200))
        XCTAssertEqual(store.state, .ready, "入账后会话仍 ready")
        XCTAssertEqual(store.token, "tk-2", "token 对换新（AC-2）")
        XCTAssertEqual(store.refreshToken, "rt-2", "refresh token 同步换新（AC-2）")
        XCTAssertEqual(store.currentTenantId, tenantB, "tenantId 与 token 响应对齐（Q3）")
        XCTAssertEqual(store.user?.username, "alice", "user/tenants 不变")
        XCTAssertEqual(store.tenants.count, 1, "user/tenants 不变")
        let expires = try XCTUnwrap(store.expiresAt, "expiresAt = now + expiresIn（Q3）")
        XCTAssertEqual(expires.timeIntervalSince(before), 7200, accuracy: 5.0)
    }

    func testAdoptOAuthTokenRejectsWhenNotReady() throws {
    // fn: M04.F03
        let store = try makeStore(configured: true, loggedIn: false)
        XCTAssertNil(store.token, "前置：未登录")
        XCTAssertThrowsError(try store.adoptOAuthToken(makeToken(access: "tk-x", refresh: "rt-x", tenantId: tenantB))) {
            XCTAssertTrue($0 is SessionStoreError, "未登录 = fail-fast 拒入账")
        }
        XCTAssertNil(store.token, "一个字节都不动")
        XCTAssertEqual(store.state, .needsLogin)
    }

    func testAdoptOAuthTokenRejectsEmptyAccessTokenAndKeepsOldPair() throws {
    // fn: M04.F03
        let store = try makeStore(configured: true, loggedIn: true)
        XCTAssertThrowsError(try store.adoptOAuthToken(makeToken(access: "", refresh: "rt-x", tenantId: tenantB))) {
            XCTAssertTrue($0 is SessionStoreError, "缺 accessToken = fail-fast")
        }
        XCTAssertEqual(store.token, "tk-1", "原 token 不动（AC-4 可重试）")
        XCTAssertEqual(store.refreshToken, "rt-1", "原 refresh token 不动")
    }

    // MARK: - OAuthViewModel.authorize

    func testAuthorizeSuccessRecordsCodeAndEchoedState() async throws {
    // fn: M04.F03
        let store = try makeStore(configured: true, loggedIn: true)
        var received: (clientId: String, redirectUri: String, scope: String, state: String)?
        let vm = OAuthViewModel(store: store, seams: .init(
            authorize: { clientId, redirectUri, scope, state in
                received = (clientId, redirectUri, scope, state)
                return OAuthAuthorize200Response(code: "code-1", state: state)
            },
            exchangeCode: { _, _, _ in throw URLError(.unsupportedURL) },
            refreshToken: { _, _ in throw URLError(.unsupportedURL) }
        ))
        let ok = await vm.authorize()
        XCTAssertTrue(ok)
        let args = try XCTUnwrap(received)
        XCTAssertEqual(args.clientId, "saas-console", "clientId 来自 SessionStore 配置（ADR-0019）")
        XCTAssertEqual(args.redirectUri, OAuthViewModel.redirectURI)
        XCTAssertEqual(args.scope, "openid", "scope 恒传（后端必填，契约 requiredMode 滞后）")
        XCTAssertFalse(args.state.isEmpty, "state 自生成（CSRF）")
        XCTAssertEqual(vm.lastCode, "code-1", "授权码回显（AC-1）")
        XCTAssertEqual(vm.lastState, args.state, "回显 state 与自生成 state 一致（AC-1）")
        XCTAssertEqual(store.token, "tk-1", "authorize 不动会话 token")
    }

    func testAuthorizeStateMismatchFailsFastAndDropsCode() async throws {
    // fn: M04.F03
        let store = try makeStore(configured: true, loggedIn: true)
        var exchangeCalled = false
        let vm = OAuthViewModel(store: store, seams: .init(
            authorize: { _, _, _, _ in
                OAuthAuthorize200Response(code: "code-evil", state: "forged-state")
            },
            exchangeCode: { _, _, _ in exchangeCalled = true; return self.makeToken(access: "tk-e", refresh: "rt-e", tenantId: self.tenantB) },
            refreshToken: { _, _ in throw URLError(.unsupportedURL) }
        ))
        let ok = await vm.authorize()
        XCTAssertFalse(ok, "state 回传不一致 = fail-fast（CSRF 防线）")
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("state"), "红字指明 state 校验失败，实际：\(message)")
        } else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
        XCTAssertNil(vm.lastCode, "可疑授权码必须丢弃")
        XCTAssertNil(vm.lastState)
        let exchange = await vm.exchangeCode()
        XCTAssertFalse(exchange, "无有效授权码不可换 token")
        XCTAssertFalse(exchangeCalled, "被丢弃的 code 不许流向 token 端点")
        XCTAssertEqual(store.token, "tk-1", "会话原样")
    }

    // MARK: - OAuthViewModel.exchangeCode

    func testExchangeSuccessAdoptsTokenPair() async throws {
    // fn: M04.F03
        let store = try makeStore(configured: true, loggedIn: true)
        var received: (code: String, clientId: String, redirectUri: String)?
        let vm = OAuthViewModel(store: store, seams: .init(
            authorize: { _, _, _, state in OAuthAuthorize200Response(code: "code-1", state: state) },
            exchangeCode: { code, clientId, redirectUri in
                received = (code, clientId, redirectUri)
                return self.makeToken(access: "tk-2", refresh: "rt-2", tenantId: self.tenantB)
            },
            refreshToken: { _, _ in throw URLError(.unsupportedURL) }
        ))
        _ = await vm.authorize()
        let ok = await vm.exchangeCode()
        XCTAssertTrue(ok)
        XCTAssertEqual(received?.code, "code-1", "用刚签发的授权码换 token")
        XCTAssertEqual(received?.clientId, "saas-console")
        XCTAssertEqual(received?.redirectUri, OAuthViewModel.redirectURI)
        XCTAssertEqual(store.token, "tk-2", "token 对入账（AC-2）")
        XCTAssertEqual(store.refreshToken, "rt-2")
        XCTAssertEqual(store.currentTenantId, tenantB, "租户上下文随 token 对齐")
        XCTAssertEqual(store.state, .ready)
    }

    func testExchangeFailureKeepsSessionIntactAndRetryable() async throws {
    // fn: M04.F03
        let store = try makeStore(configured: true, loggedIn: true)
        var reject = true
        let vm = OAuthViewModel(store: store, seams: .init(
            authorize: { _, _, _, state in OAuthAuthorize200Response(code: "code-1", state: state) },
            exchangeCode: { _, _, _ in
                if reject {
                    throw ErrorResponse.error(400, nil, nil, URLError(.badServerResponse))
                }
                return self.makeToken(access: "tk-2", refresh: "rt-2", tenantId: self.tenantB)
            },
            refreshToken: { _, _ in throw URLError(.unsupportedURL) }
        ))
        _ = await vm.authorize()
        let ok = await vm.exchangeCode()
        XCTAssertFalse(ok)
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("400"), "红字带 HTTP 码（AC-4），实际：\(message)")
        } else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
        XCTAssertEqual(store.token, "tk-1", "失败原 token 不动（AC-4）")
        XCTAssertEqual(store.refreshToken, "rt-1", "失败原 refresh token 不动")

        reject = false
        let retry = await vm.exchangeCode()
        XCTAssertTrue(retry, "同一 VM 可直接重试（AC-4 可重试）")
        XCTAssertEqual(store.token, "tk-2")
    }

    func testExchangeWithoutCodeFailsFastNeverCallsSeam() async throws {
    // fn: M04.F03
        let store = try makeStore(configured: true, loggedIn: true)
        var seamCalled = false
        let vm = OAuthViewModel(store: store, seams: .init(
            authorize: { _, _, _, _ in OAuthAuthorize200Response(code: "unused", state: "unused") },
            exchangeCode: { _, _, _ in seamCalled = true; return self.makeToken(access: "tk-e", refresh: "rt-e", tenantId: self.tenantB) },
            refreshToken: { _, _ in throw URLError(.unsupportedURL) }
        ))
        let ok = await vm.exchangeCode()
        XCTAssertFalse(ok, "未签发授权码 = fail-fast")
        XCTAssertFalse(seamCalled, "缝不许被碰")
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("授权码"), "红字指明缺授权码，实际：\(message)")
        } else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
    }

    // MARK: - OAuthViewModel.refresh

    func testRefreshRotatesTokenPair() async throws {
    // fn: M04.F03
        let store = try makeStore(configured: true, loggedIn: true)
        var receivedRefresh: String?
        let vm = OAuthViewModel(store: store, seams: .init(
            authorize: { _, _, _, state in OAuthAuthorize200Response(code: "code-1", state: state) },
            exchangeCode: { _, _, _ in self.makeToken(access: "tk-2", refresh: "rt-2", tenantId: self.tenantB) },
            refreshToken: { current, clientId in
                receivedRefresh = current
                XCTAssertEqual(clientId, "saas-console")
                return self.makeToken(access: "tk-3", refresh: "rt-3", tenantId: self.tenantB)
            }
        ))
        _ = await vm.authorize()
        _ = await vm.exchangeCode()
        let ok = await vm.refresh()
        XCTAssertTrue(ok)
        XCTAssertEqual(receivedRefresh, "rt-2", "用当前 refresh token 轮换（AC-3）")
        XCTAssertEqual(store.token, "tk-3", "轮换后新 token 对入账（AC-3）")
        XCTAssertEqual(store.refreshToken, "rt-3")
        XCTAssertEqual(store.state, .ready, "轮换后会话仍 ready（AC-3）")
    }

    func testRefreshWithoutRefreshTokenFailsFastNeverCallsSeam() async throws {
    // fn: M04.F03
        // ready 但登录响应没带 refresh token → store.refreshToken 为 nil
        let store = try makeStore(configured: true, loggedIn: true, withRefresh: false)
        XCTAssertNil(store.refreshToken, "前置：无 refresh token")
        var seamCalled = false
        let vm = OAuthViewModel(store: store, seams: .init(
            authorize: { _, _, _, _ in throw URLError(.unsupportedURL) },
            exchangeCode: { _, _, _ in throw URLError(.unsupportedURL) },
            refreshToken: { _, _ in seamCalled = true; return self.makeToken(access: "tk-e", refresh: "rt-e", tenantId: self.tenantB) }
        ))
        let ok = await vm.refresh()
        XCTAssertFalse(ok, "无 refresh token = fail-fast")
        XCTAssertFalse(seamCalled, "缝不许被碰")
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("refresh"), "红字指明缺 refresh token，实际：\(message)")
        } else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
        XCTAssertEqual(store.token, "tk-1", "会话原样")
    }
}
