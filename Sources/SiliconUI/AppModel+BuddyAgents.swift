import Foundation
import SiliconControl
import SiliconRuntime

/// The Mac half of Silicon Buddy's agent sessions: the Chat tab's Codex and Pi engines,
/// seen and driven from a phone.
///
/// The phone mirrors what is on the Mac. There is one session per engine, it is the one the
/// owner is looking at, and both sides write into it: a message sent from the phone appears
/// in the Mac's transcript as it is typed there, and an approval answered on either side is
/// answered once, for both.
///
/// Everything here is built by *sampling* the app's own state rather than by posting from
/// the places that change it. That is the same trade `BuddyEventPump` makes and it is made
/// for the same reason twice over: the mutation sites are spread across
/// `AppModel+Codex.swift`, `AppModel+Pi.swift` and the guardrail, and a watcher that
/// samples cannot miss a change by forgetting to announce one — which is exactly how the
/// owner's own taps would have failed to reach the phone.
extension AppModel {

    // MARK: - One normalised row

    /// A transcript row, reduced to the shape both engines share, before the ledger stamps
    /// the two things only it knows: when the Mac first saw the row, and what model it was
    /// sent with.
    ///
    /// `Equatable` and cheap to compare, because comparing these is how a change is
    /// noticed at all.
    struct AgentRow: Sendable, Equatable {
        var id: String
        var kind: String
        var text: String
        var output: String?
        var truncated: Bool?
        var status: String?

        init(
            id: String, kind: String, text: String, output: String? = nil,
            status: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.status = status
            // An empty string is nothing said, and a key whose value is "" is a field a
            // phone has to special-case. Dropped here, once, rather than there.
            guard let output, !output.isEmpty else { return }
            // Counted in UTF-8 first because that is free for a native string, and a build
            // log is sampled ten times a second; only a long one pays for the walk from
            // its end.
            let limit = ControlAPI.agentOutputLimit
            guard output.utf8.count > limit else {
                self.output = output
                return
            }
            let tail = String(output.suffix(limit))
            self.output = tail
            if tail.utf8.count < output.utf8.count { self.truncated = true }
        }
    }

    /// One call held at the gate, once the guardrail has spoken, before the ledger stamps
    /// when it arrived.
    struct AgentPendingApproval: Sendable, Equatable {
        var id: String
        var kind: String
        var summary: String
        var reason: String?
        var screening: ControlAPI.AgentScreening
    }

    /// A session as one reading — only what can change from moment to moment, and only what
    /// is cheap to read, because the watcher takes one ten times a second on the main
    /// actor. What a summary adds on top (the model menu, the policy, the folder) is read
    /// when a route asks for it; see `AgentSessionExtras`.
    struct AgentSessionSnapshot: Sendable, Equatable {
        /// Which app this reading is of. There is one in the running program, so this never
        /// varies there — but the ledger behind these sessions is a singleton, and a
        /// singleton keyed by engine alone is one table shared by every `AppModel` that
        /// ever exists. Under a test suite that is several at once, and one of them
        /// arriving with an empty transcript would read as another's thread being cleared.
        var owner: ObjectIdentifier
        var engine: String
        var state: String
        var failure: String?
        var threadID: String?
        /// What a turn sent right now is sent with — the stored choice, which both engines
        /// write before they append the row. Read cheaply for exactly that reason: it is
        /// what the ledger stamps on a new `user` row.
        var sentWith: String
        var turnActive: Bool
        var rows: [AgentRow]
        var approvals: [AgentPendingApproval]
    }

    /// What a summary carries beyond one reading. Read per request rather than per tick:
    /// the model list walks every install and every peer, and the policy asks Jev's
    /// settings actor whether the guardrail is on.
    struct AgentSessionExtras: Sendable {
        var model: String
        var modelChoices: [ControlAPI.AgentModelChoice]
        var cwd: String?
        var approvals: String
        var sandbox: String
    }

    // MARK: - Normalisation

    /// One Codex row. Codex's own item types are richer than the wire vocabulary on
    /// purpose: a phone that had to learn `webSearch` and `mcpToolCall` and
    /// `dynamicToolCall` separately would have learned Codex's protocol rather than this
    /// app's contract, and would break when Codex renames one.
    static func agentRow(codex item: CodexChatItem) -> AgentRow {
        switch item.kind {
        case .user(let text):
            AgentRow(id: item.id, kind: "user", text: text)
        case .assistant(let text):
            AgentRow(id: item.id, kind: "assistant", text: text)
        case .reasoning(let text):
            AgentRow(id: item.id, kind: "reasoning", text: text)
        case .command(let command, let output, let running):
            // The one engine that keeps the two apart, so the wire does too.
            AgentRow(
                id: item.id, kind: "command", text: command, output: output,
                status: running ? "running" : "completed"
            )
        case .fileChange(let summary):
            AgentRow(id: item.id, kind: "fileChange", text: summary)
        case .toolCall(let title, let running):
            AgentRow(
                id: item.id, kind: "tool", text: title,
                status: running ? "running" : "completed"
            )
        case .webSearch(let query):
            AgentRow(id: item.id, kind: "tool", text: "web search: \(query)")
        case .notice(let text):
            AgentRow(id: item.id, kind: "notice", text: text)
        case .error(let text):
            AgentRow(id: item.id, kind: "error", text: text, status: "failed")
        }
    }

    /// One Pi row.
    ///
    /// Pi overwrites a tool row's text with the tool's result when it finishes, so the two
    /// cannot be separated the way Codex's can: `text` is the tool's name and `output` is
    /// whichever of the two Pi currently has there — the arguments while it runs, the
    /// result once it has. An approval card is the same shape with the arguments in it,
    /// because that is what is being decided.
    static func agentRow(pi item: PiItem) -> AgentRow {
        switch item.kind {
        case .user:
            AgentRow(id: item.id.uuidString, kind: "user", text: item.text)
        case .assistant:
            AgentRow(
                id: item.id.uuidString, kind: "assistant", text: item.text,
                status: item.running ? "running" : nil
            )
        case .thinking:
            AgentRow(
                id: item.id.uuidString, kind: "reasoning", text: item.text,
                status: item.running ? "running" : nil
            )
        case .tool(let name):
            AgentRow(
                id: item.id.uuidString, kind: "tool", text: name, output: item.text,
                status: item.running ? "running" : "completed"
            )
        case .notice:
            AgentRow(id: item.id.uuidString, kind: "notice", text: item.text)
        case .approval(_, let tool):
            AgentRow(
                id: item.id.uuidString, kind: "tool", text: tool, output: item.text,
                // The one place `declined` is a real answer rather than a shape the
                // contract has room for: a refused call stays in Pi's transcript saying so.
                status: item.answered
                    ? (item.allowed == true ? "completed" : "declined")
                    : "running"
            )
        }
    }

