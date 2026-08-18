import Foundation
import SiliconCatalog
import SiliconCore
import SiliconHardware

/// The knobs a 3D generation exposes. A superset across backends; each runtime reads only the
/// fields its entry advertises support for, so an ignored field is invisible rather than a trap.
public struct MeshConfiguration: Sendable, Codable, Hashable {
    /// TRELLIS pipeline: "512", "1024" or "1024_cascade".
    public var pipelineType: String
    /// TRELLIS texture atlas side: 512, 1024 or 2048.
    public var textureSize: Int
    /// Hunyuan denoising steps. Nil adopts the entry's default.
    public var steps: Int?
    /// Hunyuan weight quantization: nil (fp16), 8 or 4.
    public var quantize: Int?
    /// Hunyuan octree resolution for the surface decode.
    public var octree: Int
    /// LATO.2 output vertex budget, 200–5000.
    public var vertexBudget: Int
    public var seed: Int?

    public init(
        pipelineType: String = "512", textureSize: Int = 1024, steps: Int? = nil,
        quantize: Int? = nil, octree: Int = 256, vertexBudget: Int = 2000, seed: Int? = nil
    ) {
        self.pipelineType = pipelineType
        self.textureSize = textureSize
        self.steps = steps
        self.quantize = quantize
        self.octree = octree
        self.vertexBudget = vertexBudget
        self.seed = seed
    }
}

/// A phased 3D memory plan, same shape as the diffusion one: load and generate release into
/// each other, so the tallest phase decides whether the run fits.
public struct MeshPlan: Sendable, Equatable {
    public struct Phase: Sendable, Equatable, Identifiable {
        public var name: String
        public var detail: String
        public var resident: Bytes
        public var id: String { name }

        public init(name: String, detail: String, resident: Bytes) {
            self.name = name
            self.detail = detail
            self.resident = resident
        }
    }

    public var phases: [Phase]
    public var budget: Bytes
    public var verdict: MemoryPlan.Verdict
    public var remediations: [MemoryPlan.Remediation]
    public var notes: [String]
    /// True when the work happens on another machine and the local budget is untouched.
    public var isRemote: Bool

    public var peak: Bytes { phases.map(\.resident).max() ?? .zero }
    public var peakPhase: Phase? { phases.max { $0.resident < $1.resident } }

    public init(
        phases: [Phase], budget: Bytes, verdict: MemoryPlan.Verdict,
        remediations: [MemoryPlan.Remediation], notes: [String], isRemote: Bool = false
    ) {
        self.phases = phases
        self.budget = budget
        self.verdict = verdict
        self.remediations = remediations
        self.notes = notes
        self.isRemote = isRemote
    }
}

/// Predicts what a 3D generation costs in memory before it runs.
///
/// Unlike the diffusion planner this one interpolates from measured benchmark tables rather
/// than deriving from architecture: 3D pipelines mix sparse convolution, octree decoding and
/// mesh baking whose peaks do not follow closed-form arithmetic. The measured points come from
/// the hunyuan3d-swift benchmark suite and trellis-mac's logged runs, and are scaled only along
/// axes those tables actually cover.
public struct MeshPlanner: Sendable {
    public let profile: SystemProfile

    public init(profile: SystemProfile) {
        self.profile = profile
    }

