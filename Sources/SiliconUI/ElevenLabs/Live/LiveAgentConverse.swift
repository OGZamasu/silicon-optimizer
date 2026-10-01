import Foundation
import SiliconControl
import SiliconElevenLabs

// MARK: - The app's answer to POST /elevenlabs/agents/converse

extension AppModel {
    /// A text-only conversation with an agent, for the control API and MCP. The server has
    /// already made sure the caller is this Mac's own control token on loopback.
    func elevenLabsAgentConverse(_ body: Data) async -> ElevenLabsControlResponse {
        let realtime = elevenLabsLinked
            ? elevenLabsClient.map { ElevenLabsRealtime(client: $0, connector: elevenLabsSocketConnector) }
            : nil
        let handler = ElevenLabsConverseHandler(
            state: .init(linked: elevenLabsLinked, allowRiskyForAgents: elevenLabsAllowRiskyForAgents),
            realtime: realtime
        )
        return await handler.handle(body)
    }
}

/// Everything `POST /elevenlabs/agents/converse` does past the caller policy.
///
/// The order is the point, as for `/elevenlabs/call`: read the request, apply the gate (an agent
/// can run server tools that act in the real world, so the route is `realWorld`: `confirm: true`
/// and the owner's switch), check the link, read the agent (free), and only then open a socket.
/// A refusal at any step means nothing after it happened.
///
/// During the conversation nothing that needs the owner is done for them: an MCP tool approval
/// is declined (a decline is sent, never silence), and a client tool call is answered that
/// nothing ran. Server tools run on ElevenLabs' side and are reported. The answer carries the
/// transcript and the tools, never a signed URL, a token or anything key-shaped.
struct ElevenLabsConverseHandler: Sendable {
    struct State: Sendable {
        var linked: Bool
        /// The owner's `ElevenLabsControl.riskySwitch`.
        var allowRiskyForAgents: Bool
    }

    struct Timing: Sendable {
        /// How long to wait for the agent's greeting before the first message.
        var greeting: Duration = .seconds(4)
        /// Quiet after an answer before the next message (tool calls, a second message).
        var settle: Duration = .milliseconds(1_500)
        /// The longest an answer may take.
        var turn: Duration = .seconds(ElevenLabsControl.converseTurnSeconds)
    }

    var state: State
    /// Nil when nothing is linked.
    var realtime: ElevenLabsRealtime?
    var timing = Timing()

    static let operationName = "agent_converse"

    func handle(_ body: Data) async -> ElevenLabsControlResponse {
        let request: ConverseRequest
        switch ConverseRequest.parse(body) {
        case .success(let parsed): request = parsed
        case .failure(let problems):
            return .refusal(400, .init(
                error: "The conversation was not started: " + problems.list.joined(separator: " "),
                operation: Self.operationName, problems: problems.list
            ))
        }
        if let refusal = gate(confirmed: request.confirm) { return refusal }
        guard state.linked, let realtime else {
            return .refusal(409, .init(error: ElevenLabsControl.notConnected, operation: Self.operationName))
        }
        var config = ElevenLabsAgentConversationConfig(agentID: request.agentID, auth: .automatic, textOnly: true)
        config.overrides = request.overrides
        config.dynamicVariables = request.dynamicVariables
        let problems = config.problems()
        guard problems.isEmpty else {
            return .refusal(400, .init(error: "The conversation was not started: " + problems.joined(separator: " "),
                                       operation: Self.operationName, problems: problems))
        }

        let preflight: ElevenLabsAgentPreflight
        do {
            preflight = try await realtime.agentPreflight(agentID: request.agentID)
        } catch {
            return Self.refusal(for: error)
        }
        let conversation: ElevenLabsAgentConversation
        do {
            conversation = try await realtime.agentConversation(config, preflight: preflight)
        } catch {
            return Self.refusal(for: error)
        }
        let log = ConverseLog()
        return await withTaskCancellationHandler {
            await converse(request, on: conversation, preflight: preflight, log: log)
        } onCancel: {
            Task { await conversation.end() }
        }
    }

    // MARK: - The gate

