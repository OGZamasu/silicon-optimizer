@preconcurrency import AVFoundation
import Foundation
import Observation
import SiliconElevenLabs

/// Live transcription: the microphone (or a file) into realtime speech-to-text, partial and
/// committed text as it comes, with timings, key terms and the rest of Scribe's options.
///
/// The microphone is off until Start; a red indicator shows while it is on. One session per
/// screen: Start while one is open is refused, the settings are captured when it opens and the
/// controls are locked meanwhile. Mute keeps the socket fed with silence (ElevenLabs closes a
/// socket that hears nothing) while nothing said leaves the Mac.
@MainActor
@Observable
final class LiveTranscriptionModel: ElevenLabsLiveWork {
    enum Phase: Equatable, Sendable {
        case idle
        case connecting
        case live
        /// The last audio is committed and the final text is awaited.
        case finishing
        case ended
    }

    enum Source: String, CaseIterable, Identifiable, Sendable {
        case microphone
        case file
        var id: String { rawValue }
        var title: String { self == .microphone ? "Microphone" : "Audio file" }
    }

    /// One committed piece of the transcript, with what came after it.
    struct Segment: Identifiable, Equatable, Sendable {
        let id: Int
        var text: String
        var words: [ElevenLabsTranscriptWord] = []
        var languageCode: String?
        var edited: String?
        var entities: [ElevenLabsTranscriptEntity] = []

        /// When it starts, in seconds from the start of the session, when the timings say.
        var start: Double? { words.first { $0.type != "spacing" }?.start }
    }

    // MARK: Settings

    var source: Source = .microphone
    var file: URL?
    var languageCode = ""
    var commitStrategy: ElevenLabsTranscriptionStreamConfig.CommitStrategy = .vad
    var includeTimestamps = true
    var noVerbatim = false
    /// Comma-separated; each term costs extra (20 %).
    var keyterms = ""
    /// `""` (off), `all`, `pii`, `phi`, `pci`, `offensive_language`…
    var entityDetection = ""
    var transcriptEdit = ""
    var filterBackgroundAudio = false
    var muted = false {
        didSet { converter?.muted = muted }
    }

    // MARK: State

    private(set) var phase: Phase = .idle
    private(set) var microphoneOn = false
    private(set) var segments: [Segment] = []
    private(set) var partial = ""
    private(set) var warnings: [String] = []
    private(set) var serverError: String?
    private(set) var usage: ElevenLabsRealtimeUsage?
    private(set) var outcome: LiveOutcome?
    private(set) var level: Float = 0
    private(set) var exported: [URL] = []
    private(set) var exportProblem: String?
    /// The settings the open (or last) session was started with, in words.
    private(set) var sessionDescription: String?
    /// The file being sent: how far along, of how long.
    private(set) var fileProgress: (sent: Double, total: Double)?

    let context: LiveContext
    @ObservationIgnored private let guardian: LiveSessionGuard
    @ObservationIgnored private var stream: ElevenLabsTranscriptionStream?
    @ObservationIgnored private var converter: LiveCaptureConverter?
    @ObservationIgnored private var chunks: AsyncStream<Data>.Continuation?
    @ObservationIgnored private var sender: Task<Void, Never>?
    @ObservationIgnored private var nextSegmentID = 0
    @ObservationIgnored private var awaitingFinal = false
    @ObservationIgnored private var finalArrived = false

    /// Seconds of audio between commits when committing by hand (ElevenLabs commits on its own
    /// after about 36 s, and asks for one every 20–30 s).
    static let commitEvery: Double = 20
    /// How fast a file is sent: a second of audio every this many seconds.
    static var filePace: Duration = .milliseconds(100)
    /// How long Stop waits for the last committed text.
    static var finalWait: Duration = .seconds(4)

    init(context: LiveContext) {
        self.context = context
        guardian = LiveSessionGuard(context: context)
    }

    var config: ElevenLabsTranscriptionStreamConfig {
        var config = ElevenLabsTranscriptionStreamConfig(audioFormat: .pcm(rate: 16_000))
        config.commitStrategy = source == .file ? .manual : commitStrategy
        let language = languageCode.trimmingCharacters(in: .whitespaces)
        config.languageCode = language.isEmpty ? nil : language
        config.includeTimestamps = includeTimestamps && !filterBackgroundAudio ? true : nil
        config.noVerbatim = noVerbatim ? true : nil
        config.keyterms = keyterms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        config.entityDetection = entityDetection.isEmpty ? [] : [entityDetection]
        let edit = transcriptEdit.trimmingCharacters(in: .whitespacesAndNewlines)
        config.transcriptEdit = edit.isEmpty ? nil : edit
        config.filterBackgroundAudio = filterBackgroundAudio ? true : nil
        return config
    }

    var isOpen: Bool { phase == .connecting || phase == .live || phase == .finishing }

    var startBlocker: String? {
        if isOpen { return nil }
        if source == .file, file == nil { return "Choose an audio file." }
        return config.problems().first
    }

    /// What the settings add to the bill, in ElevenLabs' words.
    var costLines: [String] {
        ["ElevenLabs bills realtime transcription by the length of the audio sent."] + config.costAddOns
    }

