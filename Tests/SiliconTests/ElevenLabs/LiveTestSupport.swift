@preconcurrency import AVFoundation
import Foundation
import SiliconElevenLabs
@testable import SiliconUI

/// A microphone and speaker that touch no device: capture is whatever a test pushes, playback is
/// a list of buffers, and permission is a flag.
final class FakeLiveAudio: LiveAudioIO, @unchecked Sendable {
    private let lock = NSLock()
    private var _permission: Bool
    private var _asked = 0
    private var _capturing = false
    private var _echoCancellation: Bool?
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var _scheduled: [AVAudioPCMBuffer] = []
    private var pending: [@Sendable () -> Void] = []
    private var _flushes = 0
    private var _captureStarts = 0
    var captureFailure: (any Error)?

    init(permission: Bool = true) {
        _permission = permission
    }

    var asked: Int { lock.withLock { _asked } }
    var capturing: Bool { lock.withLock { _capturing } }
    var captureStarts: Int { lock.withLock { _captureStarts } }
    var echoCancellation: Bool? { lock.withLock { _echoCancellation } }
    var scheduled: [AVAudioPCMBuffer] { lock.withLock { _scheduled } }
    var scheduledSeconds: Double { scheduled.reduce(0) { $0 + LiveJitterBuffer.seconds($1) } }
    var flushes: Int { lock.withLock { _flushes } }

    func requestMicrophone() async -> Bool {
        lock.withLock {
            _asked += 1
            return _permission
        }
    }

    func startCapture(echoCancellation: Bool, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        if let captureFailure { throw captureFailure }
        lock.withLock {
            _capturing = true
            _captureStarts += 1
            _echoCancellation = echoCancellation
            self.onBuffer = onBuffer
        }
    }

    func stopCapture() {
        lock.withLock {
            _capturing = false
            onBuffer = nil
        }
    }

    func play(_ buffer: AVAudioPCMBuffer, played: @escaping @Sendable () -> Void) {
        lock.withLock {
            _scheduled.append(buffer)
            pending.append(played)
        }
    }

    func flushPlayback() {
        let callbacks: [@Sendable () -> Void] = lock.withLock {
            _flushes += 1
            defer { pending = [] }
            return pending
        }
        for callback in callbacks { callback() }
    }

    func stopAll() {
        stopCapture()
        flushPlayback()
    }

    /// What the microphone hears: `seconds` of a sine at `frequency`, in the device's format
    /// (48 kHz float stereo by default). Ignored while capture is off — as a real microphone is.
    @discardableResult
    func hear(seconds: Double, frequency: Double = 440, amplitude: Float = 0.5, rate: Double = 48_000, channels: AVAudioChannelCount = 2) -> Bool {
        let callback = lock.withLock { onBuffer }
        guard let callback else { return false }
        callback(LiveSignal.sine(seconds: seconds, frequency: frequency, amplitude: amplitude, rate: rate, channels: channels))
        return true
    }

    /// Everything scheduled has played.
    func finishPlaying() {
        let callbacks: [@Sendable () -> Void] = lock.withLock {
            defer { pending = [] }
            return pending
        }
        for callback in callbacks { callback() }
    }
}

/// Synthetic audio.
enum LiveSignal {
    static func sine(
        seconds: Double, frequency: Double, amplitude: Float = 0.5, rate: Double = 48_000, channels: AVAudioChannelCount = 1
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let samples = buffer.floatChannelData![channel]
            for index in 0..<Int(frames) {
                samples[index] = amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / rate))
            }
        }
        return buffer
    }

    /// 16-bit little-endian PCM bytes of a sine.
    static func pcm(seconds: Double, frequency: Double = 220, rate: Int = 16_000) -> Data {
        var data = Data()
        for index in 0..<Int(seconds * Double(rate)) {
            let value = Int16(12_000 * sin(2 * Double.pi * frequency * Double(index) / Double(rate))).littleEndian
            withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Int16 samples from little-endian bytes.
    static func samples(_ data: Data) -> [Int16] {
        stride(from: data.startIndex, to: data.endIndex - 1, by: 2).map {
            Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)
        }
    }

    /// Upward zero crossings per second of `samples` at `rate`: the frequency of a sine.
    static func frequency(_ samples: [Float], rate: Double) -> Double {
        var crossings = 0
        for index in 1..<samples.count where samples[index - 1] < 0 && samples[index] >= 0 { crossings += 1 }
        return Double(crossings) / (Double(samples.count) / rate)
    }
}

/// A live screen's world: a client on the fake transport, the fake socket, the fake devices, a
/// scratch output folder and a pane whose client can be swapped (another key or region).
@MainActor
final class LiveRig {
    /// The linked client, swappable: the pane and the screens read it at the moment they need it.
    final class Account {
        var client: ElevenLabsClient?
        init(_ client: ElevenLabsClient?) { self.client = client }
    }

    let transport: FakeElevenLabsTransport
    let sink: TemporaryFileSink
    let credentials: FakeCredentialSource
    let account: Account
    let connector: FakeElevenLabsSocketConnector
    let audio: FakeLiveAudio
    let pane: ElevenLabsPaneState
    var context: LiveContext

    var client: ElevenLabsClient? {
        get { account.client }
        set { account.client = newValue }
    }

    init(
        region: ElevenLabsRegion = .global, permission: Bool = true,
        replies: @escaping @Sendable (ElevenLabsRequest) async throws -> FakeElevenLabsTransport.Reply = { _ in
            .jsonText(#"{"detail":"not scripted"}"#, status: 404)
        },
        server: @escaping FakeElevenLabsSocketConnector.Server = { _ in }
    ) {
        let transport = FakeElevenLabsTransport(handler: replies)
        let connector = FakeElevenLabsSocketConnector(server: server)
        let audio = FakeLiveAudio(permission: permission)
        let sink = TemporaryFileSink()
        let credentials = FakeCredentialSource(key: "sk_" + String(repeating: "liverigfixture", count: 3))
        let account = Account(Self.makeClient(credentials: credentials, region: region, transport: transport, sink: sink))
        let pane = ElevenLabsPaneState(defaults: nil, client: { account.client })
        self.sink = sink
        self.credentials = credentials
        self.transport = transport
        self.connector = connector
        self.audio = audio
        self.account = account
        self.pane = pane
        context = LiveContext(
            client: { account.client }, connector: { connector }, audio: { audio }, sink: { sink }, pane: pane
        )
        context.limits.agentStartTimeout = 5
    }

    static func makeClient(
        credentials: FakeCredentialSource, region: ElevenLabsRegion, transport: FakeElevenLabsTransport,
        sink: TemporaryFileSink
    ) -> ElevenLabsClient {
        var limits = ElevenLabsClient.Limits()
        limits.firstBackoff = 0.01
        limits.longestRetryWait = 0.02
        return ElevenLabsClient(credentials: credentials, region: region, transport: transport, sink: sink, limits: limits)
    }

    /// Another account: a new client (as a new key or a region change makes).
    func switchAccount(region: ElevenLabsRegion = .us) {
        client = Self.makeClient(credentials: credentials, region: region, transport: transport, sink: sink)
    }

    func clean() {
        sink.removeAll()
        transport.removeTemporaryFiles()
    }

    /// Waits until `condition` holds (or fifteen seconds pass: in a full run other suites can
    /// hold the main actor for seconds, and this returns as soon as it holds anyway).
    func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }
}
