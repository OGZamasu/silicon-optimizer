import Foundation

/// What a multi-context speech socket hands back. `.ended` is always last.
public enum ElevenLabsSpeechMultiStreamEvent: Sendable, Equatable {
    /// Audio for a context (nil: the default context).
    case audio(context: String?, Data, alignment: ElevenLabsAlignment?, normalizedAlignment: ElevenLabsAlignment?)
    /// A context has finished: ElevenLabs sends this when it closes one.
    case contextFinished(String?)
    case message(String)
    case unknown([String])
    case ended(ElevenLabsSocketClose)
}

/// `multi-stream-input`: up to five independent contexts on one socket — for barge-in, where the
/// interrupted context is closed and the next one opened, or for overlapping lines.
///
/// Every message names its context with `context_id`. A context's first message may carry its
/// own voice settings; its keepalive is `""` (on this socket that does not end anything);
/// `closeContext` stops it, and audio still in flight for a closed context is dropped here —
/// the docs leave that bookkeeping to the client.
public final class ElevenLabsSpeechMultiStream: @unchecked Sendable {
    /// ElevenLabs' limit.
    public static let maximumContexts = 5

    public let config: ElevenLabsSpeechStreamConfig
    public let events: AsyncStream<ElevenLabsSpeechMultiStreamEvent>
    private let continuation: AsyncStream<ElevenLabsSpeechMultiStreamEvent>.Continuation
    private let channel: ElevenLabsRealtimeChannel
    private let meter = UsageMeter()
    private let lock = NSLock()
    private var open: Set<String> = []
    private var abandoned: Set<String> = []
    private var closingSocket = false

    private init(channel: ElevenLabsRealtimeChannel, config: ElevenLabsSpeechStreamConfig) {
        self.channel = channel
        self.config = config
        (events, continuation) = AsyncStream<ElevenLabsSpeechMultiStreamEvent>.makeStream(bufferingPolicy: .unbounded)
    }

    static func start(on socket: any ElevenLabsSocket, config: ElevenLabsSpeechStreamConfig) -> ElevenLabsSpeechMultiStream {
        let stream = ElevenLabsSpeechMultiStream(channel: ElevenLabsRealtimeChannel(socket: socket), config: config)
        stream.channel.start(
            onFrame: { [weak stream] frame in stream?.receive(frame) },
            onEnd: { [weak stream] failure in stream?.end(failure) }
        )
        return stream
    }

    public var usage: ElevenLabsRealtimeUsage { meter.snapshot }
    /// The contexts open now.
    public var openContexts: Set<String> { lock.withLock { open } }

    /// Opens (or re-opens, with new settings) context `id`, with its first text. The
    /// connection's voice settings, schedule and dictionaries go with it unless `settings`
    /// replaces them. A sixth open context is refused.
    public func openContext(
        _ id: String, text: String = " ", settings: ElevenLabsSpeechStreamConfig? = nil
    ) async throws {
        try Self.check(id)
        let refused: Bool = lock.withLock {
            if closingSocket { return true }
            return !open.contains(id) && open.count >= Self.maximumContexts
        }
        if lock.withLock({ closingSocket }) || channel.hasEnded { throw ElevenLabsRealtimeError.ended }
        if refused {
            throw ElevenLabsRealtimeError.invalidConfiguration([
                "A socket holds at most \(Self.maximumContexts) contexts; close one first.",
            ])
        }
        var message = (settings ?? config).initialFields()
        message["context_id"] = .string(id)
        message["text"] = .string(text.isEmpty ? " " : (text.hasSuffix(" ") ? text : text + " "))
        lock.withLock {
            open.insert(id)
            abandoned.remove(id)
        }
        try await channel.send(json: .object(message))
        let counted = text.trimmingCharacters(in: .whitespaces)
        meter.update { $0.charactersSent += counted.count }
    }