    func gate(confirmed: Bool) -> ElevenLabsControlResponse? {
        let allowed = state.allowRiskyForAgents
        guard !(confirmed && allowed) else { return nil }
        let missing = switch (allowed, confirmed) {
        case (false, false): "Here the switch is off and the call did not say confirm: true."
        case (false, true): "Here the switch is off."
        default: "Here the call did not say confirm: true."
        }
        let message = "A conversation with an ElevenLabs agent is real-world: the agent can run its server "
            + "tools (webhooks, transfers, phone numbers) and it spends the owner's credits. An agent may start one "
            + "only with confirm: true, after the user has agreed to this conversation, and only while the owner "
            + "has turned on \"\(ElevenLabsControl.riskySwitch)\" in \(ElevenLabsControl.riskySwitchLocation) on the "
            + "Mac. \(missing) Nothing was sent."
        return .refusal(403, .init(
            error: message, operation: Self.operationName, risk: ElevenLabsRisk.realWorld.rawValue,
            summary: "A text conversation with an agent", setting: ElevenLabsControl.riskySwitch
        ))
    }

    // MARK: - The conversation

    private func converse(
        _ request: ConverseRequest, on conversation: ElevenLabsAgentConversation,
        preflight: ElevenLabsAgentPreflight, log: ConverseLog
    ) async -> ElevenLabsControlResponse {
        let reader = Task { await Self.read(conversation, into: log) }
        // The agent's greeting, if it has one.
        if await log.wait(within: timing.greeting, until: { $0.agentAnswers > 0 || $0.ended != nil }) {
            await log.waitForQuiet(timing.settle, within: timing.turn)
        }
        var note: String?
        var sent = 0
        for message in request.messages.prefix(request.turns) {
            if log.snapshot.ended != nil { break }
            let before = log.snapshot.agentAnswers
            do {
                try await conversation.sendUserMessage(message)
            } catch {
                note = "The conversation ended before every message was sent: \(ElevenLabsRealtimeError(wrapping: error).description)"
                break
            }
            sent += 1
            log.append(role: "user", text: message)
            let answered = await log.wait(within: timing.turn, until: { $0.agentAnswers > before || $0.ended != nil })
            if Task.isCancelled { break }
            guard answered else {
                note = "The agent did not answer within \(ElevenLabsControl.converseTurnSeconds) seconds, so the conversation was ended."
                break
            }
            await log.waitForQuiet(timing.settle, within: timing.turn)
        }
        let endedByAgent = log.snapshot.ended
        await conversation.end()
        await reader.value
        if Task.isCancelled {
            return .refusal(ElevenLabsControlHandler.cancelledStatus, .init(
                error: "The conversation was cancelled before it finished. ElevenLabs may have billed what ran; "
                    + "check the agent's Conversations before starting another.",
                operation: Self.operationName
            ))
        }
        return .init(status: 200, body: Self.answer(
            request: request, preflight: preflight, conversation: conversation, log: log.snapshot,
            sent: sent, endedByAgent: endedByAgent, note: note
        ).encoded())
    }

    /// Reads every event, answering what must be answered on the owner's behalf: approvals are
    /// declined and client tool calls told nothing ran.
    private static func read(_ conversation: ElevenLabsAgentConversation, into log: ConverseLog) async {
        for await event in conversation.events {
            switch event {
            case .agentResponse(let text, _, _):
                log.agentAnswered(text)
            case .agentResponseCorrection(_, let corrected, _):
                log.correctLastAgent(corrected)
            case .clientToolCall(let call):
                if call.expectsResponse != false {
                    try? await conversation.answerClientTool(
                        call.toolCallID, result: ElevenLabsControl.converseClientToolAnswer, errorType: "user_rejected"
                    )
                }
                log.tool(id: call.toolCallID, kind: "client", name: call.toolName, parameters: call.parameters,
                         handled: "answered that nothing ran (no client tools over MCP)")
            case .mcpToolCall(let call):
                var handled: String?
                if call.isAwaitingApproval {
                    let declined = await conversation.answerApproval(call.toolCallID, approved: false)
                    handled = declined ? ElevenLabsControl.converseApprovalDeclined : nil
                }
                log.tool(id: call.toolCallID, kind: "mcp", name: call.toolName, type: call.serviceID.map { "server \($0)" },
                         status: call.state, parameters: call.parameters, handled: handled)
            case .agentToolRequest(let activity), .agentToolResponse(let activity):
                log.tool(id: activity.toolCallID, kind: "server", name: activity.toolName, type: activity.toolType,
                         status: activity.status ?? (activity.isError == true ? "error" : nil), parameters: nil, handled: nil)
            case .error(let error):
                log.error(error)
            case .ended(let close):
                log.end(close)
            default:
                log.touch()
            }
        }
    }

