import AVFoundation
import Foundation
import Observation
import SiliconElevenLabs
import SwiftUI

/// Plays one audio file in the app: play, pause, scrub.
@MainActor
@Observable
final class ElevenLabsAudioPlayer {
    let url: URL
    /// Set for headerless audio: the player opens a WAV made from it in memory.
    let raw: ElevenLabsRawAudio.Format?
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    /// Why the file could not be opened, if it could not.
    private(set) var problem: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Timer?

    init(url: URL, raw: ElevenLabsRawAudio.Format? = nil) {
        self.url = url
        self.raw = raw
    }

    /// Opens the file without playing it, so the duration is known before the first press.
    func prepare() {
        guard player == nil, problem == nil else { return }
        do {
            let player: AVAudioPlayer
            if let raw {
                let data = try Data(contentsOf: url, options: .alwaysMapped)
                player = try AVAudioPlayer(data: ElevenLabsRawAudio.wav(
                    from: data, encoding: raw.encoding, sampleRate: raw.sampleRate
                ))
            } else {
                player = try AVAudioPlayer(contentsOf: url)
            }
            player.prepareToPlay()
            self.player = player
            duration = player.duration
        } catch {
            problem = "This audio could not be opened: \(error.localizedDescription)"
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        prepare()
        guard let player else { return }
        if player.currentTime >= player.duration - 0.05 { player.currentTime = 0 }
        player.play()
        isPlaying = true
        startTicking()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
        currentTime = player?.currentTime ?? currentTime
    }

    func seek(to time: TimeInterval) {
        prepare()
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
    }

    func stop() {
        player?.stop()
        isPlaying = false
        stopTicking()
    }

    private func startTicking() {
        stopTicking()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            stopTicking()
        }
    }
}

/// An audio file's player: play/pause, a scrubber with times, Save… and Reveal in Finder.
struct ElevenLabsAudioPlayerView: View {
    let url: URL
    var title: String?

    @State private var player: ElevenLabsAudioPlayer

    /// Give the view `.id(url)` where the file can change under it: the player is made once
    /// per view identity.
    ///
    /// - Parameter raw: For headerless audio (PCM, μ-law, A-law): how to read it.
    init(url: URL, title: String? = nil, raw: ElevenLabsRawAudio.Format? = nil) {
        self.url = url
        self.title = title
        _player = State(initialValue: ElevenLabsAudioPlayer(url: url, raw: raw))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
            }
            HStack(spacing: 10) {
                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.title)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .disabled(player.problem != nil)

                Slider(
                    value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                    in: 0...max(player.duration, 0.01)
                )
                .disabled(player.duration <= 0)

                Text("\(Self.clock(player.currentTime)) / \(Self.clock(player.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()

                ElevenLabsFileActions(url: url)
            }
            if let problem = player.problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { player.prepare() }
        .onDisappear { player.stop() }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// Reads a stream to its end: audio and other bytes to one file from the sink (fed to the
/// player as they arrive), events kept as JSON. What `ElevenLabsRunner` uses for `.play`.
enum ElevenLabsStreamCollector {
    /// - Parameter outputFormat: The run's `output_format`. Audio is saved as that format:
    ///   the `…/with-timestamps` streams are JSON carrying base64 audio, so the stream's own
    ///   content type (`application/json`) says nothing about the audio in it.
    static func collect(
        _ stream: AsyncThrowingStream<ElevenLabsChunk, any Error>,
        operation: ElevenLabsOperation,
        sink: any ElevenLabsFileSink,
        player: ElevenLabsStreamPlayer?,
        outputFormat: String? = nil,
        progress: @escaping @Sendable (Int) async -> Void
    ) async throws -> ElevenLabsResult {
        var meta = ElevenLabsMeta(status: 200)
        var events: [JSONValue] = []
        var file: (url: URL, handle: FileHandle, contentType: String)?
        var bytes = 0

        func write(_ data: Data, isAudio: Bool) throws {
            if file == nil {
                let streamed = meta.contentType?.lowercased() ?? ""
                let contentType = isAudio && !streamed.hasPrefix("audio/")
                    ? audioContentType(outputFormat: outputFormat)
                    : (meta.contentType ?? audioContentType(outputFormat: outputFormat))
                let url = try sink.destination(
                    for: operation,
                    suggestedName: "\(operation.id).\(fileExtension(for: contentType))",
                    contentType: contentType
                )
                FileManager.default.createFile(atPath: url.path, contents: nil)
                file = (url, try FileHandle(forWritingTo: url), contentType)
            }
            try file?.handle.write(contentsOf: data)
            bytes += data.count
        }

        do {
            for try await chunk in stream {
                try Task.checkCancellation()
                switch chunk {
                case .started(let started):
                    meta = started
                case .audio(let data):
                    try write(data, isAudio: true)
                    if let player { await player.append(data) }
                    await progress(bytes)
                case .bytes(let data):
                    try write(data, isAudio: false)
                    await progress(bytes)
                case .event(let event):
                    events.append(event)
                }
            }
        } catch {
            if let file {
                try? file.handle.close()
                try? FileManager.default.removeItem(at: file.url)
            }
            throw error
        }

        guard let file else { return .events(events, meta) }
        try file.handle.close()
        await sink.didWrite(file.url, contentType: file.contentType, operation: operation)
        let written = ElevenLabsResultPart.file(file.url, contentType: file.contentType, bytes: bytes)
        if events.isEmpty {
            return .file(file.url, contentType: file.contentType, bytes: bytes, meta)
        }
        return .parts(events.map(ElevenLabsResultPart.json) + [written], meta)
    }

