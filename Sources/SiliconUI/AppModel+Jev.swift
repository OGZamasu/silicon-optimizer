import Foundation
import SiliconCatalog
import SiliconControl
import SiliconRuntime

/// The app's end of the Jev integration: who holds the key, and the two control routes that
/// read and set what Jev is allowed to do.
///
/// The key provider handed over here is the *only* route the service has to the credential.
/// `TypeSafeCredential.read` asks the Keychain for the secret and may show a consent dialog,
/// so it is given as a closure called at the moment a request is about to be sent;
/// `TypeSafeCredential.isSet` answers "is there one?" from item attributes alone and never
/// prompts, which is what Settings and `isAvailable` use while drawing.
/// Hands `JevService` its key provider, once, and gives everything that depends on it
/// something to wait for.
///
/// The configuration crosses onto an actor, so it cannot be finished synchronously from
/// `AppModel.start()`. Without a handle to wait on, a `/decide` arriving in the first
/// milliseconds of launch could be answered "no key" on a Mac that has one — the control
/// server's own start is a `Task` too, and nothing orders the two. So the work is kept as a
/// task and every entry point that needs a configured service awaits it first. `start()` is
/// called before the control server, so in practice this has already finished by the time
/// anyone asks.
@MainActor
enum JevBootstrap {
    private static var task: Task<Void, Never>?

    static func begin() {
        guard task == nil else { return }
        task = Task {
            await JevService.shared.configure(
                keyProvider: { TypeSafeCredential.read() },
                keyIsSet: { TypeSafeCredential.isSet }
            )
        }
    }

    /// Returns once the shared service has its key provider. Cheap after the first call,
    /// and a no-op in a test that never started the app.
    static func ready() async { await task?.value }
}

extension AppModel {

    /// Called once at start. Costs nothing — no Keychain read, no file read, no network.
    func configureJev() {
        JevBootstrap.begin()
        // The lanes start here rather than from `start()` because this is the Jev-owned
        // file and `start()` is not: one line in the file that already owns this wiring,
        // instead of an edit to the model another session is holding.
        configureDecisionLanes()
    }

    // MARK: - Control routes

    public func jevStatus() async -> ControlAPI.JevStatus {
        await JevBootstrap.ready()
        // What "follow whether a lane is installed" currently resolves to is this Mac's
        // to answer, not the service's — the service knows nothing about video models.
        return await Self.jevStatus(
            from: JevService.shared, uncensoredLaneInstalled: hasUncensoredVideoLane
        )
    }

    public func updateJev(_ update: ControlAPI.JevUpdate) async throws -> ControlAPI.JevStatus {
        await JevBootstrap.ready()
        // Checked before the edit rather than inside it. `normalized()` would quietly fall
        // back to the pin, and silently storing something other than what was asked for is
        // worse than refusing: an unknown model name is a 422 on every later call.
        if let model = update.model, !JevService.allowedModels.contains(model) {
            throw ControlHostError.badRequest(
                "Unknown Jev model \"\(model)\". Use one of: "
                + JevService.allowedModels.joined(separator: ", ") + "."
            )
        }
        try await JevService.shared.update { settings in
            if let enabled = update.enabled { settings.enabled = enabled }
            if let model = update.model { settings.model = model }
            for (id, on) in update.features ?? [:] {
                // Ignored rather than refused: a client built against a later version may
                // know a feature this build does not, and the switch means nothing here.
                guard let feature = JevFeature(rawValue: id) else { continue }
                settings.features[feature] = on
            }
            if update.clearMonthlyBudget == true {
                settings.monthlyBudgetUSD = nil
            } else if let budget = update.monthlyBudgetUSD {
                settings.monthlyBudgetUSD = budget
            }
            if let minutes = update.cacheMinutes { settings.cacheMinutes = minutes }
            if let bytes = update.maxStateBytes { settings.maxStateBytes = bytes }
            if update.clearRoutingFallback == true {
                settings.routingFallbackModel = nil
            } else if let model = update.routingFallbackModel {
                settings.routingFallbackModel = model
            }
            if update.clearVerificationEscalation == true {
                settings.verificationEscalationModel = nil
            } else if let model = update.verificationEscalationModel {
                settings.verificationEscalationModel = model
            }
            if update.clearAutomaticUncensoredLane == true {
                settings.automaticUncensoredLane = nil
            } else if let automatic = update.automaticUncensoredLane {
                settings.automaticUncensoredLane = automatic
            }
            if let auto = update.composerAutoRoute { settings.composerAutoRoute = auto }
        }
        return await jevStatus()
    }

