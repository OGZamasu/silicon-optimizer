import Foundation
import SiliconCore
import SiliconHardware

/// Predicts memory use before a model is loaded, and explains what to change when it will not fit.
///
/// The estimates below are physical rather than fudged: weights come from parameter counts and
/// the effective bit rate, the KV cache from the attention geometry, and the expert slot pool
/// from the same `3 x d_model x d_expert_ffn x n_moe_layers` product the llama.cpp paging RFC
/// uses. Where a number is empirical it is called out in a comment.
public struct MemoryPlanner: Sendable {

    public let profile: SystemProfile

    public init(profile: SystemProfile) {
        self.profile = profile
    }

    // MARK: - Weights

    /// Parameters held in a single expert slot, summed over every MoE layer.
    public static func parametersPerExpertSlot(_ shape: ModelShape) -> Int64 {
        guard let moe = shape.moe else { return 0 }
        return moe.parametersPerExpertSlot(embeddingLength: shape.embeddingLength)
    }

    /// Parameters that are not routed experts: embeddings, attention, norms, shared experts.
    public static func nonExpertParameters(_ shape: ModelShape) -> Int64 {
        guard let moe = shape.moe else { return shape.totalParameters }
        let expertTotal = parametersPerExpertSlot(shape) * Int64(moe.expertCount)
        // Clamp: catalog parameter counts are rounded, and a negative remainder would be worse
        // than a slightly optimistic one.
        return max(shape.totalParameters / 20, shape.totalParameters - expertTotal)
    }

    public static func weightBytes(_ parameters: Int64, _ quantization: Quantization) -> Bytes {
        Bytes(Int64(Double(parameters) * quantization.bitsPerWeight / 8.0))
    }

    // MARK: - KV cache

    /// Bytes of KV cache per token of context.
    ///
    /// Two tensors (K and V) per layer, each `n_kv_heads x head_dim` wide. Grouped-query
    /// attention is why modern models can afford 128K context: `head_count_kv` is often an
    /// eighth of `head_count`.
    public static func kvBytesPerToken(_ shape: ModelShape, precision: KVCachePrecision) -> Double {
        Double(2 * shape.blockCount * shape.headCountKV * shape.headDimension)
            * precision.bytesPerElement
    }

    public static func kvCacheBytes(
        _ shape: ModelShape, context: Int, precision: KVCachePrecision
    ) -> Bytes {
        Bytes(Int64(kvBytesPerToken(shape, precision: precision) * Double(context)))
    }

    // MARK: - Compute buffers

    /// Scratch memory llama.cpp allocates for graph evaluation.
    ///
    /// Two components dominate. The first scales with the micro-batch and the hidden size and is
    /// always present. The second is the attention score matrix — `ubatch x context x heads` in
    /// fp32 — which flash attention eliminates by never materialising it. On a 32K context with
    /// 32 heads and a 512 micro-batch that second term alone is over 2 GB, which is why the
    /// planner treats flash attention as close to mandatory.
    public static func computeBufferBytes(
        _ shape: ModelShape, configuration: LoadConfiguration
    ) -> Bytes {
        let ubatch = Double(max(1, configuration.microBatchSize))
        let hidden = Double(shape.embeddingLength)
        let ffn = Double(max(shape.feedForwardLength, shape.moe?.expertFeedForwardLength ?? 0))

        // Activations for the widest intermediate tensor, double-buffered, in fp16.
        var bytes = ubatch * (hidden * 4 + ffn * 2) * 2

        if !configuration.flashAttention {
            bytes += ubatch * Double(configuration.contextLength) * Double(shape.headCount) * 4
        }

        // Metal keeps a residency floor for the command buffers and the model's own descriptors.
        return Bytes(Int64(max(bytes, 192 * 1_048_576)))
    }

    // MARK: - Planning