    /// The content type of audio in `outputFormat` (`mp3_44100_128`, `pcm_24000`,
    /// `ulaw_8000`…), named as the client names the files it collects; MP3 when not given.
    static func audioContentType(outputFormat: String?) -> String {
        let format = outputFormat?.lowercased() ?? "mp3"
        for (prefix, type) in [("mp3", "audio/mpeg"), ("pcm", "audio/pcm"), ("opus", "audio/opus"),
                               ("wav", "audio/wav"), ("ulaw", "audio/ulaw"), ("alaw", "audio/alaw"),
                               ("flac", "audio/flac")] where format.hasPrefix(prefix) {
            return type
        }
        return "audio/mpeg"
    }

    /// A file extension for a content type, for names the sink makes unique.
    static func fileExtension(for contentType: String) -> String {
        let type = contentType.lowercased().split(separator: ";").first.map(String.init) ?? ""
        switch type {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/ogg": return "ogg"
        case "audio/opus": return "opus"
        case "audio/ulaw": return "ulaw"
        case "audio/alaw", "audio/x-alaw": return "alaw"
        case "audio/flac": return "flac"
        case "audio/mp4", "audio/aac": return "m4a"
        case "audio/pcm", "audio/l16": return "pcm"
        case "audio/basic", "audio/mulaw", "audio/x-mulaw": return "ulaw"
        case "video/mp4": return "mp4"
        case "application/zip", "application/x-zip-compressed", "application/x-zip": return "zip"
        case "text/csv": return "csv"
        case "application/json": return "json"
        case "text/plain": return "txt"
        case "text/html": return "html"
        default: return type.hasPrefix("audio/") ? "audio" : "bin"
        }
    }
}

/// Headerless audio as ElevenLabs sends it — 16-bit PCM, μ-law, A-law — made playable: decoded
/// to 16-bit PCM and given a WAV header, in memory, for the player only. The file on disk is
/// never changed, so Save… still copies exactly what ElevenLabs sent.
enum ElevenLabsRawAudio {
    enum Encoding: String, Sendable {
        case pcm16, ulaw, alaw

        /// The rate to assume when the run's `output_format` is not known. μ-law and A-law
        /// only come at 8 kHz; PCM is the owner's choice, so the player offers the others.
        var fallbackRate: Double {
            switch self {
            case .pcm16: 24_000
            case .ulaw, .alaw: 8_000
            }
        }
    }

    /// Everything the player needs to open a raw file.
    struct Format: Hashable, Sendable {
        var encoding: Encoding
        var sampleRate: Double
    }

    /// The sample rates ElevenLabs offers for PCM.
    static let pcmRates: [Double] = [8_000, 16_000, 22_050, 24_000, 44_100, 48_000]

