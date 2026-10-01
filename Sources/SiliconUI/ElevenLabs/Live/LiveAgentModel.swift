@preconcurrency import AVFoundation
import Foundation
import Observation
import SiliconElevenLabs

/// Talk to an agent: a live conversation with one of the owner's Agents Platform agents — the
/// microphone in, the agent's voice out (or text both ways), both sides' words on screen.
///
/// What it holds to:
/// - **One conversation per screen.** Start is refused while one is starting, waiting for an
///   answer or open; the agent is captured when Start is pressed (the picker locks), so switching
///   agents mid-start opens nothing new.
/// - **Real-world actions are the owner's.** Before an agent that can act on ElevenLabs' side —
///   call a URL, transfer a call, press keypad tones, use an MCP server — the screen asks, naming
///   each tool and where it reaches. Every MCP tool approval is a card naming the tool and its
///   server, answered only by the owner, for the conversation it was asked in; it is declined —
///   the decline is sent — when it times out, when the conversation ends, or when the account
///   changes. A client tool call is answered that nothing ran: this app runs none.
/// - **The microphone is off until Start**, and a red indicator shows while it is on.
/// - **No reconnect.** A dropped conversation says so (it may have been billed) and stays ended.
@MainActor
@Observable
final class LiveAgentModel: ElevenLabsLiveWork {
    enum Phase: Equatable, Sendable {
        case idle
        /// Reading the agent's settings (free) before anything opens.
        case preparing
        /// Waiting for the owner to agree to an agent that can act in the real world.
        case asking
        case connecting
        case live
        case ending
        case ended
    }

    struct AgentSummary: Identifiable, Hashable, Sendable {
        let id: String
        var name: String
    }

    enum Load: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    struct Line: Identifiable, Equatable, Sendable {
        enum Role: String, Sendable { case user, agent, tool, system }
        let id: Int
        var role: Role
        var text: String
        var eventID: Int?
        /// A user line still being heard, or an agent line still streaming.
        var tentative = false
        var interrupted = false
        var liked: Bool?
    }

    /// An MCP tool call waiting for the owner, with everything it was asked with.
    struct Approval: Identifiable, Equatable, Sendable {
        enum State: Equatable, Sendable {
            case waiting
            case sending
            case approved
            case declined(String)
            /// ElevenLabs stopped waiting for it (answered elsewhere, ran, failed).
            case movedOn
        }

        /// The tool call's id, as ElevenLabs gave it.
        let id: String
        /// The conversation it was asked in.
        let session: UUID
        let agentName: String
        let toolName: String
        let toolDescription: String?
        let serverName: String
        let serverHost: String?
        let parameters: JSONValue
        let deadline: Date
        var state: State = .waiting
    }

    /// The question before starting an agent that can act in the real world.
    struct StartQuestion: Equatable, Sendable {
        let agentID: String
        let agentName: String
        let textOnly: Bool
        /// One line per tool: what it is and where it reaches.
        let tools: [String]
        let preflight: ElevenLabsAgentPreflight
        let servers: [String: LiveMCPServer]
    }

    // MARK: Settings

    var selectedAgentID = ""
    /// Text both ways, no audio: cheaper, and the agent must allow it.
    var textOnly = false
    var muted = false {
        didSet { converter?.muted = muted }
    }
    /// The text box beside the microphone.
    var message = ""

    // MARK: State

    private(set) var agents: [AgentSummary] = []
    private(set) var agentsLoad: Load = .idle
    private(set) var phase: Phase = .idle
    private(set) var lines: [Line] = []
    private(set) var approvals: [Approval] = []
    private(set) var question: StartQuestion?
    private(set) var outcome: LiveOutcome?
    private(set) var usage: ElevenLabsRealtimeUsage?
    private(set) var conversationID: String?
    /// The agent of the open (or last) conversation.
    private(set) var sessionAgentName: String?
    private(set) var sessionTextOnly = false
    private(set) var microphoneOn = false
    private(set) var level: Float = 0
    private(set) var queueStatus: String?
    private(set) var savedTranscript: URL?
    private(set) var now = Date()

