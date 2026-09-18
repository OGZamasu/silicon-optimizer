import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore
@testable import SiliconHardware
@testable import SiliconPlanner

/// Bonsai 2 27B is the featured entry: a 27B that fits a 16 GB Mac because PrismML trained
/// it into ternary weights. The catalog has to say that honestly — real file sizes, the fork
/// it needs, the Qwen3.8 shape it inherits — or the planner's promise is worthless.
@Suite("Bonsai 2 catalog entry")
struct BonsaiCatalogTests {

    private let entry = ModelCatalog.bonsai2_27B

    @Test func isTheFeaturedFirstEntry() {
        #expect(ModelCatalog.all.first?.id == "bonsai-2-27b")
        #expect(entry.isFeatured)
        // One spotlight, or the word stops meaning anything.
        #expect(ModelCatalog.all.filter(\.isFeatured).map(\.id) == ["bonsai-2-27b"])
    }

    @Test func inheritsTheQwen38ShapeAndNamesItsRuntime() {
        #expect(entry.shape == ModelCatalog.qwen3_8_27B.shape)
        #expect(entry.needsPrismRuntime)
        #expect(entry.variants.map(\.quantization) == [.ptq1_0, .pq2_0])
        #expect(entry.variants.allSatisfy { $0.visionProjector?.contains("mmproj") == true })
        #expect(entry.capabilities.contains(.vision))
        #expect(entry.maxContext == 262_144)
        #expect(entry.summary.contains("fork"))
        // Stock entries must not trip the runtime check.
        #expect(!ModelCatalog.qwen3_8_27B.needsPrismRuntime)
    }

    /// Sizes are the repository's real bytes; the bit-rate estimate has to land within a few
    /// percent of them, or the effective rates on the enum are wrong.
    @Test func declaredSizesMatchTheBitRate() {
        for variant in entry.variants {
            let estimate = ModelCatalog.size(entry.shape.totalParameters, variant.quantization)
            let ratio = Double(estimate.rawValue) / Double(variant.downloadSize.rawValue)
            #expect(ratio > 0.95 && ratio < 1.05, "\(variant.quantization.rawValue): \(ratio)")
        }
    }

    /// The whole point: a 27B that fits a 16 GB Mac at a real context length.
    @Test func fitsASixteenGigabyteMac() {
        let m2_16 = SystemProfile(
            chipName: "Apple M2", generation: .m2, variant: .base, modelIdentifier: "Mac14,2",
            totalMemory: .gib(16), performanceCores: 4, efficiencyCores: 4, gpuCores: 10,
            neuralEngineCores: 16, diskTotal: .gib(512), diskFree: .gib(200),
            memoryBandwidthGBps: 100, ssdReadMBps: 3000
        )
        let plan = MemoryPlanner(profile: m2_16).plan(
            shape: entry.shape, quantization: .ptq1_0,
            configuration: LoadConfiguration(contextLength: 16_384)
        )
        #expect(plan.resident <= plan.budget,
                "resident \(plan.resident.formatted) of \(plan.budget.formatted)")
        #expect(plan.nonExpertWeights.gibibytes < 6.5)
    }

    /// PrismML's packings are release formats. The downgrade ladder must never offer them to
    /// a model that shipped as Q4_K_M — there is no such file to download. Without the
    /// exclusion PQ2_0 sits between IQ2_XXS and Q2_K on the ladder and would be offered.
    @Test func ternaryIsNeverOfferedAsADowngrade() {
        #expect(Quantization.ptq1_0.isNativeFormat)
        #expect(Quantization.pq2_0.isNativeFormat)
        #expect(Quantization.mxfp4.isNativeFormat)
        #expect(!Quantization.q2_K.isNativeFormat && !Quantization.iq1_S.isNativeFormat)

        let m3Max36 = SystemProfile(
            chipName: "Apple M3 Max", generation: .m3, variant: .max, modelIdentifier: "Mac15,11",
            totalMemory: .gib(36), performanceCores: 10, efficiencyCores: 4, gpuCores: 30,
            neuralEngineCores: 16, diskTotal: .gib(1024), diskFree: .gib(500),
            memoryBandwidthGBps: 300, ssdReadMBps: 5000
        )
        // A dense 70B at Q4_K_M does not fit 36 GB; the ladder should reach for IQ formats.
        let plan = MemoryPlanner(profile: m3Max36).plan(
            shape: ModelCatalog.llama3_3_70B.shape, quantization: .q4_K_M,
            configuration: LoadConfiguration(contextLength: 8192)
        )
        let offered = plan.remediations
            .filter { $0.kind == .lowerQuantization }
            .map(\.title)
        #expect(!offered.isEmpty)
        #expect(!offered.contains { $0.contains("PTQ1_0") || $0.contains("PQ2_0") }, "\(offered)")
    }
}
