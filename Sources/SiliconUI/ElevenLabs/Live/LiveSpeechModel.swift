import Foundation
import Observation
import SiliconElevenLabs

/// Live speech: text in, speech out as it is generated, over `stream-input`.
///
/// The owner types or pastes, presses Speak, and hears it as it streams; more text can follow on
/// the same socket until it goes quiet (ElevenLabs closes it after the inactivity timeout, and
/// the next Speak opens a new one). One socket per screen: Speak while one is opening is refused,
/// the text box is emptied the moment Speak takes it (so a second click has nothing to send), and
/// the voice, model and settings are the ones captured when the socket opened — the pickers are
/// locked while it is open.
@MainActor
@Observable
final class LiveSpeechModel: ElevenLabsLiveWork {
    enum Phase: Equatable, Sendable {
        case idle
        case connecting
        case live
        /// The end of the sequence was sent; the last audio is on its way.
        case finishing
        case ended
    }

    /// A word of what was spoken, on one clock from the start of the session.
    struct Word: Identifiable, Equatable, Sendable {
        let id: Int
        var text: String
        var startMs: Int
        var endMs: Int
    }

    // MARK: Settings

    var voiceID = ""
    var modelID = "eleven_flash_v2_5"
    var outputFormat = "pcm_24000"
    var languageCode = ""
    /// Generation without the chunk schedule — fastest, for whole sentences.
    var autoMode = false
    var overridesVoiceSettings = false
    var stability = 0.5
    var similarityBoost = 0.75
    var style = 0.0
    var speed = 1.0
    var useSpeakerBoost = true
    /// Seconds without text before ElevenLabs closes the socket (1–180).
    var inactivityTimeout = 60
    var text = ""

    // MARK: State

    private(set) var phase: Phase = .idle
    private(set) var sending = false
    /// What was sent to be spoken, in order.
    private(set) var spoken: [String] = []
    private(set) var words: [Word] = []
    /// The voice and model the open (or last) session was started with.
    private(set) var sessionDescription: String?
    private(set) var usage: ElevenLabsRealtimeUsage?
    private(set) var outcome: LiveOutcome?
    /// What ElevenLabs said in a message, if anything.
    private(set) var serverMessage: String?
    private(set) var savedFile: URL?
    private(set) var saveProblem: String?
    /// Audio received this session (kept to save), and whether it outgrew what is kept.
    private(set) var audio = Data()
    private(set) var audioTruncated = false
    private(set) var now = Date()

    static let audioLimit = 256 << 20

    // MARK: Plumbing

    let context: LiveContext
    @ObservationIgnored private let guardian: LiveSessionGuard
    @ObservationIgnored private var stream: ElevenLabsSpeechStream?
    @ObservationIgnored private var playback: LivePlayback?
    @ObservationIgnored private var sessionEncoding: ElevenLabsAudioEncoding?
    @ObservationIgnored private var receivedSeconds: Double = 0
    @ObservationIgnored private var nextWordID = 0

    init(context: LiveContext) {
        self.context = context
        guardian = LiveSessionGuard(context: context)
    }

    /// The models ElevenLabs serves on this socket (`eleven_v3`/`v4` are not among them).
    static let models = ["eleven_flash_v2_5", "eleven_turbo_v2_5", "eleven_multilingual_v2", "eleven_flash_v2", "eleven_turbo_v2"]
    /// PCM plays as it arrives without a decoder; MP3 and μ-law play too.
    static let formats = ElevenLabsSpeechStreamConfig.socketOutputFormats

    var config: ElevenLabsSpeechStreamConfig {
        var config = ElevenLabsSpeechStreamConfig(voiceID: voiceID, modelID: modelID, outputFormat: outputFormat)
        let language = languageCode.trimmingCharacters(in: .whitespaces)
        config.languageCode = language.isEmpty ? nil : language
        config.inactivityTimeout = inactivityTimeout
        config.autoMode = autoMode ? true : nil
        // Timings come with every piece of audio, for the words under the text.
        config.syncAlignment = true
        if overridesVoiceSettings {
            config.voiceSettings = .init(
                stability: stability, similarityBoost: similarityBoost, style: style,
                useSpeakerBoost: useSpeakerBoost, speed: speed
            )
        }
        return config
    }

    var isOpen: Bool { phase == .connecting || phase == .live || phase == .finishing }
    var settingsLocked: Bool { isOpen }

    /// Why Speak cannot be pressed now, or nil.
    var speakBlocker: String? {
        if phase == .connecting { return "Connecting…" }
        if phase == .finishing { return "Finishing the last audio…" }
        if sending { return "Sending…" }
        if voiceID.isEmpty { return "Choose a voice." }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Type something to say." }
        if !isOpen, let problem = config.problems().first { return problem }
        return nil
    }