    /// The raw encoding of a file, from its extension or content type; nil for audio that
    /// carries its own header (MP3, WAV, Opus…).
    static func encoding(url: URL, contentType: String) -> Encoding? {
        let type = contentType.lowercased().split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        switch url.pathExtension.lowercased() {
        case "pcm": return .pcm16
        case "ulaw": return .ulaw
        case "alaw": return .alaw
        default: break
        }
        switch type {
        case "audio/pcm", "audio/l16": return .pcm16
        case "audio/basic", "audio/x-mulaw", "audio/ulaw": return .ulaw
        case "audio/alaw", "audio/x-alaw": return .alaw
        default: return nil
        }
    }

    /// The rate an `output_format` names: `pcm_24000` → 24000, `ulaw_8000` → 8000.
    static func sampleRate(outputFormat: String?) -> Double? {
        guard let format = outputFormat?.lowercased(),
              let digits = format.split(separator: "_").dropFirst().first,
              let rate = Double(digits), rate > 0
        else { return nil }
        return rate
    }

    /// Mono 16-bit PCM WAV bytes for `data` in `encoding` at `sampleRate`.
    static func wav(from data: Data, encoding: Encoding, sampleRate: Double) -> Data {
        var samples: [Int16]
        switch encoding {
        case .pcm16:
            samples = stride(from: 0, to: data.count - 1, by: 2).map { index in
                Int16(bitPattern: UInt16(data[data.startIndex + index]) | UInt16(data[data.startIndex + index + 1]) << 8)
            }
        case .ulaw:
            samples = data.map(decodeULaw)
        case .alaw:
            samples = data.map(decodeALaw)
        }
        let rate = UInt32(sampleRate.rounded())
        let payload = UInt32(samples.count * 2)
        var wav = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); append(36 + payload)
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        wav.append(contentsOf: Array("data".utf8)); append(payload)
        samples.withUnsafeMutableBufferPointer { buffer in
            for index in buffer.indices { buffer[index] = buffer[index].littleEndian }
        }
        samples.withUnsafeBytes { wav.append(contentsOf: $0) }
        return wav
    }

    /// G.711 μ-law to linear.
    static func decodeULaw(_ byte: UInt8) -> Int16 {
        let value = ~byte
        let exponent = Int((value >> 4) & 0x07)
        let magnitude = ((Int(value & 0x0F) << 3) + 0x84) << exponent - 0x84
        return Int16(value & 0x80 != 0 ? -magnitude : magnitude)
    }

    /// G.711 A-law to linear.
    static func decodeALaw(_ byte: UInt8) -> Int16 {
        let value = byte ^ 0x55
        let exponent = Int((value >> 4) & 0x07)
        var magnitude = (Int(value & 0x0F) << 4) + 8
        if exponent > 0 { magnitude = (magnitude + 0x100) << (exponent - 1) }
        return Int16(value & 0x80 != 0 ? magnitude : -magnitude)
    }
}

/// A headerless audio file's player, with a sample-rate choice for PCM when the run did not
/// say which rate it asked for.
struct ElevenLabsRawAudioPlayerView: View {
    let url: URL
    let encoding: ElevenLabsRawAudio.Encoding
    /// Known from the run's `output_format`; the player then offers no choice.
    let knownRate: Double?

    @State private var chosenRate: Double

    init(url: URL, encoding: ElevenLabsRawAudio.Encoding, knownRate: Double?) {
        self.url = url
        self.encoding = encoding
        self.knownRate = knownRate
        _chosenRate = State(initialValue: knownRate ?? encoding.fallbackRate)
    }

    var body: some View {
        let rate = knownRate ?? chosenRate
        VStack(alignment: .leading, spacing: 4) {
            ElevenLabsAudioPlayerView(
                url: url, title: url.lastPathComponent,
                raw: ElevenLabsRawAudio.Format(encoding: encoding, sampleRate: rate)
            )
            .id("\(url.path)|\(rate)")
            HStack(spacing: 8) {
                Text(encoding == .pcm16 ? "Raw 16-bit PCM" : (encoding == .ulaw ? "μ-law" : "A-law"))
                if knownRate == nil, encoding == .pcm16 {
                    Picker("Sample rate", selection: $chosenRate) {
                        ForEach(ElevenLabsRawAudio.pcmRates, id: \.self) { rate in
                            Text("\(Int(rate)) Hz").tag(rate)
                        }
                    }
                    .controlSize(.small)
                    .fixedSize()
                } else {
                    Text("\(Int(rate)) Hz")
                }
                Text("· Save… keeps the file exactly as ElevenLabs sent it.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
