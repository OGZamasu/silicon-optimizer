import AppKit
import Foundation
import SiliconControl
import SiliconRuntime

/// One rendered row of the Codex conversation. Codex streams typed "items" — agent prose,
/// commands, file changes, tool calls — and each becomes one of these, updated in place as
/// its deltas arrive.
public struct CodexChatItem: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case user(String)
        case assistant(String)
        /// The model's thinking summary; folded in the UI.
        case reasoning(String)
        case command(command: String, output: String, running: Bool)
        case fileChange(String)
        case toolCall(title: String, running: Bool)
        case webSearch(String)
        case notice(String)
        case error(String)
    }

    public var id: String
    public var kind: Kind
}

/// A server-initiated approval Codex is waiting on: run this command, or apply this file
/// change. Answered through the buttons its card renders.
public struct CodexApproval: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case command(String)
        case fileChange(String)

        /// What the guardrail is told this call is. Codex's two approval kinds are its
        /// shell and its patch applier; the names are the ones its own protocol uses.
        var toolName: String {
            switch self {
            case .command: "shell"
            case .fileChange: "apply_patch"
            }
        }

        var arguments: String {
            switch self {
            case .command(let command): command
            case .fileChange(let summary): summary
            }
        }
    }

    public var id = UUID()
    public var rpcID: JSONValue
    public var kind: Kind
    public var reason: String?
    /// What Jev made of it. Nil while the screening is in flight, and for the whole life of
    /// the card when guardrails are off — the card says so rather than implying safety.
    public var screening: GuardrailScreening?
}

/// Lifecycle of the Codex sidecar behind the Chat tab's Codex engine.
///
/// Same shape as the harness integration: lazy start on first show, torn down when the
/// engine changes, killed with the app. The difference is the surface — Codex has no web UI
/// to embed, so this app drives its app-server protocol and renders the conversation
/// natively.
extension AppModel {

    /// The gateway model ids the Codex picker offers — every local install and every model
    /// the swarm's nodes have, marked with where each runs.
    public var codexModelChoices: [GatewayAPI.Model] {
        gatewayModelSnapshot()
    }

    /// The model the next turn will use.
    public var codexSelectedModel: String {
        settings.codexModel
            ?? autoSelectableGatewayModels().first(where: \.serving)?.id
            ?? autoSelectableGatewayModels().first?.id
            ?? ""
    }

    public var codexWorkingDirectory: URL {
        if let stored = settings.codexWorkingDirectory, !stored.isEmpty {
            return URL(fileURLWithPath: stored)
        }
        // A harmless display/picker seed only. startCodexIfNeeded refuses to trust or start
        // against it until the user explicitly chooses a folder.
        return CodexRuntime.homeDirectory.appendingPathComponent("workspace", isDirectory: true)
    }