    // MARK: - Answers

    static func answer(
        request: ConverseRequest, preflight: ElevenLabsAgentPreflight, conversation: ElevenLabsAgentConversation,
        log: ConverseLog.Snapshot, sent: Int, endedByAgent: ElevenLabsSocketClose?, note: String?
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "agent_id": .string(request.agentID),
            "transcript": .array(log.lines.map { ["role": .string($0.role), "text": .string(ElevenLabsRedaction.redact($0.text))] }),
            "tool_calls": .array(log.tools.map(\.json)),
            "messages_sent": .number(Double(sent)),
            "duration_seconds": .number((conversation.usage.duration() * 10).rounded() / 10),
            "cost_note": .string(ElevenLabsControl.converseCostNote),
        ]
        if let name = preflight.name { object["agent_name"] = .string(ElevenLabsRedaction.redact(name)) }
        if let id = conversation.startedWith?.conversationID { object["conversation_id"] = .string(id) }
        if !log.errors.isEmpty { object["errors"] = .array(log.errors) }
        if let endedByAgent {
            object["ended"] = .string(endedByAgent.kind == .normal
                ? "by the agent" : ElevenLabsRealtimeRedaction.scrub("by ElevenLabs: \(endedByAgent.description)"))
        } else {
            object["ended"] = .string("by this app, after the last message")
        }
        var notes: [String] = []
        if let note { notes.append(note) }
        if sent < request.messages.count, note == nil, endedByAgent == nil {
            notes.append("max_turns stopped it after \(sent) of \(request.messages.count) messages.")
        }
        if endedByAgent != nil, sent < request.turns {
            notes.append("It ended after \(sent) of \(request.turns) messages.")
        }
        if !notes.isEmpty { object["note"] = .string(ElevenLabsRealtimeRedaction.scrub(notes.joined(separator: " "))) }
        return .object(object)
    }

    /// A failure before the conversation started, as the caller may read it.
    static func refusal(for error: any Error) -> ElevenLabsControlResponse {
        let unknown = " It may have started on ElevenLabs' side and been billed; check the agent's Conversations before trying again."
        if let error = error as? ElevenLabsError {
            // The agent could not be read (REST): nothing was opened.
            let failure = ElevenLabsControlHandler.status(forUpstreamError: error)
            return .refusal(failure.status, .init(
                error: "The conversation was not started: " + ElevenLabsRealtimeRedaction.scrub(error.description),
                operation: operationName, upstreamStatus: failure.upstream
            ))
        }
        let realtime = ElevenLabsRealtimeError(wrapping: error)
        switch realtime {
        case .invalidConfiguration(let problems):
            return .refusal(409, .init(
                error: "The conversation was not started: " + problems.joined(separator: " "),
                operation: operationName, problems: problems
            ))
        case .notLinked:
            return .refusal(409, .init(error: ElevenLabsControl.notConnected, operation: operationName))
        case .credentialUnavailable:
            return .refusal(503, .init(error: realtime.description + " The owner may need to answer the Keychain prompt on the Mac.",
                                       operation: operationName))
        case .signedLink(let inner):
            let failure = ElevenLabsControlHandler.status(forUpstreamError: inner)
            let serverSide = failure.upstream.map { $0 >= 500 } ?? true
            return .refusal(failure.status, .init(
                error: "The conversation was not started: its signed link could not be made (" + inner.description + ")."
                    + (serverSide ? unknown : ""),
                operation: operationName, upstreamStatus: failure.upstream
            ))
        case .refusedHost:
            return .refusal(502, .init(error: realtime.description + " Nothing was opened.", operation: operationName))
        case .cancelled:
            return .refusal(ElevenLabsControlHandler.cancelledStatus, .init(
                error: "The conversation was cancelled while it was starting." + unknown, operation: operationName
            ))
        case .timedOut:
            return .refusal(504, .init(error: realtime.description + "." + unknown, operation: operationName))
        default:
            return .refusal(502, .init(error: "The conversation did not start: " + realtime.description + unknown,
                                       operation: operationName))
        }
    }
}

