import Foundation
import SiliconCore
import SiliconHardware

/// How an image is generated, and therefore what it costs.
public struct ImageConfiguration: Sendable, Codable, Hashable {
    public var width: Int
    public var height: Int
    public var steps: Int
    /// Weight precision. Diffusion transformers tolerate quantization well — better than
    /// convolutional models — which is why 4-bit is a reasonable default here.
    public var quantization: Quantization
    /// Whether the runtime frees the text encoders once the prompt is encoded. Worth several
    /// gigabytes and costs nothing on a single image.
    public var evictTextEncoders: Bool
    /// Decode the image in tiles rather than whole. Trades a little speed for a much lower
    /// decode peak.
    public var tiledDecode: Bool
    /// Blocks kept resident when streaming the denoiser from disk. Nil means all of them.
    public var residentBlocks: Int?
    /// Whether the weights on disk are already at the target precision.
    ///
    /// This is the difference between a model that fits and one that does not. Runtimes fetch
    /// full-precision weights from Hugging Face and quantize them *in memory* at load, so the
    /// first run peaks at the unquantized size no matter what precision was asked for. Saving a
    /// quantized copy once removes that spike from every subsequent run.
    public var weightsArePrequantized: Bool
    /// Whether this model's runtime can actually *load* a quantized copy back.
    ///
    /// Saving one is only useful if it can be read again, and that is not universal: mflux 0.18.1
    /// forwards `--base-model` in the FLUX.1 and FIBO entry points but not in the FLUX.2 or
    /// Z-Image ones, so a locally saved FLUX.2 model fails with "Cannot infer base_model". Until
    /// that is fixed upstream the load spike is unavoidable there, and advising otherwise would
    /// send someone to an error message.
    public var canReuseQuantizedSave: Bool
    /// Images generated in one run. Batching amortises the encode but multiplies the latents.
    public var batchSize: Int

    public init(
        width: Int = 1024,
        height: Int = 1024,
        steps: Int = 4,
        quantization: Quantization = .mlx4,
        evictTextEncoders: Bool = true,
        tiledDecode: Bool = false,
        residentBlocks: Int? = nil,
        weightsArePrequantized: Bool = false,
        canReuseQuantizedSave: Bool = true,
        batchSize: Int = 1
    ) {
        self.width = width
        self.height = height
        self.steps = steps
        self.quantization = quantization
        self.evictTextEncoders = evictTextEncoders
        self.tiledDecode = tiledDecode
        self.residentBlocks = residentBlocks
        self.weightsArePrequantized = weightsArePrequantized
        self.canReuseQuantizedSave = canReuseQuantizedSave
        self.batchSize = batchSize
    }

    public var megapixels: Double {
        Double(width * height) / 1_000_000
    }
}

/// A predicted memory profile for generating an image.
public struct DiffusionPlan: Sendable, Equatable {

    /// Generation runs in stages, and the stages do not overlap. What matters is the tallest
    /// one, not the total — a distinction that changes the answer by many gigabytes.
    public struct Phase: Sendable, Equatable, Identifiable {
        public var name: String
        public var detail: String
        public var resident: Bytes
        public var id: String { name }
    }

    public var phases: [Phase]
    public var budget: Bytes
    public var streamedFromDisk: Bytes
    public var verdict: MemoryPlan.Verdict
    public var remediations: [MemoryPlan.Remediation]
    public var notes: [String]

    /// The tallest stage. This is the number that decides whether generation succeeds.
    public var peak: Bytes {
        phases.map(\.resident).max() ?? .zero
    }

    /// Which stage sets the peak — the thing to attack if it does not fit.
    public var peakPhase: Phase? {
        phases.max { $0.resident < $1.resident }
    }

    public var headroom: Bytes { budget - peak }
    public var utilization: Double { peak.fraction(of: budget) }
}

/// Predicts memory for diffusion image models.
///
/// Deliberately separate from `MemoryPlanner` rather than a branch inside it. A language model
/// holds everything at once and grows with conversation length; an image model runs in stages
/// that release each other's memory and grows with image *area*. The only shared idea is the
/// budget, so sharing anything else would mean a formula that fits neither.
public struct DiffusionPlanner: Sendable {

    public let profile: SystemProfile

    public init(profile: SystemProfile) {
        self.profile = profile
    }

