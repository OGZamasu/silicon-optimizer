import Foundation
import SiliconCatalog
import SiliconControl
import SiliconCore
import SiliconHardware
import SiliconPlanner
import SiliconRuntime

/// Exposes the app over its local control API, so the MCP bridge — and therefore Claude and
/// ChatGPT — can use the model that is already loaded.
extension AppModel: ControlHost {

    // MARK: - Read

    public func profile() async -> ControlAPI.Profile {
        // Bound to a local so the name unambiguously means the property, not this method.
        let hardware = self.profile
        return ControlAPI.Profile(
            chip: hardware.chipName,
            generation: hardware.generation.displayName,
            totalMemoryBytes: hardware.totalMemory.rawValue,
            modelBudgetBytes: hardware.safeModelBudget.rawValue,
            performanceCores: hardware.performanceCores,
            efficiencyCores: hardware.efficiencyCores,
            gpuCores: hardware.gpuCores,
            neuralEngineCores: hardware.neuralEngineCores,
            memoryBandwidthGBps: hardware.memoryBandwidthGBps,
            diskFreeBytes: hardware.diskFree.rawValue
        )
    }

    public func metrics() async -> ControlAPI.Metrics {
        let sample = self.metrics
        return ControlAPI.Metrics(
            memoryUsedBytes: sample.memoryUsed.rawValue,
            memoryWiredBytes: sample.memoryWired.rawValue,
            memoryTotalBytes: sample.memoryTotal.rawValue,
            swapUsedBytes: sample.swapUsed.rawValue,
            gpuUtilization: sample.gpuUtilization,
            cpuUtilization: sample.cpuUtilization,
            memoryPressure: sample.memoryPressure.label
        )
    }

    public func status() async -> ControlAPI.Status {
        ControlAPI.Status(
            state: runtimeState.label,
            loadedModelID: loadedModel?.id,
            loadedModelName: loadedModel?.name,
            contextLength: activeConfiguration?.contextLength,
            expertStreaming: activeConfiguration?.expertStreaming != nil,
            lastGenerationTokensPerSecond: lastGeneration?.generationTokensPerSecond,
            activity: activeGenerationSummary,
            failure: Self.failedLoadDetail(
                state: runtimeState, recorded: LoadFailureRecorder.shared.last
            )
        )
    }

    /// Whether a load that ended in this error is one to put in front of the owner.
    ///
    /// A load that was replaced belongs to the load that replaced it — its progress line is
    /// the true one, and stamping a failure over it would replace a fact with a leftover.
    /// An unload part-way through a load is the owner getting exactly what they asked for,
    /// and answering that with an error dialog is the app arguing with them.
    ///
    /// Here rather than inline in `loadAsync` so the rule can be tested: it is the whole
    /// difference between "your model failed" and "you loaded something else".
    static func showsFailure(for error: any Error) -> Bool {
        (error as? RuntimeError)?.wasInterrupted != true
    }

    /// The structured account of the load that produced this state line, or nothing.
    ///
    /// Two conditions, both necessary. The app has to be *in* a failed state — a recorded
    /// failure beside a model that is loading happily is a lie about the present. And the
    /// recorded failure has to be the one the state line came from: the app's own catch sets
    /// the state to the error's description, which is the failure's summary, so equal
    /// sentences mean the detail belongs to the line a client is showing. A load that failed
    /// somewhere the runtime never reached — no such model, a plan the selector refused —
    /// has a state line and no detail, which is the honest answer rather than the previous
    /// failure's log.
    ///
    /// Static and pure so that rule can be tested. Both halves of it are a promise to a
    /// client, and a promise nothing checks is one the next edit gets to break quietly.
    static func failedLoadDetail(
        state: RuntimeState, recorded: LoadFailure?
    ) -> ControlAPI.LoadFailure? {
        guard case .failed = state else { return nil }
        guard let recorded, recorded.summary == state.label else { return nil }
        return recorded.wire
    }

    public func installed() async -> [ControlAPI.InstalledModel] {
        installedModels.map { model in
            ControlAPI.InstalledModel(
                id: model.id,
                name: model.name,
                quantization: model.quantization.rawValue,
                sizeOnDiskBytes: model.sizeOnDisk.rawValue,
                isLoaded: loadedModel?.id == model.id,
                supportsVision: model.supportsVision
            )
        }
    }

    public func catalog(category: String?, onlyRunnable: Bool) async -> [ControlAPI.CatalogModel] {
        let filter = category.flatMap { ModelCategory(rawValue: $0) }
        let configurator = autoConfigurator()
        return ModelCatalog.all
            .filter { filter == nil || $0.category == filter }
            .map { entry in
                describe(
                    entry,
                    recommendation: configurator.best(
                        for: entry, otherAppsInUse: memoryUsedByOtherApps
                    )
                )
            }
            .filter { !onlyRunnable || $0.recommendation != nil }
            // Runnable models first, then by editorial rating.
            .sorted { lhs, rhs in
                let lhsRunnable = lhs.recommendation != nil
                let rhsRunnable = rhs.recommendation != nil
                if lhsRunnable != rhsRunnable { return lhsRunnable }
                if lhs.featured != rhs.featured { return lhs.featured == true }
                return lhs.rating > rhs.rating
            }
    }

    /// The strongest model this Mac can run — and, when the caller says what the job is,
    /// the strongest model *for that job*.
    ///
    /// Hardware fit is computed first either way, because it is what decides which models
    /// are candidates at all: a model that will not run here cannot be recommended for
    /// anything, and the ranking it produces is the fallback whenever Jev is off, has no
    /// key, is out of budget, or fails. A task with the feature disabled is answered exactly
    /// as it was before this existed, and costs nothing.
    public func recommend(category: String?, task: String?) async -> ControlAPI.CatalogModel? {
        let filter = category.flatMap { ModelCategory(rawValue: $0) }
        let pool = filter.map { wanted in ModelCatalog.all.filter { $0.category == wanted } }
            ?? ModelCatalog.all.filter { $0.category != .embedding }
        let ranked = autoConfigurator().rank(
            catalog: pool, otherAppsInUse: memoryUsedByOtherApps
        )
        guard let pick = ranked.first else { return nil }

        guard let job = RecommendationQuestions.trimmedTask(task) else {
            return describe(pick.entry, recommendation: pick)
        }
        await JevBootstrap.ready()
        guard await DecisionRouter.shared.canAnswer(.recommendation) else {
            return describe(pick.entry, recommendation: pick)
        }
        guard let answer = await taskRanking(job, over: ranked) else {
            return describe(pick.entry, recommendation: pick)
        }
        return answer
    }

