import Foundation
import Observation
import SiliconElevenLabs

// MARK: - Data

/// A pronunciation dictionary, from the list or with its rules.
struct PronunciationDictionary: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var description: String?
    var latestVersionID: String
    var ruleCount: Int
    var permission: String?
    var createdAt: Int?
    var archivedAt: Int?
    var rules: [PronunciationRule]

    init?(json: JSONValue) {
        guard let id = json["id"].stringValue else { return nil }
        self.id = id
        name = json["name"].stringValue ?? id
        description = json["description"].stringValue
        latestVersionID = json["latest_version_id"].stringValue ?? json["version_id"].stringValue ?? ""
        ruleCount = json["latest_version_rules_num"].intValue ?? json["version_rules_num"].intValue ?? 0
        permission = json["permission_on_resource"].stringValue
        createdAt = json["creation_time_unix"].intValue
        archivedAt = json["archived_time_unix"].intValue
        rules = (json["rules"].arrayValue ?? []).compactMap(PronunciationRule.init(json:))
    }

    var isArchived: Bool { archivedAt != nil }
}

/// One rule: say this string as another (an alias) or as these sounds (a phoneme).
struct PronunciationRule: Identifiable, Hashable, Sendable {
    enum Kind: String, CaseIterable, Identifiable, Sendable {
        case alias, phoneme
        var id: String { rawValue }
    }

    var id = UUID()
    var kind: Kind = .alias
    var stringToReplace = ""
    var alias = ""
    var phoneme = ""
    var alphabet = "ipa"
    var caseSensitive = true
    var wordBoundaries = true

    init() {}

    init?(json: JSONValue) {
        guard let string = json["string_to_replace"].stringValue,
              let kind = json["type"].stringValue.flatMap(Kind.init(rawValue:)) else { return nil }
        self.kind = kind
        stringToReplace = string
        alias = json["alias"].stringValue ?? ""
        phoneme = json["phoneme"].stringValue ?? ""
        alphabet = json["alphabet"].stringValue ?? "ipa"
        caseSensitive = json["case_sensitive"].boolValue ?? true
        wordBoundaries = json["word_boundaries"].boolValue ?? true
    }

    /// The rule as the spec's union takes it; nil while it is incomplete.
    var json: JSONValue? {
        let string = stringToReplace.trimmingCharacters(in: .whitespaces)
        guard !string.isEmpty else { return nil }
        var rule: [String: JSONValue] = [
            "string_to_replace": .string(string), "type": .string(kind.rawValue),
            "case_sensitive": .bool(caseSensitive), "word_boundaries": .bool(wordBoundaries),
        ]
        switch kind {
        case .alias:
            guard !alias.isEmpty else { return nil }
            rule["alias"] = .string(alias)
        case .phoneme:
            guard !phoneme.isEmpty, !alphabet.isEmpty else { return nil }
            rule["phoneme"] = .string(phoneme)
            rule["alphabet"] = .string(alphabet)
        }
        return .object(rule)
    }

    /// "Nguyen → Win", "tomato /təˈmɑːtoʊ/ (ipa)".
    var summary: String {
        switch kind {
        case .alias: "\(stringToReplace) → \(alias)"
        case .phoneme: "\(stringToReplace) /\(phoneme)/ (\(alphabet))"
        }
    }
}

// MARK: - Model

/// Pronunciation dictionaries: how names and terms are said, as rules — created from rules or a
/// PLS lexicon, edited rule by rule, renamed, archived and downloaded as PLS.
@MainActor
@Observable
final class PronunciationSectionModel {
    let actions: VoicesStudioActions

    var sort = ""
    var sortDirection = ""
    var includeArchived = true
    private(set) var dictionaries: [PronunciationDictionary] = []
    private(set) var hasMore = false
    @ObservationIgnored private var cursor: String?
    private(set) var loadedOnce = false
    private(set) var selected: PronunciationDictionary?
    var rename = ""
    /// Rules of the selected dictionary chosen for removal, by the string they replace.
    var marked: Set<String> = []

    // New dictionary
    var newName = ""
    var newDescription = ""
    var newAccess = ""
    var newFromFile = false
    var newFile: [URL] = []
    /// The rule editor: new rules, for a new dictionary or to add to the selected one.
    var rules: [PronunciationRule] = [PronunciationRule()]
    private(set) var problems: [String] = []
    private(set) var download: VoicesStudioFile?

    /// The directions `sort_direction`'s description names.
    static let directions = ["DESCENDING", "ASCENDING"]

    init(environment: VoicesStudioEnvironment) {
        actions = VoicesStudioActions(context: environment.context)
        actions.readsShownInPlace = ["get_pronunciation_dictionaries_metadata"]
    }