    /// `GET /jev/guardrails/recent`. Read straight off the main actor's ring buffer, which
    /// is where every screening this app makes is recorded — and which holds ids and bands
    /// rather than commands, so answering a phone with it discloses nothing.
    public func recentGuardrailScreenings() async -> ControlAPI.GuardrailScreenings {
        await JevGuardrails.recent()
    }

    // MARK: - Calibration

    /// How the app describes the loaded model to a calibration: the id, and the weights
    /// behind it. An id alone can be reused — removed and reinstalled at a different
    /// quantization, or a local build overwritten — and floors would then be applied to
    /// weights they were never measured against.
    var calibrationModel: CalibrationQuestions.LoadedModel? {
        guard let loaded = loadedModel else { return nil }
        return .init(
            id: loaded.id,
            sizeBytes: loaded.sizeOnDisk.rawValue,
            installedAt: ControlAPI.timestamp(loaded.installedAt)
        )
    }

    /// The floors `provider: "auto"` escalates on.
    ///
    /// Per lane now, because a confidence number means whatever produced it means by it:
    /// the floors measured against the loaded chat model read one token deep say nothing
    /// about Laya's, which is a decision model with a distribution of its own. So the
    /// cascade asks for the floors belonging to whichever lane is about to answer its free
    /// pass, and falls back to the settings when that lane has never been calibrated.
    func cascadeFloors(
        for lane: DecisionLaneID = .oneToken
    ) async -> ControlAPI.JevCalibration.Floors {
        await JevBootstrap.ready()
        let settings = await JevService.shared.settings().cascadeFloors
        let url = await JevService.shared.calibrationURL(for: lane)
        let calibration = await LocalCalibrationStore.shared.result(at: url)
        return CalibrationQuestions.floors(
            for: await calibrationModel(for: lane), calibration: calibration,
            settings: settings
        )
    }

    /// How a lane describes the thing its floors were measured against.
    ///
    /// For the one-token lane that is the loaded model — an id, its bytes and when it was
    /// installed, because an id alone can be reused. For Laya it is the checkpoint *and its
    /// pinned revision*, for exactly the same reason: "aac6fef/laya-mlx" at one commit is
    /// not a promise about the next, and floors measured against one must not be applied to
    /// the other.
    func calibrationModel(
        for lane: DecisionLaneID, using service: JevService = .shared
    ) async -> CalibrationQuestions.LoadedModel? {
        switch lane {
        case .oneToken:
            return calibrationModel
        case .laya:
            let checkpoint = await service.settings().layaCheckpoint
            return .init(
                id: "\(checkpoint.repository)@\(checkpoint.revision)",
                sizeBytes: checkpoint.downloadBytes, installedAt: nil
            )
        case .node, .jev:
            // A node's weights are not this Mac's to identify, and Jev is the reference
            // rather than a thing being calibrated.
            return nil
        }
    }

    /// `GET /jev/calibration` — the last run, or nil if there has never been one.
    ///
    /// The stored result plus the three things only this Mac knows: whether those floors are
    /// the ones actually running, which floors are, and what is loaded instead. A client
    /// showing a calibration measured on a model nobody has loaded since would otherwise be
    /// describing something that is not happening.
    public func jevCalibration() async -> ControlAPI.JevCalibration? {
        await calibration(for: .oneToken)
    }

    /// `GET /jev/calibration?lane=…` — one lane's last run.
    ///
    /// Answered here rather than left to `ControlHost`'s default, which knows only the
    /// one-token lane: that default is for hosts with no lanes of their own, and standing in
    /// for this Mac's it turned every `?lane=laya` and `?lane=node` into a 404.
    public func decisionCalibration(lane: String?) async -> ControlAPI.JevCalibration? {
        await decisionCalibration(lane: lane, using: .shared)
    }

    func decisionCalibration(
        lane: String?, using service: JevService
    ) async -> ControlAPI.JevCalibration? {
        // No lane, or `local`, is the one-token lane — the route as it always answered.
        // Jev is the reference a calibration measures against, never a lane with one.
        guard let id = lane.map({ DecisionLaneID.named($0) }) ?? .oneToken, id != .jev
        else { return nil }
        return await calibration(for: id, using: service)
    }

