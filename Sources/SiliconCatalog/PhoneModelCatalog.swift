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
        /// How much memory the phone should see free before it loads this: the peak it
        /// measured, grown to `contextLength`, with a quarter again on top. See
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

    public static let all: [PhoneModelEntry] = [qwen35_2B, gemma4E2B]

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

    /// The free memory to ask for before loading: the measured peak, plus what the KV cache
    /// and the attention scratch grow by between the benchmark's context and `context`, with
    /// a quarter again on top — rounded up to a tenth of a gigabyte.
    ///
    /// The growth is worked out from the model's own header rather than guessed: only the
    /// layers that attend over the whole context grow with it (Qwen3.5 attends fully in one
    /// layer in four and runs the rest as a fixed-size recurrent state; Gemma 4 E2B shares
    /// its last twenty layers' cache and keeps most of its own to a 512-token window), at
    /// f16 for the cache and f32 for a 512-token batch's attention scores.
    static func minimumFreeMemory(
        peak: Int64, cacheBytesPerToken: Int64, attentionHeads: Int64, context: Int64
    ) -> Int64 {
        let grownTokens = context - Int64(benchmarkContextTokens)
        let cache = cacheBytesPerToken * grownTokens
        let scores = attentionHeads * 512 * grownTokens * 4
        let needed = Double(peak + cache + scores) * 1.25
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
                peak: qwenPeak, cacheBytesPerToken: 6 * 2 * (256 + 256) * 2,
                attentionHeads: 8, context: 4096
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
                peak: gemmaPeak, cacheBytesPerToken: 3 * 1 * (512 + 512) * 2,
                attentionHeads: 8, context: 4096
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
