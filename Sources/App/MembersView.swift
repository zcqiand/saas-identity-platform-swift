import CoreKit
import SaasSharedGenerated
import SwiftUI

// REQ-2026-003 T-2（M01.F02，AC-1~AC-4）：成员角色页——从 AccountView 租户段
// NavigationLink 进入。成员列表（username/status/角色）+ 点选成员进角色编辑
// （勾选清单来自生成物 TenantRolesAPI，按成员当前 roleIds 预勾选）+ 保存
// 全量覆盖（Q3：勾选即最终态）+ 失败红字列表不动可重试。数据流全在
// MembersViewModel（CoreKit），本层只渲染与转发；API 面只认生成物（硬规则 §4）。

struct MembersView: View {
    let session: AppSession

    @StateObject private var vm: MembersViewModel

    init(session: AppSession) {
        self.session = session
        _vm = StateObject(wrappedValue: MembersViewModel(
            store: session.store,
            seams: .init(
                listMembers: APIGlue.listMembers,
                listRoles: APIGlue.listRoles,
                assignRoles: APIGlue.assignRoles
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
                        RoleAssignView(vm: vm, member: member)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.username)
                            Text("角色 \(member.roleIds.count) 个 · \(member.status.rawValue)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
        .task {
            // AC-1：进页并发拉成员 + 角色（VM 内 async let）；失败红字可下拉重试
            //（重新进页或进详情再退回触发 task）。
            _ = await vm.load()
        }
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
                LabeledContent("状态", value: member.status.rawValue)
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
