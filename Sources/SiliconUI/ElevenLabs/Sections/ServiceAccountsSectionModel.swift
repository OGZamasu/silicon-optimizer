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
        keys = ServiceAccountKey.keys(in: json, of: id)
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
    /// The service account the key belongs to, as the list says — what on/off and delete act
    /// on, whichever account is selected when they are pressed.
    var accountID: String?

    /// The keys in an answer's `api-keys`, each tied to its account (the list's own field, or
    /// the account they were listed under).
    static func keys(in json: JSONValue, of accountID: String) -> [ServiceAccountKey] {
        (json["api-keys"].arrayValue ?? []).compactMap(ServiceAccountKey.init(json:)).map { key in
            var key = key
            if key.accountID == nil { key.accountID = accountID }
            return key
        }
    }

    init?(json: JSONValue) {
        guard let id = json["key_id"].stringValue else { return nil }
        self.id = id
        accountID = json["service_account_user_id"].stringValue
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
        actions.onReadAgain = { [weak self] held in
            guard let self else { return }
            if held.operationID == "create_service_account_api_key", let accountID = held.scope {
                await refreshKeys(accountID)
            } else {
                await refresh()
            }
        }
        // A key held for one account is shown — and checked — under that account only.
        actions.showsHold = { [weak self] held in held.scope == nil || held.scope == self?.selected?.id }
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
        let changesBefore = keyChanges
        guard let json = await actions.perform("get_workspace_service_accounts", quietly: true)?.voicesStudioJSON
        else { return }
        var listed = (json["service-accounts"].arrayValue ?? []).compactMap(ServiceAccount.init(json:))
        for index in listed.indices {
            let id = listed[index].id
            if keyChanges[id, default: 0] != changesBefore[id, default: 0] {
                // A key change of this account answered after this list was asked for: its keys
                // here are older than that change. Keep the ones on screen.
                listed[index].keys = accounts.first { $0.id == id }?.keys ?? listed[index].keys
            } else {
                keysAwaitingRead = keysAwaitingRead.filter { $0.value != id }
            }
        }
        accounts = listed
        loadedOnce = true
        if let id = selected?.id { selected = accounts.first { $0.id == id } }
    }

    func refreshIfNeeded() async {
        guard !loadedOnce else { return }
        await refresh()
    }

    func select(_ id: String?) {
        // A key shown once belongs to the account it was made for: it is not shown under the
        // next one. Nor is what was said about that account's keys (an answer that was lost).
        if selected?.id != id {
            actions.dismissCredentials()
            problems = []
        }
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

    /// What holds "Create account" after its answer was lost.
    nonisolated static func lostAccountMessage(_ name: String) -> String {
        "The answer to creating the service account “\(name)” was lost, so it may have been made. If it is in the "
            + "list, use it — or delete it on elevenlabs.io — rather than making another."
    }

    /// What holds "Make key" after its answer was lost: the key may exist, and its secret —
    /// shown only in that answer — cannot be shown again.
    nonisolated static func lostKeyMessage(_ name: String, account: String) -> String {
        "The answer to making the key “\(name)” for “\(account)” was lost, so it may have been made — its secret "
            + "cannot be shown again. If it is in that account's keys, delete it, then make another."
    }

    func createAccount() async {
        let name = newAccountName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard let json = await actions.perform(
            "create_service_account", createAccountArguments(), subject: "a service account “\(name)”",
            question: VoicesStudioQuestion(
                "Create the service account “\(name)”?", button: "Create account",
                consequence: "A new identity joins the workspace; keys made for it can act on the workspace's "
                    + "resources as their permissions allow."
            ),
            holdIfUnknown: VoicesStudioHold(notice: Self.lostAccountMessage(name), listOperation: "get_workspace_service_accounts")
        )?.voicesStudioJSON else {
            // It may have been made: the list shows whether it was. The name stays typed.
            if actions.outcomeWasUnknown("create_service_account") { await refresh() }
            return
        }
        newAccountName = ""
        newAccountGroups = [:]
        await refresh()
        select(json["service-account-user-id"].stringValue)
    }

    // MARK: Keys

    /// Key changes that have answered, by account. A read of an account's keys asked before one
    /// of them answered is older than it, and is dropped: it would put a key's old permissions
    /// back on its row — for the editor to start from.
    @ObservationIgnored private var keyChanges: [String: Int] = [:]

    /// Keys changed whose account has not been read again since the change answered: key id →
    /// account id. Their rows show what the change sent; Edit waits for the read, so the editor
    /// never starts from a row a change has just made stale.
    private(set) var keysAwaitingRead: [String: String] = [:]

    /// Why `key` cannot be edited now, when it cannot.
    func editBlockReason(_ key: ServiceAccountKey) -> String? {
        guard let accountID = keysAwaitingRead[key.id] else { return nil }
        if actions.problem("get_service_account_api_keys_route", slot: accountID) != nil {
            return "Its keys could not be read again after the last change — read them again to edit it."
        }
        return "Waiting for its keys to be read again after the last change."
    }

    /// Whether `key` waits for its account's keys to be read again, and that read failed.
    func keysReadFailed(for key: ServiceAccountKey) -> Bool {
        guard let accountID = keysAwaitingRead[key.id] else { return false }
        return actions.problem("get_service_account_api_keys_route", slot: accountID) != nil
    }

    /// Fetches the keys of `accountID` (the selected account when nil) — after a change, the
    /// keys of the account the change was made to, whichever is selected by then. Each account's
    /// keys are read on a runner of their own, so reading one account's keys never abandons
    /// another's; a read asked before a key change of its account answered is dropped.
    func refreshKeys(_ accountID: String? = nil) async {
        guard let accountID = accountID ?? selected?.id else { return }
        // Today every read of an account's keys runs here, on that account's runner, and the
        // read a change asks for abandons any older one before its answer is used — so this
        // check cannot be seen to act. It is kept for a future read of the same account made off
        // that runner (an accounts list carries keys too, and has its own check in `refresh`).
        let changesBefore = keyChanges[accountID, default: 0]
        guard let json = await actions.perform(
                "get_service_account_api_keys_route", ["service_account_user_id": .string(accountID)], quietly: true,
                slot: accountID
              )?.voicesStudioJSON,
              keyChanges[accountID, default: 0] == changesBefore else { return }
        let keys = ServiceAccountKey.keys(in: json, of: accountID)
        if let index = accounts.firstIndex(where: { $0.id == accountID }) { accounts[index].keys = keys }
        // Another account may have been chosen meanwhile: these are this account's keys only.
        if selected?.id == accountID { selected?.keys = keys }
        keysAwaitingRead = keysAwaitingRead.filter { $0.value != accountID }
    }

    /// A change to the keys of `accountID` has answered (to `keyID`, when it was one key's):
    /// reads asked before it are stale, and that key's Edit waits for the next read.
    private func noteKeyChange(_ keyID: String?, of accountID: String) {
        keyChanges[accountID, default: 0] += 1
        if let keyID { keysAwaitingRead[keyID] = accountID }
    }

    /// Changes key `keyID` of `accountID` in place, in the account list and in the selection.
    private func updateKey(_ keyID: String, of accountID: String, _ change: (inout ServiceAccountKey) -> Void) {
        if let a = accounts.firstIndex(where: { $0.id == accountID }),
           let k = accounts[a].keys.firstIndex(where: { $0.id == keyID }) {
            change(&accounts[a].keys[k])
        }
        if var account = selected, account.id == accountID, let k = account.keys.firstIndex(where: { $0.id == keyID }) {
            change(&account.keys[k])
            selected = account
        }
    }

    /// `key` with what an answered edit sent: what ElevenLabs holds now.
    nonisolated static func applying(_ arguments: [String: JSONValue], to key: inout ServiceAccountKey) {
        if let name = arguments["name"]?.stringValue { key.name = name }
        if let permissions = arguments["permissions"] {
            key.permissions = permissions.stringValue == "all" ? ["all"] : permissions.arrayValue?.compactMap(\.stringValue) ?? key.permissions
        }
        if let limit = arguments["character_limit"] {
            key.characterLimit = limit.stringValue == "clear" ? nil : limit.intValue ?? key.characterLimit
        }
        if let ips = arguments["allowed_ips"] {
            key.allowedIPs = ips.stringValue == "clear" ? [] : ips.arrayValue?.compactMap(\.stringValue) ?? key.allowedIPs
        }
        if let enabled = arguments["is_enabled"]?.boolValue {
            key.isDisabled = !enabled
            if enabled { key.disableReason = nil }
        }
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
        guard problems.isEmpty else { return }
        guard await actions.perform(
            "create_service_account_api_key", arguments,
            subject: "an API key “\(keyDraft.name)” for “\(account.name)”",
            question: VoicesStudioQuestion(
                "Make the API key “\(keyDraft.name)” for “\(account.name)”?", button: "Make key",
                consequence: "Whoever holds the new key can use the workspace as its permissions allow, and spend "
                    + "its credits\(keyDraft.characterLimit.isEmpty ? "" : " up to its monthly limit"). It is shown once."
            ),
            holdIfUnknown: VoicesStudioHold(
                notice: Self.lostKeyMessage(keyDraft.name, account: account.name), scope: account.id,
                listOperation: "get_service_account_api_keys_route", listSlot: account.id
            )
        ) != nil else {
            // It may have been made, its secret never shown: "Make key" is held until the owner
            // has checked, the draft stays, and the account's keys are read at once.
            if actions.outcomeWasUnknown("create_service_account_api_key") {
                noteKeyChange(nil, of: account.id)
                await refreshKeys(account.id)
            }
            return
        }
        if selected?.id == account.id { keyDraft = ServiceAccountKeyDraft() }
        noteKeyChange(nil, of: account.id)
        await refreshKeys(account.id)
    }

    func edit(_ key: ServiceAccountKey?) {
        // A key changed a moment ago is edited from its next read, not from a row that may not
        // be what ElevenLabs holds.
        if let key, let reason = editBlockReason(key) {
            problems = [reason]
            return
        }
        problems = []
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

    /// What the section says when a key change's answer was lost: the change may have been made.
    nonisolated static func lostAnswerMessage(_ name: String) -> String {
        "The answer to the change of “\(name)” was lost, so it may have been made. Its keys are read again: "
            + "check what it holds before changing it again."
    }

    /// A change to `key` gave no answer, yet may have been carried out (a 5xx, a lost answer, a
    /// cancel after sending): its row may be older than what ElevenLabs holds, and an editor
    /// opened from it would send that older state back with the next change. So it is treated
    /// as a change that may have landed, without claiming what it sent: the editor open on it
    /// closes, its Edit waits, and the account's keys are read again.
    private func keyChangeMayHaveLanded(_ key: ServiceAccountKey, of accountID: String) async {
        noteKeyChange(key.id, of: accountID)
        if editingKey?.id == key.id { edit(nil) }
        problems = [Self.lostAnswerMessage(key.name)]
        await refreshKeys(accountID)
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
        ) != nil else {
            if actions.outcomeWasUnknown("edit_service_account_api_key") {
                await keyChangeMayHaveLanded(key, of: accountID)
            }
            return
        }
        // ElevenLabs now holds what was sent: the row takes it at once (only once the change has
        // answered — a refused change claims nothing), and Edit waits for the keys' next read.
        updateKey(key.id, of: accountID) { Self.applying(arguments, to: &$0) }
        noteKeyChange(key.id, of: accountID)
        if editingKey?.id == key.id { edit(nil) }
        await refreshKeys(accountID)
    }

    /// The account a key belongs to: its own, not whichever is selected when a row is pressed.
    private func account(of key: ServiceAccountKey) -> ServiceAccount? {
        guard let id = key.accountID ?? selected?.id else { return nil }
        return accounts.first { $0.id == id } ?? (selected?.id == id ? selected : nil)
    }

    func setEnabled(_ key: ServiceAccountKey, _ enabled: Bool) async {
        guard let account = account(of: key),
              await actions.perform(
                "edit_service_account_api_key",
                ["service_account_user_id": .string(account.id), "api_key_id": .string(key.id), "is_enabled": .bool(enabled)],
                subject: enabled ? "the API key “\(key.name)” back on" : "the API key “\(key.name)” off",
                question: enabled
                    ? VoicesStudioQuestion("Turn the API key “\(key.name)” back on?", button: "Turn on",
                                           consequence: "Whatever holds this key can use it again.")
                    : VoicesStudioQuestion("Turn off the API key “\(key.name)” of “\(account.name)”?", button: "Turn off key",
                                           consequence: "Whatever uses this key stops working until it is turned back on.")
              ) != nil else {
            // The row would keep the state from before, its button offering the action just
            // taken: read the keys again.
            if let account = account(of: key), actions.outcomeWasUnknown("edit_service_account_api_key") {
                await keyChangeMayHaveLanded(key, of: account.id)
            }
            return
        }
        updateKey(key.id, of: account.id) { Self.applying(["is_enabled": .bool(enabled)], to: &$0) }
        noteKeyChange(key.id, of: account.id)
        await refreshKeys(account.id)
    }

    func delete(_ key: ServiceAccountKey) async {
        guard let account = account(of: key),
              await actions.perform(
                "delete_service_account_api_key",
                ["service_account_user_id": .string(account.id), "api_key_id": .string(key.id)],
                subject: "the API key “\(key.name)” of “\(account.name)”",
                consequence: "Whatever uses this key stops working, for good."
              ) != nil else { return }
        // Gone: its row goes at once, so it cannot be edited or turned on meanwhile.
        if let a = accounts.firstIndex(where: { $0.id == account.id }) { accounts[a].keys.removeAll { $0.id == key.id } }
        if selected?.id == account.id { selected?.keys.removeAll { $0.id == key.id } }
        noteKeyChange(nil, of: account.id)
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
