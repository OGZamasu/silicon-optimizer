import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// How the agents are doing: conversations happening now, what callers talk about (topics),
/// what the LLMs would cost, the tags conversations are filed under, and triage tickets about
/// conversations that went wrong.
struct AgentAnalyticsSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        AgentAnalyticsScreen(model: AgentsPlatformStore.shared(for: app).analytics)
    }
}

struct AgentAnalyticsScreen: View {
    @Bindable var model: AgentAnalyticsModel

    var body: some View {
        ElevenLabsSectionPage(.agentAnalytics) {
            AgentsCard("Scope", subtitle: "Live count, topics, cost and agent tickets follow this choice.") {
                AgentsAgentPicker(directory: model.store.directory, selection: $model.agentID, noneTitle: "All agents")
                    .fixedSize()
                    .onChange(of: model.agentID) { Task { await model.agentChanged() } }
            }
            AgentLiveCountCard(model: model)
            AgentTopicsCard(model: model)
            AgentLLMCostCard(model: model)
            AgentTicketsCard(model: model)
            AgentTagsCard(model: model)
        }
        .task { await model.loadLiveCount() }
    }
}

// MARK: - View-model

@MainActor
@Observable
final class AgentAnalyticsModel {
    enum TicketScope: String, CaseIterable, Identifiable {
        case workspace = "Whole workspace"
        case agent = "The chosen agent"
        var id: String { rawValue }
    }

    @ObservationIgnored unowned let store: AgentsPlatformStore
    var calls: AgentsCalls { store.calls }

    var agentID = ""

    // Live
    private(set) var liveCount: Int?
    private(set) var liveCheckedAt: Date?

    // Topics
    var topicSort = ""
    private(set) var topics: [AgentsTopic] = []
    private(set) var topicWindow: (Date?, Date?) = (nil, nil)

    // LLM cost
    var promptLength = 2000
    var pages = 0
    var ragEnabled = false
    private(set) var prices: [AgentsLLMPrice] = []

    // Tickets
    var ticketScope: TicketScope = .workspace
    var ticketStatus = ""
    let tickets: AgentsPagedList<AgentsTicket>
    private(set) var ticket: AgentsTicket?
    private(set) var assignableUsers: [AgentsWorkspaceUser] = []
    var newTicketConversationID = ""
    var newTicketComment = ""
    var ticketComment = ""
    var turnIndex = 0
    var turnComment = ""

    // Tags
    let tags: AgentsPagedList<AgentsTag>
    var newTagTitle = ""
    var newTagDescription = ""
    private(set) var selectedTagID: String?
    /// The tag whose title and description the fields hold; nil while the selected one's are on their way.
    private(set) var loadedTagID: String?

    /// The selected tag's title and description: in, on their way, or not coming (the error, and
    /// how to retry).
    var tagLoad: AgentsDetailLoad {
        .of(loaded: selectedTagID != nil && loadedTagID == selectedTagID,
            runner: selectedTagID.map { calls.runner(AgentsOp.getTag, slot: $0) })
    }
    var editTagTitle = ""
    var editTagDescription = ""

    init(store: AgentsPlatformStore) {
        self.store = store
        let box = AgentsWeakBox<AgentAnalyticsModel>()
        tickets = AgentsPagedList { cursor in await box.value?.fetchTickets(cursor) }
        tags = AgentsPagedList { cursor in await box.value?.fetchTags(cursor) }
        box.value = self
        topicSort = AgentsSchema.choices(AgentsOp.agentTopics, "sort_by").first ?? ""
    }

    func agentChanged() async {
        topics = []
        prices = []
        if agentID.isEmpty, ticketScope == .agent { ticketScope = .workspace }
        await loadLiveCount()
        if ticketScope == .agent { await tickets.refresh() }
    }

    // MARK: Live

    func loadLiveCount() async {
        var arguments: [String: JSONValue] = [:]
        if !agentID.isEmpty { arguments["agent_id"] = .string(agentID) }
        guard let json = await calls.json(AgentsOp.liveCount, arguments, quiet: true) else { return }
        liveCount = json["count"].intValue
        liveCheckedAt = Date()
    }

    // MARK: Topics