    // MARK: - Components

    public static func weightBytes(_ parameters: Int64, _ quantization: Quantization) -> Bytes {
        Bytes(Int64(Double(parameters) * quantization.bitsPerWeight / 8.0))
    }

    /// Latents carried between denoising steps, in fp16.
    ///
    /// Small next to the weights, but they scale with image area, so they are what makes a
    /// 2048px render cost four times a 1024px one before attention is even considered.
    public static func latentBytes(_ shape: DiffusionShape, _ configuration: ImageConfiguration) -> Bytes {
        let elements = shape.latentElements(width: configuration.width, height: configuration.height)
        // The sampler keeps roughly three of these live at once: current, predicted, and the
        // guidance branch.
        return Bytes(elements * 2 * 3 * Int64(configuration.batchSize))
    }

    /// Activation memory inside a transformer block while denoising.
    ///
    /// Attention over the latent grid is quadratic in the token count, and the token count is
    /// itself proportional to image area — so activations grow with the *fourth* power of the
    /// image's side length. This is the term that makes high resolutions fail suddenly rather
    /// than gradually.
    public static func denoiseActivationBytes(
        _ shape: DiffusionShape, _ configuration: ImageConfiguration
    ) -> Bytes {
        let tokens = Double(shape.spatialTokens(
            width: configuration.width, height: configuration.height
        ))
        let batch = Double(configuration.batchSize)

        // Hidden-state working set for one block, double-buffered, in fp16.
        let hidden = tokens * Double(shape.hiddenSize) * 2 * 4 * batch
        // Metal's attention kernels are tiled, so the score matrix is never materialised in
        // full. What remains scales with tokens and heads rather than tokens squared.
        let attention = tokens * Double(shape.headCount) * 2 * 8 * batch

        return Bytes(Int64(hidden + attention))
    }

    /// Peak while the VAE turns latents back into pixels.
    ///
    /// The decoder upsamples to full resolution and briefly holds wide intermediate feature
    /// maps — often the tallest moment of the whole run, and the reason an image can fail at
    /// the very last step after minutes of denoising. Tiling caps it by decoding in pieces.
    public static func decodeActivationBytes(
        _ shape: DiffusionShape, _ configuration: ImageConfiguration
    ) -> Bytes {
        let pixels = Double(configuration.width * configuration.height)
        if configuration.tiledDecode {
            // Bounded by the tile, not the image.
            return Bytes(Int64(512 * 512 * 128 * 2 * 2))
        }
        // Widest feature map is roughly 128 channels at full resolution, fp16, double-buffered.
        return Bytes(Int64(pixels * 128 * 2 * 2 * Double(configuration.batchSize)))
    }

    // MARK: - Planning

