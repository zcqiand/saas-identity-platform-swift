import CoreKit
import SaasSharedGenerated
import SwiftUI

// REQ-2026-003 T-2（M01.F02，AC-1~AC-4）+ REQ-2026-009 T-2（M00.F02）：成员管理页
// ——从 AccountView 租户段 NavigationLink 进入。成员列表 + 行进成员详情
// （资料编辑/状态切换/角色分配/移除）+ 工具条新建/邀请 sheet + 行 contextMenu
// 快捷挂起/恢复。数据流全在 MembersViewModel（CoreKit），本层只渲染与转发；
// API 面只认生成物（硬规则 §4）。

struct MembersView: View {
    let session: AppSession

    @StateObject private var vm: MembersViewModel

    @State private var showCreate = false
    @State private var showInvite = false

    init(session: AppSession) {
        self.session = session
        _vm = StateObject(wrappedValue: MembersViewModel(
            store: session.store,
            seams: .init(
                listMembers: APIGlue.listMembers,
                listRoles: APIGlue.listRoles,
                assignRoles: APIGlue.assignRoles,
                getMember: APIGlue.getMember,
                createMember: APIGlue.createMember,
                updateMember: APIGlue.updateMember,
                changeStatus: APIGlue.changeStatus,
                deleteMember: APIGlue.deleteMember,
                inviteMember: APIGlue.inviteMember
            )
        ))
    }

