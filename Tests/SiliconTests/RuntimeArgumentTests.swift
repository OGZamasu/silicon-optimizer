import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore
@testable import SiliconPlanner
@testable import SiliconRuntime

private func makeModel(moe: Bool = true) -> InstalledModel {
    let entry = moe ? ModelCatalog.qwen3_30B_A3B : ModelCatalog.qwen3_8B
    return InstalledModel(
        id: "test", name: entry.name, catalogID: entry.id, quantization: .q4_K_M,
        format: .gguf, primaryFile: URL(fileURLWithPath: "/models/test.gguf"),
        allFiles: [URL(fileURLWithPath: "/models/test.gguf")], projectorFile: nil,
        sizeOnDisk: .gib(18), installedAt: Date(), shape: entry.shape,
        capabilities: entry.capabilities
    )
}

@Suite("llama.cpp argument synthesis")
struct LlamaArgumentTests {

    @Test func buildsTheExpectedBaselineCommand() {
        let arguments = LlamaArguments(
            model: makeModel(),
            configuration: LoadConfiguration(contextLength: 16_384, threads: 10),
            port: 9000
        ).build()

        #expect(arguments.contains("--model"))
        #expect(arguments.contains("/models/test.gguf"))
        #expect(consecutive(arguments, "--ctx-size", "16384"))
        #expect(consecutive(arguments, "--port", "9000"))
        // Apple Silicon shares memory between CPU and GPU, so every layer belongs on the GPU.
        #expect(consecutive(arguments, "--n-gpu-layers", "999"))
        #expect(consecutive(arguments, "--flash-attn", "on"))
        #expect(consecutive(arguments, "--threads", "10"))
        #expect(arguments.contains("--jinja"))
    }

    @Test func quantizedKVCacheSetsBothHalves() {
        let arguments = LlamaArguments(
            model: makeModel(),
            configuration: LoadConfiguration(kvCachePrecision: .q8_0),
            port: 1
        ).build()
        #expect(consecutive(arguments, "--cache-type-k", "q8_0"))
        #expect(consecutive(arguments, "--cache-type-v", "q8_0"))
    }

    @Test func f16CacheIsLeftAtTheDefault() {
        let arguments = LlamaArguments(
            model: makeModel(), configuration: LoadConfiguration(kvCachePrecision: .f16), port: 1
        ).build()
        #expect(!arguments.contains("--cache-type-k"))
    }

    /// The paging proof of concept requires `--no-mmap` (so expert tensors are never mapped up
    /// front) and `--no-warmup` (so warmup does not touch every expert and defeat the pool).
    /// Emitting `--moe-n-slots` without them produces an out-of-memory crash at load.
    @Test func expertStreamingEmitsItsRequiredCompanionFlags() {
        var configuration = LoadConfiguration(contextLength: 8192)
        configuration.expertStreaming = ExpertStreamingConfiguration(slotCount: 64)
        configuration.microBatchSize = 8

        let arguments = LlamaArguments(model: makeModel(), configuration: configuration, port: 1)
            .build()

        #expect(consecutive(arguments, "--moe-n-slots", "64"))
        #expect(arguments.contains("--no-mmap"))
        #expect(arguments.contains("--no-warmup"))
    }

    /// Regression: `--moe-n-layers` was omitted when the count was 0, trusting the "0 = all
    /// layers" default documented in `--help`. That normalisation only happens for the context
    /// parameters; the model loader reads the raw value and skips every layer, so the feature
    /// silently did nothing. Measured on Qwen3-Coder-30B: 19 GB without the flag, 5.3 GB with.
    @Test func expertStreamingAlwaysStatesItsLayerCount() {
        var configuration = LoadConfiguration(contextLength: 8192)
        configuration.expertStreaming = ExpertStreamingConfiguration(slotCount: 24)
        configuration.microBatchSize = 3

        let arguments = LlamaArguments(model: makeModel(), configuration: configuration, port: 1)
            .build()

        // Qwen3-30B-A3B has 48 MoE layers.
        #expect(consecutive(arguments, "--moe-n-layers", "48"))
    }

    @Test func anExplicitLayerCountIsHonoured() {
        var configuration = LoadConfiguration(contextLength: 8192)
        configuration.expertStreaming = ExpertStreamingConfiguration(slotCount: 24, layerCount: 12)
        configuration.microBatchSize = 3

        let arguments = LlamaArguments(model: makeModel(), configuration: configuration, port: 1)
            .build()
        #expect(consecutive(arguments, "--moe-n-layers", "12"))
    }

