import Foundation
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
    func configureJev() { JevBootstrap.begin() }

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

    /// The floors `provider: "auto"` escalates on: the last calibration's when it was
    /// measured against the model loaded right now, and the settings' otherwise.
    func cascadeFloors() async -> ControlAPI.JevCalibration.Floors {
        await JevBootstrap.ready()
        let settings = await JevService.shared.settings().cascadeFloors
        let store = await JevService.shared.storeLocations()
        let calibration = await LocalCalibrationStore.shared.result(at: store.calibration)
        return CalibrationQuestions.floors(
            forModel: loadedModel?.id, calibration: calibration, settings: settings
        )
    }

    /// `GET /jev/calibration` — the last run, or nil if there has never been one.
    public func jevCalibration() async -> ControlAPI.JevCalibration? {
        await JevBootstrap.ready()
        let store = await JevService.shared.storeLocations()
        return await LocalCalibrationStore.shared.result(at: store.calibration)
    }

    /// `POST /jev/calibrate` — run every case through both lanes and write the result.
    ///
    /// Both halves have to be there: a calibration is a *comparison*, so without a loaded
    /// model there is nothing to calibrate, and without Jev there is nothing to calibrate
    /// against. Each refusal says which one is missing rather than "could not calibrate".
    public func calibrateJev() async throws -> ControlAPI.JevCalibration {
        await JevBootstrap.ready()
        guard case .ready(let endpoint) = runtimeState, let loaded = loadedModel else {
            throw ControlHostError.badRequest(
                "Calibration compares the model loaded here with Jev, so a model has to be "
                + "loaded. Load one and try again."
            )
        }
        guard await JevService.shared.isAvailable(.calibration) else {
            throw ControlHostError.badRequest(
                "Calibration asks Jev for the reference answers. Add a TypeSafe API key and "
                + "turn on Use Jev and Decision calibration in Settings → TypeSafe (Jev)."
            )
        }

        let settings = await JevService.shared.settings()
        let store = await JevService.shared.storeLocations()
        let set = CalibrationQuestions.allCases(userCasesAt: store.userCases)
        let decider = LocalDecider(endpoint: endpoint, modelName: loaded.name)

        noteActivity()
        let result = await whileGenerating {
            await CalibrationQuestions.calibrate(
                cases: set.cases,
                context: .init(
                    localModelID: loaded.id,
                    localModelName: loaded.name,
                    jevModel: settings.model,
                    fallbackFloors: settings.cascadeFloors,
                    builtInCount: CalibrationQuestions.builtIn.count,
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
        // Written even when both floors fell back to the defaults: the agreement rates and
        // the reliability bins are the point of looking, and a run that found no better
        // floor is a result a person should be able to read rather than a failure.
        try? await LocalCalibrationStore.shared.save(result, to: store.calibration)
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