    /// The characters Speak would send, for the cost note.
    var pendingCharacters: Int { text.trimmingCharacters(in: .whitespacesAndNewlines).count }

    // MARK: Actions

    /// Sends the text box: opens a socket first when none is open.
    func speak() async {
        guard speakBlocker == nil else { return }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Taken now: a second click finds nothing to send.
        text = ""
        sending = true
        defer { sending = false }
        if stream == nil {
            guard await open() else {
                if spoken.isEmpty { text = words }
                return
            }
        }
        guard let stream, phase == .live else { return }
        let token = guardian.token
        // Piece by piece, so a failure part-way knows what went (and was billed) and what did not.
        let pieces = ElevenLabsTextChunker.chunks(words)
        var sent = 0
        do {
            for (index, piece) in pieces.enumerated() {
                try await stream.send(piece, flush: index == pieces.count - 1)
                sent += 1
            }
            guard guardian.isCurrent(token) else { return }
            spoken.append(words)
        } catch {
            // Only what was not sent goes back in the box, to send again once a stream is open —
            // whatever has become of this one. (Speak is refused while this runs, so no other
            // session has started meanwhile.)
            let unsent = pieces.dropFirst(sent).joined().trimmingCharacters(in: .whitespaces)
            if text.isEmpty { text = unsent }
            let why = ElevenLabsRealtimeError(wrapping: error).description
            if sent > 0 {
                spoken.append(pieces.prefix(sent).joined().trimmingCharacters(in: .whitespaces))
                serverMessage = why + " Part of the text was sent (and billed); the rest is back in the box."
            } else {
                serverMessage = why
            }
        }
        refresh()
    }

    /// The end of the sequence: ElevenLabs speaks what it holds and closes.
    func finish() async {
        guard phase == .live, let stream else { return }
        phase = .finishing
        do {
            try await stream.finish()
        } catch {
            await stop()
        }
    }

    /// Closes now: the speaker goes quiet and nothing more is generated.
    func stop() async {
        guard isOpen else { return }
        let stopping = stream
        if phase == .connecting {
            end(.notStarted("Cancelled before any text was sent."))
        } else {
            end(.ended(summary(stopped: true)))
        }
        await stopping?.close()
    }

    /// Leaving the screen ends the session: nothing keeps talking where it cannot be seen.
    func leave() {
        // Ended, its last audio still playing out: that release does not stay armed after the
        // screen is gone.
        guard isOpen else {
            playback?.stopIfReleasePending()
            return
        }
        let stopping = stream
        end(.ended(LiveOutcome.leftScreen))
        Task { await stopping?.close() }
    }

    func endForAccountChange() -> Bool {
        guard isOpen else { return false }
        let stopping = stream
        end(.mayHaveBeenBilled(LiveOutcome.accountChanged))
        Task { await stopping?.close() }
        return true
    }

    /// Writes this session's audio to the output folder: WAV for PCM and μ-law, MP3 as it came.
    func save() async {
        saveProblem = nil
        guard !audio.isEmpty, let encoding = sessionEncoding else { return }
        guard let sink = context.sink() else {
            saveProblem = "There is nowhere to save it."
            return
        }
        let (data, ext, type): (Data, String, String)
        switch encoding {
        case .pcm(let rate): (data, ext, type) = (ElevenLabsRawAudio.wav(from: audio, encoding: .pcm16, sampleRate: Double(rate)), "wav", "audio/wav")
        case .ulaw: (data, ext, type) = (ElevenLabsRawAudio.wav(from: audio, encoding: .ulaw, sampleRate: 8_000), "wav", "audio/wav")
        case .alaw: (data, ext, type) = (ElevenLabsRawAudio.wav(from: audio, encoding: .alaw, sampleRate: 8_000), "wav", "audio/wav")
        case .mp3: (data, ext, type) = (audio, "mp3", "audio/mpeg")
        case .opus: (data, ext, type) = (audio, "ogg", "audio/ogg")
        }
        do {
            savedFile = try await LiveFiles.write(data, name: "live-speech", ext: ext, contentType: type,
                                                  operation: ElevenLabsLiveOperations.speech, sink: sink)
        } catch {
            saveProblem = "It could not be saved: \(ElevenLabsRedaction.redact(error.localizedDescription))"
        }
    }

    /// Keeps the counters fresh; and ends a session whose account is no longer the linked one.
    func tick() {
        now = Date()
        refresh()
        if isOpen, phase != .connecting, !guardian.accountIsCurrent { _ = endForAccountChange() }
    }

