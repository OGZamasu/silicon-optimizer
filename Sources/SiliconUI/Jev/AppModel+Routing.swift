import Foundation
import SiliconCatalog
import SiliconControl
import SiliconCore
import SiliconRuntime

/// The app's end of model routing: turning what this Mac can reach into candidates, and
/// answering the gateway's one question — which real model should take this request.
///
/// The judgment lives in `RoutingQuestions.swift`; this file is the wiring. It holds no state
/// of its own, and it cannot fail a request: every path out of `gatewayRoute` returns a model
/// to use, because a chat completion that dies because a routing service was down would be a
/// worse feature than no routing at all.
extension AppModel {

    // MARK: - GatewayHost

    public func gatewayRoute(modelID: String, body: Data) async -> GatewayRoutingDecision? {
        // Every ordinary id goes straight through, untouched and un-awaited-on.
        guard GatewayAPI.isAutoModelID(modelID) else { return nil }

        let candidates = RoutingQuestions.shortlist(await routingCandidates())
        guard let fallback = routingDefaultModelID(among: candidates) else { return nil }
        return await ModelRouter.route(
            request: RoutingRequest.read(body: body),
            candidates: candidates, defaultModel: fallback
        )
    }

    // MARK: - Candidates

    /// Every gateway model Auto may pick between, with the traits the questions describe it
    /// by. Built from the same list `GET /v1/models` serves, so a model someone hid in the
    /// Swarm page is not quietly still a candidate.
    func routingCandidates() async -> [RoutingCandidate] {
        let models = await gatewayModels().filter { !GatewayAPI.isAutoModelID($0.id) }
        // Labels are assigned over the whole list at once, because their only hard job is
        // being unique within one question.
        let labels = RoutingCandidate.labels(for: models.map(\.displayName))
        var candidates: [RoutingCandidate] = []
        for (index, model) in models.enumerated() {
            let label = labels[index]
            switch GatewayAPI.parseModelID(model.id) {
            case .local(let installID):
                guard let installed = installedModels.first(where: { $0.id == installID })
                else { continue }
                candidates.append(.local(
                    model, installed: installed,
                    catalog: installed.catalogID.flatMap { ModelCatalog.entry(id: $0) },
                    label: label
                ))
            case .node(let slug, _):
                let peer = swarmPeers.first { GatewayAPI.peerSlug($0.name) == slug }?.name
                candidates.append(.node(model, peer: peer ?? slug, label: label))
            case .cloud(let provider, _):
                candidates.append(.cloud(
                    model,
                    cloud: cloudModels.first { $0.gatewayID == model.id },
                    provider: CloudProvider(rawValue: provider)?.displayName ?? provider,
                    label: label
                ))
            case nil:
                continue
            }
        }
        return candidates
    }

    /// Where a request goes when Jev has no opinion, cannot be asked, or picked something
    /// that cannot take it.
    ///
    /// The owner's pick if they made one and it is still there; otherwise the model loaded
    /// on this Mac; otherwise the first one that would answer without a load. Never a remote
    /// model unless there is nothing else — for the reason `autoSelectableGatewayModels`
    /// gives: ticking a box to make a paid model *available* is not asking to be billed by
    /// something that chose it for you.
    func routingDefaultModelID(among candidates: [RoutingCandidate]) -> String? {
        if let pinned = RoutingFallback.modelID,
           candidates.contains(where: { $0.id == pinned }) {
            return pinned
        }
        if let loaded = loadedModel, runtimeState.isRunning {
            let id = GatewayAPI.modelID(local: loaded.id)
            if candidates.contains(where: { $0.id == id }) { return id }
        }
        if let warm = candidates.first(where: { $0.readyNow && !$0.placement.isCloud }) {
            return warm.id
        }
        if let local = candidates.first(where: { !$0.placement.isCloud }) { return local.id }
        return candidates.first?.id
    }

    /// The model list with Auto in front of it, when Auto is real.
    ///
    /// Two conditions, both necessary. Routing has to be able to answer — on, with a key,
    /// inside the budget — and there has to be something to choose between: a harness that
    /// sees an id will call it, and an Auto that cannot pick is an id that fails.
    nonisolated static func listingAuto(
        _ models: [GatewayAPI.Model], routingAvailable: Bool
    ) -> [GatewayAPI.Model] {
        guard routingAvailable, !models.isEmpty else { return models }
        let auto = GatewayAPI.Model(
            id: GatewayAPI.autoModelID,
            displayName: GatewayAPI.autoModelDisplayName,
            where_: "Chosen per request",
            // Deliberately no context window: it is whatever the chosen model's is, and a
            // number here would be a promise Auto cannot keep.
            serving: true
        )
        return [auto] + models
    }
}

// MARK: - Deciding

/// One routed request, start to finish: ask Jev, read the answers, apply the policy.
///
/// Free of the app so it can be driven by a test against a loopback TypeSafe — and because
/// it has no business touching the model library: by this point the candidates and the
/// default have already been worked out.
public enum ModelRouter {

    public static func route(
        request: RoutingRequest, candidates: [RoutingCandidate], defaultModel: String,
        using service: JevService = .shared
    ) async -> GatewayRoutingDecision {
        func using(_ id: String, _ reason: String) -> GatewayRoutingDecision {
            let name = candidates.first { $0.id == id }?.name ?? id
            return GatewayRoutingDecision(modelID: id, reason: "\(name) — \(reason)")
        }

        // Off, no key, or the month's budget is spent. Not an error: the owner decided this,
        // and Auto still has to answer.
        guard await service.isAvailable(.routing) else {
            return using(defaultModel, "Jev is not answering routing right now; used the default")
        }

        do {
            let response = try await RoutingQuestions.ask(
                request: request, candidates: candidates, using: service
            )
            let answers = RoutingAnswers.read(from: response).observing(request)
            let decision = RoutingPolicy.choose(
                answers: answers, candidates: candidates, defaultModel: defaultModel
            )
            return GatewayRoutingDecision(modelID: decision.modelID, reason: decision.reason)
        } catch {
            // A 429 that outlasted its retries, a budget that ran out between the check and
            // the call, TypeSafe being down. The request is still a request.
            return using(
                defaultModel,
                "routing did not answer (\(error.localizedDescription)); used the default"
            )
        }
    }
}

// MARK: - The owner's default

/// Which model Auto falls back to, as the owner set it in Settings.
///
/// Its own defaults key rather than a field in `settings.json` or `jev.json`: the first is
/// the app's own document and the second is owned by an actor that governs spending, and
/// this is neither — it is one id, written by a picker, read by the router.
///
/// Nil means "decide for me", which is the shipped behaviour: the loaded model, else the
/// first one that answers without a load.
public enum RoutingFallback {

    public static let defaultsKey = "dev.siliconoptimizer.jev.routingFallbackModel"

    public static var modelID: String? {
        get {
            let stored = UserDefaults.standard.string(forKey: defaultsKey)
            return (stored?.isEmpty ?? true) ? nil : stored
        }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }
}