    /// A runtime's state in the four words the wire has.
    ///
    /// `stopping` folds into `stopped`: it is on its way there, the only thing a phone can
    /// offer about either is "start it", and a fifth word would be a state whose button
    /// does nothing.
    static func agentState(_ state: RuntimeState) -> (state: String, failure: String?) {
        switch state {
        case .idle, .stopping: ("stopped", nil)
        case .starting: ("starting", nil)
        case .ready: ("running", nil)
        case .failed(let message): ("failed", message)
        }
    }

    static func agentState(_ state: PiEngineState) -> (state: String, failure: String?) {
        switch state {
        case .idle, .stopping: ("stopped", nil)
        case .starting: ("starting", nil)
        case .ready: ("running", nil)
        case .failed(let message): ("failed", message)
        }
    }

    static func agentChoices(_ models: [GatewayAPI.Model]) -> [ControlAPI.AgentModelChoice] {
        models.map {
            ControlAPI.AgentModelChoice(
                id: $0.id,
                label: $0.serving ? "\($0.displayName) — serving now" : $0.displayName,
                where: $0.where_
            )
        }
    }

    /// The line the Mac's card shows, as the wire carries it.
    ///
    /// An unscreened call keeps its reason only when the reason is one of the guardrail's
    /// own fixed sentences. The other source of that text is an error's description — a
    /// hostname, a URL, a message from somebody else's server — and `/jev/guardrails/recent`
    /// keeps those off the wire for the same reason; here it becomes a sentence that says
    /// what the person needs to know, which is that nothing was checked.
    static func agentScreening(_ screening: GuardrailScreening) -> ControlAPI.AgentScreening {
        switch screening {
        case .screened(let verdict, _, _, _):
            ControlAPI.AgentScreening(verdict: verdict.name, summary: screening.summary)
        case .unavailable(let reason):
            ControlAPI.AgentScreening(
                verdict: "unavailable",
                summary: knownUnscreenedReasons.contains(reason)
                    ? screening.summary
                    : "Jev: not screened — the screening could not be completed."
            )
        }
    }

    /// `JevGuardrails.unavailableReason`'s sentences. Should that list change without this
    /// one, the new sentence is replaced by the generic one — the safe direction.
    static let knownUnscreenedReasons: Set<String> = [
        "Jev is off in Settings → TypeSafe (Jev).",
        "Guardrails are off in Settings → TypeSafe (Jev).",
        "Jev has no key on this Mac, or this month's budget is spent.",
    ]