    // MARK: Session

    private func open() async -> Bool {
        let config = config
        guard let realtime = context.realtime() else {
            outcome = .notStarted(ElevenLabsError.notLinked.description)
            return false
        }
        resetSession()
        phase = .connecting
        let token = guardian.begin(client: realtime.client, work: self)
        sessionDescription = "\(voiceName(config.voiceID)) · \(config.modelID ?? "default model") · \(config.outputFormat ?? ElevenLabsSpeechStreamConfig.defaultOutputFormat)"
        do {
            let stream = try await realtime.speechStream(config)
            guard guardian.isCurrent(token), phase == .connecting else {
                await stream.close()
                return false
            }
            self.stream = stream
            sessionEncoding = config.outputEncoding
            // The last session's audio may still be playing out; it no longer gets to let go of
            // the devices this one is about to use.
            playback?.cancelPendingRelease()
            playback = config.outputEncoding.map {
                LivePlayback(audio: context.audio(), encoding: $0, claim: context.audio().claim())
            }
            phase = .live
            Task { await consume(stream, token: token) }
            Task { await watch(token: token) }
            return true
        } catch {
            guard guardian.isCurrent(token) else { return false }
            end(LiveOutcome.failedToStart(error))
            return false
        }
    }

    private func consume(_ stream: ElevenLabsSpeechStream, token: UUID) async {
        for await event in stream.events {
            guard guardian.isCurrent(token) else { continue }
            switch event {
            case .audio(let data, let alignment, _):
                let offset = Int((receivedSeconds * 1_000).rounded())
                if let seconds = sessionEncoding?.seconds(inBytes: data.count) { receivedSeconds += seconds }
                playback?.append(data)
                keep(data)
                if let alignment { addWords(alignment.shifted(by: offset)) }
            case .final:
                playback?.finish()
            case .message(let text):
                serverMessage = text
            case .unknown:
                break
            case .ended(let close):
                playback?.finish()
                let finishing = phase == .finishing
                if close.kind == .normal {
                    end(.ended(finishing ? summary(stopped: false)
                        : "The socket closed after \(inactivityTimeout) s without text. " + summary(stopped: false)),
                        silence: false)
                } else {
                    end(.mayHaveBeenBilled("The stream ended early: \(close.description). What was sent may have been billed."))
                }
            }
        }
    }

    private func watch(token: UUID) async {
        while guardian.isCurrent(token) {
            tick()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// - Parameter silence: Stop the speaker now (Stop, leaving, an account change, a failure);
    ///   otherwise what has arrived plays out.
    private func end(_ outcome: LiveOutcome, silence: Bool = true) {
        refresh()
        // The devices are let go: at once when silenced, once the last audio has played otherwise.
        if silence {
            playback?.stopAndRelease()
        } else {
            playback?.finishThenRelease()
        }
        self.outcome = outcome
        stream = nil
        phase = .ended
        guardian.end()
    }

    private func refresh() {
        if let stream { usage = stream.usage }
    }

    private func resetSession() {
        spoken = []
        words = []
        audio = Data()
        audioTruncated = false
        receivedSeconds = 0
        serverMessage = nil
        outcome = nil
        savedFile = nil
        saveProblem = nil
        usage = nil
    }

    private func keep(_ data: Data) {
        guard audio.count + data.count <= Self.audioLimit else {
            audioTruncated = true
            return
        }
        audio.append(data)
    }

    private func addWords(_ alignment: ElevenLabsAlignment) {
        for word in alignment.words {
            words.append(Word(id: nextWordID, text: word.word, startMs: word.startMs, endMs: word.endMs))
            nextWordID += 1
        }
        if words.count > 2_000 { words.removeFirst(words.count - 2_000) }
    }

    private func summary(stopped: Bool) -> String {
        let characters = usage?.charactersSent ?? 0
        let lead = stopped ? "Stopped." : "Done."
        return "\(lead) \(characters.formatted()) characters sent — ElevenLabs bills speech by the characters."
    }

    private func voiceName(_ id: String) -> String {
        context.pane?.voices.voice(id: id)?.name ?? id
    }
}

/// Writes a live screen's file through the sink, the way the client writes its own.
enum LiveFiles {
    static func write(
        _ data: Data, name: String, ext: String, contentType: String, operation: ElevenLabsOperation,
        sink: any ElevenLabsFileSink
    ) async throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        let url = try sink.destination(
            for: operation, suggestedName: "\(name)-\(formatter.string(from: Date())).\(ext)", contentType: contentType
        )
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .withoutOverwriting)
        await sink.didWrite(url, contentType: contentType, operation: operation)
        return url
    }
}
