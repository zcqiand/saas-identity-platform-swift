import SwiftUI
import CoreKit
import SaasSharedGenerated

// REQ-2026-012 T-2：租户应用订阅管理（M00.F05）。列表（I01）+ 订阅 sheet
// （I02：client Picker + 到期日）+ 详情页（I03 状态启停 + 到期日更新 +
// I04 移除二次确认）。寻址契约：clientId 字符串列非 UUID id。网络面全走
// APIGlue 生成物缝；client 清单复用 AdminClientsViewModel（RolesAdminView
// 同款，Picker 数据源语义）。

struct TenantApplicationsAdminView: View {
    let session: AppSession

    @StateObject private var vm: TenantApplicationsViewModel
    @StateObject private var clientsVM: AdminClientsViewModel
    @State private var showSubscribe = false

    init(session: AppSession) {
        self.session = session
        _vm = StateObject(wrappedValue: TenantApplicationsViewModel(
            store: session.store,
            seams: .init(
                list: APIGlue.listTenantApplications,
                subscribe: APIGlue.subscribeTenantApplication,
                update: APIGlue.updateTenantApplication,
                remove: APIGlue.removeTenantApplication
            )
        ))
        _clientsVM = StateObject(wrappedValue: AdminClientsViewModel(seams: .init(
            listClients: APIGlue.listClients
        )))
    }

    var body: some View {
        List {
            Section {
                if vm.applications.isEmpty {
                    Text(vm.phase == .busy ? "加载中…" : "无订阅应用")
                        .foregroundStyle(.secondary)
                }
                ForEach(vm.applications, id: \.clientId) { app in
                    NavigationLink {
                        // 传快照值，详情页以 vm 实时行渲染（列表原位更新即见）。
                        TenantApplicationDetailView(vm: vm, app: app)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(app.clientId)
                                Text(app.status == 1 ? "启用" : "停用")
                                    .font(.caption2)
                                    .foregroundStyle(app.status == 1 ? .green : .secondary)
                            }
                            Text(expireLabel(app))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("订阅应用（当前租户）")
            } footer: {
                Text("寻址 clientId 字符串列；到期时间随订阅/更新维护")
            }
            if case .failed(let message) = vm.phase {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("租户应用")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("订阅应用") { showSubscribe = true }
            }
        }
        .sheet(isPresented: $showSubscribe) {
            TenantApplicationSubscribeSheet(vm: vm, clients: clientsVM.clients)
        }
        .task {
            // 并发拉订阅清单 + client 清单（订阅 sheet 的 Picker 数据源）。
            _ = await vm.load()
            _ = await clientsVM.load()
        }
    }

    private func expireLabel(_ app: TenantApplication) -> String {
        guard let expire = app.expireTime else { return "无到期时间" }
        return "到期：\(expire.formatted(date: .abbreviated, time: .shortened))"
    }
}

// MARK: - 订阅详情（I03/I04）

/// 订阅详情：状态启停（PATCH status）+ 到期日更新 + 移除（二次确认）。
/// 契约口径：UpdateTenantApplicationRequest.expireTime 不传 = 不改
/// （partial-update，CT I76 实证）——所以「清空到期」不可达（omit 即保持
/// 原值），需要换期只能改期；到期日更新总是带当前值提交。
struct TenantApplicationDetailView: View {
    @ObservedObject var vm: TenantApplicationsViewModel
    let app: TenantApplication

    @State private var enabled = true
    @State private var expireDate = Date()
    @State private var confirmRemove = false
    @Environment(\.dismiss) private var dismiss

    /// 实时行（列表原位更新后详情跟随）；行没了 = 已被移除，兜快照渲染。
    private var row: TenantApplication? {
        vm.applications.first { $0.clientId == app.clientId }
    }

    var body: some View {
        Form {
            if let row {
                Section("订阅") {
                    LabeledContent("clientId", value: row.clientId)
                    LabeledContent("状态", value: row.status == 1 ? "启用" : "停用")
                    LabeledContent(
                        "创建于",
                        value: row.createdAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    LabeledContent(
                        "到期",
                        value: row.expireTime?.formatted(date: .abbreviated, time: .shortened) ?? "—"
                    )
                }
                Section("状态") {
                    // PATCH partial：播种触发等值变化由 row.status 守卫拦；
                    // expireTime 总带当前值（不传 = 不改，避免误清）。
                    Toggle("启用", isOn: $enabled)
                        .onChange(of: enabled) { _, newValue in
                            guard row.status != (newValue ? 1 : 0) else { return }
                            Task {
                                _ = await vm.update(clientId: row.clientId,
                                                    status: newValue ? 1 : 0,
                                                    expireTime: row.expireTime)
                            }
                        }
                }
                Section {
                    DatePicker("到期", selection: $expireDate, displayedComponents: .date)
                    Button("保存到期时间") {
                        Task {
                            _ = await vm.update(clientId: row.clientId,
                                                status: row.status,
                                                expireTime: expireDate)
                        }
                    }
                    .disabled(vm.phase == .busy)
                } header: {
                    Text("到期时间")
                } footer: {
                    Text("契约 partial-update：不提交 = 不改，故「清空到期」不可达（需重订）")
                }
                Section("危险区") {
                    Button("移除订阅", role: .destructive) {
                        confirmRemove = true
                    }
                    .disabled(vm.phase == .busy)
                    .confirmationDialog(
                        "移除对「\(row.clientId)」的订阅？",
                        isPresented: $confirmRemove,
                        titleVisibility: .visible
                    ) {
                        Button("移除", role: .destructive) {
                            Task {
                                if await vm.remove(clientId: row.clientId) {
                                    dismiss()
                                }
                            }
                        }
                    } message: {
                        Text("移除后该 client 不再属于当前租户，可重新订阅")
                    }
                }
            } else {
                Section {
                    Text("该订阅已不存在")
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
        .navigationTitle(row?.clientId ?? app.clientId)
        .onAppear {
            // 表单以进页快照播种（编辑起点 = 现状，防覆盖）。
            enabled = app.status == 1
            expireDate = app.expireTime ?? Calendar.current.date(byAdding: .year, value: 1, to: Date())!
        }
    }
}

// MARK: - 订阅 sheet（I02）

/// 订阅应用：client Picker（AdminClientsViewModel 全量）+ 到期日（可空）。
/// 未知 clientId 后端 404 / 重复订阅后端 400（裸 SQL 泄漏 wart）——红字
/// 如实呈现，不做前置重名校验（REQ-012 探针口径）。
struct TenantApplicationSubscribeSheet: View {
    @ObservedObject var vm: TenantApplicationsViewModel
    let clients: [OAuthClient]

    @State private var clientId = ""
    @State private var expireDate = Calendar.current.date(byAdding: .year, value: 1, to: Date())!
    @Environment(\.dismiss) private var dismiss

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
                    DatePicker("到期（可选）", selection: $expireDate, displayedComponents: .date)
                } footer: {
                    Text("到期时间默认一年后，可在详情页改期或停用")
                }
                Section {
                    Button("订阅") {
                        Task {
                            if await vm.subscribe(clientId: clientId, expireTime: expireDate) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(clientId.isEmpty || vm.phase == .busy)
                }
                if case .failed(let message) = vm.phase {
                    Section {
                        Text(message)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("订阅应用")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
