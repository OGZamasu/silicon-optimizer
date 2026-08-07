import Foundation
import SiliconCore

/// Cache precision for the attention KV store. Quantizing it is the cheapest way to buy context.
public enum KVCachePrecision: String, Sendable, Codable, CaseIterable, Identifiable {
    case f16 = "f16"
    case q8_0 = "q8_0"
    case q5_1 = "q5_1"
    case q4_0 = "q4_0"

    public var id: String { rawValue }

    /// Bytes per stored element, including block scale overhead.
    public var bytesPerElement: Double {
        switch self {
        case .f16: 2.0
        case .q8_0: 1.0625      // 32-element blocks, one f16 scale each
        case .q5_1: 0.75
        case .q4_0: 0.5625
        }
    }

    public var label: String {
        switch self {
        case .f16: "F16 — full precision"
        case .q8_0: "Q8_0 — half the size, no measurable loss"
        case .q5_1: "Q5_1 — aggressive"
        case .q4_0: "Q4_0 — smallest, may degrade long-context recall"
        }
    }
}

/// Everything that determines how much memory a load will take.
public struct LoadConfiguration: Sendable, Codable, Hashable {
    public var contextLength: Int
    public var batchSize: Int              // -b, logical batch
    public var microBatchSize: Int         // -ub, the one that sizes compute buffers
    public var kvCachePrecision: KVCachePrecision
    public var flashAttention: Bool
    /// Fraction of layers placed on the GPU. 1.0 means fully offloaded, which is what you want
    /// on Apple Silicon since the GPU shares the same memory as the CPU.
    public var gpuLayerFraction: Double
    public var expertStreaming: ExpertStreamingConfiguration?
    public var threads: Int

    public init(
        contextLength: Int = 8192,
        batchSize: Int = 2048,
        microBatchSize: Int = 512,
        kvCachePrecision: KVCachePrecision = .f16,
        flashAttention: Bool = true,
        gpuLayerFraction: Double = 1.0,
        expertStreaming: ExpertStreamingConfiguration? = nil,
        threads: Int = 0
    ) {
        self.contextLength = contextLength
        self.batchSize = batchSize
        self.microBatchSize = microBatchSize
        self.kvCachePrecision = kvCachePrecision
        self.flashAttention = flashAttention
        self.gpuLayerFraction = gpuLayerFraction
        self.expertStreaming = expertStreaming
        self.threads = threads
    }
}

/// Configuration for llama.cpp's on-demand MoE expert paging.
///
/// Mirrors the RFC in ggml-org/llama.cpp#23324: a fixed pool of `slotCount` expert slots lives
/// in Metal shared memory, a CPU sidecar resolves router choices to slots with an LRU policy,
/// and misses are `pread` from the GGUF. Inference stays numerically exact — only residency
/// changes — so the trade is memory against speed, not memory against quality.
public struct ExpertStreamingConfiguration: Sendable, Codable, Hashable {
    /// `--moe-n-slots`. Each slot holds one expert across every MoE layer.
    public var slotCount: Int
    /// `--moe-n-layers`. Zero means every MoE layer participates.
    public var layerCount: Int

    public init(slotCount: Int, layerCount: Int = 0) {
        self.slotCount = slotCount
        self.layerCount = layerCount
    }

    /// The pool must be able to hold every expert every token in the micro-batch could select,
    /// or a batch can evict a slot it still needs. The RFC states this as
    /// `ub * n_expert_used <= n_slots`.
    public static func maximumMicroBatch(slotCount: Int, expertsUsedPerToken: Int) -> Int {
        max(1, slotCount / max(1, expertsUsedPerToken))
    }

    public func satisfiesConstraint(microBatch: Int, expertsUsedPerToken: Int) -> Bool {
        microBatch * expertsUsedPerToken <= slotCount
    }
}
