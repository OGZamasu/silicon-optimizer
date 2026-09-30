import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Outside MCP tool servers connected to agents. Connecting one lets agents call its tools in
/// the middle of conversations and send it what callers say, so every change here asks first.
/// Per server: its tools, which ones may run without asking, per-tool overrides, its
/// behaviour, and removal.
struct AgentMCPServersSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        AgentMCPServersScreen(model: AgentsPlatformStore.shared(for: app).mcpServers)
    }
}

struct AgentMCPServersScreen: View {
    @Bindable var model: AgentMCPServersModel

    var body: some View {
        ElevenLabsSectionPage(.agentMCPServers, accessory: {
            HStack(spacing: 8) {
                AgentsRefreshButton(list: model.list, help: "Fetch the servers again")
                Button {
                    model.creating = true
                } label: {
                    Label("Connect a server", systemImage: "plus")
                }
            }
        }) {
            if model.creating { AgentMCPServerComposer(model: model) }
            AgentsMasterDetail {
                AgentsCard("MCP servers") {
                    AgentsListBody(model.list, runner: model.calls.runner(AgentsOp.listMCPServers),
                                   empty: "No MCP servers connected.") { server in
                        AgentsRow(selected: model.selectedID == server.id) {
                            Task { await model.select(server.id) }
                        } content: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name).lineLimit(1)
                                Text(server.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Text("\(AgentsFormat.words(server.approvalPolicy)) · \(AgentsFormat.count(server.dependentAgents, "agent"))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            } detail: {
                if let server = model.server {
                    AgentMCPServerDetail(model: model, server: server)
                } else {
                    AgentsCard("No server selected") {
                        AgentsEmptyState(title: "Choose a server",
                                         message: "Its tools, which of them run without asking, and its settings appear here.",
                                         systemImage: "server.rack")
                    }
                }
            }
        }
        .task { await model.list.loadIfNeeded() }
    }
}

// MARK: - View-model

/// A server's behaviour settings, as the form edits them.
struct AgentsMCPSettings: Equatable, Sendable {
    var approvalPolicy = ""
    var timeoutSeconds = 30
    var executionMode = ""
    var preToolSpeech = ""
    var interruptionMode = ""
    var secretID = ""

    init() {}

    init(config: JSONValue) {
        approvalPolicy = config["approval_policy"].stringValue ?? ""
        timeoutSeconds = config["response_timeout_secs"].intValue ?? 30
        executionMode = config["execution_mode"].stringValue ?? ""
        preToolSpeech = config["pre_tool_speech"].stringValue ?? ""
        interruptionMode = config["interruption_mode"].stringValue ?? ""
        secretID = config["secret_token"]["secret_id"].stringValue ?? ""
    }

    /// The update body for what differs from `original`.
    func changes(from original: AgentsMCPSettings) -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        if approvalPolicy != original.approvalPolicy, !approvalPolicy.isEmpty { body["approval_policy"] = .string(approvalPolicy) }
        if timeoutSeconds != original.timeoutSeconds { body["response_timeout_secs"] = .number(Double(timeoutSeconds)) }
        if executionMode != original.executionMode, !executionMode.isEmpty { body["execution_mode"] = .string(executionMode) }
        if preToolSpeech != original.preToolSpeech, !preToolSpeech.isEmpty { body["pre_tool_speech"] = .string(preToolSpeech) }
        if interruptionMode != original.interruptionMode, !interruptionMode.isEmpty {
            body["interruption_mode"] = .string(interruptionMode)
        }
        if secretID != original.secretID {
            body["secret_token"] = secretID.isEmpty ? .null : ["secret_id": .string(secretID)]
        }
        return body
    }
}

@MainActor
@Observable
final class AgentMCPServersModel {
    @ObservationIgnored unowned let store: AgentsPlatformStore
    var calls: AgentsCalls { store.calls }

    let list: AgentsPagedList<AgentsMCPServer>
    private(set) var selectedID: String?
    private(set) var server: AgentsMCPServer?
    private(set) var tools: [AgentsMCPTool] = []
    private(set) var toolsError: String?
    var settings = AgentsMCPSettings()
    private(set) var originalSettings = AgentsMCPSettings()
    /// A tool's override being edited, by tool name.
    private(set) var overrides: [String: JSONValue] = [:]
    var overrideTimeout: [String: Int] = [:]
    var overrideExecution: [String: String] = [:]

    // New server
    var creating = false
    var newName = ""
    var newURL = ""
    var newTransport = ""
    var newDescription = ""
    var newApprovalPolicy = ""
    var newSecretID = ""

    init(store: AgentsPlatformStore) {
        self.store = store
        let box = AgentsWeakBox<AgentMCPServersModel>()
        list = AgentsPagedList { _ in await box.value?.fetchList() }
        box.value = self
        newTransport = AgentsSchema.choices(AgentsOp.createMCPServer, "config.transport").first ?? ""
        newApprovalPolicy = AgentsSchema.defaultValue(AgentsOp.createMCPServer, "config.approval_policy")?.stringValue
            ?? AgentsSchema.choices(AgentsOp.createMCPServer, "config.approval_policy").first ?? ""
    }

    private func fetchList() async -> AgentsPage<AgentsMCPServer>? {
        guard let json = await calls.json(AgentsOp.listMCPServers, quiet: true) else { return nil }
        return AgentsPage(items: (json["mcp_servers"].arrayValue ?? []).compactMap(AgentsMCPServer.init(json:)))
    }

    func select(_ id: String) async {
        selectedID = id
        tools = []
        toolsError = nil
        overrides = [:]
        if let known = list.item(id) { show(known) }
        guard let json = await calls.json(AgentsOp.getMCPServer, ["mcp_server_id": .string(id)], slot: id, quiet: true),
              selectedID == id, let server = AgentsMCPServer(json: json) else { return }
        show(server)
        list.upsert(server)
    }

    private func show(_ server: AgentsMCPServer) {
        self.server = server
        settings = AgentsMCPSettings(config: server.config)
        originalSettings = settings
    }

    func loadTools() async {
        guard let selectedID else { return }
        guard let json = await calls.json(AgentsOp.listMCPTools, ["mcp_server_id": .string(selectedID)], slot: selectedID,
                                          quiet: true) else { return }
        // The spec names a tool in the statuses as `mcp:<server id>:<tool name>`.
        let prefix = "mcp:\(selectedID):"
        let statuses = Dictionary(
            (json["tool_approval_statuses"].arrayValue ?? []).compactMap { status -> (String, JSONValue)? in
                guard let id = status["tool_id"].stringValue else { return nil }
                return (id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id, status)
            },
            uniquingKeysWith: { first, _ in first }
        )
        tools = (json["tools"].arrayValue ?? []).compactMap { tool in
            tool["name"].stringValue.map {
                AgentsMCPTool(name: $0, description: tool["description"].stringValue ?? "",
                              inputSchema: tool["inputSchema"], approval: statuses[$0]?["approval_policy"].stringValue,
                              state: statuses[$0]?["state"].stringValue)
            }
        }
        toolsError = json["success"].boolValue == false ? (json["error_message"].stringValue ?? "The server did not list its tools.") : nil
    }

    // MARK: Changing the server

    func saveSettings() async {
        guard let server else { return }
        let changes = settings.changes(from: originalSettings)
        guard !changes.isEmpty else { return }
        var arguments = changes
        arguments["mcp_server_id"] = .string(server.id)
        var consequence = "Every agent using “\(server.name)” (\(AgentsFormat.count(server.dependentAgents, "agent"))) calls "
            + "its tools with the new settings from its next conversation."
        if settings.approvalPolicy != originalSettings.approvalPolicy {
            consequence = Self.approvalChange(to: settings.approvalPolicy, server: server) + " " + consequence
        }
        guard let json = await calls.json(
            AgentsOp.updateMCPServer, arguments, slot: server.id,
            subject: settings.approvalPolicy != originalSettings.approvalPolicy
                ? "“\(server.name)” — tools \(Self.policyWords(settings.approvalPolicy))" : "“\(server.name)”",
            consequence: consequence
        ) else { return }
        if let updated = AgentsMCPServer(json: json) {
            show(updated)
            list.upsert(updated)
        } else {
            originalSettings = settings
        }
    }

    /// What a change of the server's approval policy means, in words.
    static func approvalChange(to policy: String, server: AgentsMCPServer) -> String {
        switch policy {
        case "auto_approve_all":
            "Every tool on \(server.url) will run without asking the caller first — including tools the server adds later."
        case "require_approval_all":
            "Every tool on “\(server.name)” will ask the caller before it runs."
        default:
            "Tools on “\(server.name)” run as each one is set: those allowed run without asking, the rest ask first."
        }
    }

    static func policyWords(_ policy: String) -> String {
        switch policy {
        case "auto_approve_all": "run without asking"
        case "require_approval_all": "all ask first"
        default: "set tool by tool"
        }
    }

    /// Lets one tool run without asking (or makes it ask), under per-tool approval.
    func setApproval(_ tool: AgentsMCPTool, autoApproved: Bool) async {
        guard let server else { return }
        let policy = autoApproved ? "auto_approved" : "requires_approval"
        guard await calls.json(AgentsOp.approveMCPTool, [
            "mcp_server_id": .string(server.id), "tool_name": .string(tool.name),
            "tool_description": .string(tool.description), "input_schema": tool.inputSchema == .null ? [:] : tool.inputSchema,
            "approval_policy": .string(policy),
        ], slot: "\(server.id)/\(tool.name)",
           subject: autoApproved ? "“\(tool.name)” to run without asking" : "“\(tool.name)” to ask first",
           consequence: autoApproved
            ? "Agents may call “\(tool.name)” on \(server.url) without asking the caller first."
            : "Agents must get the caller's approval before calling “\(tool.name)”."
        ) != nil else { return }
        await loadTools()
    }

    func removeApproval(_ tool: AgentsMCPTool) async {
        guard let server else { return }
        guard await calls.json(
            AgentsOp.removeMCPToolApproval, ["mcp_server_id": .string(server.id), "tool_name": .string(tool.name)],
            slot: "\(server.id)/\(tool.name)", subject: "the approval of “\(tool.name)”",
            consequence: "“\(tool.name)” goes back to the server's approval policy (\(AgentsFormat.words(server.approvalPolicy)))."
        ) != nil else { return }
        await loadTools()
    }

    func loadOverride(_ tool: AgentsMCPTool) async {
        guard let server else { return }
        let json = await calls.json(
            AgentsOp.getMCPToolOverride, ["mcp_server_id": .string(server.id), "tool_name": .string(tool.name)],
            slot: "\(server.id)/\(tool.name)", quiet: true
        )
        overrides[tool.name] = json ?? .object([:])
        overrideTimeout[tool.name] = json?["response_timeout_secs"].intValue ?? 0
        overrideExecution[tool.name] = json?["execution_mode"].stringValue ?? ""
    }

    func saveOverride(_ tool: AgentsMCPTool) async {
        guard let server else { return }
        var arguments: [String: JSONValue] = ["mcp_server_id": .string(server.id), "tool_name": .string(tool.name)]
        if let timeout = overrideTimeout[tool.name], timeout > 0 { arguments["response_timeout_secs"] = .number(Double(timeout)) }
        if let mode = overrideExecution[tool.name], !mode.isEmpty { arguments["execution_mode"] = .string(mode) }
        let exists = (overrides[tool.name]?["tool_name"].stringValue) != nil
        let operation = exists ? AgentsOp.updateMCPToolOverride : AgentsOp.addMCPToolOverride
        guard await calls.json(
            operation, arguments, slot: "\(server.id)/\(tool.name)", subject: "“\(tool.name)” on “\(server.name)”",
            consequence: "Agents calling “\(tool.name)” on “\(server.name)” use these settings instead of the server's."
        ) != nil else { return }
        await loadOverride(tool)
    }

    func removeOverride(_ tool: AgentsMCPTool) async {
        guard let server else { return }
        guard await calls.json(
            AgentsOp.removeMCPToolOverride, ["mcp_server_id": .string(server.id), "tool_name": .string(tool.name)],
            slot: "\(server.id)/\(tool.name)", subject: "the override of “\(tool.name)”",
            consequence: "“\(tool.name)” goes back to the server's settings."
        ) != nil else { return }
        overrides[tool.name] = nil
    }

    func delete() async {
        guard let server else { return }
        guard await calls.json(
            AgentsOp.deleteMCPServer, ["mcp_server_id": .string(server.id)], slot: server.id,
            subject: "the MCP server “\(server.name)”",
            consequence: "ElevenLabs forgets the connection to \(server.url). "
                + "\(AgentsFormat.count(server.dependentAgents, "agent")) using it lose its tools."
        ) != nil else { return }
        list.remove(server.id)
        store.directory.mcpServers.remove(server.id)
        selectedID = nil
        self.server = nil
    }

    // MARK: Connecting

    /// What the address typed for a new server is: refused, or allowed with warnings.
    var newAddress: AgentsOutsideAddress { AgentsOutsideAddress(newURL) }

    func createArguments() -> [String: JSONValue]? {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let url = newURL.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, newAddress.isAllowed else { return nil }
        var config: [String: JSONValue] = ["name": .string(name), "url": .string(url)]
        if !newTransport.isEmpty { config["transport"] = .string(newTransport) }
        if !newDescription.isEmpty { config["description"] = .string(newDescription) }
        if !newApprovalPolicy.isEmpty { config["approval_policy"] = .string(newApprovalPolicy) }
        if !newSecretID.isEmpty { config["secret_token"] = ["secret_id": .string(newSecretID)] }
        return ["config": .object(config)]
    }

    func create() async {
        guard let arguments = createArguments() else { return }
        let url = newURL.trimmingCharacters(in: .whitespaces)
        let warnings = newAddress.warnings
        let tools: String = switch newApprovalPolicy {
        case "auto_approve_all": "Its tools will run without asking the caller first."
        case "require_approval_all": "Its tools ask the caller before they run."
        default: "Its tools ask the caller first unless you allow one by one."
        }
        guard let json = await calls.json(
            AgentsOp.createMCPServer, arguments, title: "Connected “\(newName)”",
            subject: "“\(newName)” at \(url)",
            consequence: (warnings.isEmpty ? "" : "Careful: " + warnings.joined(separator: " ") + " ")
                + "Agents you give it to can call its tools during conversations and send it what callers say. "
                + tools + " Only connect servers you trust."
        ), let server = AgentsMCPServer(json: json) else { return }
        list.upsert(server)
        store.directory.mcpServers.upsert(server)
        creating = false
        newName = ""
        newURL = ""
        newDescription = ""
        await select(server.id)
    }

    static let arguments: [AgentsArgument] = [
        AgentsArgument(AgentsOp.getMCPServer, "mcp_server_id"), AgentsArgument(AgentsOp.listMCPTools, "mcp_server_id"),
        AgentsArgument(AgentsOp.updateMCPServer, "mcp_server_id"), AgentsArgument(AgentsOp.updateMCPServer, "approval_policy"),
        AgentsArgument(AgentsOp.updateMCPServer, "response_timeout_secs"), AgentsArgument(AgentsOp.updateMCPServer, "execution_mode"),
        AgentsArgument(AgentsOp.updateMCPServer, "pre_tool_speech"), AgentsArgument(AgentsOp.updateMCPServer, "interruption_mode"),
        AgentsArgument(AgentsOp.updateMCPServer, "secret_token.secret_id"),
        AgentsArgument(AgentsOp.approveMCPTool, "mcp_server_id"), AgentsArgument(AgentsOp.approveMCPTool, "tool_name"),
        AgentsArgument(AgentsOp.approveMCPTool, "tool_description"), AgentsArgument(AgentsOp.approveMCPTool, "input_schema"),
        AgentsArgument(AgentsOp.approveMCPTool, "approval_policy"),
        AgentsArgument(AgentsOp.removeMCPToolApproval, "mcp_server_id"), AgentsArgument(AgentsOp.removeMCPToolApproval, "tool_name"),
        AgentsArgument(AgentsOp.getMCPToolOverride, "mcp_server_id"), AgentsArgument(AgentsOp.getMCPToolOverride, "tool_name"),
        AgentsArgument(AgentsOp.addMCPToolOverride, "mcp_server_id"), AgentsArgument(AgentsOp.addMCPToolOverride, "tool_name"),
        AgentsArgument(AgentsOp.addMCPToolOverride, "response_timeout_secs"), AgentsArgument(AgentsOp.addMCPToolOverride, "execution_mode"),
        AgentsArgument(AgentsOp.updateMCPToolOverride, "mcp_server_id"), AgentsArgument(AgentsOp.updateMCPToolOverride, "tool_name"),
        AgentsArgument(AgentsOp.updateMCPToolOverride, "response_timeout_secs"),
        AgentsArgument(AgentsOp.updateMCPToolOverride, "execution_mode"),
        AgentsArgument(AgentsOp.removeMCPToolOverride, "mcp_server_id"), AgentsArgument(AgentsOp.removeMCPToolOverride, "tool_name"),
        AgentsArgument(AgentsOp.deleteMCPServer, "mcp_server_id"),
        AgentsArgument(AgentsOp.createMCPServer, "config.name"), AgentsArgument(AgentsOp.createMCPServer, "config.url"),
        AgentsArgument(AgentsOp.createMCPServer, "config.transport"), AgentsArgument(AgentsOp.createMCPServer, "config.description"),
        AgentsArgument(AgentsOp.createMCPServer, "config.approval_policy"),
        AgentsArgument(AgentsOp.createMCPServer, "config.secret_token.secret_id"),
    ]
}

// MARK: - Views

private struct AgentMCPServerComposer: View {
    @Bindable var model: AgentMCPServersModel

    var body: some View {
        let runner = model.calls.runner(AgentsOp.createMCPServer)
        AgentsCard("Connect an MCP server", subtitle: "Agents you give it to can call its tools and send it what callers say. Only connect servers you trust.") {
            Button("Close") { model.creating = false }.buttonStyle(.link)
        } content: {
            Form {
                TextField("Name", text: $model.newName, prompt: Text("Order system"))
                TextField("Address", text: $model.newURL, prompt: Text("https://mcp.example.com/sse"))
                Picker("Transport", selection: $model.newTransport) {
                    ForEach(AgentsSchema.choices(AgentsOp.createMCPServer, "config.transport"), id: \.self) { Text($0).tag($0) }
                }
                TextField("Description", text: $model.newDescription, prompt: Text("Optional"))
                Picker("Tools may run", selection: $model.newApprovalPolicy) {
                    ForEach(AgentsSchema.choices(AgentsOp.createMCPServer, "config.approval_policy"), id: \.self) {
                        Text(AgentsFormat.words($0)).tag($0)
                    }
                }
                Picker("Token", selection: $model.newSecretID) {
                    Text("None").tag("")
                    ForEach(model.store.directory.secrets.items) { Text($0.name).tag($0.id) }
                }
                .task { await model.store.directory.secrets.loadIfNeeded() }
            }
            .formStyle(.columns)
            Text("A token the server needs is sent from one of your workspace secrets; add it in Secrets first.")
                .font(.caption).foregroundStyle(.secondary)
            let address = model.newAddress
            if !model.newURL.trimmingCharacters(in: .whitespaces).isEmpty {
                if let refusal = address.refusal {
                    Label(refusal, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
                }
                ForEach(address.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            AgentsRunButton(runner: runner, title: "Connect…", disabled: model.createArguments() == nil) {
                Task { await model.create() }
            }
            AgentsRunnerOutput(runner: runner, showsResult: false)
        }
    }
}

private struct AgentMCPServerDetail: View {
    @Bindable var model: AgentMCPServersModel
    let server: AgentsMCPServer

    var body: some View {
        let calls = model.calls
        VStack(alignment: .leading, spacing: 14) {
            AgentsCard(server.name, subtitle: server.description.isEmpty ? nil : server.description) {
                AgentsFact(label: "Address", value: server.url)
                AgentsFact(label: "Transport", value: server.transport)
                AgentsFact(label: "Used by", value: AgentsFormat.count(server.dependentAgents, "agent"))
                AgentsFact(label: "ID", value: server.id, monospaced: true)
                AgentsRunnerError(runner: calls.runner(AgentsOp.getMCPServer, slot: server.id))
            }
            AgentsCard("Tools", subtitle: "What the server offers agents, and whether each asks the caller before running.") {
                Button("List the server's tools") { Task { await model.loadTools() } }
                AgentsRunnerError(runner: calls.runner(AgentsOp.listMCPTools, slot: server.id))
                if let error = model.toolsError {
                    Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
                ForEach(model.tools) { tool in
                    AgentMCPToolRow(model: model, server: server, tool: tool)
                }
            }
            AgentsCard("Behaviour", subtitle: "How agents use this server's tools.") {
                Form {
                    Picker("Tools may run", selection: $model.settings.approvalPolicy) {
                        ForEach(AgentsSchema.choices(AgentsOp.updateMCPServer, "approval_policy"), id: \.self) {
                            Text(AgentsFormat.words($0)).tag($0)
                        }
                    }
                    let limits = AgentsSchema.range(AgentsOp.updateMCPServer, "response_timeout_secs", fallback: 5...300)
                    Stepper("Give up after \(model.settings.timeoutSeconds) s", value: $model.settings.timeoutSeconds,
                            in: Int(limits.lowerBound)...Int(limits.upperBound))
                    Picker("While a tool runs", selection: $model.settings.executionMode) {
                        ForEach(AgentsSchema.choices(AgentsOp.updateMCPServer, "execution_mode"), id: \.self) {
                            Text(AgentsFormat.words($0)).tag($0)
                        }
                    }
                    Picker("Say something first", selection: $model.settings.preToolSpeech) {
                        ForEach(AgentsSchema.choices(AgentsOp.updateMCPServer, "pre_tool_speech"), id: \.self) {
                            Text(AgentsFormat.words($0)).tag($0)
                        }
                    }
                    Picker("Interruptions", selection: $model.settings.interruptionMode) {
                        ForEach(AgentsSchema.choices(AgentsOp.updateMCPServer, "interruption_mode"), id: \.self) {
                            Text(AgentsFormat.words($0)).tag($0)
                        }
                    }
                    Picker("Token", selection: $model.settings.secretID) {
                        Text("None").tag("")
                        ForEach(model.store.directory.secrets.items) { Text($0.name).tag($0.id) }
                        if !model.settings.secretID.isEmpty, model.store.directory.secrets.item(model.settings.secretID) == nil {
                            Text(model.settings.secretID).tag(model.settings.secretID)
                        }
                    }
                    .task { await model.store.directory.secrets.loadIfNeeded() }
                }
                .formStyle(.columns)
                if model.settings.approvalPolicy != model.originalSettings.approvalPolicy {
                    Label(AgentMCPServersModel.approvalChange(to: model.settings.approvalPolicy, server: server),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                AgentsRunButton(runner: calls.runner(AgentsOp.updateMCPServer, slot: server.id), title: "Save…",
                                    disabled: model.settings == model.originalSettings) {
                    Task { await model.saveSettings() }
                }
                AgentsRunnerOutput(runner: calls.runner(AgentsOp.updateMCPServer, slot: server.id))
            }
            AgentsCard("Disconnect") {
                AgentsRunButton(runner: calls.runner(AgentsOp.deleteMCPServer, slot: server.id), title: "Delete the server…") {
                    Task { await model.delete() }
                }
                AgentsRunnerOutput(runner: calls.runner(AgentsOp.deleteMCPServer, slot: server.id))
            }
        }
    }
}

private struct AgentMCPToolRow: View {
    @Bindable var model: AgentMCPServersModel
    let server: AgentsMCPServer
    let tool: AgentsMCPTool
    @State private var expanded = false

    var body: some View {
        let calls = model.calls
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.name).font(.callout.weight(.medium))
                    if !tool.description.isEmpty {
                        Text(tool.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if let badge = tool.badge {
                    AgentsBadge(text: badge.text, color: badge.attention ? .orange : .secondary)
                }
                Menu("Approval") {
                    Button("Run without asking…") { Task { await model.setApproval(tool, autoApproved: true) } }
                    Button("Ask the caller first…") { Task { await model.setApproval(tool, autoApproved: false) } }
                    Button("Follow the server's policy…") { Task { await model.removeApproval(tool) } }
                }
                .fixedSize()
            }
            AgentsRunnerOutput(runner: calls.runner(AgentsOp.approveMCPTool, slot: "\(server.id)/\(tool.name)"), showsResult: false)
            AgentsRunnerOutput(runner: calls.runner(AgentsOp.removeMCPToolApproval, slot: "\(server.id)/\(tool.name)"), showsResult: false)
            DisclosureGroup("Override its settings", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Stepper("Timeout \(model.overrideTimeout[tool.name].map { $0 > 0 ? "\($0) s" : "as the server" } ?? "as the server")",
                                value: Binding(get: { model.overrideTimeout[tool.name] ?? 0 },
                                               set: { model.overrideTimeout[tool.name] = $0 }),
                                in: 0...300, step: 5)
                        Picker("While it runs", selection: Binding(get: { model.overrideExecution[tool.name] ?? "" },
                                                                   set: { model.overrideExecution[tool.name] = $0 })) {
                            Text("As the server").tag("")
                            ForEach(AgentsSchema.choices(AgentsOp.addMCPToolOverride, "execution_mode"), id: \.self) {
                                Text(AgentsFormat.words($0)).tag($0)
                            }
                        }
                        .fixedSize()
                    }
                    HStack {
                        Button("Save override…") { Task { await model.saveOverride(tool) } }
                        if model.overrides[tool.name]?["tool_name"].stringValue != nil {
                            Button("Remove override…") { Task { await model.removeOverride(tool) } }
                        }
                    }
                    ForEach([AgentsOp.addMCPToolOverride, AgentsOp.updateMCPToolOverride, AgentsOp.removeMCPToolOverride], id: \.self) {
                        AgentsRunnerOutput(runner: calls.runner($0, slot: "\(server.id)/\(tool.name)"), showsResult: false)
                    }
                }
                .padding(.top, 4)
            }
            .font(.caption)
            .onChange(of: expanded) { if expanded, model.overrides[tool.name] == nil { Task { await model.loadOverride(tool) } } }
            Divider()
        }
    }
}
