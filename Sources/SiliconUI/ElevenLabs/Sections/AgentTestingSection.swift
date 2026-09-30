import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Agent tests: response tests (does the agent answer this well?), simulation tests (a
/// simulated caller with a goal), tool-call tests; folders for them; running a set against an
/// agent and reading each run's verdict; and the older one-off simulated conversation.
struct AgentTestingSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        AgentTestingScreen(model: AgentsPlatformStore.shared(for: app).testing)
    }
}

struct AgentTestingScreen: View {
    @Bindable var model: AgentTestingModel

    var body: some View {
        ElevenLabsSectionPage(.agentTesting, accessory: {
            HStack(spacing: 8) {
                AgentsRefreshButton(list: model.list, help: "Fetch the tests again")
                Button {
                    model.startCreating()
                } label: {
                    Label("New test", systemImage: "plus")
                }
            }
        }) {
            AgentsMasterDetail(masterWidth: 300) {
                AgentTestBrowser(model: model)
            } detail: {
                if model.editing {
                    AgentTestEditor(model: model)
                } else {
                    AgentsCard("No test selected") {
                        AgentsEmptyState(title: "Choose a test",
                                         message: "Or make one: a response the agent should give, or a caller it should handle.",
                                         systemImage: "checkmark.seal")
                    }
                }
            }
            AgentTestRunCard(model: model)
            AgentTestInvocationsCard(model: model)
            AgentSimulationCard(model: model)
        }
        .task { await model.list.loadIfNeeded() }
    }
}

// MARK: - The editable test

/// The parts of a test the form edits. Sent whole on save — the API replaces a test — keeping
/// the fetched values of the fields the form does not show.
struct AgentsTestDraft: Equatable, Sendable {
    struct Turn: Equatable, Sendable, Identifiable {
        var id = UUID()
        var role = "user"
        var message = ""
    }

    /// llm, simulation or tool.
    var type = "llm"
    var name = ""
    var turns: [Turn] = [Turn()]
    var successCondition = ""
    var successExamples = ""
    var failureExamples = ""
    var scenario = ""
    var maxTurns = 5
    var parentFolderID: String?
    var base: JSONValue = .null

    init() {}

    init(json: JSONValue) {
        base = json
        type = json["type"].stringValue ?? "llm"
        name = json["name"].stringValue ?? ""
        turns = (json["chat_history"].arrayValue ?? []).map {
            Turn(role: $0["role"].stringValue ?? "user", message: $0["message"].stringValue ?? "")
        }
        if turns.isEmpty { turns = [Turn()] }
        successCondition = json["success_condition"].stringValue ?? ""
        successExamples = (json["success_examples"].arrayValue ?? []).compactMap { $0["response"].stringValue }.joined(separator: "\n")
        failureExamples = (json["failure_examples"].arrayValue ?? []).compactMap { $0["response"].stringValue }.joined(separator: "\n")
        scenario = json["simulation_scenario"].stringValue ?? ""
        maxTurns = json["simulation_max_turns"].intValue ?? 5
        parentFolderID = json["folder_parent_id"].stringValue ?? json["parent_folder_id"].stringValue
    }

