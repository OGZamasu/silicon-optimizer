import Foundation
import Testing
@testable import SiliconCatalog
import SiliconCore
import SiliconHardware
@testable import SiliconPlanner

/// What the planner tells a Mac about Qwen-Image 2.1: a text encoder that is never quantized
/// but is read a layer at a time, an fp32 VAE, a 7.1B transformer at the chosen precision, and
/// a runner that runs them in stages so no two of them are resident at once. Pure arithmetic;
/// nothing runs.
@Suite("Qwen-Image 2.1 memory plan")
struct QwenImage21PlannerTests {

    static let m3Max36 = SystemProfile(
        chipName: "Apple M3 Max", generation: .m3, variant: .max, modelIdentifier: "Mac15,11",
        totalMemory: .gib(36), performanceCores: 10, efficiencyCores: 4, gpuCores: 30,
        neuralEngineCores: 16, diskTotal: .gib(1024), diskFree: .gib(500),
        memoryBandwidthGBps: 300, ssdReadMBps: 5000
    )
    static let base = DiffusionCatalog.qwenImage21
    static let pruna = DiffusionCatalog.qwenImage21Pruna

    private func plan(
        _ entry: DiffusionEntry, _ quantization: Quantization, side: Int = 1024,
        profile: SystemProfile = m3Max36, otherApps: Bytes = .zero, lowRAM: Bool = false
    ) -> DiffusionPlan {
        DiffusionPlanner(profile: profile).plan(
            shape: entry.shape,
            configuration: ImageConfiguration(
                width: side, height: side, steps: entry.shape.defaultSteps,
                quantization: quantization, lowRAM: lowRAM,
                canReuseQuantizedSave: entry.supportsQuantizedReuse
            ),
            otherAppsInUse: otherApps
        )
    }

    private func phase(_ plan: DiffusionPlan, _ name: String) -> Bytes {
        plan.phases.first { $0.name == name }?.resident ?? .zero
    }

    /// Records the figures this build produces, beside what the verification run measured.
    @Test func printsThePlanForA36GBMac() {
        for entry in [Self.base, Self.pruna] {
            for (quantization, lowRAM) in [(Quantization.mlx4, false), (.mlx8, false), (.bf16, false),
                                           (.mlx4, true), (.mlx8, true)] {
                let plan = plan(entry, quantization, lowRAM: lowRAM)
                print("\n\(entry.name) · \(quantization.rawValue)\(lowRAM ? " · tiled decode" : "") · 1024x1024 on 36 GB")
                for phase in plan.phases {
                    print(String(format: "  %-8s %@", (phase.name as NSString).utf8String!,
                                 phase.resident.formatted))
                }
                print("  PEAK     \(plan.peak.formatted) (\(plan.peakPhase?.name ?? "-")) · "
                      + "budget \(plan.budget.formatted) · \(plan.verdict.label)")
            }
        }
    }