    /// Asks Jev what the job needs, applies `RecommendationPolicy`, and turns the top three
    /// into one answer with its runners-up attached.
    ///
    /// Returns nil — rather than throwing — on any failure. A recommendation is advice; an
    /// expired budget, a 500 from TypeSafe or a question id that no longer matches should
    /// leave the caller with the hardware-fit answer, not with an error where a model name
    /// was expected.
    private func taskRanking(
        _ job: (text: String, truncated: Bool), over ranked: [AutoConfigurator.Recommendation]
    ) async -> ControlAPI.CatalogModel? {
        // Fit order first, then the reservations, so a job that needs to see is offered
        // something that can even on a Mac whose sixteen best fits are all text models.
        let all = ranked.map {
            RecommendationCandidate(
                entry: $0.entry, recommendation: $0,
                isInstalled: isInstalled($0.entry, quantization: $0.quantization)
            )
        }
        let candidates = RecommendationQuestions.shortlist(from: all)
        guard !candidates.isEmpty else { return nil }

        let byID = Dictionary(ranked.map { ($0.entry.id, $0) }, uniquingKeysWith: { a, _ in a })
        let fitScores = RecommendationPolicy.normalizedFit(
            Dictionary(
                candidates.compactMap { candidate in
                    byID[candidate.id].map { (candidate.id, $0.score) }
                },
                uniquingKeysWith: max
            )
        )

        let outcome: RecommendationPolicy.Outcome
        do {
            let answers = try await RecommendationQuestions.ask(
                task: job.text, candidates: candidates
            )
            outcome = try RecommendationPolicy.rank(
                answers: answers, candidates: candidates, fitScores: fitScores
            )
        } catch {
            return nil
        }

        let described: [ControlAPI.CatalogModel] = outcome.ranked.compactMap { place in
            guard let fit = byID[place.id] else { return nil }
            var model = describe(fit.entry, recommendation: fit)
            model.reason = place.reason
            return model
        }
        guard var best = described.first else { return nil }

        var notes = outcome.notes
        if job.truncated {
            // Said rather than swallowed: a six-page description was judged on its first
            // four kilobytes, and somebody wondering why the answer ignored the last page
            // should be told the last page was never sent.
            notes.append(
                "The description was trimmed to "
                + "\(RecommendationQuestions.maximumTaskBytes / 1024) KB before it was sent."
            )
        }
        best.note = notes.isEmpty ? nil : notes.joined(separator: " ")
        best.followedJev = outcome.followedJev
        best.alternatives = Array(described.dropFirst())
        return best
    }

    // MARK: - Plan

    public func plan(_ request: ControlAPI.PlanRequest) async throws -> ControlAPI.Plan {
        guard let entry = ModelCatalog.entry(id: request.modelID) else {
            throw ControlHostError.unknownModel(request.modelID)
        }
        let contextLength = request.contextLength ?? 8192
        guard contextLength >= 1, entry.maxContext >= 1, contextLength <= entry.maxContext else {
            throw ControlHostError.badRequest(
                "Context length must be between 1 and \(entry.maxContext) tokens for "
                    + "\(entry.name)."
            )
        }
        let quantization = request.quantization
            .flatMap { Quantization(rawValue: $0) }
            ?? autoConfigurator().best(for: entry, otherAppsInUse: memoryUsedByOtherApps)?.quantization
            ?? .q4_K_M

        var configuration = LoadConfiguration(
            contextLength: contextLength,
            kvCachePrecision: request.kvCachePrecision
                .flatMap { KVCachePrecision(rawValue: $0) } ?? .f16,
            flashAttention: request.flashAttention ?? true,
            threads: profile.performanceCores
        )
        if let slots = request.expertSlots {
            guard let moe = entry.shape.moe, slots >= 1, moe.expertCount >= 1,
                  slots <= moe.expertCount else {
                throw ControlHostError.badRequest(
                    "Expert slots must be between 1 and the model's expert count."
                )
            }
            configuration.expertStreaming = ExpertStreamingConfiguration(slotCount: slots)
            configuration.microBatchSize = ExpertStreamingConfiguration.maximumMicroBatch(
                slotCount: slots, expertsUsedPerToken: moe.expertsUsedPerToken
            )
            configuration.batchSize = max(configuration.microBatchSize, 256)
        }

        return describe(plan(for: entry, quantization: quantization, configuration: configuration))
    }

    // MARK: - Act

    public func install(_ request: ControlAPI.LoadRequest) async throws -> String {
        guard let entry = ModelCatalog.entry(id: request.modelID) else {
            throw ControlHostError.unknownModel(request.modelID)
        }
        let quantization = request.quantization
            .flatMap { Quantization(rawValue: $0) }
            ?? autoConfigurator().best(for: entry, otherAppsInUse: memoryUsedByOtherApps)?.quantization
            ?? .q4_K_M

        guard !isInstalled(entry, quantization: quantization) else {
            if quantization.needsPrismRuntime && !hasPrismTernaryRuntime {
                installPrismRuntime()
                return "\(entry.name) (\(quantization.rawValue)) is already installed. "
                    + "Fetching its reviewed PrismML runtime; progress is shown in the app."
            }
            return "\(entry.name) (\(quantization.rawValue)) is already installed."
        }

        // Preflight before claiming the download has begun. The transfer runs detached, so a
        // disk-space failure inside it would surface only in the app window while the caller
        // had already been told "downloading now".
        // An external folder when asked — the same "Download to…" the browser offers, so an
        // agent can keep a 6 GB file off a nearly full startup volume. Otherwise the volume
        // that will actually take the download: the configured library folder, which used
        // to be ignored here, so a full startup disk refused downloads bound for a 3 TB one.
        let saveTo = request.directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let projectorAllowance = entry.capabilities.contains(.vision) ? Bytes.gib(2) : .zero
        try ModelDownloader.checkDiskSpace(
            needed: (entry.variant(for: quantization)?.downloadSize ?? .zero) + projectorAllowance,
            at: saveTo ?? settings.resolvedModelLibraryDirectory ?? ModelLibrary.defaultRoot
        )

        install(entry, quantization: quantization, saveTo: saveTo)
        let size = entry.variant(for: quantization)?.downloadSize.formatted ?? "unknown size"
        return "Started downloading \(entry.name) (\(quantization.rawValue), \(size)). "
            + "Progress is shown in the app."
    }

    public func load(_ request: ControlAPI.LoadRequest) async throws -> ControlAPI.Status {
        let target: InstalledModel
        if let match = installedModels.first(where: { $0.id == request.modelID }) {
            target = match
        } else if let quantization = request.quantization.flatMap({ Quantization(rawValue: $0) }),
                  let match = installedModels.first(where: {
                      $0.catalogID == request.modelID && $0.quantization == quantization
                  }) {
            target = match
        } else if let match = installedModels.first(where: { $0.catalogID == request.modelID }) {
            target = match
        } else {
            throw ControlHostError.notInstalled(request.modelID)
        }

        let configuration = try controlLoadConfiguration(for: target, request: request)
        await loadAsync(target, configuration: configuration)
        guard runtimeState.isRunning else {
            throw ControlHostError.loadFailed(runtimeState.label)
        }
        return await status()
    }

    /// Resolve defaults after validating the caller's actual context. Keeping this separate
    /// from process launch lets the control path's load policy be checked without a model file.
    func controlLoadConfiguration(
        for target: InstalledModel, request: ControlAPI.LoadRequest
    ) throws -> LoadConfiguration {
        if let context = request.contextLength {
            let catalogMaximum = target.catalogID.flatMap(ModelCatalog.entry(id:))?.maxContext
            let maximum = catalogMaximum ?? target.shape?.trainingContextLength ?? 1_048_576
            guard context >= 1, maximum >= 1, context <= maximum else {
                throw ControlHostError.badRequest(
                    "Context length must be between 1 and \(maximum) tokens for this model."
                )
            }
        }
        var configuration = defaultConfiguration(
            for: target, contextLength: request.contextLength
        )
        if let slots = request.expertSlots {
            guard let moe = target.shape?.moe, slots >= 1, moe.expertCount >= 1,
                  slots <= moe.expertCount else {
                throw ControlHostError.badRequest(
                    "Expert slots must be between 1 and the model's expert count."
                )
            }
            configuration.expertStreaming = ExpertStreamingConfiguration(slotCount: slots)
            configuration.microBatchSize = ExpertStreamingConfiguration.maximumMicroBatch(
                slotCount: slots, expertsUsedPerToken: moe.expertsUsedPerToken
            )
            configuration.batchSize = max(configuration.microBatchSize, 256)
        }

        return configuration
    }

