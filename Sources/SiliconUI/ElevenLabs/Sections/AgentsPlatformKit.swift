import AppKit
import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI
import UniformTypeIdentifiers

// The Agents Platform sections' shared parts: how their view-models run calls, page through
// lists and remember what they loaded, and the few views every one of those screens uses.
// Everything here is the agents sections' own; the shell's runner, confirmation, result views
// and "Show API call" do the actual work.

// MARK: - Calls

/// One runner per operation (and per `slot`, where one screen runs the same operation for
/// several things at once), so each control shows its own progress, error and API call.
@MainActor
final class AgentsCalls {
    let context: ElevenLabsRunner.Context
    private var runners: [String: ElevenLabsRunner] = [:]

    init(context: ElevenLabsRunner.Context) {
        self.context = context
    }

    /// Whether this build's catalog has the operation. A spec refresh that drops one leaves
    /// its control disabled instead of crashing.
    static func isAvailable(_ operationID: String) -> Bool {
        ElevenLabsCatalog.operation(operationID) != nil
    }

    /// The runner for `operationID`, made on first use.
    func runner(_ operationID: String, slot: String = "") -> ElevenLabsRunner {
        let key = slot.isEmpty ? operationID : "\(operationID)#\(slot)"
        if let runner = runners[key] { return runner }
        let operation = ElevenLabsCatalog.operation(operationID) ?? Self.unavailable(operationID)
        let runner = ElevenLabsRunner(operation: operation, context: context)
        runners[key] = runner
        return runner
    }

    /// Runs an operation and returns its answer, or nil when it was refused, declined,
    /// cancelled or failed — the runner says which.
    ///
    /// - Parameters:
    ///   - quiet: For reads that fill a list: kept out of the pane's recent results.
    ///   - subject/consequence: For the confirmation of a destructive or real-world operation.
    ///   The pane asks the question: its title is the shell's verb (or the operation's summary)
    ///   followed by `subject`, so a subject is a noun phrase ("3 real phone calls with “Support”").
    @discardableResult
    func run(
        _ operationID: String, _ arguments: [String: JSONValue] = [:],
        files: [String: [ElevenLabsFile]] = [:], slot: String = "", quiet: Bool = false,
        title: String? = nil, subject: String? = nil, consequence: String? = nil
    ) async -> ElevenLabsResult? {
        guard Self.isAvailable(operationID) else { return nil }
        let runner = runner(operationID, slot: slot)
        runner.recordsResults = !quiet
        if let title { runner.title = title }
        return await runner.perform(
            arguments: arguments, files: files, subject: subject, consequence: consequence
        )
    }

    /// `run`, for an operation that answers JSON: the JSON (`.null` for an empty answer).
    @discardableResult
    func json(
        _ operationID: String, _ arguments: [String: JSONValue] = [:],
        files: [String: [ElevenLabsFile]] = [:], slot: String = "", quiet: Bool = false,
        title: String? = nil, subject: String? = nil, consequence: String? = nil
    ) async -> JSONValue? {
        guard let result = await run(
            operationID, arguments, files: files, slot: slot, quiet: quiet, title: title,
            subject: subject, consequence: consequence
        ) else { return nil }
        return Self.json(of: result)
    }

    /// The JSON in an answer: the body, the collected events, or a JSON part.
    static func json(of result: ElevenLabsResult) -> JSONValue? {
        switch result {
        case .json(let value, _): value
        case .events(let events, _): .array(events)
        case .text(let text, _): .string(text)
        case .parts(let parts, _):
            parts.lazy.compactMap { if case .json(let value) = $0 { value } else { nil } }.first
        case .file: nil
        }
    }

    /// A stand-in for an operation the catalog does not have, so a runner can still be drawn.
    /// `run` never sends it.
    static func unavailable(_ operationID: String) -> ElevenLabsOperation {
        ElevenLabsOperation(
            id: operationID, method: "GET", path: "/unavailable", group: "Unavailable",
            summary: "Not in this build's ElevenLabs catalog", details: "", deprecated: false,
            parameters: [], body: nil, response: .json, risk: .read, billable: false,
            returnsCredential: false, supportsStreaming: false
        )
    }
}

// MARK: - Lists

/// Lets a list's fetch closure reach the view-model that owns the list without keeping it alive.
@MainActor
final class AgentsWeakBox<Value: AnyObject> {
    weak var value: Value?
}

/// One page of a list as ElevenLabs returns it.
struct AgentsPage<Item: Sendable>: Sendable {
    var items: [Item]
    /// What to send for the next page; nil when there is none.
    var cursor: String?
    var hasMore: Bool

    init(items: [Item], cursor: String? = nil, hasMore: Bool? = nil) {
        self.items = items
        self.cursor = cursor
        self.hasMore = hasMore ?? (cursor != nil)
    }
}

/// A list fetched a page at a time: refresh, load more, and edits after a create or delete
/// so the list does not have to be fetched again.
@MainActor
@Observable
final class AgentsPagedList<Item: Identifiable & Sendable> where Item.ID: Sendable {
    private(set) var items: [Item] = []
    private(set) var hasMore = false
    private(set) var loading = false
    /// Whether a fetch has finished at least once.
    private(set) var loaded = false
    /// Why the last fetch failed; the runner has the details.
    private(set) var failed = false

    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private let fetch: @MainActor (_ cursor: String?) async -> AgentsPage<Item>?

    init(fetch: @escaping @MainActor (_ cursor: String?) async -> AgentsPage<Item>?) {
        self.fetch = fetch
    }

    func loadIfNeeded() async {
        guard !loaded, !loading else { return }
        await refresh()
    }

    /// The first page again, replacing what is shown. Asked while a fetch is under way (a
    /// filter changed mid-load), it fetches once more when that one ends, so the list matches
    /// the filters on screen.
    func refresh() async {
        guard !loading else {
            refreshAgain = true
            return
        }
        loading = true
        defer { loading = false }
        repeat {
            refreshAgain = false
            guard let page = await fetch(nil) else {
                failed = true
                return
            }
            failed = false
            items = page.items
            cursor = page.cursor
            hasMore = page.hasMore && page.cursor != nil
            loaded = true
        } while refreshAgain
    }