    public func plan(
        shape: DiffusionShape,
        configuration: ImageConfiguration,
        otherAppsInUse: Bytes = .zero
    ) -> DiffusionPlan {
        let quantization = configuration.quantization

        let textEncoders = Self.weightBytes(shape.textEncoderParameters, quantization)
        let vae = Self.weightBytes(shape.vaeParameters, quantization)
        let latents = Self.latentBytes(shape, configuration)

        // Layer streaming: only the resident slice of the denoiser is in memory.
        var transformer = Self.weightBytes(shape.transformerParameters, quantization)
        var streamed = Bytes.zero
        var notes: [String] = []

        if let resident = configuration.residentBlocks, resident < shape.blockCount, resident > 0 {
            let perBlock = Self.weightBytes(shape.parametersPerBlock, quantization)
            let full = transformer
            transformer = perBlock * Double(resident)
            streamed = full - transformer
            notes.append(
                "Layer streaming keeps \(resident) of \(shape.blockCount) transformer blocks "
                + "resident (\(perBlock.formatted) each) and reads the rest from disk each step."
            )
            notes.append(
                "Every denoising step touches every block, so the whole streamed portion is read "
                + "\(configuration.steps) times — \((streamed * Double(configuration.steps)).formatted) "
                + "of disk traffic per image."
            )
        }

        // Loading comes first, and on a first run it is usually the tallest thing that happens.
        //
        // Charging a full-precision copy of everything plus the largest quantized component is
        // deliberately pessimistic: mflux quantizes component by component and frees as it goes,
        // so the true peak sits below this. On FLUX.2-klein-4B (16.46 GB of fp16 weights, 4.61 GB
        // once quantized) it predicts 19.1 GB against 17.9 GB measured. Erring high is the point
        // — the failure mode of the opposite error is an OOM partway through a long run.
        let fullPrecision = Self.weightBytes(shape.totalParameters, .f16)
        let quantizedLargest = Self.weightBytes(
            max(shape.transformerParameters, shape.textEncoderParameters), quantization
        )
        let loadResident = configuration.weightsArePrequantized
            ? Self.weightBytes(shape.totalParameters, quantization)
            : fullPrecision + quantizedLargest

        if !configuration.weightsArePrequantized, quantization != .f16, quantization != .bf16 {
            notes.append(
                "Weights are downloaded at full precision and quantized in memory, so the first "
                + "run peaks at \(loadResident.formatted) regardless of the precision asked for. "
                + (configuration.canReuseQuantizedSave
                   ? "Saving a quantized copy removes that spike."
                   : "This runtime cannot load a quantized copy back for this model family, so "
                     + "the spike applies to every run, not just the first.")
            )
        }

        // The stages, in the order they run.
        var phases: [DiffusionPlan.Phase] = [
            .init(
                name: "Load",
                detail: configuration.weightsArePrequantized
                    ? "Reads weights already at the target precision"
                    : "Reads full-precision weights and quantizes them in memory",
                resident: loadResident
            ),
            .init(
                name: "Encode",
                detail: "Text encoders turn the prompt into conditioning",
                resident: textEncoders + latents
            ),
            .init(
                name: "Denoise",
                detail: "\(configuration.steps) steps through the transformer",
                resident: transformer + latents
                    + Self.denoiseActivationBytes(shape, configuration)
                    + (configuration.evictTextEncoders ? .zero : textEncoders)
            ),
            .init(
                name: "Decode",
                detail: configuration.tiledDecode
                    ? "VAE reconstructs the image in tiles"
                    : "VAE reconstructs the image",
                resident: vae + latents + Self.decodeActivationBytes(shape, configuration)
            ),
        ]

        // Metal keeps a floor for command buffers and pipeline state.
        phases = phases.map {
            .init(name: $0.name, detail: $0.detail, resident: $0.resident + .mib(320))
        }

        let systemWiredAllowance = profile.totalMemory * 0.10
        let unavoidable = Bytes(max(0, otherAppsInUse.rawValue - systemWiredAllowance.rawValue))
        let budget = Bytes(max(
            (profile.safeModelBudget * 0.35).rawValue,
            profile.safeModelBudget.rawValue - unavoidable.rawValue
        ))

        var plan = DiffusionPlan(
            phases: phases, budget: budget, streamedFromDisk: streamed,
            verdict: .comfortable, remediations: [], notes: notes
        )
        plan.verdict = verdict(for: plan)
        plan.remediations = remediations(
            for: plan, shape: shape, configuration: configuration
        )
        return plan
    }

    private func verdict(for plan: DiffusionPlan) -> MemoryPlan.Verdict {
        guard plan.budget > .zero else { return .impossible }
        if plan.peak > profile.totalMemory { return .impossible }
        return switch plan.utilization {
        case ..<0.80: .comfortable
        case ..<1.00: .tight
        default: .willSwap
        }
    }

    // MARK: - Remediations

