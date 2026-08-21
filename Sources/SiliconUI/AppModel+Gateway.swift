import AppKit
import Foundation
import SiliconCatalog
import SiliconControl
import SiliconPlanner
import SiliconRuntime

/// The app side of the model gateway: the one server both external harnesses call to see
/// every model — local installs and swarm peers' offerings alike — and to have any of them
/// made ready on demand.
extension AppModel: GatewayHost {

    /// The gateway's stable loopback port. Persisted like the harness ports and for the same
    /// reason: the DeepSeek Harness plugin config and Codex provider config both carry the
    /// URL, and a port that drifted would strand them.
    func gatewayPort() -> Int {
        if let resolved = resolvedGatewayPort { return resolved }
        var port = settings.gatewayPort ?? 0
        if port == 0 || !HarnessRuntime.isPortFree(port) {
            port = HarnessRuntime.allocatePort()
        }
        if settings.gatewayPort != port {
            settings.gatewayPort = port
            settings.save()
        }
        resolvedGatewayPort = port
        return port
    }

    /// Starts the gateway at launch, next to the control server. Loopback only — the server
    /// itself enforces that — and token-free, matching the posture of the inference server
    /// it fronts.
    func startGatewayServer() {
        let supportDirectory = SwarmConfig.configURL.deletingLastPathComponent()
        let ledger = GatewayLedger(
            directory: supportDirectory,
            previews: settings.fleetPreviewsEnabled ?? true
        )
        gatewayLedger = ledger
        let server = GatewayServer(host: self, ledger: ledger)
        gatewayServer = server
        let port = gatewayPort()
        Task {
            do {
                try await server.start(preferredPort: port)
                // The well-known file local agents read instead of running lsof against
                // the app. No secrets in it — the gateway is loopback and token-free.
                GatewayDiscovery.write(
                    port: port,
                    pid: ProcessInfo.processInfo.processIdentifier,
                    version: Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                        as? String ?? "dev",
                    directory: supportDirectory
                )
            } catch {
                // Not fatal: the app works without external harnesses; they will report
                // the connection failure in their own words.
                libraryError = "Model gateway unavailable: \(error.localizedDescription)"
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            GatewayDiscovery.remove(directory: supportDirectory)
        }
    }

    // MARK: - GatewayHost

    public func gatewayModels() async -> [GatewayAPI.Model] {
        var models = gatewayModelSnapshot()
        let stats = await gatewayLedger?.stats() ?? [:]
        for index in models.indices {
            let id = models[index].id
            switch GatewayAPI.parseModelID(id) {
            case .local:
                // llama-server reads the nested kwargs form; Qwen also honors the
                // /no_think soft switch in the prompt.
                models[index].thinkingControls = ["chat_template_kwargs", "no_think"]
            case .node(let slug, _):
                // The node engine takes a top-level enable_thinking and 400s on
                // chat_template_kwargs — the gateway translates either way, but
                // callers deserve to know the native dialect.
                models[index].thinkingControls = ["enable_thinking"]
                if let peer = swarmPeers.first(where: {
                    GatewayAPI.peerSlug($0.name) == slug
                }) {
                    models[index].queueDepth = peer.queueDepth
                }
            case nil:
                break
            }
            if let stat = stats[id] {
                models[index].tokensPerSecond = stat.tokensPerSecond
                if stat.inFlight > 0 { models[index].pendingRequests = stat.inFlight }
            }
        }
        return models
    }

    /// The gateway's world view right now, also what the Codex model picker shows —
    /// one construction so the two can never disagree about ids.
    func gatewayModelSnapshot() -> [GatewayAPI.Model] {
        var models: [GatewayAPI.Model] = []
        let hidden = Set(settings.hiddenGatewayModels ?? [])

        for installed in installedModels
        where !hidden.contains(GatewayAPI.modelID(local: installed.id)) {
            let serving = loadedModel?.id == installed.id && runtimeState.isRunning
            models.append(GatewayAPI.Model(
                id: GatewayAPI.modelID(local: installed.id),
                // An em dash, not parentheses: Qwen Code's picker drops a parenthetical
                // suffix from the name, and two quantizations of one model then read as
                // identical twins. The dash form displays whole in every engine.
                displayName: "\(installed.name) — \(installed.quantization.rawValue)",
                where_: "This Mac",
                // A not-yet-loaded model advertises the context a gateway load will
                // actually give it (the agent floor), not its training maximum — a
                // harness that budgets against 128K while the load came up at 16K
                // would blow the window on its first long turn.
                contextWindow: serving
                    ? activeConfiguration?.contextLength
                    : installed.shape.map { min($0.trainingContextLength, Self.harnessContextFloor) },
                serving: serving,
                quantization: installed.quantization.rawValue
            ))
        }

        for peer in swarmPeers where peer.reachable {
            guard let llm = peer.llm, llm.installed else { continue }
            let slug = GatewayAPI.peerSlug(peer.name)
            // The serving name leads, and file spellings of the same model are folded into
            // it — nodes list "qwen3_8_27b.ninfer" but serve "qwen3.8-27b".
            var names: [String] = []
            if let current = llm.model { names.append(current) }
            for candidate in llm.availableModels
            where !names.contains(where: { GatewayAPI.modelNamesMatch($0, candidate) }) {
                names.append(candidate)
            }
            for name in names
            where !hidden.contains(GatewayAPI.modelID(peerSlug: slug, model: name)) {
                let serving = llm.running && llm.model == name
                models.append(GatewayAPI.Model(
                    id: GatewayAPI.modelID(peerSlug: slug, model: name),
                    displayName: "\(name) — \(peer.name)",
                    where_: peer.name,
                    contextWindow: serving ? llm.contextLength : nil,
                    serving: serving
                ))
            }
        }
        return models
    }

    public func gatewayEnsureReady(
        modelID: String, onStage: @escaping @Sendable (String) -> Void
    ) async throws -> GatewayReadyBackend {
        noteActivity()
        guard let parsed = GatewayAPI.parseModelID(modelID) else {
            throw GatewayHostError.unknownModel(modelID)
        }
        switch parsed {
        case .local(let installID):
            return try await ensureLocalReady(installID: installID, onStage: onStage)
        case .node(let peerSlug, let model):
            return try await ensureNodeReady(peerSlug: peerSlug, model: model, onStage: onStage)
        }
    }

    // MARK: - Local models

    private func ensureLocalReady(
        installID: String, onStage: @escaping @Sendable (String) -> Void
    ) async throws -> GatewayReadyBackend {
        guard let target = installedModels.first(where: { $0.id == installID }) else {
            throw GatewayHostError.unknownModel("local/\(installID)")
        }

        // Serialize gateway-triggered loads: two harness tabs asking for two models at once
        // must not fight over the runtime. Each caller chains its work after whatever is
        // already queued and cleans up its own slot — never a wait-and-recheck loop, which
        // spun the main actor forever when a caller vanished (client disconnect mid-load)
        // without clearing the shared slot, wedging the gateway and the UI with it.
        let previous = gatewayEnsureTask
        let task = Task { [weak self] in
            _ = await previous?.value
            _ = await self?.ensureLocalLoaded(target, onStage: onStage)
        }
        gatewayEnsureTask = task
        defer {
            if gatewayEnsureTask == task { gatewayEnsureTask = nil }
        }
        _ = await task.value

        guard loadedModel?.id == target.id, case .ready(let endpoint) = runtimeState,
              (activeConfiguration?.contextLength ?? 0) >= Self.harnessContextMinimum
        else {
            // The one refusal that is not a failure: a different model mid-answer must not
            // be swapped out from under whoever is using it.
            if runtimeState.isRunning, hasWorkInFlight, let busy = loadedModel {
                throw GatewayHostError.modelBusy(busy.name)
            }
            if agentConfiguration(for: target) == nil {
                throw GatewayHostError.contextWontFit(target.name)
            }
            throw GatewayHostError.loadFailed(target.name, runtimeState.label)
        }
        return GatewayReadyBackend(baseURL: endpoint, backendModel: installID)
    }

    private func ensureLocalLoaded(
        _ target: InstalledModel, onStage: @escaping @Sendable (String) -> Void
    ) async {
        // Someone else's load may be mid-flight; let it settle before judging.
        await waitForSettledRuntime()

        // Already serving is only good enough if the context can hold an agent
        // conversation — a 4K load answers the harness's very first message with
        // "exceeds the available context size", so it must be reloaded larger.
        if loadedModel?.id == target.id, runtimeState.isRunning,
           (activeConfiguration?.contextLength ?? 0) >= Self.harnessContextMinimum {
            return
        }

        // A model that is busy answering someone must not be swapped out from under them;
        // the caller turns this state into a "busy" error.
        if runtimeState.isRunning, hasWorkInFlight {
            return
        }

        guard let configuration = agentConfiguration(for: target) else {
            // Nothing agent-sized fits in memory right now; the caller reports it in words
            // rather than this loading a context that can never work.
            return
        }
        onStage("loading \(target.name) on this Mac — large models can take a minute or two")
        await loadAsync(target, configuration: configuration)
    }

    /// Waits for a load or unload already underway to finish, bounded so a wedged runtime
    /// cannot hold gateway requests hostage.
    private func waitForSettledRuntime() async {
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            switch runtimeState {
            case .starting, .stopping: try? await Task.sleep(for: .milliseconds(500))
            case .idle, .ready, .failed: return
            }
        }
    }