    /// The component sizes the stages are built from: the text encoder at bf16 whatever the
    /// precision, the VAE at fp32, the transformer at the precision asked for.
    @Test func componentsAreChargedAtThePrecisionTheyRunAt() {
        for quantization in [Quantization.mlx4, .mlx6, .mlx8, .bf16] {
            #expect(DiffusionPlanner.textEncoderBytes(Self.base.shape, quantization)
                    == Bytes(7_568_000_000 * 2))
            #expect(DiffusionPlanner.vaeBytes(Self.base.shape, quantization)
                    == Bytes(338_000_000 * 4))
        }
        // The older families are unchanged: their encoders follow the precision.
        #expect(DiffusionPlanner.textEncoderBytes(DiffusionCatalog.qwenImage.shape, .mlx4)
                == DiffusionPlanner.weightBytes(DiffusionCatalog.qwenImage.shape.textEncoderParameters, .mlx4))
        #expect(!DiffusionCatalog.qwenImage.shape.runsInStages)
    }

    /// Encode holds the encoder's embedding table and one layer; the transformer only ever at
    /// its quantized size; the decode holds the VAE without the transformer.
    @Test func theStagesNeverHoldTwoLargeComponents() {
        let q4 = plan(Self.pruna, .mlx4), q8 = plan(Self.pruna, .mlx8)
        #expect(q4.phases.map(\.name) == ["Encode", "Load", "Denoise", "Decode"])
        // Encode does not move with precision: the encoder is never quantized. It is 15 GB in
        // bf16, but read a layer at a time only the embedding table and one layer are held.
        #expect(phase(q4, "Encode") == phase(q8, "Encode"))
        #expect(DiffusionPlanner.textEncoderBytes(Self.pruna.shape, .mlx4) > Bytes(15_000_000_000))
        #expect(phase(q4, "Encode") > Bytes(1_600_000_000))
        #expect(phase(q4, "Encode") < Bytes(3_000_000_000))
        // The transformer moves with precision, and is all the denoiser holds besides its
        // working memory.
        let transformerQ8 = DiffusionPlanner.weightBytes(Self.pruna.shape.transformerParameters, .mlx8)
        #expect(phase(q8, "Denoise") > transformerQ8)
        #expect(phase(q8, "Denoise") < transformerQ8 + Bytes(2_000_000_000))
        #expect(phase(q4, "Denoise") < phase(q8, "Denoise"))
        // The decode carries no transformer at all.
        #expect(phase(q4, "Decode") == phase(q8, "Decode"))
        #expect(phase(q8, "Decode") < DiffusionPlanner.vaeBytes(Self.pruna.shape, .mlx8)
                + DiffusionPlanner.decodeActivationBytes(Self.pruna.shape, ImageConfiguration()) + .gib(1))
        // Merging costs the adapter's run a little more while the transformer is read.
        #expect(phase(plan(Self.pruna, .mlx8), "Load") > phase(plan(Self.base, .mlx8), "Load"))
        #expect(q8.notes.contains { $0.contains("never quantized") && $0.contains("a layer at a time") })
    }

    /// The figures the verification render measured through the runner (mflux 0.20.0, the
    /// 8-step adapter, 8-bit, 1024², low-memory mode, M3 Max 36 GB: MLX's own peak per
    /// phase), and the planner at or just above each — never below.
    static let measured: [(phase: String, gigabytes: Double)] = [
        ("Encode", 1.68), ("Load", 8.04), ("Denoise", 8.83), ("Decode", 6.98),
    ]

    @Test func eachMeasuredStageIsPredictedAtOrAbove() {
        let q8 = DiffusionPlanner(profile: Self.m3Max36).plan(
            shape: Self.pruna.shape,
            configuration: ImageConfiguration(
                width: 1024, height: 1024, steps: 8, quantization: .mlx8, lowRAM: true,
                canReuseQuantizedSave: false
            )
        )
        #expect(Self.pruna.shape.peakIsCalibrated)
        #expect(!q8.notes.contains { $0.contains("extrapolated") })
        for (name, gigabytes) in Self.measured {
            let predicted = Double(phase(q8, name).rawValue) / 1e9
            #expect(predicted >= gigabytes, "\(name): \(predicted) GB predicted, \(gigabytes) GB measured")
            #expect(predicted <= gigabytes * 1.25, "\(name): \(predicted) GB predicted, \(gigabytes) GB measured")
        }
    }

    /// The VAE decode is this model's tallest stage at 1024² — about 21.7 GB of working memory
    /// untiled, measured at 20.7 GB a megapixel — and low-memory mode, which decodes in
    /// 512×512 tiles, takes it down to one tile's worth.
    @Test func tilingIsWhatTheDecodeTurnsOn() {
        let untiled = plan(Self.pruna, .mlx8)
        #expect(untiled.peakPhase?.name == "Decode")
        #expect(phase(untiled, "Decode") > Bytes(22_000_000_000))
        #expect(untiled.remediations.contains { $0.title.contains("low-memory mode") })

        var tiledConfiguration = ImageConfiguration(
            width: 1024, height: 1024, steps: 8, quantization: .mlx8, lowRAM: true,
            canReuseQuantizedSave: false
        )
        let tiled = DiffusionPlanner(profile: Self.m3Max36).plan(
            shape: Self.pruna.shape, configuration: tiledConfiguration
        )
        #expect(phase(tiled, "Decode") < Bytes(8_000_000_000))
        #expect(tiled.peakPhase?.name != "Decode")
        // Below one tile, tiling changes nothing.
        tiledConfiguration.width = 512
        tiledConfiguration.height = 512
        var untiledSmall = tiledConfiguration
        untiledSmall.lowRAM = false
        #expect(DiffusionPlanner.decodeActivationBytes(Self.pruna.shape, tiledConfiguration)
                == DiffusionPlanner.decodeActivationBytes(Self.pruna.shape, untiledSmall))
        // Families whose low-memory mode does not tile are charged the same either way.
        let klein = DiffusionCatalog.flux2Klein4B.shape
        var kleinTiled = ImageConfiguration(width: 1024, height: 1024, steps: 8, lowRAM: true)
        let tiledKlein = DiffusionPlanner.decodeActivationBytes(klein, kleinTiled)
        kleinTiled.lowRAM = false
        #expect(tiledKlein == DiffusionPlanner.decodeActivationBytes(klein, kleinTiled))
    }

    /// The owner's 36 GB M3 Max: at 8-bit both entries fit, comfortably once the decode is
    /// tiled; without tiling the plan says it is tight rather than promising a fit.
    @Test func a36GBMacRunsItAt8BitWithATiledDecode() {
        for entry in [Self.base, Self.pruna] {
            let untiled = plan(entry, .mlx8)
            #expect(untiled.verdict == .tight, "\(entry.id): \(untiled.peak.formatted) against \(untiled.budget.formatted)")
            let tiled = DiffusionPlanner(profile: Self.m3Max36).plan(
                shape: entry.shape,
                configuration: ImageConfiguration(
                    width: 1024, height: 1024, steps: entry.shape.defaultSteps,
                    quantization: .mlx8, lowRAM: true, canReuseQuantizedSave: false
                )
            )
            #expect(tiled.verdict == .comfortable)
            #expect(tiled.peak < Bytes(10_000_000_000))
        }
    }

    /// A Mac whose other apps hold most of its memory is told the untiled render will not fit.
    /// And a 16 GB Mac, which cannot hold the untiled decode at all, still runs the few-step
    /// entry at 4-bit with a tiled decode.
    @Test func smallerOrBusierMacsAreToldTheTruth() {
        let crowded = plan(Self.pruna, .mlx8, otherApps: .gib(24))
        #expect(!crowded.verdict.isUsable)
        let small = SystemProfile(
            chipName: "Apple M2", generation: .m2, variant: .base, modelIdentifier: "Mac14,2",
            totalMemory: .gib(16), performanceCores: 4, efficiencyCores: 4, gpuCores: 10,
            neuralEngineCores: 16, diskTotal: .gib(512), diskFree: .gib(100),
            memoryBandwidthGBps: 100, ssdReadMBps: 3000
        )
        #expect(plan(Self.pruna, .mlx4, profile: small).verdict == .impossible)
        let tiledSmall = DiffusionPlanner(profile: small).plan(
            shape: Self.pruna.shape,
            configuration: ImageConfiguration(
                width: 1024, height: 1024, steps: 8, quantization: .mlx4, lowRAM: true,
                canReuseQuantizedSave: false
            )
        )
        #expect(tiledSmall.verdict.isUsable, "\(tiledSmall.peak.formatted) against \(tiledSmall.budget.formatted)")
    }

    /// Old shapes still decode: every field added for this family has a default.
    @Test func aShapeWrittenBeforeTheseFieldsStillReads() throws {
        let old = """
            {"blockCount":25,"hiddenSize":2560,"headCount":24,"transformerParameters":3997000000,
             "vaeParameters":84000000,"textEncoderParameters":4148000000,"vaeScaleFactor":8,
             "latentChannels":16,"patchSize":2,"maxTextTokens":512,"nativeResolution":1024,
             "defaultSteps":8,"peakIsCalibrated":true}
            """
        let shape = try JSONDecoder().decode(DiffusionShape.self, from: Data(old.utf8))
        #expect(shape == DiffusionCatalog.flux2Klein4B.shape)
        let again = try JSONDecoder().decode(
            DiffusionShape.self, from: JSONEncoder().encode(Self.pruna.shape)
        )
        #expect(again == Self.pruna.shape)
    }
}
