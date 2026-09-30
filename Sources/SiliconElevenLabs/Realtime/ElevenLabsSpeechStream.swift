import Foundation

// MARK: - Settings

/// The settings of a streaming text-to-speech socket (`stream-input` and `multi-stream-input`
/// take the same query). Names follow the pinned AsyncAPI; nil leaves ElevenLabs' default.
public struct ElevenLabsSpeechStreamConfig: Sendable, Hashable {
    public var voiceID: String
    /// Default `eleven_multilingual_v2`. `eleven_v3` and `eleven_v4` are not available on this
    /// socket (ElevenLabs sends them to the Text to Dialogue socket instead), so they are refused.
    public var modelID: String?
    /// One of `socketOutputFormats`; ElevenLabs' default is `mp3_44100_128`. PCM plays without a
    /// streaming decoder.
    public var outputFormat: String?
    public var languageCode: String?
    /// Seconds without input before ElevenLabs closes the socket: 1 to 180, default 20.
    public var inactivityTimeout: Int?
    public var syncAlignment: Bool?
    /// Generates as soon as possible, without the chunk schedule — for whole sentences only.
    public var autoMode: Bool?
    /// `auto`, `on` or `off`.
    public var applyTextNormalization: String?
    public var seed: Int?
    public var enableSSMLParsing: Bool?
    /// False is zero-retention mode (Enterprise only).
    public var enableLogging: Bool?
    /// Sent once, in the first message.
    public var voiceSettings: ElevenLabsStreamVoiceSettings?
    /// Characters buffered before each of the first generations, each 50–500.
    public var chunkLengthSchedule: [Int]?
    /// Sent once, in the first message.
    public var pronunciationDictionaries: [ElevenLabsPronunciationLocator] = []

    public init(
        voiceID: String, modelID: String? = nil, outputFormat: String? = nil,
        languageCode: String? = nil, inactivityTimeout: Int? = nil, syncAlignment: Bool? = nil,
        autoMode: Bool? = nil, applyTextNormalization: String? = nil, seed: Int? = nil,
        enableSSMLParsing: Bool? = nil, enableLogging: Bool? = nil,
        voiceSettings: ElevenLabsStreamVoiceSettings? = nil, chunkLengthSchedule: [Int]? = nil,
        pronunciationDictionaries: [ElevenLabsPronunciationLocator] = []
    ) {
        self.voiceID = voiceID
        self.modelID = modelID
        self.outputFormat = outputFormat
        self.languageCode = languageCode
        self.inactivityTimeout = inactivityTimeout
        self.syncAlignment = syncAlignment
        self.autoMode = autoMode
        self.applyTextNormalization = applyTextNormalization
        self.seed = seed
        self.enableSSMLParsing = enableSSMLParsing
        self.enableLogging = enableLogging
        self.voiceSettings = voiceSettings
        self.chunkLengthSchedule = chunkLengthSchedule
        self.pronunciationDictionaries = pronunciationDictionaries
    }

    /// The output formats the streaming socket is known to take: the SDK's `OutputFormat` enum.
    /// The REST operations take more (`pcm_48000`, `opus_*`, `alaw_8000`…), unverified here.
    public static let socketOutputFormats = [
        "mp3_22050_32", "mp3_44100_32", "mp3_44100_64", "mp3_44100_96", "mp3_44100_128",
        "mp3_44100_192", "pcm_16000", "pcm_22050", "pcm_24000", "pcm_44100", "ulaw_8000",
    ]

    /// ElevenLabs' default output when none is asked for.
    public static let defaultOutputFormat = "mp3_44100_128"

    /// Models the socket does not serve.
    public static func isUnsupportedModel(_ model: String) -> Bool {
        let model = model.lowercased()
        return model.hasPrefix("eleven_v3") || model.hasPrefix("eleven_v4")
    }

    /// The encoding the audio will arrive in.
    public var outputEncoding: ElevenLabsAudioEncoding? {
        ElevenLabsAudioEncoding(name: outputFormat ?? Self.defaultOutputFormat)
    }

