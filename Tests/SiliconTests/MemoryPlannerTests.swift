import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore
@testable import SiliconHardware
@testable import SiliconPlanner

/// The machine the llama.cpp expert-paging RFC benchmarked on, so predictions can be compared
/// directly against its published table.
private let m3Pro36 = SystemProfile(
    chipName: "Apple M3 Pro", generation: .m3, variant: .pro, modelIdentifier: "Mac15,6",
    totalMemory: .gib(36), performanceCores: 6, efficiencyCores: 6, gpuCores: 18,
    neuralEngineCores: 16, diskTotal: .gib(1024), diskFree: .gib(500),
    memoryBandwidthGBps: 150, ssdReadMBps: 5000
)

private let m3Max36 = SystemProfile(
    chipName: "Apple M3 Max", generation: .m3, variant: .max, modelIdentifier: "Mac15,11",
    totalMemory: .gib(36), performanceCores: 10, efficiencyCores: 4, gpuCores: 30,
    neuralEngineCores: 16, diskTotal: .gib(1024), diskFree: .gib(500),
    memoryBandwidthGBps: 300, ssdReadMBps: 5000
)

private let qwen30BA3B = ModelCatalog.qwen3_30B_A3B.shape

@Suite("Expert slot sizing")
struct ExpertSlotTests {

    /// The RFC reports ~0.173 GiB of wired memory per slot for Qwen3-30B-A3B at Q6_K. A slot
    /// holds one expert across every MoE layer, so the size is
    /// `3 * d_model * d_expert_ffn * n_moe_layers * bpw / 8`.
    @Test func perSlotSizeMatchesPublishedBenchmark() {
        let parameters = MemoryPlanner.parametersPerExpertSlot(qwen30BA3B)
        #expect(parameters == 3 * 2048 * 768 * 48)

        let bytes = MemoryPlanner.weightBytes(parameters, .q6_K)
        // 0.173 GiB, within a hundredth of a gibibyte.
        #expect(abs(bytes.gibibytes - 0.173) < 0.01)
    }

    /// Slot count and wired memory should be linear, which is what makes the published table a
    /// straight line: 32 -> 10.6, 64 -> 16.1, 80 -> 18.9 GiB.
    @Test(arguments: [(32, 10.6), (64, 16.1), (80, 18.9)])
    func residentMemoryTracksPublishedTable(slots: Int, expectedGiB: Double) {
        let planner = MemoryPlanner(profile: m3Pro36)
        let configuration = LoadConfiguration(
            contextLength: 32_768,
            kvCachePrecision: .f16,
            flashAttention: true,
            expertStreaming: ExpertStreamingConfiguration(slotCount: slots)
        )
        let plan = planner.plan(
            shape: qwen30BA3B, quantization: .q6_K, configuration: configuration
        )
        // Within 1 GiB of the measured figure. The residual covers Metal driver overhead we
        // deliberately do not try to model exactly.
        #expect(abs(plan.resident.gibibytes - expectedGiB) < 1.0,
                "slots=\(slots) predicted \(plan.resident.formatted), expected ~\(expectedGiB) GiB")
    }

    @Test func streamingReducesResidentMemory() {
        let planner = MemoryPlanner(profile: m3Pro36)
        let base = LoadConfiguration(contextLength: 32_768)
        let streamed = LoadConfiguration(
            contextLength: 32_768,
            expertStreaming: ExpertStreamingConfiguration(slotCount: 32)
        )
        let full = planner.plan(shape: qwen30BA3B, quantization: .q6_K, configuration: base)
        let paged = planner.plan(shape: qwen30BA3B, quantization: .q6_K, configuration: streamed)

        #expect(paged.resident < full.resident)
        #expect(paged.streamedFromDisk > .gib(15))
        // Nothing is lost from the model — the bytes moved, they did not disappear.
        #expect(abs((paged.resident + paged.streamedFromDisk).gibibytes - full.resident.gibibytes) < 0.1)
    }

    /// `ub * n_expert_used <= n_slots` is the constraint the RFC states; violating it risks
    /// evicting a slot that the in-flight batch still needs.
    @Test func microBatchConstraintFollowsSlotCount() {
        #expect(ExpertStreamingConfiguration.maximumMicroBatch(
            slotCount: 80, expertsUsedPerToken: 8) == 10)
        #expect(ExpertStreamingConfiguration.maximumMicroBatch(
            slotCount: 32, expertsUsedPerToken: 8) == 4)

        let configuration = ExpertStreamingConfiguration(slotCount: 64)
        #expect(configuration.satisfiesConstraint(microBatch: 8, expertsUsedPerToken: 8))
        #expect(!configuration.satisfiesConstraint(microBatch: 9, expertsUsedPerToken: 8))
    }
}

