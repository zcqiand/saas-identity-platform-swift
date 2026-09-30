import Foundation
import SaasSharedGenerated

// REQ-2026-005 T-1：应用维护（M04.F01：OAuth client CRUD + 公共元数据）。
// 平台 admin 视角，Seams 模式同 MembersViewModel/OAuthViewModel：网络实现由
// App 层 APIGlue（生成物 AdminClientsAPI 唯一入口）供（T-2），单测注入 fake。
// list 不传分页（live 探针实证分页 0-indexed，nil 全量，翻页 UI 非范围）。
// create/update/delete 成功原位维护列表（不重拉）；失败只置 phase 红字，
// 列表不动可重试（AC-5 惯例）。delete 是危险操作（服务端吊销该 client 全部
// token），确认流在 App 层 AlertDialog，本层只执行。

/// OAuth client 管理状态机：列表 → 创建 / 编辑 / 删除。
@MainActor
public final class AdminClientsViewModel: ObservableObject {

    public struct Seams {
        public var listClients: () async throws -> AdminClientsListClients200Response
        public var getClient: (_ clientId: String) async throws -> OAuthClient
        public var createClient: (_ request: CreateOAuthClientRequest) async throws -> OAuthClient
        public var updateClient: (_ clientId: String, _ request: UpdateOAuthClientRequest) async throws -> OAuthClient
        public var deleteClient: (_ clientId: String) async throws -> Void

        public init(
            listClients: @escaping () async throws -> AdminClientsListClients200Response = { throw SessionStoreError("listClients 缝未注入") },
            getClient: @escaping (_ clientId: String) async throws -> OAuthClient = { _ in throw SessionStoreError("getClient 缝未注入") },
            createClient: @escaping (_ request: CreateOAuthClientRequest) async throws -> OAuthClient = { _ in throw SessionStoreError("createClient 缝未注入") },
            updateClient: @escaping (_ clientId: String, _ request: UpdateOAuthClientRequest) async throws -> OAuthClient = { _, _ in throw SessionStoreError("updateClient 缝未注入") },
            deleteClient: @escaping (_ clientId: String) async throws -> Void = { _ in throw SessionStoreError("deleteClient 缝未注入") }
        ) {
            self.listClients = listClients
            self.getClient = getClient
            self.createClient = createClient
            self.updateClient = updateClient
            self.deleteClient = deleteClient
        }
    }

    public enum Phase: Equatable {
        case idle
        case busy
        case failed(String)
    }

    @Published public private(set) var clients: [OAuthClient] = []
    @Published public private(set) var phase: Phase = .idle

    private let seams: Seams

    public init(seams: Seams) {
        self.seams = seams
    }

    /// 拉取 client 全量清单（不传分页，Q1：live 实证 0-indexed 传 nil 全量）。
    @discardableResult
    public func load() async -> Bool {
        phase = .busy
        do {
            let page = try await seams.listClients()
            clients = page.items
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 注册新 client（secret 必填录入，Q2）。成功追加行（不重拉）。
    @discardableResult
    public func create(_ request: CreateOAuthClientRequest) async -> Bool {
        phase = .busy
        do {
            let created = try await seams.createClient(request)
            clients.append(created)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 更新 client（partial 请求：只提交改动的字段）。成功原位替换该行（不重拉）。
    @discardableResult
    public func update(_ clientId: String, _ request: UpdateOAuthClientRequest) async -> Bool {
        phase = .busy
        do {
            let updated = try await seams.updateClient(clientId, request)
            if let index = clients.firstIndex(where: { $0.clientId == clientId }) {
                clients[index] = updated
            }
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 删除 client（危险操作：服务端吊销该 client 名下全部 token；App 层确认后
    /// 才进这里）。成功原位移除该行（不重拉）。
    @discardableResult
    public func deleteClient(_ clientId: String) async -> Bool {
        phase = .busy
        do {
            try await seams.deleteClient(clientId)
            clients.removeAll { $0.clientId == clientId }
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
        return "请求失败（\(error.localizedDescription)）"
    }
}
