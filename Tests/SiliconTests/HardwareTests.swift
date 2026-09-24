import Foundation
import Testing
@testable import SiliconCore
@testable import SiliconHardware

@Suite("Hardware detection")
struct HardwareTests {

    /// Runs against whatever machine the suite is executing on, so it asserts on invariants
    /// rather than on one specific Mac.
    @Test func detectsThisMachine() {
        let profile = HardwareProbe.detect()

        #expect(profile.totalMemory > .gib(3))
        #expect(profile.performanceCores > 0)
        #expect(profile.gpuCores > 0)
        #expect(profile.memoryBandwidthGBps > 0)
        #expect(profile.diskTotal > .zero)

        if profile.isAppleSilicon {
            #expect(profile.neuralEngineCores >= 16)
            // Every Apple Silicon Mac has both cluster types except the base M1 in some
            // configurations, so only assert the performance cluster exists.
            #expect(profile.chipName.contains("Apple M"))
        }
    }

    @Test(arguments: [
        ("Apple M1", ChipGeneration.m1, ChipVariant.base),
        ("Apple M1 Pro", .m1, .pro),
        ("Apple M2 Max", .m2, .max),
        ("Apple M3 Ultra", .m3, .ultra),
        ("Apple M4 Pro", .m4, .pro),
        ("Apple M5", .m5, .base),
    ])
    func parsesChipBrandStrings(brand: String, generation: ChipGeneration, variant: ChipVariant) {
        let (parsedGeneration, parsedVariant) = HardwareProbe.parseChip(brand)
        #expect(parsedGeneration == generation)
        #expect(parsedVariant == variant)
    }

    @Test func rejectsNonAppleSilicon() {
        let (generation, _) = HardwareProbe.parseChip("Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz")
        #expect(generation == .unknown)
    }

    /// The M3 Max ships in two bins that differ in bandwidth; GPU core count is what separates
    /// them, and getting this wrong would skew every speed estimate on those machines.
    @Test func disambiguatesM3MaxBinsByGPUCores() {
        #expect(HardwareProbe.memoryBandwidth(generation: .m3, variant: .max, gpuCores: 30) == 300)
        #expect(HardwareProbe.memoryBandwidth(generation: .m3, variant: .max, gpuCores: 40) == 400)
    }

    /// The safe budget must always leave the system something to work with.
    @Test(arguments: [8.0, 16.0, 24.0, 36.0, 64.0, 128.0, 512.0])
    func budgetLeavesHeadroom(memoryGiB: Double) {
        var profile = SystemProfile.unknownMac
        profile.totalMemory = .gib(memoryGiB)
        #expect(profile.safeModelBudget < profile.totalMemory)
        #expect(profile.safeModelBudget > profile.totalMemory * 0.5)
        // Larger machines should be allowed to give proportionally more to the model.
        #expect(profile.safeModelBudget.gibibytes >= memoryGiB * 0.55 - 0.01)
    }

    /// The tick counters are 32 bits and host-wide, so the idle one wraps after a few weeks
    /// awake. The sample straddling the wrap has to read as the ticks that elapsed — not trap
    /// the whole app, which a checked subtraction did.
    @Test func cpuLoadAcrossACounterWrapIsTheTicksThatElapsed() {
        let before = host_cpu_load_info(cpu_ticks: (1_000, 500, UInt32.max - 99, 10))
        // 100 idle ticks take the counter to exactly 2^32, i.e. 0; 200 more land at 200.
        let after = host_cpu_load_info(cpu_ticks: (1_100, 600, 200, 10))

        // 300 idle against 200 busy: 40% busy, the same as without the wrap.
        #expect(abs(MetricsSampler.cpuUtilization(from: before, to: after) - 0.4) < 1e-9)
    }

    @Test func cpuLoadIsTheBusyShareOfTheTicksBetweenSamples() {
        let before = host_cpu_load_info(cpu_ticks: (100, 100, 100, 0))
        let after = host_cpu_load_info(cpu_ticks: (150, 125, 175, 0))
        #expect(abs(MetricsSampler.cpuUtilization(from: before, to: after) - 0.5) < 1e-9)
        // No ticks at all between two samples is no load, not a division by zero.
        #expect(MetricsSampler.cpuUtilization(from: after, to: after) == 0)
    }

    @Test func samplerReadsLiveCounters() {
        let metrics = MetricsSampler().sample()
        #expect(metrics.memoryTotal > .gib(3))
        #expect(metrics.memoryUsed > .zero)
        #expect(metrics.memoryUsed < metrics.memoryTotal)
        #expect(metrics.gpuUtilization >= 0 && metrics.gpuUtilization <= 1)
    }
}