    // `unload()` is not implemented here: AppModel's own method already satisfies the
    // protocol requirement, and redeclaring it would recurse.

    public func chat(_ request: ControlAPI.ChatRequest) async throws -> ControlAPI.ChatResponse {
        guard let runtime = activeRuntime, runtimeState.isRunning else {
            throw ControlHostError.noModelLoaded
        }

        let messages = request.messages.map { message in
            ChatMessage(
                role: ChatMessage.Role(rawValue: message.role) ?? .user,
                content: message.content,
                images: message.images
            )
        }
        let chatRequest = ChatRequest(
            messages: messages,
            temperature: request.temperature ?? settings.temperature,
            topP: settings.topP,
            maxTokens: request.maxTokens ?? (settings.maxTokens > 0 ? settings.maxTokens : nil),
            reasoningEffort: settings.reasoningEffort.isEmpty ? nil : settings.reasoningEffort
        )

        // MCP tool calls are request/response, so the stream is collected before returning.
        // `whileGenerating` is what makes that visible: there is no `generationTask` on this
        // path, so without it a long answer reads as idleness and the idle timer unloads the
        // model — or the Mac sleeps — halfway through writing it.
        var content = ""
        var reasoning = ""
        var metrics = GenerationMetrics()
        try await whileGenerating {
            for try await event in try await runtime.chat(chatRequest) {
                switch event {
                case .token(let token): content += token
                case .reasoningToken(let token): reasoning += token
                case .finished(let final): metrics = final
                }
            }
        }
        lastGeneration = metrics

        // Verification, and — when the policy says so — a stronger model's answer instead.
        //
        // This path can escalate where the streaming ones cannot: it has shown the caller
        // nothing yet, so replacing the reply costs nobody a message they were reading.
        // Truncation is read from the runtime's own finish reason against the budget this
        // request actually sent, never asked of a model.
        //
        // Inside `whileGenerating` like the generation above it, and for the same reason:
        // an escalation to a cold cloud model is seconds of no local activity at all, and
        // the idle timer would happily unload the model — or let the Mac sleep — in the
        // middle of a request that is still being answered.
        let outcome = await whileGenerating {
            await self.verify(
                prompt: VerificationPrompt(messages: request.messages),
                reply: content,
                truncated: metrics.wasTruncated(budget: chatRequest.maxTokens)
            )
        }
        var answer = content
        var thinking = reasoning
        var reported = metrics
        if case .escalated(_, let better, _, _) = outcome {
            answer = better
            // The local model's chain of thought is not the escalated answer's, and its
            // throughput describes text this response no longer contains. Returning either
            // beside a reply another model wrote would be a plain untruth about where the
            // answer came from — so both are dropped, and `verification.escalatedTo` says
            // who did write it.
            thinking = ""
            reported = GenerationMetrics()
        }

        return ControlAPI.ChatResponse(
            content: answer,
            reasoning: thinking.isEmpty ? nil : thinking,
            promptTokens: reported.promptTokens,
            generatedTokens: reported.generatedTokens,
            tokensPerSecond: reported.generationTokensPerSecond,
            verification: outcome.verdictName.map {
                ControlAPI.ChatVerdict(
                    verdict: $0, reasons: outcome.reasons,
                    escalatedTo: outcome.escalatedTo, suggestion: outcome.suggestion
                )
            }
        )
    }

    /// Who answers a decision.
    ///
    /// `auto` is a **cascade**, not a fallback. The model loaded here answers first — nothing
    /// leaves the Mac and there is nothing to pay — and then, per question, only the answers
    /// it was not sure of are put to Jev. What counts as "not sure" is the calibration's
    /// business: `POST /jev/calibrate` measures where this model's confidence stops
    /// predicting Jev's verdict, and the cascade thresholds there. With no model loaded there
    /// is nothing to cascade from and `auto` is the old fallback; with Jev unavailable there
    /// is nothing to cascade to and it is the local lane, unchanged.
    ///
    /// Naming a lane makes it a hard requirement instead, and skips the cascade in both
    /// directions: `local` never pays, `typesafe` never asks the model here.
    public func decide(_ request: ControlAPI.DecideRequest) async throws -> ControlAPI.DecideResponse {
        try request.validate()
        let provider = (request.provider ?? "auto").lowercased()
        var localEndpoint: URL?
        if case .ready(let endpoint) = runtimeState { localEndpoint = endpoint }

        func oneToken(
            _ asked: ControlAPI.DecideRequest = request
        ) async throws -> ControlAPI.DecideResponse {
            guard let endpoint = localEndpoint, let loaded = loadedModel else {
                throw ControlHostError.noModelLoaded
            }
            noteActivity()
            let decider = LocalDecider(endpoint: endpoint, modelName: loaded.name)
            return try await whileGenerating { try await decider.decide(asked) }
        }

        /// The free half of the cascade, and of `provider: "local"`.
        ///
        /// "Local" used to have exactly one meaning — the loaded chat model, read one token
        /// deep — and now has three. The best of them answers: Laya if it is installed,
        /// because it is a decision model where the one-token reading is an approximation
        /// of one; then a swarm node, which costs nothing either; then the loaded model,
        /// which is what this always was and still is on a Mac with nothing installed.
        ///
        /// Nothing about the *shape* changes: the response is the same type, `provider`
        /// says which of the three answered, and a caller that only ever looked at
        /// `answers` cannot tell the difference.
        func local(
            _ asked: ControlAPI.DecideRequest = request
        ) async throws -> ControlAPI.DecideResponse {
            guard let lane = await DecisionRouter.shared.localLane(for: .decideTool),
                  lane != .oneToken
            else { return try await oneToken(asked) }
            do {
                return try await DecisionRouter.shared.ask(
                    lane: lane, feature: .decideTool,
                    state: asked.state, questions: asked.questions
                )
            } catch {
                // A lane that was ready a moment ago and is not now — a sidecar that died,
                // a node that went to sleep. The loaded model is still here, and an answer
                // from it beats a failed decision.
                guard localEndpoint != nil else { throw error }
                return try await oneToken(asked)
            }
        }
        func typeSafe() async throws -> ControlAPI.DecideResponse {
            // Waited on rather than assumed: a request arriving in the first milliseconds of
            // launch must not be told there is no key on a Mac that has one.
            await JevBootstrap.ready()
            return try await Self.decideViaTypeSafe(request)
        }

        switch provider {
        case "local": return try await local()
        case "typesafe": return try await typeSafe()
        // Named outright, which skips the policy: "answer with Laya" rather than "answer
        // with whatever is best", which is what a test bench and a comparison need.
        case "laya", "node":
            guard let lane = DecisionLaneID.named(provider) else {
                throw ControlHostError.badRequest(
                    ControlAPI.DecisionLaneVocabulary.unknownLane(provider)
                )
            }
            return try await DecisionRouter.shared.ask(
                lane: lane, feature: .decideTool,
                state: request.state, questions: request.questions
            )
        case "auto":
            // With nothing free to cascade *from*, `auto` is a single lane and the policy
            // picks it: Jev when the owner has turned it on and keyed it, otherwise Laya,
            // otherwise a node. Only when none of those exists is there nothing to say.
            let free = await DecisionRouter.shared.localLane(for: .decideTool)
            guard localEndpoint != nil || free != nil else {
                await JevBootstrap.ready()
                if await JevService.shared.isAvailable(.decideTool) { return try await typeSafe() }
                throw ControlHostError.badRequest(
                    "Nothing can decide yet: install Laya in Settings → Decisions, load a "
                    + "model, or add a TypeSafe API key and turn on the decide tool."
                )
            }
            // The floors belonging to the lane that is about to answer the free pass,
            // not to "the local lane" as if there were only one of them.
            let floors = await cascadeFloors(for: free ?? .oneToken)
            return try await DecisionCascade.run(
                request,
                floors: floors,
                // Asked only once the local answers are in and at least one of them was
                // uncertain, so a confident run never reads the settings file — and the
                // Keychain is not touched until a request is actually about to be sent.
                jevAvailable: {
                    await JevBootstrap.ready()
                    return await Self.cascadeMayEscalate()
                },
                local: { try await local($0) },
                jev: { try await Self.escalate($0) }
            )
        default:
            throw ControlHostError.badRequest(
                "Unknown provider \"\(request.provider ?? "")\". "
                + "Use auto, local, laya, node or typesafe."
            )
        }
    }