    public var hasExplicitCodexWorkingDirectory: Bool {
        guard let stored = settings.codexWorkingDirectory else { return false }
        return !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Starts the Codex sidecar unless it is already up or on its way.
    public func startCodexIfNeeded() {
        guard hasExplicitCodexWorkingDirectory else {
            codexState = .idle
            return
        }
        switch codexState {
        case .ready, .starting: return
        case .idle, .failed, .stopping: break
        }

        let runtime = codexRuntime ?? CodexRuntime()
        codexRuntime = runtime
        codexState = .starting(stage: "Looking for Node.js…")
        registerCodexTermination()

        // Warm the swarm view in parallel so node models are in the picker by first paint.
        Task { await refreshSwarm() }

        let nodePath = settings.nodeBinaryPath ?? ""
        let gateway = gatewayPort()
        let model = codexSelectedModel
        let workingDirectory = codexWorkingDirectory.path
        Task {
            let events = await runtime.start(
                nodePath: nodePath, gatewayPort: gateway, gatewayToken: gatewayToken,
                defaultModel: model.isEmpty ? "local/none" : model,
                trustedProjectPath: workingDirectory
            ) { [weak self] state in
                Task { @MainActor in self?.codexState = state }
            }
            let pid = await runtime.processIdentifier
            await MainActor.run { [weak self] in self?.codexProcessID = pid }
            guard let events else { return }
            for await event in events {
                await MainActor.run { [weak self] in self?.handleCodexEvent(event) }
            }
        }
    }

    public func stopCodex() {
        guard let runtime = codexRuntime else { return }
        codexState = .stopping
        codexProcessID = nil
        codexThreadID = nil
        codexTurnActive = false
        codexApprovals.removeAll()
        Task {
            await runtime.stop()
            await MainActor.run { [weak self] in self?.codexState = .idle }
        }
    }

    public func restartCodex() {
        codexItems.removeAll()
        codexTokenLabel = nil
        guard let runtime = codexRuntime else { return startCodexIfNeeded() }
        // Stop must finish before start begins: the two share one runtime actor, and a
        // start that overlaps a stop can have its fresh process torn down under it.
        codexState = .stopping
        codexProcessID = nil
        codexThreadID = nil
        codexTurnActive = false
        codexApprovals.removeAll()
        Task {
            await runtime.stop()
            await MainActor.run { [weak self] in
                self?.codexState = .idle
                self?.startCodexIfNeeded()
            }
        }
    }

    /// Clears the conversation: the next message starts a fresh Codex thread.
    public func newCodexThread() {
        codexThreadID = nil
        codexItems.removeAll()
        codexApprovals.removeAll()
        codexTokenLabel = nil
        codexTurnActive = false
    }

    // MARK: - Sending

    public func sendCodexMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let runtime = codexRuntime, codexState.isRunning else { return }

        let model = codexSelectedModel
        settings.codexModel = model
        settings.save()

        codexItems.append(CodexChatItem(id: UUID().uuidString, kind: .user(trimmed)))
        codexTurnActive = true
        noteActivity()

        let cwd = codexWorkingDirectory.path
        let approval = Self.codexPolicyValue(
            settings.codexApprovalPolicy, allowed: ["untrusted", "on-request", "never"],
            fallback: "on-request"
        )
        let sandbox = Self.codexPolicyValue(
            settings.codexSandbox,
            allowed: ["read-only", "workspace-write", "danger-full-access"],
            fallback: "read-only"
        )

        Task {
            do {
                let threadID: String
                if let existing = codexThreadID {
                    threadID = existing
                } else {
                    let started = try await runtime.send(method: "thread/start", params: [
                        "model": .string(model),
                        "cwd": .string(cwd),
                        "approvalPolicy": .string(approval),
                        "sandbox": .string(sandbox),
                    ])
                    guard let id = started["thread"]["id"].stringValue else {
                        throw CodexRuntime.CodexError.server(
                            code: -1, message: "thread/start returned no thread id"
                        )
                    }
                    codexThreadID = id
                    threadID = id
                }

                // Only documented fields ride along: the model may change per turn, the
                // policies were fixed at thread/start.
                _ = try await runtime.send(method: "turn/start", params: [
                    "threadId": .string(threadID),
                    "input": .array([.object(["type": "text", "text": .string(trimmed)])]),
                    "cwd": .string(cwd),
                    "model": .string(model),
                ])
            } catch {
                codexTurnActive = false
                codexItems.append(CodexChatItem(
                    id: UUID().uuidString, kind: .error(error.localizedDescription)
                ))
            }
        }
    }

    /// Codex's policy enums are kebab-case on the wire ("on-request", "workspace-write");
    /// anything unrecognized — including values an older build may have stored — falls
    /// back rather than failing thread creation with an opaque enum error.
    static func codexPolicyValue(
        _ stored: String?, allowed: Set<String>, fallback: String
    ) -> String {
        guard let stored, allowed.contains(stored) else { return fallback }
        return stored
    }

    /// Asks Codex to stop the current turn. The turn still ends through `turn/completed`.
    public func interruptCodexTurn() {
        guard let runtime = codexRuntime, let threadID = codexThreadID else { return }
        Task {
            _ = try? await runtime.send(method: "turn/interrupt", params: [
                "threadId": .string(threadID),
            ])
        }
    }

