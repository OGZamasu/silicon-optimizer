import Foundation

// Test doubles, public so every builder's tests use the same ones. None of them touches the
// network, the Keychain or anything outside a temporary directory they create themselves.

// MARK: - Transport

/// An in-memory transport: records every request and answers from a script.
///
/// It enforces the same host rule as production — https to a region host only — and records
/// any request that breaks it in `hostViolations` before refusing it, so a test can assert
/// both that the client never tried and that the fake would have caught it.
public final class FakeElevenLabsTransport: ElevenLabsTransport, @unchecked Sendable {

    /// One scripted answer.
    public struct Reply: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var body: Data
        /// For `stream`: the body in these pieces. Defaults to `body` in one piece.
        public var chunks: [Data]?
        /// Thrown instead of answering (after `delay`).
        public var error: ElevenLabsError?
        /// Waited before answering, and between streamed chunks.
        public var delay: Duration?

        public init(
            status: Int = 200, headers: [String: String] = [:], body: Data = Data(),
            chunks: [Data]? = nil, error: ElevenLabsError? = nil, delay: Duration? = nil
        ) {
            self.status = status
            self.headers = headers
            self.body = body
            self.chunks = chunks
            self.error = error
            self.delay = delay
        }

        public static func json(
            _ value: JSONValue, status: Int = 200, headers: [String: String] = [:]
        ) -> Reply {
            .init(status: status, headers: ["content-type": "application/json"].merging(headers) { $1 },
                  body: value.encoded())
        }

        public static func jsonText(
            _ text: String, status: Int = 200, headers: [String: String] = [:]
        ) -> Reply {
            .init(status: status, headers: ["content-type": "application/json"].merging(headers) { $1 },
                  body: Data(text.utf8))
        }

        public static func audio(
            _ bytes: Data, contentType: String = "audio/mpeg", chunks: [Data]? = nil,
            headers: [String: String] = [:]
        ) -> Reply {
            .init(status: 200, headers: ["content-type": contentType].merging(headers) { $1 },
                  body: bytes, chunks: chunks)
        }

