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
            activity: activeGenerationSummary
        )
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
                return lhs.rating > rhs.rating
            }
    }

    public func recommend(category: String?) async -> ControlAPI.CatalogModel? {
        let filter = category.flatMap { ModelCategory(rawValue: $0) }
        let pool = filter.map { wanted in ModelCatalog.all.filter { $0.category == wanted } }
            ?? ModelCatalog.all.filter { $0.category != .embedding }
        guard let pick = autoConfigurator().rank(
            catalog: pool, otherAppsInUse: memoryUsedByOtherApps
        ).first else { return nil }
        return describe(pick.entry, recommendation: pick)
    }

    // MARK: - Plan

    public func plan(_ request: ControlAPI.PlanRequest) async throws -> ControlAPI.Plan {
        guard let entry = ModelCatalog.entry(id: request.modelID) else {
            throw ControlHostError.unknownModel(request.modelID)
        }
        let quantization = request.quantization
            .flatMap { Quantization(rawValue: $0) }
            ?? autoConfigurator().best(for: entry, otherAppsInUse: memoryUsedByOtherApps)?.quantization
            ?? .q4_K_M

        var configuration = LoadConfiguration(
            contextLength: request.contextLength ?? 8192,
            kvCachePrecision: request.kvCachePrecision
                .flatMap { KVCachePrecision(rawValue: $0) } ?? .f16,
            flashAttention: request.flashAttention ?? true,
            threads: profile.performanceCores
        )
        if let slots = request.expertSlots, let moe = entry.shape.moe {
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
            return "\(entry.name) (\(quantization.rawValue)) is already installed."
        }

        // Preflight before claiming the download has begun. The transfer runs detached, so a
        // disk-space failure inside it would surface only in the app window while the caller
        // had already been told "downloading now".
        let projectorAllowance = entry.capabilities.contains(.vision) ? Bytes.gib(2) : .zero
        try ModelDownloader.checkDiskSpace(
            needed: (entry.variant(for: quantization)?.downloadSize ?? .zero) + projectorAllowance,
            at: ModelLibrary.defaultRoot
        )

        install(entry, quantization: quantization)
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

        var configuration = defaultConfiguration(for: target)
        if let context = request.contextLength { configuration.contextLength = context }
        if let slots = request.expertSlots, let moe = target.shape?.moe {
            configuration.expertStreaming = ExpertStreamingConfiguration(slotCount: slots)
            configuration.microBatchSize = ExpertStreamingConfiguration.maximumMicroBatch(
                slotCount: slots, expertsUsedPerToken: moe.expertsUsedPerToken
            )
            configuration.batchSize = max(configuration.microBatchSize, 256)
        }

        await loadAsync(target, configuration: configuration)
        guard runtimeState.isRunning else {
            throw ControlHostError.loadFailed(runtimeState.label)
        }
        return await status()
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
        var content = ""
        var reasoning = ""
        var metrics = GenerationMetrics()
        for try await event in try await runtime.chat(chatRequest) {
            switch event {
            case .token(let token): content += token
            case .reasoningToken(let token): reasoning += token
            case .finished(let final): metrics = final
            }
        }
        lastGeneration = metrics

        return ControlAPI.ChatResponse(
            content: content,
            reasoning: reasoning.isEmpty ? nil : reasoning,
            promptTokens: metrics.promptTokens,
            generatedTokens: metrics.generatedTokens,
            tokensPerSecond: metrics.generationTokensPerSecond
        )
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
            }
        )
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

public enum ControlHostError: Error, LocalizedError {
    case unknownModel(String)
    case notInstalled(String)
    case noModelLoaded
    case loadFailed(String)

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
        let (entry, configuration) = try resolveImage(request)
        return describe(
            diffusionPlan(for: entry, configuration: configuration),
            configuration: configuration
        )
    }

    public func generateImage(
        _ request: ControlAPI.ImageRequest
    ) async throws -> ControlAPI.ImageResponse {
        guard let installation = imageRuntime ?? MFluxRuntime.locate() else {
            throw ImageRuntimeError.notInstalled
        }
        let (entry, configuration) = try resolveImage(request)
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
        do {
            for try await event in try await MFluxRuntime(
                installation: installation, huggingFaceToken: settings.huggingFaceToken,
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
                configuration.initImageInfluence = max(0, min(1, influence))
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
        let image = URL(fileURLWithPath: (request.imagePath as NSString).expandingTildeInPath)
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
                    }
                )
            },
            polledSecondsAgo: lastSwarmPoll.map { Date().timeIntervalSince($0) }
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
            + (isGenerating ? 1 : 0)
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