    var fullText: String {
        segments.map { $0.edited ?? $0.text }.joined(separator: " ")
    }

    // MARK: Actions

    /// Opens a session and starts the microphone, or sends the chosen file.
    func start() async {
        guard !isOpen, startBlocker == nil else { return }
        let config = config
        let source = source
        let file = file
        resetSession()
        phase = .connecting
        if source == .microphone {
            guard await context.audio().requestMicrophone() else {
                end(.notStarted("The microphone is not allowed for this app. Allow it in System Settings → Privacy & Security → Microphone."))
                return
            }
            guard phase == .connecting else { return }
        }
        guard let realtime = context.realtime() else {
            end(.notStarted(ElevenLabsError.notLinked.description))
            return
        }
        let token = guardian.begin(client: realtime.client, work: self)
        sessionDescription = describe(config, source: source, file: file)
        let stream: ElevenLabsTranscriptionStream
        do {
            stream = try await realtime.transcriptionStream(config)
        } catch {
            if guardian.isCurrent(token) { end(LiveOutcome.failedToStart(error)) }
            return
        }
        guard guardian.isCurrent(token), phase == .connecting,
              let converter = LiveCaptureConverter(target: config.audioFormat, chunkMilliseconds: source == .file ? 1_000 : 100)
        else {
            await stream.close()
            return
        }
        self.stream = stream
        self.converter = converter
        converter.muted = muted
        let (chunks, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.chunks = continuation
        sender = Task.detached { for await chunk in chunks { try? await stream.sendAudio(chunk) } }
        phase = .live
        Task { await consume(stream, token: token) }
        Task { await watch(token: token) }
        switch source {
        case .microphone:
            do {
                try context.audio().startCapture(echoCancellation: false) { buffer in
                    for chunk in converter.process(buffer) { continuation.yield(chunk) }
                }
                microphoneOn = true
            } catch {
                await close(.mayHaveBeenBilled("The microphone could not start: \(ElevenLabsRedaction.redact(error.localizedDescription))."))
            }
        case .file:
            if let file { Task { await send(file: file, converter: converter, token: token) } }
        }
    }

    /// Microphone off, the rest committed, the last text awaited, the socket closed.
    func stop() async {
        switch phase {
        case .connecting:
            end(.notStarted("Cancelled before any audio was sent."))
        case .live:
            await finishSending(commit: true)
        default:
            break
        }
    }

    /// Leaving the screen ends the session at once.
    func leave() {
        guard isOpen else { return }
        let closing = stream
        end(.ended(LiveOutcome.leftScreen))
        Task { await closing?.close() }
    }

    func endForAccountChange() -> Bool {
        guard isOpen else { return false }
        let closing = stream
        end(.mayHaveBeenBilled(LiveOutcome.accountChanged))
        Task { await closing?.close() }
        return true
    }

    func tick() {
        refresh()
        if isOpen, phase != .connecting, !guardian.accountIsCurrent { _ = endForAccountChange() }
    }

    /// Writes the transcript as text and as JSON (segments, words, edits, entities).
    func export() async {
        exportProblem = nil
        guard !segments.isEmpty else { return }
        guard let sink = context.sink() else {
            exportProblem = "There is nowhere to save it."
            return
        }
        let json: JSONValue = ["segments": .array(segments.map { segment in
            var object: [String: JSONValue] = ["text": .string(segment.text)]
            if let edited = segment.edited { object["edited_text"] = .string(edited) }
            if let language = segment.languageCode { object["language_code"] = .string(language) }
            if !segment.words.isEmpty {
                object["words"] = .array(segment.words.map { word in
                    var entry: [String: JSONValue] = ["text": .string(word.text)]
                    if let start = word.start { entry["start"] = .number(start) }
                    if let end = word.end { entry["end"] = .number(end) }
                    if let type = word.type { entry["type"] = .string(type) }
                    if let speaker = word.speakerID { entry["speaker_id"] = .string(speaker) }
                    return .object(entry)
                })
            }
            if !segment.entities.isEmpty {
                object["entities"] = .array(segment.entities.map {
                    ["text": .string($0.text), "type": .string($0.type)]
                })
            }
            return .object(object)
        })]
        do {
            let operation = ElevenLabsLiveOperations.transcription
            exported = [
                try await LiveFiles.write(Data((fullText + "\n").utf8), name: "live-transcript", ext: "txt",
                                          contentType: "text/plain", operation: operation, sink: sink),
                try await LiveFiles.write(json.encoded(pretty: true), name: "live-transcript", ext: "json",
                                          contentType: "application/json", operation: operation, sink: sink),
            ]
        } catch {
            exportProblem = "It could not be saved: \(ElevenLabsRedaction.redact(error.localizedDescription))"
        }
    }

    // MARK: Session

    private func send(file: URL, converter: LiveCaptureConverter, token: UUID) async {
        let decoded: [Data]
        let total: Double
        do {
            (decoded, total) = try await Task.detached { try LiveAudioFile.chunks(of: file, with: converter) }.value
        } catch {
            guard guardian.isCurrent(token) else { return }
            await close(.mayHaveBeenBilled("The file could not be read: \(ElevenLabsRedaction.redact(error.localizedDescription))."))
            return
        }
        fileProgress = (0, total)
        var sentSeconds = 0.0
        var sinceCommit = 0.0
        let bytesPerSecond = Double(converter.target.bytesPerSecond ?? 32_000)
        for chunk in decoded {
            guard guardian.isCurrent(token), phase == .live, let stream else { return }
            do {
                try await stream.sendAudio(chunk)
            } catch {
                return
            }
            let seconds = Double(chunk.count) / bytesPerSecond
            sentSeconds += seconds
            sinceCommit += seconds
            fileProgress = (sentSeconds, total)
            if sinceCommit >= Self.commitEvery {
                try? await stream.commit()
                sinceCommit = 0
            }
            try? await Task.sleep(for: Self.filePace)
        }
        guard guardian.isCurrent(token), phase == .live else { return }
        await finishSending(commit: true)
    }

    private func finishSending(commit: Bool) async {
        guard phase == .live, let stream else { return }
        let token = guardian.token
        phase = .finishing
        if microphoneOn { context.audio().stopCapture() }
        microphoneOn = false
        if let rest = converter?.flush() { chunks?.yield(rest) }
        chunks?.finish()
        await sender?.value
        guard guardian.isCurrent(token) else { return }
        // The text for the last stretch comes as a committed transcript after this commit.
        awaitingFinal = true
        finalArrived = false
        if commit { try? await stream.commit() }
        let deadline = ContinuousClock.now + Self.finalWait
        while guardian.isCurrent(token), !finalArrived, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard guardian.isCurrent(token) else { return }
        await close(.ended(summary()))
    }

    private func close(_ outcome: LiveOutcome) async {
        let closing = stream
        end(outcome)
        await closing?.close()
    }

    private func consume(_ stream: ElevenLabsTranscriptionStream, token: UUID) async {
        for await event in stream.events {
            guard guardian.isCurrent(token) else { continue }
            switch event {
            case .started:
                break
            case .partial(let text):
                partial = text
            case .committed(let text):
                partial = ""
                if awaitingFinal { finalArrived = true }
                guard !text.isEmpty else { continue }
                segments.append(Segment(id: nextSegmentID, text: text))
                nextSegmentID += 1
            case .committedWithTimestamps(let text, let language, let words):
                if let index = segments.lastIndex(where: { $0.text == text }) {
                    segments[index].words = words
                    segments[index].languageCode = language
                }
            case .entities(let text, let entities):
                if let index = segments.lastIndex(where: { $0.text == text }) { segments[index].entities = entities }
            case .edited(let text, let edited):
                // May arrive out of commit order: matched by the committed text.
                if let index = segments.lastIndex(where: { $0.text == text }) { segments[index].edited = edited }
            case .warning(let text):
                warnings.append(text)
            case .error(let type, let message):
                serverError = message.isEmpty ? type : "\(type): \(message)"
            case .finalTranscript, .unknown:
                break
            case .ended(let close):
                if close.kind == .normal {
                    end(.ended(summary()))
                } else {
                    let why = serverError.map { " (\($0))" } ?? ""
                    end(.mayHaveBeenBilled("The session ended early: \(close.description)\(why). The audio sent may have been billed."))
                }
            }
        }
    }

    private func watch(token: UUID) async {
        while guardian.isCurrent(token) {
            tick()
            level = converter?.level ?? 0
            try? await Task.sleep(for: .milliseconds(100))
        }
        level = 0
    }

    private func end(_ outcome: LiveOutcome) {
        refresh()
        if microphoneOn { context.audio().stopCapture() }
        microphoneOn = false
        chunks?.finish()
        chunks = nil
        sender?.cancel()
        sender = nil
        converter = nil
        stream = nil
        partial = ""
        self.outcome = outcome
        phase = .ended
        guardian.end()
    }

    private func refresh() {
        if let stream { usage = stream.usage }
    }

    private func resetSession() {
        awaitingFinal = false
        finalArrived = false
        segments = []
        partial = ""
        warnings = []
        serverError = nil
        usage = nil
        outcome = nil
        exported = []
        exportProblem = nil
        fileProgress = nil
    }

    private func summary() -> String {
        let seconds = usage?.audioSecondsSent ?? 0
        return "Done. \(LiveClock.text(seconds)) of audio sent — ElevenLabs bills transcription by the audio's length."
    }

    private func describe(_ config: ElevenLabsTranscriptionStreamConfig, source: Source, file: URL?) -> String {
        var parts = [source == .file ? "File \(file?.lastPathComponent ?? "")" : "Microphone",
                     config.languageCode.map { "language \($0)" } ?? "language detected",
                     config.commitStrategy == .vad ? "commits at pauses" : "commits by hand"]
        if !config.keyterms.isEmpty { parts.append("\(config.keyterms.count) key terms") }
        if config.transcriptEdit != nil { parts.append("transcript edit") }
        if !config.entityDetection.isEmpty { parts.append("entities: \(config.entityDetection.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }
}
