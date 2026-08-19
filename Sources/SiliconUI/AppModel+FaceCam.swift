import AVFoundation
import AppKit
import Foundation
import SiliconRuntime

/// The live face camera: your camera in, the character's face out, straight into OBS.
extension AppModel {

    public var faceCamInstallation: FaceCamRuntime.Installation {
        FaceCamRuntime.installation()
    }

    public var faceCamIsLive: Bool {
        if case .live = faceCamState { return true }
        return false
    }

    /// The address to hand OBS. Same shape as the persona overlay: a page, not a raw
    /// stream, because a Browser Source needs something to render.
    public var faceCamURL: URL? {
        if case .live(let url, _) = faceCamState { return url }
        return nil
    }

    public var faceCamFPS: Double {
        if case .live(_, let fps) = faceCamState { return fps }
        return 0
    }

    /// Cameras the machine can actually offer, in the order OpenCV will index them —
    /// which is the order AVFoundation lists them, so the picker's choice matches
    /// what the engine opens.
    public func refreshCameras() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        )
        availableCameras = discovery.devices.map(\.localizedName)
        if selectedCameraIndex >= availableCameras.count {
            selectedCameraIndex = 0
        }
    }

    /// Starts swapping. The face comes from the selected character's portrait — the
    /// same picture that performs on the overlay — so a character looks like itself
    /// whether it is speaking a written line or wearing your expressions.
    public func startFaceCam() {
        guard let persona = selectedPersona, let portrait = persona.portraitURL else {
            faceCamError = "Pick a character with a portrait first — that face is what "
                + "the camera wears."
            return
        }
        guard faceCamInstallation.isInstalled else {
            faceCamError = faceCamInstallation.detail
            return
        }
        faceCamError = nil
        faceCamState = .starting(stage: "Asking for the camera…")

        let options = FaceCamRuntime.Options(
            sourceImage: portrait,
            cameraIndex: selectedCameraIndex,
            port: settings.faceCamPort,
            mirror: faceCamMirror,
            mouthMask: faceCamMouthMask,
            manyFaces: false,
            opacity: faceCamOpacity
        )
        let runtime = faceCamRuntime ?? FaceCamRuntime()
        faceCamRuntime = runtime
        registerFaceCamTermination()

        Task {
            // The engine opens the camera in a child process, which inherits this
            // app's permission — so the app has to be the one that asks.
            guard await Self.requestCameraAccess() else {
                faceCamState = .failed(message:
                    "Camera access was declined — allow Silicon Optimizer under System "
                    + "Settings → Privacy & Security → Camera.")
                faceCamError = "Camera access was declined."
                return
            }
            await runtime.start(options) { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    self.faceCamState = state
                    if case .failed(let message) = state { self.faceCamError = message }
                }
            }
        }
    }

    static func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    public func stopFaceCam() {
        guard let runtime = faceCamRuntime else { return }
        faceCamState = .idle
        Task { await runtime.stop() }
    }

    /// Sets up Deep-Live-Cam in its own environment: its own Python, its own clone,
    /// its own models. Kept apart from the other tools because its dependencies pin
    /// versions the audio and image stacks disagree with.
    public func installFaceCam() {
        guard let bundled = Bundle.main.url(forResource: "facecam", withExtension: "py")
            ?? Bundle.main.resourceURL?.appendingPathComponent("facecam.py")
        else {
            faceCamError = "The camera driver is missing from the app."
            return
        }
        let environment = FaceCamRuntime.environment
        let repository = FaceCamRuntime.repository
        var steps: [RepairStep] = []

        if !FileManager.default.isExecutableFile(atPath: FaceCamRuntime.python.path) {
            steps.append(RepairStep(
                executable: URL(fileURLWithPath: Self.faceCamPython),
                arguments: ["-m", "venv", environment.path],
                currentDirectory: nil,
                label: "Making its Python environment —"
            ))
        }
        if !FileManager.default.fileExists(atPath: repository.path) {
            steps.append(RepairStep(
                executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: [
                    "clone", "--depth", "1",
                    "https://github.com/hacksider/Deep-Live-Cam.git", repository.path,
                ],
                currentDirectory: nil,
                label: "Downloading Deep-Live-Cam —"
            ))
        }
        steps.append(RepairStep(
            executable: environment.appendingPathComponent("bin/pip"),
            arguments: [
                "install", "-r", repository.appendingPathComponent("requirements.txt").path,
            ],
            currentDirectory: nil,
            label: "Installing its tools (several minutes) —"
        ))
        // The project downloads its own weights, through its own pre-check, so the
        // model comes from where upstream says it does.
        steps.append(RepairStep(
            executable: FaceCamRuntime.python,
            arguments: [
                "-c",
                "import sys; sys.path.insert(0, '\(repository.path)'); "
                + "import modules.globals as g; "
                + "g.execution_providers=['CoreMLExecutionProvider','CPUExecutionProvider']; "
                + "g.headless=True; "
                + "from modules.processors.frame import face_swapper; "
                + "face_swapper.pre_check()",
            ],
            currentDirectory: repository,
            label: "Fetching the face model (550 MB) —"
        ))

        runRepair(id: "facecam-install", steps: steps) { [weak self] in
            try? FaceCamRuntime.installDriver(from: bundled)
            self?.refreshCameras()
        }
        // The driver is ours and tiny; put it in place immediately so a rerun of the
        // installer is never needed just to pick up a new copy of it.
        try? FaceCamRuntime.installDriver(from: bundled)
    }

    /// Deep-Live-Cam's dependencies have no wheels for the newest Python, so its
    /// environment is built on the newest one they do support.
    static var faceCamPython: String {
        let candidates = [
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/usr/local/bin/python3.13",
            "/usr/bin/python3",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/bin/python3"
    }

    /// The engine is a child process; nothing stops it for us when the app quits.
    private func registerFaceCamTermination() {
        guard !faceCamTerminationRegistered else { return }
        faceCamTerminationRegistered = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let runtime = self?.faceCamRuntime else { return }
                // Termination is synchronous; a detached task would not outrun exit.
                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    await runtime.stop()
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 2)
            }
        }
    }
}