    /// One lane's last calibration, with the context only this Mac can fill in.
    public func calibration(
        for lane: DecisionLaneID, using service: JevService = .shared
    ) async -> ControlAPI.JevCalibration? {
        await JevBootstrap.ready()
        let url = await service.calibrationURL(for: lane)
        guard var result = await LocalCalibrationStore.shared.result(at: url)
        else { return nil }
        let model = await calibrationModel(for: lane, using: service)
        let settings = await service.settings().cascadeFloors
        let applies = result.measured(
            modelID: model?.id, sizeBytes: model?.sizeBytes, installedAt: model?.installedAt
        )
        result.lane = result.lane ?? lane.wireName
        result.appliesToLoadedModel = applies
        result.floorsInEffect = applies
            ? result.floors.normalized(default: settings)
            : settings
        result.loadedModelName = applies
            ? nil
            : (lane == .oneToken ? loadedModel?.name : model?.id)
        return result
    }

    /// Every lane that has ever been calibrated on this Mac, for the Decisions panel.
    public func allCalibrations() async -> [String: ControlAPI.JevCalibration] {
        var results: [String: ControlAPI.JevCalibration] = [:]
        for lane in [DecisionLaneID.oneToken, .laya, .node] {
            guard let result = await calibration(for: lane) else { continue }
            results[lane.wireName] = result
        }
        return results
    }

    /// `POST /jev/calibrate` — run every case through both lanes and write the result.
    ///
    /// Both halves have to be there: a calibration is a *comparison*, so without a loaded
    /// model there is nothing to calibrate, and without Jev there is nothing to calibrate
    /// against. Each refusal says which one is missing rather than "could not calibrate".
    ///
    /// One at a time. Two runs would interleave requests at one llama-server, double the
    /// bill, and race each other to write the same file — so a second one is refused with a
    /// 409 the caller can act on rather than queued behind the first.
    public func calibrateJev() async throws -> ControlAPI.JevCalibration {
        await JevBootstrap.ready()
        guard case .ready(let endpoint) = runtimeState, let loaded = loadedModel else {
            throw ControlHostError.badRequest(
                "Calibration compares the model loaded here with Jev, so a model has to be "
                + "loaded. Load one and try again."
            )
        }
        if let refusal = await Self.calibrationPinRefusal(using: .shared) {
            throw ControlHostError.badRequest(refusal)
        }
        guard await JevService.shared.isAvailable(.calibration) else {
            throw ControlHostError.badRequest(
                "Calibration asks Jev for the reference answers. Add a TypeSafe API key and "
                + "turn on Use Jev and Decision calibration in Settings → TypeSafe (Jev)."
            )
        }
        guard !CalibrationRun.isRunning else {
            throw ControlHostError.busy(Self.calibrationAlreadyRunning)
        }

        let work = Task<ControlAPI.JevCalibration, any Error> { [self] in
            try await runCalibration(endpoint: endpoint, loaded: loaded)
        }
        CalibrationRun.task = work
        defer { CalibrationRun.task = nil }
        return try await work.value
    }

    /// Why the owner's pin for Decision calibration forbids a run, or nil when it allows one.
    ///
    /// A calibration is a comparison against Jev's answers and is billed to this ability, so
    /// an ability pinned "Always local" or "Off" cannot run one at all. Said in those words
    /// rather than left to the "add a TypeSafe API key" refusal below, which would send an
    /// owner who pinned it away from the cloud on purpose looking for a key they already have.
    static func calibrationPinRefusal(using service: JevService) async -> String? {
        switch await service.settings().laneOverride(.calibration) {
        case .off:
            return "Decision calibration is switched off in Settings → Decisions, so no "
                + "calibration runs. Nothing was sent to Jev."
        case .alwaysLocal:
            return "Decision calibration is set to Always local in Settings → Decisions. A "
                + "calibration measures a lane against Jev's answers, so it cannot run without "
                + "asking Jev. Nothing was sent."
        case .automatic, .alwaysJev:
            return nil
        }
    }

    /// Why a finished run must not be written, or nil when it may be.
    ///
    /// A run where nothing could be compared is not a calibration, it is a failure with a
    /// report attached. Writing it would replace a good calibration with floors derived from
    /// no data at all — and because the floors fall back to the settings when a search finds
    /// nothing, the file would look perfectly reasonable while meaning nothing. So it throws,
    /// and the previous result and the cache holding it stay exactly where they were.
    static func refusalForUnsavableRun(_ result: ControlAPI.JevCalibration) -> String? {
        guard result.comparisons == 0 else { return nil }
        return "No case could be answered by both lanes, so there is nothing to calibrate "
            + "from and the previous result is unchanged."
            + (result.notes.first.map { " First failure: \($0)" } ?? "")
    }