    @ObservationIgnored private var refreshAgain = false

    /// The next page, appended.
    func loadMore() async {
        guard !loading, hasMore, let cursor else { return }
        loading = true
        defer { loading = false }
        guard let page = await fetch(cursor) else {
            failed = true
            return
        }
        failed = false
        let known = Set(items.map(\.id))
        items += page.items.filter { !known.contains($0.id) }
        self.cursor = page.cursor
        hasMore = page.hasMore && page.cursor != nil
    }

    /// Replaces the list without fetching: for tests, previews, and answers that carry it.
    func set(_ items: [Item], hasMore: Bool = false) {
        self.items = items
        self.hasMore = hasMore
        cursor = nil
        loaded = true
        failed = false
    }

    func item(_ id: Item.ID) -> Item? {
        items.first { $0.id == id }
    }

    /// Puts `item` first, or in place of the one with its id.
    func upsert(_ item: Item) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }
    }

    func remove(_ id: Item.ID) {
        items.removeAll { $0.id == id }
    }

    /// Forgets everything, as before the first fetch.
    func reset() {
        items = []
        hasMore = false
        cursor = nil
        loaded = false
        failed = false
    }
}

// MARK: - Store

/// What the agents sections keep while the app runs: the lists several of them pick from
/// (agents, phone numbers, tools, documents…) and each section's view-model, so a selection
/// made in Agents is still there after a look at Conversations.
///
/// One per pane. The main window rebuilds a section's view every time it is shown, so this
/// lives beside the pane state rather than in any view; a new client (another key or region)
/// starts a fresh store, so nothing from one account shows under another.
@MainActor
@Observable
final class AgentsPlatformStore {
    let calls: AgentsCalls
    let directory: AgentsDirectory
    /// The voices every agent voice picker offers.
    let voices: ElevenLabsVoiceDirectory

    /// Sections the owner is sent to by a link inside another ("Open in Conversations").
    @ObservationIgnored var open: @MainActor (ElevenLabsSection) -> Void

    init(context: ElevenLabsRunner.Context, open: @escaping @MainActor (ElevenLabsSection) -> Void = { _ in }) {
        let calls = AgentsCalls(context: context)
        self.calls = calls
        directory = AgentsDirectory(calls: calls)
        voices = ElevenLabsVoiceDirectory(client: context.client)
        self.open = open
    }

    @ObservationIgnored private(set) lazy var agents = AgentsModel(store: self)
    @ObservationIgnored private(set) lazy var conversations = AgentConversationsModel(store: self)
    @ObservationIgnored private(set) lazy var knowledge = AgentKnowledgeModel(store: self)
    @ObservationIgnored private(set) lazy var tools = AgentToolsModel(store: self)
    @ObservationIgnored private(set) lazy var phoneNumbers = AgentPhoneNumbersModel(store: self)
    @ObservationIgnored private(set) lazy var batchCalls = AgentBatchCallsModel(store: self)
    @ObservationIgnored private(set) lazy var mcpServers = AgentMCPServersModel(store: self)
    @ObservationIgnored private(set) lazy var secrets = AgentSecretsModel(store: self)
    @ObservationIgnored private(set) lazy var testing = AgentTestingModel(store: self)
    @ObservationIgnored private(set) lazy var analytics = AgentAnalyticsModel(store: self)

    // MARK: Which account it belongs to

    /// The client this store was made for, held weakly: once that client is gone (a disconnect,
    /// a new key, a region change), no later client can be mistaken for it — not even one the
    /// allocator places at the same address.
    @ObservationIgnored private weak var madeFor: ElevenLabsClient?
    @ObservationIgnored private var madeWithClient = false

    /// Whether this store holds data for `client`'s account.
    func belongs(to client: ElevenLabsClient?) -> Bool {
        guard madeWithClient else { return client == nil }
        guard let madeFor, let client else { return false }
        return madeFor === client
    }

    fileprivate func claim(for client: ElevenLabsClient?) {
        madeFor = client
        madeWithClient = client != nil
    }

    static let stateKey = "agents.platform"

    /// The running app's store for `model`'s pane, kept in the pane's section state (which the
    /// shell drops on disconnect, a new key or a region change) and checked against the
    /// current client besides, so another account's data is never handed back.
    static func shared(for model: AppModel) -> AgentsPlatformStore {
        let pane = model.elevenLabsPane
        let client = model.elevenLabsClient
        let make = { () -> AgentsPlatformStore in
            let store = AgentsPlatformStore(context: .app(model)) { [weak model] section in
                model?.elevenLabsPane.open(section)
            }
            store.claim(for: client)
            return store
        }
        let store = pane.state(key: stateKey, make: make)
        if store.belongs(to: client) { return store }
        pane.dropSectionStates()
        return pane.state(key: stateKey, make: make)
    }

    /// Puts `store` in place for `model`'s pane: for tests and snapshots with a fake client.
    static func register(_ store: AgentsPlatformStore, for model: AppModel) {
        store.claim(for: model.elevenLabsClient)
        model.elevenLabsPane.dropSectionStates()
        _ = model.elevenLabsPane.state(key: stateKey) { store }
    }
}

/// The lists more than one section picks from, fetched once and shared.
@MainActor
@Observable
final class AgentsDirectory {
    let agents: AgentsPagedList<AgentsAgent>
    let phoneNumbers: AgentsPagedList<AgentsPhoneNumber>
    let tools: AgentsPagedList<AgentsTool>
    let documents: AgentsPagedList<AgentsKnowledgeDocument>
    let mcpServers: AgentsPagedList<AgentsMCPServer>
    let secrets: AgentsPagedList<AgentsSecret>
    let tags: AgentsPagedList<AgentsTag>
    let tests: AgentsPagedList<AgentsTest>
    /// Names of agents looked up by id, for agents the first pages of the list did not reach.
    private(set) var names: [String: String] = [:]
    @ObservationIgnored private let calls: AgentsCalls

