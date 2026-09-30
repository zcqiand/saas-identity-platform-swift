import Foundation
import SaasSharedGenerated

// REQ-2026-001 T-2：会话状态机（lab swift SessionStore 同构，按 saas 契约形状适配）。
// needsSetup=未配后端（baseURL/clientId 任一缺）；needsLogin=配置齐无会话（登录页）；
// ready=已登录。token/refreshToken 走 TokenStoring 注入缝（App 层绑 Keychain，测试绑
// 内存 fake）；baseURL/clientId/会话快照（SysUser/memberships，非密）走 UserDefaults
// ——都是用户显式配置/登录的持久化，不是代码默认值兜底（§1 / ADR-0019）。
// 401 失效与登出共用 logout 语义（AC-4/AC-5）。
// 与 lab 的形状差异（saas 契约所致）：LoginResponse.user 是 SysUser（非 CurrentUser）；
// token 字段名 accessToken；登录必须带 clientId（ConfigView 显式配置）；
// 切换租户换发的是 SwitchTenantResponse 新 token 对（非 LoginResponse，REQ-2026-002）。

/// 会话状态存储：配置页（needsSetup）→ 登录页（needsLogin）→ 账户页（ready）。
public final class SessionStore {

    public enum SessionState: Equatable {
        case needsSetup
        case needsLogin
        case ready
    }

    private static let baseURLKey = "corekit.baseURL"
    private static let clientIdKey = "corekit.clientId"
    private static let sessionKey = "corekit.session"
    static let tokenKey = "corekit.token"
    static let refreshTokenKey = "corekit.refreshToken"

    private let defaults: UserDefaults
    private let secrets: TokenStoring

    public private(set) var state: SessionState
    public private(set) var baseURL: String?
    /// 登录用 OAuth client 标识（ConfigView 用户显式配置，ADR-0019；dev 惯例
    /// `saas-console`）。生命周期同 baseURL：logout 保留，clear 全清。
    public private(set) var clientId: String?
    public private(set) var token: String?
    public private(set) var refreshToken: String?
    public private(set) var user: SysUser?
    public private(set) var tenants: [TenantMembership] = []
    /// 当前租户上下文（LoginResponse.currentTenantId / adoptSwitch 更新 / 快照恢复）。
    /// nil 显示 —，不兜底字面量。
    public private(set) var currentTenantId: UUID?
    /// 当前 token 过期时刻（SwitchTenantResponse.expiresAt；REQ-2026-002 Q2：
    /// 仅随快照记录作展示依据，本期不做主动过期刷新）。
    public private(set) var expiresAt: Date?

    public init(defaults: UserDefaults, secrets: TokenStoring) {
        self.defaults = defaults
        self.secrets = secrets
        baseURL = defaults.string(forKey: Self.baseURLKey)
        clientId = defaults.string(forKey: Self.clientIdKey)
        token = secrets.read(Self.tokenKey)
        refreshToken = secrets.read(Self.refreshTokenKey)

        if token?.isEmpty == false {
            if let data = defaults.data(forKey: Self.sessionKey),
               let snapshot = try? JSONDecoder().decode(SessionSnapshot.self, from: data) {
                user = snapshot.user
                tenants = snapshot.tenants
                currentTenantId = snapshot.currentTenantId
                expiresAt = snapshot.expiresAt
            }
            state = Self.isConfigured(baseURL, clientId) ? .ready : .needsSetup
        } else {
            // 密态缺失：上一任会话快照不许呈现（失效即回登录页，AC-5）。
            token = nil
            refreshToken = nil
            user = nil
            tenants = []
            currentTenantId = nil
            defaults.removeObject(forKey: Self.sessionKey)
            state = Self.isConfigured(baseURL, clientId) ? .needsLogin : .needsSetup
        }
    }

    private static func isConfigured(_ baseURL: String?, _ clientId: String?) -> Bool {
        baseURL?.isEmpty == false && clientId?.isEmpty == false
    }

