import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Workspace tools agents can call: webhooks to the owner's servers and tools the client
/// handles. List, create, edit (the common fields, or the whole configuration as JSON), see
/// which agents use one and how its calls went, delete.
struct AgentToolsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        AgentToolsScreen(model: AgentsPlatformStore.shared(for: app).tools)
    }
}

struct AgentToolsScreen: View {
    @Bindable var model: AgentToolsModel

    var body: some View {
        ElevenLabsSectionPage(.agentTools, accessory: {
            HStack(spacing: 8) {
                AgentsRefreshButton(list: model.list, help: "Fetch the tools again")
                Button {
                    model.startCreating()
                } label: {
                    Label("New tool", systemImage: "plus")
                }
            }
        }) {
            AgentsMasterDetail {
                AgentsCard("Tools") {
                    AgentsSearchField(prompt: "Names starting with…", text: $model.search) {
                        Task { await model.list.refresh() }
                    }
                    Picker("Kind", selection: $model.typeFilter) {
                        Text("All kinds").tag("")
                        ForEach(AgentsSchema.choices(AgentsOp.listTools, "types"), id: \.self) {
                            Text(AgentsFormat.words($0)).tag($0)
                        }
                    }
                    .font(.caption)
                    .fixedSize()
                    .onChange(of: model.typeFilter) { Task { await model.list.refresh() } }
                    AgentsListBody(model.list, runner: model.calls.runner(AgentsOp.listTools),
                                   empty: "No tools yet. Make one with New tool.") { tool in
                        AgentsRow(selected: model.selectedID == tool.id && !model.creating) {
                            Task { await model.select(tool.id) }
                        } content: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(tool.name).lineLimit(1)
                                    AgentsBadge(text: AgentsFormat.words(tool.type))
                                }
                                Text(tool.totalCalls.map { "\($0.formatted()) calls" } ?? tool.description)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            } detail: {
                if model.creating {
                    AgentToolForm(model: model, editor: $model.newTool, isNew: true)
                } else if model.selectedID != nil {
                    AgentToolDetailView(model: model)
                } else {
                    AgentsCard("No tool selected") {
                        AgentsEmptyState(title: "Choose a tool",
                                         message: "Or make a webhook the agent calls, or a tool your own client handles.",
                                         systemImage: "wrench.and.screwdriver")
                    }
                }
            }
        }
        .task { await model.list.loadIfNeeded() }
    }
}

// MARK: - The editable tool

/// The fields of a tool's configuration the form edits. Everything else in the configuration
/// is kept as it was and sent back with them.
struct AgentsToolEditor: Equatable, Sendable {
    /// webhook or client.
    var kind = "webhook"
    var name = ""
    var description = ""
    var url = ""
    var method = "POST"
    var timeoutSeconds = 20
    var expectsResponse = false
    /// A client tool's parameters, as JSON Schema text.
    var parametersJSON = ""
    /// The configuration as fetched, for everything the form does not show.
    var base: JSONValue = .null

    init() {}

    init(config: JSONValue) {
        base = config
        kind = config["type"].stringValue ?? "webhook"
        name = config["name"].stringValue ?? ""
        description = config["description"].stringValue ?? ""
        url = config["api_schema"]["url"].stringValue ?? ""
        method = config["api_schema"]["method"].stringValue ?? "POST"
        timeoutSeconds = config["response_timeout_secs"].intValue ?? 20
        expectsResponse = config["expects_response"].boolValue ?? false
        parametersJSON = config["parameters"] == .null ? "" : config["parameters"].jsonString(pretty: true)
    }

    /// Whether this kind is edited field by field here (webhook and client tools); the others
    /// (system, MCP, integrations) are edited as JSON.
    var isFormEditable: Bool { kind == "webhook" || kind == "client" }

