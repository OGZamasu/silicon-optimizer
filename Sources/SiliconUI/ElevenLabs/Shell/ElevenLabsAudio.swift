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
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    private(set) var currentTime: TimeInterval = 0
    /// Why the file could not be opened, if it could not.
    private(set) var problem: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Timer?

    init(url: URL) {
        self.url = url
    }

    /// Opens the file without playing it, so the duration is known before the first press.
    func prepare() {
        guard player == nil, problem == nil else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
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
    init(url: URL, title: String? = nil) {
        self.url = url
        self.title = title
        _player = State(initialValue: ElevenLabsAudioPlayer(url: url))
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
    static func collect(
        _ stream: AsyncThrowingStream<ElevenLabsChunk, any Error>,
        operation: ElevenLabsOperation,
        sink: any ElevenLabsFileSink,
        player: ElevenLabsStreamPlayer?,
        progress: @escaping @Sendable (Int) async -> Void
    ) async throws -> ElevenLabsResult {
        var meta = ElevenLabsMeta(status: 200)
        var events: [JSONValue] = []
        var file: (url: URL, handle: FileHandle, contentType: String)?
        var bytes = 0

        func write(_ data: Data) throws {
            if file == nil {
                let contentType = meta.contentType ?? "audio/mpeg"
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
                    try write(data)
                    if let player { await player.append(data) }
                    await progress(bytes)
                case .bytes(let data):
                    try write(data)
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

    /// A file extension for a content type, for names the sink makes unique.
    static func fileExtension(for contentType: String) -> String {
        let type = contentType.lowercased().split(separator: ";").first.map(String.init) ?? ""
        switch type {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/ogg", "audio/opus": return "ogg"
        case "audio/flac": return "flac"
        case "audio/mp4", "audio/aac": return "m4a"
        case "audio/pcm", "audio/basic", "audio/l16": return "pcm"
        case "audio/mulaw", "audio/x-mulaw": return "ulaw"
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
