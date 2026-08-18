import Foundation
import SiliconCore

/// How a 3D model is executed. Unlike diffusion, the 3D backends are not one runtime with many
/// checkpoints — each engine is its own program with its own invocation, so the entry carries
/// which engine runs it.
public enum MeshBackend: String, Sendable, Codable {
    /// TRELLIS.2 running in the local Python venv on MPS.
    case trellis
    /// Hunyuan3D 2 via the native MLX-Swift `hy3d` binary.
    case hunyuan
    /// LATO.2 running as a remote HTTP service on a CUDA machine.
    case latoRemote
    /// In the catalog for completeness, but no runner is wired up yet.
    case unsupported
}

/// One image-to-3D model. Memory figures are measured, not derived: 3D pipelines mix sparse
/// convolutions, octree decoders and mesh baking whose costs do not follow a formula the way
/// diffusion phases do, so honest numbers here come from benchmark tables and logged runs.
public struct MeshEntry: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var author: String
    public var license: String
    public var summary: String
    public var backend: MeshBackend
    /// Size of the weights on disk (or to download).
    public var weightsSize: Bytes
    /// Weights resident in memory once loaded.
    public var residentMemory: Bytes
    /// Measured generation peak, at the entry's default configuration.
    public var peakMemory: Bytes
    /// Honest wall-clock expectation, stated as a range because thermals can stretch it.
    public var typicalDuration: String
    /// What comes out: formats and whether it is textured.
    public var outputs: String
    public var isTextured: Bool
    public var rating: Int
    public var defaultSteps: Int?
    /// Which knobs this backend actually has. Showing a steps control for a backend that
    /// ignores it would be worse than hiding it.
    public var supportsPipelineType: Bool
    public var supportsTextureSize: Bool
    public var supportsSteps: Bool
    public var supportsQuantization: Bool
    public var supportsVertexBudget: Bool
    /// Shown when the backend is not ready to run: the one command or setting that fixes it.
    public var setupHint: String?

    public init(
        id: String, name: String, author: String, license: String, summary: String,
        backend: MeshBackend, weightsSize: Bytes, residentMemory: Bytes, peakMemory: Bytes,
        typicalDuration: String, outputs: String, isTextured: Bool, rating: Int,
        defaultSteps: Int? = nil,
        supportsPipelineType: Bool = false, supportsTextureSize: Bool = false,
        supportsSteps: Bool = false, supportsQuantization: Bool = false,
        supportsVertexBudget: Bool = false, setupHint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.license = license
        self.summary = summary
        self.backend = backend
        self.weightsSize = weightsSize
        self.residentMemory = residentMemory
        self.peakMemory = peakMemory
        self.typicalDuration = typicalDuration
        self.outputs = outputs
        self.isTextured = isTextured
        self.rating = rating
        self.defaultSteps = defaultSteps
        self.supportsPipelineType = supportsPipelineType
        self.supportsTextureSize = supportsTextureSize
        self.supportsSteps = supportsSteps
        self.supportsQuantization = supportsQuantization
        self.supportsVertexBudget = supportsVertexBudget
        self.setupHint = setupHint
    }
}

public enum MeshCatalog {

    public static let all: [MeshEntry] = [
        trellis2, hunyuanMini, hunyuanTurbo, lato2, tripoSR, stableFast3D,
    ]

    public static func entry(id: String) -> MeshEntry? {
        all.first { $0.id == id }
    }

    /// TRELLIS.2 4B — the quality pick. Peak and timings from the trellis-mac README's M4 Pro
    /// benchmark and a measured run on this machine's M3 Max; both agree on ~18 GB peak.
    public static let trellis2 = MeshEntry(
        id: "trellis2-4b",
        name: "TRELLIS.2 4B",
        author: "Microsoft",
        license: "MIT",
        summary: "The quality pick: a full textured PBR mesh from one image. Runs locally on "
            + "Metal through the trellis-mac port. First run downloads about 13 GB of weights.",
        backend: .trellis,
        weightsSize: .gib(13),
        residentMemory: .gib(13),
        peakMemory: Bytes.gib(18),
        typicalDuration: "3–10 min",
        outputs: "Textured GLB + OBJ",
        isTextured: true,
        rating: 5,
        supportsPipelineType: true,
        supportsTextureSize: true
    )