    public func plan(
        shape: ModelShape,
        quantization: Quantization,
        configuration: LoadConfiguration,
        otherAppsInUse: Bytes = .zero
    ) -> MemoryPlan {
        let nonExpertParams = Self.nonExpertParameters(shape)
        let nonExpertWeights = Self.weightBytes(nonExpertParams, quantization)

        var expertWeights = Bytes.zero
        var streamed = Bytes.zero
        var notes: [String] = []

        if let moe = shape.moe {
            let perSlot = Self.weightBytes(Self.parametersPerExpertSlot(shape), quantization)
            let fullResidency = perSlot * Double(moe.expertCount)

            if let streaming = configuration.expertStreaming {
                let slots = min(streaming.slotCount, moe.expertCount)
                expertWeights = perSlot * Double(slots)
                streamed = fullResidency - expertWeights
                notes.append(
                    "Expert streaming keeps \(slots) of \(moe.expertCount) experts resident "
                    + "(\(perSlot.formatted) each) and pages the rest from disk."
                )
                let maxUBatch = ExpertStreamingConfiguration.maximumMicroBatch(
                    slotCount: slots, expertsUsedPerToken: moe.expertsUsedPerToken
                )
                if configuration.microBatchSize > maxUBatch {
                    notes.append(
                        "Micro-batch must drop to \(maxUBatch) to satisfy "
                        + "ubatch x experts_used <= slots. Prompt processing will be much slower."
                    )
                }
            } else {
                expertWeights = fullResidency
            }
        }

        let kvCache = Self.kvCacheBytes(
            shape, context: configuration.contextLength, precision: configuration.kvCachePrecision
        )
        let compute = Self.computeBufferBytes(shape, configuration: configuration)

        // `otherAppsInUse` is other processes' *wired* memory — the part macOS genuinely cannot
        // take back. Ordinary application memory is compressible and evictable, and the kernel
        // will page it out to make room for the model, so subtracting all in-use memory would
        // collapse the budget to nothing on any busy machine and make every plan meaningless.
        //
        // A share of wired memory belongs to macOS itself and is already priced into
        // `safeModelBudget`, so only the excess above that is charged again here.
        let systemWiredAllowance = profile.totalMemory * 0.10
        let unavoidable = Bytes(max(0, otherAppsInUse.rawValue - systemWiredAllowance.rawValue))
        // Never let the budget fall so far that nothing is loadable; at that point the honest
        // answer is a "close some apps" remediation, not a zero-sized budget.
        let budget = Bytes(max(
            (profile.safeModelBudget * 0.35).rawValue,
            profile.safeModelBudget.rawValue - unavoidable.rawValue
        ))

        var plan = MemoryPlan(
            nonExpertWeights: nonExpertWeights,
            expertWeights: expertWeights,
            kvCache: kvCache,
            computeBuffers: compute,
            streamedFromDisk: streamed,
            budget: budget,
            otherAppsInUse: otherAppsInUse,
            verdict: .comfortable,
            remediations: [],
            notes: notes
        )

        plan.verdict = verdict(for: plan)
        plan.remediations = remediations(
            for: plan, shape: shape, quantization: quantization, configuration: configuration
        )
        return plan
    }

    private func verdict(for plan: MemoryPlan) -> MemoryPlan.Verdict {
        // A zero or negative budget must never read as "no pressure". `Bytes.fraction(of:)`
        // returns 0 for a zero denominator, which would otherwise score as perfectly comfortable.
        guard plan.budget > .zero else { return .impossible }
        let utilization = plan.utilization
        // Above the safe budget the Metal driver starts spilling to compressed memory and then
        // to swap; generation speed collapses long before allocation actually fails.
        if plan.resident > profile.totalMemory { return .impossible }
        return switch utilization {
        case ..<0.80: .comfortable
        case ..<1.00: .tight
        default: .willSwap
        }
    }

    // MARK: - Remediations

