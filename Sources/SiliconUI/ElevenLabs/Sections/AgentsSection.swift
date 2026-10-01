import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Voice agents: the list, a new agent, and one agent's configuration — what it says and how
/// (prompt, first message, language), its voice, its model and limits, the tools, documents
/// and MCP servers it may use, how it is shared, and its branches and versions. Also the
/// workspace-wide agent settings. Talking to an agent live is the realtime wave's; its place
/// is kept below the editor.
struct AgentsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        AgentsScreen(model: AgentsPlatformStore.shared(for: app).agents)
    }
}

/// The screen, given its view-model — what snapshots and tests draw.
struct AgentsScreen: View {
    let model: AgentsModel

    var body: some View {
        ElevenLabsSectionPage(.agents, accessory: {
            HStack(spacing: 8) {
                AgentsRefreshButton(list: model.list, help: "Fetch the agents again")
                Button {
                    model.startCreating()
                } label: {
                    Label("New agent", systemImage: "plus")
                }
                .disabled(!AgentsCalls.isAvailable(AgentsOp.createAgent))
            }
        }) {
            AgentsMasterDetail {
                AgentsAgentList(model: model)
            } detail: {
                if model.creating {
                    AgentsNewAgentForm(model: model)
                } else if model.selectedID != nil {
                    AgentsAgentEditor(model: model)
                } else {
                    AgentsCard("No agent selected") {
                        AgentsEmptyState(
                            title: "Choose an agent",
                            message: "Pick one on the left to change its prompt, voice, model, tools and sharing — or make a new one.",
                            systemImage: "person.2.wave.2"
                        )
                    }
                }
            }
            AgentsWorkspaceSettingsCard(model: model.workspace)
        }
        .agentsQuestion(model.questions)
        .task { await model.list.loadIfNeeded() }
    }
}

// MARK: - View-model

@MainActor
@Observable
final class AgentsModel {
    enum Tab: String, CaseIterable, Identifiable {
        case behaviour = "Behaviour"
        case voice = "Voice"
        case model = "Model & limits"
        case tools = "Tools & knowledge"
        case sharing = "Sharing"
        case branches = "Branches"
        var id: String { rawValue }
    }

    @ObservationIgnored unowned let store: AgentsPlatformStore
    var calls: AgentsCalls { store.calls }

    // List
    var search = ""
    var showArchived = false
    /// One of the spec's `sort_by` values, or "" for ElevenLabs' order.
    var sortBy = ""
    let list: AgentsPagedList<AgentsAgent>

    // Selection
    private(set) var selectedID: String?
    var tab: Tab = .behaviour
    /// The agent as loaded, and the edits made since.
    private(set) var loaded: AgentsAgentDraft?
    var draft = AgentsAgentDraft()
    /// Everything else ElevenLabs said about the agent, for the details the editor does not own.
    private(set) var detailJSON: JSONValue = .null
    private(set) var versionID: String?
    private(set) var branchID: String?
    private(set) var mainBranchID: String?
    /// Describes the change in the agent's version history.
    var changeDescription = ""

    // New agent
    private(set) var creating = false
    var newDraft = AgentsAgentDraft.newAgent()

    // Duplicate
    var duplicateName = ""

    // Sub-areas
    let branches: AgentsBranchesModel
    let sharing: AgentsSharingModel
    let workspace: AgentsWorkspaceSettingsModel
    /// Questions for edits that reach callers or outside servers without the risk table asking.
    let questions = AgentsQuestionBox()
    /// Why "Keep as a draft" cannot run for the agent on screen, or nil.
    private(set) var draftProblem: String?
    /// Said after a save whose answer was lost, about the agent on screen.
    private(set) var lostSaveNote: String?
    /// The LLMs ElevenLabs offers this account (filtered by region); nil until fetched.
    private(set) var availableLLMs: [AgentsLLMInfo]?

    init(store: AgentsPlatformStore) {
        self.store = store
        let calls = store.calls
        let box = AgentsWeakBox<AgentsModel>()
        list = AgentsPagedList { cursor in await box.value?.fetchPage(cursor) }
        branches = AgentsBranchesModel(calls: calls, questions: questions)
        sharing = AgentsSharingModel(calls: calls)
        workspace = AgentsWorkspaceSettingsModel(calls: calls)
        box.value = self
    }

    private func fetchPage(_ cursor: String?) async -> AgentsPage<AgentsAgent>? {
        var arguments: [String: JSONValue] = ["page_size": 50, "archived": .bool(showArchived)]
        let search = search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty { arguments["search"] = .string(search) }
        if !sortBy.isEmpty { arguments["sort_by"] = .string(sortBy) }
        if let cursor { arguments["cursor"] = .string(cursor) }
        guard let json = await calls.json(AgentsOp.listAgents, arguments, quiet: true) else { return nil }
        return AgentsPage(
            items: (json["agents"].arrayValue ?? []).compactMap(AgentsAgent.init(json:)),
            cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
        )
    }

    /// Whether the editor holds changes not yet saved.
    var isDirty: Bool {
        guard let loaded else { return false }
        return !draft.changes(from: loaded).isEmpty
    }

    var selectedName: String {
        loaded?.name ?? selectedID.flatMap { list.item($0)?.name } ?? "this agent"
    }

    // MARK: Selecting

    func select(_ id: String) async {
        creating = false
        guard selectedID != id || loaded == nil else { return }
        selectedID = id
        loaded = nil
        detailJSON = .null
        changeDescription = ""
        duplicateName = ""
        draftProblem = nil
        lostSaveNote = nil
        branches.reset(agentID: id)
        sharing.reset(agentID: id)
        await load(id)
    }

    /// Fetches the agent's configuration into the editor.
    func load(_ id: String, branchID: String? = nil) async {
        var arguments: [String: JSONValue] = ["agent_id": .string(id)]
        if let branchID { arguments["branch_id"] = .string(branchID) }
        let runner = calls.runner(AgentsOp.getAgent, slot: id)
        guard let json = await calls.json(AgentsOp.getAgent, arguments, slot: id, quiet: true) else { return }
        // The answer carries the agent's shareable token; it is not what was asked for here,
        // so it is not shown. Sharing fetches the link when the owner wants it.
        runner.dismissCredential()
        guard selectedID == id else { return }
        apply(json)
    }

    /// Takes an agent answer (get or patch) into the editor.
    func apply(_ json: JSONValue) {
        detailJSON = json
        let parsed = AgentsAgentDraft(json: json)
        loaded = parsed
        draft = parsed
        versionID = json["version_id"].stringValue
        branchID = json["branch_id"].stringValue
        mainBranchID = json["main_branch_id"].stringValue
        branches.mainBranchID = mainBranchID
        branches.currentVersionID = versionID
        if let id = json["agent_id"].stringValue {
            list.upsertIfPresent(AgentsAgent(
                id: id, name: parsed.name, voiceID: parsed.voiceID, tags: parsed.tags,
                createdAt: list.item(id)?.createdAt, lastCallAt: list.item(id)?.lastCallAt,
                archived: json["platform_settings"]["archived"].boolValue ?? false
            ))
        }
    }

    func revert() {
        if let loaded { draft = loaded }
    }

    func refreshList() async {
        await list.refresh()
    }

    // MARK: Saving

    /// What Save would send: the changed fields only, plus the agent id.
    func saveArguments() -> [String: JSONValue]? {
        guard let selectedID, let loaded else { return nil }
        let changes = draft.changes(from: loaded)
        guard !changes.isEmpty else { return nil }
        var arguments = changes
        arguments["agent_id"] = .string(selectedID)
        let note = changeDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { arguments["version_description"] = .string(note) }
        return arguments
    }

    /// An outside service the agent would start sending callers' words to: an MCP server or a
    /// webhook tool newly given to it.
    struct OutsideConnection: Equatable, Sendable {
        var name: String
        /// Where it sends, as a host; nil when the list has not said.
        var host: String?
        var line: String { host.map { "\(name) (\($0))" } ?? name }
    }

    /// The MCP servers and webhook tools Save would newly give the agent.
    func newOutsideConnections() -> [OutsideConnection] {
        guard let loaded else { return [] }
        let directory = store.directory
        var found: [OutsideConnection] = []
        for id in draft.mcpServerIDs where !loaded.mcpServerIDs.contains(id) {
            let server = directory.mcpServers.item(id)
            found.append(OutsideConnection(name: server?.name ?? id, host: server.flatMap { URL(string: $0.url)?.host }))
        }
        for id in draft.toolIDs where !loaded.toolIDs.contains(id) {
            let tool = directory.tools.item(id)
            // Client tools run in the owner's own app; only tools that call out are asked about.
            guard tool?.type != "client", tool?.type != "system" else { continue }
            let url = tool?.config["api_schema"]["url"].stringValue
            found.append(OutsideConnection(name: tool?.name ?? id, host: url.flatMap { URL(string: $0)?.host }))
        }
        return found
    }

    /// Saves the changes. When they give the agent an MCP server or a webhook tool, asks first:
    /// that is the step that starts sending what callers say to that address.
    func save() async {
        guard let agentID = selectedID, let arguments = saveArguments() else { return }
        let saved = draft
        let name = saved.name
        let outside = newOutsideConnections()
        guard !outside.isEmpty else {
            await commitSave(arguments, agentID: agentID, saved: saved)
            return
        }
        let what = outside.count == 1 ? outside[0].line : AgentsFormat.count(outside.count, "outside service")
        questions.ask(AgentsQuestion(
            title: "Let “\(name)” send callers' words to \(what)?",
            message: "From its next conversation the agent may call "
                + ListFormatter.localizedString(byJoining: outside.map(\.line))
                + ", passing on what callers say. Only connect services you trust.",
            confirmLabel: "Save and connect"
        )) { [weak self] in
            await self?.commitSave(arguments, agentID: agentID, saved: saved)
        }
    }

    /// Saves exactly the changes the question (if any) was about, to the agent they were made on.
    private func commitSave(_ arguments: [String: JSONValue], agentID selectedID: String, saved: AgentsAgentDraft) async {
        let runner = calls.runner(AgentsOp.updateAgent, slot: selectedID)
        lostSaveNote = nil
        guard let json = await calls.json(AgentsOp.updateAgent, arguments, slot: selectedID,
                                          title: "Saved agent “\(saved.name)”")
        else {
            if calls.outcomeWasUnknown(AgentsOp.updateAgent, slot: selectedID) { await rebaseAfterLostSave(selectedID, name: saved.name) }
            return
        }
        runner.dismissCredential()
        changeDescription = ""
        guard self.selectedID == selectedID else { return }
        if json["agent_id"].stringValue != nil {
            apply(json)
        } else {
            loaded = saved
        }
    }

    /// What the editor says after a save whose answer was lost.
    nonisolated static func lostSaveMessage(_ name: String) -> String {
        "The answer to saving “\(name)” was lost, so it may have been saved. The agent has been read again: what "
            + "still differs from it shows as unsaved, and Revert goes back to it."
    }

    /// After a save of agent `id` whose answer was lost (a 5xx, a timeout, a cancel after
    /// sending): the agent is read again and becomes the editor's base — what ElevenLabs holds —
    /// while the draft keeps the owner's edits. What the save carried out then shows as saved,
    /// the rest as unsaved; and Revert, or a list edited in place, starts from what ElevenLabs
    /// holds, not from the agent before the save (whose next save would take the change back).
    private func rebaseAfterLostSave(_ id: String, name: String) async {
        var arguments: [String: JSONValue] = ["agent_id": .string(id)]
        if let branchID, branchID != mainBranchID { arguments["branch_id"] = .string(branchID) }
        guard let json = await calls.json(AgentsOp.getAgent, arguments, slot: id, quiet: true) else { return }
        calls.runner(AgentsOp.getAgent, slot: id).dismissCredential()
        guard selectedID == id else { return }
        let edits = draft
        apply(json)
        draft = edits
        lostSaveNote = Self.lostSaveMessage(name)
    }

    // MARK: Creating

    func startCreating() {
        creating = true
        newDraft = AgentsAgentDraft.newAgent()
    }

    func cancelCreating() {
        creating = false
    }

