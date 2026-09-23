import Foundation
import SiliconCatalog
import SiliconControl
import SiliconRuntime

// MARK: - Starting the lanes

/// Registers this Mac's decision lanes with the router, once.
///
/// Registration is what makes a lane exist. Before this runs — and in every test that never
/// starts the app — the router knows only Jev, which is exactly how the app behaved before
/// any of this, and is why the eight features' own suites did not have to change.
@MainActor
enum DecisionLanesBootstrap {
    private static var task: Task<Void, Never>?

    static func begin(_ model: AppModel) {
        guard task == nil else { return }
        task = Task { @MainActor in
            await configure(model, runtime: .shared, router: .shared)
            await LayaLaneDefaults.refresh()
        }
    }

    static func configure(_ model: AppModel, runtime: LayaRuntime, router: DecisionRouter) async {
        await runtime.configure(
            // Read on every call rather than captured: the owner can move the model
            // library while the app is running, and a captured path would go on
            // pointing at the old drive.
            library: { [weak model] in
                await MainActor.run { model?.settings.resolvedModelLibraryDirectory }
            },
            script: { await MainActor.run { AppModel.layaSidecarScript } }
        )
        await router.register(LayaLane(
            runtime: runtime,
            checkpoint: { await MainActor.run { LayaLaneDefaults.checkpoint } },
            enabled: { await MainActor.run { LayaLaneDefaults.enabled } }
        ))
        await router.register(NodeDecisionLane(peer: { [weak model] in
            await MainActor.run { model?.decisionNodePeer }
        }))
        await router.register(OneTokenLane(decider: { [weak model] in
            await MainActor.run { model?.oneTokenDecider }
        }))
    }

    static func ready() async { await task?.value }
}

/// The two settings the Laya lane reads on every question, mirrored onto the main actor.
///
/// These values are copied from `JevService` whenever they change. Lane callbacks await
/// the main actor to read the current copy, including when a gateway request asks about
/// readiness from a background executor.
@MainActor
enum LayaLaneDefaults {
    static var enabled = true
    static var nodeEnabled = false
    static var checkpoint = LayaCheckpoint.default

    static func refresh() async {
        let settings = await JevService.shared.settings()
        enabled = settings.layaEnabled
        nodeEnabled = settings.nodeLaneEnabled
        checkpoint = settings.layaCheckpoint
    }
}

extension AppModel {

