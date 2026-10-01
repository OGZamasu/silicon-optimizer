import Foundation

// Test doubles for the realtime sockets, public so every builder's tests use the same ones.
// Nothing here opens a network connection.

/// An in-memory socket opener. Records every request, refuses the ones production would refuse
/// (`hostViolations` lists them), and hands each socket it opens to `server`, a script that
/// plays ElevenLabs' side: read what the client sent, push frames, close.
public final class FakeElevenLabsSocketConnector: ElevenLabsSocketConnector, @unchecked Sendable {
    public typealias Server = @Sendable (FakeElevenLabsSocket) async -> Void

    private let lock = NSLock()
    private let allowedHosts: Set<String>
    private let server: Server
    private var _requests: [ElevenLabsSocketRequest] = []
    private var _violations: [URL] = []
    private var _sockets: [FakeElevenLabsSocket] = []
    private var failures: [(ElevenLabsRealtimeError, Duration?)] = []
    private var delay: Duration?

    public init(allowedHosts: Set<String> = ElevenLabsRegion.allowedHosts, server: @escaping Server = { _ in }) {
        self.allowedHosts = allowedHosts
        self.server = server
    }

    /// Every connect asked for, in order, including refused ones.
    public var requests: [ElevenLabsSocketRequest] { lock.withLock { _requests } }
    /// URLs production would have refused.
    public var hostViolations: [URL] { lock.withLock { _violations } }
    /// The sockets opened, in order.
    public var sockets: [FakeElevenLabsSocket] { lock.withLock { _sockets } }

    /// The next connect waits `delay` (if given), then fails with `error`.
    public func failNextConnect(with error: ElevenLabsRealtimeError, after delay: Duration? = nil) {
        lock.withLock { failures.append((error, delay)) }
    }

    /// Every connect waits this long before opening (cancellable).
    public func setConnectDelay(_ delay: Duration?) {
        lock.withLock { self.delay = delay }
    }

    public func connect(_ request: ElevenLabsSocketRequest) async throws -> any ElevenLabsSocket {
        let (failure, wait): ((ElevenLabsRealtimeError, Duration?)?, Duration?) = lock.withLock {
            _requests.append(request)
            return (failures.isEmpty ? nil : failures.removeFirst(), delay)
        }
        guard request.url.scheme == "wss", let host = request.url.host, allowedHosts.contains(host),
              request.url.port == nil
        else {
            lock.withLock { _violations.append(request.url) }
            throw ElevenLabsRealtimeError.refusedHost(request.url.host ?? "an unnamed host")
        }
        if let pause = failure?.1 ?? wait {
            do { try await Task.sleep(for: pause) } catch { throw ElevenLabsRealtimeError.cancelled }
        }
        if let failure { throw failure.0 }
        try Task.checkCancellation()
        let socket = FakeElevenLabsSocket(request: request)
        lock.withLock { _sockets.append(socket) }
        let server = server
        Task { await server(socket) }
        return socket
    }
}

/// One in-memory socket: the client's end is `ElevenLabsSocket`; the server script's end is
/// `nextSent`, `push` and `serverClose`.
public final class FakeElevenLabsSocket: ElevenLabsSocket, @unchecked Sendable {
    public let request: ElevenLabsSocketRequest
    private let lock = NSLock()
    private var _sent: [ElevenLabsSocketMessage] = []
    private var readCursor = 0
    private var inbox: [ElevenLabsSocketMessage] = []
    private var receivers: [CheckedContinuation<ElevenLabsSocketMessage?, Never>] = []
    private var ended: ElevenLabsSocketClose?
    private var _closedByClient: ElevenLabsSocketClose?
    private var _pings = 0
    private var stalled = false
    private var sendDelay: Duration?

    init(request: ElevenLabsSocketRequest) {
        self.request = request
    }

    /// Everything the client sent, in order.
    public var sent: [ElevenLabsSocketMessage] { lock.withLock { _sent } }
    /// The client's frames as JSON (frames that are not JSON are left out).
    public var sentJSON: [JSONValue] { sent.compactMap(\.json) }
    /// How the client closed the socket, if it did.
    public var closedByClient: ElevenLabsSocketClose? { lock.withLock { _closedByClient } }
    /// How the socket ended, either side.
    public var endedWith: ElevenLabsSocketClose? { lock.withLock { ended } }
    public var pings: Int { lock.withLock { _pings } }

    // MARK: Server side