    /// Sends text to context `id`, which must be open.
    public func send(_ text: String, context id: String, flush: Bool = false) async throws {
        try Self.check(id)
        let content = text.trimmingCharacters(in: .newlines)
        guard !content.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ElevenLabsRealtimeError.invalidConfiguration(["There is no text to send."])
        }
        try checkOpen(id)
        var message: [String: JSONValue] = [
            "context_id": .string(id), "text": .string(content.hasSuffix(" ") ? content : content + " "),
        ]
        if flush { message["flush"] = true }
        try await channel.send(json: .object(message))
        let counted = content.hasSuffix(" ") ? String(content.dropLast()) : content
        meter.update { $0.charactersSent += counted.count }
    }

    /// Makes ElevenLabs speak what context `id` holds now.
    public func flush(context id: String) async throws {
        try Self.check(id)
        try checkOpen(id)
        try await channel.send(json: ["context_id": .string(id), "flush": true])
    }

    /// Resets context `id`'s inactivity clock: `""` with its id — on this socket not an end.
    public func keepAlive(context id: String) async throws {
        try Self.check(id)
        try checkOpen(id)
        try await channel.send(json: ["context_id": .string(id), "text": ""])
    }

    /// Stops context `id`. Audio for it that arrives afterwards is dropped.
    public func closeContext(_ id: String) async throws {
        try Self.check(id)
        try checkOpen(id)
        lock.withLock {
            open.remove(id)
            abandoned.insert(id)
        }
        try await channel.send(json: ["context_id": .string(id), "close_context": true])
    }

    /// Asks ElevenLabs to finish what is flushing and close every context and the socket.
    public func closeSocket() async throws {
        if channel.hasEnded { throw ElevenLabsRealtimeError.ended }
        lock.withLock { closingSocket = true }
        try await channel.send(json: ["close_socket": true])
    }

    /// Closes the socket now.
    public func close() async {
        lock.withLock { closingSocket = true }
        await channel.close(reason: "User ended session", discardingQueued: true)
    }

    public func waitUntilEnded() async {
        await channel.waitForReader()
    }

    static func check(_ id: String) throws {
        let problems = ElevenLabsRealtimeValidation.idProblems(id, name: "context_id")
        guard problems.isEmpty, id.count <= 64 else {
            throw ElevenLabsRealtimeError.invalidConfiguration(
                problems.isEmpty ? ["context_id must be at most 64 characters."] : problems
            )
        }
    }

    private func checkOpen(_ id: String) throws {
        let (isOpen, closing) = lock.withLock { (open.contains(id), closingSocket) }
        if closing || channel.hasEnded { throw ElevenLabsRealtimeError.ended }
        guard isOpen else {
            throw ElevenLabsRealtimeError.invalidConfiguration(["The context \(id) is not open."])
        }
    }

    private func receive(_ message: ElevenLabsSocketMessage) {
        guard let frame = message.json, frame.objectValue != nil else {
            continuation.yield(.unknown([]))
            return
        }
        let context = frame.first("contextId", "context_id").stringValue
        let dropped = context.map { id in lock.withLock { abandoned.contains(id) } } ?? false
        var yielded = false
        if let text = frame["audio"].stringValue, !text.isEmpty, let audio = Data(looseBase64: text) {
            yielded = true
            if !dropped {
                meter.update { usage in
                    if usage.connectedAt == nil { usage.connectedAt = Date() }
                    usage.audioBytesReceived += audio.count
                    if let seconds = config.outputEncoding?.seconds(inBytes: audio.count) {
                        usage.audioSecondsReceived += seconds
                    }
                }
                continuation.yield(.audio(
                    context: context, audio, alignment: ElevenLabsAlignment(json: frame["alignment"]),
                    normalizedAlignment: ElevenLabsAlignment(json: frame.first("normalizedAlignment", "normalized_alignment"))
                ))
            }
        }
        if frame.first("isFinal", "is_final").looseBool == true {
            yielded = true
            if let context { lock.withLock { _ = open.remove(context) } }
            continuation.yield(.contextFinished(context))
        }
        guard !yielded else { return }
        if let message = frame.first("message", "error", "detail").stringValue {
            continuation.yield(.message(ElevenLabsRedaction.redact(message)))
        } else if frame.objectValue?.keys.contains("audio") != true {
            continuation.yield(.unknown(frame.objectValue?.keys.sorted() ?? []))
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
