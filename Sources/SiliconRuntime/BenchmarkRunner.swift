import Foundation
import SiliconCatalog
import SiliconCore
import SiliconPlanner

/// Measures what a loaded model actually does, as opposed to what the planner predicted.
///
/// The estimator works from bandwidth and FLOPs. Across architectures that lands anywhere from
/// 45% low to spot on — good enough to choose a model, not good enough to tune one. Running a
/// handful of real generations closes the gap for the model measured.
///
/// The correction is stored per model, not per machine. Measured on an M3 Max, a dense 7B ran
/// 45% above the physical estimate while a 30B mixture-of-experts matched it exactly; applying
/// one global factor would have taken an exact prediction and made it wrong by the same 45%.
public actor BenchmarkRunner {

    public struct Report: Sendable, Codable, Equatable {
        public var modelName: String
        public var quantization: String
        public var contextLength: Int
        public var ranAt: Date

        public var shortPromptGeneration: Double     // tok/s from a near-empty prompt
        public var longPromptPrefill: Double         // tok/s ingesting a large prompt
        public var longContextGeneration: Double     // tok/s with the cache well filled
        public var timeToFirstToken: TimeInterval

        /// What the planner predicted before the run, for comparison.
        public var predictedGeneration: Double
        public var predictedPrefill: Double

        /// Measured / predicted. Below 1 means the estimator was optimistic.
        public var generationAccuracy: Double {
            predictedGeneration > 0 ? shortPromptGeneration / predictedGeneration : 1
        }

        /// How much throughput is lost once the KV cache is full. Attention is quadratic in
        /// context, so some falloff is expected; a lot of it means the cache is thrashing.
        public var longContextFalloff: Double {
            shortPromptGeneration > 0
                ? 1 - (longContextGeneration / shortPromptGeneration) : 0
        }

        /// One-line verdict, 0–100, weighted toward interactive feel.
        public var score: Int {
            let speed = min(shortPromptGeneration / 60, 1.0) * 45
            let prefill = min(longPromptPrefill / 600, 1.0) * 25
            let latency = max(0, 1 - timeToFirstToken / 3.0) * 15
            let stability = max(0, 1 - longContextFalloff * 2) * 15
            return Int((speed + prefill + latency + stability).rounded())
        }

        public var grade: String {
            switch score {
            case 85...: "Excellent"
            case 70..<85: "Good"
            case 50..<70: "Usable"
            case 30..<50: "Slow"
            default: "Painful"
            }
        }
    }

    public struct Finding: Sendable, Equatable, Identifiable {
        public var id: String { title }
        public var title: String
        public var detail: String
        public var severity: Severity

        public enum Severity: String, Sendable, Equatable {
            case good, advice, warning
        }
    }

    public enum Phase: Sendable, Equatable {
        case warmup, shortGeneration, prefill, longContext, done

        public var label: String {
            switch self {
            case .warmup: "Warming up…"
            case .shortGeneration: "Measuring generation speed…"
            case .prefill: "Measuring prompt processing…"
            case .longContext: "Measuring long-context behaviour…"
            case .done: "Done"
            }
        }
    }

    private let runtime: any InferenceRuntime

    public init(runtime: any InferenceRuntime) {
        self.runtime = runtime
    }

    /// Runs the suite. `onPhase` reports progress so the UI is not a blank spinner.
    public func run(
        model: InstalledModel,
        configuration: LoadConfiguration,
        predicted: SpeedEstimate,
        onPhase: @Sendable @escaping (Phase) -> Void
    ) async throws -> Report {
        // The first generation after a load pays for Metal pipeline compilation, so it is
        // discarded rather than measured.
        onPhase(.warmup)
        _ = try await measure(prompt: "Hi.", maxTokens: 16)

        onPhase(.shortGeneration)
        let short = try await measure(
            prompt: "Write a haiku about the sea.", maxTokens: 128
        )

        onPhase(.prefill)
        // A prompt long enough that ingestion dominates, but short enough to fit any context.
        let longPrompt = Self.filler(approximateTokens: 2000)
        let prefill = try await measure(
            prompt: longPrompt + "\n\nSummarise the above in one sentence.", maxTokens: 48
        )

        onPhase(.longContext)
        // Fill a meaningful fraction of the window so the cache is genuinely deep.
        let deepTokens = max(2000, min(configuration.contextLength / 2, 12_000))
        let deep = try await measure(
            prompt: Self.filler(approximateTokens: deepTokens)
                + "\n\nReply with one short sentence about the text above.",
            maxTokens: 96
        )

        onPhase(.done)
        return Report(
            modelName: model.name,
            quantization: model.quantization.rawValue,
            contextLength: configuration.contextLength,
            ranAt: Date(),
            shortPromptGeneration: short.generationTokensPerSecond,
            longPromptPrefill: max(prefill.prefillTokensPerSecond, short.prefillTokensPerSecond),
            longContextGeneration: deep.generationTokensPerSecond,
            timeToFirstToken: short.timeToFirstToken,
            predictedGeneration: predicted.generationTokensPerSecond,
            predictedPrefill: predicted.prefillTokensPerSecond
        )
    }

    private func measure(prompt: String, maxTokens: Int) async throws -> GenerationMetrics {
        var metrics = GenerationMetrics()
        let request = ChatRequest(
            messages: [ChatMessage(role: .user, content: prompt)],
            // Deterministic, so a re-run is comparable.
            temperature: 0, topP: 1, maxTokens: maxTokens,
            // Reasoning models would otherwise spend the whole budget thinking and report
            // throughput for tokens the user never sees.
            reasoningEffort: "low"
        )
        for try await event in try await runtime.chat(request) {
            if case .finished(let final) = event { metrics = final }
        }
        return metrics
    }

    /// Deterministic filler text of roughly the requested token count. Natural prose is used
    /// rather than repeated tokens because a degenerate prompt compresses in the KV cache and
    /// would flatter the result.
    static func filler(approximateTokens: Int) -> String {
        let sentences = [
            "The unified memory architecture allows the processor and graphics units to address the same physical pages without copying.",
            "Quantization reduces the precision of stored weights, trading a small amount of accuracy for a large reduction in bandwidth.",
            "Mixture-of-experts layers route each token to a small subset of specialists, so only a fraction of the parameters activate.",
            "Attention cost grows with the square of sequence length, which is why long contexts are expensive to process but cheap to extend.",
            "Metal command buffers are scheduled asynchronously, and the encoder waits on shared events before dependent work begins.",
        ]
        // Roughly 20 tokens per sentence for English prose.
        let needed = max(1, approximateTokens / 20)
        return (0..<needed)
            .map { sentences[$0 % sentences.count] }
            .joined(separator: " ")
    }
}

