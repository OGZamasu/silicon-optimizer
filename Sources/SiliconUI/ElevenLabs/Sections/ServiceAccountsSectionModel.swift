import Foundation
import Observation
import SiliconElevenLabs

// MARK: - Data

struct ServiceAccount: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var createdAt: Int?
    var keys: [ServiceAccountKey]

    init?(json: JSONValue) {
        guard let id = json["service_account_user_id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        createdAt = json["created_at_unix"].intValue
        keys = (json["api-keys"].arrayValue ?? []).compactMap(ServiceAccountKey.init(json:))
    }
}

/// A service account's API key, as listed: never the key itself, only its hint.
struct ServiceAccountKey: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var hint: String
    var isDisabled: Bool
    var disableReason: String?
    var permissions: [String]
    var characterLimit: Int?
    var characterCount: Int?
    var allowedIPs: [String]
    var createdAt: Int?

    init?(json: JSONValue) {
        guard let id = json["key_id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        hint = json["hint"].stringValue ?? ""
        isDisabled = json["is_disabled"].boolValue ?? false
        disableReason = json["disable_reason"].stringValue
        permissions = json["permissions"].arrayValue?.compactMap(\.stringValue) ?? []
        characterLimit = json["character_limit"].intValue
        characterCount = json["character_count"].intValue
        allowedIPs = json["allowed_ips"].arrayValue?.compactMap(\.stringValue) ?? []
        createdAt = json["created_at_unix"].intValue
    }
}

/// The key form: a new key, or the changes to one.
struct ServiceAccountKeyDraft: Hashable, Sendable {
    var name = ""
    var allPermissions = true
    var permissions: Set<String> = []
    /// Blank for no monthly limit.
    var characterLimit = ""
    /// One address or CIDR range per line; blank for any.
    var allowedIPs = ""
    /// Nil leaves the workspace's default.
    var holderMayDisable: Bool?
}

// MARK: - Model

/// Service accounts: machine identities for the workspace and their API keys — created with
/// permissions, limits and allowed addresses, the new key shown once; keys renamed, limited,
/// turned off or deleted; the workspace's rule on key holders disabling their own keys; and a
/// switch to disable the very key this app uses.
@MainActor
@Observable
final class ServiceAccountsSectionModel {
    let actions: VoicesStudioActions

    private(set) var accounts: [ServiceAccount] = []
    private(set) var loadedOnce = false
    private(set) var selected: ServiceAccount?
    var newAccountName = ""
    /// Group id → permission level for a new account's default sharing.
    var newAccountGroups: [String: String] = [:]
    var newGroupID = ""
    var newGroupLevel = "viewer"

    var keyDraft = ServiceAccountKeyDraft()
    /// The key being changed, when the form edits one.
    private(set) var editingKey: ServiceAccountKey?
    private(set) var problems: [String] = []

    /// The workspace policy choice: "allow", "forbid" or "clear".
    var policy = "clear"

    init(environment: VoicesStudioEnvironment) {
        actions = VoicesStudioActions(context: environment.context)
        actions.readsShownInPlace = ["get_workspace_service_accounts"]
    }

    // MARK: Spec

    static let controls: [VoicesStudioControl] = [
        .init("create_service_account", "name"),
        .init("create_service_account", "default_sharing_groups[].group_id"),
        .init("create_service_account", "default_sharing_groups[].permission_level", enumerated: true),
        .init("get_service_account_api_keys_route", "service_account_user_id"),
        .init("create_service_account_api_key", "name"),
        .init("create_service_account_api_key", "permissions", enumerated: true),
        .init("create_service_account_api_key", "character_limit"),
        .init("create_service_account_api_key", "allowed_ips"),
        .init("create_service_account_api_key", "third_party_disable_allowed"),
        .init("edit_service_account_api_key", "name"),
        .init("edit_service_account_api_key", "is_enabled"),
        .init("edit_service_account_api_key", "permissions", enumerated: true),
        .init("edit_service_account_api_key", "character_limit"),
        .init("edit_service_account_api_key", "allowed_ips"),
        .init("edit_service_account_api_key", "third_party_disable_allowed"),
        .init("delete_service_account_api_key", "api_key_id"),
        .init("set_third_party_disabling_policy", "third_party_disable_allowed"),
        .init("disable", "api_key_name", describedValues: ["self"]),
    ]

    static let callsWithoutControls: Set<String> = ["get_workspace_service_accounts"]
    static let explorerOnly: [String: String] = [:]

    /// The permissions a key can be given, from the spec's enum (`all` is its own switch).
    var permissionChoices: [String] {
        VoicesStudioSchema.choices("create_service_account_api_key", "permissions").filter { $0 != "all" }
    }
    var levels: [String] { VoicesStudioSchema.choices("create_service_account", "default_sharing_groups[].permission_level") }

    // MARK: Accounts

    var listProblem: String? { actions.problem("get_workspace_service_accounts") }
    var isListing: Bool { actions.isRunning("get_workspace_service_accounts") }