    func loadTopics() async {
        guard !agentID.isEmpty else { return }
        var arguments: [String: JSONValue] = ["agent_id": .string(agentID), "page_size": 30]
        if !topicSort.isEmpty { arguments["sort_by"] = .string(topicSort) }
        guard let json = await calls.json(AgentsOp.agentTopics, arguments, quiet: true) else { return }
        topics = (json["topics"].arrayValue ?? []).compactMap(AgentsTopic.init(json:))
        topicWindow = (AgentsJSON.date(json["window_start_unix_secs"]), AgentsJSON.date(json["window_end_unix_secs"]))
    }

    // MARK: Cost

    /// What each LLM would cost per minute: for the chosen agent as configured, or for the
    /// prompt length and knowledge base size given.
    func estimateCost() async {
        let json: JSONValue?
        if agentID.isEmpty {
            json = await calls.json(AgentsOp.llmCost, [
                "prompt_length": .number(Double(promptLength)), "number_of_pages": .number(Double(pages)),
                "rag_enabled": .bool(ragEnabled),
            ], quiet: true)
        } else {
            json = await calls.json(AgentsOp.agentLLMCost, ["agent_id": .string(agentID)], quiet: true)
        }
        guard let json else { return }
        prices = (json["llm_prices"].arrayValue ?? []).compactMap(AgentsLLMPrice.init(json:))
            .sorted { $0.perMinute < $1.perMinute }
    }

    // MARK: Tickets

    private func fetchTickets(_ cursor: String?) async -> AgentsPage<AgentsTicket>? {
        var arguments: [String: JSONValue] = ["page_size": 50]
        if !ticketStatus.isEmpty { arguments["status"] = .string(ticketStatus) }
        if let cursor { arguments["cursor"] = .string(cursor) }
        let operation: String
        if ticketScope == .agent, !agentID.isEmpty {
            operation = AgentsOp.listAgentTickets
            arguments["agent_id"] = .string(agentID)
        } else {
            operation = AgentsOp.listTickets
        }
        guard let json = await calls.json(operation, arguments, quiet: true) else { return nil }
        let tickets = (json["agent_conversation_tickets"].arrayValue ?? []).compactMap(AgentsTicket.init(json:))
        await store.directory.resolveAgentNames(tickets.map(\.agentID))
        return AgentsPage(items: tickets, cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue)
    }

    /// The ticket last asked for: a slower answer for an earlier one never replaces it.
    private(set) var openingTicketID: String?

    func openTicket(_ id: String) async {
        openingTicketID = id
        guard let json = await calls.json(AgentsOp.getTicket, ["agentqa_ticket_id": .string(id)], slot: id, quiet: true),
              openingTicketID == id, let ticket = AgentsTicket(json: json) else { return }
        self.ticket = ticket
        tickets.upsert(ticket)
        await loadAssignableUsers(agentID: ticket.agentID)
    }

    func loadAssignableUsers(agentID: String) async {
        guard !agentID.isEmpty else { return }
        guard let json = await calls.json(AgentsOp.assignableUsers, ["agent_id": .string(agentID)], quiet: true) else { return }
        assignableUsers = (json.arrayValue ?? []).compactMap(AgentsWorkspaceUser.init(json:))
    }

    /// A ticket about a conversation, or — with no conversation — a follow-up task for the chosen agent.
    func createTicket() async {
        let comment = newTicketComment.trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = newTicketConversationID.trimmingCharacters(in: .whitespaces)
        guard !comment.isEmpty else { return }
        let json: JSONValue?
        if !conversation.isEmpty {
            json = await calls.json(AgentsOp.createTicket, [
                "conversation_id": .string(conversation), "qa_comment": .string(comment),
            ], title: "Ticket about a conversation")
        } else {
            guard !agentID.isEmpty else { return }
            json = await calls.json(AgentsOp.createManualTicket, [
                "agent_id": .string(agentID), "qa_comment": .string(comment),
            ], title: "Ticket for “\(store.directory.agentName(agentID))”")
        }
        guard let json else { return }
        newTicketComment = ""
        newTicketConversationID = ""
        if let ticket = AgentsTicket(json: json) {
            tickets.upsert(ticket)
            openingTicketID = ticket.id
            self.ticket = ticket
        } else {
            await tickets.refresh()
        }
    }