/// Turns a report into concrete advice, and into a calibration factor for future predictions.
public struct BenchmarkAnalyzer: Sendable {

    public init() {}

    public func findings(
        for report: BenchmarkRunner.Report,
        configuration: LoadConfiguration,
        model: InstalledModel
    ) -> [BenchmarkRunner.Finding] {
        var findings: [BenchmarkRunner.Finding] = []

        // Estimator accuracy.
        let accuracy = report.generationAccuracy
        if accuracy < 0.7 {
            findings.append(.init(
                title: "Slower than predicted",
                detail: String(
                    format: "Measured %.0f tok/s against a predicted %.0f. Something is holding "
                        + "this back — check that no other application is using the GPU, and "
                        + "that memory pressure is normal. Estimates for this model have been "
                        + "recalibrated downward.",
                    report.shortPromptGeneration, report.predictedGeneration
                ),
                severity: .warning
            ))
        } else if accuracy > 1.15 {
            findings.append(.init(
                title: "Faster than predicted",
                detail: String(
                    format: "Measured %.0f tok/s against a predicted %.0f. Estimates for "
                        + "this model have been recalibrated upward; other models are "
                        + "unaffected.",
                    report.shortPromptGeneration, report.predictedGeneration
                ),
                severity: .good
            ))
        }

        // Long-context behaviour.
        if report.longContextFalloff > 0.4 {
            findings.append(.init(
                title: "Large slowdown at depth",
                detail: String(
                    format: "Throughput fell %.0f%% with the cache filled. Quantizing the KV "
                        + "cache to Q8_0 reduces the bandwidth it consumes per token.",
                    report.longContextFalloff * 100
                ),
                severity: .advice
            ))
        } else if report.longContextFalloff < 0.15 {
            findings.append(.init(
                title: "Holds up at long context",
                detail: "Throughput barely changed with a deep cache.",
                severity: .good
            ))
        }

        // Flash attention is the single biggest avoidable cost.
        if !configuration.flashAttention {
            findings.append(.init(
                title: "Flash Attention is off",
                detail: "Turning it on lowers memory use and usually raises prompt throughput. "
                    + "There is no quality cost.",
                severity: .advice
            ))
        }

        // Prompt processing.
        if report.longPromptPrefill < 100 {
            let cause = configuration.expertStreaming != nil
                ? "Expert streaming caps the micro-batch, which is the usual cause."
                : "Raising the micro-batch size may help if memory allows."
            findings.append(.init(
                title: "Slow prompt processing",
                detail: String(
                    format: "%.0f tok/s ingesting a long prompt. %@",
                    report.longPromptPrefill, cause
                ),
                severity: .warning
            ))
        }

        // Interactivity.
        if report.timeToFirstToken > 2.0 {
            findings.append(.init(
                title: "Noticeable first-token delay",
                detail: String(
                    format: "%.1fs before the first token. A smaller context or a smaller model "
                        + "would feel more responsive.",
                    report.timeToFirstToken
                ),
                severity: .advice
            ))
        }

        if findings.isEmpty || findings.allSatisfy({ $0.severity == .good }) {
            findings.insert(.init(
                title: "Well configured",
                detail: "Nothing worth changing — this setup is performing as it should.",
                severity: .good
            ), at: 0)
        }
        return findings
    }

    /// A multiplier to apply to future speed predictions on this machine.
    ///
    /// Clamped hard: a single benchmark on a busy machine should nudge the model, not replace
    /// it, and an unclamped factor would let one bad run poison every recommendation.
    public func calibration(from report: BenchmarkRunner.Report) -> Double {
        guard report.predictedGeneration > 0, report.shortPromptGeneration > 0 else { return 1 }
        return (report.shortPromptGeneration / report.predictedGeneration)
            .clamped(to: 0.5...1.5)
    }
}