    // MARK: - Node models

    private func ensureNodeReady(
        peerSlug: String, model: String, onStage: @escaping @Sendable (String) -> Void
    ) async throws -> GatewayReadyBackend {
        guard let peer = swarmPeers.first(where: {
            GatewayAPI.peerSlug($0.name) == peerSlug
        }) else {
            throw GatewayHostError.unknownPeer(peerSlug)
        }

        if let backend = Self.nodeBackend(peer: peer, model: model) { return backend }

        guard peer.reachable else {
            throw GatewayHostError.peerUnreachable(peer.name)
        }

        // A GPU job preempts the node's LLM on purpose — the card belongs to the render
        // until the queue drains, and the LLM restores itself a couple of minutes later.
        // Arbitration deserves an honest sentence, not a start attempt that stalls.
        if let depth = peer.queueDepth, depth > 0 {
            throw GatewayHostError.peerRendering(peer.name, queueDepth: depth)
        }

        onStage("starting \(model) on \(peer.name)")
        await setPeerLLM(peer, running: true, model: model)

        // The node reports through the swarm poll; watch it until the model answers.
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let current = swarmPeers.first(where: { $0.name == peer.name }) {
                if let backend = Self.nodeBackend(peer: current, model: model) { return backend }
                // The node chose to serve something else — a node that cannot pick ignores
                // the request. Saying so beats silently answering with the wrong model.
                if let llm = current.llm, llm.running, llm.healthy,
                   let served = llm.model, !GatewayAPI.modelNamesMatch(served, model) {
                    throw GatewayHostError.peerServingOther(peer.name, served: served)
                }
            }
            try? await Task.sleep(for: .seconds(3))
            await refreshSwarm()
        }
        throw GatewayHostError.peerStartTimedOut(peer.name, model: model)
    }

    private static func nodeBackend(peer: PeerStatus, model: String) -> GatewayReadyBackend? {
        guard let llm = peer.llm, llm.running, llm.healthy, let served = llm.model,
              GatewayAPI.modelNamesMatch(served, model),
              let base = llm.openAIBase.flatMap(URL.init(string:))
        else { return nil }
        // The peer's base already ends in /v1, and the request goes out under the engine's
        // own spelling of the name — engines 404 anything else.
        return GatewayReadyBackend(baseURL: base, backendModel: served)
    }

    // MARK: - Media for the chat surfaces

    public func gatewayMediaRoots() async -> [String] {
        [
            settings.resolvedVideoOutputDirectory.path,
            settings.resolvedImageOutputDirectory.path,
            settings.resolvedMeshOutputDirectory.path,
        ]
    }

    public func gatewayReveal(path: String) async {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    public func gatewayOpenMeshViewer() async {
        selectedTab = .threeD
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Swarm page controls

    /// Whether a gateway model is switched off for pickers and the gateway.
    func isGatewayModelHidden(_ id: String) -> Bool {
        settings.hiddenGatewayModels?.contains(id) ?? false
    }

    func setGatewayModel(_ id: String, hidden: Bool) {
        var set = Set(settings.hiddenGatewayModels ?? [])
        if hidden { set.insert(id) } else { set.remove(id) }
        settings.hiddenGatewayModels = set.isEmpty ? nil : set.sorted()
        settings.save()
    }

    /// One context-size choice for the Swarm page's preset menu, with the planner's
    /// verdict attached so sizes that cannot fit are offered disabled, not discovered
    /// broken.
    struct ContextChoice: Identifiable {
        var tokens: Int
        var fits: Bool
        var reason: String?
        var current: Bool
        var id: Int { tokens }
        var label: String { "\(tokens / 1024)K" }
    }

    static let swarmContextPresets = [8192, 12_288, 16_384, 24_576, 32_768, 49_152, 65_536]

    /// The preset menu for the local machine card: every size up to the model's
    /// training ceiling, judged against memory right now.
    func localContextChoices() -> [ContextChoice] {
        guard let loaded = loadedModel else { return [] }
        let active = activeConfiguration?.contextLength
        guard let shape = loaded.shape else {
            return Self.swarmContextPresets.map {
                ContextChoice(tokens: $0, fits: true, reason: nil, current: $0 == active)
            }
        }
        let planner = planner()
        var configuration = defaultConfiguration(for: loaded)
        return Self.swarmContextPresets
            .filter { $0 <= shape.trainingContextLength }
            .map { size in
                configuration.contextLength = size
                let verdict = planner.plan(
                    shape: shape, quantization: loaded.quantization,
                    configuration: configuration, otherAppsInUse: memoryUsedByOtherApps
                ).verdict
                return ContextChoice(
                    tokens: size,
                    fits: verdict.isUsable,
                    reason: verdict.isUsable ? nil : "needs more free memory",
                    current: size == active
                )
            }
    }

    /// Reloads the loaded model at a chosen context — the Swarm page's "make the
    /// window larger" without a trip through Models.
    func reloadLoadedModel(atContext tokens: Int) {
        guard let loaded = loadedModel else { return }
        var configuration = activeConfiguration ?? defaultConfiguration(for: loaded)
        configuration.contextLength = tokens
        Task { await loadAsync(loaded, configuration: configuration) }
    }

    /// Fires a one-line prompt through the gateway at a machine's serving model, so a
    /// human can prove the whole path — gateway, routing, backend — with one click.
    /// The request lands in the activity ledger like any other; the Swarm page is its
    /// own witness.
    func testMachine(gatewayModelID: String) async {
        struct Body: Encodable {
            var model: String
            var stream = false
            var max_tokens = 24
            var enable_thinking = false
            var messages: [[String: String]]
        }
        let body = Body(
            model: gatewayModelID,
            messages: [["role": "user", "content": "Reply with exactly: swarm test ok"]]
        )
        guard let encoded = try? JSONEncoder().encode(body),
              let url = URL(string: "http://127.0.0.1:\(gatewayPort())/v1/chat/completions")
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = encoded
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - Context for agents

    /// The load configuration a gateway request deserves, or nil when no agent-sized
    /// context fits in memory right now.
    ///
    /// Agent harnesses burn thousands of tokens on preamble and send twelve-thousand-token
    /// first messages; a load below the 8K minimum answers every request with "exceeds the
    /// available context size" and is worse than no load at all. So this escalates harder
    /// than the app's own picker: comfortable 16K if it exists, else the largest merely
    /// usable (tight) agent size, else a refusal the caller can put into words.
    func agentConfiguration(for model: InstalledModel) -> LoadConfiguration? {
        var configuration = defaultConfiguration(for: model)
        if configuration.contextLength >= Self.harnessContextFloor { return configuration }
        guard let shape = model.shape else {
            return configuration.contextLength >= Self.harnessContextMinimum
                ? configuration : nil
        }

        let ceiling = min(Self.harnessContextFloor, shape.trainingContextLength)
        let planner = planner()
        func verdict(_ context: Int) -> MemoryPlan.Verdict {
            var candidate = configuration
            candidate.contextLength = context
            return planner.plan(
                shape: shape, quantization: model.quantization,
                configuration: candidate, otherAppsInUse: memoryUsedByOtherApps
            ).verdict
        }

        let sizes = [16_384, 12_288, 8192].filter {
            $0 <= ceiling && $0 > configuration.contextLength
        }
        if let comfortable = sizes.first(where: { verdict($0) == .comfortable }) {
            configuration.contextLength = comfortable
            return configuration
        }
        if let usable = sizes.first(where: { verdict($0).isUsable }) {
            configuration.contextLength = usable
            return configuration
        }
        return configuration.contextLength >= Self.harnessContextMinimum ? configuration : nil
    }
}

enum GatewayHostError: Error, LocalizedError, GatewayWaitableError {
    case unknownModel(String)
    case unknownPeer(String)
    case peerUnreachable(String)
    case peerServingOther(String, served: String)
    case peerStartTimedOut(String, model: String)
    case loadFailed(String, String)
    case modelBusy(String)
    case contextWontFit(String)
    case peerRendering(String, queueDepth: Int)

    /// The states a caller's X-Silicon-Wait budget may sit out: machines that are
    /// occupied, not machines that are wrong.
    var isWaitable: Bool {
        switch self {
        case .peerRendering, .modelBusy: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .unknownModel(let id):
            "No model called \(id) is installed here or offered by a node."
        case .unknownPeer(let slug):
            "No node called \(slug) is in the swarm registry."
        case .peerUnreachable(let name):
            "\(name) is not reachable right now."
        case .peerServingOther(let name, let served):
            "\(name) started \(served) instead — it may not support choosing a model remotely."
        case .peerStartTimedOut(let name, let model):
            "\(name) did not bring \(model) up within three minutes."
        case .loadFailed(let name, let state):
            "Could not load \(name): \(state)"
        case .modelBusy(let name):
            "\(name) is busy answering right now; try again when it finishes, or send "
            + "an X-Silicon-Wait: 180 header to wait in line."
        case .contextWontFit(let name):
            "Agent chat needs \(name) loaded with at least an 8K context, and there isn't "
            + "enough free memory for that right now. Close some apps and try again."
        case .peerRendering(let name, let depth):
            "\(name)'s GPU is rendering (\(depth) job\(depth == 1 ? "" : "s") queued); "
            + "its chat model comes back about two minutes after the queue drains — "
            + "roughly \(depth * 2) minutes from now. Retry then, or send an "
            + "X-Silicon-Wait: \(min(depth * 150, 600)) header to wait it out."
        }
    }
}
