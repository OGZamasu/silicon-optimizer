import Foundation

/// The architectural dimensions the memory planner needs. These come from GGUF metadata when a
/// model is on disk, and from the curated catalog before it is downloaded.
public struct ModelShape: Hashable, Sendable, Codable {
    /// Generous schema ceilings for model-supplied dimensions. They are deliberately far above
    /// current architectures, but keep later byte arithmetic inside a range the planner can
    /// represent safely.
    public static let maximumParameterCount: Int64 = 10_000_000_000_000
    public static let maximumBlockCount = 4_096
    public static let maximumEmbeddingLength = 1_048_576
    public static let maximumFeedForwardLength = 4_194_304
    public static let maximumHeadCount = 65_536
    public static let maximumHeadDimension = 65_536
    public static let maximumContextLength = 16_777_216
    public static let maximumVocabularySize = 16_777_216
    public static let maximumExpertCount = 65_536

    public var totalParameters: Int64
    public var blockCount: Int
    public var embeddingLength: Int          // d_model
    public var feedForwardLength: Int        // dense FFN intermediate size
    public var headCount: Int
    public var headCountKV: Int              // < headCount means grouped-query attention
    public var trainingContextLength: Int
    public var vocabSize: Int

    /// Width of a single attention head.
    ///
    /// This is *not* reliably `embedding_length / head_count`. Qwen3 keeps a 128-wide head on a
    /// 2048-wide residual stream, and gpt-oss uses 64 on 2880 — deriving it would have put every
    /// KV cache estimate for those families off by a factor of two. GGUF publishes it as
    /// `attention.key_length`; when that is absent the derived value is the correct fallback.
    public var headDimensionOverride: Int?

    /// Non-nil only for mixture-of-experts models.
    public var moe: MoEShape?

    public var isMoE: Bool { moe != nil }

    public init(
        totalParameters: Int64,
        blockCount: Int,
        embeddingLength: Int,
        feedForwardLength: Int,
        headCount: Int,
        headCountKV: Int,
        trainingContextLength: Int,
        vocabSize: Int = 152_064,
        headDimension: Int? = nil,
        moe: MoEShape? = nil
    ) {
        self.headDimensionOverride = headDimension
        self.totalParameters = totalParameters
        self.blockCount = blockCount
        self.embeddingLength = embeddingLength
        self.feedForwardLength = feedForwardLength
        self.headCount = headCount
        self.headCountKV = headCountKV
        self.trainingContextLength = trainingContextLength
        self.vocabSize = vocabSize
        self.moe = moe
    }

    /// Dimension of one attention head, from the model's own metadata where available.
    public var headDimension: Int {
        if let headDimensionOverride, headDimensionOverride > 0 { return headDimensionOverride }
        return headCount > 0 ? embeddingLength / headCount : 128
    }

    /// Whether every value is meaningful and all derived expert arithmetic is representable.
    ///
    /// `ModelShape` remains a non-failable value type for catalog and Codable compatibility.
    /// Boundaries that accept untrusted shapes use this property to fail closed before planning.
    public var isValidForPlanning: Bool {
        guard (1...Self.maximumParameterCount).contains(totalParameters),
              (1...Self.maximumBlockCount).contains(blockCount),
              (1...Self.maximumEmbeddingLength).contains(embeddingLength),
              (0...Self.maximumFeedForwardLength).contains(feedForwardLength),
              (1...Self.maximumHeadCount).contains(headCount),
              (1...headCount).contains(headCountKV),
              (1...Self.maximumContextLength).contains(trainingContextLength),
              (1...Self.maximumVocabularySize).contains(vocabSize),
              (1...Self.maximumHeadDimension).contains(headDimension)
        else { return false }

        guard let moe else { return true }
        guard (1...Self.maximumExpertCount).contains(moe.expertCount),
              (1...moe.expertCount).contains(moe.expertsUsedPerToken),
              (1...Self.maximumFeedForwardLength).contains(moe.expertFeedForwardLength),
              (1...blockCount).contains(moe.moeLayerCount),
              moe.activeParameters >= 0,
              moe.activeParameters <= totalParameters,
              let perExpert = moe.checkedParametersPerExpertSlot(
                embeddingLength: embeddingLength
              ),
              let expertCount = Int64(exactly: moe.expertCount)
        else { return false }
        let (allExperts, overflow) = perExpert.multipliedReportingOverflow(by: expertCount)
        return !overflow && allExperts <= totalParameters
    }

