import Foundation

/// The plumbing every session shares: one socket, one writer that sends frames strictly in the
/// order they were queued (an `urgent` frame — a pong — jumps the queue so it never waits behind
/// seconds of audio), and one reader that hands each frame to the session in arrival order.
///
/// There is no reconnect anywhere below this: a socket that ends, ends the session. A new
/// session is a new, separately billed connection, and only the owner (or the caller) opens one.
final class ElevenLabsRealtimeChannel: @unchecked Sendable {
    let socket: any ElevenLabsSocket
    private let lock = NSLock()
    private var urgent: [Outgoing] = []
    private var normal: [Outgoing] = []
    private var waiter: CheckedContinuation<Outgoing?, Never>?
    /// Frames the writer has taken and not yet finished sending: a close waits for these too,
    /// not only for the queue (a decline handed to the writer just before a close was lost).
    private var sending = 0
    private var finished: ElevenLabsRealtimeError?
    private var writer: Task<Void, Never>?
    private var reader: Task<Void, Never>?

    struct Outgoing: Sendable {
        var message: ElevenLabsSocketMessage
        var done: (@Sendable (ElevenLabsRealtimeError?) -> Void)?
    }

    init(socket: any ElevenLabsSocket) {
        self.socket = socket
    }

    /// Starts the writer and the reader. `onFrame` gets every frame; `onEnd` once, with how the
    /// socket ended.
    func start(
        onFrame: @escaping @Sendable (ElevenLabsSocketMessage) async -> Void,
        onEnd: @escaping @Sendable (ElevenLabsRealtimeError) async -> Void
    ) {
        let socket = socket
        writer = Task { [weak self] in
            while let item = await self?.next() {
                do {
                    try await socket.send(item.message)
                    self?.sent()
                    item.done?(nil)
                } catch {
                    let failure = ElevenLabsRealtimeError(wrapping: error)
                    self?.sent()
                    item.done?(failure)
                    self?.finish(failure)
                    return
                }
            }
        }
        reader = Task { [weak self] in
            while true {
                do {
                    let frame = try await socket.receive()
                    await onFrame(frame)
                } catch {
                    let failure = ElevenLabsRealtimeError(wrapping: error)
                    self?.finish(failure)
                    await onEnd(failure)
                    return
                }
            }
        }
    }

    /// Queues a frame; returns once the socket has taken it (or refused it).
    func send(_ message: ElevenLabsSocketMessage, urgent isUrgent: Bool = false) async throws {
        let failure: ElevenLabsRealtimeError? = await withCheckedContinuation { continuation in
            let item = Outgoing(message: message) { continuation.resume(returning: $0) }
            if let refused = enqueue(item, urgent: isUrgent) { continuation.resume(returning: refused) }
        }
        if let failure { throw failure }
    }

    /// Queues a frame without waiting for it — for a pong, sent from the reader.
    func post(_ message: ElevenLabsSocketMessage, urgent isUrgent: Bool = false) {
        _ = enqueue(Outgoing(message: message, done: nil), urgent: isUrgent)
    }

    /// Queues `json` as a text frame.
    func send(json: JSONValue, urgent: Bool = false) async throws {
        try await send(.text(json.jsonString()), urgent: urgent)
    }

    /// Closes the socket: frames already queued are sent first unless `discardingQueued`.
    func close(code: Int = ElevenLabsSocketClose.normalClosure, reason: String, discardingQueued: Bool = false) async {
        if !discardingQueued { await drain() }
        finish(.closed(ElevenLabsSocketClose(code: code, reason: reason)))
        await socket.close(code: code, reason: reason)
    }

    /// Whether the channel has ended (closed by either side).
    var hasEnded: Bool { lock.withLock { finished != nil } }

    /// Waits for the reader to see the end of the socket.
    func waitForReader() async {
        await reader?.value
    }

    // MARK: - Queue

    private enum Step {
        case refused(ElevenLabsRealtimeError)
        case handoff(CheckedContinuation<Outgoing?, Never>)
        case queued
    }

    /// Nil when queued (or handed straight to the waiting writer); the failure when the
    /// channel has already ended.
    private func enqueue(_ item: Outgoing, urgent isUrgent: Bool) -> ElevenLabsRealtimeError? {
        let step: Step = lock.withLock {
            if let finished { return .refused(finished) }
            if let waiter {
                self.waiter = nil
                sending += 1
                return .handoff(waiter)
            }
            if isUrgent { urgent.append(item) } else { normal.append(item) }
            return .queued
        }
        switch step {
        case .refused(let failure): return failure
        case .handoff(let waiter):
            waiter.resume(returning: item)
            return nil
        case .queued: return nil
        }
    }

    private func next() async -> Outgoing? {
        await withCheckedContinuation { continuation in
            let ready: Outgoing?? = lock.withLock {
                if !urgent.isEmpty {
                    sending += 1
                    return .some(urgent.removeFirst())
                }
                if !normal.isEmpty {
                    sending += 1
                    return .some(normal.removeFirst())
                }
                if finished != nil { return .some(nil) }
                waiter = continuation
                return .none
            }
            if case .some(let item) = ready { continuation.resume(returning: item) }
        }
    }

    private func sent() {
        lock.withLock { sending -= 1 }
    }

    /// Waits until everything queued has been sent, the frame being written included — two
    /// seconds at most: a socket that has stalled must not keep a close waiting for ever.
    private func drain() async {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let empty = lock.withLock { urgent.isEmpty && normal.isEmpty && sending == 0 }
            if empty || hasEnded { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func finish(_ failure: ElevenLabsRealtimeError) {
        let (dropped, idle): ([Outgoing], CheckedContinuation<Outgoing?, Never>?) = lock.withLock {
            guard finished == nil else { return ([], nil) }
            finished = failure
            let dropped = urgent + normal
            urgent = []
            normal = []
            defer { waiter = nil }
            return (dropped, waiter)
        }
        idle?.resume(returning: nil)
        for item in dropped { item.done?(failure) }
    }
}
