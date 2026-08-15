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

    /// Cost scales with area, so doubling each side roughly quadruples what resolution drives.
    ///
    /// Regression for the first half of issue #3: the peak used to barely move with resolution
    /// at all, because the resolution-dependent terms summed to under a gigabyte at 1024x1024
    /// where measurement needs nearly ten. A flat load spike made up the difference at one
    /// resolution and nowhere else.
    @Test func costScalesWithAreaNotSideLength() {
        let planner = DiffusionPlanner(profile: m3Max)
        let klein = DiffusionCatalog.flux2Klein4B.shape
        let small = planner.plan(
            shape: klein, configuration: ImageConfiguration(width: 512, height: 512)
        )
        let large = planner.plan(
            shape: klein, configuration: ImageConfiguration(width: 1024, height: 1024)
        )

        // Four times the area, and the decode term is what carries it.
        let ratio = Double(DiffusionPlanner.decodeActivationBytes(
            klein, ImageConfiguration(width: 1024, height: 1024)
        ).rawValue) / Double(DiffusionPlanner.decodeActivationBytes(
            klein, ImageConfiguration(width: 512, height: 512)
        ).rawValue)
        #expect(abs(ratio - 4.0) < 0.05, "expected 4x the area, got \(ratio)")

        // The peak itself has to move too — that is the part that was broken. Measurement puts
        // the gap between these two resolutions at 7.4 GB.
        #expect(Double((large.peak - small.peak).rawValue) / 1e9 > 6.0)
    }

    /// `--low-ram` is the only memory flag mflux has, and it was measured to change the peak of
    /// a single image by nothing at all. The planner must not pretend otherwise: it once offered
    /// "decode the image in tiles" for a runtime with no tiling flag, which passed `--low-ram`
    /// and then reported a saving that never materialised.
    @Test func lowRAMModeIsNotChargedAsAMemorySaving() {
        let planner = DiffusionPlanner(profile: m3Max)
        let plain = planner.plan(
            shape: schnell, configuration: ImageConfiguration(width: 2048, height: 2048)
        )
        let low = planner.plan(
            shape: schnell,
            configuration: ImageConfiguration(width: 2048, height: 2048, lowRAM: true)
        )
        #expect(plain.peak == low.peak)
        #expect(!plain.remediations.contains { $0.title.lowercased().contains("tile") })
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
        for entry in DiffusionCatalog.all {
            for side in [512, 640, 768, 896, 1024] {
                let configuration = ImageConfiguration(
                    width: side, height: side,
                    steps: entry.shape.defaultSteps, quantization: .mlx4,
                    weightsArePrequantized: false
                )
                let plan = planner.plan(shape: entry.shape, configuration: configuration)
                print("\n\(entry.name) · 4-bit · \(side)x\(side)")
                for phase in plan.phases {
                    print(String(format: "  %-8s %@", (phase.name as NSString).utf8String!,
                                 phase.resident.formatted))
                }
                print("  PEAK     \(plan.peak.formatted)  (\(plan.peakPhase?.name ?? "-"))")
                print("  verdict  \(plan.verdict.label)")
                if let measured = DiffusionMeasurementTests.measuredPeaks.first(where: {
                    $0.model == entry.id && $0.side == side
                }) {
                    let predicted = Double(plan.peak.rawValue) / 1e9
                    print(String(format: "  measured %.2f GB  (%+.1f%%)", measured.peakGB,
                                 (predicted - measured.peakGB) / measured.peakGB * 100))
                }
            }
        }
        #expect(Bool(true))
    }
}

@Suite("Diffusion prediction against measurement")
struct DiffusionMeasurementTests {

