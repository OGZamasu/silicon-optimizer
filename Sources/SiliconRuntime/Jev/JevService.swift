import CryptoKit
import Foundation
import SiliconControl

// MARK: - Features

/// The places in this app that may ask Jev a question.
///
/// One enum rather than a free-form string because every governed thing — the settings
/// toggles, the ledger's breakdown, the budget, the control API — keys off it. A feature
/// that is not in this list cannot spend the owner's money.
public enum JevFeature: String, CaseIterable, Codable, Sendable {
    case decideTool
    case guardrails
    case routing
    case mediaRouting
    case skillSelection
    case recommendation
    case verification
    case calibration

    public var displayName: String {
        switch self {
        case .decideTool: "Decide tool"
        case .guardrails: "Guardrails"
        case .routing: "Prompt routing"
        case .mediaRouting: "Media routing"
        case .skillSelection: "Tool selection and pruning"
        case .recommendation: "Model recommendation"
        case .verification: "Answer verification"
        case .calibration: "Decision calibration"
        }
    }

    /// One line, written for the Settings row rather than for a developer: the owner is
    /// deciding whether to pay for this, so it says what it buys, not how it works.
    public var summary: String {
        switch self {
        case .decideTool:
            "Answers the `decide` tool and POST /decide with calibrated probabilities instead of the local model's own."
        case .guardrails:
            "Screens a tool call before it runs — what it touches, what it would cost, "
            + "whether the user asked for it — and turns that into run, ask, or refuse."
        case .routing:
            "Picks which loaded model, runtime or swarm node should take a request."
        case .mediaRouting:
            "Reads an image, video or mesh request and picks the model and settings for it."
        case .skillSelection:
            "Tool selection and pruning: suggests which tool or skill fits the turn, and "
            + "which history a small model still needs."
        case .recommendation:
            "Reads your description of the job and ranks the models this Mac can run by "
            + "what that job actually needs."
        case .verification:
            "Checks a finished answer against its evidence and flags the ones worth a second look."
        case .calibration:
            "Measures the local decision lane against Jev on a labelled set and tunes when "
            + "`auto` falls back to Jev."
        }
    }

    /// Whether the app actually calls Jev for this yet. The rest are shown in Settings as
    /// the roadmap — off, captioned "coming" — so the owner can see where this is going
    /// rather than meeting eight new toggles at once later.
    public var isBuilt: Bool { Self.built.contains(self) }

    /// One list rather than a chain of `==`, so each feature's own PR adds a member here
    /// and nothing else — and a branch that lands beside another settles the conflict by
    /// keeping both members rather than choosing between two rewritten expressions.
    private static let built: Set<JevFeature> = [
        .decideTool, .routing, .mediaRouting, .guardrails, .recommendation,
        .verification, .calibration, .skillSelection,
    ]
}

/// The shared three-way gate: act, ask, or hand it to a person.
///
/// TypeSafe's own advice is that a confidence threshold is not one number — the level at
/// which you act without asking depends on what happens when the answer is wrong. So the
/// band is computed here and the two numbers are the caller's.
public enum JevBand: String, Codable, Sendable, Equatable {
    /// Confident enough to do the thing.
    case act
    /// Plausible, but worth a confirmation before acting.
    case confirm
    /// Not confident enough to use. Ask a person, or fall back to code.
    case escalate
}

/// A feature's two thresholds, kept beside its questions so a human reviewing the feature
/// sees the judgment and the policy at once.
public struct JevThresholds: Codable, Sendable, Equatable {
    /// At or above this confidence, act without asking.
    public var act: Double
    /// At or above this confidence but below `act`, confirm first. Below it, escalate.
    public var confirm: Double

    public init(act: Double, confirm: Double) {
        self.act = act
        self.confirm = confirm
    }

    public func band(_ confidence: Double) -> JevBand {
        JevService.confidenceBand(confidence, low: confirm, high: act)
    }

    /// The gate for a **noul**, which is a different shape from the one above.
    ///
    /// A noul has no `confidence`: the number it returns *is* the answer, the probability
    /// that the statement holds. 0.5 does not mean "medium intensity", it means the model
    /// finds yes and no about equally likely — so the certain answers are at *both* ends
    /// and the useless ones are in the middle. Putting a Choice/Score confidence gate on a
    /// noul reads 0.05 — a confident no — as no confidence at all.
    ///
    /// So: act at `yes` and above (a confident yes) or at `no` and below (a confident no),
    /// escalate in between. There is no `.confirm` band here; a noul that has landed in the
    /// middle has nothing to confirm. See TypeSafe's Confidence page and the `jev-1.13`
    /// jaggedness note on numeric reading.
    public static func noulBand(_ p: Double, yes: Double, no: Double) -> JevBand {
        (p >= yes || p <= no) ? .act : .escalate
    }
}

/// What a feature implements to ask Jev something.
///
/// The protocol requires only the feature and its questions. The **convention** — which the
/// protocol cannot enforce and which every feature is nonetheless expected to follow — is
/// that a feature's questions and its thresholds live together in one file,
/// `Sources/SiliconUI/Jev/<Feature>Questions.swift`. That directory because the hooks that
/// call them are in `SiliconUI`; one file because of review.
///
/// This is TypeSafe's own advice, and the reason is review. A question's wording *is* the
/// behaviour — `jev-1.13` answers what you wrote rather than what you meant — and a
/// threshold decides what the app does with the answer. Split across three files they drift;
/// in one file a person can read the whole policy in a minute and say whether it is right.
public protocol JevQuestionSet {
    static var feature: JevFeature { get }
    static var questions: [String: ControlAPI.SystemOneQuestion] { get }
}

