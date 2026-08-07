import Foundation
import SiliconCore

/// A predicted memory breakdown for one (model, configuration) pair.
public struct MemoryPlan: Sendable, Equatable {
    public var nonExpertWeights: Bytes
    public var expertWeights: Bytes
    public var kvCache: Bytes
    public var computeBuffers: Bytes
    /// Weights that stay on disk because expert streaming is enabled.
    public var streamedFromDisk: Bytes

    public var budget: Bytes
    public var otherAppsInUse: Bytes

    public var verdict: Verdict
    public var remediations: [Remediation]
    public var notes: [String]

    /// Memory that must actually be resident while generating.
    public var resident: Bytes {
        nonExpertWeights + expertWeights + kvCache + computeBuffers
    }

    public var headroom: Bytes { budget - resident }

    public var utilization: Double { resident.fraction(of: budget) }

    public enum Verdict: Sendable, Equatable {
        /// Fits with room to spare.
        case comfortable
        /// Fits, but leaves little room for other applications.
        case tight
        /// Exceeds the safe budget — expect swapping and severe slowdown.
        case willSwap
        /// Cannot run at all in this configuration.
        case impossible

        public var label: String {
            switch self {
            case .comfortable: "Comfortable"
            case .tight: "Tight"
            case .willSwap: "Will swap"
            case .impossible: "Won't fit"
            }
        }

        public var isUsable: Bool { self == .comfortable || self == .tight }
    }

    public struct Remediation: Sendable, Equatable, Identifiable {
        public var id: String { title }
        public var title: String
        public var detail: String
        /// Memory this would free.
        public var saving: Bytes
        /// Cost in quality or speed, described plainly.
        public var cost: String
        public var kind: Kind

        public enum Kind: String, Sendable, Equatable {
            case reduceContext, lowerQuantization, quantizeKVCache
            case enableFlashAttention, enableExpertStreaming, switchRuntime, closeApps
        }

        public init(title: String, detail: String, saving: Bytes, cost: String, kind: Kind) {
            self.title = title
            self.detail = detail
            self.saving = saving
            self.cost = cost
            self.kind = kind
        }
    }
}

/// Predicted throughput for a configuration.
public struct SpeedEstimate: Sendable, Equatable {
    /// Tokens per second during generation.
    public var generationTokensPerSecond: Double
    /// Tokens per second while ingesting a prompt.
    public var prefillTokensPerSecond: Double
    /// Set when expert streaming makes the estimate materially less certain.
    public var isStreamingBound: Bool

    public var summary: String {
        String(format: "~%.0f tok/s generation · ~%.0f tok/s prompt",
               generationTokensPerSecond, prefillTokensPerSecond)
    }
}