    /// A path as the wire shows it: relative to the home folder, so a device learns where
    /// in it the agent works without learning the account's name.
    static func homeRelative(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Reading the live sessions

    func agentSnapshot(engine: String) -> AgentSessionSnapshot? {
        switch engine {
        case "codex": codexSessionSnapshot()
        case "pi": piSessionSnapshot()
        default: nil
        }
    }

    func agentSnapshots() -> [AgentSessionSnapshot] {
        ControlAPI.agentEngines.compactMap { agentSnapshot(engine: $0) }
    }

    private func codexSessionSnapshot() -> AgentSessionSnapshot {
        let state = Self.agentState(codexState)
        return AgentSessionSnapshot(
            owner: agentLedgerOwner,
            engine: "codex",
            state: state.state,
            failure: state.failure,
            threadID: codexThreadID,
            sentWith: settings.codexModel ?? "",
            turnActive: codexTurnActive,
            rows: codexItems.map { Self.agentRow(codex: $0) },
            // A stopped engine is asking nobody anything. And a card goes out only once the
            // guardrail has spoken: until then its verdict is on its way, and a card the
            // guardrail is about to answer by itself must not flash up as a question.
            approvals: !codexState.isRunning ? [] : codexApprovals.compactMap { approval in
                guard let screening = approval.screening else { return nil }
                return AgentPendingApproval(
                    id: approval.id.uuidString,
                    kind: {
                        switch approval.kind {
                        case .command: "command"
                        case .fileChange: "fileChange"
                        }
                    }(),
                    summary: approval.kind.arguments,
                    reason: approval.reason,
                    screening: Self.agentScreening(screening)
                )
            }
        )
    }

    private func piSessionSnapshot() -> AgentSessionSnapshot {
        let state = Self.agentState(piState)
        return AgentSessionSnapshot(
            owner: agentLedgerOwner,
            engine: "pi",
            state: state.state,
            failure: state.failure,
            // Pi's RPC has no thread id to give: a session is the process's own and is
            // named by the file it is written to, not by anything a client is handed.
            threadID: nil,
            sentWith: piCurrentModel ?? settings.piModel ?? "",
            turnActive: piBusy,
            rows: piItems.map { Self.agentRow(pi: $0) },
            approvals: piState != .ready ? [] : piItems.compactMap { item in
                guard case .approval(_, let tool) = item.kind,
                      let screening = Self.piScreeningAwaitingAPerson(item)
                else { return nil }
                return AgentPendingApproval(
                    id: item.id.uuidString, kind: "tool",
                    summary: "\(tool) \(item.text)"
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    // Pi's gate is this app's own extension, and it asks nothing beyond
                    // "may this run?" — so there is no reason to pass on, and inventing
                    // one would be putting words in the agent's mouth.
                    reason: nil,
                    screening: Self.agentScreening(screening)
                )
            }
        )
    }

    /// The verdict on a Pi card that is waiting for a person, or nil when it is not
    /// waiting for one — answered already, or still being screened. The one gate both the
    /// list and the answer go through, so they cannot disagree about what is answerable.
    ///
    /// While Jev is screening, the Mac shows "Screening…" and no buttons. That is not a
    /// courtesy: `screenPiToolCall` defers to any answer given in the meantime and throws
    /// the verdict away, so a call answered during the screening runs even if the
    /// guardrail was about to block it.
    static func piScreeningAwaitingAPerson(_ item: PiItem) -> GuardrailScreening? {
        guard !item.answered else { return nil }
        return item.screening
    }

    /// What the summary adds to a reading. See `AgentSessionExtras`.
    func agentExtras(engine: String) async -> AgentSessionExtras {
        let guardrail = await agentGuardrailPosture()
        let choices = Self.agentChoices(
            AgentSessionSeams.modelChoices ?? gatewayModelSnapshot()
        )
        switch engine {
        case "codex":
            // The thread keeps what it started with, so a running thread reports its own
            // policy; a fresh one reports what the next `thread/start` would send.
            let policy = BuddyAgentSessions.shared.threadPolicy(
                owner: agentLedgerOwner, engine: "codex", threadID: codexThreadID
            ) ?? Self.codexThreadPolicy(
                storedApproval: settings.codexApprovalPolicy,
                storedSandbox: settings.codexSandbox, guarded: guardrail.isOn
            )
            return AgentSessionExtras(
                model: codexSelectedModel,
                modelChoices: choices,
                cwd: hasExplicitCodexWorkingDirectory
                    ? Self.homeRelative(codexWorkingDirectory.path) : nil,
                approvals: policy.approval == "never"
                    ? "unattended" : (guardrail == .screening ? "screened" : "asked"),
                sandbox: policy.sandbox
            )
        default:
            return AgentSessionExtras(
                model: piCurrentModel ?? settings.piModel ?? "",
                modelChoices: choices,
                cwd: Self.homeRelative(PiRuntime.workspaceDirectory.path),
                // Pi's protocol never asks. The gate is the guardrail's; without it, Pi's
                // tools simply run. With it on but unable to judge, every held call goes
                // to a person unscreened — asked, not screened.
                approvals: guardrail.piApprovalMode,
                sandbox: "none"
            )
        }
    }

    /// Where the guardrail stands, in the three states that change what a phone is told.
    ///
    /// "On" and "screening" are different answers. Switched on, it holds every call and
    /// pins Codex to asking — but with no key, or this month's budget spent, it can judge
    /// none of them, and each one reaches a person marked "not screened". Reporting that as
    /// `screened` would tell a phone something is checking calls when nothing is.
    func agentGuardrailPosture() async -> GuardrailPosture {
        if let stubbed = AgentSessionSeams.guardrails { return stubbed }
        guard await JevGuardrails.isTurnedOn() else { return .off }
        return await DecisionRouter.shared.canAnswer(.guardrails) ? .screening : .unavailable
    }

    /// Whether the guardrail is switched on — what pins Codex's policy, and what makes Pi
    /// hold a call at all, whether or not it can then judge it.
    func agentGuardrailsOn() async -> Bool {
        await agentGuardrailPosture().isOn
    }

    /// This app's half of the agent ledger's key. See `AgentSessionSnapshot.owner`.
    var agentLedgerOwner: ObjectIdentifier { ObjectIdentifier(self) }

    /// Reads the live session and brings the ledger up to date, without posting anything.
    ///
    /// Every route calls this before it answers, which is what makes a 409 honest when
    /// nobody has an `/events` stream open: an approval the owner answered at the Mac an
    /// hour ago is recorded here, at the moment the phone asks, rather than only by a
    /// watcher that was not running.
    @discardableResult
    func refreshAgentLedger(engine: String) -> AgentSessionSnapshot? {
        guard let snapshot = agentSnapshot(engine: engine) else { return nil }
        BuddyAgentSessions.shared.reconcile(snapshot)
        return snapshot
    }

    /// Writes the settings down — or, under a test, hands them to the test instead.
    ///
    /// `Settings.save()` also writes the Hugging Face token to the login Keychain, and a
    /// test process must never touch that. The two places an agent route can reach a save
    /// — a turn sent with a model picked, and Pi's model switch — go through here.
    func persistSettings() {
        if let stub = AgentSessionSeams.saveSettings {
            stub(settings)
        } else {
            settings.save()
        }
    }

    // MARK: - ControlHost

    public func agentSessions() async -> ControlAPI.AgentSessionList {
        var sessions: [ControlAPI.AgentSessionSummary] = []
        for engine in ControlAPI.agentEngines {
            if let summary = try? await summarizeAgent(engine) { sessions.append(summary) }
        }
        return ControlAPI.AgentSessionList(sessions: sessions)
    }

    public func agentSession(
        engine: String, query: ControlAPI.AgentSessionQuery
    ) async throws -> ControlAPI.AgentSessionDetail {
        let engine = try Self.agentEngine(engine)
        let extras = await agentExtras(engine: engine)
        let snapshot = try requireAgentSnapshot(engine)
        return BuddyAgentSessions.shared.detail(of: snapshot, extras: extras, query: query)
    }

    public func startAgentSession(
        engine: String
    ) async throws -> ControlAPI.AgentSessionSummary {
        switch try Self.agentEngine(engine) {
        case "codex":
            // The folder is the owner's to choose and nobody else's. A phone that could
            // name one could name any folder on this Mac — and Codex would then be trusted
            // in it, which is the whole of its sandbox story.
            guard hasExplicitCodexWorkingDirectory else {
                throw AgentSessionError.noWorkingDirectory
            }
            startCodexIfNeeded()
        default:
            switch Self.piStart(from: piState) {
            case .start: startPiIfNeeded()
            case .restart: restartPi()
            case .nothing: break
            case .refuse: throw AgentSessionError.stillStopping("pi")
            }
        }
        return try await summarizeAgent(engine)
    }

    enum PiStart: Equatable { case start, restart, nothing, refuse }

    /// What `POST /agent/sessions/pi/start` does from each state. Its own function because
    /// the one case that matters is the one that is easy to get wrong: `startPiIfNeeded`
    /// starts only from idle, so from `failed` it does nothing — and a start that answered
    /// 200 while doing nothing would leave a phone waiting on an engine nobody is
    /// starting. From `failed` this does what the Mac's own Retry does.
    static func piStart(from state: PiEngineState) -> PiStart {
        switch state {
        case .idle: .start
        case .failed: .restart
        case .starting, .ready: .nothing
        case .stopping: .refuse
        }
    }

    public func newAgentThread(engine: String) async throws -> ControlAPI.AgentSessionSummary {
        switch try Self.agentEngine(engine) {
        case "codex":
            // A turn in flight belongs to the thread being left; stop it rather than let it
            // keep running against a thread nothing is showing any more. `turn/interrupt`
            // names its thread before the one below is forgotten.
            if codexTurnActive { interruptCodexTurn() }
            newCodexThread()
        default:
            // Pi's RPC does have a new-session command, so this is a fresh session rather
            // than a fresh process: `{"type":"new_session"}`, which is what the TUI's own
            // new-session key sends. It needs a running Pi to reach, so an engine that is
            // down is a 409 rather than a silent nothing.
            guard piState == .ready, piRuntime != nil else {
                throw AgentSessionError.notRunning("pi")
            }
            // Anything the gate is holding is answered before the session goes. The
            // extension blocks on `extension_ui_response`, so a card cleared off the
            // screen without one leaves it waiting on an answer that is never coming —
            // which is the same reason `abortPi` exists and does this.
            abortPi()
            piSend(["type": "new_session"])
            // Locally too, and at once: the command is answered asynchronously and the
            // transcript on screen belongs to the session being left behind.
            piItems.removeAll()
            piStreamingItem = nil
            piThinkingItem = nil
            piBusy = false
        }
        return try await summarizeAgent(engine)
    }

    public func stopAgentSession(engine: String) async throws -> ControlAPI.AgentSessionSummary {
        switch try Self.agentEngine(engine) {
        case "codex": stopCodex()
        default: stopPi()
        }
        return try await summarizeAgent(engine)
    }

    public func interruptAgentSession(
        engine: String
    ) async throws -> ControlAPI.AgentSessionSummary {
        let snapshot = try requireAgentSnapshot(try Self.agentEngine(engine))
        guard snapshot.state == "running" else {
            throw AgentSessionError.notRunning(snapshot.engine)
        }
        switch snapshot.engine {
        case "codex": interruptCodexTurn()
        default: abortPi()
        }
        return try await summarizeAgent(snapshot.engine)
    }

    public func sendAgentMessage(
        engine: String, _ request: ControlAPI.AgentMessageRequest
    ) async throws -> ControlAPI.AgentMessageAccepted {
        let engine = try Self.agentEngine(engine)
        let extras = await agentExtras(engine: engine)
        // Nothing below awaits: the checks and the send are one step on the main actor, so
        // the engine cannot change state between being checked and being sent to.
        let snapshot = try requireAgentSnapshot(engine)
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentSessionError.emptyMessage }
        // Checked before the engine is asked, so a picked model that does not exist is a
        // 400 rather than a turn answered by a different model than the one on screen.
        let asked = request.model.flatMap { $0.isEmpty ? nil : $0 }
        if let asked, !extras.modelChoices.contains(where: { $0.id == asked }) {
            throw AgentSessionError.unknownModel(asked)
        }
        guard snapshot.state == "running" else {
            throw AgentSessionError.notRunning(snapshot.engine)
        }
        // The Mac's send button is disabled for exactly this. A second `turn/start` on a
        // busy Codex thread fails, and its failure clears the "working" state on screen
        // while the first turn is still running. Pi takes a message mid-turn as steering,
        // which is what typing into it on the Mac does too.
        if snapshot.engine == "codex", snapshot.turnActive {
            throw AgentSessionError.turnInProgress(snapshot.engine)
        }

        // Read before, compared after: "the newest row" is only the row this send became
        // if a row actually appeared. An engine that is `running` but whose sidecar has
        // gone underneath it drops the message silently, and handing back the id of
        // somebody else's row would be worse than saying no.
        let before = agentRowCount(snapshot.engine)
        let previousCodexModel = settings.codexModel

        let model: String
        switch snapshot.engine {
        case "codex":
            // Sticky, as the Mac's own menu is: the picked model becomes the engine's, and
            // `sendCodexMessage` writes it down with the turn.
            if let asked { settings.codexModel = asked }
            model = codexSelectedModel
            sendCodexMessage(text)
        default:
            if let asked { setPiModel(asked) }
            model = piCurrentModel ?? ""
            sendPiMessage(text)
        }

        guard agentRowCount(snapshot.engine) > before,
              let id = newestAgentRowID(snapshot.engine)
        else {
            // Nothing was sent, so nothing was chosen either.
            if snapshot.engine == "codex" { settings.codexModel = previousCodexModel }
            throw AgentSessionError.notRunning(snapshot.engine)
        }
        refreshAgentLedger(engine: snapshot.engine)
        BuddyAgentSessions.shared.stamp(
            model: model, on: id, owner: agentLedgerOwner, engine: snapshot.engine
        )
        return ControlAPI.AgentMessageAccepted(itemID: id)
    }