extension JevQuestionSet {
    /// Asks this set's questions through the one door, so the feature toggle, the budget,
    /// the cache and the ledger all apply without the caller remembering them.
    ///
    /// - Parameter service: the app leaves this alone. A feature's own tests pass a
    ///   `JevService` pointed at a loopback server, so a question set can be exercised
    ///   end to end without the shared instance or a real key.
    public static func ask(
        state: JSONContent, cacheKey: String? = nil, using service: JevService = .shared
    ) async throws -> ControlAPI.DecideResponse {
        try await service.ask(
            feature, state: state, questions: questions, cacheKey: cacheKey
        )
    }
}

// MARK: - Settings

/// What the owner has decided about Jev, in
/// `~/Library/Application Support/SiliconOptimizer/jev.json`.
///
/// Its own file rather than a line in the app's settings: this governs spending, it is read
/// by an actor rather than by the main-actor settings object, and a control client may
/// rewrite it. The API key is *not* here and never will be — it lives in the Keychain.
public struct JevSettings: Codable, Sendable, Equatable {

    /// The master switch. Off means no feature asks Jev anything, whatever its own toggle
    /// says, and nothing reads the Keychain.
    public var enabled: Bool = false

    /// Pinned by default rather than `jev-latest`. An alias moves when TypeSafe ships a
    /// release, and thresholds tuned against one version are not promises about the next
    /// one — so the version is chosen here and changed deliberately.
    public var model: String = JevService.pinnedModel

    /// Per-feature switches. Everything is off but the decide tool, which is the one
    /// feature that exists and the one the owner already opted into by adding a key.
    public var features: [JevFeature: Bool] = Self.defaultFeatures

    /// Nil means no cap. Otherwise Jev stops answering once this month's estimated spend
    /// reaches it, and the features fail closed rather than quietly costing more.
    public var monthlyBudgetUSD: Double?

    /// Which gateway model `silicon/auto` falls back to when Jev cannot be asked, or is not
    /// sure enough to choose. Nil — the default — means the model loaded on this Mac, else
    /// the first one that would answer without a load.
    ///
    /// Here rather than in the app's own settings because it belongs to a Jev feature, and
    /// because this file is the one a person can open, read and edit: a fallback that lived
    /// in `UserDefaults` could not be seen, copied to another Mac, or pointed somewhere else
    /// by `SILICON_JEV_CONFIG` for a test.
    public var routingFallbackModel: String?

    /// How long an identical question keeps its answer. Zero turns the cache off.
    public var cacheMinutes: Int = 10

    /// Whether an adult prompt may be sent to the uncensored lane without being asked.
    ///
    /// Nil is the default and is not the same as false: it means "follow whether an
    /// uncensored lane is installed", and that is resolved every time it is read rather than
    /// frozen the first time a settings window is drawn. Someone who installs a lane after
    /// saying nothing gets the sensible answer; someone who said no keeps it.
    ///
    /// Here rather than in `UserDefaults` because it governs where a prompt is allowed to
    /// go, which is the same kind of decision as the rest of this file — and because
    /// `GET /jev` and a paired phone should be able to see and set it.
    public var automaticUncensoredLane: Bool?

    /// Whether the Video tab's composer asks the media router to pick the model and the
    /// length, rather than using the ones in its own controls.
    public var composerAutoRoute: Bool = false

    /// Whether an agent's tool call that the guardrail rates safe may be answered without
    /// the person: `.act` is accepted, `.block` is denied, and `.confirm` still waits for a
    /// human whatever this says.
    ///
    /// Off by default, and it belongs here rather than in the app's settings because it is
    /// the one switch that lets a model's judgment stand in for the owner's. Turning it on
    /// is a considered decision about a specific feature; it is not a default anyone should
    /// acquire by upgrading.
    public var autoApproveSafeToolCalls: Bool = false

    /// Whether the gateway may drop old tool results out of a chat request bound for a
    /// model running on hardware you own, once the prompt is crowding that model's window.
    ///
    /// Off by default, and deliberately its own switch under the feature rather than part
    /// of it: suggesting a tool changes what a model is *told*, while this changes what it
    /// is *given*, and a wrong drop is a turn that has forgotten something. Someone who
    /// wants the suggestion is not thereby asking for the pruning.
    public var pruneToolHistory: Bool = false

    /// How full the target model's context window has to be before pruning is considered,
    /// as a fraction of it. Below this the history is not the problem and the cheapest
    /// correct thing to do is nothing.
    ///
    /// 0.7 leaves the model most of its window before anything is touched, and leaves room
    /// for the answer after it. Clamped to 0.1…0.95 in `normalized()`: 0 would prune every
    /// request and 1 would prune none, and neither is a setting anyone means.
    public var pruneAboveFraction: Double = 0.7

    /// The largest `state` this app will send, in bytes — a deliberately pessimistic proxy
    /// for tokens. `jev-1.13` allows 32k tokens for the state plus the longest question and
    /// 64k for the state plus *all* the questions, and a byte is not a token: dense prose
    /// runs near four bytes to a token, but JSON keys, punctuation and non-English text run
    /// far closer to one. 64 KB stays inside both budgets even at the bad end of that range
    /// with room left for a dozen questions. Refused here rather than at TypeSafe, because a
    /// 422 costs a round trip and says nothing useful — and because past this size the model
    /// loses accuracy to irrelevant detail anyway.
    public var maxStateBytes: Int = JevService.defaultMaxStateBytes

