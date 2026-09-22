import Foundation

/// The agent sessions a phone can see and drive: the Chat tab's Codex and Pi engines,
/// mirrored rather than duplicated.
///
/// There is one session per engine and it is *the* session — the same thread the owner is
/// looking at on the Mac, the same items, the same approvals. A phone is a second screen
/// on it, not a second seat: sending from the phone appends to the Mac's transcript, and an
/// approval answered on either side is answered once, for both. That is why the session id
/// is simply the engine id and there is no registry of threads here — a registry would be
/// a second place for the truth to live.
///
/// Every one of these routes runs commands on this Mac, so they are full scope only — and
/// so is what they reveal. A chat-only device is refused by the scope gate before it
/// reaches any of them, the swarm token is refused at the route, and neither is sent an
/// `agent` frame on `/events`: a transcript carries the commands an agent ran and what
/// they printed, which is exactly what those two were not given.
extension ControlAPI {

    /// The engines that have a session. Exported so a generated client can enumerate them
    /// without hard-coding two strings, and so `ContractExportTests` and the server cannot
    /// drift into offering different ones.
    public static let agentEngines = ["codex", "pi"]

    /// What a session is doing, as a phone needs to show it.
    ///
    /// Four words, and `stopping` is deliberately not among them: an engine on its way down
    /// is reported `stopped`, because the only thing a phone can do about either is offer to
    /// start it, and a fifth word would be a state its buttons could not act on.
    public static let agentSessionStates = ["stopped", "starting", "running", "failed"]

    /// Whether anything stands between the agent and this Mac, in the three answers a phone
    /// has to be able to tell apart before it hands the agent a task.
    ///
    /// - `screened` — the agent asks before it acts, and the Jev guardrail judges each ask
    ///   before a person sees it.
    /// - `asked` — the agent asks, and a person decides; nothing screens it first. That
    ///   includes the guardrail switched on but unable to judge — no key on the Mac, or
    ///   this month's budget spent — when every call reaches a person marked "not screened".
    /// - `unattended` — nothing asks. Codex under the "never ask" policy, and Pi whenever
    ///   the guardrail is off: Pi's own protocol has no permission request, so without the
    ///   guardrail's gate its tools simply run.
    public static let agentApprovalModes = ["screened", "asked", "unattended"]

    /// Codex's sandbox modes, plus `none` for Pi, whose tools run as this Mac's user.
    public static let agentSandboxes = [
        "read-only", "workspace-write", "danger-full-access", "none",
    ]

    /// The kinds of row a transcript has, in the one vocabulary both engines are mapped
    /// onto. Codex's typed items and Pi's RPC events say different words for the same
    /// things; a phone should learn one set.
    public static let agentItemKinds = [
        "user", "assistant", "reasoning", "command", "fileChange", "tool", "notice", "error",
    ]

    /// What a row that has a lifecycle is doing. Absent on rows that have none — prose has
    /// no status, and inventing "completed" for a sentence would be a fact the engine never
    /// reported.
    public static let agentItemStatuses = ["running", "completed", "failed", "declined"]

    /// How much of a row's `output` travels, in characters, counted from the end.
    ///
    /// The tail rather than the head because the end of a build log is where the error is,
    /// and because a running command's output grows at the end — which is the part a
    /// reader is watching. Beyond this the row says `truncated: true` and the Mac keeps the
    /// rest. Ten readings a second of an uncapped log is how a phone's radio would be spent.
    public static let agentOutputLimit = 8_192

    /// How many rows `GET /agent/sessions/{engine}` answers when `limit` is not given, and
    /// the most it will answer when it is.
    public static let agentDefaultItemLimit = 500
    public static let agentMaximumItemLimit = 2_000

    /// What the guardrail said about a held call, in the words the Mac's own card uses.
    public static let agentScreeningVerdicts = ["act", "confirm", "block", "unavailable"]