    /// The configuration to send: the fetched one with the form's fields in place.
    func config() throws -> JSONValue {
        var config = base.objectValue ?? [:]
        config["type"] = .string(kind)
        config["name"] = .string(name.trimmingCharacters(in: .whitespaces))
        config["description"] = .string(description)
        config["response_timeout_secs"] = .number(Double(timeoutSeconds))
        switch kind {
        case "webhook":
            var schema = base["api_schema"].objectValue ?? [:]
            schema["url"] = .string(url.trimmingCharacters(in: .whitespaces))
            schema["method"] = .string(method)
            config["api_schema"] = .object(schema)
        case "client":
            config["expects_response"] = .bool(expectsResponse)
            let text = parametersJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                config.removeValue(forKey: "parameters")
            } else {
                config["parameters"] = try JSONValue(data: Data(text.utf8))
            }
        default:
            break
        }
        return .object(config)
    }

    var problems: [String] {
        var problems: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("A tool needs a name.") }
        if description.trimmingCharacters(in: .whitespaces).isEmpty {
            problems.append("A tool needs a description: it is how the agent knows when to call it.")
        }
        if kind == "webhook", let refusal = AgentsOutsideAddress(url).refusal {
            problems.append(refusal)
        }
        if kind == "client", !parametersJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           (try? JSONValue(data: Data(parametersJSON.utf8))) == nil {
            problems.append("The parameters are not valid JSON.")
        }
        return problems
    }
}

// MARK: - View-model

@MainActor
@Observable
final class AgentToolsModel {
    @ObservationIgnored unowned let store: AgentsPlatformStore
    var calls: AgentsCalls { store.calls }

    var search = ""
    var typeFilter = ""
    let list: AgentsPagedList<AgentsTool>

    private(set) var selectedID: String?
    private(set) var tool: AgentsTool?
    var editor = AgentsToolEditor()
    private(set) var original = AgentsToolEditor()
    /// The whole configuration as JSON, for kinds the form does not cover or for anything it
    /// leaves out.
    var configJSON = ""
    var editsJSON = false
    private(set) var dependents: [String] = []
    private(set) var executions: [AgentsToolExecution] = []
    var errorsOnly = false
    var forceDelete = false

    private(set) var creating = false
    var newTool = AgentsToolEditor()

    init(store: AgentsPlatformStore) {
        self.store = store
        let box = AgentsWeakBox<AgentToolsModel>()
        list = AgentsPagedList { cursor in await box.value?.fetchPage(cursor) }
        box.value = self
    }

    private func fetchPage(_ cursor: String?) async -> AgentsPage<AgentsTool>? {
        var arguments: [String: JSONValue] = ["page_size": 50]
        let search = search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty { arguments["search"] = .string(search) }
        if !typeFilter.isEmpty { arguments["types"] = [.string(typeFilter)] }
        if let cursor { arguments["cursor"] = .string(cursor) }
        guard let json = await calls.json(AgentsOp.listTools, arguments, quiet: true) else { return nil }
        return AgentsPage(
            items: (json["tools"].arrayValue ?? []).compactMap(AgentsTool.init(json:)),
            cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
        )
    }

    var isDirty: Bool { editsJSON ? configJSON != tool?.config.jsonString(pretty: true) : editor != original }

    func select(_ id: String) async {
        creating = false
        selectedID = id
        dependents = []
        executions = []
        editsJSON = false
        // The editor only ever holds the selected tool: an unknown one shows nothing until it arrives,
        // so Save and Delete cannot pair one tool's id with another's configuration or name.
        if let known = list.item(id) { show(known) } else { tool = nil }
        guard let json = await calls.json(AgentsOp.getTool, ["tool_id": .string(id)], slot: id, quiet: true),
              selectedID == id, let tool = AgentsTool(json: json) else { return }
        show(tool)
    }

    private func show(_ tool: AgentsTool) {
        self.tool = tool
        editor = AgentsToolEditor(config: tool.config)
        original = editor
        configJSON = tool.config.jsonString(pretty: true)
        editsJSON = !editor.isFormEditable
    }

    /// The configuration Save sends, or the reason it cannot.
    func configToSave() -> Result<JSONValue, AgentsToolConfigError> {
        if editsJSON {
            guard let value = try? JSONValue(data: Data(configJSON.utf8)), value.objectValue != nil else {
                return .failure(AgentsToolConfigError(message: "The configuration is not a JSON object."))
            }
            return .success(value)
        }
        if let problem = editor.problems.first { return .failure(AgentsToolConfigError(message: problem)) }
        do {
            return .success(try editor.config())
        } catch {
            return .failure(AgentsToolConfigError(message: "The parameters are not valid JSON."))
        }
    }