    /// Every peak this planner has been checked against, at the resolution it was measured at.
    ///
    /// Seven runs, two models, two machines, all mflux 0.18.1 at 4-bit with 8 steps. The
    /// 1024x1024 klein-4B figure was measured here on an M3 Max and independently on an M5 Pro,
    /// which agreed to the second decimal; the rest of the sweep is from the M5 Pro (issue #3).
    /// Peak memory is a property of the graph, not of the machine, which is why figures from a
    /// 24 GB machine calibrate a planner running on a 36 GB one.
    ///
    ///     model       resolution   Mpx     measured peak
    ///     klein-4B    512x512      0.262   10.52 GB
    ///     klein-4B    640x640      0.410   11.81 GB
    ///     klein-4B    768x768      0.590   13.53 GB
    ///     klein-4B    896x896      0.803   15.60 GB
    ///     klein-4B    1024x1024    1.049   17.94 GB
    ///     klein-9B    512x512      0.262   20.93 GB
    ///     klein-9B    768x768      0.590   23.94 GB
    static let measuredPeaks: [(model: String, side: Int, peakGB: Double)] = [
        ("flux2-klein-4b", 512, 10.52),
        ("flux2-klein-4b", 640, 11.81),
        ("flux2-klein-4b", 768, 13.53),
        ("flux2-klein-4b", 896, 15.60),
        ("flux2-klein-4b", 1024, 17.94),
        ("flux2-klein-9b", 512, 20.93),
        ("flux2-klein-9b", 768, 23.94),
    ]

    /// The band is deliberately not centred. A planner that promises a fit and then runs the
    /// machine out of memory is worse than one that warns a little early, so the error must stay
    /// positive; 10% caps how much caution is allowed before it becomes its own bug.
    ///
    /// The version this replaced satisfied both bounds at 1024x1024 and nowhere else — 82% high
    /// at 512x512 on klein-4B, 37% high on klein-9B, which is what issue #3 reported. Two errors
    /// of opposite sign happened to cancel at the single resolution it had been checked at.
    @Test(arguments: DiffusionMeasurementTests.measuredPeaks)
    func staysWithinTenPercentAboveEveryMeasuredPeak(
        model: String, side: Int, peakGB: Double
    ) {
        let shape = DiffusionCatalog.entry(id: model)!.shape
        let plan = DiffusionPlanner(profile: m3Max).plan(
            shape: shape,
            configuration: ImageConfiguration(
                width: side, height: side, steps: 8,
                quantization: .mlx4, weightsArePrequantized: false
            )
        )
        let predicted = Double(plan.peak.rawValue) / 1e9
        let error = (predicted - peakGB) / peakGB
        let report = String(
            format: "%@ at %dx%d: predicted %.2f GB against %.2f GB measured (%+.1f%%)",
            model, side, side, predicted, peakGB, error * 100
        )
        #expect(predicted >= peakGB, "under-promises — \(report)")
        #expect(error < 0.10, "over-cautious — \(report)")
    }

    /// Which phase peaks changes with resolution, and getting that wrong is what made the old
    /// model insensitive to it. Loading is the tall phase only below about a quarter of a
    /// megapixel; above that the VAE decode overtakes it and keeps climbing.
    ///
    /// The crossover is that low because both phases scale with the same thing. Loading charges
    /// the largest component at two bytes a parameter, and the decode charges the transformer at
    /// two bytes a parameter — so which one wins is decided by the resolution term alone, and
    /// the resolution term passes the gap between them at roughly 480x480.
    @Test func theDecodeOvertakesTheLoadAsResolutionRises() {
        let planner = DiffusionPlanner(profile: m3Max)
        let shape = DiffusionCatalog.flux2Klein4B.shape
        let tiny = planner.plan(
            shape: shape, configuration: ImageConfiguration(width: 384, height: 384, steps: 8)
        )
        let large = planner.plan(
            shape: shape, configuration: ImageConfiguration(width: 1024, height: 1024, steps: 8)
        )
        #expect(tiny.peakPhase?.name == "Load")
        #expect(large.peakPhase?.name == "Decode")
    }

