import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore
@testable import SiliconHardware
@testable import SiliconPlanner
@testable import SiliconUI

/// Builds a syntactically valid GGUF header in memory, so the parser can be tested without
/// keeping a multi-gigabyte fixture in the repository.
struct GGUFBuilder {
    enum Value {
        case uint32(UInt32)
        case int64(Int64)
        case uint64(UInt64)
        case double(Double)
        case string(String)
        case stringArray([String])
    }

    var architecture: String
    var values: [(String, Value)] = []
    /// name -> dimensions
    var tensors: [(String, [UInt64])] = []

    func data() -> Data {
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
            case .int64(let number):
                appendUInt32(11)
                appendUInt64(UInt64(bitPattern: number))
            case .uint64(let number):
                appendUInt32(10)
                appendUInt64(number)
            case .double(let number):
                appendUInt32(12)
                appendUInt64(number.bitPattern)
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

        return data
    }

    func write(to url: URL) throws {
        try data().write(to: url)
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendGGUFString(_ value: String) {
        let bytes = Array(value.utf8)
        appendLittleEndian(UInt64(bytes.count))
        append(contentsOf: bytes)
    }
}

@Suite("GGUF header parsing")
struct GGUFReaderTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gguf-test-\(UUID().uuidString).gguf")
    }

    private func prefix(tensors: UInt64 = 0, metadata: UInt64 = 0) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(0x4655_4747))
        data.appendLittleEndian(UInt32(3))
        data.appendLittleEndian(tensors)
        data.appendLittleEndian(metadata)
        return data
    }

    private func expectInvalid(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try GGUFReader().read(data: data)
            Issue.record("malformed GGUF was accepted", sourceLocation: sourceLocation)
        } catch GGUFReader.ReadError.invalidData {
            // Expected typed rejection, distinct from a partial remote range.
        } catch {
            Issue.record("expected invalidData, got \(error)", sourceLocation: sourceLocation)
        }
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
            ],
            tensors: [("token_embd.weight", [30_500_000_000])]
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

    @Test func rejectsUnboundedCountsBeforeAllocationOrIteration() {
        expectInvalid(prefix(metadata: UInt64.max))
        expectInvalid(prefix(tensors: UInt64.max))

        var oversizedString = prefix(metadata: 1)
        oversizedString.appendLittleEndian(UInt64.max)
        expectInvalid(oversizedString)

        var oversizedArray = prefix(metadata: 1)
        oversizedArray.appendGGUFString("array")
        oversizedArray.appendLittleEndian(UInt32(9))       // array
        oversizedArray.appendLittleEndian(UInt32(0))       // uint8 elements
        oversizedArray.appendLittleEndian(UInt64.max)
        expectInvalid(oversizedArray)

        var excessiveWork = prefix(metadata: 1)
        excessiveWork.appendGGUFString("strings")
        excessiveWork.appendLittleEndian(UInt32(9))
        excessiveWork.appendLittleEndian(UInt32(8))        // variable-width strings
        excessiveWork.appendLittleEndian(UInt64(1_000_001))
        expectInvalid(excessiveWork)
    }

    @Test func rejectsUnrepresentableTensorDimensionsAndProducts() {
        var unrepresentable = prefix(tensors: 1)
        unrepresentable.appendGGUFString("weight")
        unrepresentable.appendLittleEndian(UInt32(1))
        unrepresentable.appendLittleEndian(UInt64.max)
        expectInvalid(unrepresentable)

        var excessiveProduct = prefix(tensors: 1)
        excessiveProduct.appendGGUFString("weight")
        excessiveProduct.appendLittleEndian(UInt32(2))
        excessiveProduct.appendLittleEndian(UInt64(Int64.max))
        excessiveProduct.appendLittleEndian(UInt64(2))
        expectInvalid(excessiveProduct)
    }

    @Test func rejectsNestedArraysAtTheDepthBudget() {
        var data = prefix(metadata: 1)
        data.appendGGUFString("nested")
        data.appendLittleEndian(UInt32(9))                 // top-level array value
        for _ in 0...16 {
            data.appendLittleEndian(UInt32(9))             // one nested array
            data.appendLittleEndian(UInt64(1))
        }
        data.appendLittleEndian(UInt32(0))                 // final uint8 array
        data.appendLittleEndian(UInt64(0))
        expectInvalid(data)
    }

    @Test func tensorTableTruncationAlwaysPropagates() throws {
        let metadataOnly = GGUFBuilder(architecture: "llama").data()
        let complete = GGUFBuilder(
            architecture: "llama", tensors: [("weight", [128, 256])]
        ).data()
        #expect(complete.count > metadataOnly.count)

        for length in metadataOnly.count..<complete.count {
            do {
                _ = try GGUFReader().read(data: complete.prefix(length))
                Issue.record("accepted tensor table truncated at byte \(length)")
            } catch GGUFReader.ReadError.truncated {
                // The remote reader relies on this exact signal to double its range.
            } catch {
                Issue.record("expected truncated at byte \(length), got \(error)")
            }
        }
        #expect(try GGUFReader().read(data: complete).parameterCount == 32_768)
    }

    @Test func shapeRejectsNonIntegralAndInconsistentNumericMetadata() {
        let base: [String: GGUFReader.Value] = [
            "llama.block_count": .integer(32),
            "llama.embedding_length": .integer(4096),
            "llama.attention.head_count": .integer(32),
        ]

        func shape(overrides: [String: GGUFReader.Value], parameters: Int64 = 10_000_000_000)
            -> ModelShape? {
            GGUFReader().shape(from: .init(
                architecture: "llama",
                name: nil,
                tensorCount: 1,
                values: base.merging(overrides) { _, replacement in replacement },
                parameterCount: parameters
            ))
        }

        #expect(shape(overrides: ["llama.block_count": .double(.nan)]) == nil)
        #expect(shape(overrides: ["llama.embedding_length": .double(.infinity)]) == nil)
        #expect(shape(overrides: ["llama.attention.head_count": .double(31.5)]) == nil)
        #expect(shape(overrides: ["llama.block_count": .integer(0)]) == nil)
        #expect(shape(overrides: [:], parameters: 0) == nil)
        #expect(shape(overrides: [:], parameters: Int64.max) == nil)
        #expect(shape(overrides: [
            "llama.expert_count": .integer(8),
            "llama.expert_used_count": .integer(9),
            "llama.expert_feed_forward_length": .integer(1024),
        ]) == nil)
        #expect(shape(overrides: [
            "llama.expert_count": .integer(8),
            "llama.expert_used_count": .integer(2),
            "llama.expert_feed_forward_length": .integer(1024),
            "llama.leading_dense_block_count": .integer(33),
        ]) == nil)
        #expect(shape(overrides: [
            "llama.expert_count": .integer(8),
            "llama.expert_used_count": .integer(2),
            "llama.expert_feed_forward_length": .integer(1024),
            "llama.leading_dense_block_count": .integer(Int64.min),
        ]) == nil)
        #expect(shape(overrides: [:])?.isValidForPlanning == true)
    }
}

