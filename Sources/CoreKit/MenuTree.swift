import Foundation
import SaasSharedGenerated

// REQ-2026-008 T-1：菜单组树（M04.F04 菜单管理切片）。
// 平铺 [SysMenu] → 树。口径（live 探针实证 2026-10-01 @5101）：
// - CRUD 平铺列表根节点 parentId = 零值 UUID（…0000），与 /me/menus 的
//   null 是两套口径（后者生成物解码必炸，本切片排除，shared requiredMode
//   修正另立提案走人工批）。
// - 兄弟按 sortOrder 升序；同序 tie-break 按 title（确定性渲染）。
// - 孤儿（父不在集合内）挂根，不让数据无声消失（服务端孤儿只在并发删除时
//   瞬时出现）。

/// 树节点：menu + 有序 children。
public struct MenuNode: Equatable, Identifiable {
    public let menu: SysMenu
    public let children: [MenuNode]

    /// SwiftUI OutlineGroup 需要 Identifiable。
    public var id: UUID { menu.id }

    /// OutlineGroup 的 children keyPath 要求可选（nil = 叶子）。
    public var childNodes: [MenuNode]? {
        children.isEmpty ? nil : children
    }

    public init(menu: SysMenu, children: [MenuNode]) {
        self.menu = menu
        self.children = children
    }
}

/// 组树：零值 UUID = 根；兄弟 sortOrder 升序，tie-break title；孤儿挂根。
public func buildMenuTree(from menus: [SysMenu]) -> [MenuNode] {
    let rootSentinel = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    let byId = Dictionary(uniqueKeysWithValues: menus.map { ($0.id, $0) })
    var childrenByParent: [UUID: [SysMenu]] = [:]
    var roots: [SysMenu] = []

    for menu in menus {
        if menu.parentId == rootSentinel || byId[menu.parentId] == nil {
            roots.append(menu)
        } else {
            childrenByParent[menu.parentId, default: []].append(menu)
        }
    }

    func node(_ menu: SysMenu) -> MenuNode {
        MenuNode(
            menu: menu,
            children: (childrenByParent[menu.id] ?? []).sorted {
                ($0.sortOrder, $0.title) < ($1.sortOrder, $1.title)
            }.map(node)
        )
    }

    return roots.sorted {
        ($0.sortOrder, $0.title) < ($1.sortOrder, $1.title)
    }.map(node)
}