@Suite("KV cache and compute buffers")
struct CacheSizingTests {

    /// Qwen3-30B-A3B has 48 layers, 4 KV heads and a 128-wide head, so each token costs
    /// `2 * 48 * 4 * 128 * 2` = 98,304 bytes at f16.
    @Test func kvCacheScalesWithAttentionGeometry() {
        let perToken = MemoryPlanner.kvBytesPerToken(qwen30BA3B, precision: .f16)
        #expect(perToken == 98_304)

        let at32K = MemoryPlanner.kvCacheBytes(qwen30BA3B, context: 32_768, precision: .f16)
        #expect(abs(at32K.gibibytes - 3.0) < 0.05)
    }

    @Test func quantizedCacheHalvesMemory() {
        let f16 = MemoryPlanner.kvCacheBytes(qwen30BA3B, context: 32_768, precision: .f16)
        let q8 = MemoryPlanner.kvCacheBytes(qwen30BA3B, context: 32_768, precision: .q8_0)
        let ratio = Double(q8.rawValue) / Double(f16.rawValue)
        #expect(abs(ratio - 0.53) < 0.02)
    }

    /// Without flash attention the score matrix is materialised, and it dominates everything
    /// else at long context. This is the single biggest avoidable allocation in llama.cpp.
    @Test func flashAttentionRemovesTheScoreMatrix() {
        let withFA = LoadConfiguration(contextLength: 32_768, flashAttention: true)
        let withoutFA = LoadConfiguration(contextLength: 32_768, flashAttention: false)

        let a = MemoryPlanner.computeBufferBytes(qwen30BA3B, configuration: withFA)
        let b = MemoryPlanner.computeBufferBytes(qwen30BA3B, configuration: withoutFA)
        #expect(b > a + .gib(1.5))
    }
}

@Suite("Verdicts and remediations")
struct RemediationTests {

    @Test func oversizedModelIsRejectedAndExplained() {
        let planner = MemoryPlanner(profile: m3Max36)
        let plan = planner.plan(
            shape: ModelCatalog.llama3_3_70B.shape,
            quantization: .q8_0,
            configuration: LoadConfiguration(contextLength: 32_768)
        )
        #expect(!plan.verdict.isUsable)
        #expect(!plan.remediations.isEmpty)
        // A dense model has no expert-streaming escape hatch.
        #expect(!plan.remediations.contains { $0.kind == .enableExpertStreaming })
        #expect(plan.remediations.contains { $0.kind == .lowerQuantization })
    }

    @Test func moeModelIsOfferedExpertStreaming() {
        let planner = MemoryPlanner(profile: m3Max36)
        let plan = planner.plan(
            shape: ModelCatalog.gptOSS120B.shape,
            quantization: .mxfp4,
            configuration: LoadConfiguration(contextLength: 32_768)
        )
        #expect(!plan.verdict.isUsable)
        #expect(plan.remediations.contains { $0.kind == .enableExpertStreaming })
    }

    @Test func remediationsAreOrderedByImpact() {
        let planner = MemoryPlanner(profile: m3Max36)
        let plan = planner.plan(
            shape: ModelCatalog.qwen3_32B.shape,
            quantization: .q8_0,
            configuration: LoadConfiguration(contextLength: 65_536, flashAttention: false)
        )
        let savings = plan.remediations.map(\.saving.rawValue)
        #expect(savings == savings.sorted(by: >))
    }

    /// Regression: a busy machine once drove the budget to zero, and because
    /// `Bytes.fraction(of: .zero)` is 0 that scored as *perfectly comfortable* — the planner
    /// happily recommended a 35 GB Q8_0 on a 38 GB Mac and labelled it safe.
    @Test func busyMachineNeverReportsAZeroBudget() {
        let planner = MemoryPlanner(profile: m3Max36)
        // More wired memory than the machine's entire model budget.
        let plan = planner.plan(
            shape: ModelCatalog.qwen3_30B_A3B.shape,
            quantization: .q8_0,
            configuration: LoadConfiguration(contextLength: 32_768),
            otherAppsInUse: .gib(34)
        )
        #expect(plan.budget > .zero)
        #expect(!plan.verdict.isUsable)
        #expect(plan.remediations.contains { $0.kind == .closeApps })
    }