    /// What saving a tool's configuration means, for the question: its name, where it sends
    /// and which headers go with it (names only, never their values), and any warning about
    /// the address.
    static func describe(_ config: JSONValue) -> (subject: String, consequence: String) {
        let name = config["name"].stringValue ?? "tool"
        let url = config["api_schema"]["url"].stringValue
        let address = url.map(AgentsOutsideAddress.init)
        let headers = (config["api_schema"]["request_headers"].objectValue ?? [:]).keys.sorted()
        var subject = "“\(name)”"
        if let host = address?.host { subject += " calling \(host)" }
        var consequence: String
        if let host = address?.host {
            consequence = "Agents that use “\(name)” will send it what the conversation needs, at \(host)"
                + (headers.isEmpty ? "" : ", with the headers " + ListFormatter.localizedString(byJoining: headers)) + "."
        } else {
            consequence = "Agents that use “\(name)” can call it during conversations."
        }
        if let warnings = address?.warnings, !warnings.isEmpty {
            consequence = "Careful: " + warnings.joined(separator: " ") + " " + consequence
        }
        return (subject, consequence + " Every agent using it gets the change from its next conversation.")
    }

    /// Saves the configuration in the editor to the tool it was opened from.
    func save() async {
        guard let id = tool?.id, id == selectedID, case .success(let config) = configToSave() else { return }
        let wording = Self.describe(config)
        guard let json = await calls.json(AgentsOp.updateTool, ["tool_id": .string(id), "tool_config": config],
                                          slot: id, title: "Saved tool “\(config["name"].stringValue ?? "")”",
                                          subject: wording.subject, consequence: wording.consequence,
                                          question: "Save the tool \(wording.subject)?", confirmLabel: "Save tool"),
              let saved = AgentsTool(json: json) else { return }
        list.upsert(saved)
        store.directory.tools.upsert(saved)
        if selectedID == id { show(saved) }
    }

    func startCreating() {
        creating = true
        newTool = AgentsToolEditor()
    }

    func create() async {
        guard newTool.problems.isEmpty, let config = try? newTool.config() else { return }
        let wording = Self.describe(config)
        guard let json = await calls.json(
            AgentsOp.createTool, ["tool_config": config], title: "New tool “\(newTool.name)”",
            subject: wording.subject, consequence: wording.consequence,
            question: "Create the tool \(wording.subject)?", confirmLabel: "Create tool",
            holdIfUnknown: AgentsCreateHolds.lost("the tool “\(newTool.name)”", check: "the tools list")
        ) else {
            if calls.outcomeWasUnknown(AgentsOp.createTool) {
                calls.holds.onReadAgain(AgentsOp.createTool) { [weak self] in await self?.list.refresh() }
                await list.refresh()
            }
            return
        }
        guard let tool = AgentsTool(json: json) else { return }
        list.upsert(tool)
        store.directory.tools.upsert(tool)
        creating = false
        selectedID = tool.id
        show(tool)
    }

    func loadDependents() async {
        guard let selectedID else { return }
        guard let json = await calls.json(AgentsOp.toolDependents, ["tool_id": .string(selectedID)], slot: selectedID, quiet: true),
              self.selectedID == selectedID
        else { return }
        dependents = (json["agents"].arrayValue ?? []).map { $0["name"].stringValue ?? $0["id"].stringValue ?? "An agent" }
    }

    func loadExecutions() async {
        guard let selectedID else { return }
        var arguments: [String: JSONValue] = ["tool_id": .string(selectedID), "page_size": 30]
        if errorsOnly { arguments["is_error"] = true }
        guard let json = await calls.json(AgentsOp.toolExecutions, arguments, slot: selectedID, quiet: true),
              self.selectedID == selectedID else { return }
        executions = (json["executions"].arrayValue ?? []).compactMap(AgentsToolExecution.init(json:))
        await store.directory.resolveAgentNames(executions.map(\.agentID))
    }

