import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore
@testable import SiliconHardware
@testable import SiliconPlanner

/// Qwen3.8 27B, and Bonsai 2 built from it, keep a KV cache in 16 of their 65 blocks. The other
/// 48 are Gated DeltaNet linear attention with a fixed-size state, and the 65th is an MTP block
/// the runtime gives no share of the main cache. Planned as 65 attention blocks, a 128K context
/// cost four times what the runtime allocates and the 256K the model was trained for would not
/// fit a 36 GB Mac at all (#26).
@Suite("Hybrid attention memory")
struct HybridAttentionTests {

    /// The owner's M3 Max: 36 GiB, the 38.7 GB of the measurements below.
    private static let m3Max36 = SystemProfile(
        chipName: "Apple M3 Max", generation: .m3, variant: .max, modelIdentifier: "Mac15,11",
        totalMemory: .gib(36), performanceCores: 10, efficiencyCores: 4, gpuCores: 30,
        neuralEngineCores: 16, diskTotal: .gib(1024), diskFree: .gib(500),
        memoryBandwidthGBps: 300, ssdReadMBps: 5000
    )

    private static let qwen = ModelCatalog.qwen3_8_27B.shape

    /// The same shape as a saved index from before this change reads: no split at all.
    private static var qwenAsEveryBlockAttention: ModelShape {
        var shape = qwen
        shape.hybrid = nil
        return shape
    }

    // MARK: - The cache

    /// K and V, 4 heads of 256, in the 16 full-attention blocks only — the issue's own
    /// architecture-derived figures: 4.56 GB at q8_0 and 8 GiB at f16 for 131,072 tokens.
    @Test func onlyTheFullAttentionBlocksKeepACache() {
        #expect(Self.qwen.kvLayerCount == 16)
        #expect(MemoryPlanner.kvBytesPerToken(Self.qwen, precision: .f16) == 2 * 16 * 4 * 256 * 2)
        #expect(MemoryPlanner.kvCacheBytes(Self.qwen, context: 131_072, precision: .f16)
            == .gib(8))
        let q8 = MemoryPlanner.kvCacheBytes(Self.qwen, context: 131_072, precision: .q8_0)
        #expect(abs(Double(q8.rawValue) / 1e9 - 4.56) < 0.01)

