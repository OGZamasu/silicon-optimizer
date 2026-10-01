import AppKit
@preconcurrency import AVFoundation
import Foundation
import SiliconElevenLabs

// The live screens' audio: the microphone in, converted to the format a socket asked for and cut
// into chunks; the socket's audio out, decoded, held in a small jitter buffer and played; and an
// interruption that silences it at once. Everything that turns samples into bytes and back is
// plain DSP over `AVAudioPCMBuffer`s, so tests drive it with synthetic buffers; only
// `LiveEngineAudio` touches a device, and no test builds one.

// MARK: - Microphone → socket

/// Turns microphone buffers, whatever the device gives (float, one or two channels, 44.1 or
/// 48 kHz), into the socket's format — 16-bit little-endian mono PCM at its rate, or 8 kHz μ-law —
/// in chunks of `chunkMilliseconds`. While `muted`, the chunks are silence: the socket stays fed
/// (ElevenLabs closes a quiet transcription socket, and an agent waits) but nothing said leaves.
final class LiveCaptureConverter: @unchecked Sendable {
    let target: ElevenLabsAudioEncoding
    let chunkBytes: Int
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private let output: AVAudioFormat
    private var pending = Data()
    private var _muted = false
    private var _level: Float = 0

    /// - Parameters:
    ///   - target: `pcm_<rate>` or `ulaw_8000`.
    ///   - chunkMilliseconds: How much audio each chunk holds.
    init?(target: ElevenLabsAudioEncoding, chunkMilliseconds: Int) {
        let rate: Double
        switch target {
        case .pcm(let value): rate = Double(value)
        case .ulaw: rate = 8_000
        default: return nil
        }
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let bytesPerSecond = target.bytesPerSecond
        else { return nil }
        self.target = target
        self.output = output
        chunkBytes = max(2, bytesPerSecond * max(10, chunkMilliseconds) / 1_000 / 2 * 2)
    }

    var muted: Bool {
        get { lock.withLock { _muted } }
        set { lock.withLock { _muted = newValue } }
    }

    /// The loudness of what was last sent, 0 (silence) to 1 (full scale).
    var level: Float { lock.withLock { _level } }

    /// Converts `buffer` and returns every whole chunk now ready, in order.
    func process(_ buffer: AVAudioPCMBuffer) -> [Data] {
        lock.withLock {
            guard buffer.frameLength > 0, let samples = convert(buffer) else { return [] }
            let silent = _muted
            _level = silent ? 0 : Self.level(of: samples)
            pending.append(encode(silent ? [Float](repeating: 0, count: samples.count) : samples))
            var chunks: [Data] = []
            while pending.count >= chunkBytes {
                chunks.append(Data(pending.prefix(chunkBytes)))
                pending.removeFirst(chunkBytes)
            }
            return chunks
        }
    }

    /// Whatever is left — what the resampler still holds included — as a last short chunk.
    func flush() -> Data? {
        lock.withLock {
            if let tail = drain(), !tail.isEmpty {
                pending.append(encode(_muted ? [Float](repeating: 0, count: tail.count) : tail))
            }
            guard !pending.isEmpty else { return nil }
            defer { pending = Data() }
            return pending
        }
    }

    /// On the lock. The frames the resampler holds back for its filter, and a fresh start.
    private func drain() -> [Float]? {
        guard let converter, let drained = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 4_096) else { return nil }
        var error: NSError?
        converter.convert(to: drained, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        converter.reset()
        guard error == nil, let channel = drained.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(drained.frameLength)))
    }

    /// On the lock. Float mono at the target rate.
    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let format = buffer.format
        if converter == nil || converterInput != format {
            converter = AVAudioConverter(from: format, to: output)
            converterInput = format
        }
        guard let converter else { return nil }
        let ratio = output.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        let input = OneShot(buffer)
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            guard let next = input.take() else {
                status.pointee = .noDataNow
                return nil
            }
            status.pointee = .haveData
            return next
        }
        guard error == nil, let channel = converted.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
    }

    private func encode(_ samples: [Float]) -> Data {
        switch target {
        case .ulaw:
            return Data(samples.map { Self.encodeULaw(Self.int16($0)) })
        default:
            var data = Data(capacity: samples.count * 2)
            for sample in samples {
                let value = Self.int16(sample).littleEndian
                withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
            }
            return data
        }
    }

    static func int16(_ sample: Float) -> Int16 {
        Int16(max(-1, min(1, sample)) * 32_767)
    }

    /// RMS, as 0…1 on a 60 dB scale.
    static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let mean = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        let decibels = 10 * log10(max(mean, 1e-12))
        return max(0, min(1, (decibels + 60) / 60))
    }

    /// G.711 μ-law, the encoder that pairs with `ElevenLabsRawAudio.decodeULaw`.
    static func encodeULaw(_ sample: Int16) -> UInt8 {
        let bias = 0x84
        let clip = 32_635
        var value = Int(sample)
        let sign = value < 0 ? 0x80 : 0
        if value < 0 { value = -value }
        value = min(value, clip) + bias
        var exponent = 7
        var mask = 0x4000
        while exponent > 0, value & mask == 0 {
            exponent -= 1
            mask >>= 1
        }
        let mantissa = (value >> (exponent + 3)) & 0x0F
        return ~UInt8(sign | (exponent << 4) | mantissa)
    }

    /// One buffer, handed to the converter once; the block runs inside `convert`, on this thread.
    private final class OneShot: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }
}

