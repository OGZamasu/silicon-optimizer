import Foundation
import SiliconCatalog
import SiliconCore
import SiliconPlanner

/// A request to generate a 3D model from an image.
public struct MeshRequest: Sendable {
    /// The conditioning image.
    public var image: URL
    public var configuration: MeshConfiguration
    /// Directory the result files are written into.
    public var outputDirectory: URL
    /// Base name for the result files, without extension.
    public var baseName: String

    public init(
        image: URL, configuration: MeshConfiguration = MeshConfiguration(),
        outputDirectory: URL, baseName: String
    ) {
        self.image = image
        self.configuration = configuration
        self.outputDirectory = outputDirectory
        self.baseName = baseName
    }
}

/// Progress through a 3D generation.
public enum MeshEvent: Sendable {
    case stage(String)
    /// Fractional progress when the backend reports one; many stages do not.
    case progress(Double)
    case finished(MeshResult)
}

/// The files one generation produced. GLB and OBJ are both optional because backends differ:
/// Hunyuan writes only a GLB, LATO.2's main product is the OBJ.
public struct MeshResult: Sendable, Equatable, Identifiable {
    public var id: String { (glb ?? obj)?.path ?? baseName }
    public var baseName: String
    public var glb: URL?
    public var obj: URL?
    /// Sidecar textures, when the backend writes them next to the mesh.
    public var textures: [URL]
    public var sourceImage: URL
    public var modelName: String
    public var elapsed: TimeInterval

    /// The best file to hand to a viewer or external tool.
    public var primaryFile: URL? { glb ?? obj }

    public init(
        baseName: String, glb: URL?, obj: URL?, textures: [URL],
        sourceImage: URL, modelName: String, elapsed: TimeInterval
    ) {
        self.baseName = baseName
        self.glb = glb
        self.obj = obj
        self.textures = textures
        self.sourceImage = sourceImage
        self.modelName = modelName
        self.elapsed = elapsed
    }
}

/// A backend that turns images into meshes.
///
/// Same design as `ImageRuntime`, for the same reason: these are one-shot processes (or one
/// remote job), not resident servers, so they do not belong under `InferenceRuntime`.
public protocol MeshRuntime: Actor {
    var state: RuntimeState { get }
    func generate(_ request: MeshRequest) async throws
        -> AsyncThrowingStream<MeshEvent, any Error>
    func cancel() async
}

public enum MeshRuntimeError: Error, LocalizedError {
    case notInstalled(String)
    case generationFailed(String)
    case watchdog
    case noMeshProduced
    case remoteUnreachable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let detail):
            detail
        case .generationFailed(let message):
            message
        case .watchdog:
            "The macOS GPU watchdog interrupted the render and it produced an empty mesh. "
                + "This happens under display pressure — try again with the machine less busy, "
                + "or leave the render running without switching spaces."
        case .noMeshProduced:
            "The backend finished without writing a mesh."
        case .remoteUnreachable(let detail):
            detail
        case .cancelled:
            "Generation cancelled."
        }
    }
}

// MARK: - Installation discovery

/// What the 3D backends need on disk, resolved from the configured trellis2 base directory.
///
/// Everything lives under one base (default `/Volumes/T9/trellis2`) because that is how the
/// engines were set up: TRELLIS.2 in `trellis-mac/` with its venv, Hunyuan3D in
/// `hunyuan3d-swift/` with its weights.
public struct MeshInstallation: Sendable {
    public var isInstalled: Bool
    /// Human answer to "why not", or "what to expect" when installed.
    public var detail: String

    public init(isInstalled: Bool, detail: String) {
        self.isInstalled = isInstalled
        self.detail = detail
    }
}

public enum MeshLocator {

    /// TRELLIS.2: needs the repo, its venv, and notes whether the 13 GB weights are cached.
    public static func trellis(base: URL) -> MeshInstallation {
        let repo = base.appendingPathComponent("trellis-mac")
        let python = repo.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.fileExists(atPath: python.path) else {
            return MeshInstallation(
                isInstalled: false,
                detail: "trellis-mac venv not found under \(base.path). Set the trellis2 "
                    + "folder in Settings → 3D toolkit."
            )
        }
        let weights = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--microsoft--TRELLIS.2-4B")
        let weightsPresent = (try? FileManager.default.contentsOfDirectory(
            at: weights.appendingPathComponent("snapshots"), includingPropertiesForKeys: nil
        ))?.isEmpty == false
        return MeshInstallation(
            isInstalled: true,
            detail: weightsPresent
                ? "Ready — weights cached."
                : "Ready — first run downloads ~13 GB of weights."
        )
    }

    /// Hunyuan3D: needs a `hy3d` binary whose Metal library actually compiled — the xcodebuild
    /// products directory is the one that has it — plus the weight slot for the entry.
    public static func hunyuan(base: URL, weightsSlot: String) -> MeshInstallation {
        let package = base.appendingPathComponent("hunyuan3d-swift")
        guard hy3dExecutable(base: base) != nil else {
            return MeshInstallation(
                isInstalled: false,
                detail: "hy3d binary not built with its Metal library. Build it with: "
                    + "cd \(package.path) && xcodebuild -scheme hy3d -configuration Release "
                    + "-derivedDataPath .xcbuild build"
            )
        }
        let weights = package.appendingPathComponent("weights/\(weightsSlot)")
        let hasWeights = (try? FileManager.default.contentsOfDirectory(atPath: weights.path))?
            .contains { $0.hasSuffix(".safetensors") } ?? false
        guard hasWeights else {
            return MeshInstallation(
                isInstalled: false,
                detail: "Weights missing at weights/\(weightsSlot)."
            )
        }
        return MeshInstallation(isInstalled: true, detail: "Ready — native MLX.")
    }

    /// The hy3d binary to run. Prefers the xcodebuild products (which carry the compiled
    /// `mlx-swift_Cmlx.bundle`); the plain SwiftPM build is only accepted when a metallib
    /// bundle exists beside it, because without one every MLX call aborts at launch.
    public static func hy3dExecutable(base: URL) -> URL? {
        let package = base.appendingPathComponent("hunyuan3d-swift")
        let candidates = [
            package.appendingPathComponent(".xcbuild/Build/Products/Release/hy3d"),
            package.appendingPathComponent(".build/release/hy3d"),
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(
            atPath: candidate.path
        ) {
            let bundle = candidate.deletingLastPathComponent()
                .appendingPathComponent("mlx-swift_Cmlx.bundle")
            if FileManager.default.fileExists(atPath: bundle.path) {
                return candidate
            }
        }
        return nil
    }
}