    // MARK: Spec

    static let controls: [VoicesStudioControl] = [
        .init("get_pronunciation_dictionaries_metadata", "sort", enumerated: true),
        .init("get_pronunciation_dictionaries_metadata", "sort_direction", describedValues: directions),
        .init("get_pronunciation_dictionaries_metadata", "include_archived"),
        .init("get_pronunciation_dictionaries_metadata", "cursor"),
        .init("get_pronunciation_dictionary_metadata", "pronunciation_dictionary_id"),
        .init("add_from_rules", "name"),
        .init("add_from_rules", "description"),
        .init("add_from_rules", "workspace_access", enumerated: true),
        .init("add_from_rules", "rules[].string_to_replace"),
        .init("add_from_rules", "rules[].type"),
        .init("add_from_rules", "rules[].alias"),
        .init("add_from_rules", "rules[].phoneme"),
        .init("add_from_rules", "rules[].alphabet"),
        .init("add_from_rules", "rules[].case_sensitive"),
        .init("add_from_rules", "rules[].word_boundaries"),
        .init("add_from_file", "name"),
        .init("add_from_file", "description"),
        .init("add_from_file", "workspace_access", enumerated: true),
        .init("add_from_file", "file"),
        .init("add_rules", "rules"),
        .init("set_rules", "rules"),
        .init("remove_rules", "rule_strings"),
        .init("patch_pronunciation_dictionary", "name"),
        .init("patch_pronunciation_dictionary", "archived"),
        .init("get_pronunciation_dictionary_version_pls", "dictionary_id"),
        .init("get_pronunciation_dictionary_version_pls", "version_id"),
    ]

    static let callsWithoutControls: Set<String> = []
    static let explorerOnly: [String: String] = [:]

    var sorts: [String] { VoicesStudioSchema.choices("get_pronunciation_dictionaries_metadata", "sort") }
    var accessLevels: [String] { VoicesStudioSchema.choices("add_from_rules", "workspace_access") }

    // MARK: List

    var listProblem: String? { actions.problem("get_pronunciation_dictionaries_metadata") }
    var isListing: Bool { actions.isRunning("get_pronunciation_dictionaries_metadata") }

