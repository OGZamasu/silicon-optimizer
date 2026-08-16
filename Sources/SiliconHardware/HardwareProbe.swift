import Foundation
import IOKit
import SiliconCore

/// Reads the machine's fixed characteristics. Everything here is available to an unsandboxed
/// user process without elevated privileges — no `powermetrics`, no helper tool.
public enum HardwareProbe {

    public static func detect() -> SystemProfile {
        let brand = sysctlString("machdep.cpu.brand_string") ?? "Unknown"
        let (generation, variant) = parseChip(brand)
        let gpuCores = detectGPUCores() ?? estimatedGPUCores(generation: generation, variant: variant)
        let memory = Bytes(sysctlInt("hw.memsize") ?? 8_589_934_592)

        // perflevel0 is the performance cluster, perflevel1 the efficiency cluster. Machines
        // with a single cluster type report only perflevel0.
        let pCores = sysctlInt("hw.perflevel0.physicalcpu").map(Int.init) ?? 4
        let eCores = sysctlInt("hw.perflevel1.physicalcpu").map(Int.init) ?? 0

        let (diskTotal, diskFree) = diskCapacity()

        return SystemProfile(
            chipName: brand.replacingOccurrences(of: "Apple ", with: "Apple "),
            generation: generation,
            variant: variant,
            modelIdentifier: sysctlString("hw.model") ?? "unknown",
            totalMemory: memory,
            performanceCores: pCores,
            efficiencyCores: eCores,
            gpuCores: gpuCores,
            neuralEngineCores: neuralEngineCores(generation: generation, variant: variant),
            diskTotal: diskTotal,
            diskFree: diskFree,
            memoryBandwidthGBps: memoryBandwidth(generation: generation, variant: variant, gpuCores: gpuCores)
        )
    }

    // MARK: - Chip identification

    static func parseChip(_ brand: String) -> (ChipGeneration, ChipVariant) {
        guard brand.contains("Apple M") else { return (.unknown, .base) }
        let generation: ChipGeneration = {
            for gen in ChipGeneration.allCases where gen != .unknown {
                if brand.contains("Apple M\(gen.rawValue)") { return gen }
            }
            return .unknown
        }()
        let variant: ChipVariant = {
            if brand.contains("Ultra") { return .ultra }
            if brand.contains("Max") { return .max }
            if brand.contains("Pro") { return .pro }
            return .base
        }()
        return (generation, variant)
    }

    // MARK: - GPU

    /// The GPU core count lives in the IORegistry under the AGXAccelerator node.
    static func detectGPUCores() -> Int? {
        guard let matching = IOServiceMatching("AGXAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            let value = IORegistryEntryCreateCFProperty(
                entry, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue()
            if let number = value as? NSNumber { return number.intValue }
        }
        return nil
    }

    static func estimatedGPUCores(generation: ChipGeneration, variant: ChipVariant) -> Int {
        switch variant {
        case .base: 10
        case .pro: generation >= .m3 ? 18 : 16
        case .max: generation >= .m3 ? 40 : 32
        case .ultra: generation >= .m3 ? 80 : 64
        }
    }

    static func neuralEngineCores(generation: ChipGeneration, variant: ChipVariant) -> Int {
        // Every shipping Apple Silicon chip has a 16-core ANE, doubled on Ultra parts
        // because those are two dies fused together.
        variant == .ultra ? 32 : 16
    }

    // MARK: - Memory bandwidth

    /// Peak unified-memory bandwidth in GB/s, from Apple's published figures. Token generation
    /// on a memory-bound decode is roughly `bandwidth / bytes-read-per-token`, so this drives
    /// the speed estimates throughout the app.
    ///
    /// Where a variant shipped in more than one memory configuration we disambiguate by GPU
    /// core count — notably the M3 Max, which is 300 GB/s in the 30-core bin and 400 GB/s in
    /// the 40-core bin.
    static func memoryBandwidth(generation: ChipGeneration, variant: ChipVariant, gpuCores: Int) -> Double {
        switch (generation, variant) {
        case (.m1, .base): 68.25
        case (.m1, .pro): 200
        case (.m1, .max): 400
        case (.m1, .ultra): 800

        case (.m2, .base): 100
        case (.m2, .pro): 200
        case (.m2, .max): 400
        case (.m2, .ultra): 800

        case (.m3, .base): 100
        case (.m3, .pro): 150
        case (.m3, .max): gpuCores <= 30 ? 300 : 400
        case (.m3, .ultra): 800

        case (.m4, .base): 120
        case (.m4, .pro): 273
        case (.m4, .max): gpuCores <= 32 ? 410 : 546
        case (.m4, .ultra): 1092

        // M5 moved to LPDDR5X. Higher-tier parts are estimated by scaling the base part on
        // the same ratios the M4 family used; they are refined once real silicon reports in.
        //
        // An attempt to replace the Pro figure with one derived from a real M5 Pro was reverted
        // (#1): the residual it corrected was measured on a single dense model, and bandwidth is
        // a machine-wide term, so absorbing a dense-specific error here necessarily mis-predicts
        // MoE models. See `SpeedEstimator.bandwidthEfficiency` — that is where the error lives.
        case (.m5, .base): 153
        case (.m5, .pro): 345
        case (.m5, .max): gpuCores <= 32 ? 520 : 690
        case (.m5, .ultra): 1380

        case (.unknown, _): 68.25
        }
    }

    // MARK: - Disk

    static func diskCapacity() -> (total: Bytes, free: Bytes) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]) else {
            return (.gib(256), .gib(64))
        }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        // `ForImportantUsage` reflects what macOS will actually free up for us by purging
        // caches and local snapshots, which is the number a download should be checked against.
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        return (Bytes(total), Bytes(free))
    }

    // MARK: - sysctl helpers

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // sysctl strings are NUL-terminated; drop the terminator before decoding.
        return String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        if sysctlbyname(name, &value, &size, nil, 0) == 0 { return value }
        // Some keys are published as 32-bit.
        var small: Int32 = 0
        var smallSize = MemoryLayout<Int32>.size
        if sysctlbyname(name, &small, &smallSize, nil, 0) == 0 { return Int64(small) }
        return nil
    }
}
