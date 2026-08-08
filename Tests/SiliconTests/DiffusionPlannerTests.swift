import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore
@testable import SiliconHardware
@testable import SiliconPlanner

private let m3Max = SystemProfile(
    chipName: "Apple M3 Max", generation: .m3, variant: .max, modelIdentifier: "Mac15,11",
    totalMemory: .gib(36), performanceCores: 10, efficiencyCores: 4, gpuCores: 30,
    neuralEngineCores: 16, diskTotal: .gib(1024), diskFree: .gib(400),
    memoryBandwidthGBps: 300, ssdReadMBps: 5000
)

@Suite("Diffusion memory planning")
struct DiffusionPlannerTests {

    private let schnell = DiffusionCatalog.fluxSchnell.shape

    /// The defining difference from a language model: stages do not overlap, so the peak is the
    /// tallest one rather than the sum. Summing would roughly double the answer.
    @Test func peakIsTheTallestPhaseNotTheSum() {
        let plan = DiffusionPlanner(profile: m3Max).plan(
            shape: schnell, configuration: ImageConfiguration()
        )
        let total = plan.phases.reduce(Bytes.zero) { $0 + $1.resident }
        #expect(plan.peak < total)
        #expect(plan.peak == plan.phases.map(\.resident).max())
        // Load, Encode, Denoise, Decode.
        #expect(plan.phases.count == 4)
    }

    /// FLUX's text encoders are 4.9B parameters — bigger than many language models. Holding them
    /// through the denoising loop is the single most wasteful thing a naive runner does.
    @Test func freeingTextEncodersChangesTheDenoisePhase() {
        let planner = DiffusionPlanner(profile: m3Max)
        let kept = planner.plan(
            shape: schnell,
            configuration: ImageConfiguration(evictTextEncoders: false)
        )
        let freed = planner.plan(
            shape: schnell,
            configuration: ImageConfiguration(evictTextEncoders: true)
        )
        let keptDenoise = kept.phases.first { $0.name == "Denoise" }!.resident
        let freedDenoise = freed.phases.first { $0.name == "Denoise" }!.resident
        #expect(keptDenoise > freedDenoise)
        // 4.88B parameters at 4.5 bits is roughly 2.7 GB.
        #expect((keptDenoise - freedDenoise) > .gib(2))
    }

    /// Cost scales with area, so doubling each side roughly quadruples latents and activations.
    @Test func costScalesWithAreaNotSideLength() {
        let planner = DiffusionPlanner(profile: m3Max)
        // Prequantized, because otherwise the one-off load spike dominates both and the
        // resolution effect this test is about is invisible.
        let small = planner.plan(
            shape: schnell,
            configuration: ImageConfiguration(
                width: 512, height: 512, weightsArePrequantized: true
            )
        )
        let large = planner.plan(
            shape: schnell,
            configuration: ImageConfiguration(
                width: 2048, height: 2048, weightsArePrequantized: true
            )
        )
        let smallActivations = DiffusionPlanner.denoiseActivationBytes(
            schnell, ImageConfiguration(width: 512, height: 512)
        )
        let largeActivations = DiffusionPlanner.denoiseActivationBytes(
            schnell, ImageConfiguration(width: 2048, height: 2048)
        )
        let ratio = Double(largeActivations.rawValue) / Double(smallActivations.rawValue)
        // 512 -> 2048 is 16x the area.
        #expect(abs(ratio - 16.0) < 0.5, "expected roughly 16x, got \(ratio)")

        // Compared per phase rather than on the peak: for a model this large the weights
        // dominate at every resolution, so the peak is flat while the phases that actually
        // scale with area are not. That is the model being right, not the test being lenient.
        #expect(large.phases.first { $0.name == "Denoise" }!.resident
                > small.phases.first { $0.name == "Denoise" }!.resident)
        #expect(large.phases.first { $0.name == "Decode" }!.resident
                > small.phases.first { $0.name == "Decode" }!.resident)
    }

    @Test func tiledDecodeCapsTheDecodePhase() {
        let planner = DiffusionPlanner(profile: m3Max)
        let whole = planner.plan(
            shape: schnell, configuration: ImageConfiguration(width: 2048, height: 2048)
        )
        let tiled = planner.plan(
            shape: schnell,
            configuration: ImageConfiguration(width: 2048, height: 2048, tiledDecode: true)
        )
        let wholeDecode = whole.phases.first { $0.name == "Decode" }!.resident
        let tiledDecode = tiled.phases.first { $0.name == "Decode" }!.resident
        #expect(tiledDecode < wholeDecode)
    }

    /// Layer streaming is the same idea as expert streaming, applied to DiT blocks.
    @Test func layerStreamingReducesTheDenoisePhase() {
        let planner = DiffusionPlanner(profile: m3Max)
        let resident = planner.plan(
            shape: schnell,
            configuration: ImageConfiguration(weightsArePrequantized: true)
        )
        let streamed = planner.plan(
            shape: schnell,
            configuration: ImageConfiguration(residentBlocks: 14, weightsArePrequantized: true)
        )
        #expect(streamed.phases.first { $0.name == "Denoise" }!.resident
                < resident.phases.first { $0.name == "Denoise" }!.resident)
        #expect(streamed.streamedFromDisk > .gib(3))
        // Nothing vanishes: the weights moved to disk, they did not shrink.
        let residentDenoise = resident.phases.first { $0.name == "Denoise" }!.resident
        let streamedDenoise = streamed.phases.first { $0.name == "Denoise" }!.resident
        #expect(abs((streamedDenoise + streamed.streamedFromDisk).gibibytes
                    - residentDenoise.gibibytes) < 0.1)
    }

    /// Streaming re-reads every block on every step, so the disk cost is per-step, not once.
    @Test func streamingNotesTheRepeatedReadCost() {
        let plan = DiffusionPlanner(profile: m3Max).plan(
            shape: schnell, configuration: ImageConfiguration(steps: 4, residentBlocks: 14)
        )
        #expect(plan.notes.contains { $0.contains("4 times") })
    }

    @Test func remediationsTargetWhicheverPhaseIsTallest() {
        var small = m3Max
        small.totalMemory = .gib(8)
        let plan = DiffusionPlanner(profile: small).plan(
            shape: schnell,
            configuration: ImageConfiguration(width: 2048, height: 2048, quantization: .mlx8)
        )
        #expect(!plan.verdict.isUsable)
        #expect(!plan.remediations.isEmpty)
        #expect(plan.remediations.map(\.saving.rawValue) == plan.remediations.map(\.saving.rawValue).sorted(by: >))
    }

    @Test func comfortableSetupNeedsNoRemediation() {
        let plan = DiffusionPlanner(profile: m3Max).plan(
            shape: DiffusionCatalog.flux2Klein4B.shape,
            configuration: ImageConfiguration(
                width: 1024, height: 1024, weightsArePrequantized: true
            )
        )
        #expect(plan.verdict == .comfortable)
        #expect(plan.remediations.isEmpty)
    }
}