        public static func failure(_ error: ElevenLabsError, delay: Duration? = nil) -> Reply {
            .init(status: 0, error: error, delay: delay)
        }
    }

    /// A request as it arrived, with its body read at that moment (a multipart body is a
    /// temporary file the client removes once the call ends).
    public struct Recorded: Sendable {
        public var request: ElevenLabsRequest
        public var body: Data
        public var streamed: Bool
    }

    private let lock = NSLock()
    private var _recorded: [Recorded] = []
    private var _hostViolations: [URL] = []
    private var _cancelled = 0
    private let handler: @Sendable (ElevenLabsRequest) async throws -> Reply
    private let allowedHosts: Set<String>
    private let directory: URL

    /// - Parameter handler: Answers each request. Throwing is a transport failure.
    public init(
        allowedHosts: Set<String> = ElevenLabsRegion.allowedHosts,
        handler: @escaping @Sendable (ElevenLabsRequest) async throws -> Reply
    ) {
        self.handler = handler
        self.allowedHosts = allowedHosts
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-fake-transport-\(UUID().uuidString)", isDirectory: true)
    }

    /// Answers with `replies` in order; past the end, every request is a 599 with a note.
    public convenience init(replies: [Reply]) {
        let queue = ReplyQueue(replies)
        self.init { _ in queue.next() }
    }

    public var recorded: [Recorded] { lock.withLock { _recorded } }
    public var requests: [ElevenLabsRequest] { recorded.map(\.request) }
    public var hostViolations: [URL] { lock.withLock { _hostViolations } }
    /// Streams whose consumer went away before the last chunk.
    public var cancelledStreams: Int { lock.withLock { _cancelled } }

    public func send(_ request: ElevenLabsRequest) async throws -> ElevenLabsResponse {
        let reply = try await answer(request, streamed: false)
        if let delay = reply.delay { try await sleep(delay) }
        if let error = reply.error { throw error }
        switch request.responseHandling {
        case .memory(let limit):
            guard reply.body.count <= limit else {
                throw ElevenLabsError.tooLarge("the answer passed \(limit) bytes")
            }
            return ElevenLabsResponse(status: reply.status, headers: reply.headers, body: .data(reply.body))
        case .file(let limit):
            guard Int64(reply.body.count) <= limit else {
                throw ElevenLabsError.tooLarge("the answer passed \(limit) bytes")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(UUID().uuidString)
            try reply.body.write(to: file)
            return ElevenLabsResponse(status: reply.status, headers: reply.headers, body: .file(file))
        }
    }

    public func stream(_ request: ElevenLabsRequest) async throws -> ElevenLabsStreamingResponse {
        let reply = try await answer(request, streamed: true)
        if let error = reply.error {
            if let delay = reply.delay { try await sleep(delay) }
            throw error
        }
        let chunks = reply.chunks ?? [reply.body]
        let delay = reply.delay
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            let producer = Task {
                for chunk in chunks {
                    if let delay {
                        do { try await Task.sleep(for: delay) } catch {
                            continuation.finish(throwing: ElevenLabsError.cancelled)
                            return
                        }
                    }
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { [weak self] termination in
                if case .cancelled = termination {
                    producer.cancel()
                    self?.lock.withLock { self?._cancelled += 1 }
                }
            }
        }
        return ElevenLabsStreamingResponse(status: reply.status, headers: reply.headers, body: body)
    }

    private func answer(_ request: ElevenLabsRequest, streamed: Bool) async throws -> Reply {
        var body = Data()
        switch request.body {
        case .none: break
        case .data(let data): body = data
        case .file(let url): body = (try? Data(contentsOf: url)) ?? Data()
        }
        lock.withLock { _recorded.append(Recorded(request: request, body: body, streamed: streamed)) }
        guard request.url.scheme == "https", let host = request.url.host,
              allowedHosts.contains(host)
        else {
            lock.withLock { _hostViolations.append(request.url) }
            throw ElevenLabsError.refusedHost(request.url.host ?? request.url.absoluteString)
        }
        return try await handler(request)
    }

    private func sleep(_ delay: Duration) async throws {
        do { try await Task.sleep(for: delay) } catch { throw ElevenLabsError.cancelled }
    }

    /// Removes the temporary files this fake wrote. Only its own directory, and only when it
    /// is where the fake created it.
    public func removeTemporaryFiles() {
        TemporaryFileSink.removeScratch(directory)
    }
}

private final class ReplyQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [FakeElevenLabsTransport.Reply]

    init(_ replies: [FakeElevenLabsTransport.Reply]) { self.replies = replies }

    func next() -> FakeElevenLabsTransport.Reply {
        lock.withLock {
            replies.isEmpty
                ? .jsonText(#"{"detail":"no scripted reply left"}"#, status: 599)
                : replies.removeFirst()
        }
    }
}

// MARK: - Credential

/// A key held in memory. Counts reads so a test can see when (and whether) the key was asked
/// for; `failure` makes every read throw, as a locked Keychain would.
public final class FakeCredentialSource: ElevenLabsKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _key: String?
    private var _reads = 0
    private var _writes = 0
    private var _failure: ElevenLabsError?

    public init(key: String? = nil, failure: ElevenLabsError? = nil) {
        _key = key
        _failure = failure
    }

    public var key: String? { lock.withLock { _key } }
    public var reads: Int { lock.withLock { _reads } }
    public var writes: Int { lock.withLock { _writes } }

    public func setFailure(_ failure: ElevenLabsError?) { lock.withLock { _failure = failure } }

    public func apiKey() async throws -> String? {
        try lock.withLock {
            _reads += 1
            if let _failure { throw _failure }
            return _key
        }
    }

    public func store(_ key: String) async throws {
        try lock.withLock {
            if let _failure { throw _failure }
            _writes += 1
            _key = key
        }
    }

    public func remove() async throws {
        try lock.withLock {
            if let _failure { throw _failure }
            _writes += 1
            _key = nil
        }
    }
}

// MARK: - File sink

/// Writes into a directory it creates under the system temporary directory, and removes only
/// that.
public final class TemporaryFileSink: ElevenLabsFileSink, @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var _written: [(url: URL, contentType: String, operation: String)] = []

    public init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-sink-\(UUID().uuidString)", isDirectory: true)
    }

    public func destination(
        for operation: ElevenLabsOperation, suggestedName: String, contentType: String
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ElevenLabsFileNames.unique(suggestedName, in: directory)
    }

    public func didWrite(_ file: URL, contentType: String, operation: ElevenLabsOperation) async {
        lock.withLock { _written.append((file, contentType, operation.id)) }
    }

    /// Files reported through `didWrite`, in order.
    public var written: [URL] { lock.withLock { _written.map(\.url) } }

    /// Removes the directory — only if it is still a scratch directory this type made.
    public func removeAll() { Self.removeScratch(directory) }

    /// The require-scratch check every test cleanup goes through: removes `directory` only
    /// when it sits directly in the system temporary directory and has one of this module's
    /// scratch prefixes.
    public static func removeScratch(_ directory: URL) {
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let target = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard target.deletingLastPathComponent().path == temporary.path,
              target.lastPathComponent.hasPrefix("elevenlabs-")
        else { return }
        try? FileManager.default.removeItem(at: target)
    }
}

/// File naming shared by the sinks.
public enum ElevenLabsFileNames {
    /// `name` made safe for a file name (no separators, no leading dot), and not longer than
    /// 120 characters.
    public static func sanitized(_ name: String) -> String {
        var cleaned = name.map { character -> Character in
            character == "/" || character == ":" || character == "\\" || character.isNewline
                ? "-" : character
        }
        while cleaned.first == "." { cleaned.removeFirst() }
        let result = String(cleaned.prefix(120)).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "elevenlabs" : result
    }

    /// `name` in `directory`, with " 2", " 3"… before the extension if it is taken.
    public static func unique(_ name: String, in directory: URL) -> URL {
        let name = sanitized(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }
}
