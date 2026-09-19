import AppKit
import Foundation
import SiliconCatalog
import SiliconPlanner
import SiliconRuntime

/// Lifecycle of the DeepSeek Harness sidecar behind the Chat tab.
///
/// The harness starts lazily, the first time the harness chat is actually shown, because it is
/// a Node.js process with a first-run download — cost that must never be paid by someone who
/// only came to load a model.
extension AppModel {

    /// The two stable localhost ports the harness integration depends on: one for its web UI,
    /// one for the inference server its provider config points at.
    ///
    /// Chosen once, persisted, and re-verified each session: a port that something else now
    /// occupies is replaced rather than fought over.
    func harnessPorts() -> (web: Int, inference: Int) {
        if let resolved = resolvedHarnessPorts { return resolved }

        var web = settings.harnessWebPort ?? 0
        if web == 0 || !HarnessRuntime.isPortFree(web) {
            web = HarnessRuntime.allocatePort()
        }
        var inference = settings.harnessInferencePort ?? 0
        if inference == 0 || !HarnessRuntime.isPortFree(inference) {
            inference = HarnessRuntime.allocatePort()
        }

        if settings.harnessWebPort != web || settings.harnessInferencePort != inference {
            settings.harnessWebPort = web
            settings.harnessInferencePort = inference
            settings.save()
        }
        let resolved = (web, inference)
        resolvedHarnessPorts = resolved
        return resolved
    }

    /// The context the harness chat wants: its system prompt and tool definitions consume
    /// roughly 8K tokens before the conversation begins, so the plain-chat ladder's lower
    /// rungs produce instant "exceeds the available context size" failures.
    public static let harnessContextFloor = 16_384
    /// Below this the harness cannot complete even a first exchange.
    public static let harnessContextMinimum = 8_192

    /// Raises a load configuration's context for harness chat, but only as far as the memory
    /// plan stays comfortable — a harness that fits is worth more than a context that swaps.
    ///
    /// Leaves the configuration alone when the legacy engine is active, when the context is
    /// already at the floor, or when nothing larger fits; the Chat tab warns about the last
    /// case rather than this silently degrading the load.
    func harnessContextAdjusted(
        _ configuration: LoadConfiguration, for model: InstalledModel
    ) -> LoadConfiguration {
        guard settings.chatEngine == .harness,
              configuration.contextLength < Self.harnessContextFloor,
              let shape = model.shape
        else { return configuration }

        // Never push past what the model was trained for; quality collapses out there and
        // the banner is a better answer than a confidently broken load.
        let ceiling = min(Self.harnessContextFloor, shape.trainingContextLength)
        let planner = planner()

        for context in [16_384, 12_288, 8192]
        where context <= ceiling && context > configuration.contextLength {
            var candidate = configuration
            candidate.contextLength = context
            let plan = planner.plan(
                shape: shape, quantization: model.quantization,
                configuration: candidate, otherAppsInUse: memoryUsedByOtherApps
            )
            if plan.verdict == .comfortable { return candidate }
        }
        return configuration
    }

    /// What the harness's model picker and context budgeting should say about the loaded
    /// model. Without this it shows the bare provider id and assumes a 262K context.
    var advertisedModel: HarnessRuntime.AdvertisedModel {
        guard let loaded = loadedModel else { return HarnessRuntime.AdvertisedModel() }
        return HarnessRuntime.AdvertisedModel(
            name: "\(loaded.name) (\(loaded.quantization.rawValue))",
            contextLength: activeConfiguration?.contextLength
        )
    }

    /// Keeps the harness's provider entry describing the model actually being served. The
    /// harness re-reads its settings document per request, so this takes effect on the next
    /// message without a restart.
    func refreshHarnessProviderIfNeeded() {
        guard settings.chatEngine == .harness else { return }
        try? HarnessRuntime.ensureProviderConfigured(
            home: HarnessRuntime.homeDirectory,
            inferencePort: harnessPorts().inference,
            model: advertisedModel
        )
    }

    /// Swarm models used to be written into the harness settings as one provider per peer.
    /// The `silicon` plugin provider now lists them live from the gateway — every node
    /// model, loaded or not — so the old managed entries are retired on sight, with any
    /// saved default that referenced one rewritten to its gateway id first.
    func syncSwarmChatProviders() {
        guard settings.chatEngine == .harness else { return }
        try? HarnessRuntime.ensureSwarmProvidersRetired(home: HarnessRuntime.homeDirectory)
    }