    /// Which gateway model a flagged answer is re-run on — a `GatewayAPI` model id such as
    /// `cloud/openai/gpt-5.5` or `node/studio/qwen3.8-27b`, chosen in Settings.
    ///
    /// Nil means "work it out": a model a swarm node is already serving, else an enabled
    /// cloud model, else nothing and the answer is only annotated. Only `.verification`
    /// reads it, but it lives here because this is the file the owner's Jev decisions are
    /// kept in and a control client may rewrite.
    public var verificationEscalationModel: String?
    /// The cascade's floors, when no calibration has been run for the loaded model.
    ///
    /// `POST /jev/calibrate` measures better ones and writes them to `local-calibration.json`
    /// beside this file; these three are what the cascade uses until then, and what it falls
    /// back to when a different model is loaded. They are deliberately unambitious — a
    /// choice the local model is less than 60% sure of, or a noul it has put near the middle,
    /// is worth a second opinion on almost any model.
    ///
    /// One number here for both choices and scores, which a calibration then splits in two.
    /// Before anything has been measured there is nothing to tell them apart with, and two
    /// identical settings rows would be asking the owner a question they cannot answer.
    public var cascadeFloor: Double = JevSettings.defaultCascadeFloor
    /// A noul strictly between these two is escalated; at either edge it is a confident
    /// answer. Exclusive on purpose, so this agrees with `JevThresholds.noulBand`.
    public var cascadeNoulLow: Double = JevSettings.defaultCascadeNoulLow
    public var cascadeNoulHigh: Double = JevSettings.defaultCascadeNoulHigh

    public static let defaultCascadeFloor = 0.6
    public static let defaultCascadeNoulLow = 0.25
    public static let defaultCascadeNoulHigh = 0.75

    /// The floors as the cascade wants them, before a calibration file is consulted.
    public var cascadeFloors: ControlAPI.JevCalibration.Floors {
        .init(confidence: cascadeFloor, noulLow: cascadeNoulLow, noulHigh: cascadeNoulHigh)
    }

    public init() {}

    public static let defaultFeatures: [JevFeature: Bool] = Dictionary(
        uniqueKeysWithValues: JevFeature.allCases.map { ($0, $0 == .decideTool) }
    )

    public func isOn(_ feature: JevFeature) -> Bool { features[feature] ?? false }

    /// Whether an adult prompt is routed automatically, resolved against what is installed
    /// right now. Nil follows the lane; a stored answer overrides it.
    public func automaticUncensoredLane(uncensoredLaneInstalled: Bool) -> Bool {
        automaticUncensoredLane ?? uncensoredLaneInstalled
    }

    // MARK: Storage

    /// Hand-rolled rather than synthesised for two reasons: a `[JevFeature: Bool]` would
    /// encode as a flat array of alternating keys and values, and a file written by a
    /// build that knows a feature this one does not must not fail the whole load.
    private enum CodingKeys: String, CodingKey {
        case enabled, model, features, monthlyBudgetUSD, cacheMinutes, maxStateBytes
        case routingFallbackModel
        case automaticUncensoredLane, composerAutoRoute
        case autoApproveSafeToolCalls
        case verificationEscalationModel
        case cascadeFloor, cascadeNoulLow, cascadeNoulHigh
        case pruneToolHistory, pruneAboveFraction
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? model
        monthlyBudgetUSD = try container.decodeIfPresent(Double.self, forKey: .monthlyBudgetUSD)
        cacheMinutes = try container.decodeIfPresent(Int.self, forKey: .cacheMinutes) ?? cacheMinutes
        maxStateBytes = try container.decodeIfPresent(Int.self, forKey: .maxStateBytes) ?? maxStateBytes
        routingFallbackModel = try container.decodeIfPresent(
            String.self, forKey: .routingFallbackModel
        )
        automaticUncensoredLane = try container.decodeIfPresent(
            Bool.self, forKey: .automaticUncensoredLane
        )
        composerAutoRoute = try container.decodeIfPresent(
            Bool.self, forKey: .composerAutoRoute
        ) ?? composerAutoRoute
        autoApproveSafeToolCalls = try container.decodeIfPresent(
            Bool.self, forKey: .autoApproveSafeToolCalls
        ) ?? autoApproveSafeToolCalls
        verificationEscalationModel = try container.decodeIfPresent(
            String.self, forKey: .verificationEscalationModel
        )
        cascadeFloor = try container.decodeIfPresent(Double.self, forKey: .cascadeFloor) ?? cascadeFloor
        cascadeNoulLow = try container.decodeIfPresent(Double.self, forKey: .cascadeNoulLow) ?? cascadeNoulLow
        cascadeNoulHigh = try container.decodeIfPresent(Double.self, forKey: .cascadeNoulHigh) ?? cascadeNoulHigh
        pruneToolHistory = try container.decodeIfPresent(
            Bool.self, forKey: .pruneToolHistory
        ) ?? pruneToolHistory
        pruneAboveFraction = try container.decodeIfPresent(
            Double.self, forKey: .pruneAboveFraction
        ) ?? pruneAboveFraction
        if let raw = try container.decodeIfPresent([String: Bool].self, forKey: .features) {
            for (name, on) in raw {
                // An unknown name is a feature from a newer build. Ignoring it is right:
                // this build cannot call it, so its switch means nothing here.
                guard let feature = JevFeature(rawValue: name) else { continue }
                features[feature] = on
            }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(monthlyBudgetUSD, forKey: .monthlyBudgetUSD)
        try container.encode(cacheMinutes, forKey: .cacheMinutes)
        try container.encode(maxStateBytes, forKey: .maxStateBytes)
        try container.encodeIfPresent(routingFallbackModel, forKey: .routingFallbackModel)
        // Written only once the owner has actually chosen. Absent still means "follow
        // whether a lane is installed", which deleting the line restores.
        try container.encodeIfPresent(automaticUncensoredLane, forKey: .automaticUncensoredLane)
        try container.encode(composerAutoRoute, forKey: .composerAutoRoute)
        try container.encode(autoApproveSafeToolCalls, forKey: .autoApproveSafeToolCalls)
        try container.encodeIfPresent(
            verificationEscalationModel, forKey: .verificationEscalationModel
        )
        try container.encode(cascadeFloor, forKey: .cascadeFloor)
        try container.encode(cascadeNoulLow, forKey: .cascadeNoulLow)
        try container.encode(cascadeNoulHigh, forKey: .cascadeNoulHigh)
        try container.encode(pruneToolHistory, forKey: .pruneToolHistory)
        try container.encode(pruneAboveFraction, forKey: .pruneAboveFraction)
        // Every case, every time: a file that lists all eight is one a person can edit.
        try container.encode(
            Dictionary(uniqueKeysWithValues: JevFeature.allCases.map { ($0.rawValue, isOn($0)) }),
            forKey: .features
        )
    }