    /// The sidecar script, out of the app bundle.
    static var layaSidecarScript: URL? {
        let candidates = [
            Bundle.main.url(forResource: "laya_sidecar", withExtension: "py", subdirectory: "laya"),
            Bundle.main.resourceURL?.appendingPathComponent("laya/laya_sidecar.py"),
            // Running from a checkout — `swift run`, and the tests.
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/laya/laya_sidecar.py"),
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    func configureDecisionLanes() { DecisionLanesBootstrap.begin(self) }

    /// The one-token lane's decider, when a model is loaded here.
    var oneTokenDecider: LocalDecider? {
        guard case .ready(let endpoint) = runtimeState, let loaded = loadedModel
        else { return nil }
        return LocalDecider(endpoint: endpoint, modelName: loaded.name)
    }

    // MARK: - The node lane

    /// The peer that would answer a decision, or nil when none would.
    ///
    /// Read off the swarm poll this app already runs. A node advertises a decision lane as
    /// an ordinary capability in `/v1/node` — `kind: "decision"`, one entry per checkpoint
    /// it has resident — so nothing on either side needed a new field: `PeerCapability`
    /// already carries the id, the kind, whether it is ready, and how long it typically
    /// takes, and this Mac has been parsing all four since the swarm existed.
    ///
    /// The fastest ready one wins, and a peer that is unreachable is not a candidate at
    /// all: a decision must never wait on a machine that is asleep.
    var decisionNodePeer: NodeDecisionLane.Peer? {
        guard LayaLaneDefaults.nodeEnabled else { return nil }
        let candidates = decisionNodeCandidates.filter(\.ready)
        guard let best = candidates.min(by: {
            ($0.perQuestionMS ?? .greatestFiniteMagnitude)
                < ($1.perQuestionMS ?? .greatestFiniteMagnitude)
        }) else { return nil }
        guard let peer = swarmPeers.first(where: { $0.name == best.name }),
              let url = URL(string: peer.baseURL)
        else { return nil }
        return .init(
            name: peer.name, baseURL: url,
            token: swarmConfig?.bearer(forPeer: peer.name),
            checkpoints: best.checkpoints, perQuestionMS: best.perQuestionMS
        )
    }

    /// Every peer advertising a decision lane, ready or not — so the panel can show a node
    /// that exists but is asleep rather than showing nothing at all.
    var decisionNodeCandidates: [ControlAPI.NodeLaneDetail.Candidate] {
        swarmPeers.compactMap { peer in
            let decisions = peer.capabilities.filter {
                $0.kind == NodeDecisionLane.capabilityKind
            }
            guard !decisions.isEmpty else { return nil }
            let ready = decisions.filter(\.ready)
            return .init(
                name: peer.name,
                reachable: peer.reachable,
                ready: peer.reachable && !ready.isEmpty,
                checkpoints: ready.map(\.id).sorted(),
                perQuestionMS: ready.compactMap(\.typicalSeconds).min().map { $0 * 1000 },
                detail: decisions.compactMap(\.detail).first
            )
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}

// MARK: - The control routes

extension AppModel {

    /// `GET /decisions` — everything the Decisions panel draws, in one request.
    public func decisionsStatus() async -> ControlAPI.DecisionsStatus {
        await JevBootstrap.ready()
        await DecisionLanesBootstrap.ready()
        let settings = await JevService.shared.settings()
        let ledger = await JevService.shared.ledger()
        let month = JevLedger.monthKey()
        let totals = ledger.month(month)
        let library = self.settings.resolvedModelLibraryDirectory
        let installation = LayaRuntime.installation(
            checkpoint: settings.layaCheckpoint, library: library,
            script: Self.layaSidecarScript
        )

        var abilities: [ControlAPI.DecisionAbility] = []
        for feature in JevFeature.allCases {
            let entry = totals.features[feature.rawValue] ?? JevLedger.Entry()
            let lane = await DecisionRouter.shared.lane(for: feature)
            let last = await DecisionRouter.shared.lastAnswer(for: feature)
            abilities.append(.init(
                id: feature.rawValue,
                displayName: feature.displayName,
                summary: feature.summary,
                enabled: settings.isOn(feature),
                built: feature.isBuilt,
                laneOverride: settings.laneOverride(feature).rawValue,
                lane: lane?.wireName,
                unavailableReason: lane == nil
                    ? Self.whyNothingAnswers(feature, settings: settings) : nil,
                calls: entry.calls,
                inputTokens: entry.inputTokens,
                estimatedUSD: entry.estimatedUSD,
                averageLatencyMS: entry.averageLatencyMS,
                lastLane: last.map { $0.peer.map { p in "node:\(p)" } ?? $0.lane.wireName },
                lastAt: last.map { ControlAPI.timestamp($0.at) },
                lastLatencyMS: last?.latencyMS,
                lastError: last?.failed,
                thresholds: Self.thresholds(for: feature)
            ))
        }

        return ControlAPI.DecisionsStatus(
            lanes: await decisionLaneViews(settings: settings, installation: installation, totals: totals),
            abilities: abilities,
            calibrations: await allCalibrations(),
            recent: await JevGuardrails.recent(),
            month: month,
            totalCalls: totals.total.calls,
            totalEstimatedUSD: totals.total.estimatedUSD
        )
    }

    private func decisionLaneViews(
        settings: JevSettings, installation: LayaInstallation, totals: JevLedger.Month
    ) async -> [ControlAPI.DecisionLaneView] {
        let library = self.settings.resolvedModelLibraryDirectory
        let hubCache = library.map { LayaRuntime.hubCacheDirectory(library: $0) }
        let checkpoints = LayaCheckpoint.allCases.map { checkpoint in
            ControlAPI.LayaCheckpointView(
                id: checkpoint.rawValue,
                displayName: checkpoint.displayName,
                repository: checkpoint.repository,
                revision: checkpoint.revision,
                downloadBytes: checkpoint.downloadBytes,
                baseModel: checkpoint.baseModel,
                parameterMillions: checkpoint.parameterMillions,
                contextTokens: checkpoint.contextTokens,
                installed: hubCache.map {
                    LayaRuntime.isInstalled(checkpoint, hubCache: $0)
                } ?? false,
                publishedShortQuestionMS: checkpoint.publishedShortQuestionMS,
                publishedPeakMemoryBytes: checkpoint.publishedPeakMemoryBytes,
                summary: checkpoint.summary
            )
        }
        let nodeCandidates = decisionNodeCandidates
        let node = decisionNodePeer

        return [
            .init(
                id: DecisionLaneID.jev.wireName,
                displayName: DecisionLaneID.jev.displayName,
                available: await JevService.shared.isAvailable(.decideTool),
                installed: TypeSafeCredential.isSet,
                detail: settings.enabled
                    ? (TypeSafeCredential.isSet
                        ? "Answering on \(settings.model)."
                        : "Turned on, but no API key is stored.")
                    : "Off. Nothing is sent to TypeSafe and nothing is billed.",
                leavesTheMac: true, costsMoney: true,
                jev: .init(
                    enabled: settings.enabled, keySet: TypeSafeCredential.isSet,
                    model: settings.model, monthlyBudgetUSD: settings.monthlyBudgetUSD,
                    budgetRemainingUSD: settings.monthlyBudgetUSD.map {
                        $0 - totals.total.estimatedUSD
                    },
                    spentThisMonthUSD: totals.total.estimatedUSD
                )
            ),
            .init(
                id: DecisionLaneID.laya.wireName,
                displayName: DecisionLaneID.laya.displayName,
                available: settings.layaEnabled && installation.isInstalled,
                installed: installation.isInstalled,
                detail: settings.layaEnabled
                    ? installation.detail
                    : "Switched off in Settings → Decisions.",
                leavesTheMac: false, costsMoney: false,
                measuredPerQuestionMS: await LayaRuntime.shared.lastPerQuestionMS,
                laya: .init(
                    enabled: settings.layaEnabled,
                    checkpoint: settings.layaCheckpoint.rawValue,
                    checkpoints: checkpoints,
                    package: LayaPackage.requirement,
                    packageSHA256: LayaPackage.wheelSHA256,
                    licence: LayaCheckpoint.licence,
                    weightsAttribution: LayaCheckpoint.weightsAttribution,
                    portAttribution: LayaCheckpoint.portAttribution,
                    sourceURL: LayaPackage.repository,
                    upstreamURL: LayaPackage.upstreamRepository,
                    bytesOnDisk: installation.bytesOnDisk,
                    installedAt: installation.environment?.deletingLastPathComponent().path,
                    loaded: await LayaRuntime.shared.isLoaded,
                    peakMemoryBytes: await LayaRuntime.shared.lastPeakMemoryBytes,
                    installing: await LayaRuntime.shared.isInstalling
                )
            ),
            .init(
                id: DecisionLaneID.node.wireName,
                displayName: DecisionLaneID.node.displayName,
                available: node != nil,
                installed: !nodeCandidates.isEmpty,
                detail: Self.nodeDetail(
                    enabled: settings.nodeLaneEnabled, candidates: nodeCandidates
                ),
                // Nothing is billed, but the state crosses the tailnet to another machine,
                // which is the other question the owner is entitled to ask.
                leavesTheMac: true, costsMoney: false,
                measuredPerQuestionMS: node?.perQuestionMS,
                node: .init(
                    enabled: settings.nodeLaneEnabled,
                    peer: node?.name,
                    reachable: node != nil,
                    checkpoints: node?.checkpoints ?? [],
                    advertisedPerQuestionMS: node?.perQuestionMS,
                    candidates: nodeCandidates
                )
            ),
            .init(
                id: DecisionLaneID.oneToken.wireName,
                displayName: DecisionLaneID.oneToken.displayName,
                available: oneTokenDecider != nil,
                installed: oneTokenDecider != nil,
                detail: loadedModel.map {
                    "\($0.name), read one token deep. Uncalibrated, but it needs nothing "
                    + "installed."
                } ?? "No model is loaded here.",
                leavesTheMac: false, costsMoney: false
            ),
        ]
    }

    static func nodeDetail(
        enabled: Bool, candidates: [ControlAPI.NodeLaneDetail.Candidate]
    ) -> String {
        guard enabled else {
            return "Off. A node answers for free, but the state crosses your tailnet to it."
        }
        guard !candidates.isEmpty else {
            return "No node on your swarm is offering a decision lane."
        }
        guard let ready = candidates.first(where: \.ready) else {
            return "\(candidates.map(\.name).joined(separator: ", ")) offers one, but is not "
                + "reachable right now."
        }
        return "\(ready.name), with \(ready.checkpoints.joined(separator: ", "))."
    }

    /// Why nothing would answer a feature. Written for a person reading a settings row.
    static func whyNothingAnswers(_ feature: JevFeature, settings: JevSettings) -> String {
        switch settings.laneOverride(feature) {
        case .off:
            return "Switched off for this ability."
        case .alwaysJev:
            return settings.enabled
                ? "Pinned to Jev, which cannot answer right now."
                : "Pinned to Jev, which is switched off."
        case .alwaysLocal:
            return "Pinned to a local lane, and none is installed."
        case .automatic:
            return settings.isOn(feature)
                ? "Nothing is set up to answer it: install Laya, load a model, or turn on Jev."
                : "Switched off for this ability."
        }
    }

    /// A feature's fixed act/confirm pair, where it has one.
    ///
    /// Four of the eight compute their gate per question — the guardrail runs nine of them
    /// with two different shapes, verification's depends on what was verified — so those
    /// report none rather than a number that is true of one question out of nine.
    static func thresholds(for feature: JevFeature) -> ControlAPI.DecisionAbility.Thresholds? {
        func pair(_ t: JevThresholds) -> ControlAPI.DecisionAbility.Thresholds {
            .init(act: t.act, confirm: t.confirm)
        }
        switch feature {
        case .routing: return pair(RoutingQuestions.thresholds)
        case .mediaRouting: return pair(MediaRoutingThresholds.model)
        case .skillSelection: return pair(SkillSelectionQuestions.thresholds)
        case .recommendation: return pair(RecommendationQuestions.choiceThresholds)
        case .guardrails: return pair(GuardrailQuestions.hazard)
        case .decideTool, .verification, .calibration: return nil
        }
    }
}

// MARK: - Changing the lanes

extension AppModel {

    /// `POST /decisions/lanes` — a patch, like `POST /jev`.
    ///
    /// Unknown ids are **refused** here where `POST /jev` ignores them, and the difference
    /// is deliberate. A feature switch this build has never heard of means nothing here, so
    /// ignoring it is honest. A lane word that silently did nothing would leave the owner
    /// believing an ability was pinned away from the cloud when it was not, and that is a
    /// belief this app must never let anybody hold by accident.
    public func updateDecisionLanes(
        _ update: ControlAPI.DecisionLanesUpdate
    ) async throws -> ControlAPI.DecisionsStatus {
        await JevBootstrap.ready()
        await DecisionLanesBootstrap.ready()

        var checkpoint: LayaCheckpoint?
        if let asked = update.layaCheckpoint {
            guard let parsed = LayaCheckpoint(rawValue: asked) else {
                throw ControlHostError.badRequest(
                    ControlAPI.DecisionLaneVocabulary.unknownCheckpoint(asked)
                )
            }
            checkpoint = parsed
        }
        var overrides: [JevFeature: DecisionLaneOverride] = [:]
        for (id, choice) in update.overrides ?? [:] {
            guard let feature = JevFeature(rawValue: id) else {
                throw ControlHostError.badRequest(
                    "Unknown ability \"\(id)\". Use one of: "
                    + JevFeature.allCases.map(\.rawValue).joined(separator: ", ") + "."
                )
            }
            guard let override = DecisionLaneOverride(rawValue: choice) else {
                throw ControlHostError.badRequest(
                    ControlAPI.DecisionLaneVocabulary.unknownOverride(choice)
                )
            }
            overrides[feature] = override
        }

        let previous = await JevService.shared.settings().layaCheckpoint
        let fixed = overrides
        let pickedCheckpoint = checkpoint
        try await JevService.shared.update { settings in
            if let on = update.layaEnabled { settings.layaEnabled = on }
            if let on = update.nodeLaneEnabled { settings.nodeLaneEnabled = on }
            if let pickedCheckpoint { settings.layaCheckpoint = pickedCheckpoint }
            for (feature, override) in fixed { settings.laneOverrides[feature] = override }
        }
        await LayaLaneDefaults.refresh()
        await DecisionRouter.shared.forgetReadiness()

        // Switching checkpoints, switching the lane off, or asking outright all mean the
        // resident weights are no longer the right ones to be holding.
        if update.unloadLaya == true || update.layaEnabled == false
            || (pickedCheckpoint != nil && pickedCheckpoint != previous) {
            await LayaRuntime.shared.unload()
        }
        return await decisionsStatus()
    }

    /// `POST /decisions/install` — fetch the pinned package and a checkpoint.
    ///
    /// Answers as soon as the work is *started*, not when it finishes: this is a gigabyte
    /// over somebody's internet connection, and a route that held the socket open for it
    /// would time out on every client that asked. Progress is read back from
    /// `GET /decisions`, where `laya.installing` says whether one is running.
    public func installDecisionLane(
        _ request: ControlAPI.DecisionInstallRequest
    ) async throws -> ControlAPI.DecisionInstallAccepted {
        await JevBootstrap.ready()
        await DecisionLanesBootstrap.ready()
        var checkpoint = await JevService.shared.settings().layaCheckpoint
        if let asked = request.checkpoint {
            guard let parsed = LayaCheckpoint(rawValue: asked) else {
                throw ControlHostError.badRequest(
                    ControlAPI.DecisionLaneVocabulary.unknownCheckpoint(asked)
                )
            }
            checkpoint = parsed
        }
        guard let library = settings.resolvedModelLibraryDirectory else {
            throw ControlHostError.badRequest(
                LayaInstallError.noModelLibrary.localizedDescription
            )
        }
        guard !(await LayaRuntime.shared.isInstalling) else {
            throw ControlHostError.busy(
                "A Laya install is already running on this Mac. Wait for it to finish."
            )
        }
        let onlyWeights = request.checkpointOnly == true
        let picked = checkpoint
        LayaInstallCenter.shared.began(picked)
        Task.detached {
            do {
                if onlyWeights {
                    try await LayaRuntime.shared.fetch(picked)
                } else {
                    try await LayaRuntime.shared.install(checkpoint: picked)
                }
                await MainActor.run { LayaInstallCenter.shared.finished(nil) }
            } catch {
                await MainActor.run {
                    LayaInstallCenter.shared.finished(error.localizedDescription)
                }
            }
            await DecisionRouter.shared.forgetReadiness()
        }
        return .init(
            started: true, checkpoint: picked.rawValue,
            estimatedBytes: picked.downloadBytes,
            destination: LayaRuntime.hubCacheDirectory(library: library).path,
            detail: "Fetching \(LayaPackage.requirement) and \(picked.displayName) into "
                + "your model library. Watch `laya.installing` on GET /decisions."
        )
    }

    /// `POST /decisions/test` — the bench. One named lane, one question set, the raw
    /// probabilities, and no feature's thresholds applied.
    public func runDecisionTest(
        _ request: ControlAPI.DecisionTestRequest
    ) async throws -> ControlAPI.DecisionTestResult {
        await JevBootstrap.ready()
        await DecisionLanesBootstrap.ready()
        guard let lane = DecisionLaneID.named(request.lane) else {
            throw ControlHostError.badRequest(
                ControlAPI.DecisionLaneVocabulary.unknownLane(request.lane)
            )
        }
        let asked = ControlAPI.DecideRequest(
            state: request.state, questions: request.questions
        )
        try asked.validate()
        let started = Date()
        // Billed to the decide tool when the bench asks Jev, because it is a decide-tool
        // call: it spends the same money, so it goes in the same ledger line and under the
        // same budget rather than being a way to spend past one.
        let response = try await DecisionRouter.shared.ask(
            lane: lane, feature: .decideTool,
            state: request.state, questions: request.questions
        )
        let elapsed = response.latencyMS ?? Date().timeIntervalSince(started) * 1000
        return .init(
            lane: response.provider ?? lane.wireName,
            model: response.model,
            answers: response.answers,
            latencyMS: elapsed,
            perQuestionMS: elapsed / Double(max(1, request.questions.count)),
            usage: response.usage,
            estimatedUSD: lane == .jev
                ? ControlAPI.JevPricing.costUSD(inputTokens: response.usage.inputTokens)
                : 0
        )
    }

    /// `POST /jev/calibrate` with a lane, and `POST /decisions/calibrate`.
    ///
    /// A calibration is a *comparison*, and Jev is the reference on either side of it — so
    /// this still needs Jev, whichever lane is being measured. What changes is which lane
    /// plays the part that used to be hard-coded to the loaded model.
    public func calibrateDecisionLane(_ name: String?) async throws -> ControlAPI.JevCalibration {
        await JevBootstrap.ready()
        await DecisionLanesBootstrap.ready()
        guard let lane = name.map({ DecisionLaneID.named($0) }) ?? .oneToken else {
            throw ControlHostError.badRequest(
                ControlAPI.DecisionLaneVocabulary.unknownLane(name ?? "")
            )
        }
        guard lane != .jev else {
            throw ControlHostError.badRequest(
                "Jev is the reference a calibration measures against, so it cannot be the "
                + "lane being calibrated. Name local, laya or node."
            )
        }
        // The one-token lane keeps the route it has always had, unchanged in every respect
        // — same refusals, same file, same numbers.
        if lane == .oneToken { return try await calibrateJev() }

        guard await JevService.shared.isAvailable(.calibration) else {
            throw ControlHostError.badRequest(
                "Calibration asks Jev for the reference answers. Add a TypeSafe API key and "
                + "turn on Use Jev and Decision calibration in Settings → Decisions."
            )
        }
        guard await DecisionRouter.shared.availability(for: .calibration)[lane] else {
            throw ControlHostError.badRequest(
                "\(lane.displayName) cannot answer right now, so there is nothing to "
                + "calibrate. Install it, or switch it on in Settings → Decisions."
            )
        }
        guard !CalibrationRun.isRunning else {
            throw ControlHostError.busy(Self.calibrationAlreadyRunning)
        }

        let work = Task<ControlAPI.JevCalibration, any Error> { [self] in
            try await runLaneCalibration(lane: lane)
        }
        CalibrationRun.task = work
        defer { CalibrationRun.task = nil }
        return try await work.value
    }

    private func runLaneCalibration(
        lane: DecisionLaneID
    ) async throws -> ControlAPI.JevCalibration {
        let settings = await JevService.shared.settings()
        let store = await JevService.shared.storeLocations()
        let set = CalibrationQuestions.allCases(userCasesAt: store.userCases)
        let model = await calibrationModel(for: lane)
        var notes = set.notes

        // When more than one free lane exists, the run says how they compare — which is the
        // question an owner actually has once there are two of them, and which no per-lane
        // report on its own answers.
        let available = await DecisionRouter.shared.availability(for: .calibration)
        let others = DecisionLanePolicy.localPreference.filter { $0 != lane && available[$0] }
        if !others.isEmpty {
            notes.append(
                "This measures \(lane.displayName) against Jev. "
                + others.map(\.displayName).joined(separator: " and ")
                + " can also answer here; calibrate each one to compare their floors."
            )
        }

        noteActivity()
        let result = try await whileGenerating {
            try await CalibrationQuestions.calibrate(
                cases: set.cases,
                context: .init(
                    localModelID: model?.id ?? lane.wireName,
                    localModelName: lane.displayName,
                    jevModel: settings.model,
                    fallbackFloors: settings.cascadeFloors,
                    localModelSizeBytes: model?.sizeBytes,
                    localModelInstalledAt: model?.installedAt,
                    notes: notes
                ),
                local: { asked in
                    try await DecisionRouter.shared.ask(
                        lane: lane, feature: .calibration,
                        state: asked.state, questions: asked.questions
                    )
                },
                jev: { asked in
                    try await JevService.shared.ask(
                        .calibration, state: asked.state, questions: asked.questions
                    )
                }
            )
        }

        if let refusal = Self.refusalForUnsavableRun(result) {
            throw ControlHostError.badRequest(refusal)
        }
        var stamped = result
        stamped.lane = lane.wireName
        let url = await JevService.shared.calibrationURL(for: lane)
        do {
            try await LocalCalibrationStore.shared.save(stamped, to: url)
        } catch {
            throw ControlHostError.badRequest(
                "The calibration ran but could not be saved (\(error.localizedDescription)), "
                + "so the previous result is still in effect."
            )
        }
        return stamped
    }
}


// MARK: - Watching an install

/// What an install is doing, for the panel to draw.
///
/// Its own observable object rather than a property on `AppModel` for the reason
/// `BuddyCenter` is one: the install is a fact about this Mac rather than about any one
/// view, it is started from a control route as well as from a button, and an extension
/// cannot add a stored property to the model anyway.
@MainActor
@Observable
public final class LayaInstallCenter {
    public static let shared = LayaInstallCenter()

    public private(set) var step: String?
    public private(set) var detail: String?
    public private(set) var fraction: Double = 0
    public private(set) var error: String?
    public private(set) var checkpoint: LayaCheckpoint?

    public var isRunning: Bool { step != nil }

    private init() {}

    func began(_ checkpoint: LayaCheckpoint) {
        self.checkpoint = checkpoint
        step = "Starting"
        detail = nil
        fraction = 0
        error = nil
    }

    func progressed(_ progress: LayaInstallProgress) {
        step = progress.step
        detail = progress.detail
        fraction = progress.fraction
    }

    func finished(_ failure: String?) {
        step = nil
        detail = nil
        fraction = failure == nil ? 1 : 0
        error = failure
    }

    /// Starts one from the UI, with the progress wired up.
    public func install(checkpoint: LayaCheckpoint, weightsOnly: Bool = false) {
        guard !isRunning else { return }
        began(checkpoint)
        Task {
            do {
                if weightsOnly {
                    try await LayaRuntime.shared.fetch(checkpoint) { progress in
                        Task { @MainActor in LayaInstallCenter.shared.progressed(progress) }
                    }
                } else {
                    try await LayaRuntime.shared.install(checkpoint: checkpoint) { progress in
                        Task { @MainActor in LayaInstallCenter.shared.progressed(progress) }
                    }
                }
                finished(nil)
            } catch {
                finished(error.localizedDescription)
            }
            await DecisionRouter.shared.forgetReadiness()
        }
    }
}