extension ElevenLabsControlHandler {
    /// An `ElevenLabsError` as this route's status, and ElevenLabs' own status when it gave one.
    static func status(forUpstreamError error: ElevenLabsError) -> (status: Int, upstream: Int?) {
        switch error {
        case .api(let status, _, _, _): (Self.status(forUpstream: status), status)
        case .rateLimited: (429, 429)
        case .notLinked: (409, nil)
        case .credentialUnavailable: (503, nil)
        case .invalidArguments: (400, nil)
        case .cancelled: (cancelledStatus, nil)
        default: (502, nil)
        }
    }
}

// MARK: - The request

/// A converse body, checked field by field so every problem is named at once.
struct ConverseRequest: Sendable {
    var agentID: String
    var messages: [String]
    var overrides: JSONValue?
    var dynamicVariables: [String: JSONValue]
    /// How many of `messages` to send.
    var turns: Int
    var confirm: Bool

    struct Problems: Error {
        var list: [String]
    }

    static func parse(_ body: Data) -> Result<ConverseRequest, Problems> {
        let shape = "Send {\"agent_id\": …, \"messages\": [\"…\"], \"confirm\": true} as JSON."
        guard !body.isEmpty, let value = try? JSONValue.parse(body), case .object(let object) = value else {
            return .failure(Problems(list: ["The body must be a JSON object. " + shape]))
        }
        var problems: [String] = []
        let unknown = object.keys.filter { !ElevenLabsControl.converseFields.contains($0) }.sorted()
        if !unknown.isEmpty {
            problems.append("Unknown field\(unknown.count == 1 ? "" : "s") "
                + unknown.map { "\"\(ElevenLabsControlHandler.quoted($0))\"" }.joined(separator: ", ")
                + ": a conversation takes agent_id, messages, overrides, dynamic_variables, max_turns and confirm.")
        }
        let agentID = object["agent_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if agentID.isEmpty { problems.append("agent_id must name an agent, e.g. \"agent_…\".") }
        var messages: [String] = []
        if case .array(let items)? = object["messages"] {
            for (index, item) in items.enumerated() {
                guard let text = item.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    problems.append("messages[\(index)] must be a non-empty string.")
                    continue
                }
                if text.count > ElevenLabsControl.maximumConverseMessageLength {
                    problems.append("messages[\(index)] is longer than \(ElevenLabsControl.maximumConverseMessageLength) characters.")
                }
                messages.append(text)
            }
            if items.isEmpty { problems.append("messages must hold at least one message.") }
            if items.count > ElevenLabsControl.maximumConverseMessages {
                problems.append("At most \(ElevenLabsControl.maximumConverseMessages) messages in one conversation.")
            }
        } else {
            problems.append("messages must be a list of strings, the user's side of the conversation.")
        }
        var overrides: JSONValue?
        switch object["overrides"] {
        case nil, .null?: break
        case .object(let given)?:
            overrides = .object(given)
            if given["conversation"]?.objectValue?["text_only"] != nil {
                problems.append("overrides.conversation.text_only cannot be set: this conversation is always text-only.")
            }
        default: problems.append("overrides must be an object of conversation_config_override sections.")
        }
        var variables: [String: JSONValue] = [:]
        switch object["dynamic_variables"] {
        case nil, .null?: break
        case .object(let given)?:
            for (name, value) in given {
                switch value {
                case .string, .number, .bool: variables[name] = value
                default: problems.append("dynamic_variables.\(ElevenLabsControlHandler.quoted(name)) must be a string, number or boolean.")
                }
            }
        default: problems.append("dynamic_variables must be an object of names to values.")
        }
        var turns = messages.count
        switch object["max_turns"] {
        case nil, .null?: break
        case .number(let number)? where number.isFinite && number.rounded() == number
            && (1...Double(ElevenLabsControl.maximumConverseMessages)).contains(number):
            turns = min(messages.count, Int(number))
        default: problems.append("max_turns must be a whole number from 1 to \(ElevenLabsControl.maximumConverseMessages).")
        }
        var confirm = false
        switch object["confirm"] {
        case nil, .null?: break
        case .bool(let given)?: confirm = given
        default: problems.append("confirm must be true or false.")
        }
        guard problems.isEmpty else { return .failure(Problems(list: problems)) }
        return .success(ConverseRequest(
            agentID: agentID, messages: messages, overrides: overrides, dynamicVariables: variables,
            turns: turns, confirm: confirm
        ))
    }
}