    /// The request body: the fetched test's fields the API accepts for this kind, with the
    /// form's in place.
    func body(operationID: String) -> JSONValue {
        let accepted = Self.acceptedFields(operationID: operationID, type: type)
        var body: [String: JSONValue] = [:]
        for (key, value) in base.objectValue ?? [:] where accepted.contains(key) && value != .null {
            body[key] = value
        }
        body["type"] = .string(type)
        body["name"] = .string(name.trimmingCharacters(in: .whitespaces))
        let history = turns.filter { !$0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        body["chat_history"] = .array(history.map {
            ["role": .string($0.role), "message": .string($0.message), "time_in_call_secs": 0]
        })
        if let parentFolderID { body["parent_folder_id"] = .string(parentFolderID) }
        switch type {
        case "simulation":
            body["simulation_scenario"] = .string(scenario)
            body["simulation_max_turns"] = .number(Double(maxTurns))
            body["success_condition"] = .string(successCondition)
        case "llm":
            body["success_condition"] = .string(successCondition)
            body["success_examples"] = .array(Self.lines(successExamples).map { ["response": .string($0), "type": "success"] })
            body["failure_examples"] = .array(Self.lines(failureExamples).map { ["response": .string($0), "type": "failure"] })
        default:
            break
        }
        return .object(body)
    }

    static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The property names the spec lists for this kind of test in `operationID`'s body.
    static func acceptedFields(operationID: String, type: String) -> Set<String> {
        guard let schema = ElevenLabsCatalog.operation(operationID)?.body?.schema else { return [] }
        let variants = schema["anyOf"].arrayValue ?? schema["oneOf"].arrayValue ?? [schema]
        for variant in variants {
            let properties = variant["properties"].objectValue ?? [:]
            let constant = properties["type"]?["const"].stringValue ?? properties["type"]?["default"].stringValue
            if constant == type { return Set(properties.keys) }
        }
        return []
    }

    var problems: [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("A test needs a name.") }
        switch type {
        case "simulation":
            if scenario.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("Describe the simulated caller and what they want.")
            }
        case "llm":
            if !turns.contains(where: { $0.role == "user" && !$0.message.trimmingCharacters(in: .whitespaces).isEmpty }) {
                problems.append("Write what the caller says.")
            }
            if successCondition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("Say what a good answer does.")
            }
        default:
            break
        }
        return problems
    }
}

// MARK: - View-model

@MainActor
@Observable
final class AgentTestingModel {
    @ObservationIgnored unowned let store: AgentsPlatformStore
    var calls: AgentsCalls { store.calls }

    // Browsing
    var search = ""
    private(set) var folderID: String?
    private(set) var breadcrumb: [(id: String, name: String)] = []
    let list: AgentsPagedList<AgentsTest>
    var checked: Set<String> = []
    var moveTo = ""
    var newFolderName = ""
    var renameFolder = ""

    // Editing
    private(set) var editing = false
    private(set) var selectedID: String?
    var draft = AgentsTestDraft()
    private(set) var original = AgentsTestDraft()

    // Running
    var runAgentID = ""
    var runTestIDs: Set<String> = []
    var repeatCount = 1
    private(set) var invocation: JSONValue = .null
    let invocations: AgentsPagedList<AgentsTestInvocation>
    var resubmitRunIDs: Set<String> = []

    // One-off simulation
    var simulationAgentID = ""
    var simulatedUser = ""
    var simulationTurns = 10
    var simulationStreams = false
    private(set) var simulated: [AgentsTranscriptTurn] = []
    private(set) var simulationAnalysis: JSONValue = .null

    init(store: AgentsPlatformStore) {
        self.store = store
        let box = AgentsWeakBox<AgentTestingModel>()
        list = AgentsPagedList { cursor in await box.value?.fetchPage(cursor) }
        invocations = AgentsPagedList { cursor in await box.value?.fetchInvocations(cursor) }
        box.value = self
    }

    private func fetchPage(_ cursor: String?) async -> AgentsPage<AgentsTest>? {
        var arguments: [String: JSONValue] = [
            "page_size": 50, "parent_folder_id": .string(folderID ?? "root"), "sort_mode": "folders_first",
            "types": ["llm", "tool", "simulation", "folder"],
        ]
        let search = search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty { arguments["search"] = .string(search) }
        if let cursor { arguments["cursor"] = .string(cursor) }
        guard let json = await calls.json(AgentsOp.listTests, arguments, quiet: true) else { return nil }
        return AgentsPage(
            items: (json["tests"].arrayValue ?? []).compactMap(AgentsTest.init(json:)),
            cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
        )
    }

    // MARK: Folders

    func open(folder: AgentsTest) async {
        breadcrumb.append((folder.id, folder.name))
        folderID = folder.id
        renameFolder = folder.name
        checked = []
        await list.refresh()
        if let json = await calls.json(AgentsOp.getTestFolder, ["folder_id": .string(folder.id)], quiet: true),
           let name = json["name"].stringValue {
            renameFolder = name
        }
    }