        // Bonsai and OrcaBonsai are the same network, so the same cache.
        #expect(ModelCatalog.bonsai2_27B.shape.kvLayerCount == 16)
        #expect(ModelCatalog.orcaBonsai27B.shape.kvLayerCount == 16)
        #expect(ModelCatalog.qwen3_8_27B_mlx.shape.kvLayerCount == 16)
    }

    /// The fixed part: 48 blocks of about 3.1 MiB each, per sequence, in f32 — whatever the
    /// context, and whatever precision the KV cache is stored at.
    @Test func theLinearBlocksKeepAFixedStatePerSequence() {
        let perLayer = 3 * (6144 + 2 * 16 * 128) + 128 * 6144
        #expect(Self.qwen.hybrid?.recurrentStateElementsPerLayer == perLayer)
        let one = MemoryPlanner.recurrentStateBytes(Self.qwen, sequences: 1)
        #expect(one == Bytes(Int64(48 * perLayer * 4)))
        #expect(MemoryPlanner.recurrentStateBytes(Self.qwen, sequences: 4) == one * 4)

        let planner = MemoryPlanner(profile: Self.m3Max36)
        func state(_ configuration: LoadConfiguration, _ quantization: Quantization) -> Bytes {
            planner.plan(
                shape: Self.qwen, quantization: quantization, configuration: configuration
            ).recurrentState
        }
        // llama-server's default is four slots, and each keeps its own state; MLX serves one.
        #expect(state(LoadConfiguration(contextLength: 8192), .q4_K_M) == one * 4)
        #expect(state(LoadConfiguration(contextLength: 262_144), .q4_K_M) == one * 4)
        #expect(state(LoadConfiguration(contextLength: 8192, parallelSequences: 1), .q4_K_M)
            == one)
        #expect(state(LoadConfiguration(contextLength: 8192), .mlx4) == one)
        #expect(state(
            LoadConfiguration(contextLength: 8192, kvCachePrecision: .q4_0), .q4_K_M
        ) == one * 4)
    }

    // MARK: - Against the report and the measurements

    /// The issue's reproduction: Q4_K_M at 131,072 with a q8_0 cache on a 36 GB Mac was
    /// 35.4 GB resident, 18.5 GB of it KV, and "Will swap".
    @Test func theReportedPlanNoLongerSwaps() {
        let plan = MemoryPlanner(profile: Self.m3Max36).plan(
            shape: Self.qwen, quantization: .q4_K_M,
            configuration: LoadConfiguration(contextLength: 131_072, kvCachePrecision: .q8_0)
        )
        #expect(abs(Double(plan.kvCache.rawValue) / 1e9 - 4.56) < 0.01)
        #expect(plan.recurrentState > .zero)
        #expect(plan.resident == plan.nonExpertWeights + plan.kvCache + plan.recurrentState
            + plan.computeBuffers)
        #expect(plan.verdict.isUsable, "\(plan.verdict.label) at \(plan.resident.formatted)")
        #expect(plan.notes.contains { $0.contains("Only 16 of 65 blocks keep a KV cache") })
    }

    /// OrcaBonsai 27B (PTQ1_0, f16 cache, flash attention) measured on the owner's M3 Max:
    /// llama-server at about 6.5, 8.0 and 12.7 GB RSS at 32K, 128K and 256K, against a plan of
    /// "fits", 41.1 GB and 76.0 GB.
    ///
    /// The plan now follows what llama.cpp allocates for the attention cache at load — 16 GiB
    /// at 256K, the size its log prints — and that is more than the whole RSS measured, so RSS
    /// after load does not capture the allocation (plausibly because the zero-filled buffer
    /// compresses until tokens fill it; not measured here). What is pinned is that the plan
    /// never promises less than the runtime took, and no longer refuses the context the model
    /// was trained for.
    @Test(arguments: [(32_768, 6.5), (131_072, 8.0), (262_144, 12.7)])
    func theOwnersMeasurementsAreCoveredAndLongContextFits(context: Int, measuredGB: Double) {
        let plan = MemoryPlanner(profile: Self.m3Max36).plan(
            shape: ModelCatalog.orcaBonsai27B.shape, quantization: .ptq1_0,
            configuration: LoadConfiguration(contextLength: context, kvCachePrecision: .f16)
        )
        let plannedGB = Double(plan.resident.rawValue) / 1e9
        #expect(plannedGB >= measuredGB, "planned \(plannedGB) GB, measured \(measuredGB) GB")
        #expect(plan.verdict.isUsable, "\(plan.verdict.label) at \(plan.resident.formatted)")
    }

    /// And the numbers the owner saw before, from the shape a saved index still holds until it
    /// is read again — which is also the proof that an all-attention shape plans exactly as it
    /// always did.
    @Test(arguments: [(131_072, 41.1), (262_144, 76.0)])
    func aShapeWithoutTheSplitPlansAsItAlwaysDid(context: Int, formerGB: Double) {
        let plan = MemoryPlanner(profile: Self.m3Max36).plan(
            shape: Self.qwenAsEveryBlockAttention, quantization: .ptq1_0,
            configuration: LoadConfiguration(contextLength: context, kvCachePrecision: .f16)
        )
        #expect(abs(Double(plan.resident.rawValue) / 1e9 - formerGB) < 0.05)
        #expect(plan.recurrentState == .zero)
    }

    // MARK: - Every other model

    /// Every ordinary model keeps a cache in every block and no recurrent state, exactly as
    /// before — the split is opt-in per shape, and only Qwen3.8's family has one.
    @Test func ordinaryModelsAreUnchanged() {
        let planner = MemoryPlanner(profile: Self.m3Max36)
        for entry in ModelCatalog.all where entry.shape.hybrid == nil {
            let shape = entry.shape
            #expect(shape.kvLayerCount == shape.blockCount, "\(entry.id)")
            #expect(MemoryPlanner.kvBytesPerToken(shape, precision: .f16)
                == 2 * Double(shape.blockCount) * Double(shape.headCountKV)
                    * Double(shape.headDimension) * 2, "\(entry.id)")
            let plan = planner.plan(
                shape: shape, quantization: entry.variants.first?.quantization ?? .q4_K_M,
                configuration: LoadConfiguration(contextLength: 8192, parallelSequences: 0)
            )
            // A slot count means nothing to a model without recurrent state, so not even a
            // nonsensical one changes its plan.
            #expect(plan.recurrentState == .zero, "\(entry.id)")
            #expect(!plan.notes.contains { $0.contains("keep a KV cache") }, "\(entry.id)")
        }
        let hybrids = ModelCatalog.all.filter { $0.shape.hybrid != nil }.map(\.id)
        #expect(Set(hybrids) == [
            "qwen3.8-27b", "qwen3.8-27b-mlx", "bonsai-2-27b", "orcabonsai-27b-uncensored",
        ])
    }

    /// A split that does not account for every block is not a shape anything can plan from.
    @Test func aSplitThatDoesNotAddUpIsRejected() {
        var shape = Self.qwen
        shape.hybrid?.linearAttentionLayers = 47
        #expect(!shape.isValidForPlanning)
        shape.hybrid?.linearAttentionLayers = -1
        #expect(!shape.isValidForPlanning)
        shape = Self.qwen
        shape.hybrid?.recurrentStateElementsPerLayer = -1
        #expect(!shape.isValidForPlanning)
        #expect(MemoryPlanner(profile: Self.m3Max36).plan(
            shape: shape, quantization: .q4_K_M, configuration: LoadConfiguration()
        ).verdict == .impossible)
    }

    // MARK: - Reading it off a file

    /// The keys of a real qwen35 header (a Bonsai 2 install): no MTP block in that file, so
    /// 64 blocks, every fourth full attention.
    private func qwen35Header(blockCount: UInt32, mtp: UInt32?) -> GGUFBuilder {
        var values: [(String, GGUFBuilder.Value)] = [
            ("qwen35.block_count", .uint32(blockCount)),
            ("qwen35.context_length", .uint32(262_144)),
            ("qwen35.embedding_length", .uint32(5120)),
            ("qwen35.feed_forward_length", .uint32(17_408)),
            ("qwen35.attention.head_count", .uint32(24)),
            ("qwen35.attention.head_count_kv", .uint32(4)),
            ("qwen35.attention.key_length", .uint32(256)),
            ("qwen35.ssm.conv_kernel", .uint32(4)),
            ("qwen35.ssm.state_size", .uint32(128)),
            ("qwen35.ssm.group_count", .uint32(16)),
            ("qwen35.ssm.time_step_rank", .uint32(48)),
            ("qwen35.ssm.inner_size", .uint32(6144)),
            ("qwen35.full_attention_interval", .uint32(4)),
        ]
        if let mtp { values.append(("qwen35.nextn_predict_layers", .uint32(mtp))) }
        return GGUFBuilder(
            architecture: "qwen35", values: values,
            tensors: [("token_embd.weight", [27_400_000_000])]
        )
    }

    @Test func theSplitIsReadFromAQwen35Header() throws {
        let reader = GGUFReader()
        let bonsai = try #require(reader.shape(from: try reader.read(
            data: qwen35Header(blockCount: 64, mtp: nil).data()
        )))
        #expect(bonsai.hybrid == HybridAttention(
            fullAttentionLayers: 16, linearAttentionLayers: 48, mtpLayers: 0,
            recurrentStateElementsPerLayer: 3 * (6144 + 2 * 16 * 128) + 128 * 6144
        ))

        // A file that carries the MTP block counts it, and it keeps no share of the cache.
        let withMTP = try #require(reader.shape(from: try reader.read(
            data: qwen35Header(blockCount: 65, mtp: 1).data()
        )))
        #expect(withMTP.hybrid?.mtpLayers == 1)
        #expect(withMTP.hybrid?.fullAttentionLayers == 16)
        #expect(withMTP.hybrid == Self.qwen.hybrid)
        #expect(MemoryPlanner.kvBytesPerToken(withMTP, precision: .f16)
            == MemoryPlanner.kvBytesPerToken(Self.qwen, precision: .f16))
    }

    /// An ordinary header has no split, even with a hybrid catalog entry as its fallback — a
    /// different stack of blocks is a different model. The same stack without the keys takes
    /// the catalog's.
    @Test func anOrdinaryHeaderHasNoSplit() throws {
        let reader = GGUFReader()
        let ordinary = GGUFBuilder(
            architecture: "qwen3",
            values: [
                ("qwen3.block_count", .uint32(36)),
                ("qwen3.embedding_length", .uint32(4096)),
                ("qwen3.attention.head_count", .uint32(32)),
                ("qwen3.attention.head_count_kv", .uint32(8)),
                ("qwen3.attention.key_length", .uint32(128)),
            ],
            tensors: [("token_embd.weight", [8_000_000_000])]
        )
        let metadata = try reader.read(data: ordinary.data())
        #expect(reader.shape(from: metadata)?.hybrid == nil)
        #expect(reader.shape(from: metadata, fallback: Self.qwen)?.hybrid == nil)

        var bare = qwen35Header(blockCount: 65, mtp: 1)
        bare.values.removeAll { $0.0.contains(".ssm.") || $0.0.hasSuffix("attention_interval") }
        let bareMetadata = try reader.read(data: bare.data())
        #expect(reader.shape(from: bareMetadata, fallback: Self.qwen)?.hybrid == Self.qwen.hybrid)
    }

    // MARK: - Saved indexes

    /// A shape saved before the split existed decodes, as an all-attention shape; an ordinary
    /// shape encodes without the key, byte for byte what an older app would read.
    @Test func savedShapesFromBeforeTheSplitStillDecode() throws {
        let saved = #"""
            {"totalParameters":27400000000,"blockCount":65,"embeddingLength":5120,
             "feedForwardLength":17408,"headCount":24,"headCountKV":4,
             "trainingContextLength":262144,"vocabSize":248320,"headDimensionOverride":256}
            """#
        let shape = try JSONDecoder().decode(ModelShape.self, from: Data(saved.utf8))
        #expect(shape.hybrid == nil)
        #expect(shape == Self.qwenAsEveryBlockAttention)

        let ordinary = try JSONEncoder().encode(ModelCatalog.qwen3_30B_A3B.shape)
        #expect(!String(decoding: ordinary, as: UTF8.self).contains("hybrid"))
        let hybrid = try JSONDecoder().decode(
            ModelShape.self, from: try JSONEncoder().encode(Self.qwen)
        )
        #expect(hybrid == Self.qwen)
    }

    /// The owner's installs were registered before the split existed. Loading the library
    /// reads their headers again for it — once, since the result is saved — and leaves every
    /// model the catalog does not know to be hybrid exactly as it was.
    @Test func existingInstallsLearnTheirSplitWhenTheLibraryLoads() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hybrid-library-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let bonsaiFile = root.appendingPathComponent("Ternary-Bonsai-2-27B-PTQ1_0.gguf")
        try qwen35Header(blockCount: 64, mtp: nil).write(to: bonsaiFile)
        let otherFile = root.appendingPathComponent("other.gguf")
        try qwen35Header(blockCount: 64, mtp: nil).write(to: otherFile)
        let mlxFile = root.appendingPathComponent("model-00001-of-00003.safetensors")
        try Data("stand-in".utf8).write(to: mlxFile)

        var legacy = Self.qwenAsEveryBlockAttention
        legacy.blockCount = 64
        func installed(
            _ id: String, _ file: URL, catalogID: String?, format: ModelFormat,
            shape: ModelShape
        ) -> InstalledModel {
            InstalledModel(
                id: id, name: id, catalogID: catalogID, quantization: .ptq1_0, format: format,
                primaryFile: file, allFiles: [file], projectorFile: nil, sizeOnDisk: .zero,
                installedAt: Date(), shape: shape, capabilities: []
            )
        }
        let seeded = ModelLibrary(root: root)
        try await seeded.load()
        try await seeded.add(installed(
            "bonsai", bonsaiFile, catalogID: "bonsai-2-27b", format: .gguf, shape: legacy
        ))
        // Same header, but nothing in the catalog says it is hybrid: left alone.
        try await seeded.add(installed(
            "imported", otherFile, catalogID: nil, format: .gguf, shape: legacy
        ))
        try await seeded.add(installed(
            "mlx", mlxFile, catalogID: "qwen3.8-27b-mlx", format: .mlx,
            shape: Self.qwenAsEveryBlockAttention
        ))

        let relaunched = ModelLibrary(root: root)
        try await relaunched.load()
        #expect(await relaunched.model(id: "bonsai")?.shape?.hybrid?.fullAttentionLayers == 16)
        #expect(await relaunched.model(id: "bonsai")?.shape?.hybrid?.mtpLayers == 0)
        #expect(await relaunched.model(id: "imported")?.shape?.hybrid == nil)
        #expect(await relaunched.model(id: "mlx")?.shape?.hybrid == Self.qwen.hybrid)

        // Written back, so the next launch has nothing to read again.
        let index = try String(
            contentsOf: root.appendingPathComponent("index.json"), encoding: .utf8
        )
        #expect(index.contains("fullAttentionLayers"))
    }
}