    var body: some View {
        Form {
            Section {
                if vm.members.isEmpty {
                    Text(vm.phase == .busy ? "加载中…" : "无成员")
                        .foregroundStyle(.secondary)
                }
                ForEach(vm.members, id: \.id) { member in
                    NavigationLink {
                        // M00.F02：行进成员详情（编辑/状态/角色/移除收敛在一个页面）；
                        // 传快照值，详情页以 vm 实时行渲染（列表原位更新即见）。
                        MemberDetailAdminView(vm: vm, member: member)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.username)
                            Text("角色 \(member.roleIds.count) 个 · \(memberStatusLabel(member.status))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    // M00.F02 快捷操作：contextMenu 挂起/恢复，结果以响应原位替换行。
                    .contextMenu {
                        if member.status == .suspended {
                            Button("恢复") {
                                Task { _ = await vm.changeStatus(memberID: member.id, to: .active) }
                            }
                        } else {
                            Button("挂起", role: .destructive) {
                                Task { _ = await vm.changeStatus(memberID: member.id, to: .suspended) }
                            }
                        }
                    }
                }
            } header: {
                Text("成员（当前租户）")
            } footer: {
                // 租户名富化是家族既有人裁缝（同 AccountView 口径），这里显示 UUID。
                Text("租户：\(session.store.currentTenantId?.uuidString ?? "—")")
            }
            if case .failed(let message) = vm.phase {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle("成员角色")
        .toolbar {
            // M00.F02 I02/I06：新建成员 / 邀请成员入口（email 后端必填 → sheet
            // 内校验，见 MemberCreateSheet/MemberInviteSheet）。
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("新建成员") { showCreate = true }
                    Button("邀请成员") { showInvite = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            MemberCreateSheet(vm: vm)
        }
        .sheet(isPresented: $showInvite) {
            MemberInviteSheet(vm: vm)
        }
        .task {
            // AC-1：进页并发拉成员 + 角色（VM 内 async let）；失败红字可下拉重试
            //（重新进页或进详情再退回触发 task）。
            _ = await vm.load()
        }
    }
}

/// 状态中文标签（M00.F02 列表行 + 详情页共用；不进 VM——纯渲染口径）。
func memberStatusLabel(_ status: TenantMemberStatus) -> String {
    switch status {
    case .active: return "活跃"
    case .invited: return "已邀请"
    case .suspended: return "已挂起"
    case .disabled: return "已禁用"
    }
}

/// 角色编辑（AC-2/AC-3）：勾选清单预勾选成员当前角色，保存 = PUT 全量覆盖；
/// 成功 dismiss（VM 已原位更新成员行，返回即见），失败红字留在本页可重试。
struct RoleAssignView: View {
    @ObservedObject var vm: MembersViewModel
    let member: TenantMemberUserView

    @State private var selected: [String] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("成员") {
                LabeledContent("用户名", value: member.username)
                LabeledContent("状态", value: memberStatusLabel(member.status))
            }
            Section {
                ForEach(vm.roles, id: \.id) { role in
                    let roleId = role.id.uuidString
                    Button {
                        if let index = selected.firstIndex(of: roleId) {
                            selected.remove(at: index)
                        } else {
                            selected.append(roleId)
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(role.roleName)
                                Text("\(role.roleCode) · \(roleId)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selected.contains(roleId) {
                                Image(systemName: "checkmark").foregroundStyle(.tint)
                            }
                        }
                    }
                }
                if vm.roles.isEmpty {
                    Text("无角色").foregroundStyle(.secondary)
                }
            } header: {
                Text("角色（勾选即最终态）")
            } footer: {
                Text("保存为全量覆盖：提交的勾选集合就是该成员的最终角色集")
            }
            Section {
                Button("保存") {
                    Task {
                        if await vm.assignRoles(selected, to: member.id) {
                            dismiss()
                        }
                    }
                }
                .disabled(vm.phase == .busy)
            }
            if case .failed(let message) = vm.phase {
                Section {
                    Text(message)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
        }
        .navigationTitle(member.username)
        .onAppear {
            // 预勾选当前角色（风险表第 3 条：防误操作清空——勾选以现状为起点）
            selected = member.roleIds
        }
    }
}

// MARK: - M00.F02 成员详情/管理页（REQ-2026-009 T-2）

/// 成员详情：资料编辑（I04 PATCH partial）+ 状态切换（I08）+ 角色分配入口
/// （RoleAssignView 不回归）+ 移除（I05 二次确认）。行数据以 vm 实时行渲染
/// （replaceRow 原位更新返回即见）；编辑表单以进页快照播种、保存才提交。
struct MemberDetailAdminView: View {
    @ObservedObject var vm: MembersViewModel
    let member: TenantMemberUserView

    @State private var email: String = ""
    @State private var mobile: String = ""
    @State private var status: TenantMemberStatus = .active
    @State private var confirmRemove = false
    @Environment(\.dismiss) private var dismiss

    /// 实时行（列表原位更新后详情跟随）；行没了 = 已被移除，兜快照渲染。
    private var row: TenantMemberUserView? {
        vm.members.first { $0.id == member.id }
    }

    var body: some View {
        Form {
            if let row {
                Section("成员") {
                    LabeledContent("用户名", value: row.username)
                    LabeledContent("邮箱", value: row.email ?? "—")
                    LabeledContent("状态", value: memberStatusLabel(row.status))
                }
                Section("状态") {
                    Picker("状态", selection: $status) {
                        Text(memberStatusLabel(.active)).tag(TenantMemberStatus.active)
                        Text(memberStatusLabel(.suspended)).tag(TenantMemberStatus.suspended)
                    }
                    // 挂起成员 PUT roles 响应假报 active（REQ-009 Q2），状态切换
                    // 专走 changeStatus 端点；播种触发等值变化由 row.status 守卫拦。
                    .onChange(of: status) { _, newValue in
                        guard row.status != newValue else { return }
                        Task { _ = await vm.changeStatus(memberID: row.id, to: newValue) }
                    }
                }
                Section {
                    TextField("邮箱", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("手机号（留空不动）", text: $mobile)
                        .keyboardType(.phonePad)
                    Button("保存资料") {
                        Task {
                            // PATCH partial：空输入 = nil = 该字段不提交（生成物
                            // encodeIfPresent 口径），不会误清后端值。
                            if await vm.update(
                                memberID: row.id,
                                email: email.isEmpty ? nil : email,
                                mobile: mobile.isEmpty ? nil : mobile
                            ) {
                                email = ""
                                mobile = ""
                            }
                        }
                    }
                    .disabled(vm.phase == .busy)
                } header: {
                    Text("编辑资料")
                } footer: {
                    Text("留空的字段不提交（保持原值）")
                }
                Section {
                    NavigationLink("角色分配") {
                        RoleAssignView(vm: vm, member: row)
                    }
                }
                Section("危险区") {
                    Button("移出当前租户", role: .destructive) {
                        confirmRemove = true
                    }
                    .disabled(vm.phase == .busy)
                    .confirmationDialog(
                        "移除成员「\(row.username)」？",
                        isPresented: $confirmRemove,
                        titleVisibility: .visible
                    ) {
                        Button("移除", role: .destructive) {
                            Task {
                                // 只摘 tenant_membership，全局账号保留（契约口径）；
                                // 204 后 VM 已移除本地行，行没了退回列表。
                                if await vm.remove(memberID: row.id) {
                                    dismiss()
                                }
                            }
                        }
                    } message: {
                        Text("仅解除该租户的成员关系，全局账号保留")
                    }
                }
            } else {
                Section {
                    Text("该成员已不在当前租户")
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
        .navigationTitle(row?.username ?? member.username)
        .onAppear {
            // 表单与 Picker 以进页快照播种（编辑起点 = 现状，防覆盖）。
            email = member.email ?? ""
            status = member.status
        }
    }
}

// MARK: - 新建 / 邀请 sheet（M00.F02 I02/I06）

/// 新建成员（I02）：email 契约 optional 但后端必填（live 400 实证，Q1）——
/// UI 必填校验拦在前头；password 是 CreateSysUserRequest 必填项。
struct MemberCreateSheet: View {
    @ObservedObject var vm: MembersViewModel

    @State private var username = ""
    @State private var password = ""
    @State private var email = ""
    @State private var mobile = ""
    @Environment(\.dismiss) private var dismiss

    private var valid: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty
            && password.count >= 6
            && !email.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码（≥6 位）", text: $password)
                    TextField("邮箱（必填）", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("手机号（选填）", text: $mobile)
                        .keyboardType(.phonePad)
                }
                Section {
                    Button("创建") {
                        Task {
                            if await vm.create(
                                username: username.trimmingCharacters(in: .whitespaces),
                                password: password,
                                email: email.trimmingCharacters(in: .whitespaces),
                                mobile: mobile.isEmpty ? nil : mobile
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
            .navigationTitle("新建成员")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}

/// 邀请成员（I06）：email 必填（同 Q1 口径）；无 username/password——账号由
/// 被邀人激活时建立（memberName 后端从 email local-part 派生，live 实证）。
/// 成功后列表追加「已邀请」行（flatRow 映射 user.status）。
struct MemberInviteSheet: View {
    @ObservedObject var vm: MembersViewModel

    @State private var email = ""
    @State private var mobile = ""
    @Environment(\.dismiss) private var dismiss

    private var valid: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("邮箱（必填）", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("手机号（选填）", text: $mobile)
                        .keyboardType(.phonePad)
                } footer: {
                    Text("邀请后该成员以「已邀请」状态出现在列表，激活后转活跃")
                }
                Section {
                    Button("发送邀请") {
                        Task {
                            if await vm.invite(
                                email: email.trimmingCharacters(in: .whitespaces),
                                mobile: mobile.isEmpty ? nil : mobile
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
            .navigationTitle("邀请成员")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
