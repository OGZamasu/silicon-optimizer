import SiliconElevenLabs
import SwiftUI

/// Service accounts: machine identities for the workspace and their API keys. A new key is
/// shown once, where it was made, and never kept.
struct ServiceAccountsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ServiceAccountsScreen(model: VoicesStudioModels.model(ServiceAccountsSectionModel.self, for: app) {
            ServiceAccountsSectionModel(environment: $0)
        })
    }
}

struct ServiceAccountsScreen: View {
    @Bindable var model: ServiceAccountsSectionModel

    var body: some View {
        ElevenLabsSectionPage(.serviceAccounts) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isListing)
        } content: {
            ServiceAccountsListCard(model: model)
            if let account = model.selected {
                ServiceAccountKeysCard(model: model, account: account)
            }
            ServiceAccountsRulesCard(model: model)
            VoicesStudioActivity(actions: model.actions, fallback: model.actions.runner("get_workspace_service_accounts"),
                                 credentialsInline: true)
        }
        .task { await model.refreshIfNeeded() }
    }
}

struct ServiceAccountsListCard: View {
    @Bindable var model: ServiceAccountsSectionModel

    var body: some View {
        Card(title: "Service accounts", systemImage: "person.badge.key") {
            VoicesStudioListState(loading: model.isListing, problem: model.listProblem, isEmpty: model.accounts.isEmpty,
                                  emptyText: "No service accounts yet.")
            ForEach(model.accounts) { account in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.name).font(.callout.weight(.medium))
                        Text("\(account.keys.count) key\(account.keys.count == 1 ? "" : "s")"
                             + (VoicesStudioFormat.date(unixSeconds: account.createdAt).map { " · \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4).padding(.horizontal, 6)
                .background(model.selected?.id == account.id ? Color.accentColor.opacity(0.12) : .clear,
                            in: .rect(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { model.select(account.id) }
            }
            Divider()
            Text("New service account").font(.headline)
            TextField("Name", text: $model.newAccountName).textFieldStyle(.roundedBorder)
            ForEach(model.newAccountGroups.keys.sorted(), id: \.self) { group in
                HStack {
                    Text("Shared with \(group) as \(model.newAccountGroups[group] ?? "")").font(.callout)
                    Spacer()
                    Button("Remove") { model.newAccountGroups[group] = nil }.controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                TextField("Share its work with group id (optional)", text: $model.newGroupID).textFieldStyle(.roundedBorder)
                Picker("As", selection: $model.newGroupLevel) {
                    ForEach(model.levels, id: \.self) { Text(VoicesStudioFormat.words($0)).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button("Add") {
                    model.newAccountGroups[model.newGroupID.trimmingCharacters(in: .whitespaces)] = model.newGroupLevel
                    model.newGroupID = ""
                }
                .disabled(model.newGroupID.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Spacer()
                Button("Create service account…") { Task { await model.createAccount() } }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(model.newAccountName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct ServiceAccountKeysCard: View {
    @Bindable var model: ServiceAccountsSectionModel
    let account: ServiceAccount

    var body: some View {
        Card(title: "Keys of \(account.name)", systemImage: "key") {
            if let runner = model.actions.runner("create_service_account_api_key"), let credential = runner.credential {
                ElevenLabsCredentialReveal(credential: credential) { runner.dismissCredential() }
            }
            if account.keys.isEmpty {
                Text("No keys yet.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(account.keys) { key in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(key.name).font(.callout.weight(.medium))
                            Text("…\(key.hint)").font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(keyLine(key)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    if key.isDisabled {
                        Badge(text: key.disableReason.map { "Off: \(VoicesStudioFormat.words($0))" } ?? "Off", tint: .red)
                    }
                    Button("Edit") { model.edit(key) }.controlSize(.small)
                    Button(key.isDisabled ? "Turn on…" : "Turn off…") { Task { await model.setEnabled(key, key.isDisabled) } }
                        .controlSize(.small)
                    Button(role: .destructive) { Task { await model.delete(key) } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete \(key.name)")
                }
            }
            Divider()
            Text(model.editingKey.map { "Change “\($0.name)”" } ?? "New key").font(.headline)
            TextField("Name", text: $model.keyDraft.name).textFieldStyle(.roundedBorder)
            Toggle("May do everything", isOn: $model.keyDraft.allPermissions)
            if !model.keyDraft.allPermissions {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading) {
                    ForEach(model.permissionChoices, id: \.self) { permission in
                        Toggle(VoicesStudioFormat.words(permission), isOn: Binding(
                            get: { model.keyDraft.permissions.contains(permission) },
                            set: { on in
                                if on { model.keyDraft.permissions.insert(permission) } else { model.keyDraft.permissions.remove(permission) }
                            }
                        ))
                    }
                }
            }
            TextField("Monthly character limit (blank for none)", text: $model.keyDraft.characterLimit)
                .textFieldStyle(.roundedBorder)
                .help(VoicesStudioSchema.description("create_service_account_api_key", "character_limit"))
            VStack(alignment: .leading, spacing: 2) {
                Text("Allowed addresses, one IP or CIDR range per line (blank for any)").font(.caption).foregroundStyle(.secondary)
                ElevenLabsTextArea(text: $model.keyDraft.allowedIPs, prompt: "10.0.0.0/24", minHeight: 40)
            }
            Picker("Holder may disable it", selection: $model.keyDraft.holderMayDisable) {
                Text("Workspace default").tag(Bool?.none)
                Text("Yes").tag(Bool?.some(true))
                Text("No").tag(Bool?.some(false))
            }
            .help(VoicesStudioSchema.description("create_service_account_api_key", "third_party_disable_allowed"))
            if !model.problems.isEmpty { ElevenLabsProblemList(problems: model.problems) }
            HStack {
                if model.editingKey != nil { Button("Cancel") { model.edit(nil) } }
                Spacer()
                Button(model.editingKey == nil ? "Create key…" : "Save changes…") {
                    Task { model.editingKey == nil ? await model.createKey() : await model.saveKey() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
    }

    private func keyLine(_ key: ServiceAccountKey) -> String {
        var parts: [String] = []
        parts.append(key.permissions.isEmpty || key.permissions.contains("all") ? "Everything"
                     : key.permissions.map(VoicesStudioFormat.words).joined(separator: ", "))
        if let limit = key.characterLimit {
            parts.append("\((key.characterCount ?? 0).formatted()) of \(limit.formatted()) characters this month")
        }
        if !key.allowedIPs.isEmpty { parts.append(key.allowedIPs.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

struct ServiceAccountsRulesCard: View {
    @Bindable var model: ServiceAccountsSectionModel
    @State private var danger = false

    var body: some View {
        Card(title: "Workspace rules", systemImage: "checklist") {
            HStack(spacing: 8) {
                Picker("Key holders disabling their own keys", selection: $model.policy) {
                    Text("Each key's own setting").tag("clear")
                    Text("Always allowed").tag("allow")
                    Text("Never allowed").tag("forbid")
                }
                .help(VoicesStudioSchema.description("set_third_party_disabling_policy", "third_party_disable_allowed"))
                Button("Apply…") { Task { await model.savePolicy() } }
            }
            DisclosureGroup("If this app's key leaked", isExpanded: $danger) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Disabling turns off, at ElevenLabs, the key this Mac is connected with. Everything using it "
                         + "stops working until you connect a new key in Settings → ElevenLabs.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Spacer()
                        Button(role: .destructive) { Task { await model.disableOwnKey() } } label: {
                            Label("Disable this app's key…", systemImage: "key.slash")
                        }
                    }
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
    }
}