    @Test func noStreamingFlagsWhenStreamingIsOff() {
        let arguments = LlamaArguments(
            model: makeModel(), configuration: LoadConfiguration(), port: 1
        ).build()
        #expect(!arguments.contains("--moe-n-slots"))
        #expect(!arguments.contains("--no-mmap"))
    }

    @Test func validationRejectsAnOversizedMicroBatch() {
        var configuration = LoadConfiguration()
        configuration.expertStreaming = ExpertStreamingConfiguration(slotCount: 32)
        configuration.microBatchSize = 512      // 512 * 8 experts >> 32 slots

        let problems = LlamaArguments(model: makeModel(), configuration: configuration, port: 1)
            .validate()
        #expect(problems.contains { $0.contains("Micro-batch") })
    }

    @Test func validationAcceptsAConformingMicroBatch() {
        var configuration = LoadConfiguration()
        configuration.expertStreaming = ExpertStreamingConfiguration(slotCount: 64)
        configuration.microBatchSize = 8        // 8 * 8 == 64
        configuration.batchSize = 256

        let problems = LlamaArguments(model: makeModel(), configuration: configuration, port: 1)
            .validate()
        #expect(problems.isEmpty)
    }

    @Test func validationRejectsStreamingOnADenseModel() {
        var configuration = LoadConfiguration()
        configuration.expertStreaming = ExpertStreamingConfiguration(slotCount: 32)

        let problems = LlamaArguments(
            model: makeModel(moe: false), configuration: configuration, port: 1
        ).validate()
        #expect(problems.contains { $0.contains("mixture-of-experts") })
    }

    @Test func validationFlagsABuildWithoutStreamingSupport() {
        var configuration = LoadConfiguration()
        configuration.expertStreaming = ExpertStreamingConfiguration(slotCount: 64)
        configuration.microBatchSize = 8

        let installation = RuntimeInstallation(
            kind: .llamaCpp, executable: URL(fileURLWithPath: "/usr/bin/llama-server"),
            version: "b1234", hasExpertStreaming: false, source: .homebrew
        )
        let problems = LlamaArguments(
            model: makeModel(), configuration: configuration, port: 1, installation: installation
        ).validate()
        #expect(problems.contains { $0.contains("--moe-n-slots") })
    }

    private func consecutive(_ arguments: [String], _ flag: String, _ value: String) -> Bool {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count
        else { return false }
        return arguments[index + 1] == value
    }
}

@Suite("Runtime selection")
struct RuntimeSelectionTests {

    private var llama: RuntimeInstallation {
        RuntimeInstallation(
            kind: .llamaCpp, executable: URL(fileURLWithPath: "/opt/homebrew/bin/llama-server"),
            version: "b1", hasExpertStreaming: true, source: .homebrew
        )
    }

    @Test func ggufGoesToLlamaCpp() throws {
        let selector = RuntimeSelector(available: [.llamaCpp: llama])
        let selection = try selector.select(model: makeModel(), configuration: LoadConfiguration())
        #expect(selection.kind == .llamaCpp)
    }

    @Test func streamingRequiresACapableBuild() {
        var configuration = LoadConfiguration()
        configuration.expertStreaming = ExpertStreamingConfiguration(slotCount: 32)

        var incapable = llama
        incapable.hasExpertStreaming = false
        let selector = RuntimeSelector(available: [.llamaCpp: incapable])

        #expect(throws: RuntimeError.self) {
            try selector.select(model: makeModel(), configuration: configuration)
        }
    }

    @Test func missingRuntimeIsReportedClearly() {
        let selector = RuntimeSelector(available: [:])
        #expect(throws: RuntimeError.self) {
            try selector.select(model: makeModel(), configuration: LoadConfiguration())
        }
    }
}

@Suite("Failure diagnosis")
struct DiagnosisTests {

    /// A user should get an instruction, not a stack trace, when a load fails.
    @Test(arguments: [
        ("ggml_metal_graph_compute: failed to allocate buffer", "context length"),
        ("error: unrecognized argument: --moe-n-slots", "expert streaming"),
        ("llama_model_load: unknown model architecture 'wibble'", "architecture"),
        ("error loading model: No such file or directory", "missing"),
    ])
    func mapsKnownFailuresToAdvice(log: String, expectedFragment: String) {
        let message = LlamaCppRuntime.diagnose(log: log)
        #expect(message.lowercased().contains(expectedFragment.lowercased()),
                "got: \(message)")
    }

    @Test func unknownFailuresFallBackToTheLogTail() {
        let message = LlamaCppRuntime.diagnose(log: "something entirely unexpected happened")
        #expect(message.contains("something entirely unexpected"))
    }
}

