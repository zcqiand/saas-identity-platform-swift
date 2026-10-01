import XCTest
import SaasSharedGenerated
@testable import CoreKit

/// REQ-2026-008 T-1: MenusViewModel (M04.F04 lean slice: menu CRUD + tree).
/// Seams pattern: CoreKit owns the state machine, network impl injected by
/// App-layer APIGlue (generated ClientMenusAPI only entry), unit tests inject
/// fakes. Wire facts pinned by live probe 2026-10-01 @5101: clientId string
/// addressing, menuId String path param, flat list root parentId = zero UUID,
/// status Int, reorder returns 200 [] and silently ignores unknown ids.
/// Success mutates the list in place; failure sets red phase, list untouched.
@MainActor
final class MenusViewModelTests: XCTestCase {

    private let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private let dashboardID = UUID(uuidString: "00000000-0000-0000-0000-910000000001")!
    private let resourceID = UUID(uuidString: "00000000-0000-0000-0000-910000000002")!
    private let contractID = UUID(uuidString: "00000000-0000-0000-0000-910000000003")!
    private let reportID = UUID(uuidString: "00000000-0000-0000-0000-910000000004")!

    private func makeMenu(
        id: UUID, parentId: UUID, title: String, type: SysMenuType = .menu,
        sortOrder: Int, status: Int = 1, path: String? = nil
    ) -> SysMenu {
        SysMenu(
            id: id, clientId: "lab-management", parentId: parentId, title: title,
            type: type, path: path, sortOrder: sortOrder, status: status,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// Live seed shape: two roots (zero-UUID parent) + one child.
    private var seedList: [SysMenu] {
        [
            makeMenu(id: dashboardID, parentId: zero, title: "Dashboard", sortOrder: 1, path: "dashboard"),
            makeMenu(id: resourceID, parentId: zero, title: "Resources", type: .directory, sortOrder: 2),
            makeMenu(id: contractID, parentId: resourceID, title: "Contracts", sortOrder: 1, path: "contracts"),
        ]
    }

    private var flatTitles: [String] {
        seedList.map(\.title)
    }

    func testLoadPopulatesMenusAndBuildsTree() async {
    // fn: M04.F04
        var listCalls = 0
        let vm = MenusViewModel(seams: .init(
            listMenus: { clientId in
                XCTAssertEqual(clientId, "lab-management", "clientId string addressing (Q1)")
                listCalls += 1
                return self.seedList
            }
        ))
        let ok = await vm.load(clientId: "lab-management")
        XCTAssertTrue(ok)
        XCTAssertTrue(listCalls == 1)
        XCTAssertEqual(vm.menus.map(\.title), flatTitles, "flat list kept as-is (AC-1)")
        let tree = vm.tree
        XCTAssertEqual(tree.map(\.menu.title), ["Dashboard", "Resources"], "zero UUID = root, sortOrder asc")
        XCTAssertEqual(tree[1].children.map(\.menu.title), ["Contracts"], "child nested under directory")
        XCTAssertEqual(vm.phase, .idle)
    }

    func testLoadFailureKeepsEmptyAndRetryable() async {
    // fn: M04.F04
        var reject = true
        let vm = MenusViewModel(seams: .init(
            listMenus: { _ in
                if reject {
                    throw ErrorResponse.error(403, nil, nil, URLError(.userAuthenticationRequired))
                }
                return self.seedList
            }
        ))
        let ok = await vm.load(clientId: "lab-management")
        XCTAssertFalse(ok, "403 = failure (AC-4)")
        if case .failed(let message) = vm.phase {
            XCTAssertTrue(message.contains("403"), "red text carries HTTP code, got: \(message)")
        } else {
            XCTFail("phase should be failed, got \(vm.phase)")
        }
        XCTAssertTrue(vm.menus.isEmpty, "no fake data on failure")

        reject = false
        let retried = await vm.load(clientId: "lab-management")
        XCTAssertTrue(retried, "retryable (AC-4)")
        XCTAssertEqual(vm.menus.count, 3)
    }

    func testCreateAppendsRowAndTreesUnderParent() async {
    // fn: M04.F04
        let created = makeMenu(id: reportID, parentId: resourceID, title: "Reports", sortOrder: 2, path: "reports")
        let vm = MenusViewModel(seams: .init(
            listMenus: { _ in self.seedList },
            createMenu: { clientId, request in
                XCTAssertEqual(clientId, "lab-management")
                XCTAssertEqual(request.title, "Reports")
                XCTAssertEqual(request.parentId, self.resourceID, "create under directory carries parentId")
                return created
            }
        ))
        _ = await vm.load(clientId: "lab-management")
        let ok = await vm.create(CreateSysMenuRequest(
            parentId: resourceID, title: "Reports", type: .menu, path: "reports", sortOrder: 2
        ))
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.menus.count, 4, "append in place, no reload (AC-2)")
        let resource = vm.tree.first { $0.menu.id == resourceID }
        XCTAssertEqual(resource?.children.map(\.menu.title), ["Contracts", "Reports"], "tree re-sorts by sortOrder")
        XCTAssertEqual(vm.phase, .idle)
    }

    func testUpdateReplacesRowInPlace() async {
    // fn: M04.F04
        var patchCalls = 0
        let renamed = makeMenu(id: contractID, parentId: resourceID, title: "Contracts v2", sortOrder: 1, status: 0, path: "contracts")
        let vm = MenusViewModel(seams: .init(
            listMenus: { _ in self.seedList },
            updateMenu: { clientId, menuId, request in
                XCTAssertEqual(clientId, "lab-management")
                XCTAssertEqual(menuId, self.contractID.uuidString, "menuId addressed as String path param")
                XCTAssertEqual(request.title, "Contracts v2")
                patchCalls += 1
                return renamed
            }
        ))
        _ = await vm.load(clientId: "lab-management")
        let ok = await vm.update(menuId: contractID.uuidString, request: UpdateSysMenuRequest(title: "Contracts v2", status: 0))
        XCTAssertTrue(ok)
        XCTAssertTrue(patchCalls == 1)
        XCTAssertEqual(vm.menus.count, 3, "no reload")
        XCTAssertEqual(vm.menus.first { $0.id == contractID }?.title, "Contracts v2", "row replaced in place (AC-3)")
        XCTAssertEqual(vm.menus.first { $0.id == contractID }?.status, 0)
    }

    func testMoveReplacesRowParentId() async {
    // fn: M04.F04
        let moved = makeMenu(id: dashboardID, parentId: resourceID, title: "Dashboard", sortOrder: 3, path: "dashboard")
        let vm = MenusViewModel(seams: .init(
            listMenus: { _ in self.seedList },
            moveMenu: { clientId, menuId, parentId in
                XCTAssertEqual(clientId, "lab-management")
                XCTAssertEqual(menuId, self.dashboardID.uuidString)
                XCTAssertEqual(parentId, self.resourceID.uuidString, "move carries target parent as String?")
                return moved
            }
        ))
        _ = await vm.load(clientId: "lab-management")
        let ok = await vm.move(menuId: dashboardID.uuidString, parentId: resourceID.uuidString)
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.menus.first { $0.id == dashboardID }?.parentId, resourceID, "row parentId updated in place (AC-3)")
        let resource = vm.tree.first { $0.menu.id == resourceID }
        XCTAssertEqual(resource?.children.map(\.menu.title), ["Contracts", "Dashboard"], "tree re-nests after move")
    }

