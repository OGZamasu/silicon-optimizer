import Foundation

/// The production socket: `URLSessionWebSocketTask` on an ephemeral session with no cookies, no
/// cache and no redirects, opened only to the ElevenLabs region hosts over `wss`.
///
/// The upgrade request carries the caller's headers (the key, for the speech and transcription
/// sockets), so the key travels exactly as it does over REST: in `xi-api-key`, over TLS, to an
/// allowlisted host. `maximumMessageSize` is raised before the task starts (Foundation's default
/// is 1 MiB; the SDKs take 16 MiB). A redirect answer to the upgrade is refused, never followed.
public final class URLSessionWebSocketConnector: ElevenLabsSocketConnector, @unchecked Sendable {
    private let session: URLSession
    private let relays: SocketRelayTable
    private let allowedHosts: Set<String>
    /// Tests only: plain `ws` to 127.0.0.1 on this port. Nil in the app, and there is no way to
    /// set it from outside this module in a release build.
    private let loopbackPort: Int?

    public convenience init() {
        self.init(allowedHosts: ElevenLabsRegion.allowedHosts, loopbackPort: nil)
    }

    #if DEBUG
    /// A connector that also opens plain `ws` to `127.0.0.1:port` — for the wire-level tests'
    /// loopback server, and for nothing else. Debug builds only; internal to the module.
    static func loopbackForTesting(port: Int) -> URLSessionWebSocketConnector {
        URLSessionWebSocketConnector(allowedHosts: ElevenLabsRegion.allowedHosts, loopbackPort: port)
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
        configuration.httpAdditionalHeaders = ["User-Agent": "SiliconOptimizer"]
        configuration.waitsForConnectivity = false
        relays = SocketRelayTable()
        session = URLSession(
            configuration: configuration, delegate: SocketSessionDelegate(relays: relays), delegateQueue: nil
        )
    }

    deinit { session.invalidateAndCancel() }

    /// Whether a socket to `url` may be opened with a key in its headers. A pure function of the
    /// URL, so every look-alike is tested without opening anything.
    static func isAllowed(_ url: URL, allowedHosts: Set<String>, loopbackPort: Int?) -> Bool {
        guard let host = url.host, url.user == nil, url.password == nil else { return false }
        if url.scheme == "wss", allowedHosts.contains(host), url.port == nil || url.port == 443 {
            return true
        }
        if let loopbackPort, url.scheme == "ws", host == "127.0.0.1", url.port == loopbackPort {
            return true
        }
        return false
    }

    public func connect(_ request: ElevenLabsSocketRequest) async throws -> any ElevenLabsSocket {
        guard Self.isAllowed(request.url, allowedHosts: allowedHosts, loopbackPort: loopbackPort) else {
            throw ElevenLabsRealtimeError.refusedHost(
                request.url.host.map { ElevenLabsRedaction.redact($0) } ?? ElevenLabsRealtimeRedaction.describe(request.url)
            )
        }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.timeoutInterval = request.openTimeout
        urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        urlRequest.httpShouldHandleCookies = false
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let task = session.webSocketTask(with: urlRequest)
        // Before `resume`: a task that has started keeps the default.
        task.maximumMessageSize = request.maximumMessageSize
        let relay = SocketRelay()
        relays.insert(relay, for: task.taskIdentifier)
        let key = request.header("xi-api-key")
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await relay.awaitOpen(timeout: request.openTimeout) { task.resume() }
            } onCancel: {
                task.cancel()
            }
        } catch {
            task.cancel()
            relays.remove(task.taskIdentifier)
            if Task.isCancelled { throw ElevenLabsRealtimeError.cancelled }
            let status = (task.response as? HTTPURLResponse)?.statusCode
            if let status, status != 101 {
                throw ElevenLabsRealtimeError.handshakeFailed(
                    status: status, message: HTTPURLResponse.localizedString(forStatusCode: status)
                )
            }
            throw ElevenLabsRealtimeError(wrapping: error, redactingKey: key)
        }
        return URLSessionElevenLabsSocket(task: task, relay: relay, relays: relays, key: key)
    }
}

