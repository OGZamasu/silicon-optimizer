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
        var status: String?

        init(
            id: String, kind: String, text: String, output: String? = nil,
            status: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            // An empty string is nothing said, and a key whose value is "" is a field a
            // phone has to special-case. Dropped here, once, rather than there.
            self.output = (output?.isEmpty ?? true) ? nil : output
            self.status = status
        }
    }

    /// One call held at the gate, before the ledger stamps when it arrived.
    struct AgentPendingApproval: Sendable, Equatable {
        var id: String
        var kind: String
        var summary: String
        var reason: String?
    }

    /// A whole session as one reading. Diffed against the last one to produce frames, and
    /// rendered into `ControlAPI` shapes to answer a route.
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
        var model: String
        var modelChoices: [ControlAPI.AgentModelChoice]
        var cwd: String
        var turnActive: Bool
        var rows: [AgentRow]
        var approvals: [AgentPendingApproval]
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
            model: codexSelectedModel,
            modelChoices: Self.agentChoices(codexModelChoices),
            cwd: codexWorkingDirectory.path,
            turnActive: codexTurnActive,
            rows: codexItems.map { Self.agentRow(codex: $0) },
            approvals: codexApprovals.map { approval in
                AgentPendingApproval(
                    id: approval.id.uuidString,
                    kind: {
                        switch approval.kind {
                        case .command: "command"
                        case .fileChange: "fileChange"
                        }
                    }(),
                    summary: approval.kind.arguments,
                    reason: approval.reason
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
            model: piCurrentModel ?? settings.piModel ?? "",
            modelChoices: Self.agentChoices(piModelChoices),
            cwd: PiRuntime.workspaceDirectory.path,
            turnActive: piBusy,
            rows: piItems.map { Self.agentRow(pi: $0) },
            approvals: piItems.compactMap { item in
                guard case .approval(_, let tool) = item.kind, !item.answered else {
                    return nil
                }
                return AgentPendingApproval(
                    id: item.id.uuidString, kind: "tool",
                    summary: "\(tool) \(item.text)"
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    // Pi's gate is this app's own extension, and it asks nothing beyond
                    // "may this run?" — so there is no reason to pass on, and inventing
                    // one would be putting words in the agent's mouth.
                    reason: nil
                )
            }
        )
    }

    /// Reads the live session and brings the ledger up to date, without posting anything.
    ///
    /// Every route calls this before it answers, which is what makes a 409 honest when
    /// nobody has an `/events` stream open: an approval the owner answered at the Mac an
    /// hour ago is recorded here, at the moment the phone asks, rather than only by a
    /// watcher that was not running.
    /// This app's half of the agent ledger's key. See `AgentSessionSnapshot.owner`.
    var agentLedgerOwner: ObjectIdentifier { ObjectIdentifier(self) }

    @discardableResult
    func refreshAgentLedger(engine: String) -> AgentSessionSnapshot? {
        guard let snapshot = agentSnapshot(engine: engine) else { return nil }
        BuddyAgentSessions.shared.reconcile(snapshot)
        return snapshot
    }

    // MARK: - ControlHost

    public func agentSessions() async -> ControlAPI.AgentSessionList {
        ControlAPI.AgentSessionList(sessions: agentSnapshots().map { snapshot in
            BuddyAgentSessions.shared.reconcile(snapshot)
            return BuddyAgentSessions.shared.summary(of: snapshot)
        })
    }

    public func agentSession(
        engine: String, since: String?
    ) async throws -> ControlAPI.AgentSessionDetail {
        let snapshot = try requireAgentSnapshot(engine)
        return BuddyAgentSessions.shared.detail(of: snapshot, since: since)
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
            startPiIfNeeded()
        }
        return try summarizeAgent(engine)
    }

    public func newAgentThread(engine: String) async throws -> ControlAPI.AgentSessionSummary {
        switch try Self.agentEngine(engine) {
        case "codex":
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
        return try summarizeAgent(engine)
    }

    public func stopAgentSession(engine: String) async throws -> ControlAPI.AgentSessionSummary {
        switch try Self.agentEngine(engine) {
        case "codex": stopCodex()
        default: stopPi()
        }
        return try summarizeAgent(engine)
    }

    public func interruptAgentSession(
        engine: String
    ) async throws -> ControlAPI.AgentSessionSummary {
        let snapshot = try requireAgentSnapshot(engine)
        guard snapshot.state == "running" else {
            throw AgentSessionError.notRunning(snapshot.engine)
        }
        switch snapshot.engine {
        case "codex": interruptCodexTurn()
        default: abortPi()
        }
        return try summarizeAgent(snapshot.engine)
    }

    public func sendAgentMessage(
        engine: String, _ request: ControlAPI.AgentMessageRequest
    ) async throws -> ControlAPI.AgentMessageAccepted {
        let snapshot = try requireAgentSnapshot(engine)
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw AgentSessionError.emptyMessage }
        // Checked before the engine is asked, so a picked model that does not exist is a
        // 400 rather than a turn answered by a different model than the one on screen.
        if let asked = request.model, !asked.isEmpty {
            guard snapshot.modelChoices.contains(where: { $0.id == asked }) else {
                throw AgentSessionError.unknownModel(asked)
            }
        }
        guard snapshot.state == "running" else {
            throw AgentSessionError.notRunning(snapshot.engine)
        }

        // Read before, compared after: "the newest row" is only the row this send became
        // if a row actually appeared. An engine that is `running` but whose sidecar has
        // gone underneath it drops the message silently, and handing back the id of
        // somebody else's row would be worse than saying no.
        let before = agentRowCount(snapshot.engine)

        let model: String
        switch snapshot.engine {
        case "codex":
            if let asked = request.model, !asked.isEmpty {
                settings.codexModel = asked
                settings.save()
            }
            model = codexSelectedModel
            sendCodexMessage(text)
        default:
            if let asked = request.model, !asked.isEmpty { setPiModel(asked) }
            model = piCurrentModel ?? ""
            sendPiMessage(text)
        }

        // Both engines append the row synchronously — it is on the Mac's screen before
        // this returns — so the newest row is this send, provided there is a new one.
        guard agentRowCount(snapshot.engine) > before,
              let id = newestAgentRowID(snapshot.engine)
        else { throw AgentSessionError.notRunning(snapshot.engine) }
        refreshAgentLedger(engine: snapshot.engine)
        BuddyAgentSessions.shared.stamp(
            model: model, on: id, owner: agentLedgerOwner, engine: snapshot.engine
        )
        return ControlAPI.AgentMessageAccepted(itemID: id)
    }

    public func answerAgentApproval(
        engine: String, id: String, decision: String
    ) async throws -> ControlAPI.AgentApprovalResult {
        guard ControlAPI.agentApprovalDecisions.contains(decision) else {
            throw AgentSessionError.unknownDecision(decision)
        }
        let accept = decision == "accept"
        // Before anything is looked up: an answer given at the Mac while nothing was
        // watching is recorded now, which is what turns the race below into a 409 rather
        // than a second `respond` to the runtime.
        let snapshot = try requireAgentSnapshot(engine)

        guard snapshot.approvals.contains(where: { $0.id == id }) else {
            // Not waiting. Either the Mac answered it — which the caller should be told,
            // because the decision was made and nothing failed — or it never existed.
            if BuddyAgentSessions.shared.wasAnsweredOnTheMac(
                id: id, owner: agentLedgerOwner, engine: snapshot.engine
            ) {
                throw AgentSessionError.answeredOnTheMac(id)
            }
            throw AgentSessionError.unknownApproval(id)
        }

        // Claimed before it is forwarded, so the reconcile that follows records this as
        // the phone's answer rather than the Mac's — and so a second request for the same
        // id finds it already gone. This is the only path from a device to a runtime's
        // `respond`, and it runs once per id by construction.
        BuddyAgentSessions.shared.claimRemote(
            id: id, owner: agentLedgerOwner, engine: snapshot.engine, accept: accept
        )
        switch snapshot.engine {
        case "codex":
            guard let approval = codexApprovals.first(where: { $0.id.uuidString == id })
            else { throw AgentSessionError.unknownApproval(id) }
            answerCodexApproval(approval, accept: accept)
        default:
            guard let card = piItems.first(where: {
                $0.id.uuidString == id && !$0.answered
            }) else { throw AgentSessionError.unknownApproval(id) }
            answerPiApproval(card, allow: accept)
        }
        return ControlAPI.AgentApprovalResult(
            id: id, decision: accept ? "accepted" : "declined",
            session: try summarizeAgent(snapshot.engine)
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

    private func summarizeAgent(_ engine: String) throws -> ControlAPI.AgentSessionSummary {
        BuddyAgentSessions.shared.summary(of: try requireAgentSnapshot(engine))
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

// MARK: - The ledger

/// What the app itself does not keep about an agent session, and what a phone needs:
/// when each row was first seen, what model it was sent with, a sequence number to catch up
/// from, and who answered which approval.
///
/// A singleton for the same reason `BuddyGenerations` is one — `AppModel` is `@Observable`
/// and an extension cannot add stored properties to it — and `@MainActor` because every
/// caller already is.
@MainActor
public final class BuddyAgentSessions {

    public static let shared = BuddyAgentSessions()

    /// Everything remembered about one engine.
    private struct Ledger {
        /// The session's own clock. Bumped for every change worth telling a phone about,
        /// and the number `?since=` takes.
        var seq = 0
        var rowSeq: [String: Int] = [:]
        var rows: [String: AppModel.AgentRow] = [:]
        var firstSeen: [String: Date] = [:]
        var model: [String: String] = [:]
        /// The order rows were first seen in, so a catch-up answers them the way the
        /// transcript reads rather than the way a dictionary iterates.
        var order: [String] = []
        var startedAt = Date()
        /// The clock reading at the last time this transcript was emptied — a new thread,
        /// a restart, a stop. A `?since=` from before it cannot be caught up, only
        /// replaced, and `complete` is how the answer says so.
        var clearedAt = 0

        var pendingApprovals: [String: AppModel.AgentPendingApproval] = [:]
        var approvalFirstSeen: [String: Date] = [:]
        /// Answered approvals, newest last, with who answered and what they said. Bounded,
        /// because this is a race record and not a history.
        var resolved: [(id: String, by: String, decision: String)] = []
        /// Ids a device has claimed but whose card has not yet been observed to go. What
        /// makes the difference between "the owner answered this" and "the last request
        /// did".
        var claimed: [String: Bool] = [:]
        /// What was answered at the Mac, recorded by the two functions every answer on
        /// this machine goes through — the buttons on the card and the guardrail's own
        /// auto-answer alike.
        ///
        /// Only the *decision* comes from there; that an approval stopped waiting is still
        /// noticed by sampling, so a card that goes for some other reason is still seen.
        /// Which way it went is the one thing sampling cannot recover: a Codex card is
        /// removed whichever button was pressed.
        var answeredHere: [String: Bool] = [:]

        /// The snapshot the pump last posted frames from. Only the pump touches it, so a
        /// route reconciling between ticks cannot swallow a frame.
        var posted: AppModel.AgentSessionSnapshot?

        /// How many times a device's answer has been forwarded to this engine's runtime.
        /// See `forwardedAnswers(of:)`.
        var forwarded = 0
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
    /// it takes that path — so a change that let the race through moves this number and
    /// the test fails.
    public func forwardedAnswers(of model: AppModel) -> Int {
        let owner = model.agentLedgerOwner
        return ledgers.reduce(0) { $1.key.owner == owner ? $0 + $1.value.forwarded : $0 }
    }

    /// Forgets everything remembered about one app's sessions.
    ///
    /// For tests, and scoped rather than wholesale for two reasons. A suite running beside
    /// another must not reset *its* watcher's baseline — a watcher that finds no previous
    /// reading reports the session rather than what changed in it, so a wipe from the
    /// outside looks to a phone like a stream that has gone quiet. And an
    /// `ObjectIdentifier` is an address, which the allocator may hand out again once an
    /// earlier `AppModel` has gone: clearing this app's entries as it starts is what makes
    /// that reuse harmless.
    public func forget(_ model: AppModel) {
        let owner = model.agentLedgerOwner
        for key in ledgers.keys where key.owner == owner { ledgers.removeValue(forKey: key) }
    }

    // MARK: Reconciliation

    /// Brings one engine's ledger up to date with what the app actually holds now.
    ///
    /// Idempotent and cheap: a reading identical to the last one moves nothing, which is
    /// what lets both the pump and every route call it without arguing about the clock.
    func reconcile(_ snapshot: AppModel.AgentSessionSnapshot) {
        let key = LedgerKey(owner: snapshot.owner, engine: snapshot.engine)
        var ledger = ledgers[key] ?? Ledger()
        let now = Date()

        let ids = snapshot.rows.map(\.id)
        // A transcript that has been emptied — a new thread, a restart — shares no row
        // with the one before it. Noticed here rather than announced by the caller,
        // because "the owner pressed New Thread" reaches this file no other way.
        if !ledger.rows.isEmpty, Set(ids).isDisjoint(with: ledger.rows.keys) {
            ledger.rowSeq.removeAll()
            ledger.rows.removeAll()
            ledger.firstSeen.removeAll()
            ledger.model.removeAll()
            ledger.order.removeAll()
            ledger.seq += 1
            ledger.clearedAt = ledger.seq
        }

        for row in snapshot.rows {
            if ledger.rows[row.id] == row { continue }
            if ledger.firstSeen[row.id] == nil {
                ledger.firstSeen[row.id] = now
                ledger.order.append(row.id)
                // The model a turn was sent with is knowable exactly once: when the row
                // appears. Stamped for whichever side sent it — the phone's own send
                // overwrites this with what it actually asked for a moment later.
                if row.kind == "user" { ledger.model[row.id] = snapshot.model }
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
        ledger.forwarded += 1
        ledgers[key] = ledger
    }

    /// An approval was answered on this Mac — by the person, or by the guardrail on their
    /// behalf. Called from the two functions every answer here goes through.
    ///
    /// Only the decision: whether a card is still waiting is read from the app's own state
    /// every time anything asks, so an approval that goes away without passing through
    /// here is still noticed. This is what a *phone* needs in order to take the card down
    /// the right way — an accept and a decline both remove a Codex card, and the frame
    /// has to say which happened.
    public func noteAnswerHere(
        id: String, owner: ObjectIdentifier, engine: String, accept: Bool
    ) {
        let key = LedgerKey(owner: owner, engine: engine)
        var ledger = ledgers[key] ?? Ledger()
        ledger.answeredHere[id] = accept
        ledgers[key] = ledger
    }

    func stamp(model: String, on id: String, owner: ObjectIdentifier, engine: String) {
        guard !model.isEmpty else { return }
        ledgers[LedgerKey(owner: owner, engine: engine)]?.model[id] = model
    }

    // MARK: Rendering

    func summary(of snapshot: AppModel.AgentSessionSnapshot) -> ControlAPI.AgentSessionSummary {
        let ledger = ledgers[LedgerKey(owner: snapshot.owner, engine: snapshot.engine)]
            ?? Ledger()
        let newest = snapshot.rows.compactMap { ledger.firstSeen[$0.id] }.max()
        return ControlAPI.AgentSessionSummary(
            engine: snapshot.engine,
            state: snapshot.state,
            threadID: snapshot.threadID,
            model: snapshot.model,
            modelChoices: snapshot.modelChoices,
            cwd: snapshot.cwd,
            turnActive: snapshot.turnActive,
            pendingApprovals: snapshot.approvals.count,
            itemCount: snapshot.rows.count,
            updatedAt: ControlAPI.timestamp(newest ?? ledger.startedAt),
            failure: snapshot.failure
        )
    }

    func detail(
        of snapshot: AppModel.AgentSessionSnapshot, since: String?
    ) -> ControlAPI.AgentSessionDetail {
        let ledger = ledgers[LedgerKey(owner: snapshot.owner, engine: snapshot.engine)]
            ?? Ledger()
        let watermark = Self.watermark(since, in: ledger)
        let items = snapshot.rows
            .filter { (ledger.rowSeq[$0.id] ?? 0) > (watermark ?? 0) }
            .map { item(from: $0, in: ledger) }
        return ControlAPI.AgentSessionDetail(
            session: summary(of: snapshot),
            items: items,
            approvals: snapshot.approvals.map { approval in
                ControlAPI.AgentApproval(
                    id: approval.id, kind: approval.kind, summary: approval.summary,
                    reason: approval.reason,
                    requestedAt: ControlAPI.timestamp(
                        ledger.approvalFirstSeen[approval.id] ?? ledger.startedAt
                    )
                )
            },
            seq: ledger.seq,
            complete: watermark == nil
        )
    }

    /// What `?since=` actually means, or nil for "start from the beginning".
    ///
    /// A number is a sequence; anything else is an item id and answers that row's
    /// sequence. Nil for a number this session has not reached, an id it does not know,
    /// and anything from before the transcript was last emptied — all three are a caller
    /// asking to continue from somewhere that no longer exists, and the honest answer to
    /// that is the whole transcript, said so by `complete`.
    private static func watermark(_ since: String?, in ledger: Ledger) -> Int? {
        guard let since, !since.isEmpty else { return nil }
        let asked: Int
        if let number = Int(since) {
            guard number >= 0, number <= ledger.seq else { return nil }
            asked = number
        } else if let known = ledger.rowSeq[since] {
            asked = known
        } else {
            return nil
        }
        guard asked >= ledger.clearedAt else { return nil }
        return asked
    }

    private func item(
        from row: AppModel.AgentRow, in ledger: Ledger
    ) -> ControlAPI.AgentItem {
        ControlAPI.AgentItem(
            id: row.id, kind: row.kind, text: row.text, output: row.output,
            status: row.status, model: ledger.model[row.id],
            at: ControlAPI.timestamp(ledger.firstSeen[row.id] ?? ledger.startedAt)
        )
    }

    // MARK: Frames

    /// What changed since the pump last posted, as `/events` frames.
    ///
    /// Call `reconcile` first: this reads the sequence numbers that assigns. Only the pump
    /// calls this, which is what keeps the coalescing promise — a route reconciling twenty
    /// times a second does not turn into twenty frames a second.
    func frames(from snapshot: AppModel.AgentSessionSnapshot) -> [BuddyEvent] {
        let key = LedgerKey(owner: snapshot.owner, engine: snapshot.engine)
        var ledger = ledgers[key] ?? Ledger()
        defer { ledgers[key] = ledger }
        let previous = ledger.posted
        ledger.posted = snapshot
        // A phone that has just connected knows nothing, so the first reading is not
        // "nothing changed" — it is the state and the turn, which is what a freshly opened
        // screen needs before any delta means anything. The transcript itself it fetches,
        // because a hundred rows do not belong on a side channel.
        guard let previous else {
            var opening = [
                agentEvent(&ledger, snapshot, kind: "state", state: snapshot.state),
                agentEvent(&ledger, snapshot, kind: "turn", turnActive: snapshot.turnActive),
            ]
            for approval in snapshot.approvals {
                opening.append(agentEvent(
                    &ledger, snapshot, kind: "approval",
                    approval: wire(approval, in: ledger), state: "pending"
                ))
            }
            return opening
        }

        var events: [BuddyEvent] = []
        if previous.state != snapshot.state {
            events.append(agentEvent(&ledger, snapshot, kind: "state", state: snapshot.state))
        }
        if previous.turnActive != snapshot.turnActive {
            events.append(agentEvent(
                &ledger, snapshot, kind: "turn", turnActive: snapshot.turnActive
            ))
        }

        let before = Dictionary(
            previous.rows.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last }
        )
        for row in snapshot.rows where before[row.id] != row {
            events.append(.agent(ControlAPI.AgentEvent(
                engine: snapshot.engine, kind: "item",
                // The row's own sequence, not a fresh one: this is the number a phone
                // hands back as `?since=`, and it has to name the row it saw.
                seq: ledger.rowSeq[row.id] ?? ledger.seq,
                item: item(from: row, in: ledger)
            )))
        }

        let waiting = Set(snapshot.approvals.map(\.id))
        for gone in previous.approvals where !waiting.contains(gone.id) {
            // Resolved — by the owner at the Mac, by the guardrail, or by a phone. All
            // three end the same way for every other screen: the card goes, and says which
            // way it went.
            let outcome = ledger.resolved.last { $0.id == gone.id }
            events.append(agentEvent(
                &ledger, snapshot, kind: "approval",
                approval: wire(gone, in: ledger),
                state: outcome?.decision ?? "declined"
            ))
        }
        let had = Set(previous.approvals.map(\.id))
        for fresh in snapshot.approvals where !had.contains(fresh.id) {
            events.append(agentEvent(
                &ledger, snapshot, kind: "approval",
                approval: wire(fresh, in: ledger), state: "pending"
            ))
        }
        return events
    }

    private func wire(
        _ approval: AppModel.AgentPendingApproval, in ledger: Ledger
    ) -> ControlAPI.AgentApproval {
        ControlAPI.AgentApproval(
            id: approval.id, kind: approval.kind, summary: approval.summary,
            reason: approval.reason,
            requestedAt: ControlAPI.timestamp(
                ledger.approvalFirstSeen[approval.id] ?? ledger.startedAt
            )
        )
    }

    /// A frame that is not about one row, and so takes the next number on the session's
    /// clock rather than a row's.
    private func agentEvent(
        _ ledger: inout Ledger, _ snapshot: AppModel.AgentSessionSnapshot,
        kind: String, approval: ControlAPI.AgentApproval? = nil,
        turnActive: Bool? = nil, state: String? = nil
    ) -> BuddyEvent {
        ledger.seq += 1
        return .agent(ControlAPI.AgentEvent(
            engine: snapshot.engine, kind: kind, seq: ledger.seq,
            approval: approval, turnActive: turnActive, state: state
        ))
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

/// Samples both agent sessions while somebody is reading `/events`, and posts what moved.
///
/// The interval is the coalescing rule, not a performance knob: Codex and Pi stream prose a
/// token at a time, and a frame per token would be a hundred a second down a phone's radio
/// for text the reader cannot follow that fast. Ten readings a second is faster than the
/// eye and two orders of magnitude cheaper — and because a reading carries the row whole,
/// a phone that misses one has missed nothing.
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
        task = Task { [weak self, weak model] in
            while !Task.isCancelled {
                guard let self, let model else { break }
                let requestsBefore = self.startRequests
                let subscribers = await hub.subscriberCount
                if subscribers == 0, self.startRequests == requestsBefore {
                    if self.generation == mine { self.task = nil }
                    return
                }
                for snapshot in model.agentSnapshots() {
                    BuddyAgentSessions.shared.reconcile(snapshot)
                    for event in BuddyAgentSessions.shared.frames(from: snapshot) {
                        await hub.post(event)
                    }
                }
                guard (try? await Task.sleep(for: interval)) != nil else { break }
            }
            if self?.generation == mine { self?.task = nil }
        }
    }

    public func stop() {
        generation = UUID()
        task?.cancel()
        task = nil
        watching = nil
    }
}
