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
extension AppModel {

    /// Called once at start. Costs nothing — no Keychain read, no file read, no network.
    func configureJev() {
        Task {
            await JevService.shared.configure(
                keyProvider: { TypeSafeCredential.read() },
                keyIsSet: { TypeSafeCredential.isSet }
            )
        }
    }

    // MARK: - Control routes

    public func jevStatus() async -> ControlAPI.JevStatus {
        await Self.jevStatus(from: JevService.shared)
    }

    public func updateJev(_ update: ControlAPI.JevUpdate) async throws -> ControlAPI.JevStatus {
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
        }
        return await jevStatus()
    }

    /// Built here rather than inside `JevService` because the key question — is one stored?
    /// — is the app's to answer, and the service is deliberately given no way to say.
    static func jevStatus(from service: JevService) async -> ControlAPI.JevStatus {
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
            monthlyUSD: ledger.months.mapValues(\.total.estimatedUSD)
        )
    }
}
