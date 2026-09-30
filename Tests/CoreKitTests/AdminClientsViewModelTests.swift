import XCTest
import SaasSharedGenerated
@testable import CoreKit

/// REQ-2026-005 T-1：应用维护 ViewModel（OAuth client CRUD）。
/// Seams 模式同 MembersViewModel/OAuthViewModel：CoreKit 只管状态机，网络实现
/// 由 App 层 APIGlue（生成物 AdminClientsAPI 唯一入口）供（T-2），单测注入 fake。
/// list 不传分页（Q1：live 实证 0-indexed，nil 全量）；delete 是危险操作走确认
/// 流（AC-4）；create/update 成功用返回的 OAuthClient 原位更新，失败红字列表
/// 不动可重试（AC-5）。
@MainActor
final class AdminClientsViewModelTests: XCTestCase {

    private let erpID = UUID(uuidString: "11111111-1111-1111-1111-111111111112")!
    private let crmID = UUID(uuidString: "11111111-1111-1111-1111-111111111113")!

    private func makeClient(
        id: UUID, clientId: String, name: String, status: Int = 1
    ) -> OAuthClient {
        OAuthClient(
            id: id, clientId: clientId, clientName: name,
            grantTypes: "authorization_code,refresh_token",
            redirectUris: "https://app.example.invalid/login",
            scopes: "openid,profile",
            accessTokenValidity: 3600, refreshTokenValidity: 604800,
            autoApprove: false, status: status,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private var seedList: AdminClientsListClients200Response {
        AdminClientsListClients200Response(
            items: [
                makeClient(id: erpID, clientId: "erp", name: "企业资源计划系统"),
                makeClient(id: crmID, clientId: "crm", name: "客户关系管理系统"),
            ],
            page: 1, pageSize: 20, total: 2
        )
    }

    func testLoadPopulatesClientsWithoutPaging() async {
    // fn: M04.F01
        var listCalled = false
        let vm = AdminClientsViewModel(seams: .init(
            listClients: {
                listCalled = true
                return self.seedList
            },
            getClient: { _ in throw SeamStubError.notUsed },
            createClient: { _ in throw SeamStubError.notUsed },
            updateClient: { _, _ in throw SeamStubError.notUsed },
            deleteClient: { _ in throw SeamStubError.notUsed }
        ))
        let ok = await vm.load()
        XCTAssertTrue(ok, "nil 全量拉取（Q1：分页 0-indexed，传 nil）")
        XCTAssertTrue(listCalled)
        XCTAssertEqual(vm.clients.map(\.clientId), ["erp", "crm"], "列表全量渲染（AC-1）")
        XCTAssertEqual(vm.phase, .idle)
    }

    func testLoadFailureKeepsEmptyAndRetryable() async {
    // fn: M04.F01
        var reject = true
        let vm = AdminClientsViewModel(seams: .init(
            listClients: {
                if reject {
                    throw ErrorResponse.error(403, nil, nil, URLError(.userAuthenticationRequired))
                }
                return self.seedList
            },
            getClient: { _ in throw SeamStubError.notUsed },
            createClient: { _ in throw SeamStubError.notUsed },
            updateClient: { _, _ in throw SeamStubError.notUsed },
            deleteClient: { _ in throw SeamStubError.notUsed }
        ))
        let ok = await vm.load()
        XCTAssertFalse(ok, "403 = 失败（AC-5）")
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("403"), "红字带 HTTP 码，实际：\(message)")
        } else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
        XCTAssertTrue(vm.clients.isEmpty, "失败不发假数据")

        reject = false
        let retry = await vm.load()
        XCTAssertTrue(retry, "同一 VM 可直接重试（AC-5 可重试）")
        XCTAssertEqual(vm.clients.count, 2)
    }

    func testCreateAppendsRowInPlaceWithoutReload() async {
    // fn: M04.F01
        var listCalls = 0
        var received: CreateOAuthClientRequest?
        let created = makeClient(id: UUID(), clientId: "new-app", name: "新应用")
        let vm = AdminClientsViewModel(seams: .init(
            listClients: { listCalls += 1; return self.seedList },
            getClient: { _ in throw SeamStubError.notUsed },
            createClient: { request in
                received = request
                return created
            },
            updateClient: { _, _ in throw SeamStubError.notUsed },
            deleteClient: { _ in throw SeamStubError.notUsed }
        ))
        _ = await vm.load()
        let request = CreateOAuthClientRequest(
            clientId: "new-app", clientName: "新应用", clientSecret: "s3cret",
            grantTypes: "authorization_code", redirectUris: "https://new.example.invalid/login",
            scopes: "openid"
        )
        let ok = await vm.create(request)
        XCTAssertTrue(ok)
        XCTAssertEqual(received?.clientId, "new-app", "create 缝收到完整请求（AC-4）")
        XCTAssertEqual(received?.clientSecret, "s3cret", "secret 必填录入（Q2）")
        XCTAssertEqual(vm.clients.count, 3, "create 成功后 count +1（AC-4）")
        XCTAssertEqual(vm.clients.last?.clientId, "new-app", "create 成功追加行（AC-4）")
        XCTAssertEqual(listCalls, 1, "不重拉列表（原位追加）")
    }

