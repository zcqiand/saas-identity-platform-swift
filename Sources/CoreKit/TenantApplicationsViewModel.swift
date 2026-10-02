import Combine
import Foundation
import SaasSharedGenerated

// REQ-2026-012 T-1：租户应用订阅 ViewModel（M00.F05）。Seams 模式同族
// （RolesViewModel 先例）：CoreKit 只管状态机，网络实现由 App 层 APIGlue
// （生成物 TenantApplicationsAPI 唯一入口）供（T-2），单测注入 fake 不发真
// 网络。寻址契约：PATCH/DELETE 用 clientId 字符串列，不是 UUID id。
// wire 日期三形态实测（REQ-012 探针）——种子 T 分隔零分数、新订阅 7 位分数
// + 冒号偏移、patch 回读尾零截断——由 FamilyDateFormatter isoNoFraction
// 兜住（同 commit），list/subscribe/update 的解码才立得住。

@MainActor
public final class TenantApplicationsViewModel: ObservableObject {

    /// 网络缝：签名对齐生成层租户应用端点。四缝都带抛错缺省——未注入就调用
    /// = fail-fast，不留静默兜底。
    public struct Seams {
        public var list: (_ tenantId: String) async throws -> TenantApplicationsListTenantApplications200Response
        public var subscribe: (_ tenantId: String, _ request: SubscribeTenantApplicationRequest) async throws -> TenantApplication
        public var update: (_ tenantId: String, _ clientId: String, _ request: UpdateTenantApplicationRequest) async throws -> TenantApplication
        public var remove: (_ tenantId: String, _ clientId: String) async throws -> Void

        public init(
            list: @escaping (_: String) async throws -> TenantApplicationsListTenantApplications200Response = { _ in
                throw SessionStoreError("list 缝未注入")
            },
            subscribe: @escaping (_: String, _: SubscribeTenantApplicationRequest) async throws -> TenantApplication = { _, _ in
                throw SessionStoreError("subscribe 缝未注入")
            },
            update: @escaping (_: String, _: String, _: UpdateTenantApplicationRequest) async throws -> TenantApplication = { _, _, _ in
                throw SessionStoreError("update 缝未注入")
            },
            remove: @escaping (_: String, _: String) async throws -> Void = { _, _ in
                throw SessionStoreError("remove 缝未注入")
            }
        ) {
            self.list = list
            self.subscribe = subscribe
            self.update = update
            self.remove = remove
        }
    }

    public enum Phase: Equatable {
        case idle
        case busy
        case failed(String)
    }

    @Published public private(set) var phase: Phase = .idle
    /// 当前租户订阅清单（AC-1 渲染；失败保持旧值不兜底空数组假象）。
    @Published public private(set) var applications: [TenantApplication] = []

    private let store: SessionStore
    private let seams: Seams

    public init(store: SessionStore, seams: Seams) {
        self.store = store
        self.seams = seams
    }

    /// 进页加载（I01）：拉订阅全量（list 不传分页参，0-indexed 同族口径）。
    @discardableResult
    public func load() async -> Bool {
        guard let tenantId = store.currentTenantId?.uuidString else {
            phase = .failed("未选择租户，无法加载租户应用")
            return false
        }
        phase = .busy
        do {
            applications = try await seams.list(tenantId).items
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    // MARK: - M00.F05 subscription lifecycle (REQ-2026-012)

    /// 订阅（I02）：clientId 必填（oauth_client FK 目标，未知 → 404 如实呈现；
    /// 重复订阅后端 400 裸 SQL 泄漏——红字如实呈现，不做前置重名校验）。
    /// expireTime 可空。成功追加行（AC-3）。
    @discardableResult
    public func subscribe(clientId: String, expireTime: Date?) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法订阅应用") else { return false }
        phase = .busy
        do {
            let request = SubscribeTenantApplicationRequest(clientId: clientId, expireTime: expireTime)
            let created = try await seams.subscribe(tenantId, request)
            applications.append(created)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 更新订阅（I03）：PATCH partial。status int32（0=停用 1=启用，同族口径）；
    /// expireTime partial-update 语义（不传不改——CT I76 live 实证）。
    /// 成功以响应原位替换行（AC-4）。
    @discardableResult
    public func update(clientId: String, status: Int?, expireTime: Date?) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法更新订阅") else { return false }
        phase = .busy
        do {
            let request = UpdateTenantApplicationRequest(status: status ?? 0, expireTime: expireTime)
            let updated = try await seams.update(tenantId, clientId, request)
            replaceRow(updated)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 移除订阅（I04，危险操作）：DELETE → 本地按 clientId 移除行（AC-5）。
    @discardableResult
    public func remove(clientId: String) async -> Bool {
        guard let tenantId = currentTenantIdOrPerform("无法移除订阅") else { return false }
        phase = .busy
        do {
            try await seams.remove(tenantId, clientId)
            applications.removeAll { $0.clientId == clientId }
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    private func replaceRow(_ row: TenantApplication) {
        if let index = applications.firstIndex(where: { $0.clientId == row.clientId }) {
            applications[index] = row
        }
    }

    private func currentTenantIdOrPerform(_ action: String) -> String? {
        guard let tenantId = store.currentTenantId?.uuidString else {
            phase = .failed("未选择租户，\(action)")
            return nil
        }
        return tenantId
    }

    private static func message(of error: Error) -> String {
        if case ErrorResponse.error(let code, _, _, _) = error {
            return "请求失败（HTTP \(code)）"
        }
        return String(describing: error)
    }
}
