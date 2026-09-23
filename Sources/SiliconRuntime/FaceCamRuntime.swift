import Foundation
import SiliconControl

/// The live face camera: Deep-Live-Cam's pipeline, driven headlessly, with the picture
/// served as MJPEG for OBS to pick up.
///
/// The project is AGPL-3.0 and ships its own desktop UI. Rather than copying any of it,
/// this fetches it into a private environment and runs it as a separate process through
/// a small driver script, which keeps the licences apart and means upstream fixes
/// arrive by moving the reviewed pin in `PinnedInstall` rather than by a port.
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

    /// The weights the swapper needs, fetched at install at a reviewed digest.
    public nonisolated static var swapperModel: URL {
        repository.appendingPathComponent("models/inswapper_128.onnx")
    }

    /// Where insightface looks for the face analyser pack the project uses.
    public nonisolated static var faceAnalyserModels: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".insightface/models/buffalo_l", isDirectory: true)
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

    /// The install, as commands. Deep-Live-Cam at its reviewed commit, checked before use;
    /// its hash-locked dependencies for this Python, build tools first so insightface (source
    /// only) builds with locked setuptools, Cython and NumPy rather than downloaded ones; and
    /// the weights, fetched at a reviewed revision and digest before the project's own
    /// downloader — which takes them from a moving branch without checking certificates on
    /// macOS — would. `basePython` makes the environment when there is none.
    public nonisolated static func installPlan(
        basePython: URL, git: URL, locks: URL = PinnedInstall.defaultLockRoot(),
        environment: URL = FaceCamRuntime.environment,
        faceAnalyserModels: URL = FaceCamRuntime.faceAnalyserModels
    ) throws -> [PinnedInstall.Command] {
        let source = PinnedInstall.deepLiveCam
        let python = environment.appendingPathComponent("bin/python3")
        let repository = environment.appendingPathComponent("Deep-Live-Cam")
        let swapperModel = repository.appendingPathComponent("models/inswapper_128.onnx")
        let existing = FileManager.default.isExecutableFile(atPath: python.path)
        let version = existing
            ? PinnedInstall.pythonVersion(ofVirtualEnvironment: environment)
            : PinnedInstall.pythonVersion(ofInterpreter: basePython)
        guard let version, PinnedInstall.deepLiveCamPythons.contains(version) else {
            throw PinnedInstall.PlanError.unsupportedPython(
                tool: source.name, found: version, supported: PinnedInstall.deepLiveCamPythons
            )
        }

        var commands: [PinnedInstall.Command] = []
        if !existing {
            commands.append(PinnedInstall.Command(
                label: "Making its Python environment",
                executable: basePython, arguments: ["-m", "venv", environment.path]
            ))
        }
        commands += PinnedInstall.fetch(source, into: repository, git: git)
        commands.append(PinnedInstall.pipInstall(
            python: python,
            lock: PinnedInstall.lock("build", for: source, python: version, in: locks),
            label: "Installing its build tools"
        ))
        commands.append(PinnedInstall.pipInstall(
            python: python,
            lock: PinnedInstall.lock("requirements", for: source, python: version, in: locks),
            label: "Installing its tools (several minutes)",
            noBuildIsolation: true
        ))
        commands.append(PinnedInstall.fetch(
            PinnedInstall.deepLiveCamSwapper, to: swapperModel,
            label: "Fetching the face model (550 MB)"
        ))
        for file in PinnedInstall.deepLiveCamFaceAnalyser {
            let name = (file.path as NSString).lastPathComponent
            commands.append(PinnedInstall.fetch(
                file, to: faceAnalyserModels.appendingPathComponent(name),
                label: "Fetching the face analyser (340 MB): \(name)"
            ))
        }
        // Loads the swapper the way the driver will; with the model in place, the project's
        // pre-check finds it and downloads nothing.
        commands.append(PinnedInstall.Command(
            label: "Checking the face engine loads",
            executable: python,
            arguments: [
                "-c",
                "import sys; sys.path.insert(0, '\(repository.path)'); "
                    + "import modules.globals as g; "
                    + "g.execution_providers=['CoreMLExecutionProvider','CPUExecutionProvider']; "
                    + "g.headless=True; "
                    + "from modules.processors.frame import face_swapper; "
                    + "sys.exit(0 if face_swapper.pre_check() else 1)",
            ],
            workingDirectory: repository
        ))
        return commands
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

        let token = UUID().uuidString
        let process = ServerProcess()
        self.process = process
        onState(.starting(stage: "Starting the face engine…"))

        do {
            try await process.start(
                executable: Self.python,
                arguments: arguments,
                environment: [
                    "PYTHONUNBUFFERED": "1",
                    "SILICON_SENSOR_TOKEN": token,
                    // Keras picks a backend at import; without this the content
                    // check drags in a framework that has no wheels here.
                    "KERAS_BACKEND": "torch",
                ],
                onLogLine: { line in
                    if let state = Self.interpret(line, port: options.port, token: token) {
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
    static func interpret(_ line: String, port: Int, token: String = "") -> State? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("ready: ") {
            return sensorURL(port: port, token: token).map { .live(url: $0, fps: 0) }
        }
        if trimmed.hasPrefix("fps: "), let fps = Double(trimmed.dropFirst(5)) {
            return sensorURL(port: port, token: token).map { .live(url: $0, fps: fps) }
        }
        if trimmed.hasPrefix("fatal: ") {
            return .failed(message: Self.explain(String(trimmed.dropFirst("fatal: ".count))))
        }
        if trimmed.hasPrefix("stage: ") {
            return .starting(stage: String(trimmed.dropFirst("stage: ".count)))
        }
        return nil
    }

    static func sensorURL(port: Int, token: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/"
        if !token.isEmpty { components.queryItems = [URLQueryItem(name: "token", value: token)] }
        return components.url
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
