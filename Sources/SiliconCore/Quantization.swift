import Foundation

/// A weight quantization format. `bitsPerWeight` values are the *effective* rates measured by
/// llama.cpp on 7B-class models, which include the per-block scale/min overhead — using the
/// nominal bit count (4 for Q4_K_M) underestimates real file size by roughly 20%.
public enum Quantization: String, CaseIterable, Sendable, Codable, Identifiable {
    case q2_K = "Q2_K"
    case q3_K_S = "Q3_K_S"
    case q3_K_M = "Q3_K_M"
    case q3_K_L = "Q3_K_L"
    case q4_0 = "Q4_0"
    case q4_K_S = "Q4_K_S"
    case q4_K_M = "Q4_K_M"
    case q5_K_S = "Q5_K_S"
    case q5_K_M = "Q5_K_M"
    case q6_K = "Q6_K"
    case q8_0 = "Q8_0"
    // IQ formats use an importance-matrix codebook rather than plain per-block scale/min, which
    // is what lets them reach sub-4-bit rates competitively — a plain Q3_K/Q2_K at the same size
    // loses noticeably more. bitsPerWeight values are llama.cpp's published effective rates.
    case iq1_S = "IQ1_S"
    case iq2_XXS = "IQ2_XXS"
    case iq3_M = "IQ3_M"
    case iq4_XS = "IQ4_XS"
    case iq4_NL = "IQ4_NL"
    case f16 = "F16"
    case bf16 = "BF16"
    /// Microscaling FP4. Unlike the Q* formats this is not a post-training compression — some
    /// models are released natively in it, so it is effectively lossless for those weights.
    case mxfp4 = "MXFP4"
    // MLX uses affine quantization with a group size; the extra scale/bias per group puts the
    // effective rate slightly above the nominal bit width.
    case mlx4 = "MLX-4bit"
    case mlx6 = "MLX-6bit"
    case mlx8 = "MLX-8bit"

    public var id: String { rawValue }

    public var bitsPerWeight: Double {
        switch self {
        case .q2_K: 3.35
        case .q3_K_S: 3.50
        case .q3_K_M: 3.91
        case .q3_K_L: 4.27
        case .q4_0: 4.55
        case .q4_K_S: 4.58
        case .q4_K_M: 4.85
        case .q5_K_S: 5.52
        case .q5_K_M: 5.69
        case .q6_K: 6.56
        case .q8_0: 8.50
        case .iq1_S: 1.56
        case .iq2_XXS: 2.06
        case .iq3_M: 3.66
        case .iq4_XS: 4.25
        case .iq4_NL: 4.50
        case .f16, .bf16: 16.0
        case .mxfp4: 4.25
        case .mlx4: 4.50
        case .mlx6: 6.50
        case .mlx8: 8.50
        }
    }

    /// Approximate perplexity increase over the F16 baseline, as a percentage. Used to explain
    /// the cost of a downgrade rather than to make precise quality claims.
    public var qualityLossPercent: Double {
        switch self {
        case .q2_K: 25.0
        case .q3_K_S: 12.0
        case .q3_K_M: 7.4
        case .q3_K_L: 5.5
        case .q4_0: 4.0
        case .q4_K_S: 2.6
        case .q4_K_M: 1.7
        case .q5_K_S: 0.9
        case .q5_K_M: 0.6
        case .q6_K: 0.2
        case .q8_0: 0.05
        case .iq1_S: 35.0
        case .iq2_XXS: 20.0
        case .iq3_M: 6.0
        case .iq4_XS: 2.3
        case .iq4_NL: 2.0
        case .f16, .bf16: 0.0
        case .mxfp4: 0.3
        case .mlx4: 2.5
        case .mlx6: 0.7
        case .mlx8: 0.1
        }
    }

    public var isMLX: Bool {
        switch self {
        case .mlx4, .mlx6, .mlx8: true
        default: false
        }
    }

    /// The format most users should land on: the best quality that still fits comfortably.
    public static let recommendedDefault = Quantization.q4_K_M

    /// Ordered best-quality-first, for downgrade searches in the planner.
    public static var byQualityDescending: [Quantization] {
        allCases.sorted { $0.bitsPerWeight > $1.bitsPerWeight }
    }

    public var displayName: String {
        switch self {
        case .q4_K_M: "Q4_K_M (recommended)"
        case .f16: "F16 (full precision)"
        case .bf16: "BF16 (full precision)"
        default: rawValue
        }
    }

    public var summary: String {
        switch self {
        case .q2_K: "Smallest. Noticeable quality loss — last resort."
        case .q3_K_S, .q3_K_M, .q3_K_L: "Aggressive compression. Use when Q4 will not fit."
        case .q4_0: "Legacy 4-bit. Prefer Q4_K_M."
        case .q4_K_S: "Slightly smaller than Q4_K_M, slightly worse."
        case .q4_K_M: "The sweet spot for Apple Silicon. Near-original quality."
        case .q5_K_S, .q5_K_M: "Higher fidelity when you have memory to spare."
        case .q6_K: "Near-lossless. Worth it on 64 GB+ machines."
        case .q8_0: "Essentially lossless. Large."
        case .iq1_S: "Extreme compression via an importance matrix. Only for models Q2_K can't fit."
        case .iq2_XXS: "Sub-3-bit with an importance matrix. Better than Q2_K at a similar size."
        case .iq3_M: "Importance-matrix 3-bit. A stronger alternative to Q3_K at similar size."
        case .iq4_XS: "Importance-matrix 4-bit, smaller than Q4_K_S at comparable quality."
        case .iq4_NL: "Importance-matrix 4-bit, non-linear codebook. Close to Q4_K_M quality."
        case .f16, .bf16: "Unquantized. Only for small models or very large machines."
        case .mxfp4: "Native 4-bit release format. Lossless for models trained in it."
        case .mlx4: "MLX 4-bit. Fast on Apple Silicon."
        case .mlx6: "MLX 6-bit. Good balance."
        case .mlx8: "MLX 8-bit. Near-lossless, larger."
        }
    }

    /// The quantization token exactly as the publisher wrote it, for display.
    ///
    /// Community repositories ship many variants this enum deliberately does not model —
    /// `Q2_K_L`, `UD-Q4_K_XL`, `IQ4_XS`. Mapping those onto the nearest known case is right for
    /// *planning*, but labelling a list with it puts two different files under the same name and
    /// makes them look like duplicates. Showing the real token keeps them distinguishable.
    public static func label(fromFilename filename: String) -> String? {
        let stem = (filename as NSString).lastPathComponent
            .replacingOccurrences(of: ".gguf", with: "", options: .caseInsensitive)
        // Trailing shard suffix is not part of the quantization.
        let withoutShard = stem.replacingOccurrences(
            of: #"-\d{5}-of-\d{5}$"#, with: "", options: .regularExpression
        )
        guard let range = withoutShard.range(
            of: #"(UD-)?I?Q\d+(_[A-Z0-9]+)*|BF16|F16|F32|MXFP4"#,
            options: [.regularExpression, .backwards]
        ) else { return nil }
        return String(withoutShard[range])
    }

    /// Parses a quantization out of a GGUF filename such as
    /// `Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf`.
    public static func inferred(fromFilename filename: String) -> Quantization? {
        let upper = filename.uppercased()
        // Longest-first so that "Q4_K_M" wins over a hypothetical "Q4" prefix match.
        return allCases
            .filter { !$0.isMLX }
            .sorted { $0.rawValue.count > $1.rawValue.count }
            .first { upper.contains($0.rawValue) }
    }
}
