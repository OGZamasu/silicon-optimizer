import Foundation
import SiliconCatalog
import SiliconCore
import SiliconHardware

/// Picks the best model and settings for this machine — the one button the whole app is built
/// around.
///
/// The rule is: take the highest-rated model whose best affordable quantization still leaves a
/// comfortable memory margin and generates fast enough to feel interactive.
public struct AutoConfigurator: Sendable {

    public struct Recommendation: Sendable, Identifiable {
        public var entry: ModelEntry
        public var quantization: Quantization
        public var configuration: LoadConfiguration
        public var plan: MemoryPlan
        public var speed: SpeedEstimate
        public var score: Double
        public var rationale: String

        public var id: String { "\(entry.id)@\(quantization.rawValue)" }
    }

    /// Below this, generation feels like waiting rather than reading.
    static let interactiveFloor = 8.0

    public let profile: SystemProfile
    private let planner: MemoryPlanner

    /// Per-model speed corrections from previous benchmarks, keyed by catalog id. Models that
    /// have never been benchmarked fall back to the uncalibrated physical estimate.
    private let calibrations: [String: Double]

    public init(profile: SystemProfile, calibrations: [String: Double] = [:]) {
        self.profile = profile
        self.planner = MemoryPlanner(profile: profile)
        self.calibrations = calibrations
    }

    private func estimator(for entry: ModelEntry) -> SpeedEstimator {
        SpeedEstimator(profile: profile, calibration: calibrations[entry.id] ?? 1.0)
    }

    /// Ranks every catalog entry for this machine, best first.
    public func rank(
        catalog: [ModelEntry] = ModelCatalog.all,
        otherAppsInUse: Bytes = .zero,
        category: ModelCategory? = nil
    ) -> [Recommendation] {
        catalog
            .filter { category == nil || $0.category == category }
            .compactMap { best(for: $0, otherAppsInUse: otherAppsInUse) }
            .sorted { $0.score > $1.score }
    }

    /// The single best thing to install right now.
    public func topPick(
        catalog: [ModelEntry] = ModelCatalog.all,
        otherAppsInUse: Bytes = .zero
    ) -> Recommendation? {
        // Embedding models are infrastructure, not something to hand someone as their first chat
        // model, so they never win the top slot.
        rank(catalog: catalog.filter { $0.category != .embedding }, otherAppsInUse: otherAppsInUse)
            .first
    }

    /// The best configuration for one specific model, or nil if nothing usable fits.
    public func best(for entry: ModelEntry, otherAppsInUse: Bytes = .zero) -> Recommendation? {
        var candidates: [Recommendation] = []

        for variant in entry.variants {
            let quantization = variant.quantization
            guard let tuned = tune(
                entry: entry, quantization: quantization, otherAppsInUse: otherAppsInUse
            ) else { continue }
            candidates.append(tuned)
        }

        return candidates.max { $0.score < $1.score }
    }

    // MARK: - Tuning a single (model, quantization) pair

    private func tune(
        entry: ModelEntry, quantization: Quantization, otherAppsInUse: Bytes
    ) -> Recommendation? {
        let shape = entry.shape

        // Start ambitious and walk down: full context, f16 cache, no streaming.
        let contextLadder = contextOptions(for: entry)
        let cacheLadder: [KVCachePrecision] = [.f16, .q8_0]

        for cache in cacheLadder {
            for context in contextLadder {
                var configuration = LoadConfiguration(
                    contextLength: context,
                    batchSize: 2048,
                    microBatchSize: 512,
                    kvCachePrecision: cache,
                    flashAttention: true,
                    gpuLayerFraction: 1.0,
                    threads: profile.performanceCores
                )
                let plan = planner.plan(
                    shape: shape, quantization: quantization,
                    configuration: configuration, otherAppsInUse: otherAppsInUse
                )
                guard plan.verdict == .comfortable else { continue }

                let speed = estimator(for: entry).estimate(
                    shape: shape, quantization: quantization,
                    configuration: configuration, plan: plan
                )
                guard speed.generationTokensPerSecond >= Self.interactiveFloor else { continue }

                configuration.threads = profile.performanceCores
                return Recommendation(
                    entry: entry, quantization: quantization, configuration: configuration,
                    plan: plan, speed: speed,
                    score: score(
                        entry: entry, quantization: quantization,
                        configuration: configuration, plan: plan, speed: speed
                    ),
                    rationale: rationale(
                        entry: entry, quantization: quantization,
                        configuration: configuration, plan: plan, speed: speed
                    )
                )
            }
        }

        // Nothing fit resident. For MoE models, expert streaming is the remaining option —
        // this is what lets a 128 GB-class model run on a 36 GB machine.
        if let moe = shape.moe, (profile.ssdReadMBps ?? 3000) >= 1500 {
            return tuneWithStreaming(
                entry: entry, quantization: quantization, moe: moe, otherAppsInUse: otherAppsInUse
            )
        }
        return nil
    }

