import CoreKit
import SaasSharedGenerated
import SwiftUI

// REQ-2026-008 T-2 (M04.F04, AC-1~AC-6): menu admin UI. Entry from AccountView
// platform-admin section. Client Picker (fed by AdminClientsViewModel) + menu
// tree (CoreKit buildMenuTree: zero UUID = root, sortOrder asc) with create /
// edit / move / sibling reorder / delete. Data flow lives in MenusViewModel;
// this layer only renders and forwards. API surface = generated only.
// Wire facts pinned by live probe 2026-10-01 @5101: clientId string addressing,
// menuId String path param, reorder returns 200 [] and ignores unknown ids,
// root-level reorder has no parent path id -> sibling move only for non-root
// nodes (root segment has no parent path id, contract shape).

private let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

struct MenusAdminView: View {
    @StateObject private var vm: MenusViewModel
    @StateObject private var clientsVM: AdminClientsViewModel
    @State private var selectedClientId: String = ""
    @State private var showCreate = false

    init() {
        _vm = StateObject(wrappedValue: MenusViewModel(seams: .init(
            listMenus: APIGlue.listMenus,
            createMenu: APIGlue.createMenu,
            updateMenu: APIGlue.updateMenu,
            moveMenu: APIGlue.moveMenu,
            reorderMenus: APIGlue.reorderMenus,
            deleteMenu: APIGlue.deleteMenu
        )))
        _clientsVM = StateObject(wrappedValue: AdminClientsViewModel(seams: .init(
            listClients: APIGlue.listClients
        )))
        _selectedClientId = State(initialValue: "")
    }

    var body: some View {
        List {
            Section {
                Picker("Client", selection: $selectedClientId) {
                    if selectedClientId.isEmpty {
                        Text("选择 client").tag("")
                    }
                    ForEach(clientsVM.clients, id: \.clientId) { client in
                        Text(client.clientId).tag(client.clientId)
                    }
                }
                .onChange(of: selectedClientId) { _, newValue in
                    guard !newValue.isEmpty else { return }
                    Task { _ = await vm.load(clientId: newValue) }
                }
                if vm.menus.isEmpty {
                    Text(vm.phase == .busy ? "加载中…" : "该 client 无菜单")
                        .foregroundStyle(.secondary)
                  }
            } header: {
                Text("菜单（client 维度）")
            } footer: {
                Text("共 \(vm.menus.count) 条 · 树由前端组（零值 UUID=根，sortOrder 排序）· 兄弟排序：行内长按 上移/下移（根级不提供——契约 reorder 以父菜单 id 寻址）")
            }

            List {
                OutlineGroup(vm.tree, children: \.childNodes) { node in
                    NavigationLink {
                        MenuEditView(vm: vm, node: node)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.menu.title)
                                Text("\(node.menu.type.rawValue) · \(node.menu.path ?? "—")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            statusBadge(node.menu.status)
                        }
                    }
                    .contextMenu {
                        if node.menu.parentId != zeroUUID {
                            Button("上移") { reorderSibling(node.menu, delta: -1) }
                            Button("下移") { reorderSibling(node.menu, delta: +1) }
                        }
                    }
                }
            }
            if case .failed(let message) = vm.phase {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("菜单管理")
        .toolbar {
            Button("新建菜单") { showCreate = true }
                .disabled(selectedClientId.isEmpty)
            }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                MenuCreateView(vm: vm, clientId: selectedClientId)
            }
        }
        .task {
            await clientsVM.load()
        }
    }

    private func statusBadge(_ status: Int) -> some View {
        Text(status == 1 ? "启用" : "停用")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(status == 1 ? Color.green.opacity(0.15) : Color.gray.opacity(0.2))
            .foregroundStyle(status == 1 ? Color.green : Color.secondary)
            .clipShape(Capsule())
    }

    /// Sibling segment of one menu (flat list filtered by parentId, sorted like
    /// the tree does: sortOrder asc, title tie-break). Root nodes have no
    /// parent path id -> reorder not offered at root level.
    private func siblings(of menu: SysMenu) -> [SysMenu] {
        vm.menus.filter { $0.parentId == menu.parentId }.sorted {
            ($0.sortOrder, $0.title) < ($1.sortOrder, $1.title)
        }
    }

    private func reorderSibling(_ menu: SysMenu, delta: Int) {
        let segment = siblings(of: menu)
        guard let index = segment.firstIndex(where: { $0.id == menu.id }) else { return }
        let target = index + delta
        guard segment.indices.contains(target) else { return }
        var ids = segment.map(\.id.uuidString)
        ids.swapAt(index, target)
        Task {
            _ = await vm.reorder(parentMenuId: menu.parentId.uuidString, orderedMenuIds: ids)
        }
    }
}