/// One `URLSessionWebSocketTask`, as an `ElevenLabsSocket`.
final class URLSessionElevenLabsSocket: ElevenLabsSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let relay: SocketRelay
    private let relays: SocketRelayTable
    private let key: String?
    private let lock = NSLock()
    private var closedByUs: ElevenLabsSocketClose?

    init(task: URLSessionWebSocketTask, relay: SocketRelay, relays: SocketRelayTable, key: String?) {
        self.task = task
        self.relay = relay
        self.relays = relays
        self.key = key
    }

    func send(_ message: ElevenLabsSocketMessage) async throws {
        if let close = currentClose() { throw ElevenLabsRealtimeError.closed(close) }
        do {
            switch message {
            case .text(let text): try await task.send(.string(text))
            case .data(let data): try await task.send(.data(data))
            }
        } catch {
            throw await ending(error)
        }
    }

    func receive() async throws -> ElevenLabsSocketMessage {
        if let close = currentClose() { throw ElevenLabsRealtimeError.closed(close) }
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .data(data)
            @unknown default: return .data(Data())
            }
        } catch {
            throw await ending(error)
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func close(code: Int, reason: String) async {
        let close = ElevenLabsSocketClose(code: code, reason: reason)
        let first: Bool = lock.withLock {
            guard closedByUs == nil else { return false }
            closedByUs = close
            return true
        }
        guard first else { return }
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task.cancel(with: closeCode, reason: Data(reason.utf8))
        relays.remove(task.taskIdentifier)
    }

    private func currentClose() -> ElevenLabsSocketClose? {
        lock.withLock { closedByUs }
    }

    /// The error a failed send or receive stands for. A socket that the server (or the network)
    /// closed says how: the delegate's close code and reason when it heard them, else the task's
    /// own, read by raw value — a code Foundation has no case for, such as 4300, would read as
    /// `.invalid` through the enum.
    private func ending(_ error: any Error) async -> ElevenLabsRealtimeError {
        if let close = currentClose() { return .closed(close) }
        if (error as? URLError)?.code == .cancelled { return .cancelled }
        if let posix = error as? POSIXError, posix.code == .EMSGSIZE { return .messageTooLarge }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(EMSGSIZE) { return .messageTooLarge }
        // The delegate may hear the close a moment after the failed receive.
        if let heard = await relay.awaitClose(within: .milliseconds(500)) { return .closed(heard) }
        let code = task.closeCode.rawValue
        if code != 0 {
            let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return .closed(ElevenLabsSocketClose(code: code, reason: reason))
        }
        return .closed(ElevenLabsSocketClose(
            code: 0, reason: ElevenLabsRealtimeError(wrapping: error, redactingKey: key).description
        ))
    }
}

// MARK: - Delegate plumbing

/// One task's opening handshake and close, as the delegate reports them.
final class SocketRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var openContinuation: CheckedContinuation<Void, any Error>?
    private var openResult: Result<Void, any Error>?
    private var closeInfo: ElevenLabsSocketClose?
    private var closeWaiters: [CheckedContinuation<ElevenLabsSocketClose?, Never>] = []

    func awaitOpen(timeout: TimeInterval, starting start: () -> Void) async throws {
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(max(timeout, 0.1) * 1_000)))
            self?.opened(.failure(URLError(.timedOut)))
        }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.withLock {
                if let openResult {
                    continuation.resume(with: openResult)
                } else {
                    openContinuation = continuation
                }
            }
            start()
        }
    }

    func opened(_ result: Result<Void, any Error>) {
        let continuation: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard openResult == nil else { return nil }
            openResult = result
            defer { openContinuation = nil }
            return openContinuation
        }
        continuation?.resume(with: result)
    }

    func closed(_ close: ElevenLabsSocketClose) {
        let waiters: [CheckedContinuation<ElevenLabsSocketClose?, Never>] = lock.withLock {
            if closeInfo == nil { closeInfo = close }
            defer { closeWaiters = [] }
            return closeWaiters
        }
        for waiter in waiters { waiter.resume(returning: close) }
    }

    /// The close the delegate heard, waiting up to `within` for it.
    func awaitClose(within: Duration) async -> ElevenLabsSocketClose? {
        if let known = lock.withLock({ closeInfo }) { return known }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: within)
            self?.giveUpWaitingForClose()
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            let known: ElevenLabsSocketClose?? = lock.withLock {
                if let closeInfo { return .some(closeInfo) }
                closeWaiters.append(continuation)
                return .none
            }
            if case .some(let close) = known { continuation.resume(returning: close) }
        }
    }

    private func giveUpWaitingForClose() {
        let waiters: [CheckedContinuation<ElevenLabsSocketClose?, Never>] = lock.withLock {
            defer { closeWaiters = [] }
            return closeWaiters
        }
        for waiter in waiters { waiter.resume(returning: nil) }
    }
}

final class SocketRelayTable: @unchecked Sendable {
    private let lock = NSLock()
    private var relays: [Int: SocketRelay] = [:]

    func insert(_ relay: SocketRelay, for id: Int) { lock.withLock { relays[id] = relay } }
    func relay(_ id: Int) -> SocketRelay? { lock.withLock { relays[id] } }
    func remove(_ id: Int) { _ = lock.withLock { relays.removeValue(forKey: id) } }
}

private final class SocketSessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    let relays: SocketRelayTable

    init(relays: SocketRelayTable) { self.relays = relays }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
    ) {
        relays.relay(webSocketTask.taskIdentifier)?.opened(.success(()))
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
    ) {
        let relay = relays.relay(webSocketTask.taskIdentifier)
        // The enum has no case for 4300 and the like; the task's own code is the number heard.
        let code = closeCode == .invalid ? webSocketTask.closeCode.rawValue : closeCode.rawValue
        relay?.closed(ElevenLabsSocketClose(
            code: code, reason: reason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        ))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let relay = relays.relay(task.taskIdentifier) else { return }
        relay.opened(.failure(error ?? URLError(.networkConnectionLost)))
        if let socket = task as? URLSessionWebSocketTask, socket.closeCode != .invalid {
            relay.closed(ElevenLabsSocketClose(
                code: socket.closeCode.rawValue,
                reason: socket.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            ))
        } else {
            relay.closed(ElevenLabsSocketClose(code: 0, reason: ""))
        }
        relays.remove(task.taskIdentifier)
    }

    /// Never follow: the upgrade fails, and the key stays with the host it was meant for.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
