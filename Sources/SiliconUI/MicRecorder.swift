import AVFoundation

/// Records the microphone into memory and writes complete WAV files on demand.
///
/// This is the trick behind live transcription: the transcribers read finished files
/// with correct headers, so every few seconds they get one — a snapshot of everything
/// said so far. The audio callback appends samples under a lock; nothing here touches
/// the file system until a snapshot is asked for.
@MainActor
final class MicRecorder {

    /// Sample storage the audio thread can append to directly — hopping to the main
    /// actor per buffer would reorder or drop chunks under load.
    private final class SampleStore: @unchecked Sendable {
        private var samples: [Float] = []
        private let lock = NSLock()

        func append(_ pointer: UnsafePointer<Float>, count: Int) {
            lock.lock()
            samples.append(contentsOf: UnsafeBufferPointer(start: pointer, count: count))
            lock.unlock()
        }

        func snapshot() -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            return samples
        }

        func clear() {
            lock.lock()
            samples = []
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return samples.count
        }
    }

    private let engine = AVAudioEngine()
    private let store = SampleStore()
    private(set) var sampleRate: Double = 48_000
    private(set) var isRecording = false

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    func start() throws {
        guard !isRecording else { return }
        store.clear()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        sampleRate = format.sampleRate
        let store = self.store
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let channel = buffer.floatChannelData?.pointee else { return }
            store.append(channel, count: Int(buffer.frameLength))
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
    }

    var recordedSeconds: Double {
        Double(store.count) / sampleRate
    }

    /// Everything captured so far, as a complete 16-bit PCM WAV.
    func writeSnapshot(to url: URL) throws {
        let samples = store.snapshot()
        try Self.wavData(samples: samples, sampleRate: Int(sampleRate)).write(to: url)
    }

    /// A minimal mono 16-bit WAV container. Hand-built because AVAudioFile finalizes
    /// its header only on close, and the whole point is writing mid-recording.
    static func wavData(samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let clipped = max(-1, min(1, sample))
            var value = Int16(clipped * 32767).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }

        var data = Data()
        func append(_ text: String) { data.append(contentsOf: text.utf8) }
        func append32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        append("RIFF")
        append32(UInt32(36 + pcm.count))
        append("WAVE")
        append("fmt ")
        append32(16)
        append16(1)                                   // PCM
        append16(1)                                   // mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * 2))              // byte rate
        append16(2)                                   // block align
        append16(16)                                  // bits per sample
        append("data")
        append32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