/// An audio file on disk, read for a socket.
/// Microphone chunks on their way to the socket, bounded.
///
/// Audio is never dropped from the middle — a transcript with a hole in it, or an agent that
/// hears half a sentence, is worse than an ending that says why. When `capacity` chunks are
/// waiting (the socket has stopped taking audio for that long: thirty seconds of 100 ms chunks by
/// default), `onOverflow` runs once, nothing more is queued, and the screen ends the session.
final class LiveMicrophoneQueue: @unchecked Sendable {
    static let defaultCapacity = 300

    let chunks: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let onOverflow: @Sendable () -> Void
    private let lock = NSLock()
    private var overflowed = false

    init(capacity: Int = defaultCapacity, onOverflow: @escaping @Sendable () -> Void) {
        (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingOldest(max(1, capacity)))
        self.onOverflow = onOverflow
    }

    /// Queues `chunk` — from the audio thread — unless the queue is full or has been.
    func yield(_ chunk: Data) {
        guard !lock.withLock({ overflowed }) else { return }
        guard case .dropped = continuation.yield(chunk) else { return }
        let first: Bool = lock.withLock {
            defer { overflowed = true }
            return !overflowed
        }
        if first { onOverflow() }
    }

    func finish() { continuation.finish() }
}

enum LiveAudioFile {
    /// The whole file converted to `converter`'s format, in its chunks, and the file's length in
    /// seconds. Reads as it goes, a second at a time; call it off the main actor.
    static func chunks(of url: URL, with converter: LiveCaptureConverter) throws -> ([Data], Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let total = Double(file.length) / format.sampleRate
        var chunks: [Data] = []
        let frames = AVAudioFrameCount(max(1, format.sampleRate))
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { break }
            try file.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            chunks += converter.process(buffer)
        }
        if let last = converter.flush() { chunks.append(last) }
        return (chunks, total)
    }
}

// MARK: - Socket → speaker

/// Turns a socket's audio bytes into float buffers at the stream's rate: PCM (a sample may
/// straddle two messages), μ-law and A-law. MP3 goes through the shell's streaming decoder.
final class LivePlaybackDecoder {
    let encoding: ElevenLabsAudioEncoding
    private let format: AVAudioFormat?
    private var carry: UInt8?
    private let mp3: ElevenLabsMP3StreamDecoder?
    private var decoded: [AVAudioPCMBuffer] = []

    init(encoding: ElevenLabsAudioEncoding) {
        self.encoding = encoding
        format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(encoding.sampleRate), channels: 1, interleaved: false
        )
        if case .mp3 = encoding {
            let decoder = ElevenLabsMP3StreamDecoder()
            mp3 = decoder
        } else {
            mp3 = nil
        }
        mp3?.onBuffer = { [weak self] buffer in self?.decoded.append(buffer) }
    }

    /// Whether this encoding can be played as it arrives.
    var canPlay: Bool {
        switch encoding {
        case .pcm, .ulaw, .alaw, .mp3: true
        case .opus: false
        }
    }

    /// The buffers `data` completes, in order.
    func decode(_ data: Data) -> [AVAudioPCMBuffer] {
        switch encoding {
        case .pcm:
            var bytes = [UInt8]()
            bytes.reserveCapacity(data.count + 1)
            if let carry { bytes.append(carry) }
            bytes.append(contentsOf: data)
            carry = bytes.count % 2 == 1 ? bytes.removeLast() : nil
            let samples = (0..<(bytes.count / 2)).map {
                Float(Int16(bitPattern: UInt16(bytes[2 * $0]) | UInt16(bytes[2 * $0 + 1]) << 8)) / 32_768
            }
            return buffer(samples).map { [$0] } ?? []
        case .ulaw:
            return buffer(data.map { Float(ElevenLabsRawAudio.decodeULaw($0)) / 32_768 }).map { [$0] } ?? []
        case .alaw:
            return buffer(data.map { Float(ElevenLabsRawAudio.decodeALaw($0)) / 32_768 }).map { [$0] } ?? []
        case .mp3:
            decoded = []
            mp3?.feed(data)
            return decoded
        case .opus:
            return []
        }
    }

    /// Drops a half sample left over, after an interruption.
    func reset() { carry = nil }

    private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let format,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

