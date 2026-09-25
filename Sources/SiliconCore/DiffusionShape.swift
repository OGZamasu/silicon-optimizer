import Foundation

/// What kind of model this is, and therefore which memory model applies.
///
/// The two are not variations on a theme. A language model's memory is dominated by a KV cache
/// that grows with conversation length; a diffusion model has no such thing, and is instead
/// dominated by latent tensors that grow with image area and by a decode step that briefly
/// dwarfs everything else. Sharing one estimator between them would produce confident numbers
/// that describe neither.
public enum ModelKind: String, Sendable, Codable, CaseIterable {
    case language
    case diffusion

    public var label: String {
        switch self {
        case .language: "Language"
        case .diffusion: "Image"
        }
    }
}

/// Dimensions a diffusion image model needs for memory planning.
///
/// Modern image models are diffusion transformers: a stack of DiT blocks operating on a
/// latent grid, wrapped by a VAE that encodes and decodes pixels, and conditioned by one or
/// more text encoders. All four contribute memory, and they do so at different moments — which
/// is the part a naive "file size plus a bit" estimate misses entirely.
public struct DiffusionShape: Hashable, Sendable, Codable {

    /// Transformer blocks in the denoiser. The unit of layer streaming, exactly as a routed
    /// expert is for a mixture-of-experts language model.
    public var blockCount: Int
    /// Width of the residual stream inside those blocks.
    public var hiddenSize: Int
    /// Attention heads in a block.
    public var headCount: Int

    /// Parameters in the denoiser itself.
    public var transformerParameters: Int64
    /// Parameters in the VAE. Small in count, but its decode step is a memory spike.
    public var vaeParameters: Int64
    /// Parameters across every text encoder. FLUX carries both CLIP and a T5, and the T5 alone
    /// is larger than some language models.
    public var textEncoderParameters: Int64

    /// How much each spatial dimension shrinks between pixels and latents. 8 for every
    /// mainstream VAE.
    public var vaeScaleFactor: Int
    /// Channels in the latent grid.
    public var latentChannels: Int
    /// Pixels per side of one latent patch the transformer treats as a token.
    public var patchSize: Int

    /// Tokens the text encoder produces, which set the cross-attention width.
    public var maxTextTokens: Int
    /// The resolution the model was trained for, used as the planning default.
    public var nativeResolution: Int
    /// Denoising steps a good result normally needs. Distilled models need very few.
    public var defaultSteps: Int

    /// Whether this model's family has been measured against the planner's memory model.
    ///
    /// The coefficients in `DiffusionPlanner` were fitted to FLUX.2 klein runs. Applying them to
    /// a family nobody has measured is a guess, and the honest thing is to say which is which
    /// rather than print both to two decimal places and let them look alike.
    public var peakIsCalibrated: Bool

    /// What a text-encoder parameter costs when the runtime never quantizes it, whatever the
    /// precision asked for: 2 for Qwen-Image 2.1's Qwen3-VL, which mflux keeps in bf16 because
    /// quantizing it degrades the conditioning. Nil when it is quantized with the rest.
    public var textEncoderBytesPerParameter: Double?

    /// The same for the VAE: 4 where it is stored and run in fp32 (Qwen-Image 2.1's is), since
    /// its convolutions are not something MLX quantizes. Nil when it follows the precision.
    public var vaeBytesPerParameter: Double?

    /// Parameters of a LoRA adapter merged into the transformer as it loads — read, merged and
    /// released while the transformer is prepared. Zero for a plain model.
    public var adapterParameters: Int64

    /// Whether the runtime runs the three components one after another with nothing
    /// overlapping: the prompt is encoded and the text encoder released before the
    /// transformer is read, the transformer is read one block at a time, and it is released
    /// before the VAE decodes. The app's Qwen-Image 2.1 runner does; MFLUX's own entry points
    /// keep the transformer through the decode.
    public var runsInStages: Bool

