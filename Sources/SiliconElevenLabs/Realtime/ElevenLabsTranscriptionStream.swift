import Foundation

// MARK: - Settings

/// Realtime speech-to-text (Scribe v2 Realtime) settings, sent as the socket's query. Names are
/// the pinned AsyncAPI's; the ranges are the ones ElevenLabs' own clients check (the docs state
/// none), so a value they would refuse is refused here before anything is opened.
public struct ElevenLabsTranscriptionStreamConfig: Sendable, Hashable {
    public enum CommitStrategy: String, Sendable, Hashable, CaseIterable {
        /// Commits when told (`commit()`); ElevenLabs' default.
        case manual
        /// ElevenLabs commits at silences.
        case vad
    }

    public var modelID = "scribe_v2_realtime"
    /// PCM at 8–48 kHz or μ-law at 8 kHz, mono. 16 kHz PCM is ElevenLabs' recommendation.
    public var audioFormat: ElevenLabsAudioEncoding = .pcm(rate: 16_000)
    public var commitStrategy: CommitStrategy?
    public var vadSilenceThresholdSeconds: Double?
    public var vadThreshold: Double?
    public var minSpeechDurationMs: Int?
    public var minSilenceDurationMs: Int?
    public var languageCode: String?
    public var secondaryLanguages: [String] = []
    public var includeTimestamps: Bool?
    public var includeLanguageDetection: Bool?
    /// At most 50, each at most 20 characters. Adds 20 % to the cost.
    public var keyterms: [String] = []
    public var noVerbatim: Bool?
    /// `all`, `pii`, `phi`, `pci`, `other`, `offensive_language`, or entity types.
    public var entityDetection: [String] = []
    /// A plain-language edit applied to each commit, at most 2,000 characters. Adds 30 % to the
    /// cost, billed for at least 10 seconds of audio per commit. Not with `entityDetection`.
    public var transcriptEdit: String?
    /// Not with `includeTimestamps`.
    public var filterBackgroundAudio: Bool?
    /// False is zero-retention mode (Enterprise only).
    public var enableLogging: Bool?
    /// Context for the first chunk only (a topic, what was said before); best under 50 characters.
    public var previousText: String?

    public init(audioFormat: ElevenLabsAudioEncoding = .pcm(rate: 16_000)) {
        self.audioFormat = audioFormat
    }

    /// The encodings the socket takes.
    public static let audioFormats: [ElevenLabsAudioEncoding] = [
        .pcm(rate: 8_000), .pcm(rate: 16_000), .pcm(rate: 22_050), .pcm(rate: 24_000),
        .pcm(rate: 44_100), .pcm(rate: 48_000), .ulaw,
    ]

    public static let maximumKeyterms = 50
    public static let maximumKeytermLength = 20
    public static let maximumTranscriptEdit = 2_000

