import AVFoundation
import AppKit
import SwiftUI

/// Records a performance from the camera.
///
/// Photoreal animation needs a video of a face to copy motion from; asking someone to
/// go and film one in another app, then come back and find the file, is a poor answer
/// when the camera is already right there.
@MainActor
@Observable
final class TakeRecorder: NSObject {

    enum State: Equatable {
        case idle
        case preparing
        case recording(seconds: Int)
        case finished(url: URL)
        case failed(message: String)
    }

    private(set) var state: State = .idle
    /// The live session, handed to the preview so the person can see themselves —
    /// recording a performance blind is how you find out afterwards you were off frame.
    private(set) var session: AVCaptureSession?

    private var output: AVCaptureMovieFileOutput?
    private var timer: Timer?
    private var startedAt: Date?
    private var completion: ((URL) -> Void)?

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var elapsedLabel: String {
        if case .recording(let seconds) = state {
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        }
        return ""
    }

    /// Opens the camera and starts previewing, without recording yet.
    func prepare(cameraIndex: Int) async {
        guard session == nil else { return }
        state = .preparing
        guard await AppModel.requestCameraAccess() else {
            state = .failed(message:
                "Camera access was declined — allow Silicon Optimizer under System "
                + "Settings → Privacy & Security → Camera.")
            return
        }

        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices
        guard let device = devices.indices.contains(cameraIndex)
            ? devices[cameraIndex] : devices.first,
            let input = try? AVCaptureDeviceInput(device: device)
        else {
            state = .failed(message: "No camera was available.")
            return
        }

        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard session.canAddInput(input) else {
            state = .failed(message: "That camera could not be opened.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMovieFileOutput()
        guard session.canAddOutput(output) else {
            state = .failed(message: "The recorder could not attach to the camera.")
            return
        }
        session.addOutput(output)

        self.session = session
        self.output = output
        // Starting the session blocks while the camera warms up, so it happens off
        // the main actor. AVCaptureSession is not Sendable, so it travels boxed.
        let box = SessionBox(session: session)
        await Task.detached { box.session.startRunning() }.value
        state = .idle
    }

    func start(into directory: URL, onFinish: @escaping (URL) -> Void) {
        guard let output, !output.isRecording else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let destination = directory.appendingPathComponent(Self.filename())
        completion = onFinish
        startedAt = Date()
        state = .recording(seconds: 0)
        output.startRecording(to: destination, recordingDelegate: self)

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let startedAt = self.startedAt, self.isRecording else { return }
                self.state = .recording(seconds: Int(Date().timeIntervalSince(startedAt)))
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        output?.stopRecording()
    }

    /// Releases the camera. Left running it would keep the light on and hold the
    /// device against the tracker and the face camera, which want it too.
    func close() {
        stop()
        if let session {
            let box = SessionBox(session: session)
            Task.detached { box.session.stopRunning() }
        }
        session = nil
        output = nil
        state = .idle
    }

    static func filename(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "silicon-take-\(formatter.string(from: date))-"
            + "\(UUID().uuidString.prefix(6)).mov"
    }
}

extension TakeRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: (any Error)?
    ) {
        Task { @MainActor in
            // A stopped recording reports "cancelled" through the same path as a real
            // failure; the file existing is what actually distinguishes them.
            let exists = FileManager.default.fileExists(atPath: outputFileURL.path)
            if let error, !exists {
                state = .failed(message: error.localizedDescription)
                return
            }
            state = .finished(url: outputFileURL)
            completion?(outputFileURL)
            completion = nil
        }
    }
}

/// AVCaptureSession is thread-safe for start and stop but not marked Sendable;
/// this carries one across an isolation boundary for exactly those two calls.
private struct SessionBox: @unchecked Sendable {
    let session: AVCaptureSession
}

/// The camera, on screen, while a take is being recorded.
struct CameraPreview: NSViewRepresentable {
    var session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = preview
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVCaptureVideoPreviewLayer)?.session = session
    }
}
