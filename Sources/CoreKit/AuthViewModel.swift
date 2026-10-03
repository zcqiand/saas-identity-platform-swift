import Combine
import Foundation
import SaasSharedGenerated

// REQ-2026-001 T-2：认证流 ViewModel——密码登录（AC-2）/ whoami（AC-3）/
// 登出（AC-4）。网络缝 Seams 注入（lab swift 同款）：CoreKit 只管状态机，
// 网络实现由 App 层 APIGlue（生成物 AuthAPI/MeAPI 唯一入口）供（T-3），
// 单测注入 fake 不发真网络。

@MainActor
public final class AuthViewModel: ObservableObject {

    /// 网络缝：签名对齐生成层会话端点。clientId 由 ViewModel 从 SessionStore
    /// 取出传入（登录请求体必带，ADR-0019 口径）。switchTenant/listTenants
    /// （REQ-2026-002）带抛错缺省——未注入就调用 = fail-fast，不留静默兜底。
    public struct Seams {
        public var login: (_ username: String, _ password: String, _ clientId: String) async throws -> LoginResponse
        public var logout: () async throws -> Void
        public var whoami: () async throws -> CurrentUser
        public var switchTenant: (_ tenantId: String) async throws -> SwitchTenantResponse
        public var listTenants: () async throws -> [TenantMembership]

        public init(
            login: @escaping (_: String, _: String, _: String) async throws -> LoginResponse,
            logout: @escaping () async throws -> Void,
            whoami: @escaping () async throws -> CurrentUser,
            switchTenant: @escaping (_: String) async throws -> SwitchTenantResponse = { _ in
                throw SessionStoreError("switchTenant 缝未注入")
            },
            listTenants: @escaping () async throws -> [TenantMembership] = {
                throw SessionStoreError("listTenants 缝未注入")
            }
        ) {
            self.login = login
            self.logout = logout
            self.whoami = whoami
            self.switchTenant = switchTenant
            self.listTenants = listTenants
        }
    }

    public enum Phase: Equatable {
        case idle
        case busy
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    /// whoami 结果（AC-3 账户页渲染；失败保持 nil，不兜底字面量）。
    @Published public private(set) var currentUser: CurrentUser?

    private let store: SessionStore
    private let seams: Seams

    public init(store: SessionStore, seams: Seams) {
        self.store = store
        self.seams = seams
    }

    // @impl M01.F04.I01 — 密码登录（会话建立）
    /// 密码登录（AC-2）：成功 adopt 进 store（state→ready），失败保持现状报 failed。
    /// clientId 未配置 = fail-fast 不发请求（ADR-0019）。
    @discardableResult
    public func login(username: String, password: String) async -> Bool {
        guard let clientId = store.clientId, clientId.isEmpty == false else {
            phase = .failed("clientId 未配置，请先完成配置")
            return false
        }
        phase = .busy
        do {
            let response = try await seams.login(username, password, clientId)
            try store.adoptLogin(response)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// whoami（AC-3）：拉当前用户并发布。401 等失败置 phase.failed（App 层
    /// 据此拦截回登录页，AC-5），currentUser 保持 nil。
    @discardableResult
    public func whoami() async -> CurrentUser? {
        phase = .busy
        do {
            let user = try await seams.whoami()
            currentUser = user
            phase = .idle
            return user
        } catch {
            phase = .failed(Self.message(of: error))
            return nil
        }
    }

    // @impl M01.F03.I02 — 切换当前租户
    /// 切换租户（REQ-2026-002 AC-2/AC-3）：换发 token 对 adoptSwitch 入账，
    /// 成功后 whoami 重拉反映新上下文；失败保原会话红字可重试（adoptSwitch
    /// fail-fast 在前，失败时 store 未被触碰）。
    @discardableResult
    public func switchTenant(to tenantId: String) async -> Bool {
        phase = .busy
        do {
            let response = try await seams.switchTenant(tenantId)
            try store.adoptSwitch(response)
            phase = .idle
            _ = await whoami()
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 成员关系列表刷新（REQ-2026-002 Q1）：meListMyTenants 真值覆盖
    /// store.tenants；失败返回 nil（不与空列表混淆），旧列表保留。
    @discardableResult
    public func listTenants() async -> [TenantMembership]? {
        phase = .busy
        do {
            let tenants = try await seams.listTenants()
            try store.refreshTenants(tenants)
            phase = .idle
            return tenants
        } catch {
            phase = .failed(Self.message(of: error))
            return nil
        }
    }

    /// 登出（AC-4）：服务端通知尽力而为，本地清空必达（回登录页不等网络）。
    public func logout() async {
        phase = .busy
        try? await seams.logout()
        currentUser = nil
        store.logout()
        phase = .idle
    }

    private static func message(of error: Error) -> String {
        if case ErrorResponse.error(let code, _, _, _) = error {
            return "请求失败（HTTP \(code)）"
        }
        return String(describing: error)
    }
}