    // MARK: - Approvals

    public func answerCodexApproval(_ approval: CodexApproval, accept: Bool) {
        // The card goes first, and unconditionally: the decision has been made, and a card
        // left on screen because the sidecar died in the meantime is a lie about what is
        // still pending.
        codexApprovals.removeAll { $0.id == approval.id }
        guard let runtime = codexRuntime else { return }
        // The result is an object, not a bare string — the protocol schema's
        // `{ decision: accept | acceptForSession | decline | cancel }`. A bare string
        // deserializes as an error on Codex's side, which the model then narrates as a
        // failed approval and retries.
        let decision = accept ? "accept" : "decline"
        Task {
            await runtime.respond(
                id: approval.rpcID, result: .object(["decision": .string(decision)])
            )
        }
    }

    // MARK: - Guardrails

    /// Screens one Codex approval and, when the owner has asked for it, answers the ones
    /// Jev is sure about.
    ///
    /// Codex is the engine where this fits best: it asks before it runs, over its own
    /// protocol, and it waits for the answer. So the screening happens *before* the command
    /// exists as anything but a proposal, and a `.block` is a real refusal rather than a
    /// note about something that already happened.
    ///
    /// Three outcomes, and the order matters. `.act` and `.block` are answered here only if
    /// "Auto-approve calls Jev rates safe" is on. `.confirm` always waits for the person.
    /// And a screening that could not happen at all waits for the person too — an
    /// unavailable guardrail must never read as a yes.
    func screenCodexApproval(_ approvalID: UUID, using service: JevService = .shared) async {
        guard let pending = codexApprovals.first(where: { $0.id == approvalID }) else { return }

        let screening = await JevGuardrails.screen(
            engine: .codex,
            request: lastCodexUserMessage(),
            tool: pending.kind.toolName,
            arguments: pending.kind.arguments,
            workingDirectory: codexWorkingDirectory.path,
            recentTranscript: recentCodexToolResults(),
            using: service
        )

        // The person may have decided while the screening was in flight. Their answer wins,
        // and the card is gone, so there is nothing to annotate and nothing to auto-answer.
        guard let index = codexApprovals.firstIndex(where: { $0.id == approvalID }) else { return }
        codexApprovals[index].screening = screening
        let approval = codexApprovals[index]

        guard await service.settings().autoApproveSafeToolCalls,
              let verdict = screening.verdict
        else { return }

        switch verdict {
        case .act:
            codexItems.append(CodexChatItem(
                id: UUID().uuidString,
                kind: .notice("Approved automatically — \(screening.summary).")
            ))
            answerCodexApproval(approval, accept: true)
        case .block(let reasons):
            codexItems.append(CodexChatItem(
                id: UUID().uuidString,
                kind: .notice(
                    "Declined automatically — Jev: block: \(reasons.joined(separator: ", "))."
                )
            ))
            answerCodexApproval(approval, accept: false)
        case .confirm:
            // The one case a person is for.
            break
        }
    }

    /// The last thing the user typed, which is what the guardrail compares the call against.
    func lastCodexUserMessage() -> String {
        for item in codexItems.reversed() {
            if case .user(let text) = item.kind { return text }
        }
        return ""
    }

    /// The last few tool results, newest last — the material an injected instruction would
    /// have arrived in. Only what came *back*: the model's own prose is not evidence about
    /// whether the model was steered.
    func recentCodexToolResults() -> [String] {
        var results: [String] = []
        for item in codexItems.reversed() {
            switch item.kind {
            case .command(let command, let output, _) where !output.isEmpty:
                results.append("$ \(command)\n\(output)")
            case .webSearch(let query):
                results.append("web search: \(query)")
            case .toolCall(let title, _):
                results.append("tool: \(title)")
            default:
                continue
            }
            if results.count >= GuardrailState.maximumResults { break }
        }
        return results.reversed()
    }

