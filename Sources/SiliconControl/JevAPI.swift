import Foundation

extension ControlAPI {

    /// `GET /jev` — what the owner has decided about Jev, what each feature would do if
    /// asked right now, and what it has cost this month.
    ///
    /// There is no field here for the API key and there never will be one. The key lives in
    /// the Keychain on the Mac; phones and swarm nodes call this Mac's `/decide`, and the
    /// Mac is what holds the credential. `keySet` says whether one exists, which is all a
    /// client needs to know to draw a sensible screen.
    public struct JevStatus: Codable, Sendable, Equatable {

        /// One feature, its switch, and its share of the month.
        public struct Feature: Codable, Sendable, Equatable {
            public var id: String
            public var displayName: String
            public var summary: String
            /// The owner's per-feature switch.
            public var enabled: Bool
            /// Whether it would answer right now: Jev on, this switch on, a key stored,
            /// budget left.
            public var available: Bool
            /// False for a feature that is on the roadmap but not yet called by anything.
            public var built: Bool
            public var calls: Int
            public var inputTokens: Int
            public var estimatedUSD: Double

            public init(
                id: String, displayName: String, summary: String, enabled: Bool,
                available: Bool, built: Bool, calls: Int, inputTokens: Int,
                estimatedUSD: Double
            ) {
                self.id = id
                self.displayName = displayName
                self.summary = summary
                self.enabled = enabled
                self.available = available
                self.built = built
                self.calls = calls
                self.inputTokens = inputTokens
                self.estimatedUSD = estimatedUSD
            }
        }

        /// The master switch.
        public var enabled: Bool
        /// The model every request pins to — a version by default, not an alias.
        public var model: String
        public var availableModels: [String]
        /// Whether a key is stored on this Mac. Never the key itself.
        public var keySet: Bool
        public var monthlyBudgetUSD: Double?
        /// What is left of the cap this month, or nil when there is no cap.
        public var budgetRemainingUSD: Double?
        public var cacheMinutes: Int
        public var maxStateBytes: Int
        /// Whether an adult media prompt is sent to the uncensored lane without asking.
        /// Nil means "follow whether an uncensored lane is installed on this Mac".
        public var automaticUncensoredLane: Bool?
        /// What that nil currently resolves to, so a client can draw the row without
        /// knowing which video models this Mac has.
        public var automaticUncensoredLaneInEffect: Bool
        /// Whether the Video tab's composer asks the media router to pick.
        public var composerAutoRoute: Bool
        /// In `JevFeature`'s own order, so a client can draw the list without sorting it.
        public var features: [Feature]
        /// Which month the totals below are for, as `2026-09`.
        public var month: String
        public var calls: Int
        public var inputTokens: Int
        public var estimatedUSD: Double
        /// Which model version actually answered, and how often, this month. A threshold
        /// tuned on one version drifting onto another shows up here first.
        public var models: [String: Int]
        /// Every month the ledger has, as month key → estimated dollars. The detail is kept
        /// for the current month; this is what a client needs to draw a history.
        public var monthlyUSD: [String: Double]
        /// True when the last call could not be written to the ledger file. The numbers
        /// above are then only as good as this session, and the budget stops counting at
        /// the next launch — which is why it is reported rather than swallowed.
        public var ledgerWriteFailed: Bool

        public init(
            enabled: Bool, model: String, availableModels: [String], keySet: Bool,
            monthlyBudgetUSD: Double?, budgetRemainingUSD: Double?, cacheMinutes: Int,
            maxStateBytes: Int, features: [Feature], month: String, calls: Int,
            inputTokens: Int, estimatedUSD: Double, models: [String: Int],
            monthlyUSD: [String: Double] = [:], ledgerWriteFailed: Bool = false,
            automaticUncensoredLane: Bool? = nil,
            automaticUncensoredLaneInEffect: Bool = false,
            composerAutoRoute: Bool = false
        ) {
            self.automaticUncensoredLane = automaticUncensoredLane
            self.automaticUncensoredLaneInEffect = automaticUncensoredLaneInEffect
            self.composerAutoRoute = composerAutoRoute
            self.enabled = enabled
            self.model = model
            self.availableModels = availableModels
            self.keySet = keySet
            self.monthlyBudgetUSD = monthlyBudgetUSD
            self.budgetRemainingUSD = budgetRemainingUSD
            self.cacheMinutes = cacheMinutes
            self.maxStateBytes = maxStateBytes
            self.features = features
            self.month = month
            self.calls = calls
            self.inputTokens = inputTokens
            self.estimatedUSD = estimatedUSD
            self.models = models
            self.monthlyUSD = monthlyUSD
            self.ledgerWriteFailed = ledgerWriteFailed
        }
    }

    // MARK: - Guardrails

