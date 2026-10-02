import CoreKit
import SaasSharedGenerated
import SwiftUI

// REQ-2026-010 T-2（M00.F03，AC-1~AC-6）：角色管理页——从 AccountView 租户段
// NavigationLink 进入。角色列表（client Picker 本地过滤：角色量小，全量拉取
// 后前端滤，0-indexed 分页不进 UI）+ 行进角色详情（资料编辑/status 启停/删除）
// + 工具条「新建角色」sheet。数据流全在 RolesViewModel（CoreKit），本层只渲染
// 与转发；API 面只认生成物 TenantRolesAPI（硬规则 §4）。

struct RolesAdminView: View {
    let session: AppSession

    @StateObject private var vm: RolesViewModel
    @StateObject private var clientsVM: AdminClientsViewModel
    @State private var selectedClientId = ""
    @State private var showCreate = false

    init(session: AppSession) {
        self.session = session
        _vm = StateObject(wrappedValue: RolesViewModel(
            store: session.store,
            seams: .init(
                listRoles: APIGlue.listRoles,
                createRole: APIGlue.createRole,
                getRole: APIGlue.getRole,
                updateRole: APIGlue.updateRole,
                deleteRole: APIGlue.deleteRole,
                listGrants: APIGlue.listGrants,
                setGrants: APIGlue.setGrants,
                clearGrants: APIGlue.clearGrants
            )
        ))
        _clientsVM = StateObject(wrappedValue: AdminClientsViewModel(seams: .init(
            listClients: APIGlue.listClients
        )))
    }

    /// client 过滤在前端做（AC-1）：全量已在本 VM，避免每切一次 client 打一次网。
    private var filtered: [SysRole] {
        selectedClientId.isEmpty ? vm.roles : vm.roles.filter { $0.clientId == selectedClientId }
    }