    /// Every reason these settings cannot be sent; empty when they can.
    public func problems() -> [String] {
        var problems = ElevenLabsRealtimeValidation.idProblems(voiceID, name: "voice_id")
        if let modelID {
            if modelID.trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("model_id is empty.")
            } else if Self.isUnsupportedModel(modelID) {
                problems.append("\(modelID) is not available when streaming text in; use Speech (the whole text at once) or Dialogue for it.")
            }
        }
        if let outputFormat, !Self.socketOutputFormats.contains(outputFormat) {
            problems.append("output_format must be one of " + Self.socketOutputFormats.joined(separator: ", ") + ".")
        }
        if let inactivityTimeout, !(1...180).contains(inactivityTimeout) {
            problems.append("inactivity_timeout must be from 1 to 180 seconds.")
        }
        if let seed, !(0...4_294_967_295).contains(seed) {
            problems.append("seed must be from 0 to 4294967295.")
        }
        if let applyTextNormalization, !["auto", "on", "off"].contains(applyTextNormalization) {
            problems.append("apply_text_normalization must be auto, on or off.")
        }
        if let schedule = chunkLengthSchedule {
            if schedule.isEmpty || schedule.contains(where: { !(50...500).contains($0) }) {
                problems.append("chunk_length_schedule must list sizes from 50 to 500 characters.")
            }
        }
        if let voiceSettings { problems += voiceSettings.problems() }
        if pronunciationDictionaries.contains(where: {
            !ElevenLabsRealtimeValidation.idProblems($0.dictionaryID, name: "pronunciation_dictionary_id").isEmpty
        }) {
            problems.append("Each pronunciation dictionary needs its id.")
        }
        return problems
    }

    /// The query, with booleans written `true`/`false` as the SDKs send them.
    func queryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        func add(_ name: String, _ value: String?) { if let value { items.append(URLQueryItem(name: name, value: value)) } }
        add("model_id", modelID)
        add("language_code", languageCode)
        add("output_format", outputFormat)
        add("inactivity_timeout", inactivityTimeout.map(String.init))
        add("sync_alignment", syncAlignment.map { $0 ? "true" : "false" })
        add("auto_mode", autoMode.map { $0 ? "true" : "false" })
        add("apply_text_normalization", applyTextNormalization)
        add("seed", seed.map(String.init))
        add("enable_ssml_parsing", enableSSMLParsing.map { $0 ? "true" : "false" })
        add("enable_logging", enableLogging.map { $0 ? "true" : "false" })
        return items
    }

    /// What the first message carries besides its text: the settings sent once.
    func initialFields() -> [String: JSONValue] {
        var fields: [String: JSONValue] = [:]
        if let voiceSettings, let json = voiceSettings.json { fields["voice_settings"] = json }
        if let chunkLengthSchedule {
            fields["generation_config"] = ["chunk_length_schedule": .array(chunkLengthSchedule.map { .number(Double($0)) })]
        }
        if !pronunciationDictionaries.isEmpty {
            fields["pronunciation_dictionary_locators"] = .array(pronunciationDictionaries.map(\.json))
        }
        return fields
    }
}

/// `voice_settings` on the speech sockets. Nil fields are left to the voice's own settings.
public struct ElevenLabsStreamVoiceSettings: Sendable, Hashable {
    public var stability: Double?
    public var similarityBoost: Double?
    public var style: Double?
    public var useSpeakerBoost: Bool?
    /// 0.7 to 1.2.
    public var speed: Double?

    public init(
        stability: Double? = nil, similarityBoost: Double? = nil, style: Double? = nil,
        useSpeakerBoost: Bool? = nil, speed: Double? = nil
    ) {
        self.stability = stability
        self.similarityBoost = similarityBoost
        self.style = style
        self.useSpeakerBoost = useSpeakerBoost
        self.speed = speed
    }

    func problems() -> [String] {
        var problems: [String] = []
        for (name, value) in [("stability", stability), ("similarity_boost", similarityBoost), ("style", style)] {
            if let value, !(0...1).contains(value) || !value.isFinite { problems.append("\(name) must be from 0 to 1.") }
        }
        if let speed, !(0.7...1.2).contains(speed) || !speed.isFinite { problems.append("speed must be from 0.7 to 1.2.") }
        return problems
    }

    var json: JSONValue? {
        var object: [String: JSONValue] = [:]
        if let stability { object["stability"] = .number(stability) }
        if let similarityBoost { object["similarity_boost"] = .number(similarityBoost) }
        if let style { object["style"] = .number(style) }
        if let useSpeakerBoost { object["use_speaker_boost"] = .bool(useSpeakerBoost) }
        if let speed { object["speed"] = .number(speed) }
        return object.isEmpty ? nil : .object(object)
    }
}

/// A pronunciation dictionary to apply, by id and (optionally) version.
public struct ElevenLabsPronunciationLocator: Sendable, Hashable {
    public var dictionaryID: String
    public var versionID: String?