/// A small jitter buffer: holds audio until `prebuffer` of it has arrived, then lets it through
/// as it comes; when the speaker runs dry while a response is still arriving, it waits for
/// another `prebuffer` rather than stuttering. `flush` drops everything — an interruption.
struct LiveJitterBuffer {
    var prebuffer: TimeInterval
    private(set) var held: [AVAudioPCMBuffer] = []
    private(set) var flowing = false
    /// Seconds scheduled and not yet played, as the player reports them.
    private(set) var queuedSeconds: TimeInterval = 0

    init(prebuffer: TimeInterval = 0.15) {
        self.prebuffer = prebuffer
    }

    var heldSeconds: TimeInterval { held.reduce(0) { $0 + Self.seconds($1) } }

    /// Takes `buffer`; returns what may go to the speaker now.
    mutating func add(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        held.append(buffer)
        if !flowing, heldSeconds >= prebuffer { flowing = true }
        return flowing ? release() : []
    }

    /// The stream ended: everything held may play.
    mutating func finish() -> [AVAudioPCMBuffer] {
        flowing = true
        return release()
    }

    /// The speaker finished `seconds` of audio.
    mutating func played(_ seconds: TimeInterval) {
        queuedSeconds = max(0, queuedSeconds - seconds)
        if queuedSeconds <= 0.001, held.isEmpty { flowing = false }
    }

    /// Drops everything held, and starts over with a fresh prebuffer.
    mutating func flush() {
        held = []
        flowing = false
        queuedSeconds = 0
    }

    private mutating func release() -> [AVAudioPCMBuffer] {
        defer { held = [] }
        queuedSeconds += held.reduce(0) { $0 + Self.seconds($1) }
        return held
    }

    static func seconds(_ buffer: AVAudioPCMBuffer) -> TimeInterval {
        Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
    }
}

// MARK: - Devices

/// The microphone and speaker. `LiveEngineAudio` in the app; a recording fake in every test.
protocol LiveAudioIO: AnyObject, Sendable {
    /// Asks for the microphone (the app's existing permission flow); false when refused.
    func requestMicrophone() async -> Bool
    /// Turns the microphone on. Buffers arrive on an audio thread. `echoCancellation` puts the
    /// input through macOS voice processing, so an agent on the speakers does not hear itself.
    func startCapture(echoCancellation: Bool, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    /// Turns the microphone tap off. The engine itself keeps running (and holding the input)
    /// until `release()`.
    func stopCapture()
    /// Schedules a decoded buffer; `played` is called when it has played (or been dropped).
    func play(_ buffer: AVAudioPCMBuffer, played: @escaping @Sendable () -> Void)
    /// Silence at once: everything scheduled is dropped.
    func flushPlayback()
    /// Lets go of the devices: the tap removed, the speaker stopped, the engine stopped and macOS
    /// voice processing turned off — so the system's microphone indicator goes out and other
    /// apps' audio is no longer ducked. It also forgets the `onDeviceChange` handler.
    /// Unconditional: for the app quitting. A session lets go with `release(claim:)`.
    func release()
    /// Takes the devices for a session that is about to capture or play; returns its claim.
    /// The newest claim owns the devices.
    func claim() -> Int
    /// `release()`, but only while `claim` is the newest claim: a session that ends — or a
    /// stream whose last audio finishes playing — after another screen's session started cannot
    /// take that session's microphone, engine or voice processing.
    func release(claim: Int)
    /// `handler` is called (on any thread) when the devices change under the microphone —
    /// headphones plugged in, another default input — which stops the engine and so the
    /// capture. The screen whose session holds the microphone sets it; `release()` clears it.
    func onDeviceChange(_ handler: (@Sendable () -> Void)?)
}

/// The devices, through one `AVAudioEngine` — one engine, so macOS voice processing on the input
/// has the output as its echo reference.
final class LiveEngineAudio: LiveAudioIO, @unchecked Sendable {
    private let lock = NSLock()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playerFormat: AVAudioFormat?
    private var capturing = false
    private var voiceProcessing = false
    private var deviceChanged: (@Sendable () -> Void)?
    private var claims = 0

    init() {
        engine.attach(player)
        // Quitting with a session open still lets go of the microphone and voice processing.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.release() }
        // A device change stops the engine: the capture would go silent while the screen still
        // says the microphone is on (and an agent keeps billing), so the session is told.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.configurationChanged() }
    }

    func claim() -> Int {
        lock.withLock {
            claims += 1
            return claims
        }
    }

    func release(claim: Int) {
        lock.withLock {
            guard claim == claims else { return }
            releaseLocked()
        }
    }

    func onDeviceChange(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { deviceChanged = handler }
    }