    /// The most of the text encoder resident at once when the runtime reads it a layer at a
    /// time — its embedding table and one layer — or nil when it is resident whole.
    public var textEncoderStreamedParameters: Int64?

    /// Working memory the VAE decode needs per megapixel, measured for this family's VAE.
    /// Nil takes the planner's figure, which was measured on the FLUX VAE.
    public var decodeBytesPerMegapixel: Double?

    /// Working memory a denoising step needs per megapixel beyond the weights, measured for
    /// this family's transformer. Nil takes the planner's per-token estimate.
    public var denoiseBytesPerMegapixel: Double?

    /// Transformer parameters the runtime keeps at 8-bit when asked for 4. mflux 0.20.0's
    /// Qwen-Image keeps each block's `img_mod_linear` (3072→18432, 60 blocks: 3.40B
    /// parameters) at 8-bit under `-q 4`, where 4-bit error compounds across the steps; no
    /// other family in the catalogue protects anything, and nothing is protected at 6 or 8.
    public var parametersKeptAt8BitWhen4Bit: Int64

    /// The area, in megapixels, of the tiles the runtime decodes in when low-memory mode is on,
    /// or nil when low-memory mode does not tile this family's decode (FLUX.2's VAE opts out
    /// of it, which is why the mode was measured to change nothing there).
    public var lowMemoryDecodeTileMegapixels: Double?

    public var totalParameters: Int64 {
        transformerParameters + vaeParameters + textEncoderParameters
    }

    public init(
        blockCount: Int,
        hiddenSize: Int,
        headCount: Int,
        transformerParameters: Int64,
        vaeParameters: Int64,
        textEncoderParameters: Int64,
        vaeScaleFactor: Int = 8,
        latentChannels: Int = 16,
        patchSize: Int = 2,
        maxTextTokens: Int = 512,
        nativeResolution: Int = 1024,
        defaultSteps: Int = 20,
        peakIsCalibrated: Bool = false,
        textEncoderBytesPerParameter: Double? = nil,
        vaeBytesPerParameter: Double? = nil,
        adapterParameters: Int64 = 0,
        runsInStages: Bool = false,
        textEncoderStreamedParameters: Int64? = nil,
        decodeBytesPerMegapixel: Double? = nil,
        denoiseBytesPerMegapixel: Double? = nil,
        parametersKeptAt8BitWhen4Bit: Int64 = 0,
        lowMemoryDecodeTileMegapixels: Double? = nil
    ) {
        self.blockCount = blockCount
        self.hiddenSize = hiddenSize
        self.headCount = headCount
        self.transformerParameters = transformerParameters
        self.vaeParameters = vaeParameters
        self.textEncoderParameters = textEncoderParameters
        self.vaeScaleFactor = vaeScaleFactor
        self.latentChannels = latentChannels
        self.patchSize = patchSize
        self.maxTextTokens = maxTextTokens
        self.nativeResolution = nativeResolution
        self.defaultSteps = defaultSteps
        self.peakIsCalibrated = peakIsCalibrated
        self.textEncoderBytesPerParameter = textEncoderBytesPerParameter
        self.vaeBytesPerParameter = vaeBytesPerParameter
        self.adapterParameters = adapterParameters
        self.runsInStages = runsInStages
        self.textEncoderStreamedParameters = textEncoderStreamedParameters
        self.decodeBytesPerMegapixel = decodeBytesPerMegapixel
        self.denoiseBytesPerMegapixel = denoiseBytesPerMegapixel
        self.parametersKeptAt8BitWhen4Bit = parametersKeptAt8BitWhen4Bit
        self.lowMemoryDecodeTileMegapixels = lowMemoryDecodeTileMegapixels
    }