/// Edit + move + delete (AC-3): title/path/status + parent Picker (root or a
/// directory). Parent change goes through the verified move seam (PATCH parent),
/// field edits through update (PATCH partial); both verified live 2026-10-01.
struct MenuEditView: View {
    @ObservedObject var vm: MenusViewModel
    let node: MenuNode

    @State private var title = ""
    @State private var path = ""
    @State private var status = 1
    @State private var parentId: String = ""
    @State private var showDeleteConfirm = false
    @Environment(\.dismiss) private var dismiss

    /// vm.menus is the single source of truth (in-place ops stale the nav snapshot).
    private var current: SysMenu {
        vm.menus.first { $0.id == node.menu.id } ?? node.menu
    }

    /// Parent options: root + every directory except the node itself
    /// (avoid trivial cycles; descendant filtering kept out of scope).
    private var parentOptions: [SysMenu] {
        vm.menus.filter { $0.type == .directory && $0.id != current.id }
    }

    var body: some View {
        Form {
            Section("详情（只读）") {
                LabeledContent("id", value: current.id.uuidString)
                    .font(.footnote.monospaced())
                LabeledContent("clientId", value: current.clientId)
                    .font(.footnote.monospaced())
                LabeledContent("type", value: current.type.rawValue)
            }
            Section {
                TextField("标题", text: $title)
                TextField("路径（可空）", text: $path)
                Picker("状态", selection: $status) {
                    Text("启用").tag(1)
                    Text("停用").tag(0)
                }
                Button("保存") {
                    Task {
                        let parentChanged = parentId != current.parentId.uuidString
                        if parentChanged {
                            let target = parentId == "" ? nil : parentId
                            guard await vm.move(menuId: current.id.uuidString, parentId: target) else { return }
                        }
                        if await vm.update(menuId: current.id.uuidString, request: UpdateSysMenuRequest(
                            title: title,
                            path: path.isEmpty ? nil : path,
                            status: status
                        )) {
                            dismiss()
                        }
                    }
                }
                .disabled(vm.phase == .busy)
            } header: {
                Text("编辑")
            } footer: {
                Text("父节点变更走 move 缝（PATCH parent）；其余字段走 update（PATCH partial）")
            }
            Section {
                Button("删除菜单", role: .destructive) {
                    showDeleteConfirm = true
                }
                .disabled(vm.phase == .busy)
                .confirmationDialog(
                    "删除 \(current.title)？",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("删除", role: .destructive) {
                        Task {
                            if await vm.deleteMenu(current.id.uuidString) {
                                dismiss()
                            }
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("子菜单将失去父级（渲染时挂根），不可恢复")
                }
            } footer: {
                Text("删除是危险操作，不可恢复")
            }
            if case .failed(let message) = vm.phase {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(current.title)
        .onAppear {
            title = current.title
            path = current.path ?? ""
            status = current.status
            parentId = current.parentId == zeroUUID ? "" : current.parentId.uuidString
        }
    }
}

/// Create menu (AC-2): title + type required (contract), parentId empty = root.
struct MenuCreateView: View {
    @ObservedObject var vm: MenusViewModel
    let clientId: String

    @State private var title = ""
    @Environment(\.dismiss) private var dismiss
    @State private var type: SysMenuType = .menu
    @State private var path = ""
    @State private var parentKey = ""   // "" = root, else directory id string
    @State private var sortOrderText = "1"

    private var formValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var parentOptions: [SysMenu] {
        vm.menus.filter { $0.type == .directory }
    }

    var body: some View {
        Form {
            Section {
                TextField("标题", text: $title)
                Picker("类型", selection: $type) {
                    Text("目录 directory").tag(SysMenuType.directory)
                    Text("菜单 menu").tag(SysMenuType.menu)
                    Text("按钮 button").tag(SysMenuType.button)
                }
                TextField("路径（可空）", text: $path)
                Picker("父菜单", selection: $parentKey) {
                    Text("根").tag("")
                    ForEach(parentOptions, id: \.id) { directory in
                        Text(directory.title).tag(directory.id.uuidString)
                    }
                }
                TextField("排序值", text: $sortOrderText)
            } header: {
                Text("新建菜单")
            } footer: {
                Text("父菜单选「根」= 平铺列表的零值 UUID；创建后原位追加进树")
            }
            Section {
                Button("创建") {
                    Task {
                        let parentId = parentKey.isEmpty ? nil : UUID(uuidString: parentKey)
                        if await vm.create(CreateSysMenuRequest(
                            parentId: parentId,
                            title: title.trimmingCharacters(in: .whitespaces),
                            type: type,
                            path: path.isEmpty ? nil : path.trimmingCharacters(in: .whitespaces),
                            sortOrder: Int(sortOrderText)
                        )) {
                            dismiss()
                        }
                    }
                }
                .disabled(vm.phase == .busy || formValid == false)
            }
            if case .failed(let message) = vm.phase {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("新建菜单")
        .toolbar {
            Button("取消") { dismiss() }
        }
    }
}