    /// `SILICON_JEV_CONFIG` points both this and the ledger somewhere else, which is how
    /// the tests get a private pair of files instead of the owner's.
    public static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["SILICON_JEV_CONFIG"] {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("SiliconOptimizer/jev.json")
    }

    /// The ledger sits next to the settings, so an override relocates both.
    public static var ledgerURL: URL { ledgerURL(besideConfigAt: configURL) }

    /// The pairing rule on its own, so it can be checked without a process-wide variable.
    public static func ledgerURL(besideConfigAt config: URL) -> URL {
        config.deletingLastPathComponent().appendingPathComponent("jev-ledger.json")
    }

    /// The last calibration run, beside the settings like everything else Jev owns.
    public static var calibrationURL: URL { calibrationURL(besideConfigAt: configURL) }

    public static func calibrationURL(besideConfigAt config: URL) -> URL {
        config.deletingLastPathComponent().appendingPathComponent("local-calibration.json")
    }

    /// Cases the owner added by hand, which the run appends to the built-in set.
    ///
    /// `SILICON_JEV_CALIBRATION_CASES` names the file outright — that is how the tests get
    /// one of their own — and otherwise it sits beside the settings, so
    /// `SILICON_JEV_CONFIG` relocates it with everything else.
    public static var userCasesURL: URL {
        if let override = ProcessInfo.processInfo.environment["SILICON_JEV_CALIBRATION_CASES"] {
            return URL(fileURLWithPath: override)
        }
        return userCasesURL(besideConfigAt: configURL)
    }

    public static func userCasesURL(besideConfigAt config: URL) -> URL {
        config.deletingLastPathComponent().appendingPathComponent("jev-calibration.json")
    }

    /// A missing or unreadable file reads as the defaults — off, nothing spent — which is
    /// the state this feature ships in and the only safe thing to assume about a file that
    /// will not parse.
    public static func load(from url: URL = configURL) -> JevSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(JevSettings.self, from: data)
        else { return JevSettings() }
        return settings.normalized()
    }

    public func save(to url: URL = configURL) throws {
        let data = try JevService.encoder.encode(self)
        try JevService.prepareDirectory(for: url)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    /// Clamps whatever a hand-edited file or a control client asked for into what this app
    /// will actually do. An unknown model name is the important one: it would be a 422 on
    /// every call, so it falls back to the pin rather than breaking the feature silently.
    public func normalized() -> JevSettings {
        var copy = self
        if !JevService.allowedModels.contains(copy.model) { copy.model = JevService.pinnedModel }
        copy.cacheMinutes = max(0, min(copy.cacheMinutes, 24 * 60))
        copy.maxStateBytes = max(1_024, min(copy.maxStateBytes, JevService.hardMaxStateBytes))
        copy.cascadeFloor = Self.clampProbability(copy.cascadeFloor, default: Self.defaultCascadeFloor)
        copy.cascadeNoulLow = Self.clampProbability(copy.cascadeNoulLow, default: Self.defaultCascadeNoulLow)
        copy.cascadeNoulHigh = Self.clampProbability(copy.cascadeNoulHigh, default: Self.defaultCascadeNoulHigh)
        // An inverted band would escalate nothing at all, which is not a setting anybody
        // means: a hand-edited file that says 0.8–0.2 gets the pair the right way round.
        if copy.cascadeNoulLow > copy.cascadeNoulHigh {
            swap(&copy.cascadeNoulLow, &copy.cascadeNoulHigh)
        }
        // A hand-edited NaN would compare false against every threshold and quietly turn
        // pruning off; the default is the honest answer to a number that is not one.
        copy.pruneAboveFraction = copy.pruneAboveFraction.isFinite
            ? max(0.1, min(copy.pruneAboveFraction, 0.95))
            : JevSettings().pruneAboveFraction
        if let budget = copy.monthlyBudgetUSD, !budget.isFinite || budget < 0 {
            copy.monthlyBudgetUSD = nil
        }
        // A hand-edited file may leave the field blank meaning "no pick"; that is nil here,
        // so the router does not go looking for a model called "".
        if let fallback = copy.routingFallbackModel,
           fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.routingFallbackModel = nil
        }
        // The same for the escalation target: the picker's "work it out" row arrives as an
        // empty string, and storing that would be a model id no gateway can parse.
        if let target = copy.verificationEscalationModel,
           target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            copy.verificationEscalationModel = nil
        }
        for feature in JevFeature.allCases where copy.features[feature] == nil {
            copy.features[feature] = Self.defaultFeatures[feature] ?? false
        }
        return copy
    }

    /// A probability from a file somebody may have typed into. NaN and infinity are not
    /// clampable into anything meaningful, so they go back to the default rather than to an
    /// edge that would read as a deliberate choice.
    static func clampProbability(_ value: Double, default fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return max(0, min(1, value))
    }
}

