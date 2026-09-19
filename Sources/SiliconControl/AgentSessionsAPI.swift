import Foundation

/// The agent sessions a phone can see and drive: the Chat tab's Codex and Pi engines,
/// mirrored rather than duplicated.
///
/// There is one session per engine and it is *the* session — the same thread the owner is
/// looking at on the Mac, the same items, the same approvals. A phone is a second screen
/// on it, not a second seat: sending from the phone appends to the Mac's transcript, and an
/// approval answered on either side is answered for both. That is why the session id is
/// simply the engine id and there is no registry of threads here — a registry would be a
/// second place for the truth to live.
///
/// Every one of these routes runs commands on this Mac, so they are full scope only. A
/// chat-only device is refused by the scope gate before it reaches any of them, and the
/// swarm token — which is a node's, not a person's — is refused at the route.
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
        /// The gateway model the next turn will use.
        public var model: String
        public var modelChoices: [AgentModelChoice]
        /// The folder this engine works in. Chosen on the Mac and never by a phone: a
        /// device that could name a folder could name any folder.
        public var cwd: String
        public var turnActive: Bool
        /// How many approvals are waiting for a person right now. A count rather than the
        /// approvals themselves, because a list is what `GET /agent/sessions/{engine}` is
        /// for and a badge is what this is for.
        public var pendingApprovals: Int
        public var itemCount: Int
        /// When this session last changed — its newest item, or when it started.
        public var updatedAt: String
        /// Why it is in `failed`, in the engine's own words. Never set otherwise.
        public var failure: String?

        public init(
            engine: String, state: String, threadID: String? = nil, model: String,
            modelChoices: [AgentModelChoice] = [], cwd: String, turnActive: Bool = false,
            pendingApprovals: Int = 0, itemCount: Int = 0, updatedAt: String,
            failure: String? = nil
        ) {
            self.engine = engine
            self.state = state
            self.threadID = threadID
            self.model = model
            self.modelChoices = modelChoices
            self.cwd = cwd
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
    /// `text` is what the row is *about* — the prose, the command line, the tool's name and
    /// arguments. `output` is what came back, and it is separate only where the engine
    /// keeps the two apart: Codex's `commandExecution` carries both, Pi replaces a tool
    /// row's text with its result and there is nothing left to separate.
    public struct AgentItem: Codable, Sendable, Equatable, Identifiable {
        /// The engine's own id where it has one, so an update lands on the row it is about
        /// rather than appending a second copy of it.
        public var id: String
        /// One of `agentItemKinds`.
        public var kind: String
        public var text: String
        public var output: String?
        /// One of `agentItemStatuses`, where the row has a lifecycle at all.
        public var status: String?
        /// The model this turn was sent with, on the row that was the sending. Stamped when
        /// the Mac first sees the row, from whichever side sent it — which is the only
        /// moment the answer is actually known.
        public var model: String?
        public var at: String

        public init(
            id: String, kind: String, text: String, output: String? = nil,
            status: String? = nil, model: String? = nil, at: String
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.output = output
            self.status = status
            self.model = model
            self.at = at
        }
    }

    /// A call the agent is holding, waiting for a person.
    ///
    /// Only what a person still has to decide reaches this list. The Jev guardrail screens
    /// every call first and answers the ones it is sure about; what is here is what it left
    /// to a human, plus — when the guardrail is off — whatever the engine itself asks about.
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
        public var requestedAt: String

        public init(
            id: String, kind: String, summary: String, reason: String? = nil,
            requestedAt: String
        ) {
            self.id = id
            self.kind = kind
            self.summary = summary
            self.reason = reason
            self.requestedAt = requestedAt
        }
    }

    /// `GET /agent/sessions/{engine}`: the summary, the transcript, and what is waiting.
    public struct AgentSessionDetail: Codable, Sendable, Equatable {
        public var session: AgentSessionSummary
        /// The whole transcript, or — with `?since=` — only what is newer than the caller
        /// already has.
        public var items: [AgentItem]
        public var approvals: [AgentApproval]
        /// This session's sequence watermark as of this answer. Hand it back as `?since=`
        /// after an interrupted stream and the next answer carries only what was missed.
        /// The same numbers the `agent` frames carry, so a phone can resume from either.
        public var seq: Int
        /// True when `items` is the whole transcript rather than a catch-up slice — which
        /// is what a client needs in order to know whether to replace its list or append to
        /// it. A `?since=` that names a sequence this Mac has forgotten answers the whole
        /// transcript rather than a silent gap, and says so here.
        public var complete: Bool

        public init(
            session: AgentSessionSummary, items: [AgentItem], approvals: [AgentApproval],
            seq: Int, complete: Bool = true
        ) {
            self.session = session
            self.items = items
            self.approvals = approvals
            self.seq = seq
            self.complete = complete
        }
    }

    /// The body of `POST /agent/sessions/{engine}/messages`.
    public struct AgentMessageRequest: Codable, Sendable, Equatable {
        public var text: String
        /// Which model to send this turn with. Must be one of the session's
        /// `modelChoices`; anything else is a 400 rather than a quiet fall back to the
        /// current one, because "it answered, just not with what you picked" is the one
        /// failure a reader cannot see.
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

    /// The `agent` frame on `GET /events`.
    ///
    /// Four kinds, and each one says which of the optional fields it filled in:
    ///
    /// - `state` — the session started, stopped or failed. `state` carries the new one.
    /// - `turn`  — a turn began or ended. `turnActive` carries which.
    /// - `item`  — a row was added or changed. `item` carries it whole, not a delta: a
    ///   phone that missed a frame would otherwise have to reassemble text it never saw.
    ///   Streamed prose is sampled rather than forwarded token by token, so one row
    ///   produces at most ten of these a second per engine however fast the model writes.
    /// - `approval` — a call is waiting, or has been answered. `approval` carries it and
    ///   `state` says which: "pending", "accepted" or "declined". The answered frame is
    ///   what lets a card on the phone disappear when the person answered it at the Mac —
    ///   and the other way round.
    ///
    /// `seq` is the session's own counter and the same one `?since=` takes, so a phone can
    /// resume from the last frame it actually saw.
    public struct AgentEvent: Codable, Sendable, Equatable {
        public var engine: String
        /// "state", "item", "approval" or "turn".
        public var kind: String
        public var seq: Int
        public var item: AgentItem?
        public var approval: AgentApproval?
        public var turnActive: Bool?
        /// The session state on a `state` frame; the approval's resolution on an
        /// `approval` one.
        public var state: String?

        public init(
            engine: String, kind: String, seq: Int, item: AgentItem? = nil,
            approval: AgentApproval? = nil, turnActive: Bool? = nil, state: String? = nil
        ) {
            self.engine = engine
            self.kind = kind
            self.seq = seq
            self.item = item
            self.approval = approval
            self.turnActive = turnActive
            self.state = state
        }
    }

    public static let agentEventKinds = ["state", "item", "approval", "turn"]

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
    /// The engine is not running, so there is nothing to send to or interrupt.
    case notRunning(String)
    /// Codex has no working folder yet, and picking one is the owner's own business.
    case noWorkingDirectory
    /// A model that is not in this session's `modelChoices`.
    case unknownModel(String)
    case emptyMessage
    /// A decision that is neither "accept" nor "decline".
    case unknownDecision(String)
    /// No approval with that id — never seen, or answered and forgotten.
    case unknownApproval(String)
    /// Answered at the Mac before this request arrived. Its own status because it is the
    /// one refusal a phone should explain rather than retry: the decision was made, just
    /// not here.
    case answeredOnTheMac(String)
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
        case .noWorkingDirectory:
            AgentSessionError.workingDirectoryIsTheMacsToPick
        case .unknownModel(let model):
            "\(model) is not one of this session's models. Pick one of the "
                + "`modelChoices` in GET /agent/sessions."
        case .emptyMessage:
            "A message needs something in it."
        case .unknownDecision(let decision):
            "\(decision) is not a decision. Send \"accept\" or \"decline\"."
        case .unknownApproval(let id):
            "No approval with id \(id) is waiting. It was answered already, or never "
                + "existed."
        case .answeredOnTheMac:
            AgentSessionError.alreadyAnsweredOnTheMac
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

    public var status: Int {
        switch self {
        case .unknownEngine, .unknownApproval: 404
        case .notRunning, .noWorkingDirectory, .answeredOnTheMac: 409
        case .unknownModel, .emptyMessage, .unknownDecision: 400
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
        engine: String, since: String?
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
