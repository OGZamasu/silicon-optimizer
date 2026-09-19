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

enum EventStreamError: Error, LocalizedError, Equatable {
    case writeTimedOut
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeTimedOut: "The device stopped reading this stream."
        case .writeFailed(let reason): reason
        }
    }
}

/// Writes SSE frames down one connection.
///
/// An actor because `/events` writes from two places at once — the hub's forwarder and the
/// heartbeat — and half of one frame interleaved with half of another is not recoverable by
/// any client.
actor EventStreamWriter {

    private let connection: NWConnection
    private let deadline: Duration
    private var opened = false

    /// `deadline` is how long one frame may take to leave. A phone that goes out of range
    /// without closing the socket leaves a send that never completes and never errors;
    /// `Task.cancel` cannot reach into Network.framework, so without it that connection —
    /// and the stream slot behind it — is held until the app quits.
    init(connection: NWConnection, deadline: Duration = ControlServer.defaultEventWriteDeadline) {
        self.connection = connection
        self.deadline = deadline
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

    /// A frame the hub has already encoded — once, for every subscriber it went to.
    func send(_ frame: BuddyEvent.Frame) async throws {
        try await send(event: frame.name, data: frame.data)
    }

    /// Says no. Before the first frame that is an ordinary HTTP status, which is what a
    /// phone can act on; afterwards the head is long gone and an `error` event is all that
    /// is left. Deciding late is why nothing is written until a route has actually started.
    func refuse(status: Int, message: String) async {
        if opened {
            try? await send(event: "error", json: ControlAPI.ErrorResponse(error: message))
        } else {
            opened = true
            try? await HTTPResponse.error(status, message).write(to: connection)
        }
    }

    private func write(_ payload: Data) async throws {
        let connection = self.connection
        let deadline = self.deadline
        try await withTaskCancellationHandler {
            switch await Self.deliver(payload, over: connection, within: deadline) {
            case .sent: return
            case .timedOut: throw EventStreamError.writeTimedOut
            case .failed(let reason): throw EventStreamError.writeFailed(reason)
            }
        } onCancel: {
            // A pending `send` cannot be cancelled; closing the socket is what unblocks it.
            connection.cancel()
        }
    }

    private enum Outcome: Sendable {
        case sent
        case timedOut
        case failed(String)
    }

    private static func deliver(
        _ payload: Data, over connection: NWConnection, within deadline: Duration
    ) async -> Outcome {
        await withTaskGroup(of: Outcome.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                    connection.send(content: payload, completion: .contentProcessed { error in
                        continuation.resume(
                            returning: error.map { .failed($0.localizedDescription) } ?? .sent
                        )
                    })
                }
            }
            group.addTask {
                guard (try? await Task.sleep(for: deadline)) != nil else {
                    return .failed("Cancelled.")
                }
                // Cancelling the connection is what makes the send above complete, so the
                // group can be drained instead of leaking a task that waits forever.
                connection.cancel()
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }
}