    // MARK: - Event handling

    func handleCodexEvent(_ event: CodexEvent) {
        switch event {
        case .notification(let method, let params):
            handleCodexNotification(method: method, params: params)
        case .serverRequest(let id, let method, let params):
            handleCodexServerRequest(id: id, method: method, params: params)
        case .terminated(let message):
            codexTurnActive = false
            codexApprovals.removeAll()
            if case .stopping = codexState {} else if case .idle = codexState {} else {
                codexState = .failed(message:
                    "Codex exited unexpectedly." + (message.map { "\n\($0)" } ?? ""))
            }
        }
    }

    private func handleCodexNotification(method: String, params: JSONValue) {
        switch method {
        case "thread/started":
            if let id = params["thread"]["id"].stringValue { codexThreadID = id }
        case "turn/started":
            codexTurnActive = true
        case "turn/completed":
            codexTurnActive = false
            let error = params["turn"]["error"]
            if let message = error["message"].stringValue {
                codexItems.append(CodexChatItem(
                    id: UUID().uuidString, kind: .error(message)
                ))
            }
        case "turn/failed":
            codexTurnActive = false
            if let message = params["error"]["message"].stringValue {
                codexItems.append(CodexChatItem(id: UUID().uuidString, kind: .error(message)))
            }
        case "item/started", "item/completed", "item/updated":
            upsertCodexItem(params["item"], completed: method == "item/completed")
        case "item/agentMessage/delta":
            appendCodexDelta(params: params) { existing, delta in
                if case .assistant(let text) = existing { return .assistant(text + delta) }
                return nil
            } orNew: { delta in .assistant(delta) }
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            appendCodexDelta(params: params) { existing, delta in
                if case .reasoning(let text) = existing { return .reasoning(text + delta) }
                return nil
            } orNew: { delta in .reasoning(delta) }
        case "item/commandExecution/outputDelta":
            appendCodexDelta(params: params) { existing, delta in
                if case .command(let command, let output, let running) = existing {
                    return .command(command: command, output: output + delta, running: running)
                }
                return nil
            } orNew: { delta in .command(command: "", output: delta, running: true) }
        case "thread/tokenUsage/updated":
            let usage = params["tokenUsage"]
            let input = usage["totalInputTokens"].intValue ?? usage["inputTokens"].intValue
            let output = usage["totalOutputTokens"].intValue ?? usage["outputTokens"].intValue
            if let input, let output {
                codexTokenLabel = "\(input.formatted()) in · \(output.formatted()) out"
            }
        case "thread/error", "error":
            if let message = params["message"].stringValue
                ?? params["error"]["message"].stringValue {
                codexItems.append(CodexChatItem(id: UUID().uuidString, kind: .error(message)))
            }
        default:
            break // plans, diffs, login notices: nothing the transcript needs yet
        }
    }

    /// Creates or updates the row for one Codex item payload.
    private func upsertCodexItem(_ item: JSONValue, completed: Bool) {
        guard let id = item["id"].stringValue else { return }
        let type = item["type"].stringValue ?? item["itemType"].stringValue ?? ""
        let kind: CodexChatItem.Kind?
        switch type {
        case "agentMessage":
            kind = .assistant(item.firstString("text", "content") ?? existingText(id: id) ?? "")
        case "reasoning":
            kind = .reasoning(item.firstString("summary", "text")
                ?? existingText(id: id) ?? "")
        case "commandExecution":
            let command = item.firstString("command", "commandLine")
                ?? item["command"].arrayValue?.compactMap(\.stringValue).joined(separator: " ")
                ?? ""
            let output = item.firstString("aggregatedOutput", "output")
                ?? existingCommandOutput(id: id)
            kind = .command(command: command, output: output, running: !completed)
        case "fileChange":
            let changes = item["changes"].arrayValue?.compactMap { change in
                change["path"].stringValue
            } ?? []
            kind = .fileChange(changes.isEmpty
                ? "File changes" : changes.joined(separator: ", "))
        case "mcpToolCall":
            let server = item["server"].stringValue ?? "tool"
            let tool = item["tool"].stringValue ?? ""
            kind = .toolCall(title: "\(server) · \(tool)", running: !completed)
        case "dynamicToolCall", "collabToolCall":
            kind = .toolCall(title: item["tool"].stringValue ?? "tool", running: !completed)
        case "webSearch":
            kind = .webSearch(item["query"].stringValue ?? "web search")
        case "userMessage":
            kind = nil // already rendered locally when it was sent
        case "error":
            kind = .error(item["message"].stringValue ?? "Codex reported an error.")
        default:
            kind = nil
        }
        guard let kind else { return }
        if let index = codexItems.firstIndex(where: { $0.id == id }) {
            codexItems[index].kind = kind
        } else {
            codexItems.append(CodexChatItem(id: id, kind: kind))
        }
    }