    public func problems() -> [String] {
        var problems: [String] = []
        if modelID != "scribe_v2_realtime" { problems.append("model_id must be scribe_v2_realtime.") }
        if !Self.audioFormats.contains(audioFormat) {
            problems.append("audio_format must be one of " + Self.audioFormats.map(\.name).joined(separator: ", ") + ".")
        }
        func range<T: Comparable>(_ value: T?, _ bounds: ClosedRange<T>, _ text: String) {
            if let value, !bounds.contains(value) { problems.append(text) }
        }
        range(vadSilenceThresholdSeconds, 0.3...3.0, "vad_silence_threshold_secs must be from 0.3 to 3.")
        range(vadThreshold, 0.1...0.9, "vad_threshold must be from 0.1 to 0.9.")
        range(minSpeechDurationMs, 50...2_000, "min_speech_duration_ms must be from 50 to 2000.")
        range(minSilenceDurationMs, 50...2_000, "min_silence_duration_ms must be from 50 to 2000.")
        if keyterms.count > Self.maximumKeyterms {
            problems.append("At most \(Self.maximumKeyterms) key terms.")
        }
        if keyterms.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.count > Self.maximumKeytermLength }) {
            problems.append("Each key term must be 1 to \(Self.maximumKeytermLength) characters.")
        }
        if let transcriptEdit {
            if transcriptEdit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                problems.append("transcript_edit is empty.")
            } else if transcriptEdit.count > Self.maximumTranscriptEdit {
                problems.append("transcript_edit must be at most \(Self.maximumTranscriptEdit) characters.")
            }
            if !entityDetection.isEmpty {
                problems.append("transcript_edit cannot be combined with entity_detection; ElevenLabs refuses the connection.")
            }
        }
        if filterBackgroundAudio == true, includeTimestamps == true {
            problems.append("filter_background_audio cannot be combined with include_timestamps.")
        }
        for code in [languageCode].compactMap({ $0 }) + secondaryLanguages
        where !(2...3).contains(code.count) || !code.allSatisfy(\.isLetter) {
            problems.append("\"\(code.prefix(12))\" is not an ISO 639-1 or 639-3 language code.")
        }
        return problems
    }

    /// The query. Lists are repeated keys (`keyterms=a&keyterms=b`), booleans `true`/`false`.
    func queryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model_id", value: modelID),
            URLQueryItem(name: "audio_format", value: audioFormat.name),
        ]
        func add(_ name: String, _ value: String?) { if let value { items.append(URLQueryItem(name: name, value: value)) } }
        func flag(_ value: Bool?) -> String? { value.map { $0 ? "true" : "false" } }
        add("commit_strategy", commitStrategy?.rawValue)
        add("vad_silence_threshold_secs", vadSilenceThresholdSeconds.map { String($0) })
        add("vad_threshold", vadThreshold.map { String($0) })
        add("min_speech_duration_ms", minSpeechDurationMs.map(String.init))
        add("min_silence_duration_ms", minSilenceDurationMs.map(String.init))
        add("language_code", languageCode)
        for language in secondaryLanguages { add("secondary_languages", language) }
        add("include_timestamps", flag(includeTimestamps))
        add("include_language_detection", flag(includeLanguageDetection))
        for term in keyterms { add("keyterms", term) }
        add("no_verbatim", flag(noVerbatim))
        for entity in entityDetection { add("entity_detection", entity) }
        add("transcript_edit", transcriptEdit)
        add("filter_background_audio", flag(filterBackgroundAudio))
        add("enable_logging", flag(enableLogging))
        return items
    }

    /// The cost add-ons these settings switch on, in ElevenLabs' words.
    public var costAddOns: [String] {
        var notes: [String] = []
        if !keyterms.isEmpty { notes.append("Key terms add 20 % to the transcription cost.") }
        if transcriptEdit != nil {
            notes.append("A transcript edit adds 30 %, billed for at least 10 seconds of audio per commit.")
        }
        return notes
    }
}

// MARK: - Events

/// A word (or the space between words) with its timing in seconds.
public struct ElevenLabsTranscriptWord: Sendable, Equatable, Hashable {
    public var text: String
    public var start: Double?
    public var end: Double?
    /// `word`, `spacing`, or whatever else ElevenLabs sends (`audio_event`), kept as sent.
    public var type: String?
    public var speakerID: String?

    public init(text: String, start: Double?, end: Double?, type: String?, speakerID: String?) {
        self.text = text
        self.start = start
        self.end = end
        self.type = type
        self.speakerID = speakerID
    }

    init?(json: JSONValue) {
        guard let text = json["text"].stringValue else { return nil }
        self.text = text
        start = json["start"].looseDouble
        end = json["end"].looseDouble
        type = json["type"].stringValue
        speakerID = json["speaker_id"].stringValue
    }
}

public struct ElevenLabsTranscriptEntity: Sendable, Equatable, Hashable {
    public var text: String
    public var type: String
    public var startCharacter: Int?
    public var endCharacter: Int?

    init?(json: JSONValue) {
        guard let text = json["text"].stringValue else { return nil }
        self.text = text
        type = json.first("entity_type", "type").stringValue ?? "entity"
        startCharacter = json["start_char"].looseInt
        endCharacter = json["end_char"].looseInt
    }
}