    // Decoded field by field so a shape written before a field existed still reads: every
    // field added after the first release has a default, and an absent one takes it.
    private enum CodingKeys: String, CodingKey {
        case blockCount, hiddenSize, headCount, transformerParameters, vaeParameters
        case textEncoderParameters, vaeScaleFactor, latentChannels, patchSize, maxTextTokens
        case nativeResolution, defaultSteps, peakIsCalibrated, textEncoderBytesPerParameter
        case vaeBytesPerParameter, adapterParameters, runsInStages, decodeBytesPerMegapixel
        case textEncoderStreamedParameters, lowMemoryDecodeTileMegapixels, denoiseBytesPerMegapixel
        case parametersKeptAt8BitWhen4Bit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            blockCount: try container.decode(Int.self, forKey: .blockCount),
            hiddenSize: try container.decode(Int.self, forKey: .hiddenSize),
            headCount: try container.decode(Int.self, forKey: .headCount),
            transformerParameters: try container.decode(Int64.self, forKey: .transformerParameters),
            vaeParameters: try container.decode(Int64.self, forKey: .vaeParameters),
            textEncoderParameters: try container.decode(Int64.self, forKey: .textEncoderParameters),
            vaeScaleFactor: try container.decode(Int.self, forKey: .vaeScaleFactor),
            latentChannels: try container.decode(Int.self, forKey: .latentChannels),
            patchSize: try container.decode(Int.self, forKey: .patchSize),
            maxTextTokens: try container.decode(Int.self, forKey: .maxTextTokens),
            nativeResolution: try container.decode(Int.self, forKey: .nativeResolution),
            defaultSteps: try container.decode(Int.self, forKey: .defaultSteps),
            peakIsCalibrated: try container.decodeIfPresent(Bool.self, forKey: .peakIsCalibrated) ?? false,
            textEncoderBytesPerParameter: try container.decodeIfPresent(
                Double.self, forKey: .textEncoderBytesPerParameter
            ),
            vaeBytesPerParameter: try container.decodeIfPresent(Double.self, forKey: .vaeBytesPerParameter),
            adapterParameters: try container.decodeIfPresent(Int64.self, forKey: .adapterParameters) ?? 0,
            runsInStages: try container.decodeIfPresent(Bool.self, forKey: .runsInStages) ?? false,
            textEncoderStreamedParameters: try container.decodeIfPresent(
                Int64.self, forKey: .textEncoderStreamedParameters
            ),
            decodeBytesPerMegapixel: try container.decodeIfPresent(
                Double.self, forKey: .decodeBytesPerMegapixel
            ),
            denoiseBytesPerMegapixel: try container.decodeIfPresent(
                Double.self, forKey: .denoiseBytesPerMegapixel
            ),
            parametersKeptAt8BitWhen4Bit: try container.decodeIfPresent(
                Int64.self, forKey: .parametersKeptAt8BitWhen4Bit
            ) ?? 0,
            lowMemoryDecodeTileMegapixels: try container.decodeIfPresent(
                Double.self, forKey: .lowMemoryDecodeTileMegapixels
            )
        )
    }

    /// Parameters held in one transformer block, which is what a streaming slot costs.
    public var parametersPerBlock: Int64 {
        blockCount > 0 ? transformerParameters / Int64(blockCount) : 0
    }

    /// Side length of the latent grid for a given image size.
    public func latentSide(forImageSide pixels: Int) -> Int {
        max(1, pixels / vaeScaleFactor)
    }

    /// Tokens the transformer attends over for a given image size.
    ///
    /// The latent grid is divided into patches, and each patch is one token. Attention cost is
    /// quadratic in this number, which is why doubling image width quadruples the activation
    /// memory rather than doubling it.
    public func spatialTokens(width: Int, height: Int) -> Int {
        let latentWidth = latentSide(forImageSide: width) / patchSize
        let latentHeight = latentSide(forImageSide: height) / patchSize
        return max(1, latentWidth * latentHeight)
    }

    /// Elements in the latent tensor carried between denoising steps.
    public func latentElements(width: Int, height: Int) -> Int64 {
        Int64(latentChannels)
            * Int64(latentSide(forImageSide: width))
            * Int64(latentSide(forImageSide: height))
    }
}
