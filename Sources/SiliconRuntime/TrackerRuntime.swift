import Foundation

/// Face tracking: the camera turned into head pose and expression values.
///
/// Runs MediaPipe's Face Landmarker in its own environment and publishes what it reads
/// two ways at once — JSON for this app's own 2D characters, and the VMC protocol over
/// OSC for the VTuber applications that already know how to wear it. That second half
/// matters: rigging Live2D and VRM models is a solved problem with mature tools, and
/// the useful thing to be in that world is a good tracker, not another renderer.
public actor TrackerRuntime {

    public enum State: Sendable, Equatable {
        case idle
        case starting(stage: String)
        case tracking(url: URL, fps: Double)
        case failed(message: String)
    }

    public struct Installation: Sendable {
        public var isInstalled: Bool
        public var detail: String
    }

    private var process: ServerProcess?

    public init() {}

    // MARK: - Locations

    public nonisolated static var environment: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".silicon-tracker")
    }

    public nonisolated static var python: URL {
        environment.appendingPathComponent("bin/python3")
    }

    public nonisolated static var model: URL {
        environment.appendingPathComponent("models/face_landmarker.task")
    }

    public nonisolated static var poseModel: URL {
        environment.appendingPathComponent("models/pose_landmarker.task")
    }

    public nonisolated static var script: URL {
        environment.appendingPathComponent("tracker.py")
    }

    /// Where the landmarker model comes from — Google's own hosting for it.
    public nonisolated static let modelURL =
        "https://storage.googleapis.com/mediapipe-models/face_landmarker/"
        + "face_landmarker/float16/1/face_landmarker.task"
    public nonisolated static let poseModelURL =
        "https://storage.googleapis.com/mediapipe-models/pose_landmarker/"
        + "pose_landmarker_lite/float16/latest/pose_landmarker_lite.task"

    public nonisolated static func installation() -> Installation {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: python.path) else {
            return Installation(
                isInstalled: false,
                detail: "Face tracking isn't set up yet — it needs MediaPipe, about "
                    + "200 MB."
            )
        }
        guard manager.fileExists(atPath: model.path) else {
            return Installation(
                isInstalled: false,
                detail: "The tracking model hasn't been downloaded yet (4 MB)."
            )
        }
        return Installation(isInstalled: true, detail: "Ready.")
    }

    public nonisolated static func installScript(from bundled: URL) throws {
        try FileManager.default.createDirectory(
            at: environment, withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: script.path) {
            try FileManager.default.removeItem(at: script)
        }
        try FileManager.default.copyItem(at: bundled, to: script)
    }

    // MARK: - Lifecycle

    public struct Options: Sendable {
        public var cameraIndex: Int
        public var port: Int
        public var mirror: Bool
        public var smoothing: Double
        /// Where to send VMC, when the user wants a rigged model driven too.
        public var oscHost: String
        public var oscPort: Int
        /// Whether to read the upper body too — shoulders, lean, hands.
        public var trackBody: Bool

        public init(
            cameraIndex: Int = 0, port: Int = 8792, mirror: Bool = true,
            smoothing: Double = 0.45, oscHost: String = "", oscPort: Int = 39539,
            trackBody: Bool = false
        ) {
            self.cameraIndex = cameraIndex
            self.port = port
            self.mirror = mirror
            self.smoothing = smoothing
            self.oscHost = oscHost
            self.oscPort = oscPort
            self.trackBody = trackBody
        }
    }

    public func start(
        _ options: Options, onState: @escaping @Sendable (State) -> Void
    ) async {
        await stop()
        let installation = Self.installation()
        guard installation.isInstalled else {
            onState(.failed(message: installation.detail))
            return
        }
        guard FileManager.default.fileExists(atPath: Self.script.path) else {
            onState(.failed(message: "The tracker script is missing from the app."))
            return
        }

        var arguments = [
            Self.script.path,
            "--model", Self.model.path,
            "--camera", String(options.cameraIndex),
            "--port", String(options.port),
            "--smoothing", String(format: "%.2f", options.smoothing),
        ]
        if options.mirror { arguments.append("--mirror") }
        if options.trackBody,
           FileManager.default.fileExists(atPath: Self.poseModel.path) {
            arguments += ["--pose-model", Self.poseModel.path]
        }
        if !options.oscHost.isEmpty {
            arguments += [
                "--osc-host", options.oscHost,
                "--osc-port", String(options.oscPort),
            ]
        }

        let process = ServerProcess()
        self.process = process
        onState(.starting(stage: "Starting the tracker…"))
        do {
            try await process.start(
                executable: Self.python,
                arguments: arguments,
                environment: ["PYTHONUNBUFFERED": "1"],
                onLogLine: { line in
                    if let state = Self.interpret(line, port: options.port) {
                        onState(state)
                    }
                }
            )
        } catch {
            onState(.failed(message: "Face tracking could not start."))
        }
    }

    static func interpret(_ line: String, port: Int) -> State? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("ready: ") {
            return URL(string: String(trimmed.dropFirst("ready: ".count)))
                .map { .tracking(url: $0, fps: 0) }
        }
        if trimmed.hasPrefix("fps: "), let fps = Double(trimmed.dropFirst(5)) {
            return URL(string: "http://127.0.0.1:\(port)/state")
                .map { .tracking(url: $0, fps: fps) }
        }
        if trimmed.hasPrefix("fatal: camera unavailable") {
            return .failed(message:
                "The camera didn't open. Another app may be using it, or Silicon "
                + "Optimizer may need permission under System Settings → Privacy & "
                + "Security → Camera.")
        }
        if trimmed.hasPrefix("fatal: ") {
            return .failed(message: String(trimmed.dropFirst("fatal: ".count)))
        }
        if trimmed.hasPrefix("stage: ") {
            return .starting(stage: String(trimmed.dropFirst("stage: ".count)))
        }
        return nil
    }

    public func stop() async {
        await process?.terminate()
        process = nil
    }
}