    public func answerAgentApproval(
        engine: String, id: String, decision: String
    ) async throws -> ControlAPI.AgentApprovalResult {
        let engine = try Self.agentEngine(engine)
        guard ControlAPI.agentApprovalDecisions.contains(decision) else {
            throw AgentSessionError.unknownDecision(decision)
        }
        let accept = decision == "accept"
        // Nothing below awaits until the answer has gone: two taps racing each other, or a
        // tap racing the Mac, are decided by which reaches this step first, and the loser
        // finds the card already gone.
        //
        // The reading comes first, too: an answer given at the Mac while nothing was
        // watching is recorded now, which is what turns the race into a 409 rather than a
        // second `respond` to the runtime.
        let snapshot = try requireAgentSnapshot(engine)

        guard snapshot.approvals.contains(where: { $0.id == id }) else {
            // Held but not answerable — the engine is down, or the guardrail has not
            // spoken yet. Both say so, because neither is a card that does not exist.
            if heldApproval(id, engine: engine) {
                if snapshot.state != "running" { throw AgentSessionError.notRunning(engine) }
                throw AgentSessionError.stillScreening(id)
            }
            // Not waiting at all. Either the Mac answered it — which the caller should be
            // told, because the decision was made and nothing failed — or it never existed.
            if BuddyAgentSessions.shared.wasAnsweredOnTheMac(
                id: id, owner: agentLedgerOwner, engine: engine
            ) {
                throw AgentSessionError.answeredOnTheMac(id)
            }
            throw AgentSessionError.unknownApproval(id)
        }

        // Claimed before it is forwarded, so the reconcile that follows records this as
        // the phone's answer rather than the Mac's. This is the only path from a device to
        // a runtime's `respond`, and it runs once per id by construction: the card is gone
        // by the time anything else can look for it.
        BuddyAgentSessions.shared.claimRemote(
            id: id, owner: agentLedgerOwner, engine: engine, accept: accept
        )
        switch engine {
        case "codex":
            guard let approval = codexApprovals.first(where: { $0.id.uuidString == id })
            else { throw AgentSessionError.unknownApproval(id) }
            BuddyAgentSessions.shared.noteForwarded(owner: agentLedgerOwner, engine: engine)
            answerCodexApproval(approval, accept: accept)
        default:
            guard let card = piItems.first(where: {
                $0.id.uuidString == id && Self.piScreeningAwaitingAPerson($0) != nil
            }) else { throw AgentSessionError.unknownApproval(id) }
            BuddyAgentSessions.shared.noteForwarded(owner: agentLedgerOwner, engine: engine)
            answerPiApproval(card, allow: accept)
        }
        return ControlAPI.AgentApprovalResult(
            id: id, decision: accept ? "accepted" : "declined",
            session: try await summarizeAgent(engine)
        )
    }

    // MARK: - Plumbing

    static func agentEngine(_ engine: String) throws -> String {
        guard ControlAPI.agentEngines.contains(engine) else {
            throw AgentSessionError.unknownEngine(engine)
        }
        return engine
    }

    private func requireAgentSnapshot(_ engine: String) throws -> AgentSessionSnapshot {
        guard let snapshot = agentSnapshot(engine: try Self.agentEngine(engine)) else {
            throw AgentSessionError.unknownEngine(engine)
        }
        BuddyAgentSessions.shared.reconcile(snapshot)
        return snapshot
    }