    /// Deletes the tool on screen: its id and the name in the question come from the same place.
    func delete() async {
        guard let tool, tool.id == selectedID else { return }
        let id = tool.id
        var arguments: [String: JSONValue] = ["tool_id": .string(id)]
        if forceDelete { arguments["force"] = true }
        guard await calls.json(
            AgentsOp.deleteTool, arguments, slot: id, subject: "the tool “\(tool.name)”",
            consequence: forceDelete
                ? "ElevenLabs deletes it and takes it out of every agent that uses it; those agents can no longer call it."
                : "ElevenLabs deletes it. If an agent still uses it, the deletion is refused."
        ) != nil else { return }
        list.remove(id)
        store.directory.tools.remove(id)
        guard selectedID == id else { return }
        selectedID = nil
        self.tool = nil
    }

    static let arguments: [AgentsArgument] = [
        AgentsArgument(AgentsOp.listTools, "page_size"), AgentsArgument(AgentsOp.listTools, "search"),
        AgentsArgument(AgentsOp.listTools, "types"), AgentsArgument(AgentsOp.listTools, "cursor"),
        AgentsArgument(AgentsOp.getTool, "tool_id"),
        AgentsArgument(AgentsOp.updateTool, "tool_id"), AgentsArgument(AgentsOp.updateTool, "tool_config"),
        AgentsArgument(AgentsOp.createTool, "tool_config.type"), AgentsArgument(AgentsOp.createTool, "tool_config.name"),
        AgentsArgument(AgentsOp.createTool, "tool_config.description"),
        AgentsArgument(AgentsOp.createTool, "tool_config.response_timeout_secs"),
        AgentsArgument(AgentsOp.createTool, "tool_config.api_schema.url"),
        AgentsArgument(AgentsOp.createTool, "tool_config.api_schema.method"),
        AgentsArgument(AgentsOp.createTool, "tool_config.expects_response"),
        AgentsArgument(AgentsOp.createTool, "tool_config.parameters"),
        AgentsArgument(AgentsOp.toolDependents, "tool_id"),
        AgentsArgument(AgentsOp.toolExecutions, "tool_id"), AgentsArgument(AgentsOp.toolExecutions, "page_size"),
        AgentsArgument(AgentsOp.toolExecutions, "is_error"),
        AgentsArgument(AgentsOp.deleteTool, "tool_id"), AgentsArgument(AgentsOp.deleteTool, "force"),
    ]
}

struct AgentsToolConfigError: Error, Equatable {
    var message: String
}

// MARK: - Views

private struct AgentToolForm: View {
    let model: AgentToolsModel
    @Binding var editor: AgentsToolEditor
    let isNew: Bool

