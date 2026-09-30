import Foundation
import SaasSharedGenerated

// REQ-2026-004 T-1：OAuth 授权码切片（M04.F03：authorize + token 双 grant + refresh）。
// saas 后端的 authorize/token 是 JSON API（Bearer 会话直接 POST，非浏览器跳板），
// 整个授权码流纯应用内完成。Seams 模式同 AuthViewModel/MembersViewModel：网络实现
// 由 App 层 APIGlue（生成物 OauthAPI 唯一入口）供（T-2），单测注入 fake。
// 契约要点（live 探针实证 2026-09-30）：scope 后端必填（恒传，默认 openid）；
// token 免 clientSecret（公共 client）；refresh_token grant 轮换全新 token 对。
// CSRF：state 自生成 + 回传校验，不一致 fail-fast 丢弃授权码。
// 入账走 SessionStore.adoptOAuthToken（adoptSwitch fail-fast 同款：坏响应不动原会话）。

/// OAuth 授权码流状态机：签发授权码（authorize）→ 换 token（exchangeCode）→
/// 刷新（refresh）。成功入账由 SessionStore 承担；失败只置 phase 红字，会话不动。
@MainActor
public final class OAuthViewModel: ObservableObject {

    public struct Seams {
        public var authorize: (_ clientId: String, _ redirectUri: String, _ scope: String, _ state: String) async throws -> OAuthAuthorize200Response
        public var exchangeCode: (_ code: String, _ clientId: String, _ redirectUri: String) async throws -> TokenResponse
        public var refreshToken: (_ currentRefreshToken: String, _ clientId: String) async throws -> TokenResponse

        public init(
            authorize: @escaping (_ clientId: String, _ redirectUri: String, _ scope: String, _ state: String) async throws -> OAuthAuthorize200Response = { _, _, _, _ in throw SessionStoreError("authorize 缝未注入") },
            exchangeCode: @escaping (_ code: String, _ clientId: String, _ redirectUri: String) async throws -> TokenResponse = { _, _, _ in throw SessionStoreError("exchangeCode 缝未注入") },
            refreshToken: @escaping (_ currentRefreshToken: String, _ clientId: String) async throws -> TokenResponse = { _, _ in throw SessionStoreError("refreshToken 缝未注入") }
        ) {
            self.authorize = authorize
            self.exchangeCode = exchangeCode
            self.refreshToken = refreshToken
        }
    }

    public enum Phase: Equatable {
        case idle
        case busy
        case failed(String)
    }

    /// saas-console 种子里的本 app 回调 URI（Q1 澄清：固定默认值，不做可编辑 UI）。
    public static let redirectURI = "saasidentity://oauth/callback"
    /// scope 恒传（后端必填；生成模型 optional 是契约 requiredMode 滞后，不依赖缺省）。
    public static let defaultScope = "openid"

    @Published public private(set) var phase: Phase = .idle
    /// 最近一次签发的授权码与其回传 state（OAuthView 回显）。
    @Published public private(set) var lastCode: String?
    @Published public private(set) var lastState: String?
    /// 自生成的 state（CSRF 防线），authorize 响应必须原样回传。
    private var pendingState: String?

    private let store: SessionStore
    private let seams: Seams

    public init(store: SessionStore, seams: Seams = .init()) {
        self.store = store
        self.seams = seams
    }

    /// 签发授权码：clientId 来自 SessionStore 配置（ADR-0019），state 自生成并要求
    /// 响应回传一致。不一致 = 疑似 CSRF，fail-fast 丢弃授权码（AC-1）。会话不动。
    @discardableResult
    public func authorize() async -> Bool {
        guard let clientId = Self.configuredClientId(of: store) else { return false }
        let state = UUID().uuidString
        pendingState = state
        phase = .busy
        do {
            let response = try await seams.authorize(clientId, Self.redirectURI, Self.defaultScope, state)
            guard response.state == state else {
                lastCode = nil
                lastState = nil
                pendingState = nil
                phase = .failed("state 回传不一致（疑似 CSRF），已丢弃授权码")
                return false
            }
            lastCode = response.code
            lastState = response.state
            phase = .idle
            return true
        } catch {
            lastCode = nil
            lastState = nil
            pendingState = nil
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 用最近签发的授权码换 token（authorization_code grant），成功经
    /// adoptOAuthToken 入账（token 对换新 + tenantId/expiresAt，AC-2）。
    @discardableResult
    public func exchangeCode() async -> Bool {
        guard let code = lastCode, code.isEmpty == false else {
            phase = .failed("尚无授权码，请先签发")
            return false
        }
        guard let clientId = Self.configuredClientId(of: store) else { return false }
        phase = .busy
        do {
            let token = try await seams.exchangeCode(code, clientId, Self.redirectURI)
            try store.adoptOAuthToken(token)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 刷新（refresh_token grant 轮换）：用当前 refresh token 换全新 token 对入账（AC-3）。
    @discardableResult
    public func refresh() async -> Bool {
        guard let clientId = Self.configuredClientId(of: store) else { return false }
        guard let current = store.refreshToken, current.isEmpty == false else {
            phase = .failed("尚无 refresh token，请先换 token")
            return false
        }
        phase = .busy
        do {
            let token = try await seams.refreshToken(current, clientId)
            try store.adoptOAuthToken(token)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    private static func configuredClientId(of store: SessionStore) -> String? {
        guard let clientId = store.clientId, clientId.isEmpty == false else {
            return nil
        }
        return clientId
    }

    private static func message(of error: Error) -> String {
        if case ErrorResponse.error(let code, _, _, _) = error {
            return "请求失败（HTTP \(code)）"
        }
        return "请求失败（\(error.localizedDescription)）"
    }
}