    /// Reads the extras first and the session after, so the summary describes the session
    /// as it is once every await is over rather than as it was before one.
    private func summarizeAgent(_ engine: String) async throws -> ControlAPI.AgentSessionSummary {
        let extras = await agentExtras(engine: try Self.agentEngine(engine))
        return BuddyAgentSessions.shared.summary(
            of: try requireAgentSnapshot(engine), extras: extras
        )
    }

    /// Whether the app itself still holds this approval unanswered, whatever the wire says.
    private func heldApproval(_ id: String, engine: String) -> Bool {
        switch engine {
        case "codex":
            codexApprovals.contains { $0.id.uuidString == id }
        default:
            piItems.contains {
                guard case .approval = $0.kind else { return false }
                return $0.id.uuidString == id && !$0.answered
            }
        }
    }

    private func newestAgentRowID(_ engine: String) -> String? {
        switch engine {
        case "codex": codexItems.last?.id
        default: piItems.last?.id.uuidString
        }
    }

    private func agentRowCount(_ engine: String) -> Int {
        switch engine {
        case "codex": codexItems.count
        default: piItems.count
        }
    }
}

// MARK: - Seams

/// The three things an agent route reaches that a unit test must not: the models on this
/// Mac's disk and on the swarm, whether Jev's guardrail is on in the owner's own settings,
/// and `Settings.save()`, which also writes the login Keychain.
///
/// Task-local, so a test binds them for exactly the work it runs and two tests in parallel
/// cannot see each other's. Nil — the app's own behaviour — everywhere else.
enum AgentSessionSeams {
    @TaskLocal static var modelChoices: [GatewayAPI.Model]?
    @TaskLocal static var guardrails: GuardrailPosture?
    @TaskLocal static var saveSettings: (@Sendable (Settings) -> Void)?
}

/// Where the Jev guardrail stands, as far as whether anything judges an agent's calls.
enum GuardrailPosture: Sendable, Equatable {
    /// Switched off. The engines behave as they did before it existed.
    case off
    /// Switched on, but unable to judge right now — no key on this Mac, or this month's
    /// budget spent. Every call it holds goes to a person, marked "not screened".
    case unavailable
    /// Switched on and able to answer.
    case screening

    var isOn: Bool { self != .off }

    /// What Pi's calls go through. Pi's own protocol never asks, so the guardrail's gate is
    /// the only thing that can.
    var piApprovalMode: String {
        switch self {
        case .off: "unattended"
        case .unavailable: "asked"
        case .screening: "screened"
        }
    }
}

// MARK: - The ledger

/// What the app itself does not keep about an agent session, and what a phone needs:
/// which transcript this is, when each row was first seen, what model it was sent with, a
/// sequence number to catch up from, and who answered which approval.
///
/// A singleton for the same reason `BuddyGenerations` is one — `AppModel` is `@Observable`
/// and an extension cannot add stored properties to it — and `@MainActor` because every
/// caller already is.
@MainActor
public final class BuddyAgentSessions {

    public static let shared = BuddyAgentSessions()

    /// Everything remembered about one engine.
    private struct Ledger {
        /// Which transcript this is. Minted when the ledger is created — that is, once per
        /// launch — and again whenever the transcript is replaced, so a sequence number is
        /// only ever read against the transcript that issued it.
        var epoch = UUID().uuidString
        /// The session's own clock, bumped for every change worth telling a phone about.
        /// Never goes backwards within a launch, across epochs included.
        var seq = 0
        /// The clock reading at which the current epoch began — the `reset` frame's.
        var epochStartSeq = 0
        var rowSeq: [String: Int] = [:]
        var rows: [String: AppModel.AgentRow] = [:]
        var firstSeen: [String: Date] = [:]
        var model: [String: String] = [:]
        var startedAt = Date()

        var pendingApprovals: [String: AppModel.AgentPendingApproval] = [:]
        var approvalFirstSeen: [String: Date] = [:]
        /// Answered approvals, newest last, with who answered — "remote", "mac", or "gone"
        /// for a card that went without anyone answering it — and what they said. Bounded,
        /// because this is a race record and not a history.
        var resolved: [(id: String, by: String, decision: String)] = []
        /// Ids a device has claimed but whose card has not yet been observed to go. What
        /// makes the difference between "the owner answered this" and "the last request
        /// did".
        var claimed: [String: Bool] = [:]
        /// What was answered at the Mac, recorded by the two functions every answer on
        /// this machine goes through — the buttons on the card and the guardrail's own
        /// auto-answer alike — for approvals this ledger has seen waiting.
        ///
        /// Only the *decision* comes from there; that an approval stopped waiting is still
        /// noticed by sampling, so a card that goes for some other reason is still seen.
        /// Which way it went is the one thing sampling cannot recover: a Codex card is
        /// removed whichever button was pressed.
        var answeredHere: [String: Bool] = [:]
        /// Answers forwarded from a device to this engine's runtime.
        var forwarded = 0
        /// What Codex's current thread was started with. A thread keeps its approval
        /// policy and sandbox for life, so this — not the settings as they are now — is
        /// what `approvals` and `sandbox` report while it runs.
        var threadPolicy: (threadID: String, approval: String, sandbox: String)?

        /// The reading the watcher last posted frames from, and the epoch it was in. Only
        /// the watcher touches these, so a route reconciling between ticks cannot swallow
        /// a frame.
        var posted: AppModel.AgentSessionSnapshot?
        var postedEpoch: String?
    }

    /// One ledger per app *and* engine. See `AgentSessionSnapshot.owner` for why the app
    /// is half of the key.
    private struct LedgerKey: Hashable {
        var owner: ObjectIdentifier
        var engine: String
    }

    private var ledgers: [LedgerKey: Ledger] = [:]

    /// How many answered approvals are remembered per engine. Enough that a phone on a bad
    /// link can still be told "the Mac answered that" minutes later, few enough that it is
    /// not a log.
    static let rememberedResolutions = 64

    public init() {}

    /// How many times an approval answer has been forwarded from a device to one of this
    /// app's runtimes.
    ///
    /// Exported for the test that proves an approval already answered at the Mac is never
    /// forwarded a second time. `answerAgentApproval` is the only path from a device to
    /// `CodexRuntime.respond` or Pi's `extension_ui_response`, and this counts every time
    /// it takes that path, at the moment it takes it — so a change that let the race
    /// through moves this number and the test fails.
    public func forwardedAnswers(of model: AppModel) -> Int {
        let owner = model.agentLedgerOwner
        return ledgers.reduce(0) { $1.key.owner == owner ? $0 + $1.value.forwarded : $0 }
    }

    /// Which transcript an engine's rows belong to right now.
    public func epoch(of model: AppModel, engine: String) -> String? {
        ledgers[LedgerKey(owner: model.agentLedgerOwner, engine: engine)]?.epoch
    }

