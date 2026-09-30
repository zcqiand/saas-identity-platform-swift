import XCTest
import SaasSharedGenerated
@testable import CoreKit

/// REQ-2026-007 T-1：租户维护 ViewModel（平台 admin 租户 CRUD）。
/// Seams 模式同 AdminClientsViewModel：CoreKit 只管状态机，网络实现由 App 层
/// APIGlue（生成物 AdminTenantsAPI 唯一入口）供（T-2），单测注入 fake。
/// 寻址 UUID id 非 key（Q1，与 admin/clients 的 clientId 字符串口径相反）；
/// status 是字符串枚举 active/suspended（Q2，与 OAuthClient 的 Int 两套口径）；
/// tenantKey 重复 409（Q3 live 实证）。成功原位维护列表不重拉；失败红字列表
/// 不动可重试。
@MainActor
final class AdminTenantsViewModelTests: XCTestCase {

    private let acmeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let globexID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func makeTenant(
        id: UUID, key: String, name: String, status: TenantStatus = .active
    ) -> Tenant {
        Tenant(
            id: id, tenantKey: key, name: name, status: status,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private var seedList: AdminTenantsListTenants200Response {
        AdminTenantsListTenants200Response(
            items: [
                makeTenant(id: acmeID, key: "acme", name: "ACME Corp"),
                makeTenant(id: globexID, key: "globex", name: "Globex Industries"),
            ],
            page: 0, pageSize: 20, total: 2
        )
    }

    func testLoadPopulatesTenantsWithoutPaging() async {
    // fn: M00.F01
        var listCalled = false
        let vm = AdminTenantsViewModel(seams: .init(
            listTenants: {
                listCalled = true
                return self.seedList
            },
            createTenant: { _ in throw TenantStubError.notUsed },
            updateTenant: { _, _ in throw TenantStubError.notUsed },
            deleteTenant: { _ in throw TenantStubError.notUsed }
        ))
        let ok = await vm.load()
        XCTAssertTrue(ok, "nil 全量拉取（Q1：分页 0-indexed，传 nil）")
        XCTAssertTrue(listCalled)
        XCTAssertEqual(vm.tenants.map(\.tenantKey), ["acme", "globex"], "列表全量渲染（AC-1）")
        XCTAssertEqual(vm.phase, .idle)
    }

    func testLoadFailureKeepsEmptyAndRetryable() async {
    // fn: M00.F01
        var reject = true
        let vm = AdminTenantsViewModel(seams: .init(
            listTenants: {
                if reject {
                    throw ErrorResponse.error(403, nil, nil, URLError(.userAuthenticationRequired))
                }
                return self.seedList
            },
            createTenant: { _ in throw TenantStubError.notUsed },
            updateTenant: { _, _ in throw TenantStubError.notUsed },
            deleteTenant: { _ in throw TenantStubError.notUsed }
        ))
        let ok = await vm.load()
        XCTAssertFalse(ok, "403 = 失败（AC-4）")
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("403"), "红字带 HTTP 码，实际：\(message)")
        } else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
        XCTAssertTrue(vm.tenants.isEmpty, "失败不发假数据")

        reject = false
        let retry = await vm.load()
        XCTAssertTrue(retry, "同一 VM 可直接重试（AC-4）")
        XCTAssertEqual(vm.tenants.count, 2)
    }

    func testCreateAppendsRowInPlaceWithoutReload() async {
    // fn: M00.F01
        var listCalls = 0
        var received: CreateTenantRequest?
        let created = makeTenant(id: UUID(), key: "initech", name: "Initech")
        let vm = AdminTenantsViewModel(seams: .init(
            listTenants: { listCalls += 1; return self.seedList },
            createTenant: { request in
                received = request
                return created
            },
            updateTenant: { _, _ in throw TenantStubError.notUsed },
            deleteTenant: { _ in throw TenantStubError.notUsed }
        ))
        _ = await vm.load()
        let ok = await vm.create(CreateTenantRequest(tenantKey: "initech", name: "Initech"))
        XCTAssertTrue(ok)
        XCTAssertEqual(received?.tenantKey, "initech", "create 缝收到 tenantKey+name（AC-2）")
        XCTAssertEqual(received?.name, "Initech")
        XCTAssertEqual(vm.tenants.count, 3, "create 成功后 count +1（AC-2）")
        XCTAssertEqual(vm.tenants.last?.tenantKey, "initech", "create 成功追加行（AC-2）")
        XCTAssertEqual(listCalls, 1, "不重拉列表（原位追加）")
    }

