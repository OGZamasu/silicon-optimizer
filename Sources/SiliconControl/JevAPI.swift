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
        /// Where `silicon/auto` sends a request when routing cannot answer, and which model
        /// a flagged answer is re-run on. Both are gateway model ids, both nil when the
        /// owner has left them to be worked out, and both readable by any client that may
        /// read this — they name a model, and a model name is not a secret.
        ///
        /// Changing them is another matter: `POST /jev` takes this Mac's own control token,
        /// so a paired phone can see that answers escalate to a cloud model and cannot be
        /// the thing that decided they should.
        public var routingFallbackModel: String?
        public var verificationEscalationModel: String?
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
            composerAutoRoute: Bool = false,
            routingFallbackModel: String? = nil,
            verificationEscalationModel: String? = nil
        ) {
            self.routingFallbackModel = routingFallbackModel
            self.verificationEscalationModel = verificationEscalationModel
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
        /// Question id → `fired`, `plausible` or `clear`: where each answer landed against
        /// the feature's thresholds.
        ///
        /// Its own three words rather than the `act`/`confirm`/`escalate` band used for a
        /// model's *confidence*, because eight of these nine questions are nouls, where the
        /// number is the answer rather than a certainty about it: 0.05 on a hazard is a firm
        /// no, and calling that "escalate" would invert it.
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
        /// Gateway model ids. `POST /jev` takes this Mac's own control token, which is what
        /// keeps a paired phone from pointing this Mac's escalations at a cloud provider:
        /// sending a whole conversation to someone else's hardware is the owner's decision,
        /// made at the Mac, next to the caption that says what is sent and to whom.
        public var routingFallbackModel: String?
        public var verificationEscalationModel: String?
        /// Put them back to "work it out". Needed for the same reason as
        /// `clearMonthlyBudget`: absent means "leave alone".
        public var clearRoutingFallback: Bool?
        public var clearVerificationEscalation: Bool?

        public init(
            enabled: Bool? = nil, model: String? = nil, features: [String: Bool]? = nil,
            monthlyBudgetUSD: Double? = nil, clearMonthlyBudget: Bool? = nil,
            cacheMinutes: Int? = nil, maxStateBytes: Int? = nil,
            automaticUncensoredLane: Bool? = nil,
            clearAutomaticUncensoredLane: Bool? = nil, composerAutoRoute: Bool? = nil,
            routingFallbackModel: String? = nil,
            verificationEscalationModel: String? = nil,
            clearRoutingFallback: Bool? = nil, clearVerificationEscalation: Bool? = nil
        ) {
            self.routingFallbackModel = routingFallbackModel
            self.verificationEscalationModel = verificationEscalationModel
            self.clearRoutingFallback = clearRoutingFallback
            self.clearVerificationEscalation = clearVerificationEscalation
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

// MARK: - Calibration

extension ControlAPI {

    /// What TypeSafe charges, in one place.
    ///
    /// In `SiliconControl` rather than beside the ledger in `SiliconRuntime` because the MCP
    /// bridge links only this target and still has to tell an agent what a calibration run
    /// will cost before it starts one. `JevLedger` reads the same constant, so the two
    /// cannot drift.
    public enum JevPricing {
        /// Input tokens only; output is free.
        public static let usdPerMillionInputTokens = 0.042

        public static func costUSD(inputTokens: Int) -> Double {
            Double(inputTokens) * usdPerMillionInputTokens / 1_000_000
        }
    }

    /// `POST /jev/calibrate` and `GET /jev/calibration` — how the local decision lane
    /// compares with Jev on a fixed set of cases, and the floors the cascade takes from it.
    ///
    /// The honest caveat travels with the numbers rather than living only in the README:
    /// Jev is the *reference*, not ground truth. An "agreement rate" is how often the model
    /// loaded here landed where Jev landed, and both can be wrong together.
    public struct JevCalibration: Codable, Sendable, Equatable {

        /// How many built-in cases ship in the reviewable set, and what one costs to ask.
        ///
        /// Duplicated from `CalibrationQuestions` — which lives in the app target the MCP
        /// bridge does not link — and pinned to it by a test, so the "about N cents" in the
        /// tool description cannot quietly stop being true.
        public static let builtInCaseCount = 40
        /// A pessimistic per-case input-token estimate: one token per byte of state and
        /// questions, which is where JSON and punctuation actually land.
        public static let estimatedInputTokensPerCase = 900

        /// What a run of `count` cases is expected to cost, rounded up to the cent it will
        /// be quoted in.
        public static func estimatedCents(cases: Int = builtInCaseCount) -> Int {
            let usd = JevPricing.costUSD(
                inputTokens: max(0, cases) * estimatedInputTokensPerCase
            )
            return max(1, Int((usd * 100).rounded(.up)))
        }

        /// Agreement on one kind of question.
        public struct Agreement: Codable, Sendable, Equatable {
            /// `noul`, `choice` or `score`.
            public var kind: String
            public var compared: Int
            public var agreed: Int
            /// Agreed over compared, or 0 when nothing of this kind was asked.
            public var rate: Double

            public init(kind: String, compared: Int, agreed: Int, rate: Double) {
                self.kind = kind
                self.compared = compared
                self.agreed = agreed
                self.rate = rate
            }
        }

        /// One tenth of the local confidence range, and how often local was right about it.
        /// A calibrated lane has `agreementRate` climbing with `meanConfidence`; a flat
        /// column is the shape that says the confidence number means nothing here.
        ///
        /// Choice and score only. A noul carries no confidence — the number *is* the answer
        /// — and folding `max(p, 1-p)` in here would be exactly the invariant `jev-1.13`'s
        /// jaggedness note says not to assume.
        public struct Bin: Codable, Sendable, Equatable {
            public var lower: Double
            public var upper: Double
            public var count: Int
            public var agreed: Int
            public var meanConfidence: Double
            public var agreementRate: Double

            public init(
                lower: Double, upper: Double, count: Int, agreed: Int,
                meanConfidence: Double, agreementRate: Double
            ) {
                self.lower = lower
                self.upper = upper
                self.count = count
                self.agreed = agreed
                self.meanConfidence = meanConfidence
                self.agreementRate = agreementRate
            }
        }

        /// The four numbers the cascade thresholds on.
        ///
        /// A choice and a score get **separate** confidence floors, searched separately and
        /// applied separately. They are different primitives answering different shapes of
        /// question, and `jev-1.13`'s jaggedness note is explicit that a threshold tuned on
        /// one does not carry to another — a score's distribution is over ordered levels
        /// where neighbours are nearly the same judgment, so it spreads where a choice's
        /// would not, and the same 0.7 means different things in the two.
        public struct Floors: Codable, Sendable, Equatable {
            /// Choices below this confidence are escalated to Jev.
            public var choiceConfidence: Double
            /// Scores below this confidence are escalated to Jev.
            public var scoreConfidence: Double
            /// A noul strictly between these two is escalated. At either edge it is a
            /// confident answer — the same rule `JevThresholds.noulBand` already uses.
            public var noulLow: Double
            public var noulHigh: Double

            public init(
                choiceConfidence: Double, scoreConfidence: Double,
                noulLow: Double, noulHigh: Double
            ) {
                self.choiceConfidence = choiceConfidence
                self.scoreConfidence = scoreConfidence
                self.noulLow = noulLow
                self.noulHigh = noulHigh
            }

            /// Both confidence floors at one value — what a setting means before anything
            /// has been measured, and what a test usually wants.
            public init(confidence: Double, noulLow: Double, noulHigh: Double) {
                self.init(
                    choiceConfidence: confidence, scoreConfidence: confidence,
                    noulLow: noulLow, noulHigh: noulHigh
                )
            }

            /// A calibration file is a file, and a file can be hand-edited into nonsense.
            /// Clamped and swapped exactly as `JevSettings.normalized()` does its own three,
            /// so a number that reaches the cascade means the same thing wherever it was
            /// read from — and a value that is not a number at all goes back to `fallback`
            /// rather than to an edge that would read as a deliberate choice.
            public func normalized(default fallback: Floors) -> Floors {
                func clamp(_ value: Double, _ other: Double) -> Double {
                    guard value.isFinite else { return other }
                    return max(0, min(1, value))
                }
                var copy = Floors(
                    choiceConfidence: clamp(choiceConfidence, fallback.choiceConfidence),
                    scoreConfidence: clamp(scoreConfidence, fallback.scoreConfidence),
                    noulLow: clamp(noulLow, fallback.noulLow),
                    noulHigh: clamp(noulHigh, fallback.noulHigh)
                )
                if copy.noulLow > copy.noulHigh {
                    swap(&copy.noulLow, &copy.noulHigh)
                }
                return copy
            }

            /// A band this wide escalates almost every noul, which is not a calibration but
            /// a decision to pay Jev for everything. A search that lands past it is reported
            /// and refused rather than adopted.
            public static let widestNoulBand = 0.8
            /// Likewise at the other end: a floor this high means the local lane is trusted
            /// almost nowhere.
            public static let highestConfidenceFloor = 0.95

            public var noulBandWidth: Double { noulHigh - noulLow }
        }

        /// Which lane these floors belong to: `local`, `laya` or `node`.
        ///
        /// Absent in a file written before there was more than one lane, and read as
        /// `local` — which is what those files measured, because it was the only lane a
        /// calibration could have been run on.
        ///
        /// The floors are per lane **and** per kind for the same reason they were already
        /// per kind: a confidence number means whatever the thing that produced it means by
        /// it. Laya's 0.7 on a choice is a decision model's calibrated-ish 0.7; the loaded
        /// chat model's 0.7 is a renormalised softmax over two letters. Sharing a floor
        /// between them would be the jaggedness mistake one level up.
        public var lane: String?

        /// The installed model id the local lane used. The cascade takes these floors only
        /// while this is what is loaded: a threshold measured on a 30B MoE is not a promise
        /// about a 4B dense one.
        public var modelID: String
        public var modelName: String
        /// Bytes on disk and when it was installed, beside the id.
        ///
        /// An id can be reused — a model removed and reinstalled at a different
        /// quantization, or a local build overwritten — and the floors would then be applied
        /// to weights they were never measured against. These two are cheap, already known,
        /// and together they catch that.
        public var modelSizeBytes: Int64?
        public var modelInstalledAt: String?
        /// The Jev version that played reference.
        public var jevModel: String
        /// ISO-8601, like every other timestamp on this wire.
        public var date: String
        public var cases: Int
        public var builtInCases: Int
        public var userCases: Int
        /// Answers compared, which is cases times the questions in each.
        public var comparisons: Int
        public var agreement: [Agreement]
        public var overallAgreementRate: Double
        public var floors: Floors
        /// The fraction of the set that would have been sent to Jev under `floors`.
        ///
        /// The number the owner actually pays for. A floor that reaches 95% agreement by
        /// escalating four answers in five has not saved anything, and no agreement rate on
        /// its own would say so.
        public var escalationRate: Double
        /// False when a search could not reach 90% with enough answers behind it, or landed
        /// somewhere too extreme to adopt, and the floor fell back to the setting's default.
        /// Reported rather than hidden: a fallback floor is a guess, and the screen says
        /// which of the two you are looking at.
        public var choiceFloorMeasured: Bool
        public var scoreFloorMeasured: Bool
        public var noulBandMeasured: Bool
        public var bins: [Bin]
        /// What the run actually spent at Jev.
        public var inputTokens: Int
        public var estimatedUSD: Double
        /// Anything the run wants a person to read before trusting the numbers — too few
        /// samples, a search that found nothing, cases that would not run.
        public var notes: [String]

        // MARK: Context, filled in when this is read rather than when it was written

        /// Whether `floors` are the ones the cascade is using right now. Nil in the stored
        /// file, which has no idea what is loaded; set by `GET /jev/calibration`.
        public var appliesToLoadedModel: Bool?
        /// The floors actually in effect — `floors` when they apply, the settings' defaults
        /// when they do not. So a client never has to guess whether what it is showing is
        /// what is happening.
        public var floorsInEffect: Floors?
        /// The model loaded right now, when it is not the one these were measured against.
        public var loadedModelName: String?

        public init(
            lane: String? = nil,
            modelID: String, modelName: String, jevModel: String, date: String,
            cases: Int, builtInCases: Int, userCases: Int, comparisons: Int,
            agreement: [Agreement], overallAgreementRate: Double, floors: Floors,
            escalationRate: Double,
            choiceFloorMeasured: Bool, scoreFloorMeasured: Bool, noulBandMeasured: Bool,
            bins: [Bin], inputTokens: Int, estimatedUSD: Double, notes: [String] = [],
            modelSizeBytes: Int64? = nil, modelInstalledAt: String? = nil,
            appliesToLoadedModel: Bool? = nil, floorsInEffect: Floors? = nil,
            loadedModelName: String? = nil
        ) {
            self.lane = lane
            self.modelID = modelID
            self.modelName = modelName
            self.modelSizeBytes = modelSizeBytes
            self.modelInstalledAt = modelInstalledAt
            self.jevModel = jevModel
            self.date = date
            self.cases = cases
            self.builtInCases = builtInCases
            self.userCases = userCases
            self.comparisons = comparisons
            self.agreement = agreement
            self.overallAgreementRate = overallAgreementRate
            self.floors = floors
            self.escalationRate = escalationRate
            self.choiceFloorMeasured = choiceFloorMeasured
            self.scoreFloorMeasured = scoreFloorMeasured
            self.noulBandMeasured = noulBandMeasured
            self.bins = bins
            self.inputTokens = inputTokens
            self.estimatedUSD = estimatedUSD
            self.notes = notes
            self.appliesToLoadedModel = appliesToLoadedModel
            self.floorsInEffect = floorsInEffect
            self.loadedModelName = loadedModelName
        }

        /// Whether a model is the one these numbers were measured against — the id, and the
        /// weights behind it.
        public func measured(
            modelID: String?, sizeBytes: Int64?, installedAt: String?
        ) -> Bool {
            guard let modelID, modelID == self.modelID else { return false }
            // Absent on either side means an older file or a host that cannot say, and a
            // missing check is not a failed one.
            if let mine = modelSizeBytes, let theirs = sizeBytes, mine != theirs { return false }
            if let mine = modelInstalledAt, let theirs = installedAt, mine != theirs { return false }
            return true
        }

        /// One line for a settings row, an MCP answer or a log.
        public var summary: String {
            let percent = Int((overallAgreementRate * 100).rounded())
            let escalated = Int((escalationRate * 100).rounded())
            return String(
                format: "%@ · %@ · %@ · %d cases · %d%% agreement · escalates %d%% · "
                + "choice %.2f · score %.2f · noul %.2f–%.2f",
                lane ?? "local", modelName, date.prefix(10).description, cases, percent,
                escalated,
                floors.choiceConfidence, floors.scoreConfidence,
                floors.noulLow, floors.noulHigh
            )
        }
    }
}

/// An error that already knows what HTTP status it should become.
///
/// The buffered routes used to turn every thrown error into a 400, which is right for "you
/// asked wrong" and wrong for "ask again later" — a client cannot tell a malformed body from
/// a run that is already in progress. `BuddyHostError` had the same problem and solved it for
/// the streaming path; this is that answer, named for what it does and reachable from both.
public protocol ControlStatusError: Error {
    var status: Int { get }
}

extension BuddyHostError: ControlStatusError {}