    func updateTicket(status: String? = nil, assignee: String? = nil) async {
        guard let ticket else { return }
        var arguments: [String: JSONValue] = ["agentqa_ticket_id": .string(ticket.id)]
        if let status { arguments["status"] = .string(status) }
        if let assignee { arguments["assignee_user_id"] = assignee.isEmpty ? .null : .string(assignee) }
        guard await calls.json(AgentsOp.updateTicket, arguments, slot: ticket.id) != nil else { return }
        if openingTicketID == ticket.id { await openTicket(ticket.id) }
    }

    func comment() async {
        guard let ticket, !ticketComment.isEmpty else { return }
        guard await calls.json(AgentsOp.commentTicket, [
            "agentqa_ticket_id": .string(ticket.id), "comment": .string(ticketComment),
        ], slot: ticket.id) != nil else { return }
        ticketComment = ""
        if openingTicketID == ticket.id { await openTicket(ticket.id) }
    }

    func commentOnTurn() async {
        guard let ticket, !turnComment.isEmpty else { return }
        guard await calls.json(AgentsOp.commentTicketTurn, [
            "agentqa_ticket_id": .string(ticket.id), "turn_index": .number(Double(turnIndex)), "comment": .string(turnComment),
        ], slot: ticket.id) != nil else { return }
        turnComment = ""
        if openingTicketID == ticket.id { await openTicket(ticket.id) }
    }

    func deleteTicket() async {
        guard let ticket else { return }
        guard await calls.json(
            AgentsOp.deleteTicket, ["agentqa_ticket_id": .string(ticket.id)], slot: ticket.id,
            subject: "the ticket “\(ticket.comment.prefix(60))”",
            consequence: "ElevenLabs deletes the ticket and its comments."
        ) != nil else { return }
        tickets.remove(ticket.id)
        guard self.ticket?.id == ticket.id else { return }
        self.ticket = nil
    }

    // MARK: Tags

    private func fetchTags(_ cursor: String?) async -> AgentsPage<AgentsTag>? {
        var arguments: [String: JSONValue] = ["page_size": 100]
        if let cursor { arguments["cursor"] = .string(cursor) }
        guard let json = await calls.json(AgentsOp.listTags, arguments, quiet: true) else { return nil }
        return AgentsPage(
            items: (json["conversation_tags"].arrayValue ?? []).compactMap(AgentsTag.init(json:)),
            cursor: json["next_cursor"].stringValue, hasMore: json["has_more"].boolValue
        )
    }

    func createTag() async {
        let title = newTagTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        var arguments: [String: JSONValue] = ["title": .string(title)]
        if !newTagDescription.isEmpty { arguments["description"] = .string(newTagDescription) }
        guard let json = await calls.json(AgentsOp.createTag, arguments) else { return }
        newTagTitle = ""
        newTagDescription = ""
        if let tag = AgentsTag(json: json) {
            tags.upsert(tag)
            store.directory.tags.upsert(tag)
        } else {
            await tags.refresh()
        }
    }

    func selectTag(_ id: String) async {
        selectedTagID = id
        // The previous tag's title never stands in for this one's.
        let known = tags.item(id)
        editTagTitle = known?.title ?? ""
        editTagDescription = known?.description ?? ""
        loadedTagID = known == nil ? nil : id
        guard let json = await calls.json(AgentsOp.getTag, ["tag_id": .string(id)], slot: id, quiet: true),
              let tag = AgentsTag(json: json), selectedTagID == id else { return }
        editTagTitle = tag.title
        editTagDescription = tag.description
        loadedTagID = id
        tags.upsert(tag)
    }

    func saveTag() async {
        guard tagLoad.isLoaded, let selectedTagID else { return }
        guard let json = await calls.json(AgentsOp.updateTag, [
            "tag_id": .string(selectedTagID), "title": .string(editTagTitle), "description": .string(editTagDescription),
        ], slot: selectedTagID) else { return }
        if let tag = AgentsTag(json: json) {
            tags.upsert(tag)
            store.directory.tags.upsert(tag)
        }
    }