    public func plan(
        entry: MeshEntry, configuration: MeshConfiguration, otherAppsInUse: Bytes = .zero
    ) -> MeshPlan {
        let budget = budget(otherAppsInUse: otherAppsInUse)

        if entry.backend == .latoRemote {
            return MeshPlan(
                phases: [
                    MeshPlan.Phase(
                        name: "Upload", detail: "Send the image to the LATO.2 service",
                        resident: .mib(64)
                    ),
                    MeshPlan.Phase(
                        name: "Remote render",
                        detail: "TRELLIS densify + LATO.2 retopology on the CUDA machine",
                        resident: .mib(64)
                    ),
                ],
                budget: budget,
                verdict: .comfortable,
                remediations: [],
                notes: [
                    "Runs on the LATO.2 service machine — this Mac's memory is untouched.",
                    "Vertex budget \(configuration.vertexBudget) "
                        + "(clean low-poly output; 200–5000).",
                ],
                isRemote: true
            )
        }

        var (resident, peak) = memoryFigures(entry: entry, configuration: configuration)
        var notes: [String] = []

        if entry.backend == .trellis {
            if configuration.pipelineType != "512" {
                // The 1024 pipelines have not been measured on this machine; the README's
                // guidance is that they push past 24 GB-class budgets. Scale honestly and
                // say the number is an extrapolation.
                peak = peak + .gib(3)
                notes.append(
                    "The \(configuration.pipelineType) pipeline is an extrapolation — only "
                        + "the 512 pipeline has measured figures."
                )
            }
            if configuration.textureSize > 1024 {
                peak = peak + .gib(1)
            }
            notes.append("First run downloads ~13 GB of weights from Hugging Face.")
            notes.append(
                "Thermals matter: the same render measured 6–10× slower on a heat-soaked "
                    + "machine. Expect the long end of the range on battery."
            )
        }

        let phases = [
            MeshPlan.Phase(
                name: "Load", detail: "\(entry.name) weights resident", resident: resident
            ),
            MeshPlan.Phase(
                name: "Generate", detail: "Peak during sampling and mesh extraction",
                resident: peak
            ),
        ]

        let verdict = verdict(peak: peak, budget: budget)
        return MeshPlan(
            phases: phases,
            budget: budget,
            verdict: verdict,
            remediations: remediations(
                entry: entry, configuration: configuration, peak: peak, budget: budget
            ),
            notes: notes
        )
    }

    /// Resident and peak, from the measured tables.
    private func memoryFigures(
        entry: MeshEntry, configuration: MeshConfiguration
    ) -> (resident: Bytes, peak: Bytes) {
        guard entry.backend == .hunyuan else {
            return (entry.residentMemory, entry.peakMemory)
        }
        // hunyuan3d-swift benchmark table (shape models, octree decode):
        //   mini  fp16 3.82/5.20 GB · 8-bit 2.24/3.59 · 4-bit 1.40/2.74
        //   large fp16 4.93/6.37 GB · 4-bit 1.71/3.15
        let scale: Double
        switch configuration.quantize {
        case 4: scale = 0.42
        case 8: scale = 0.62
        default: scale = 1.0
        }
        let resident = Bytes(Int64(Double(entry.residentMemory.rawValue) * scale))
        let peak = Bytes(Int64(Double(entry.peakMemory.rawValue) * (0.45 + 0.55 * scale)))
        return (resident, peak)
    }

    /// Same budget idea as every other plan in the app: the safe model budget, less what other
    /// apps have wired beyond the allowance already baked into it.
    private func budget(otherAppsInUse: Bytes) -> Bytes {
        let allowance = Bytes(Int64(Double(profile.totalMemory.rawValue) * 0.10))
        let excess = max(.zero, otherAppsInUse - allowance)
        return max(.zero, profile.safeModelBudget - excess)
    }

    private func verdict(peak: Bytes, budget: Bytes) -> MemoryPlan.Verdict {
        if peak > profile.totalMemory { return .impossible }
        let utilization = peak.fraction(of: budget)
        if utilization < 0.80 { return .comfortable }
        if utilization < 1.00 { return .tight }
        return .willSwap
    }

    private func remediations(
        entry: MeshEntry, configuration: MeshConfiguration, peak: Bytes, budget: Bytes
    ) -> [MemoryPlan.Remediation] {
        guard peak.fraction(of: budget) >= 0.80 else { return [] }
        var result: [MemoryPlan.Remediation] = []

        if entry.supportsQuantization, configuration.quantize == nil {
            let (_, quantizedPeak) = memoryFigures(
                entry: entry,
                configuration: {
                    var c = configuration
                    c.quantize = 8
                    return c
                }()
            )
            result.append(MemoryPlan.Remediation(
                title: "Quantize the weights to 8-bit",
                detail: "Runs the shape model at 8-bit precision.",
                saving: max(.zero, peak - quantizedPeak),
                cost: "Slightly softer geometry; the benchmark calls it near-lossless.",
                kind: .lowerQuantization
            ))
        }
        if entry.backend == .trellis, configuration.pipelineType != "512" {
            result.append(MemoryPlan.Remediation(
                title: "Use the 512 pipeline",
                detail: "The only pipeline with measured figures, and the lightest.",
                saving: .gib(3),
                cost: "Less surface detail on large objects.",
                kind: .reduceContext
            ))
        }
        result.append(MemoryPlan.Remediation(
            title: "Close other applications",
            detail: "Frees wired memory other apps are holding.",
            saving: .zero,
            cost: "None.",
            kind: .closeApps
        ))
        return result
    }
}