    func create() async {
        let arguments = newDraft.createArguments()
        guard let json = await calls.json(
            AgentsOp.createAgent, arguments, title: "Created agent “\(newDraft.name)”",
            holdIfUnknown: AgentsCreateHolds.lost("the agent “\(newDraft.name)”", check: "the agents list")
        ) else {
            // It may have been made: the list shows whether it was; the new agent's form stays.
            if calls.outcomeWasUnknown(AgentsOp.createAgent) {
                calls.holds.onReadAgain(AgentsOp.createAgent) { [weak self] in await self?.list.refresh() }
                await list.refresh()
            }
            return
        }
        guard let id = json["agent_id"].stringValue else { return }
        list.upsert(AgentsAgent(id: id, name: newDraft.name, voiceID: newDraft.voiceID, tags: newDraft.tags,
                                createdAt: Date()))
        store.directory.agents.upsert(AgentsAgent(id: id, name: newDraft.name))
        creating = false
        await select(id)
    }

    // MARK: Duplicating and deleting

    func duplicate() async {
        guard let selectedID else { return }
        let name = duplicateName.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments: [String: JSONValue] = ["agent_id": .string(selectedID)]
        if !name.isEmpty { arguments["name"] = .string(name) }
        guard let json = await calls.json(AgentsOp.duplicateAgent, arguments, slot: selectedID,
                                          title: "Duplicated “\(selectedName)”"),
              let id = json["agent_id"].stringValue
        else { return }
        let copyName = name.isEmpty ? "\(selectedName) (copy)" : name
        list.upsert(AgentsAgent(id: id, name: copyName, createdAt: Date()))
        store.directory.agents.upsert(AgentsAgent(id: id, name: copyName))
        duplicateName = ""
        await select(id)
    }

    func delete() async {
        guard let selectedID else { return }
        let name = selectedName
        guard await calls.json(
            AgentsOp.deleteAgent, ["agent_id": .string(selectedID)], slot: selectedID,
            subject: "the agent “\(name)”",
            consequence: "ElevenLabs will delete “\(name)” and its configuration, branches and versions. "
                + "Phone numbers, widgets and links that use it stop working. Its past conversations stay in history."
        ) != nil else { return }
        list.remove(selectedID)
        store.directory.agents.remove(selectedID)
        guard self.selectedID == selectedID else { return }
        self.selectedID = nil
        loaded = nil
        detailJSON = .null
    }

    // MARK: Model list

    /// The LLM choices: the ones this account can use when known, else the spec's, always
    /// including the one the agent has now.
    var llmChoices: [String] {
        let spec = AgentsSchema.choices(AgentsOp.createAgent, "conversation_config.agent.prompt.llm")
        var choices = availableLLMs.map { $0.filter { !$0.deprecated }.map(\.llm) } ?? spec
        for current in [draft.llm, newDraft.llm] where !current.isEmpty && !choices.contains(current) {
            choices.insert(current, at: 0)
        }
        return choices
    }

    func loadLLMs() async {
        guard availableLLMs == nil else { return }
        guard let json = await calls.json(AgentsOp.listLLMs, quiet: true) else { return }
        availableLLMs = (json["llms"].arrayValue ?? []).compactMap(AgentsLLMInfo.init(json:))
    }

    /// Size and kind of the documents the agent uses, by id — looked up for the ones on screen.
    private(set) var knowledgeSummaries: [String: AgentsKnowledgeDocument] = [:]

    func loadKnowledgeSummaries() async {
        let ids = draft.knowledge.map(\.id).filter { knowledgeSummaries[$0] == nil }
        guard !ids.isEmpty else { return }
        guard let json = await calls.json(AgentsOp.documentSummaries, ["document_ids": .array(ids.map(JSONValue.string))],
                                          quiet: true) else { return }
        for (id, entry) in json.objectValue ?? [:] where entry["status"].stringValue != "failure" {
            if let document = AgentsKnowledgeDocument(json: entry["data"]) { knowledgeSummaries[id] = document }
        }
    }

    /// Fields of an agent's answer that are credentials: never sent back, so ElevenLabs keeps
    /// what it has.
    static let credentialKeys: Set<String> = ["shareable_token"]

    /// The draft body: the fetched configuration with the edits merged in and credential fields
    /// left out (ElevenLabs keeps what it has for them). Header values and everything else go
    /// back as fetched — the app's runner shows them as they are. If the answer still holds a
    /// masked value anywhere, the draft is refused rather than send the mask over the real one.
    func draftBody() -> Result<[String: JSONValue], AgentsDraftRefusal> {
        guard let loaded else { return .failure(AgentsDraftRefusal(message: "The agent has not been fetched yet.")) }
        let changes = draft.changes(from: loaded)
        let config = AgentsJSON.merging(changes["conversation_config"] ?? [:], into: detailJSON["conversation_config"])
        let platform = AgentsJSON.merging(changes["platform_settings"] ?? [:], into: detailJSON["platform_settings"])
        var body: [String: JSONValue] = [
            "name": .string(draft.name),
            "conversation_config": AgentsJSON.removing(keys: Self.credentialKeys, from: config),
            "platform_settings": AgentsJSON.removing(keys: Self.credentialKeys, from: platform),
            "workflow": AgentsJSON.removing(
                keys: Self.credentialKeys,
                from: detailJSON["workflow"] == .null ? ["edges": [:], "nodes": [:]] : detailJSON["workflow"]
            ),
        ]
        if !draft.tags.isEmpty { body["tags"] = .array(draft.tags.map(JSONValue.string)) }
        let masked = AgentsJSON.paths(of: ElevenLabsRedaction.placeholder, in: .object(body))
        guard masked.isEmpty else {
            return .failure(AgentsDraftRefusal(message:
                "The fetched configuration has masked values ("
                + masked.prefix(3).joined(separator: ", ") + (masked.count > 3 ? ", …" : "")
                + "); a draft would send the mask back over the real values. Save the change instead."))
        }
        return .success(body)
    }

    /// Keeps the edits as a draft on the branch on screen instead of committing a version.
    /// When the draft newly gives the agent an MCP server or webhook tool, asks first, as Save
    /// does: the draft goes live the day it is merged or deployed.
    func saveAsDraft() async {
        guard let agentID = selectedID, let branchID else { return }
        let body: [String: JSONValue]
        switch draftBody() {
        case .failure(let refusal):
            draftProblem = refusal.message
            return
        case .success(let built):
            draftProblem = nil
            body = built
        }
        var arguments = body
        arguments["agent_id"] = .string(agentID)
        arguments["branch_id"] = .string(branchID)
        let name = draft.name
        let outside = newOutsideConnections()
        guard !outside.isEmpty else {
            await commitDraft(arguments, agentID: agentID, name: name)
            return
        }
        let what = outside.count == 1 ? outside[0].line : AgentsFormat.count(outside.count, "outside service")
        questions.ask(AgentsQuestion(
            title: "Keep a draft that lets “\(name)” send callers' words to \(what)?",
            message: "Once this draft is merged or deployed, the agent may call "
                + ListFormatter.localizedString(byJoining: outside.map(\.line))
                + ", passing on what callers say. Only connect services you trust.",
            confirmLabel: "Keep the draft"
        )) { [weak self] in
            await self?.commitDraft(arguments, agentID: agentID, name: name)
        }
    }

    /// Keeps exactly the draft the question (if any) was about, on the agent and branch it was built for.
    private func commitDraft(_ arguments: [String: JSONValue], agentID: String, name: String) async {
        guard await calls.json(AgentsOp.createDraft, arguments, slot: agentID, title: "Draft of “\(name)”") != nil
        else { return }
        if selectedID == agentID { await branches.load() }
    }

    /// Shows this agent's conversations.
    func openConversations() {
        guard let selectedID else { return }
        store.conversations.filterAgentID = selectedID
        Task { await store.conversations.list.refresh() }
        store.open(.agentConversations)
    }

    /// Every argument this screen sends, for the spec check.
    static let arguments: [AgentsArgument] = {
        var arguments = [
            AgentsArgument(AgentsOp.listAgents, "page_size"), AgentsArgument(AgentsOp.listAgents, "archived"),
            AgentsArgument(AgentsOp.listAgents, "search"), AgentsArgument(AgentsOp.listAgents, "sort_by"),
            AgentsArgument(AgentsOp.listAgents, "cursor"),
            AgentsArgument(AgentsOp.getAgent, "agent_id"), AgentsArgument(AgentsOp.getAgent, "branch_id"),
            AgentsArgument(AgentsOp.updateAgent, "agent_id"), AgentsArgument(AgentsOp.updateAgent, "name"),
            AgentsArgument(AgentsOp.updateAgent, "tags"), AgentsArgument(AgentsOp.updateAgent, "version_description"),
            AgentsArgument(AgentsOp.updateAgent, "conversation_config"),
            AgentsArgument(AgentsOp.updateAgent, "platform_settings"),
            AgentsArgument(AgentsOp.createAgent, "name"), AgentsArgument(AgentsOp.createAgent, "tags"),
            AgentsArgument(AgentsOp.duplicateAgent, "agent_id"), AgentsArgument(AgentsOp.duplicateAgent, "name"),
            AgentsArgument(AgentsOp.deleteAgent, "agent_id"),
            AgentsArgument(AgentsOp.documentSummaries, "document_ids"),
            AgentsArgument(AgentsOp.createDraft, "agent_id"), AgentsArgument(AgentsOp.createDraft, "branch_id"),
            AgentsArgument(AgentsOp.createDraft, "name"), AgentsArgument(AgentsOp.createDraft, "tags"),
            AgentsArgument(AgentsOp.createDraft, "conversation_config"),
            AgentsArgument(AgentsOp.createDraft, "platform_settings"), AgentsArgument(AgentsOp.createDraft, "workflow"),
            AgentsArgument(AgentsOp.agentSummaries, "agent_ids"),
        ]
        // The patch takes the same configuration the create does; its nested fields are checked
        // against the create's schema, which spells them out.
        arguments += AgentsAgentDraft.configPaths.map { AgentsArgument(AgentsOp.createAgent, $0) }
        arguments += AgentsBranchesModel.arguments + AgentsSharingModel.arguments + AgentsWorkspaceSettingsModel.arguments
        return arguments
    }()
}

extension AgentsPagedList where Item == AgentsAgent {
    /// Replaces the agent if the list has it; leaves the list alone otherwise.
    func upsertIfPresent(_ agent: AgentsAgent) {
        if item(agent.id) != nil { upsert(agent) }
    }
}

// MARK: - The editable configuration

/// Why a draft cannot be kept, in words.
struct AgentsDraftRefusal: Error, Equatable, Sendable {
    var message: String
}

struct AgentsKnowledgeLocator: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var type: String
    /// auto (retrieved when relevant) or prompt (always in the prompt).
    var usageMode: String

    var json: JSONValue {
        ["id": .string(id), "name": .string(name), "type": .string(type), "usage_mode": .string(usageMode)]
    }
}

/// The parts of an agent's configuration the editor changes, read from and written back to the
/// API's own nesting. Everything else in the configuration is left as ElevenLabs has it: Save
/// sends only what changed.
struct AgentsAgentDraft: Equatable, Sendable {
    var name = ""
    var tags: [String] = []
    var firstMessage = ""
    var prompt = ""
    var language = "en"
    var llm = ""
    var temperature: Double = 0
    var maxTokens = -1
    var voiceID = ""
    var ttsModel = ""
    var stability = 0.5
    var similarity = 0.8
    var speed = 1.0
    var maxDurationSeconds = 600
    var dailyLimit = 100_000
    var concurrencyLimit = -1
    var toolIDs: [String] = []
    var knowledge: [AgentsKnowledgeLocator] = []
    var mcpServerIDs: [String] = []
    var requiresAuth = false

    init() {}

    /// A new agent's starting values: the spec's defaults where it has them.
    static func newAgent() -> AgentsAgentDraft {
        var draft = AgentsAgentDraft()
        let op = AgentsOp.createAgent
        draft.name = ""
        draft.firstMessage = "Hello! How can I help you today?"
        draft.language = AgentsSchema.defaultValue(op, "conversation_config.agent.language")?.stringValue ?? "en"
        draft.llm = AgentsSchema.defaultValue(op, "conversation_config.agent.prompt.llm")?.stringValue ?? ""
        draft.voiceID = AgentsSchema.defaultValue(op, "conversation_config.tts.voice_id")?.stringValue ?? ""
        draft.ttsModel = AgentsSchema.defaultValue(op, "conversation_config.tts.model_id")?.stringValue ?? ""
        return draft
    }

