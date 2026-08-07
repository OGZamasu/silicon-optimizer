import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore
@testable import SiliconHardware
@testable import SiliconPlanner

/// Builds a syntactically valid GGUF header in memory, so the parser can be tested without
/// keeping a multi-gigabyte fixture in the repository.
struct GGUFBuilder {
    enum Value {
        case uint32(UInt32)
        case string(String)
        case stringArray([String])
    }

    var architecture: String
    var values: [(String, Value)] = []
    /// name -> dimensions
    var tensors: [(String, [UInt64])] = []

    func write(to url: URL) throws {
        var data = Data()

        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt64(_ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendString(_ value: String) {
            let bytes = Array(value.utf8)
            appendUInt64(UInt64(bytes.count))
            data.append(contentsOf: bytes)
        }

        appendUInt32(0x4655_4747)                       // "GGUF"
        appendUInt32(3)                                 // version
        appendUInt64(UInt64(tensors.count))
        appendUInt64(UInt64(values.count + 1))          // + general.architecture

        appendString("general.architecture")
        appendUInt32(8)                                 // string
        appendString(architecture)

        for (key, value) in values {
            appendString(key)
            switch value {
            case .uint32(let number):
                appendUInt32(4)
                appendUInt32(number)
            case .string(let text):
                appendUInt32(8)
                appendString(text)
            case .stringArray(let items):
                appendUInt32(9)                         // array
                appendUInt32(8)                         // of strings
                appendUInt64(UInt64(items.count))
                for item in items { appendString(item) }
            }
        }

        for (name, dimensions) in tensors {
            appendString(name)
            appendUInt32(UInt32(dimensions.count))
            for dimension in dimensions { appendUInt64(dimension) }
            appendUInt32(0)                             // ggml type F32
            appendUInt64(0)                             // data offset
        }

        try data.write(to: url)
    }
}

@Suite("GGUF header parsing")
struct GGUFReaderTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gguf-test-\(UUID().uuidString).gguf")
    }

    @Test func readsArchitectureAndDimensions() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try GGUFBuilder(
            architecture: "qwen3moe",
            values: [
                ("qwen3moe.block_count", .uint32(48)),
                ("qwen3moe.embedding_length", .uint32(2048)),
                ("qwen3moe.attention.head_count", .uint32(32)),
                ("qwen3moe.attention.head_count_kv", .uint32(4)),
                ("qwen3moe.attention.key_length", .uint32(128)),
                ("qwen3moe.expert_count", .uint32(128)),
                ("qwen3moe.expert_used_count", .uint32(8)),
                ("qwen3moe.expert_feed_forward_length", .uint32(768)),
                ("qwen3moe.context_length", .uint32(262_144)),
                ("general.name", .string("Qwen3 30B A3B")),
            ]
        ).write(to: url)

        let reader = GGUFReader()
        let metadata = try reader.read(at: url)
        #expect(metadata.architecture == "qwen3moe")
        #expect(metadata.name == "Qwen3 30B A3B")

        let shape = try #require(reader.shape(from: metadata))
        #expect(shape.blockCount == 48)
        #expect(shape.embeddingLength == 2048)
        // The decoupled head width must come from the file, not from d_model / n_heads.
        #expect(shape.headDimension == 128)
        #expect(shape.moe?.expertCount == 128)
        #expect(shape.moe?.expertsUsedPerToken == 8)
    }

    /// A large token vocabulary is an array of >100k strings. The parser must walk past it
    /// without materialising it, or opening any real model would cost hundreds of megabytes.
    @Test func skipsLargeArraysWithoutLoadingThem() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try GGUFBuilder(
            architecture: "llama",
            values: [
                ("llama.block_count", .uint32(32)),
                ("llama.embedding_length", .uint32(4096)),
                ("llama.attention.head_count", .uint32(32)),
                ("tokenizer.ggml.tokens", .stringArray((0..<5000).map { "token\($0)" })),
                ("llama.feed_forward_length", .uint32(14_336)),
            ]
        ).write(to: url)

        let reader = GGUFReader()
        let metadata = try reader.read(at: url)
        // The key after the array must still parse — proving the skip landed exactly right.
        #expect(metadata.integer("feed_forward_length") == 14_336)
        if case .arrayOfCount(let count)? = metadata.values["tokenizer.ggml.tokens"] {
            #expect(count == 5000)
        } else {
            Issue.record("token array was not recorded as an array")
        }
    }

    @Test func rejectsNonGGUFFiles() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a gguf file at all".utf8).write(to: url)

        #expect(throws: GGUFReader.ReadError.self) {
            try GGUFReader().read(at: url)
        }
    }

    /// Regression: a GGUF opened without a catalog entry to fall back on reported zero total
    /// parameters, so the planner sized its weights at 0 bytes and declared any imported model
    /// free to load.
    @Test func derivesParameterCountFromTensorShapes() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try GGUFBuilder(
            architecture: "llama",
            values: [
                ("llama.block_count", .uint32(4)),
                ("llama.embedding_length", .uint32(512)),
                ("llama.attention.head_count", .uint32(8)),
                ("llama.feed_forward_length", .uint32(1024)),
            ],
            tensors: [
                ("token_embd.weight", [512, 32_000]),      // 16,384,000
                ("blk.0.attn_q.weight", [512, 512]),       //    262,144
                ("blk.0.ffn_up.weight", [512, 1024]),      //    524,288
            ]
        ).write(to: url)

        let reader = GGUFReader()
        let metadata = try reader.read(at: url)
        #expect(metadata.parameterCount == 16_384_000 + 262_144 + 524_288)

        let shape = try #require(reader.shape(from: metadata))
        #expect(shape.totalParameters == 17_170_432)

        // And the planner must now cost it as something rather than nothing.
        let planner = MemoryPlanner(profile: .unknownMac)
        let plan = planner.plan(
            shape: shape, quantization: .q4_K_M, configuration: LoadConfiguration()
        )
        #expect(plan.nonExpertWeights > .mib(8))
    }
}

