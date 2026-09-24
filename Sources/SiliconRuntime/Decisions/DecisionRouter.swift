import Foundation
import SiliconControl

/// The one door every decision goes through, whichever lane answers it.
///
/// `JevService` is still the door for *Jev* — the master switch, the model pin, the budget,
/// the cache, the ledger and the backoff all live there and are untouched by this. What
/// this adds is the question in front of that one: **who should answer?**
///
/// It is a separate actor rather than more methods on `JevService` for a reason worth
/// stating. `JevService` is the thing that spends money, and every check in it exists to
/// stop that happening by accident. Teaching it about three lanes that do not cost anything
/// would blur what it is for. So this holds the lanes and the policy, asks `JevService`
/// whether Jev may answer, and asks `JevService` to do it when the answer is yes — it can
/// no more bypass those checks than a feature could.
public actor DecisionRouter {

    public static let shared = DecisionRouter()

    private var lanes: [DecisionLaneID: any DecisionLane] = [:]
    private var service: JevService
    /// Readiness is asked on every routing decision and while drawing Settings, so the
    /// answers are held briefly. Two seconds: long enough that a panel redrawing does not
    /// stat the filesystem eight times, short enough that installing Laya lights the row up
    /// without a relaunch.
    private var readiness: [DecisionLaneID: (ready: Bool, at: Date)] = [:]
    public static let readinessWindow: TimeInterval = 2

    /// What the last decision did, for the Decisions panel's per-ability line.
    private var lastAnswers: [JevFeature: DecisionRecord] = [:]

    public struct DecisionRecord: Sendable, Equatable {
        public var lane: DecisionLaneID
        /// The peer, when a node answered.
        public var peer: String?
        public var at: Date
        public var latencyMS: Double?
        public var questions: Int
        public var failed: String?
    }

    public init(service: JevService = .shared) {
        self.service = service
    }

    // MARK: Wiring

    /// Registers a lane. Called once at launch for each lane the app can offer.
    ///
    /// Registration is what makes a lane exist at all: with none registered this router
    /// routes to Jev or to nothing, which is exactly how the app behaved before Laya — and
    /// is why every existing test still sees the behaviour it was written against.
    public func register(_ lane: any DecisionLane) {
        lanes[lane.laneID] = lane
        readiness[lane.laneID] = nil
    }

    public func unregister(_ id: DecisionLaneID) {
        lanes[id] = nil
        readiness[id] = nil
    }

    public func registered() -> Set<DecisionLaneID> { Set(lanes.keys) }

    /// Points this router at another `JevService` — a test's, with its own settings file.
    public func use(service: JevService) {
        self.service = service
        readiness.removeAll()
        lastAnswers.removeAll()
    }

    public func forgetReadiness() { readiness.removeAll() }

    /// The router that governs a given service.
    ///
    /// The app has one of each and gets the shared pair. A test builds its own `JevService`
    /// pointed at a private settings file, and gets a **fresh** router with no lanes
    /// registered — which routes to Jev or to nothing, exactly as this app behaved before
    /// any of this existed. That is why the eight features' own test suites did not have to
    /// change: a lane only exists once somebody registers one.
    public static func router(for service: JevService) -> DecisionRouter {
        service === JevService.shared ? .shared : DecisionRouter(service: service)
    }

    // MARK: Who could answer

    /// Which lanes could answer this feature right now.
    ///
    /// Jev's answer comes from `JevService.isAvailable`, unchanged: on, this feature on, a
    /// key stored, budget left. The other three answer for themselves, cheaply — no
    /// network, no Keychain, no model load.
    public func availability(for feature: JevFeature) async -> DecisionLaneAvailability {
        var available = DecisionLaneAvailability()
        available.jev = await service.isAvailable(feature)
        available.laya = await ready(.laya)
        available.node = await ready(.node)
        available.oneToken = await ready(.oneToken)
        return available
    }

    private func ready(_ id: DecisionLaneID) async -> Bool {
        guard let lane = lanes[id] else { return false }
        if let cached = readiness[id], Date().timeIntervalSince(cached.at) < Self.readinessWindow {
            return cached.ready
        }
        let answer = await lane.isReady()
        readiness[id] = (answer, Date())
        return answer
    }

    /// Whether anything would answer this feature — what a feature's gate should ask
    /// instead of `JevService.isAvailable`, which only ever meant "would *Jev*?".
    public func canAnswer(_ feature: JevFeature) async -> Bool {
        await lane(for: feature) != nil
    }

    /// Which lane would answer, or nil for nothing.
    public func lane(for feature: JevFeature) async -> DecisionLaneID? {
        let override = await service.settings().laneOverride(feature)
        return DecisionLanePolicy.lane(
            override: override, available: await availability(for: feature)
        )
    }

    /// The best lane that costs nothing, or nil when there is none.
    ///
    /// What the `/decide` cascade wants for its first pass: something free answers every
    /// question, and only the answers it was unsure of are put to Jev. Which lane that is
    /// has an answer now that it did not before — Laya is a decision model where the
    /// one-token reading of a chat model is an approximation of one — so the cascade asks
    /// rather than assuming.
    ///
    /// Honours the feature's override, so a feature pinned to `alwaysJev` or switched off
    /// has no free lane and the cascade does not quietly acquire one.
    public func localLane(for feature: JevFeature) async -> DecisionLaneID? {
        let override = await service.settings().laneOverride(feature)
        guard override == .automatic || override == .alwaysLocal else { return nil }
        let available = await availability(for: feature)
        return DecisionLanePolicy.localPreference.first { available[$0] }
    }

    /// Asks one named lane, skipping the policy entirely.
    ///
    /// The test bench, and nothing else in the app: the point of the bench is to ask a lane
    /// the owner named even when the policy would have chosen another, which is how you
    /// find out that two lanes disagree. It still goes through `JevService` for Jev, so a
    /// bench run against the cloud is billed, budgeted and logged like any other.
    public func ask(
        lane id: DecisionLaneID, feature: JevFeature,
        state: JSONContent, questions: [String: ControlAPI.SystemOneQuestion]
    ) async throws -> ControlAPI.DecideResponse {
        try await run(
            id, feature: feature, state: state, questions: questions,
            cacheKey: nil, deadline: nil
        )
    }

    // MARK: Asking

    /// One decision, routed.
    ///
    /// Jev is executed through `JevService.ask`, so a Jev answer is identical in every
    /// respect to what it was before this existed — same cache, same ledger line, same
    /// budget, same retries. The local lanes are executed directly; they have nothing to
    /// bill and nothing to rate-limit.
    ///
    /// A lane that *fails* falls through to the next local one, never up to Jev: a sidecar
    /// dying is not the owner deciding to start paying. A lane that is merely absent was
    /// already excluded by the policy.
    @discardableResult
    public func decide(
        _ feature: JevFeature,
        state: JSONContent,
        questions: [String: ControlAPI.SystemOneQuestion],
        cacheKey: String? = nil,
        deadline: TimeInterval? = nil
    ) async throws -> ControlAPI.DecideResponse {
        let override = await service.settings().laneOverride(feature)
        let available = await availability(for: feature)
        guard let chosen = DecisionLanePolicy.lane(override: override, available: available)
        else {
            // Nothing will answer. Why that is has to be said in the words the caller has
            // always been given — `JevError.disabled`, `.noKey`, `.budgetExhausted` — and
            // `JevService` is the only thing that knows which of them applies.
            //
            // So the two overrides that permit Jev ask it, and get its refusal. It cannot
            // succeed: `isAvailable` was false a moment ago and `ask` re-checks every one
            // of the same conditions. If it somehow does — the owner turned Jev on between
            // these two lines — that is the owner's switch working, not a leak.
            //
            // `alwaysLocal` and `off` do **not** take that path, and that is the whole
            // point of them. A feature pinned away from the cloud must not reach a paid
            // call even to be told why it cannot, because a settings change landing in that
            // same gap would turn "never the cloud" into a charge.
            switch override {
            case .automatic, .alwaysJev:
                return try await service.ask(
                    feature, state: state, questions: questions,
                    cacheKey: cacheKey, deadline: deadline
                )
            case .off:
                throw JevError.disabled(feature)
            case .alwaysLocal:
                throw DecisionLaneError.nothingAvailable(feature)
            }
        }

        var attempts = [chosen]
        attempts += DecisionLanePolicy.fallbacks(
            after: chosen, override: override, available: available
        )
        var lastError: (any Error)?
        for id in attempts {
            do {
                let response = try await run(
                    id, feature: feature, state: state, questions: questions,
                    cacheKey: cacheKey, deadline: deadline
                )
                note(feature: feature, response: response, lane: id, questions: questions.count)
                return response
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                lastAnswers[feature] = DecisionRecord(
                    lane: id, peer: nil, at: Date(), latencyMS: nil,
                    questions: questions.count, failed: error.localizedDescription
                )
                // A lane that just failed is not ready, whatever it said two seconds ago —
                // unless what failed was this request rather than the lane. A state longer
                // than the checkpoint reads is refused with the lane perfectly well, and
                // marking it down would take it away from every other ability's short
                // states for the whole readiness window.
                if !Self.isRefusalOfThisRequest(error) {
                    readiness[id] = (false, Date())
                }
            }
        }
        throw lastError ?? DecisionLaneError.nothingAvailable(feature)
    }

    /// Whether a lane's error is about the request it was given, not about the lane.
    static func isRefusalOfThisRequest(_ error: any Error) -> Bool {
        guard let error = error as? DecisionLaneError else { return false }
        if case .stateTooLong = error { return true }
        return false
    }

    private func run(
        _ id: DecisionLaneID, feature: JevFeature, state: JSONContent,
        questions: [String: ControlAPI.SystemOneQuestion],
        cacheKey: String?, deadline: TimeInterval?
    ) async throws -> ControlAPI.DecideResponse {
        if id == .jev {
            // Through the service, always: this is the only path to a paid call in the
            // whole file, and it is the same call the feature made before.
            return try await service.ask(
                feature, state: state, questions: questions,
                cacheKey: cacheKey, deadline: deadline
            )
        }
        guard let lane = lanes[id] else { throw DecisionLaneError.nothingAvailable(feature) }
        let request = ControlAPI.DecideRequest(
            state: state, questions: questions, model: nil, provider: id.wireName
        )
        return try await lane.decide(request)
    }

    private func note(
        feature: JevFeature, response: ControlAPI.DecideResponse,
        lane: DecisionLaneID, questions: Int
    ) {
        let provider = response.provider ?? lane.wireName
        let peer = provider.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)
        lastAnswers[feature] = DecisionRecord(
            lane: lane, peer: peer, at: Date(), latencyMS: response.latencyMS,
            questions: questions, failed: nil
        )
    }

    public func lastAnswer(for feature: JevFeature) -> DecisionRecord? { lastAnswers[feature] }
    public func allLastAnswers() -> [JevFeature: DecisionRecord] { lastAnswers }
}
