import Foundation

/// One frame of `GET /events`. The case name is the SSE event name, so a client switches on
/// the same word the server wrote.
public enum BuddyEvent: Sendable {
    case status(ControlAPI.Status)
    case download(ControlAPI.DownloadEvent)
    case job(ControlAPI.JobEvent)
    case heartbeat(ControlAPI.HeartbeatEvent)

    public var name: String {
        switch self {
        case .status: "status"
        case .download: "download"
        case .job: "job"
        case .heartbeat: "heartbeat"
        }
    }

    /// Compact on purpose: an SSE frame ends at a blank line, so a pretty-printed payload
    /// would need escaping that no client should have to undo.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        switch self {
        case .status(let value): return try encoder.encode(value)
        case .download(let value): return try encoder.encode(value)
        case .job(let value): return try encoder.encode(value)
        case .heartbeat(let value): return try encoder.encode(value)
        }
    }
}

/// Where the app posts what changed, and where every subscribed device reads it.
///
/// A broadcaster rather than a callback on `ControlHost`, because nothing in the app should
/// have to know whether a phone happens to be listening. When nobody is subscribed, posting
/// is a no-op that costs an actor hop.
public actor BuddyEventHub {

    public static let shared = BuddyEventHub()

    private var listeners: [UUID: AsyncStream<BuddyEvent>.Continuation] = [:]

    public init() {}

    public var subscriberCount: Int { listeners.count }

    public func subscribe() -> (id: UUID, stream: AsyncStream<BuddyEvent>) {
        let id = UUID()
        // Buffering the newest few: a phone on a slow link should get the current state,
        // not a queue of every percentage point it missed.
        let stream = AsyncStream<BuddyEvent>(bufferingPolicy: .bufferingNewest(32)) {
            continuation in
            listeners[id] = continuation
        }
        return (id, stream)
    }

    /// Ends one subscription. Also what a cancelled `/events` task calls, because finishing
    /// the continuation is the only thing that breaks the reader out of its `for await`.
    public func cancel(_ id: UUID) {
        listeners.removeValue(forKey: id)?.finish()
    }

    public func post(_ event: BuddyEvent) {
        for listener in listeners.values { listener.yield(event) }
    }
}
