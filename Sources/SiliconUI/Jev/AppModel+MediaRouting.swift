import Foundation
import SiliconCatalog
import SiliconControl
import SiliconPlanner
import SiliconRuntime

/// Which `JevService` the media-routing hooks ask.
///
/// The app never sets the override, so it is always the shared instance. A test wraps its
/// own call in `MediaRouter.$override.withValue(_:)` and gets a service wired to a loopback
/// double, without the shared singleton, the owner's `jev.json` or a network.
///
/// Task-local rather than a plain `static var` deliberately: the test suites run in
/// parallel, and a process-wide switch set by one of them would silently route another
/// suite's video enqueue at whatever server this one happened to be running.
public enum MediaRouter {
    @TaskLocal public static var override: JevService?

    public static var service: JevService { override ?? .shared }
}

// MARK: - Candidates

extension AppModel {

    /// Whether this Mac is set up to route media requests right now: Jev on, the feature on,
    /// a key stored, budget left. Cheap — no network and no Keychain prompt.
    ///
    /// Waits for the bootstrap first, like every other Jev entry point. Handing the service
    /// its key provider crosses onto an actor, and an `"auto"` request that arrives in the
    /// first milliseconds of launch would otherwise be told there is no key and go unrouted
    /// on a Mac that has one — and the Video tab's toggle would be hidden by the same race.
    public var mediaRoutingIsAvailable: Bool {
        get async {
            await JevBootstrap.ready()
            return await DecisionRouter.router(for: MediaRouter.service).canAnswer(.mediaRouting)
        }
    }

    /// The owner's media-routing choices, read fresh.
    var mediaRoutingSettings: JevSettings {
        get async {
            await JevBootstrap.ready()
            return await MediaRouter.service.settings()
        }
    }

    /// Every video model, with what the last swarm poll knows about each folded in.
    ///
    /// The whole catalog rather than only the ready ones: a lane that nothing can run is
    /// still worth showing the router, because "the only model that suits this is the one
    /// you have not set up" is a more useful answer than a silent second choice. The policy
    /// is what prefers a ready lane, and it says so in the reason.
    public func videoRoutingCandidates() -> [MediaCandidate] {
        VideoCatalog.all.map { entry in
            let node = videoCapableNode(for: entry)
            return .video(
                entry, node: node?.name,
                capabilityParameters: node
                    .flatMap { videoCapability(for: entry, on: $0)?.supportedParameters } ?? []
            )
        }
    }

    /// Whether an uncensored video lane exists on this Mac at all — which is what decides
    /// whether the Settings toggle defaults on.
    public var hasUncensoredVideoLane: Bool {
        VideoCatalog.all.contains { entry in
            MediaCandidate.isUncensoredVideo(entry) && videoCapableNode(for: entry) != nil
        }
    }

    /// The diffusion models, with the machine that would actually render them.
    ///
    /// Only the installed ones are offered: an image model that is not on disk means a
    /// several-gigabyte download in the middle of what the caller thinks is a render, and
    /// choosing that for someone is not the router's place. When nothing is installed the
    /// list is the catalog, which is today's behaviour — the first entry that fits is
    /// downloaded on use.
    public func imageRoutingCandidates() -> [MediaCandidate] {
        let runsOn = imageRenderTarget == nil
            ? MediaCandidate.thisMac : MediaCandidate.pairedMachine
        let installed = DiffusionCatalog.all.filter { DiffusionInstaller.isInstalled($0) }
        let offered = installed.isEmpty ? DiffusionCatalog.all : installed
        return offered.map {
            .image($0, installed: DiffusionInstaller.isInstalled($0), runsOn: runsOn)
        }
    }
}

// MARK: - The video hooks

extension AppModel {

    /// A batch's prompts as one piece of text for the router to read.
    ///
    /// One model and one length are chosen for the whole batch, so the router is shown the
    /// whole batch — capped, because the tenth shot does not change which lane renders the
    /// first nine and a long state costs accuracy.
    static func routingPrompt(for prompts: [String]) -> String {
        prompts.prefix(12).joined(separator: "\n\n")
    }

    /// Resolves an auto video request into a concrete model, length and settings.
    ///
    /// Returns the request untouched, and no reason, whenever Jev is not available — which
    /// is the whole "behave exactly as today" contract: the caller then falls through to
    /// `selectedVideoModel` and `videoSeconds` exactly as it did before this feature
    /// existed. A refusal or a request to confirm throws instead, because both of those are
    /// things the caller must not quietly paper over.
    func mediaRoutedVideo(
        prompt: String, explicitModelID: String?, seconds: Int?
    ) async throws -> MediaRoutingDecision? {
        guard MediaRoutingQuestions.isAuto(explicitModelID),
              await mediaRoutingIsAvailable
        else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // The candidate list is only as good as the last look at the swarm, and a node that
        // came back an hour ago must not be routed around as "not ready".
        await refreshSwarmIfStale()
        let candidates = videoRoutingCandidates()
        let defaults = MediaRoutingDefaults(
            explicitModelID: nil,
            fallbackModelID: selectedVideoModel,
            explicitSeconds: seconds,
            seconds: videoSeconds,
            automaticUncensoredLane: await mediaRoutingSettings.automaticUncensoredLane(
                uncensoredLaneInstalled: hasUncensoredVideoLane
            )
        )

        let answers: MediaRoutingAnswers
        do {
            let response = try await MediaRoutingQuestions.ask(
                prompt: trimmed, kind: .video, candidates: candidates,
                using: MediaRouter.service
            )
            answers = try MediaRoutingAnswers(response, expectingModel: true)
        } catch {
            // Jev was reachable in principle and did not answer. Today's behaviour, and a
            // line saying why rather than a silent change of model.
            videoQueueMessage = "Jev did not route this clip (\(error.localizedDescription))."
                + " Used \(selectedVideoModel)."
            return nil
        }

        switch MediaRoutingPolicy.choose(
            answers: answers, candidates: candidates, kind: .video, defaults: defaults
        ) {
        case .route(let decision):
            return decision
        case .refuse(let message):
            throw ControlHostError.badRequest(message)
        }
    }
}