    func refresh() async {
        guard let json = await actions.perform("get_workspace_service_accounts", quietly: true)?.voicesStudioJSON
        else { return }
        accounts = (json["service-accounts"].arrayValue ?? []).compactMap(ServiceAccount.init(json:))
        loadedOnce = true
        if let id = selected?.id { selected = accounts.first { $0.id == id } }
    }

    func refreshIfNeeded() async {
        guard !loadedOnce else { return }
        await refresh()
    }

    func select(_ id: String?) {
        // A key shown once belongs to the account it was made for: it is not shown under the
        // next one.
        if selected?.id != id { actions.dismissCredentials() }
        selected = accounts.first { $0.id == id }
        editingKey = nil
        keyDraft = ServiceAccountKeyDraft()
    }

    func createAccountArguments() -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["name": .string(newAccountName.trimmingCharacters(in: .whitespaces))]
        if !newAccountGroups.isEmpty {
            arguments["default_sharing_groups"] = .array(newAccountGroups.keys.sorted().map { id in
                ["group_id": .string(id), "permission_level": .string(newAccountGroups[id] ?? "viewer")]
            })
        }
        return arguments
    }

    func createAccount() async {
        let name = newAccountName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty,
              let json = await actions.perform(
                "create_service_account", createAccountArguments(), subject: "a service account “\(name)”",
                question: VoicesStudioQuestion(
                    "Create the service account “\(name)”?", button: "Create account",
                    consequence: "A new identity joins the workspace; keys made for it can act on the workspace's "
                        + "resources as their permissions allow."
                )
              )?.voicesStudioJSON else { return }
        newAccountName = ""
        newAccountGroups = [:]
        await refresh()
        select(json["service-account-user-id"].stringValue)
    }

    // MARK: Keys

    /// Fetches the keys of `accountID` (the selected account when nil) — after a change, the
    /// keys of the account the change was made to, whichever is selected by then.
    func refreshKeys(_ accountID: String? = nil) async {
        guard let accountID = accountID ?? selected?.id,
              let json = await actions.perform(
                "get_service_account_api_keys_route", ["service_account_user_id": .string(accountID)], quietly: true
              )?.voicesStudioJSON else { return }
        let keys = (json["api-keys"].arrayValue ?? []).compactMap(ServiceAccountKey.init(json:))
        if let index = accounts.firstIndex(where: { $0.id == accountID }) { accounts[index].keys = keys }
        // Another account may have been chosen meanwhile: these are this account's keys only.
        if selected?.id == accountID { selected?.keys = keys }
    }

    /// The new key's arguments, and every problem with the form.
    func createKeyArguments() -> ([String: JSONValue], [String]) {
        var problems: [String] = []
        var arguments: [String: JSONValue] = [:]
        if let account = selected { arguments["service_account_user_id"] = .string(account.id) }
        let name = keyDraft.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { problems.append("Give the key a name.") }
        arguments["name"] = .string(name)
        if keyDraft.allPermissions {
            arguments["permissions"] = "all"
        } else if keyDraft.permissions.isEmpty {
            problems.append("Choose what the key may do, or allow everything.")
        } else {
            arguments["permissions"] = .array(keyDraft.permissions.sorted().map(JSONValue.string))
        }
        let limit = keyDraft.characterLimit.trimmingCharacters(in: .whitespaces)
        if !limit.isEmpty {
            if let value = Int(limit), value > 0 { arguments["character_limit"] = .number(Double(value)) } else {
                problems.append("The monthly character limit must be a whole number above 0.")
            }
        }
        let ips = keyDraft.allowedIPs.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !ips.isEmpty { arguments["allowed_ips"] = .array(ips.map(JSONValue.string)) }
        if let holder = keyDraft.holderMayDisable { arguments["third_party_disable_allowed"] = .bool(holder) }
        return (arguments, problems)
    }

    func createKey() async {
        guard let account = selected else { return }
        let (arguments, problems) = createKeyArguments()
        self.problems = problems
        guard problems.isEmpty,
              await actions.perform(
                "create_service_account_api_key", arguments,
                subject: "an API key “\(keyDraft.name)” for “\(account.name)”",
                question: VoicesStudioQuestion(
                    "Make the API key “\(keyDraft.name)” for “\(account.name)”?", button: "Make key",
                    consequence: "Whoever holds the new key can use the workspace as its permissions allow, and spend "
                        + "its credits\(keyDraft.characterLimit.isEmpty ? "" : " up to its monthly limit"). It is shown once."
                )
              ) != nil else { return }
        if selected?.id == account.id { keyDraft = ServiceAccountKeyDraft() }
        await refreshKeys(account.id)
    }

    func edit(_ key: ServiceAccountKey?) {
        editingKey = key
        guard let key else {
            keyDraft = ServiceAccountKeyDraft()
            return
        }
        keyDraft = ServiceAccountKeyDraft(
            name: key.name, allPermissions: key.permissions.isEmpty || key.permissions.contains("all"),
            permissions: Set(key.permissions.filter { $0 != "all" }),
            characterLimit: key.characterLimit.map(String.init) ?? "",
            allowedIPs: key.allowedIPs.joined(separator: "\n")
        )
    }

    /// Only what changed: a limit taken away is `clear`, the spec's word for it.
    func editKeyArguments() -> [String: JSONValue]? {
        guard let account = selected, let key = editingKey else { return nil }
        var arguments: [String: JSONValue] = [
            "service_account_user_id": .string(account.id), "api_key_id": .string(key.id),
        ]
        if keyDraft.name != key.name { arguments["name"] = .string(keyDraft.name) }
        let permissions: JSONValue = keyDraft.allPermissions ? "all" : .array(keyDraft.permissions.sorted().map(JSONValue.string))
        let before: JSONValue = key.permissions.isEmpty || key.permissions.contains("all")
            ? "all" : .array(key.permissions.sorted().map(JSONValue.string))
        if permissions != before { arguments["permissions"] = permissions }
        let limit = keyDraft.characterLimit.trimmingCharacters(in: .whitespaces)
        if limit != (key.characterLimit.map(String.init) ?? "") {
            arguments["character_limit"] = limit.isEmpty ? "clear" : (Int(limit).map { .number(Double($0)) } ?? .string(limit))
        }
        let ips = keyDraft.allowedIPs.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if ips != key.allowedIPs { arguments["allowed_ips"] = ips.isEmpty ? "clear" : .array(ips.map(JSONValue.string)) }
        if let holder = keyDraft.holderMayDisable { arguments["third_party_disable_allowed"] = .bool(holder) }
        return arguments
    }

    func saveKey() async {
        // The key and its changes are taken now: the answer acts on these, whatever is open by then.
        guard let key = editingKey, let arguments = editKeyArguments(),
              let accountID = arguments["service_account_user_id"]?.stringValue else { return }
        guard await actions.perform(
            "edit_service_account_api_key", arguments, subject: "the API key “\(key.name)”",
            question: VoicesStudioQuestion(
                "Change the API key “\(key.name)”?", button: "Save changes",
                consequence: "Whatever uses this key gets the new permissions and limits at once."
            )
        ) != nil else { return }
        if editingKey?.id == key.id { edit(nil) }
        await refreshKeys(accountID)
    }

    func setEnabled(_ key: ServiceAccountKey, _ enabled: Bool) async {
        guard let account = selected,
              await actions.perform(
                "edit_service_account_api_key",
                ["service_account_user_id": .string(account.id), "api_key_id": .string(key.id), "is_enabled": .bool(enabled)],
                subject: enabled ? "the API key “\(key.name)” back on" : "the API key “\(key.name)” off",
                question: enabled
                    ? VoicesStudioQuestion("Turn the API key “\(key.name)” back on?", button: "Turn on",
                                           consequence: "Whatever holds this key can use it again.")
                    : VoicesStudioQuestion("Turn off the API key “\(key.name)” of “\(account.name)”?", button: "Turn off key",
                                           consequence: "Whatever uses this key stops working until it is turned back on.")
              ) != nil else { return }
        await refreshKeys(account.id)
    }

    func delete(_ key: ServiceAccountKey) async {
        guard let account = selected,
              await actions.perform(
                "delete_service_account_api_key",
                ["service_account_user_id": .string(account.id), "api_key_id": .string(key.id)],
                subject: "the API key “\(key.name)” of “\(account.name)”",
                consequence: "Whatever uses this key stops working, for good."
              ) != nil else { return }
        await refreshKeys(account.id)
    }

    // MARK: Workspace rules

    func policyArguments() -> [String: JSONValue] {
        switch policy {
        case "allow": ["third_party_disable_allowed": true]
        case "forbid": ["third_party_disable_allowed": false]
        default: ["third_party_disable_allowed": .null]
        }
    }

    func savePolicy() async {
        let words = policy == "allow" ? "let every key's holder disable it"
            : policy == "forbid" ? "stop every key's holder disabling it" : "go back to each key's own setting and the plan default"
        await actions.perform(
            "set_third_party_disabling_policy", policyArguments(), subject: "the workspace's key-disabling rule",
            question: VoicesStudioQuestion(
                "Change the workspace's rule for disabling keys?", button: "Change rule",
                consequence: "Every API key in the workspace will \(words)."
            )
        )
    }

    /// Disables the key this app is connected with — the kill switch for a key that leaked.
    func disableOwnKey() async {
        await actions.perform(
            "disable", ["api_key_name": "self"], subject: "the API key this app uses",
            question: Self.killSwitchQuestion
        )
    }

    static let killSwitchQuestion = VoicesStudioQuestion(
        "Disable the key this Mac uses?", button: "Disable key",
        consequence: "ElevenLabs turns off the key this Mac is connected with. This pane, and every agent or tool "
            + "using that key, stops working.",
        warning: "This app cannot turn it back on — with its key off it can reach nothing — so turning it on "
            + "again, or making a new key, happens on elevenlabs.io; then connect the new key in Settings → ElevenLabs."
    )

    // MARK: Test support

    func load(accounts: [ServiceAccount], selected: ServiceAccount? = nil) {
        self.accounts = accounts
        self.selected = selected
        loadedOnce = true
    }
}