    let context: LiveContext
    @ObservationIgnored private let guardian: LiveSessionGuard
    @ObservationIgnored private var conversation: ElevenLabsAgentConversation?
    @ObservationIgnored private var playback: LivePlayback?
    @ObservationIgnored private var converter: LiveCaptureConverter?
    @ObservationIgnored private var chunks: AsyncStream<Data>.Continuation?
    @ObservationIgnored private var sender: Task<Void, Never>?
    @ObservationIgnored private var servers: [String: LiveMCPServer] = [:]
    @ObservationIgnored private var nextLineID = 0
    @ObservationIgnored private var listToken = UUID()
    @ObservationIgnored private var preparing = UUID()
    /// Agent audio at or below this event id is not played: the owner pressed "Stop talking".
    @ObservationIgnored private var silencedThrough: Int?
    @ObservationIgnored private var lastAgentEventID: Int?
    @ObservationIgnored private var toolLines: [String: Int] = [:]

    /// How long an approval waits when ElevenLabs does not say.
    static let defaultApprovalTimeout: TimeInterval = 300

    init(context: LiveContext) {
        self.context = context
        guardian = LiveSessionGuard(context: context)
    }

    var isOpen: Bool { phase == .connecting || phase == .live || phase == .ending }
    var isBusy: Bool { phase == .preparing || phase == .asking || isOpen }
    var selectedAgent: AgentSummary? { agents.first { $0.id == selectedAgentID } }

    var startBlocker: String? {
        if isBusy { return nil }
        if selectedAgentID.isEmpty { return "Choose an agent." }
        return nil
    }

    var waitingApprovals: [Approval] { approvals.filter { $0.state == .waiting || $0.state == .sending } }

    // MARK: Agents

    /// `GET /v1/convai/agents` (free), newest first. A failure says why and can be retried.
    func loadAgents() async {
        guard let client = context.client() else {
            agentsLoad = .failed(ElevenLabsError.notLinked.description)
            return
        }
        let token = UUID()
        listToken = token
        agentsLoad = .loading
        do {
            var found: [AgentSummary] = []
            var cursor: String?
            for _ in 0..<10 {
                var arguments: [String: JSONValue] = ["page_size": 100]
                if let cursor { arguments["cursor"] = .string(cursor) }
                let page = try ElevenLabsClient.json(await client.call("get_agents_route", arguments: arguments))
                found += (page["agents"].arrayValue ?? []).compactMap { agent in
                    agent["agent_id"].stringValue.map { AgentSummary(id: $0, name: agent["name"].stringValue ?? $0) }
                }
                cursor = page["next_cursor"].stringValue
                guard page["has_more"].boolValue == true, cursor != nil else { break }
            }
            guard listToken == token else { return }
            agents = found
            agentsLoad = .loaded
            if selectedAgentID.isEmpty, let first = found.first { selectedAgentID = first.id }
        } catch {
            guard listToken == token else { return }
            agentsLoad = .failed(ElevenLabsRunnerFailure(error).message)
        }
    }

    /// Chooses an agent from elsewhere (the Agents editor's "Talk to it live").
    func choose(agentID: String, name: String) {
        guard !isBusy else { return }
        if !agents.contains(where: { $0.id == agentID }) { agents.insert(AgentSummary(id: agentID, name: name), at: 0) }
        selectedAgentID = agentID
    }

    // MARK: Starting