// MARK: - The image hook

extension AppModel {

    /// What routing did to an image request: the request to actually run, and the line to
    /// report alongside the result.
    struct RoutedImageRequest {
        var request: ControlAPI.ImageRequest
        var reason: String?
    }

    /// Resolves `model_id: "auto"` (or an omitted model) into a concrete diffusion entry and
    /// a step count.
    ///
    /// When Jev is unavailable this only normalises the literal string `"auto"` to nil, so
    /// the request behaves exactly as an omitted model always has: the best entry this Mac
    /// can comfortably run. Without that one rewrite, `"auto"` would be an unknown-model
    /// error, and a tool that advertises the word has to honour it whether or not anyone is
    /// paying TypeSafe.
    ///
    /// Called by both `planImage` and `generateImage`, which is deliberate and not two
    /// charges: the same prompt against the same candidates is the same state and the same
    /// questions, so the service's cache answers the second one. Plan-then-generate costs
    /// one call, and a plan that named a different model than the render would have used
    /// would be worse than useless.
    func mediaRoutedImage(_ request: ControlAPI.ImageRequest) async throws -> RoutedImageRequest {
        var normalized = request
        guard MediaRoutingQuestions.isAuto(request.modelID) else {
            return RoutedImageRequest(request: request, reason: nil)
        }
        normalized.modelID = nil
        // `localOnly` is an enforced routing capability: it says this prompt must not leave
        // this Mac. Picking the model for it would send the prompt to TypeSafe, which is
        // exactly what the caller forbade — so the answer is code's, as it was before this
        // feature existed. No video request carries an equivalent field today; if one is
        // added, it belongs here too.
        guard request.localOnly != true else {
            return RoutedImageRequest(request: normalized, reason: nil)
        }
        guard await mediaRoutingIsAvailable else {
            return RoutedImageRequest(request: normalized, reason: nil)
        }
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return RoutedImageRequest(request: normalized, reason: nil) }

        let candidates = imageRoutingCandidates()
        let defaults = MediaRoutingDefaults(
            explicitModelID: nil,
            fallbackModelID: selectedDiffusionModel,
            seconds: 0,
            // There is no uncensored diffusion lane in this catalog, so the toggle cannot
            // apply here; passing false would turn every adult image prompt into a confirm
            // the owner cannot satisfy. The policy refuses instead, which is the honest
            // answer when the pool has no lane for it.
            automaticUncensoredLane: true
        )

        let answers: MediaRoutingAnswers
        do {
            let response = try await MediaRoutingQuestions.ask(
                prompt: prompt, kind: .image, candidates: candidates,
                using: MediaRouter.service
            )
            answers = try MediaRoutingAnswers(response, expectingModel: true)
        } catch {
            return RoutedImageRequest(request: normalized, reason: nil)
        }

        switch MediaRoutingPolicy.choose(
            answers: answers, candidates: candidates, kind: .image, defaults: defaults
        ) {
        case .route(let decision):
            normalized.modelID = decision.modelID
            // An explicit step count from the caller outranks the router's: they asked.
            if request.steps == nil { normalized.steps = decision.steps }
            return RoutedImageRequest(request: normalized, reason: decision.reason)
        case .refuse(let message):
            throw ControlHostError.badRequest(message)
        }
    }

    /// Joins a routing line onto whatever warning the render itself produced, so neither is
    /// lost and the order is the same every time.
    static func merged(_ warning: String?, _ reason: String?) -> String? {
        let parts = [reason, warning].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - The Image tab

// The Image tab's own composer is not routed, and the reason is not symmetry with the Video
// tab being forgotten.
//
// That composer's memory plan is live: the panel shows this model at this size and this
// precision, peaking at this many gigabytes, and whether it fits. All of that is bound to
// the model in the picker. Swapping the model underneath at the moment the button is pressed
// would make every number the person just read wrong, and the one thing that panel exists
// for is to be right before a nine-gigabyte download and a two-minute render.
//
// The Video tab has no such panel — a clip's cost is the node's, not this Mac's — which is
// why a toggle works there and would mislead here. The control API and the MCP tools route
// images, because a caller there has no panel to be contradicted by.

// MARK: - 3D

// There is no mesh hook, and the reason is not that it was skipped for time.
//
// `ControlAPI.MeshRequest` carries an image path and no prompt: the 3D lane is
// image-to-mesh, so the thing this router reads does not exist there. Jev answers questions
// about text, and no amount of state about TRELLIS.2 and Hunyuan3D would let it judge a
// photograph it cannot see. `resolveMesh` already picks the best installed backend in code,
// which is the right answer for a decision with no language in it. `MediaKind.mesh` exists
// so the policy is written once and is ready the day a text-to-3D backend appears.
