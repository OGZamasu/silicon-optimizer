import Foundation
import Testing
@testable import SiliconControl

/// How long a request may take to arrive.
///
/// The read deadline was fifteen seconds for headers and body together, which cut a phone's
/// 24 MiB upload off part-way on any link slower than about thirteen megabits — with no
/// answer written, so the phone said it could not reach the Mac. A body is now held to
/// progress, and to a minimum average rate, rather than to a fixed time. The deadlines are
/// scaled down here so none of this takes a minute.
@Suite("Control server request read deadlines")
struct RequestReadDeadlineTests {

    /// A body that keeps arriving, however long it takes overall, is read to the end.
    @Test func aSlowButSteadyBodyIsReadToTheEnd() async throws {
        let deadlines = ControlServer.ReadDeadlines(
            headers: .seconds(1), idle: .seconds(1), minimumBytesPerSecond: 1
        )
        try await withDeadlines(deadlines) { port, token in
            let body = Data(#"{"title":"Uploaded slowly"}"#.utf8)
                + Data(repeating: 0x20, count: 380)
            let raw = try await RawConnection.connect(port: port)
            defer { raw.close() }
            try await raw.send(
                Self.head("POST", "/conversations", token: token, length: body.count)
            )
            // Three seconds for the body, three times the old whole-request deadline, and
            // never more than a third of the idle one between two pieces of it.
            for piece in stride(from: 0, to: body.count, by: body.count / 10 + 1) {
                try await Task.sleep(for: .milliseconds(300))
                let end = min(body.count, piece + body.count / 10 + 1)
                try await raw.send(String(decoding: body[piece..<end], as: UTF8.self))
            }
            let answer = try await Self.firstBytes(from: raw, within: .seconds(5))
            #expect(answer.hasPrefix("HTTP/1.1 200"), "\(answer)")
        }
    }

    /// A body that stops arriving is given up on after the idle deadline, not held open.
    @Test func aStalledBodyIsGivenUpOnAfterTheIdleDeadline() async throws {
        let deadlines = ControlServer.ReadDeadlines(
            headers: .seconds(5), idle: .milliseconds(500), minimumBytesPerSecond: 1
        )
        try await withDeadlines(deadlines) { port, token in
            let raw = try await RawConnection.connect(port: port)
            defer { raw.close() }
            try await raw.send(Self.head("POST", "/conversations", token: token, length: 400))
            try await raw.send(#"{"title":"#)
            let started = ContinuousClock.now
            let answer = try await Self.firstBytes(from: raw, within: .seconds(5))
            #expect(!answer.hasPrefix("HTTP/1.1 200"))
            #expect(ContinuousClock.now - started < .seconds(3), "the connection was held")
        }
    }

    /// And one that trickles a byte just inside every idle window is cut off once it has
    /// fallen behind the minimum rate: progress, but not enough of it, does not keep a slot.
    @Test func aBodyThatTricklesInIsCutOffAtItsCeiling() async throws {
        let deadlines = ControlServer.ReadDeadlines(
            headers: .seconds(5), idle: .seconds(1), minimumBytesPerSecond: 100
        )
        try await withDeadlines(deadlines) { port, token in
            let raw = try await RawConnection.connect(port: port)
            defer { raw.close() }
            // 100 bytes at 100 a second, after a second's grace: two seconds, where a byte
            // every 300 ms would take thirty.
            try await raw.send(Self.head("POST", "/conversations", token: token, length: 100))
            let trickle = Task {
                for _ in 0..<100 {
                    try await Task.sleep(for: .milliseconds(300))
                    try await raw.send(" ")
                }
            }
            defer { trickle.cancel() }
            let started = ContinuousClock.now
            let answer = try await Self.firstBytes(from: raw, within: .seconds(8))
            #expect(!answer.hasPrefix("HTTP/1.1 200"))
            #expect(ContinuousClock.now - started < .seconds(5), "the trickle kept its slot")
        }
    }

    @Test func theStandardCeilingLeavesRoomForAPhonesLargestUploadOnASlowLink() {
        let standard = ControlServer.ReadDeadlines.standard
        let start = ContinuousClock.now
        // 24 MiB at one megabit a second takes a little over three minutes.
        let oneMegabit = Duration.seconds(Double(BuddyUploads.maximumBytes) * 8 / 1_000_000)
        #expect(standard.ceiling(forBodyOf: BuddyUploads.maximumBytes, from: start)
            > start + oneMegabit * 4)
        // A pairing request, which anybody on the tailnet may send, is still over quickly.
        #expect(standard.ceiling(forBodyOf: BuddyLimits.unauthenticatedBodyBytes, from: start)
            < start + .seconds(30))
    }

    // MARK: - Helpers

    static func head(_ method: String, _ path: String, token: String, length: Int) -> String {
        "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer \(token)\r\n"
            + "Content-Type: application/json\r\nContent-Length: \(length)\r\n\r\n"
    }

    /// What the server sends first, or "" when it closes without a word. A server that does
    /// neither within `limit` fails the test rather than hanging it.
    static func firstBytes(
        from raw: RawConnection, within limit: Duration
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask { (try? await raw.readSome()) ?? "" }
            group.addTask {
                try await Task.sleep(for: limit)
                return nil
            }
            let first = try await group.next() ?? nil
            raw.close()
            group.cancelAll()
            guard let first else { throw BuddyTestError.timeout }
            return first
        }
    }

    private func withDeadlines(
        _ deadlines: ControlServer.ReadDeadlines,
        _ body: (_ port: Int, _ token: String) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("read-deadlines-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handshakeURL = directory.appendingPathComponent("control.json")
        let server = ControlServer(
            host: BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false),
            handshakeURL: handshakeURL,
            buddy: BuddyRegistry(url: directory.appendingPathComponent("buddy.json")),
            events: BuddyEventHub(), media: MediaRegistry(url: nil),
            uploadsRoot: directory.appendingPathComponent("uploads"),
            postersRoot: directory.appendingPathComponent("posters"),
            readDeadlines: deadlines,
            discoverTailnetAddress: { nil }
        )
        try await server.start()
        defer { Task { await server.stop() } }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: handshakeURL.path) {
            guard ContinuousClock.now < deadline else { throw BuddyTestError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
        let handshake = try JSONDecoder().decode(
            ControlAPI.Handshake.self, from: try Data(contentsOf: handshakeURL)
        )
        try await body(handshake.port, handshake.token)
        await server.stop()
    }
}