    var body: some View {
        let runner = isNew ? model.calls.runner(AgentsOp.createTool)
            : model.calls.runner(AgentsOp.updateTool, slot: model.selectedID ?? "")
        AgentsCard(isNew ? "New tool" : "Settings") {
            Form {
                if isNew {
                    Picker("Kind", selection: $editor.kind) {
                        Text("Webhook — ElevenLabs calls your server").tag("webhook")
                        Text("Client — your app handles it").tag("client")
                    }
                }
                TextField("Name", text: $editor.name, prompt: Text("check_order_status"))
                TextField("When to use it", text: $editor.description, prompt: Text("Looks up an order by its number"), axis: .vertical)
                    .lineLimit(2...4)
                if editor.kind == "webhook" {
                    TextField("Address", text: $editor.url, prompt: Text("https://example.com/orders/{order_id}"))
                    ForEach(AgentsOutsideAddress(editor.url).warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Picker("Method", selection: $editor.method) {
                        ForEach(AgentsSchema.choices(AgentsOp.createTool, "tool_config.api_schema.method"), id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                } else {
                    Toggle("The agent waits for an answer", isOn: $editor.expectsResponse)
                    LabeledContent("Parameters (JSON Schema)") {
                        TextEditor(text: $editor.parametersJSON)
                            .font(.caption.monospaced())
                            .frame(minHeight: 80)
                            .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
                    }
                }
                let limits = AgentsSchema.range(AgentsOp.createTool, "tool_config.response_timeout_secs", fallback: 5...300)
                Stepper("Give up after \(editor.timeoutSeconds) s", value: $editor.timeoutSeconds,
                        in: Int(limits.lowerBound)...Int(limits.upperBound))
            }
            .formStyle(.columns)
            ElevenLabsProblemList(problems: editor.problems)
            if isNew { AgentsHeldCreateNotice(holds: model.calls.holds, operationID: AgentsOp.createTool) }
            HStack {
                AgentsRunButton(runner: runner, title: isNew ? "Create tool…" : "Save…", disabled: !editor.problems.isEmpty
                                    || (!isNew && !model.isDirty)
                                    || (isNew && model.calls.holds.notice(AgentsOp.createTool) != nil)) {
                    Task { if isNew { await model.create() } else { await model.save() } }
                }
            }
            AgentsRunnerOutput(runner: runner, showsResult: false)
        }
    }
}

private struct AgentToolDetailView: View {
    @Bindable var model: AgentToolsModel

    var body: some View {
        let calls = model.calls
        VStack(alignment: .leading, spacing: 14) {
            if let tool = model.tool {
                AgentsCard(tool.name, subtitle: tool.description) {
                    AgentsFact(label: "Kind", value: AgentsFormat.words(tool.type))
                    if let total = tool.totalCalls { AgentsFact(label: "Calls", value: total.formatted()) }
                    if let latency = tool.averageLatency { AgentsFact(label: "Average time", value: String(format: "%.2f s", latency)) }
                    AgentsFact(label: "ID", value: tool.id, monospaced: true)
                }
                if model.editor.isFormEditable {
                    Toggle("Edit the whole configuration as JSON", isOn: $model.editsJSON)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                if model.editsJSON {
                    AgentsCard("Configuration", subtitle: "Sent whole as the tool's configuration when saved.") {
                        TextEditor(text: $model.configJSON)
                            .font(.caption.monospaced())
                            .frame(minHeight: 220)
                            .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
                        if case .failure(let error) = model.configToSave() {
                            ElevenLabsProblemList(problems: [error.message])
                        }
                        AgentsRunButton(runner: calls.runner(AgentsOp.updateTool, slot: model.selectedID ?? ""), title: "Save…",
                                        disabled: !model.isDirty) {
                            Task { await model.save() }
                        }
                        AgentsRunnerOutput(runner: calls.runner(AgentsOp.updateTool, slot: model.selectedID ?? ""))
                    }
                } else {
                    AgentToolForm(model: model, editor: $model.editor, isNew: false)
                }
            } else {
                AgentsCard("Tool") {
                    AgentsRunnerError(runner: calls.runner(AgentsOp.getTool, slot: model.selectedID ?? ""))
                }
            }
            AgentsCard("Used by") {
                if model.dependents.isEmpty {
                    Button("Which agents use it") { Task { await model.loadDependents() } }
                } else {
                    Text(ListFormatter.localizedString(byJoining: model.dependents)).font(.callout)
                }
                AgentsRunnerError(runner: calls.runner(AgentsOp.toolDependents, slot: model.selectedID ?? ""))
            }
            AgentsCard("Recent calls", subtitle: "What agents sent the tool and how it went.") {
                HStack {
                    Toggle("Errors only", isOn: $model.errorsOnly).toggleStyle(.checkbox)
                    Button("Show calls") { Task { await model.loadExecutions() } }
                }
                AgentsRunnerError(runner: calls.runner(AgentsOp.toolExecutions, slot: model.selectedID ?? ""))
                ForEach(model.executions) { execution in
                    HStack {
                        Image(systemName: execution.isError ? "xmark.octagon" : "checkmark.circle")
                            .foregroundStyle(execution.isError ? .red : .green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(AgentsFormat.date(execution.at)) · \(model.store.directory.agentName(execution.agentID))")
                                .font(.callout)
                            if let error = execution.error, !error.isEmpty {
                                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                            }
                        }
                        Spacer()
                        if let latency = execution.latency {
                            Text(String(format: "%.2f s", latency)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            AgentsCard("Delete") {
                Toggle("Even if agents use it", isOn: $model.forceDelete).toggleStyle(.checkbox)
                AgentsRunButton(runner: calls.runner(AgentsOp.deleteTool, slot: model.selectedID ?? ""), title: "Delete tool…") {
                    Task { await model.delete() }
                }
                AgentsRunnerOutput(runner: calls.runner(AgentsOp.deleteTool, slot: model.selectedID ?? ""))
            }
        }
    }
}
