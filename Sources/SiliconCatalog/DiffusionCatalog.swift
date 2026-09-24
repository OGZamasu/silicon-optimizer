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
    /// Hugging Face repository the runtime fetches weights from — for an adapter entry, the
    /// adapter's own repository, which is the page its licence is on and the only thing
    /// removing it removes. Its weights come from `weightsRepository`.
    public var repository: String
    /// Bit widths this model is worth running at, best first.
    public var quantizations: [Quantization]
    public var rating: Int
    /// Whether the licence requires accepting terms on Hugging Face before download.
    public var isGated: Bool
    /// Whether a locally saved quantized copy can be loaded back for this family.
    ///
    /// False for FLUX.2 and Z-Image: `mflux-save` writes them happily, but in mflux 0.18.1 the
    /// matching generate entry point dropped `--base-model` on the floor, so reading one back
    /// failed. 0.20.0 forwards it, but nothing in this app renders from a saved copy yet — every
    /// entry runs from its Hub weights — so the flags stay as they were until that path exists
    /// and has been tried.
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

    /// The commit the weights are fetched and read at, or nil for the older entries, which
    /// follow the repository's `main`. A pinned entry is fetched with `--revision` and run from
    /// exactly that snapshot, so what renders is the revision that was reviewed.
    ///
    /// Like `downloadPatterns` and `componentDirectories`, this describes the weights in
    /// `weightsRepository` — for an adapter entry, its base's.
    public var revision: String?

    /// The entry whose weights this one runs on, when it is an adapter rather than a model:
    /// installing it installs that entry's weights too, and removing it never removes them.
    public var baseEntryID: String?

    /// The LoRA adapter this entry merges into its base's weights before rendering.
    public var adapter: DiffusionAdapter?

    public init(
        id: String, name: String, author: String, license: String, summary: String,
        shape: DiffusionShape, repository: String, quantizations: [Quantization],
        rating: Int, isGated: Bool = false, supportsQuantizedReuse: Bool = true,
        downloadPatterns: [String], componentDirectories: [String],
        revision: String? = nil, baseEntryID: String? = nil, adapter: DiffusionAdapter? = nil
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
        self.revision = revision
        self.baseEntryID = baseEntryID
        self.adapter = adapter
    }

    /// Where the weights `downloadPatterns` name live: the base entry's repository for an
    /// adapter, this entry's own otherwise.
    public var weightsRepository: String {
        baseEntryID.flatMap(DiffusionCatalog.entry(id:))?.repository ?? repository
    }

    /// The step counts this entry can run at, when it cannot run at any other: an adapter is
    /// trained for its own sigma schedule and nothing else. Nil means any count.
    public var stepChoices: [Int]? {
        adapter.map { $0.variants.map(\.steps) }
    }

    /// `steps` if this entry can run at it, otherwise the nearest count it can — the larger of
    /// two equally near, since the larger is the better image.
    public func normalizedSteps(_ steps: Int) -> Int {
        guard let choices = stepChoices, !choices.isEmpty, !choices.contains(steps)
        else { return steps }
        return choices.min {
            let (left, right) = (abs($0 - steps), abs($1 - steps))
            return left == right ? $0 > $1 : left < right
        }!
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

    /// What `mflux-generate-qwen-2.1` reads, from mflux 0.20.0's `Qwen21WeightDefinition`: its
    /// `get_download_patterns()` plus the tokenizer definition's own `processor/**`. The
    /// repository also carries `scheduler/` and a 3 MB `assets/` image, neither of which it
    /// opens; the tokenizer lives in `processor/`, not `tokenizer/` as in every family above.
    public static let qwenImage21Patterns = [
        "vae/*.safetensors", "vae/*.json",
        "transformer/*.safetensors", "transformer/*.json",
        "text_encoder/*.safetensors", "text_encoder/*.json",
        "processor/**",
    ]

    public var parameterLabel: String {
        let billions = Double(shape.totalParameters) / 1e9
        return billions >= 10 ? String(format: "%.0fB", billions)
                              : String(format: "%.1fB", billions)
    }
}