    func goUp(to index: Int) async {
        if index < 0 {
            breadcrumb = []
            folderID = nil
        } else if breadcrumb.indices.contains(index) {
            breadcrumb = Array(breadcrumb.prefix(index + 1))
            folderID = breadcrumb.last?.id
            renameFolder = breadcrumb.last?.name ?? ""
        }
        checked = []
        await list.refresh()
    }

    func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var arguments: [String: JSONValue] = ["name": .string(name)]
        if let folderID { arguments["parent_folder_id"] = .string(folderID) }
        guard await calls.json(AgentsOp.createTestFolder, arguments) != nil else { return }
        newFolderName = ""
        await list.refresh()
    }

    func renameCurrentFolder() async {
        guard let folderID else { return }
        let name = renameFolder.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, await calls.json(AgentsOp.renameTestFolder, ["folder_id": .string(folderID), "name": .string(name)],
                                              slot: folderID) != nil
        else { return }
        if !breadcrumb.isEmpty { breadcrumb[breadcrumb.count - 1].name = name }
    }

    func deleteCurrentFolder() async {
        guard let folderID, let name = breadcrumb.last?.name else { return }
        guard await calls.json(
            AgentsOp.deleteTestFolder, ["folder_id": .string(folderID), "force": true], slot: folderID,
            subject: "the test folder “\(name)”",
            consequence: "ElevenLabs deletes the folder and every test and folder inside it."
        ) != nil else { return }
        await goUp(to: breadcrumb.count - 2)
    }

    func moveChecked() async {
        let ids = checked.sorted()
        guard !ids.isEmpty else { return }
        guard await calls.json(AgentsOp.moveTests, [
            "entity_ids": .array(ids.map(JSONValue.string)), "move_to": moveTo.isEmpty ? .null : .string(moveTo),
        ]) != nil else { return }
        checked = []
        await list.refresh()
    }

    // MARK: Tests

    func startCreating() {
        editing = true
        selectedID = nil
        loadedTestID = nil
        draft = AgentsTestDraft()
        draft.parentFolderID = folderID
        original = draft
    }

    /// The test whose fields the editor holds; nil for a new test or while the selected one loads.
    private(set) var loadedTestID: String?

    /// Whether the selected test's details are still on their way: Save and Delete wait for them.
    var isLoadingTest: Bool { selectedID != nil && loadedTestID != selectedID }

    func select(_ id: String) async {
        editing = true
        selectedID = id
        // The previous test's fields never stand in for this one's.
        loadedTestID = nil
        draft = AgentsTestDraft()
        original = draft
        guard let json = await calls.json(AgentsOp.getTest, ["test_id": .string(id)], slot: id, quiet: true),
              selectedID == id else { return }
        draft = AgentsTestDraft(json: json)
        original = draft
        loadedTestID = id
    }

    var isDirty: Bool { draft != original }

    func save() async {
        guard draft.problems.isEmpty else { return }
        if let selectedID {
            guard loadedTestID == selectedID else { return }
            let saved = draft
            let body = saved.body(operationID: AgentsOp.updateTest)
            guard await calls.json(AgentsOp.updateTest, ["test_id": .string(selectedID), "body": body], slot: selectedID,
                                   title: "Saved test “\(saved.name)”") != nil else { return }
            if loadedTestID == selectedID { original = saved }
            await list.refresh()
        } else {
            let body = draft.body(operationID: AgentsOp.createTest)
            guard let json = await calls.json(AgentsOp.createTest, ["body": body], title: "New test “\(draft.name)”"),
                  let id = json["id"].stringValue else { return }
            store.directory.tests.reset()
            await list.refresh()
            await select(id)
        }
    }

    /// Deletes the test on screen: only once its details are in, so the name asked about is its own.
    func delete() async {
        guard let id = selectedID, loadedTestID == id else { return }
        let name = original.name
        guard await calls.json(
            AgentsOp.deleteTest, ["test_id": .string(id)], slot: id, subject: "the test “\(name)”",
            consequence: "ElevenLabs deletes the test. Past runs keep their results."
        ) != nil else { return }
        list.remove(id)
        guard selectedID == id else { return }
        selectedID = nil
        loadedTestID = nil
        editing = false
    }

    // MARK: Running

    /// Runs the chosen tests against the agent. Each run is a billable conversation.
    func runTests() async {
        guard !runAgentID.isEmpty, !runTestIDs.isEmpty else { return }
        let tests: [JSONValue] = runTestIDs.sorted().map { ["test_id": .string($0)] }
        var arguments: [String: JSONValue] = ["agent_id": .string(runAgentID), "tests": .array(tests)]
        if repeatCount > 1 { arguments["repeat_count"] = .number(Double(repeatCount)) }
        guard let json = await calls.json(AgentsOp.runTests, arguments,
                                          title: "Tests on “\(store.directory.agentName(runAgentID))”") else { return }
        invocation = json
        await invocations.refresh()
    }

    /// The names of the tests being summarised, from their ids.
    private(set) var summaries: [String: String] = [:]

    func loadSummaries(_ ids: [String]) async {
        let missing = ids.filter { summaries[$0] == nil }
        guard !missing.isEmpty else { return }
        guard let json = await calls.json(AgentsOp.testSummaries, ["test_ids": .array(missing.map(JSONValue.string))], quiet: true)
        else { return }
        for (id, entry) in json["tests"].objectValue ?? [:] {
            summaries[id] = entry["name"].stringValue ?? id
        }
    }

    private func fetchInvocations(_ cursor: String?) async -> AgentsPage<AgentsTestInvocation>? {
        var arguments: [String: JSONValue] = ["page_size": 20]
        if !runAgentID.isEmpty { arguments["agent_id"] = .string(runAgentID) }
        if let cursor { arguments["cursor"] = .string(cursor) }
        guard let json = await calls.json(AgentsOp.listInvocations, arguments, quiet: true) else { return nil }
        return AgentsPage(
            items: (json["results"].arrayValue ?? []).compactMap(AgentsTestInvocation.init(json:)),
            cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
        )
    }

    func openInvocation(_ id: String) async {
        resubmitRunIDs = []
        invocation = await calls.json(AgentsOp.getInvocation, ["test_invocation_id": .string(id)], slot: id, quiet: true) ?? .null
        // Runs of tests deleted or renamed since carry only an id; look their names up.
        await loadSummaries(invocationRuns.filter { $0.testName == $0.testID }.map(\.testID))
    }

    var invocationRuns: [AgentsTestRun] {
        (invocation["test_runs"].arrayValue ?? []).compactMap(AgentsTestRun.init(json:))
    }

    /// Runs the chosen test runs of the open invocation again. Billable.
    func resubmit() async {
        guard let id = invocation["id"].stringValue, !resubmitRunIDs.isEmpty else { return }
        let agentID = invocation["agent_id"].stringValue ?? runAgentID
        guard await calls.json(AgentsOp.resubmitTests, [
            "test_invocation_id": .string(id), "agent_id": .string(agentID),
            "test_run_ids": .array(resubmitRunIDs.sorted().map(JSONValue.string)),
        ], slot: id, title: "Ran tests again") != nil else { return }
        await openInvocation(id)
    }

    // MARK: Simulation

    func simulate() async {
        let persona = simulatedUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !simulationAgentID.isEmpty, !persona.isEmpty else { return }
        let arguments: [String: JSONValue] = [
            "agent_id": .string(simulationAgentID),
            "simulation_specification": ["simulated_user_config": ["prompt": ["prompt": .string(persona)]]],
            "new_turns_limit": .number(Double(simulationTurns)),
        ]
        let operation = simulationStreams ? AgentsOp.simulateStream : AgentsOp.simulate
        guard let json = await calls.json(operation, arguments, title: "Simulated conversation") else { return }
        // The stream arrives as events; the finished conversation is in the last one that has it.
        let whole = json.arrayValue?.last(where: { $0["simulated_conversation"] != .null }) ?? json
        simulated = AgentsTranscriptTurn.turns(whole["simulated_conversation"])
        simulationAnalysis = whole["analysis"]
    }

    static let arguments: [AgentsArgument] = [
        AgentsArgument(AgentsOp.listTests, "page_size"), AgentsArgument(AgentsOp.listTests, "parent_folder_id"),
        AgentsArgument(AgentsOp.listTests, "sort_mode"), AgentsArgument(AgentsOp.listTests, "types"),
        AgentsArgument(AgentsOp.listTests, "search"), AgentsArgument(AgentsOp.listTests, "cursor"),
        AgentsArgument(AgentsOp.getTestFolder, "folder_id"),
        AgentsArgument(AgentsOp.createTestFolder, "name"), AgentsArgument(AgentsOp.createTestFolder, "parent_folder_id"),
        AgentsArgument(AgentsOp.renameTestFolder, "folder_id"), AgentsArgument(AgentsOp.renameTestFolder, "name"),
        AgentsArgument(AgentsOp.deleteTestFolder, "folder_id"), AgentsArgument(AgentsOp.deleteTestFolder, "force"),
        AgentsArgument(AgentsOp.moveTests, "entity_ids"), AgentsArgument(AgentsOp.moveTests, "move_to"),
        AgentsArgument(AgentsOp.getTest, "test_id"),
        AgentsArgument(AgentsOp.updateTest, "test_id"), AgentsArgument(AgentsOp.deleteTest, "test_id"),
        AgentsArgument(AgentsOp.runTests, "agent_id"), AgentsArgument(AgentsOp.runTests, "tests[].test_id"),
        AgentsArgument(AgentsOp.runTests, "repeat_count"),
        AgentsArgument(AgentsOp.testSummaries, "test_ids"),
        AgentsArgument(AgentsOp.listInvocations, "page_size"), AgentsArgument(AgentsOp.listInvocations, "agent_id"),
        AgentsArgument(AgentsOp.listInvocations, "cursor"),
        AgentsArgument(AgentsOp.getInvocation, "test_invocation_id"),
        AgentsArgument(AgentsOp.resubmitTests, "test_invocation_id"), AgentsArgument(AgentsOp.resubmitTests, "agent_id"),
        AgentsArgument(AgentsOp.resubmitTests, "test_run_ids"),
        AgentsArgument(AgentsOp.simulate, "agent_id"), AgentsArgument(AgentsOp.simulate, "new_turns_limit"),
        AgentsArgument(AgentsOp.simulate, "simulation_specification.simulated_user_config.prompt.prompt"),
        AgentsArgument(AgentsOp.simulateStream, "agent_id"), AgentsArgument(AgentsOp.simulateStream, "new_turns_limit"),
        AgentsArgument(AgentsOp.simulateStream, "simulation_specification.simulated_user_config.prompt.prompt"),
    ] + ["type", "name", "chat_history[].role", "chat_history[].message", "chat_history[].time_in_call_secs",
         "parent_folder_id", "success_condition", "success_examples[].response", "success_examples[].type",
         "failure_examples[].response", "failure_examples[].type", "simulation_scenario", "simulation_max_turns"]
        .flatMap { [AgentsArgument(AgentsOp.createTest, $0), AgentsArgument(AgentsOp.updateTest, $0)] }
}

