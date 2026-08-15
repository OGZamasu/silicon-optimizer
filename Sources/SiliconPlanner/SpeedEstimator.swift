import Foundation
import SiliconCore
import SiliconHardware

/// Predicts throughput from first principles rather than from a lookup table.
///
/// Generation is memory-bandwidth bound: every token reads the active weights once, so
/// `tok/s ≈ bandwidth / bytes-per-token`. Prompt processing is compute bound, so it scales with
/// GPU FLOPS instead. Both carry an efficiency factor calibrated against measured llama.cpp
/// Metal results — the theoretical peaks are never reached in practice.
public struct SpeedEstimator: Sendable {

    /// Fraction of peak memory bandwidth llama.cpp's Metal backend sustains during decode.
    /// Measured llama.cpp numbers on M-series parts cluster around 55–65% of the published peak.
    ///
    /// One constant for both architectures is known to be wrong, and the direction of the error
    /// flips. Measured on a 24 GB M5 Pro, llama.cpp b10310, matched 8K context (#1):
    ///   Qwen3 8B Q4_K_M (dense)   — 55.0 tok/s measured against 46.5 predicted, 1.18x
    ///   gpt-oss-20b MXFP4 (MoE)   — 89.3 tok/s measured against 103.7 predicted, 0.86x
    /// The implied dense/MoE ratio of 1.37 is almost exactly the 1.36 already sitting between
    /// `denseComputeEfficiency` and `moeComputeEfficiency` below — the same architectural effect,
    /// modelled for prefill and unmodelled for decode.
    ///
    /// Splitting this by architecture is the fix. It is not done here because two points on one
    /// machine cannot set two constants, and guessing the split would replace a known-uniform
    /// error with an unknown-shaped one. Until then the per-model benchmark calibration absorbs it.
    static let bandwidthEfficiency = 0.60

    /// Fraction of peak GPU throughput reached while ingesting a prompt.
    ///
    /// Dense and mixture-of-experts models are separated because they genuinely differ: a dense
    /// layer is one large GEMM that saturates the GPU, whereas an MoE layer routes tokens to
    /// experts, turning that into a gather, many smaller per-expert matmuls, and a scatter. The
    /// smaller matmuls do not reach the same utilization.
    ///
    /// Calibrated on an M3 Max (30 GPU cores) against measured llama.cpp b10280:
    ///   Qwen3-1.7B dense      — 2374 tok/s measured, 2344 predicted at 0.75
    ///   Qwen3-Coder-30B-A3B   —  895 tok/s measured,  896 predicted at 0.55
    /// A single 0.30 constant under-predicted both by roughly half. Residual per-machine error
    /// is handled by the benchmark's calibration factor rather than by tuning these further.
    static let denseComputeEfficiency = 0.75
    static let moeComputeEfficiency = 0.55

    public let profile: SystemProfile

    /// Multiplier learned from a benchmark on this machine. The physical model gets within
    /// roughly 10%; measuring once closes the rest, and every later recommendation is then
    /// grounded in this Mac rather than in a published bandwidth figure.
    public let calibration: Double

    public init(profile: SystemProfile, calibration: Double = 1.0) {
        self.profile = profile
        self.calibration = calibration
    }

    /// Peak fp16 throughput in FLOP/s. Apple GPU cores carry 128 ALUs and clock near 1.4 GHz.
    var peakFLOPS: Double {
        Double(profile.gpuCores) * 128 * 2 * 1.4e9
    }

    public func estimate(
        shape: ModelShape,
        quantization: Quantization,
        configuration: LoadConfiguration,
        plan: MemoryPlan
    ) -> SpeedEstimate {
        // Bytes touched per generated token.
        var bytesPerToken = Double(plan.nonExpertWeights.rawValue)
        if let moe = shape.moe {
            let expertFraction = Double(moe.expertsUsedPerToken) / Double(moe.expertCount)
            let allExperts = Double((plan.expertWeights + plan.streamedFromDisk).rawValue)
            bytesPerToken += allExperts * expertFraction
        }
        bytesPerToken = builtinMax(bytesPerToken, 1)

        var generation = profile.memoryBandwidthGBps * 1e9 * Self.bandwidthEfficiency / bytesPerToken

        var streamingBound = false
        if configuration.expertStreaming != nil, let moe = shape.moe {
            streamingBound = true
            // Experts missing from the pool must come off the SSD. With an LRU pool of `slots`
            // out of `expertCount`, the steady-state miss rate is roughly the fraction of
            // experts not resident, weighted by how many are consulted per token.
            let slots = Double(min(configuration.expertStreaming?.slotCount ?? 0, moe.expertCount))
            let missRate = builtinMax(0, 1 - slots / Double(moe.expertCount))
            let perSlotBytes = Double(
                MemoryPlanner.weightBytes(
                    MemoryPlanner.parametersPerExpertSlot(shape), quantization
                ).rawValue
            ) / Double(shape.blockCount)     // one layer's worth of a single expert
            let bytesFromDisk = perSlotBytes
                * Double(moe.expertsUsedPerToken * shape.blockCount) * missRate

            let readBytesPerSecond = (profile.ssdReadMBps ?? 3000) * 1_048_576
            if bytesFromDisk > 0 {
                let diskLimited = readBytesPerSecond / bytesFromDisk
                generation = builtinMin(generation, diskLimited)
            }
        }

        // Prompt processing: two FLOPs per active parameter per token.
        // Derived when the catalog did not supply it, which is always the case for an
        // imported GGUF.
        let activeParameters = Double(shape.effectiveActiveParameters)
        let efficiency = shape.isMoE ? Self.moeComputeEfficiency : Self.denseComputeEfficiency
        var prefill = peakFLOPS * efficiency / builtinMax(2 * activeParameters, 1)

        // A small micro-batch cannot saturate the GPU. Expert streaming forces exactly that,
        // which is the main reason it is not free.
        let ubatch = Double(configuration.microBatchSize)
        if ubatch < 512 {
            prefill *= builtinMax(0.08, ubatch / 512)
        }

        return SpeedEstimate(
            generationTokensPerSecond: builtinMax(0.1, generation * calibration),
            prefillTokensPerSecond: builtinMax(1, prefill * calibration),
            isStreamingBound: streamingBound
        )
    }

    // `Swift.max`/`Swift.min` are shadowed inside this file by nothing, but naming them
    // explicitly keeps the intent obvious next to the many `Bytes` operators in scope.
    private func builtinMax(_ a: Double, _ b: Double) -> Double { Swift.max(a, b) }
    private func builtinMin(_ a: Double, _ b: Double) -> Double { Swift.min(a, b) }
}
