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
    /// Run the runtime in its low-memory mode.
    ///
    /// Named for what mflux actually offers — `--low-ram` — rather than for tiled VAE decoding,
    /// which this used to promise and mflux 0.18.1 had no flag for. Measured peak on
    /// FLUX.2-klein-4B is byte-identical with and without it (10.52 GB either way, issue #3, on
    /// 0.18.1), so the planner charges it nothing. What it does buy is freeing the transformer
    /// *between* images, which matters for a batch and not for one. mflux 0.20.0 adds a separate
    /// `--vae-tiling` flag; the app does not pass it, because nobody has measured what it does to
    /// the decode peak, and a lever the planner cannot price is not one it should offer.
    public var lowRAM: Bool
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
    /// Z-Image ones, so a locally saved FLUX.2 model fails with "Cannot infer base_model".
    /// 0.20.0 forwards it, but the app still runs every image model from its Hub weights and has
    /// no way to point a render at a saved copy, so the families that could not are left saying
    /// so until that path exists and has been tried — advising otherwise would send someone to
    /// a copy nothing reads.
    public var canReuseQuantizedSave: Bool
    /// Images generated in one run. Batching amortises the encode but multiplies the latents.
    public var batchSize: Int
    /// When set, generation revises this image instead of starting from noise (img2img).
    public var initImage: URL?
    /// How strongly the starting image steers the result. mflux's semantics, which are the
    /// reverse of classic img2img strength: 0 ignores the image entirely, 1 clings to it.
    public var initImageInfluence: Double

    public init(
        width: Int = 1024,
        height: Int = 1024,
        steps: Int = 4,
        quantization: Quantization = .mlx4,
        evictTextEncoders: Bool = true,
        lowRAM: Bool = false,
        residentBlocks: Int? = nil,
        weightsArePrequantized: Bool = false,
        canReuseQuantizedSave: Bool = true,
        batchSize: Int = 1,
        initImage: URL? = nil,
        initImageInfluence: Double = 0.5
    ) {
        self.width = width
        self.height = height
        self.steps = steps
        self.quantization = quantization
        self.evictTextEncoders = evictTextEncoders
        self.lowRAM = lowRAM
        self.residentBlocks = residentBlocks
        self.weightsArePrequantized = weightsArePrequantized
        self.canReuseQuantizedSave = canReuseQuantizedSave
        self.batchSize = batchSize
        self.initImage = initImage
        self.initImageInfluence = initImageInfluence
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

    /// What a transformer parameter costs in memory once the model is running, whatever
    /// precision was asked for.
    ///
    /// Two bytes — as though the request to quantize had been ignored. It was not: the weights
    /// on disk really are 4-bit, and a saved copy really is 4.61 GB. But the peak while
    /// generating tracks the *unquantized* parameter count, and does so across two models whose
    /// sizes differ by more than twice:
    ///
    ///     FLUX.2-klein-4B   8.0 GB flat term / 3.997B params = 2.01 bytes
    ///     FLUX.2-klein-9B  18.5 GB flat term / 9.0B params   = 2.06 bytes
    ///
    /// Why is not established. MLX evaluates lazily, so a plausible story is that a step's graph
    /// holds dequantized weights live until it is evaluated — but that is a story, and two points
    /// cannot confirm it. What is established is the number, and that planning against the
    /// quantized size instead under-predicts by more than half.
    public static let residentBytesPerParameter = 2.05

    /// Working memory the VAE decode needs per megapixel of output.
    ///
    /// This is the term the planner used to be missing almost entirely — it modelled the decode
    /// as one wide feature map, about 0.5 GB at 1024x1024, where measurement needs twenty times
    /// that. It was the larger half of issue #3: too small here, too large in the load phase, and
    /// the two errors happened to cancel at exactly the one resolution the planner was
    /// calibrated at.
    ///
    /// Measured slope is 9.48 GB/Mpx on klein-4B (five resolutions, all within 1% of the line)
    /// and 9.18 GB/Mpx on klein-9B (two). That they agree within 3.3% across models with
    /// different block counts and hidden sizes is what says this belongs to the VAE — which is
    /// the same component in both — rather than to the transformer. 9.8 is the top of the
    /// measured range, chosen so the residual error stays positive.
    public static let decodeBytesPerMegapixel = 9.8e9

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

    /// Bytes the resident weights cost during a run, as opposed to on disk.
    ///
    /// Everything but the transformer is charged at the precision it was quantized to. The
    /// transformer is charged at `residentBytesPerParameter`, which measurement says is what it
    /// costs no matter what precision was requested.
    public static func residentWeightBytes(_ parameters: Int64) -> Bytes {
        Bytes(Int64(Double(parameters) * residentBytesPerParameter))
    }

    /// Activation memory inside a transformer block while denoising.
    ///
    /// Small — tens of megabytes at 1024x1024, against nearly ten gigabytes for the decode. It
    /// is kept because it is real and because it is the term layer streaming acts on, not
    /// because it moves any verdict.
    ///
    /// Linear in token count, not quadratic: Metal's attention kernels are tiled, so the score
    /// matrix is never materialised in full. An earlier comment here claimed growth with the
    /// fourth power of the image side, which the code below has never done.
    public static func denoiseActivationBytes(
        _ shape: DiffusionShape, _ configuration: ImageConfiguration
    ) -> Bytes {
        if let measured = shape.denoiseBytesPerMegapixel {
            return Bytes(Int64(measured * configuration.megapixels * Double(configuration.batchSize)))
        }
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
    /// The tallest moment of the whole run above about half a megapixel, and the reason an image
    /// can fail at the very last step after minutes of denoising. It dominates because the
    /// decoder upsamples to full resolution and holds its intermediate feature maps rather than
    /// freeing them as it climbs.
    ///
    /// A single measured coefficient rather than a count of feature maps: the count would have to
    /// be guessed, and the guess was wrong by twenty times. See `decodeBytesPerMegapixel`.
    public static func decodeActivationBytes(
        _ shape: DiffusionShape, _ configuration: ImageConfiguration
    ) -> Bytes {
        // Decoded in tiles, only one tile's working memory is live at a time.
        var megapixels = configuration.megapixels
        if configuration.lowRAM, let tile = shape.lowMemoryDecodeTileMegapixels {
            megapixels = min(megapixels, tile)
        }
        return Bytes(Int64(
            (shape.decodeBytesPerMegapixel ?? decodeBytesPerMegapixel)
                * megapixels * Double(configuration.batchSize)
        ))
    }

    /// The text encoders' resident size: at the requested precision, unless the runtime
    /// never quantizes them.
    public static func textEncoderBytes(_ shape: DiffusionShape, _ quantization: Quantization) -> Bytes {
        shape.textEncoderBytesPerParameter.map {
            Bytes(Int64(Double(shape.textEncoderParameters) * $0))
        } ?? weightBytes(shape.textEncoderParameters, quantization)
    }

    /// The transformer's size once quantized — or `parameters` of it, for a slice such as one
    /// streamed block — counting the layers the runtime keeps at 8-bit when asked for 4.
    public static func quantizedTransformerBytes(
        _ shape: DiffusionShape, _ quantization: Quantization,
        parameters: Int64? = nil
    ) -> Bytes {
        let count = parameters ?? shape.transformerParameters
        guard quantization == .mlx4, shape.parametersKeptAt8BitWhen4Bit > 0,
              shape.transformerParameters > 0
        else { return weightBytes(count, quantization) }
        // A slice holds its share of the protected layers — they are one per block.
        let protected = Int64(
            (Double(shape.parametersKeptAt8BitWhen4Bit) * Double(count)
                / Double(shape.transformerParameters)).rounded()
        )
        return weightBytes(count - protected, quantization) + weightBytes(protected, .mlx8)
    }

    /// The VAE's resident size, the same way.
    public static func vaeBytes(_ shape: DiffusionShape, _ quantization: Quantization) -> Bytes {
        shape.vaeBytesPerParameter.map {
            Bytes(Int64(Double(shape.vaeParameters) * $0))
        } ?? weightBytes(shape.vaeParameters, quantization)
    }

    // MARK: - Planning

    public func plan(
        shape: DiffusionShape,
        configuration: ImageConfiguration,
        otherAppsInUse: Bytes = .zero
    ) -> DiffusionPlan {
        if shape.runsInStages {
            return stagedPlan(shape: shape, configuration: configuration, otherAppsInUse: otherAppsInUse)
        }
        let quantization = configuration.quantization

        let textEncoders = Self.textEncoderBytes(shape, quantization)
        let vae = Self.vaeBytes(shape, quantization)
        let latents = Self.latentBytes(shape, configuration)

        // Layer streaming: only the resident slice of the denoiser is in memory.
        var transformer = Self.residentWeightBytes(shape.transformerParameters)
        var loadedTransformer = Self.quantizedTransformerBytes(shape, quantization)
        var streamed = Bytes.zero
        var notes: [String] = []

        if let resident = configuration.residentBlocks, resident < shape.blockCount, resident > 0 {
            let perBlock = Self.residentWeightBytes(shape.parametersPerBlock)
            let full = transformer
            transformer = perBlock * Double(resident)
            loadedTransformer = Self.quantizedTransformerBytes(
                shape, quantization, parameters: shape.parametersPerBlock
            )
                * Double(resident)
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

        // Loading is sequential, and modelling it as simultaneous was the smaller half of issue
        // #3. mflux reads transformer, text encoder and VAE as separate safetensors, quantizing
        // and releasing each before opening the next, so only one component is ever at full
        // precision. Charging every component at full precision at once overstated klein-4B's
        // load by 8 GB.
        //
        // The largest component sets it, because the order the components are read in does not
        // matter to the worst case: whichever is biggest, it is at full precision while every
        // other one is either not yet read or already reduced. On klein-4B that is 8.30 GB for
        // the text encoder plus 2.30 GB for the rest, and 10.59 GB predicted against 10.52 GB
        // measured at 512x512, where this phase is what the run peaks at.
        let largestComponent = max(shape.transformerParameters, shape.textEncoderParameters)
        let transformerQuantized = Self.quantizedTransformerBytes(shape, quantization)
        let othersQuantized = largestComponent == shape.transformerParameters
            ? Self.weightBytes(shape.totalParameters - largestComponent, quantization)
            : transformerQuantized
                + Self.weightBytes(shape.totalParameters - largestComponent - shape.transformerParameters, quantization)
        let loadResident = configuration.weightsArePrequantized
            ? Self.weightBytes(shape.totalParameters - shape.transformerParameters, quantization)
                + transformerQuantized
            : Self.weightBytes(largestComponent, .f16) + othersQuantized

        if !configuration.weightsArePrequantized, quantization != .f16, quantization != .bf16 {
            notes.append(
                "Weights are downloaded at full precision and quantized one component at a time, "
                + "so loading peaks at \(loadResident.formatted) whatever precision was asked for. "
                + (configuration.canReuseQuantizedSave
                   ? "Saving a quantized copy removes that spike."
                   : "This runtime cannot load a quantized copy back for this model family, so "
                     + "the spike applies to every run, not just the first.")
            )
        }

        if !shape.peakIsCalibrated {
            notes.append(
                "This estimate is extrapolated. The memory model was fitted to measured "
                + "FLUX.2 klein runs; nothing in this model's family has been measured against "
                + "it, so treat the figure as an order of magnitude rather than a number."
            )
        }

        // The stages, in the order they run.
        let phases: [DiffusionPlan.Phase] = [
            .init(
                name: "Load",
                detail: configuration.weightsArePrequantized
                    ? "Reads weights already at the target precision"
                    : "Reads full-precision weights and quantizes them in memory",
                resident: loadResident
            ),
            // The transformer is charged at the size it was loaded at here, not at the two bytes
            // a parameter the phases below use. The step change happens the first time it runs:
            // whatever makes a running transformer cost its unquantized size, it has not happened
            // yet while the prompt is still being encoded. No measurement pins this phase — it
            // has never been the peak in any run measured — so it is left at the smaller of the
            // two rather than inflated on a guess.
            .init(
                name: "Encode",
                detail: "Text encoders turn the prompt into conditioning",
                resident: textEncoders + loadedTransformer + vae + latents
            ),
            .init(
                name: "Denoise",
                detail: "\(configuration.steps) steps through the transformer",
                resident: transformer + vae + latents
                    + Self.denoiseActivationBytes(shape, configuration)
                    + (configuration.evictTextEncoders ? .zero : textEncoders)
            ),
            // The transformer is still resident here. mflux does not free it before decoding —
            // which is why the decode peak tracks transformer size across models, and why this
            // phase rather than the load is what a 1024x1024 run actually peaks at.
            .init(
                name: "Decode",
                detail: "VAE reconstructs the image",
                resident: transformer + vae + latents
                    + Self.decodeActivationBytes(shape, configuration)
            ),
        ]

        return finished(
            phases: phases, streamed: streamed, notes: notes, shape: shape,
            configuration: configuration, otherAppsInUse: otherAppsInUse
        )
    }

    /// A runtime that runs the components one after another (`DiffusionShape.runsInStages`):
    /// the text encoder alone, then the transformer read block by block, then the VAE alone.
    /// The peak is the tallest stage, and no stage holds two of the three large components.
    ///
    /// The transformer is charged at the precision it was quantized to, not at the two bytes a
    /// parameter `residentBytesPerParameter` charges MFLUX's own entry points: those read it
    /// all in the same evaluation that first runs it, while the staged runner reads, merges
    /// and quantizes one block at a time and evaluates each before the next.
    func stagedPlan(
        shape: DiffusionShape, configuration: ImageConfiguration, otherAppsInUse: Bytes
    ) -> DiffusionPlan {
        let quantization = configuration.quantization
        let textEncoders = Self.textEncoderBytes(shape, quantization)
        // Read a layer at a time, the encoder holds only its embedding table and one layer.
        let encoding = shape.textEncoderStreamedParameters.map {
            Bytes(Int64(Double($0) * (shape.textEncoderBytesPerParameter
                ?? quantization.bitsPerWeight / 8)))
        } ?? textEncoders
        let vae = Self.vaeBytes(shape, quantization)
        let latents = Self.latentBytes(shape, configuration)
        let transformer = Self.quantizedTransformerBytes(shape, quantization)
        // While the transformer is read: one block at full precision on its way to being
        // quantized, with the adapter — if there is one — and the fp32 product it merges.
        let adapter = Bytes(shape.adapterParameters * 2)
        let block = Bytes(shape.parametersPerBlock * 2)
        let merging = shape.adapterParameters > 0 ? block * 2 + adapter : .zero

        var notes = [
            "Runs in stages: the text encoder is released before the transformer is read, "
                + "and the transformer before the VAE decodes, so the peak is the tallest "
                + "stage rather than the sum of them.",
        ]
        if let perParameter = shape.textEncoderBytesPerParameter,
           perParameter * 8 > quantization.bitsPerWeight {
            notes.append(
                shape.textEncoderStreamedParameters == nil
                    ? "The text encoder is never quantized — \(textEncoders.formatted) whatever "
                        + "precision is chosen — so a lower precision cannot shrink the encode stage."
                    : "The text encoder is never quantized (\(textEncoders.formatted)), so it is "
                        + "read a layer at a time as the prompt passes through it, holding "
                        + "\(encoding.formatted) at most."
            )
        }
        if !shape.peakIsCalibrated {
            notes.append(
                "This estimate is extrapolated. The memory model was fitted to measured "
                + "FLUX.2 klein runs; nothing in this model's family has been measured against "
                + "it, so treat the figure as an order of magnitude rather than a number."
            )
        }

        let phases: [DiffusionPlan.Phase] = [
            .init(
                name: "Encode",
                detail: shape.textEncoderStreamedParameters == nil
                    ? "The text encoder turns the prompt into conditioning, then is released"
                    : "The text encoder turns the prompt into conditioning, a layer at a time",
                resident: encoding + latents
            ),
            .init(
                name: "Load",
                detail: shape.adapterParameters > 0
                    ? "Reads the transformer a block at a time, merging the adapter and quantizing"
                    : "Reads the transformer a block at a time, quantizing as it goes",
                resident: transformer + block + merging
            ),
            .init(
                name: "Denoise",
                detail: "\(configuration.steps) steps through the transformer",
                resident: transformer + latents + Self.denoiseActivationBytes(shape, configuration)
            ),
            .init(
                name: "Decode",
                detail: configuration.lowRAM && shape.lowMemoryDecodeTileMegapixels != nil
                    ? "The transformer is released and the VAE reconstructs the image in tiles"
                    : "The transformer is released and the VAE reconstructs the image",
                resident: vae + latents + Self.decodeActivationBytes(shape, configuration)
            ),
        ]
        return finished(
            phases: phases, streamed: .zero, notes: notes, shape: shape,
            configuration: configuration, otherAppsInUse: otherAppsInUse
        )
    }

    /// The budget, the verdict and the remedies, shared by both kinds of plan.
    private func finished(
        phases: [DiffusionPlan.Phase], streamed: Bytes, notes: [String],
        shape: DiffusionShape, configuration: ImageConfiguration, otherAppsInUse: Bytes
    ) -> DiffusionPlan {
        // Metal keeps a floor for command buffers and pipeline state.
        let phases = phases.map {
            DiffusionPlan.Phase(name: $0.name, detail: $0.detail, resident: $0.resident + .mib(320))
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

        // Tiled decoding, where the runtime's low-memory mode really does tile this family's
        // decode — measured, unlike the families where it changes nothing.
        if peakName == "Decode", !configuration.lowRAM, shape.lowMemoryDecodeTileMegapixels != nil {
            var tiled = configuration
            tiled.lowRAM = true
            let saving = plan.peak - self.plan(shape: shape, configuration: tiled).peak
            if saving > .mib(256) {
                results.append(.init(
                    title: "Turn on low-memory mode to decode in tiles",
                    detail: "The VAE decodes the image a 512×512 tile at a time, holding one "
                        + "tile's working memory instead of the whole image's.",
                    saving: saving,
                    cost: "A little time at the end of each image.",
                    kind: .reduceContext
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

        // There used to be a "decode the image in tiles" suggestion here. It is gone because
        // mflux 0.18.1 had no tiled-decode flag — the app was passing `--low-ram` and calling it
        // tiling, and `--low-ram` was measured to change the peak by nothing at all. 0.20.0 has
        // `--vae-tiling`, unmeasured here and so not offered. Lowering the resolution is the
        // only lever known to act on the decode, and it is already below.

        // Resolution is the strongest lever, because the decode scales with area and the decode
        // is what peaks.
        if configuration.width > 512 || configuration.height > 512 {
            let smaller = ImageConfiguration(
                width: max(512, configuration.width / 2),
                height: max(512, configuration.height / 2),
                steps: configuration.steps, quantization: configuration.quantization,
                evictTextEncoders: configuration.evictTextEncoders,
                lowRAM: configuration.lowRAM,
                residentBlocks: configuration.residentBlocks, batchSize: configuration.batchSize
            )
            let saving = plan.peak - self.plan(shape: shape, configuration: smaller).peak
            if saving > .mib(256) {
                results.append(.init(
                    title: "Render at \(smaller.width)×\(smaller.height)",
                    detail: "The VAE decode costs about "
                        + "\(Bytes(Int64(Self.decodeBytesPerMegapixel)).formatted) per megapixel, "
                        + "so halving each side takes three quarters of it off the peak.",
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