/// A LoRA adapter published for a catalogue model: small files that change how its
/// transformer behaves, merged into the base weights before the run.
///
/// Each variant is trained for one sampler schedule and is useless with any other, which is why
/// the schedule lives beside the file here rather than in the runtime: the file and its sigmas
/// are one fact. The files' digests are not repeated here — they are in the reviewed manifest
/// `Scripts/pin-hub-models.sh` writes, which is what the download is checked against.
public struct DiffusionAdapter: Sendable, Codable, Hashable {

    public struct Variant: Sendable, Codable, Hashable, Identifiable {
        public var id: String { file }
        /// How the choice reads in a picker.
        public var label: String
        /// The adapter file inside the repository.
        public var file: String
        /// One per step, highest first. The terminal 0 is appended by the sampler, and nothing
        /// else is done to them: no shift, static or resolution-dependent.
        public var sigmas: [Double]

        public var steps: Int { sigmas.count }

        public init(label: String, file: String, sigmas: [Double]) {
            self.label = label
            self.file = file
            self.sigmas = sigmas
        }
    }

    public var repository: String
    /// The reviewed commit; the files are fetched from exactly this revision.
    public var revision: String
    /// What `B·A` is multiplied by when merged: PEFT's `lora_alpha / r`. The runner reads both
    /// from the file and refuses one whose ratio is not this.
    public var scale: Double
    /// Best first. Installing the entry fetches the first; the others are fetched the first
    /// time one is chosen.
    public var variants: [Variant]

    public init(repository: String, revision: String, scale: Double, variants: [Variant]) {
        self.repository = repository
        self.revision = revision
        self.scale = scale
        self.variants = variants
    }

    public var defaultVariant: Variant { variants[0] }

