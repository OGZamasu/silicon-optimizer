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

    /// Exactly the files the runtime fetches, and nothing else.
    ///
    /// Copied from mflux's own `get_download_patterns()` rather than guessed, because both
    /// directions of the guess are expensive: FLUX.2-klein-4B carries a 7.8 GB single-file
    /// variant that is never opened, and FLUX.1 keeps its T5-XXL in `text_encoder_2`, which an
    /// obvious-looking four-directory list silently omits — 9.5 GB of the model, missing, with
    /// the download reporting success.
    public var downloadPatterns: [String]

    /// Directories that must contain weights for the model to count as installed.
    public var componentDirectories: [String]

    public init(
        id: String, name: String, author: String, license: String, summary: String,
        shape: DiffusionShape, repository: String, quantizations: [Quantization],
        rating: Int, isGated: Bool = false, supportsQuantizedReuse: Bool = true,
        downloadPatterns: [String], componentDirectories: [String]
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
        self.downloadPatterns = downloadPatterns
        self.componentDirectories = componentDirectories
    }

    /// What `mflux-generate` fetches for the FLUX.1 family. Note `text_encoder_2` — the T5-XXL,
    /// and the largest single file in the repository.
    public static let flux1Patterns = [
        "text_encoder/*.safetensors", "text_encoder/*.json",
        "text_encoder_2/*.safetensors", "text_encoder_2/*.json",
        "transformer/*.safetensors", "transformer/*.json",
        "vae/*.safetensors", "vae/*.json",
        "tokenizer/**", "tokenizer_2/**",
    ]

    /// What `mflux-generate-flux2` fetches. One text encoder rather than two, and a chat
    /// template at the repository root, which a directory-shaped pattern list misses.
    public static let flux2Patterns = [
        "text_encoder/*.safetensors", "text_encoder/*.json",
        "transformer/*.safetensors", "transformer/*.json",
        "vae/*.safetensors", "vae/*.json",
        "tokenizer/**", "added_tokens.json", "chat_template.jinja",
    ]

    /// What `mflux-generate-qwen` fetches — copied from `QwenWeightDefinition.get_download_patterns()`
    /// in the installed mflux package rather than guessed from the repository's own file listing.
    /// That listing also has a `scheduler/` directory mflux never reads.
    public static let qwenImagePatterns = [
        "vae/*.safetensors", "vae/*.json",
        "transformer/*.safetensors", "transformer/*.json",
        "text_encoder/*.safetensors", "text_encoder/*.json",
        "tokenizer/**", "added_tokens.json", "chat_template.jinja",
    ]

    /// What `mflux-generate-z-image`/`-z-image-turbo` fetch, from `ZImageWeightDefinition`.
    public static let zImagePatterns = [
        "vae/*.safetensors", "vae/*.json",
        "transformer/*.safetensors", "transformer/*.json",
        "text_encoder/*.safetensors", "text_encoder/*.json",
        "tokenizer/*",
    ]

    /// What `mflux-generate-ernie-image`/`-turbo` fetch, from `ErnieWeightDefinition`. The
    /// repository also carries a `pe/` directory of comparable size to the text encoder — mflux
    /// never reads it, and fetching it anyway would roughly double the download for nothing.
    public static let erniePatterns = [
        "vae/*.safetensors", "vae/*.json",
        "transformer/*.safetensors", "transformer/*.json",
        "text_encoder/*.safetensors", "text_encoder/*.json",
        "tokenizer/**",
    ]

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
        fluxKreaDev, qwenImage, zImageTurbo, zImage, ernieImageTurbo, ernieImage,
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
        isGated: true,
        downloadPatterns: DiffusionEntry.flux1Patterns,
        componentDirectories: ["transformer", "text_encoder", "text_encoder_2", "vae"]
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
            defaultSteps: 8,
            peakIsCalibrated: true
        ),
        repository: "black-forest-labs/FLUX.2-klein-4B",
        quantizations: [.mlx4, .mlx6, .mlx8],
        rating: 4,
        supportsQuantizedReuse: false,
        downloadPatterns: DiffusionEntry.flux2Patterns,
        componentDirectories: ["transformer", "text_encoder", "vae"]
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
            defaultSteps: 8,
            peakIsCalibrated: true
        ),
        repository: "black-forest-labs/FLUX.2-klein-9B",
        quantizations: [.mlx4, .mlx6, .mlx8],
        rating: 4,
        isGated: true,
        supportsQuantizedReuse: false,
        downloadPatterns: DiffusionEntry.flux2Patterns,
        componentDirectories: ["transformer", "text_encoder", "vae"]
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
        isGated: true,
        downloadPatterns: DiffusionEntry.flux1Patterns,
        componentDirectories: ["transformer", "text_encoder", "text_encoder_2", "vae"]
    )

    /// FLUX.1-Krea-dev — a Black Forest Labs / Krea finetune of FLUX.1-dev, not a different
    /// architecture: `transformer/config.json` on the repository is identical to dev's (19
    /// double-stream plus 38 single-stream blocks, 3072 wide, 24 heads), so it shares dev's
    /// shape numbers and entry point rather than repeating a guess.
    public static let fluxKreaDev = DiffusionEntry(
        id: "flux1-krea-dev",
        name: "FLUX.1 Krea dev",
        author: "Black Forest Labs / Krea",
        license: "FLUX.1 Non-Commercial Licence",
        summary: """
            A dev finetune tuned against Krea's own aesthetic preference data for more \
            photorealistic output. Same cost as dev; non-commercial licence, gated.
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
        repository: "black-forest-labs/FLUX.1-Krea-dev",
        quantizations: [.mlx4, .mlx6, .mlx8],
        rating: 4,
        isGated: true,
        downloadPatterns: DiffusionEntry.flux1Patterns,
        componentDirectories: ["transformer", "text_encoder", "text_encoder_2", "vae"]
    )

    /// Qwen-Image — 60 transformer blocks, 3072 wide (24 heads × 128), from
    /// `transformer/config.json`. Parameter counts from the safetensors index `total_size`
    /// (bf16, so ÷2): 20.4B transformer, 8.3B text encoder — the text encoder is Qwen2.5-VL,
    /// a full vision-language model used purely for its text understanding here.
    ///
    /// Not measured against a real run, unlike FLUX.2 klein: `peakIsCalibrated` stays false.
    public static let qwenImage = DiffusionEntry(
        id: "qwen-image",
        name: "Qwen-Image",
        author: "Qwen",
        license: "Apache-2.0",
        summary: """
            A 20B-parameter model with unusually strong text rendering inside the image \
            itself. Its text encoder is a full 8B vision-language model, which is most of \
            what it costs to load.
            """,
        shape: DiffusionShape(
            blockCount: 60,
            hiddenSize: 3072,
            headCount: 24,
            transformerParameters: 20_430_000_000,
            vaeParameters: 127_000_000,
            textEncoderParameters: 8_292_000_000,
            vaeScaleFactor: 8,
            latentChannels: 16,
            patchSize: 2,
            maxTextTokens: 512,
            nativeResolution: 1328,
            defaultSteps: 20
        ),
        repository: "Qwen/Qwen-Image",
        quantizations: [.mlx4, .mlx6, .mlx8],
        rating: 4,
        // mflux-save writes a quantized copy, but the entry point's own --base-model handling
        // has the same "dropped on the floor" bug documented against FLUX.2 and Z-Image below —
        // unconfirmed for this family specifically, so treated the same until proven otherwise.
        supportsQuantizedReuse: false,
        downloadPatterns: DiffusionEntry.qwenImagePatterns,
        componentDirectories: ["transformer", "text_encoder", "vae"]
    )

    /// Z-Image-Turbo — 30 blocks, 3840 wide, 30 heads, from `transformer/config.json`. The
    /// repository ships the transformer in fp32 (double the byte count of the base Z-Image
    /// repository's bf16 for an identical parameter count) — divided out below, both entries
    /// agree on 6.15B transformer parameters. Text encoder is the same Qwen3-class model
    /// shared with base Z-Image, at 4.0B.
    public static let zImageTurbo = DiffusionEntry(
        id: "z-image-turbo",
        name: "Z-Image Turbo",
        author: "Tongyi-MAI",
        license: "Apache-2.0",
        summary: """
            Distilled for speed at 6B parameters total — the smallest model in this catalogue \
            by a wide margin, and correspondingly the cheapest to load.
            """,
        shape: DiffusionShape(
            blockCount: 30,
            hiddenSize: 3840,
            headCount: 30,
            transformerParameters: 6_155_000_000,
            vaeParameters: 84_000_000,
            textEncoderParameters: 4_022_000_000,
            vaeScaleFactor: 8,
            latentChannels: 16,
            patchSize: 2,
            maxTextTokens: 512,
            nativeResolution: 1024,
            defaultSteps: 8
        ),
        repository: "Tongyi-MAI/Z-Image-Turbo",
        quantizations: [.mlx4, .mlx6, .mlx8],
        rating: 4,
        // Confirmed against mflux 0.18.1: mflux-save writes a quantized copy happily, but
        // mflux-generate-z-image(-turbo) drops --base-model on the floor reading one back.
        supportsQuantizedReuse: false,
        downloadPatterns: DiffusionEntry.zImagePatterns,
        componentDirectories: ["transformer", "text_encoder", "vae"]
    )

    /// Z-Image — the undistilled base of Z-Image-Turbo. Identical architecture; only the
    /// training and the recommended step count differ.
    public static let zImage = DiffusionEntry(
        id: "z-image",
        name: "Z-Image",
        author: "Tongyi-MAI",
        license: "Apache-2.0",
        summary: "The undistilled base Z-Image checkpoint Turbo was distilled from. Same size, more steps.",
        shape: DiffusionShape(
            blockCount: 30,
            hiddenSize: 3840,
            headCount: 30,
            transformerParameters: 6_155_000_000,
            vaeParameters: 84_000_000,
            textEncoderParameters: 4_022_000_000,
            vaeScaleFactor: 8,
            latentChannels: 16,
            patchSize: 2,
            maxTextTokens: 512,
            nativeResolution: 1024,
            defaultSteps: 20
        ),
        repository: "Tongyi-MAI/Z-Image",
        quantizations: [.mlx4, .mlx6, .mlx8],
        rating: 3,
        supportsQuantizedReuse: false,
        downloadPatterns: DiffusionEntry.zImagePatterns,
        componentDirectories: ["transformer", "text_encoder", "vae"]
    )

    /// ERNIE-Image-Turbo — 36 blocks, 4096 wide, 32 heads, from `transformer/config.json`.
    /// The repository also carries a `pe/` directory nearly as large as the text encoder;
    /// `ErnieWeightDefinition.get_download_patterns()` never reads it, so it is excluded from
    /// both the download and this shape's text-encoder parameter count.
    public static let ernieImageTurbo = DiffusionEntry(
        id: "ernie-image-turbo",
        name: "ERNIE-Image Turbo",
        author: "Baidu",
        license: "Apache-2.0",
        summary: "Baidu's distilled, fast image model. Text-heavy prompts are its particular strength.",
        shape: DiffusionShape(
            blockCount: 36,
            hiddenSize: 4096,
            headCount: 32,
            transformerParameters: 8_033_000_000,
            vaeParameters: 84_000_000,
            textEncoderParameters: 3_849_000_000,
            vaeScaleFactor: 8,
            latentChannels: 32,
            patchSize: 2,
            maxTextTokens: 2048,
            nativeResolution: 1024,
            defaultSteps: 8
        ),
        repository: "baidu/ERNIE-Image-Turbo",
        quantizations: [.mlx4, .mlx6, .mlx8],
        rating: 4,
        supportsQuantizedReuse: false,
        downloadPatterns: DiffusionEntry.erniePatterns,
        componentDirectories: ["transformer", "text_encoder", "vae"]
    )

    /// ERNIE-Image — the undistilled base ERNIE-Image-Turbo was distilled from. Identical
    /// transformer configuration to Turbo; only the training and step count differ.
    public static let ernieImage = DiffusionEntry(
        id: "ernie-image",
        name: "ERNIE-Image",
        author: "Baidu",
        license: "Apache-2.0",
        summary: "The undistilled base ERNIE-Image checkpoint Turbo was distilled from.",
        shape: DiffusionShape(
            blockCount: 36,
            hiddenSize: 4096,
            headCount: 32,
            transformerParameters: 8_033_000_000,
            vaeParameters: 84_000_000,
            textEncoderParameters: 3_849_000_000,
            vaeScaleFactor: 8,
            latentChannels: 32,
            patchSize: 2,
            maxTextTokens: 2048,
            nativeResolution: 1024,
            defaultSteps: 20
        ),
        repository: "baidu/ERNIE-Image",
        quantizations: [.mlx4, .mlx6, .mlx8],
        rating: 3,
        supportsQuantizedReuse: false,
        downloadPatterns: DiffusionEntry.erniePatterns,
        componentDirectories: ["transformer", "text_encoder", "vae"]
    )
}