    /// Hunyuan3D 2 mini — the fast pick. Figures are the hunyuan3d-swift benchmark table:
    /// 20.9 s and ~5.6 GB peak at 30 steps; fp16 weights are 3.82 GB resident.
    public static let hunyuanMini = MeshEntry(
        id: "hunyuan3d-2-mini",
        name: "Hunyuan3D 2 mini",
        author: "Tencent",
        license: "Tencent Hunyuan Community",
        summary: "The fast pick: clean geometry in about twenty seconds, native MLX. No "
            + "texture — pair it with TRELLIS.2 when you need one, or take it straight to "
            + "your modelling tool.",
        backend: .hunyuan,
        weightsSize: .gib(3) + .mib(614),
        residentMemory: Bytes.mib(3911),
        peakMemory: Bytes.mib(5325),
        typicalDuration: "20 s–3 min",
        outputs: "GLB (geometry only)",
        isTextured: false,
        rating: 4,
        defaultSteps: 30,
        supportsSteps: true,
        supportsQuantization: true
    )

    /// Hunyuan3D 2 turbo — the large shape model distilled to 8 steps. Weights slot exists in
    /// the hunyuan3d-swift layout but is not downloaded by default.
    public static let hunyuanTurbo = MeshEntry(
        id: "hunyuan3d-2-turbo",
        name: "Hunyuan3D 2 turbo",
        author: "Tencent",
        license: "Tencent Hunyuan Community",
        summary: "The large shape model, distilled to finish in 8 steps — better geometry than "
            + "mini at nearly the same speed, for a bigger download.",
        backend: .hunyuan,
        weightsSize: .gib(5),
        residentMemory: Bytes.mib(5049),
        peakMemory: Bytes.mib(7475),
        typicalDuration: "20 s–3 min",
        outputs: "GLB (geometry only)",
        isTextured: false,
        rating: 4,
        defaultSteps: 8,
        supportsSteps: true,
        supportsQuantization: true,
        setupHint: "hf download zimengxiong/hunyuan3d-mlx-shape-large "
            + "--local-dir <trellis2>/hunyuan3d-swift/weights/shape-large"
    )

    /// LATO.2 — retopology on a remote CUDA box. The service chains TRELLIS densification
    /// into LATO.2's vertex-budgeted clean-mesh flow, so what comes back is a low-poly mesh
    /// ready for editing rather than a dense scan-like surface.
    public static let lato2 = MeshEntry(
        id: "lato-2",
        name: "LATO.2 (remote)",
        author: "LoHhhha et al.",
        license: "MIT",
        summary: "Clean, low-poly meshes with a vertex budget you choose — the output that "
            + "goes straight into a game engine or CAD. CUDA-only, so it runs on your LATO.2 "
            + "service machine; this Mac just sends the image and receives the mesh.",
        backend: .latoRemote,
        weightsSize: .gib(3) + .mib(512),
        residentMemory: .zero,
        peakMemory: .zero,
        typicalDuration: "1–5 min (remote)",
        outputs: "Low-poly OBJ + dense GLB",
        isTextured: false,
        rating: 4,
        supportsVertexBudget: true,
        setupHint: "Set the LATO.2 service URL in Settings → 3D toolkit. The service plan "
            + "lives at /Volumes/T9/LATO.2/LATO2-SETUP-PLAN.md."
    )

    /// TripoSR — catalogued so the comparison is visible, but no runner is wired yet.
    public static let tripoSR = MeshEntry(
        id: "triposr",
        name: "TripoSR",
        author: "Stability AI + Tripo",
        license: "MIT",
        summary: "A small single-shot reconstructor: rough mesh in seconds from ~1.5 GB of "
            + "weights. Lower fidelity than everything above — worth having for silhouette "
            + "drafts once a runner is wired up.",
        backend: .unsupported,
        weightsSize: .gib(1) + .mib(512),
        residentMemory: .gib(2),
        peakMemory: .gib(4),
        typicalDuration: "seconds",
        outputs: "OBJ (geometry only)",
        isTextured: false,
        rating: 2,
        setupHint: "No local runner yet — the catalog entry marks the intent."
    )

    /// Stable Fast 3D — same situation as TripoSR.
    public static let stableFast3D = MeshEntry(
        id: "stable-fast-3d",
        name: "Stable Fast 3D",
        author: "Stability AI",
        license: "Stability Community",
        summary: "UV-unwrapped, textured meshes in under a second on datacenter GPUs; on Apple "
            + "Silicon it needs a port that does not exist yet. Catalogued for the roadmap.",
        backend: .unsupported,
        weightsSize: .gib(2),
        residentMemory: .gib(3),
        peakMemory: .gib(5),
        typicalDuration: "under a minute",
        outputs: "Textured GLB",
        isTextured: true,
        rating: 3,
        setupHint: "No local runner yet — the catalog entry marks the intent."
    )
}