    public func variant(steps: Int) -> Variant? {
        variants.first { $0.steps == steps }
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
        qwenImage21, qwenImage21Pruna,
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
        // mflux-save writes a quantized copy, but through 0.18.1 the entry point's own
        // --base-model handling had the same "dropped on the floor" bug documented against
        // FLUX.2 and Z-Image below — unconfirmed for this family specifically, so treated the
        // same until proven otherwise. (0.20.0's qwen entry point still reads no --base-model.)
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
        // mflux-generate-z-image(-turbo) dropped --base-model on the floor reading one back.
        // 0.20.0 infers the family instead; see `supportsQuantizedReuse` for why this stays.
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

    // MARK: - Qwen-Image 2.1

    /// Qwen's Research Licence, which both Qwen-Image 2.1 and Pruna's adapters (a derivative
    /// of it) are distributed under: research and non-commercial use only.
    public static let qwenResearchLicence = "Qwen RESEARCH LICENSE AGREEMENT (research, non-commercial)"

    /// The Qwen-Image 2.1 commit both entries are fetched and run at.
    public static let qwenImage21Revision = "790c92633540aa0cb11d9abf19eb46d861714758"

    /// Qwen-Image 2.1 — a 7.1B single-stream, block-causal transformer (32 blocks, 32 heads ×
    /// 128, MLP ratio 3), a Qwen3-VL text encoder and a 64-channel causal VAE that compresses
    /// 16× per side, so one latent token covers a 16×16 pixel tile and there is no patching.
    /// Counted from the safetensors headers at the pinned revision: 7.115B transformer; the
    /// text-encoder files hold 8.77B, of which mflux loads only the 7.568B language model —
    /// the vision tower and the output head are never read — and always in bf16; the VAE is
    /// 338M parameters stored and run in fp32.
    public static let qwenImage21 = DiffusionEntry(
        id: "qwen-image-2.1",
        name: "Qwen-Image 2.1",
        author: "Qwen",
        license: qwenResearchLicence,
        summary: """
            Qwen's second-generation image model: a 7B transformer with strong text rendering, \
            behind a Qwen3-VL text encoder that is never quantized and is most of what it costs \
            to load. Forty steps and no guidance. Research licence — not for commercial use.
            """,
        shape: DiffusionShape(
            blockCount: 32,
            hiddenSize: 4096,
            headCount: 32,
            transformerParameters: 7_115_000_000,
            vaeParameters: 338_000_000,
            textEncoderParameters: 7_568_000_000,
            vaeScaleFactor: 16,
            latentChannels: 64,
            patchSize: 1,
            maxTextTokens: 2048,
            nativeResolution: 1024,
            defaultSteps: 40
        ),
        repository: "Qwen/Qwen-Image-2.1",
        quantizations: [.mlx4, .mlx6, .mlx8],
        rating: 4,
        // Its entry point has no --base-model at all, and the few-step entry below merges an
        // adapter into full-precision weights, which a quantized copy no longer has.
        supportsQuantizedReuse: false,
        downloadPatterns: DiffusionEntry.qwenImage21Patterns,
        componentDirectories: ["transformer", "text_encoder", "vae"],
        revision: qwenImage21Revision
    )

    /// Pruna's few-step LoRA adapters for Qwen-Image 2.1 (v0.1, DMD-trained): the same model,
    /// with one adapter merged into its transformer, in 8 steps or 5 instead of 40 — each on the
    /// sigma schedule it was trained for, with no guidance and no negative prompt. Trained at
    /// 1024² only. Runs on the base entry's weights; the adapter itself is one 336 MB file.
    public static let qwenImage21Pruna = DiffusionEntry(
        id: "qwen-image-2.1-pruna",
        name: "Qwen-Image 2.1 · Pruna few-step",
        author: "Pruna AI / Qwen",
        license: qwenResearchLicence,
        summary: """
            Qwen-Image 2.1 with Pruna's few-step adapter merged in: 8 steps instead of 40, or 5 \
            when speed matters more than finish. A first release — below the base model's \
            quality — trained at 1024². Uses Qwen-Image 2.1's weights plus one small file. \
            Research licence — not for commercial use.
            """,
        shape: DiffusionShape(
            blockCount: 32,
            hiddenSize: 4096,
            headCount: 32,
            transformerParameters: 7_115_000_000,
            vaeParameters: 338_000_000,
            textEncoderParameters: 7_568_000_000,
            vaeScaleFactor: 16,
            latentChannels: 64,
            patchSize: 1,
            maxTextTokens: 2048,
            nativeResolution: 1024,
            defaultSteps: 8
        ),
        repository: "PrunaAI/Pruna-Qwen-Image-2.1",
        quantizations: [.mlx4, .mlx6, .mlx8],
        rating: 3,
        supportsQuantizedReuse: false,
        downloadPatterns: DiffusionEntry.qwenImage21Patterns,
        componentDirectories: ["transformer", "text_encoder", "vae"],
        revision: qwenImage21Revision,
        baseEntryID: "qwen-image-2.1",
        adapter: DiffusionAdapter(
            repository: "PrunaAI/Pruna-Qwen-Image-2.1",
            revision: "113e63bb993001b3411eb3470b84fc444040cd7e",
            // lora_alpha 128 over r 64, from the files' own PEFT metadata.
            scale: 2.0,
            variants: [
                .init(
                    label: "8 steps",
                    file: "p_qwen_image_2.1_8step_v0.1.safetensors",
                    // Shift 2 on evenly spaced t, σ = 2t / (1 + t), as the model card gives it.
                    sigmas: [1.0, 14.0 / 15.0, 6.0 / 7.0, 10.0 / 13.0, 2.0 / 3.0, 6.0 / 11.0,
                             0.4, 2.0 / 9.0]
                ),
                .init(
                    label: "5 steps — faster, lower quality",
                    file: "p_qwen_image_2.1_5step_v0.1.safetensors",
                    sigmas: [1.0, 0.94, 6.0 / 7.0, 2.0 / 3.0, 0.4]
                ),
            ]
        )
    )
}