    /// Reads the agent (free), then either asks — when it can act in the real world — or starts.
    func requestStart() async {
        guard !isBusy, startBlocker == nil else { return }
        let agentID = selectedAgentID
        let agentName = selectedAgent?.name ?? agentID
        let textOnly = textOnly
        guard let realtime = context.realtime() else {
            outcome = .notStarted(ElevenLabsError.notLinked.description)
            return
        }
        outcome = nil
        phase = .preparing
        let token = UUID()
        preparing = token
        let preflight: ElevenLabsAgentPreflight
        do {
            preflight = try await realtime.agentPreflight(agentID: agentID)
        } catch {
            guard preparing == token else { return }
            phase = .ended
            outcome = .notStarted("The agent's settings could not be read, so nothing was started: \(ElevenLabsRunnerFailure(error).message)")
            return
        }
        if textOnly, !preflight.textOnlyByDefault, !preflight.textOnlyOverrideAllowed {
            phase = .ended
            outcome = .notStarted("“\(agentName)” does not allow text-only conversations. Turn on the “Text only” override in its security settings, or talk by voice.")
            return
        }
        let servers = await LiveMCPServer.list(with: realtime.client)
        guard preparing == token, phase == .preparing else { return }
        let reaching = preflight.realWorldTools
        if reaching.isEmpty {
            await begin(agentID: agentID, agentName: agentName, textOnly: textOnly, preflight: preflight, servers: servers)
        } else {
            question = StartQuestion(
                agentID: agentID, agentName: agentName, textOnly: textOnly,
                tools: reaching.map { Self.describe($0, servers: servers) }, preflight: preflight, servers: servers
            )
            phase = .asking
        }
    }

    /// The owner agreed: start the agent the question named, whatever is selected now.
    func confirmStart() async {
        guard phase == .asking, let question else { return }
        self.question = nil
        await begin(agentID: question.agentID, agentName: question.agentName, textOnly: question.textOnly,
                    preflight: question.preflight, servers: question.servers)
    }

    func cancelStart() {
        switch phase {
        case .preparing, .asking:
            preparing = UUID()
            question = nil
            phase = .idle
        case .connecting:
            end(.mayHaveBeenBilled("Cancelled while connecting. If it had already started on ElevenLabs' side it was ended at once; check Conversations if unsure."), closing: true)
        default:
            break
        }
    }

    private func begin(
        agentID: String, agentName: String, textOnly: Bool, preflight: ElevenLabsAgentPreflight,
        servers: [String: LiveMCPServer]
    ) async {
        resetSession()
        phase = .connecting
        sessionAgentName = agentName
        sessionTextOnly = textOnly
        self.servers = servers
        if !textOnly {
            guard await context.audio().requestMicrophone() else {
                phase = .ended
                outcome = .notStarted("The microphone is not allowed for this app. Allow it in System Settings → Privacy & Security → Microphone, or talk by text.")
                return
            }
            guard phase == .connecting else { return }
        }
        guard let realtime = context.realtime() else {
            phase = .ended
            outcome = .notStarted(ElevenLabsError.notLinked.description)
            return
        }
        let token = guardian.begin(client: realtime.client, work: self)
        var config = ElevenLabsAgentConversationConfig(agentID: agentID, auth: .automatic, textOnly: textOnly)
        config.userID = nil
        let conversation: ElevenLabsAgentConversation
        do {
            conversation = try await realtime.agentConversation(config, preflight: preflight)
        } catch {
            if guardian.isCurrent(token) { end(LiveOutcome.failedToStart(error), closing: false) }
            return
        }
        guard guardian.isCurrent(token), phase == .connecting else {
            await conversation.end()
            return
        }
        self.conversation = conversation
        conversationID = conversation.startedWith?.conversationID
        phase = .live
        Task { await consume(conversation, token: token) }
        Task { await watch(token: token) }
        guard !textOnly, let metadata = conversation.startedWith else { return }
        if let output = metadata.outputEncoding {
            playback = LivePlayback(audio: context.audio(), encoding: output)
        }
        guard let input = metadata.inputEncoding,
              let converter = LiveCaptureConverter(target: input, chunkMilliseconds: 100)
        else {
            note("The agent asked for \(metadata.userInputAudioFormat), which this app cannot send; talk by text instead.")
            return
        }
        self.converter = converter
        converter.muted = muted
        let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.chunks = continuation
        sender = Task.detached { for await chunk in chunks { try? await conversation.sendAudio(chunk) } }
        do {
            try context.audio().startCapture(echoCancellation: true) { buffer in
                for chunk in converter.process(buffer) { continuation.yield(chunk) }
            }
            microphoneOn = true
        } catch {
            note("The microphone could not start (\(ElevenLabsRedaction.redact(error.localizedDescription))); talk by text instead.")
        }
    }