@Suite("Active parameter derivation")
struct ActiveParameterTests {

    /// Regression: an imported MoE GGUF has no catalog entry, so `activeParameters` was zero.
    /// The speed estimator divided by it and produced a prompt-processing figure in the
    /// billions of tokens per second.
    @Test func moeWithoutCatalogMetadataStillEstimatesSanely() {
        let shape = ModelShape(
            totalParameters: 30_500_000_000, blockCount: 48, embeddingLength: 2048,
            feedForwardLength: 5472, headCount: 32, headCountKV: 4,
            trainingContextLength: 32_768, vocabSize: 151_936, headDimension: 128,
            moe: MoEShape(
                expertCount: 128, expertsUsedPerToken: 8, expertFeedForwardLength: 768,
                moeLayerCount: 48,
                activeParameters: 0,        // unknown, as it is for any imported file
                hasSharedExpert: false
            )
        )

        let profile = SystemProfile.unknownMac
        let planner = MemoryPlanner(profile: profile)
        let configuration = LoadConfiguration(contextLength: 4096)
        let plan = planner.plan(
            shape: shape, quantization: .q4_K_M, configuration: configuration
        )
        let speed = SpeedEstimator(profile: profile).estimate(
            shape: shape, quantization: .q4_K_M, configuration: configuration, plan: plan
        )

        // Qwen3-30B-A3B really has ~3.3B active parameters; the derived value should land near
        // it, and the prefill estimate should be plausible rather than astronomical.
        #expect(shape.effectiveActiveParameters > 2_000_000_000)
        #expect(shape.effectiveActiveParameters < 5_000_000_000)
        #expect(speed.prefillTokensPerSecond < 10_000)
    }

    @Test func catalogSuppliedActiveCountIsPreferred() {
        let shape = ModelCatalog.qwen3_30B_A3B.shape
        #expect(shape.effectiveActiveParameters == 3_300_000_000)
    }

    @Test func denseModelsReportTheirFullParameterCount() {
        let shape = ModelCatalog.qwen3_8B.shape
        #expect(shape.effectiveActiveParameters == shape.totalParameters)
    }
}