    init(calls: AgentsCalls) {
        self.calls = calls
        agents = AgentsPagedList { cursor in
            var arguments: [String: JSONValue] = ["page_size": 100]
            if let cursor { arguments["cursor"] = .string(cursor) }
            guard let json = await calls.json(AgentsOp.listAgents, arguments, slot: "directory", quiet: true)
            else { return nil }
            return AgentsPage(
                items: (json["agents"].arrayValue ?? []).compactMap(AgentsAgent.init(json:)),
                cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
            )
        }
        phoneNumbers = AgentsPagedList { cursor in
            var arguments: [String: JSONValue] = ["page_size": 100]
            if let cursor { arguments["cursor"] = .string(cursor) }
            guard let json = await calls.json(AgentsOp.listPhoneNumbers, arguments, slot: "directory", quiet: true)
            else { return nil }
            return AgentsPage(
                items: (json["phone_numbers"].arrayValue ?? []).compactMap(AgentsPhoneNumber.init(json:)),
                cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
            )
        }
        tools = AgentsPagedList { cursor in
            var arguments: [String: JSONValue] = ["page_size": 100]
            if let cursor { arguments["cursor"] = .string(cursor) }
            guard let json = await calls.json(AgentsOp.listTools, arguments, slot: "directory", quiet: true)
            else { return nil }
            return AgentsPage(
                items: (json["tools"].arrayValue ?? []).compactMap(AgentsTool.init(json:)),
                cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
            )
        }
        documents = AgentsPagedList { cursor in
            var arguments: [String: JSONValue] = ["page_size": 100]
            if let cursor { arguments["cursor"] = .string(cursor) }
            guard let json = await calls.json(AgentsOp.listDocuments, arguments, slot: "directory", quiet: true)
            else { return nil }
            return AgentsPage(
                items: (json["documents"].arrayValue ?? []).compactMap(AgentsKnowledgeDocument.init(json:)),
                cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
            )
        }
        mcpServers = AgentsPagedList { _ in
            guard let json = await calls.json(AgentsOp.listMCPServers, slot: "directory", quiet: true)
            else { return nil }
            return AgentsPage(items: (json["mcp_servers"].arrayValue ?? []).compactMap(AgentsMCPServer.init(json:)))
        }
        secrets = AgentsPagedList { cursor in
            var arguments: [String: JSONValue] = ["page_size": 100]
            if let cursor { arguments["cursor"] = .string(cursor) }
            guard let json = await calls.json(AgentsOp.listSecrets, arguments, slot: "directory", quiet: true)
            else { return nil }
            return AgentsPage(
                items: (json["secrets"].arrayValue ?? []).compactMap(AgentsSecret.init(json:)),
                cursor: json["next_cursor"].stringValue
            )
        }
        tags = AgentsPagedList { cursor in
            var arguments: [String: JSONValue] = ["page_size": 100]
            if let cursor { arguments["cursor"] = .string(cursor) }
            guard let json = await calls.json(AgentsOp.listTags, arguments, slot: "directory", quiet: true)
            else { return nil }
            return AgentsPage(
                items: (json["conversation_tags"].arrayValue ?? []).compactMap(AgentsTag.init(json:)),
                cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
            )
        }
        tests = AgentsPagedList { cursor in
            var arguments: [String: JSONValue] = ["page_size": 100, "types": ["llm", "tool", "simulation"]]
            if let cursor { arguments["cursor"] = .string(cursor) }
            guard let json = await calls.json(AgentsOp.listTests, arguments, slot: "directory", quiet: true)
            else { return nil }
            return AgentsPage(
                items: (json["tests"].arrayValue ?? []).compactMap(AgentsTest.init(json:)),
                cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
            )
        }
    }

    static let arguments: [AgentsArgument] = [
        AgentsOp.listAgents, AgentsOp.listPhoneNumbers, AgentsOp.listTools, AgentsOp.listDocuments, AgentsOp.listSecrets,
        AgentsOp.listTags, AgentsOp.listTests,
    ].flatMap { [AgentsArgument($0, "page_size"), AgentsArgument($0, "cursor")] } + [
        AgentsArgument(AgentsOp.listTests, "types"), AgentsArgument(AgentsOp.agentSummaries, "agent_ids"),
    ]

    /// An agent's name, or its id while neither the list nor a lookup has it.
    func agentName(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "No agent" }
        return agents.item(id)?.name ?? names[id] ?? id
    }

    /// Looks up the names of agents the list does not hold (up to 100 at a time), so rows
    /// that only carry an agent's id can name it.
    func resolveAgentNames(_ ids: [String]) async {
        let unknown = Array(Set(ids.filter { !$0.isEmpty && agents.item($0) == nil && names[$0] == nil }).sorted().prefix(100))
        guard !unknown.isEmpty else { return }
        guard let json = await calls.json(AgentsOp.agentSummaries, ["agent_ids": .array(unknown.map(JSONValue.string))],
                                          quiet: true) else { return }
        for (id, entry) in json.objectValue ?? [:] where entry["status"].stringValue != "failure" {
            if let name = entry["data"]["name"].stringValue { names[id] = name }
        }
    }

    func phoneNumber(_ id: String?) -> AgentsPhoneNumber? {
        guard let id else { return nil }
        return phoneNumbers.item(id)
    }
}

/// Everything the agents sections send, gathered for the spec check.
enum AgentsSections {
    static let all: [ElevenLabsSection] = [
        .agents, .agentConversations, .agentKnowledge, .agentTools, .agentPhoneNumbers, .agentBatchCalls,
        .agentMCPServers, .agentSecrets, .agentTesting, .agentAnalytics,
    ]

    @MainActor
    static var arguments: [AgentsArgument] {
        AgentsDirectory.arguments + AgentsModel.arguments + AgentConversationsModel.arguments
            + AgentKnowledgeModel.arguments + AgentToolsModel.arguments + AgentPhoneNumbersModel.arguments
            + AgentBatchCallsModel.arguments + AgentMCPServersModel.arguments + AgentSecretsModel.arguments
            + AgentTestingModel.arguments + AgentAnalyticsModel.arguments
    }
}

// MARK: - Schema

