import CoreKit
import SaasSharedGenerated
import SwiftUI

// REQ-2026-005 T-2（M04.F01，AC-1~AC-5）：应用维护页——AccountView 新段
// NavigationLink 进入。列表（clientId/名称/状态）→ 详情（只读 + 编辑表单 +
// 删除确认）+ 新建（secret 必填录入）。逗号串字段（redirectUris/grantTypes/
// scopes）原样透传展示编辑（Q3：DB 形态直出，不发明数组转换层）；分页不传
// （Q1：0-indexed，nil 全量）。数据流全在 AdminClientsViewModel（CoreKit），
// 本层只渲染与转发；API 面只认生成物（硬规则 §4）。

struct ApplicationsView: View {
    @StateObject private var vm: AdminClientsViewModel
    @State private var showCreate = false

    init() {
        _vm = StateObject(wrappedValue: AdminClientsViewModel(seams: .init(
            listClients: APIGlue.listClients,
            getClient: APIGlue.getClient,
            createClient: APIGlue.createClient,
            updateClient: APIGlue.updateClient,
            deleteClient: APIGlue.deleteClient,
            setClientStatus: APIGlue.setClientStatus
        )))
    }

    var body: some View {
        Form {
            Section {
                if vm.clients.isEmpty {
                    Text(vm.phase == .busy ? "加载中…" : "无应用")
                        .foregroundStyle(.secondary)
                }
                ForEach(vm.clients, id: \.clientId) { client in
                    NavigationLink {
                        ClientDetailView(vm: vm, client: client)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.clientName)
                            Text("\(client.clientId) · \(client.status == 1 ? "启用" : "停用")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("OAuth 应用（平台 admin）")
            } footer: {
                Text("共 \(vm.clients.count) 个 · 停用后该应用的 authorize/token 立即被拒绝（详情页可切换）")
            }
            if case .failed(let message) = vm.phase {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("应用维护")
        .toolbar {
            Button("新建应用") { showCreate = true }
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                ClientCreateView(vm: vm)
            }
        }
        .task {
            _ = await vm.load()
        }
    }
}

/// 详情 + 编辑 + 删除 + 启用状态（REQ-2026-005 AC-2~AC-4 / REQ-2026-006
/// AC-1~AC-4）：只读段原样展示逗号串字段；编辑段保存走 partial
/// UpdateOAuthClientRequest；启用状态段 Toggle（启用直通、停用二次确认——
/// 停用即该应用 authorize/token 立即拒绝）；删除走二次确认（服务端吊销该
/// client 全部 token，不可逆），成功 dismiss 返回列表（行已原位移除）。
struct ClientDetailView: View {
    @ObservedObject var vm: AdminClientsViewModel
    let client: OAuthClient

    @State private var clientName: String = ""
    @State private var redirectUris: String = ""
    @State private var grantTypes: String = ""
    @State private var scopes: String = ""
    @State private var showDeleteConfirm = false
    @State private var showDisableConfirm = false
    @Environment(\.dismiss) private var dismiss

    /// vm.clients 是唯一真相（setStatus/update 原位替换行后导航快照会陈旧），
    /// 渲染取活行，取不到（已被删除）回退导航快照。
    private var current: OAuthClient {
        vm.clients.first { $0.clientId == client.clientId } ?? client
    }

    var body: some View {
        Form {
            Section("详情（只读）") {
                LabeledContent("clientId", value: current.clientId)
                    .font(.footnote.monospaced())
                LabeledContent("状态", value: current.status == 1 ? "启用" : "停用")
                LabeledContent("access 有效期", value: "\(current.accessTokenValidity)s")
                LabeledContent("refresh 有效期", value: "\(current.refreshTokenValidity)s")
                LabeledContent("自动批准", value: current.autoApprove ? "是" : "否")
            }
            Section {
                // REQ-2026-006（M04.F02）：启用直通（无损），停用走确认
                // dialog（立即拒绝该应用的 authorize/token）。失败时列表行
                // 不动，Toggle 随 Binding 回弹原状态（AC-4）。
                Toggle("启用", isOn: Binding(
                    get: { current.status == 1 },
                    set: { enabled in
                        if enabled {
                            Task { _ = await vm.setStatus(current.clientId, 1) }
                        } else {
                            showDisableConfirm = true
                        }
                    }
                ))
                .disabled(vm.phase == .busy)
                .confirmationDialog(
                    "停用 \(current.clientId)？",
                    isPresented: $showDisableConfirm,
                    titleVisibility: .visible
                ) {
                    Button("停用（其 authorize/token 立即拒绝）", role: .destructive) {
                        Task { _ = await vm.setStatus(current.clientId, 0) }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("该应用的所有授权与刷新请求将立即被后端拒绝；重新启用即恢复")
                }
            } header: {
                Text("启用状态")
            } footer: {
                Text("status 切换立即生效，服务端不落审计（BASE I06）")
            }
            Section {
                TextField("应用名称", text: $clientName)
                TextField("redirectUris（逗号分隔）", text: $redirectUris)
                TextField("grantTypes（逗号分隔）", text: $grantTypes)
                TextField("scopes（逗号分隔）", text: $scopes)
                Button("保存") {
                    Task {
                        if await vm.update(client.clientId, UpdateOAuthClientRequest(
                            clientName: clientName,
                            grantTypes: grantTypes,
                            redirectUris: redirectUris,
                            scopes: scopes
                        )) {
                            dismiss()
                        }
                    }
                }
                .disabled(vm.phase == .busy)
            } header: {
                Text("编辑（逗号分隔原样提交）")
            } footer: {
                Text("密钥不返明文：详情无 secret 字段（BASE I03 仅指纹语义）")
            }
            Section {
                Button("删除应用", role: .destructive) {
                    showDeleteConfirm = true
                }
                .disabled(vm.phase == .busy)
                .confirmationDialog(
                    "删除 \(client.clientId)？",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("删除（吊销其全部 token，不可逆）", role: .destructive) {
                        Task {
                            if await vm.deleteClient(client.clientId) {
                                dismiss()
                            }
                        }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("服务端将吊销该 client 名下所有 access/refresh token")
                }
            } footer: {
                Text("删除是危险操作：吊销该应用全部 token 且不可恢复")
            }
            if case .failed(let message) = vm.phase {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(client.clientName)
        .onAppear {
            // 编辑段以现状为起点（partial 提交，未动的字段保持原值）
            clientName = client.clientName
            redirectUris = client.redirectUris
            grantTypes = client.grantTypes
            scopes = client.scopes ?? ""
        }
    }
}

/// 新建应用（AC-4）：clientId/名称/secret（必填录入，Q2）+ 逗号行白名单与
/// scope/grantTypes。成功 dismiss（VM 已追加行，返回即见）。
struct ClientCreateView: View {
    @ObservedObject var vm: AdminClientsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var clientId = ""
    @State private var clientName = ""
    @State private var clientSecret = ""
    @State private var redirectUris = ""
    @State private var grantTypes = "authorization_code"
    @State private var scopes = ""

    private var formValid: Bool {
        [clientId, clientName, clientSecret, redirectUris, grantTypes].allSatisfy {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    var body: some View {
        Form {
            Section {
                TextField("clientId（唯一标识）", text: $clientId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("应用名称", text: $clientName)
                SecureField("clientSecret（必填）", text: $clientSecret)
            } header: {
                Text("身份")
            }
            Section {
                TextField("redirectUris（逗号分隔）", text: $redirectUris)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("grantTypes（逗号分隔）", text: $grantTypes)
                TextField("scopes（逗号分隔，可空）", text: $scopes)
            } header: {
                Text("白名单与授权")
            } footer: {
                Text("redirectUris / grantTypes / scopes 以逗号分隔原样提交（DB 形态）")
            }
            Section {
                Button("注册") {
                    Task {
                        if await vm.create(CreateOAuthClientRequest(
                            clientId: clientId.trimmingCharacters(in: .whitespaces),
                            clientName: clientName.trimmingCharacters(in: .whitespaces),
                            clientSecret: clientSecret,
                            grantTypes: grantTypes.trimmingCharacters(in: .whitespaces),
                            redirectUris: redirectUris.trimmingCharacters(in: .whitespaces),
                            scopes: scopes.isEmpty ? nil : scopes
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
        .navigationTitle("新建应用")
        .toolbar {
            Button("取消") { dismiss() }
        }
    }
}