@Suite("Diffusion prediction record")
struct DiffusionPredictionRecord {
    /// Records what the planner predicts, so the figures checked against a real run are the
    /// ones this build actually produces rather than something remembered.
    @Test func printsPredictionsForTheModelsUnderTest() {
        let planner = DiffusionPlanner(profile: m3Max)
        for entry in [DiffusionCatalog.flux2Klein4B, DiffusionCatalog.fluxSchnell] {
            for quantization in [Quantization.mlx4] {
                let configuration = ImageConfiguration(
                    width: 1024, height: 1024,
                    steps: entry.shape.defaultSteps, quantization: quantization,
                    weightsArePrequantized: false
                )
                let plan = planner.plan(shape: entry.shape, configuration: configuration)
                print("\n\(entry.name) · \(quantization.rawValue) · 1024x1024")
                for phase in plan.phases {
                    print(String(format: "  %-8s %@", (phase.name as NSString).utf8String!,
                                 phase.resident.formatted))
                }
                print("  PEAK     \(plan.peak.formatted)  (\(plan.peakPhase?.name ?? "-"))")
                print("  verdict  \(plan.verdict.label)")
            }
        }
        #expect(Bool(true))
    }
}

@Suite("Diffusion prediction against measurement")
struct DiffusionMeasurementTests {