    /// Whether `auto` may pay Jev for an answer this machine was unsure of.
    ///
    /// Two switches, both of them the owner's, and the order matters.
    ///
    /// **Decide tool** is the switch that governs ongoing `/decide` spending. Turning it off
    /// has to stop every penny of it — including a chat-scope phone's, which reaches this
    /// same code through `POST /decide` — so it is checked first and it is what the
    /// escalation is billed to. Its budget, its cache and its ledger line all apply.
    ///
    /// **Decision calibration** is what turns the old fallback into a cascade at all. With
    /// it off, `auto` is the single lane it has always been, whatever the decide tool says.
    ///
    /// A free function rather than a closure inside `decide` so a test can hold the gate and
    /// the ledger it writes to, which is the only way to prove that turning the first switch
    /// off actually stops the spending.
    static func cascadeMayEscalate(_ service: JevService = .shared) async -> Bool {
        guard await service.isAvailable(.decideTool) else { return false }
        return await service.settings().isOn(.calibration)
    }

    /// The `typesafe` lane: the request put to Jev, billed to the decide tool.
    ///
    /// Through the one door rather than straight at `SystemOneClient`: the decide tool is a
    /// Jev feature like any other, so it obeys the same master switch, model pin, size
    /// limit, budget, cache and ledger as the rest. The Keychain is consulted inside, at
    /// the moment a request is sent — a refusal by any of those checks never touches it.
    ///
    /// `request.model` is deliberately dropped: the version is the owner's choice, pinned
    /// in Settings, and a tool call should not be able to move this Mac onto an alias
    /// whose answers the thresholds were never tuned against.
    ///
    /// A free function with the service as a parameter, like `cascadeMayEscalate`, and for
    /// the same reason: `decide` cannot be driven by a test, and the ledger line this bills
    /// is the whole point of the lane. Inlined in `decide`, a mutation that billed it to
    /// `.calibration` survived the suite — the only billing test could reach `escalate`.
    static func decideViaTypeSafe(
        _ request: ControlAPI.DecideRequest, using service: JevService = .shared
    ) async throws -> ControlAPI.DecideResponse {
        try await service.ask(
            .decideTool, state: request.state, questions: request.questions
        )
    }

    /// The escalation itself: the `typesafe` lane over the questions the local model was
    /// unsure of, so it is billed to the decide tool.
    ///
    /// Not to `.calibration`: that line is for calibration runs, and an owner reading the
    /// ledger to find out what `decide` costs should find it under the decide tool. Gating
    /// on one feature and spending another's budget would also mean a decide-tool budget
    /// that `/decide` could spend past.
    static func escalate(
        _ request: ControlAPI.DecideRequest, using service: JevService = .shared
    ) async throws -> ControlAPI.DecideResponse {
        try await decideViaTypeSafe(request, using: service)
    }

    public func benchmark() async throws -> ControlAPI.BenchmarkResult {
        guard let runtime = activeRuntime, runtimeState.isRunning,
              let loaded = loadedModel, let shape = loaded.shape,
              let configuration = activeConfiguration
        else { throw ControlHostError.noModelLoaded }

        noteActivity()
        let plan = planner().plan(
            shape: shape, quantization: loaded.quantization,
            configuration: configuration, otherAppsInUse: memoryUsedByOtherApps
        )
        // Predict uncalibrated, so the benchmark measures the model rather than grading a
        // previous benchmark's correction.
        let predicted = SpeedEstimator(profile: profile).estimate(
            shape: shape, quantization: loaded.quantization,
            configuration: configuration, plan: plan
        )

        benchmarkPhase = .warmup
        defer { benchmarkPhase = nil }

        let report = try await BenchmarkRunner(runtime: runtime).run(
            model: loaded, configuration: configuration, predicted: predicted
        ) { phase in
            Task { @MainActor in self.benchmarkPhase = phase }
        }

        let analyzer = BenchmarkAnalyzer()
        let findings = analyzer.findings(
            for: report, configuration: configuration, model: loaded
        )
        benchmarkReport = report
        benchmarkFindings = findings
        let key = loaded.catalogID ?? loaded.id
        settings.speedCalibrations[key] = analyzer.calibration(from: report)
        settings.save()
        noteActivity()

        return ControlAPI.BenchmarkResult(
            modelName: report.modelName,
            score: report.score,
            grade: report.grade,
            generationTokensPerSecond: report.shortPromptGeneration,
            promptTokensPerSecond: report.longPromptPrefill,
            timeToFirstToken: report.timeToFirstToken,
            longContextFalloff: report.longContextFalloff,
            predictedGenerationTokensPerSecond: report.predictedGeneration,
            calibration: settings.speedCalibrations[key] ?? 1.0,
            findings: findings.map {
                .init(title: $0.title, detail: $0.detail, severity: $0.severity.rawValue)
            }
        )
    }

    // MARK: - Mapping

    private func describe(
        _ entry: ModelEntry, recommendation: AutoConfigurator.Recommendation?
    ) -> ControlAPI.CatalogModel {
        ControlAPI.CatalogModel(
            id: entry.id,
            name: entry.name,
            author: entry.author,
            license: entry.license,
            summary: entry.summary,
            category: entry.category.rawValue,
            parameters: entry.parameterLabel,
            activeParameters: entry.activeParameterLabel,
            isMoE: entry.isMoE,
            capabilities: entry.capabilities.labels.map(\.0),
            rating: entry.rating,
            maxContext: entry.maxContext,
            quantizations: entry.variants.map(\.quantization.rawValue),
            recommendation: recommendation.map { recommendation in
                ControlAPI.Recommendation(
                    quantization: recommendation.quantization.rawValue,
                    contextLength: recommendation.configuration.contextLength,
                    expertSlots: recommendation.configuration.expertStreaming?.slotCount,
                    estimatedGenerationTokensPerSecond:
                        recommendation.speed.generationTokensPerSecond,
                    estimatedPromptTokensPerSecond: recommendation.speed.prefillTokensPerSecond,
                    downloadBytes: entry.variant(for: recommendation.quantization)?
                        .downloadSize.rawValue ?? 0,
                    plan: describe(recommendation.plan),
                    rationale: recommendation.rationale
                )
            },
            featured: entry.isFeatured,
            runtimeNote: runtimeNote(for: entry)
        )
    }