    /// From a `get_agent_route` (or patch) answer.
    init(json: JSONValue) {
        let config = json["conversation_config"]
        let agent = config["agent"]
        let prompt = agent["prompt"]
        let tts = config["tts"]
        let platform = json["platform_settings"]
        name = json["name"].stringValue ?? ""
        tags = AgentsJSON.strings(json["tags"])
        firstMessage = agent["first_message"].stringValue ?? ""
        language = agent["language"].stringValue ?? "en"
        self.prompt = prompt["prompt"].stringValue ?? ""
        llm = prompt["llm"].stringValue ?? ""
        temperature = prompt["temperature"].doubleValue ?? 0
        maxTokens = prompt["max_tokens"].intValue ?? -1
        toolIDs = AgentsJSON.strings(prompt["tool_ids"])
        mcpServerIDs = AgentsJSON.strings(prompt["mcp_server_ids"])
        knowledge = (prompt["knowledge_base"].arrayValue ?? []).compactMap { item in
            item["id"].stringValue.map {
                AgentsKnowledgeLocator(
                    id: $0, name: item["name"].stringValue ?? $0, type: item["type"].stringValue ?? "text",
                    usageMode: item["usage_mode"].stringValue ?? "auto"
                )
            }
        }
        voiceID = tts["voice_id"].stringValue ?? ""
        ttsModel = tts["model_id"].stringValue ?? ""
        stability = tts["stability"].doubleValue ?? 0.5
        similarity = tts["similarity_boost"].doubleValue ?? 0.8
        speed = tts["speed"].doubleValue ?? 1.0
        maxDurationSeconds = config["conversation"]["max_duration_seconds"].intValue ?? 600
        dailyLimit = platform["call_limits"]["daily_limit"].intValue ?? 100_000
        concurrencyLimit = platform["call_limits"]["agent_concurrency_limit"].intValue ?? -1
        requiresAuth = platform["auth"]["enable_auth"].boolValue ?? false
    }

    /// Where each field lives in the configuration, relative to the body.
    static let configPaths: [String] = [
        "conversation_config.agent.first_message", "conversation_config.agent.language",
        "conversation_config.agent.prompt.prompt", "conversation_config.agent.prompt.llm",
        "conversation_config.agent.prompt.temperature", "conversation_config.agent.prompt.max_tokens",
        "conversation_config.agent.prompt.tool_ids", "conversation_config.agent.prompt.mcp_server_ids",
        "conversation_config.agent.prompt.knowledge_base[].id",
        "conversation_config.agent.prompt.knowledge_base[].name",
        "conversation_config.agent.prompt.knowledge_base[].type",
        "conversation_config.agent.prompt.knowledge_base[].usage_mode",
        "conversation_config.tts.voice_id", "conversation_config.tts.model_id",
        "conversation_config.tts.stability", "conversation_config.tts.similarity_boost",
        "conversation_config.tts.speed", "conversation_config.conversation.max_duration_seconds",
        "platform_settings.call_limits.daily_limit", "platform_settings.call_limits.agent_concurrency_limit",
        "platform_settings.auth.enable_auth",
    ]

    /// The patch body for what differs from `original`: top-level fields by name, nested ones
    /// in their objects. Empty when nothing changed.
    func changes(from original: AgentsAgentDraft) -> [String: JSONValue] {
        var body: JSONValue = .object([:])
        func set(_ path: String, _ value: JSONValue) { body = AgentsJSON.setting(value, at: path, in: body) }
        if name != original.name { set("name", .string(name)) }
        if tags != original.tags { set("tags", .array(tags.map(JSONValue.string))) }
        if firstMessage != original.firstMessage { set("conversation_config.agent.first_message", .string(firstMessage)) }
        if language != original.language { set("conversation_config.agent.language", .string(language)) }
        if prompt != original.prompt { set("conversation_config.agent.prompt.prompt", .string(prompt)) }
        if llm != original.llm { set("conversation_config.agent.prompt.llm", .string(llm)) }
        if temperature != original.temperature {
            set("conversation_config.agent.prompt.temperature", .number(temperature))
        }
        if maxTokens != original.maxTokens {
            set("conversation_config.agent.prompt.max_tokens", .number(Double(maxTokens)))
        }
        if toolIDs != original.toolIDs {
            set("conversation_config.agent.prompt.tool_ids", .array(toolIDs.map(JSONValue.string)))
        }
        if mcpServerIDs != original.mcpServerIDs {
            set("conversation_config.agent.prompt.mcp_server_ids", .array(mcpServerIDs.map(JSONValue.string)))
        }
        if knowledge != original.knowledge {
            set("conversation_config.agent.prompt.knowledge_base", .array(knowledge.map(\.json)))
        }
        if voiceID != original.voiceID { set("conversation_config.tts.voice_id", .string(voiceID)) }
        if ttsModel != original.ttsModel { set("conversation_config.tts.model_id", .string(ttsModel)) }
        if stability != original.stability { set("conversation_config.tts.stability", .number(stability)) }
        if similarity != original.similarity { set("conversation_config.tts.similarity_boost", .number(similarity)) }
        if speed != original.speed { set("conversation_config.tts.speed", .number(speed)) }
        if maxDurationSeconds != original.maxDurationSeconds {
            set("conversation_config.conversation.max_duration_seconds", .number(Double(maxDurationSeconds)))
        }
        if dailyLimit != original.dailyLimit {
            set("platform_settings.call_limits.daily_limit", .number(Double(dailyLimit)))
        }
        if concurrencyLimit != original.concurrencyLimit {
            set("platform_settings.call_limits.agent_concurrency_limit", .number(Double(concurrencyLimit)))
        }
        if requiresAuth != original.requiresAuth { set("platform_settings.auth.enable_auth", .bool(requiresAuth)) }
        return body.objectValue ?? [:]
    }

