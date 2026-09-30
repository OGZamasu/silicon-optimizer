import Foundation
import Observation
import SiliconElevenLabs

/// A workspace webhook, as the list gives it.
struct WorkspaceWebhook: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var url: String
    var isDisabled: Bool
    var isAutoDisabled: Bool
    var authType: String?
    var events: [String]
    var usages: [String]
    var lastFailureCode: Int?
    var lastFailureAt: Int?
    var createdAt: Int?

    init?(json: JSONValue) {
        guard let id = json["webhook_id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        url = json["webhook_url"].stringValue ?? ""
        isDisabled = json["is_disabled"].boolValue ?? false
        isAutoDisabled = json["is_auto_disabled"].boolValue ?? false
        authType = json["auth_type"].stringValue
        events = json["events"].arrayValue?.compactMap(\.stringValue) ?? []
        usages = (json["usage"].arrayValue ?? []).compactMap { $0["usage_type"].stringValue }
        lastFailureCode = json["most_recent_failure_error_code"].intValue
        lastFailureAt = json["most_recent_failure_timestamp"].intValue
        createdAt = json["created_at_unix"].intValue
    }
}

struct WebhookDraft: Hashable, Sendable {
    var name = ""
    var url = ""
    /// "Name: value" per line.
    var headers = ""
    var events: Set<String> = []
    var retry = true
    var disabled = false
}

/// Workspace webhooks: where ElevenLabs posts events. A new webhook's signing secret is shown
/// once. Every change sends the workspace's events somewhere, so each one asks first.
@MainActor
@Observable
final class WebhooksSectionModel {
    let actions: VoicesStudioActions
    var includeUsages = false
    private(set) var webhooks: [WorkspaceWebhook] = []
    private(set) var loadedOnce = false
    var draft = WebhookDraft()
    private(set) var editing: WorkspaceWebhook?
    private(set) var problems: [String] = []

    init(environment: VoicesStudioEnvironment) {
        actions = VoicesStudioActions(context: environment.context)
    }

    // MARK: Spec

    static let controls: [VoicesStudioControl] = [
        .init("get_workspace_webhooks_route", "include_usages"),
        .init("create_workspace_webhook_route", "settings.auth_type"),
        .init("create_workspace_webhook_route", "settings.name"),
        .init("create_workspace_webhook_route", "settings.webhook_url"),
        .init("create_workspace_webhook_route", "settings.request_headers"),
        .init("edit_workspace_webhook_route", "name"),
        .init("edit_workspace_webhook_route", "is_disabled"),
        .init("edit_workspace_webhook_route", "events", enumerated: true),
        .init("edit_workspace_webhook_route", "retry_enabled"),
        .init("edit_workspace_webhook_route", "request_headers"),
        .init("delete_workspace_webhook_route", "webhook_id"),
    ]

    static let callsWithoutControls: Set<String> = []
    static let explorerOnly: [String: String] = [:]

    var eventChoices: [String] { VoicesStudioSchema.choices("edit_workspace_webhook_route", "events") }

    // MARK: List

    var listProblem: String? { actions.problem("get_workspace_webhooks_route") }
    var isListing: Bool { actions.isRunning("get_workspace_webhooks_route") }

    func refresh() async {
        guard let json = await actions.perform(
            "get_workspace_webhooks_route", ["include_usages": .bool(includeUsages)], quietly: true
        )?.voicesStudioJSON else { return }
        webhooks = (json["webhooks"].arrayValue ?? []).compactMap(WorkspaceWebhook.init(json:))
        loadedOnce = true
    }

    func refreshIfNeeded() async {
        guard !loadedOnce else { return }
        await refresh()
    }

    // MARK: Changes

    nonisolated static func headers(_ text: String) -> [String: JSONValue] {
        var headers: [String: JSONValue] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { headers[parts[0]] = .string(parts[1]) }
        }
        return headers
    }

    func createArguments() -> ([String: JSONValue], [String]) {
        var problems: [String] = []
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        let url = draft.url.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { problems.append("Give the webhook a name.") }
        if !url.lowercased().hasPrefix("https://") { problems.append("The address must be an https:// URL, as the spec asks.") }
        var settings: [String: JSONValue] = ["auth_type": "hmac", "name": .string(name), "webhook_url": .string(url)]
        let headers = Self.headers(draft.headers)
        if !headers.isEmpty { settings["request_headers"] = .object(headers) }
        return (["settings": .object(settings)], problems)
    }

    func create() async {
        let (arguments, problems) = createArguments()
        self.problems = problems
        guard problems.isEmpty,
              await actions.perform(
                "create_workspace_webhook_route", arguments, subject: "a webhook to \(draft.url)",
                consequence: "ElevenLabs will send the events you subscribe it to — with the data they carry — "
                    + "to \(draft.url). Its signing secret is shown once."
              ) != nil else { return }
        draft = WebhookDraft()
        await refresh()
    }

    func edit(_ webhook: WorkspaceWebhook?) {
        editing = webhook
        guard let webhook else {
            draft = WebhookDraft()
            return
        }
        draft = WebhookDraft(name: webhook.name, url: webhook.url, headers: "", events: Set(webhook.events),
                             retry: true, disabled: webhook.isDisabled)
    }

    func editArguments() -> [String: JSONValue]? {
        guard let webhook = editing else { return nil }
        var arguments: [String: JSONValue] = [
            "webhook_id": .string(webhook.id), "name": .string(draft.name), "is_disabled": .bool(draft.disabled),
            "events": .array(draft.events.sorted().map(JSONValue.string)), "retry_enabled": .bool(draft.retry),
        ]
        let headers = Self.headers(draft.headers)
        if !headers.isEmpty { arguments["request_headers"] = .object(headers) }
        return arguments
    }

    func save() async {
        guard let webhook = editing, let arguments = editArguments() else { return }
        let added = draft.events.subtracting(webhook.events).sorted()
        guard await actions.perform(
            "edit_workspace_webhook_route", arguments, subject: "the webhook “\(webhook.name)”",
            consequence: added.isEmpty
                ? "\(webhook.url) gets \(draft.disabled ? "nothing until turned on again" : "the events listed")."
                : "\(webhook.url) starts receiving \(added.map(VoicesStudioFormat.words).joined(separator: ", ")) events."
        ) != nil else { return }
        edit(nil)
        await refresh()
    }

    func delete(_ webhook: WorkspaceWebhook) async {
        guard await actions.perform(
            "delete_workspace_webhook_route", ["webhook_id": .string(webhook.id)], subject: "the webhook “\(webhook.name)”",
            consequence: webhook.usages.isEmpty ? "\(webhook.url) stops receiving events."
                : "\(webhook.url) stops receiving events, and \(webhook.usages.count) things using it lose their notifications."
        ) != nil else { return }
        await refresh()
    }

    // MARK: Test support

    func load(webhooks: [WorkspaceWebhook]) {
        self.webhooks = webhooks
        loadedOnce = true
    }
}