/// Reading limits and choices from the catalog (the pinned spec), so a slider's range or a
/// menu's values are the API's own rather than remembered ones.
enum AgentsSchema {
    /// The schema at `path` inside `operationID`'s arguments: a parameter name, or a dotted path
    /// into the JSON body where `[]` steps into an array's items. Nil where the catalog has
    /// nothing (or cut the schema short).
    static func schema(_ operationID: String, _ path: String) -> JSONValue? {
        guard let operation = ElevenLabsCatalog.operation(operationID) else { return nil }
        var segments = path.split(separator: ".").map(String.init)
        guard let first = segments.first else { return nil }
        if segments.count == 1, let parameter = operation.parameter(named: first) {
            return parameter.schema
        }
        guard var node = operation.body?.schema else { return nil }
        while !segments.isEmpty {
            var segment = segments.removeFirst()
            var intoItems = false
            if segment.hasSuffix("[]") {
                segment.removeLast(2)
                intoItems = true
            }
            guard let next = property(segment, of: node) else { return nil }
            node = intoItems ? items(of: next) : next
        }
        return node
    }

    /// `name` in an object schema, looking through `anyOf`/`oneOf`/`allOf` wrappers.
    static func property(_ name: String, of schema: JSONValue) -> JSONValue? {
        let schema = JSONSchema.unwrapNullable(schema)
        if let value = schema["properties"].objectValue?[name] { return value }
        for key in ["anyOf", "oneOf", "allOf"] {
            for variant in schema[key].arrayValue ?? [] {
                if let found = property(name, of: variant) { return found }
            }
        }
        return nil
    }

    static func items(of schema: JSONValue) -> JSONValue {
        let schema = JSONSchema.unwrapNullable(schema)
        if schema["items"] != .null { return schema["items"] }
        for variant in schema["anyOf"].arrayValue ?? [] where variant["items"] != .null {
            return variant["items"]
        }
        return .null
    }

    /// The `enum` values at `path`, as strings, in the spec's order.
    static func choices(_ operationID: String, _ path: String) -> [String] {
        guard let schema = schema(operationID, path) else { return [] }
        return enumValues(JSONSchema.unwrapNullable(schema)).compactMap { value in
            value.stringValue ?? value.intValue.map(String.init)
        }
    }

    private static func enumValues(_ schema: JSONValue) -> [JSONValue] {
        if let values = schema["enum"].arrayValue { return values.filter { $0 != .null } }
        for key in ["anyOf", "oneOf", "allOf"] {
            for variant in schema[key].arrayValue ?? [] {
                let found = enumValues(variant)
                if !found.isEmpty { return found }
            }
        }
        return []
    }

    /// The `minimum`…`maximum` range at `path`, or `fallback` where the schema has none.
    static func range(_ operationID: String, _ path: String, fallback: ClosedRange<Double>) -> ClosedRange<Double> {
        guard let schema = schema(operationID, path).map(JSONSchema.unwrapNullable) else { return fallback }
        let low = schema["minimum"].doubleValue ?? fallback.lowerBound
        let high = schema["maximum"].doubleValue ?? fallback.upperBound
        return low <= high ? low...high : fallback
    }

    /// The schema's `default` at `path`.
    static func defaultValue(_ operationID: String, _ path: String) -> JSONValue? {
        guard let raw = schema(operationID, path) else { return nil }
        let value = raw["default"] != .null ? raw["default"] : JSONSchema.unwrapNullable(raw)["default"]
        return value == .null ? nil : value
    }

    static func maxLength(_ operationID: String, _ path: String) -> Int? {
        schema(operationID, path).map(JSONSchema.unwrapNullable)?["maxLength"].intValue
    }
}

/// One argument a screen can send: which operation, and where in its arguments. Sections list
/// every one of theirs, and a test resolves each against the pinned spec — so a spec refresh
/// that renames something fails a test rather than the owner's next call.
struct AgentsArgument: Hashable, Sendable, CustomStringConvertible {
    var operationID: String
    /// A parameter name, or a dotted path into the body; `[]` steps into array items.
    var path: String

    init(_ operationID: String, _ path: String) {
        self.operationID = operationID
        self.path = path
    }

    var description: String { "\(operationID): \(path)" }
}

// MARK: - JSON helpers

enum AgentsJSON {
    /// `value` at a dotted path, creating objects on the way: for building nested bodies.
    static func setting(_ value: JSONValue, at path: String, in object: JSONValue) -> JSONValue {
        let segments = path.split(separator: ".").map(String.init)
        return setting(value, at: segments[...], in: object)
    }

    private static func setting(_ value: JSONValue, at segments: ArraySlice<String>, in object: JSONValue) -> JSONValue {
        guard let first = segments.first else { return value }
        var dictionary = object.objectValue ?? [:]
        dictionary[first] = setting(value, at: segments.dropFirst(), in: dictionary[first] ?? .null)
        return .object(dictionary)
    }

    /// `changes` laid over `base`, objects merged key by key, anything else replaced.
    static func merging(_ changes: JSONValue, into base: JSONValue) -> JSONValue {
        guard case .object(let changed) = changes, case .object(var merged) = base else {
            return changes == .object([:]) ? base : changes
        }
        for (key, value) in changed { merged[key] = merging(value, into: merged[key] ?? .null) }
        return .object(merged)
    }