    /// Ordinary (compressible) app memory must not be charged against the budget; only wired
    /// memory is. A machine with a browser open still has to be able to run a model.
    @Test func moderateWiredMemoryBarelyMovesTheBudget() {
        let planner = MemoryPlanner(profile: m3Max36)
        let idle = planner.plan(
            shape: ModelCatalog.qwen3_8B.shape, quantization: .q4_K_M,
            configuration: LoadConfiguration(contextLength: 8192)
        )
        let busy = planner.plan(
            shape: ModelCatalog.qwen3_8B.shape, quantization: .q4_K_M,
            configuration: LoadConfiguration(contextLength: 8192),
            otherAppsInUse: .gib(3.5)          // typical wired footprint
        )
        #expect(busy.budget == idle.budget)
        #expect(busy.verdict == .comfortable)
    }

    @Test func comfortableModelNeedsNoRemediation() {
        let planner = MemoryPlanner(profile: m3Max36)
        let plan = planner.plan(
            shape: ModelCatalog.qwen3_8B.shape,
            quantization: .q4_K_M,
            configuration: LoadConfiguration(contextLength: 8192)
        )
        #expect(plan.verdict == .comfortable)
        #expect(plan.remediations.isEmpty)
    }
}

@Suite("Speed estimates")
struct SpeedTests {

    /// A 3.3B-active MoE on 300 GB/s should land in the tens of tokens per second, not the
    /// hundreds and not single digits.
    @Test func moeGeneratesAtActiveParameterSpeed() {
        let planner = MemoryPlanner(profile: m3Max36)
        let estimator = SpeedEstimator(profile: m3Max36)
        let configuration = LoadConfiguration(contextLength: 8192)
        let plan = planner.plan(
            shape: qwen30BA3B, quantization: .q4_K_M, configuration: configuration
        )
        let speed = estimator.estimate(
            shape: qwen30BA3B, quantization: .q4_K_M, configuration: configuration, plan: plan
        )
        #expect(speed.generationTokensPerSecond > 40)
        #expect(speed.generationTokensPerSecond < 150)
    }

    /// A dense 70B at Q4 reads ~40 GB per token, so it cannot exceed a handful of tokens
    /// per second on any current Mac.
    @Test func dense70BIsSlow() {
        let planner = MemoryPlanner(profile: m3Max36)
        let estimator = SpeedEstimator(profile: m3Max36)
        let shape = ModelCatalog.llama3_3_70B.shape
        let configuration = LoadConfiguration(contextLength: 4096)
        let plan = planner.plan(shape: shape, quantization: .q4_K_M, configuration: configuration)
        let speed = estimator.estimate(
            shape: shape, quantization: .q4_K_M, configuration: configuration, plan: plan
        )
        #expect(speed.generationTokensPerSecond < 8)
    }
}

@Suite("Automatic configuration")
struct AutoConfiguratorTests {

    @Test(arguments: [8.0, 16.0, 24.0, 36.0, 64.0, 128.0])
    func everyMemoryTierGetsAUsableRecommendation(memoryGiB: Double) {
        var profile = m3Max36
        profile.totalMemory = .gib(memoryGiB)
        let recommendation = AutoConfigurator(profile: profile).topPick()

        let pick = try? #require(recommendation)
        guard let pick else { return }
        #expect(pick.plan.verdict.isUsable)
        #expect(pick.speed.generationTokensPerSecond >= 8)
        #expect(pick.plan.resident <= profile.safeModelBudget)
    }

    /// More memory should never produce a worse recommendation.
    @Test func recommendationsImproveWithMemory() {
        var small = m3Max36
        small.totalMemory = .gib(16)
        var large = m3Max36
        large.totalMemory = .gib(128)

        let smallPick = AutoConfigurator(profile: small).topPick()
        let largePick = AutoConfigurator(profile: large).topPick()
        #expect(smallPick != nil)
        #expect(largePick != nil)
        if let smallPick, let largePick {
            #expect(largePick.entry.shape.totalParameters >= smallPick.entry.shape.totalParameters)
        }
    }

    @Test func eightGigabyteMachineGetsASmallModel() {
        var profile = m3Max36
        profile.totalMemory = .gib(8)
        profile.gpuCores = 10
        profile.memoryBandwidthGBps = 100
        let pick = AutoConfigurator(profile: profile).topPick()
        #expect(pick != nil)
        if let pick {
            #expect(pick.entry.shape.totalParameters < 10_000_000_000)
        }
    }
}

@Suite("Prefill estimates")
struct PrefillEstimateTests {