    /// One gateway model as a picker needs it: what to send, what to show, and where it
    /// runs. The last one matters on a phone — "this Mac" and "the machine in the study"
    /// are a different promise about latency and about what is switched on.
    public struct AgentModelChoice: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var label: String
        /// "This Mac", or the peer's own name. For reading, never for routing: the `id` is
        /// what a turn is sent with.
        public var `where`: String

        public init(id: String, label: String, where location: String) {
            self.id = id
            self.label = label
            self.where = location
        }
    }

    /// A session as the list shows it. Present even when the engine is stopped, because a
    /// phone that cannot see a stopped engine cannot offer to start one.
    public struct AgentSessionSummary: Codable, Sendable, Equatable, Identifiable {
        /// "codex" or "pi". Also the session id — see the note on this extension.
        public var engine: String
        public var id: String { engine }
        /// One of `agentSessionStates`.
        public var state: String
        /// The engine's own id for the thread, once it has one. Codex mints it at
        /// `thread/start`; Pi has none to give, and the field is null there.
        public var threadID: String?
        /// Which transcript this is. Changes when the thread is replaced — a new thread, a
        /// restart — and when this Mac's app relaunches, so a phone that sees a different
        /// value knows the rows it holds belong to something that is gone.
        public var epoch: String
        /// The gateway model the next turn will use.
        public var model: String
        public var modelChoices: [AgentModelChoice]
        /// The folder this engine works in, relative to the home folder (`~/…`) — never the
        /// absolute home path. Null for Codex until the owner has chosen one on the Mac:
        /// the folder is the one thing a device may not pick, since a device that could
        /// name a folder could name any folder.
        public var cwd: String?
        /// One of `agentApprovalModes`: whether the agent asks before it acts, and whether
        /// the guardrail looks first. Read before handing it a task from across the room.
        public var approvals: String
        /// One of `agentSandboxes`. Codex's is the one its current thread started with,
        /// because a thread keeps what it started with; `none` for Pi.
        public var sandbox: String
        public var turnActive: Bool
        /// How many approvals are waiting for a person right now — zero while the engine is
        /// not running, because a stopped engine is asking nobody anything.
        public var pendingApprovals: Int
        public var itemCount: Int
        /// When this session last changed — its newest item, or when it started.
        public var updatedAt: String
        /// Why it is in `failed`, in the engine's own words. Never set otherwise.
        public var failure: String?

        public init(
            engine: String, state: String, threadID: String? = nil, epoch: String,
            model: String, modelChoices: [AgentModelChoice] = [], cwd: String?,
            approvals: String, sandbox: String, turnActive: Bool = false,
            pendingApprovals: Int = 0, itemCount: Int = 0, updatedAt: String,
            failure: String? = nil
        ) {
            self.engine = engine
            self.state = state
            self.threadID = threadID
            self.epoch = epoch
            self.model = model
            self.modelChoices = modelChoices
            self.cwd = cwd
            self.approvals = approvals
            self.sandbox = sandbox
            self.turnActive = turnActive
            self.pendingApprovals = pendingApprovals
            self.itemCount = itemCount
            self.updatedAt = updatedAt
            self.failure = failure
        }
    }

    public struct AgentSessionList: Codable, Sendable, Equatable {
        public var sessions: [AgentSessionSummary]

        public init(sessions: [AgentSessionSummary]) { self.sessions = sessions }
    }

    /// One row of a transcript, in the shape both engines are normalised into.
    ///
    /// `text` is what the row is *about* — the prose, the command line, the tool's name.
    /// `output` is what came back, and it is separate only where the engine keeps the two
    /// apart: Codex's `commandExecution` carries both, and Pi replaces a tool row's text
    /// with its result, so for Pi `output` is whichever of the two Pi currently holds.
    public struct AgentItem: Codable, Sendable, Equatable, Identifiable {
        /// The engine's own id where it has one, so an update lands on the row it is about
        /// rather than appending a second copy of it.
        public var id: String
        /// One of `agentItemKinds`.
        public var kind: String
        public var text: String
        /// At most the last `agentOutputLimit` characters of it.
        public var output: String?
        /// True when `output` is the tail of something longer. Absent otherwise.
        public var truncated: Bool?
        /// One of `agentItemStatuses`, where the row has a lifecycle at all.
        public var status: String?
        /// The model this turn was sent with, on the row that was the sending. Stamped when
        /// the Mac first sees the row, from whichever side sent it — which is the only
        /// moment the answer is actually known.
        public var model: String?
        public var at: String

        public init(
            id: String, kind: String, text: String, output: String? = nil,
            truncated: Bool? = nil, status: String? = nil, model: String? = nil, at: String
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.output = output
            self.truncated = truncated
            self.status = status
            self.model = model
            self.at = at
        }
    }

    /// What the guardrail made of a held call — the line the Mac's own card shows.
    public struct AgentScreening: Codable, Sendable, Equatable {
        /// One of `agentScreeningVerdicts`. `unavailable` means nothing was judged — Jev is
        /// off, has no key, or could not be reached — and must never read as a pass.
        public var verdict: String
        /// The sentence itself: "Jev: safe", "Jev: review: destructive", "Jev: not
        /// screened — Guardrails are off in Settings → TypeSafe (Jev)."
        public var summary: String

        public init(verdict: String, summary: String) {
            self.verdict = verdict
            self.summary = summary
        }
    }

    /// A call the agent is holding, waiting for a person.
    ///
    /// Only what a person still has to decide reaches this list, and only once the
    /// guardrail has had its say. Jev screens every call first and answers the ones it is
    /// sure about; a call it is still screening is not listed — the Mac shows it as
    /// "Screening…" with no buttons, and answering it from anywhere would throw away the
    /// verdict about to land. What is listed carries that verdict, so a phone can show
    /// exactly what the Mac's card does.
    public struct AgentApproval: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        /// "command", "fileChange" or "tool".
        public var kind: String
        /// The command line, the paths, or the tool and its arguments — the thing being
        /// decided, not a description of it.
        public var summary: String
        /// Why the engine is asking, when it said. Codex sometimes does; Pi's gate never
        /// does, because the gate is this app's own.
        public var reason: String?
        public var screening: AgentScreening
        public var requestedAt: String

        public init(
            id: String, kind: String, summary: String, reason: String? = nil,
            screening: AgentScreening, requestedAt: String
        ) {
            self.id = id
            self.kind = kind
            self.summary = summary
            self.reason = reason
            self.screening = screening
            self.requestedAt = requestedAt
        }
    }

    /// What `GET /agent/sessions/{engine}` was asked for.
    ///
    /// `since` and `epoch` are one cursor in two halves, and a slice is only answered when
    /// both match: a sequence number means nothing outside the transcript that issued it,
    /// and a phone resuming across a new thread or an app relaunch would otherwise be
    /// handed rows of a different transcript as if they continued its own.
    public struct AgentSessionQuery: Sendable, Equatable {
        public var since: Int?
        public var epoch: String?
        public var limit: Int?

        public init(since: Int? = nil, epoch: String? = nil, limit: Int? = nil) {
            self.since = since
            self.epoch = epoch
            self.limit = limit
        }
    }

    /// `GET /agent/sessions/{engine}`: the summary, the transcript, and what is waiting.
    public struct AgentSessionDetail: Codable, Sendable, Equatable {
        public var session: AgentSessionSummary
        /// Oldest first. The whole transcript, or — with a matching `since` and `epoch` —
        /// only the rows that changed after that point. Never more than `limit`.
        public var items: [AgentItem]
        public var approvals: [AgentApproval]
        /// This session's sequence number as of this answer. Hand it back as `?since=`,
        /// with `epoch`, after an interrupted stream and the next answer carries only what
        /// was missed. The same numbers the `agent` frames carry.
        public var seq: Int
        /// Which transcript `seq` belongs to. The same value as `session.epoch`; here as
        /// well because the two are one cursor.
        public var epoch: String
        /// True when `items` replaces what a client holds; false when it is a slice to merge
        /// in by id. A `since` from another epoch, or one this session never reached,
        /// answers the transcript rather than a gap — and says so here.
        public var complete: Bool
        /// Rows left out because of `limit`. A slice that would not fit is answered as the
        /// newest `limit` rows of the transcript with `complete: true`, because a slice
        /// missing its oldest changes would leave a client silently out of date.
        public var omitted: Int

        public init(
            session: AgentSessionSummary, items: [AgentItem], approvals: [AgentApproval],
            seq: Int, epoch: String, complete: Bool = true, omitted: Int = 0
        ) {
            self.session = session
            self.items = items
            self.approvals = approvals
            self.seq = seq
            self.epoch = epoch
            self.complete = complete
            self.omitted = omitted
        }
    }

    /// The body of `POST /agent/sessions/{engine}/messages`.
    public struct AgentMessageRequest: Codable, Sendable, Equatable {
        public var text: String
        /// Which model to send this turn with. Must be one of the session's
        /// `modelChoices`; anything else is a 400 rather than a quiet fall back to the
        /// current one, because "it answered, just not with what you picked" is the one
        /// failure a reader cannot see.
        ///
        /// **Sticky**: it becomes the engine's model, exactly as picking it in the Mac's
        /// own menu does — saved, and shown in that menu from then on. It is the session's
        /// model that is being chosen, not a one-turn override.
        public var model: String?

        public init(text: String, model: String? = nil) {
            self.text = text
            self.model = model
        }
    }

    /// 202. The turn has been handed to the engine; watch `/events` for what it does.
    public struct AgentMessageAccepted: Codable, Sendable, Equatable {
        /// The transcript row this send became, already visible on the Mac.
        public var itemID: String

        public init(itemID: String) { self.itemID = itemID }
    }

    /// The body of `POST /agent/sessions/{engine}/approvals/{id}`.
    public struct AgentApprovalDecision: Codable, Sendable, Equatable {
        /// "accept" or "decline".
        public var decision: String

        public init(decision: String) { self.decision = decision }
    }

    public static let agentApprovalDecisions = ["accept", "decline"]

    /// What answering an approval says back. The session summary rides along so a phone
    /// that has just decided does not have to ask what changed.
    public struct AgentApprovalResult: Codable, Sendable, Equatable {
        public var id: String
        /// "accepted" or "declined" — the decision as it was applied.
        public var decision: String
        public var session: AgentSessionSummary

        public init(id: String, decision: String, session: AgentSessionSummary) {
            self.id = id
            self.decision = decision
            self.session = session
        }
    }

    /// The `agent` frame on `GET /events`. Sent only to this Mac's own token and to devices
    /// paired with full control.
    ///
    /// Five kinds, and each one says which of the optional fields it filled in:
    ///
    /// - `reset` — the transcript was replaced: a new thread, a restart. Drop every row
    ///   and approval held for this engine; `epoch`, `threadID`, `state` and `turnActive`
    ///   describe what replaced them. Fetch the transcript again from here.
    /// - `state` — the session started, stopped or failed, or its thread got its id.
    ///   `state` carries the session state.
    /// - `turn`  — a turn began or ended. `turnActive` carries which.
    /// - `item`  — a row was added or changed. `item` carries it whole, not a delta: a
    ///   phone that missed a frame would otherwise have to reassemble text it never saw.
    ///   Streamed prose is sampled rather than forwarded token by token, so a row produces
    ///   at most ten of these a second however fast the model writes.
    /// - `approval` — a call is waiting, or has stopped waiting. `approval` carries it and
    ///   `state` says which: "pending", "accepted" or "declined". The answered frame is what
    ///   takes a card down on the phone when the person answered it at the Mac — and the
    ///   other way round.
    ///
    /// Every frame carries `epoch` and `threadID`. Frames reach a subscriber in `seq` order
    /// — non-decreasing, never backwards — and `seq` is the number `?since=` takes, so a
    /// phone resuming from the last frame it saw misses nothing.
    ///
    /// A phone that has just connected is sent `state`, `turn` and every pending
    /// `approval` first, all at the current `seq`, and after them only what changes. Rows
    /// are not in the opening — a transcript does not belong on a side channel — so fetch
    /// it once the opening has arrived. A transcript fetched *before* the opening, at a
    /// lower `seq`, is caught up with `?since=<that seq>&epoch=…`: what changed in between
    /// is in no frame, and in that answer.
    public struct AgentEvent: Codable, Sendable, Equatable {
        public var engine: String
        /// One of `agentEventKinds`.
        public var kind: String
        public var seq: Int
        public var epoch: String
        public var threadID: String?
        public var item: AgentItem?
        public var approval: AgentApproval?
        public var turnActive: Bool?
        /// The session state on a `state` or `reset` frame; the approval's resolution on an
        /// `approval` one.
        public var state: String?

        public init(
            engine: String, kind: String, seq: Int, epoch: String, threadID: String? = nil,
            item: AgentItem? = nil, approval: AgentApproval? = nil, turnActive: Bool? = nil,
            state: String? = nil
        ) {
            self.engine = engine
            self.kind = kind
            self.seq = seq
            self.epoch = epoch
            self.threadID = threadID
            self.item = item
            self.approval = approval
            self.turnActive = turnActive
            self.state = state
        }
    }

    public static let agentEventKinds = ["reset", "state", "item", "approval", "turn"]

    /// What an `approval` frame's `state` can say.
    public static let agentApprovalStates = ["pending", "accepted", "declined"]
}

