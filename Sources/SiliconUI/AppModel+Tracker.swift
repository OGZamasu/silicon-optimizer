import AppKit
import Foundation
import SiliconControl
import SiliconRuntime

/// Face tracking: the camera read as head pose and expression, then handed to whoever
/// should wear it — this app's own characters, and any VTuber application that speaks
/// VMC.
extension AppModel {

    public var trackerInstallation: TrackerRuntime.Installation {
        TrackerRuntime.installation()
    }

    public var trackerIsRunning: Bool {
        if case .tracking = trackerState { return true }
        return false
    }

    public var trackerFPS: Double {
        if case .tracking(_, let fps) = trackerState { return fps }
        return 0
    }

    public func startTracking() {
        guard trackerInstallation.isInstalled else {
            trackerError = trackerInstallation.detail
            return
        }
        trackerError = nil
        trackerState = .starting(stage: "Asking for the camera…")

        let options = TrackerRuntime.Options(
            cameraIndex: selectedCameraIndex,
            port: settings.trackerPort,
            mirror: trackerMirror,
            smoothing: trackerSmoothing,
            oscHost: settings.sendVMC
                ? settings.vmcHost.trimmingCharacters(in: .whitespaces) : "",
            oscPort: settings.vmcPort,
            trackBody: trackBody,
            trackHands: trackHands
        )
        let runtime = trackerRuntime ?? TrackerRuntime()
        trackerRuntime = runtime
        registerTrackerTermination()

        Task {
            guard await Self.requestCameraAccess() else {
                trackerState = .failed(message:
                    "Camera access was declined — allow Silicon Optimizer under System "
                    + "Settings → Privacy & Security → Camera.")
                return
            }
            await runtime.start(options) { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    self.trackerState = state
                    switch state {
                    case .tracking(let url, _):
                        // Tell any open overlay where to read the tracking from.
                        OverlayBroadcast.shared.setTrackerURL(url.absoluteString)
                    case .failed(let message):
                        self.trackerError = message
                        OverlayBroadcast.shared.setTrackerURL("")
                    case .idle, .starting:
                        break
                    }
                }
            }
        }
    }

    public func stopTracking() {
        guard let runtime = trackerRuntime else { return }
        trackerState = .idle
        OverlayBroadcast.shared.setTrackerURL("")
        Task { await runtime.stop() }
    }

    /// Sets up MediaPipe in its own environment and fetches the landmarker model from
    /// Google's own hosting for it.
    public func installTracker() {
        guard let bundled = Bundle.main.url(forResource: "tracker", withExtension: "py")
            ?? Bundle.main.resourceURL?.appendingPathComponent("tracker.py")
        else {
            trackerError = "The tracker script is missing from the app."
            return
        }
        let environment = TrackerRuntime.environment
        var steps: [RepairStep] = []

        if !FileManager.default.isExecutableFile(atPath: TrackerRuntime.python.path) {
            steps.append(RepairStep(
                executable: URL(fileURLWithPath: Self.faceCamPython),
                arguments: ["-m", "venv", environment.path],
                currentDirectory: nil,
                label: "Making its Python environment —"
            ))
        }
        steps.append(RepairStep(
            executable: environment.appendingPathComponent("bin/pip"),
            arguments: [
                "install", "--upgrade",
                // Pinned to the line that actually runs here: the 1.x wheels abort
                // inside the landmarker graph on this machine.
                "mediapipe==0.10.35", "python-osc", "opencv-python",
            ],
            currentDirectory: nil,
            label: "Installing MediaPipe —"
        ))
        steps.append(RepairStep(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: [
                "-sL", "--create-dirs",
                "-o", TrackerRuntime.model.path,
                TrackerRuntime.modelURL,
            ],
            currentDirectory: nil,
            label: "Fetching the face model —"
        ))
        steps.append(RepairStep(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: [
                "-sL", "--create-dirs",
                "-o", TrackerRuntime.poseModel.path,
                TrackerRuntime.poseModelURL,
            ],
            currentDirectory: nil,
            label: "Fetching the body model —"
        ))
        steps.append(RepairStep(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: [
                "-sL", "--create-dirs",
                "-o", TrackerRuntime.handModel.path,
                TrackerRuntime.handModelURL,
            ],
            currentDirectory: nil,
            label: "Fetching the hand model —"
        ))

        runRepair(id: "tracker-install", steps: steps) { [weak self] in
            try? TrackerRuntime.installScript(from: bundled)
            self?.refreshCameras()
        }
        try? TrackerRuntime.installScript(from: bundled)
    }

    private func registerTrackerTermination() {
        guard !trackerTerminationRegistered else { return }
        trackerTerminationRegistered = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let runtime = self?.trackerRuntime else { return }
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
