import Foundation

/// One model a paired phone can run by itself when this Mac is out of reach.
///
/// Not a `ModelEntry`, and deliberately so. These are files the Mac fetches *for* the phone
/// and serves to it over the tailnet — the phone stays tailnet-only, so it never talks to
/// Hugging Face itself — and nothing on the Mac ever loads them. Keeping them in their own
/// type is what keeps them out of `ModelCatalog.all`, `GET /catalog`, the recommender and
/// the load path: there is no way to hand one of these to a runtime by mistake, because no
/// runtime takes one.
///
/// Every field that says *which bytes* is a pin, not a hint. The Mac's own catalogue
/// resolves filenames against the Hub because community repositories rename things; here
/// the repository, the commit, the file, the size and the SHA-256 are all fixed, because a
/// phone is going to trust this file enough to run it, and the digest is what it checks.
public struct PhoneModelEntry: Sendable, Hashable, Identifiable {

    /// The catalogue key, and the only thing a request ever names. Never a path.
    public var id: String
    /// What a phone shows.
    public var label: String
    /// The one a phone offers first.
    public var isDefault: Bool
    /// Hugging Face repository, e.g. `bartowski/Qwen_Qwen3.5-2B-GGUF`.
    public var repository: String
    /// The commit the file is fetched at — `resolve/<commit>/<file>`, never `main`.
    public var commit: String
    /// A plain file name, with no folder in it. It becomes the file's name on the Mac.
    public var file: String
    public var sizeBytes: Int64
    /// Lower-case hex. The Mac verifies the download against it, serves it as the ETag, and
    /// the phone checks it again at the end of its own transfer.
    public var sha256: String
    public var licence: String
    public var recommended: Recommended
    /// Numbers taken on a real phone, so the phone can say what to expect before it spends
    /// a gigabyte finding out. Nil for a model nobody has measured.
    public var measured: Measured?
    /// Said out loud rather than left for the owner to discover: this one is larger and
    /// noticeably slower on the phone than the default.
    public var slowerOnPhone: Bool

    /// How the phone should run it.
    public struct Recommended: Sendable, Hashable {
        /// Threads for reading the prompt, and for writing the answer. They differ because
        /// the two phases are limited by different things — the prompt by arithmetic, the
        /// answer by memory bandwidth — and the phone's big cores are few.
        public var threadsPrompt: Int
        public var threadsGenerate: Int
        public var contextLength: Int
        /// How much memory the phone should see free before it loads this, as a gate: the
        /// weights, plus everything else the model was measured using — grown to
        /// `contextLength`, with a quarter again on top of that part only. The weights are
        /// memory-mapped from the file, so Android can drop those pages and read them back
        /// under pressure; padding them would refuse a model that runs. See
        /// `PhoneModelCatalog.minimumFreeMemory`.
        public var minFreeMemoryBytes: Int64
        /// Whether the chat template is rendered with thinking on. Off for both: a phone
        /// answering because the Mac is away should answer, not deliberate for a minute.
        public var thinking: Bool

        public init(
            threadsPrompt: Int, threadsGenerate: Int, contextLength: Int,
            minFreeMemoryBytes: Int64, thinking: Bool
        ) {
            self.threadsPrompt = threadsPrompt
            self.threadsGenerate = threadsGenerate
            self.contextLength = contextLength
            self.minFreeMemoryBytes = minFreeMemoryBytes
            self.thinking = thinking
        }
    }

    /// What one benchmark run on a real phone measured, and the one figure derived from it.
    public struct Measured: Sendable, Hashable {
        public var device: String
        /// Which build of which runtime, on which part of the chip.
        public var runtime: String
        /// What the phone was doing at the time. A hot, charging phone is the honest worst
        /// case, which is why it is the one written down.
        public var conditions: String
        /// Writing speed, in tokens a second, at `recommended.threadsGenerate` (llama-bench
        /// tg128, three runs).
        public var tokensPerSecond: Double
        /// Every thread count tried, with the writing speed it gave — the sweep
        /// `tokensPerSecond` was picked from.
        public var threadSweep: [ThreadSample]
        /// Prompt speed, in tokens a second, at `recommended.threadsPrompt` (llama-bench
        /// pp512, three runs). The time to the first word is worked out from it.
        public var promptTokensPerSecond: Double
        /// What a long answer settles to once the phone is hot (llama-bench tg256, ten runs),
        /// or nil when that has not been measured. Nil never means "does not slow down".
        public var sustainedTokensPerSecond: Double?
        /// The largest resident memory seen during the runs — at a context of at most
        /// `peakMemoryContextTokens`, well short of the 4,096 the phone is told to use.
        public var peakMemoryBytes: Int64
        public var peakMemoryContextTokens: Int