    private func configurationChanged() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            // A real change stops the engine; one this class made itself (voice processing,
            // under the lock and followed by a start) finds it running again.
            guard capturing, !engine.isRunning else { return nil }
            return deviceChanged
        }
        handler?()
    }

    func requestMicrophone() async -> Bool {
        await MicRecorder().requestPermission()
    }

    func startCapture(echoCancellation: Bool, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        try lock.withLock {
            guard !capturing else { return }
            let input = engine.inputNode
            if echoCancellation != voiceProcessing {
                if engine.isRunning { engine.stop() }
                try input.setVoiceProcessingEnabled(echoCancellation)
                voiceProcessing = echoCancellation
            }
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in onBuffer(buffer) }
            capturing = true
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        }
    }

    func stopCapture() {
        lock.withLock {
            guard capturing else { return }
            engine.inputNode.removeTap(onBus: 0)
            capturing = false
        }
    }

    func play(_ buffer: AVAudioPCMBuffer, played: @escaping @Sendable () -> Void) {
        lock.withLock {
            if playerFormat != buffer.format {
                player.stop()
                engine.disconnectNodeOutput(player)
                engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
                playerFormat = buffer.format
            }
            if !engine.isRunning {
                engine.prepare()
                guard (try? engine.start()) != nil else { played(); return }
            }
            player.scheduleBuffer(buffer) { played() }
            if !player.isPlaying { player.play() }
        }
    }

    func flushPlayback() {
        lock.withLock {
            player.stop()
            if engine.isRunning { player.play() }
        }
    }

    func release() {
        lock.withLock { releaseLocked() }
    }

    private func releaseLocked() {
        deviceChanged = nil
        if capturing { engine.inputNode.removeTap(onBus: 0) }
        capturing = false
        player.stop()
        engine.stop()
        if voiceProcessing {
            try? engine.inputNode.setVoiceProcessingEnabled(false)
            voiceProcessing = false
        }
    }
}

// MARK: - Playback for a screen

/// One stream's way to the speaker: decode, jitter-buffer, play, and stop at once on an
/// interruption. Tracks how much has played, for the screen.
@MainActor
final class LivePlayback {
    private let audio: any LiveAudioIO
    /// The claim of the session this plays for: its releases act only while that is the newest.
    private let claim: Int
    private var decoder: LivePlaybackDecoder
    private var jitter = LiveJitterBuffer()
    /// Bumped by every flush: a buffer that finishes after it does not count.
    private var generation = 0
    private(set) var playedSeconds: TimeInterval = 0
    private(set) var receivedBytes = 0
    /// Set by `finishThenRelease()`: once the last buffer has played, the devices are let go.
    private var releasesWhenDrained = false

    init(audio: any LiveAudioIO, encoding: ElevenLabsAudioEncoding, claim: Int) {
        self.audio = audio
        self.claim = claim
        decoder = LivePlaybackDecoder(encoding: encoding)
    }

    var canPlay: Bool { decoder.canPlay }
    var isPlaying: Bool { jitter.flowing || jitter.queuedSeconds > 0 }

    func append(_ data: Data) {
        receivedBytes += data.count
        for buffer in decoder.decode(data) {
            for ready in jitter.add(buffer) { schedule(ready) }
        }
    }

    /// The stream is over: whatever is held plays.
    func finish() {
        for ready in jitter.finish() { schedule(ready) }
    }

    /// The stream is over: what is held plays out, and then the devices are let go.
    func finishThenRelease() {
        finish()
        releasesWhenDrained = true
        releaseIfDrained()
    }

    /// Another session has the devices now: a release still pending from this one must not stop them.
    func cancelPendingRelease() {
        releasesWhenDrained = false
    }

    /// Silence now and let go now (under this playback's claim).
    func stopAndRelease() {
        releasesWhenDrained = false
        interrupt()
        audio.release(claim: claim)
    }

    /// The screen is left while its last audio plays out: the pending release is not left armed
    /// — the rest is silenced and the devices let go now.
    func stopIfReleasePending() {
        guard releasesWhenDrained else { return }
        stopAndRelease()
    }

    private func releaseIfDrained() {
        guard releasesWhenDrained, jitter.held.isEmpty, jitter.queuedSeconds <= 0.001 else { return }
        releasesWhenDrained = false
        audio.release(claim: claim)
    }

    /// An interruption: silence now, and nothing held or half-decoded survives.
    func interrupt() {
        generation += 1
        jitter.flush()
        decoder.reset()
        audio.flushPlayback()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        let seconds = LiveJitterBuffer.seconds(buffer)
        let scheduled = generation
        audio.play(buffer) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == scheduled else { return }
                self.jitter.played(seconds)
                self.playedSeconds += seconds
                self.releaseIfDrained()
            }
        }
    }
}