    /// Measured on the M3 Max these constants were calibrated against. Predictions should land
    /// within 15% — close enough that the advice is sound, without pretending to more precision
    /// than a two-point calibration earns.
    @Test(arguments: [
        // (model, measured prompt tok/s on M3 Max / llama.cpp b10280)
        ("qwen3-1.7b", 2374.0),
        ("qwen3-coder-30b-a3b", 895.0),
    ])
    func prefillMatchesMeasuredHardware(modelID: String, measured: Double) throws {
        let entry = try #require(ModelCatalog.entry(id: modelID))
        let configuration = LoadConfiguration(contextLength: 16_384)
        let plan = MemoryPlanner(profile: m3Max36).plan(
            shape: entry.shape, quantization: .q4_K_M, configuration: configuration
        )
        let speed = SpeedEstimator(profile: m3Max36).estimate(
            shape: entry.shape, quantization: .q4_K_M,
            configuration: configuration, plan: plan
        )
        let error = abs(speed.prefillTokensPerSecond - measured) / measured
        #expect(error < 0.15,
                "\(modelID): predicted \(Int(speed.prefillTokensPerSecond)), measured \(Int(measured))")
    }

    /// A mixture-of-experts model must not be credited with dense-model prompt throughput:
    /// routing splits one large GEMM into many small ones that never reach peak utilization.
    @Test func moeIsCreditedLessPrefillEfficiencyThanDense() {
        let dense = ModelCatalog.qwen3_8B.shape          // 8.19B, all active
        let moe = ModelCatalog.qwen3_30B_A3B.shape       // 30.5B total, 3.3B active

        let estimator = SpeedEstimator(profile: m3Max36)
        let planner = MemoryPlanner(profile: m3Max36)
        let configuration = LoadConfiguration(contextLength: 8192)

        func prefill(_ shape: ModelShape) -> Double {
            let plan = planner.plan(
                shape: shape, quantization: .q4_K_M, configuration: configuration
            )
            return estimator.estimate(
                shape: shape, quantization: .q4_K_M, configuration: configuration, plan: plan
            ).prefillTokensPerSecond
        }

        // Per active parameter, the MoE model must come out slower.
        let densePerParam = prefill(dense) * Double(dense.effectiveActiveParameters)
        let moePerParam = prefill(moe) * Double(moe.effectiveActiveParameters)
        #expect(moePerParam < densePerParam)
    }

    /// Expert streaming forces a tiny micro-batch, which is the real cost of the feature.
    @Test func expertStreamingCollapsesPrefill() {
        let shape = ModelCatalog.qwen3_30B_A3B.shape
        let planner = MemoryPlanner(profile: m3Max36)
        let estimator = SpeedEstimator(profile: m3Max36)

        let normal = LoadConfiguration(contextLength: 8192)
        var streamed = LoadConfiguration(contextLength: 8192)
        streamed.expertStreaming = ExpertStreamingConfiguration(slotCount: 32)
        streamed.microBatchSize = 4      // 4 * 8 experts == 32 slots

        func prefill(_ configuration: LoadConfiguration) -> Double {
            let plan = planner.plan(
                shape: shape, quantization: .q4_K_M, configuration: configuration
            )
            return estimator.estimate(
                shape: shape, quantization: .q4_K_M, configuration: configuration, plan: plan
            ).prefillTokensPerSecond
        }
        #expect(prefill(streamed) < prefill(normal) * 0.25)
    }
}

@Suite("Calibration isolation")
struct CalibrationIsolationTests {

    /// Regression: calibration was one number for the whole machine, so benchmarking a dense 7B
    /// (which ran 46% above the physical estimate) rewrote the prediction for a 30B MoE that had
    /// been exactly right — 89 tok/s measured became 130 tok/s predicted. Corrections belong to
    /// the model they were measured on.
    @Test func calibratingOneModelDoesNotMoveAnother() {
        let uncalibrated = AutoConfigurator(profile: m3Max36)
        let calibrated = AutoConfigurator(
            profile: m3Max36, calibrations: ["qwen2.5-vl-7b": 1.46]
        )

        let coder = ModelCatalog.qwen3Coder30B
        let before = uncalibrated.best(for: coder)?.speed.generationTokensPerSecond
        let after = calibrated.best(for: coder)?.speed.generationTokensPerSecond

        #expect(before != nil)
        #expect(after != nil)
        if let before, let after {
            #expect(abs(before - after) < 0.01, "an unrelated model's calibration leaked")
        }
    }

