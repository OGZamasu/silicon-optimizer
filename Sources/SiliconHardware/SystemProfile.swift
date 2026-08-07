import Foundation
import SiliconCore

public enum ChipGeneration: Int, Sendable, Codable, Comparable, CaseIterable {
    case unknown = 0, m1 = 1, m2 = 2, m3 = 3, m4 = 4, m5 = 5

    public static func < (lhs: ChipGeneration, rhs: ChipGeneration) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        self == .unknown ? "Unknown" : "M\(rawValue)"
    }

    /// Generations from M3 onward ship hardware-accelerated ray tracing and dynamic caching;
    /// more importantly for us, M3+ Metal drivers handle large unified allocations more
    /// gracefully, which affects how aggressively we size the KV cache.
    public var hasDynamicCaching: Bool { self >= .m3 }
}

public enum ChipVariant: String, Sendable, Codable, CaseIterable {
    case base = "", pro = "Pro", max = "Max", ultra = "Ultra"

    public var displayName: String { self == .base ? "" : rawValue }
}

/// A complete picture of the machine, resolved once at launch.
public struct SystemProfile: Sendable, Codable, Equatable {
    public var chipName: String
    public var generation: ChipGeneration
    public var variant: ChipVariant
    public var modelIdentifier: String

    public var totalMemory: Bytes
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var gpuCores: Int
    public var neuralEngineCores: Int

    public var diskTotal: Bytes
    public var diskFree: Bytes

    /// Peak unified-memory bandwidth in GB/s. This is the single best predictor of
    /// token generation speed for memory-bound decoding.
    public var memoryBandwidthGBps: Double

    /// Measured sequential SSD read throughput in MB/s, populated by the optional benchmark.
    /// Expert streaming is only viable when this is high.
    public var ssdReadMBps: Double?

    public var isAppleSilicon: Bool { generation != .unknown }

    public var displayName: String {
        variant == .base ? chipName : "\(chipName)"
    }

    public init(
        chipName: String,
        generation: ChipGeneration,
        variant: ChipVariant,
        modelIdentifier: String,
        totalMemory: Bytes,
        performanceCores: Int,
        efficiencyCores: Int,
        gpuCores: Int,
        neuralEngineCores: Int,
        diskTotal: Bytes,
        diskFree: Bytes,
        memoryBandwidthGBps: Double,
        ssdReadMBps: Double? = nil
    ) {
        self.chipName = chipName
        self.generation = generation
        self.variant = variant
        self.modelIdentifier = modelIdentifier
        self.totalMemory = totalMemory
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.gpuCores = gpuCores
        self.neuralEngineCores = neuralEngineCores
        self.diskTotal = diskTotal
        self.diskFree = diskFree
        self.memoryBandwidthGBps = memoryBandwidthGBps
        self.ssdReadMBps = ssdReadMBps
    }

    /// macOS will not let a single process wire down all of physical memory. The Metal driver
    /// enforces a recommended working-set limit, which historically sits near 75% on small
    /// machines and rises on larger ones. We keep our own budget slightly under that so the
    /// window server and the user's other apps stay responsive.
    public var safeModelBudget: Bytes {
        let gb = totalMemory.gibibytes
        let fraction: Double
        switch gb {
        case ..<10: fraction = 0.55       // 8 GB: macOS itself needs most of this
        case ..<18: fraction = 0.62       // 16 GB
        case ..<26: fraction = 0.70       // 24 GB
        case ..<40: fraction = 0.74       // 32/36 GB
        case ..<70: fraction = 0.78       // 48/64 GB
        case ..<100: fraction = 0.82      // 96 GB
        default: fraction = 0.85          // 128 GB and up
        }
        return totalMemory * fraction
    }

    /// The `iogpu.wired_limit_mb` sysctl can raise the Metal working-set ceiling. We surface
    /// this so the app can offer it as an explicit, reversible power-user action.
    public var defaultWiredLimit: Bytes {
        totalMemory.gibibytes <= 36 ? totalMemory * 0.75 : totalMemory * 0.80
    }

    public static let unknownMac = SystemProfile(
        chipName: "Unknown Mac", generation: .unknown, variant: .base,
        modelIdentifier: "unknown", totalMemory: .gib(8),
        performanceCores: 4, efficiencyCores: 4, gpuCores: 8, neuralEngineCores: 16,
        diskTotal: .gib(256), diskFree: .gib(64), memoryBandwidthGBps: 68
    )
}