    /// What an agent needs to know before installing: whether the runtime this entry
    /// needs is actually here.
    private func runtimeNote(for entry: ModelEntry) -> String? {
        guard entry.needsPrismRuntime else { return nil }
        if hasPrismTernaryRuntime {
            return "PrismML's llama.cpp fork is installed; this build reads the format."
        }
        if let install = prismRuntimeInstall {
            return install.error.map {
                "Fetching PrismML's llama.cpp fork failed: \($0) — install_model retries it."
            } ?? "Fetching PrismML's llama.cpp fork now: \(install.stage)."
        }
        return "Needs PrismML's llama.cpp fork (a 12 MB download); install_model fetches it "
            + "alongside the weights, or set a fork build's path in Settings › Advanced."
    }

    private func describe(_ plan: MemoryPlan) -> ControlAPI.Plan {
        ControlAPI.Plan(
            verdict: plan.verdict.label,
            residentBytes: plan.resident.rawValue,
            budgetBytes: plan.budget.rawValue,
            weightsBytes: plan.nonExpertWeights.rawValue,
            expertsBytes: plan.expertWeights.rawValue,
            kvCacheBytes: plan.kvCache.rawValue,
            computeBytes: plan.computeBuffers.rawValue,
            streamedFromDiskBytes: plan.streamedFromDisk.rawValue,
            suggestions: plan.remediations.map {
                ControlAPI.Suggestion(
                    title: $0.title, detail: $0.detail,
                    savingBytes: $0.saving.rawValue, cost: $0.cost
                )
            },
            notes: plan.notes
        )
    }
}

public enum ControlHostError: Error, LocalizedError, ControlStatusError {
    case unknownModel(String)
    case notInstalled(String)
    case noModelLoaded
    case loadFailed(String)
    case badRequest(String)
    /// The Mac is already doing this, and doing it twice would be worse than waiting.
    case busy(String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id):
            "No model with id '\(id)' in the catalog. Use list_models to see valid ids."
        case .notInstalled(let id):
            "'\(id)' is not installed. Use install_model first."
        case .noModelLoaded:
            "No model is loaded. Use load_model first."
        case .loadFailed(let reason):
            "The model failed to load: \(reason)"
        case .badRequest(let reason):
            reason
        case .busy(let reason):
            reason
        }
    }

    /// Everything here is "you asked wrong", which is a 400 — except being told to come back
    /// later, which a caller can act on and a 400 gives it no way to recognise.
    public var status: Int {
        switch self {
        case .busy: 409
        default: 400
        }
    }
}

// MARK: - Image generation over the control API

extension AppModel {

    public func imageModels() async -> [ControlAPI.ImageModel] {
        DiffusionCatalog.all.map { entry in
            let configuration = recommendedImageConfiguration(for: entry)
            return ControlAPI.ImageModel(
                id: entry.id,
                name: entry.name,
                author: entry.author,
                license: entry.license,
                summary: entry.summary,
                parameters: entry.parameterLabel,
                blocks: entry.shape.blockCount,
                defaultSteps: entry.shape.defaultSteps,
                isGated: entry.isGated,
                recommendation: describe(
                    diffusionPlan(for: entry, configuration: configuration),
                    configuration: configuration
                )
            )
        }
    }

    public func planImage(_ request: ControlAPI.ImageRequest) async throws -> ControlAPI.ImagePlan {
        // An omitted or "auto" model is the media router's cue; with Jev off this only
        // normalises the word and the plan is the one this call has always produced.
        let routed = try await mediaRoutedImage(request)
        let (entry, configuration) = try resolveImage(routed.request)
        var plan = describe(
            diffusionPlan(for: entry, configuration: configuration),
            configuration: configuration
        )
        if let reason = routed.reason { plan.notes.insert(reason, at: 0) }
        return plan
    }

    public func generateImage(
        _ request: ControlAPI.ImageRequest
    ) async throws -> ControlAPI.ImageResponse {
        let routed = try await mediaRoutedImage(request)
        var response = try await generateRoutedImage(routed.request)
        response.warning = Self.merged(response.warning, routed.reason)
        return response
    }

    /// The image render itself, with the model and the settings already decided.
    private func generateRoutedImage(
        _ request: ControlAPI.ImageRequest
    ) async throws -> ControlAPI.ImageResponse {
        let (entry, configuration) = try resolveImage(request)

        // Routing before the MFLUX guard, deliberately: a Mac without MFLUX — or a
        // weak one — is exactly the machine that should hand the job to a node.
        let candidateNode = imageRenderTarget
        if Self.shouldRouteImageRemotely(
            localOnly: request.localOnly, hasCandidate: candidateNode != nil
        ), let node = candidateNode {
            return try await generateImageOnNode(
                request, configuration: configuration, node: node
            )
        }

        guard let installation = imageRuntime ?? MFluxRuntime.locate() else {
            throw ImageRuntimeError.notInstalled
        }
        let predicted = diffusionPlan(for: entry, configuration: configuration)

        // Warn rather than refuse: the estimate is not always right, and a hard block leaves
        // someone unable to run a model that would in fact work, with no way to proceed.
        let warning = predicted.verdict.isUsable ? nil : refusalMessage(for: entry, plan: predicted)

        noteActivity()
        let output = nextImageOutputURL()
        let carrier = InstalledModel(
            id: entry.id, name: entry.name, catalogID: entry.id,
            quantization: configuration.quantization, format: .mlx,
            primaryFile: output, allFiles: [], projectorFile: nil,
            sizeOnDisk: .zero, installedAt: Date(), shape: nil, capabilities: []
        )

        imageState = .starting(stage: "Starting MFLUX…")
        defer { imageState = .idle; imageProgress = nil }

        var result: ImageResult?
        let token = await huggingFaceToken()
        do {
            for try await event in try await MFluxRuntime(
                installation: installation, huggingFaceToken: token,
                hubCache: settings.resolvedEngineCacheDirectory
            ).generate(
                ImageRequest(
                    prompt: request.prompt, configuration: configuration,
                    seed: request.seed, output: output
                ),
                model: carrier
            ) {
                switch event {
                case .stage(let stage): imageState = .starting(stage: stage)
                case .step(let index, let total):
                    imageProgress = (index, total)
                    imageState = .starting(stage: "Denoising \(index)/\(total)…")
                case .finished(let finished):
                    result = finished
                    generatedImages.insert(finished, at: 0)
                }
            }
        } catch ImageRuntimeError.gated {
            // An agent needs the same things a person does: which model, and where the
            // licence lives.
            throw ImageRuntimeError.generationFailed(
                gatedGuidance(for: entry)
                    + " Licence page: https://huggingface.co/\(entry.repository)"
            )
        }

        guard let result else { throw ImageRuntimeError.noImageProduced }
        return ControlAPI.ImageResponse(
            path: result.image.path,
            elapsedSeconds: result.elapsed,
            peakMemoryBytes: result.peakMemory?.rawValue,
            predictedPeakBytes: predicted.peak.rawValue,
            model: entry.name,
            warning: warning
        )
    }