    // MARK: During

    /// Sends the text box as something said. Only while a conversation is open: Return in the
    /// box never starts one.
    func sendMessage() async {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .live, let conversation, !text.isEmpty else { return }
        message = ""
        let token = guardian.token
        // On screen before it goes, so the agent's answer always comes after it.
        let line = append(.user, text)
        do {
            try await conversation.sendUserMessage(text)
        } catch {
            guard guardian.isCurrent(token) else { return }
            lines.removeAll { $0.id == line }
            message = text
            note("The message was not sent: \(ElevenLabsRealtimeError(wrapping: error).description)")
        }
    }

    /// Stops the agent's voice here and now. ElevenLabs is not told (the protocol has no such
    /// message); the rest of that answer is simply not played. Speaking stops it there too.
    func interrupt() {
        guard phase == .live else { return }
        playback?.interrupt()
        silencedThrough = lastAgentEventID
        if let index = lines.lastIndex(where: { $0.role == .agent }) { lines[index].interrupted = true }
    }

    /// Answers the approval the owner pressed — for the conversation and tool call it was asked
    /// with, never whatever is on screen by the time the answer lands.
    func answer(_ approvalID: String, session: UUID, approved: Bool) async {
        guard let index = approvals.firstIndex(where: { $0.id == approvalID && $0.session == session }),
              approvals[index].state == .waiting
        else { return }
        guard guardian.isCurrent(session), phase == .live, let conversation else {
            approvals[index].state = .declined("the conversation had ended")
            return
        }
        guard now < approvals[index].deadline else {
            await expire(approvalID, session: session)
            return
        }
        approvals[index].state = .sending
        let sent = await conversation.answerApproval(approvalID, approved: approved)
        guard let after = approvals.firstIndex(where: { $0.id == approvalID && $0.session == session }) else { return }
        approvals[after].state = sent ? (approved ? .approved : .declined("by you")) : .movedOn
    }

    /// Likes or dislikes an agent answer (or clears it).
    func rate(_ lineID: Int, liked: Bool?) async {
        guard phase == .live, let conversation,
              let index = lines.firstIndex(where: { $0.id == lineID }), let eventID = lines[index].eventID
        else { return }
        let token = guardian.token
        do {
            try await conversation.sendFeedback(eventID: eventID, liked: liked)
            guard guardian.isCurrent(token), let after = lines.firstIndex(where: { $0.id == lineID }) else { return }
            lines[after].liked = liked
        } catch {}
    }

    // MARK: Ending

    /// Ends the conversation: every approval still waiting is declined (sent), the microphone
    /// goes off, the socket closes, and the transcript is saved.
    func end() async {
        switch phase {
        case .live:
            let closing = conversation
            phase = .ending
            stopMicrophone()
            await closing?.end()
            // The socket's end arrives through `consume`, which finishes the session.
        case .connecting, .preparing, .asking:
            cancelStart()
        default:
            break
        }
    }

    /// Leaving the screen ends the conversation: nothing keeps listening where it cannot be seen.
    func leave() {
        guard isBusy else { return }
        if phase == .preparing || phase == .asking {
            cancelStart()
            return
        }
        end(.ended(LiveOutcome.leftScreen), closing: true)
    }

    func endForAccountChange() -> Bool {
        if phase == .preparing || phase == .asking {
            cancelStart()
            return false
        }
        guard isOpen else { return false }
        end(.mayHaveBeenBilled(LiveOutcome.accountChanged), closing: true)
        return true
    }