// MARK: - Views

private struct AgentTestBrowser: View {
    @Bindable var model: AgentTestingModel

    var body: some View {
        AgentsCard("Tests") {
            HStack(spacing: 4) {
                Button("All tests") { Task { await model.goUp(to: -1) } }.buttonStyle(.link)
                ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { index, folder in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(folder.name) { Task { await model.goUp(to: index) } }.buttonStyle(.link).lineLimit(1)
                }
            }
            .font(.caption)
            AgentsSearchField(prompt: "Search tests and folders", text: $model.search) {
                Task { await model.list.refresh() }
            }
            AgentsListBody(model.list, runner: model.calls.runner(AgentsOp.listTests), empty: "No tests here.") { test in
                HStack(spacing: 4) {
                    Toggle("", isOn: Binding(
                        get: { model.checked.contains(test.id) },
                        set: { on in if on { model.checked.insert(test.id) } else { model.checked.remove(test.id) } }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Select \(test.name)")
                    AgentsRow(selected: model.selectedID == test.id) {
                        if test.isFolder {
                            Task { await model.open(folder: test) }
                        } else {
                            Task { await model.select(test.id) }
                        }
                    } content: {
                        HStack(spacing: 6) {
                            Image(systemName: test.isFolder ? "folder" : "checkmark.seal").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(test.name).lineLimit(1)
                                Text(test.isFolder ? AgentsFormat.count(test.childrenCount ?? 0, "item") : test.typeName)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !model.checked.isEmpty {
                Divider()
                HStack {
                    Picker("Move to", selection: $model.moveTo) {
                        Text("All tests").tag("")
                        ForEach(model.list.items.filter(\.isFolder)) { Text($0.name).tag($0.id) }
                    }
                    .fixedSize()
                    Button("Move \(model.checked.count)") { Task { await model.moveChecked() } }
                }
                .font(.callout)
                AgentsRunnerOutput(runner: model.calls.runner(AgentsOp.moveTests), showsResult: false)
            }
            Divider()
            HStack {
                TextField("New folder", text: $model.newFolderName).textFieldStyle(.roundedBorder)
                Button("Create") { Task { await model.createFolder() } }.disabled(model.newFolderName.isEmpty)
            }
            .font(.callout)
            if !model.breadcrumb.isEmpty {
                HStack {
                    TextField("Folder name", text: $model.renameFolder).textFieldStyle(.roundedBorder)
                    Button("Rename") { Task { await model.renameCurrentFolder() } }
                    AgentsRunButton(runner: model.calls.runner(AgentsOp.deleteTestFolder, slot: model.breadcrumb.last?.id ?? ""), title: "Delete…") {
                        Task { await model.deleteCurrentFolder() }
                    }
                }
                .font(.callout)
                AgentsRunnerOutput(runner: model.calls.runner(AgentsOp.deleteTestFolder, slot: model.breadcrumb.last?.id ?? ""))
            }
            AgentsRunnerError(runner: model.calls.runner(AgentsOp.createTestFolder))
            AgentsRunnerError(runner: model.calls.runner(AgentsOp.renameTestFolder, slot: model.breadcrumb.last?.id ?? ""))
        }
    }
}

private struct AgentTestEditor: View {
    @Bindable var model: AgentTestingModel

    var body: some View {
        let runner = model.selectedID.map { model.calls.runner(AgentsOp.updateTest, slot: $0) }
            ?? model.calls.runner(AgentsOp.createTest)
        VStack(alignment: .leading, spacing: 14) {
            AgentsCard(model.selectedID == nil ? "New test" : model.isLoadingTest ? "Loading the test…" : model.draft.name) {
                if let id = model.selectedID {
                    AgentsFact(label: "ID", value: id, monospaced: true)
                    AgentsRunnerError(runner: model.calls.runner(AgentsOp.getTest, slot: id))
                }
                Form {
                    TextField("Name", text: $model.draft.name, prompt: Text("Refund request is escalated"))
                    Picker("Kind", selection: $model.draft.type) {
                        Text("Response — the agent's next reply is judged").tag("llm")
                        Text("Simulation — a simulated caller with a goal").tag("simulation")
                        Text("Tool call — the agent calls the right tool").tag("tool")
                    }
                    .disabled(model.selectedID != nil)
                }
                .formStyle(.columns)
            }
            if model.draft.type == "simulation" {
                AgentsCard("The caller", subtitle: "Who the simulated caller is and what they want; the agent is judged on how the conversation goes.") {
                    TextEditor(text: $model.draft.scenario)
                        .font(.callout).frame(minHeight: 90)
                        .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
                    let limits = AgentsSchema.range(AgentsOp.createTest, "simulation_max_turns", fallback: 1...50)
                    Stepper("At most \(model.draft.maxTurns) turns", value: $model.draft.maxTurns,
                            in: Int(limits.lowerBound)...Int(limits.upperBound))
                }
            } else {
                AgentsCard("The conversation so far", subtitle: model.draft.type == "llm" ? "The agent's next reply after this is what gets judged." : nil) {
                    ForEach($model.draft.turns) { $turn in
                        HStack(alignment: .top) {
                            Picker("", selection: $turn.role) {
                                Text("Caller").tag("user")
                                Text("Agent").tag("agent")
                            }
                            .labelsHidden()
                            .fixedSize()
                            TextField("Message", text: $turn.message, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...4)
                            Button {
                                model.draft.turns.removeAll { $0.id == turn.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove this message")
                        }
                    }
                    Button("Add a message") { model.draft.turns.append(.init()) }.buttonStyle(.link)
                }
            }
            if model.draft.type != "tool" {
                AgentsCard("What counts as success") {
                    TextEditor(text: $model.draft.successCondition)
                        .font(.callout).frame(minHeight: 60)
                        .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
                    if model.draft.type == "llm" {
                        Text("Good replies, one per line").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $model.draft.successExamples)
                            .font(.callout).frame(minHeight: 40)
                            .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
                        Text("Bad replies, one per line").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $model.draft.failureExamples)
                            .font(.callout).frame(minHeight: 40)
                            .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
                    }
                }
            } else {
                AgentsCard("Expected tool call") {
                    Text("Which tool and parameters count as right is edited in the Explorer (create or update an agent response test); the conversation above is kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            AgentsCard("Save") {
                ElevenLabsProblemList(problems: model.draft.problems)
                HStack {
                    AgentsRunButton(runner: runner, title: model.selectedID == nil ? "Create test" : "Save test",
                                        disabled: model.isLoadingTest || !model.draft.problems.isEmpty
                                            || (model.selectedID != nil && !model.isDirty)) {
                        Task { await model.save() }
                    }
                    if model.selectedID != nil {
                        AgentsRunButton(runner: model.calls.runner(AgentsOp.deleteTest, slot: model.selectedID ?? ""), title: "Delete…",
                                        disabled: model.isLoadingTest) {
                            Task { await model.delete() }
                        }
                    }
                }
                AgentsRunnerOutput(runner: runner, showsResult: false)
                AgentsRunnerOutput(runner: model.calls.runner(AgentsOp.deleteTest, slot: model.selectedID ?? ""))
            }
        }
    }
}

private struct AgentTestRunCard: View {
    @Bindable var model: AgentTestingModel

    var body: some View {
        let runner = model.calls.runner(AgentsOp.runTests)
        let tests = model.store.directory.tests
        AgentsCard("Run tests on an agent", subtitle: "Each test runs as a conversation with the agent, which uses credits.") {
            HStack {
                AgentsAgentPicker(directory: model.store.directory, selection: $model.runAgentID).fixedSize()
                Stepper("Run each \(model.repeatCount)×", value: $model.repeatCount, in: {
                    let limits = AgentsSchema.range(AgentsOp.runTests, "repeat_count", fallback: 1...50)
                    return Int(limits.lowerBound)...Int(limits.upperBound)
                }())
            }
            AgentsChecklist(items: tests.items.filter { !$0.isFolder }, selection: $model.runTestIDs,
                            title: \.name, subtitle: { $0.typeName })
            if tests.hasMore {
                Button("More tests") { Task { await tests.loadMore() } }.buttonStyle(.link)
            }
            AgentsRunButton(runner: runner, title: "Run \(AgentsFormat.count(model.runTestIDs.count, "test"))",
                                disabled: model.runAgentID.isEmpty || model.runTestIDs.isEmpty) {
                Task { await model.runTests() }
            }
            AgentsRunnerOutput(runner: runner, showsResult: false)
        }
        .task { await tests.loadIfNeeded() }
    }
}

private struct AgentTestInvocationsCard: View {
    @Bindable var model: AgentTestingModel

    var body: some View {
        AgentsCard("Test runs", subtitle: "Each time tests were run, with every run's verdict.") {
            AgentsRefreshButton(list: model.invocations, help: "Fetch the test runs again")
        } content: {
            AgentsListBody(model.invocations, runner: model.calls.runner(AgentsOp.listInvocations), empty: "No test runs yet.") { run in
                AgentsRow(selected: model.invocation["id"].stringValue == run.id) {
                    Task { await model.openInvocation(run.id) }
                } content: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(run.title).lineLimit(1)
                            Text(AgentsFormat.date(run.createdAt)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if run.passed > 0 { AgentsBadge(text: "\(run.passed) passed", color: .green) }
                        if run.failed > 0 { AgentsBadge(text: "\(run.failed) failed", color: .red) }
                        if run.pending > 0 { AgentsBadge(text: "\(run.pending) pending", color: .blue) }
                    }
                }
            }
            if model.invocation != .null {
                Divider()
                ForEach(model.invocationRuns) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { model.resubmitRunIDs.contains(run.id) },
                                set: { on in if on { model.resubmitRunIDs.insert(run.id) } else { model.resubmitRunIDs.remove(run.id) } }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .accessibilityLabel("Run \(run.testName) again")
                            Text(model.summaries[run.testID] ?? run.testName).font(.callout)
                            Spacer()
                            AgentsBadge(text: AgentsFormat.words(run.result ?? run.status),
                                        color: AgentsBadge.color(forStatus: run.result ?? run.status))
                        }
                        if let rationale = run.rationale, !rationale.isEmpty {
                            Text(rationale).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                AgentsRunButton(runner: model.calls.runner(AgentsOp.resubmitTests, slot: model.invocation["id"].stringValue ?? ""),
                                    title: model.resubmitRunIDs.isEmpty ? "Run the ticked tests again"
                                        : "Run \(AgentsFormat.count(model.resubmitRunIDs.count, "test")) again",
                                    disabled: model.resubmitRunIDs.isEmpty) {
                    Task { await model.resubmit() }
                }
                AgentsRunnerOutput(runner: model.calls.runner(AgentsOp.resubmitTests, slot: model.invocation["id"].stringValue ?? ""))
            }
        }
        .task { await model.invocations.loadIfNeeded() }
    }
}

private struct AgentSimulationCard: View {
    @Bindable var model: AgentTestingModel

    var body: some View {
        let operation = model.simulationStreams ? AgentsOp.simulateStream : AgentsOp.simulate
        let runner = model.calls.runner(operation)
        AgentsCard("Simulated conversation", subtitle: "A one-off conversation between the agent and a simulated caller. ElevenLabs is retiring this on 31 October 2026 in favour of simulation tests above.") {
            HStack {
                AgentsAgentPicker(directory: model.store.directory, selection: $model.simulationAgentID).fixedSize()
                Stepper("\(model.simulationTurns) turns", value: $model.simulationTurns, in: 1...{
                    Int(AgentsSchema.range(AgentsOp.simulate, "new_turns_limit", fallback: 1...100).upperBound)
                }())
                Toggle("Stream", isOn: $model.simulationStreams).toggleStyle(.checkbox)
            }
            TextField("The caller", text: $model.simulatedUser, prompt: Text("You want to move your delivery to Friday and are in a hurry."), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            AgentsRunButton(runner: runner, title: "Simulate",
                                disabled: model.simulationAgentID.isEmpty || model.simulatedUser.isEmpty) {
                Task { await model.simulate() }
            }
            AgentsRunnerOutput(runner: runner, showsResult: false)
            if !model.simulated.isEmpty {
                AgentsTranscriptView(turns: model.simulated)
                if let summary = model.simulationAnalysis["transcript_summary"].stringValue {
                    Text(summary).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