    /// `value` without the given keys, at any depth.
    static func removing(keys: Set<String>, from value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(object.filter { !keys.contains($0.key) }.mapValues { removing(keys: keys, from: $0) })
        case .array(let array):
            return .array(array.map { removing(keys: keys, from: $0) })
        case .null, .bool, .number, .string:
            return value
        }
    }

    /// The dotted paths of every string holding `text` (the redaction placeholder, say), whole or
    /// in part ("Bearer ‹redacted›").
    static func paths(of text: String, in value: JSONValue, prefix: String = "") -> [String] {
        switch value {
        case .string(let string):
            return string.contains(text) ? [prefix.isEmpty ? "(the whole answer)" : prefix] : []
        case .object(let object):
            return object.keys.sorted().flatMap { paths(of: text, in: object[$0] ?? .null, prefix: prefix.isEmpty ? $0 : "\(prefix).\($0)") }
        case .array(let array):
            return array.enumerated().flatMap { paths(of: text, in: $0.element, prefix: "\(prefix)[\($0.offset)]") }
        case .null, .bool, .number:
            return []
        }
    }

    /// The value at a dotted path.
    static func value(at path: String, in object: JSONValue) -> JSONValue {
        path.split(separator: ".").reduce(object) { $0[String($1)] }
    }

    /// Every leaf path in `value` (objects dotted, arrays as `[]`), for checking what was sent.
    /// Objects the spec leaves open (maps such as dynamic variables) are the caller's to stop at.
    static func leafPaths(_ value: JSONValue, prefix: String = "") -> [String] {
        switch value {
        case .object(let object) where !object.isEmpty:
            return object.keys.sorted().flatMap { key in
                leafPaths(object[key] ?? .null, prefix: prefix.isEmpty ? key : "\(prefix).\(key)")
            }
        case .array(let array) where !array.isEmpty:
            let paths = Set(array.flatMap { leafPaths($0, prefix: prefix + "[]") })
            return paths.sorted()
        default:
            return prefix.isEmpty ? [] : [prefix]
        }
    }

    static func strings(_ value: JSONValue) -> [String] {
        value.arrayValue?.compactMap(\.stringValue) ?? []
    }

    static func date(_ value: JSONValue) -> Date? {
        value.doubleValue.map { Date(timeIntervalSince1970: $0 > 10_000_000_000 ? $0 / 1000 : $0) }
    }
}

// MARK: - Outside addresses

/// What an address an agent will send callers' words to is: refused outright (no host, a
/// password in it, not http or https), or allowed with warnings the confirmation repeats
/// (plain http, this Mac, a private network).
struct AgentsOutsideAddress: Equatable, Sendable {
    var refusal: String?
    var warnings: [String]

    var host: String?

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        warnings = []
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else {
            refusal = "That is not a web address."
            return
        }
        guard scheme == "https" || scheme == "http" else {
            refusal = "Only http and https addresses can be used."
            return
        }
        guard components.user == nil, components.password == nil else {
            refusal = "Leave the user name and password out of the address; put a token in Secrets instead."
            return
        }
        guard let host = components.host?.lowercased(), !host.isEmpty else {
            refusal = "The address has no host."
            return
        }
        self.host = host
        if scheme == "http" {
            warnings.append("It is plain http: what callers say, and any token, travel unencrypted.")
        }
        switch Self.kind(of: host) {
        case .loopback:
            warnings.append("It points at a machine's own loopback (\(host)); ElevenLabs cannot reach this Mac there.")
        case .linkLocal:
            warnings.append("It is a link-local address (\(host)), such as a cloud metadata service.")
        case .privateNetwork:
            warnings.append("It is a private-network address (\(host)).")
        case .public:
            break
        }
    }

    var isAllowed: Bool { refusal == nil }

    enum Kind: Equatable {
        case loopback, linkLocal, privateNetwork, `public`
    }

    /// What a host is, whatever way it is written: a name (`localhost`, `localhost.`, `.local`),
    /// dotted, decimal, hex or octal IPv4 (`127.1`, `2130706433`, `0x7f000001`, `0177.0.0.1`),
    /// or IPv6 including IPv4-mapped (`::1`, `::ffff:127.0.0.1`, `fe80::…`, `fd00::…`).
    static func kind(of rawHost: String) -> Kind {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host.hasSuffix(".localhost") { return .loopback }
        if host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") {
            return .privateNetwork
        }
        if host.contains(":") {
            if let mapped = ipv4Mapped(host) { return kind(ofIPv4: mapped) }
            if host == "::1" || host == "0:0:0:0:0:0:0:1" { return .loopback }
            if host == "::" { return .loopback }
            if host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea") || host.hasPrefix("feb") { return .linkLocal }
            if host.hasPrefix("fc") || host.hasPrefix("fd") { return .privateNetwork }
            return .public
        }
        if let address = ipv4(host) { return kind(ofIPv4: address) }
        return .public
    }

    static func kind(ofIPv4 address: UInt32) -> Kind {
        let a = address >> 24, b = (address >> 16) & 0xFF
        if a == 127 || address == 0 { return .loopback }
        if a == 169 && b == 254 { return .linkLocal }
        if a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) {
            return .privateNetwork
        }
        return .public
    }

    /// An IPv4 address as `inet_aton` reads it: one to four parts, each decimal, `0x` hex or
    /// leading-zero octal, the last part filling the remaining bytes.
    static func ipv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard (1...4).contains(parts.count) else { return nil }
        var values: [UInt64] = []
        for part in parts {
            guard !part.isEmpty else { return nil }
            let value: UInt64?
            if part.hasPrefix("0x") {
                value = UInt64(part.dropFirst(2), radix: 16)
            } else if part.count > 1, part.hasPrefix("0") {
                value = UInt64(part.dropFirst(), radix: 8)
            } else {
                value = UInt64(part, radix: 10)
            }
            guard let value else { return nil }
            values.append(value)
        }
        var address: UInt64 = 0
        for (index, value) in values.enumerated() {
            if index == values.count - 1 {
                let remainingBytes = 4 - index
                guard value < (UInt64(1) << (8 * UInt64(remainingBytes))) else { return nil }
                address = (address << (8 * UInt64(remainingBytes))) | value
            } else {
                guard value < 256 else { return nil }
                address = (address << 8) | value
            }
        }
        return UInt32(truncatingIfNeeded: address)
    }

    /// The IPv4 address inside an IPv4-mapped IPv6 host (`::ffff:127.0.0.1`, `::ffff:7f00:1`).
    static func ipv4Mapped(_ host: String) -> UInt32? {
        guard host.hasPrefix("::ffff:") else { return nil }
        let rest = String(host.dropFirst("::ffff:".count))
        if rest.contains(".") { return ipv4(rest) }
        let groups = rest.split(separator: ":").compactMap { UInt32($0, radix: 16) }
        guard groups.count == 2, groups.allSatisfy({ $0 <= 0xFFFF }) else { return nil }
        return (groups[0] << 16) | groups[1]
    }
}

// MARK: - Formatting