    private func tuneWithStreaming(
        entry: ModelEntry, quantization: Quantization, moe: MoEShape, otherAppsInUse: Bytes
    ) -> Recommendation? {
        let shape = entry.shape
        let perSlot = MemoryPlanner.weightBytes(
            MemoryPlanner.parametersPerExpertSlot(shape), quantization
        )
        guard perSlot > .zero else { return nil }

        for context in contextOptions(for: entry) {
            // Size the pool from what is left after the fixed costs.
            var probe = LoadConfiguration(
                contextLength: context, kvCachePrecision: .q8_0, flashAttention: true,
                expertStreaming: ExpertStreamingConfiguration(slotCount: moe.expertCount),
                threads: profile.performanceCores
            )
            let fixed = planner.plan(
                shape: shape, quantization: quantization,
                configuration: LoadConfiguration(
                    contextLength: context, kvCachePrecision: .q8_0, flashAttention: true,
                    expertStreaming: ExpertStreamingConfiguration(slotCount: 0)
                ),
                otherAppsInUse: otherAppsInUse
            )
            let available = fixed.budget - fixed.resident
            guard available > perSlot else { continue }

            let slots = min(moe.expertCount - 1, Int(available.rawValue / perSlot.rawValue))
            guard slots >= 8 else { continue }

            probe.expertStreaming = ExpertStreamingConfiguration(slotCount: slots)
            probe.microBatchSize = ExpertStreamingConfiguration.maximumMicroBatch(
                slotCount: slots, expertsUsedPerToken: moe.expertsUsedPerToken
            )
            probe.batchSize = max(probe.microBatchSize, 256)

            let plan = planner.plan(
                shape: shape, quantization: quantization,
                configuration: probe, otherAppsInUse: otherAppsInUse
            )
            guard plan.verdict.isUsable else { continue }

            let speed = estimator(for: entry).estimate(
                shape: shape, quantization: quantization, configuration: probe, plan: plan
            )
            guard speed.generationTokensPerSecond >= Self.interactiveFloor else { continue }

            return Recommendation(
                entry: entry, quantization: quantization, configuration: probe,
                plan: plan, speed: speed,
                // Streaming is a real compromise, so it should never outrank a model that fits
                // outright. The penalty keeps it as a fallback rather than a default.
                score: score(
                    entry: entry, quantization: quantization,
                    configuration: probe, plan: plan, speed: speed
                ) * 0.55,
                rationale: rationale(
                    entry: entry, quantization: quantization,
                    configuration: probe, plan: plan, speed: speed
                )
            )
        }
        return nil
    }

    // MARK: - Scoring

    private func score(
        entry: ModelEntry, quantization: Quantization,
        configuration: LoadConfiguration, plan: MemoryPlan, speed: SpeedEstimate
    ) -> Double {
        // Capability is the dominant term — a better model is worth waiting a little longer for.
        let capability = log2(Double(entry.shape.totalParameters) / 1e9 + 1) * 10
        let editorial = Double(entry.rating) * 6
        let fidelity = (10 - quantization.qualityLossPercent).clamped(to: 0...10)

        // Context is worth far more than the last percent of quantization fidelity. Without
        // this term the search happily trades 16K of context for the ~1% perplexity difference
        // between Q4_K_M and Q5_K_M, and hands back a 4K-context coding model — technically the
        // highest-fidelity option that fits, and useless for real work.
        let contextRatio = Double(configuration.contextLength) / 4096
        let contextTerm = min(log2(contextRatio + 1), 5) * 4

        // Speed matters up to the point of being comfortably interactive, then stops mattering.
        let speedTerm = min(speed.generationTokensPerSecond, 40) * 0.5

        // Leaving the machine usable is worth something.
        let headroomTerm = (1 - plan.utilization).clamped(to: 0...1) * 8

        return capability + editorial + fidelity + contextTerm + speedTerm + headroomTerm
    }

    private func contextOptions(for entry: ModelEntry) -> [Int] {
        let ceiling = min(entry.maxContext, 131_072)
        return [131_072, 65_536, 32_768, 16_384, 8192, 4096].filter { $0 <= ceiling }
    }

    private func rationale(
        entry: ModelEntry, quantization: Quantization,
        configuration: LoadConfiguration, plan: MemoryPlan, speed: SpeedEstimate
    ) -> String {
        var parts: [String] = []
        parts.append(
            "\(quantization.rawValue) at \(formatContext(configuration.contextLength)) context "
            + "uses \(plan.resident.formatted) of your \(plan.budget.formatted) budget"
        )
        if let moe = entry.shape.moe {
            if let streaming = configuration.expertStreaming {
                parts.append(
                    "with \(streaming.slotCount) of \(moe.expertCount) experts resident and the "
                    + "rest streamed from disk"
                )
            } else {
                parts.append(String(
                    format: "and generates at the speed of a %.1fB model",
                    Double(moe.activeParameters) / 1e9
                ))
            }
        }
        parts.append(String(format: "≈%.0f tok/s", speed.generationTokensPerSecond))
        return parts.joined(separator: ", ") + "."
    }

    private func formatContext(_ tokens: Int) -> String {
        tokens >= 1024 ? "\(tokens / 1024)K" : "\(tokens)"
    }
}


