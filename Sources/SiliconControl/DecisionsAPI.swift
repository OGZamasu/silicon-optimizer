import Foundation

extension ControlAPI {

    // MARK: - Lanes

    /// One decision lane, as a client meets it.
    ///
    /// Four of these exist and they are deliberately described by the same fields, because
    /// the whole point of the lane abstraction is that a question does not change when a
    /// different one answers it. The per-lane detail hangs off `jev`, `laya` and `node`,
    /// each present only on its own lane.
    ///
    /// The ids are strings rather than an enum for the usual reason this target has them:
    /// `SiliconControl` links nothing, so it cannot see `DecisionLaneID` in `SiliconRuntime`
    /// — the MCP bridge would have to link the whole domain layer to read a route. The
    /// vocabulary is written down in `DecisionLaneVocabulary` below and pinned to the enum
    /// by a test, so the two cannot drift.
    public struct DecisionLaneView: Codable, Sendable, Equatable {
        /// `typesafe`, `laya`, `node` or `local`.
        public var id: String
        public var displayName: String
        /// Whether this lane could answer something right now.
        public var available: Bool
        /// Whether it is set up at all — a lane can be installed and still unavailable
        /// because the owner switched it off, or because its budget is spent.
        public var installed: Bool
        /// One sentence for the row: what is missing, or what is loaded.
        public var detail: String
        /// Whether asking it sends the state off this Mac.
        public var leavesTheMac: Bool
        /// Whether asking it spends money.
        public var costsMoney: Bool
        /// Measured on this Mac, per question, over the answers this lane has actually
        /// given. Nil until it has given one — a published benchmark is not a measurement
        /// of this machine and is labelled separately.
        public var measuredPerQuestionMS: Double?
        public var jev: JevLaneDetail?
        public var laya: LayaLaneDetail?
        public var node: NodeLaneDetail?

        public init(
            id: String, displayName: String, available: Bool, installed: Bool,
            detail: String, leavesTheMac: Bool, costsMoney: Bool,
            measuredPerQuestionMS: Double? = nil,
            jev: JevLaneDetail? = nil, laya: LayaLaneDetail? = nil,
            node: NodeLaneDetail? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.available = available
            self.installed = installed
            self.detail = detail
            self.leavesTheMac = leavesTheMac
            self.costsMoney = costsMoney
            self.measuredPerQuestionMS = measuredPerQuestionMS
            self.jev = jev
            self.laya = laya
            self.node = node
        }
    }

    /// The cloud lane. Never the key — only whether one exists, exactly as `GET /jev` has
    /// always answered.
    public struct JevLaneDetail: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var keySet: Bool
        public var model: String
        public var monthlyBudgetUSD: Double?
        public var budgetRemainingUSD: Double?
        public var spentThisMonthUSD: Double
        public var usdPerMillionInputTokens: Double

