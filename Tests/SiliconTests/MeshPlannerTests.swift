import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore
@testable import SiliconHardware
@testable import SiliconPlanner

private let m3Max = SystemProfile(
    chipName: "Apple M3 Max", generation: .m3, variant: .max, modelIdentifier: "Mac15,11",
    totalMemory: .gib(36), performanceCores: 10, efficiencyCores: 4, gpuCores: 30,
    neuralEngineCores: 16, diskTotal: .gib(1024), diskFree: .gib(400),
    memoryBandwidthGBps: 300, ssdReadMBps: 5000
)

private let m1Base = SystemProfile(
    chipName: "Apple M1", generation: .m1, variant: .base, modelIdentifier: "MacBookAir10,1",
    totalMemory: .gib(8), performanceCores: 4, efficiencyCores: 4, gpuCores: 7,
    neuralEngineCores: 16, diskTotal: .gib(256), diskFree: .gib(100),
    memoryBandwidthGBps: 68, ssdReadMBps: 2800
)

@Suite("3D memory planning")
struct MeshPlannerTests {

    /// The planner's figures are measured, not derived, so the catalog numbers must flow
    /// through unchanged at default configuration.
    @Test func hunyuanUsesTheMeasuredFigures() {
        let plan = MeshPlanner(profile: m3Max).plan(
            entry: MeshCatalog.hunyuanMini, configuration: MeshConfiguration()
        )
        #expect(plan.peak == MeshCatalog.hunyuanMini.peakMemory)
        #expect(plan.phases.count == 2)
        #expect(plan.verdict == .comfortable)
    }

    /// Quantization tracks the benchmark table: 8-bit roughly a third off the peak, 4-bit
    /// roughly half. Direction matters more than digits — the planner must never claim
    /// quantizing costs memory.
    @Test func quantizationLowersTheFigures() {
        let planner = MeshPlanner(profile: m3Max)
        let fp16 = planner.plan(
            entry: MeshCatalog.hunyuanMini, configuration: MeshConfiguration()
        )
        let q8 = planner.plan(
            entry: MeshCatalog.hunyuanMini, configuration: MeshConfiguration(quantize: 8)
        )
        let q4 = planner.plan(
            entry: MeshCatalog.hunyuanMini, configuration: MeshConfiguration(quantize: 4)
        )
        #expect(q8.peak < fp16.peak)
        #expect(q4.peak < q8.peak)
    }

    /// TRELLIS.2 peaks at a measured ~18 GB — comfortable on 36 GB, impossible on 8 GB.
    @Test func trellisVerdictTracksTheMachine() {
        let configuration = MeshConfiguration()
        let big = MeshPlanner(profile: m3Max).plan(
            entry: MeshCatalog.trellis2, configuration: configuration
        )
        let small = MeshPlanner(profile: m1Base).plan(
            entry: MeshCatalog.trellis2, configuration: configuration
        )
        #expect(big.verdict.isUsable)
        #expect(small.verdict == .impossible)
    }

    /// Remote work must never be gated on local memory: an 8 GB Air can drive LATO.2.
    @Test func latoIsAlwaysComfortableBecauseItIsRemote() {
        let plan = MeshPlanner(profile: m1Base).plan(
            entry: MeshCatalog.lato2, configuration: MeshConfiguration()
        )
        #expect(plan.isRemote)
        #expect(plan.verdict == .comfortable)
    }

    /// A tight plan must offer the quantization way out when the backend has one.
    @Test func tightPlansSuggestQuantization() {
        // Turbo's fp16 peak (~7.3 GB) against an 8 GB machine's budget is past the
        // comfortable line, so remediations must appear, led by quantization.
        let plan = MeshPlanner(profile: m1Base).plan(
            entry: MeshCatalog.hunyuanTurbo, configuration: MeshConfiguration()
        )
        #expect(!plan.verdict.isUsable || plan.verdict == .tight)
        #expect(plan.remediations.contains { $0.kind == .lowerQuantization })
    }
}

@Suite("3D catalog")
struct MeshCatalogTests {

    @Test func idsAreUnique() {
        let ids = MeshCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    /// Every backend that cannot run out of the box must say how to fix that.
    @Test func unavailableEntriesCarryASetupHint() {
        for entry in MeshCatalog.all
        where entry.backend == .unsupported || entry.backend == .latoRemote {
            #expect(entry.setupHint?.isEmpty == false, "\(entry.id) needs a setupHint")
        }
    }
}
