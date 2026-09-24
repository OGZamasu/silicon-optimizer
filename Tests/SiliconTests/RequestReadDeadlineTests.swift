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

    /// A body is read for as long as it keeps arriving at a slow link's pace, so how much a
    /// caller may send is also how long it may hold a connection. Somebody with a token
    /// nobody issued may send what somebody with no token may, and is told 401 before a byte
    /// of anything larger is read — rather than holding a slot for minutes while four
    /// megabytes trickle in.
    @Test func anUnknownBearerIsAnsweredBeforeItsBodyIsRead() async throws {
        let deadlines = ControlServer.ReadDeadlines(
            headers: .seconds(5), idle: .seconds(2), minimumBytesPerSecond: 16 * 1024
        )
        try await withServer(deadlines) { fixture in
            let raw = try await RawConnection.connect(port: fixture.tailnetPort)
            defer { raw.close() }
            try await raw.send(Self.head(
                "POST", "/chat", token: "not-issued", length: BuddyLimits.requestBodyBytes
            ))
            let trickle = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(500))
                    try await raw.send(" ")
                }
            }
            defer { trickle.cancel() }
            let answer = try await Self.firstBytes(from: raw, within: .seconds(4))
            #expect(answer.hasPrefix("HTTP/1.1 401"), "\(answer)")
        }
    }

    /// And what that leaves alone: anybody's `/health` and `/buddy/pair`, whatever stale
    /// token rides along; a paired phone's large request; and a revoked phone still hearing
    /// 401, the answer that tells it to pair again, rather than "too large".
    @Test func anUnknownBearerIsStillAnsweredAsItWasBefore() async throws {
        try await withServer(.standard) { fixture in
            let phone = fixture.phone
            #expect(try await phone.status("GET", "/health", token: "not-issued") == 200)

            let stale = "a-token-from-before-the-phone-was-revoked"
            let invitation = await fixture.registry.invite(
                host: "127.0.0.1", port: fixture.tailnetPort
            )
            #expect(try await phone.status(
                "POST", "/buddy/pair", token: stale,
                body: #"{"code":"\#(invitation.code)","deviceName":"Phone","platform":"ios"}"#
            ) == 200)

            let paired = try await fixture.pair()
            let photo = "data:image/jpeg;base64," + String(repeating: "A", count: 1_500_000)
            let chat = #"{"messages":[{"role":"user","content":"What is this?","images":[""#
                + photo + #""]}]}"#
            #expect(try await phone.status("POST", "/chat", token: paired.token, body: chat)
                == 200)

            #expect(await fixture.registry.revoke(deviceID: paired.deviceID))
            #expect(try await phone.status("POST", "/chat", token: paired.token, body: chat)
                == 401)
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

    /// The server under test, reachable on loopback and on a stand-in for the tailnet
    /// listener, with its own device registry and every file in a temporary folder.
    struct Fixture {
        let port: Int
        let token: String
        let tailnetPort: Int
        let registry: BuddyRegistry
        let session: URLSession

        var phone: TestClient { TestClient(port: tailnetPort, token: token, session: session) }

        func pair() async throws -> ControlAPI.BuddyPairResponse {
            let invitation = await registry.invite(host: "127.0.0.1", port: tailnetPort)
            let (status, body) = try await phone.call(
                "POST", "/buddy/pair", token: nil,
                body: #"{"code":"\#(invitation.code)","deviceName":"Phone","platform":"ios"}"#
            )
            #expect(status == 200)
            return try JSONDecoder().decode(ControlAPI.BuddyPairResponse.self, from: body)
        }
    }

    private func withDeadlines(
        _ deadlines: ControlServer.ReadDeadlines,
        _ body: (_ port: Int, _ token: String) async throws -> Void
    ) async throws {
        try await withServer(deadlines) { try await body($0.port, $0.token) }
    }

    private func withServer(
        _ deadlines: ControlServer.ReadDeadlines, _ body: (Fixture) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("read-deadlines-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handshakeURL = directory.appendingPathComponent("control.json")
        let registry = BuddyRegistry(url: directory.appendingPathComponent("buddy.json"))
        let server = ControlServer(
            host: BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false),
            handshakeURL: handshakeURL, buddy: registry,
            events: BuddyEventHub(), media: MediaRegistry(url: nil),
            uploadsRoot: directory.appendingPathComponent("uploads"),
            postersRoot: directory.appendingPathComponent("posters"),
            readDeadlines: deadlines,
            discoverTailnetAddress: { nil }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

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
        await registry.setAllowsTailnetDevices(true)
        let tailnetPort = try await BuddyControlTests.bindTailnetListener(
            on: server, avoiding: handshake.port
        )
        try await body(Fixture(
            port: handshake.port, token: handshake.token, tailnetPort: tailnetPort,
            registry: registry, session: session
        ))
        await server.stop()
    }
}