    private func remediations(
        for plan: MemoryPlan,
        shape: ModelShape,
        quantization: Quantization,
        configuration: LoadConfiguration
    ) -> [MemoryPlan.Remediation] {
        guard plan.verdict != .comfortable else { return [] }
        var results: [MemoryPlan.Remediation] = []
        let overBy = plan.resident - plan.budget

        // Flash attention first: it is free.
        if !configuration.flashAttention {
            var withFA = configuration
            withFA.flashAttention = true
            let saving = plan.computeBuffers - Self.computeBufferBytes(shape, configuration: withFA)
            if saving > .mib(64) {
                results.append(.init(
                    title: "Turn on Flash Attention",
                    detail: "Computes attention without materialising the full score matrix.",
                    saving: saving,
                    cost: "None. It is also faster.",
                    kind: .enableFlashAttention
                ))
            }
        }

        // KV cache quantization: nearly free at Q8_0.
        if configuration.kvCachePrecision == .f16, plan.kvCache > .mib(512) {
            let saving = plan.kvCache - Self.kvCacheBytes(
                shape, context: configuration.contextLength, precision: .q8_0
            )
            results.append(.init(
                title: "Store the KV cache at Q8_0",
                detail: "Halves cache memory for the same context length.",
                saving: saving,
                cost: "No measurable quality difference in practice.",
                kind: .quantizeKVCache
            ))
        }

        // Context reduction, sized to actually close the gap.
        if configuration.contextLength > 4096, plan.kvCache > .mib(256) {
            let perToken = Self.kvBytesPerToken(shape, precision: configuration.kvCachePrecision)
            let tokensToDrop = Double(overBy.rawValue) / max(perToken, 1)
            let target = max(4096, roundToPowerOfTwo(configuration.contextLength - Int(tokensToDrop)))
            if target < configuration.contextLength {
                let saving = Self.kvCacheBytes(
                    shape, context: configuration.contextLength - target,
                    precision: configuration.kvCachePrecision
                )
                results.append(.init(
                    title: "Reduce context to \(formatContext(target))",
                    detail: "The KV cache costs \(Bytes(Int64(perToken)).formatted) per token.",
                    saving: saving,
                    cost: "Shorter conversations and documents before earlier turns are dropped.",
                    kind: .reduceContext
                ))
            }
        }

        // Expert streaming — only for MoE models, and only when storage can keep up.
        if let moe = shape.moe, configuration.expertStreaming == nil {
            let perSlot = Self.weightBytes(Self.parametersPerExpertSlot(shape), quantization)
            // Pick the largest pool that fits the budget, leaving the rest of the plan intact.
            let available = plan.budget - plan.nonExpertWeights - plan.kvCache - plan.computeBuffers
            let affordable = perSlot.rawValue > 0
                ? Int(available.rawValue / perSlot.rawValue) : 0
            let slots = max(8, min(moe.expertCount - 1, affordable))
            // Ordered with the comparison last: `a < b, c > .zero` parses as a generic argument
            // list and fails to compile.
            if available > .zero, slots < moe.expertCount {
                let saving = perSlot * Double(moe.expertCount - slots)
                let maxUBatch = ExpertStreamingConfiguration.maximumMicroBatch(
                    slotCount: slots, expertsUsedPerToken: moe.expertsUsedPerToken
                )
                let storageNote = (profile.ssdReadMBps ?? 0) > 0 && (profile.ssdReadMBps ?? 0) < 1500
                    ? " Your volume measured \(Int(profile.ssdReadMBps ?? 0)) MB/s, which is slow for this."
                    : ""
                results.append(.init(
                    title: "Stream experts from disk (\(slots) of \(moe.expertCount) resident)",
                    detail: "Keeps a \(slots)-slot LRU pool in memory and pages the rest from the "
                        + "GGUF on demand. Output is identical — only residency changes."
                        + storageNote,
                    saving: saving,
                    cost: "Prompt processing drops sharply: the micro-batch must fall to "
                        + "\(maxUBatch) tokens. Generation slows modestly.",
                    kind: .enableExpertStreaming
                ))
            }
        }

        // Lower quantization, as the last structural lever.
        let lowerOptions = Quantization.byQualityDescending.filter {
            $0.bitsPerWeight < quantization.bitsPerWeight && !$0.isMLX && $0 != .mxfp4
        }
        if let candidate = lowerOptions.first(where: { lower in
            let ratio = lower.bitsPerWeight / quantization.bitsPerWeight
            let newWeights = (plan.nonExpertWeights + plan.expertWeights) * ratio
            return newWeights + plan.kvCache + plan.computeBuffers <= plan.budget
        }) {
            let ratio = candidate.bitsPerWeight / quantization.bitsPerWeight
            let saving = (plan.nonExpertWeights + plan.expertWeights) * (1 - ratio)
            results.append(.init(
                title: "Use \(candidate.rawValue) instead of \(quantization.rawValue)",
                detail: candidate.summary,
                saving: saving,
                cost: String(
                    format: "About %.1f%% more perplexity than %@.",
                    candidate.qualityLossPercent - quantization.qualityLossPercent,
                    quantization.rawValue
                ),
                kind: .lowerQuantization
            ))
        }

        // If even the smallest quantization cannot fit, say so outright rather than leaving the
        // user to work down the list discovering that none of it helps.
        if !results.contains(where: { $0.kind == .lowerQuantization }),
           let smallest = lowerOptions.last {
            let ratio = smallest.bitsPerWeight / quantization.bitsPerWeight
            let floorWeights = (plan.nonExpertWeights + plan.expertWeights) * ratio
            if floorWeights + plan.kvCache + plan.computeBuffers > plan.budget {
                results.append(.init(
                    title: "This model is too large for this Mac",
                    detail: "Even at \(smallest.rawValue) the weights alone would need "
                        + "\(floorWeights.formatted), against a \(plan.budget.formatted) budget. "
                        + "Choose a smaller model.",
                    saving: .zero,
                    cost: "None — this is the honest answer.",
                    kind: .lowerQuantization
                ))
            }
        }

        // Only worth suggesting when other processes have actually eaten into the budget.
        let reclaimable = profile.safeModelBudget - plan.budget
        if reclaimable > .gib(2) {
            results.append(.init(
                title: "Quit memory-heavy apps",
                detail: "Other applications have \(plan.otherAppsInUse.formatted) of memory wired "
                    + "down, which cannot be compressed or swapped out for the model.",
                saving: reclaimable,
                cost: "You lose whatever those apps were doing.",
                kind: .closeApps
            ))
        }

        // Largest saving first — that is the order a user wants to act in.
        return results.sorted { $0.saving > $1.saving }
    }

    private func roundToPowerOfTwo(_ value: Int) -> Int {
        guard value > 0 else { return 4096 }
        var result = 4096
        while result * 2 <= value { result *= 2 }
        return result
    }

    private func formatContext(_ tokens: Int) -> String {
        tokens >= 1024 ? "\(tokens / 1024)K" : "\(tokens)"
    }
}