    /// Forgets everything remembered about one app's sessions.
    ///
    /// For tests, and scoped rather than wholesale for two reasons. A suite running beside
    /// another must not reset *its* watcher's baseline. And an `ObjectIdentifier` is an
    /// address, which the allocator may hand out again once an earlier `AppModel` has
    /// gone: clearing this app's entries as it starts is what makes that reuse harmless.
    public func forget(_ model: AppModel) {
        let owner = model.agentLedgerOwner
        for key in ledgers.keys where key.owner == owner { ledgers.removeValue(forKey: key) }
    }

    // MARK: Reconciliation

    /// Brings one engine's ledger up to date with what the app actually holds now.
    ///
    /// Idempotent and cheap: a reading identical to the last one moves nothing, which is
    /// what lets both the watcher and every route call it without arguing about the clock.
    func reconcile(_ snapshot: AppModel.AgentSessionSnapshot) {
        let key = LedgerKey(owner: snapshot.owner, engine: snapshot.engine)
        var ledger = ledgers[key] ?? Ledger()
        let now = Date()

        // A transcript that has been emptied — a new thread, a restart — shares no row
        // with the one before it. Noticed here rather than announced by the caller,
        // because "the owner pressed New Thread" reaches this file no other way. It is a
        // different transcript from here on, and says so with a new epoch.
        if !ledger.rows.isEmpty, Set(snapshot.rows.map(\.id)).isDisjoint(with: ledger.rows.keys) {
            ledger.rowSeq.removeAll()
            ledger.rows.removeAll()
            ledger.firstSeen.removeAll()
            ledger.model.removeAll()
            ledger.seq += 1
            ledger.epoch = UUID().uuidString
            ledger.epochStartSeq = ledger.seq
        }

        for row in snapshot.rows {
            if ledger.rows[row.id] == row { continue }
            if ledger.firstSeen[row.id] == nil {
                ledger.firstSeen[row.id] = now
                // The model a turn was sent with is knowable exactly once: when the row
                // appears. Stamped for whichever side sent it — the phone's own send
                // overwrites this with what it actually asked for a moment later.
                if row.kind == "user", !snapshot.sentWith.isEmpty {
                    ledger.model[row.id] = snapshot.sentWith
                }
            }
            ledger.rows[row.id] = row
            ledger.seq += 1
            ledger.rowSeq[row.id] = ledger.seq
        }

        // Approvals that have stopped waiting, and why. Three ways, and a phone needs all
        // three kept apart: a device claimed it, the owner answered it here, or it went
        // without an answer at all — a stopped engine, a restart, a sidecar that died.
        // The last is not a decision and must not read as one: nothing will run, so it is
        // reported `declined`, but nobody "answered first" and a later request for it is a
        // 404 rather than a 409 about a decision that was never made.
        let waiting = Set(snapshot.approvals.map(\.id))
        for (id, _) in ledger.pendingApprovals where !waiting.contains(id) {
            let claim = ledger.claimed.removeValue(forKey: id)
            let here = ledger.answeredHere.removeValue(forKey: id)
            let resolution: (by: String, accepted: Bool) =
                if let claim { ("remote", claim) }
                else if let here { ("mac", here) }
                else { ("gone", false) }
            ledger.resolved.append((
                id: id, by: resolution.by,
                decision: resolution.accepted ? "accepted" : "declined"
            ))
            if ledger.resolved.count > Self.rememberedResolutions {
                ledger.resolved.removeFirst(ledger.resolved.count - Self.rememberedResolutions)
            }
            ledger.pendingApprovals.removeValue(forKey: id)
            ledger.approvalFirstSeen.removeValue(forKey: id)
        }
        for approval in snapshot.approvals {
            if ledger.approvalFirstSeen[approval.id] == nil {
                ledger.approvalFirstSeen[approval.id] = now
            }
            ledger.pendingApprovals[approval.id] = approval
        }

        ledgers[key] = ledger
    }

    /// The decision recorded for a disappearance whose claim said nothing — i.e. the Mac's
    /// own answer. Only ever consulted about an id that is no longer waiting.
    func wasAnsweredOnTheMac(id: String, owner: ObjectIdentifier, engine: String) -> Bool {
        ledgers[LedgerKey(owner: owner, engine: engine)]?
            .resolved.last { $0.id == id }?.by == "mac"
    }

    /// A device is about to answer this one. Recorded before the answer is forwarded, so
    /// the reconcile that notices the card going knows who did it.
    func claimRemote(id: String, owner: ObjectIdentifier, engine: String, accept: Bool) {
        let key = LedgerKey(owner: owner, engine: engine)
        var ledger = ledgers[key] ?? Ledger()
        ledger.claimed[id] = accept
        ledgers[key] = ledger
    }

    /// The answer is going to the runtime now.
    func noteForwarded(owner: ObjectIdentifier, engine: String) {
        let key = LedgerKey(owner: owner, engine: engine)
        var ledger = ledgers[key] ?? Ledger()
        ledger.forwarded += 1
        ledgers[key] = ledger
    }

    /// An approval was answered on this Mac — by the person, or by the guardrail on their
    /// behalf. Called from the two functions every answer here goes through.
    ///
    /// Recorded only for an approval this ledger has seen waiting, which bounds it: an
    /// approval nobody was ever shown is one no device can ask about, and an entry for it
    /// would never be cleared.
    public func noteAnswerHere(
        id: String, owner: ObjectIdentifier, engine: String, accept: Bool
    ) {
        let key = LedgerKey(owner: owner, engine: engine)
        guard ledgers[key]?.pendingApprovals[id] != nil else { return }
        ledgers[key]?.answeredHere[id] = accept
    }

    /// Codex started a thread with this policy. Called from the one place that decides it.
    public func noteThreadPolicy(
        owner: ObjectIdentifier, engine: String, threadID: String, approval: String,
        sandbox: String
    ) {
        let key = LedgerKey(owner: owner, engine: engine)
        var ledger = ledgers[key] ?? Ledger()
        ledger.threadPolicy = (threadID, approval, sandbox)
        ledgers[key] = ledger
    }

    func threadPolicy(
        owner: ObjectIdentifier, engine: String, threadID: String?
    ) -> (approval: String, sandbox: String)? {
        guard let threadID,
              let policy = ledgers[LedgerKey(owner: owner, engine: engine)]?.threadPolicy,
              policy.threadID == threadID
        else { return nil }
        return (policy.approval, policy.sandbox)
    }

    func stamp(model: String, on id: String, owner: ObjectIdentifier, engine: String) {
        guard !model.isEmpty else { return }
        ledgers[LedgerKey(owner: owner, engine: engine)]?.model[id] = model
    }

    // MARK: Rendering