@Suite("Vision projector selection")
struct ProjectorSelectionTests {

    /// The real file list from unsloth/Qwen2.5-VL-7B-Instruct-GGUF.
    private var realRepo: [HuggingFaceClient.RepoFile] {
        [
            .init(path: "Qwen2.5-VL-7B-Instruct-Q4_K_M.gguf", size: .gib(4.36), sha256: "a"),
            .init(path: "mmproj-BF16.gguf", size: .gib(1.26), sha256: "b"),
            .init(path: "mmproj-F16.gguf", size: .gib(1.26), sha256: "c"),
            .init(path: "mmproj-F32.gguf", size: .gib(2.51), sha256: "d"),
        ]
    }

    private var resolver: ModelResolver { ModelResolver(client: HuggingFaceClient()) }

    /// Regression: selection was `first(where: contains("mmproj"))`, so whichever order the
    /// Hugging Face API returned decided the answer — and F32 is twice the download for no
    /// benefit on Apple Silicon.
    @Test func catalogHintWins() {
        let picked = resolver.selectProjector(from: realRepo, hint: "mmproj-F16.gguf")
        #expect(picked?.path == "mmproj-F16.gguf")
    }

    @Test func fallsBackToF16WhenTheHintIsStale() {
        let picked = resolver.selectProjector(from: realRepo, hint: "mmproj-does-not-exist.gguf")
        #expect(picked?.path == "mmproj-F16.gguf")
    }

    @Test func prefersBF16OverF32WhenF16IsAbsent() {
        let withoutF16 = realRepo.filter { !$0.path.contains("-F16") }
        let picked = resolver.selectProjector(from: withoutF16, hint: nil)
        #expect(picked?.path == "mmproj-BF16.gguf")
    }

    /// Unknown naming should cost the least, not the most.
    @Test func unknownNamingTakesTheSmallest() {
        let odd: [HuggingFaceClient.RepoFile] = [
            .init(path: "mmproj-custom-big.gguf", size: .gib(9), sha256: nil),
            .init(path: "mmproj-custom-small.gguf", size: .gib(1), sha256: nil),
        ]
        #expect(resolver.selectProjector(from: odd, hint: nil)?.path == "mmproj-custom-small.gguf")
    }

    @Test func noProjectorInRepoIsNotAnError() {
        let textOnly: [HuggingFaceClient.RepoFile] = [
            .init(path: "model-Q4_K_M.gguf", size: .gib(4), sha256: nil)
        ]
        #expect(resolver.selectProjector(from: textOnly, hint: nil) == nil)
    }
}

@Suite("Companion file exclusion")
struct CompanionFileTests {

    /// Real filenames from ggml-org/gpt-oss-20b-GGUF and unsloth vision repos.
    @Test(arguments: [
        ("eagle3-gpt-oss-20b-Q8_0.gguf", true),
        ("eagle3-gpt-oss-120b-BF16.gguf", true),
        ("mmproj-F16.gguf", true),
        ("mmproj-BF16.gguf", true),
        ("gpt-oss-20b-MXFP4.gguf", false),
        ("Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf", false),
        ("Q3_K_M/GLM-4.5-Air-Q3_K_M-00001-of-00002.gguf", false),
    ])
    func identifiesCompanionFiles(path: String, isCompanion: Bool) {
        #expect(ModelResolver.isCompanionFile(path) == isCompanion)
    }

    /// The failure this guards against: a draft model that happens to be larger than the real
    /// weights would win the "largest match" fallback and be handed to the user as the model.
    @Test func draftModelNeverWinsEvenWhenLarger() {
        let files: [HuggingFaceClient.RepoFile] = [
            .init(path: "eagle3-model-Q8_0.gguf", size: .gib(40), sha256: nil),
            .init(path: "model-Q8_0.gguf", size: .gib(8), sha256: nil),
        ]
        let usable = files.filter { !ModelResolver.isCompanionFile($0.path) }
        #expect(usable.count == 1)
        #expect(usable[0].path == "model-Q8_0.gguf")
    }
}