        public struct ThreadSample: Sendable, Hashable {
            public var threads: Int
            public var tokensPerSecond: Double

            public init(threads: Int, tokensPerSecond: Double) {
                self.threads = threads
                self.tokensPerSecond = tokensPerSecond
            }
        }

        /// Estimated, not measured: how long a 300-token question takes to read at
        /// `promptTokensPerSecond`, rounded *up* to a tenth of a second — the same way for
        /// every model, so a faster number is never a rounding accident. The answer's first
        /// word follows the last prompt token.
        public var secondsToFirstWord300: Double {
            (300 / promptTokensPerSecond * 10).rounded(.up) / 10
        }

        public init(
            device: String, runtime: String, conditions: String, tokensPerSecond: Double,
            threadSweep: [ThreadSample], promptTokensPerSecond: Double,
            sustainedTokensPerSecond: Double?, peakMemoryBytes: Int64,
            peakMemoryContextTokens: Int
        ) {
            self.device = device
            self.runtime = runtime
            self.conditions = conditions
            self.tokensPerSecond = tokensPerSecond
            self.threadSweep = threadSweep
            self.promptTokensPerSecond = promptTokensPerSecond
            self.sustainedTokensPerSecond = sustainedTokensPerSecond
            self.peakMemoryBytes = peakMemoryBytes
            self.peakMemoryContextTokens = peakMemoryContextTokens
        }
    }

    public init(
        id: String, label: String, isDefault: Bool, repository: String, commit: String,
        file: String, sizeBytes: Int64, sha256: String, licence: String,
        recommended: Recommended, measured: Measured?, slowerOnPhone: Bool
    ) {
        self.id = id
        self.label = label
        self.isDefault = isDefault
        self.repository = repository
        self.commit = commit
        self.file = file
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
        self.licence = licence
        self.recommended = recommended
        self.measured = measured
        self.slowerOnPhone = slowerOnPhone
    }

    /// Whether `file` is a bare name that cannot climb out of the folder it is joined to.
    /// Checked by the store before any path is built from it, and pinned by a test for the
    /// entries below — the one string here that ever becomes part of a path.
    public var hasPlainFileName: Bool {
        !file.isEmpty && file != "." && file != ".." && !file.contains("/")
            && !file.contains("\\") && !file.hasPrefix(".") && !file.contains("\0")
    }
}

/// The phone's fallback models, separate from `ModelCatalog` so they never appear as Mac
/// models, never reach a runtime here, and never land in the Mac's model library.
public enum PhoneModelCatalog {

    /// The default first, then the rest by size: a phone reading this list in order sees
    /// the one to use, then the one to fall back to when there is no room for it, then the
    /// one to take when there is room to spare.
    public static let all: [PhoneModelEntry] = [qwen35_2B, qwen35_08B, gemma4E2B]

    public static func entry(id: String) -> PhoneModelEntry? {
        all.first { $0.id == id }
    }

    public static var defaultEntry: PhoneModelEntry {
        all.first(where: \.isDefault) ?? qwen35_2B
    }

    /// Where the owner's own phone measured these: a Galaxy S24 Ultra running llama.cpp
    /// b11053 on the CPU, hot and on the charger, with llama-bench at 4 and 6 threads.
    static let measuredOn = "Galaxy S24 Ultra"
    static let measuredWith = "llama.cpp b11053, CPU"
    static let measuredWhile = "phone hot and charging"
    /// The largest context the benchmark ran at: a 512-token prompt and 128 tokens written.
    static let benchmarkContextTokens = 640