enum AgentsFormat {
    static func date(_ date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "never" }
        return date.formatted(.relative(presentation: .named))
    }

    static func duration(_ seconds: Int?) -> String {
        guard let seconds else { return "—" }
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        let rest = seconds % 60
        if minutes < 60 { return rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    static func bytes(_ bytes: Int?) -> String {
        guard let bytes else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// `snake_case` API words as a reader would write them: "in_progress" → "In progress".
    static func words(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        let spaced = raw.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// "1 recipient", "12 recipients".
    static func count(_ count: Int, _ noun: String, plural: String? = nil) -> String {
        "\(count.formatted()) \(count == 1 ? noun : (plural ?? noun + "s"))"
    }
}

// MARK: - Views

/// A titled group on a section's page.
struct AgentsCard<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String?
    let accessory: Accessory
    let content: Content

    init(
        _ title: String, subtitle: String? = nil, @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                accessory
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
    }
}

extension AgentsCard where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

/// A list beside its detail when the window is wide, above it when narrow.
struct AgentsMasterDetail<Master: View, Detail: View>: View {
    var masterWidth: CGFloat = 290
    let master: Master
    let detail: Detail

    init(masterWidth: CGFloat = 290, @ViewBuilder master: () -> Master, @ViewBuilder detail: () -> Detail) {
        self.masterWidth = masterWidth
        self.master = master()
        self.detail = detail()
    }

    var body: some View {
        AgentsSplitLayout(masterWidth: masterWidth, minimumDetailWidth: 420, spacing: 16) {
            master
            detail
        }
    }
}

/// Two subviews side by side — the first at a fixed width — when the offered width leaves the
/// second at least `minimumDetailWidth`; stacked otherwise. Decided by the width on offer, not
/// by the subviews' ideal sizes (a form's text field would always ask for more).
struct AgentsSplitLayout: Layout {
    var masterWidth: CGFloat
    var minimumDetailWidth: CGFloat
    var spacing: CGFloat

    private func sideBySide(_ width: CGFloat?) -> Bool {
        guard let width, width.isFinite else { return false }
        return width >= masterWidth + spacing + minimumDetailWidth
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? masterWidth + spacing + minimumDetailWidth
        if sideBySide(proposal.width) {
            let detailWidth = width - masterWidth - spacing
            let master = subviews[0].sizeThatFits(ProposedViewSize(width: masterWidth, height: nil))
            let detail = subviews[1].sizeThatFits(ProposedViewSize(width: detailWidth, height: nil))
            return CGSize(width: width, height: max(master.height, detail.height))
        }
        let master = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let detail = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: master.height + spacing + detail.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        if sideBySide(bounds.width) {
            let detailWidth = bounds.width - masterWidth - spacing
            subviews[0].place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: masterWidth, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX + masterWidth + spacing, y: bounds.minY), anchor: .topLeading,
                              proposal: ProposedViewSize(width: detailWidth, height: nil))
        } else {
            let master = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + master.height + spacing), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// A selectable row in one of the sections' lists.
struct AgentsRow<Content: View>: View {
    var selected: Bool
    let action: () -> Void
    let content: Content

    init(selected: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.selected = selected
        self.action = action
        self.content = content()
    }

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    selected ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: .rect(cornerRadius: 7)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A list's rows, its empty and loading states, its error, and "Load more".
struct AgentsListBody<Item: Identifiable & Sendable, Row: View>: View where Item.ID: Sendable {
    let list: AgentsPagedList<Item>
    /// The runner that fetches it, for its error.
    var runner: ElevenLabsRunner?
    var empty: String
    let row: (Item) -> Row

    init(
        _ list: AgentsPagedList<Item>, runner: ElevenLabsRunner? = nil, empty: String,
        @ViewBuilder row: @escaping (Item) -> Row
    ) {
        self.list = list
        self.runner = runner
        self.empty = empty
        self.row = row
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let failure = runner?.failure, list.failed {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.bottom, 6)
            }
            if list.items.isEmpty {
                if list.loading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } else if list.loaded {
                    Text(empty)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)
                }
            }
            ForEach(list.items) { item in
                row(item)
            }
            if list.hasMore {
                Button {
                    Task { await list.loadMore() }
                } label: {
                    HStack(spacing: 6) {
                        if list.loading { ProgressView().controlSize(.small) }
                        Text("Load more")
                    }
                }
                .buttonStyle(.link)
                .disabled(list.loading)
                .padding(.top, 6)
            }
        }
    }
}

/// A coloured status word.
struct AgentsBadge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: .capsule)
    }

    /// The colour for a status word ElevenLabs uses across conversations, calls and tests.
    static func color(forStatus status: String?) -> Color {
        switch status?.lowercased() {
        case "success", "done", "completed", "passed", "resolved", "succeeded", "ready", "active":
            .green
        case "failure", "failed", "error", "cancelled", "canceled", "rejected":
            .red
        case "in-progress", "in_progress", "running", "processing", "dispatched", "initiated", "pending",
             "created", "open", "scheduled":
            .blue
        case "voicemail", "unknown", "merged", "partial":
            .orange
        default:
            .secondary
        }
    }
}

/// A label and a value, one line.
struct AgentsFact: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }
}

/// Where a section has nothing to show yet.
struct AgentsEmptyState: View {
    let title: String
    var message: String?
    var systemImage: String = "tray"

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// A search box with a clear button.
struct AgentsSearchField: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                    onSubmit()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.background, in: .rect(cornerRadius: 7))
        .overlay { RoundedRectangle(cornerRadius: 7).stroke(.separator) }
    }
}

/// A refresh button for a list, spinning while it loads.
struct AgentsRefreshButton<Item: Identifiable & Sendable>: View where Item.ID: Sendable {
    let list: AgentsPagedList<Item>
    var help = "Fetch the list again"