    /// 配置页落账：baseURL + clientId 任一空/非法拒存（fail-fast 不留半配置态，
    /// AC-1）。成功后无会话 → needsLogin；有会话（换后端重配）→ ready 并重注 Bearer。
    public func saveConfig(baseURL rawBaseURL: String, clientId rawClientId: String) throws {
        let normalized = try APIClient.normalizeBaseURL(rawBaseURL)
        let trimmedClient = rawClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedClient.isEmpty == false else {
            throw SessionStoreError.emptyField("clientId 不能为空")
        }
        defaults.set(normalized, forKey: Self.baseURLKey)
        defaults.set(trimmedClient, forKey: Self.clientIdKey)
        baseURL = normalized
        clientId = trimmedClient
        if let token {
            OpenAPIClientAPI.basePath = normalized
            OpenAPIClientAPI.customHeaders["Authorization"] = "Bearer \(token)"
            state = .ready
        } else {
            state = .needsLogin
        }
    }

    /// 登录成功后的入账：密态落缝 + 会话快照落 defaults + Bearer 注入，状态进 ready。
    /// 响应缺 accessToken = 不入账（fail-fast，不留半会话）。
    public func adoptLogin(_ response: LoginResponse) throws {
        guard let accessToken = response.accessToken, accessToken.isEmpty == false else {
            throw SessionStoreError.emptyField("登录响应缺 accessToken")
        }
        secrets.save(Self.tokenKey, accessToken)
        token = accessToken
        if let refresh = response.refreshToken, refresh.isEmpty == false {
            secrets.save(Self.refreshTokenKey, refresh)
            refreshToken = refresh
        } else {
            secrets.delete(Self.refreshTokenKey)
            refreshToken = nil
        }
        user = response.user
        tenants = response.availableTenants
        currentTenantId = response.currentTenantId
        let snapshot = SessionSnapshot(
            user: response.user, tenants: response.availableTenants,
            currentTenantId: response.currentTenantId
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.sessionKey)
        }
        if let baseURL {
            // baseURL 已过校验，这里只为重注 basePath + Bearer（失败不掩盖登录成功）。
            _ = try? APIClient.bootstrap(baseURL: baseURL, token: accessToken)
        }
        state = .ready
    }

    /// 切换租户入账（REQ-2026-002）：SwitchTenantResponse 换发的是新 token 对
    /// （saas 契约，非 LoginResponse——lab 同端点不同形，独立实现不复用 adoptLogin）。
    /// user/tenants 不变；token/refresh 换新落密态缝、currentTenantId 更新、
    /// expiresAt 随快照记录、Bearer 重注，state 保持 ready。缺 accessToken 或
    /// 未登录 = fail-fast 一个字节都不动（AC-3 原会话可重试）。
    public func adoptSwitch(_ response: SwitchTenantResponse) throws {
        guard state == .ready else {
            throw SessionStoreError.invalidState("未登录，不能切换租户")
        }
        guard response.accessToken.isEmpty == false else {
            throw SessionStoreError.emptyField("切换响应缺 accessToken")
        }
        secrets.save(Self.tokenKey, response.accessToken)
        token = response.accessToken
        if response.refreshToken.isEmpty == false {
            secrets.save(Self.refreshTokenKey, response.refreshToken)
            refreshToken = response.refreshToken
        } else {
            secrets.delete(Self.refreshTokenKey)
            refreshToken = nil
        }
        currentTenantId = response.tenantId
        expiresAt = response.expiresAt
        if let user {
            let snapshot = SessionSnapshot(
                user: user, tenants: tenants,
                currentTenantId: currentTenantId, expiresAt: expiresAt
            )
            if let data = try? JSONEncoder().encode(snapshot) {
                defaults.set(data, forKey: Self.sessionKey)
            }
        }
        if let baseURL {
            // baseURL 已过校验，这里只为重注 basePath + Bearer（失败不掩盖切换成功）。
            _ = try? APIClient.bootstrap(baseURL: baseURL, token: response.accessToken)
        }
    }

    /// OAuth token 对入账（REQ-2026-004）：authorization_code 换发 / refresh_token
    /// 轮换共用。token 对换新落密态缝、currentTenantId 对齐响应 tenantId、
    /// expiresAt = now + expiresIn、Bearer 重注，state 保持 ready。user/tenants 不变。
    /// 缺 accessToken 或未登录 = fail-fast 一个字节都不动（AC-4 原会话可重试）。
    public func adoptOAuthToken(_ response: TokenResponse) throws {
        guard state == .ready else {
            throw SessionStoreError.invalidState("未登录，不能入账 OAuth token")
        }
        guard response.accessToken.isEmpty == false else {
            throw SessionStoreError.emptyField("token 响应缺 accessToken")
        }
        secrets.save(Self.tokenKey, response.accessToken)
        token = response.accessToken
        if response.refreshToken.isEmpty == false {
            secrets.save(Self.refreshTokenKey, response.refreshToken)
            refreshToken = response.refreshToken
        } else {
            secrets.delete(Self.refreshTokenKey)
            refreshToken = nil
        }
        currentTenantId = response.tenantId
        expiresAt = Date().addingTimeInterval(Double(response.expiresIn))
        if let user {
            let snapshot = SessionSnapshot(
                user: user, tenants: tenants,
                currentTenantId: currentTenantId, expiresAt: expiresAt
            )
            if let data = try? JSONEncoder().encode(snapshot) {
                defaults.set(data, forKey: Self.sessionKey)
            }
        }
        if let baseURL {
            // baseURL 已过校验，这里只为重注 basePath + Bearer（失败不掩盖入账成功）。
            _ = try? APIClient.bootstrap(baseURL: baseURL, token: response.accessToken)
        }
    }

    /// 成员关系列表刷新（REQ-2026-002 Q1）：meListMyTenants 真值覆盖快照 tenants
    ///（进页先用登录快照渲染，拉到真值再覆盖，不一致以后端为准）。currentTenantId
    /// 不动；未登录拒刷。
    public func refreshTenants(_ tenants: [TenantMembership]) throws {
        guard state == .ready, let user else {
            throw SessionStoreError.invalidState("未登录，不能刷新成员关系")
        }
        self.tenants = tenants
        let snapshot = SessionSnapshot(
            user: user, tenants: tenants,
            currentTenantId: currentTenantId, expiresAt: expiresAt
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: Self.sessionKey)
        }
    }

    /// 登出/401 失效共用（AC-4/AC-5）：清密态 + 快照，留配置直接回登录页。
    public func logout() {
        secrets.delete(Self.tokenKey)
        secrets.delete(Self.refreshTokenKey)
        token = nil
        refreshToken = nil
        defaults.removeObject(forKey: Self.sessionKey)
        user = nil
        tenants = []
        currentTenantId = nil
        state = .needsLogin
        OpenAPIClientAPI.customHeaders.removeValue(forKey: "Authorization")
    }

    /// 全清回配置页（换后端入口）。clientId 生命周期同 baseURL：这里一并清。
    public func clear() {
        logout()
        defaults.removeObject(forKey: Self.baseURLKey)
        baseURL = nil
        defaults.removeObject(forKey: Self.clientIdKey)
        clientId = nil
        state = .needsSetup
    }
}

/// 会话快照（非密态，落 defaults）：登录响应里的用户与租户成员关系 +
/// 当前租户上下文。lab swift 的 CurrentUserSession 是生成模型；saas 契约无此
/// 形状，CoreKit 本地定义（字段全部来自生成物类型，无手写 DTO）。
public struct SessionSnapshot: Codable {
    public var user: SysUser
    public var tenants: [TenantMembership]
    public var currentTenantId: UUID?
    /// 切换租户换发 token 的过期时刻（REQ-2026-002 Q2；可选，老快照缺字段可解码）。
    public var expiresAt: Date?

    public init(user: SysUser, tenants: [TenantMembership], currentTenantId: UUID?, expiresAt: Date? = nil) {
        self.user = user
        self.tenants = tenants
        self.currentTenantId = currentTenantId
        self.expiresAt = expiresAt
    }
}

/// SessionStore 校验失败（fail-fast，不兜底）。
public struct SessionStoreError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
    public static func emptyField(_ message: String) -> SessionStoreError { SessionStoreError(message) }
    public static func invalidState(_ message: String) -> SessionStoreError { SessionStoreError(message) }
}
