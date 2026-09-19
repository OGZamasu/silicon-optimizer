import Foundation
import SiliconControl
import SiliconRuntime

/// The Pi engine: the app drives Pi's RPC mode natively — prompt in, JSONL events
/// out — and renders its own transcript, the Codex pattern. The silicon extension
/// (written into Pi's workspace at start) supplies every gateway model and mirrors
/// the app's whole MCP toolbox as native Pi tools.
extension AppModel {

    /// One entry in the Pi transcript.
    @Observable
    public final class PiItem: Identifiable {
        public enum Kind: Equatable {
            case user
            case assistant
            case thinking
            case tool(name: String)
            case notice
            /// A tool call held at the guardrail. `requestID` is the
            /// `extension_ui_request` id the answer has to quote.
            case approval(requestID: String, tool: String)
        }

        public let id = UUID()
        public let kind: Kind
        public var text: String
        public var running: Bool
        /// What Jev made of the call this entry is about. Set on a `.tool` entry that was
        /// screened and allowed, and on every `.approval` entry.
        public var screening: GuardrailScreening?
        /// Whether an approval card has been answered. The card stays in the transcript —
        /// a decision is part of the history — but its buttons go away.
        public var answered = false
        /// What the answer was, once there is one. The card says which, because "answered"
        /// leaves the reader to guess the one thing they came back to find out.
        public var allowed: Bool?
        /// Pi's own id for the tool call this entry is about. How a verdict finds its row
        /// when two calls to the same tool are in flight at once.
        public var callID: String?

        init(
            kind: Kind, text: String, running: Bool = false,
            screening: GuardrailScreening? = nil, callID: String? = nil
        ) {
            self.kind = kind
            self.text = text
            self.running = running
            self.screening = screening
            self.callID = callID
        }
    }

    func startPiIfNeeded() {
        guard case .idle = piState else { return }
        restartPi()
    }