    public init(dictionaryID: String, versionID: String? = nil) {
        self.dictionaryID = dictionaryID
        self.versionID = versionID
    }

    var json: JSONValue {
        var object: [String: JSONValue] = ["pronunciation_dictionary_id": .string(dictionaryID)]
        if let versionID { object["version_id"] = .string(versionID) }
        return .object(object)
    }
}

enum ElevenLabsRealtimeValidation {
    /// An id that goes into a URL path or query: not empty, not a path, nothing that would change
    /// the address it is put in.
    static func idProblems(_ id: String, name: String) -> [String] {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return ["\(name) is required."] }
        if trimmed != id || id.count > 200
            || id.contains(where: { "/\\?#%&=".contains($0) || $0.isNewline || $0.isWhitespace })
            || id == "." || id == ".." {
            return ["\(name) must be an id, not a path or an address."]
        }
        return []
    }
}

// MARK: - Text

/// Splits text for streaming the way ElevenLabs' own SDK does: at sentence and clause ends,
/// every piece ending in exactly one space, which the socket wants.
public enum ElevenLabsTextChunker {
    /// `text` in pieces of at most about `maximum` characters, split after punctuation where it
    /// can be, each ending with a single space. Whitespace-only text gives no pieces.
    public static func chunks(_ text: String, maximum: Int = 250) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        var pieces: [String] = []
        var current = ""
        let breakers: Set<Character> = [".", "!", "?", ";", ":", ",", "…", "—"]
        var previous: Character?
        for character in normalized {
            if character.isWhitespace, let previous, breakers.contains(previous), current.count >= 20 {
                pieces.append(current)
                current = ""
            } else if character.isWhitespace, current.count >= maximum {
                pieces.append(current)
                current = ""
            } else {
                current.append(character.isNewline ? " " : character)
            }
            previous = character
        }
        pieces.append(current)
        return pieces.compactMap { piece in
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed + " "
        }
    }
}

// MARK: - Events

/// What a speech socket hands back, in arrival order. `.ended` is always last.
public enum ElevenLabsSpeechStreamEvent: Sendable, Equatable {
    /// Audio in the stream's output format, with the character timings of this piece (relative
    /// to the piece) when ElevenLabs sent them.
    case audio(Data, alignment: ElevenLabsAlignment?, normalizedAlignment: ElevenLabsAlignment?)
    /// Everything sent so far has been spoken (`isFinal`).
    case final
    /// A message with no audio and only words in it — ElevenLabs' way of reporting a problem.
    case message(String)
    /// A frame this app does not know, by its keys.
    case unknown([String])
    case ended(ElevenLabsSocketClose)
}

extension ElevenLabsSpeechStreamEvent {
    /// Reads one `stream-input` frame. Both spellings of every key.
    static func decode(_ frame: JSONValue) -> [ElevenLabsSpeechStreamEvent] {
        guard frame.objectValue != nil else { return [.unknown([])] }
        var events: [ElevenLabsSpeechStreamEvent] = []
        if let text = frame["audio"].stringValue, !text.isEmpty, let audio = Data(looseBase64: text) {
            events.append(.audio(
                audio, alignment: ElevenLabsAlignment(json: frame["alignment"]),
                normalizedAlignment: ElevenLabsAlignment(json: frame.first("normalizedAlignment", "normalized_alignment"))
            ))
        }
        if frame.first("isFinal", "is_final").looseBool == true { events.append(.final) }
        if events.isEmpty {
            if let message = frame.first("message", "error", "detail").stringValue {
                events.append(.message(ElevenLabsRedaction.redact(message)))
            } else if frame["audio"] == .null, frame.objectValue?.keys.contains("audio") == true
                        || frame.objectValue?.keys.contains(where: { $0 == "isFinal" || $0 == "is_final" }) == true {
                // `{"audio": null, "isFinal": false}`: nothing to do.
            } else {
                events.append(.unknown((frame.objectValue?.keys.sorted()) ?? []))
            }
        }
        return events
    }
}

// MARK: - Single context

/// `stream-input`: one context, text in, audio out.
///
/// The first message (`" "` plus the settings) is sent when it opens. Text is sent in pieces
/// ending in a space; `flush` makes ElevenLabs speak what it holds now; `finish` sends the end
/// of the sequence (`""`), after which ElevenLabs speaks the rest and closes. A keepalive is a
/// single space — never `""`, which would end the stream.
public final class ElevenLabsSpeechStream: @unchecked Sendable {
    public let config: ElevenLabsSpeechStreamConfig
    public let events: AsyncStream<ElevenLabsSpeechStreamEvent>
    private let continuation: AsyncStream<ElevenLabsSpeechStreamEvent>.Continuation
    private let channel: ElevenLabsRealtimeChannel
    private let meter = UsageMeter()
    private let lock = NSLock()
    private var finished = false