    /// The client's next frame as JSON, in order; nil once the socket has ended and every frame
    /// has been read, or after `timeout`.
    public func nextSent(timeout: Duration = .seconds(10)) async -> JSONValue? {
        let deadline = ContinuousClock.now + timeout
        while true {
            let next: (message: ElevenLabsSocketMessage?, over: Bool) = lock.withLock {
                if readCursor < _sent.count {
                    defer { readCursor += 1 }
                    return (_sent[readCursor], false)
                }
                return (nil, ended != nil)
            }
            if let message = next.message { return message.json ?? .string("<not JSON>") }
            if next.over || ContinuousClock.now >= deadline { return nil }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The client's next frame whose `type` (or `message_type`) is `type`, skipping others.
    public func nextSent(ofType type: String, timeout: Duration = .seconds(10)) async -> JSONValue? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            guard let next = await nextSent(timeout: deadline - ContinuousClock.now) else { return nil }
            if next["type"].stringValue == type || next["message_type"].stringValue == type { return next }
        }
        return nil
    }

    /// Waits until the client has sent at least `count` frames.
    @discardableResult
    public func waitForSent(_ count: Int, timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if lock.withLock({ _sent.count >= count }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    /// Sends `json` to the client as a text frame.
    public func push(_ json: JSONValue) { push(.text(json.jsonString())) }

    public func push(_ message: ElevenLabsSocketMessage) {
        let receiver: CheckedContinuation<ElevenLabsSocketMessage?, Never>? = lock.withLock {
            guard ended == nil else { return nil }
            if !receivers.isEmpty { return receivers.removeFirst() }
            inbox.append(message)
            return nil
        }
        receiver?.resume(returning: message)
    }

    /// Closes from ElevenLabs' side with `code` and `reason`: frames already pushed are still
    /// read first.
    public func serverClose(code: Int = 1000, reason: String = "") {
        finish(ElevenLabsSocketClose(code: code, reason: reason))
    }

    /// From now on the client's sends never complete — a stalled connection — until the socket
    /// ends.
    public func stallSends() {
        lock.withLock { stalled = true }
    }

    /// From now on each of the client's sends takes `delay` to complete — a slow connection.
    public func delaySends(by delay: Duration) {
        lock.withLock { sendDelay = delay }
    }

    /// The connection drops, with no close code.
    public func drop() {
        finish(ElevenLabsSocketClose(code: 0, reason: "the connection was lost"))
    }

    /// Waits until the socket has ended, either side.
    @discardableResult
    public func waitUntilEnded(timeout: Duration = .seconds(10)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if endedWith != nil { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    // MARK: ElevenLabsSocket

    public func send(_ message: ElevenLabsSocketMessage) async throws {
        while lock.withLock({ stalled && ended == nil }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if let delay = lock.withLock({ sendDelay }) { try? await Task.sleep(for: delay) }
        let refused: ElevenLabsSocketClose? = lock.withLock {
            if let ended { return ended }
            _sent.append(message)
            return nil
        }
        if let refused { throw ElevenLabsRealtimeError.closed(refused) }
    }

    public func receive() async throws -> ElevenLabsSocketMessage {
        let message: ElevenLabsSocketMessage? = await withCheckedContinuation { continuation in
            let ready: ElevenLabsSocketMessage?? = lock.withLock {
                if !inbox.isEmpty { return .some(inbox.removeFirst()) }
                if ended != nil { return .some(nil) }
                receivers.append(continuation)
                return .none
            }
            if case .some(let message) = ready { continuation.resume(returning: message) }
        }
        if let message { return message }
        throw ElevenLabsRealtimeError.closed(endedWith ?? ElevenLabsSocketClose(code: 0, reason: ""))
    }

    public func ping() async throws {
        lock.withLock { _pings += 1 }
    }

    public func close(code: Int, reason: String) async {
        let close = ElevenLabsSocketClose(code: code, reason: reason)
        lock.withLock { if _closedByClient == nil, ended == nil { _closedByClient = close } }
        finish(close)
    }

    private func finish(_ close: ElevenLabsSocketClose) {
        let waiting: [CheckedContinuation<ElevenLabsSocketMessage?, Never>] = lock.withLock {
            guard ended == nil else { return [] }
            ended = close
            defer { receivers = [] }
            // Frames pushed before the close are still delivered, as a real socket would.
            return inbox.isEmpty ? receivers : []
        }
        for receiver in waiting { receiver.resume(returning: nil) }
    }
}