    nonisolated static func shouldRouteImageRemotely(
        localOnly: Bool?, hasCandidate: Bool
    ) -> Bool {
        localOnly != true && hasCandidate
    }

    /// The control-API image path, rendered by a node (#136): same response shape,
    /// the model field names the machine so agents and ledgers see where it ran.
    private func generateImageOnNode(
        _ request: ControlAPI.ImageRequest,
        configuration: ImageConfiguration,
        node: PeerStatus
    ) async throws -> ControlAPI.ImageResponse {
        guard let base = URL(string: node.baseURL.trimmingCharacters(in: .whitespaces))
        else {
            throw ImageRuntimeError.generationFailed("\(node.name)'s address didn't parse.")
        }
        noteActivity()
        imageState = .starting(stage: "Sending to \(node.name)…")
        defer { imageState = .idle; imageProgress = nil }

        let runtime = NodeImageRuntime()
        let nodeRequest = NodeImageRequest(
            prompt: request.prompt,
            width: configuration.width,
            height: configuration.height,
            steps: configuration.steps,
            seed: request.seed,
            outputDirectory: settings.resolvedImageOutputDirectory
        )
        let nodeName = node.name
        let result = try await runtime.generate(
            nodeRequest, node: base, token: swarmConfig?.bearer(forPeer: node.name)
        ) { progress in
            Task { @MainActor [weak self] in
                self?.imageState = .starting(
                    stage: progress.line(fallback: "Rendering on \(nodeName)")
                )
            }
        }
        guard let first = result.images.first else {
            throw ImageRuntimeError.noImageProduced
        }
        for url in result.images {
            generatedImages.insert(
                ImageResult(
                    image: url, elapsed: result.elapsed,
                    peakMemory: nil, stepsPerSecond: 0
                ), at: 0
            )
        }
        return ControlAPI.ImageResponse(
            path: first.path,
            elapsedSeconds: result.elapsed,
            peakMemoryBytes: nil,
            predictedPeakBytes: 0,
            model: "text-to-image on \(node.name)",
            warning: nil
        )
    }

    // MARK: - Mapping

    private func resolveImage(
        _ request: ControlAPI.ImageRequest
    ) throws -> (DiffusionEntry, ImageConfiguration) {
        let entry: DiffusionEntry
        if let id = request.modelID {
            guard let match = DiffusionCatalog.entry(id: id) else {
                throw ControlHostError.unknownModel(id)
            }
            entry = match
        } else {
            // Default to the best thing this Mac can comfortably run.
            entry = DiffusionCatalog.all.first {
                diffusionPlan(
                    for: $0, configuration: recommendedImageConfiguration(for: $0)
                ).verdict == .comfortable && !$0.isGated
            } ?? DiffusionCatalog.fluxSchnell
        }

        var configuration = recommendedImageConfiguration(for: entry)
        if let width = request.width { configuration.width = width }
        if let height = request.height { configuration.height = height }
        if let steps = request.steps { configuration.steps = steps }
        guard (1...8192).contains(configuration.width),
              (1...8192).contains(configuration.height),
              configuration.width <= 40_000_000 / configuration.height
        else {
            throw ControlHostError.badRequest(
                "Image dimensions must be positive, no more than 8192 per side, and "
                    + "no more than 40 megapixels total."
            )
        }
        guard (1...200).contains(configuration.steps) else {
            throw ControlHostError.badRequest("Image steps must be between 1 and 200.")
        }
        if let raw = request.quantization, let quantization = Quantization(rawValue: raw) {
            configuration.quantization = quantization
        }
        if let initPath = request.initImagePath {
            let url = URL(fileURLWithPath: (initPath as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ControlHostError.loadFailed(
                    "No image at \(url.path) to revise. Pass an absolute path to an "
                        + "existing image file."
                )
            }
            configuration.initImage = url
            if let influence = request.initImageInfluence {
                guard influence.isFinite, (0...1).contains(influence) else {
                    throw ControlHostError.badRequest(
                        "Initial-image influence must be a finite value from 0 through 1."
                    )
                }
                configuration.initImageInfluence = influence
            }
        }
        return (entry, configuration)
    }

    private func describe(
        _ plan: DiffusionPlan, configuration: ImageConfiguration
    ) -> ControlAPI.ImagePlan {
        ControlAPI.ImagePlan(
            width: configuration.width,
            height: configuration.height,
            steps: configuration.steps,
            quantization: configuration.quantization.rawValue,
            peakBytes: plan.peak.rawValue,
            peakPhase: plan.peakPhase?.name ?? "",
            budgetBytes: plan.budget.rawValue,
            verdict: plan.verdict.label,
            phases: plan.phases.map {
                .init(name: $0.name, detail: $0.detail, residentBytes: $0.resident.rawValue)
            },
            suggestions: plan.remediations.map {
                ControlAPI.Suggestion(
                    title: $0.title, detail: $0.detail,
                    savingBytes: $0.saving.rawValue, cost: $0.cost
                )
            },
            notes: plan.notes
        )
    }
}

// MARK: - 3D generation over the control API

extension AppModel {

    public func meshModels() async -> [ControlAPI.MeshModel] {
        MeshCatalog.all.map { entry in
            let installation = meshInstallation(for: entry)
            return ControlAPI.MeshModel(
                id: entry.id,
                name: entry.name,
                author: entry.author,
                summary: entry.summary,
                outputs: entry.outputs,
                typicalDuration: entry.typicalDuration,
                peakBytes: entry.peakMemory.rawValue,
                weightsBytes: entry.weightsSize.rawValue,
                isInstalled: installation.isInstalled,
                installDetail: installation.detail
            )
        }
    }

    public func planMesh(_ request: ControlAPI.MeshRequest) async throws -> ControlAPI.MeshPlan {
        let (entry, configuration) = try resolveMesh(request)
        return describe(meshPlan(for: entry, configuration: configuration), entry: entry)
    }

