import CoreKit
import SaasSharedGenerated
import SwiftUI

// REQ-2026-007 T-2（M00.F01，AC-1~AC-6）：租户维护页——AccountView 新段
// NavigationLink 进入。列表（name/tenantKey/status 徽标）→ 编辑（改名 +
// status Picker + 删除确认）+ 新建（tenantKey/name）。寻址 UUID id（Q1）；
// status 字符串枚举（Q2）；删除是级联危险操作走二次确认。数据流全在
// AdminTenantsViewModel（CoreKit），本层只渲染与转发；API 面只认生成物。

struct TenantsAdminView: View {
    @StateObject private var vm: AdminTenantsViewModel
    @State private var showCreate = false

    init() {
        _vm = StateObject(wrappedValue: AdminTenantsViewModel(seams: .init(
            listTenants: APIGlue.listAllTenants,
            createTenant: APIGlue.createTenant,
            updateTenant: APIGlue.updateTenant,
            deleteTenant: APIGlue.deleteTenant
        )))
    }

    var body: some View {
        Form {
            Section {
                if vm.tenants.isEmpty {
                    Text(vm.phase == .busy ? "加载中…" : "无租户")
                        .foregroundStyle(.secondary)
                }
                ForEach(vm.tenants, id: \.id) { tenant in
                    NavigationLink {
                        TenantEditView(vm: vm, tenant: tenant)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tenant.name)
                            Text("\(tenant.tenantKey) · \(tenant.status == .active ? "启用" : "停用")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("租户（平台 admin）")
            } footer: {
                Text("共 \(vm.tenants.count) 个 · status 切换即生效（active/suspended）")
            }
            if case .failed(let message) = vm.phase {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("租户管理")
        .toolbar {
            Button("新建租户") { showCreate = true }
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                TenantCreateView(vm: vm)
            }
        }
        .task {
            _ = await vm.load()
        }
    }
}

/// 编辑 + 删除（AC-3）：改名 + status Picker（active/suspended 字符串枚举）；
/// 删除走二次确认（级联危险操作），成功 dismiss 返回列表（行已原位移除）。
struct TenantEditView: View {
    @ObservedObject var vm: AdminTenantsViewModel
    let tenant: Tenant

    @State private var name: String = ""
    @State private var status: TenantStatus = .active
    @State private var showDeleteConfirm = false
    @Environment(\.dismiss) private var dismiss

    /// vm.tenants 是唯一真相（update/delete 原位替换后导航快照会陈旧）。
    private var current: Tenant {
        vm.tenants.first { $0.id == tenant.id } ?? tenant
    }

    var body: some View {
        Form {
            Section("详情（只读）") {
                LabeledContent("tenantKey", value: current.tenantKey)
                    .font(.footnote.monospaced())
                LabeledContent("id", value: current.id.uuidString)
                    .font(.footnote.monospaced())
            }
            Section {
                TextField("租户名称", text: $name)
                Picker("状态", selection: $status) {
                    Text("启用").tag(TenantStatus.active)
                    Text("停用").tag(TenantStatus.suspended)
                }
                Button("保存") {
                    Task {
                        if await vm.update(current.id, UpdateTenantRequest(
                            name: name,
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
                Text("status 是字符串枚举 active/suspended（与 OAuth 的 Int 口径不同）")
            }
            Section {
                Button("删除租户", role: .destructive) {
                    showDeleteConfirm = true
                }
                .disabled(vm.phase == .busy)
                .confirmationDialog(
                    "删除 \(current.tenantKey)？",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("删除（级联清理成员与订阅）", role: .destructive) {
                        Task {
                            if await vm.deleteTenant(current.id) {
                                dismiss()
                            }
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("租户及其成员关系、应用订阅将被级联处理，不可恢复")
                }
            } footer: {
                Text("删除是级联危险操作，不可恢复")
            }
            if case .failed(let message) = vm.phase {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(current.name)
        .onAppear {
            name = current.name
            status = current.status
        }
    }
}

/// 新建租户（AC-2）：tenantKey/name 必填。tenantKey 重复 409 红字可重试；
/// 服务端默认 status=active。
struct TenantCreateView: View {
    @ObservedObject var vm: AdminTenantsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var tenantKey = ""
    @State private var name = ""

    private var formValid: Bool {
        [tenantKey, name].allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        Form {
            Section {
                TextField("tenantKey（唯一标识）", text: $tenantKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("租户名称", text: $name)
            } header: {
                Text("身份")
            } footer: {
                Text("tenantKey 重复返回 409；创建后默认 status=active")
            }
            Section {
                Button("创建") {
                    Task {
                        if await vm.create(CreateTenantRequest(
                            tenantKey: tenantKey.trimmingCharacters(in: .whitespaces),
                            name: name.trimmingCharacters(in: .whitespaces)
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
        .navigationTitle("新建租户")
        .toolbar {
            Button("取消") { dismiss() }
        }
    }
}