    func summary(
        of snapshot: AppModel.AgentSessionSnapshot, extras: AppModel.AgentSessionExtras
    ) -> ControlAPI.AgentSessionSummary {
        let ledger = ledgers[LedgerKey(owner: snapshot.owner, engine: snapshot.engine)]
            ?? Ledger()
        let newest = snapshot.rows.compactMap { ledger.firstSeen[$0.id] }.max()
        return ControlAPI.AgentSessionSummary(
            engine: snapshot.engine,
            state: snapshot.state,
            threadID: snapshot.threadID,
            epoch: ledger.epoch,
            model: extras.model,
            modelChoices: extras.modelChoices,
            cwd: extras.cwd,
            approvals: extras.approvals,
            sandbox: extras.sandbox,
            turnActive: snapshot.turnActive,
            pendingApprovals: snapshot.approvals.count,
            itemCount: snapshot.rows.count,
            updatedAt: ControlAPI.timestamp(newest ?? ledger.startedAt),
            failure: snapshot.failure
        )
    }

    func detail(
        of snapshot: AppModel.AgentSessionSnapshot, extras: AppModel.AgentSessionExtras,
        query: ControlAPI.AgentSessionQuery
    ) -> ControlAPI.AgentSessionDetail {
        let ledger = ledgers[LedgerKey(owner: snapshot.owner, engine: snapshot.engine)]
            ?? Ledger()
        let limit = min(
            max(query.limit ?? ControlAPI.agentDefaultItemLimit, 1),
            ControlAPI.agentMaximumItemLimit
        )
        var chosen = snapshot.rows
        var complete = true
        if let watermark = Self.watermark(query, in: ledger) {
            let slice = snapshot.rows.filter { (ledger.rowSeq[$0.id] ?? 0) > watermark }
            // A slice that does not fit would leave out its oldest changes, and a client
            // merging it would be silently out of date. The transcript's tail, said to be
            // the transcript's tail, is the honest answer.
            if slice.count <= limit {
                chosen = slice
                complete = false
            }
        }
        let omitted = max(0, chosen.count - limit)
        return ControlAPI.AgentSessionDetail(
            session: summary(of: snapshot, extras: extras),
            items: chosen.suffix(limit).map { item(from: $0, in: ledger) },
            approvals: snapshot.approvals.map { wire($0, in: ledger) },
            seq: ledger.seq,
            epoch: ledger.epoch,
            complete: complete,
            omitted: omitted
        )
    }

    /// What `?since=` actually means, or nil for "start from the beginning".
    ///
    /// Nil for a cursor from another transcript — another epoch, including one from before
    /// this app last launched — and for a sequence this transcript never reached. All of
    /// those are a caller asking to continue from somewhere that no longer exists, and the
    /// honest answer is the transcript itself, said so by `complete`.
    private static func watermark(
        _ query: ControlAPI.AgentSessionQuery, in ledger: Ledger
    ) -> Int? {
        guard let since = query.since, let epoch = query.epoch, epoch == ledger.epoch,
              since >= ledger.epochStartSeq, since <= ledger.seq
        else { return nil }
        return since
    }

    private func item(
        from row: AppModel.AgentRow, in ledger: Ledger
    ) -> ControlAPI.AgentItem {
        ControlAPI.AgentItem(
            id: row.id, kind: row.kind, text: row.text, output: row.output,
            truncated: row.truncated, status: row.status, model: ledger.model[row.id],
            at: ControlAPI.timestamp(ledger.firstSeen[row.id] ?? ledger.startedAt)
        )
    }

    private func wire(
        _ approval: AppModel.AgentPendingApproval, in ledger: Ledger
    ) -> ControlAPI.AgentApproval {
        ControlAPI.AgentApproval(
            id: approval.id, kind: approval.kind, summary: approval.summary,
            reason: approval.reason, screening: approval.screening,
            requestedAt: ControlAPI.timestamp(
                ledger.approvalFirstSeen[approval.id] ?? ledger.startedAt
            )
        )
    }

    // MARK: Frames

    /// What changed since the watcher last posted, as `/events` frames, in `seq` order.
    ///
    /// Call `reconcile` first: this reads the sequence numbers that assigns. Only the
    /// watcher calls this, which is what keeps the coalescing promise — a route
    /// reconciling twenty times a second does not turn into twenty frames a second.
    ///
    /// The first reading after the watcher starts posts nothing: it is the baseline. A
    /// phone that has just connected is sent `openingFrames` from that same reading, so
    /// what it is opened with and what changes after it cannot have a gap between them.
    func frames(from snapshot: AppModel.AgentSessionSnapshot) -> [BuddyEvent] {
        let key = LedgerKey(owner: snapshot.owner, engine: snapshot.engine)
        var ledger = ledgers[key] ?? Ledger()
        defer { ledgers[key] = ledger }
        let previous = ledger.posted
        let previousEpoch = ledger.postedEpoch
        ledger.posted = snapshot
        ledger.postedEpoch = ledger.epoch
        guard let previous, let previousEpoch else { return [] }

        var events: [ControlAPI.AgentEvent] = []
        func next() -> Int {
            ledger.seq += 1
            return ledger.seq
        }
        func event(
            _ kind: String, seq: Int, item: ControlAPI.AgentItem? = nil,
            approval: ControlAPI.AgentApproval? = nil, turnActive: Bool? = nil,
            state: String? = nil
        ) -> ControlAPI.AgentEvent {
            ControlAPI.AgentEvent(
                engine: snapshot.engine, kind: kind, seq: seq, epoch: ledger.epoch,
                threadID: snapshot.threadID, item: item, approval: approval,
                turnActive: turnActive, state: state
            )
        }

        if previousEpoch != ledger.epoch {
            // A different transcript. One frame says so and carries everything a phone
            // needs to start again; the old rows and the old cards need no frames of their
            // own, because the reset has already told the phone to drop them.
            events.append(event(
                "reset", seq: ledger.epochStartSeq, turnActive: snapshot.turnActive,
                state: snapshot.state
            ))
            for row in snapshot.rows {
                events.append(event(
                    "item", seq: ledger.rowSeq[row.id] ?? ledger.seq,
                    item: item(from: row, in: ledger)
                ))
            }
            for approval in snapshot.approvals {
                events.append(event(
                    "approval", seq: next(), approval: wire(approval, in: ledger),
                    state: "pending"
                ))
            }
        } else {
            if previous.state != snapshot.state || previous.threadID != snapshot.threadID {
                events.append(event("state", seq: next(), state: snapshot.state))
            }
            if previous.turnActive != snapshot.turnActive {
                events.append(event("turn", seq: next(), turnActive: snapshot.turnActive))
            }
            let before = Dictionary(
                previous.rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }
            )
            for row in snapshot.rows where before[row.id] != row {
                // The row's own sequence, not a fresh one: this is the number a phone
                // hands back as `?since=`, and it has to name the row it saw.
                events.append(event(
                    "item", seq: ledger.rowSeq[row.id] ?? ledger.seq,
                    item: item(from: row, in: ledger)
                ))
            }
            let waiting = Set(snapshot.approvals.map(\.id))
            for gone in previous.approvals where !waiting.contains(gone.id) {
                // Resolved — by the owner at the Mac, by the guardrail, or by a phone. All
                // three end the same way for every other screen: the card goes, and says
                // which way it went.
                let outcome = ledger.resolved.last { $0.id == gone.id }
                events.append(event(
                    "approval", seq: next(), approval: wire(gone, in: ledger),
                    state: outcome?.decision ?? "declined"
                ))
            }
            let had = Set(previous.approvals.map(\.id))
            for fresh in snapshot.approvals where !had.contains(fresh.id) {
                events.append(event(
                    "approval", seq: next(), approval: wire(fresh, in: ledger),
                    state: "pending"
                ))
            }
        }
        // Rows carry the sequence they were given when a route or the watcher first saw
        // them change, which can be earlier than a frame made just now. Sorted, a phone
        // resuming from the last frame it read has read everything below it.
        return events.sorted { $0.seq < $1.seq }.map { .agent($0) }
    }

    /// What a phone that has just connected is told: the session's state, whether a turn
    /// is running, and every card waiting — all at the current `seq`, so everything it is
    /// sent afterwards is newer. The transcript itself it fetches: a hundred rows do not
    /// belong on a side channel.
    func openingFrames(for snapshot: AppModel.AgentSessionSnapshot) -> [BuddyEvent] {
        let ledger = ledgers[LedgerKey(owner: snapshot.owner, engine: snapshot.engine)]
            ?? Ledger()
        func event(
            _ kind: String, approval: ControlAPI.AgentApproval? = nil,
            turnActive: Bool? = nil, state: String? = nil
        ) -> BuddyEvent {
            .agent(ControlAPI.AgentEvent(
                engine: snapshot.engine, kind: kind, seq: ledger.seq, epoch: ledger.epoch,
                threadID: snapshot.threadID, approval: approval, turnActive: turnActive,
                state: state
            ))
        }
        return [
            event("state", state: snapshot.state),
            event("turn", turnActive: snapshot.turnActive),
        ] + snapshot.approvals.map {
            event("approval", approval: wire($0, in: ledger), state: "pending")
        }
    }
}