    public static let calibrationAlreadyRunning =
        "A calibration is already running on this Mac. Wait for it to finish, or cancel it "
            + "in Settings → TypeSafe (Jev)."

    private func runCalibration(
        endpoint: URL, loaded: InstalledModel
    ) async throws -> ControlAPI.JevCalibration {
        let settings = await JevService.shared.settings()
        let store = await JevService.shared.storeLocations()
        let set = CalibrationQuestions.allCases(userCasesAt: store.userCases)
        let decider = LocalDecider(endpoint: endpoint, modelName: loaded.name)

        noteActivity()
        let result = try await whileGenerating {
            try await CalibrationQuestions.calibrate(
                cases: set.cases,
                context: .init(
                    localModelID: loaded.id,
                    localModelName: loaded.name,
                    jevModel: settings.model,
                    fallbackFloors: settings.cascadeFloors,
                    localModelSizeBytes: loaded.sizeOnDisk.rawValue,
                    localModelInstalledAt: ControlAPI.timestamp(loaded.installedAt),
                    notes: set.notes
                ),
                local: { try await decider.decide($0) },
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
        do {
            try await LocalCalibrationStore.shared.save(result, to: store.calibration)
        } catch {
            // Not swallowed. A run that cost real money and then vanished, leaving the old
            // floors in place with no sign of it, is the one outcome nobody could debug.
            throw ControlHostError.badRequest(
                "The calibration ran but could not be saved (\(error.localizedDescription)), "
                + "so the previous result is still in effect."
            )
        }
        return result
    }

    /// Built here rather than inside `JevService` because the key question — is one stored?
    /// — is the app's to answer, and the service is deliberately given no way to say.
    static func jevStatus(
        from service: JevService, uncensoredLaneInstalled: Bool = false
    ) async -> ControlAPI.JevStatus {
        let settings = await service.settings()
        let ledger = await service.ledger()
        let month = JevLedger.monthKey()
        let totals = ledger.month(month)

        var features: [ControlAPI.JevStatus.Feature] = []
        for feature in JevFeature.allCases {
            let entry = totals.features[feature.rawValue] ?? JevLedger.Entry()
            features.append(.init(
                id: feature.rawValue,
                displayName: feature.displayName,
                summary: feature.summary,
                enabled: settings.isOn(feature),
                available: await service.isAvailable(feature),
                built: feature.isBuilt,
                calls: entry.calls,
                inputTokens: entry.inputTokens,
                estimatedUSD: entry.estimatedUSD
            ))
        }

        return ControlAPI.JevStatus(
            enabled: settings.enabled,
            model: settings.model,
            availableModels: JevService.allowedModels,
            keySet: TypeSafeCredential.isSet,
            monthlyBudgetUSD: settings.monthlyBudgetUSD,
            budgetRemainingUSD: settings.monthlyBudgetUSD.map {
                $0 - totals.total.estimatedUSD
            },
            cacheMinutes: settings.cacheMinutes,
            maxStateBytes: settings.maxStateBytes,
            features: features,
            month: month,
            calls: totals.total.calls,
            inputTokens: totals.total.inputTokens,
            estimatedUSD: totals.total.estimatedUSD,
            models: totals.models,
            monthlyUSD: ledger.months.mapValues(\.total.estimatedUSD),
            ledgerWriteFailed: await service.ledgerWriteFailed,
            automaticUncensoredLane: settings.automaticUncensoredLane,
            automaticUncensoredLaneInEffect: settings.automaticUncensoredLane(
                uncensoredLaneInstalled: uncensoredLaneInstalled
            ),
            composerAutoRoute: settings.composerAutoRoute,
            routingFallbackModel: settings.routingFallbackModel,
            verificationEscalationModel: settings.verificationEscalationModel
        )
    }
}

/// The one calibration run allowed at a time, and the handle that can stop it.
///
/// A free function's worth of state, kept here rather than on `AppModel` because an extension
/// cannot add a stored property — and because "is a calibration running?" is a fact about
/// this Mac rather than about any one view.
@MainActor
enum CalibrationRun {
    static var task: Task<ControlAPI.JevCalibration, any Error>?

    static var isRunning: Bool { task != nil }

    /// Cancelling throws out of the run between cases, so a half-measured set is never
    /// written and the previous calibration keeps working.
    static func cancel() { task?.cancel() }
}
