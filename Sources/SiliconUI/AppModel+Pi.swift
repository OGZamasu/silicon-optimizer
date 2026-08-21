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
        }

        public let id = UUID()
        public let kind: Kind
        public var text: String
        public var running: Bool

        init(kind: Kind, text: String, running: Bool = false) {
            self.kind = kind
            self.text = text
            self.running = running
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
            ?? gatewayModelSnapshot().first(where: \.serving)?.id
            ?? gatewayModelSnapshot().first?.id
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
                gatewayPort: gatewayPort,
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
    private func piSend(_ command: [String: Any]) {
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
        piSend(["type": "abort"])
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
                        running: true
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