// MARK: - Ledger

/// What Jev has been asked and what it cost, in `jev-ledger.json` beside the settings.
///
/// Kept per month and per feature because those are the two questions an owner actually
/// asks — "what am I spending?" and "on what?" — and because the budget is monthly. A new
/// month is a new key rather than a reset, so last month is still there to look at.
public struct JevLedger: Codable, Sendable, Equatable {

    /// TypeSafe charges for input tokens only; output is free. The number itself lives in
    /// `SiliconControl`, which the MCP bridge links and this target does not reach into —
    /// so a run's cost can be quoted there from the same figure billed here.
    public static let usdPerMillionInputTokens = ControlAPI.JevPricing.usdPerMillionInputTokens

    public static func cost(inputTokens: Int) -> Double {
        ControlAPI.JevPricing.costUSD(inputTokens: inputTokens)
    }

    /// One bucket of spend. Latency is summed rather than listed: an average is what a
    /// settings line can show, and keeping every call would make this file grow forever.
    public struct Entry: Codable, Sendable, Equatable {
        public var calls: Int = 0
        public var inputTokens: Int = 0
        public var outputTokens: Int = 0
        public var latencyMSTotal: Double = 0

        public init() {}

        public var estimatedUSD: Double { JevLedger.cost(inputTokens: inputTokens) }

        public var averageLatencyMS: Double? {
            calls > 0 ? latencyMSTotal / Double(calls) : nil
        }

        mutating func add(inputTokens: Int, outputTokens: Int, latencyMS: Double) {
            calls += 1
            self.inputTokens += inputTokens
            self.outputTokens += outputTokens
            latencyMSTotal += latencyMS
        }
    }

    public struct Month: Codable, Sendable, Equatable {
        public var total = Entry()
        /// Feature raw value → its share of the month.
        public var features: [String: Entry] = [:]
        /// Which model version actually answered, and how often. The response reports the
        /// versioned id even when the request named an alias, so this is how a threshold
        /// tuned on 1.13 gets noticed drifting onto 1.14.
        public var models: [String: Int] = [:]

        public init() {}
    }

    /// `"2026-09"` → that month.
    public var months: [String: Month] = [:]

    public init() {}

    public static func monthKey(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    public func month(_ key: String = JevLedger.monthKey()) -> Month {
        months[key] ?? Month()
    }

    /// The three headline numbers, over the current month — which is what the budget is
    /// about and what Settings shows.
    public var calls: Int { month().total.calls }
    public var inputTokens: Int { month().total.inputTokens }
    public var estimatedUSD: Double { month().total.estimatedUSD }

    public func spentUSD(in key: String = JevLedger.monthKey()) -> Double {
        month(key).total.estimatedUSD
    }

    public mutating func record(
        feature: JevFeature, inputTokens: Int, outputTokens: Int,
        latencyMS: Double, model: String, at date: Date = Date()
    ) {
        let key = Self.monthKey(date)
        var month = months[key] ?? Month()
        month.total.add(inputTokens: inputTokens, outputTokens: outputTokens, latencyMS: latencyMS)
        var feature_ = month.features[feature.rawValue] ?? Entry()
        feature_.add(inputTokens: inputTokens, outputTokens: outputTokens, latencyMS: latencyMS)
        month.features[feature.rawValue] = feature_
        month.models[model, default: 0] += 1
        months[key] = month
    }

    public static func load(from url: URL = JevSettings.ledgerURL) -> JevLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(JevLedger.self, from: data)
        else { return JevLedger() }
        return ledger
    }

    public func save(to url: URL = JevSettings.ledgerURL) throws {
        let data = try JevService.encoder.encode(self)
        try JevService.prepareDirectory(for: url)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }
}

// MARK: - Errors

public enum JevError: Error, LocalizedError, Equatable {
    /// Jev is off, or this feature's switch is.
    case disabled(JevFeature)
    /// No key in the Keychain. Nothing was sent.
    case noKey
    case budgetExhausted(spentUSD: Double, budgetUSD: Double)
    case tooLarge(bytes: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .disabled(let feature):
            "Jev is not enabled for \(feature.displayName). Turn it on in Settings → TypeSafe (Jev)."
        case .noKey:
            "No TypeSafe API key is set. Add one in Settings → TypeSafe (Jev)."
        case .budgetExhausted(let spent, let budget):
            String(
                format: "This month's Jev budget is spent (about $%.2f of $%.2f). Raise or clear the cap in Settings → TypeSafe (Jev).",
                spent, budget
            )
        case .tooLarge(let bytes, let limit):
            String(
                format: "That state is %.1f KB; Jev is sent at most %.1f KB. Filter it down to what the question needs.",
                Double(bytes) / 1024, Double(limit) / 1024
            )
        }
    }
}

// MARK: - The service

