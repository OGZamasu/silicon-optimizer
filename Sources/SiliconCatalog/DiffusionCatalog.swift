import Foundation
import SiliconCore

/// A diffusion image model in the curated list.
public struct DiffusionEntry: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var author: String
    public var license: String
    public var summary: String
    public var shape: DiffusionShape
    /// Hugging Face repository the runtime fetches weights from.
    public var repository: String
    /// Bit widths this model is worth running at, best first.
    public var quantizations: [Quantization]
    public var rating: Int
    /// Whether the licence requires accepting terms on Hugging Face before download.
    public var isGated: Bool
    /// Whether a locally saved quantized copy can be loaded back for this family.
    ///
    /// False for FLUX.2 and Z-Image: `mflux-save` writes them happily, but the matching generate
    /// entry point drops `--base-model` on the floor, so reading one back fails. Checked against
    /// mflux 0.18.1.
    public var supportsQuantizedReuse: Bool

    public init(
        id: String, name: String, author: String, license: String, summary: String,
        shape: DiffusionShape, repository: String, quantizations: [Quantization],
        rating: Int, isGated: Bool = false, supportsQuantizedReuse: Bool = true
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.license = license
        self.summary = summary
        self.shape = shape
        self.repository = repository
        self.quantizations = quantizations
        self.rating = rating
        self.isGated = isGated
        self.supportsQuantizedReuse = supportsQuantizedReuse
    }

    public var parameterLabel: String {
        let billions = Double(shape.totalParameters) / 1e9
        return billions >= 10 ? String(format: "%.0fB", billions)
                              : String(format: "%.1fB", billions)
    }
}

/// Curated image models, all runnable through MFLUX on Apple Silicon.
///
/// Architecture figures come from MFLUX's own model configuration rather than from model cards,
/// so the block counts and hidden sizes the planner works from are the ones the runtime will
/// actually construct.
public enum DiffusionCatalog {

    public static let all: [DiffusionEntry] = [
        fluxSchnell, flux2Klein4B, flux2Klein9B, fluxDev,
    ]

    public static func entry(id: String) -> DiffusionEntry? {
        all.first { $0.id == id }
    }

    /// FLUX.1-schnell — 19 double-stream plus 38 single-stream blocks, 3072 wide, 24 heads.
    /// Text conditioning is T5-XXL (4.76B) alongside CLIP-L (123M); the T5 alone is larger than
    /// several language models in this app's other catalog, which is why freeing it after
    /// encoding matters so much.
    public static let fluxSchnell = DiffusionEntry(
        id: "flux1-schnell",
        name: "FLUX.1 schnell",
        author: "Black Forest Labs",
        license: "Apache-2.0",
        summary: """
            Distilled for speed: four steps is enough for a finished image, where most models \
            need twenty or more. The best starting point on Apple Silicon, and permissively \
            licensed.
            """,
        shape: DiffusionShape(
            blockCount: 57,
            hiddenSize: 3072,
            headCount: 24,
            transformerParameters: 11_900_000_000,
            vaeParameters: 84_000_000,
            textEncoderParameters: 4_883_000_000,
            vaeScaleFactor: 8,
            latentChannels: 16,
            patchSize: 2,
            maxTextTokens: 256,
            nativeResolution: 1024,
            defaultSteps: 4
        ),
        repository: "black-forest-labs/FLUX.1-schnell",
        quantizations: [.mlx4, .mlx6, .mlx8],
        rating: 5,
        // Apache-2.0, but the repository itself is still gated (`gated: auto` on the Hub API):
        // the licence is permissive once you have the weights, and you accept terms to get them.
        // Checked against the API rather than inferred from the licence.
        isGated: true
    )

    /// FLUX.2-klein-4B — 5 double-stream plus 20 single-stream blocks, 2560 wide, 24 heads,
    /// with a compact text encoder rather than a T5-XXL.
    public static let flux2Klein4B = DiffusionEntry(
        id: "flux2-klein-4b",
        name: "FLUX.2 klein 4B",
        author: "Black Forest Labs",
        license: "FLUX.2 Community Licence",
        summary: """
            A quarter the size of schnell with a far smaller text encoder, so it fits where \
            nothing else will. The right choice on 16 GB machines.
            """,
        shape: DiffusionShape(
            blockCount: 25,
            hiddenSize: 2560,
            headCount: 24,
            // Counted from the safetensors headers of the downloaded weights rather than taken
            // from a model card: the text encoder is 4.15B, not the ~1.5B the name implies, and
            // it is the largest single component — it, not the transformer, sets the load peak.
            transformerParameters: 3_997_000_000,
            vaeParameters: 84_000_000,
            textEncoderParameters: 4_148_000_000,
            vaeScaleFactor: 8,
            latentChannels: 16,
            patchSize: 2,
            maxTextTokens: 512,
            nativeResolution: 1024,
            defaultSteps: 8
        ),
        repository: "black-forest-labs/FLUX.2-klein-4B",
        quantizations: [.mlx4, .mlx6, .mlx8],
        rating: 4,
        supportsQuantizedReuse: false
    )

    /// FLUX.2-klein-9B — 8 double-stream plus 24 single-stream blocks, 4096 wide, 32 heads.
    public static let flux2Klein9B = DiffusionEntry(
        id: "flux2-klein-9b",
        name: "FLUX.2 klein 9B",
        author: "Black Forest Labs",
        license: "FLUX.2 Community Licence",
        summary: "Noticeably stronger than the 4B at roughly twice the memory.",
        shape: DiffusionShape(
            blockCount: 32,
            hiddenSize: 4096,
            headCount: 32,
            transformerParameters: 9_000_000_000,
            vaeParameters: 84_000_000,
            textEncoderParameters: 2_500_000_000,
            vaeScaleFactor: 8,
            latentChannels: 16,
            patchSize: 2,
            maxTextTokens: 512,
            nativeResolution: 1024,
            defaultSteps: 8
        ),
        repository: "black-forest-labs/FLUX.2-klein-9B",
        quantizations: [.mlx4, .mlx6, .mlx8],
        rating: 4,
        isGated: true,
        supportsQuantizedReuse: false
    )

    /// FLUX.1-dev — same architecture as schnell but undistilled, so it needs many more steps
    /// and honours a guidance scale.
    public static let fluxDev = DiffusionEntry(
        id: "flux1-dev",
        name: "FLUX.1 dev",
        author: "Black Forest Labs",
        license: "FLUX.1 Non-Commercial Licence",
        summary: """
            The highest quality of the FLUX.1 family, at roughly five times the steps of \
            schnell. Non-commercial licence, and gated on Hugging Face.
            """,
        shape: DiffusionShape(
            blockCount: 57,
            hiddenSize: 3072,
            headCount: 24,
            transformerParameters: 11_900_000_000,
            vaeParameters: 84_000_000,
            textEncoderParameters: 4_883_000_000,
            vaeScaleFactor: 8,
            latentChannels: 16,
            patchSize: 2,
            maxTextTokens: 512,
            nativeResolution: 1024,
            defaultSteps: 20
        ),
        repository: "black-forest-labs/FLUX.1-dev",
        quantizations: [.mlx4, .mlx6, .mlx8],
        rating: 5,
        isGated: true
    )
}