    /// Loading reads one component at a time, so only the largest is ever at full precision.
    ///
    /// klein-4B: 8.30 GB for the text encoder at fp16 plus 2.30 GB for the transformer and VAE
    /// already reduced, against 10.52 GB measured at the resolution where this phase is the peak.
    /// The old model charged every component at full precision simultaneously — 19.1 GB, 8 GB of
    /// memory that is never all live at once.
    @Test func theLoadPhaseChargesOneComponentAtFullPrecisionNotAll() {
        let plan = DiffusionPlanner(profile: m3Max).plan(
            shape: DiffusionCatalog.flux2Klein4B.shape,
            configuration: ImageConfiguration(width: 512, height: 512, steps: 8)
        )
        let load = Double(plan.phases.first { $0.name == "Load" }!.resident.rawValue) / 1e9
        #expect(abs(load - 10.59 - 0.335) < 0.2, "load phase predicted \(load) GB")

        let everythingAtOnce = Double(
            DiffusionPlanner.weightBytes(
                DiffusionCatalog.flux2Klein4B.shape.totalParameters, .f16
            ).rawValue
        ) / 1e9
        #expect(load < everythingAtOnce, "\(load) GB should be well under \(everythingAtOnce) GB")
    }

    /// The consequence issue #3 was actually about: klein-9B runs on a 24 GB machine at 512x512,
    /// and the app refused it outright. "Won't fit" and "will swap" are different claims, and
    /// only one of them was true — it produced a correct image, slowly, at 20.93 GB measured.
    @Test func kleinNineBIsCalledSlowRatherThanImpossibleOnATwentyFourGigMachine() {
        var m5Pro = m3Max
        m5Pro.chipName = "Apple M5 Pro"
        m5Pro.totalMemory = .gib(24)

        let planner = DiffusionPlanner(profile: m5Pro)
        let shape = DiffusionCatalog.flux2Klein9B.shape

        let small = planner.plan(
            shape: shape, configuration: ImageConfiguration(width: 512, height: 512, steps: 8)
        )
        // Measured 20.93 GB on a 25.77 GB machine — tight, not impossible. It took 390s, and it
        // finished, and it produced a better image than klein-4B did.
        #expect(small.verdict == .willSwap)
        #expect(small.verdict != .impossible)

        // And klein-4B, which the same machine was told would swap, is comfortable.
        let klein4B = planner.plan(
            shape: DiffusionCatalog.flux2Klein4B.shape,
            configuration: ImageConfiguration(width: 512, height: 512, steps: 8)
        )
        #expect(klein4B.verdict == .comfortable, "measured 10.52 GB, generated in 13 seconds")

        // At 1024x1024 klein-9B genuinely does not fit on this machine, and should still say so.
        let large = planner.plan(
            shape: shape, configuration: ImageConfiguration(width: 1024, height: 1024, steps: 8)
        )
        #expect(large.verdict == .impossible)
    }

    /// mflux 0.18.1 can write a quantized FLUX.2 copy but not read one back, so the app must not
    /// offer "save a quantized copy" for that family — the advice ends in an error message.
    ///
    /// Tested at 384x384 because that is now the only place the advice can appear at all: saving
    /// a quantized copy shortens the load phase, and the load phase stops being the peak above
    /// about a quarter of a megapixel. Below that window the suggestion is real; above it, it
    /// would be offering to fix something that is not what is tall.
    @Test func doesNotSuggestSavingAQuantizedCopyWhenItCannotBeLoadedBack() {
        let planner = DiffusionPlanner(profile: m3Max)
        let shape = DiffusionCatalog.flux2Klein4B.shape

        var reusable = ImageConfiguration(width: 384, height: 384, steps: 8, quantization: .mlx4)
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

    /// A resident language model has to be charged against an image run, because generating an
    /// image does not replace it — llama-server keeps its weights the whole time.
    ///
    /// The app used to exclude the loaded model from the image budget (correct for planning
    /// another *language* load, which would swap it out) and so called a 19 GB image run
    /// comfortable while 20 GB of Qwen was resident on a 38 GB machine. It ran out of memory.
    @Test func aResidentLanguageModelCountsAgainstAnImageRun() {
        let planner = DiffusionPlanner(profile: m3Max)
        let configuration = ImageConfiguration(
            width: 1024, height: 1024, steps: 8, quantization: .mlx4
        )
        let shape = DiffusionCatalog.flux2Klein4B.shape

        let alone = planner.plan(shape: shape, configuration: configuration, otherAppsInUse: .gib(3))
        let alongsideAnLLM = planner.plan(
            shape: shape, configuration: configuration, otherAppsInUse: .gib(23)
        )

        #expect(alone.verdict == .comfortable)
        #expect(!alongsideAnLLM.verdict.isUsable)
        // The run costs the same either way — it is the budget that moved.
        #expect(alone.peak == alongsideAnLLM.peak)
        #expect(alongsideAnLLM.budget < alone.budget)
    }
}

@Suite("Image model installation")
struct DiffusionInstallerTests {