    func testCreateConflictKeepsListAndRetryable() async {
    // fn: M00.F01
        var reject = true
        let vm = AdminTenantsViewModel(seams: .init(
            listTenants: { self.seedList },
            createTenant: { _ in
                if reject {
                    throw ErrorResponse.error(409, nil, nil, URLError(.badServerResponse))
                }
                return self.makeTenant(id: UUID(), key: "initech", name: "Initech")
            },
            updateTenant: { _, _ in throw TenantStubError.notUsed },
            deleteTenant: { _ in throw TenantStubError.notUsed }
        ))
        _ = await vm.load()
        let ok = await vm.create(CreateTenantRequest(tenantKey: "initech", name: "Initech"))
        XCTAssertFalse(ok, "tenantKey 重复 409 = 失败（AC-3/Q3）")
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("409"), "红字带 HTTP 码（AC-4），实际：\(message)")
        } else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
        XCTAssertEqual(vm.tenants.count, 2, "失败列表不动（AC-4）")

        reject = false
        let retry = await vm.create(CreateTenantRequest(tenantKey: "initech", name: "Initech"))
        XCTAssertTrue(retry, "同一 VM 可直接重试（AC-4）")
        XCTAssertEqual(vm.tenants.last?.tenantKey, "initech")
    }

    func testUpdateReplacesRowInPlace() async {
    // fn: M00.F01
        var received: (id: UUID, request: UpdateTenantRequest)?
        let renamed = makeTenant(id: acmeID, key: "acme", name: "ACME（改名后）")
        let vm = AdminTenantsViewModel(seams: .init(
            listTenants: { self.seedList },
            createTenant: { _ in throw TenantStubError.notUsed },
            updateTenant: { id, request in
                received = (id, request)
                return renamed
            },
            deleteTenant: { _ in throw TenantStubError.notUsed }
        ))
        _ = await vm.load()
        let ok = await vm.update(acmeID, UpdateTenantRequest(name: "ACME（改名后）"))
        XCTAssertTrue(ok)
        XCTAssertEqual(received?.id, acmeID, "寻址 UUID id（Q1，非 key 非字符串）")
        XCTAssertEqual(received?.request.name, "ACME（改名后）")
        XCTAssertEqual(vm.tenants.first { $0.id == acmeID }?.name, "ACME（改名后）",
                       "update 成功原位替换行（AC-3）")
        XCTAssertEqual(vm.tenants.first { $0.id == globexID }?.name, "Globex Industries",
                       "其他行不动")
        XCTAssertEqual(vm.tenants.count, 2, "列表长度不变（原位替换非重拉）")
    }

    func testUpdateStatusUsesStringEnum() async {
    // fn: M00.F01
        var receivedStatus: TenantStatus?
        let suspended = makeTenant(id: acmeID, key: "acme", name: "ACME Corp", status: .suspended)
        let vm = AdminTenantsViewModel(seams: .init(
            listTenants: { self.seedList },
            createTenant: { _ in throw TenantStubError.notUsed },
            updateTenant: { _, request in
                receivedStatus = request.status
                return suspended
            },
            deleteTenant: { _ in throw TenantStubError.notUsed }
        ))
        _ = await vm.load()
        let ok = await vm.update(acmeID, UpdateTenantRequest(status: .suspended))
        XCTAssertTrue(ok, "停用租户成功（AC-3）")
        XCTAssertEqual(receivedStatus, .suspended, "status 走字符串枚举（Q2，非 Int）")
        XCTAssertEqual(vm.tenants.first { $0.id == acmeID }?.status, .suspended, "行随返回体刷新")
    }

    func testDeleteRemovesRowInPlace() async {
    // fn: M00.F01
        var deleted: UUID?
        let vm = AdminTenantsViewModel(seams: .init(
            listTenants: { self.seedList },
            createTenant: { _ in throw TenantStubError.notUsed },
            updateTenant: { _, _ in throw TenantStubError.notUsed },
            deleteTenant: { id in
                deleted = id
            }
        ))
        _ = await vm.load()
        let ok = await vm.deleteTenant(acmeID)
        XCTAssertTrue(ok)
        XCTAssertEqual(deleted, acmeID, "delete 缝收到 UUID id（Q1）")
        XCTAssertEqual(vm.tenants.map(\.tenantKey), ["globex"], "删除后原位移除（AC-2）")
        XCTAssertEqual(vm.tenants.count, 1, "其他行完整保留")
    }
}

/// 测试桩专用错误（缝不该被碰的用例里抛）。
private enum TenantStubError: Error {
    case notUsed
}
