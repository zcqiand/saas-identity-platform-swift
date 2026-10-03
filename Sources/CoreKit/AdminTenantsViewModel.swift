import Foundation
import SaasSharedGenerated

// REQ-2026-007 T-1：租户维护（M00.F01：平台 admin 租户 CRUD）。
// Seams 模式同 AdminClientsViewModel：网络实现由 App 层 APIGlue（生成物
// AdminTenantsAPI 唯一入口）供（T-2），单测注入 fake。
// 寻址 UUID id 非 key（Q1，与 admin/clients 的 clientId 字符串口径相反）；
// TenantStatus 是字符串枚举 active/suspended（Q2，与 OAuthClient 的 Int 两套
// 口径并存不混用）；tenantKey 重复创建 409（Q3 live 实证）。
// 成功原位维护列表（追加/替换/移除，不重拉）；失败只置 phase 红字，列表不动
// 可重试。删除是级联危险操作，确认流在 App 层 confirmationDialog，本层只执行。

/// 平台 admin 租户管理状态机：列表 → 创建 / 更新 / 删除。
@MainActor
public final class AdminTenantsViewModel: ObservableObject {

    public struct Seams {
        public var listTenants: () async throws -> AdminTenantsListTenants200Response
        public var createTenant: (_ request: CreateTenantRequest) async throws -> Tenant
        public var updateTenant: (_ id: UUID, _ request: UpdateTenantRequest) async throws -> Tenant
        public var deleteTenant: (_ id: UUID) async throws -> Void

        public init(
            listTenants: @escaping () async throws -> AdminTenantsListTenants200Response = { throw SessionStoreError("listTenants 缝未注入") },
            createTenant: @escaping (_ request: CreateTenantRequest) async throws -> Tenant = { _ in throw SessionStoreError("createTenant 缝未注入") },
            updateTenant: @escaping (_ id: UUID, _ request: UpdateTenantRequest) async throws -> Tenant = { _, _ in throw SessionStoreError("updateTenant 缝未注入") },
            deleteTenant: @escaping (_ id: UUID) async throws -> Void = { _ in throw SessionStoreError("deleteTenant 缝未注入") }
        ) {
            self.listTenants = listTenants
            self.createTenant = createTenant
            self.updateTenant = updateTenant
            self.deleteTenant = deleteTenant
        }
    }

    public enum Phase: Equatable {
        case idle
        case busy
        case failed(String)
    }

    @Published public private(set) var tenants: [Tenant] = []
    @Published public private(set) var phase: Phase = .idle

    private let seams: Seams

    public init(seams: Seams) {
        self.seams = seams
    }

    // @impl M00.F01.I01 — 租户列表
    /// 拉取租户全量清单（不传分页，Q1：分页 0-indexed 传 nil 全量）。
    @discardableResult
    public func load() async -> Bool {
        phase = .busy
        do {
            let page = try await seams.listTenants()
            tenants = page.items
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    // @impl M00.F01.I02 — 创建租户（成功就地追加行，不重拉）
    /// 新建租户（tenantKey 重复 409，Q3）。成功追加行（不重拉）。
    @discardableResult
    public func create(_ request: CreateTenantRequest) async -> Bool {
        phase = .busy
        do {
            let created = try await seams.createTenant(request)
            tenants.append(created)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 更新租户（partial 请求：name / status 字符串枚举）。成功原位替换该行
    /// （不重拉）。
    @discardableResult
    public func update(_ id: UUID, _ request: UpdateTenantRequest) async -> Bool {
        phase = .busy
        do {
            let updated = try await seams.updateTenant(id, request)
            if let index = tenants.firstIndex(where: { $0.id == id }) {
                tenants[index] = updated
            }
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// 删除租户（级联危险操作：App 层确认后才进这里）。成功原位移除该行。
    @discardableResult
    public func deleteTenant(_ id: UUID) async -> Bool {
        phase = .busy
        do {
            try await seams.deleteTenant(id)
            tenants.removeAll { $0.id == id }
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