    /// Compared at a fixed configuration. Going through `best(for:)` would not be like-for-like:
    /// a faster estimate lets a higher quantization clear the interactive floor, so the search
    /// legitimately returns a different — better — configuration.
    @Test func calibrationScalesTheEstimateItOwns() {
        let entry = ModelCatalog.qwen2_5VL_7B
        let configuration = LoadConfiguration(contextLength: 8192)
        let plan = MemoryPlanner(profile: m3Max36).plan(
            shape: entry.shape, quantization: .q4_K_M, configuration: configuration
        )

        func speed(_ calibration: Double) -> Double {
            SpeedEstimator(profile: m3Max36, calibration: calibration).estimate(
                shape: entry.shape, quantization: .q4_K_M,
                configuration: configuration, plan: plan
            ).generationTokensPerSecond
        }
        #expect(abs(speed(1.46) - speed(1.0) * 1.46) < 0.01)
    }

    /// A better estimate is allowed to change which configuration wins — that is the point of
    /// measuring — but it must never make the recommendation worse.
    @Test func calibrationNeverDowngradesTheRecommendation() {
        let entry = ModelCatalog.qwen2_5VL_7B
        let plain = AutoConfigurator(profile: m3Max36).best(for: entry)
        let tuned = AutoConfigurator(
            profile: m3Max36, calibrations: [entry.id: 1.46]
        ).best(for: entry)

        guard let plain, let tuned else { Issue.record("no recommendation"); return }
        #expect(tuned.score >= plain.score)
    }

    @Test func unbenchmarkedModelsUseThePhysicalEstimate() {
        let configurator = AutoConfigurator(profile: m3Max36, calibrations: ["something-else": 3.0])
        let plain = AutoConfigurator(profile: m3Max36)
        let entry = ModelCatalog.qwen3_8B
        #expect(
            configurator.best(for: entry)?.speed.generationTokensPerSecond
                == plain.best(for: entry)?.speed.generationTokensPerSecond
        )
    }
}

@Suite("IQ quantization sizing")
struct IQQuantizationTests {

    /// The rates `llama-quantize --help` prints for each format. Pinned here because they are
    /// transcribed constants with no derivation to check them against — an edit that fat-fingers
    /// one would otherwise change every plan for that format silently.
    @Test(arguments: [
        (Quantization.iq1_S, 1.56),
        (.iq2_XXS, 2.06),
        (.iq3_M, 3.66),
        (.iq4_XS, 4.25),
        (.iq4_NL, 4.50),
    ])
    func bitsPerWeightMatchesPublishedRates(quantization: Quantization, expectedBpw: Double) {
        #expect(quantization.bitsPerWeight == expectedBpw)
    }

    /// Regression: `Quantization.inferred(fromFilename:)` used to return nil for IQ names, so
    /// every call site fell back to `.q4_K_M` (4.85 bpw) — roughly 2.35x too heavy at IQ2_XXS —
    /// which is the exact scenario IQ quants exist to solve. A 70B IQ2_XXS should size to
    /// roughly 18 GB, not the ~43 GB the old fallback would have produced.
    @Test func iq2XXSSeventyBSizesNearEighteenGigabytesNotFortyThree() {
        let bytes = MemoryPlanner.weightBytes(
            ModelCatalog.llama3_3_70B.shape.totalParameters, .iq2_XXS
        )
        #expect(abs(bytes.gibibytes - 16.9) < 0.5)

        let wronglyFallenBack = MemoryPlanner.weightBytes(
            ModelCatalog.llama3_3_70B.shape.totalParameters, .q4_K_M
        )
        #expect(wronglyFallenBack.gibibytes > bytes.gibibytes * 2)
    }

    /// The planning-level consequence: on a 36 GB Mac, a 70B model correctly identified as
    /// IQ2_XXS fits; the same model mis-sized at the old Q4_K_M fallback would not.
    @Test func correctlyInferredIQQuantizationFitsWhereFallbackWouldNotHaveFit() {
        let inferred = Quantization.inferred(fromFilename: "Llama-3.3-70B-Instruct-IQ2_XXS.gguf")
        #expect(inferred == .iq2_XXS)

        let planner = MemoryPlanner(profile: m3Max36)
        let plan = planner.plan(
            shape: ModelCatalog.llama3_3_70B.shape,
            quantization: inferred ?? .q4_K_M,
            configuration: LoadConfiguration(contextLength: 8192)
        )
        #expect(plan.verdict.isUsable)

        let asIfFallenBack = planner.plan(
            shape: ModelCatalog.llama3_3_70B.shape,
            quantization: .q4_K_M,
            configuration: LoadConfiguration(contextLength: 8192)
        )
        #expect(!asIfFallenBack.verdict.isUsable)
    }
}