// MARK: - What happened

/// The conversation as it goes, written by the reader and read by the turn loop.
final class ConverseLog: @unchecked Sendable {
    struct Line: Sendable { var role: String; var text: String }

    struct Tool: Sendable {
        var id: String?
        var kind: String
        var name: String
        var type: String?
        var status: String?
        var parameters: JSONValue?
        var handled: String?

        var json: JSONValue {
            var object: [String: JSONValue] = ["kind": .string(kind), "name": .string(ElevenLabsRedaction.redact(name))]
            if let type { object["type"] = .string(type) }
            if let status { object["status"] = .string(status) }
            if let parameters, parameters != .null { object["parameters"] = ConverseLog.masked(parameters) }
            if let handled { object["handled"] = .string(handled) }
            if kind == "server" {
                object["note"] = "Ran on ElevenLabs' side; this app cannot stop or undo it."
            }
            return .object(object)
        }
    }

    struct Snapshot: Sendable {
        var lines: [Line] = []
        var tools: [Tool] = []
        var errors: [JSONValue] = []
        var agentAnswers = 0
        var lastEvent = ContinuousClock.now
        var ended: ElevenLabsSocketClose?
    }

    private let lock = NSLock()
    private var state = Snapshot()

    var snapshot: Snapshot { lock.withLock { state } }

    func append(role: String, text: String) {
        lock.withLock {
            state.lines.append(Line(role: role, text: text))
            state.lastEvent = .now
        }
    }

    func agentAnswered(_ text: String) {
        lock.withLock {
            state.lines.append(Line(role: "agent", text: text))
            state.agentAnswers += 1
            state.lastEvent = .now
        }
    }

    func correctLastAgent(_ text: String) {
        lock.withLock {
            if let index = state.lines.lastIndex(where: { $0.role == "agent" }) { state.lines[index].text = text }
            state.lastEvent = .now
        }
    }

    func tool(id: String?, kind: String, name: String, type: String? = nil, status: String? = nil,
              parameters: JSONValue?, handled: String?) {
        lock.withLock {
            if let id, let index = state.tools.firstIndex(where: { $0.id == id && $0.kind == kind }) {
                if let type { state.tools[index].type = type }
                if let status { state.tools[index].status = status }
                if let handled { state.tools[index].handled = handled }
            } else {
                state.tools.append(Tool(id: id, kind: kind, name: name, type: type, status: status,
                                        parameters: parameters, handled: handled))
            }
            state.lastEvent = .now
        }
    }

    func error(_ error: ElevenLabsAgentError) {
        var object: [String: JSONValue] = ["message": .string(ElevenLabsRealtimeRedaction.scrub(error.message))]
        if let code = error.code { object["code"] = .number(Double(code)) }
        if let name = error.name { object["name"] = .string(name) }
        lock.withLock {
            state.errors.append(.object(object))
            state.lastEvent = .now
        }
    }

    func end(_ close: ElevenLabsSocketClose) {
        lock.withLock { if state.ended == nil { state.ended = close } }
    }

    func touch() {
        lock.withLock { state.lastEvent = .now }
    }

    /// Waits until `condition` holds or `within` passes; true when it held.
    func wait(within: Duration, until condition: (Snapshot) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + within
        while !condition(snapshot) {
            if ContinuousClock.now >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    /// Waits until nothing has happened for `quiet`, the conversation ends, or `within` passes.
    func waitForQuiet(_ quiet: Duration, within: Duration) async {
        let deadline = ContinuousClock.now + within
        while ContinuousClock.now < deadline, !Task.isCancelled {
            let current = snapshot
            if current.ended != nil || ContinuousClock.now - current.lastEvent >= quiet { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Tool parameters as an agent over MCP may see them: fields named like secrets masked, and
    /// anything key-shaped in any string.
    static func masked(_ value: JSONValue) -> JSONValue {
        func scrub(_ value: JSONValue) -> JSONValue {
            switch value {
            case .string(let text): .string(ElevenLabsRedaction.redact(text))
            case .array(let items): .array(items.map(scrub))
            case .object(let object): .object(object.mapValues(scrub))
            case .null, .bool, .number: value
            }
        }
        return scrub(ElevenLabsControlHandler.maskSecretFields(value))
    }
}