    public func generateMesh(
        _ request: ControlAPI.MeshRequest
    ) async throws -> ControlAPI.MeshResponse {
        let (entry, configuration) = try resolveMesh(request)
        // Optional on the wire since devices got `uploadID`/`mediaID`, which the control
        // server resolves into this field before the request reaches here. Nothing this
        // side can do with a request that still has none.
        guard let named = request.imagePath, !named.isEmpty else {
            throw ControlHostError.badRequest(ControlServer.noSubjectImage)
        }
        let image = URL(fileURLWithPath: (named as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: image.path) else {
            throw MeshRuntimeError.generationFailed(
                "No image at \(image.path). Pass an absolute path to an existing image file."
            )
        }
        let installation = meshInstallation(for: entry)
        guard installation.isInstalled else {
            throw MeshRuntimeError.notInstalled(installation.detail)
        }
        guard let runtime = makeMeshRuntime(for: entry) else {
            throw MeshRuntimeError.notInstalled(installation.detail)
        }

        let predicted = meshPlan(for: entry, configuration: configuration)
        let warning: String? = predicted.verdict.isUsable ? nil :
            "\(entry.name) was predicted to peak at \(predicted.peak.formatted) against a "
            + "\(predicted.budget.formatted) budget; expect swapping."

        noteActivity()
        let (directory, baseName) = nextMeshOutputLocation()
        meshState = .starting(stage: "Starting \(entry.name)…")
        defer { meshState = .idle; meshProgress = nil }

        var result: MeshResult?
        for try await event in try await runtime.generate(MeshRequest(
            image: image, configuration: configuration,
            outputDirectory: directory, baseName: baseName
        )) {
            switch event {
            case .stage(let stage): meshState = .starting(stage: stage)
            case .progress(let fraction): meshProgress = fraction
            case .finished(let finished):
                result = finished
                meshResults.insert(finished, at: 0)
            }
        }

        guard let result else { throw MeshRuntimeError.noMeshProduced }
        return ControlAPI.MeshResponse(
            glbPath: result.glb?.path,
            objPath: result.obj?.path,
            elapsedSeconds: result.elapsed,
            model: entry.name,
            warning: warning
        )
    }

    private func resolveMesh(
        _ request: ControlAPI.MeshRequest
    ) throws -> (MeshEntry, MeshConfiguration) {
        let entry: MeshEntry
        if let id = request.modelID {
            guard let match = MeshCatalog.entry(id: id) else {
                throw ControlHostError.unknownModel(id)
            }
            entry = match
        } else {
            // Default to the best installed backend — fast one first, quality one if it is
            // the only thing ready.
            entry = MeshCatalog.all.first {
                $0.backend != .unsupported && meshInstallation(for: $0).isInstalled
            } ?? MeshCatalog.hunyuanMini
        }

        var configuration = MeshConfiguration()
        configuration.steps = entry.defaultSteps
        if let pipeline = request.pipelineType { configuration.pipelineType = pipeline }
        if let textureSize = request.textureSize { configuration.textureSize = textureSize }
        if let steps = request.steps { configuration.steps = steps }
        if let quantize = request.quantize { configuration.quantize = quantize }
        if let octree = request.octree { configuration.octree = octree }
        if let budget = request.vertexBudget {
            configuration.vertexBudget = max(200, min(5000, budget))
        }
        configuration.seed = request.seed
        return (entry, configuration)
    }

    // MARK: - Video

    /// The video catalog, with an availability answer per entry: a node advertising the
    /// model's exact capability, or silicon-node's generic `text-to-video` for the
    /// models it serves. A node that then lacks the weights refuses the submit itself.
    public func videoModels() async -> [ControlAPI.VideoModel] {
        await refreshSwarmIfStale()
        return VideoCatalog.all.map { entry in
            let node = videoCapableNode(for: entry)
            return ControlAPI.VideoModel(
                id: entry.id,
                name: entry.name,
                summary: entry.summary,
                typicalDuration: entry.typicalDuration,
                supportsImageInput: entry.supportsImageInput,
                supportedSeconds: entry.supportedSeconds,
                available: node != nil,
                node: node?.name,
                supportedParameters: node.flatMap { videoCapability(for: entry, on: $0)?.supportedParameters },
                supportedResolutions: entry.supportedResolutions,
                supportsNegativePrompt: entry.supportsNegativePrompt
            )
        }
    }

    /// Queue a clip exactly like the Video tab, then wait for its file for legacy
    /// synchronous callers. All rendering and recovery belongs to the queue worker.
    public func generateVideo(
        _ request: ControlAPI.VideoGenerateRequest
    ) async throws -> ControlAPI.VideoResponse {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ControlHostError.badRequest("The prompt is empty.") }
        // An omitted or "auto" model goes to the media router. It answers nil when Jev is
        // not available, and everything below then behaves exactly as it did before.
        let routed = try await mediaRoutedVideo(
            prompt: prompt, explicitModelID: request.modelID, seconds: request.seconds
        )
        // "auto" is a routing instruction rather than a model id, so it never reaches the
        // catalog: unrouted, it means what an omitted model has always meant.
        let namedID = MediaRoutingQuestions.isAuto(request.modelID) ? nil : request.modelID
        let explicitEntry: VideoEntry?
        if let requestedID = routed?.modelID ?? namedID {
            guard let entry = VideoCatalog.entry(id: requestedID) else {
                let known = VideoCatalog.all.map(\.id).joined(separator: ", ")
                throw ControlHostError.badRequest(
                    "Unknown video model \(requestedID). Known: \(known)"
                )
            }
            explicitEntry = entry
        } else {
            explicitEntry = nil
        }

        // A cold refresh may replace the historical Wan default with the first exact
        // capability actually available. Resolve an omitted model only after that.
        await refreshSwarmIfStale()
        let entryID = routed?.modelID ?? namedID ?? selectedVideoModel
        guard let entry = explicitEntry ?? VideoCatalog.entry(id: entryID) else {
            let known = VideoCatalog.all.map(\.id).joined(separator: ", ")
            throw ControlHostError.badRequest("Unknown video model \(entryID). Known: \(known)")
        }
        let seconds: Int
        // A named length is still checked against the model here, routed or not: the router
        // honours it exactly or refuses, so it can only agree with this — and a caller that
        // named both a model and a length never reaches the router at all.
        if let requestedSeconds = request.seconds {
            guard entry.supportedSeconds.contains(requestedSeconds) else {
                let choices = entry.supportedSeconds.map(String.init).joined(separator: ", ")
                throw ControlHostError.badRequest(
                    "\(entry.name) supports these clip lengths: \(choices) seconds."
                )
            }
            seconds = requestedSeconds
        } else if let routedSeconds = routed?.seconds {
            seconds = routedSeconds
        } else {
            seconds = entry.normalizedSeconds(
                ControlAPI.VideoGenerateRequest.clampedSeconds(videoSeconds)
            )
        }
        let chainPrompts: [String]?
        do {
            chainPrompts = try ControlAPI.VideoGenerateRequest.validatedH3ChainPrompts(
                request.h3ChainPrompts, modelID: entry.id, seconds: seconds
            )
        } catch {
            throw ControlHostError.badRequest(error.localizedDescription)
        }
        guard let node = videoCapableNode(for: entry),
              URL(string: node.baseURL.trimmingCharacters(in: .whitespaces)) != nil
        else {
            throw ControlHostError.badRequest(
                "No ready swarm node offers \(entry.name) right now — the node may be "
                + "off or still setting that model up."
            )
        }
        // The router only sets these when the node advertised them, so they go through the
        // same checks as a caller's own and are refused the same way if the node changed.
        let h3Turbo = routed?.h3Turbo ?? request.h3Turbo
        let h3Steps = routed?.h3Steps ?? request.h3Steps
        try ControlAPI.VideoGenerateRequest.validateSampling(h3Turbo: h3Turbo, h3Steps: h3Steps, modelID: entry.id)
        if h3Turbo != nil,
           videoCapability(for: entry, on: node)?.supportedParameters.contains("h3_turbo") != true {
            throw ControlHostError.badRequest("This node does not support per-clip h3_turbo; update its video-node adapter or omit that field.")
        }
        if h3Steps != nil,
           videoCapability(for: entry, on: node)?.supportedParameters.contains("h3_steps") != true {
            throw ControlHostError.badRequest("This node does not advertise h3_steps. Update its video-node adapter and Phosphene, or omit steps for Auto.")
        }
        // A synchronous caller cannot wait indefinitely for a manually paused
        // queue. Reject before accepting anything; the async queue API can append
        // to a paused queue intentionally. Never resume it on the caller's behalf.
        guard !videoBatchQueue.isPaused else {
            throw ControlHostError.badRequest("The video queue is paused. Resume it first, or use /video/queue to save clips for later. No clip was added.")
        }

        let videoRequest = VideoRequest(
            entryID: entry.id,
            prompt: prompt,
            image: request.imagePath.map { URL(fileURLWithPath: $0) },
            seconds: seconds,
            resolution: request.resolution ?? videoResolution,
            h3ChainPrompts: chainPrompts,
            outputDirectory: settings.resolvedVideoOutputDirectory,
            seed: request.seed, h3Turbo: h3Turbo, h3Steps: h3Steps,
            // Sent only where the lane takes one. Every node lane does today; dropping it
            // silently on one that does not is better than a refusal over a field the
            // caller could not have known about — and `GET /video/models` says which.
            negativePrompt: entry.supportsNegativePrompt
                ? request.negativePrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilWhenEmpty
                : nil
        )

        videoError = nil
        // A disconnected synchronous client must not enqueue after a slow
        // capability refresh. Once accepted, only its waiter is cancellable.
        try Task.checkCancellation()
        let item = try enqueueSingleVideo(videoRequest, detail: routed?.reason)
        // Lease before the first suspension after acceptance, so even a very
        // fast completion + clear cannot beat entry into the polling function.
        videoBatchQueue.retainReceipt(item.id)
        defer { videoBatchQueue.releaseReceipt(item.id) }
        return try await waitForQueuedVideo(item.id)
    }

