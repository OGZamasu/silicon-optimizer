import Foundation

/// The live face camera: Deep-Live-Cam's pipeline, driven headlessly, with the picture
/// served as MJPEG for OBS to pick up.
///
/// The project is AGPL-3.0 and ships its own desktop UI. Rather than copying any of it,
/// this clones it into a private environment and runs it as a separate process through
/// a small driver script, which keeps the licences apart and means upstream fixes
/// arrive with a `git pull` rather than a port.
public actor FaceCamRuntime {

    public enum State: Sendable, Equatable {
        case idle
        case starting(stage: String)
        case live(url: URL, fps: Double)
        case failed(message: String)
    }

    /// What has to exist before the camera can run.
    public struct Installation: Sendable {
        public enum Missing: Sendable, Equatable {
            case nothing
            case environment
            case models
        }
        public var missing: Missing
        public var detail: String
        public var isInstalled: Bool { missing == .nothing }
    }

    private var process: ServerProcess?
    private(set) var port: Int = 0

    public init() {}

    // MARK: - Locations

    public nonisolated static var environment: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".silicon-facecam")
    }

    public nonisolated static var python: URL {
        environment.appendingPathComponent("bin/python3")
    }

    public nonisolated static var repository: URL {
        environment.appendingPathComponent("Deep-Live-Cam")
    }

    /// The weights the swapper needs, downloaded by the project's own pre-check.
    public nonisolated static var swapperModel: URL {
        repository.appendingPathComponent("models/inswapper_128.onnx")
    }

    /// The driver script, copied out of the app bundle so the environment owns a
    /// stable path even when the app is replaced mid-stream.
    public nonisolated static var driverScript: URL {
        environment.appendingPathComponent("facecam.py")
    }

    public nonisolated static func installation() -> Installation {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: python.path),
              manager.fileExists(atPath: repository.appendingPathComponent(
                  "modules/processors/frame/face_swapper.py"
              ).path)
        else {
            return Installation(
                missing: .environment,
                detail: "The live face camera isn't set up yet. It downloads "
                    + "Deep-Live-Cam and about 2 GB of tools and models."
            )
        }
        guard manager.fileExists(atPath: swapperModel.path) else {
            return Installation(
                missing: .models,
                detail: "The face model hasn't finished downloading yet (about 550 MB)."
            )
        }
        return Installation(missing: .nothing, detail: "Ready.")
    }

    /// Copies the driver next to the environment it drives.
    public nonisolated static func installDriver(from bundled: URL) throws {
        try FileManager.default.createDirectory(
            at: environment, withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: driverScript.path) {
            try FileManager.default.removeItem(at: driverScript)
        }
        try FileManager.default.copyItem(at: bundled, to: driverScript)
    }

    // MARK: - Lifecycle

    public struct Options: Sendable {
        public var sourceImage: URL
        public var cameraIndex: Int
        public var port: Int
        public var mirror: Bool
        public var mouthMask: Bool
        public var manyFaces: Bool
        public var opacity: Double

        public init(
            sourceImage: URL, cameraIndex: Int = 0, port: Int = 8791,
            mirror: Bool = true, mouthMask: Bool = true,
            manyFaces: Bool = false, opacity: Double = 1
        ) {
            self.sourceImage = sourceImage
            self.cameraIndex = cameraIndex
            self.port = port
            self.mirror = mirror
            self.mouthMask = mouthMask
            self.manyFaces = manyFaces
            self.opacity = opacity
        }
    }

    /// Starts the camera, reporting progress until it is live or has failed.
    public func start(
        _ options: Options, onState: @escaping @Sendable (State) -> Void
    ) async {
        await stop()
        let installation = Self.installation()
        guard installation.isInstalled else {
            onState(.failed(message: installation.detail))
            return
        }
        guard FileManager.default.fileExists(atPath: Self.driverScript.path) else {
            onState(.failed(message: "The camera driver is missing from the app."))
            return
        }

        port = options.port
        var arguments = [
            Self.driverScript.path,
            "--repo", Self.repository.path,
            "--source", options.sourceImage.path,
            "--camera", String(options.cameraIndex),
            "--port", String(options.port),
            "--opacity", String(format: "%.2f", options.opacity),
        ]
        if options.mirror { arguments.append("--mirror") }
        if options.mouthMask { arguments.append("--mouth-mask") }
        if options.manyFaces { arguments.append("--many-faces") }

        let process = ServerProcess()
        self.process = process
        onState(.starting(stage: "Starting the face engine…"))

        do {
            try await process.start(
                executable: Self.python,
                arguments: arguments,
                environment: [
                    "PYTHONUNBUFFERED": "1",
                    // Keras picks a backend at import; without this the content
                    // check drags in a framework that has no wheels here.
                    "KERAS_BACKEND": "torch",
                ],
                onLogLine: { line in
                    if let state = Self.interpret(line, port: options.port) {
                        onState(state)
                    }
                }
            )
        } catch {
            onState(.failed(message: "The face camera could not start."))
        }
    }

    /// Turns the driver's output into something worth showing. It prints its stages,
    /// its frame rate, and one `fatal:` line when it gives up.
    static func interpret(_ line: String, port: Int) -> State? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("ready: ") {
            let text = String(trimmed.dropFirst("ready: ".count))
            return URL(string: text).map { .live(url: $0, fps: 0) }
        }
        if trimmed.hasPrefix("fps: "), let fps = Double(trimmed.dropFirst(5)) {
            return URL(string: "http://127.0.0.1:\(port)/").map { .live(url: $0, fps: fps) }
        }
        if trimmed.hasPrefix("fatal: ") {
            return .failed(message: Self.explain(String(trimmed.dropFirst("fatal: ".count))))
        }
        if trimmed.hasPrefix("stage: ") {
            return .starting(stage: String(trimmed.dropFirst("stage: ".count)))
        }
        return nil
    }

    /// The driver's terse reasons, said the way a person would.
    static func explain(_ reason: String) -> String {
        switch reason {
        case let text where text.contains("camera unavailable"):
            "The camera didn't open. Another app may be using it, or Silicon "
                + "Optimizer may need permission under System Settings → Privacy "
                + "& Security → Camera."
        case let text where text.contains("no face in source"):
            "No face was found in that portrait — the swap needs a clear, "
                + "front-facing face to copy from."
        case let text where text.contains("unreadable source"):
            "That portrait couldn't be read as an image."
        case let text where text.contains("content check"):
            "Deep-Live-Cam's content check refused that image."
        default:
            reason
        }
    }

    public func stop() async {
        await process?.terminate()
        process = nil
    }

    public var isRunning: Bool {
        get async { await process?.isRunning ?? false }
    }
}