    /// What the guardrail decided about one tool call.
    ///
    /// Carried in two places: `GET /jev/guardrails/recent` below, and — as `screening` — on
    /// the approval objects the Silicon Buddy agent-session API will hand a phone, so a
    /// phone deciding whether to allow a command sees the same verdict and the same reasons
    /// the Mac's own card shows. It is the reason this lives in the wire types rather than
    /// in the UI: one shape, one vocabulary, both screens.
    ///
    /// There is no field here for what was screened, and there will not be one. The command,
    /// its arguments and the request are never carried off the Mac by this type.
    public struct GuardrailScreening: Codable, Sendable, Equatable {
        /// `act`, `confirm` or `block`.
        public var verdict: String
        /// The question ids that fired, sorted — `destructive`, `exfiltrates`,
        /// `outside_working_tree`… Empty for `act`.
        public var reasons: [String]
        /// How long the screening took, end to end.
        public var latencyMS: Double?

        public init(verdict: String, reasons: [String], latencyMS: Double? = nil) {
            self.verdict = verdict
            self.reasons = reasons
            self.latencyMS = latencyMS
        }
    }

    /// One remembered screening.
    public struct GuardrailScreeningRecord: Codable, Sendable, Equatable {
        /// ISO-8601, like every other timestamp on this wire.
        public var at: String
        /// Which engine asked: `codex`, `pi`, `harness`, `buddy`.
        public var engine: String
        public var screening: GuardrailScreening
        /// Question id → `act`, `confirm` or `escalate`: where each answer landed against
        /// the feature's thresholds. For a hazard, `act` means it held firmly enough to act
        /// on, `confirm` means it was plausible, and `escalate` means it did not fire.
        public var bands: [String: String]

        public init(
            at: String, engine: String, screening: GuardrailScreening, bands: [String: String]
        ) {
            self.at = at
            self.engine = engine
            self.screening = screening
            self.bands = bands
        }
    }

    /// `GET /jev/guardrails/recent` — the last fifty screenings this Mac made.
    ///
    /// Question ids and bands, never content: the buffer holds no command, no argument and
    /// no request, so a phone reading it learns the pattern of what was refused without
    /// learning what anyone typed. In memory only; a relaunch starts it empty.
    public struct GuardrailScreenings: Codable, Sendable, Equatable {
        /// Whether a screening would happen right now — Jev on, guardrails on, a key
        /// stored, budget left.
        public var available: Bool
        /// Every question id this build asks, in its own order, so a client can label the
        /// bands without hard-coding the list.
        public var questions: [String]
        /// Oldest first.
        public var screenings: [GuardrailScreeningRecord]

        public init(
            available: Bool, questions: [String], screenings: [GuardrailScreeningRecord]
        ) {
            self.available = available
            self.questions = questions
            self.screenings = screenings
        }
    }

    /// `POST /jev` — a patch, not a replacement. Every field is optional and only what is
    /// sent changes, so a client that knows about four settings cannot wipe a fifth one it
    /// has never heard of.
    public struct JevUpdate: Codable, Sendable, Equatable {
        public var enabled: Bool?
        public var model: String?
        /// Feature id → switch. Ids this build does not know are ignored.
        public var features: [String: Bool]?
        public var monthlyBudgetUSD: Double?
        /// Clears the cap. Needed because a missing `monthlyBudgetUSD` means "leave it
        /// alone", so there is no way to say "no cap" with that field alone.
        public var clearMonthlyBudget: Bool?
        public var cacheMinutes: Int?
        public var maxStateBytes: Int?
        /// Whether adult media prompts are routed to the uncensored lane automatically.
        public var automaticUncensoredLane: Bool?
        /// Puts `automaticUncensoredLane` back to "follow whether a lane is installed".
        /// Needed for the same reason as `clearMonthlyBudget`: absent means "leave alone".
        public var clearAutomaticUncensoredLane: Bool?
        public var composerAutoRoute: Bool?

        public init(
            enabled: Bool? = nil, model: String? = nil, features: [String: Bool]? = nil,
            monthlyBudgetUSD: Double? = nil, clearMonthlyBudget: Bool? = nil,
            cacheMinutes: Int? = nil, maxStateBytes: Int? = nil,
            automaticUncensoredLane: Bool? = nil,
            clearAutomaticUncensoredLane: Bool? = nil, composerAutoRoute: Bool? = nil
        ) {
            self.automaticUncensoredLane = automaticUncensoredLane
            self.clearAutomaticUncensoredLane = clearAutomaticUncensoredLane
            self.composerAutoRoute = composerAutoRoute
            self.enabled = enabled
            self.model = model
            self.features = features
            self.monthlyBudgetUSD = monthlyBudgetUSD
            self.clearMonthlyBudget = clearMonthlyBudget
            self.cacheMinutes = cacheMinutes
            self.maxStateBytes = maxStateBytes
        }
    }
}
