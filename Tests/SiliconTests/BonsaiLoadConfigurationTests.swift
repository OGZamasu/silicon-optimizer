import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconCore
@testable import SiliconHardware
@testable import SiliconPlanner
@testable import SiliconRuntime
@testable import SiliconUI

@Suite("Bonsai control load defaults", .redirectedConversationStore)
@MainActor
struct BonsaiLoadConfigurationTests {
    private func app(memoryGiB: Double = 36) -> AppModel {
        let app = AppModel(settings: .init())
        app.profile = SystemProfile(
            chipName: "Apple M5 Max", generation: .m5, variant: .max,
            modelIdentifier: "test", totalMemory: .gib(memoryGiB),
            performanceCores: 6, efficiencyCores: 12, gpuCores: 32, neuralEngineCores: 16,
            diskTotal: .gib(1024), diskFree: .gib(500), memoryBandwidthGBps: 520
        )
        return app
    }

    private func model(
        entry: ModelEntry = ModelCatalog.bonsai2_27B, quantization: Quantization = .pq2_0
    ) -> InstalledModel {
        let file = URL(fileURLWithPath: "/models/test.gguf")
        return InstalledModel(
            id: "\(entry.id)@\(quantization.rawValue)", name: entry.name, catalogID: entry.id,
            quantization: quantization, format: .gguf, primaryFile: file,
            allFiles: [file], projectorFile: nil, sizeOnDisk: .gib(7), installedAt: Date(),
            shape: entry.shape, capabilities: entry.capabilities
        )
    }

    /// Regression: load_model selected defaults for a smaller window, then overwrote only
    /// --ctx-size. The resulting 128K server still had FP16 cache and large batches.
    @Test func requestedContextIsResolvedBeforeRuntimeDefaults() throws {
        let app = app()
        let model = model()
        let configuration = try app.controlLoadConfiguration(
            for: model, request: .init(modelID: model.id, contextLength: 131_072)
        )
        let args = LlamaArguments(model: model, configuration: configuration, port: 8080).build()
        func value(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1)
            else { return nil }
            return args[index + 1]
        }
        #expect(value("--ctx-size") == "131072")
        #expect(value("--cache-type-k") == "q8_0")
        #expect(value("--cache-type-v") == "q8_0")
        #expect(value("--batch-size") == "512")
        #expect(value("--ubatch-size") == "128")
        #expect(value("--parallel") == "1")
        #expect(value("--threads") == "6")
    }

    @Test func largerRequestIsPreservedAndInvalidContextsStillFail() throws {
        let app = app()
        let model = model()
        let configuration = try app.controlLoadConfiguration(
            for: model, request: .init(modelID: model.id, contextLength: 262_144)
        )
        #expect(configuration.contextLength == 262_144)
        #expect(configuration.kvCachePrecision == .q8_0)
        for context in [0, -1, 262_145, Int.max] {
            #expect(throws: ControlHostError.self) {
                try app.controlLoadConfiguration(
                    for: model, request: .init(modelID: model.id, contextLength: context)
                )
            }
        }
    }

    @Test func explicitExpertSlotsKeepTheirExistingBatchConstraint() throws {
        let app = app()
        let model = model(entry: ModelCatalog.qwen3_30B_A3B, quantization: .q4_K_M)
        let configuration = try app.controlLoadConfiguration(
            for: model,
            request: .init(modelID: model.id, contextLength: 32_768, expertSlots: 32)
        )
        #expect(configuration.contextLength == 32_768)
        #expect(configuration.expertStreaming?.slotCount == 32)
        #expect(configuration.microBatchSize == 4)
        #expect(configuration.batchSize == 256)
        #expect(configuration.parallelSequences == nil)
    }

    @Test func largerMacRetainsItsExistingDefaultPolicy() throws {
        let app = app(memoryGiB: 64)
        let model = model()
        let configuration = try app.controlLoadConfiguration(
            for: model, request: .init(modelID: model.id, contextLength: 131_072)
        )
        #expect(configuration.contextLength == 131_072)
        #expect(configuration.batchSize == 2048)
        #expect(configuration.microBatchSize == 512)
        #expect(configuration.parallelSequences == nil)
    }
}
