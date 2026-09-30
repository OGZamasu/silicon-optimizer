import SiliconElevenLabs
import SwiftUI

/// Workspace webhooks: addresses ElevenLabs posts events to, their events and health.
struct WebhooksSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        WebhooksScreen(model: VoicesStudioModels.model(WebhooksSectionModel.self, for: app) {
            WebhooksSectionModel(environment: $0)
        })
    }
}

struct WebhooksScreen: View {
    @Bindable var model: WebhooksSectionModel

    var body: some View {
        ElevenLabsSectionPage(.webhooks) {
            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(model.isListing)
        } content: {
            if let runner = model.actions.runner("create_workspace_webhook_route"), let credential = runner.credential {
                ElevenLabsCredentialReveal(credential: credential) { runner.dismissCredential() }
                    .onDisappear { runner.dismissCredential() }
            }
            Card(title: "Webhooks", systemImage: "arrow.up.forward.app") {
                Toggle("Show what uses each webhook (admins)", isOn: $model.includeUsages)
                    .onChange(of: model.includeUsages) { Task { await model.refresh() } }
                VoicesStudioListState(loading: model.isListing, problem: model.listProblem, isEmpty: model.webhooks.isEmpty,
                                      emptyText: "No webhooks yet.")
                ForEach(model.webhooks) { webhook in
                    WebhookRow(model: model, webhook: webhook)
                    if webhook.id != model.webhooks.last?.id { Divider() }
                }
            }
            WebhookFormCard(model: model)
            VoicesStudioActivity(actions: model.actions, fallback: model.actions.runner("get_workspace_webhooks_route"),
                                 credentialsInline: true)
        }
        .task { await model.refreshIfNeeded() }
        .onDisappear { model.actions.dismissCredentials() }
    }
}

struct WebhookRow: View {
    let model: WebhooksSectionModel
    let webhook: WorkspaceWebhook

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(webhook.name).font(.callout.weight(.medium))
                if webhook.isAutoDisabled {
                    Badge(text: "Turned off by ElevenLabs", tint: .red)
                } else if webhook.isDisabled {
                    Badge(text: "Off", tint: .secondary)
                } else {
                    Badge(text: "On", tint: .green)
                }
                if let auth = webhook.authType { Badge(text: auth.uppercased()) }
                Spacer()
                Button("Edit") { Task { await model.startEditing(webhook) } }.controlSize(.small)
                Button(role: .destructive) { Task { await model.delete(webhook) } } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete \(webhook.name)")
            }
            Text(webhook.url).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if !webhook.events.isEmpty {
                Text("Events: " + webhook.events.map(VoicesStudioFormat.words).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !webhook.usages.isEmpty {
                Text("Used by: " + webhook.usages.map(VoicesStudioFormat.words).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let code = webhook.lastFailureCode {
                Text("Last failure: HTTP \(code)" + (VoicesStudioFormat.date(unixSeconds: webhook.lastFailureAt).map { " on \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }
}

struct WebhookFormCard: View {
    @Bindable var model: WebhooksSectionModel

    var body: some View {
        Card(title: model.editing.map { "Change “\($0.name)”" } ?? "New webhook", systemImage: "plus.circle") {
            TextField("Name", text: $model.draft.name).textFieldStyle(.roundedBorder)
            if model.editing == nil {
                TextField("https:// address", text: $model.draft.url).textFieldStyle(.roundedBorder)
                    .help(VoicesStudioSchema.description("create_workspace_webhook_route", "settings.webhook_url"))
                Text("Signed with HMAC: the secret to check signatures with is shown once, after it is made.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(model.draft.url).font(.caption.monospaced()).foregroundStyle(.secondary)
                if model.eventsKnown {
                    Text("Events").font(.caption.weight(.medium))
                    ForEach(model.eventChoices, id: \.self) { event in
                        Toggle(VoicesStudioFormat.words(event), isOn: Binding(
                            get: { model.draft.events.contains(event) },
                            set: { on in if on { model.draft.events.insert(event) } else { model.draft.events.remove(event) } }
                        ))
                    }
                } else {
                    Text("Its event subscriptions could not be read, so they are left as they are.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Retry after a temporary failure", selection: $model.draft.retry) {
                    Text("Leave as it is").tag(Bool?.none)
                    Text("Retry").tag(Bool?.some(true))
                    Text("Don't retry").tag(Bool?.some(false))
                }
                .help(VoicesStudioSchema.description("edit_workspace_webhook_route", "retry_enabled"))
                Toggle("Turned off", isOn: $model.draft.disabled)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Extra request headers, one “Name: value” per line (optional)").font(.caption).foregroundStyle(.secondary)
                ElevenLabsTextArea(text: $model.draft.headers, prompt: "X-Team: voice", minHeight: 40)
            }
            if !model.problems.isEmpty { ElevenLabsProblemList(problems: model.problems) }
            HStack {
                if model.editing != nil { Button("Cancel") { model.edit(nil) } }
                Spacer()
                Button(model.editing == nil ? "Create webhook…" : "Save…") {
                    Task { model.editing == nil ? await model.create() : await model.save() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
    }
}