    func tick() {
        now = Date()
        if let conversation { usage = conversation.usage }
        level = converter?.level ?? 0
        if phase == .live || phase == .ending, !guardian.accountIsCurrent { _ = endForAccountChange() }
        let session = guardian.token
        for approval in approvals where approval.state == .waiting && approval.session == session && now >= approval.deadline {
            Task { await expire(approval.id, session: session) }
        }
    }

    /// ElevenLabs stopped waiting: the decline is sent anyway, so it never hears silence.
    private func expire(_ approvalID: String, session: UUID) async {
        guard let index = approvals.firstIndex(where: { $0.id == approvalID && $0.session == session }),
              approvals[index].state == .waiting
        else { return }
        approvals[index].state = .sending
        _ = await conversation?.answerApproval(approvalID, approved: false)
        guard let after = approvals.firstIndex(where: { $0.id == approvalID && $0.session == session }) else { return }
        approvals[after].state = .declined("it timed out")
    }

    /// Ends the session here. `closing` ends the conversation on the socket too — declining every
    /// approval still waiting first.
    private func end(_ outcome: LiveOutcome, closing: Bool) {
        if let conversation { usage = conversation.usage }
        let closingConversation = closing ? conversation : nil
        stopMicrophone()
        playback?.interrupt()
        for index in approvals.indices where approvals[index].state == .waiting || approvals[index].state == .sending {
            approvals[index].state = .declined("the conversation ended")
        }
        conversation = nil
        playback = nil
        question = nil
        self.outcome = outcome
        phase = .ended
        guardian.end()
        if let closingConversation { Task { await closingConversation.end() } }
        Task { await saveTranscript() }
    }

    private func stopMicrophone() {
        if microphoneOn { context.audio().stopCapture() }
        microphoneOn = false
        chunks?.finish()
        chunks = nil
        sender?.cancel()
        sender = nil
        converter = nil
        level = 0
    }

    // MARK: Events

    private func consume(_ conversation: ElevenLabsAgentConversation, token: UUID) async {
        for await event in conversation.events {
            guard guardian.isCurrent(token) else {
                continue
            }
            handle(event, token: token)
        }
    }

