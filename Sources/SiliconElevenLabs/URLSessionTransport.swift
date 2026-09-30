import Foundation

/// The production transport: an ephemeral URLSession with no cookies, no cache and no
/// redirects, that sends only to the ElevenLabs region hosts over https.
///
/// Every request is checked here as well as in the client: a URL that is not https to one of
/// `ElevenLabsRegion.allowedHosts` is refused before a connection is opened. Redirects are
/// refused, so a 3xx comes back as the answer rather than taking the key somewhere else.
/// TLS is the system's default evaluation; nothing here relaxes it. Bodies arrive through the
/// delegate as they are received, so a download goes to disk and a stream is forwarded
/// without either being held whole in memory.
public final class URLSessionTransport: ElevenLabsTransport, @unchecked Sendable {
    private let session: URLSession
    private let relays: RelayTable
    private let allowedHosts: Set<String>
    /// Tests only: plain http to 127.0.0.1 on this port. Nil in the app, and there is no way
    /// to set it from outside this module in a release build.
    private let loopbackPort: Int?

    public convenience init() {
        self.init(allowedHosts: ElevenLabsRegion.allowedHosts, loopbackPort: nil)
    }

    #if DEBUG
    /// A transport that also sends plain http to `127.0.0.1:port` — for the wire-level tests'
    /// loopback server, and for nothing else. Debug builds only; internal to the module.
    static func loopbackForTesting(port: Int) -> URLSessionTransport {
        URLSessionTransport(allowedHosts: ElevenLabsRegion.allowedHosts, loopbackPort: port)
    }
    #endif

    private init(allowedHosts: Set<String>, loopbackPort: Int?) {
        self.allowedHosts = allowedHosts
        self.loopbackPort = loopbackPort
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.httpAdditionalHeaders = ["User-Agent": "SiliconOptimizer"]
        configuration.waitsForConnectivity = false
        relays = RelayTable()
        session = URLSession(
            configuration: configuration, delegate: SessionDelegate(relays: relays), delegateQueue: nil
        )
    }

    deinit { session.invalidateAndCancel() }

    // MARK: - ElevenLabsTransport

    public func send(_ request: ElevenLabsRequest) async throws -> ElevenLabsResponse {
        let (head, body, task) = try await start(request)
        do {
            switch request.responseHandling {
            case .memory(let limit):
                var data = Data()
                for try await chunk in body {
                    data.append(chunk)
                    if data.count > limit {
                        task.cancel()
                        throw ElevenLabsError.tooLarge("the answer passed \(limit) bytes")
                    }
                }
                // A cancelled consumer ends the loop without an error; a partial body must
                // not pass for a whole one.
                try Task.checkCancellation()
                return ElevenLabsResponse(status: head.status, headers: head.headers, body: .data(data))
            case .file(let limit):
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("elevenlabs-download-\(UUID().uuidString)")
                FileManager.default.createFile(atPath: file.path, contents: nil)
                do {
                    let handle = try FileHandle(forWritingTo: file)
                    defer { try? handle.close() }
                    var written: Int64 = 0
                    for try await chunk in body {
                        written += Int64(chunk.count)
                        if written > limit {
                            task.cancel()
                            throw ElevenLabsError.tooLarge("the answer passed \(limit) bytes")
                        }
                        try handle.write(contentsOf: chunk)
                    }
                    try Task.checkCancellation()
                } catch {
                    try? FileManager.default.removeItem(at: file)
                    throw error
                }
                return ElevenLabsResponse(status: head.status, headers: head.headers, body: .file(file))
            }
        } catch {
            task.cancel()
            throw Self.mapped(error)
        }
    }

    public func stream(_ request: ElevenLabsRequest) async throws -> ElevenLabsStreamingResponse {
        let (head, body, task) = try await start(request)
        let forwarded = AsyncThrowingStream<Data, any Error> { continuation in
            let pump = Task {
                do {
                    for try await chunk in body { continuation.yield(chunk) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapped(error))
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    pump.cancel()
                    task.cancel()
                }
            }
        }
        return ElevenLabsStreamingResponse(status: head.status, headers: head.headers, body: forwarded)
    }

    // MARK: - Starting a task

    struct Head: Sendable {
        var status: Int
        var headers: [String: String]
    }