    func restartPi() {
        piState = .starting("Preparing the workspace…")
        piItems.removeAll()
        piBusy = false
        let runtime = piRuntime ?? PiRuntime()
        piRuntime = runtime

        let workspace = PiRuntime.workspaceDirectory
        let gatewayPort = gatewayPort()
        let defaultModel = settings.piModel
            ?? autoSelectableGatewayModels().first(where: \.serving)?.id
            ?? autoSelectableGatewayModels().first?.id
        do {
            try PiRuntime.ensureConfigured(
                workspace: workspace,
                defaultModel: defaultModel,
                extensionSource: PiRuntime.locateExtension()
            )
        } catch {
            piState = .failed("Could not write Pi's configuration: "
                + "\(error.localizedDescription)")
            return
        }

        piEventTask?.cancel()
        piEventTask = Task { [weak self] in
            guard let self else { return }
            let events = await runtime.start(
                gatewayPort: gatewayPort, gatewayToken: gatewayToken,
                mcpServerPath: CodexRuntime.locateMCPServer(),
                nodePath: self.settings.nodeBinaryPath ?? "",
                onState: { state in
                    Task { @MainActor [weak self] in
                        self?.applyPiRuntimeState(state)
                    }
                }
            )
            guard let events else { return }
            // Pin the session to the chosen gateway model even when a stale
            // workspace setting disagrees.
            if let defaultModel {
                self.piCurrentModel = defaultModel
                self.piSend(["type": "set_model", "provider": "silicon",
                             "modelId": defaultModel])
            }
            for await line in events {
                guard let data = line.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data)
                        as? [String: Any]
                else { continue }
                self.handlePiEvent(event)
            }
        }
    }

    func stopPi() {
        piEventTask?.cancel()
        piEventTask = nil
        let runtime = piRuntime
        piRuntime = nil
        piState = .idle
        Task { await runtime?.stop() }
    }

    private func applyPiRuntimeState(_ state: PiRuntime.State) {
        switch state {
        case .idle: piState = .idle
        case .starting(let stage): piState = .starting(stage)
        case .ready: piState = .ready
        case .stopping: piState = .stopping
        case .failed(let message): piState = .failed(message)
        }
    }

    // MARK: - Actions

    /// Encodes and ships one RPC command to Pi.
    func piSend(_ command: [String: Any]) {
        guard let runtime = piRuntime,
              let data = try? JSONSerialization.data(withJSONObject: command),
              let line = String(data: data, encoding: .utf8)
        else { return }
        Task { await runtime.send(line: line) }
    }


    func sendPiMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, piRuntime != nil else { return }
        piItems.append(PiItem(kind: .user, text: trimmed))
        var command: [String: Any] = ["type": "prompt", "message": trimmed]
        if piBusy {
            // Mid-stream, the protocol demands a choice; steering matches what a
            // user typing into a busy agent means.
            command["streamingBehavior"] = "steer"
        }
        piSend(command)
    }

    func abortPi() {
        // Answer anything the guardrail is holding first. An abort that leaves a dialog
        // open leaves the extension waiting on an answer that is never coming.
        for item in piItems where !item.answered {
            guard case .approval(let requestID, _) = item.kind else { continue }
            item.answered = true
            item.allowed = false
            item.running = false
            piSend(["type": "extension_ui_response", "id": requestID, "cancelled": true])
        }
        piSend(["type": "abort"])
    }

    // MARK: - Guardrails

    /// One tool call Pi is holding at the gate.
    ///
    /// Pi's RPC protocol has no permission request of its own: a client is told that a tool
    /// ran, not asked whether it may. The gate is installed from the extension this app
    /// writes into Pi's workspace, whose `tool_call` handler blocks the call and asks
    /// through `ctx.ui.confirm` — which in RPC mode is an `extension_ui_request` on stdout
    /// waiting for an `extension_ui_response` on stdin. So this is a real pre-execution
    /// gate, and a refusal here means the tool does not run.
    struct PiGuardrailRequest {
        /// The title the extension's dialog carries, matched exactly. The other half of
        /// this constant is `GUARDRAIL_MARKER` in `Resources/pi-silicon/silicon.ts`.
        static let marker = "silicon.guardrail.v1"

        var requestID: String
        var tool: String
        var arguments: String
        /// Pi's own id for the call, so the verdict can find its transcript row.
        var callID: String?
    }

    /// Routes one `extension_ui_request`.
    ///
    /// Ours is answered by the guardrail. Anything else that blocks — a dialog from a
    /// global Pi extension the user installed themselves — is answered `cancelled` rather
    /// than ignored: this app has no dialog surface for it, and an unanswered dialog stops
    /// the turn forever.
    private func handlePiExtensionUIRequest(_ event: [String: Any]) {
        guard let id = event["id"] as? String else { return }
        let method = event["method"] as? String ?? ""

        guard method == "confirm",
              event["title"] as? String == PiGuardrailRequest.marker
        else {
            if ["select", "confirm", "input", "editor"].contains(method) {
                piSend(["type": "extension_ui_response", "id": id, "cancelled": true])
            }
            return
        }

        let call = Self.parsePiGuardrailRequest(event["message"] as? String ?? "")
        Task {
            await screenPiToolCall(PiGuardrailRequest(
                requestID: id, tool: call.tool, arguments: call.arguments,
                callID: call.callID
            ))
        }
    }

    /// The extension sends `{v, tool, toolCallId, arguments}` as the dialog's message.
    /// A payload that will not parse is screened as-is rather than waved through.
    static func parsePiGuardrailRequest(
        _ payload: String
    ) -> (tool: String, arguments: String, callID: String?) {
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return ("tool", payload, nil) }
        let tool = object["tool"] as? String ?? "tool"
        let callID = object["toolCallId"] as? String
        guard let raw = object["arguments"],
              let encoded = try? JSONSerialization.data(
                withJSONObject: raw, options: [.sortedKeys, .fragmentsAllowed]
              )
        else { return (tool, "", callID) }
        return (tool, String(decoding: encoded, as: UTF8.self), callID)
    }

    /// Screens one held call and answers the extension.
    ///
    /// The card goes up *before* the screening starts, empty, and fills in when the verdict
    /// lands. Two reasons, and they are the same two as on the Codex side: the person can
    /// answer at once instead of waiting on a round trip, and a call that is being held
    /// appears in the transcript as a call that is being held — the in-flight list is the
    /// transcript, which is what lets `abortPi` answer every one of them.
    ///
    /// The three-way rule is the Codex hook's, for the same reason: `.confirm` is what a
    /// person is for, and a screening that could not happen is not a yes.
    func screenPiToolCall(
        _ request: PiGuardrailRequest, using service: JevService = .shared
    ) async {
        // Off means off. Pi ran unattended before this feature existed, and a guardrail
        // nobody switched on must not start holding tool calls.
        guard await JevGuardrails.isTurnedOn(using: service) else {
            answerPiGuardrail(request.requestID, allow: true)
            return
        }

        let card = PiItem(
            kind: .approval(requestID: request.requestID, tool: request.tool),
            text: request.arguments, running: true, callID: request.callID
        )
        piItems.append(card)

        let autoApprove = await service.settings().autoApproveSafeToolCalls
        let screening = await JevGuardrails.screen(
            engine: .pi,
            request: lastPiUserMessage(),
            userIntent: lastSubstantivePiRequest(),
            tool: request.tool,
            arguments: request.arguments,
            workingDirectory: PiRuntime.workspaceDirectory.path,
            recentTranscript: recentPiToolResults(),
            protecting: [PiRuntime.configurationDirectory.path],
            autoApproveArmed: autoApprove,
            using: service
        )
        card.screening = screening

        // They may have answered while the request was in flight. Their decision stands.
        guard !card.answered else { return }

        if autoApprove, let verdict = screening.verdict {
            switch verdict {
            case .act:
                markPiToolCall(request.callID, with: screening)
                answerPiApproval(card, allow: true, silently: true)
                return
            case .block:
                answerPiApproval(card, allow: false, silently: true)
                return
            case .confirm:
                break
            }
        }
        card.running = false
    }

    /// The buttons on the approval card, and the auto-answer path.
    ///
    /// - Parameter silently: true when the guardrail answered rather than the person. The
    ///   card records which either way; `silently` only decides whether the transcript also
    ///   gets a line saying so.
    public func answerPiApproval(_ item: PiItem, allow: Bool, silently: Bool = false) {
        guard case .approval(let requestID, _) = item.kind, !item.answered else { return }
        item.answered = true
        item.allowed = allow
        item.running = false
        answerPiGuardrail(requestID, allow: allow)
        guard silently, let screening = item.screening else { return }
        piItems.append(PiItem(
            kind: .notice,
            text: allow
                ? "Allowed automatically — \(screening.summary)."
                : "Blocked automatically — \(screening.summary).",
            screening: screening
        ))
    }

    private func answerPiGuardrail(_ requestID: String, allow: Bool) {
        piSend(["type": "extension_ui_response", "id": requestID, "confirmed": allow])
    }

    /// Puts the verdict on the transcript entry for a call that was allowed without asking,
    /// so "it ran" and "it was screened" are visible in the same place.
    ///
    /// Keyed on Pi's own call id rather than the tool's name: two `bash` calls can be in
    /// flight from one assistant message, and "the last running one with this name" would
    /// hang the second call's verdict on the first call's row.
    private func markPiToolCall(_ callID: String?, with screening: GuardrailScreening) {
        guard let callID else { return }
        piItems.last { $0.callID == callID }?.screening = screening
    }

    func lastPiUserMessage() -> String {
        piItems.last { $0.kind == .user }?.text ?? ""
    }

    /// The last message that actually asked for something — see the Codex side for why
    /// "thanks, that worked" must not become the goal every later call is judged against.
    func lastSubstantivePiRequest() -> String {
        piItems.last { $0.kind == .user && Self.isSubstantiveRequest($0.text) }?.text
            ?? lastPiUserMessage()
    }

    /// The last few finished tool results — where an injected instruction would have
    /// arrived. A running entry is this call's own arguments, not a result.
    func recentPiToolResults() -> [String] {
        piItems
            .filter { if case .tool = $0.kind { return !$0.running } else { return false } }
            .suffix(GuardrailState.maximumResults)
            .map(\.text)
    }

    func setPiModel(_ id: String) {
        guard piRuntime != nil else { return }
        settings.piModel = id
        settings.save()
        piCurrentModel = id
        piSend(["type": "set_model", "provider": "silicon", "modelId": id])
    }

    // MARK: - Event mapping

    /// Maps Pi's RPC events onto transcript items. Streaming text and thinking are
    /// appended to the newest item of their kind; tools get their own entries that
    /// resolve in place when execution ends.
    private func handlePiEvent(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "agent_start":
            piBusy = true
        case "agent_end", "agent_settled":
            piBusy = false
            for item in piItems where item.running { item.running = false }

        case "message_start":
            let role = (event["message"] as? [String: Any])?["role"] as? String
            if role == "assistant" {
                piStreamingItem = nil
                piThinkingItem = nil
            }

        case "message_update":
            guard let delta = event["assistantMessageEvent"] as? [String: Any],
                  let kind = delta["type"] as? String else { return }
            switch kind {
            case "text_delta":
                if let text = delta["delta"] as? String {
                    appendPiText(text, thinking: false)
                }
            case "thinking_delta":
                if let text = delta["delta"] as? String {
                    appendPiText(text, thinking: true)
                }
            case "toolcall_end":
                if let call = delta["toolCall"] as? [String: Any],
                   let name = call["name"] as? String {
                    piItems.append(PiItem(
                        kind: .tool(name: name),
                        text: Self.piToolSummary(call["arguments"]),
                        running: true,
                        callID: call["id"] as? String
                    ))
                }
            default:
                break
            }

        case "message_end":
            // The authoritative message replaces streamed assembly drift.
            if let message = event["message"] as? [String: Any],
               message["role"] as? String == "assistant" {
                let text = Self.piMessageText(message)
                if !text.isEmpty {
                    if let streaming = piStreamingItem {
                        streaming.text = text
                    } else {
                        piItems.append(PiItem(kind: .assistant, text: text))
                    }
                }
            }
            piStreamingItem = nil
            piThinkingItem = nil

        case "tool_execution_end":
            let name = event["toolName"] as? String ?? "tool"
            if let item = piItems.last(where: {
                $0.kind == .tool(name: name) && $0.running
            }) {
                item.running = false
                if let result = event["result"] as? [String: Any] {
                    let output = Self.piContentText(result["content"])
                    if !output.isEmpty {
                        item.text = output
                    }
                }
            }

        case "extension_ui_request":
            handlePiExtensionUIRequest(event)

        case "extension_error":
            let text = event["error"] as? String ?? "An extension failed."
            piItems.append(PiItem(kind: .notice, text: text))

        case "response":
            // Command responses: surface failures, absorb successes silently.
            if event["success"] as? Bool == false,
               let error = event["error"] as? String {
                piItems.append(PiItem(kind: .notice, text: error))
            }

        default:
            break
        }
    }

    private func appendPiText(_ text: String, thinking: Bool) {
        if thinking {
            if let item = piThinkingItem {
                item.text += text
            } else {
                let item = PiItem(kind: .thinking, text: text, running: true)
                piThinkingItem = item
                piItems.append(item)
            }
        } else {
            if let item = piStreamingItem {
                item.text += text
            } else {
                let item = PiItem(kind: .assistant, text: text, running: true)
                piStreamingItem = item
                piItems.append(item)
            }
        }
    }

    /// The text content of an AgentMessage: joined text blocks.
    static func piMessageText(_ message: [String: Any]) -> String {
        piContentText(message["content"])
    }

    static func piContentText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { part -> String? in
            guard part["type"] as? String == "text" else { return nil }
            return part["text"] as? String
        }.joined(separator: "\n")
    }

    /// A one-line label for a tool call's arguments.
    static func piToolSummary(_ arguments: Any?) -> String {
        guard let arguments else { return "" }
        if let text = arguments as? String { return String(text.prefix(200)) }
        guard let object = arguments as? [String: Any],
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]
              ),
              let text = String(data: data, encoding: .utf8)
        else { return "" }
        return String(text.prefix(200))
    }

    /// Pi's model picker: the same gateway snapshot every engine sees.
    var piModelChoices: [GatewayAPI.Model] {
        gatewayModelSnapshot()
    }
}