/// What the transcription socket hands back. `.ended` is always last.
public enum ElevenLabsTranscriptionStreamEvent: Sendable, Equatable {
    /// The session is open, with the settings ElevenLabs actually applied.
    case started(sessionID: String?, config: JSONValue)
    /// Interim text for the segment in progress; each replaces the last.
    case partial(String)
    /// The final text of a segment.
    case committed(String)
    case committedWithTimestamps(text: String, languageCode: String?, words: [ElevenLabsTranscriptWord])
    case entities(text: String, [ElevenLabsTranscriptEntity])
    /// The transcript edit of a committed segment — may arrive out of commit order.
    case edited(text: String, editedText: String)
    /// Not fatal; the session goes on.
    case warning(String)
    /// One of ElevenLabs' error types (`auth_error`, `quota_exceeded`, `commit_throttled`…);
    /// the socket usually closes after it.
    case error(type: String, message: String)
    /// Sent by some SDK versions and not by the documented API; the committed messages are the
    /// ones to rely on.
    case finalTranscript(String)
    case unknown(String)
    case ended(ElevenLabsSocketClose)
}

extension ElevenLabsTranscriptionStreamEvent {
    /// The error types every source lists, and the deprecated alias one SDK keeps.
    public static let errorTypes: Set<String> = [
        "auth_error", "quota_exceeded", "transcriber_error", "input_error", "invalid_request", "error",
        "commit_throttled", "unaccepted_terms", "rate_limited", "queue_overflow", "resource_exhausted",
        "session_time_limit_exceeded", "chunk_size_exceeded", "insufficient_audio_activity",
        "unaccepted_terms_error",
    ]

    static func decode(_ frame: JSONValue) -> ElevenLabsTranscriptionStreamEvent {
        let type = frame.first("message_type", "type").stringValue ?? ""
        let text = frame["text"].stringValue ?? ""
        switch type {
        case "session_started":
            return .started(sessionID: frame["session_id"].stringValue, config: frame["config"])
        case "partial_transcript":
            return .partial(text)
        case "committed_transcript":
            return .committed(text)
        case "committed_transcript_with_timestamps":
            return .committedWithTimestamps(
                text: text, languageCode: frame["language_code"].stringValue,
                words: (frame["words"].arrayValue ?? []).compactMap(ElevenLabsTranscriptWord.init(json:))
            )
        case "committed_transcript_entities":
            return .entities(text: text, (frame["entities"].arrayValue ?? []).compactMap(ElevenLabsTranscriptEntity.init(json:)))
        case "edited_transcript":
            return .edited(text: text, editedText: frame["edited_text"].stringValue ?? "")
        case "warning":
            return .warning(ElevenLabsRealtimeRedaction.scrub(frame.first("warning", "message").stringValue ?? "A warning without words."))
        case "final_transcript", "final_transcript_with_timestamps":
            return .finalTranscript(text)
        case let error where errorTypes.contains(error):
            return .error(
                type: error,
                message: ElevenLabsRealtimeRedaction.scrub(frame.first("error", "message").stringValue ?? "")
            )
        default:
            if frame["error"].stringValue != nil {
                return .error(type: type.isEmpty ? "error" : type,
                              message: ElevenLabsRealtimeRedaction.scrub(frame["error"].stringValue ?? ""))
            }
            return .unknown(type)
        }
    }
}

// MARK: - Session

/// Realtime speech-to-text: audio in (`input_audio_chunk`, base64, mono, in the socket's
/// format), partial and committed transcripts out.
///
/// Audio longer than a second is sent in one-second pieces (ElevenLabs asks for 0.1–1 s). A
/// manual commit is an empty chunk with `commit: true`. `previous_text` goes with the first chunk
/// only; ElevenLabs refuses it later. There is no keepalive but audio: a caller that mutes the
/// microphone should keep sending silence.
public final class ElevenLabsTranscriptionStream: @unchecked Sendable {
    public let config: ElevenLabsTranscriptionStreamConfig
    public let events: AsyncStream<ElevenLabsTranscriptionStreamEvent>
    private let continuation: AsyncStream<ElevenLabsTranscriptionStreamEvent>.Continuation
    private let channel: ElevenLabsRealtimeChannel
    private let meter = UsageMeter()
    private let lock = NSLock()
    private var sentFirst = false
    private var closing = false

