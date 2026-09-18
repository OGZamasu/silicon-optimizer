import Foundation
import Network

/// A route that answers `text/event-stream`.
///
/// The rest of this server replies in one buffer; a stream is the opposite shape — headers
/// first, then frames for as long as both sides stay interested. `run` returning is what
/// ends the response, so a route ends by returning rather than by writing a terminator.
struct EventSource: Sendable {
    let run: @Sendable (EventStreamWriter) async -> Void
}

/// Writes SSE frames down one connection.
///
/// An actor because `/events` writes from two places at once — the hub's forwarder and the
/// heartbeat — and half of one frame interleaved with half of another is not recoverable
/// by any client.
actor EventStreamWriter {

    private let connection: NWConnection
    private var opened = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Sends the response head. Idempotent, so an error path can open a stream that never
    /// got as far as its first frame and still say what went wrong.
    func open() async throws {
        guard !opened else { return }
        opened = true
        // No Content-Length: the body ends when the connection does. `no-store` and the
        // proxy hint keep anything in between from buffering a stream into a single reply.
        let head = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream; charset=utf-8",
            "Cache-Control: no-store",
            "X-Accel-Buffering: no",
            "Connection: close",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        try await write(Data(head.utf8))
    }

    func send(event: String, data: Data) async throws {
        try await open()
        var frame = Data("event: \(event)\ndata: ".utf8)
        frame.append(data)
        frame.append(Data("\n\n".utf8))
        try await write(frame)
    }

    func send(event: String, json value: some Encodable) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try await send(event: event, data: try encoder.encode(value))
    }

    func send(_ event: BuddyEvent) async throws {
        try await send(event: event.name, data: try event.encoded())
    }

    private func write(_ payload: Data) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
