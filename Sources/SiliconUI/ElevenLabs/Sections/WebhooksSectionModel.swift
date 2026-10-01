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
    /// Nil leaves retries as they are: the list never says how they are set.
    var retry: Bool?
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
        actions.readsShownInPlace = ["get_workspace_webhooks_route"]
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
        if !url.lowercased().hasPrefix("https://") { problems.append("The address must be an https:// URL.") }
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

    /// Whether the webhook being edited was listed with its usages — the only way the list
    /// carries its `events` ("Only populated when usages are requested"). Without them its
    /// subscriptions are unknown, so the editor neither shows nor sends them.
    private(set) var eventsKnown = false
    /// The subscriptions the webhook had when the editor opened.
    private var originalEvents: Set<String> = []

    /// The webhook whose editor was last asked for: an answer that arrives after another Edit
    /// was pressed is dropped, so the editor never opens on the wrong webhook.
    @ObservationIgnored private var wantedEdit: String?

    /// Opens the editor, listing the webhooks with their usages first so the events shown (and
    /// any change to them) start from what ElevenLabs holds. When that list cannot be read the
    /// editor is not opened: a save sends the name and whether the webhook is off, and the row
    /// drawn earlier may be older than ElevenLabs (turned off on the website since, say).
    func startEditing(_ webhook: WorkspaceWebhook) async {
        wantedEdit = webhook.id
        let json = await actions.perform(
            "get_workspace_webhooks_route", ["include_usages": true], quietly: true
        )?.voicesStudioJSON
        guard wantedEdit == webhook.id else { return }
        if let json {
            webhooks = (json["webhooks"].arrayValue ?? []).compactMap(WorkspaceWebhook.init(json:))
            includeUsages = true
            guard let fresh = webhooks.first(where: { $0.id == webhook.id }) else {
                // Gone since the list was drawn: nothing to edit, and the old entry is stale.
                edit(nil)
                problems = ["“\(webhook.name)” is no longer in the workspace's webhooks."]
                return
            }
            problems = []
            edit(fresh, eventsKnown: true)
        } else {
            // An editor already open on this webhook (from a read that worked) stays as it is.
            if editing?.id != webhook.id { edit(nil) }
            problems = ["“\(webhook.name)” could not be read again, so it was not opened for editing: press Edit to try again."]
        }
    }

    func edit(_ webhook: WorkspaceWebhook?, eventsKnown: Bool? = nil) {
        if webhook?.id != wantedEdit { wantedEdit = webhook?.id }
        editing = webhook
        guard let webhook else {
            draft = WebhookDraft()
            self.eventsKnown = false
            originalEvents = []
            return
        }
        self.eventsKnown = eventsKnown ?? includeUsages
        originalEvents = Set(webhook.events)
        draft = WebhookDraft(name: webhook.name, url: webhook.url, headers: "", events: Set(webhook.events),
                             retry: nil, disabled: webhook.isDisabled)
    }

    /// Only what the owner changed, besides the two fields the spec requires: the name and
    /// whether it is off. `events` is "the complete set" — sending it replaces every
    /// subscription — so it goes only when the subscriptions were known and changed.
    func editArguments() -> [String: JSONValue]? {
        guard let webhook = editing else { return nil }
        var arguments: [String: JSONValue] = [
            "webhook_id": .string(webhook.id), "name": .string(draft.name), "is_disabled": .bool(draft.disabled),
        ]
        if eventsKnown, draft.events != originalEvents {
            arguments["events"] = .array(draft.events.sorted().map(JSONValue.string))
        }
        if let retry = draft.retry { arguments["retry_enabled"] = .bool(retry) }
        let headers = Self.headers(draft.headers)
        if !headers.isEmpty { arguments["request_headers"] = .object(headers) }
        return arguments
    }

    func save() async {
        guard let webhook = editing, let arguments = editArguments() else { return }
        let added = draft.events.subtracting(originalEvents).sorted()
        let removed = originalEvents.subtracting(draft.events).sorted()
        var consequence: [String] = []
        if arguments["events"] != nil {
            if !added.isEmpty {
                consequence.append("\(webhook.url) starts receiving \(added.map(VoicesStudioFormat.words).joined(separator: ", ")) events.")
            }
            if !removed.isEmpty {
                consequence.append("It stops receiving \(removed.map(VoicesStudioFormat.words).joined(separator: ", ")) events.")
            }
        } else {
            consequence.append("Its event subscriptions stay as they are.")
        }
        if draft.disabled != webhook.isDisabled {
            consequence.append(draft.disabled ? "It receives nothing until it is turned on again." : "It receives events again.")
        }
        guard await actions.perform(
            "edit_workspace_webhook_route", arguments, subject: "the webhook “\(webhook.name)”",
            consequence: consequence.joined(separator: " ")
        ) != nil else { return }
        // Close the editor only if it is still this webhook's, and no other webhook's editor
        // has been asked for meanwhile (closing would drop that request).
        if editing?.id == webhook.id, wantedEdit == webhook.id { edit(nil) }
        await refresh()
    }

    func delete(_ webhook: WorkspaceWebhook) async {
        guard await actions.perform(
            "delete_workspace_webhook_route", ["webhook_id": .string(webhook.id)], subject: "the webhook “\(webhook.name)”",
            consequence: webhook.usages.isEmpty ? "\(webhook.url) stops receiving events."
                : "\(webhook.url) stops receiving events, and \(webhook.usages.count) things using it lose their notifications."
        ) != nil else { return }
        if editing?.id == webhook.id, wantedEdit == webhook.id { edit(nil) }
        await refresh()
    }

    // MARK: Test support

    func load(webhooks: [WorkspaceWebhook]) {
        self.webhooks = webhooks
        loadedOnce = true
    }
}