    /// Checks the host, starts the task, and waits for the response head. The body follows
    /// through the returned stream.
    private func start(
        _ request: ElevenLabsRequest
    ) async throws -> (Head, AsyncThrowingStream<Data, any Error>, URLSessionTask) {
        guard isAllowed(request.url) else {
            throw ElevenLabsError.refusedHost(request.url.host ?? request.url.absoluteString)
        }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let relay = Relay()
        let task: URLSessionTask
        switch request.body {
        case .none:
            task = session.dataTask(with: urlRequest)
        case .data(let data):
            task = session.uploadTask(with: urlRequest, from: data)
        case .file(let url):
            relay.bodyFile = url
            task = session.uploadTask(with: urlRequest, fromFile: url)
        }
        relays.insert(relay, for: task.taskIdentifier)

        let head: Head
        do {
            head = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await relay.awaitHead { task.resume() }
            } onCancel: {
                task.cancel()
            }
        } catch {
            task.cancel()
            relays.remove(task.taskIdentifier)
            throw Self.mapped(error)
        }
        return (head, relay.body, task)
    }

    private func isAllowed(_ url: URL) -> Bool {
        Self.isAllowed(url, allowedHosts: allowedHosts, loopbackPort: loopbackPort)
    }

    /// Whether a request to `url` may leave this Mac with the key in it. A pure function of the
    /// URL, so the negative cases — every way a URL can look like an ElevenLabs host and not be
    /// one — are tested without opening a socket.
    static func isAllowed(_ url: URL, allowedHosts: Set<String>, loopbackPort: Int?) -> Bool {
        guard let host = url.host else { return false }
        if url.scheme == "https", allowedHosts.contains(host), url.port == nil || url.port == 443 {
            return true
        }
        if let loopbackPort, url.scheme == "http", host == "127.0.0.1", url.port == loopbackPort {
            return true
        }
        return false
    }

    static func mapped(_ error: any Error) -> ElevenLabsError {
        switch error {
        case let error as ElevenLabsError: return error
        case is CancellationError: return .cancelled
        case let error as URLError:
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .network("the request timed out")
            case .notConnectedToInternet: return .network("this Mac is offline")
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
                 .serverCertificateHasUnknownRoot, .clientCertificateRejected, .secureConnectionFailed:
                return .network("the secure connection could not be verified (\(error.code.rawValue))")
            default: return .network(error.localizedDescription)
            }
        default: return .network("\(error)")
        }
    }
}

// MARK: - Delegate plumbing

/// One task's head continuation and body stream.
private final class Relay: @unchecked Sendable {
    private let lock = NSLock()
    private var headContinuation: CheckedContinuation<URLSessionTransport.Head, any Error>?
    private var headResult: Result<URLSessionTransport.Head, any Error>?
    let body: AsyncThrowingStream<Data, any Error>
    private let bodyContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    var bodyFile: URL?

    init() {
        (body, bodyContinuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .unbounded)
    }

    func awaitHead(starting start: () -> Void) async throws -> URLSessionTransport.Head {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if let headResult {
                    continuation.resume(with: headResult)
                } else {
                    headContinuation = continuation
                }
            }
            start()
        }
    }

    func deliverHead(_ result: Result<URLSessionTransport.Head, any Error>) {
        let continuation: CheckedContinuation<URLSessionTransport.Head, any Error>? = lock.withLock {
            guard headResult == nil else { return nil }
            headResult = result
            defer { headContinuation = nil }
            return headContinuation
        }
        continuation?.resume(with: result)
    }

    func yield(_ data: Data) { bodyContinuation.yield(data) }

    func finish(_ error: (any Error)?) {
        if let error {
            deliverHead(.failure(error))
            bodyContinuation.finish(throwing: error)
        } else {
            deliverHead(.failure(URLError(.badServerResponse)))
            bodyContinuation.finish()
        }
    }
}

private final class RelayTable: @unchecked Sendable {
    private let lock = NSLock()
    private var relays: [Int: Relay] = [:]

    func insert(_ relay: Relay, for id: Int) { lock.withLock { relays[id] = relay } }
    func relay(_ id: Int) -> Relay? { lock.withLock { relays[id] } }
    func remove(_ id: Int) { _ = lock.withLock { relays.removeValue(forKey: id) } }
}

private final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let relays: RelayTable

    init(relays: RelayTable) { self.relays = relays }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            relays.relay(dataTask.taskIdentifier)?.finish(URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }
        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            headers[String(describing: name).lowercased()] = String(describing: value)
        }
        relays.relay(dataTask.taskIdentifier)?.deliverHead(.success(.init(status: http.statusCode, headers: headers)))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        relays.relay(dataTask.taskIdentifier)?.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        relays.relay(task.taskIdentifier)?.finish(error)
        relays.remove(task.taskIdentifier)
    }

    /// Never follow: the 3xx itself becomes the answer, and the key stays where it was sent.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    /// A body sent from a file may have to be sent again (a connection reset before any
    /// answer); hand URLSession a fresh stream of the same file.
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        completionHandler(relays.relay(task.taskIdentifier)?.bodyFile.flatMap(InputStream.init(url:)))
    }
}

/// A transport that sends nothing: what an app model built for a test or a preview gets, so
/// no code path there can reach ElevenLabs.
public struct UnavailableElevenLabsTransport: ElevenLabsTransport {
    public init() {}

    public func send(_ request: ElevenLabsRequest) async throws -> ElevenLabsResponse {
        throw ElevenLabsError.network("no network in this context")
    }

    public func stream(_ request: ElevenLabsRequest) async throws -> ElevenLabsStreamingResponse {
        throw ElevenLabsError.network("no network in this context")
    }
}