    func testMoveToRootSendsNilAndUnnests() async {
    // fn: M04.F04
        let moved = makeMenu(id: contractID, parentId: zero, title: "Contracts", sortOrder: 3, path: "contracts")
        let vm = MenusViewModel(seams: .init(
            listMenus: { _ in self.seedList },
            moveMenu: { clientId, _, parentId in
                XCTAssertNil(parentId, "move to root sends null parentId (live: move PATCH parentId null)")
                return moved
            }
        ))
        _ = await vm.load(clientId: "lab-management")
        let ok = await vm.move(menuId: contractID.uuidString, parentId: nil)
        XCTAssertTrue(ok)
        XCTAssertEqual(vm.tree.map(\.menu.title), ["Dashboard", "Resources", "Contracts"], "un-nested to root")
    }

    func testReorderReassignsSiblingSortOrderLocally() async {
    // fn: M04.F04
        var reorderCalls = 0
        // Post-move fixture: two siblings already under Resources
        // (Contracts sortOrder 1, Dashboard sortOrder 2).
        let list: [SysMenu] = [
            makeMenu(id: resourceID, parentId: zero, title: "Resources", type: .directory, sortOrder: 1),
            makeMenu(id: contractID, parentId: resourceID, title: "Contracts", sortOrder: 1, path: "contracts"),
            makeMenu(id: dashboardID, parentId: resourceID, title: "Dashboard", sortOrder: 2, path: "dashboard"),
        ]
        let vm = MenusViewModel(seams: .init(
            listMenus: { _ in list },
            reorderMenus: { clientId, menuId, orderedMenuIds in
                XCTAssertEqual(clientId, "lab-management")
                XCTAssertEqual(menuId, self.resourceID.uuidString, "reorder addressed at the parent directory")
                XCTAssertEqual(orderedMenuIds, [self.dashboardID.uuidString, self.contractID.uuidString], "full sibling segment submitted (Q4)")
                reorderCalls += 1
                return []
            }
        ))
        _ = await vm.load(clientId: "lab-management")
        let ok = await vm.reorder(
            parentMenuId: resourceID.uuidString,
            orderedMenuIds: [dashboardID.uuidString, contractID.uuidString]
        )
        XCTAssertTrue(ok)
        XCTAssertTrue(reorderCalls == 1)
        XCTAssertEqual(vm.menus.first { $0.id == dashboardID }?.sortOrder, 1, "local sortOrder reassigned per submitted order (Q4)")
        XCTAssertEqual(vm.menus.first { $0.id == contractID }?.sortOrder, 2)
        let resource = vm.tree.first { $0.menu.id == resourceID }
        XCTAssertEqual(resource?.children.map(\.menu.title), ["Dashboard", "Contracts"], "tree order flips after reorder")
    }

    func testDeleteRemovesRow() async {
    // fn: M04.F04
        var deleteCalls = 0
        let vm = MenusViewModel(seams: .init(
            listMenus: { _ in self.seedList },
            deleteMenu: { clientId, menuId in
                XCTAssertEqual(clientId, "lab-management")
                XCTAssertEqual(menuId, self.contractID.uuidString)
                deleteCalls += 1
            }
        ))
        _ = await vm.load(clientId: "lab-management")
        let ok = await vm.deleteMenu(contractID.uuidString)
        XCTAssertTrue(ok)
        XCTAssertTrue(deleteCalls == 1)
        XCTAssertEqual(vm.menus.count, 2, "row removed in place (AC-2)")
        XCTAssertFalse(vm.menus.contains { $0.id == contractID })
    }

    func testOpWithoutClientFailsFast() async {
    // fn: M04.F04
        let vm = MenusViewModel(seams: .init())
        let ok = await vm.create(CreateSysMenuRequest(title: "x", type: .menu))
        XCTAssertFalse(ok, "no client selected = fail-fast, no seam call")
        if case .failed(let message) = vm.phase {
            XCTAssertFalse(message.isEmpty)
        } else {
            XCTFail("phase should be failed, got \(vm.phase)")
        }
    }
}
