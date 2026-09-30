import SiliconElevenLabs
import SwiftUI

/// Members & sharing: the workspace's people, seats and invitations, groups, who a resource is
/// shared with, sign-in connections, and the audit log. Changes here reach other people, so
/// each one asks first and names who it affects.
struct WorkspaceSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        WorkspaceScreen(model: VoicesStudioModels.model(WorkspaceSectionModel.self, for: app) {
            WorkspaceSectionModel(environment: $0)
        })
    }
}

struct WorkspaceScreen: View {
    @Bindable var model: WorkspaceSectionModel

    var body: some View {
        ElevenLabsSectionPage(.workspace) {
            Picker("Show", selection: $model.tab) {
                ForEach(WorkspaceSectionModel.Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch model.tab {
            case .members: WorkspaceMembersCard(model: model)
            case .invites: WorkspaceInvitesCard(model: model)
            case .groups: WorkspaceGroupsCard(model: model)
            case .sharing: WorkspaceSharingCard(model: model)
            case .connections: WorkspaceConnectionsCard(model: model)
            case .audit: WorkspaceAuditCard(model: model)
            }
            VoicesStudioActivity(actions: model.actions, fallback: model.actions.runner("get_workspace_members"))
        }
        .task(id: model.tab) { await model.loadTab() }
    }
}

struct WorkspaceMembersCard: View {
    @Bindable var model: WorkspaceSectionModel

    var body: some View {
        Card(title: "\(model.members.count) members", systemImage: "person.3") {
            VoicesStudioListState(loading: model.actions.isRunning("get_workspace_members"),
                                  problem: model.actions.problem("get_workspace_members"),
                                  isEmpty: model.members.isEmpty, emptyText: "No members listed.")
            ForEach(model.members) { member in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(member.firstName.isEmpty ? member.email : member.firstName).font(.callout.weight(.medium))
                        Text(member.email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    if member.isOwner { Badge(text: "Owner", tint: .accentColor) }
                    if member.isLocked { Badge(text: "Locked", tint: .red) }
                    Picker("Seat", selection: Binding(
                        get: { model.seatEdits[member.id] ?? member.seatType },
                        set: { model.seatEdits[member.id] = $0 }
                    )) {
                        ForEach(model.seatTypes, id: \.self) { Text(VoicesStudioFormat.words($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(member.isOwner)
                    if let edit = model.seatEdits[member.id], edit != member.seatType {
                        Button("Change seat…") { Task { await model.changeSeat(member) } }.controlSize(.small)
                    }
                    Button(member.isLocked ? "Unlock…" : "Lock…") { Task { await model.setLocked(member, !member.isLocked) } }
                        .controlSize(.small)
                        .disabled(member.isOwner)
                }
            }
        }
    }
}

struct WorkspaceInvitesCard: View {
    @Bindable var model: WorkspaceSectionModel

    var body: some View {
        Card(title: "Invite people", systemImage: "envelope") {
            TextField("Email addresses, comma-separated", text: $model.inviteEmails, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            HStack(spacing: 8) {
                VoicesStudioChoicePicker(title: "Seat", selection: $model.inviteSeat, choices: model.seatTypes,
                                         defaultLabel: "Default seat")
                    .fixedSize()
                TextField("Monthly credit limit (optional)", text: $model.inviteUsageLimit)
                    .textFieldStyle(.roundedBorder)
                    .help(VoicesStudioSchema.description("invite_user", "usage_limit"))
            }
            if !model.groups.isEmpty {
                Text("Add them to groups").font(.caption.weight(.medium))
                ForEach(model.groups) { group in
                    Toggle(group.name, isOn: Binding(
                        get: { model.inviteGroups.contains(group.id) },
                        set: { on in if on { model.inviteGroups.insert(group.id) } else { model.inviteGroups.remove(group.id) } }
                    ))
                }
            }
            if !model.inviteProblems.isEmpty { ElevenLabsProblemList(problems: model.inviteProblems) }
            HStack {
                Spacer()
                Button("Send invitations…") { Task { await model.invite() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
            Divider()
            Text("Withdraw an invitation").font(.headline)
            HStack(spacing: 8) {
                TextField("Email address", text: $model.withdrawEmail).textFieldStyle(.roundedBorder)
                Button("Withdraw…") { Task { await model.withdrawInvite() } }
                    .disabled(model.withdrawEmail.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct WorkspaceGroupsCard: View {
    @Bindable var model: WorkspaceSectionModel

    var body: some View {
        Card(title: "Groups", systemImage: "person.2.circle") {
            HStack(spacing: 8) {
                TextField("Find a group by name", text: $model.groupSearch)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.searchGroups() } }
                Button("Find") { Task { await model.searchGroups() } }
                Button("All groups") { Task { await model.refreshGroups() } }
            }
            VoicesStudioListState(loading: model.actions.isRunning("get_groups_endpoint"),
                                  problem: model.actions.problem("get_groups_endpoint") ?? model.actions.problem("search_groups"),
                                  isEmpty: model.groups.isEmpty && model.groupsAnswer == nil, emptyText: "No groups.")
            if let answer = model.groupsAnswer {
                ElevenLabsJSONBlock(value: answer, label: "Groups, as ElevenLabs sent them")
            }
            ForEach(model.groups) { group in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(group.name).font(.callout.weight(.medium))
                        Text(group.id).font(.caption.monospaced()).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                    ForEach(group.members, id: \.self) { email in
                        HStack {
                            Text(email).font(.callout)
                            Spacer()
                            Button("Remove…") { Task { await model.removeMember(email, from: group) } }.controlSize(.small)
                        }
                        .padding(.leading, 12)
                    }
                    HStack(spacing: 8) {
                        TextField("Member's email", text: Binding(
                            get: { model.memberEmail[group.id] ?? "" }, set: { model.memberEmail[group.id] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("Add to group…") { Task { await model.addMember(to: group) } }
                    }
                    .padding(.leading, 12)
                }
                Divider()
            }
        }
    }
}

struct WorkspaceSharingCard: View {
    @Bindable var model: WorkspaceSectionModel

    var body: some View {
        Card(title: "Who a resource is shared with", systemImage: "square.and.arrow.up.on.square") {
            HStack(spacing: 8) {
                VoicesStudioChoicePicker(title: "Kind", selection: $model.resourceType, choices: model.resourceTypes,
                                         defaultLabel: "Choose a kind")
                    .fixedSize()
                TextField("Resource id (a voice, project, agent…)", text: $model.resourceID).textFieldStyle(.roundedBorder)
                Button("Look up") { Task { await model.loadResource() } }
                    .disabled(model.resourceID.isEmpty || model.resourceType.isEmpty)
            }
            if let resource = model.resource {
                Text(resource.name).font(.headline)
                ForEach(resource.roles.keys.sorted(), id: \.self) { role in
                    VoicesStudioFact(VoicesStudioFormat.words(role), (resource.roles[role] ?? []).joined(separator: ", "))
                }
                Divider()
                HStack(spacing: 8) {
                    Picker("With", selection: $model.shareTarget) {
                        Text("Choose").tag("")
                        Text("Everyone (baseline role)").tag("default")
                        ForEach(resource.shareOptions) { Text("\($0.name) (\($0.type))").tag($0.id) }
                    }
                    .fixedSize()
                    TextField("…or an email", text: $model.shareEmail).textFieldStyle(.roundedBorder)
                    VoicesStudioChoicePicker(title: "Role", selection: $model.shareRole, choices: model.roles,
                                             defaultLabel: "Role")
                        .fixedSize()
                }
                HStack {
                    Spacer()
                    Button("Stop sharing…") { Task { await model.unshare() } }
                        .disabled(model.targetArguments().isEmpty)
                    Button("Share…") { Task { await model.share() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(model.targetArguments().isEmpty || model.shareRole.isEmpty)
                }
            }
        }
    }
}

struct WorkspaceConnectionsCard: View {
    @Bindable var model: WorkspaceSectionModel

    var body: some View {
        Card(title: "Sign-in connections", systemImage: "key.horizontal") {
            Text("Credentials agents and tools use to sign in to other services.").font(.caption).foregroundStyle(.secondary)
            VoicesStudioListState(loading: model.actions.isRunning("list_auth_connections"),
                                  problem: model.actions.problem("list_auth_connections"),
                                  isEmpty: model.connections.isEmpty, emptyText: "No sign-in connections.")
            ForEach(model.connections) { connection in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(connection.name).font(.callout.weight(.medium))
                        Text([VoicesStudioFormat.words(connection.authType), connection.provider,
                              connection.usedBy > 0 ? "used by \(connection.usedBy)" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let status = connection.status { VoicesStudioStatusBadge(status: status) }
                    if model.canEdit(connection) {
                        Button("Edit") { model.edit(connection) }.controlSize(.small)
                    }
                    Button(role: .destructive) { Task { await model.deleteConnection(connection) } } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete \(connection.name)")
                }
            }
            if let editing = model.editingConnection,
               let form = model.connectionForm("update_auth_connection", authType: editing.authType) {
                Divider()
                Text("Change “\(editing.name)”").font(.headline)
                ElevenLabsOperationForm(form: form, showsHeadings: false)
                HStack {
                    Button("Cancel") { model.edit(nil) }
                    Spacer()
                    Button("Save…") { Task { await model.updateConnection() } }.buttonStyle(.borderedProminent)
                }
            }
            Divider()
            Text("New connection").font(.headline)
            Picker("Kind", selection: $model.newConnectionType) {
                ForEach(model.createKinds) { Text(VoicesStudioFormat.words($0.authType)).tag($0.authType) }
            }
            .onAppear { if model.newConnectionType.isEmpty { model.newConnectionType = model.createKinds.first?.authType ?? "" } }
            if let form = model.connectionForm("create_auth_connection", authType: model.newConnectionType) {
                ElevenLabsOperationForm(form: form, showsHeadings: false)
                    .id(model.newConnectionType)
            }
            HStack {
                Spacer()
                Button("Create connection…") { Task { await model.createConnection() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
    }
}

struct WorkspaceAuditCard: View {
    @Bindable var model: WorkspaceSectionModel

    var body: some View {
        Card(title: "Audit log", systemImage: "list.bullet.clipboard") {
            HStack(spacing: 8) {
                TextField("Activity (e.g. Subscription Creation)", text: $model.auditActivity)
                TextField("Class (e.g. Account Change)", text: $model.auditClass)
                Button("Filter") { Task { await model.refreshAudit() } }
            }
            .textFieldStyle(.roundedBorder)
            VoicesStudioListState(loading: model.actions.isRunning("get_workspace_audit_logs"),
                                  problem: model.actions.problem("get_workspace_audit_logs"),
                                  isEmpty: model.audit.isEmpty, emptyText: "Nothing logged.")
            ForEach(model.audit) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(VoicesStudioFormat.date(iso: entry.time) ?? entry.time)
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(entry.activity).font(.callout.weight(.medium))
                            if entry.failed { Badge(text: "Failed", tint: .red) }
                        }
                        Text([entry.actor, entry.className].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        if !entry.message.isEmpty {
                            Text(entry.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }
            VoicesStudioMoreButton(hasMore: model.auditHasMore, loading: model.actions.isRunning("get_workspace_audit_logs")) {
                Task { await model.moreAudit() }
            }
        }
    }
}