    private func remediations(
        for plan: DiffusionPlan,
        shape: DiffusionShape,
        configuration: ImageConfiguration
    ) -> [MemoryPlan.Remediation] {
        guard plan.verdict != .comfortable else { return [] }
        var results: [MemoryPlan.Remediation] = []
        let peakName = plan.peakPhase?.name ?? ""

        // The load spike is usually the tallest thing on a first run, and it is entirely
        // avoidable — but only by saving a quantized copy, which nothing else on this list does.
        if peakName == "Load", !configuration.weightsArePrequantized,
           configuration.canReuseQuantizedSave {
            var prequantized = configuration
            prequantized.weightsArePrequantized = true
            let saving = plan.peak - self.plan(shape: shape, configuration: prequantized).peak
            if saving > .mib(256) {
                results.append(.init(
                    title: "Save a quantized copy first",
                    detail: "The runtime downloads full-precision weights and quantizes them in "
                        + "memory, so the first run peaks far above the size it settles at. "
                        + "Converting once on disk removes that spike from every run after.",
                    saving: saving,
                    cost: "A one-off conversion, and the disk space to keep the copy.",
                    kind: .lowerQuantization
                ))
            }
        }

        // Free, and only matters if the runtime is not doing it already.
        if !configuration.evictTextEncoders {
            var evicted = configuration
            evicted.evictTextEncoders = true
            let saving = plan.peak - self.plan(
                shape: shape, configuration: evicted
            ).peak
            if saving > .mib(256) {
                results.append(.init(
                    title: "Free the text encoders after encoding",
                    detail: "They are only needed to turn the prompt into conditioning, and are "
                        + "dead weight for every denoising step after that.",
                    saving: saving,
                    cost: "None for a single image. Re-encoding costs a moment if you generate "
                        + "several from the same prompt.",
                    kind: .enableFlashAttention
                ))
            }
        }

        // Only worth suggesting when decode is what is actually killing it.
        if peakName == "Decode", !configuration.tiledDecode {
            var tiled = configuration
            tiled.tiledDecode = true
            let saving = plan.peak - self.plan(shape: shape, configuration: tiled).peak
            if saving > .mib(256) {
                results.append(.init(
                    title: "Decode the image in tiles",
                    detail: "The final VAE step is the tallest moment of the run. Decoding in "
                        + "pieces caps it at the tile size instead of the image size.",
                    saving: saving,
                    cost: "Slightly slower, and can leave faint seams on some models.",
                    kind: .quantizeKVCache
                ))
            }
        }

        // Resolution is the strongest lever, because cost scales with area.
        if configuration.width > 512 || configuration.height > 512 {
            let smaller = ImageConfiguration(
                width: max(512, configuration.width / 2),
                height: max(512, configuration.height / 2),
                steps: configuration.steps, quantization: configuration.quantization,
                evictTextEncoders: configuration.evictTextEncoders,
                tiledDecode: configuration.tiledDecode,
                residentBlocks: configuration.residentBlocks, batchSize: configuration.batchSize
            )
            let saving = plan.peak - self.plan(shape: shape, configuration: smaller).peak
            if saving > .mib(256) {
                results.append(.init(
                    title: "Render at \(smaller.width)×\(smaller.height)",
                    detail: "Cost scales with area, so halving each side quarters the latents "
                        + "and the activations.",
                    saving: saving,
                    cost: "A smaller image. Upscaling afterwards recovers much of the detail.",
                    kind: .reduceContext
                ))
            }
        }

        // Lower precision.
        let lower: [Quantization] = [.mlx6, .mlx4]
        if let candidate = lower.first(where: { $0.bitsPerWeight < configuration.quantization.bitsPerWeight }) {
            var quantized = configuration
            quantized.quantization = candidate
            let saving = plan.peak - self.plan(shape: shape, configuration: quantized).peak
            if saving > .mib(256) {
                results.append(.init(
                    title: "Quantize the weights to \(candidate.rawValue)",
                    detail: "Diffusion transformers tolerate this better than most architectures.",
                    saving: saving,
                    cost: "A small loss of fine detail.",
                    kind: .lowerQuantization
                ))
            }
        }

        // Streaming, when the denoiser itself is the problem.
        if peakName == "Denoise", configuration.residentBlocks == nil, shape.blockCount > 8 {
            var streamed = configuration
            let resident = max(4, shape.blockCount / 4)
            streamed.residentBlocks = resident
            let saving = plan.peak - self.plan(shape: shape, configuration: streamed).peak
            let readPerImage = Self.weightBytes(shape.parametersPerBlock, configuration.quantization)
                * Double((shape.blockCount - resident) * configuration.steps)
            if saving > .mib(256) {
                results.append(.init(
                    title: "Stream transformer blocks from disk (\(resident) of \(shape.blockCount) resident)",
                    detail: "Keeps a rolling window of blocks in memory and reads the rest as "
                        + "each step needs them. Output is unchanged.",
                    saving: saving,
                    cost: "\(readPerImage.formatted) of disk reads per image. On a fast internal "
                        + "SSD that is seconds; on an external disk it dominates.",
                    kind: .enableExpertStreaming
                ))
            }
        }

        return results.sorted { $0.saving > $1.saving }
    }
}
