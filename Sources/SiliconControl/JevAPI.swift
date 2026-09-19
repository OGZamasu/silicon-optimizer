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

        public init(
            enabled: Bool, model: String, availableModels: [String], keySet: Bool,
            monthlyBudgetUSD: Double?, budgetRemainingUSD: Double?, cacheMinutes: Int,
            maxStateBytes: Int, features: [Feature], month: String, calls: Int,
            inputTokens: Int, estimatedUSD: Double, models: [String: Int],
            monthlyUSD: [String: Double] = [:]
        ) {
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

        public init(
            enabled: Bool? = nil, model: String? = nil, features: [String: Bool]? = nil,
            monthlyBudgetUSD: Double? = nil, clearMonthlyBudget: Bool? = nil,
            cacheMinutes: Int? = nil, maxStateBytes: Int? = nil
        ) {
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