private final class GGUFRangeProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var payload = Data()
    nonisolated(unsafe) private static var requestedLengths: [Int] = []

    static func configure(payload: Data) {
        lock.withLock {
            self.payload = payload
            requestedLengths = []
        }
    }

    static var requests: [Int] { lock.withLock { requestedLengths } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let end = request.value(forHTTPHeaderField: "Range")?
            .split(separator: "-").last.flatMap { Int($0) } ?? 0
        let length = end + 1
        let responseData = Self.lock.withLock { () -> Data in
            Self.requestedLengths.append(length)
            return Data(Self.payload.prefix(length))
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes 0-\(responseData.count - 1)/*"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Remote GGUF parser security", .serialized)
struct RemoteGGUFParserSecurityTests {
    @Test func retriesWhenTheTensorTableFallsBeyondTheInitialRange() async throws {
        let payload = GGUFBuilder(
            architecture: "llama",
            values: [
                ("llama.block_count", .uint32(32)),
                ("llama.embedding_length", .uint32(4096)),
                ("llama.attention.head_count", .uint32(32)),
                ("general.description", .string(String(
                    repeating: "x", count: RemoteGGUFReader.initialChunk
                ))),
            ],
            tensors: [("weight", [1_000_000_000])]
        ).data()
        GGUFRangeProtocol.configure(payload: payload)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GGUFRangeProtocol.self]
        let reader = RemoteGGUFReader(session: URLSession(configuration: configuration))

        let metadata = try await reader.readHeader(repository: "owner/model", file: "model.gguf")

        #expect(metadata.parameterCount == 1_000_000_000)
        #expect(GGUFRangeProtocol.requests == [
            RemoteGGUFReader.initialChunk, RemoteGGUFReader.initialChunk * 2,
        ])
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

@Suite("Conversation folders")
@MainActor
struct ConversationFolderTests {

    private func modelWithConversations(_ count: Int) -> AppModel {
        let model = AppModel(settings: .init())
        for _ in 0..<count { model.newConversation() }
        return model
    }

    @Test func newConversationsStartUnfiled() {
        let model = modelWithConversations(2)
        #expect(model.conversations(in: nil).count == 2)
        #expect(model.folders.isEmpty)
    }

    @Test func movingAConversationFilesIt() {
        let model = modelWithConversations(2)
        let folder = model.createFolder(named: "Work")
        let first = model.conversations[0].id

        model.move(first, to: folder.id)
        #expect(model.conversations(in: folder.id).map(\.id) == [first])
        #expect(model.conversations(in: nil).count == 1)
    }

    /// Deleting a container must never destroy what is inside it. The conversations become
    /// unfiled instead.
    @Test func deletingAFolderKeepsItsConversations() {
        let model = modelWithConversations(3)
        let folder = model.createFolder(named: "Research")
        for conversation in model.conversations { model.move(conversation.id, to: folder.id) }
        #expect(model.conversations(in: folder.id).count == 3)

        model.deleteFolder(folder.id)
        #expect(model.folders.isEmpty)
        #expect(model.conversations.count == 3, "conversations were destroyed with the folder")
        #expect(model.conversations(in: nil).count == 3)
    }

    @Test func pinnedConversationsAreListedOnceAtTheTop() {
        let model = modelWithConversations(2)
        let folder = model.createFolder(named: "Work")
        let first = model.conversations[0].id
        model.move(first, to: folder.id)
        model.conversations[0].isPinned = true

        // Pinned items get their own section, so they must not also appear inside the folder.
        #expect(!model.conversations(in: folder.id).contains { $0.id == first })
    }

    @Test func renameRejectsBlankNames() {
        let model = AppModel(settings: .init())
        let folder = model.createFolder(named: "Keep")
        model.renameFolder(folder.id, to: "   ")
        #expect(model.folders[0].name == "Keep")
    }

    @Test func unnamedFoldersStillGetALabel() {
        let model = AppModel(settings: .init())
        let folder = model.createFolder(named: "  ")
        #expect(!folder.name.isEmpty)
    }

    /// Searching should hide folders with no matches rather than leave empty headings.
    @Test func searchHidesEmptyFolders() {
        let model = modelWithConversations(2)
        let folder = model.createFolder(named: "Work")
        model.move(model.conversations[0].id, to: folder.id)
        model.conversations[0].title = "Metal shader debugging"

        model.conversationSearch = "metal"
        #expect(model.visibleFolders().map(\.id) == [folder.id])

        model.conversationSearch = "nothing matches this"
        #expect(model.visibleFolders().isEmpty)
    }
}
