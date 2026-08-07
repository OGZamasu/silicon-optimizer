import Foundation
import IOKit
import SiliconCore

/// A single instantaneous reading of system load.
public struct SystemMetrics: Sendable, Equatable {
    public var memoryUsed: Bytes = .zero
    public var memoryWired: Bytes = .zero
    public var memoryCompressed: Bytes = .zero
    public var memoryFree: Bytes = .zero
    public var memoryTotal: Bytes = .zero

    public var swapUsed: Bytes = .zero
    public var swapTotal: Bytes = .zero

    public var gpuUtilization: Double = 0      // 0...1
    public var gpuMemoryInUse: Bytes = .zero
    public var cpuUtilization: Double = 0      // 0...1

    /// macOS memory pressure, mirroring the green/yellow/red state in Activity Monitor.
    public var memoryPressure: MemoryPressure = .normal

    public init() {}

    public var memoryUsedFraction: Double { memoryUsed.fraction(of: memoryTotal) }
}

public enum MemoryPressure: Int, Sendable, Comparable, Codable {
    case normal = 1, warning = 2, critical = 4

    public static func < (lhs: MemoryPressure, rhs: MemoryPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

/// Samples live system counters. Every source here is readable without root.
public struct MetricsSampler: Sendable {
    private let pageSize: UInt64
    private let totalMemory: Bytes

    public init() {
        var size: UInt64 = 0
        var length = MemoryLayout<UInt64>.size
        sysctlbyname("hw.pagesize", &size, &length, nil, 0)
        self.pageSize = size == 0 ? 16384 : size
        self.totalMemory = Bytes(HardwareProbe.sysctlInt("hw.memsize") ?? 0)
    }

    public func sample() -> SystemMetrics {
        var metrics = SystemMetrics()
        metrics.memoryTotal = totalMemory
        readVMStatistics(into: &metrics)
        readSwap(into: &metrics)
        readGPU(into: &metrics)
        metrics.cpuUtilization = readCPULoad()
        metrics.memoryPressure = readMemoryPressure()
        return metrics
    }

    // MARK: - Memory

    private func readVMStatistics(into metrics: inout SystemMetrics) {
        var stats = vm_statistics64_data_t()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        func bytes(_ pages: natural_t) -> Bytes { Bytes(Int64(UInt64(pages) * pageSize)) }

        metrics.memoryWired = bytes(stats.wire_count)
        metrics.memoryCompressed = bytes(stats.compressor_page_count)
        metrics.memoryFree = bytes(stats.free_count)

        // Activity Monitor's "Memory Used" is app memory (anonymous pages that are not
        // purgeable) plus wired plus compressed. File-backed pages are excluded because the
        // kernel can evict them on demand.
        let appMemory = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        metrics.memoryUsed = Bytes(max(0, appMemory) * Int64(pageSize))
            + metrics.memoryWired + metrics.memoryCompressed
    }

    private func readSwap(into metrics: inout SystemMetrics) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return }
        metrics.swapUsed = Bytes(Int64(usage.xsu_used))
        metrics.swapTotal = Bytes(Int64(usage.xsu_total))
    }

    private func readMemoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .normal
        }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    // MARK: - GPU

    /// The Metal driver publishes a `PerformanceStatistics` dictionary on the IOAccelerator
    /// node. It is the same source Activity Monitor's GPU history window reads.
    private func readGPU(into metrics: inout SystemMetrics) {
        guard let matching = IOServiceMatching("IOAccelerator") else { return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let raw = IORegistryEntryCreateCFProperty(
                entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue(), let stats = raw as? [String: Any] else { continue }

            if let utilization = stats["Device Utilization %"] as? NSNumber {
                metrics.gpuUtilization = min(1.0, utilization.doubleValue / 100.0)
            }
            if let inUse = stats["In use system memory"] as? NSNumber {
                metrics.gpuMemoryInUse = Bytes(inUse.int64Value)
            }
            // The first accelerator node with statistics is the integrated GPU.
            if metrics.gpuUtilization > 0 || metrics.gpuMemoryInUse > .zero { return }
        }
    }

    // MARK: - CPU

    private final class LoadState: @unchecked Sendable {
        var previous: host_cpu_load_info?
        let lock = NSLock()
    }
    private static let loadState = LoadState()

    private func readCPULoad() -> Double {
        var info = host_cpu_load_info()
        var count = UInt32(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        // CPU ticks are cumulative since boot, so utilization is only meaningful as a delta
        // against the previous sample.
        Self.loadState.lock.lock()
        defer { Self.loadState.lock.unlock() }
        defer { Self.loadState.previous = info }

        guard let previous = Self.loadState.previous else { return 0 }
        let user = Double(info.cpu_ticks.0 - previous.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 - previous.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 - previous.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 - previous.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return (user + system + nice) / total
    }
}