    /// Starts the harness unless it is already running or on its way.
    public func startHarnessIfNeeded() {
        switch harnessState {
        case .ready, .starting: return
        case .idle, .failed, .stopping: break
        }

        let ports = harnessPorts()
        let runtime = harnessRuntime ?? HarnessRuntime()
        harnessRuntime = runtime
        harnessState = .starting(stage: "Looking for Node.js…")
        registerHarnessTermination()
        // The harness re-reads its settings per request, so polling the swarm now — in
        // parallel with its boot — has the peers' chat models in the picker by the time
        // anyone can type.
        Task { await refreshSwarm() }

        let nodePath = settings.nodeBinaryPath ?? ""
        let advertised = advertisedModel
        let gateway = gatewayPort()
        Task {
            await runtime.start(
                webPort: ports.web, inferencePort: ports.inference, nodePath: nodePath,
                advertising: advertised, gatewayPort: gateway, gatewayToken: gatewayToken
            ) { [weak self] state in
                Task { @MainActor in self?.harnessState = state }
            }
            let pid = await runtime.processIdentifier
            await MainActor.run { [weak self] in self?.harnessProcessID = pid }
        }
    }

    public func stopHarness() {
        guard let runtime = harnessRuntime else { return }
        harnessState = .stopping
        harnessProcessID = nil
        Task {
            await runtime.stop()
            await MainActor.run { [weak self] in self?.harnessState = .idle }
        }
    }

    public func restartHarness() {
        guard let runtime = harnessRuntime else { return startHarnessIfNeeded() }
        harnessState = .stopping
        harnessProcessID = nil
        Task {
            await runtime.stop()
            await MainActor.run { [weak self] in
                self?.harnessState = .idle
                self?.startHarnessIfNeeded()
            }
        }
    }

    // MARK: - Guardrails

    // TODO: screen the harness's tool calls through `JevGuardrails`. Everything needed is
    // here except one plugin, and this is what it would take.
    //
    // The harness *does* have an approval seam — `@deepseek-ai/dsh-user-approval`. A tool
    // that needs permission calls `ctx.approval.request(...)`, and the answer comes from
    // whichever plugin registered an `approval/request` waterfall listener; with no
    // answerer the request resolves `unavailable` and the call fails closed. The session
    // policy is `ask` or `never`, and `ask` is what routes through the seam.
    //
    // So the shape is clear: `Resources/dsh-llm-silicon` — the plugin this app already
    // vendors into the harness profile, today only a model provider — registers an
    // `approval/request` listener, calls this Mac's control API to have the call screened,
    // and maps the verdict onto `allowed-once` / `rejected`, leaving anything it cannot
    // decide to the harness's own permission UI. It would need a `POST /jev/guardrails/screen`
    // route beside the `GET /jev/guardrails/recent` this branch adds, taking the call and
    // returning the verdict, because the plugin runs in a Node process and cannot reach
    // `JevGuardrails` directly.
    //
    // What stops it being worth doing yet is the evidence, not the plumbing: the seam's own
    // documentation says the request carries the tool name, a reason and a call id, and
    // *not* the arguments. Eight of this guardrail's nine questions are about the arguments
    // — what path, what destination, whether the text came from a previous tool result — so
    // a screening from that seam would be Jev guessing from a tool's name. That is worse
    // than no verdict, because it would look like one. The harness also renders its own
    // conversation in a web view, so there is no card of ours to put the verdict on.
    //
    // Revisit when the seam carries arguments, or when the harness exposes the tool call
    // itself to a plugin the way Pi's `tool_call` event does.

    /// Reacts to the chat engine picker: a sidecar only runs while it is the chosen engine,
    /// and the chosen one starts as soon as the Chat tab is showing.
    public func chatEngineDidChange() {
        if settings.chatEngine != .harness { stopHarness() }
        if settings.chatEngine != .codex { stopCodex() }
        if settings.chatEngine != .qwenCode { stopQwen() }
        if settings.chatEngine != .pi { stopPi() }
        guard selectedTab == .chat else { return }
        switch settings.chatEngine {
        case .harness: startHarnessIfNeeded()
        case .codex: startCodexIfNeeded()
        case .qwenCode: startQwenIfNeeded()
        case .pi: startPiIfNeeded()
        case .legacy: break
        }
    }

    /// The harness is a child process; nothing kills it for us when the app exits. The
    /// termination notification arrives synchronously, so signal by pid rather than hoping a
    /// detached task outruns process exit.
    private func registerHarnessTermination() {
        guard !harnessTerminationRegistered else { return }
        harnessTerminationRegistered = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let pid = self?.harnessProcessID {
                    kill(pid, SIGTERM)
                }
            }
        }
    }
}
