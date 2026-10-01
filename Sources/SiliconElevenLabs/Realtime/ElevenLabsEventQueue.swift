import Foundation

/// A session's events on their way to its reader, bounded.
///
/// Up to `capacity` events may wait; one more place is kept for the session's last event
/// (`.ended`), so that one is always delivered. When `capacity` are waiting, the reader has
/// fallen behind — or the server is flooding — and the session is ended rather than left to
/// grow without limit: the socket is closed with 1011 and `fellBehindReason`, which the session's
/// `.ended` then carries, and events after that are dropped. Nothing reconnects.
final class ElevenLabsEventQueue<Event: Sendable>: @unchecked Sendable {
    /// The close reason a session ended this way carries (and ElevenLabs is sent).
    static var fellBehindReason: String { "This app fell behind reading the session" }
    static var fellBehindCode: Int { 1011 }

    let stream: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let channel: ElevenLabsRealtimeChannel
    private let lock = NSLock()
    private var overflowed = false

    init(capacity: Int, channel: ElevenLabsRealtimeChannel) {
        self.channel = channel
        (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingOldest(max(1, capacity) + 1))
    }

    /// Hands `event` to the reader, unless the queue has already overflowed.
    func yield(_ event: Event) {
        guard !lock.withLock({ overflowed }) else { return }
        let full: Bool = switch continuation.yield(event) {
        case .enqueued(let remaining): remaining <= 1
        case .dropped: true
        case .terminated: false
        @unknown default: false
        }
        guard full, lock.withLock({ () -> Bool in
            defer { overflowed = true }
            return !overflowed
        }) else { return }
        let channel = channel
        Task {
            await channel.close(code: Self.fellBehindCode, reason: Self.fellBehindReason, discardingQueued: true)
        }
    }

    /// The session's last event, in the place kept for it; nothing follows.
    func finish(with last: Event) {
        continuation.yield(last)
        continuation.finish()
    }
}