    /// A swarm answer older than the poll interval is re-fetched before it backs a
    /// claim like "no node offers video".
    /// Re-polls the swarm when the last look is more than twenty seconds old. The
    /// video queue worker relies on this too: a batch can outlive the last poll by
    /// hours, and a node that rebooted overnight has to be noticed without anyone
    /// opening the Swarm or Video tab.
    func refreshSwarmIfStale() async {
        let age = lastSwarmPoll.map { Date().timeIntervalSince($0) } ?? .infinity
        if age > 20 { await refreshSwarm() }
    }

    /// The Mac's `/v1/node` advertisement — the frozen swarm shape. Capability figures
    /// come from the same measured catalog the app plans with.
    /// The swarm as this app currently sees it, including how old that view is.
    public func swarm() async -> ControlAPI.SwarmView {
        ControlAPI.SwarmView(
            peers: swarmPeers.map { peer in
                ControlAPI.SwarmView.Peer(
                    name: peer.name,
                    baseURL: peer.baseURL,
                    reachable: peer.reachable,
                    error: peer.error,
                    capabilities: peer.capabilities.map {
                        ControlAPI.SwarmView.Capability(
                            id: $0.id, kind: $0.kind, ready: $0.ready
                        )
                    },
                    // Everything below was already on this Mac's own Swarm card and went
                    // no further. The phone showed a name, an address and a dot; this is
                    // the rest of what the last poll actually learned. Nothing new is
                    // fetched to answer it — a peer that is down still carries its error
                    // and nothing else, because that is all there is to say about it.
                    platform: peer.platform,
                    hardware: peer.hardware,
                    totalMemoryGB: peer.totalGB,
                    usedMemoryGB: peer.usedGB,
                    headroomGB: peer.headroomGB,
                    gpuUtilization: peer.gpuUtil,
                    queueDepth: peer.queueDepth,
                    gpuConsumer: peer.gpuConsumer,
                    // The name only while it is actually serving: a stopped lane has a
                    // model on disk, which is `lanes.gguf == false` and not a claim that
                    // something is loaded.
                    loadedModel: peer.llm?.running == true ? peer.llm?.model : nil,
                    modelEngine: peer.llm?.running == true ? peer.llm?.engine : nil,
                    modelContextLength: peer.llm?.running == true
                        ? peer.llm?.contextLength : nil,
                    lanes: Self.lanes(of: peer)
                )
            },
            polledSecondsAgo: lastSwarmPoll.map { Date().timeIntervalSince($0) },
            // The other half of the swarm: whether this Mac's peers can reach *it*. A node
            // that cannot call back looks exactly like a node that is down, and the reason
            // is nearly always that tailscale is not running here.
            exposure: await controlServer?.exposure
        )
    }

    public func nodeAdvertisement() async -> ControlAPI.NodeAdvertisement {
        var capabilities: [ControlAPI.NodeCapability] = []

        capabilities.append(ControlAPI.NodeCapability(
            id: "llm",
            kind: "llm",
            ready: loadedModel != nil,
            peakGB: loadedModel.map { Double($0.sizeOnDisk.rawValue) / 1e9 },
            typicalSeconds: nil,
            detail: loadedModel.map { "\($0.name) loaded" }
                ?? "No model loaded; load one from the Models tab."
        ))
        capabilities.append(ControlAPI.NodeCapability(
            id: "image-flux",
            kind: "image",
            ready: imageRuntime != nil,
            peakGB: nil,
            typicalSeconds: nil,
            detail: imageRuntime != nil
                ? "MFLUX ready (FLUX family)" : "MFLUX not installed."
        ))
        for entry in MeshCatalog.all where entry.backend != .latoRemote {
            let installation = meshInstallation(for: entry)
            capabilities.append(ControlAPI.NodeCapability(
                id: entry.id,
                kind: "mesh",
                ready: installation.isInstalled,
                peakGB: entry.peakMemory > .zero
                    ? Double(entry.peakMemory.rawValue) / 1e9 : nil,
                typicalSeconds: nil,
                detail: installation.detail
            ))
        }

        let queueDepth = imageQueue.count + meshQueue.count
            + (currentImageJob != nil ? 1 : 0) + (currentMeshJob != nil ? 1 : 0)
            + (hasWorkInFlight ? 1 : 0)
        let resident = loadedModel != nil ? estimatedResidentBytes : .zero
        let headroom = max(
            0, Double((profile.safeModelBudget - resident).rawValue) / 1e9
        )

        return ControlAPI.NodeAdvertisement(
            name: Host.current().localizedName ?? "mac",
            platform: "macos-apple-silicon",
            profile: ControlAPI.MacProfile(
                chip: profile.chipName,
                memoryGB: Double(profile.totalMemory.rawValue) / 1e9,
                bandwidthGBps: profile.memoryBandwidthGBps,
                gpuCores: profile.gpuCores
            ),
            capabilities: capabilities,
            metrics: ControlAPI.NodeMetrics(
                queueDepth: queueDepth,
                headroomGB: headroom,
                gpuUtilPct: Int(metrics.gpuUtilization * 100),
                memoryUsedPct: Int(metrics.memoryUsedFraction * 100)
            )
        )
    }

    private func describe(_ plan: MeshPlan, entry: MeshEntry) -> ControlAPI.MeshPlan {
        ControlAPI.MeshPlan(
            model: entry.name,
            peakBytes: plan.peak.rawValue,
            peakPhase: plan.peakPhase?.name ?? "",
            budgetBytes: plan.budget.rawValue,
            verdict: plan.verdict.label,
            isRemote: plan.isRemote,
            phases: plan.phases.map {
                .init(name: $0.name, detail: $0.detail, residentBytes: $0.resident.rawValue)
            },
            suggestions: plan.remediations.map {
                ControlAPI.Suggestion(
                    title: $0.title, detail: $0.detail,
                    savingBytes: $0.saving.rawValue, cost: $0.cost
                )
            },
            notes: plan.notes
        )
    }
}