    private func handle(_ event: ElevenLabsAgentEvent, token: UUID) {
        switch event {
        case .started(let metadata):
            conversationID = metadata.conversationID
        case .audio(let data, let eventID, _, _):
            if let eventID { lastAgentEventID = max(lastAgentEventID ?? eventID, eventID) }
            if let eventID, let silenced = silencedThrough, eventID <= silenced { return }
            playback?.append(data)
        case .interruption:
            // The owner spoke over the agent: stop now; the session drops the rest of that answer.
            playback?.interrupt()
            if let index = lines.lastIndex(where: { $0.role == .agent }) { lines[index].interrupted = true }
        case .userTranscript(let text, let eventID):
            if let index = lines.lastIndex(where: { $0.role == .user && $0.tentative }) {
                lines[index].text = text
                lines[index].tentative = false
                lines[index].eventID = eventID
            } else {
                append(.user, text, eventID: eventID)
            }
        case .tentativeUserTranscript(let text, let eventID):
            if let index = lines.lastIndex(where: { $0.role == .user && $0.tentative }) {
                lines[index].text = text
            } else {
                append(.user, text, eventID: eventID, tentative: true)
            }
        case .agentResponse(let text, let eventID, _):
            if let eventID { lastAgentEventID = max(lastAgentEventID ?? eventID, eventID) }
            if let index = lines.lastIndex(where: { $0.role == .agent && $0.tentative }) {
                lines[index].text = text
                lines[index].tentative = false
                lines[index].eventID = eventID
            } else {
                append(.agent, text, eventID: eventID)
            }
        case .agentResponseCorrection(_, let corrected, _):
            if let index = lines.lastIndex(where: { $0.role == .agent }) {
                lines[index].text = corrected
                lines[index].interrupted = true
            }
        case .agentResponsePart(let text, let kind, let eventID, _):
            switch kind {
            case "start":
                append(.agent, text, eventID: eventID, tentative: true)
            case "stop":
                if let index = lines.lastIndex(where: { $0.role == .agent && $0.tentative }) {
                    lines[index].text += text
                    lines[index].tentative = false
                }
            default:
                if let index = lines.lastIndex(where: { $0.role == .agent && $0.tentative }) {
                    lines[index].text += text
                } else {
                    append(.agent, text, eventID: eventID, tentative: true)
                }
            }
        case .clientToolCall(let call):
            // This app runs no client tools: it says so, and nothing runs.
            Task {
                try? await conversation?.answerClientTool(
                    call.toolCallID, result: "This app has no client tool named \(call.toolName); nothing was run.",
                    errorType: "user_rejected"
                )
            }
            append(.tool, "The agent asked this Mac to run “\(call.toolName)”. This app runs no client tools, so it answered that nothing ran.")
        case .agentToolRequest(let activity):
            toolLine(activity, text: "Running “\(activity.toolName)”\(activity.toolType.map { " (\($0))" } ?? "") on ElevenLabs' side…")
        case .agentToolResponse(let activity):
            let status = activity.status ?? (activity.isError == true ? "error" : "done")
            toolLine(activity, text: "“\(activity.toolName)”\(activity.toolType.map { " (\($0))" } ?? "") ran on ElevenLabs' side: \(status).")
        case .mcpToolCall(let call):
            mcp(call, token: token)
        case .queueStatus(let status):
            queueStatus = status
            switch status {
            case "waiting": note("Waiting in the agent's call queue…")
            case "admitted": note("Admitted from the call queue.")
            case "timed_out": note("The call queue timed out.")
            default: break
            }
        case .error(let error):
            note("ElevenLabs reported \(error.name ?? "an error")\(error.code.map { " (\($0))" } ?? ""): \(error.message)")
        case .guardrailTriggered(let name):
            note("A guardrail\(name.map { " (\($0))" } ?? "") ended the agent's answer.")
        case .ended(let close):
            switch close.kind {
            case .normal:
                let who = phase == .ending ? "You ended the conversation." : "The agent ended the conversation."
                end(.ended("\(who) " + summary()), closing: false)
            case .queueTimedOut:
                end(.mayHaveBeenBilled("The agent's call queue timed out (4300). " + summary()), closing: false)
            case .error:
                end(.mayHaveBeenBilled("The conversation ended early: \(close.description). It may have been billed; it is not reconnected."), closing: false)
            }
        case .ping, .vadScore, .contextUsage, .agentResponseComplete, .agentResponseMetadata, .mcpConnectionStatus,
             .other, .unknown:
            break
        }
    }

    private func mcp(_ call: ElevenLabsMCPToolCall, token: UUID) {
        let server = call.serviceID.flatMap { servers[$0] }
        if call.isAwaitingApproval {
            guard !approvals.contains(where: { $0.id == call.toolCallID && $0.session == token }) else { return }
            approvals.append(Approval(
                id: call.toolCallID, session: token, agentName: sessionAgentName ?? "The agent",
                toolName: call.toolName, toolDescription: call.toolDescription,
                serverName: server?.name ?? "an MCP server (\(call.serviceID ?? "no id"))",
                serverHost: server?.host, parameters: call.parameters,
                deadline: now.addingTimeInterval(call.approvalTimeout ?? Self.defaultApprovalTimeout)
            ))
            append(.tool, "“\(call.toolName)” on \(server?.name ?? "an MCP server") asks for your approval.")
        } else {
            if let index = approvals.firstIndex(where: { $0.id == call.toolCallID && $0.session == token }),
               approvals[index].state == .waiting || approvals[index].state == .sending {
                approvals[index].state = .movedOn
            }
            let detail = call.state == "failure" ? ": failed — \(call.errorMessage ?? "no reason given")" : ": \(call.state)"
            append(.tool, "MCP tool “\(call.toolName)”\(detail).")
        }
    }

    private func toolLine(_ activity: ElevenLabsAgentToolActivity, text: String) {
        if let id = activity.toolCallID, let lineID = toolLines[id], let index = lines.firstIndex(where: { $0.id == lineID }) {
            lines[index].text = text
        } else {
            let id = append(.tool, text)
            if let callID = activity.toolCallID { toolLines[callID] = id }
        }
    }