    private init(channel: ElevenLabsRealtimeChannel, config: ElevenLabsSpeechStreamConfig) {
        self.channel = channel
        self.config = config
        (events, continuation) = AsyncStream<ElevenLabsSpeechStreamEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    static func start(
        on socket: any ElevenLabsSocket, config: ElevenLabsSpeechStreamConfig
    ) async throws -> ElevenLabsSpeechStream {
        let stream = ElevenLabsSpeechStream(channel: ElevenLabsRealtimeChannel(socket: socket), config: config)
        stream.channel.start(
            onFrame: { [weak stream] frame in stream?.receive(frame) },
            onEnd: { [weak stream] failure in stream?.end(failure) }
        )
        var first = config.initialFields()
        first["text"] = " "
        do {
            try await stream.channel.send(json: .object(first))
        } catch {
            await stream.close()
            throw error
        }
        return stream
    }

    /// What this session has used so far.
    public var usage: ElevenLabsRealtimeUsage { meter.snapshot }
    /// The format audio arrives in.
    public var outputEncoding: ElevenLabsAudioEncoding? { config.outputEncoding }

    /// Sends `text` to be spoken. It is given the trailing space the socket wants. Empty text is
    /// refused — `""` would end the stream; use `finish()` for that.
    public func send(_ text: String, flush: Bool = false, tryTriggerGeneration: Bool? = nil) async throws {
        let content = text.trimmingCharacters(in: .newlines)
        guard !content.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ElevenLabsRealtimeError.invalidConfiguration(["There is no text to send; an empty message would end the stream."])
        }
        try checkOpen()
        var message: [String: JSONValue] = ["text": .string(content.hasSuffix(" ") ? content : content + " ")]
        if flush { message["flush"] = true }
        if let tryTriggerGeneration { message["try_trigger_generation"] = .bool(tryTriggerGeneration) }
        try await channel.send(json: .object(message))
        let counted = content.hasSuffix(" ") ? String(content.dropLast()) : content
        meter.update { $0.charactersSent += counted.count }
    }

    /// Sends `text` in the pieces `ElevenLabsTextChunker` makes, flushing after the last.
    public func speak(_ text: String) async throws {
        let pieces = ElevenLabsTextChunker.chunks(text)
        guard !pieces.isEmpty else {
            throw ElevenLabsRealtimeError.invalidConfiguration(["There is no text to speak."])
        }
        for (index, piece) in pieces.enumerated() {
            try await send(piece, flush: index == pieces.count - 1)
        }
    }

    /// Makes ElevenLabs speak everything it holds now, and keeps the socket open.
    public func flush() async throws {
        try checkOpen()
        try await channel.send(json: ["text": " ", "flush": true])
    }

    /// Resets the inactivity clock: a single space, which is not the end of the sequence.
    public func keepAlive() async throws {
        try checkOpen()
        try await channel.send(json: ["text": " "])
    }

    /// The end of the sequence (`""`): ElevenLabs speaks what is left, sends `isFinal` and
    /// closes. Nothing more can be sent afterwards.
    public func finish() async throws {
        try checkOpen()
        lock.withLock { finished = true }
        try await channel.send(json: ["text": ""])
    }

    /// Closes the socket now: whatever has not been spoken is not.
    public func close() async {
        lock.withLock { finished = true }
        await channel.close(reason: "User ended session", discardingQueued: true)
    }

    /// Waits until the socket has ended.
    public func waitUntilEnded() async {
        await channel.waitForReader()
    }

    private func checkOpen() throws {
        if lock.withLock({ finished }) || channel.hasEnded { throw ElevenLabsRealtimeError.ended }
    }

    private func receive(_ message: ElevenLabsSocketMessage) {
        guard let frame = message.json else {
            continuation.yield(.unknown([]))
            return
        }
        for event in ElevenLabsSpeechStreamEvent.decode(frame) {
            if case .audio(let data, _, _) = event {
                meter.update { usage in
                    if usage.connectedAt == nil { usage.connectedAt = Date() }
                    usage.audioBytesReceived += data.count
                    if let seconds = config.outputEncoding?.seconds(inBytes: data.count) {
                        usage.audioSecondsReceived += seconds
                    }
                }
            }
            continuation.yield(event)
        }
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