    func testCreateFailureKeepsListAndRetryable() async {
    // fn: M04.F01
        var reject = true
        let vm = AdminClientsViewModel(seams: .init(
            listClients: { self.seedList },
            getClient: { _ in throw SeamStubError.notUsed },
            createClient: { _ in
                if reject {
                    throw ErrorResponse.error(400, nil, nil, URLError(.badServerResponse))
                }
                return self.makeClient(id: UUID(), clientId: "new-app", name: "新应用")
            },
            updateClient: { _, _ in throw SeamStubError.notUsed },
            deleteClient: { _ in throw SeamStubError.notUsed }
        ))
        _ = await vm.load()
        let request = CreateOAuthClientRequest(
            clientId: "new-app", clientName: "新应用", clientSecret: "s3cret",
            grantTypes: "authorization_code", redirectUris: "https://new.example.invalid/login"
        )
        let ok = await vm.create(request)
        XCTAssertFalse(ok)
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("400"), "红字带 HTTP 码（AC-5），实际：\(message)")
        } else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
        XCTAssertEqual(vm.clients.count, 2, "失败列表不动（AC-5）")

        reject = false
        let retry = await vm.create(request)
        XCTAssertTrue(retry, "同一 VM 可直接重试（AC-5）")
        XCTAssertEqual(vm.clients.last?.clientId, "new-app")
    }

    func testUpdateReplacesRowInPlace() async {
    // fn: M04.F01
        var received: (clientId: String, request: UpdateOAuthClientRequest)?
        let renamed = makeClient(id: erpID, clientId: "erp", name: "ERP（改名后）")
        let vm = AdminClientsViewModel(seams: .init(
            listClients: { self.seedList },
            getClient: { _ in throw SeamStubError.notUsed },
            createClient: { _ in throw SeamStubError.notUsed },
            updateClient: { clientId, request in
                received = (clientId, request)
                return renamed
            },
            deleteClient: { _ in throw SeamStubError.notUsed }
        ))
        _ = await vm.load()
        let request = UpdateOAuthClientRequest(clientName: "ERP（改名后）")
        let ok = await vm.update("erp", request)
        XCTAssertTrue(ok)
        XCTAssertEqual(received?.clientId, "erp")
        XCTAssertEqual(received?.request.clientName, "ERP（改名后）")
        XCTAssertEqual(vm.clients.first { $0.clientId == "erp" }?.clientName, "ERP（改名后）",
                       "update 成功原位替换行（AC-3）")
        XCTAssertEqual(vm.clients.first { $0.clientId == "crm" }?.clientName, "客户关系管理系统",
                       "其他行不动")
        XCTAssertEqual(vm.clients.count, 2, "列表长度不变（原位替换非重拉）")
    }

    func testUpdateFailureKeepsRowAndReports() async {
    // fn: M04.F01
        var reject = true
        let vm = AdminClientsViewModel(seams: .init(
            listClients: { self.seedList },
            getClient: { _ in throw SeamStubError.notUsed },
            createClient: { _ in throw SeamStubError.notUsed },
            updateClient: { _, _ in
                if reject {
                    throw ErrorResponse.error(500, nil, nil, URLError(.badServerResponse))
                }
                return self.makeClient(id: self.erpID, clientId: "erp", name: "ERP（改名后）")
            },
            deleteClient: { _ in throw SeamStubError.notUsed }
        ))
        _ = await vm.load()
        let ok = await vm.update("erp", UpdateOAuthClientRequest(clientName: "ERP（改名后）"))
        XCTAssertFalse(ok)
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("500"), "红字带 HTTP 码（AC-5），实际：\(message)")
        } else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
        XCTAssertEqual(vm.clients.first { $0.clientId == "erp" }?.clientName, "企业资源计划系统",
                       "失败行不动（AC-5）")

        reject = false
        let retry = await vm.update("erp", UpdateOAuthClientRequest(clientName: "ERP（改名后）"))
        XCTAssertTrue(retry)
        XCTAssertEqual(vm.clients.first { $0.clientId == "erp" }?.clientName, "ERP（改名后）")
    }

    func testDeleteRemovesRowInPlace() async {
    // fn: M04.F01
        var deleted: String?
        let vm = AdminClientsViewModel(seams: .init(
            listClients: { self.seedList },
            getClient: { _ in throw SeamStubError.notUsed },
            createClient: { _ in throw SeamStubError.notUsed },
            updateClient: { _, _ in throw SeamStubError.notUsed },
            deleteClient: { clientId in
                deleted = clientId
            }
        ))
        _ = await vm.load()
        let ok = await vm.deleteClient("erp")
        XCTAssertTrue(ok)
        XCTAssertEqual(deleted, "erp", "delete 缝收到 clientId（AC-4）")
        XCTAssertEqual(vm.clients.map(\.clientId), ["crm"], "删除后原位移除（AC-4）")
        XCTAssertEqual(vm.clients.count, 1, "其他行完整保留")
    }

    func testDeleteFailureKeepsRowAndRetryable() async {
    // fn: M04.F01
        var reject = true
        let vm = AdminClientsViewModel(seams: .init(
            listClients: { self.seedList },
            getClient: { _ in throw SeamStubError.notUsed },
            createClient: { _ in throw SeamStubError.notUsed },
            updateClient: { _, _ in throw SeamStubError.notUsed },
            deleteClient: { _ in
                if reject {
                    throw ErrorResponse.error(409, nil, nil, URLError(.badServerResponse))
                }
            }
        ))
        _ = await vm.load()
        let ok = await vm.deleteClient("erp")
        XCTAssertFalse(ok)
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("409"), "红字带 HTTP 码（AC-5），实际：\(message)")
        } else {
            XCTFail("phase 应为 failed，实际 \(vm.phase)")
        }
        XCTAssertEqual(vm.clients.map(\.clientId), ["erp", "crm"], "失败行不动（AC-5）")

        reject = false
        let retry = await vm.deleteClient("erp")
        XCTAssertTrue(retry, "同一 VM 可直接重试（AC-5）")
        XCTAssertEqual(vm.clients.map(\.clientId), ["crm"])
    }
}

/// 测试桩专用错误（缝不该被碰的用例里抛）。
private enum SeamStubError: Error {
    case notUsed
}