    /// Parameters actually touched per token — the number that determines generation speed.
    ///
    /// GGUF headers do not publish this, so for any model the catalog has not seen it has to be
    /// derived: everything that is not a routed expert, plus the experts a single token actually
    /// activates. Returning zero here (as a missing catalog entry once did) makes the speed
    /// estimator divide by nothing and report prompt throughput in the billions.
    public var effectiveActiveParameters: Int64 {
        guard let moe else { return totalParameters }
        if moe.activeParameters > 0 { return moe.activeParameters }

        guard let perExpert = moe.checkedParametersPerExpertSlot(embeddingLength: embeddingLength),
              let expertCount = Int64(exactly: moe.expertCount),
              let expertsUsed = Int64(exactly: moe.expertsUsedPerToken)
        else { return max(0, totalParameters) }
        let (allExperts, allExpertsOverflow) = perExpert.multipliedReportingOverflow(by: expertCount)
        guard !allExpertsOverflow else { return max(0, totalParameters) }
        let (remainder, remainderOverflow) = totalParameters.subtractingReportingOverflow(allExperts)
        guard !remainderOverflow else { return max(0, totalParameters) }
        let nonExpert = max(totalParameters / 20, remainder)
        let (activeExperts, activeOverflow) = perExpert.multipliedReportingOverflow(by: expertsUsed)
        guard !activeOverflow else { return max(0, totalParameters) }
        let (active, totalOverflow) = nonExpert.addingReportingOverflow(activeExperts)
        return totalOverflow ? max(0, totalParameters) : max(0, active)
    }
}

/// Mixture-of-experts dimensions. Expert streaming economics depend entirely on these.
public struct MoEShape: Hashable, Sendable, Codable {
    /// Total routed experts per MoE layer (e.g. 128 for Qwen3-30B-A3B).
    public var expertCount: Int
    /// Experts activated per token (`n_expert_used`, e.g. 8).
    public var expertsUsedPerToken: Int
    /// Intermediate width of a single routed expert's FFN.
    public var expertFeedForwardLength: Int
    /// How many transformer blocks actually contain MoE layers. Some models keep the first
    /// block(s) dense, so this is not always equal to `blockCount`.
    public var moeLayerCount: Int
    /// Parameters active per token, used for speed estimates.
    public var activeParameters: Int64
    /// Whether the architecture has an always-on shared expert alongside the routed ones.
    public var hasSharedExpert: Bool

    public init(
        expertCount: Int,
        expertsUsedPerToken: Int,
        expertFeedForwardLength: Int,
        moeLayerCount: Int,
        activeParameters: Int64,
        hasSharedExpert: Bool = false
    ) {
        self.expertCount = expertCount
        self.expertsUsedPerToken = expertsUsedPerToken
        self.expertFeedForwardLength = expertFeedForwardLength
        self.moeLayerCount = moeLayerCount
        self.activeParameters = activeParameters
        self.hasSharedExpert = hasSharedExpert
    }

    /// Parameters in a single routed expert, summed across every MoE layer.
    ///
    /// A routed expert is three matrices — gate, up and down — each `d_model x d_expert_ffn`.
    /// The paging implementation reserves slots per layer, so one "slot" costs this much.
    /// Validated against the RFC benchmark: Qwen3-30B-A3B-Q6_K reports ~0.173 GiB per slot, and
    /// `3 * 2048 * 768 * 48 * 6.56/8` reproduces that to three significant figures.
    public func parametersPerExpertSlot(embeddingLength: Int) -> Int64 {
        checkedParametersPerExpertSlot(embeddingLength: embeddingLength) ?? Int64.max
    }

    fileprivate func checkedParametersPerExpertSlot(embeddingLength: Int) -> Int64? {
        guard let embedding = Int64(exactly: embeddingLength),
              let feedForward = Int64(exactly: expertFeedForwardLength),
              let layers = Int64(exactly: moeLayerCount),
              embedding > 0, feedForward > 0, layers > 0
        else { return nil }

        let (matrices, firstOverflow) = embedding.multipliedReportingOverflow(by: 3)
        let (perLayer, secondOverflow) = matrices.multipliedReportingOverflow(by: feedForward)
        let (total, thirdOverflow) = perLayer.multipliedReportingOverflow(by: layers)
        guard !firstOverflow, !secondOverflow, !thirdOverflow else { return nil }
        return total
    }
}
