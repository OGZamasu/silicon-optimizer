import Foundation
import SiliconControl

// MARK: - Laya, on this Mac

/// The local Laya lane: one resident sidecar, answering in milliseconds, nothing leaving
/// the machine and nothing billed.
///
/// The one retry lives here rather than in `LayaSidecar` because this is the level that
/// knows whether the retry has been spent. A sidecar that died between the availability
/// check and the question gets restarted once — the ordinary cause is the environment being
/// upgraded underneath it, or the machine having slept — and a second failure is reported
/// rather than turned into a loop that reloads 800 MB of weights on every request.
public struct LayaLane: DecisionLane {
    public let laneID = DecisionLaneID.laya
    private let runtime: LayaRuntime
    private let checkpoint: @Sendable () async -> LayaCheckpoint
    /// Whether the lane should answer at all — the owner's switch, checked here so the
    /// policy above can treat "not installed" and "switched off" identically.
    private let enabled: @Sendable () async -> Bool

    public init(
        runtime: LayaRuntime = .shared,
        checkpoint: @escaping @Sendable () async -> LayaCheckpoint = { .default },
        enabled: @escaping @Sendable () async -> Bool = { true }
    ) {
        self.runtime = runtime
        self.checkpoint = checkpoint
        self.enabled = enabled
    }

    public func isReady() async -> Bool {
        guard await enabled() else { return false }
        return await runtime.installation(checkpoint: checkpoint()).isInstalled
    }

    public func decide(
        _ request: ControlAPI.DecideRequest
    ) async throws -> ControlAPI.DecideResponse {
        try request.validate()
        let checkpoint = await checkpoint()
        let started = Date()
        do {
            return try await ask(request, checkpoint: checkpoint, started: started)
        } catch let error as LayaSidecarError where error.deservesRestart {
            // One restart, then the truth.
            await runtime.unload()
            return try await ask(request, checkpoint: checkpoint, started: started)
        }
    }

    private func ask(
        _ request: ControlAPI.DecideRequest, checkpoint: LayaCheckpoint, started: Date
    ) async throws -> ControlAPI.DecideResponse {
        let sidecar = try await runtime.sidecar(for: checkpoint)
        let response = try await sidecar.decide(
            state: LayaWire.state(request.state),
            questions: LayaWire.questions(request.questions)
        )
        await runtime.noteAnswer(
            perQuestionMS: response.perQuestionMS,
            peakMemoryBytes: response.peakMemoryBytes
        )
        return try LayaWire.response(
            response, for: request, checkpoint: checkpoint,
            wallClockMS: Date().timeIntervalSince(started) * 1000
        )
    }
}

// MARK: - Laya, on a swarm node

/// The same checkpoints on a node's CUDA card, reached over the tailnet.
///
/// Nearly free to build, because the node serves `POST /v1/systemone` — TypeSafe's own path
/// and shape — and `SystemOneClient` was already written to speak it to "anything else that
/// speaks the same shape, a swarm node with the route, say". So the node lane is that
/// client pointed somewhere else, with the swarm credential in place of an API key.
///
/// The deadline is short and deliberate. A peer that is asleep, or on the other side of a
/// tailnet that is reconnecting, must not hold up a decision: past a couple of seconds the
/// policy's next lane is a better answer than this one's.
public struct NodeDecisionLane: DecisionLane {
    public let laneID = DecisionLaneID.node

    /// One reachable peer that has said it can decide.
    public struct Peer: Sendable, Equatable {
        public var name: String
        public var baseURL: URL
        public var token: String?
        /// Checkpoint ids the node says are loaded, from its `/v1/node` advertisement.
        public var checkpoints: [String]
        /// What it says one question costs, in milliseconds.
        public var perQuestionMS: Double?

        public init(
            name: String, baseURL: URL, token: String?, checkpoints: [String] = [],
            perQuestionMS: Double? = nil
        ) {
            self.name = name
            self.baseURL = baseURL
            self.token = token
            self.checkpoints = checkpoints
            self.perQuestionMS = perQuestionMS
        }
    }

    /// Which peer to ask, read fresh: the swarm is polled on a timer and a node that was
    /// ready a minute ago may not be now.
    private let peer: @Sendable () async -> Peer?
    private let session: URLSession?
    public var deadline: TimeInterval

    public init(
        peer: @escaping @Sendable () async -> Peer?,
        session: URLSession? = nil,
        deadline: TimeInterval = 4
    ) {
        self.peer = peer
        self.session = session
        self.deadline = deadline
    }

    public func isReady() async -> Bool { await peer() != nil }