    private init(channel: ElevenLabsRealtimeChannel, config: ElevenLabsTranscriptionStreamConfig) {
        self.channel = channel
        self.config = config
        (events, continuation) = AsyncStream<ElevenLabsTranscriptionStreamEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    static func start(on socket: any ElevenLabsSocket, config: ElevenLabsTranscriptionStreamConfig) -> ElevenLabsTranscriptionStream {
        let stream = ElevenLabsTranscriptionStream(channel: ElevenLabsRealtimeChannel(socket: socket), config: config)
        stream.channel.start(
            onFrame: { [weak stream] frame in stream?.receive(frame) },
            onEnd: { [weak stream] failure in stream?.end(failure) }
        )
        return stream
    }

    public var usage: ElevenLabsRealtimeUsage { meter.snapshot }

    /// Bytes in one second of the socket's audio.
    public var bytesPerSecond: Int { config.audioFormat.bytesPerSecond ?? 32_000 }

    /// Sends audio already in the socket's format. Split into pieces of at most a second.
    public func sendAudio(_ audio: Data) async throws {
        guard !audio.isEmpty else { return }
        try checkOpen()
        let piece = bytesPerSecond
        var offset = audio.startIndex
        while offset < audio.endIndex {
            let end = audio.index(offset, offsetBy: piece, limitedBy: audio.endIndex) ?? audio.endIndex
            try await sendChunk(Data(audio[offset..<end]), commit: false)
            offset = end
        }
    }

    /// Commits what was said since the last commit: an empty chunk with `commit: true`.
    public func commit() async throws {
        try checkOpen()
        try await sendChunk(Data(), commit: true)
        meter.update { $0.commits += 1 }
    }

    /// Closes the socket (1000).
    public func close() async {
        lock.withLock { closing = true }
        await channel.close(reason: "User ended session")
    }

    public func waitUntilEnded() async {
        await channel.waitForReader()
    }

    private func checkOpen() throws {
        if lock.withLock({ closing }) || channel.hasEnded { throw ElevenLabsRealtimeError.ended }
    }

    private func sendChunk(_ audio: Data, commit: Bool) async throws {
        var message: [String: JSONValue] = [
            "message_type": "input_audio_chunk", "audio_base_64": .string(audio.base64EncodedString()),
            "commit": .bool(commit), "sample_rate": .number(Double(config.audioFormat.sampleRate)),
        ]
        let first = lock.withLock {
            defer { sentFirst = true }
            return !sentFirst
        }
        if first, let previous = config.previousText, !previous.isEmpty {
            message["previous_text"] = .string(previous)
        }
        try await channel.send(json: .object(message))
        if let seconds = config.audioFormat.seconds(inBytes: audio.count) {
            meter.update { $0.audioSecondsSent += seconds }
        }
    }

    private func receive(_ message: ElevenLabsSocketMessage) {
        guard let frame = message.json, frame.objectValue != nil else {
            continuation.yield(.unknown(""))
            return
        }
        let event = ElevenLabsTranscriptionStreamEvent.decode(frame)
        if case .started = event { meter.update { $0.connectedAt = $0.connectedAt ?? Date() } }
        continuation.yield(event)
    }

    private func end(_ failure: ElevenLabsRealtimeError) {
        meter.update { $0.endedAt = Date() }
        let close: ElevenLabsSocketClose = if case .closed(let close) = failure {
            close
        } else {
            ElevenLabsSocketClose(code: 0, reason: failure.description)
        }
        continuation.yield(.ended(close))
        continuation.finish()
    }
}
