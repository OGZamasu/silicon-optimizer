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
        defaultSteps: Int = 20
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