    public func decide(
        _ request: ControlAPI.DecideRequest
    ) async throws -> ControlAPI.DecideResponse {
        try request.validate()
        guard let peer = await peer() else { throw DecisionLaneError.nodeUnreachable }
        let client = SystemOneClient(
            baseURL: peer.baseURL,
            // The node authenticates with the swarm credential this Mac already holds for
            // it. `SystemOneClient` sends it as a bearer, which is what every other route
            // on that node takes.
            apiKey: peer.token ?? "",
            session: session ?? Self.session(deadline: deadline)
        )
        var asked = request
        // The node's checkpoints are named without the MLX suffix — `laya`,
        // `laya-multilingual` — because they are the upstream PyTorch repositories rather
        // than the ported ones. Same weights, same answers, different name on the wire.
        asked.model = request.model ?? Self.nodeModelName(for: .default)
        asked.provider = nil
        var response = try await client.decide(asked)
        // `provider` carries the peer's name so a reader can tell *which* machine answered,
        // not merely that some node did. `DecisionLaneID.named` reads the part before the
        // colon, so this stays parseable.
        response.provider = "\(DecisionLaneID.node.wireName):\(peer.name)"
        return response
    }

    /// What the node calls a checkpoint.
    public static func nodeModelName(for checkpoint: LayaCheckpoint) -> String {
        switch checkpoint {
        case .english: "laya"
        case .multilingual: "laya-multilingual"
        case .typedDecisions: "laya-typed-decisions"
        }
    }

    /// The capability `kind` a node advertises a decision lane under, in `/v1/node`.
    ///
    /// A convention on the frozen `NodeCapability` shape rather than a new field: it
    /// already carries `id`, `kind`, `ready`, `typical_seconds` and `detail`, and the Mac
    /// already parses all five. So the node adds a capability and this Mac sees it with no
    /// wire change on either side.
    public static let capabilityKind = "decision"