    /// The create body: a name, tags, and the configuration the new-agent form covers.
    func createArguments() -> [String: JSONValue] {
        var body: JSONValue = .object([:])
        func set(_ path: String, _ value: JSONValue) { body = AgentsJSON.setting(value, at: path, in: body) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { set("name", .string(trimmed)) }
        if !tags.isEmpty { set("tags", .array(tags.map(JSONValue.string))) }
        set("conversation_config.agent.first_message", .string(firstMessage))
        set("conversation_config.agent.language", .string(language.isEmpty ? "en" : language))
        set("conversation_config.agent.prompt.prompt", .string(prompt))
        if !llm.isEmpty { set("conversation_config.agent.prompt.llm", .string(llm)) }
        if !voiceID.isEmpty { set("conversation_config.tts.voice_id", .string(voiceID)) }
        if !ttsModel.isEmpty { set("conversation_config.tts.model_id", .string(ttsModel)) }
        return body.objectValue ?? [:]
    }

    /// Tags as the owner types them: comma-separated.
    var tagsText: String {
        get { tags.joined(separator: ", ") }
        set {
            tags = newValue.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
    }
}

// MARK: - List

private struct AgentsAgentList: View {
    @Bindable var model: AgentsModel

    var body: some View {
        AgentsCard("Agents", subtitle: model.list.items.isEmpty ? nil : AgentsFormat.count(model.list.items.count, "agent")) {
            AgentsSearchField(prompt: "Search agents by name", text: $model.search) {
                Task { await model.refreshList() }
            }
            HStack {
                Toggle("Archived", isOn: $model.showArchived)
                    .toggleStyle(.checkbox)
                    .onChange(of: model.showArchived) { Task { await model.refreshList() } }
                Spacer()
                Picker("Sort", selection: $model.sortBy) {
                    Text("Default order").tag("")
                    ForEach(AgentsSchema.choices(AgentsOp.listAgents, "sort_by"), id: \.self) { value in
                        Text(AgentsFormat.words(value)).tag(value)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: model.sortBy) { Task { await model.refreshList() } }
            }
            .font(.caption)
            AgentsListBody(model.list, runner: model.calls.runner(AgentsOp.listAgents),
                           empty: "No agents yet. Make one with New agent.") { agent in
                AgentsRow(selected: model.selectedID == agent.id && !model.creating) {
                    Task { await model.select(agent.id) }
                } content: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(agent.name).lineLimit(1)
                            if agent.archived { AgentsBadge(text: "Archived") }
                        }
                        Text(agent.lastCallAt.map { "Last call \(AgentsFormat.relative($0))" } ?? "No calls yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !agent.tags.isEmpty {
                            Text(agent.tags.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - New agent

private struct AgentsNewAgentForm: View {
    @Bindable var model: AgentsModel

    var body: some View {
        let runner = model.calls.runner(AgentsOp.createAgent)
        AgentsCard("New agent", subtitle: "The essentials; everything else can be changed once it exists.") {
            Form {
                TextField("Name", text: $model.newDraft.name, prompt: Text("Support agent"))
                TextField("Tags", text: $model.newDraft.tagsText, prompt: Text("support, english"))
                TextField("Language", text: $model.newDraft.language, prompt: Text("en"))
                TextField("First message", text: $model.newDraft.firstMessage, axis: .vertical)
                    .lineLimit(2...4)
                LabeledContent("System prompt") {
                    TextEditor(text: $model.newDraft.prompt)
                        .font(.callout)
                        .frame(minHeight: 110)
                        .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
                }
                Picker("LLM", selection: $model.newDraft.llm) {
                    ForEach(model.llmChoices, id: \.self) { Text($0).tag($0) }
                }
                ElevenLabsVoicePicker(selection: $model.newDraft.voiceID, title: "Voice", directory: model.store.voices)
                Picker("Voice model", selection: $model.newDraft.ttsModel) {
                    ForEach(AgentsSchema.choices(AgentsOp.createAgent, "conversation_config.tts.model_id"), id: \.self) {
                        Text($0).tag($0)
                    }
                }
            }
            .formStyle(.columns)
            AgentsHeldCreateNotice(holds: model.calls.holds, operationID: AgentsOp.createAgent)
            HStack {
                AgentsRunButton(runner: runner, title: "Create agent",
                                    disabled: model.newDraft.name.trimmingCharacters(in: .whitespaces).isEmpty
                                        || model.calls.holds.notice(AgentsOp.createAgent) != nil) {
                    Task { await model.create() }
                }
                Button("Cancel") { model.cancelCreating() }
            }
            AgentsRunnerOutput(runner: runner, showsResult: false)
        }
        .task { await model.loadLLMs() }
    }
}

// MARK: - Editor

private struct AgentsAgentEditor: View {
    @Bindable var model: AgentsModel

    var body: some View {
        let id = model.selectedID ?? ""
        let loadRunner = model.calls.runner(AgentsOp.getAgent, slot: id)
        VStack(alignment: .leading, spacing: 14) {
            header(id: id)
            if model.loaded == nil {
                AgentsCard("Loading") {
                    if loadRunner.isRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Fetching the agent's configuration…").foregroundStyle(.secondary)
                        }
                    }
                    AgentsRunnerError(runner: loadRunner)
                    if loadRunner.failure != nil {
                        Button("Try again") { Task { await model.load(id) } }
                    }
                }
            } else {
                Picker("Part", selection: $model.tab) {
                    ForEach(AgentsModel.Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch model.tab {
                case .behaviour: AgentsBehaviourTab(model: model)
                case .voice: AgentsVoiceTab(model: model)
                case .model: AgentsModelTab(model: model)
                case .tools: AgentsToolsKnowledgeTab(model: model)
                case .sharing: AgentsSharingTab(model: model.sharing, agentName: model.selectedName, auth: $model.draft.requiresAuth)
                case .branches: AgentsBranchesTab(model: model.branches, agentName: model.selectedName)
                }
                if model.tab != .branches { saveBar }
                AgentsLiveConversationSlot(agentID: id, agentName: model.selectedName)
            }
        }
    }

    private func header(id: String) -> some View {
        AgentsCard(model.selectedName, subtitle: nil) {
            HStack(spacing: 8) {
                Button("Conversations") { model.openConversations() }
                Menu("More") {
                    Button("Copy agent ID") { AgentsPasteboard.copy(id) }
                    Button("Fetch again") { Task { await model.load(id) } }
                }
                .fixedSize()
            }
        } content: {
            HStack(spacing: 6) {
                Text(id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                AgentsCopyButton(text: id)
                if let version = model.versionID {
                    Text("· version \(version)").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            if !(model.loaded?.tags.isEmpty ?? true) {
                HStack(spacing: 4) {
                    ForEach(model.loaded?.tags ?? [], id: \.self) { AgentsBadge(text: $0, color: .blue) }
                }
            }
            DisclosureGroup("Duplicate or delete") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("Name of the copy", text: $model.duplicateName,
                                  prompt: Text("\(model.selectedName) (copy)"))
                            .textFieldStyle(.roundedBorder)
                        AgentsRunButton(runner: model.calls.runner(AgentsOp.duplicateAgent, slot: id), title: "Duplicate") {
                            Task { await model.duplicate() }
                        }
                    }
                    AgentsRunnerOutput(runner: model.calls.runner(AgentsOp.duplicateAgent, slot: id))
                    Divider()
                    AgentsRunButton(runner: model.calls.runner(AgentsOp.deleteAgent, slot: id), title: "Delete agent…") {
                        Task { await model.delete() }
                    }
                    AgentsRunnerOutput(runner: model.calls.runner(AgentsOp.deleteAgent, slot: id))
                }
                .padding(.top, 6)
            }
            .font(.callout)
        }
    }

    private var saveBar: some View {
        let id = model.selectedID ?? ""
        let runner = model.calls.runner(AgentsOp.updateAgent, slot: id)
        let draftRunner = model.calls.runner(AgentsOp.createDraft, slot: id)
        return AgentsCard(model.isDirty ? "Unsaved changes" : "Saved", subtitle: model.isDirty
                          ? "Save sends only what changed; ElevenLabs keeps a version of each save." : nil) {
            HStack(spacing: 8) {
                TextField("Describe this change (optional)", text: $model.changeDescription)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.isDirty)
                AgentsRunButton(runner: runner, title: "Save changes", disabled: !model.isDirty, showsRisk: model.isDirty) {
                    Task { await model.save() }
                }
                Button("Revert") { model.revert() }
                    .disabled(!model.isDirty)
            }
            if let note = model.lostSaveNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.branchID != nil, model.isDirty {
                AgentsRunButton(runner: draftRunner, title: "Keep as a draft instead") {
                    Task { await model.saveAsDraft() }
                }
                .controlSize(.small)
            }
            if let problem = model.draftProblem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AgentsRunnerOutput(runner: runner)
            AgentsRunnerOutput(runner: draftRunner)
        }
    }
}

private struct AgentsBehaviourTab: View {
    @Bindable var model: AgentsModel

    var body: some View {
        AgentsCard("What it says", subtitle: "The system prompt steers every reply; the first message opens the call.") {
            Form {
                TextField("Name", text: $model.draft.name)
                TextField("Tags", text: $model.draft.tagsText, prompt: Text("Comma-separated"))
                TextField("Language", text: $model.draft.language, prompt: Text("en"))
                    .help("The agent's default language, as an ISO code (en, es, de…).")
                TextField("First message", text: $model.draft.firstMessage, axis: .vertical)
                    .lineLimit(2...5)
                LabeledContent("System prompt") {
                    VStack(alignment: .leading, spacing: 3) {
                        TextEditor(text: $model.draft.prompt)
                            .font(.callout)
                            .frame(minHeight: 180)
                            .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
                        Text("\(model.draft.prompt.count.formatted()) characters")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.columns)
        }
    }
}

private struct AgentsVoiceTab: View {
    @Bindable var model: AgentsModel

    var body: some View {
        let op = AgentsOp.createAgent
        AgentsCard("How it sounds", subtitle: "The voice and model the agent speaks with, and how steady, close to the original and fast it is.") {
            Form {
                ElevenLabsVoicePicker(selection: $model.draft.voiceID, title: "Voice", directory: model.store.voices)
                Picker("Voice model", selection: $model.draft.ttsModel) {
                    let choices = AgentsSchema.choices(op, "conversation_config.tts.model_id")
                    if !model.draft.ttsModel.isEmpty, !choices.contains(model.draft.ttsModel) {
                        Text(model.draft.ttsModel).tag(model.draft.ttsModel)
                    }
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }
                AgentsSlider(title: "Stability", value: $model.draft.stability,
                             range: AgentsSchema.range(op, "conversation_config.tts.stability", fallback: 0...1))
                AgentsSlider(title: "Similarity", value: $model.draft.similarity,
                             range: AgentsSchema.range(op, "conversation_config.tts.similarity_boost", fallback: 0...1))
                AgentsSlider(title: "Speed", value: $model.draft.speed,
                             range: AgentsSchema.range(op, "conversation_config.tts.speed", fallback: 0.7...1.2))
            }
            .formStyle(.columns)
        }
    }
}

private struct AgentsModelTab: View {
    @Bindable var model: AgentsModel

    var body: some View {
        AgentsCard("Model and limits", subtitle: "Which LLM answers, how freely, and how long and how often the agent may talk — the limits bound what calls can cost.") {
            Form {
                Picker("LLM", selection: $model.draft.llm) {
                    ForEach(model.llmChoices, id: \.self) { Text($0).tag($0) }
                }
                AgentsSlider(title: "Temperature", value: $model.draft.temperature, range: 0...1, step: 0.05)
                LabeledContent("Max tokens per reply") {
                    HStack {
                        TextField("", value: $model.draft.maxTokens, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text("-1 is no limit").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Longest call") {
                    HStack {
                        TextField("", value: $model.draft.maxDurationSeconds, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text("seconds (\(AgentsFormat.duration(model.draft.maxDurationSeconds)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Calls per day") {
                    TextField("", value: $model.draft.dailyLimit, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 110)
                }
                LabeledContent("Calls at once") {
                    HStack {
                        TextField("", value: $model.draft.concurrencyLimit, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text("-1 follows the workspace limit").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.columns)
            if let llm = model.availableLLMs?.first(where: { $0.llm == model.draft.llm }), let context = llm.maxContext {
                Text("\(llm.llm): up to \(context.formatted()) tokens of context\(llm.supportsImages ? ", reads images" : "").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await model.loadLLMs() }
    }
}

private struct AgentsToolsKnowledgeTab: View {
    @Bindable var model: AgentsModel

    var body: some View {
        let directory = model.store.directory
        VStack(alignment: .leading, spacing: 14) {
            AgentsCard("Tools", subtitle: "Workspace tools the agent may call. Manage them in Tools.") {
                AgentsListBody(directory.tools, runner: model.calls.runner(AgentsOp.listTools, slot: "directory"),
                               empty: "No workspace tools yet.") { tool in
                    Toggle(isOn: membership(\.toolIDs, tool.id)) {
                        HStack(spacing: 6) {
                            Text(tool.name)
                            AgentsBadge(text: AgentsFormat.words(tool.type))
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            AgentsCard("Knowledge base", subtitle: "Documents the agent answers from. “Always” puts a document in every prompt; “When relevant” retrieves it.") {
                ForEach($model.draft.knowledge) { $locator in
                    HStack {
                        Image(systemName: model.knowledgeSummaries[locator.id]?.systemImage ?? "doc.text")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(locator.name).lineLimit(1)
                            if let summary = model.knowledgeSummaries[locator.id] {
                                Text("\(summary.typeName) · \(AgentsFormat.bytes(summary.sizeBytes))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Picker("Use", selection: $locator.usageMode) {
                            Text("When relevant").tag("auto")
                            Text("Always").tag("prompt")
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button {
                            model.draft.knowledge.removeAll { $0.id == locator.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(locator.name)")
                    }
                }
                let attached = Set(model.draft.knowledge.map(\.id))
                let available = directory.documents.items.filter { !$0.isFolder && !attached.contains($0.id) }
                Menu("Add a document") {
                    ForEach(available) { document in
                        Button(document.name) {
                            model.draft.knowledge.append(AgentsKnowledgeLocator(
                                id: document.id, name: document.name, type: document.type, usageMode: "auto"
                            ))
                        }
                    }
                }
                .fixedSize()
                .disabled(available.isEmpty)
                .task {
                    await directory.documents.loadIfNeeded()
                    await model.loadKnowledgeSummaries()
                }
            }
            AgentsCard("MCP servers", subtitle: "Outside tool servers the agent may use. Manage them in MCP servers.") {
                AgentsListBody(directory.mcpServers, runner: model.calls.runner(AgentsOp.listMCPServers, slot: "directory"),
                               empty: "No MCP servers connected.") { server in
                    Toggle(isOn: membership(\.mcpServerIDs, server.id)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name)
                            Text(server.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .task {
            await directory.tools.loadIfNeeded()
            await directory.mcpServers.loadIfNeeded()
        }
    }

    private func membership(_ keyPath: WritableKeyPath<AgentsAgentDraft, [String]>, _ id: String) -> Binding<Bool> {
        Binding(
            get: { model.draft[keyPath: keyPath].contains(id) },
            set: { on in
                if on {
                    if !model.draft[keyPath: keyPath].contains(id) { model.draft[keyPath: keyPath].append(id) }
                } else {
                    model.draft[keyPath: keyPath].removeAll { $0 == id }
                }
            }
        )
    }
}

// MARK: - Sharing

@MainActor
@Observable
final class AgentsSharingModel {
    @ObservationIgnored let calls: AgentsCalls
    private(set) var agentID = ""
    private(set) var widget: JSONValue = .null

    init(calls: AgentsCalls) {
        self.calls = calls
    }

    /// This agent's runner for `operationID`: another agent's result, question or token never
    /// shows here.
    func runner(_ operationID: String) -> ElevenLabsRunner {
        calls.runner(operationID, slot: agentID)
    }

    func reset(agentID: String) {
        forgetShownCredentials()
        self.agentID = agentID
        widget = .null
    }

    /// Takes the link token off screen: on a change of agent, and when Sharing is left.
    func forgetShownCredentials() {
        guard !agentID.isEmpty else { return }
        runner(AgentsOp.agentLink).dismissCredential()
    }

    func loadWidget() async {
        guard !agentID.isEmpty else { return }
        guard let json = await calls.json(AgentsOp.agentWidget, ["agent_id": .string(agentID)], slot: agentID, quiet: true)
        else { return }
        widget = json["widget_config"]
    }

    /// The shareable link's token, shown once through the runner.
    func fetchLink() async {
        guard !agentID.isEmpty else { return }
        await calls.json(AgentsOp.agentLink, ["agent_id": .string(agentID)], slot: agentID, title: "Shareable link")
    }

    func uploadAvatar(_ url: URL) async {
        guard !agentID.isEmpty else { return }
        let result = await calls.json(AgentsOp.agentAvatar, ["agent_id": .string(agentID)],
                                      files: ["avatar_file": [ElevenLabsFile(url: url)]], slot: agentID, title: "Agent avatar")
        if result != nil { await loadWidget() }
    }

    func uploadHoldAudio(_ url: URL) async {
        guard !agentID.isEmpty else { return }
        await calls.json(AgentsOp.setHoldAudio, ["agent_id": .string(agentID)],
                         files: ["hold_audio_file": [ElevenLabsFile(url: url)]], slot: agentID, title: "Hold audio")
    }

    func removeHoldAudio(agentName: String) async {
        guard !agentID.isEmpty else { return }
        await calls.json(
            AgentsOp.deleteHoldAudio, ["agent_id": .string(agentID)], slot: agentID,
            subject: "the custom hold audio of “\(agentName)”",
            consequence: "Callers waiting for “\(agentName)” will hear the default hold tone again."
        )
    }

    static let arguments: [AgentsArgument] = [
        AgentsArgument(AgentsOp.agentWidget, "agent_id"), AgentsArgument(AgentsOp.agentLink, "agent_id"),
        AgentsArgument(AgentsOp.agentAvatar, "agent_id"), AgentsArgument(AgentsOp.agentAvatar, "avatar_file"),
        AgentsArgument(AgentsOp.setHoldAudio, "agent_id"), AgentsArgument(AgentsOp.setHoldAudio, "hold_audio_file"),
        AgentsArgument(AgentsOp.deleteHoldAudio, "agent_id"),
    ]
}

private struct AgentsSharingTab: View {
    let model: AgentsSharingModel
    let agentName: String
    @Binding var auth: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AgentsCard("Access", subtitle: "With authentication on, conversations need a signed URL or token from your server; without it, anyone with the agent's id can talk to it.") {
                Toggle("Require authentication", isOn: $auth)
                Text("Saved with the other changes below.").font(.caption).foregroundStyle(.secondary)
            }
            AgentsCard("Shareable link", subtitle: "A token that lets anyone holding it start a conversation with this agent. Shown once.") {
                AgentsRunButton(runner: model.runner(AgentsOp.agentLink), title: "Get the link token") {
                    Task { await model.fetchLink() }
                }
                AgentsRunnerOutput(runner: model.runner(AgentsOp.agentLink), showsResult: false)
            }
            AgentsCard("Widget", subtitle: "How the embeddable widget looks for this agent.") {
                let widget = model.widget
                if widget == .null {
                    AgentsRunnerError(runner: model.runner(AgentsOp.agentWidget))
                    Text("Not fetched yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    AgentsFact(label: "Layout", value: AgentsFormat.words(widget["variant"].stringValue))
                    AgentsFact(label: "Placement", value: AgentsFormat.words(widget["placement"].stringValue))
                    AgentsFact(label: "Avatar", value: AgentsFormat.words(widget["avatar"]["type"].stringValue))
                    AgentsFact(label: "Text input", value: widget["text_input_enabled"].boolValue == true ? "On" : "Off")
                    ElevenLabsJSONTree(widget, label: "widget_config", expandedDepth: 0)
                }
                HStack {
                    Button("Upload avatar…") {
                        if let url = AgentsFilePicker.choose(types: ["png", "jpg", "jpeg", "gif", "webp"]).first {
                            Task { await model.uploadAvatar(url) }
                        }
                    }
                    Button("Fetch again") { Task { await model.loadWidget() } }
                }
                AgentsRunnerOutput(runner: model.runner(AgentsOp.agentAvatar), showsResult: false)
            }
            AgentsCard("Hold audio", subtitle: "Played on loop to callers waiting in this agent's queue.") {
                HStack {
                    Button("Upload hold audio…") {
                        if let url = AgentsFilePicker.choose(types: ["mp3", "wav", "m4a", "ogg"]).first {
                            Task { await model.uploadHoldAudio(url) }
                        }
                    }
                    AgentsRunButton(runner: model.runner(AgentsOp.deleteHoldAudio), title: "Remove…") {
                        Task { await model.removeHoldAudio(agentName: agentName) }
                    }
                }
                AgentsRunnerOutput(runner: model.runner(AgentsOp.setHoldAudio), showsResult: false)
                AgentsRunnerOutput(runner: model.runner(AgentsOp.deleteHoldAudio), showsResult: false)
            }
        }
        .task(id: model.agentID) { await model.loadWidget() }
        .onDisappear { model.forgetShownCredentials() }
    }
}

// MARK: - Branches, versions, merge proposals

@MainActor
@Observable
final class AgentsBranchesModel {
    @ObservationIgnored let calls: AgentsCalls
    private(set) var agentID = ""
    var mainBranchID: String?
    var currentVersionID: String?
    var includeArchived = false
    private(set) var branches: [AgentsBranch] = []
    private(set) var loaded = false
    var selectedBranchID: String?
    private(set) var version: JSONValue = .null
    private(set) var proposals: [AgentsMergeProposal] = []
    var selectedProposalID: String?
    private(set) var proposal: JSONValue = .null
    private(set) var procedures: [AgentsProcedure] = []
    private(set) var selectedProcedureID: String?
    /// "branch/procedure" of the procedure whose fields the editor holds; nil for a new one or while loading.
    private(set) var loadedProcedureKey: String?
    /// The operation that fetches the open procedure (its draft, or the committed version).
    private(set) var procedureFetchOperation: String?
    var procedureName = ""
    var procedureType = "free_form"
    var procedureTrigger = ""
    var procedureContent = ""
    /// Traffic per branch for a deployment, in percent.
    var traffic: [String: Double] = [:]

    // Forms
    var newBranchName = ""
    var newBranchDescription = ""
    var archiveSourceOnMerge = true
    var proposalTitle = ""
    var proposalDescription = ""
    var proposalComment = ""
    var reviewComment = ""

    @ObservationIgnored let questions: AgentsQuestionBox

    init(calls: AgentsCalls, questions: AgentsQuestionBox) {
        self.calls = calls
        self.questions = questions
    }

    /// Which item an operation's runner belongs to — the branch, the procedure, the proposal or
    /// the agent on screen — so one item's result or question never shows on another.
    func slot(for operationID: String) -> String {
        switch operationID {
        case AgentsOp.getBranch, AgentsOp.updateBranch, AgentsOp.mergePreview, AgentsOp.mergeBranch,
             AgentsOp.rebasePreview, AgentsOp.rebaseBranch, AgentsOp.deleteDraft, AgentsOp.listProcedures,
             AgentsOp.compileProcedures, AgentsOp.createProcedure:
            return "\(agentID)/\(selectedBranchID ?? "")"
        case AgentsOp.getProcedure, AgentsOp.getProcedureDraft, AgentsOp.updateProcedureDraft,
             AgentsOp.deleteProcedureDraft, AgentsOp.removeProcedure:
            return "\(agentID)/\(selectedBranchID ?? "")/\(selectedProcedureID ?? "")"
        case AgentsOp.getMergeProposal, AgentsOp.commentMergeProposal, AgentsOp.reviewMergeProposal,
             AgentsOp.acceptMergeProposal, AgentsOp.updateMergeProposal:
            return "\(agentID)/\(selectedProposalID ?? "")"
        default:
            return agentID
        }
    }

    func runner(_ operationID: String) -> ElevenLabsRunner {
        calls.runner(operationID, slot: slot(for: operationID))
    }

    @discardableResult
    private func json(
        _ operationID: String, _ arguments: [String: JSONValue] = [:], slot explicit: String? = nil, quiet: Bool = false,
        title: String? = nil, subject: String? = nil, consequence: String? = nil
    ) async -> JSONValue? {
        await calls.json(operationID, arguments, slot: explicit ?? slot(for: operationID), quiet: quiet, title: title,
                         subject: subject, consequence: consequence)
    }

    func reset(agentID: String) {
        self.agentID = agentID
        branches = []
        loaded = false
        selectedBranchID = nil
        version = .null
        proposals = []
        selectedProposalID = nil
        proposal = .null
        procedures = []
        selectedProcedureID = nil
        loadedProcedureKey = nil
        procedureName = ""
        procedureTrigger = ""
        procedureContent = ""
        traffic = [:]
    }

    var selectedBranch: AgentsBranch? { branches.first { $0.id == selectedBranchID } }
    var mainBranch: AgentsBranch? { branches.first { $0.id == mainBranchID } ?? branches.first { $0.isMain } }

    func load() async {
        guard !agentID.isEmpty else { return }
        let arguments: [String: JSONValue] = [
            "agent_id": .string(agentID), "include_archived": .bool(includeArchived), "include_commit_status": true,
        ]
        guard let json = await json(AgentsOp.listBranches, arguments, quiet: true) else { return }
        branches = (json["results"].arrayValue ?? []).compactMap { AgentsBranch(json: $0, mainBranchID: mainBranchID) }
        loaded = true
        traffic = Dictionary(uniqueKeysWithValues: branches.map { ($0.id, $0.livePercentage ?? 0) })
        if selectedBranchID == nil { selectedBranchID = branches.first(where: { !$0.isMain })?.id ?? branches.first?.id }
        await loadVersion()
        await loadProposals()
    }

    func loadVersion() async {
        guard let currentVersionID, !agentID.isEmpty else { return }
        version = await json(
            AgentsOp.versionMetadata, ["agent_id": .string(agentID), "version_id": .string(currentVersionID)], quiet: true
        ) ?? .null
    }

    func loadBranch(_ id: String) async {
        guard let json = await json(
            AgentsOp.getBranch, ["agent_id": .string(agentID), "branch_id": .string(id)], quiet: true
        ), let branch = AgentsBranch(json: json, mainBranchID: mainBranchID) else { return }
        if let index = branches.firstIndex(where: { $0.id == id }) { branches[index] = branch }
    }

    func createBranch() async {
        guard let currentVersionID else { return }
        let arguments: [String: JSONValue] = [
            "agent_id": .string(agentID), "name": .string(newBranchName.trimmingCharacters(in: .whitespaces)),
            "description": .string(newBranchDescription), "parent_version_id": .string(currentVersionID),
        ]
        guard await json(AgentsOp.createBranch, arguments, title: "New branch “\(newBranchName)”") != nil else { return }
        newBranchName = ""
        newBranchDescription = ""
        await load()
    }

    func setArchived(_ archived: Bool) async {
        guard let branch = selectedBranch else { return }
        guard await json(
            AgentsOp.updateBranch,
            ["agent_id": .string(agentID), "branch_id": .string(branch.id), "is_archived": .bool(archived)],
            title: archived ? "Archived “\(branch.name)”" : "Restored “\(branch.name)”"
        ) != nil else { return }
        await load()
    }

    func setProtection(_ status: String) async {
        guard let branch = selectedBranch else { return }
        guard await json(
            AgentsOp.updateBranch,
            ["agent_id": .string(agentID), "branch_id": .string(branch.id), "protection_status": .string(status)]
        ) != nil else { return }
        await loadBranch(branch.id)
    }

    func previewMerge() async {
        guard let branch = selectedBranch, let target = mainBranch else { return }
        let runner = runner(AgentsOp.mergePreview)
        await json(AgentsOp.mergePreview, [
            "agent_id": .string(agentID), "source_branch_id": .string(branch.id),
            "target_branch_id": .string(target.id),
        ], quiet: true)
        runner.dismissCredential()
    }

    /// Asks first: a merge into main changes what live callers hear from their next call.
    /// The branches the question names are the ones merged: both are taken when it is asked.
    func requestMerge(agentName: String) {
        guard let branch = selectedBranch, let target = mainBranch, branch.id != target.id else { return }
        let agent = agentID
        let archive = archiveSourceOnMerge
        questions.ask(AgentsQuestion(
            title: "Merge “\(branch.name)” into “\(target.name)” of “\(agentName)”?",
            message: "Callers of “\(agentName)” who reach “\(target.name)” hear the merged configuration from their next "
                + "conversation." + (archive ? " “\(branch.name)” is archived afterwards." : ""),
            confirmLabel: "Merge"
        )) { [weak self] in
            await self?.merge(branch, into: target, of: agent, archivingSource: archive)
        }
    }

    func merge(_ branch: AgentsBranch, into target: AgentsBranch, of agent: String, archivingSource archive: Bool) async {
        guard await json(AgentsOp.mergeBranch, [
            "agent_id": .string(agent), "source_branch_id": .string(branch.id),
            "target_branch_id": .string(target.id), "archive_source_branch": .bool(archive),
        ], slot: "\(agent)/\(branch.id)", title: "Merged “\(branch.name)” into “\(target.name)”") != nil else { return }
        if agentID == agent { await load() }
    }

    func previewRebase() async {
        guard let branch = selectedBranch else { return }
        let runner = runner(AgentsOp.rebasePreview)
        await json(AgentsOp.rebasePreview, ["agent_id": .string(agentID), "branch_id": .string(branch.id)], quiet: true)
        runner.dismissCredential()
    }

    func rebase() async {
        guard let branch = selectedBranch else { return }
        guard await json(
            AgentsOp.rebaseBranch, ["agent_id": .string(agentID), "branch_id": .string(branch.id)],
            title: "Rebased “\(branch.name)”"
        ) != nil else { return }
        await load()
    }

    func deleteDraft(agentName: String) async {
        guard let branch = selectedBranch else { return }
        guard await json(
            AgentsOp.deleteDraft, ["agent_id": .string(agentID), "branch_id": .string(branch.id)],
            subject: "the unsaved draft on “\(branch.name)”",
            consequence: "ElevenLabs will throw away the draft changes on the branch “\(branch.name)” of “\(agentName)”. Committed versions are kept."
        ) != nil else { return }
        await loadBranch(branch.id)
    }

    /// The traffic split must add up to 100 %.
    var trafficTotal: Double {
        branches.filter { !$0.isArchived }.reduce(0) { $0 + (traffic[$1.id] ?? 0) }
    }

    /// Asks first, naming each branch's share: a deployment moves live callers at once.
    /// The split the question names is the split deployed: taken when it is asked.
    func requestDeploy(agentName: String) {
        let shares = branches.filter { !$0.isArchived }.map { (branch: $0, share: traffic[$0.id] ?? 0) }
        let split = shares.map { "\($0.branch.name) \(Int($0.share)) %" }
        let requests: [JSONValue] = shares.map { entry in
            [
                "branch_id": .string(entry.branch.id),
                "deployment_strategy": ["type": "percentage", "traffic_percentage": .number(entry.share)],
            ]
        }
        let agent = agentID
        questions.ask(AgentsQuestion(
            title: "Send “\(agentName)”'s callers to " + ListFormatter.localizedString(byJoining: split) + "?",
            message: "New conversations with “\(agentName)” are shared out this way as soon as you confirm.",
            confirmLabel: "Deploy"
        )) { [weak self] in
            await self?.deploy(requests, to: agent)
        }
    }

    func deploy(_ requests: [JSONValue], to agent: String) async {
        guard await json(AgentsOp.createDeployment, [
            "agent_id": .string(agent), "deployment_request": ["requests": .array(requests)],
        ], slot: agent, title: "Deployed the traffic split") != nil else { return }
        if agentID == agent { await load() }
    }

    func loadProcedures() async {
        guard let branch = selectedBranch else { return }
        guard let json = await json(
            AgentsOp.listProcedures, ["agent_id": .string(agentID), "branch_id": .string(branch.id)], quiet: true
        ) else { return }
        procedures = (json["procedures"].arrayValue ?? []).compactMap(AgentsProcedure.init(json:))
    }

    /// Opens a procedure in the editor: its draft when it has one, else the committed version.
    func openProcedure(_ procedure: AgentsProcedure) async {
        guard let branch = selectedBranch else { return }
        selectedProcedureID = procedure.id
        // The previous procedure's text never stands in for this one's.
        loadedProcedureKey = nil
        procedureName = procedure.name
        procedureType = procedure.type
        procedureTrigger = procedure.trigger
        procedureContent = ""
        let arguments: [String: JSONValue] = [
            "agent_id": .string(agentID), "branch_id": .string(branch.id), "procedure_id": .string(procedure.id),
        ]
        let operation = procedure.hasDraft ? AgentsOp.getProcedureDraft : AgentsOp.getProcedure
        procedureFetchOperation = operation
        guard let json = await json(operation, arguments, quiet: true), selectedProcedureID == procedure.id,
              selectedBranchID == branch.id else { return }
        procedureName = json["name"].stringValue ?? procedure.name
        procedureType = json["type"].stringValue ?? procedure.type
        procedureTrigger = json["trigger"].stringValue ?? procedure.trigger
        procedureContent = json["content"].stringValue ?? ""
        loadedProcedureKey = "\(branch.id)/\(procedure.id)"
    }

    /// Whether the editor holds the open procedure of the selected branch (or a new one):
    /// saving, discarding and removing wait for its text to arrive.
    var procedureIsLoaded: Bool {
        guard let selectedProcedureID else { return true }
        guard let selectedBranchID, let loadedProcedureKey else { return false }
        return loadedProcedureKey == "\(selectedBranchID)/\(selectedProcedureID)"
    }

    /// The open procedure's text: in (or a new procedure), on its way, or not coming (the error,
    /// and how to retry).
    var procedureLoad: AgentsDetailLoad {
        guard selectedProcedureID != nil else { return .loaded }
        return .of(loaded: procedureIsLoaded, runner: procedureFetchOperation.map { runner($0) })
    }

    func newProcedure() {
        selectedProcedureID = nil
        loadedProcedureKey = nil
        procedureName = ""
        procedureType = AgentsSchema.choices(AgentsOp.createProcedure, "type").first ?? "free_form"
        procedureTrigger = ""
        procedureContent = ""
    }

    /// Creates the procedure, or saves the edits to the open one as its draft.
    func saveProcedure() async {
        guard procedureLoad.isLoaded, let branch = selectedBranch else { return }
        var arguments: [String: JSONValue] = [
            "agent_id": .string(agentID), "branch_id": .string(branch.id),
            "name": .string(procedureName.trimmingCharacters(in: .whitespaces)), "type": .string(procedureType),
            "content": .string(procedureContent),
        ]
        if !procedureTrigger.isEmpty { arguments["trigger"] = .string(procedureTrigger) }
        if let id = selectedProcedureID {
            arguments["procedure_id"] = .string(id)
            guard await json(AgentsOp.updateProcedureDraft, arguments, title: "Procedure “\(procedureName)”") != nil
            else { return }
        } else {
            guard let json = await json(AgentsOp.createProcedure, arguments, title: "Procedure “\(procedureName)”")
            else { return }
            if selectedProcedureID == nil, selectedBranchID == branch.id, let id = json["procedure_id"].stringValue {
                selectedProcedureID = id
                loadedProcedureKey = "\(branch.id)/\(id)"
            }
        }
        await loadProcedures()
    }

    func discardProcedureDraft() async {
        guard procedureLoad.isLoaded, let branch = selectedBranch, let id = selectedProcedureID else { return }
        guard await json(
            AgentsOp.deleteProcedureDraft,
            ["agent_id": .string(agentID), "branch_id": .string(branch.id), "procedure_id": .string(id)],
            subject: "your draft of “\(procedureName)”",
            consequence: "The procedure goes back to its committed version on “\(branch.name)”."
        ) != nil else { return }
        await loadProcedures()
        if selectedProcedureID == id, let procedure = procedures.first(where: { $0.id == id }) { await openProcedure(procedure) }
    }

    func removeProcedure() async {
        guard procedureLoad.isLoaded, let branch = selectedBranch, let id = selectedProcedureID else { return }
        guard await json(
            AgentsOp.removeProcedure,
            ["agent_id": .string(agentID), "branch_id": .string(branch.id), "procedure_id": .string(id)],
            subject: "the procedure “\(procedureName)” from “\(branch.name)”",
            consequence: "It leaves the branch's working set (a folder takes everything inside it along). "
                + "ElevenLabs refuses if another procedure hands off to it."
        ) != nil else { return }
        if selectedProcedureID == id {
            selectedProcedureID = nil
            loadedProcedureKey = nil
        }
        await loadProcedures()
    }

    /// Turns the branch's procedure drafts into its workflow. The result is shown as it comes.
    func compileProcedures() async {
        guard let branch = selectedBranch else { return }
        await json(AgentsOp.compileProcedures, ["agent_id": .string(agentID), "branch_id": .string(branch.id)],
                         title: "Compiled the procedures of “\(branch.name)”")
    }

    // Merge proposals

    func loadProposals() async {
        guard let json = await json(AgentsOp.listMergeProposals, ["agent_id": .string(agentID)], quiet: true)
        else { return }
        proposals = (json["results"].arrayValue ?? []).compactMap(AgentsMergeProposal.init(json:))
    }

    func openProposal(_ id: String) async {
        selectedProposalID = id
        if proposal["id"].stringValue != id { proposal = .null }
        let fetched = await json(
            AgentsOp.getMergeProposal, ["agent_id": .string(agentID), "merge_proposal_id": .string(id)],
            slot: "\(agentID)/\(id)", quiet: true
        )
        // An older, slower fetch never replaces the proposal selected since.
        guard selectedProposalID == id else { return }
        proposal = fetched ?? .null
    }

    /// Whether the details on screen are the selected proposal's: acting waits for them.
    var proposalIsLoaded: Bool {
        selectedProposalID != nil && proposal["id"].stringValue == selectedProposalID
    }

    /// The selected proposal's details: in, on their way, or not coming (the error, and how to retry).
    var proposalLoad: AgentsDetailLoad {
        .of(loaded: proposalIsLoaded, runner: selectedProposalID.map { _ in runner(AgentsOp.getMergeProposal) })
    }

    func propose() async {
        guard let branch = selectedBranch, let target = mainBranch else { return }
        guard let json = await json(AgentsOp.createMergeProposal, [
            "agent_id": .string(agentID), "source_branch_id": .string(branch.id),
            "target_branch_id": .string(target.id), "title": .string(proposalTitle),
            "description": .string(proposalDescription),
        ], title: "Merge proposal “\(proposalTitle)”") else { return }
        proposalTitle = ""
        proposalDescription = ""
        await loadProposals()
        if let id = json["id"].stringValue { await openProposal(id) }
    }

    func comment() async {
        guard proposalIsLoaded, let id = selectedProposalID else { return }
        guard await json(AgentsOp.commentMergeProposal, [
            "agent_id": .string(agentID), "merge_proposal_id": .string(id), "body": .string(proposalComment),
        ]) != nil else { return }
        proposalComment = ""
        if selectedProposalID == id { await openProposal(id) }
    }

    func review(approve: Bool) async {
        guard proposalIsLoaded, let id = selectedProposalID else { return }
        guard await json(AgentsOp.reviewMergeProposal, [
            "agent_id": .string(agentID), "merge_proposal_id": .string(id),
            "state": .string(approve ? "approved" : "changes_requested"), "comment": .string(reviewComment),
        ]) != nil else { return }
        reviewComment = ""
        if selectedProposalID == id { await openProposal(id) }
    }

    /// Asks first: merging a proposal changes its target branch — usually main, what live
    /// callers hear.
    ///
    /// The id merged and the names in the question come from the same, loaded proposal: while
    /// another one's details are still arriving nothing is asked, and "yes" merges the proposal
    /// the question named, whatever is selected by then.
    func requestAcceptProposal(agentName: String) {
        guard proposalIsLoaded, let id = proposal["id"].stringValue else { return }
        let agent = agentID
        let title = proposal["title"].stringValue ?? "this proposal"
        let sourceID = proposal["source_branch_id"].stringValue
        let targetID = proposal["target_branch_id"].stringValue
        let source = branches.first { $0.id == sourceID }?.name ?? sourceID ?? "its branch"
        let target = branches.first { $0.id == targetID }
        let targetName = target?.name ?? targetID ?? "its target"
        let live = target.flatMap { $0.livePercentage }.map { $0 > 0 ? " It answers \(Int($0)) % of calls now." : "" } ?? ""
        questions.ask(AgentsQuestion(
            title: "Merge “\(title)” (“\(source)”) into “\(targetName)” of “\(agentName)”?",
            message: "Callers of “\(agentName)” who reach “\(targetName)” hear the merged configuration from their next "
                + "conversation.\(live)" + (archiveSourceOnMerge ? " “\(source)” is archived afterwards." : ""),
            confirmLabel: "Merge"
        )) { [weak self, archiveSourceOnMerge] in
            await self?.acceptProposal(id: id, of: agent, archivingSource: archiveSourceOnMerge)
        }
    }

    func acceptProposal(id: String, of agent: String, archivingSource archive: Bool) async {
        guard await json(AgentsOp.acceptMergeProposal, [
            "agent_id": .string(agent), "merge_proposal_id": .string(id),
            "archive_source_branch": .bool(archive),
        ], slot: "\(agent)/\(id)", title: "Merged a proposal") != nil else { return }
        guard agentID == agent else { return }
        await load()
        if selectedProposalID == id { await openProposal(id) }
    }

    func closeProposal() async {
        guard proposalIsLoaded, let id = selectedProposalID else { return }
        guard await json(AgentsOp.updateMergeProposal, [
            "agent_id": .string(agentID), "merge_proposal_id": .string(id), "close": true,
        ]) != nil else { return }
        await loadProposals()
        if selectedProposalID == id { await openProposal(id) }
    }

    static let arguments: [AgentsArgument] = [
        AgentsArgument(AgentsOp.listBranches, "agent_id"), AgentsArgument(AgentsOp.listBranches, "include_archived"),
        AgentsArgument(AgentsOp.listBranches, "include_commit_status"),
        AgentsArgument(AgentsOp.versionMetadata, "agent_id"), AgentsArgument(AgentsOp.versionMetadata, "version_id"),
        AgentsArgument(AgentsOp.getBranch, "agent_id"), AgentsArgument(AgentsOp.getBranch, "branch_id"),
        AgentsArgument(AgentsOp.createBranch, "agent_id"), AgentsArgument(AgentsOp.createBranch, "name"),
        AgentsArgument(AgentsOp.createBranch, "description"), AgentsArgument(AgentsOp.createBranch, "parent_version_id"),
        AgentsArgument(AgentsOp.updateBranch, "agent_id"), AgentsArgument(AgentsOp.updateBranch, "branch_id"),
        AgentsArgument(AgentsOp.updateBranch, "is_archived"), AgentsArgument(AgentsOp.updateBranch, "protection_status"),
        AgentsArgument(AgentsOp.mergePreview, "agent_id"), AgentsArgument(AgentsOp.mergePreview, "source_branch_id"),
        AgentsArgument(AgentsOp.mergePreview, "target_branch_id"),
        AgentsArgument(AgentsOp.mergeBranch, "agent_id"), AgentsArgument(AgentsOp.mergeBranch, "source_branch_id"),
        AgentsArgument(AgentsOp.mergeBranch, "target_branch_id"), AgentsArgument(AgentsOp.mergeBranch, "archive_source_branch"),
        AgentsArgument(AgentsOp.rebasePreview, "agent_id"), AgentsArgument(AgentsOp.rebasePreview, "branch_id"),
        AgentsArgument(AgentsOp.rebaseBranch, "agent_id"), AgentsArgument(AgentsOp.rebaseBranch, "branch_id"),
        AgentsArgument(AgentsOp.deleteDraft, "agent_id"), AgentsArgument(AgentsOp.deleteDraft, "branch_id"),
        AgentsArgument(AgentsOp.createDeployment, "agent_id"),
        AgentsArgument(AgentsOp.createDeployment, "deployment_request.requests[].branch_id"),
        AgentsArgument(AgentsOp.createDeployment, "deployment_request.requests[].deployment_strategy.type"),
        AgentsArgument(AgentsOp.createDeployment, "deployment_request.requests[].deployment_strategy.traffic_percentage"),
        AgentsArgument(AgentsOp.listProcedures, "agent_id"), AgentsArgument(AgentsOp.listProcedures, "branch_id"),
        AgentsArgument(AgentsOp.getProcedure, "agent_id"), AgentsArgument(AgentsOp.getProcedure, "branch_id"),
        AgentsArgument(AgentsOp.getProcedure, "procedure_id"),
        AgentsArgument(AgentsOp.getProcedureDraft, "agent_id"), AgentsArgument(AgentsOp.getProcedureDraft, "branch_id"),
        AgentsArgument(AgentsOp.getProcedureDraft, "procedure_id"),
        AgentsArgument(AgentsOp.createProcedure, "agent_id"), AgentsArgument(AgentsOp.createProcedure, "branch_id"),
        AgentsArgument(AgentsOp.createProcedure, "name"), AgentsArgument(AgentsOp.createProcedure, "type"),
        AgentsArgument(AgentsOp.createProcedure, "content"), AgentsArgument(AgentsOp.createProcedure, "trigger"),
        AgentsArgument(AgentsOp.updateProcedureDraft, "agent_id"), AgentsArgument(AgentsOp.updateProcedureDraft, "branch_id"),
        AgentsArgument(AgentsOp.updateProcedureDraft, "procedure_id"), AgentsArgument(AgentsOp.updateProcedureDraft, "name"),
        AgentsArgument(AgentsOp.updateProcedureDraft, "type"), AgentsArgument(AgentsOp.updateProcedureDraft, "content"),
        AgentsArgument(AgentsOp.updateProcedureDraft, "trigger"),
        AgentsArgument(AgentsOp.deleteProcedureDraft, "agent_id"), AgentsArgument(AgentsOp.deleteProcedureDraft, "branch_id"),
        AgentsArgument(AgentsOp.deleteProcedureDraft, "procedure_id"),
        AgentsArgument(AgentsOp.removeProcedure, "agent_id"), AgentsArgument(AgentsOp.removeProcedure, "branch_id"),
        AgentsArgument(AgentsOp.removeProcedure, "procedure_id"),
        AgentsArgument(AgentsOp.compileProcedures, "agent_id"), AgentsArgument(AgentsOp.compileProcedures, "branch_id"),
        AgentsArgument(AgentsOp.listMergeProposals, "agent_id"),
        AgentsArgument(AgentsOp.getMergeProposal, "agent_id"), AgentsArgument(AgentsOp.getMergeProposal, "merge_proposal_id"),
        AgentsArgument(AgentsOp.createMergeProposal, "agent_id"), AgentsArgument(AgentsOp.createMergeProposal, "source_branch_id"),
        AgentsArgument(AgentsOp.createMergeProposal, "target_branch_id"), AgentsArgument(AgentsOp.createMergeProposal, "title"),
        AgentsArgument(AgentsOp.createMergeProposal, "description"),
        AgentsArgument(AgentsOp.commentMergeProposal, "agent_id"),
        AgentsArgument(AgentsOp.commentMergeProposal, "merge_proposal_id"), AgentsArgument(AgentsOp.commentMergeProposal, "body"),
        AgentsArgument(AgentsOp.reviewMergeProposal, "agent_id"), AgentsArgument(AgentsOp.reviewMergeProposal, "merge_proposal_id"),
        AgentsArgument(AgentsOp.reviewMergeProposal, "state"), AgentsArgument(AgentsOp.reviewMergeProposal, "comment"),
        AgentsArgument(AgentsOp.acceptMergeProposal, "agent_id"), AgentsArgument(AgentsOp.acceptMergeProposal, "merge_proposal_id"),
        AgentsArgument(AgentsOp.acceptMergeProposal, "archive_source_branch"),
        AgentsArgument(AgentsOp.updateMergeProposal, "agent_id"), AgentsArgument(AgentsOp.updateMergeProposal, "merge_proposal_id"),
        AgentsArgument(AgentsOp.updateMergeProposal, "close"),
    ]
}

private struct AgentsProceduresEditor: View {
    @Bindable var model: AgentsBranchesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("List procedures") { Task { await model.loadProcedures() } }
                Button("New procedure") { model.newProcedure() }
                AgentsRunButton(runner: model.runner(AgentsOp.compileProcedures), title: "Compile drafts into the workflow") {
                    Task { await model.compileProcedures() }
                }
                .controlSize(.small)
            }
            AgentsRunnerOutput(runner: model.runner(AgentsOp.compileProcedures), showsResult: true)
            AgentsRunnerError(runner: model.runner(AgentsOp.listProcedures))
            ForEach(model.procedures) { procedure in
                AgentsRow(selected: model.selectedProcedureID == procedure.id) {
                    Task { await model.openProcedure(procedure) }
                } content: {
                    HStack {
                        Image(systemName: procedure.type == "folder" ? "folder" : "list.number")
                        Text(procedure.name)
                        if procedure.hasDraft { AgentsBadge(text: "Draft", color: .orange) }
                        Spacer()
                        Text(AgentsFormat.words(procedure.type)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text(model.selectedProcedureID == nil ? "New procedure" : "Edit (saved as your draft)").font(.caption.weight(.medium))
            HStack {
                TextField("Name", text: $model.procedureName).textFieldStyle(.roundedBorder)
                Picker("Kind", selection: $model.procedureType) {
                    ForEach(AgentsSchema.choices(AgentsOp.createProcedure, "type"), id: \.self) { Text(AgentsFormat.words($0)).tag($0) }
                }
                .fixedSize()
            }
            TextField("When it applies", text: $model.procedureTrigger, prompt: Text("The caller wants a refund"))
                .textFieldStyle(.roundedBorder)
            AgentsDetailLoadProblem(load: model.procedureLoad)
            TextEditor(text: $model.procedureContent)
                .font(.callout)
                .frame(minHeight: 100)
                .overlay { RoundedRectangle(cornerRadius: 5).stroke(.separator) }
            HStack {
                let saveOperation = model.selectedProcedureID == nil ? AgentsOp.createProcedure : AgentsOp.updateProcedureDraft
                AgentsRunButton(runner: model.runner(saveOperation), title: model.selectedProcedureID == nil ? "Create" : "Save draft",
                                    disabled: !model.procedureLoad.isLoaded
                                        || model.procedureName.trimmingCharacters(in: .whitespaces).isEmpty,
                                    disabledReason: model.procedureLoad.reason(waiting: "Waiting for the procedure's text.")) {
                    Task { await model.saveProcedure() }
                }
                if model.selectedProcedureID != nil {
                    Button("Discard draft…") { Task { await model.discardProcedureDraft() } }
                        .disabled(!model.procedureLoad.isLoaded)
                    Button("Remove…") { Task { await model.removeProcedure() } }
                        .disabled(!model.procedureLoad.isLoaded)
                }
            }
            ForEach([AgentsOp.createProcedure, AgentsOp.updateProcedureDraft, AgentsOp.deleteProcedureDraft,
                     AgentsOp.removeProcedure], id: \.self) {
                AgentsRunnerOutput(runner: model.runner($0), showsResult: false)
            }
        }
    }
}

private struct AgentsBranchesTab: View {
    @Bindable var model: AgentsBranchesModel
    let agentName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AgentsCard("Branches", subtitle: "Work on changes apart from what callers hear, then merge them into main or send them part of the traffic.") {
                Toggle("Show archived branches", isOn: $model.includeArchived)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .onChange(of: model.includeArchived) { Task { await model.load() } }
                AgentsRunnerError(runner: model.runner(AgentsOp.listBranches))
                if model.loaded, model.branches.isEmpty {
                    Text("This agent has no branches.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.branches) { branch in
                    AgentsRow(selected: model.selectedBranchID == branch.id) {
                        model.selectedBranchID = branch.id
                    } content: {
                        HStack(spacing: 8) {
                            Image(systemName: branch.isMain ? "star.fill" : "arrow.triangle.branch")
                                .foregroundStyle(branch.isMain ? .yellow : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(branch.name)
                                    if branch.isArchived { AgentsBadge(text: "Archived") }
                                    if branch.draftExists { AgentsBadge(text: "Draft", color: .orange) }
                                }
                                Text(branchLine(branch)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let live = branch.livePercentage, live > 0 {
                                Text("\(Int(live)) % live").font(.caption.monospacedDigit())
                            }
                        }
                    }
                }
            }
            if model.selectedBranch != nil { selectedBranchCard }
            newBranchCard
            deploymentCard
            proposalsCard
            if model.version != .null {
                AgentsCard("Current version") {
                    AgentsFact(label: "Version", value: model.version["id"].stringValue ?? "—", monospaced: true)
                    AgentsFact(label: "Description", value: model.version["version_description"].stringValue ?? "—")
                    AgentsFact(label: "Committed", value: AgentsFormat.date(AgentsJSON.date(model.version["time_committed_secs"])))
                    AgentsFact(label: "Number in branch", value: model.version["seq_no_in_branch"].intValue.map(String.init) ?? "—")
                }
            }
        }
        .task(id: model.agentID) { if !model.loaded { await model.load() } }
    }

    private func branchLine(_ branch: AgentsBranch) -> String {
        var parts: [String] = []
        if let ahead = branch.commitsAhead, ahead > 0 { parts.append("\(ahead) ahead") }
        if let behind = branch.commitsBehind, behind > 0 { parts.append("\(behind) behind") }
        if let calls = branch.calls7d { parts.append("\(calls) calls this week") }
        parts.append("committed \(AgentsFormat.relative(branch.lastCommittedAt))")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var selectedBranchCard: some View {
        if let branch = model.selectedBranch {
            AgentsCard("“\(branch.name)”", subtitle: branch.description.isEmpty ? nil : branch.description) {
                HStack(spacing: 8) {
                    if !branch.isMain {
                        AgentsRunButton(runner: model.runner(AgentsOp.mergePreview), title: "Preview merge") {
                            Task { await model.previewMerge() }
                        }
                        AgentsRunButton(runner: model.runner(AgentsOp.mergeBranch),
                                            title: "Merge into \(model.mainBranch?.name ?? "main")") {
                            model.requestMerge(agentName: agentName)
                        }
                    }
                    Toggle("Archive after merging", isOn: $model.archiveSourceOnMerge).toggleStyle(.checkbox)
                }
                AgentsRunnerOutput(runner: model.runner(AgentsOp.mergePreview), showsResult: true)
                AgentsRunnerOutput(runner: model.runner(AgentsOp.mergeBranch), showsResult: false)
                if !branch.isMain {
                    HStack(spacing: 8) {
                        AgentsRunButton(runner: model.runner(AgentsOp.rebasePreview), title: "Preview rebase") {
                            Task { await model.previewRebase() }
                        }
                        AgentsRunButton(runner: model.runner(AgentsOp.rebaseBranch), title: "Rebase onto main") {
                            Task { await model.rebase() }
                        }
                    }
                    AgentsRunnerOutput(runner: model.runner(AgentsOp.rebasePreview), showsResult: true)
                    AgentsRunnerOutput(runner: model.runner(AgentsOp.rebaseBranch), showsResult: false)
                }
                HStack(spacing: 8) {
                    Button(branch.isArchived ? "Restore" : "Archive") {
                        Task { await model.setArchived(!branch.isArchived) }
                    }
                    Picker("Who may change it", selection: Binding(
                        get: { branch.protection ?? "" },
                        set: { value in Task { await model.setProtection(value) } }
                    )) {
                        if branch.protection == nil { Text("Default").tag("") }
                        ForEach(AgentsSchema.choices(AgentsOp.updateBranch, "protection_status"), id: \.self) {
                            Text(AgentsFormat.words($0)).tag($0)
                        }
                    }
                    .fixedSize()
                }
                if branch.draftExists {
                    AgentsRunButton(runner: model.runner(AgentsOp.deleteDraft), title: "Discard the draft…") {
                        Task { await model.deleteDraft(agentName: agentName) }
                    }
                }
                AgentsRunnerOutput(runner: model.runner(AgentsOp.updateBranch), showsResult: false)
                AgentsRunnerOutput(runner: model.runner(AgentsOp.deleteDraft), showsResult: false)
                DisclosureGroup("Procedures") {
                    AgentsProceduresEditor(model: model)
                        .padding(.top, 4)
                }
                .font(.callout)
            }
        }
    }

    private var newBranchCard: some View {
        AgentsCard("New branch", subtitle: "Starts from the version on screen.") {
            HStack {
                TextField("Name", text: $model.newBranchName).textFieldStyle(.roundedBorder)
                TextField("What it is for", text: $model.newBranchDescription).textFieldStyle(.roundedBorder)
                AgentsRunButton(runner: model.runner(AgentsOp.createBranch), title: "Create",
                                    disabled: model.newBranchName.trimmingCharacters(in: .whitespaces).isEmpty
                                        || model.currentVersionID == nil) {
                    Task { await model.createBranch() }
                }
            }
            AgentsRunnerOutput(runner: model.runner(AgentsOp.createBranch), showsResult: false)
        }
    }

    private var deploymentCard: some View {
        AgentsCard("Traffic", subtitle: "Which share of conversations each branch answers. The shares must add up to 100 %.") {
            ForEach(model.branches.filter { !$0.isArchived }) { branch in
                HStack {
                    Text(branch.name).frame(width: 140, alignment: .leading).lineLimit(1)
                    Slider(value: Binding(
                        get: { model.traffic[branch.id] ?? 0 },
                        set: { model.traffic[branch.id] = $0.rounded() }
                    ), in: 0...100)
                    Text("\(Int(model.traffic[branch.id] ?? 0)) %").font(.callout.monospacedDigit()).frame(width: 48)
                }
            }
            HStack {
                Text("Total \(Int(model.trafficTotal)) %")
                    .font(.caption)
                    .foregroundStyle(model.trafficTotal == 100 ? Color.secondary : Color.red)
                Spacer()
                AgentsRunButton(runner: model.runner(AgentsOp.createDeployment), title: "Deploy",
                                    disabled: model.trafficTotal != 100 || model.branches.isEmpty) {
                    model.requestDeploy(agentName: agentName)
                }
            }
            AgentsRunnerOutput(runner: model.runner(AgentsOp.createDeployment), showsResult: false)
        }
    }

    private var proposalsCard: some View {
        AgentsCard("Merge proposals", subtitle: "Ask for a branch to be merged, review, comment, and merge.") {
            ForEach(model.proposals) { proposal in
                AgentsRow(selected: model.selectedProposalID == proposal.id) {
                    Task { await model.openProposal(proposal.id) }
                } content: {
                    HStack {
                        Text(proposal.title).lineLimit(1)
                        Spacer()
                        AgentsBadge(text: AgentsFormat.words(proposal.outcome), color: AgentsBadge.color(forStatus: proposal.outcome))
                    }
                }
            }
            if model.proposals.isEmpty {
                Text("No merge proposals.").font(.callout).foregroundStyle(.secondary)
            }
            if model.selectedBranch.map({ !$0.isMain }) == true {
                HStack {
                    TextField("Title", text: $model.proposalTitle).textFieldStyle(.roundedBorder)
                    TextField("Description", text: $model.proposalDescription).textFieldStyle(.roundedBorder)
                }
                AgentsRunButton(runner: model.runner(AgentsOp.createMergeProposal), title: "Propose the merge",
                                    disabled: model.proposalTitle.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await model.propose() }
                }
                AgentsRunnerOutput(runner: model.runner(AgentsOp.createMergeProposal), showsResult: false)
            }
            if model.selectedProposalID != nil, !model.proposalIsLoaded {
                Divider()
                let load = model.proposalLoad
                if load == .loading {
                    Text("Loading the proposal…").font(.caption).foregroundStyle(.secondary)
                }
                AgentsDetailLoadProblem(load: load)
            }
            if model.proposal != .null {
                Divider()
                let proposal = model.proposal
                Text(proposal["title"].stringValue ?? "").font(.headline)
                if let text = proposal["description"].stringValue, !text.isEmpty {
                    Text(text).font(.callout).textSelection(.enabled)
                }
                ForEach(Array((proposal["comments"].arrayValue ?? []).enumerated()), id: \.offset) { _, comment in
                    Text("• " + (comment["body"].stringValue ?? comment["comment"].stringValue ?? ""))
                        .font(.callout)
                        .textSelection(.enabled)
                }
                HStack {
                    TextField("Comment", text: $model.proposalComment).textFieldStyle(.roundedBorder)
                    AgentsRunButton(runner: model.runner(AgentsOp.commentMergeProposal), title: "Comment",
                                        disabled: model.proposalComment.isEmpty) {
                        Task { await model.comment() }
                    }
                }
                HStack {
                    TextField("Review note", text: $model.reviewComment).textFieldStyle(.roundedBorder)
                    Button("Approve") { Task { await model.review(approve: true) } }
                    Button("Request changes") { Task { await model.review(approve: false) } }
                }
                HStack {
                    AgentsRunButton(runner: model.runner(AgentsOp.acceptMergeProposal), title: "Merge it…",
                                    disabled: !model.proposalIsLoaded,
                                    disabledReason: model.proposalLoad.reason(waiting: "Waiting for the proposal's details.")) {
                        model.requestAcceptProposal(agentName: agentName)
                    }
                    Button("Close proposal") { Task { await model.closeProposal() } }
                }
                ForEach([AgentsOp.commentMergeProposal, AgentsOp.reviewMergeProposal, AgentsOp.acceptMergeProposal,
                         AgentsOp.updateMergeProposal], id: \.self) { op in
                    AgentsRunnerOutput(runner: model.runner(op), showsResult: false)
                }
            }
        }
    }
}

// MARK: - Workspace settings

@MainActor
@Observable
final class AgentsWorkspaceSettingsModel {
    @ObservationIgnored let calls: AgentsCalls
    private(set) var settings: JSONValue = .null
    private(set) var dashboard: JSONValue = .null
    var canUseMCPServers = false
    var ragRetentionDays = 10
    var livekitStack = ""
    var postCallWebhookID = ""
    var webhookEvents: Set<String> = []

    init(calls: AgentsCalls) {
        self.calls = calls
    }

    func load() async {
        if let json = await calls.json(AgentsOp.getSettings, quiet: true) {
            settings = json
            canUseMCPServers = json["can_use_mcp_servers"].boolValue ?? false
            ragRetentionDays = json["rag_retention_period_days"].intValue ?? 10
            livekitStack = json["default_livekit_stack"].stringValue ?? ""
            postCallWebhookID = json["webhooks"]["post_call_webhook_id"].stringValue ?? ""
            webhookEvents = Set(AgentsJSON.strings(json["webhooks"]["events"]))
        }
        dashboard = await calls.json(AgentsOp.getDashboardSettings, quiet: true) ?? .null
    }

    /// The fields that differ from what was fetched.
    func changes() -> [String: JSONValue] {
        var body: [String: JSONValue] = [:]
        if canUseMCPServers != (settings["can_use_mcp_servers"].boolValue ?? false) {
            body["can_use_mcp_servers"] = .bool(canUseMCPServers)
        }
        if ragRetentionDays != (settings["rag_retention_period_days"].intValue ?? 10) {
            body["rag_retention_period_days"] = .number(Double(ragRetentionDays))
        }
        if !livekitStack.isEmpty, livekitStack != settings["default_livekit_stack"].stringValue {
            body["default_livekit_stack"] = .string(livekitStack)
        }
        let oldHook = settings["webhooks"]["post_call_webhook_id"].stringValue ?? ""
        let oldEvents = Set(AgentsJSON.strings(settings["webhooks"]["events"]))
        if postCallWebhookID != oldHook || webhookEvents != oldEvents {
            var webhooks: [String: JSONValue] = ["events": .array(webhookEvents.sorted().map(JSONValue.string))]
            webhooks["post_call_webhook_id"] = postCallWebhookID.isEmpty ? .null : .string(postCallWebhookID)
            body["webhooks"] = .object(webhooks)
        }
        return body
    }

    func save() async {
        let body = changes()
        guard !body.isEmpty else { return }
        let changed = body.keys.sorted().map { AgentsFormat.words($0).lowercased() }
        guard let json = await calls.json(
            AgentsOp.updateSettings, body, subject: "the workspace's agent settings",
            consequence: "This changes \(ListFormatter.localizedString(byJoining: changed)) for every agent in the "
                + "workspace. Post-call webhooks send conversation data to the webhook's address.",
            question: "Save the workspace's agent settings?", confirmLabel: "Save settings"
        ) else { return }
        if json["can_use_mcp_servers"] != .null { settings = json } else { await load() }
    }

    func removeChart(at index: Int) async {
        var charts = dashboard["charts"].arrayValue ?? []
        guard charts.indices.contains(index) else { return }
        let name = charts[index]["name"].stringValue ?? "chart"
        charts.remove(at: index)
        guard let json = await calls.json(
            AgentsOp.updateDashboardSettings, ["charts": .array(charts)], subject: "the dashboard chart “\(name)”",
            consequence: "Everyone in the workspace stops seeing the chart “\(name)” on the agents dashboard.",
            question: "Remove the dashboard chart “\(name)”?", confirmLabel: "Remove chart"
        ) else { return }
        dashboard = json["charts"] != .null ? json : ["charts": .array(charts)]
    }

    static let arguments: [AgentsArgument] = [
        AgentsArgument(AgentsOp.updateSettings, "can_use_mcp_servers"),
        AgentsArgument(AgentsOp.updateSettings, "rag_retention_period_days"),
        AgentsArgument(AgentsOp.updateSettings, "default_livekit_stack"),
        AgentsArgument(AgentsOp.updateSettings, "webhooks.events"),
        AgentsArgument(AgentsOp.updateSettings, "webhooks.post_call_webhook_id"),
        AgentsArgument(AgentsOp.updateDashboardSettings, "charts"),
    ]
}

private struct AgentsWorkspaceSettingsCard: View {
    @Bindable var model: AgentsWorkspaceSettingsModel
    @State private var expanded = false

    var body: some View {
        AgentsCard("Workspace agent settings", subtitle: "Apply to every agent in the workspace. Changing them asks first.") {
            DisclosureGroup("Show settings", isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 10) {
                    if model.settings == .null {
                        AgentsRunnerError(runner: model.calls.runner(AgentsOp.getSettings))
                        Button("Fetch settings") { Task { await model.load() } }
                    } else {
                        Form {
                            Toggle("Agents may use MCP servers", isOn: $model.canUseMCPServers)
                            Stepper("Keep RAG indexes \(model.ragRetentionDays) days", value: $model.ragRetentionDays,
                                    in: 0...Int(AgentsSchema.range(AgentsOp.updateSettings, "rag_retention_period_days", fallback: 0...30).upperBound))
                            Picker("Call infrastructure", selection: $model.livekitStack) {
                                if model.livekitStack.isEmpty { Text("Default").tag("") }
                                ForEach(AgentsSchema.choices(AgentsOp.updateSettings, "default_livekit_stack"), id: \.self) {
                                    Text(AgentsFormat.words($0)).tag($0)
                                }
                            }
                            TextField("Post-call webhook id", text: $model.postCallWebhookID, prompt: Text("None"))
                            LabeledContent("Webhook events") {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(AgentsSchema.choices(AgentsOp.updateSettings, "webhooks.events"), id: \.self) { event in
                                        Toggle(AgentsFormat.words(event), isOn: Binding(
                                            get: { model.webhookEvents.contains(event) },
                                            set: { on in
                                                if on { model.webhookEvents.insert(event) } else { model.webhookEvents.remove(event) }
                                            }
                                        ))
                                        .toggleStyle(.checkbox)
                                    }
                                }
                            }
                        }
                        .formStyle(.columns)
                        AgentsRunButton(runner: model.calls.runner(AgentsOp.updateSettings), title: "Save settings…",
                                            disabled: model.changes().isEmpty) {
                            Task { await model.save() }
                        }
                        AgentsRunnerOutput(runner: model.calls.runner(AgentsOp.updateSettings), showsResult: false)
                        let charts = model.dashboard["charts"].arrayValue ?? []
                        if !charts.isEmpty {
                            Text("Dashboard charts").font(.subheadline.weight(.medium))
                            ForEach(Array(charts.enumerated()), id: \.offset) { index, chart in
                                HStack {
                                    Text(chart["name"].stringValue ?? "Chart")
                                    AgentsBadge(text: AgentsFormat.words(chart["type"].stringValue))
                                    Spacer()
                                    Button("Remove…") { Task { await model.removeChart(at: index) } }
                                        .buttonStyle(.link)
                                }
                            }
                            AgentsRunnerOutput(runner: model.calls.runner(AgentsOp.updateDashboardSettings), showsResult: false)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .onChange(of: expanded) { if expanded, model.settings == .null { Task { await model.load() } } }
    }
}