    func deleteTag() async {
        guard let selectedTagID, let tag = tags.item(selectedTagID) else { return }
        guard await calls.json(
            AgentsOp.deleteTag, ["tag_id": .string(selectedTagID)], slot: selectedTagID, subject: "the tag “\(tag.title)”",
            consequence: "ElevenLabs deletes the tag and takes it off every conversation that carries it."
        ) != nil else { return }
        tags.remove(selectedTagID)
        store.directory.tags.remove(selectedTagID)
        guard self.selectedTagID == selectedTagID else { return }
        self.selectedTagID = nil
        loadedTagID = nil
    }

    static let arguments: [AgentsArgument] = [
        AgentsArgument(AgentsOp.liveCount, "agent_id"),
        AgentsArgument(AgentsOp.agentTopics, "agent_id"), AgentsArgument(AgentsOp.agentTopics, "page_size"),
        AgentsArgument(AgentsOp.agentTopics, "sort_by"),
        AgentsArgument(AgentsOp.llmCost, "prompt_length"), AgentsArgument(AgentsOp.llmCost, "number_of_pages"),
        AgentsArgument(AgentsOp.llmCost, "rag_enabled"), AgentsArgument(AgentsOp.agentLLMCost, "agent_id"),
        AgentsArgument(AgentsOp.listTickets, "page_size"), AgentsArgument(AgentsOp.listTickets, "status"),
        AgentsArgument(AgentsOp.listTickets, "cursor"),
        AgentsArgument(AgentsOp.listAgentTickets, "agent_id"), AgentsArgument(AgentsOp.listAgentTickets, "page_size"),
        AgentsArgument(AgentsOp.listAgentTickets, "status"), AgentsArgument(AgentsOp.listAgentTickets, "cursor"),
        AgentsArgument(AgentsOp.getTicket, "agentqa_ticket_id"), AgentsArgument(AgentsOp.assignableUsers, "agent_id"),
        AgentsArgument(AgentsOp.createTicket, "conversation_id"), AgentsArgument(AgentsOp.createTicket, "qa_comment"),
        AgentsArgument(AgentsOp.createManualTicket, "agent_id"), AgentsArgument(AgentsOp.createManualTicket, "qa_comment"),
        AgentsArgument(AgentsOp.updateTicket, "agentqa_ticket_id"), AgentsArgument(AgentsOp.updateTicket, "status"),
        AgentsArgument(AgentsOp.updateTicket, "assignee_user_id"),
        AgentsArgument(AgentsOp.commentTicket, "agentqa_ticket_id"), AgentsArgument(AgentsOp.commentTicket, "comment"),
        AgentsArgument(AgentsOp.commentTicketTurn, "agentqa_ticket_id"), AgentsArgument(AgentsOp.commentTicketTurn, "turn_index"),
        AgentsArgument(AgentsOp.commentTicketTurn, "comment"),
        AgentsArgument(AgentsOp.deleteTicket, "agentqa_ticket_id"),
        AgentsArgument(AgentsOp.listTags, "page_size"), AgentsArgument(AgentsOp.listTags, "cursor"),
        AgentsArgument(AgentsOp.createTag, "title"), AgentsArgument(AgentsOp.createTag, "description"),
        AgentsArgument(AgentsOp.getTag, "tag_id"),
        AgentsArgument(AgentsOp.updateTag, "tag_id"), AgentsArgument(AgentsOp.updateTag, "title"),
        AgentsArgument(AgentsOp.updateTag, "description"), AgentsArgument(AgentsOp.deleteTag, "tag_id"),
    ]
}

// MARK: - Views

private struct AgentLiveCountCard: View {
    let model: AgentAnalyticsModel

    var body: some View {
        AgentsCard("Right now") {
            Button {
                Task { await model.loadLiveCount() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Count again")
            .accessibilityLabel("Count the live conversations again")
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.liveCount.map { $0.formatted() } ?? "—")
                    .font(.system(size: 34, weight: .semibold).monospacedDigit())
                Text(model.liveCount == 1 ? "conversation in progress" : "conversations in progress")
                    .foregroundStyle(.secondary)
                Spacer()
                if let at = model.liveCheckedAt {
                    Text("as of \(at.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.tertiary)
                }
            }
            AgentsRunnerError(runner: model.calls.runner(AgentsOp.liveCount))
        }
    }
}

private struct AgentTopicsCard: View {
    @Bindable var model: AgentAnalyticsModel