@Suite("Quantization inference")
struct QuantizationTests {

    @Test(arguments: [
        ("Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf", Quantization.q4_K_M),
        ("model-Q6_K.gguf", .q6_K),
        ("Llama-3.3-70B-Instruct-Q3_K_M-00001-of-00002.gguf", .q3_K_M),
        ("gpt-oss-20b-MXFP4.gguf", .mxfp4),
    ])
    func parsesQuantizationFromFilenames(filename: String, expected: Quantization) {
        #expect(Quantization.inferred(fromFilename: filename) == expected)
    }

    /// Longest-match wins, so Q4_K_M is never mistaken for a bare Q4.
    @Test func prefersTheMostSpecificMatch() {
        #expect(Quantization.inferred(fromFilename: "x-Q4_K_S.gguf") == .q4_K_S)
        #expect(Quantization.inferred(fromFilename: "x-Q5_K_M.gguf") == .q5_K_M)
    }

    @Test func returnsNilWhenThereIsNoQuantizationInTheName() {
        #expect(Quantization.inferred(fromFilename: "model.gguf") == nil)
    }
}

@Suite("Benchmark scoring")
struct BenchmarkTests {

    private func report(
        generation: Double = 50, prefill: Double = 500,
        longContext: Double = 45, ttft: Double = 0.4,
        predicted: Double = 50
    ) -> BenchmarkRunner.Report {
        BenchmarkRunner.Report(
            modelName: "Test", quantization: "Q4_K_M", contextLength: 8192, ranAt: Date(),
            shortPromptGeneration: generation, longPromptPrefill: prefill,
            longContextGeneration: longContext, timeToFirstToken: ttft,
            predictedGeneration: predicted, predictedPrefill: 500
        )
    }

    @Test func scoreRewardsFastInteractiveSetups() {
        let fast = report(generation: 90, prefill: 900, longContext: 85, ttft: 0.2)
        let slow = report(generation: 4, prefill: 40, longContext: 1.5, ttft: 6)
        #expect(fast.score > slow.score)
        #expect(fast.score >= 85)
        #expect(slow.score < 30)
    }

    @Test func scoreStaysInRange() {
        let absurd = report(generation: 9999, prefill: 99_999, longContext: 9999, ttft: 0)
        #expect(absurd.score <= 100)
        let dire = report(generation: 0.01, prefill: 0.01, longContext: 0, ttft: 60)
        #expect(dire.score >= 0)
    }

    @Test func fallOffIsMeasuredAgainstTheShortRun() {
        let halved = report(generation: 100, longContext: 50)
        #expect(abs(halved.longContextFalloff - 0.5) < 0.01)
    }

    /// A single benchmark on a busy machine must nudge the estimator, never replace it —
    /// an unclamped factor would let one bad run poison every later recommendation.
    @Test(arguments: [(1.0, 1.0), (0.5, 0.5), (5.0, 1.5), (0.01, 0.5), (1.2, 1.2)])
    func calibrationIsClamped(ratio: Double, expected: Double) {
        let measured = report(generation: 50 * ratio, predicted: 50)
        let factor = BenchmarkAnalyzer().calibration(from: measured)
        #expect(abs(factor - expected) < 0.001)
    }

    @Test func calibrationIgnoresDegenerateInput() {
        #expect(BenchmarkAnalyzer().calibration(from: report(generation: 0, predicted: 0)) == 1)
    }

    @Test func slowRunProducesAWarning() {
        let findings = BenchmarkAnalyzer().findings(
            for: report(generation: 10, predicted: 50),
            configuration: LoadConfiguration(),
            model: makeModel()
        )
        #expect(findings.contains { $0.severity == .warning })
    }

    @Test func healthyRunSaysSoInsteadOfInventingProblems() {
        let findings = BenchmarkAnalyzer().findings(
            for: report(generation: 52, longContext: 50, predicted: 50),
            configuration: LoadConfiguration(flashAttention: true),
            model: makeModel()
        )
        #expect(findings.allSatisfy { $0.severity == .good })
    }

    /// Filler must be real prose: repeated tokens compress in the KV cache and would flatter
    /// the prefill number.
    @Test func fillerIsProportionateAndVaried() {
        let short = BenchmarkRunner.filler(approximateTokens: 200)
        let long = BenchmarkRunner.filler(approximateTokens: 2000)
        #expect(long.count > short.count * 5)
        #expect(Set(short.split(separator: ".")).count > 1)
    }
}