    private func watch(token: UUID) async {
        while guardian.isCurrent(token) {
            tick()
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: Small things

    @discardableResult
    private func append(_ role: Line.Role, _ text: String, eventID: Int? = nil, tentative: Bool = false) -> Int {
        let id = nextLineID
        nextLineID += 1
        lines.append(Line(id: id, role: role, text: text, eventID: eventID, tentative: tentative))
        if lines.count > 1_000 { lines.removeFirst(lines.count - 1_000) }
        return id
    }

    private func note(_ text: String) {
        append(.system, text)
    }

    private func resetSession() {
        lines = []
        approvals = []
        outcome = nil
        usage = nil
        conversationID = nil
        queueStatus = nil
        savedTranscript = nil
        silencedThrough = nil
        lastAgentEventID = nil
        toolLines = [:]
    }

    private func summary() -> String {
        let length = LiveClock.text(usage?.duration() ?? 0)
        return "It lasted \(length) — ElevenLabs bills agent conversations by their length."
    }

    /// Saves the transcript to the output folder once the conversation is over. ElevenLabs keeps
    /// the conversation too (Conversations, by its id).
    private func saveTranscript() async {
        guard !lines.isEmpty, let sink = context.sink() else { return }
        var text = "Conversation with \(sessionAgentName ?? "an agent")"
        if let conversationID { text += " (\(conversationID))" }
        text += "\n\n" + lines.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n") + "\n"
        savedTranscript = try? await LiveFiles.write(
            Data(text.utf8), name: "agent-conversation", ext: "txt", contentType: "text/plain",
            operation: ElevenLabsLiveOperations.conversation, sink: sink
        )
    }

    static func describe(_ tool: ElevenLabsAgentToolSummary, servers: [String: LiveMCPServer]) -> String {
        switch tool.kind {
        case .webhook: "“\(tool.name)” calls \(tool.host ?? "an outside address")"
        case .integration: "“\(tool.name)” uses a connected account"
        case .system:
            switch tool.name {
            case "transfer_to_number": "can transfer the call to a phone number"
            case "transfer_to_agent": "can hand the conversation to another agent"
            case "play_keypad_touch_tone": "can press phone keypad tones"
            case "voicemail_detection": "can leave a voicemail"
            default: "“\(tool.name)”"
            }
        case .mcp:
            if let host = tool.host, let server = servers[host] {
                "\(tool.name.hasPrefix("tools of") ? "the tools of" : "“\(tool.name)” on") the MCP server “\(server.name)”\(server.host.map { " at \($0)" } ?? "")"
            } else {
                "“\(tool.name)” on an MCP server\(tool.host.map { " (\($0))" } ?? "")"
            }
        case .workspace: "a workspace tool (\(tool.name)) whose address this screen cannot see"
        case .client, .other: "“\(tool.name)”"
        }
    }
}

/// An MCP server as an approval names it: its name and the host it lives on — nothing else of
/// its settings (they can hold its token and headers) is kept.
struct LiveMCPServer: Equatable, Sendable {
    var name: String
    var host: String?

    /// `GET /v1/convai/mcp-servers` (free), by id. Empty when it cannot be read: approvals then
    /// name the server by its id.
    static func list(with client: ElevenLabsClient) async -> [String: LiveMCPServer] {
        guard let answer = try? ElevenLabsClient.json(await client.call("list_mcp_servers_route")) else { return [:] }
        var servers: [String: LiveMCPServer] = [:]
        for server in answer["mcp_servers"].arrayValue ?? [] {
            guard let id = server["id"].stringValue else { continue }
            let url = server["config"]["url"].stringValue
            servers[id] = LiveMCPServer(
                name: server["config"]["name"].stringValue ?? id,
                host: url.flatMap { URL(string: $0)?.host }
            )
        }
        return servers
    }
}