/// What the agent routes refuse with, and the status each refusal is.
///
/// Its own error type rather than a fold into `BuddyHostError` because the statuses are the
/// whole contract here: a phone can act on 404, 409 and 400, and cannot act on 400 for all
/// three.
public enum AgentSessionError: Error, LocalizedError, ControlStatusError, Equatable {
    /// A path segment that is not one of `ControlAPI.agentEngines`.
    case unknownEngine(String)
    /// The engine is not running, so there is nothing to send to, interrupt or approve.
    case notRunning(String)
    /// On its way down. Starting it again has to wait for that to finish.
    case stillStopping(String)
    /// Codex has no working folder yet, and picking one is the owner's own business.
    case noWorkingDirectory
    /// A model that is not in this session's `modelChoices`.
    case unknownModel(String)
    case emptyMessage
    /// Codex is mid-turn. The Mac's own send button is disabled for exactly this; a second
    /// `turn/start` on a busy thread fails, and its failure would end the first turn's
    /// "working" state on screen while that turn is still running.
    case turnInProgress(String)
    /// A decision that is neither "accept" nor "decline".
    case unknownDecision(String)
    /// No approval with that id — never seen, or answered and forgotten.
    case unknownApproval(String)
    /// Held, but the guardrail has not spoken yet. The Mac shows no buttons for it either.
    case stillScreening(String)
    /// Answered at the Mac before this request arrived. Its own status because it is the
    /// one refusal a phone should explain rather than retry: the decision was made, just
    /// not here.
    case answeredOnTheMac(String)
    /// A `since` or a `limit` that is not a whole number.
    case badQuery(String)
    /// A host with no agent engines at all — the MCP bridge's doubles, the fixtures.
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .unknownEngine(let engine):
            "No agent session called \(engine). This Mac runs "
                + "\(ControlAPI.agentEngines.joined(separator: " and "))."
        case .notRunning(let engine):
            "\(Self.displayName(engine)) is not running. Start it with "
                + "POST /agent/sessions/\(engine)/start and try again."
        case .stillStopping(let engine):
            "\(Self.displayName(engine)) is still stopping. Try again in a moment."
        case .noWorkingDirectory:
            AgentSessionError.workingDirectoryIsTheMacsToPick
        case .unknownModel(let model):
            "\(model) is not one of this session's models. Pick one of the "
                + "`modelChoices` in GET /agent/sessions."
        case .emptyMessage:
            "A message needs something in it."
        case .turnInProgress:
            AgentSessionError.waitForTheTurn
        case .unknownDecision(let decision):
            "\(decision) is not a decision. Send \"accept\" or \"decline\"."
        case .unknownApproval(let id):
            "No approval with id \(id) is waiting. It was answered already, or never "
                + "existed."
        case .stillScreening:
            AgentSessionError.stillBeingScreened
        case .answeredOnTheMac:
            AgentSessionError.alreadyAnsweredOnTheMac
        case .badQuery(let what):
            "\(what) must be a whole number."
        case .unsupported:
            "This host runs no agent sessions."
        }
    }

    /// Exported so the fixture and the server cannot promise different sentences. The
    /// folder is the one thing about a Codex session a phone may not choose: a device that
    /// could name a folder could name any folder on this Mac, and Codex would then be
    /// trusted in it.
    public static let workingDirectoryIsTheMacsToPick =
        "Codex has no working folder yet. Choose one in the Chat tab on the Mac — a "
        + "paired device may drive the session but not pick the folder it runs in."

    /// Likewise. Said in full because the person holding the phone needs to know the
    /// decision *was* made, not that their tap failed.
    public static let alreadyAnsweredOnTheMac =
        "That was answered at the Mac before this arrived. The agent already has its "
        + "decision; nothing was sent twice."

    public static let stillBeingScreened =
        "Jev is still screening that call. It can be answered once the verdict is in — "
        + "watch for its approval frame on /events."

    public static let waitForTheTurn =
        "Codex is still working on the last message. Wait for the turn to end, or stop it "
        + "with POST /agent/sessions/codex/interrupt."

    public var status: Int {
        switch self {
        case .unknownEngine, .unknownApproval: 404
        case .notRunning, .stillStopping, .noWorkingDirectory, .turnInProgress,
             .stillScreening, .answeredOnTheMac: 409
        case .unknownModel, .emptyMessage, .unknownDecision, .badQuery: 400
        case .unsupported: 501
        }
    }

    static func displayName(_ engine: String) -> String {
        switch engine {
        case "codex": "Codex"
        case "pi": "Pi"
        default: engine
        }
    }
}