// MARK: - The watchers' shared bookkeeping

/// What a watcher is currently watching: one app, one hub.
///
/// Both pumps are singletons — `AppModel` is `@Observable`, so an extension cannot hold
/// their task — and a singleton has to be able to tell "already running" from "running
/// against something else". In the app there is one of each and this never changes; under
/// a test suite there is a fresh hub per case, and a pump that answered "already running"
/// to those would keep feeding a hub nobody reads while the reader that just arrived got
/// nothing but heartbeats.
struct WatchTarget: Equatable {
    var model: ObjectIdentifier
    var hub: ObjectIdentifier

    init(model: AppModel, hub: BuddyEventHub) {
        self.model = ObjectIdentifier(model)
        self.hub = ObjectIdentifier(hub)
    }
}

// MARK: - The watcher

/// Samples both agent sessions while somebody allowed to see them is reading `/events`,
/// and posts what moved.
///
/// The interval is the coalescing rule, not a performance knob: Codex and Pi stream prose a
/// token at a time, and a frame per token would be a hundred a second down a phone's radio
/// for text the reader cannot follow that fast. Ten readings a second is faster than the
/// eye and two orders of magnitude cheaper — and because a reading carries the row whole,
/// a phone that misses one has missed nothing.
///
/// It runs only while the hub has an audience for agent frames — this Mac's own token or a
/// full-control device. A chat-only phone or the swarm on `/events` does not start it:
/// reading transcripts for subscribers that will never be sent them is main-actor time
/// spent on nothing.
@MainActor
public final class AgentEventPump {

    public static let shared = AgentEventPump()

    /// Ten a second, per engine, per row.
    public static let interval: Duration = .milliseconds(100)

    private var task: Task<Void, Never>?
    /// Bumped on every stop, so a task winding down can tell whether the handle it is about
    /// to clear is still its own.
    private var generation = UUID()
    /// Incremented on every start request — see `BuddyEventPump.shouldStop` for the race
    /// this closes; it is the same one, and getting it wrong the same way would leave a
    /// phone watching a session that never reports.
    private var startRequests = 0
    /// What the running loop is watching. See `WatchTarget`.
    private var watching: WatchTarget?
    /// What the running loop last read of `PaidLanes.allowed`. See `BuddyEventPump`.
    private(set) var paidLanesOpenInLoop: Bool?

    public init() {}

    public var isRunning: Bool { task != nil }

    func start(
        watching model: AppModel, hub: BuddyEventHub = .shared,
        interval: Duration = AgentEventPump.interval
    ) {
        startRequests += 1
        let target = WatchTarget(model: model, hub: hub)
        if task != nil, watching == target { return }
        if task != nil { stop() }
        watching = target
        let mine = UUID()
        generation = mine
        // Started by a subscriber's request, like `BuddyEventPump`, and for the same reason
        // with the paid lanes open: see `PaidLanes.forTheApp`.
        task = PaidLanes.forTheApp {
            Task { [weak self, weak model] in
                while !Task.isCancelled {
                    guard let self, let model else { break }
                    self.paidLanesOpenInLoop = PaidLanes.allowed
                    let requestsBefore = self.startRequests
                    let audience = await hub.agentAudienceCount
                    if audience == 0, self.startRequests == requestsBefore {
                        if self.generation == mine { self.stop() }
                        return
                    }
                    // Taken before the reading, so a phone that arrives after it is picked up
                    // on the next one rather than being handed an opening older than frames it
                    // has already been sent.
                    let newcomers = await hub.takeNewAgentSubscribers()
                    for snapshot in model.agentSnapshots() {
                        BuddyAgentSessions.shared.reconcile(snapshot)
                        let changes = BuddyAgentSessions.shared.frames(from: snapshot)
                        if !changes.isEmpty {
                            // Not to the newcomers: their opening, below, is this same reading,
                            // and changes leading up to it would arrive with smaller numbers
                            // than it after it.
                            await hub.post(changes, excluding: newcomers)
                        }
                        if !newcomers.isEmpty {
                            await hub.post(
                                BuddyAgentSessions.shared.openingFrames(for: snapshot),
                                to: newcomers
                            )
                        }
                    }
                    guard (try? await Task.sleep(for: interval)) != nil else { break }
                }
                if self?.generation == mine { self?.task = nil }
            }
        }
    }

    public func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        watching = nil
    }
}