    var body: some View {
        Button {
            Task { await list.refresh() }
        } label: {
            if list.loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .disabled(list.loading)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Picks one agent from the account's agents.
struct AgentsAgentPicker: View {
    let directory: AgentsDirectory
    @Binding var selection: String
    var title = "Agent"
    /// The label of the empty choice; nil when an agent must be chosen.
    var noneTitle: String?

    var body: some View {
        let agents = directory.agents
        Picker(title, selection: $selection) {
            if let noneTitle {
                Text(noneTitle).tag("")
            } else if selection.isEmpty {
                Text("Choose an agent").tag("")
            }
            if !selection.isEmpty, agents.item(selection) == nil {
                Text(selection).tag(selection)
            }
            ForEach(agents.items) { agent in
                Text(agent.name).tag(agent.id)
            }
        }
        .task { await agents.loadIfNeeded() }
    }
}

/// Picks one of the account's phone numbers.
struct AgentsPhoneNumberPicker: View {
    let directory: AgentsDirectory
    @Binding var selection: String
    var title = "From number"
    /// Only numbers that can place calls.
    var outboundOnly = true
    var noneTitle: String?

    var body: some View {
        let numbers = directory.phoneNumbers
        Picker(title, selection: $selection) {
            if let noneTitle {
                Text(noneTitle).tag("")
            } else if selection.isEmpty {
                Text("Choose a number").tag("")
            }
            ForEach(numbers.items.filter { !outboundOnly || $0.supportsOutbound }) { number in
                Text(number.displayName).tag(number.id)
            }
        }
        .task { await numbers.loadIfNeeded() }
    }
}

/// Everything a run leaves on screen — the shell's `ElevenLabsRunnerOutput` — or nothing while
/// the runner has done nothing: a card with several actions would otherwise carry a gap for
/// each. Questions are the pane's to ask; secrets the owner typed are masked by the core.
struct AgentsRunnerOutput: View {
    let runner: ElevenLabsRunner
    var showsResult = false

    var body: some View {
        if runner.phase == .idle, runner.result == nil, runner.failure == nil, runner.credential == nil,
           runner.confirmation == nil {
            EmptyView()
        } else {
            ElevenLabsRunnerOutput(runner: runner, showsResult: showsResult)
        }
    }
}

/// The Run button for the agents screens: the shell's look, but Return runs it only where the
/// screen says it is safe (`isDefault`), and Cancel is offered only where stopping cannot leave
/// something half done in the world.
struct AgentsRunButton: View {
    let runner: ElevenLabsRunner
    var title: String
    var disabled = false
    var disabledReason: String?
    /// Return presses it. Only for reads and edits the owner can take back; never for anything
    /// that asks first.
    var isDefault = false
    /// The risk capsule beside the button; off where it would read as a state ("Changes" next
    /// to a Save with nothing to save).
    var showsRisk = true
    let action: () -> Void

    init(runner: ElevenLabsRunner, title: String = "Run", disabled: Bool = false, disabledReason: String? = nil,
         isDefault: Bool = false, showsRisk: Bool = true, action: @escaping () -> Void) {
        self.runner = runner
        self.title = title
        self.disabled = disabled
        self.disabledReason = disabledReason
        self.isDefault = isDefault
        self.showsRisk = showsRisk
        self.action = action
    }

    var body: some View {
        HStack(spacing: 10) {
            if runner.isRunning {
                ProgressView().controlSize(.small)
                Text("Working…").font(.callout).foregroundStyle(.secondary)
                Button("Cancel") { runner.cancel() }
            } else {
                button
                if showsRisk, runner.operation.risk != .read {
                    ElevenLabsRiskBadge(risk: runner.operation.risk)
                }
                if disabled, let disabledReason, !disabledReason.isEmpty {
                    Label(disabledReason, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let note = ElevenLabsCostNote.text(for: runner.operation) {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var button: some View {
        let base = Button(action: action) { Text(title).frame(minWidth: 60) }
            .buttonStyle(.borderedProminent)
            .tint(runner.operation.requiresConfirmation ? .orange : .accentColor)
            .disabled(disabled || runner.isAwaitingConfirmation)
        if isDefault, !runner.operation.requiresConfirmation, !runner.operation.billable {
            base.keyboardShortcut(.defaultAction)
        } else {
            base
        }
    }
}

// MARK: - Questions the screen asks itself

/// A question for an edit the risk table files as an ordinary change but that reaches live
/// callers or outside servers — merging a branch into main, moving traffic, wiring an MCP
/// server into an agent. Asked in the screen's words before anything is sent.
struct AgentsQuestion: Identifiable, Equatable, Sendable {
    let id = UUID()
    var title: String
    var message: String
    var confirmLabel: String
}

/// Holds the question on screen and what to do on "yes".
@MainActor
@Observable
final class AgentsQuestionBox {
    private(set) var question: AgentsQuestion?
    @ObservationIgnored private var onYes: (@MainActor () async -> Void)?

    func ask(_ question: AgentsQuestion, then onYes: @escaping @MainActor () async -> Void) {
        self.question = question
        self.onYes = onYes
    }

    /// Answers the question on screen; "yes" runs what was waiting for it.
    func answer(_ yes: Bool) async {
        let action = onYes
        question = nil
        onYes = nil
        if yes { await action?() }
    }
}

extension View {
    /// Presents `box`'s question as a sheet-style dialog: Cancel is the default.
    func agentsQuestion(_ box: AgentsQuestionBox) -> some View {
        confirmationDialog(
            box.question?.title ?? "",
            isPresented: Binding(get: { box.question != nil }, set: { if !$0 { Task { await box.answer(false) } } }),
            titleVisibility: .visible,
            presenting: box.question
        ) { question in
            Button(question.confirmLabel, role: .destructive) { Task { await box.answer(true) } }
            Button("Cancel", role: .cancel) { Task { await box.answer(false) } }
        } message: { question in
            Text(question.message)
        }
    }
}

// MARK: - Real-world sends

/// Keeps one kind of real-world send — a batch of calls, a call, a WhatsApp message — from going
/// out twice. Once the owner has confirmed and the request is on its way there is no Cancel:
/// stopping the wait would not stop the call. If the run ends without an answer that proves
/// nothing was placed (cancelled, timed out, the network dropped, ElevenLabs failed), the
/// screen says it may already have been placed, and no second send is possible until the owner
/// says they have checked.
@MainActor
@Observable
final class AgentsSendGuard {
    enum State: Equatable {
        case ready
        case sending
        /// It may have gone out; the text says what to check.
        case uncertain(String)
    }

    private(set) var state: State = .ready
    /// The runner of the send in progress — whichever provider's it is.
    @ObservationIgnored private(set) weak var inFlight: ElevenLabsRunner?

    var canSend: Bool { state == .ready }

    /// Waiting for the owner's answer to the question, rather than for ElevenLabs.
    var isAsking: Bool { isSending && (inFlight?.isAwaitingConfirmation ?? false) }
    var isSending: Bool { state == .sending }

    var warning: String? {
        if case .uncertain(let text) = state { return text }
        return nil
    }

    /// Runs one send. `send` performs the runner; `check` says where to look if the outcome is
    /// unknown ("Batch calls", "Conversations"). Returns the answer, or nil.
    func send(
        runner: ElevenLabsRunner, what: String, check: String, _ send: () async -> JSONValue?
    ) async -> JSONValue? {
        guard state == .ready else { return nil }
        state = .sending
        inFlight = runner
        defer { inFlight = nil }
        let answer = await send()
        if answer != nil {
            state = .ready
            return answer
        }
        if Self.provesNothingWasSent(runner) {
            state = .ready
        } else {
            state = .uncertain(
                "\(what) may already have been placed: the request reached ElevenLabs and no answer came back"
                    + (runner.failure.map { " (\($0.message.trimmingCharacters(in: CharacterSet(charactersIn: ". "))))" } ?? "")
                    + ". Check \(check) before trying again."
            )
        }
        return nil
    }

    /// The owner has looked; another send may go.
    func acknowledge() {
        if case .uncertain = state { state = .ready }
    }

    /// Declined, refused before sending, or refused by ElevenLabs with a reason that means it
    /// did not act: nothing went out.
    static func provesNothingWasSent(_ runner: ElevenLabsRunner) -> Bool {
        switch runner.phase {
        case .idle:
            return true
        case .failed:
            switch runner.failure {
            case .notLinked, .invalidArguments, .credentialUnavailable, .keyRejected, .forbidden, .rateLimited:
                return true
            case .offline, .other, .none:
                return false
            }
        case .cancelled, .running, .awaitingConfirmation, .succeeded:
            return false
        }
    }
}

/// The send button for a real-world send: no Cancel once it is on its way, never the default
/// button, and — after an unknown outcome — the warning and the owner's "I have checked".
struct AgentsSendButton: View {
    let runner: ElevenLabsRunner
    let guardian: AgentsSendGuard
    var title: String
    var disabled = false
    var disabledReason: String?
    /// What sending costs, beside the button.
    var note = "Billed by the minute once answered."
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning = guardian.warning {
                VStack(alignment: .leading, spacing: 6) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("I have checked — allow sending again") { guardian.acknowledge() }
                }
                .padding(10)
                .background(.orange.opacity(0.1), in: .rect(cornerRadius: 8))
            }
            HStack(spacing: 10) {
                if guardian.isSending, !guardian.isAsking {
                    ProgressView().controlSize(.small)
                    Text("Sending — this cannot be stopped from here").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button(action: action) { Text(title).frame(minWidth: 60) }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(disabled || !guardian.canSend)
                    ElevenLabsRiskBadge(risk: runner.operation.risk)
                    if disabled, let disabledReason, !disabledReason.isEmpty {
                        Text(disabledReason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else if guardian.canSend {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// A run's error in one line, for reads that fill a list or a detail.
struct AgentsRunnerError: View {
    let runner: ElevenLabsRunner

    var body: some View {
        if let failure = runner.failure {
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Copies text to the pasteboard.
enum AgentsPasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A small "Copy" button for an id.
struct AgentsCopyButton: View {
    let text: String
    var label = "Copy ID"

    var body: some View {
        Button(label) { AgentsPasteboard.copy(text) }
            .buttonStyle(.link)
            .font(.caption)
    }
}

/// A user–agent transcript: who said what, when, and which tools the agent used.
struct AgentsTranscriptView: View {
    let turns: [AgentsTranscriptTurn]
    var emptyText = "No messages."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if turns.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(turns) { turn in
                HStack(alignment: .top, spacing: 8) {
                    if turn.role == "user" { Spacer(minLength: 40) }
                    VStack(alignment: turn.role == "user" ? .trailing : .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(turn.role == "user" ? "User" : "Agent")
                                .font(.caption.weight(.semibold))
                            if let time = turn.timeInCall {
                                Text(AgentsFormat.clock(time)).font(.caption2.monospacedDigit())
                            }
                            if turn.interrupted { AgentsBadge(text: "Interrupted", color: .orange) }
                        }
                        .foregroundStyle(.secondary)
                        if let message = turn.message, !message.isEmpty {
                            Text(message)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    turn.role == "user" ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.12),
                                    in: .rect(cornerRadius: 10)
                                )
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(turn.toolCalls, id: \.self) { tool in
                            Label(tool, systemImage: "wrench.and.screwdriver")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if turn.role != "user" { Spacer(minLength: 40) }
                }
            }
        }
    }
}

extension AgentsFormat {
    /// "1:05" for 65 seconds into a call.
    static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A multi-choice list of ids with names, as toggles.
struct AgentsChecklist<Item: Identifiable>: View where Item.ID == String {
    let items: [Item]
    @Binding var selection: Set<String>
    let title: (Item) -> String
    var subtitle: ((Item) -> String?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                Toggle(isOn: Binding(
                    get: { selection.contains(item.id) },
                    set: { on in
                        if on { selection.insert(item.id) } else { selection.remove(item.id) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title(item)).lineLimit(1)
                        if let line = subtitle?(item), !line.isEmpty {
                            Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

/// A slider for a number whose range comes from the spec, with its value shown.
struct AgentsSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var format: String = "%.2f"

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: $value, in: range, step: step)
                    .frame(minWidth: 140)
                Text(String(format: format, value))
                    .font(.callout.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }
}

/// Picks files with the open panel.
enum AgentsFilePicker {
    @MainActor
    static func choose(types: [String] = [], multiple: Bool = false) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        if !types.isEmpty {
            panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        }
        return panel.runModal() == .OK ? panel.urls : []
    }
}

