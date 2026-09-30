import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Agent conversations: find them (by agent, result, date, or words and meaning in what was
/// said), read the transcript with its analysis, play the recording, rate it, tag it, run the
/// analysis again, delete it — and hand out a signed URL or WebRTC token so a page of the
/// owner's can start one.
struct AgentConversationsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        AgentConversationsScreen(model: AgentsPlatformStore.shared(for: app).conversations)
    }
}

struct AgentConversationsScreen: View {
    @Bindable var model: AgentConversationsModel

    var body: some View {
        ElevenLabsSectionPage(.agentConversations, accessory: {
            AgentsRefreshButton(list: model.list, help: "Fetch the conversations again")
        }) {
            AgentConversationFilters(model: model)
            AgentsMasterDetail(masterWidth: 300) {
                AgentsCard(model.searchMode == .list ? "Conversations" : "Matching messages") {
                    if model.searchMode == .list {
                        AgentsListBody(model.list, runner: model.calls.runner(AgentsOp.listConversations),
                                       empty: "No conversations match.") { conversation in
                            AgentsRow(selected: model.selectedID == conversation.id) {
                                Task { await model.select(conversation.id) }
                            } content: {
                                AgentConversationRow(conversation: conversation,
                                                     agentName: conversation.agentName ?? model.store.directory.agentName(conversation.agentID))
                            }
                        }
                    } else {
                        AgentsRunnerError(runner: model.calls.runner(model.searchMode.operation))
                        if model.searching {
                            ProgressView().controlSize(.small)
                        } else if model.hits.isEmpty {
                            Text(model.searchText.isEmpty ? "Type what to look for above." : "No messages match.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(model.hits) { hit in
                            AgentsRow(selected: model.selectedID == hit.conversationID) {
                                Task { await model.select(hit.conversationID) }
                            } content: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(hit.text).lineLimit(3).font(.callout)
                                    Text("\(hit.agentName ?? model.store.directory.agentName(hit.agentID)) · \(AgentsFormat.date(hit.startedAt))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } detail: {
                if let detail = model.detail {
                    AgentConversationDetailView(model: model, detail: detail)
                } else if let id = model.selectedID {
                    AgentsCard("Conversation") {
                        let runner = model.calls.runner(AgentsOp.getConversation, slot: id)
                        if runner.isRunning { ProgressView().controlSize(.small) }
                        AgentsRunnerError(runner: runner)
                    }
                } else {
                    AgentsCard("No conversation selected") {
                        AgentsEmptyState(title: "Choose a conversation",
                                         message: "Its transcript, analysis and recording appear here.",
                                         systemImage: "phone.bubble")
                    }
                }
            }
            AgentConversationStartCard(model: model)
            AgentConversationLookupCard(model: model)
            AgentConversationUsersCard(model: model)
        }
        .task { await model.list.loadIfNeeded() }
    }
}

// MARK: - View-model

/// A message found by a transcript search.
struct AgentsConversationHit: Identifiable, Hashable, Sendable {
    var id: String { "\(conversationID)#\(index)" }
    var conversationID: String
    var agentID: String
    var agentName: String?
    var index: Int
    var text: String
    var startedAt: Date?

    init?(json: JSONValue) {
        guard let id = json["conversation_id"].stringValue else { return nil }
        conversationID = id
        agentID = json["agent_id"].stringValue ?? ""
        agentName = json["agent_name"].stringValue
        index = json["transcript_index"].intValue ?? 0
        text = json["chunk_text"].stringValue ?? ""
        startedAt = AgentsJSON.date(json["conversation_start_time_unix_secs"])
    }
}

/// Someone who has talked to the account's agents.
struct AgentsCaller: Identifiable, Hashable, Sendable {
    var id: String
    var conversations: Int
    var lastContact: Date?
    var lastConversationID: String?
    var lastAgentName: String?

    init?(json: JSONValue) {
        guard let id = json["user_id"].stringValue else { return nil }
        self.id = id
        conversations = json["conversation_count"].intValue ?? 0
        lastContact = AgentsJSON.date(json["last_contact_unix_secs"])
        lastConversationID = json["last_contact_conversation_id"].stringValue
        lastAgentName = json["last_contact_agent_name"].stringValue
    }
}

@MainActor
@Observable
final class AgentConversationsModel {
    enum SearchMode: String, CaseIterable, Identifiable {
        case list = "Titles and summaries"
        case words = "Words in messages"
        case meaning = "Meaning"
        var id: String { rawValue }

        var operation: String {
            switch self {
            case .list: AgentsOp.listConversations
            case .words: AgentsOp.textSearch
            case .meaning: AgentsOp.smartSearch
            }
        }
    }

    enum Since: String, CaseIterable, Identifiable {
        case any = "Any time"
        case day = "Last 24 hours"
        case week = "Last 7 days"
        case month = "Last 30 days"
        var id: String { rawValue }

        var seconds: TimeInterval? {
            switch self {
            case .any: nil
            case .day: 86_400
            case .week: 7 * 86_400
            case .month: 30 * 86_400
            }
        }
    }

    @ObservationIgnored unowned let store: AgentsPlatformStore
    var calls: AgentsCalls { store.calls }

    // Filters
    var filterAgentID = ""
    /// One of the spec's `call_successful` values, or "".
    var result = ""
    var since: Since = .any
    var searchText = ""
    var searchMode: SearchMode = .list
    /// Now, for the date filter; a test pins it.
    @ObservationIgnored var now: () -> Date = Date.init

    let list: AgentsPagedList<AgentsConversation>
    private(set) var hits: [AgentsConversationHit] = []
    private(set) var searching = false

    // Detail
    private(set) var selectedID: String?
    private(set) var detail: AgentsConversationDetail?
    private(set) var sipMessages: [JSONValue] = []

    // Start elsewhere
    var startAgentID = ""
    var includeConversationID = false

    // Lookup
    var lookupAgentID = ""
    var lookupReference = ""

    // Callers
    let callers: AgentsPagedList<AgentsCaller>

    init(store: AgentsPlatformStore) {
        self.store = store
        let box = AgentsWeakBox<AgentConversationsModel>()
        list = AgentsPagedList { cursor in await box.value?.fetchPage(cursor) }
        callers = AgentsPagedList { cursor in await box.value?.fetchCallers(cursor) }
        box.value = self
    }

    /// The list's arguments for the current filters.
    func listArguments(cursor: String? = nil) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = ["page_size": 30, "summary_mode": "include"]
        if !filterAgentID.isEmpty { arguments["agent_id"] = .string(filterAgentID) }
        if !result.isEmpty { arguments["call_successful"] = .string(result) }
        if let seconds = since.seconds {
            arguments["call_start_after_unix"] = .number((now().timeIntervalSince1970 - seconds).rounded(.down))
        }
        let search = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if searchMode == .list, !search.isEmpty { arguments["search"] = .string(search) }
        if let cursor { arguments["cursor"] = .string(cursor) }
        return arguments
    }

    private func fetchPage(_ cursor: String?) async -> AgentsPage<AgentsConversation>? {
        guard let json = await calls.json(AgentsOp.listConversations, listArguments(cursor: cursor), quiet: true)
        else { return nil }
        return AgentsPage(
            items: (json["conversations"].arrayValue ?? []).compactMap(AgentsConversation.init(json:)),
            cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
        )
    }

    /// Runs the search box: the list's own filter, or a search through what was said.
    func runSearch() async {
        switch searchMode {
        case .list:
            await list.refresh()
        case .words, .meaning:
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                hits = []
                return
            }
            var arguments: [String: JSONValue] = ["text_query": .string(query), "page_size": 20]
            if !filterAgentID.isEmpty { arguments["agent_id"] = .string(filterAgentID) }
            if searchMode == .words {
                if !result.isEmpty { arguments["call_successful"] = .string(result) }
                if let seconds = since.seconds {
                    arguments["call_start_after_unix"] = .number((now().timeIntervalSince1970 - seconds).rounded(.down))
                }
            }
            searching = true
            defer { searching = false }
            guard let json = await calls.json(searchMode.operation, arguments, quiet: true) else { return }
            hits = (json["results"].arrayValue ?? []).compactMap(AgentsConversationHit.init(json:))
            await store.directory.resolveAgentNames(hits.filter { $0.agentName == nil }.map(\.agentID))
        }
    }

    func select(_ id: String) async {
        guard selectedID != id || detail == nil else { return }
        selectedID = id
        detail = nil
        sipMessages = []
        await loadDetail(id)
    }

    func loadDetail(_ id: String) async {
        guard let json = await calls.json(AgentsOp.getConversation, ["conversation_id": .string(id)], slot: id, quiet: true),
              selectedID == id
        else { return }
        detail = AgentsConversationDetail(json: json)
    }

    // MARK: Actions

    func fetchAudio() async {
        guard let detail else { return }
        await calls.run(AgentsOp.conversationAudio, ["conversation_id": .string(detail.id)],
                        slot: detail.id, title: "Recording of \(detail.title ?? detail.id)")
    }

    func sendFeedback(_ feedback: String?) async {
        guard let detail else { return }
        let value: JSONValue = feedback.map(JSONValue.string) ?? .null
        guard await calls.json(AgentsOp.conversationFeedback, ["conversation_id": .string(detail.id), "feedback": value])
            != nil else { return }
        self.detail?.feedback = feedback
    }

    func assignTag(_ tagID: String) async {
        guard let detail else { return }
        guard await calls.json(AgentsOp.assignTags, [
            "conversation_id": .string(detail.id), "tag_ids": [.string(tagID)],
        ]) != nil else { return }
        if !(self.detail?.tagIDs.contains(tagID) ?? true) { self.detail?.tagIDs.append(tagID) }
    }

    func unassignTag(_ tagID: String) async {
        guard let detail else { return }
        let name = store.directory.tags.item(tagID)?.title ?? tagID
        guard await calls.json(
            AgentsOp.unassignTag, ["conversation_id": .string(detail.id), "tag_id": .string(tagID)],
            subject: "the tag “\(name)” from this conversation",
            consequence: "The conversation will no longer carry the tag “\(name)”. The tag itself is kept.",
            confirmTitle: "Remove the tag “\(name)” from this conversation?", confirmLabel: "Remove tag"
        ) != nil else { return }
        self.detail?.tagIDs.removeAll { $0 == tagID }
    }

    /// Analyses the conversation again with the agent's current criteria. Spends credits.
    func runAnalysis() async {
        guard let detail else { return }
        guard let json = await calls.json(AgentsOp.runAnalysis, ["conversation_id": .string(detail.id)],
                                          title: "Analysis of \(detail.title ?? detail.id)") else { return }
        if let updated = AgentsConversationDetail(json: json), selectedID == detail.id { self.detail = updated }
    }

    func rerunEvaluation(_ evaluationID: String) async {
        guard let detail else { return }
        guard await calls.json(AgentsOp.runEvaluation, [
            "conversation_id": .string(detail.id), "evaluation_id": .string(evaluationID),
        ], slot: evaluationID) != nil else { return }
        await loadDetail(detail.id)
    }

    func loadSIPMessages() async {
        guard let detail else { return }
        guard let json = await calls.json(AgentsOp.conversationSIPMessages,
                                          ["conversation_id": .string(detail.id), "page_size": 20], quiet: true)
        else { return }
        sipMessages = json["sip_messages"].arrayValue ?? []
    }

    func delete() async {
        guard let detail else { return }
        let title = detail.title.map { "“\($0)”" } ?? "from \(AgentsFormat.date(detail.startedAt))"
        guard await calls.json(
            AgentsOp.deleteConversation, ["conversation_id": .string(detail.id)],
            subject: "the conversation \(title)",
            consequence: "ElevenLabs will delete its transcript, recording and analysis. This cannot be undone."
        ) != nil else { return }
        list.remove(detail.id)
        hits.removeAll { $0.conversationID == detail.id }
        selectedID = nil
        self.detail = nil
    }

    // MARK: Start elsewhere

    /// A signed URL for a page of the owner's to open a conversation with an agent that needs
    /// authorisation. Shown once.
    func fetchSignedURL() async {
        guard !startAgentID.isEmpty else { return }
        var arguments: [String: JSONValue] = ["agent_id": .string(startAgentID)]
        if includeConversationID { arguments["include_conversation_id"] = true }
        await calls.json(AgentsOp.signedURL, arguments)
    }

    /// A WebRTC session token for the same. Shown once.
    func fetchWebRTCToken() async {
        guard !startAgentID.isEmpty else { return }
        await calls.json(AgentsOp.webRTCToken, ["agent_id": .string(startAgentID)])
    }

    // MARK: Lookup and callers

    /// Finds the conversation a Slack message or Zendesk ticket link refers to, and opens it.
    func resolveReference() async {
        let reference = lookupReference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lookupAgentID.isEmpty, !reference.isEmpty else { return }
        guard let json = await calls.json(AgentsOp.resolveReference, [
            "agent_id": .string(lookupAgentID), "reference": .string(reference),
        ], quiet: true), let found = AgentsConversationDetail(json: json) else { return }
        selectedID = found.id
        detail = found
    }

    private func fetchCallers(_ cursor: String?) async -> AgentsPage<AgentsCaller>? {
        var arguments: [String: JSONValue] = ["page_size": 30]
        if !filterAgentID.isEmpty { arguments["agent_id"] = .string(filterAgentID) }
        if let cursor { arguments["cursor"] = .string(cursor) }
        guard let json = await calls.json(AgentsOp.conversationUsers, arguments, quiet: true) else { return nil }
        return AgentsPage(
            items: (json["users"].arrayValue ?? []).compactMap(AgentsCaller.init(json:)),
            cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
        )
    }

    static let arguments: [AgentsArgument] = [
        AgentsArgument(AgentsOp.listConversations, "page_size"), AgentsArgument(AgentsOp.listConversations, "summary_mode"),
        AgentsArgument(AgentsOp.listConversations, "agent_id"), AgentsArgument(AgentsOp.listConversations, "call_successful"),
        AgentsArgument(AgentsOp.listConversations, "call_start_after_unix"), AgentsArgument(AgentsOp.listConversations, "search"),
        AgentsArgument(AgentsOp.listConversations, "cursor"),
        AgentsArgument(AgentsOp.textSearch, "text_query"), AgentsArgument(AgentsOp.textSearch, "page_size"),
        AgentsArgument(AgentsOp.textSearch, "agent_id"), AgentsArgument(AgentsOp.textSearch, "call_successful"),
        AgentsArgument(AgentsOp.textSearch, "call_start_after_unix"),
        AgentsArgument(AgentsOp.smartSearch, "text_query"), AgentsArgument(AgentsOp.smartSearch, "page_size"),
        AgentsArgument(AgentsOp.smartSearch, "agent_id"),
        AgentsArgument(AgentsOp.getConversation, "conversation_id"),
        AgentsArgument(AgentsOp.conversationAudio, "conversation_id"),
        AgentsArgument(AgentsOp.conversationFeedback, "conversation_id"), AgentsArgument(AgentsOp.conversationFeedback, "feedback"),
        AgentsArgument(AgentsOp.assignTags, "conversation_id"), AgentsArgument(AgentsOp.assignTags, "tag_ids"),
        AgentsArgument(AgentsOp.unassignTag, "conversation_id"), AgentsArgument(AgentsOp.unassignTag, "tag_id"),
        AgentsArgument(AgentsOp.runAnalysis, "conversation_id"),
        AgentsArgument(AgentsOp.runEvaluation, "conversation_id"), AgentsArgument(AgentsOp.runEvaluation, "evaluation_id"),
        AgentsArgument(AgentsOp.conversationSIPMessages, "conversation_id"),
        AgentsArgument(AgentsOp.conversationSIPMessages, "page_size"),
        AgentsArgument(AgentsOp.deleteConversation, "conversation_id"),
        AgentsArgument(AgentsOp.signedURL, "agent_id"), AgentsArgument(AgentsOp.signedURL, "include_conversation_id"),
        AgentsArgument(AgentsOp.webRTCToken, "agent_id"),
        AgentsArgument(AgentsOp.resolveReference, "agent_id"), AgentsArgument(AgentsOp.resolveReference, "reference"),
        AgentsArgument(AgentsOp.conversationUsers, "page_size"), AgentsArgument(AgentsOp.conversationUsers, "agent_id"),
        AgentsArgument(AgentsOp.conversationUsers, "cursor"),
    ]
}

// MARK: - Views

private struct AgentConversationFilters: View {
    @Bindable var model: AgentConversationsModel

    var body: some View {
        AgentsCard("Find conversations") {
            HStack(spacing: 10) {
                AgentsAgentPicker(directory: model.store.directory, selection: $model.filterAgentID, noneTitle: "All agents")
                    .fixedSize()
                Picker("Result", selection: $model.result) {
                    Text("Any result").tag("")
                    ForEach(AgentsSchema.choices(AgentsOp.listConversations, "call_successful"), id: \.self) {
                        Text(AgentsFormat.words($0)).tag($0)
                    }
                }
                .fixedSize()
                Picker("When", selection: $model.since) {
                    ForEach(AgentConversationsModel.Since.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
            }
            .onChange(of: model.filterAgentID) { Task { await model.runSearch() } }
            .onChange(of: model.result) { Task { await model.runSearch() } }
            .onChange(of: model.since) { Task { await model.runSearch() } }
            HStack(spacing: 8) {
                AgentsSearchField(prompt: "Search", text: $model.searchText) {
                    Task { await model.runSearch() }
                }
                Picker("Search in", selection: $model.searchMode) {
                    ForEach(AgentConversationsModel.SearchMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: model.searchMode) { Task { await model.runSearch() } }
            }
        }
    }
}

private struct AgentConversationRow: View {
    let conversation: AgentsConversation
    let agentName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(conversation.title ?? "Conversation").lineLimit(1)
                Spacer(minLength: 4)
                if let result = conversation.callSuccessful {
                    AgentsBadge(text: AgentsFormat.words(result), color: AgentsBadge.color(forStatus: result))
                }
            }
            Text("\(agentName) · \(AgentsFormat.date(conversation.startedAt)) · \(AgentsFormat.duration(conversation.durationSeconds))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if conversation.status != "done" {
                AgentsBadge(text: AgentsFormat.words(conversation.status), color: AgentsBadge.color(forStatus: conversation.status))
            }
        }
    }
}

private struct AgentConversationDetailView: View {
    let model: AgentConversationsModel
    let detail: AgentsConversationDetail

    var body: some View {
        let calls = model.calls
        VStack(alignment: .leading, spacing: 14) {
            AgentsCard(detail.title ?? "Conversation", subtitle: detail.summary) {
                HStack(spacing: 6) {
                    Button {
                        Task { await model.sendFeedback(detail.feedback == "like" ? nil : "like") }
                    } label: {
                        Image(systemName: detail.feedback == "like" ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }
                    .help("Good conversation")
                    .accessibilityLabel("Rate as good")
                    Button {
                        Task { await model.sendFeedback(detail.feedback == "dislike" ? nil : "dislike") }
                    } label: {
                        Image(systemName: detail.feedback == "dislike" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    }
                    .help("Bad conversation")
                    .accessibilityLabel("Rate as bad")
                }
                .buttonStyle(.borderless)
            } content: {
                HStack(spacing: 6) {
                    if let result = detail.callSuccessful {
                        AgentsBadge(text: AgentsFormat.words(result), color: AgentsBadge.color(forStatus: result))
                    }
                    AgentsBadge(text: AgentsFormat.words(detail.status), color: AgentsBadge.color(forStatus: detail.status))
                }
                AgentsFact(label: "Agent", value: detail.agentName ?? model.store.directory.agentName(detail.agentID))
                AgentsFact(label: "Started", value: AgentsFormat.date(detail.startedAt))
                AgentsFact(label: "Length", value: AgentsFormat.duration(detail.durationSeconds))
                if let cost = detail.cost { AgentsFact(label: "Cost", value: "\(cost.formatted()) credits") }
                if let reason = detail.terminationReason, !reason.isEmpty { AgentsFact(label: "Ended because", value: reason) }
                if let call = detail.phoneCall, !call.isEmpty { AgentsFact(label: "Phone call", value: call) }
                if let language = detail.mainLanguage { AgentsFact(label: "Language", value: language) }
                AgentsFact(label: "ID", value: detail.id, monospaced: true)
                AgentsRunnerOutput(runner: calls.runner(AgentsOp.conversationFeedback), showsResult: false)
            }
            tagsCard
            if detail.hasAudio {
                AgentsCard("Recording") {
                    ElevenLabsRunButton(runner: calls.runner(AgentsOp.conversationAudio, slot: detail.id), title: "Fetch the recording") {
                        Task { await model.fetchAudio() }
                    }
                    AgentsRunnerOutput(runner: calls.runner(AgentsOp.conversationAudio, slot: detail.id), showsResult: true)
                }
            }
            analysisCard
            AgentsCard("Transcript", subtitle: AgentsFormat.count(detail.turns.count, "message")) {
                AgentsTranscriptView(turns: detail.turns)
            }
            if detail.phoneCall != nil {
                AgentsCard("SIP messages", subtitle: "The signalling of the phone call, for troubleshooting.") {
                    Button("Fetch SIP messages") { Task { await model.loadSIPMessages() } }
                    AgentsRunnerError(runner: calls.runner(AgentsOp.conversationSIPMessages))
                    ForEach(Array(model.sipMessages.enumerated()), id: \.offset) { _, message in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(AgentsFormat.words(message["direction"].stringValue)) · \(message["transport"].stringValue ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(message["raw_message"].stringValue ?? "")
                                .font(.caption.monospaced()).lineLimit(6).textSelection(.enabled)
                        }
                    }
                }
            }
            AgentsCard("Delete") {
                ElevenLabsRunButton(runner: calls.runner(AgentsOp.deleteConversation), title: "Delete conversation…") {
                    Task { await model.delete() }
                }
                AgentsRunnerOutput(runner: calls.runner(AgentsOp.deleteConversation), showsResult: false)
            }
        }
    }

    private var tagsCard: some View {
        let tags = model.store.directory.tags
        return AgentsCard("Tags") {
            HStack(spacing: 6) {
                if detail.tagIDs.isEmpty {
                    Text("No tags.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(detail.tagIDs, id: \.self) { id in
                    HStack(spacing: 2) {
                        AgentsBadge(text: tags.item(id)?.title ?? id, color: .blue)
                        Button {
                            Task { await model.unassignTag(id) }
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove the tag \(tags.item(id)?.title ?? id)")
                    }
                }
                Spacer()
                Menu("Add tag") {
                    ForEach(tags.items.filter { !detail.tagIDs.contains($0.id) }) { tag in
                        Button(tag.title) { Task { await model.assignTag(tag.id) } }
                    }
                }
                .fixedSize()
                .disabled(tags.items.isEmpty)
            }
            AgentsRunnerOutput(runner: model.calls.runner(AgentsOp.assignTags), showsResult: false)
            AgentsRunnerOutput(runner: model.calls.runner(AgentsOp.unassignTag), showsResult: false)
        }
        .task { await tags.loadIfNeeded() }
    }

    private var analysisCard: some View {
        AgentsCard("Analysis", subtitle: "How the conversation measured up against the agent's criteria, and what it collected.") {
            if detail.evaluations.isEmpty, detail.collected.isEmpty {
                Text("No criteria results.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(detail.evaluations) { evaluation in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(evaluation.id).font(.callout.weight(.medium))
                        AgentsBadge(text: AgentsFormat.words(evaluation.result), color: AgentsBadge.color(forStatus: evaluation.result))
                        Spacer()
                        Button("Evaluate again") { Task { await model.rerunEvaluation(evaluation.id) } }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    if !evaluation.rationale.isEmpty {
                        Text(evaluation.rationale).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    AgentsRunnerError(runner: model.calls.runner(AgentsOp.runEvaluation, slot: evaluation.id))
                }
            }
            ForEach(detail.collected) { item in
                AgentsFact(label: item.id, value: item.value)
            }
            ElevenLabsRunButton(runner: model.calls.runner(AgentsOp.runAnalysis), title: "Analyse again") {
                Task { await model.runAnalysis() }
            }
            AgentsRunnerOutput(runner: model.calls.runner(AgentsOp.runAnalysis), showsResult: false)
        }
    }
}

private struct AgentConversationStartCard: View {
    @Bindable var model: AgentConversationsModel

    var body: some View {
        AgentsCard("Start a conversation from your own page", subtitle: "For agents that require authentication: a signed URL or a WebRTC token your page uses to open one conversation. Each is shown once and expires soon; opening a conversation with it spends credits.") {
            HStack(spacing: 10) {
                AgentsAgentPicker(directory: model.store.directory, selection: $model.startAgentID).fixedSize()
                Toggle("Include a conversation ID", isOn: $model.includeConversationID).toggleStyle(.checkbox)
            }
            HStack(spacing: 8) {
                ElevenLabsRunButton(runner: model.calls.runner(AgentsOp.signedURL), title: "Get a signed URL",
                                    disabled: model.startAgentID.isEmpty) {
                    Task { await model.fetchSignedURL() }
                }
                ElevenLabsRunButton(runner: model.calls.runner(AgentsOp.webRTCToken), title: "Get a WebRTC token",
                                    disabled: model.startAgentID.isEmpty) {
                    Task { await model.fetchWebRTCToken() }
                }
            }
            AgentsRunnerOutput(runner: model.calls.runner(AgentsOp.signedURL), showsResult: false)
            AgentsRunnerOutput(runner: model.calls.runner(AgentsOp.webRTCToken), showsResult: false)
        }
    }
}

private struct AgentConversationLookupCard: View {
    @Bindable var model: AgentConversationsModel

    var body: some View {
        AgentsCard("Open from a Slack or Zendesk link", subtitle: "Finds the conversation a Slack message or Zendesk ticket about an agent refers to.") {
            HStack(spacing: 8) {
                AgentsAgentPicker(directory: model.store.directory, selection: $model.lookupAgentID).fixedSize()
                TextField("Link", text: $model.lookupReference, prompt: Text("https://…"))
                    .textFieldStyle(.roundedBorder)
                ElevenLabsRunButton(runner: model.calls.runner(AgentsOp.resolveReference), title: "Open",
                                    disabled: model.lookupAgentID.isEmpty || model.lookupReference.isEmpty) {
                    Task { await model.resolveReference() }
                }
            }
            AgentsRunnerError(runner: model.calls.runner(AgentsOp.resolveReference))
        }
    }
}

private struct AgentConversationUsersCard: View {
    let model: AgentConversationsModel
    @State private var expanded = false

    var body: some View {
        AgentsCard("Callers", subtitle: "Everyone who has talked to your agents (or the agent chosen above), most recent first.") {
            DisclosureGroup("Show callers", isExpanded: $expanded) {
                AgentsListBody(model.callers, runner: model.calls.runner(AgentsOp.conversationUsers), empty: "No callers yet.") { caller in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(caller.id).font(.callout.monospaced()).lineLimit(1)
                            Text("\(AgentsFormat.count(caller.conversations, "conversation")) · last \(AgentsFormat.relative(caller.lastContact))\(caller.lastAgentName.map { " with \($0)" } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let id = caller.lastConversationID {
                            Button("Last conversation") { Task { await model.select(id) } }.buttonStyle(.link).font(.caption)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .onChange(of: expanded) { if expanded { Task { await model.callers.loadIfNeeded() } } }
    }
}