        public init(
            enabled: Bool, keySet: Bool, model: String, monthlyBudgetUSD: Double?,
            budgetRemainingUSD: Double?, spentThisMonthUSD: Double,
            usdPerMillionInputTokens: Double = JevPricing.usdPerMillionInputTokens
        ) {
            self.enabled = enabled
            self.keySet = keySet
            self.model = model
            self.monthlyBudgetUSD = monthlyBudgetUSD
            self.budgetRemainingUSD = budgetRemainingUSD
            self.spentThisMonthUSD = spentThisMonthUSD
            self.usdPerMillionInputTokens = usdPerMillionInputTokens
        }
    }

    /// One Laya checkpoint the owner may choose between.
    public struct LayaCheckpointView: Codable, Sendable, Equatable {
        public var id: String
        public var displayName: String
        public var repository: String
        /// The exact commit this app fetches. A branch would move; thresholds measured
        /// against one revision are not a promise about the next.
        public var revision: String
        public var downloadBytes: Int64
        public var baseModel: String
        public var parameterMillions: Int
        public var contextTokens: Int
        public var installed: Bool
        /// The published P50 for one short question on the machine the benchmark was run
        /// on — not this one. Labelled as published wherever it is shown.
        public var publishedShortQuestionMS: Double
        public var publishedPeakMemoryBytes: Int64
        public var summary: String

        public init(
            id: String, displayName: String, repository: String, revision: String,
            downloadBytes: Int64, baseModel: String, parameterMillions: Int,
            contextTokens: Int, installed: Bool, publishedShortQuestionMS: Double,
            publishedPeakMemoryBytes: Int64, summary: String
        ) {
            self.id = id
            self.displayName = displayName
            self.repository = repository
            self.revision = revision
            self.downloadBytes = downloadBytes
            self.baseModel = baseModel
            self.parameterMillions = parameterMillions
            self.contextTokens = contextTokens
            self.installed = installed
            self.publishedShortQuestionMS = publishedShortQuestionMS
            self.publishedPeakMemoryBytes = publishedPeakMemoryBytes
            self.summary = summary
        }
    }

    /// The local Laya lane.
    ///
    /// `licence`, `weightsAttribution` and `portAttribution` are three fields rather than
    /// one because the weights and the MLX port have the same licence and **different
    /// rightsholders**, and Apache-2.0 §4(d) asks for the notice that ships with each. A
    /// single "Apache-2.0" label would hide whose notice it is.
    public struct LayaLaneDetail: Codable, Sendable, Equatable {
        public var enabled: Bool
        /// Which checkpoint the lane loads.
        public var checkpoint: String
        public var checkpoints: [LayaCheckpointView]
        /// The pinned Python package, e.g. `laya-mlx==0.1.0`.
        public var package: String
        public var packageSHA256: String
        public var licence: String
        public var weightsAttribution: String
        public var portAttribution: String
        public var sourceURL: String
        public var upstreamURL: String
        /// Bytes the environment and the fetched checkpoints occupy, inside the model
        /// library — never the startup disk.
        public var bytesOnDisk: Int64
        /// Where those bytes are. Absent when no library is configured.
        public var installedAt: String?
        /// Whether a checkpoint is resident right now.
        public var loaded: Bool
        /// What MLX reported at the last peak.
        public var peakMemoryBytes: Int64?
        /// Whether an install is running.
        public var installing: Bool

        public init(
            enabled: Bool, checkpoint: String, checkpoints: [LayaCheckpointView],
            package: String, packageSHA256: String, licence: String,
            weightsAttribution: String, portAttribution: String, sourceURL: String,
            upstreamURL: String, bytesOnDisk: Int64, installedAt: String? = nil,
            loaded: Bool = false, peakMemoryBytes: Int64? = nil, installing: Bool = false
        ) {
            self.enabled = enabled
            self.checkpoint = checkpoint
            self.checkpoints = checkpoints
            self.package = package
            self.packageSHA256 = packageSHA256
            self.licence = licence
            self.weightsAttribution = weightsAttribution
            self.portAttribution = portAttribution
            self.sourceURL = sourceURL
            self.upstreamURL = upstreamURL
            self.bytesOnDisk = bytesOnDisk
            self.installedAt = installedAt
            self.loaded = loaded
            self.peakMemoryBytes = peakMemoryBytes
            self.installing = installing
        }
    }

    /// The swarm-node lane: the same Laya checkpoints on somebody else's GPU.
    public struct NodeLaneDetail: Codable, Sendable, Equatable {
        public var enabled: Bool
        /// The peer that would answer, when one would.
        public var peer: String?
        public var reachable: Bool
        /// Checkpoint ids the node says it has loaded, off its `/v1/node` advertisement.
        public var checkpoints: [String]
        /// What the node says one question costs it.
        public var advertisedPerQuestionMS: Double?
        /// Every peer that advertises a decision lane, ready or not, so the panel can show
        /// a node that is there but asleep rather than showing nothing.
        public var candidates: [Candidate]

        public struct Candidate: Codable, Sendable, Equatable {
            public var name: String
            public var reachable: Bool
            public var ready: Bool
            public var checkpoints: [String]
            public var perQuestionMS: Double?
            public var detail: String?

            public init(
                name: String, reachable: Bool, ready: Bool, checkpoints: [String],
                perQuestionMS: Double? = nil, detail: String? = nil
            ) {
                self.name = name
                self.reachable = reachable
                self.ready = ready
                self.checkpoints = checkpoints
                self.perQuestionMS = perQuestionMS
                self.detail = detail
            }
        }

        public init(
            enabled: Bool, peer: String? = nil, reachable: Bool = false,
            checkpoints: [String] = [], advertisedPerQuestionMS: Double? = nil,
            candidates: [Candidate] = []
        ) {
            self.enabled = enabled
            self.peer = peer
            self.reachable = reachable
            self.checkpoints = checkpoints
            self.advertisedPerQuestionMS = advertisedPerQuestionMS
            self.candidates = candidates
        }
    }

    // MARK: - Abilities

    /// One decision ability — one of the eight features — with who answers it and what it
    /// has cost.
    ///
    /// This is `JevStatus.Feature` grown up: the same id, name, summary and switch, plus
    /// the three things that only exist now that there is more than one lane — which lane
    /// would answer, which one last did, and what the owner has pinned it to.
    public struct DecisionAbility: Codable, Sendable, Equatable {
        public var id: String
        public var displayName: String
        public var summary: String
        /// The owner's per-feature switch, shared with `GET /jev`.
        public var enabled: Bool
        /// False for a feature on the roadmap that nothing calls yet.
        public var built: Bool
        /// `automatic`, `alwaysLocal`, `alwaysJev` or `off`.
        public var laneOverride: String
        /// Which lane would answer right now, or nil for nothing.
        public var lane: String?
        /// Why nothing would, when nothing would.
        public var unavailableReason: String?
        /// This month, from the Jev ledger — so it counts paid calls only, which is what
        /// "what has it cost" means.
        public var calls: Int
        public var inputTokens: Int
        public var estimatedUSD: Double
        public var averageLatencyMS: Double?
        /// The last answer, whichever lane gave it.
        public var lastLane: String?
        public var lastAt: String?
        public var lastLatencyMS: Double?
        public var lastError: String?
        /// The feature's own act/confirm thresholds, when it has a fixed pair. Some
        /// features compute theirs per question and report none.
        public var thresholds: Thresholds?

        public struct Thresholds: Codable, Sendable, Equatable {
            public var act: Double
            public var confirm: Double

            public init(act: Double, confirm: Double) {
                self.act = act
                self.confirm = confirm
            }
        }

        public init(
            id: String, displayName: String, summary: String, enabled: Bool, built: Bool,
            laneOverride: String, lane: String?, unavailableReason: String? = nil,
            calls: Int, inputTokens: Int, estimatedUSD: Double,
            averageLatencyMS: Double? = nil, lastLane: String? = nil,
            lastAt: String? = nil, lastLatencyMS: Double? = nil, lastError: String? = nil,
            thresholds: Thresholds? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.summary = summary
            self.enabled = enabled
            self.built = built
            self.laneOverride = laneOverride
            self.lane = lane
            self.unavailableReason = unavailableReason
            self.calls = calls
            self.inputTokens = inputTokens
            self.estimatedUSD = estimatedUSD
            self.averageLatencyMS = averageLatencyMS
            self.lastLane = lastLane
            self.lastAt = lastAt
            self.lastLatencyMS = lastLatencyMS
            self.lastError = lastError
            self.thresholds = thresholds
        }
    }

    // MARK: - The panel

    /// `GET /decisions` — everything the Decisions panel draws, in one request.
    ///
    /// One route rather than five because it is one screen, and because five would mean a
    /// phone drawing a panel out of answers taken at five different moments — lanes from
    /// before an install finished, abilities from after.
    public struct DecisionsStatus: Codable, Sendable, Equatable {
        public var lanes: [DecisionLaneView]
        public var abilities: [DecisionAbility]
        /// The last calibration per lane, keyed by lane id. A lane with none is absent.
        public var calibrations: [String: JevCalibration]
        /// The same buffer `GET /jev/guardrails/recent` serves, included so the panel is
        /// one request.
        public var recent: GuardrailScreenings
        /// Which month the ability totals are for.
        public var month: String
        public var totalCalls: Int
        public var totalEstimatedUSD: Double

        public init(
            lanes: [DecisionLaneView], abilities: [DecisionAbility],
            calibrations: [String: JevCalibration] = [:],
            recent: GuardrailScreenings, month: String,
            totalCalls: Int, totalEstimatedUSD: Double
        ) {
            self.lanes = lanes
            self.abilities = abilities
            self.calibrations = calibrations
            self.recent = recent
            self.month = month
            self.totalCalls = totalCalls
            self.totalEstimatedUSD = totalEstimatedUSD
        }
    }

    /// `POST /decisions/lanes` — a patch, like `POST /jev`: every field optional, only what
    /// is sent changes, so a client that knows three settings cannot wipe a fourth it has
    /// never heard of.
    public struct DecisionLanesUpdate: Codable, Sendable, Equatable {
        /// Whether the local Laya lane may answer.
        public var layaEnabled: Bool?
        /// Which checkpoint it loads. Changing it unloads the old one.
        public var layaCheckpoint: String?
        /// Whether a swarm node may answer.
        public var nodeLaneEnabled: Bool?
        /// Feature id → `automatic`, `alwaysLocal`, `alwaysJev` or `off`. Ids and words
        /// this build does not know are refused rather than ignored: unlike a feature
        /// switch, a lane word that silently did nothing would leave the owner believing a
        /// feature was pinned local when it was not.
        public var overrides: [String: String]?
        /// Releases the loaded checkpoint now rather than at the idle timeout.
        public var unloadLaya: Bool?

        public init(
            layaEnabled: Bool? = nil, layaCheckpoint: String? = nil,
            nodeLaneEnabled: Bool? = nil, overrides: [String: String]? = nil,
            unloadLaya: Bool? = nil
        ) {
            self.layaEnabled = layaEnabled
            self.layaCheckpoint = layaCheckpoint
            self.nodeLaneEnabled = nodeLaneEnabled
            self.overrides = overrides
            self.unloadLaya = unloadLaya
        }
    }

    /// `POST /decisions/install` — fetch the pinned package and a checkpoint into the model
    /// library.
    public struct DecisionInstallRequest: Codable, Sendable, Equatable {
        /// Which checkpoint. Absent means the default, the English 421M.
        public var checkpoint: String?
        /// Fetch the weights only, for an environment that is already built.
        public var checkpointOnly: Bool?

        public init(checkpoint: String? = nil, checkpointOnly: Bool? = nil) {
            self.checkpoint = checkpoint
            self.checkpointOnly = checkpointOnly
        }
    }

    /// What an install answered. The work itself runs on, so this is an acknowledgement and
    /// a place to look, not a result.
    public struct DecisionInstallAccepted: Codable, Sendable, Equatable {
        public var started: Bool
        public var checkpoint: String
        public var estimatedBytes: Int64
        /// Where it will land — the model library, never the startup disk.
        public var destination: String?
        public var detail: String

        public init(
            started: Bool, checkpoint: String, estimatedBytes: Int64,
            destination: String? = nil, detail: String
        ) {
            self.started = started
            self.checkpoint = checkpoint
            self.estimatedBytes = estimatedBytes
            self.destination = destination
            self.detail = detail
        }
    }

    /// `POST /jev/calibrate` and `POST /decisions/calibrate` — which lane to measure
    /// against Jev.
    ///
    /// The body is optional and so is the field. An empty body is the route exactly as it
    /// was before there was more than one lane, which is what keeps every existing caller
    /// — the MCP tool, the Settings button, a script somebody wrote — working untouched.
    public struct DecisionCalibrateRequest: Codable, Sendable, Equatable {
        /// `local`, `laya` or `node`. Absent means `local`. Never `typesafe`: Jev is
        /// the reference a calibration is measured *against*.
        public var lane: String?

        public init(lane: String? = nil) { self.lane = lane }
    }

    /// `POST /decisions/test` — the test bench. Sends one question set to one named lane
    /// and hands back the probabilities, without any feature's thresholds applied.
    ///
    /// Deliberately *not* `/decide`: that route routes, and the point of the bench is to
    /// ask a lane the owner has named even when the policy would have chosen another —
    /// which is how you find out that two lanes disagree.
    public struct DecisionTestRequest: Codable, Sendable, Equatable {
        /// `typesafe`, `laya`, `node` or `local`.
        public var lane: String
        public var state: JSONContent
        public var questions: [String: SystemOneQuestion]

        public init(lane: String, state: JSONContent, questions: [String: SystemOneQuestion]) {
            self.lane = lane
            self.state = state
            self.questions = questions
        }
    }

    /// One bench run.
    public struct DecisionTestResult: Codable, Sendable, Equatable {
        public var lane: String
        /// The checkpoint or model that actually answered.
        public var model: String
        public var answers: [String: SystemOneAnswer]
        public var latencyMS: Double?
        public var perQuestionMS: Double?
        public var usage: SystemOneUsage
        /// What it cost, which is zero on every lane but Jev.
        public var estimatedUSD: Double

        public init(
            lane: String, model: String, answers: [String: SystemOneAnswer],
            latencyMS: Double?, perQuestionMS: Double?, usage: SystemOneUsage,
            estimatedUSD: Double
        ) {
            self.lane = lane
            self.model = model
            self.answers = answers
            self.latencyMS = latencyMS
            self.perQuestionMS = perQuestionMS
            self.usage = usage
            self.estimatedUSD = estimatedUSD
        }
    }

    /// The words the lane routes use, written once.
    ///
    /// `SiliconControl` cannot see `DecisionLaneID` or `DecisionLaneOverride` — it links
    /// nothing, so that the MCP bridge stays small — and a wire vocabulary spelled out in
    /// two targets is a vocabulary that will eventually disagree with itself. A test pins
    /// each list to the enum it mirrors.
    public enum DecisionLaneVocabulary {
        /// The spellings `DecideResponse.provider` already uses, plus the two new lanes.
        /// TypeSafe's lane is `typesafe` here as it is there — a second word for the same
        /// thing would be a second thing to get wrong.
        public static let lanes = ["typesafe", "laya", "node", "local"]
        public static let overrides = ["automatic", "alwaysLocal", "alwaysJev", "off"]
        public static let checkpoints = ["english", "multilingual", "typedDecisions"]

        /// What an unknown lane word is answered with. Its own sentence so the fixture and
        /// the server cannot drift.
        public static func unknownLane(_ asked: String) -> String {
            "Unknown lane \"\(asked)\". Use one of: \(lanes.joined(separator: ", "))."
        }

        public static func unknownOverride(_ asked: String) -> String {
            "Unknown lane choice \"\(asked)\". Use one of: \(overrides.joined(separator: ", "))."
        }

        public static func unknownCheckpoint(_ asked: String) -> String {
            "Unknown Laya checkpoint \"\(asked)\". Use one of: "
            + "\(checkpoints.joined(separator: ", "))."
        }
    }
}
