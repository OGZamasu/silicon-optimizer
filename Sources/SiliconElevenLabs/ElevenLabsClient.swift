import Foundation

/// Calls ElevenLabs on the owner's behalf: one instance per linked key and region.
///
/// Every operation in `ElevenLabsCatalog` is reachable through `call`, and the typed helpers
/// in `ElevenLabsClient+Helpers.swift` are thin wrappers over it. The key is read from the
/// credential source at the moment a request is built, sent only in the `xi-api-key` header,
/// and only to the region's host over https. Nothing is sent until the arguments check out;
/// a billable request is never sent twice.
public actor ElevenLabsClient {

    /// Size and time bounds. The defaults suit the app; tests shrink them.
    public struct Limits: Sendable {
        /// The largest JSON or text answer held in memory.
        public var inlineBytes: Int = 64 << 20
        /// The largest body written to a file.
        public var fileBytes: Int64 = 8 << 30
        /// The largest multipart upload, all files together.
        public var uploadBytes: Int64 = 3 << 30
        /// Reads and edits.
        public var quickTimeout: TimeInterval = 60
        /// Generations: speech, music, sound, design.
        public var generationTimeout: TimeInterval = 600
        /// Uploads, dubbing, transcription of long files.
        public var uploadTimeout: TimeInterval = 1_800
        /// How long a streamed answer may go quiet.
        public var streamIdleTimeout: TimeInterval = 120
        /// Retries of a read after a 429, a 5xx or a failed connection.
        public var retries: Int = 3
        /// The longest single wait before a retry, whatever `Retry-After` asks.
        public var longestRetryWait: TimeInterval = 20
        /// The first backoff when there is no `Retry-After`; doubled each time.
        public var firstBackoff: TimeInterval = 1

        public init() {}
    }

    public nonisolated let region: ElevenLabsRegion
    let credentials: any ElevenLabsCredentialSource
    let transport: any ElevenLabsTransport
    let sink: any ElevenLabsFileSink
    let limits: Limits
    let gate: ElevenLabsGate

    public init(
        credentials: any ElevenLabsCredentialSource, region: ElevenLabsRegion,
        transport: any ElevenLabsTransport, sink: any ElevenLabsFileSink,
        limits: Limits = Limits()
    ) {
        self.credentials = credentials
        self.region = region
        self.transport = transport
        self.sink = sink
        self.limits = limits
        gate = ElevenLabsGate(limit: 2)
    }

    // MARK: - Calls

    /// Runs one operation to completion. Big bodies go to the file sink; JSON comes back
    /// inline (base64 audio inside it saved to files); SSE and streamed JSON are collected.
    ///
    /// - Parameters:
    ///   - arguments: Path, query and header parameters by name, and the body's fields by
    ///     name (a JSON body may also be given whole as `body`).
    ///   - files: Multipart file fields by name.
    public func call(
        _ operationID: String, arguments: [String: JSONValue] = [:],
        files: [String: [ElevenLabsFile]] = [:]
    ) async throws -> ElevenLabsResult {
        guard let operation = ElevenLabsCatalog.operation(operationID) else {
            throw ElevenLabsError.unknownOperation(operationID)
        }
        return try await call(operation, arguments: arguments, files: files)
    }

    /// `call` for an operation already in hand.
    public func call(
        _ operation: ElevenLabsOperation, arguments: [String: JSONValue] = [:],
        files: [String: [ElevenLabsFile]] = [:]
    ) async throws -> ElevenLabsResult {
        let prepared = try prepare(operation, arguments: arguments, files: files)
        let outputFormat = arguments["output_format"]?.stringValue
        let collectsStream = operation.response == .events
            || (operation.supportsStreaming && operation.response == .json)
        return try await withSlot {
            if collectsStream {
                return try await self.collectStream(prepared, outputFormat: outputFormat)
            }
            return try await self.send(prepared, outputFormat: outputFormat)
        }
    }

    /// Runs one operation and hands its body over as it arrives: `.started` first, then
    /// audio, events or bytes. Cancelling the consuming task cancels the request.
    public nonisolated func stream(
        _ operationID: String, arguments: [String: JSONValue] = [:],
        files: [String: [ElevenLabsFile]] = [:]
    ) -> AsyncThrowingStream<ElevenLabsChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let operation = ElevenLabsCatalog.operation(operationID) else {
                        throw ElevenLabsError.unknownOperation(operationID)
                    }
                    try await self.runStream(operation, arguments: arguments, files: files) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalized(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// What `call` would send for these arguments, with the key left out — for "Show API
    /// call". Throws what `call` would throw for invalid arguments.
    public nonisolated func describe(
        _ operationID: String, arguments: [String: JSONValue] = [:],
        files: [String: [ElevenLabsFile]] = [:]
    ) throws -> ElevenLabsCallDescription {
        guard let operation = ElevenLabsCatalog.operation(operationID) else {
            throw ElevenLabsError.unknownOperation(operationID)
        }
        return try prepare(operation, arguments: arguments, files: files).describe()
    }

    /// Every problem with these arguments, or none. `call` refuses when this is not empty.
    public nonisolated func validate(
        _ operationID: String, arguments: [String: JSONValue] = [:],
        files: [String: [ElevenLabsFile]] = [:]
    ) -> [String] {
        guard let operation = ElevenLabsCatalog.operation(operationID) else {
            return ["There is no ElevenLabs operation named \"\(operationID)\"."]
        }
        do {
            _ = try prepare(operation, arguments: arguments, files: files)
            return []
        } catch ElevenLabsError.invalidArguments(let problems) {
            return problems
        } catch {
            return ["\(error)"]
        }
    }

    // MARK: - Account

    /// `GET /v1/user` and `GET /v1/user/subscription`, both free: the plan, the balance and
    /// when it resets. Connect calls this to verify a key before storing it. Sets the number of
    /// requests this client lets run at once from the plan.
    public func account() async throws -> ElevenLabsAccount {
        let user = try await call("get_user_info")
        let subscription = try await call("get_user_subscription_info")
        guard case .json(let userJSON, _) = user, case .json(let plan, _) = subscription else {
            throw ElevenLabsError.api(status: 200, code: nil,
                                      message: "The account answer was not JSON.", requestID: nil)
        }
        let tier = plan["tier"].stringValue ?? userJSON["subscription"]["tier"].stringValue ?? "unknown"
        let concurrency = Self.concurrency(forTier: tier)
        await gate.setLimit(concurrency)
        return ElevenLabsAccount(
            userID: userJSON["user_id"].stringValue ?? "",
            firstName: userJSON["first_name"].stringValue,
            tier: tier,
            status: plan["status"].stringValue,
            characterCount: plan["character_count"].intValue ?? 0,
            characterLimit: plan["character_limit"].intValue ?? 0,
            nextResetAt: plan["next_character_count_reset_unix"].doubleValue.map(Date.init(timeIntervalSince1970:)),
            voiceSlotsUsed: plan["voice_slots_used"].intValue,
            voiceLimit: plan["voice_limit"].intValue,
            professionalVoiceLimit: plan["professional_voice_limit"].intValue,
            canUseInstantVoiceCloning: plan["can_use_instant_voice_cloning"].boolValue,
            canUseProfessionalVoiceCloning: plan["can_use_professional_voice_cloning"].boolValue,
            concurrencyLimit: concurrency
        )
    }

    /// Requests at once, by plan: ElevenLabs' published concurrency (free 2, starter 3,
    /// creator 5, higher plans more), capped at 5 — one Mac has no use for more — and 2 for a
    /// plan this table does not know.
    static func concurrency(forTier tier: String) -> Int {
        switch tier.lowercased() {
        case "free": 2
        case "starter": 3
        case let name where name.hasPrefix("creator") || name.hasPrefix("pro")
            || name.hasPrefix("scale") || name.hasPrefix("business") || name.hasPrefix("growing")
            || name.hasPrefix("enterprise"): 5
        default: 2
        }
    }

    /// How many requests may run at once right now.
    public var concurrencyLimit: Int { get async { await gate.limit } }

    // MARK: - Preparing

    nonisolated func prepare(
        _ operation: ElevenLabsOperation, arguments: [String: JSONValue],
        files: [String: [ElevenLabsFile]]
    ) throws -> PreparedCall {
        switch ElevenLabsRequestBuilder.prepare(
            operation, arguments: arguments, files: files, region: region,
            uploadLimit: limits.uploadBytes
        ) {
        case .success(let prepared): return prepared
        case .failure(let error): throw error
        }
    }

    /// The request as it goes out: the key added, the multipart body assembled on disk.
    /// The caller removes `upload` when the call is over.
    private func materialize(
        _ prepared: PreparedCall, handling: ElevenLabsRequest.ResponseHandling, timeout: TimeInterval
    ) async throws -> (request: ElevenLabsRequest, key: String, upload: URL?) {
        let key = try await readKey()
        guard prepared.url.scheme == "https", let host = prepared.url.host,
              host == region.host, ElevenLabsRegion.allowedHosts.contains(host)
        else { throw ElevenLabsError.refusedHost(prepared.url.host ?? prepared.url.absoluteString) }

        var headers = prepared.headers
        headers["xi-api-key"] = key
        headers["Accept"] = "*/*"
        var body: ElevenLabsRequest.Body = .none
        var upload: URL?
        switch prepared.body {
        case .none:
            break
        case .json(let value):
            headers["Content-Type"] = "application/json"
            body = .data(value.encoded())
        case .multipart(let parts):
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("elevenlabs-upload-\(UUID().uuidString).multipart")
            upload = file
            do {
                headers["Content-Type"] = try MultipartWriter.write(parts, to: file)
            } catch {
                try? FileManager.default.removeItem(at: file)
                throw error
            }
            body = .file(file)
        }
        let request = ElevenLabsRequest(
            operationID: prepared.operation.id, method: prepared.operation.method,
            url: prepared.url, headers: headers, body: body, timeout: timeout,
            responseHandling: handling
        )
        return (request, key, upload)
    }

    private func readKey() async throws -> String {
        let key: String?
        do {
            key = try await credentials.apiKey()
        } catch let error as ElevenLabsError {
            throw error
        } catch {
            throw ElevenLabsError.credentialUnavailable(ElevenLabsRedaction.redact("\(error)"))
        }
        guard let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            throw ElevenLabsError.notLinked
        }
        return key
    }

    func timeout(for operation: ElevenLabsOperation) -> TimeInterval {
        if operation.body?.contentType == .multipart || operation.group.hasPrefix("Dubbing") {
            return limits.uploadTimeout
        }
        if operation.risk == .generate { return limits.generationTimeout }
        return limits.quickTimeout
    }

    // MARK: - Sending

    /// One request, whole answer. Retried only where a retry cannot bill twice.
    private func send(_ prepared: PreparedCall, outputFormat: String?) async throws -> ElevenLabsResult {
        let operation = prepared.operation
        let wantsFile = operation.response.isFile || operation.response == .multipartMixed
        let handling: ElevenLabsRequest.ResponseHandling = wantsFile
            ? .file(limit: limits.fileBytes) : .memory(limit: limits.inlineBytes)
        let (request, key, upload) = try await materialize(
            prepared, handling: handling, timeout: timeout(for: operation)
        )
        defer { if let upload { try? FileManager.default.removeItem(at: upload) } }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            let response: ElevenLabsResponse
            do {
                response = try await transport.send(request)
            } catch {
                let failure = Self.normalized(error, key: key)
                if case .network = failure, retriesSafely(operation), attempt < limits.retries {
                    attempt += 1
                    try await pause(backoff(attempt: attempt, retryAfter: nil))
                    continue
                }
                throw failure
            }
            let meta = Self.meta(from: response.status, headers: response.headers)
            if (200..<300).contains(response.status) {
                return try await decode(response, meta: meta, operation: operation, outputFormat: outputFormat)
            }
            let bytes = Self.errorBytes(response.body)
            let retryAfter = Self.retryAfter(response.headers)
            let transient = response.status == 429 || [500, 502, 503, 504].contains(response.status)
            if transient, attempt < limits.retries,
               response.status == 429 ? !operation.billable : retriesSafely(operation) {
                attempt += 1
                try await pause(backoff(attempt: attempt, retryAfter: retryAfter))
                continue
            }
            throw Self.apiError(status: response.status, headers: response.headers, body: bytes,
                                key: key, region: region, retryAfter: retryAfter)
        }
    }

    /// Whether sending again is harmless: reads only. A 429 is a refusal before any work, so
    /// that alone may also be retried for non-billable edits; a lost connection may not — the
    /// first attempt may have landed.
    private func retriesSafely(_ operation: ElevenLabsOperation) -> Bool {
        operation.risk == .read
    }

    private func backoff(attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        let wait = retryAfter ?? limits.firstBackoff * pow(2, Double(attempt - 1))
        return min(max(wait, 0), limits.longestRetryWait)
    }

    private func pause(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        do { try await Task.sleep(for: .milliseconds(Int(seconds * 1_000))) } catch {
            throw ElevenLabsError.cancelled
        }
    }

    /// A 2xx answer, turned into a result.
    private func decode(
        _ response: ElevenLabsResponse, meta: ElevenLabsMeta, operation: ElevenLabsOperation,
        outputFormat: String?
    ) async throws -> ElevenLabsResult {
        let contentType = meta.contentType
        switch response.body {
        case .data(let data):
            if operation.response == .text || (contentType?.hasPrefix("text/") == true && !Self.isJSON(contentType)) {
                return .text(String(decoding: data, as: UTF8.self), meta)
            }
            return try await jsonResult(data, meta: meta, operation: operation, outputFormat: outputFormat)
        case .file(let temporary):
            defer { try? FileManager.default.removeItem(at: temporary) }
            // An error-free answer can still be JSON where the spec promised a file.
            if Self.isJSON(contentType) {
                let data = try Data(contentsOf: temporary, options: .alwaysMapped)
                guard data.count <= limits.inlineBytes else {
                    throw ElevenLabsError.tooLarge("a JSON answer of \(data.count) bytes")
                }
                return try await jsonResult(Data(data), meta: meta, operation: operation, outputFormat: outputFormat)
            }
            if operation.response == .multipartMixed || contentType?.lowercased().hasPrefix("multipart/") == true {
                return try await splitMixed(temporary, meta: meta, operation: operation)
            }
            let ext = ElevenLabsFileTypes.fileExtension(contentType: contentType, outputFormat: outputFormat)
            let type = contentType ?? Self.defaultContentType(operation.response)
            let (url, bytes) = try await store(temporary, name: Self.fileName(operation, ext: ext),
                                               contentType: type, operation: operation)
            return .file(url, contentType: type, bytes: bytes, meta)
        }
    }

    /// JSON, with any base64 audio inside it moved into files.
    private func jsonResult(
        _ data: Data, meta: ElevenLabsMeta, operation: ElevenLabsOperation, outputFormat: String?
    ) async throws -> ElevenLabsResult {
        let trimmed = data.drop { $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        guard !trimmed.isEmpty else { return .json(.null, meta) }
        guard let value = try? JSONValue.parse(data) else {
            return .text(String(decoding: data, as: UTF8.self), meta)
        }
        let (cleaned, audio) = Base64Audio.extract(from: value)
        guard !audio.isEmpty else { return .json(value, meta) }
        var parts: [ElevenLabsResultPart] = [.json(cleaned)]
        let ext = ElevenLabsFileTypes.fileExtension(contentType: nil, outputFormat: outputFormat ?? "mp3")
        for (index, clip) in audio.enumerated() {
            let name = Self.fileName(operation, ext: ext, index: audio.count > 1 ? index + 1 : nil)
            let (url, bytes) = try await write(clip, name: name, contentType: "audio/\(ext == "mp3" ? "mpeg" : ext)", operation: operation)
            parts.append(.file(url, contentType: "audio/\(ext == "mp3" ? "mpeg" : ext)", bytes: bytes))
        }
        return .parts(parts, meta)
    }

    /// `multipart/mixed`: the JSON part inline, every other part to a file.
    private func splitMixed(
        _ temporary: URL, meta: ElevenLabsMeta, operation: ElevenLabsOperation
    ) async throws -> ElevenLabsResult {
        let data = try Data(contentsOf: temporary, options: .alwaysMapped)
        guard let boundary = MultipartMixed.boundary(fromContentType: meta.contentType) else {
            throw ElevenLabsError.api(status: meta.status, code: nil,
                                      message: "A multipart answer came without a boundary.",
                                      requestID: meta.requestID)
        }
        var parts: [ElevenLabsResultPart] = []
        for (index, part) in MultipartMixed.split(data, boundary: boundary).enumerated() {
            if Self.isJSON(part.contentType), let value = try? JSONValue.parse(part.body) {
                parts.append(.json(value))
            } else if part.contentType.hasPrefix("text/") {
                parts.append(.text(String(decoding: part.body, as: UTF8.self)))
            } else {
                let ext = ElevenLabsFileTypes.fileExtension(contentType: part.contentType, outputFormat: nil)
                let name = part.filename.map(ElevenLabsFileNames.sanitized)
                    ?? Self.fileName(operation, ext: ext, index: index + 1)
                let (url, bytes) = try await write(part.body, name: name, contentType: part.contentType, operation: operation)
                parts.append(.file(url, contentType: part.contentType, bytes: bytes))
            }
        }
        return .parts(parts, meta)
    }

    // MARK: - Streaming

    /// Collects a streamed answer (SSE, or JSON chunks) for `call`: audio joined into one
    /// file as it arrives, everything else kept as events.
    private func collectStream(_ prepared: PreparedCall, outputFormat: String?) async throws -> ElevenLabsResult {
        let operation = prepared.operation
        var events: [JSONValue] = []
        var meta = ElevenLabsMeta(status: 0)
        var audioFile: (url: URL, handle: FileHandle)?
        var audioBytes = 0
        let ext = ElevenLabsFileTypes.fileExtension(contentType: nil, outputFormat: outputFormat ?? "mp3")
        let type = "audio/\(ext == "mp3" ? "mpeg" : ext)"
        do {
            try await streamPrepared(prepared) { chunk in
                switch chunk {
                case .started(let started): meta = started
                case .event(let event): events.append(event)
                case .audio(let data):
                    if audioFile == nil {
                        let url = try self.sink.destination(
                            for: operation, suggestedName: Self.fileName(operation, ext: ext), contentType: type
                        )
                        FileManager.default.createFile(atPath: url.path, contents: nil)
                        audioFile = (url, try FileHandle(forWritingTo: url))
                    }
                    try audioFile?.handle.write(contentsOf: data)
                    audioBytes += data.count
                case .bytes(let data):
                    events.append(.string(String(decoding: data, as: UTF8.self)))
                }
            }
        } catch {
            if let audioFile {
                try? audioFile.handle.close()
                try? FileManager.default.removeItem(at: audioFile.url)
            }
            throw error
        }
        guard let audioFile else { return .events(events, meta) }
        try? audioFile.handle.close()
        await sink.didWrite(audioFile.url, contentType: type, operation: operation)
        return .parts([.file(audioFile.url, contentType: type, bytes: audioBytes), .json(.array(events))], meta)
    }

    private func runStream(
        _ operation: ElevenLabsOperation, arguments: [String: JSONValue],
        files: [String: [ElevenLabsFile]], yield: @escaping @Sendable (ElevenLabsChunk) -> Void
    ) async throws {
        let prepared = try prepare(operation, arguments: arguments, files: files)
        try await withSlot {
            try await self.streamPrepared(prepared) { yield($0) }
        }
    }

    /// Sends once and hands chunks to `handle` in order. Never retried: a stream that has
    /// started may already be billed.
    private func streamPrepared(
        _ prepared: PreparedCall, handle: (ElevenLabsChunk) async throws -> Void
    ) async throws {
        let operation = prepared.operation
        let (request, key, upload) = try await materialize(
            prepared, handling: .memory(limit: limits.inlineBytes), timeout: limits.streamIdleTimeout
        )
        defer { if let upload { try? FileManager.default.removeItem(at: upload) } }
        try Task.checkCancellation()
        let response: ElevenLabsStreamingResponse
        do {
            response = try await transport.stream(request)
        } catch {
            throw Self.normalized(error, key: key)
        }
        let meta = Self.meta(from: response.status, headers: response.headers)
        guard (200..<300).contains(response.status) else {
            var collected = Data()
            do {
                for try await chunk in response.body where collected.count < 1 << 20 {
                    collected.append(chunk)
                }
            } catch {}
            throw Self.apiError(status: response.status, headers: response.headers, body: collected,
                                key: key, region: region, retryAfter: Self.retryAfter(response.headers))
        }
        try await handle(.started(meta))

        let contentType = meta.contentType?.lowercased() ?? ""
        let isEvents = operation.response == .events || contentType.hasPrefix("text/event-stream")
        let isJSON = !isEvents && (Self.isJSON(contentType) || (operation.response == .json && contentType.isEmpty))
        var sse = ServerSentEventParser()
        var json = JSONStreamParser()
        do {
            for try await chunk in response.body {
                try Task.checkCancellation()
                if isEvents {
                    for event in sse.feed(chunk) { try await emit(event, handle) }
                } else if isJSON {
                    for value in json.feed(chunk) { try await emit(value, eventName: nil, handle) }
                } else if operation.response == .audio || contentType.hasPrefix("audio/") {
                    try await handle(.audio(chunk))
                } else {
                    try await handle(.bytes(chunk))
                }
            }
            if isEvents {
                for event in sse.finish() { try await emit(event, handle) }
            }
        } catch {
            throw Self.normalized(error, key: key)
        }
    }

    private func emit(_ event: ServerSentEventParser.Event, _ handle: (ElevenLabsChunk) async throws -> Void) async throws {
        guard let data = event.data.data(using: .utf8), let value = try? JSONValue.parse(data) else {
            var wrapped: [String: JSONValue] = ["data": .string(event.data)]
            if let name = event.name { wrapped["event"] = .string(name) }
            try await handle(.event(.object(wrapped)))
            return
        }
        var named = value
        if let name = event.name, case .object(var object) = value, object["event"] == nil {
            object["event"] = .string(name)
            named = .object(object)
        }
        try await emit(named, eventName: event.name ?? value["type"].stringValue, handle)
    }

    private func emit(_ value: JSONValue, eventName: String?, _ handle: (ElevenLabsChunk) async throws -> Void) async throws {
        let (cleaned, audio) = Base64Audio.extract(from: value, eventName: eventName)
        for clip in audio where !clip.isEmpty { try await handle(.audio(clip)) }
        try await handle(.event(cleaned))
    }

    // MARK: - Files

    private func store(
        _ temporary: URL, name: String, contentType: String, operation: ElevenLabsOperation
    ) async throws -> (URL, Int) {
        let destination = try sink.destination(for: operation, suggestedName: name, contentType: contentType)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: temporary, to: destination)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0
        await sink.didWrite(destination, contentType: contentType, operation: operation)
        return (destination, bytes)
    }

    private func write(
        _ data: Data, name: String, contentType: String, operation: ElevenLabsOperation
    ) async throws -> (URL, Int) {
        let destination = try sink.destination(for: operation, suggestedName: name, contentType: contentType)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .withoutOverwriting)
        await sink.didWrite(destination, contentType: contentType, operation: operation)
        return (destination, data.count)
    }

    static func fileName(_ operation: ElevenLabsOperation, ext: String, index: Int? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        let stem = operation.id.replacingOccurrences(of: "_route", with: "")
            .replacingOccurrences(of: "_", with: "-")
        let numbered = index.map { "-\($0)" } ?? ""
        return "\(stem)-\(formatter.string(from: Date()))\(numbered).\(ext)"
    }

    static func defaultContentType(_ kind: ElevenLabsResponseKind) -> String {
        switch kind {
        case .audio: "audio/mpeg"
        case .binary(let type): type
        case .json: "application/json"
        case .text: "text/plain"
        case .events: "text/event-stream"
        case .multipartMixed: "multipart/mixed"
        }
    }

    // MARK: - Concurrency

    private func withSlot<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await gate.acquire()
        do {
            let value = try await work()
            await gate.release()
            return value
        } catch {
            await gate.release()
            throw Self.normalized(error)
        }
    }

    // MARK: - Answers

    /// Response headers worth keeping. Everything else — cookies, tracing, whatever a proxy
    /// adds — is dropped.
    static let allowlistedHeaders: Set<String> = [
        "request-id", "x-request-id", "character-cost", "x-character-count", "history-item-id",
        "song-id", "x-region", "content-type", "retry-after", "current-concurrent-requests",
        "maximum-concurrent-requests", "x-ratelimit-limit", "x-ratelimit-remaining",
        "x-ratelimit-reset", "tts-latency-ms", "dubbing-id", "x-dubbing-id",
    ]

    static func meta(from status: Int, headers: [String: String]) -> ElevenLabsMeta {
        let lowered = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        let kept = lowered.filter { allowlistedHeaders.contains($0.key) }
            .mapValues { ElevenLabsRedaction.redact($0) }
        return ElevenLabsMeta(
            status: status,
            requestID: kept["request-id"] ?? kept["x-request-id"],
            characterCost: kept["character-cost"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
            contentType: kept["content-type"],
            headers: kept
        )
    }

    static func isJSON(_ contentType: String?) -> Bool {
        guard let type = contentType?.lowercased() else { return false }
        return type.hasPrefix("application/json") || type.contains("+json")
    }

    static func retryAfter(_ headers: [String: String]) -> TimeInterval? {
        guard let value = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value
            .trimmingCharacters(in: .whitespaces)
        else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }

    static func errorBytes(_ body: ElevenLabsResponse.Body) -> Data {
        switch body {
        case .data(let data):
            return data.prefix(1 << 20)
        case .file(let url):
            defer { try? FileManager.default.removeItem(at: url) }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
            defer { try? handle.close() }
            return (try? handle.read(upToCount: 1 << 20)) ?? Data()
        }
    }

    /// ElevenLabs' error shapes — `{"detail": "text"}`, `{"detail": {"status", "message"}}`,
    /// FastAPI's `{"detail": [{"loc", "msg", "type"}]}` — as one error, key redacted.
    static func apiError(
        status: Int, headers: [String: String], body: Data, key: String?, region: ElevenLabsRegion,
        retryAfter: TimeInterval?
    ) -> ElevenLabsError {
        let meta = meta(from: status, headers: headers)
        if status == 429 { return .rateLimited(retryAfter: retryAfter) }
        var code: String?
        var message: String
        let parsed = try? JSONValue.parse(body)
        let detail = parsed?["detail"] ?? .null
        switch detail {
        case .string(let text):
            message = text
        case .object:
            code = detail["status"].stringValue ?? detail["code"].stringValue ?? detail["type"].stringValue
            message = detail["message"].stringValue ?? detail["msg"].stringValue ?? detail.jsonString()
        case .array(let items):
            code = "validation_error"
            message = items.prefix(10).map { item in
                let location = (item["loc"].arrayValue ?? [])
                    .compactMap { $0.stringValue ?? $0.intValue.map(String.init) }
                    .filter { $0 != "body" }
                    .joined(separator: ".")
                let text = item["msg"].stringValue ?? item.jsonString()
                return location.isEmpty ? text : "\(location): \(text)"
            }.joined(separator: "; ")
        default:
            if let parsed, let text = parsed["message"].stringValue ?? parsed["error"]["message"].stringValue
                ?? parsed["error"].stringValue {
                message = text
                code = parsed["error"]["code"].stringValue ?? parsed["code"].stringValue
            } else {
                let text = String(decoding: body.prefix(500), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                message = text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text
            }
        }
        if (300..<400).contains(status) {
            code = code ?? "redirect"
            message = "ElevenLabs answered with a redirect, which this app does not follow."
        }
        if status == 401 {
            message += region.isResidency
                ? " The key may belong to a different region: \(region.displayName) workspaces have keys of their own."
                : " If this key belongs to an EU, India or Singapore data-residency workspace, choose that region."
        }
        return .api(status: status, code: code.map { ElevenLabsRedaction.redact($0, knownKey: key) },
                    message: ElevenLabsRedaction.redact(message, knownKey: key),
                    requestID: meta.requestID)
    }

    /// Any error as an `ElevenLabsError`, with the key and anything key-shaped taken out.
    static func normalized(_ error: any Error, key: String? = nil) -> ElevenLabsError {
        switch error {
        case let error as ElevenLabsError:
            return redacted(error, key: key)
        case is CancellationError:
            return .cancelled
        case let error as URLError where error.code == .cancelled:
            return .cancelled
        case let error as URLError:
            return .network(ElevenLabsRedaction.redact(error.localizedDescription, knownKey: key))
        default:
            return .network(ElevenLabsRedaction.redact("\(error)", knownKey: key))
        }
    }

    static func redacted(_ error: ElevenLabsError, key: String?) -> ElevenLabsError {
        func scrub(_ text: String) -> String { ElevenLabsRedaction.redact(text, knownKey: key) }
        switch error {
        case .credentialUnavailable(let why): return .credentialUnavailable(scrub(why))
        case .invalidArguments(let problems): return .invalidArguments(problems.map(scrub))
        case .api(let status, let code, let message, let requestID):
            return .api(status: status, code: code.map(scrub), message: scrub(message), requestID: requestID)
        case .network(let why): return .network(scrub(why))
        case .refusedHost(let host): return .refusedHost(scrub(host))
        case .tooLarge(let why): return .tooLarge(scrub(why))
        case .notLinked, .unknownOperation, .rateLimited, .cancelled: return error
        }
    }
}

// MARK: - Gate

/// At most `limit` requests at once, first come first served. A waiter whose task is
/// cancelled leaves the queue.
actor ElevenLabsGate {
    private(set) var limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    init(limit: Int) { self.limit = max(1, limit) }

    func setLimit(_ newLimit: Int) {
        limit = max(1, newLimit)
        wakeWaiters()
    }

    func acquire() async throws {
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: ElevenLabsError.cancelled)
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    func release() {
        running = max(0, running - 1)
        wakeWaiters()
    }

    private func wakeWaiters() {
        while running < limit, !waiters.isEmpty {
            let next = waiters.removeFirst()
            running += 1
            next.continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: ElevenLabsError.cancelled)
    }

    var inFlight: Int { running }
    var queued: Int { waiters.count }
}
