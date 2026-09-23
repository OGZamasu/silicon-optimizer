import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore
@testable import SiliconHardware
@testable import SiliconPlanner
@testable import SiliconRuntime

@Suite("Long-context ternary defaults")
struct LongContextDefaultsTests {
    private func configurator(memoryGiB: Double = 36) -> AutoConfigurator {
        AutoConfigurator(profile: SystemProfile(
            chipName: "Apple M5 Max", generation: .m5, variant: .max,
            modelIdentifier: "test", totalMemory: .gib(memoryGiB),
            performanceCores: 6, efficiencyCores: 12, gpuCores: 32,
            neuralEngineCores: 16, diskTotal: .gib(1024), diskFree: .gib(500),
            memoryBandwidthGBps: 520
        ))
    }

    private var model: InstalledModel {
        let entry = ModelCatalog.bonsai2_27B
        let file = URL(fileURLWithPath: "/models/Bonsai-PQ2_0.gguf")
        return InstalledModel(
            id: "bonsai-test", name: entry.name, catalogID: entry.id,
            quantization: .pq2_0, format: .gguf, primaryFile: file, allFiles: [file],
            projectorFile: nil, sizeOnDisk: .gib(7), installedAt: Date(),
            shape: entry.shape, capabilities: entry.capabilities
        )
    }

    @Test(arguments: [Quantization.ptq1_0, .pq2_0])
    func limitsLongContextRuntimeAllocations(quantization: Quantization) {
        let original = LoadConfiguration(
            contextLength: 131_072, flashAttention: false, gpuLayerFraction: 0.5,
            threads: 6
        )
        let adjusted = configurator().adjustedRuntimeDefaults(
            original, quantization: quantization
        )
        #expect(adjusted.contextLength == 131_072)
        #expect(adjusted.kvCachePrecision == .q8_0)
        #expect(adjusted.batchSize == 512)
        #expect(adjusted.microBatchSize == 128)
        #expect(adjusted.parallelSequences == 1)
        #expect(adjusted.threads == original.threads)
        #expect(adjusted.flashAttention == original.flashAttention)
        #expect(adjusted.gpuLayerFraction == original.gpuLayerFraction)
        #expect(original.kvCachePrecision == .f16 && original.parallelSequences == nil)
    }

    @Test(arguments: [KVCachePrecision.q8_0, .q5_1, .q4_0])
    func preservesSmallerCacheAndBatchDefaults(precision: KVCachePrecision) {
        let original = LoadConfiguration(
            contextLength: 262_144, batchSize: 64, microBatchSize: 32,
            kvCachePrecision: precision, parallelSequences: 1
        )
        #expect(configurator().adjustedRuntimeDefaults(original, quantization: .pq2_0)
                == original)
    }

    @Test func leavesShorterContextsUnchanged() {
        let original = LoadConfiguration(contextLength: 65_536)
        #expect(configurator().adjustedRuntimeDefaults(original, quantization: .pq2_0)
                == original)
    }

    @Test func leavesLargerMachinesUnchanged() {
        let original = LoadConfiguration(contextLength: 131_072)
        #expect(configurator(memoryGiB: 64).adjustedRuntimeDefaults(
            original, quantization: .pq2_0
        ) == original)
    }

    @Test(arguments: [Quantization.q4_K_M, .mlx4, .mxfp4])
    func leavesOtherWeightFormatsUnchanged(quantization: Quantization) {
        let original = LoadConfiguration(contextLength: 131_072)
        #expect(configurator().adjustedRuntimeDefaults(original, quantization: quantization)
                == original)
    }

    @Test func automaticRecommendationsUseAdjustedDefaults() throws {
        // The catalog entry itself, now that its KV cache is planned for the 16 blocks that
        // keep one (#26); this used to shrink the shape to 16 blocks to get a 128K plan.
        let entry = ModelCatalog.bonsai2_27B
        let recommendation = try #require(configurator().best(for: entry))
        #expect(recommendation.configuration.contextLength == 131_072)
        #expect(recommendation.configuration.kvCachePrecision == .q8_0)
        #expect(recommendation.configuration.batchSize == 512)
        #expect(recommendation.configuration.microBatchSize == 128)
        #expect(recommendation.configuration.parallelSequences == 1)
        #expect(recommendation.plan.kvCache == MemoryPlanner.kvCacheBytes(
            entry.shape, context: 131_072, precision: .q8_0
        ))
    }

    @Test func launchCommandCarriesContextCacheAndSequenceSettings() {
        let configuration = configurator().adjustedRuntimeDefaults(
            LoadConfiguration(contextLength: 131_072), quantization: .pq2_0
        )
        let arguments = LlamaArguments(model: model, configuration: configuration, port: 9000)
        #expect(arguments.validate().isEmpty)
        let command = arguments.build()
        for (flag, value) in [
            ("--ctx-size", "131072"), ("--cache-type-k", "q8_0"),
            ("--cache-type-v", "q8_0"), ("--batch-size", "512"),
            ("--ubatch-size", "128"), ("--parallel", "1"),
        ] {
            let index = command.firstIndex(of: flag)
            #expect(index != nil && command[index! + 1] == value)
        }
        #expect(!LlamaArguments(model: model, configuration: LoadConfiguration(), port: 9000)
            .build().contains("--parallel"))
    }

    @Test(arguments: [0, -1])
    func rejectsInvalidParallelSequenceCounts(count: Int) {
        let arguments = LlamaArguments(
            model: model, configuration: LoadConfiguration(parallelSequences: count), port: 9000
        )
        #expect(arguments.validate().contains { $0.contains("Parallel sequence count") })
    }

    @Test func explicitSlotArgumentsRemainAnOverride() {
        let arguments = LlamaArguments(
            model: model, configuration: LoadConfiguration(parallelSequences: 1),
            port: 9000, extraArguments: ["--parallel", "4"]
        )
        #expect(arguments.validate().isEmpty)
        #expect(Array(arguments.build().suffix(2)) == ["--parallel", "4"])
    }

    @Test func oldSavedConfigurationsKeepRuntimeDefaultConcurrency() throws {
        let legacy = Data(#"{"contextLength":131072,"batchSize":2048,"microBatchSize":512,"kvCachePrecision":"f16","flashAttention":true,"gpuLayerFraction":1,"threads":6}"#.utf8)
        let decoded = try JSONDecoder().decode(LoadConfiguration.self, from: legacy)
        #expect(decoded.parallelSequences == nil)
        #expect(decoded.kvCachePrecision == .f16)
        #expect(decoded.contextLength == 131_072)

        var updated = decoded
        updated.parallelSequences = 1
        let roundTrip = try JSONDecoder().decode(
            LoadConfiguration.self, from: JSONEncoder().encode(updated)
        )
        #expect(roundTrip == updated)
    }
}