    func listArguments(cursor: String?) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["page_size": 50, "include_archived": .bool(includeArchived)]
        arguments.voicesStudioSet("sort", VoicesStudioFormat.text(sort))
        arguments.voicesStudioSet("sort_direction", VoicesStudioFormat.text(sortDirection))
        arguments.voicesStudioSet("cursor", cursor.map(JSONValue.string))
        return arguments
    }

    func refresh() async {
        guard let json = await actions.perform(
            "get_pronunciation_dictionaries_metadata", listArguments(cursor: nil), quietly: true
        )?.voicesStudioJSON else { return }
        dictionaries = (json["pronunciation_dictionaries"].arrayValue ?? []).compactMap(PronunciationDictionary.init(json:))
        take(json)
    }

    func loadMore() async {
        guard hasMore, let cursor,
              let json = await actions.perform(
                "get_pronunciation_dictionaries_metadata", listArguments(cursor: cursor), quietly: true
              )?.voicesStudioJSON else { return }
        let known = Set(dictionaries.map(\.id))
        dictionaries += (json["pronunciation_dictionaries"].arrayValue ?? [])
            .compactMap(PronunciationDictionary.init(json:)).filter { !known.contains($0.id) }
        take(json)
    }

    private func take(_ json: JSONValue) {
        cursor = json["next_cursor"].stringValue
        hasMore = json["has_more"].boolValue == true && cursor != nil
        loadedOnce = true
    }

    func refreshIfNeeded() async {
        guard !loadedOnce else { return }
        await refresh()
    }

    /// The dictionary last chosen: an answer that arrives after another was chosen is dropped.
    @ObservationIgnored private var wantedDictionary: String?

    func select(_ id: String?) async {
        wantedDictionary = id
        guard let id else {
            selected = nil
            return
        }
        if selected?.id != id {
            selected = dictionaries.first { $0.id == id }
            // The rename field is this dictionary's from now on: it held the previous one's name,
            // which "Rename" would have sent to this one.
            rename = selected?.name ?? ""
            rulesIn = nil
            marked = []
            download = nil
        }
        await fetch(id)
    }

    /// Changes to each dictionary that have answered, by id. A read asked before one of them
    /// answered is older than it — even when it answers later, on another runner — and is
    /// dropped whole: it would put the old name and rules back on screen.
    @ObservationIgnored private var landed: [String: Int] = [:]

    /// Fetches one dictionary into the list, and onto the screen only while it is still the
    /// chosen one — so a change that finishes after another was chosen does not take it back.
    private func fetch(_ id: String, slot: String? = nil) async {
        let changesBefore = landed[id, default: 0]
        guard let json = await actions.perform(
            "get_pronunciation_dictionary_metadata", ["pronunciation_dictionary_id": .string(id)], quietly: true,
            slot: slot
        )?.voicesStudioJSON, let dictionary = PronunciationDictionary(json: json),
              landed[id, default: 0] == changesBefore else { return }
        if let index = dictionaries.firstIndex(where: { $0.id == id }) { dictionaries[index] = dictionary }
        guard wantedDictionary == id else { return }
        selected = dictionary
        rename = dictionary.name
        rulesIn = id
    }

    /// The dictionary whose rules on screen are what ElevenLabs holds: read since its last
    /// change answered. Between a change answering and the fetch after it, the rules shown are
    /// the ones from before, and "Edit all in the editor" would copy them for a Replace that
    /// undoes the change.
    private(set) var rulesIn: String?

    /// Whether the open dictionary's rules may be copied into the editor.
    var rulesAreIn: Bool { selected != nil && rulesIn == selected?.id }

    /// Why the open dictionary's rules are not in, once nothing is reading them any more: the
    /// fetch after its last change failed, or the read that opened it did. "Edit all" then says
    /// so, beside a Try again (a fresh read of the dictionary), instead of waiting for a read
    /// that is not coming. Nil while the rules are in, or while either read is still on its way.
    var rulesProblem: String? {
        guard let id = selected?.id, !rulesAreIn else { return nil }
        let operation = "get_pronunciation_dictionary_metadata"
        let afterChange = VoicesStudioActions.afterChange(of: id)
        guard !actions.isRunning(operation), !actions.isRunning(operation, slot: afterChange) else { return nil }
        return actions.problem(operation) ?? actions.problem(operation, slot: afterChange)
    }

    /// After a change to dictionary `id`: fetch it again on a runner of its own (the read of a
    /// dictionary opened meanwhile is not abandoned); the screen takes it only while it is open.
    private func refetch(_ id: String) async {
        landed[id, default: 0] += 1
        if rulesIn == id { rulesIn = nil }
        await fetch(id, slot: VoicesStudioActions.afterChange(of: id))
    }

    /// After a change to dictionary `id` that gave no answer: when it may still have been
    /// carried out (a 5xx, a lost answer, a cancel after sending), the same as after one that
    /// answered — the rules on screen may be older than ElevenLabs', and "Edit all" would copy
    /// them for a Replace that undoes the change — so "Edit all" waits and it is read again.
    /// Nothing is claimed: what was sent is not put on screen.
    private func refetchIfUnknown(_ operationID: String, _ id: String) async {
        guard actions.outcomeWasUnknown(operationID) else { return }
        await refetch(id)
    }

    /// Whether dictionary `id` is still the one open — the only one whose rule editor and marks a
    /// finished change may clear.
    private func isOpen(_ id: String) -> Bool { wantedDictionary == id }

    // MARK: Rules

    /// The complete rules in the editor, and a problem for each row that is not.
    func ruleArguments() -> ([JSONValue], [String]) {
        var values: [JSONValue] = []
        var problems: [String] = []
        for (index, rule) in rules.enumerated() {
            let blank = rule.stringToReplace.isEmpty && rule.alias.isEmpty && rule.phoneme.isEmpty
            if blank { continue }
            if let value = rule.json { values.append(value) } else {
                problems.append("Rule \(index + 1) needs the text to replace and its \(rule.kind == .alias ? "alias" : "phoneme and alphabet").")
            }
        }
        if values.isEmpty, problems.isEmpty { problems.append("Write at least one rule.") }
        return (values, problems)
    }

    func createArguments() -> ([String: JSONValue], [String: [ElevenLabsFile]], String, [String]) {
        var problems: [String] = []
        var arguments: [String: JSONValue] = [:]
        let name = newName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { problems.append("Give the dictionary a name.") }
        arguments["name"] = .string(name)
        arguments.voicesStudioSet("description", VoicesStudioFormat.text(newDescription))
        arguments.voicesStudioSet("workspace_access", VoicesStudioFormat.text(newAccess))
        if newFromFile {
            guard let file = newFile.first else {
                return (arguments, [:], "add_from_file", problems + ["Choose the .pls file."])
            }
            return (arguments, ["file": [ElevenLabsFile(url: file)]], "add_from_file", problems)
        }
        let (values, ruleProblems) = ruleArguments()
        arguments["rules"] = .array(values)
        return (arguments, [:], "add_from_rules", problems + ruleProblems)
    }

    func create() async {
        let (arguments, files, operation, problems) = createArguments()
        self.problems = problems
        let chosen = wantedDictionary
        guard problems.isEmpty,
              let json = await actions.perform(operation, arguments, files: files, title: "Dictionary \(newName)")?
                .voicesStudioJSON, let id = json["id"].stringValue else { return }
        newName = ""
        newDescription = ""
        newFile = []
        await refresh()
        // The rule editor is shared with the open dictionary: it is cleared, and the new
        // dictionary opened, only if the owner did not open another meanwhile.
        guard wantedDictionary == chosen else { return }
        rules = [PronunciationRule()]
        await select(id)
    }

    func addRules() async {
        guard let dictionary = selected else { return }
        let (values, problems) = ruleArguments()
        self.problems = problems
        guard problems.isEmpty else { return }
        guard await actions.perform(
            "add_rules", ["pronunciation_dictionary_id": .string(dictionary.id), "rules": .array(values)],
            title: "Rules for \(dictionary.name)"
        ) != nil else { return await refetchIfUnknown("add_rules", dictionary.id) }
        if isOpen(dictionary.id) { rules = [PronunciationRule()] }
        await refetch(dictionary.id)
    }

    /// Replaces every rule with the editor's — the rules on screen are what the new version
    /// holds.
    func replaceRules() async {
        guard let dictionary = selected else { return }
        let (values, problems) = ruleArguments()
        self.problems = problems
        guard problems.isEmpty else { return }
        guard await actions.perform(
            "set_rules", ["pronunciation_dictionary_id": .string(dictionary.id), "rules": .array(values)],
            subject: "the rules of “\(dictionary.name)”",
            consequence: "A new version holds only the \(values.count) rules in the editor; the "
                + "\(dictionary.ruleCount) it has now are left in the previous version.",
            title: "Replace rules of \(dictionary.name)"
        ) != nil else { return await refetchIfUnknown("set_rules", dictionary.id) }
        if isOpen(dictionary.id) { rules = [PronunciationRule()] }
        await refetch(dictionary.id)
    }

    /// Puts the dictionary's current rules in the editor, to change and replace them — only once
    /// they are ElevenLabs' current ones (`rulesAreIn`).
    func editCurrentRules() {
        guard rulesAreIn, let dictionary = selected, !dictionary.rules.isEmpty else { return }
        rules = dictionary.rules
    }

    func removeMarked() async {
        guard let dictionary = selected, !marked.isEmpty else { return }
        guard await actions.perform(
            "remove_rules",
            ["pronunciation_dictionary_id": .string(dictionary.id), "rule_strings": .array(marked.sorted().map(JSONValue.string))],
            title: "Remove rules from \(dictionary.name)"
        ) != nil else { return await refetchIfUnknown("remove_rules", dictionary.id) }
        if isOpen(dictionary.id) { marked = [] }
        await refetch(dictionary.id)
    }

    func saveName() async {
        guard let dictionary = selected else { return }
        guard await actions.perform(
            "patch_pronunciation_dictionary",
            ["pronunciation_dictionary_id": .string(dictionary.id), "name": .string(rename)], title: "Rename dictionary"
        ) != nil else { return await refetchIfUnknown("patch_pronunciation_dictionary", dictionary.id) }
        await refetch(dictionary.id)
    }

    func setArchived(_ archived: Bool) async {
        guard let dictionary = selected else { return }
        guard await actions.perform(
            "patch_pronunciation_dictionary",
            ["pronunciation_dictionary_id": .string(dictionary.id), "archived": .bool(archived)],
            title: archived ? "Archive \(dictionary.name)" : "Restore \(dictionary.name)"
        ) != nil else { return await refetchIfUnknown("patch_pronunciation_dictionary", dictionary.id) }
        await refetch(dictionary.id)
    }

    func downloadPLS() async {
        guard let dictionary = selected,
              let result = await actions.perform(
                "get_pronunciation_dictionary_version_pls",
                ["dictionary_id": .string(dictionary.id), "version_id": .string(dictionary.latestVersionID)],
                title: "\(dictionary.name).pls"
              ) else { return }
        download = result.voicesStudioFiles.first
    }

    // MARK: Test support

    func load(dictionaries: [PronunciationDictionary], selected: PronunciationDictionary? = nil) {
        self.dictionaries = dictionaries
        self.selected = selected
        wantedDictionary = selected?.id
        rename = selected?.name ?? ""
        rulesIn = selected?.id
        loadedOnce = true
    }
}