    /// The free memory to ask for before loading: the weights as they are, plus the rest of
    /// the measured peak — llama.cpp's repacked copy of the weights, the KV cache, scratch —
    /// grown from the benchmark's context to `context`, with a quarter again on top of that
    /// part, rounded up to a tenth of a gigabyte.
    ///
    /// The margin is on the working memory alone because the weights are memory-mapped: on a
    /// busy phone Android drops those pages and reads them back from the file, so a quarter
    /// on 3 GB of them would turn the gate into a refusal of a model that runs.
    ///
    /// The growth is worked out from the model's own header rather than guessed: only the
    /// layers that attend over the whole context grow with it (Qwen3.5 attends fully in one
    /// layer in four and runs the rest as a fixed-size recurrent state; Gemma 4 E2B shares
    /// its last twenty layers' cache and keeps most of its own to a 512-token window), at
    /// f16 for the cache and f32 for a 512-token batch's attention scores.
    static func minimumFreeMemory(
        peak: Int64, weights: Int64, cacheBytesPerToken: Int64, attentionHeads: Int64,
        context: Int64
    ) -> Int64 {
        let grownTokens = context - Int64(benchmarkContextTokens)
        let cache = cacheBytesPerToken * grownTokens
        let scores = attentionHeads * 512 * grownTokens * 4
        let working = Double(peak - weights + cache + scores) * 1.25
        let needed = Double(weights) + working
        return Int64((needed / 100_000_000).rounded(.up)) * 100_000_000
    }

    /// The default: 1.3 GB, quick to first word, and quick enough after it.
    public static let qwen35_2B = PhoneModelEntry(
        id: "qwen3.5-2b-q4_0",
        label: "Qwen3.5 2B",
        isDefault: true,
        repository: "bartowski/Qwen_Qwen3.5-2B-GGUF",
        commit: "7d26695454df6de5fbcce2e58681e62dae06ce43",
        file: "Qwen_Qwen3.5-2B-Q4_0.gguf",
        sizeBytes: 1_296_764_000,
        sha256: "91c102fc9a86de80e427057ee938e1e34fcaf3bba956b7296e252406e05f36f6",
        licence: "Apache-2.0",
        recommended: .init(
            threadsPrompt: 6, threadsGenerate: 4, contextLength: 4096,
            // 2,467 MiB measured; six full-attention layers of 2 KV heads × 256, 8 heads.
            minFreeMemoryBytes: minimumFreeMemory(
                peak: qwenPeak, weights: 1_296_764_000,
                cacheBytesPerToken: 6 * 2 * (256 + 256) * 2, attentionHeads: 8, context: 4096
            ),
            thinking: false
        ),
        measured: .init(
            device: measuredOn, runtime: measuredWith, conditions: measuredWhile,
            tokensPerSecond: 19.2,
            threadSweep: [.init(threads: 4, tokensPerSecond: 19.2),
                          .init(threads: 6, tokensPerSecond: 17.2)],
            promptTokensPerSecond: 122.9,
            // Never measured on a long answer, so not claimed either way.
            sustainedTokensPerSecond: nil,
            peakMemoryBytes: qwenPeak, peakMemoryContextTokens: benchmarkContextTokens
        ),
        slowerOnPhone: false
    )

    /// VmHWM of llama-bench on the phone: 2,467 MiB.
    static let qwenPeak: Int64 = 2_467 * 1_048_576

    /// A peak for a model nobody has run on a phone, from the one thing that can be known
    /// about it without running it: how big the file is.
    ///
    /// Everything the runtime holds beside the memory-mapped weights — llama.cpp's repacked
    /// copy of them, the recurrent state, the KV cache, the scratch and the graph — came to
    /// 0.99 times the weights when the S24 Ultra ran Qwen3.5 2B: the same architecture, the
    /// same build, the same phone. Taking it as a whole one times the weights is that
    /// measurement rounded the only safe way, and the round trip is pinned by a test — this
    /// applied to the 2B's own weights lands within a percent of its measured peak, and
    /// above it rather than below.
    ///
    /// It is an estimate and it is used for one thing: the free-memory gate, which is
    /// advice. Nothing derived from it is published to a phone as a measurement — an entry
    /// with no benchmark behind it carries `measured: nil`, and that is how the catalogue
    /// says nobody has run it.
    static func estimatedPeak(weights: Int64) -> Int64 { weights * 2 }