/// The one door every Jev-backed feature goes through.
///
/// Features do not build a `SystemOneClient` of their own, and that is the point: enabling,
/// the model pin, the size limit, the budget, the retry policy, the cache and the ledger are
/// all decided once, here, where the owner's settings can reach them. A feature that wants
/// to ask Jev something writes a `JevQuestionSet` and calls `ask`.
///
/// The API key never appears in this type's stored state as anything but a closure that can
/// fetch it. It is read from the Keychain at the moment a request is about to be sent, is
/// held only for the length of that call, is never logged, never written to either JSON file
/// and never returned by any control route.
public actor JevService {

    public static let shared = JevService()

    /// The version this app is tuned against. `JevSettings.model` defaults to it.
    public static let pinnedModel = "jev-1.13.0"
    /// What the model picker offers, and what a control client may set. An alias is allowed
    /// but not the default — see `JevSettings.model`.
    public static let allowedModels = [pinnedModel, "jev-latest", "jev-preview"]

    public static let defaultMaxStateBytes = 64 * 1024
    /// The ceiling the setting may be raised to. `jev-1.13` allows 32k tokens for the state
    /// plus the longest question, and bytes are a pessimistic proxy for tokens — at one byte
    /// per token, which is where JSON and non-English text land, 96 KB is already past that
    /// budget. Nobody should need it, and nothing above it can be asked for.
    public static let hardMaxStateBytes = 96 * 1024

    /// Total attempts, not retries: one call, then at most two more on 429/529.
    public static let maximumAttempts = 3
    /// However long a `retry-after` asks for, this app waits at most this long before
    /// giving the caller its error back. A UI feature cannot sit on a request for an hour.
    public static let maximumBackoffSeconds: TimeInterval = 30

    /// Both files are user-only, and so is the directory holding them. 0600 on a file
    /// inside a world-readable directory still leaks the fact of the file and its size.
    static func prepareDirectory(for url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    // MARK: Wiring

    private var keyProvider: @Sendable () -> String? = { nil }
    private var keyIsSetProvider: (@Sendable () -> Bool)?
    private var baseURL = SystemOneClient.typeSafeBaseURL
    private var session: URLSession?
    private var sleeper: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(for: .seconds(seconds))
    }

    private var configURL = JevSettings.configURL
    private var ledgerURL = JevSettings.ledgerURL
    private var loadedSettings: JevSettings?
    private var loadedLedger: JevLedger?
    private var cache: [String: CacheEntry] = [:]

    /// What the last completed `ask` waited between attempts. The authority is the value
    /// `send` returns; this is a mirror for the Settings debug line and for tests, and with
    /// two asks in flight it is whichever finished last.
    public private(set) var lastRetryDelays: [TimeInterval] = []

    /// Why the ledger could not be written, if it could not. A silent failure here would
    /// mean the budget quietly stopped counting — the one thing a spending cap must not do
    /// — so it is surfaced in `GET /jev` and on the Settings screen.
    public private(set) var ledgerWriteError: String?

    public var ledgerWriteFailed: Bool { ledgerWriteError != nil }

    /// Requests on the wire right now, keyed the same way the cache is. A second identical
    /// ask joins the first rather than paying for it again.
    private var inFlight: [String: Task<ControlAPI.DecideResponse, any Error>] = [:]

    /// What those in-flight requests might still add to the month, estimated from the bytes
    /// going out. Without it a burst of concurrent asks all read the same spent figure and
    /// all pass a cap they collectively break.
    private var reservedUSD: Double = 0

    private struct CacheEntry {
        var response: ControlAPI.DecideResponse
        var storedAt: Date
    }

    public init() {}

    /// Points the service at a key and a server.
    ///
    /// - Parameters:
    ///   - keyProvider: reads the key from wherever it lives — in the app, the Keychain.
    ///     Called at most once per network call, and never when a check refuses first.
    ///   - baseURL: TypeSafe, or a loopback double in tests.
    ///   - keyIsSet: whether a key exists, *without* fetching it. The Keychain can answer
    ///     that from attributes alone and so without a consent prompt, which is why it is
    ///     a separate closure: `isAvailable` is called while drawing Settings, and drawing
    ///     Settings must not put a system dialog on screen.
    ///   - session: a URLSession for tests.
    ///   - sleep: the backoff's wait, so a test can assert the delays instead of serving them.
    ///   - configURL: where the settings live, and — beside them — the ledger. The app
    ///     leaves this nil and gets `JevSettings.configURL`, which reads `SILICON_JEV_CONFIG`
    ///     when it is set. Passed explicitly by tests, which run in parallel and so cannot
    ///     each own a process-wide environment variable.
    public func configure(
        keyProvider: @escaping @Sendable () -> String?,
        baseURL: URL = SystemOneClient.typeSafeBaseURL,
        keyIsSet: (@Sendable () -> Bool)? = nil,
        session: URLSession? = nil,
        sleep: (@Sendable (TimeInterval) async -> Void)? = nil,
        configURL: URL? = nil
    ) {
        self.keyProvider = keyProvider
        self.keyIsSetProvider = keyIsSet
        self.baseURL = baseURL
        self.session = session
        if let sleep { self.sleeper = sleep }
        // Re-read the files: a caller that repoints the store must not inherit the previous
        // location's settings from this actor's cache.
        self.configURL = configURL ?? JevSettings.configURL
        ledgerURL = JevSettings.ledgerURL(besideConfigAt: self.configURL)
        loadedSettings = nil
        loadedLedger = nil
        ledgerWriteError = nil
        cache.removeAll()
        lastRetryDelays = []
    }

    // MARK: Settings

    public func settings() -> JevSettings {
        if let loadedSettings { return loadedSettings }
        let loaded = JevSettings.load(from: configURL)
        loadedSettings = loaded
        return loaded
    }

    /// Edit-in-place, normalise, persist. Throws only if the file could not be written —
    /// an owner who turned a feature on should be told when that did not stick.
    ///
    /// `@Sendable` because the callers are the main actor (Settings) and a control route,
    /// and an edit crossing into this actor has to be safe to run here.
    public func update(_ change: @Sendable (inout JevSettings) -> Void) throws {
        var updated = settings()
        change(&updated)
        updated = updated.normalized()
        try updated.save(to: configURL)
        loadedSettings = updated
        // A model or cache-window change invalidates answers held under the old one.
        cache.removeAll()
    }

    public func ledger() -> JevLedger {
        if let loadedLedger { return loadedLedger }
        let loaded = JevLedger.load(from: ledgerURL)
        loadedLedger = loaded
        return loaded
    }

    /// Where this service's three sibling files live — the settings, the last calibration,
    /// and the owner's own calibration cases.
    ///
    /// Asked of the actor rather than derived from `JevSettings.configURL` by the caller,
    /// because a test points `configure(configURL:)` somewhere private and everything that
    /// writes beside the settings has to follow it there.
    public func storeLocations() -> (config: URL, calibration: URL, userCases: URL) {
        (
            configURL,
            JevSettings.calibrationURL(besideConfigAt: configURL),
            configURL == JevSettings.configURL
                ? JevSettings.userCasesURL
                : JevSettings.userCasesURL(besideConfigAt: configURL)
        )
    }

    /// Whether this feature would answer right now. Four conditions, all cheap: no network,
    /// and no Keychain prompt.
    public func isAvailable(_ feature: JevFeature) -> Bool {
        let settings = settings()
        guard settings.enabled, settings.isOn(feature), hasKey() else { return false }
        return (remainingBudgetUSD(settings) ?? .infinity) > 0
    }

    private func hasKey() -> Bool {
        if let keyIsSetProvider { return keyIsSetProvider() }
        return keyProvider() != nil
    }

    /// Nil means no cap was set. Otherwise what is left of it this month, counting what is
    /// already on the wire as if it had landed.
    private func remainingBudgetUSD(_ settings: JevSettings) -> Double? {
        guard let budget = settings.monthlyBudgetUSD else { return nil }
        return budget - ledger().spentUSD() - reservedUSD
    }

    // MARK: The gate

    /// Where a confidence lands on the three-way gate.
    ///
    /// `high` and above acts, `low` and above confirms, below `low` escalates. The two
    /// numbers belong to the feature, not to this function: what counts as confident
    /// enough to delete a file is not what counts as confident enough to pick a tab.
    public static func confidenceBand(_ c: Double, low: Double, high: Double) -> JevBand {
        if c >= high { return .act }
        if c >= low { return .confirm }
        return .escalate
    }

    // MARK: Asking

    /// One request to Jev, governed.
    ///
    /// Everything that can refuse does so before a socket is opened: the feature's switch,
    /// the budget, the size of the state, the shape of the questions, the presence of a key.
    /// What is left is a single request — Jev reads the state once and answers every
    /// question against it in parallel, so a feature should ask all of its questions here
    /// rather than calling repeatedly.
    ///
    /// - Parameter cacheKey: replaces the derived key when the caller knows two states are
    ///   the same decision — a file whose path matters but whose modification date does not.
    @discardableResult
    public func ask(
        _ feature: JevFeature,
        state: JSONContent,
        questions: [String: ControlAPI.SystemOneQuestion],
        cacheKey: String? = nil
    ) async throws -> ControlAPI.DecideResponse {
        let settings = settings()
        guard settings.enabled, settings.isOn(feature) else { throw JevError.disabled(feature) }

        let request = ControlAPI.DecideRequest(
            state: state, questions: questions, model: settings.model, provider: "typesafe"
        )
        try request.validate()
        try Self.checkLimits(questions)

        let bytes = try Self.stateBytes(state)
        guard bytes <= settings.maxStateBytes else {
            throw JevError.tooLarge(bytes: bytes, limit: settings.maxStateBytes)
        }

        if let budget = settings.monthlyBudgetUSD {
            let spent = ledger().spentUSD()
            // Counting the calls already on the wire is what stops ten concurrent asks all
            // reading the same figure and all deciding there is room.
            guard spent + reservedUSD < budget else {
                throw JevError.budgetExhausted(spentUSD: spent + reservedUSD, budgetUSD: budget)
            }
        }
        guard hasKey() else { throw JevError.noKey }

        let key = cacheKey.map { "\(feature.rawValue)|\(settings.model)|\($0)" }
            ?? Self.cacheKey(feature: feature, model: settings.model, request: request)
        if settings.cacheMinutes > 0, let hit = cache[key],
           Date().timeIntervalSince(hit.storedAt) < Double(settings.cacheMinutes) * 60 {
            debug("\(feature.rawValue) cache hit, \(questions.count) question(s)")
            return hit.response
        }

        // Already on the wire: join it rather than send the same bytes twice. Two features
        // asking the same question about the same file at the same moment is the ordinary
        // case, not the exotic one, and the cache cannot help until the first lands.
        if let existing = inFlight[key] {
            debug("\(feature.rawValue) joined a call already in flight")
            return try await existing.value
        }

        guard let apiKey = keyProvider() else { throw JevError.noKey }

        // The ledger's location is captured here rather than read at the end: a `configure`
        // that lands mid-flight must not write this call's cost to a different file.
        let ledgerURL = self.ledgerURL
        let reservation = JevLedger.cost(inputTokens: Self.estimatedTokens(bytes: bytes))
        reservedUSD += reservation
        let work = Task<ControlAPI.DecideResponse, any Error> { [request, apiKey, feature] in
            try await self.send(request, apiKey: apiKey, feature: feature)
        }
        inFlight[key] = work

        let response: ControlAPI.DecideResponse
        do {
            response = try await work.value
        } catch {
            inFlight.removeValue(forKey: key)
            reservedUSD = max(0, reservedUSD - reservation)
            throw error
        }
        inFlight.removeValue(forKey: key)
        reservedUSD = max(0, reservedUSD - reservation)

        if settings.cacheMinutes > 0 {
            cache[key] = CacheEntry(response: response, storedAt: Date())
            pruneCache(window: Double(settings.cacheMinutes) * 60)
        }
        // Only the originator records: a joined caller shares the answer and the cost, and
        // billing it twice would be a lie the budget then acts on.
        record(feature: feature, response: response, to: ledgerURL)
        return response
    }

    /// Bytes to tokens for the budget reservation only. One token per byte is the worst
    /// realistic ratio (JSON keys, punctuation, CJK), and over-reserving is the safe way to
    /// be wrong about a spending cap.
    static func estimatedTokens(bytes: Int) -> Int { bytes }

    /// The request, plus the backoff. 429 and 529 mean "later", so this waits — honouring
    /// `retry-after` when TypeSafe sends one — and tries again, at most twice. Every other
    /// status is the caller's problem and comes straight back.
    ///
    /// The delays are returned rather than accumulated in a property, so two asks in flight
    /// cannot interleave into one list.
    private func send(
        _ request: ControlAPI.DecideRequest, apiKey: String, feature: JevFeature
    ) async throws -> ControlAPI.DecideResponse {
        let (response, delays) = try await attempt(request, apiKey: apiKey, feature: feature)
        lastRetryDelays = delays
        return response
    }

    private func attempt(
        _ request: ControlAPI.DecideRequest, apiKey: String, feature: JevFeature
    ) async throws -> (ControlAPI.DecideResponse, [TimeInterval]) {
        let client = SystemOneClient(baseURL: baseURL, apiKey: apiKey, session: session)
        var delays: [TimeInterval] = []
        var attempt = 1
        while true {
            do {
                let response = try await client.decide(request)
                debug(
                    "\(feature.rawValue) ok · \(request.questions.keys.sorted().joined(separator: ","))"
                    + " · \(response.usage.inputTokens) input tokens"
                    + " · \(Int(response.latencyMS ?? 0)) ms · \(response.model)"
                )
                return (response, delays)
            } catch let error as SystemOneError {
                guard case .overloaded(let status, let retryAfter, _) = error,
                      attempt < Self.maximumAttempts
                else { throw error }
                // Capped: a server asking for an hour is asking for more than a UI feature
                // can give it, and the caller is better off with the error.
                let delay = min(
                    retryAfter ?? Self.backoffSeconds(attempt), Self.maximumBackoffSeconds
                )
                delays.append(delay)
                debug("\(feature.rawValue) HTTP \(status), retrying in \(delay)s (attempt \(attempt))")
                await sleeper(delay)
                attempt += 1
            }
        }
    }

    /// 1s, 2s, 4s — doubling, and only used when the server did not say when to come back.
    static func backoffSeconds(_ attempt: Int) -> TimeInterval {
        pow(2, Double(max(0, attempt - 1)))
    }

    private func record(
        feature: JevFeature, response: ControlAPI.DecideResponse, to url: URL
    ) {
        var ledger = ledger()
        ledger.record(
            feature: feature, inputTokens: response.usage.inputTokens,
            outputTokens: response.usage.outputTokens,
            latencyMS: response.latencyMS ?? 0, model: response.model
        )
        loadedLedger = ledger
        do {
            try ledger.save(to: url)
            ledgerWriteError = nil
        } catch {
            // Not swallowed: an unwritable ledger means the budget stops counting between
            // launches, and a spending cap that quietly stops counting is worse than none.
            ledgerWriteError = error.localizedDescription
            debug("ledger write failed: \(error.localizedDescription)")
        }
    }

    /// The model names this key can send. Used by the Settings "Test connection" button,
    /// which is the cheapest honest answer to "is my key right?" — it spends no tokens.
    public func testConnection() async throws -> [String] {
        guard let apiKey = keyProvider() else { throw JevError.noKey }
        return try await SystemOneClient(baseURL: baseURL, apiKey: apiKey, session: session)
            .models()
    }

    // MARK: Limits and keys

    /// The documented per-question limits, checked here so an oversized question fails by
    /// name instead of coming back as a 422 about a JSON path.
    static func checkLimits(_ questions: [String: ControlAPI.SystemOneQuestion]) throws {
        for (name, question) in questions {
            switch question.type {
            case "choice":
                let count = question.criteria?.objectValue?.count ?? 0
                guard count <= 255 else {
                    throw ControlAPI.SystemOneValidationError(
                        name: name, reason: "a choice may offer at most 255 options; this one has \(count)."
                    )
                }
            case "score":
                let count = question.criteria?.arrayValue?.count ?? 0
                guard (2...10).contains(count) else {
                    throw ControlAPI.SystemOneValidationError(
                        name: name, reason: "a score needs between 2 and 10 levels; this one has \(count)."
                    )
                }
            default:
                continue
            }
        }
    }

    static func stateBytes(_ state: JSONContent) throws -> Int {
        if case .string(let text) = state { return text.utf8.count }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(state).count
    }

    /// A stable digest of everything that would change the answer. Hashed rather than kept
    /// whole so the cache holds no state text under a key that something might log.
    static func cacheKey(
        feature: JevFeature, model: String, request: ControlAPI.DecideRequest
    ) -> String {
        let body = (try? SystemOneClient.body(for: request)) ?? Data()
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        return "\(feature.rawValue)|\(model)|\(digest)"
    }

    private func pruneCache(window: TimeInterval) {
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.storedAt) < window }
    }

    // MARK: Logging

    /// `SILICON_JEV_DEBUG=1` prints question ids, token counts and latency to stderr.
    /// Never the state, never an answer: this is for finding out why a feature is slow or
    /// expensive, not for reading what it was asked about.
    private static let debugEnabled =
        ProcessInfo.processInfo.environment["SILICON_JEV_DEBUG"] == "1"

    private func debug(_ line: @autoclosure () -> String) {
        guard Self.debugEnabled else { return }
        FileHandle.standardError.write(Data("[jev] \(line())\n".utf8))
    }
}