    var body: some View {
        AgentsCard("Topics", subtitle: "What callers talk to the chosen agent about, from ElevenLabs' latest topic discovery.") {
            HStack {
                Picker("Rank by", selection: $model.topicSort) {
                    ForEach(AgentsSchema.choices(AgentsOp.agentTopics, "sort_by"), id: \.self) { Text(AgentsFormat.words($0)).tag($0) }
                }
                .fixedSize()
                Button("Show topics") { Task { await model.loadTopics() } }
                    .disabled(model.agentID.isEmpty)
            }
            if model.agentID.isEmpty {
                Text("Choose an agent above.").font(.caption).foregroundStyle(.secondary)
            }
            AgentsRunnerError(runner: model.calls.runner(AgentsOp.agentTopics))
            if let start = model.topicWindow.0, let end = model.topicWindow.1 {
                Text("From \(AgentsFormat.date(start)) to \(AgentsFormat.date(end))").font(.caption).foregroundStyle(.secondary)
            }
            let maximum = max(model.topics.map(\.conversations).max() ?? 1, 1)
            ForEach(model.topics.filter { $0.parentID == nil }) { topic in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(topic.label).font(.callout.weight(.medium))
                        Spacer()
                        Text(AgentsFormat.count(topic.conversations, "conversation")).font(.caption.monospacedDigit())
                        if let rate = topic.successRate {
                            AgentsBadge(text: "\(Int((rate * (rate <= 1 ? 100 : 1)).rounded())) % succeed",
                                        color: rate >= 0.7 || rate >= 70 ? .green : .orange)
                        }
                    }
                    GeometryReader { geometry in
                        Capsule().fill(Color.accentColor.opacity(0.35))
                            .frame(width: geometry.size.width * CGFloat(topic.conversations) / CGFloat(maximum))
                    }
                    .frame(height: 5)
                    if !topic.description.isEmpty {
                        Text(topic.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
        }
    }
}

private struct AgentLLMCostCard: View {
    @Bindable var model: AgentAnalyticsModel

    var body: some View {
        let operation = model.agentID.isEmpty ? AgentsOp.llmCost : AgentsOp.agentLLMCost
        AgentsCard("What the LLMs would cost", subtitle: model.agentID.isEmpty
                   ? "For a prompt and knowledge base of this size. Nothing is spent to find out."
                   : "For the chosen agent as it is configured. Nothing is spent to find out.") {
            if model.agentID.isEmpty {
                HStack {
                    Stepper("Prompt of \(model.promptLength.formatted()) characters", value: $model.promptLength, in: 0...200_000, step: 500)
                    Stepper("\(model.pages) pages of documents", value: $model.pages, in: 0...10_000, step: 10)
                    Toggle("Retrieval", isOn: $model.ragEnabled).toggleStyle(.checkbox)
                }
                .font(.callout)
            }
            Button("Estimate") { Task { await model.estimateCost() } }
            AgentsRunnerError(runner: model.calls.runner(operation))
            if !model.prices.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("LLM").font(.caption.weight(.medium))
                        Text("Per minute").font(.caption.weight(.medium))
                        Text("Per message").font(.caption.weight(.medium))
                    }
                    ForEach(model.prices.prefix(25)) { price in
                        GridRow {
                            Text(price.llm).font(.callout)
                            Text(String(format: "%.4f", price.perMinute)).font(.callout.monospacedDigit())
                            Text(String(format: "%.4f", price.perMessage)).font(.callout.monospacedDigit())
                        }
                    }
                }
                Text("In US dollars, as ElevenLabs estimates them.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct AgentTicketsCard: View {
    @Bindable var model: AgentAnalyticsModel

    var body: some View {
        let calls = model.calls
        AgentsCard("Triage tickets", subtitle: "Conversations where an agent fell short, and follow-ups for the people who fix it.") {
            HStack {
                Picker("Tickets for", selection: $model.ticketScope) {
                    ForEach(AgentAnalyticsModel.TicketScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                .disabled(model.agentID.isEmpty)
                Picker("Status", selection: $model.ticketStatus) {
                    Text("Any status").tag("")
                    ForEach(AgentsSchema.choices(AgentsOp.listTickets, "status"), id: \.self) { Text(AgentsFormat.words($0)).tag($0) }
                }
                .fixedSize()
                AgentsRefreshButton(list: model.tickets, help: "Fetch the tickets again")
            }
            .onChange(of: model.ticketScope) { Task { await model.tickets.refresh() } }
            .onChange(of: model.ticketStatus) { Task { await model.tickets.refresh() } }
            AgentsListBody(model.tickets, runner: calls.runner(model.ticketScope == .agent ? AgentsOp.listAgentTickets : AgentsOp.listTickets),
                           empty: "No tickets.") { ticket in
                AgentsRow(selected: model.ticket?.id == ticket.id) {
                    Task { await model.openTicket(ticket.id) }
                } content: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ticket.comment.isEmpty ? "Ticket" : ticket.comment).lineLimit(2)
                            Text("\(model.store.directory.agentName(ticket.agentID)) · \(AgentsFormat.words(ticket.source)) · \(AgentsFormat.date(ticket.createdAt))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        AgentsBadge(text: AgentsFormat.words(ticket.status), color: AgentsBadge.color(forStatus: ticket.status))
                    }
                }
            }
            if let ticket = model.ticket {
                Divider()
                AgentTicketDetail(model: model, ticket: ticket)
            }
            Divider()
            Text("New ticket").font(.subheadline.weight(.medium))
            TextField("Conversation ID (leave empty for a follow-up task for the chosen agent)", text: $model.newTicketConversationID)
                .textFieldStyle(.roundedBorder)
            TextField("What went wrong, or what to do", text: $model.newTicketComment, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            let manual = model.newTicketConversationID.trimmingCharacters(in: .whitespaces).isEmpty
            AgentsRunButton(runner: calls.runner(manual ? AgentsOp.createManualTicket : AgentsOp.createTicket), title: "Raise ticket",
                                disabled: model.newTicketComment.isEmpty || (manual && model.agentID.isEmpty)) {
                Task { await model.createTicket() }
            }
            AgentsRunnerOutput(runner: calls.runner(manual ? AgentsOp.createManualTicket : AgentsOp.createTicket), showsResult: false)
        }
        .task { await model.tickets.loadIfNeeded() }
    }
}

private struct AgentTicketDetail: View {
    @Bindable var model: AgentAnalyticsModel
    let ticket: AgentsTicket

    var body: some View {
        let calls = model.calls
        VStack(alignment: .leading, spacing: 8) {
            Text(ticket.comment).font(.callout).textSelection(.enabled)
            if let issue = ticket.issueType { AgentsFact(label: "Kind of issue", value: AgentsFormat.words(issue)) }
            if !ticket.conversationIDs.isEmpty {
                HStack {
                    Text("Conversations").font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                    ForEach(ticket.conversationIDs.prefix(5), id: \.self) { id in
                        Button(String(id.suffix(8))) {
                            Task { await model.store.conversations.select(id) }
                            model.store.open(.agentConversations)
                        }
                        .buttonStyle(.link)
                        .font(.caption.monospaced())
                    }
                }
            }
            HStack {
                Picker("Status", selection: Binding(get: { ticket.status }, set: { status in
                    Task { await model.updateTicket(status: status) }
                })) {
                    ForEach(AgentsSchema.choices(AgentsOp.updateTicket, "status"), id: \.self) { Text(AgentsFormat.words($0)).tag($0) }
                }
                .fixedSize()
                Picker("Assignee", selection: Binding(get: { ticket.assigneeID ?? "" }, set: { user in
                    Task { await model.updateTicket(assignee: user) }
                })) {
                    Text("Nobody").tag("")
                    ForEach(model.assignableUsers) { user in
                        Text(user.name + (user.hasAccess ? "" : " (no access)")).tag(user.id)
                    }
                    if let assignee = ticket.assigneeID, !model.assignableUsers.contains(where: { $0.id == assignee }) {
                        Text(assignee).tag(assignee)
                    }
                }
                .fixedSize()
            }
            AgentsRunnerOutput(runner: calls.runner(AgentsOp.updateTicket, slot: ticket.id))
            ForEach(Array(ticket.comments.enumerated()), id: \.offset) { _, comment in
                Text("• \(comment.comment)").font(.callout).textSelection(.enabled)
            }
            ForEach(Array(ticket.turnComments.enumerated()), id: \.offset) { _, comment in
                Text("• Message \(comment.turn): \(comment.comment)").font(.callout).textSelection(.enabled)
            }
            HStack {
                TextField("Comment", text: $model.ticketComment).textFieldStyle(.roundedBorder)
                Button("Comment") { Task { await model.comment() } }.disabled(model.ticketComment.isEmpty)
            }
            HStack {
                Stepper("On message \(model.turnIndex)", value: $model.turnIndex, in: 0...500)
                TextField("Comment on that message", text: $model.turnComment).textFieldStyle(.roundedBorder)
                Button("Comment") { Task { await model.commentOnTurn() } }.disabled(model.turnComment.isEmpty)
            }
            AgentsRunnerError(runner: calls.runner(AgentsOp.commentTicket, slot: ticket.id))
            AgentsRunnerError(runner: calls.runner(AgentsOp.commentTicketTurn, slot: ticket.id))
            AgentsRunButton(runner: calls.runner(AgentsOp.deleteTicket, slot: ticket.id), title: "Delete ticket…") {
                Task { await model.deleteTicket() }
            }
            AgentsRunnerOutput(runner: calls.runner(AgentsOp.deleteTicket, slot: ticket.id))
        }
        .font(.callout)
    }
}

private struct AgentTagsCard: View {
    @Bindable var model: AgentAnalyticsModel

    var body: some View {
        let calls = model.calls
        AgentsCard("Conversation tags", subtitle: "Labels for filing conversations; add them to a conversation in Conversations.") {
            AgentsListBody(model.tags, runner: calls.runner(AgentsOp.listTags), empty: "No tags yet.") { tag in
                AgentsRow(selected: model.selectedTagID == tag.id) {
                    Task { await model.selectTag(tag.id) }
                } content: {
                    HStack {
                        AgentsBadge(text: tag.title, color: .blue)
                        Text(tag.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            if model.selectedTagID != nil {
                HStack {
                    TextField("Title", text: $model.editTagTitle).textFieldStyle(.roundedBorder)
                    TextField("Description", text: $model.editTagDescription).textFieldStyle(.roundedBorder)
                    Button("Save") { Task { await model.saveTag() } }
                        .disabled(!model.tagLoad.isLoaded)
                    AgentsRunButton(runner: calls.runner(AgentsOp.deleteTag, slot: model.selectedTagID ?? ""), title: "Delete…") {
                        Task { await model.deleteTag() }
                    }
                }
                let load = model.tagLoad
                if let waiting = load.reason(waiting: "Waiting for the tag's title."), load == .loading {
                    Label(waiting, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                }
                AgentsDetailLoadProblem(load: load)
                AgentsRunnerOutput(runner: calls.runner(AgentsOp.updateTag, slot: model.selectedTagID ?? ""))
                AgentsRunnerOutput(runner: calls.runner(AgentsOp.deleteTag, slot: model.selectedTagID ?? ""))
            }
            Divider()
            HStack {
                TextField("New tag", text: $model.newTagTitle, prompt: Text("Refund")).textFieldStyle(.roundedBorder)
                TextField("Description", text: $model.newTagDescription, prompt: Text("Optional")).textFieldStyle(.roundedBorder)
                AgentsRunButton(runner: calls.runner(AgentsOp.createTag), title: "Add",
                                    disabled: model.newTagTitle.trimmingCharacters(in: .whitespaces).isEmpty) {
                    Task { await model.createTag() }
                }
            }
            AgentsRunnerOutput(runner: calls.runner(AgentsOp.createTag), showsResult: false)
        }
        .task { await model.tags.loadIfNeeded() }
    }
}