    /// The fallback for a phone with no room for the default, and nothing more than that.
    ///
    /// 0.56 GB against the default's 1.30, and a gate of 1.4 GB against its 3.1, so a phone
    /// with about 2.5 GB free — an ordinary evening on a Galaxy S24 Ultra — has something it
    /// can actually load. **Qwen3.5 2B stays the default and stays the better answer.** This
    /// is what a phone offers when the default will not fit, not a second recommendation:
    /// `isDefault` is false here and true there, and there is exactly one of those.
    ///
    /// llama.cpp's own conversion of the instruction-tuned release, Apache-2.0 and ungated,
    /// with the same chat template as the 2B — thinking off renders as an empty think block,
    /// so `thinking: false` is a thing the template can actually do. Uniformly Q4_0 apart
    /// from the 248,320-token embedding table, which it keeps at Q8_0: that table is nearly
    /// half the file, and it is the part a 0.8B model can least afford to lose. It carries no
    /// multi-token-prediction block, so the 24 layers in the file are the 24 the phone runs.
    public static let qwen35_08B = PhoneModelEntry(
        id: "qwen3.5-0.8b-q4_0",
        label: "Qwen3.5 0.8B",
        isDefault: false,
        repository: "ggml-org/Qwen3.5-0.8B-GGUF",
        commit: "8fea620810c4afa23dd6443f999a48574c1611a3",
        file: "Qwen3.5-0.8B-Q4_0.gguf",
        sizeBytes: 563_036_064,
        sha256: "57d1997790d1744fba5b40a7317df71ea5e2acee28c47e78f0cce39c0703f8cf",
        licence: "Apache-2.0",
        recommended: .init(
            // The threads are the 2B's, because the sweep that chose them was run on this
            // architecture, this build and this phone, and nobody has swept this model.
            threadsPrompt: 6, threadsGenerate: 4, contextLength: 4096,
            // 1,074 MiB estimated rather than measured — see `estimatedPeak`. The cache is
            // the header's own: `full_attention_interval` 4 over 24 layers is six layers
            // that attend over the whole context, each with 2 KV heads of 256 key and 256
            // value, at f16; the other eighteen are a fixed-size recurrent state that does
            // not grow. Eight attention heads, as the 2B has.
            minFreeMemoryBytes: minimumFreeMemory(
                peak: estimatedPeak(weights: 563_036_064), weights: 563_036_064,
                cacheBytesPerToken: 6 * 2 * (256 + 256) * 2, attentionHeads: 8, context: 4096
            ),
            thinking: false
        ),
        // Nobody has run this one on a phone, so there is nothing to report and nothing is
        // reported: nil, which the wire carries as no `measured` at all. Estimated speeds in
        // a field called `measured`, beside a device and a runtime that were never used,
        // would be an invention rather than a number.
        measured: nil,
        // Smaller and quicker than the default, not slower: the flag marks the model that
        // costs a phone something, and this one is what a phone falls back *to*.
        slowerOnPhone: false
    )

    /// Larger and slower on the phone: Google's quantization-aware Q4_0 of Gemma 4 E2B.
    /// Offered, never the default.
    public static let gemma4E2B = PhoneModelEntry(
        id: "gemma-4-e2b-q4_0",
        label: "Gemma 4 E2B",
        isDefault: false,
        repository: "google/gemma-4-E2B-it-qat-q4_0-gguf",
        commit: "675cff42a74c774d6cb76f76d8eacb49b48c9b93",
        file: "gemma-4-E2B_q4_0-it.gguf",
        sizeBytes: 3_349_516_256,
        sha256: "fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634",
        licence: "Apache-2.0",
        recommended: .init(
            threadsPrompt: 4, threadsGenerate: 6, contextLength: 4096,
            // 4,136 MiB measured; three global layers of 1 KV head × 512 own a growing cache.
            minFreeMemoryBytes: minimumFreeMemory(
                peak: gemmaPeak, weights: 3_349_516_256,
                cacheBytesPerToken: 3 * 1 * (512 + 512) * 2, attentionHeads: 8, context: 4096
            ),
            thinking: false
        ),
        measured: .init(
            device: measuredOn, runtime: measuredWith, conditions: measuredWhile,
            tokensPerSecond: 15.1,
            threadSweep: [.init(threads: 4, tokensPerSecond: 14.1),
                          .init(threads: 6, tokensPerSecond: 15.1)],
            promptTokensPerSecond: 92.6,
            sustainedTokensPerSecond: 7.5,
            peakMemoryBytes: gemmaPeak, peakMemoryContextTokens: benchmarkContextTokens
        ),
        slowerOnPhone: true
    )

    /// VmHWM of llama-bench on the phone, the higher of its two runs: 4,136 MiB.
    static let gemmaPeak: Int64 = 4_136 * 1_048_576
}