    private static func session(deadline: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = deadline
        configuration.timeoutIntervalForResource = deadline
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

// MARK: - The loaded language model

/// The lane that was here before any of this: the model loaded in this app, read one token
/// deep. Slower than Laya, much less calibrated, and installed on every Mac that has a
/// model at all — which is what keeps it as the last resort rather than retiring it.
public struct OneTokenLane: DecisionLane {
    public let laneID = DecisionLaneID.oneToken
    private let decider: @Sendable () async -> LocalDecider?

    public init(decider: @escaping @Sendable () async -> LocalDecider?) {
        self.decider = decider
    }

    public func isReady() async -> Bool { await decider() != nil }

    public func decide(
        _ request: ControlAPI.DecideRequest
    ) async throws -> ControlAPI.DecideResponse {
        guard let decider = await decider() else { throw DecisionLaneError.noLocalModel }
        return try await decider.decide(request)
    }
}

// MARK: - Jev

/// TypeSafe, through the one governed door.
///
/// Deliberately thin: everything that makes a Jev call different from a local one — the
/// master switch, the model pin, the budget, the cache, the ledger, the backoff — is
/// `JevService`'s and stays there. This exists so the policy can hold four lanes of the
/// same type rather than special-casing one of them.
public struct JevDecisionLane: DecisionLane {
    public let laneID = DecisionLaneID.jev
    private let service: JevService
    private let feature: JevFeature

    public init(service: JevService = .shared, feature: JevFeature) {
        self.service = service
        self.feature = feature
    }

    public func isReady() async -> Bool { await service.isAvailable(feature) }

    public func decide(
        _ request: ControlAPI.DecideRequest
    ) async throws -> ControlAPI.DecideResponse {
        try await service.ask(feature, state: request.state, questions: request.questions)
    }
}

// MARK: - Errors

public enum DecisionLaneError: Error, LocalizedError, Equatable {
    case nodeUnreachable
    case noLocalModel
    /// Every lane refused, or the owner has switched them all off.
    case nothingAvailable(JevFeature)
    /// The lane answered, but not the question that was asked.
    case wrongAnswerKind(question: String, expected: String, got: String)
    case missingAnswer(question: String)
    /// The state is longer than the checkpoint's encoder can see, so an answer would be
    /// about a truncated version of it.
    case stateTooLong(bytes: Int, limit: Int, checkpoint: String)

    public var errorDescription: String? {
        switch self {
        case .nodeUnreachable:
            "No swarm node is offering a decision lane right now."
        case .noLocalModel:
            "No model is loaded here, so the fallback decision lane has nothing to ask."
        case .nothingAvailable(let feature):
            "Nothing is set up to answer \(feature.displayName). Install Laya in "
            + "Settings → Decisions, load a model, or turn on Jev."
        case .wrongAnswerKind(let question, let expected, let got):
            "Laya answered \"\(question)\" with a \(got); a \(expected) was asked for."
        case .missingAnswer(let question):
            "Laya did not answer \"\(question)\"."
        case .stateTooLong(let bytes, let limit, let checkpoint):
            "That state is \(bytes / 1024) KB and \(checkpoint) reads about \(limit / 1024) KB "
            + "of it. Filter it down, or choose a checkpoint with a longer context."
        }
    }
}

// MARK: - Translating

/// Between this app's wire types and laya-mlx's dictionaries.
///
/// Its own type so the mapping is testable without a model: every one of these functions is
/// pure, and the tests feed them the exact dictionaries the library is documented to return.
public enum LayaWire {

    /// The state, as JSON the sidecar can hand straight to `system_one`.
    ///
    /// laya-mlx accepts a string, a dict or a list and serialises the last two itself, so
    /// the shape is passed through rather than flattened — a `choice` about an object reads
    /// better when the model sees the object's keys.
    public static func state(_ state: JSONContent) -> Any {
        object(from: state) ?? state.promptText
    }

    public static func questions(
        _ questions: [String: ControlAPI.SystemOneQuestion]
    ) -> [String: Any] {
        var wire: [String: Any] = [:]
        for (name, question) in questions {
            var one: [String: Any] = ["type": question.type]
            if let instructions = question.instructions, !instructions.isNull {
                one["instructions"] = object(from: instructions) ?? instructions.promptText
            }
            // A noul carries no criteria in laya's own examples; an object with the two
            // descriptions is still accepted and still useful, so it is sent when present.
            if let criteria = question.criteria, !criteria.isNull {
                one["criteria"] = object(from: criteria) ?? criteria.promptText
            }
            wire[name] = one
        }
        return wire
    }

    /// A `JSONContent` as a Foundation object, or nil for the cases that have to become a
    /// string (which `promptText` then renders with stable key order).
    static func object(from content: JSONContent) -> Any? {
        switch content {
        case .null: nil
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map { object(from: $0) ?? NSNull() }
        case .object(let values): values.mapValues { object(from: $0) ?? NSNull() }
        }
    }

    /// laya's answers, checked against the questions that were asked.
    ///
    /// Checked rather than trusted: a lane that answered a `score` where a `choice` was
    /// asked would otherwise reach a feature's typed accessor and throw there, three frames
    /// away from the thing that was actually wrong.
    public static func response(
        _ response: LayaSidecarResponse,
        for request: ControlAPI.DecideRequest,
        checkpoint: LayaCheckpoint,
        wallClockMS: Double
    ) throws -> ControlAPI.DecideResponse {
        var answers: [String: ControlAPI.SystemOneAnswer] = [:]
        for (name, question) in request.questions {
            guard let raw = response.answers[name] else {
                throw DecisionLaneError.missingAnswer(question: name)
            }
            guard raw.type == question.type else {
                throw DecisionLaneError.wrongAnswerKind(
                    question: name, expected: question.type, got: raw.type
                )
            }
            answers[name] = try answer(raw, name: name)
        }
        return ControlAPI.DecideResponse(
            model: response.model ?? checkpoint.repository,
            usage: .init(
                inputTokens: response.usage?.inputTokens ?? 0,
                outputTokens: response.usage?.outputTokens ?? 0
            ),
            answers: answers,
            provider: DecisionLaneID.laya.wireName,
            // The wall clock, like every other lane reports: what the caller waited,
            // including the pipe. The model's own figure is kept separately, on the
            // runtime, because that is the one worth comparing against a benchmark.
            latencyMS: wallClockMS
        )
    }

    static func answer(
        _ raw: LayaSidecarAnswer, name: String
    ) throws -> ControlAPI.SystemOneAnswer {
        switch raw.type {
        case "noul":
            guard let noul = raw.noul else {
                throw DecisionLaneError.missingAnswer(question: name)
            }
            return .noul(clamped(noul))
        case "choice":
            guard let choice = raw.choice else {
                throw DecisionLaneError.missingAnswer(question: name)
            }
            let probabilities = (raw.probabilities ?? [:]).mapValues(clamped)
            return .choice(
                choice: choice,
                // laya reports its own confidence; falling back to the winning
                // probability keeps the field meaningful if a release ever drops it.
                confidence: clamped(raw.confidence ?? probabilities[choice] ?? 0),
                probabilities: probabilities
            )
        case "score":
            guard let score = raw.score else {
                throw DecisionLaneError.missingAnswer(question: name)
            }
            let probabilities = (raw.probabilities ?? [:]).mapValues(clamped)
            return .score(
                score: score,
                confidence: clamped(raw.confidence ?? probabilities.values.max() ?? 0),
                legend: (raw.legend ?? [:]).mapValues { JSONContent.string($0) },
                probabilities: probabilities
            )
        default:
            throw DecisionLaneError.wrongAnswerKind(
                question: name, expected: "noul, choice or score", got: raw.type
            )
        }
    }

    /// A probability from another process is a number somebody else computed. Rounding at
    /// four decimal places can leave a distribution summing to 1.0001, and a NaN would
    /// compare false against every threshold and silently escalate nothing.
    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }
}