    private func existingText(id: String) -> String? {
        guard let item = codexItems.first(where: { $0.id == id }) else { return nil }
        switch item.kind {
        case .assistant(let text), .reasoning(let text): return text
        default: return nil
        }
    }

    private func existingCommandOutput(id: String) -> String {
        guard let item = codexItems.first(where: { $0.id == id }),
              case .command(_, let output, _) = item.kind else { return "" }
        return output
    }

    /// Routes one delta notification to its item, creating the row if the delta arrived
    /// before its `item/started` (the protocol does not promise an order).
    private func appendCodexDelta(
        params: JSONValue,
        _ transform: (CodexChatItem.Kind, String) -> CodexChatItem.Kind?,
        orNew makeNew: (String) -> CodexChatItem.Kind
    ) {
        guard let delta = params.firstString("delta", "textDelta", "chunk", "output"),
              !delta.isEmpty
        else { return }
        let id = params["itemId"].stringValue ?? params["item_id"].stringValue ?? "live"
        if let index = codexItems.firstIndex(where: { $0.id == id }),
           let updated = transform(codexItems[index].kind, delta) {
            codexItems[index].kind = updated
        } else {
            codexItems.append(CodexChatItem(id: id, kind: makeNew(delta)))
        }
    }

    private func handleCodexServerRequest(id: JSONValue, method: String, params: JSONValue) {
        switch method {
        case "item/commandExecution/requestApproval":
            let command = params.firstString("command", "commandLine")
                ?? params["command"].arrayValue?.compactMap(\.stringValue)
                    .joined(separator: " ")
                ?? "a command"
            appendCodexApproval(CodexApproval(
                rpcID: id, kind: .command(command),
                reason: params["reason"].stringValue
            ))
        case "item/fileChange/requestApproval":
            let paths = params["changes"].arrayValue?
                .compactMap { $0["path"].stringValue }.joined(separator: ", ")
            appendCodexApproval(CodexApproval(
                rpcID: id, kind: .fileChange(paths ?? "file changes"),
                reason: params["reason"].stringValue
            ))
        default:
            // Anything unrecognized is declined rather than left hanging: a stuck server
            // request would freeze the turn forever.
            let runtime = codexRuntime
            Task { await runtime?.respond(id: id, result: .string("decline")) }
            codexItems.append(CodexChatItem(
                id: UUID().uuidString,
                kind: .notice("Declined an unsupported Codex request (\(method)).")
            ))
        }
    }

    /// Shows the card, then screens it. The card comes first on purpose: the person can
    /// answer at once rather than waiting on a network round trip, and the verdict appears
    /// on the card a moment later if they have not.
    private func appendCodexApproval(_ approval: CodexApproval) {
        codexApprovals.append(approval)
        Task { await screenCodexApproval(approval.id) }
    }

    /// Codex is a child process; app exit must take it along. Same synchronous-signal
    /// pattern as the harness, for the same reason.
    private func registerCodexTermination() {
        guard !codexTerminationRegistered else { return }
        codexTerminationRegistered = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let pid = self?.codexProcessID {
                    kill(pid, SIGTERM)
                }
            }
        }
    }
}