    /// Measured on this machine: FLUX.2-klein-4B, 1024x1024, 8 steps, 4-bit, weights fetched at
    /// full precision and quantized at load. MFLUX reported `Peak MLX memory: 17.94 GB`.
    ///
    /// The first version of this planner predicted 2.7 GB, because it assumed the weights
    /// arrived already quantized. They do not — which is exactly the kind of confidently wrong
    /// number this project exists to avoid.
    ///
    /// Reproduced twice: 17.94 GB, then 17.9 GB on a second run driven through the app itself.
    /// The prediction sits ~6% above that, because the model charges a full-precision copy of
    /// every component at once while mflux quantizes them one at a time and frees as it goes.
    /// Left deliberately on the high side: a planner that promises a fit and then OOMs is worse
    /// than one that warns slightly early, so the error is bounded in both directions but the
    /// band is not centred.
    @Test func matchesTheMeasuredPeakForAnUnquantizedFirstRun() {
        let plan = DiffusionPlanner(profile: m3Max).plan(
            shape: DiffusionCatalog.flux2Klein4B.shape,
            configuration: ImageConfiguration(
                width: 1024, height: 1024, steps: 8,
                quantization: .mlx4, weightsArePrequantized: false
            )
        )
        let measured = 17.94       // GB, reported by MFLUX
        let predicted = Double(plan.peak.rawValue) / 1e9
        #expect(predicted >= measured,
                "predicted \(String(format: "%.2f", predicted)) GB — must not under-promise")
        #expect((predicted - measured) / measured < 0.10,
                "predicted \(String(format: "%.2f", predicted)) GB against \(measured) GB measured")
        #expect(plan.peakPhase?.name == "Load", "the load spike should dominate a first run")
    }

    /// Once a quantized copy exists the load spike disappears and denoising takes over.
    @Test func prequantizedWeightsRemoveTheLoadSpike() {
        let planner = DiffusionPlanner(profile: m3Max)
        let shape = DiffusionCatalog.flux2Klein4B.shape
        let first = planner.plan(
            shape: shape,
            configuration: ImageConfiguration(steps: 8, weightsArePrequantized: false)
        )
        let later = planner.plan(
            shape: shape,
            configuration: ImageConfiguration(steps: 8, weightsArePrequantized: true)
        )
        #expect(later.peak < first.peak / 2)
        #expect(first.peakPhase?.name == "Load")
        // Load still peaks even prequantized — every component is resident before the text
        // encoders are freed — but it drops from a full-precision spike to the settled size.
        #expect(later.peak < .gib(6))
    }

    /// The consequence that matters: FLUX.1-schnell cannot be quantized on the fly on a 36 GB
    /// machine, because the full-precision weights alone are over 33 GB. Telling someone it
    /// "fits at 4-bit" would strand them minutes into a download.
    @Test func schnellDoesNotFitWhenQuantizingOnTheFly() {
        let planner = DiffusionPlanner(profile: m3Max)
        let shape = DiffusionCatalog.fluxSchnell.shape

        let onTheFly = planner.plan(
            shape: shape,
            configuration: ImageConfiguration(steps: 4, weightsArePrequantized: false)
        )
        #expect(!onTheFly.verdict.isUsable)
        #expect(onTheFly.remediations.contains { $0.title.contains("quantized copy") })

        let prepared = planner.plan(
            shape: shape,
            configuration: ImageConfiguration(steps: 4, weightsArePrequantized: true)
        )
        #expect(prepared.verdict.isUsable, "with a quantized copy it should fit comfortably")
    }

    /// mflux 0.18.1 can write a quantized FLUX.2 copy but not read one back, so the app must not
    /// offer "save a quantized copy" for that family — the advice ends in an error message.
    @Test func doesNotSuggestSavingAQuantizedCopyWhenItCannotBeLoadedBack() {
        let planner = DiffusionPlanner(profile: m3Max)
        let shape = DiffusionCatalog.flux2Klein4B.shape

        var reusable = ImageConfiguration(width: 1024, height: 1024, steps: 8, quantization: .mlx4)
        reusable.canReuseQuantizedSave = true
        var notReusable = reusable
        notReusable.canReuseQuantizedSave = false

        let offered = planner.plan(shape: shape, configuration: reusable, otherAppsInUse: .gib(20))
        let withheld = planner.plan(
            shape: shape, configuration: notReusable, otherAppsInUse: .gib(20)
        )

        #expect(offered.peakPhase?.name == "Load")
        #expect(offered.remediations.contains { $0.title.contains("quantized copy") })
        #expect(!withheld.remediations.contains { $0.title.contains("quantized copy") })

        // The numbers must not move — only the advice does.
        #expect(offered.peak == withheld.peak)
        #expect(withheld.notes.contains { $0.contains("every run, not just the first") })
    }

    /// The catalog figures are counted from the shipped safetensors, so the planner's idea of a
    /// quantized copy should match what `mflux-save --quantize 4` actually writes: 4.61 GB across
    /// transformer, text encoder and VAE, at a measured 4.48 bits per weight.
    @Test func prequantizedLoadMatchesTheSizeOnDisk() {
        let planner = DiffusionPlanner(profile: m3Max)
        var configuration = ImageConfiguration(
            width: 1024, height: 1024, steps: 8, quantization: .mlx4
        )
        configuration.weightsArePrequantized = true

        let plan = planner.plan(shape: DiffusionCatalog.flux2Klein4B.shape, configuration: configuration)
        let load = plan.phases.first { $0.name == "Load" }!.resident

        // 4.61 GB of weights plus the Metal floor.
        let measured = 4.61e9
        let predicted = Double(load.rawValue) - Double(Bytes.mib(320).rawValue)
        let error = abs(predicted - measured) / measured
        #expect(error < 0.05, "predicted \(predicted / 1e9) GB against 4.61 GB measured")
    }
}
