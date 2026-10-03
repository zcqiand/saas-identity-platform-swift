import Foundation
import SaasSharedGenerated

// REQ-2026-008 T-1: menu admin (M04.F04 lean slice: menu CRUD + structure).
// Seams pattern same as AdminTenantsViewModel: network impl supplied by App
// layer APIGlue (generated ClientMenusAPI as the only entry), unit tests
// inject fakes. Wire facts pinned by live probe 2026-10-01 @5101:
// - clientId string addressing (same as admin/clients); menuId path param is
//   String in the generated API, VM converts with id.uuidString.
// - Flat list root parentId = zero UUID (see MenuTree.swift); the /me/menus
//   null shape is NOT in this slice.
// - status is Int (1 on / 0 off, same as OAuthClient); SysMenuType is a
//   string enum; the name field is `title`.
// Success mutates the list in place (append/replace/remove; reorder re-sorts
// locally without reload); failure only sets phase to a red message, list
// untouched and retryable. Delete confirmation lives in the App layer.

/// Menu admin state machine: load per client -> create/update/move/reorder/delete.
@MainActor
public final class MenusViewModel: ObservableObject {

    public struct Seams {
        public var listMenus: (_ clientId: String) async throws -> [SysMenu]
        public var createMenu: (_ clientId: String, _ request: CreateSysMenuRequest) async throws -> SysMenu
        public var updateMenu: (_ clientId: String, _ menuId: String, _ request: UpdateSysMenuRequest) async throws -> SysMenu
        public var moveMenu: (_ clientId: String, _ menuId: String, _ parentId: String?) async throws -> SysMenu
        public var reorderMenus: (_ clientId: String, _ menuId: String, _ orderedMenuIds: [String]) async throws -> [SysMenu]
        public var deleteMenu: (_ clientId: String, _ menuId: String) async throws -> Void

        public init(
            listMenus: @escaping (_ clientId: String) async throws -> [SysMenu] = { _ in throw SessionStoreError("listMenus seam not injected") },
            createMenu: @escaping (_ clientId: String, _ request: CreateSysMenuRequest) async throws -> SysMenu = { _, _ in throw SessionStoreError("createMenu seam not injected") },
            updateMenu: @escaping (_ clientId: String, _ menuId: String, _ request: UpdateSysMenuRequest) async throws -> SysMenu = { _, _, _ in throw SessionStoreError("updateMenu seam not injected") },
            moveMenu: @escaping (_ clientId: String, _ menuId: String, _ parentId: String?) async throws -> SysMenu = { _, _, _ in throw SessionStoreError("moveMenu seam not injected") },
            reorderMenus: @escaping (_ clientId: String, _ menuId: String, _ orderedMenuIds: [String]) async throws -> [SysMenu] = { _, _, _ in throw SessionStoreError("reorderMenus seam not injected") },
            deleteMenu: @escaping (_ clientId: String, _ menuId: String) async throws -> Void = { _, _ in throw SessionStoreError("deleteMenu seam not injected") }
        ) {
            self.listMenus = listMenus
            self.createMenu = createMenu
            self.updateMenu = updateMenu
            self.moveMenu = moveMenu
            self.reorderMenus = reorderMenus
            self.deleteMenu = deleteMenu
        }
    }

    public enum Phase: Equatable {
        case idle
        case busy
        case failed(String)
    }

    /// Current client (set by load; all op seams address through it).
    public private(set) var clientId: String?
    @Published public private(set) var menus: [SysMenu] = []
    @Published public private(set) var phase: Phase = .idle

    private let seams: Seams

    public init(seams: Seams) {
        self.seams = seams
    }

    /// Tree view for UI (zero UUID = root, sortOrder ascending).
    public var tree: [MenuNode] {
        buildMenuTree(from: menus)
    }

    // @impl M04.F04.I01 — 菜单列表（扁平清单，ch37 只读消费）
    /// Fetch the flat menu list for one client.
    @discardableResult
    public func load(clientId: String) async -> Bool {
        phase = .busy
        do {
            let list = try await seams.listMenus(clientId)
            self.clientId = clientId
            menus = list
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// Create a menu (no parentId = root). Success appends the row (no reload).
    @discardableResult
    public func create(_ request: CreateSysMenuRequest) async -> Bool {
        guard let clientId else {
            phase = .failed("no client selected")
            return false
        }
        phase = .busy
        do {
            let created = try await seams.createMenu(clientId, request)
            menus.append(created)
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// Update a menu (partial request). Success replaces the row in place.
    @discardableResult
    public func update(menuId: String, request: UpdateSysMenuRequest) async -> Bool {
        guard let clientId else {
            phase = .failed("no client selected")
            return false
        }
        phase = .busy
        do {
            let updated = try await seams.updateMenu(clientId, menuId, request)
            if let index = menus.firstIndex(where: { $0.id.uuidString == menuId }) {
                menus[index] = updated
            }
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// Move under a new parent (nil = back to root). Success replaces the row
    /// in place (server returns the SysMenu with the new parentId).
    @discardableResult
    public func move(menuId: String, parentId: String?) async -> Bool {
        guard let clientId else {
            phase = .failed("no client selected")
            return false
        }
        phase = .busy
        do {
            let moved = try await seams.moveMenu(clientId, menuId, parentId)
            if let index = menus.firstIndex(where: { $0.id.uuidString == menuId }) {
                menus[index] = moved
            }
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// Reorder one sibling segment (submit the full orderedMenuIds). After
    /// success re-sort that segment's sortOrder locally (server returns an
    /// empty array, Q4), no reload.
    @discardableResult
    public func reorder(parentMenuId: String, orderedMenuIds: [String]) async -> Bool {
        guard let clientId else {
            phase = .failed("no client selected")
            return false
        }
        phase = .busy
        do {
            _ = try await seams.reorderMenus(clientId, parentMenuId, orderedMenuIds)
            for (index, id) in orderedMenuIds.enumerated() {
                if let row = menus.firstIndex(where: { $0.id.uuidString == id }) {
                    menus[row].sortOrder = index + 1
                }
            }
            phase = .idle
            return true
        } catch {
            phase = .failed(Self.message(of: error))
            return false
        }
    }

    /// Delete a menu. Success removes the row in place.
    @discardableResult
    public func deleteMenu(_ menuId: String) async -> Bool {
        guard let clientId else {
            phase = .failed("no client selected")
            return false
        }
        phase = .busy
        do {
            try await seams.deleteMenu(clientId, menuId)
            menus.removeAll { $0.id.uuidString == menuId }
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