    var body: some View {
        List {
            Section {
                Picker("Client 过滤", selection: $selectedClientId) {
                    Text("全部").tag("")
                    ForEach(clientsVM.clients, id: \.clientId) { client in
                        Text(client.clientId).tag(client.clientId)
                    }
                }
                if filtered.isEmpty {
                    Text(vm.phase == .busy ? "加载中…" : "无角色")
                        .foregroundStyle(.secondary)
                }
                ForEach(filtered, id: \.id) { role in
                    NavigationLink {
                        // 传快照值，详情页以 vm 实时行渲染（列表原位更新即见）。
                        RoleDetailAdminView(vm: vm, role: role)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(role.roleCode)
                                if role.isPreset {
                                    Text("预设")
                                        .font(.caption2)
                                        .foregroundStyle(.tint)
                                }
                            }
                            Text("\(role.roleName) · \(role.clientId) · \(role.status == 1 ? "启用" : "停用")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("角色（当前租户）")
            } footer: {
                Text("租户：\(session.store.currentTenantId?.uuidString ?? "—") · 过滤在前端做（列表全量拉取）")
            }
            if case .failed(let message) = vm.phase {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("角色管理")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("新建角色") { showCreate = true }
            }
        }
        .sheet(isPresented: $showCreate) {
            RoleCreateSheet(vm: vm, clients: clientsVM.clients)
        }
        .task {
            // AC-1：进页并发拉角色 + client 清单（新建 sheet 的 Picker 数据源）。
            _ = await vm.load()
            _ = await clientsVM.load()
        }
    }
}

/// 状态中文标签（M00.F03 列表行 + 详情页共用；不进 VM——纯渲染口径）。
func roleStatusLabel(_ status: Int) -> String {
    status == 1 ? "启用" : "停用"
}

// MARK: - M00.F03 角色详情（REQ-2026-010 T-2）

/// 角色详情：资料编辑（I04 PATCH partial）+ status 启停（AC-4）+ 移除
/// （I05 二次确认）。行数据以 vm 实时行渲染；编辑表单以进页快照播种、
/// 保存才提交；roleCode/tenantId 只读（契约不可改口径）。
struct RoleDetailAdminView: View {
    @ObservedObject var vm: RolesViewModel
    let role: SysRole

    @State private var roleName: String = ""
    @State private var description: String = ""
    @State private var enabled = true
    @State private var confirmRemove = false
    @Environment(\.dismiss) private var dismiss

    /// 实时行（列表原位更新后详情跟随）；行没了 = 已被移除，兜快照渲染。
    private var row: SysRole? {
        vm.roles.first { $0.id == role.id }
    }

    var body: some View {
        Form {
            if let row {
                Section("角色") {
                    LabeledContent("roleCode", value: row.roleCode)
                    LabeledContent("roleName", value: row.roleName)
                    LabeledContent("Client", value: row.clientId)
                    LabeledContent("预设", value: row.isPreset ? "是" : "否")
                }
                Section("状态") {
                    // PATCH partial：播种触发等值变化由 row.status 守卫拦。
                    Toggle("启用", isOn: $enabled)
                        .onChange(of: enabled) { _, newValue in
                            guard row.status != (newValue ? 1 : 0) else { return }
                            Task { _ = await vm.setStatus(roleID: row.id, to: newValue ? 1 : 0) }
                        }
                }
                Section {
                    TextField("roleName", text: $roleName)
                    TextField("描述", text: $description)
                    Button("保存资料") {
                        Task {
                            // PATCH partial：空输入 = nil = 该字段不提交（生成物
                            // encodeIfPresent 口径），不会误清后端值。
                            if await vm.update(
                                roleID: row.id,
                                roleName: roleName.isEmpty ? nil : roleName,
                                description: description.isEmpty ? nil : description
                            ) {
                                roleName = ""
                                description = ""
                            }
                        }
                    }
                    .disabled(vm.phase == .busy)
                } header: {
                    Text("编辑资料")
                } footer: {
                    Text("roleCode 不可改（契约口径）；留空的字段不提交（保持原值）")
                }
                // M00.F04（REQ-2026-011）：菜单授权段（多选 + 保存/清空）。
                RoleMenuGrantsSection(vm: vm, role: row)
                Section("危险区") {
                    Button("删除角色", role: .destructive) {
                        confirmRemove = true
                    }
                    .disabled(vm.phase == .busy)
                    .confirmationDialog(
                        "删除角色「\(row.roleCode)」？",
                        isPresented: $confirmRemove,
                        titleVisibility: .visible
                    ) {
                        Button("删除", role: .destructive) {
                            Task {
                                if await vm.remove(roleID: row.id) {
                                    dismiss()
                                }
                            }
                        }
                    } message: {
                        Text("删除后引用该角色的成员绑定由后端规则裁决")
                    }
                }
            } else {
                Section {
                    Text("该角色已不存在")
                        .foregroundStyle(.secondary)
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
        .navigationTitle(row?.roleCode ?? role.roleCode)
        .onAppear {
            // 表单与 Toggle 以进页快照播种（编辑起点 = 现状，防覆盖）。
            roleName = role.roleName
            description = role.description ?? ""
            enabled = role.status == 1
        }
    }
}

// MARK: - 菜单授权段（M00.F04，REQ-2026-011 T-2）

/// 角色详情「菜单授权」段：该 client 菜单多选勾选 + 保存授权（PUT 全量替换）
/// + 清空（DELETE 二次确认）。菜单清单复用 REQ-008 APIGlue.listMenus 缝
/// （role.clientId 定源，Q4；SysMenu.id UUID → menuIds String 走 uuidString），
/// id 全来自清单返回值——AC-4：UI 不可能产生未知 id（后端 400 FK 路径不可达）。
/// 勾选态本地 Set（menuIds 后端顺序不保证，探针实证）；授权网络态在
/// RolesViewModel.grants（Q1），失败红字经 vm.phase 由父页呈现。
struct RoleMenuGrantsSection: View {
    @ObservedObject var vm: RolesViewModel
    let role: SysRole

    @State private var menus: [SysMenu] = []
    @State private var menusError: String?
    @State private var selected: Set<String> = []
    @State private var seeded = false
    @State private var confirmClear = false

    var body: some View {
        Section {
            if let menusError {
                Text(menusError)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
            if menus.isEmpty && menusError == nil {
                Text(vm.phase == .busy ? "加载中…" : "该 client 无菜单可授")
                    .foregroundStyle(.secondary)
            }
            ForEach(menus, id: \.id) { menu in
                Toggle(isOn: binding(for: menu.id.uuidString)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(menu.title)
                        Text(menu.path ?? menu.id.uuidString)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(vm.phase == .busy)
            }
            Button("保存授权") {
                Task {
                    // 提交按菜单清单序稳定排列（PUT 全量替换：未勾选=移除）。
                    let ordered = menus.map(\.id.uuidString).filter { selected.contains($0) }
                    if await vm.saveGrants(roleID: role.id, menuIds: ordered) {
                        // 勾选态以响应为准（顺序不保证照存不重排）。
                        selected = Set(vm.grants?.menuIds ?? [])
                        seeded = true
                    }
                }
            }
            .disabled(vm.phase == .busy || menus.isEmpty)
            Button("清空授权", role: .destructive) {
                confirmClear = true
            }
            .disabled(vm.phase == .busy || (vm.grants?.menuIds.isEmpty ?? true))
            .confirmationDialog(
                "清空角色「\(role.roleCode)」的全部菜单授权？",
                isPresented: $confirmClear,
                titleVisibility: .visible
            ) {
                Button("清空", role: .destructive) {
                    Task {
                        if await vm.clearGrants(roleID: role.id) {
                            selected = []
                        }
                    }
                }
            } message: {
                Text("清空后该角色失去所有菜单访问，可重新勾选保存恢复")
            }
        } header: {
            Text("菜单授权")
        } footer: {
            Text("勾选 = 授予该菜单；保存为全量替换（未勾选的会被移除）")
        }
        .task {
            // 菜单清单：进段拉一次（client 定源自 role.clientId，失败红字
            // 不静默——try? 会把炸面藏成降级）。
            if menus.isEmpty && menusError == nil {
                do {
                    menus = try await APIGlue.listMenus(role.clientId)
                } catch {
                    if case ErrorResponse.error(let code, _, _, _) = error {
                        menusError = "菜单清单加载失败（HTTP \(code)）"
                    } else {
                        menusError = "菜单清单加载失败：\(String(describing: error))"
                    }
                }
            }
            // 授权态播种：首次成功后不再重播（保存/清空各自回写 selected，
            // 防止重复 GET 盖掉未保存的本地勾选）。
            if !seeded {
                if await vm.loadGrants(roleID: role.id) {
                    selected = Set(vm.grants?.menuIds ?? [])
                    seeded = true
                }
            }
        }
    }

    /// Set 语义勾选绑定（menuIds 顺序不保证，全程 Set 比较）。
    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(id) },
            set: {
                if $0 {
                    selected.insert(id)
                } else {
                    selected.remove(id)
                }
            }
        )
    }
}

// MARK: - 新建角色 sheet（M00.F03 I02）

/// 新建角色（I02）：clientId Picker 必选（Q3：复用 APIGlue.listClients admin 面，
/// 不发明自由输入）/roleCode/roleName 必填。重名 roleCode 后端 500 空 body
/// （Q1）——红字如实呈现。
struct RoleCreateSheet: View {
    @ObservedObject var vm: RolesViewModel
    let clients: [OAuthClient]

    @State private var clientId = ""
    @State private var roleCode = ""
    @State private var roleName = ""
    @State private var description = ""
    @Environment(\.dismiss) private var dismiss

    private var valid: Bool {
        !clientId.isEmpty
            && !roleCode.trimmingCharacters(in: .whitespaces).isEmpty
            && !roleName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Client（必选）", selection: $clientId) {
                        if clientId.isEmpty {
                            Text("选择 client").tag("")
                        }
                        ForEach(clients, id: \.clientId) { client in
                            Text(client.clientId).tag(client.clientId)
                        }
                    }
                    TextField("roleCode（唯一标识）", text: $roleCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("roleName（显示名）", text: $roleName)
                    TextField("描述（选填）", text: $description)
                } footer: {
                    Text("角色绑定一个 OAuth client（tenant × client 作用域）；重名 roleCode 后端会拒绝")
                }
                Section {
                    Button("创建") {
                        Task {
                            if await vm.create(
                                clientId: clientId,
                                roleCode: roleCode.trimmingCharacters(in: .whitespaces),
                                roleName: roleName.trimmingCharacters(in: .whitespaces),
                                description: description.isEmpty ? nil : description
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!valid || vm.phase == .busy)
                }
                if case .failed(let message) = vm.phase {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("新建角色")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