    /// The CLI reports human sizes, and a bare number means bytes.
    @Test func parsesTheSizesTheCLIPrints() {
        #expect(DiffusionInstaller.parseSize("7.8G") == 7_800_000_000)
        #expect(DiffusionInstaller.parseSize("1.6K") == 1_600)
        #expect(DiffusionInstaller.parseSize("2.5M") == 2_500_000)
        #expect(DiffusionInstaller.parseSize("446.0") == 446)
        #expect(DiffusionInstaller.parseSize("-") == 0)
    }

    /// Only what MFLUX actually reads. Fetching the whole repository would pull
    /// FLUX.2-klein-4B's 7.8 GB single-file variant, which it never opens.
    @Test func fetchesOnlyTheComponentsTheRuntimeLoads() {
        for entry in DiffusionCatalog.all {
            #expect(!entry.downloadPatterns.contains("*"))
            #expect(entry.downloadPatterns.contains { $0.hasPrefix("transformer/") })
            #expect(entry.downloadPatterns.contains { $0.hasPrefix("vae/") })
        }
    }

    /// The families do not have the same layout, and assuming they do loses most of a model.
    ///
    /// FLUX.1 keeps its T5-XXL — 9.5 GB, the largest file in the repository — in
    /// `text_encoder_2`. A pattern list written from FLUX.2's four directories omits it, and
    /// because `hf download` exits cleanly having fetched what it was asked for, the install
    /// reports success and the first generation is what discovers the model is incomplete.
    @Test func fluxOneFetchesTheSecondTextEncoder() {
        for entry in [DiffusionCatalog.fluxSchnell, DiffusionCatalog.fluxDev] {
            #expect(entry.downloadPatterns.contains { $0.hasPrefix("text_encoder_2/") })
            #expect(entry.componentDirectories.contains("text_encoder_2"))
        }
        for entry in [DiffusionCatalog.flux2Klein4B, DiffusionCatalog.flux2Klein9B] {
            #expect(!entry.componentDirectories.contains("text_encoder_2"))
            // FLUX.2 keeps a chat template at the repository root, which a list of directories
            // silently drops.
            #expect(entry.downloadPatterns.contains("chat_template.jinja"))
        }
    }

    /// Hugging Face's cache flattens `org/name` into `models--org--name`.
    @Test func mapsRepositoriesOntoTheHubCacheLayout() {
        let directory = DiffusionInstaller.cacheDirectory(
            for: "black-forest-labs/FLUX.2-klein-4B"
        )
        #expect(directory.lastPathComponent == "models--black-forest-labs--FLUX.2-klein-4B")
    }

    /// Checked against the Hub API rather than inferred from the licence: schnell is Apache-2.0
    /// but its repository is still gated, and klein-9B is gated too. Getting this wrong sends
    /// someone into a download that fails with "access denied".
    @Test func recordsWhichModelsAreGated() {
        #expect(DiffusionCatalog.fluxSchnell.isGated)
        #expect(DiffusionCatalog.fluxDev.isGated)
        #expect(DiffusionCatalog.flux2Klein9B.isGated)
        #expect(!DiffusionCatalog.flux2Klein4B.isGated)
    }
}