/// The agent half of `ControlHost`.
///
/// Separated into its own protocol extension with defaults, like the video queue's, so the
/// hosts that are not the Mac app — the MCP bridge's doubles, the contract fixtures — keep
/// compiling and answer the one honest thing they can: this host runs no agents.
extension ControlHost {

    public func agentSessions() async -> ControlAPI.AgentSessionList {
        ControlAPI.AgentSessionList(sessions: [])
    }

    public func agentSession(
        engine: String, query: ControlAPI.AgentSessionQuery
    ) async throws -> ControlAPI.AgentSessionDetail {
        throw AgentSessionError.unsupported
    }

    public func startAgentSession(
        engine: String
    ) async throws -> ControlAPI.AgentSessionSummary {
        throw AgentSessionError.unsupported
    }

    public func newAgentThread(engine: String) async throws -> ControlAPI.AgentSessionSummary {
        throw AgentSessionError.unsupported
    }

    public func stopAgentSession(engine: String) async throws -> ControlAPI.AgentSessionSummary {
        throw AgentSessionError.unsupported
    }

    public func sendAgentMessage(
        engine: String, _ request: ControlAPI.AgentMessageRequest
    ) async throws -> ControlAPI.AgentMessageAccepted {
        throw AgentSessionError.unsupported
    }

    public func interruptAgentSession(
        engine: String
    ) async throws -> ControlAPI.AgentSessionSummary {
        throw AgentSessionError.unsupported
    }

    public func answerAgentApproval(
        engine: String, id: String, decision: String
    ) async throws -> ControlAPI.AgentApprovalResult {
        throw AgentSessionError.unsupported
    }
}
