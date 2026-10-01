import Foundation
import Testing
@testable import SiliconElevenLabs

/// The production socket (`URLSessionWebSocketTask`) against a loopback WebSocket server, for
/// what an in-memory fake cannot show: the upgrade request as sent, messages past Foundation's
/// 1 MiB default, close codes Foundation has no name for (4300), refused and redirected
/// upgrades, cancellation. Nothing here leaves 127.0.0.1.
@Suite("ElevenLabs realtime sockets on the wire", .serialized)
struct RealtimeWireTests {

    static let key = "sk_" + String(repeating: "wirerealtime", count: 3)

    /// The key goes on the upgrade request, in `xi-api-key`, and nowhere else: not in the
    /// request line, not in a frame.
    @Test func theKeyTravelsInTheUpgradeHeaderAndNowhereElse() async throws {
        let server = try RealtimeLoopbackServer { _ in
            .accept { connection in
                _ = await connection.text(0)
                connection.sendJSON(["isFinal": true])
            }
        }
        defer { server.stop() }
        let connector = URLSessionWebSocketConnector.loopbackForTesting(port: Int(server.port))
        let request = ElevenLabsSocketRequest(
            url: server.url("/v1/text-to-speech/voice1/stream-input?model_id=eleven_flash_v2_5&output_format=pcm_16000"),
            headers: ["xi-api-key": Self.key]
        )
        let socket = try await connector.connect(request)
        try await socket.send(.text(#"{"text":" "}"#))
        #expect(try await socket.receive() == .text(#"{"isFinal":true}"#))
        await socket.close(code: 1000, reason: "")

        let upgrade = try #require(server.receivedUpgrades.first)
        #expect(upgrade.headers["xi-api-key"] == Self.key)
        #expect(!upgrade.target.contains(Self.key))
        #expect(upgrade.target == "/v1/text-to-speech/voice1/stream-input?model_id=eleven_flash_v2_5&output_format=pcm_16000")
        let connection = try #require(server.openedConnections.first)
        #expect(connection.texts == [#"{"text":" "}"#])
        // Nothing that prints the request shows the key.
        #expect(!request.description.contains(Self.key))
        #expect(!String(reflecting: request).contains(Self.key))
        var dumped = ""
        dump(request, to: &dumped)
        #expect(!dumped.contains(Self.key))
    }

    /// Foundation's default limit is 1 MiB; the SDKs take 16. The connector raises it before the
    /// task starts, so a three-megabyte message (a long alignment, a big audio chunk) arrives.
    @Test func messagesOverAMegabyteArriveAndTheLimitHolds() async throws {
        let big = String(repeating: "a", count: 3 << 20)
        let server = try RealtimeLoopbackServer { _ in
            .accept { connection in connection.sendText(big) }
        }
        defer { server.stop() }
        let connector = URLSessionWebSocketConnector.loopbackForTesting(port: Int(server.port))
        let socket = try await connector.connect(ElevenLabsSocketRequest(url: server.url("/big")))
        let message = try await socket.receive()
        #expect(message == .text(big))
        await socket.close(code: 1000, reason: "")

        // With Foundation's 1 MiB default the same message never arrives.
        let limited = try await connector.connect(ElevenLabsSocketRequest(url: server.url("/big"), maximumMessageSize: 1 << 20))
        await #expect(throws: ElevenLabsRealtimeError.messageTooLarge) { _ = try await limited.receive() }
    }

    /// 4300 has no case in `URLSessionWebSocketTask.CloseCode`; it is read by number.
    @Test(arguments: [(4300, "queue timed out"), (1008, "policy"), (1000, "bye"), (1011, "internal")])
    func closeCodesAreReadByNumber(code: Int, reason: String) async throws {
        let server = try RealtimeLoopbackServer { _ in
            .accept { connection in connection.close(code: code, reason: reason) }
        }
        defer { server.stop() }
        let connector = URLSessionWebSocketConnector.loopbackForTesting(port: Int(server.port))
        let socket = try await connector.connect(ElevenLabsSocketRequest(url: server.url("/close")))
        do {
            _ = try await socket.receive()
            Issue.record("expected the socket to end")
        } catch ElevenLabsRealtimeError.closed(let close) {
            #expect(close.code == code)
            #expect(close.reason == reason)
            #expect(close.kind == (code == 4300 ? .queueTimedOut : code == 1000 ? .normal : .error))
        }
        // Sending on it now says it has closed.
        await #expect(throws: ElevenLabsRealtimeError.self) { try await socket.send(.text("{}")) }
    }

    @Test func aDroppedConnectionEndsWithNoCode() async throws {
        let server = try RealtimeLoopbackServer { _ in
            .accept { connection in
                try? await Task.sleep(for: .milliseconds(50))
                connection.drop()
            }
        }
        defer { server.stop() }
        let connector = URLSessionWebSocketConnector.loopbackForTesting(port: Int(server.port))
        let socket = try await connector.connect(ElevenLabsSocketRequest(url: server.url("/drop")))
        do {
            _ = try await socket.receive()
            Issue.record("expected the socket to end")
        } catch ElevenLabsRealtimeError.closed(let close) {
            #expect(close.kind == .error)
        }
    }

    /// The client's close frame carries the code and reason.
    ///
    /// What a busy process does: in a full test run, URLSession now and then ends the TCP
    /// connection with a FIN and no close frame at all (the server reads zero frames, then the
    /// FIN) — measured at 2–6 sockets in 8 in full runs, never in a run of the wire tests alone.
    /// It is Foundation's, not the server's reading (the server's end is a clean FIN, not a reset),
    /// and the socket has ended either way. So, as in a session — whose reader always has a
    /// receive pending when it closes — each socket here has one, and sockets are tried until a
    /// frame is read (twenty at most, a little apart, since the losses come in runs). A frame read
    /// must carry exactly 1000 and the reason; none read in twenty is a failure: a close that
    /// sends no frame fails every time.
    @Test func closingSendsTheCodeAndReason() async throws {
        let server = try RealtimeLoopbackServer { _ in .accept { _ in } }
        defer { server.stop() }
        let connector = URLSessionWebSocketConnector.loopbackForTesting(port: Int(server.port))
        var seen: (code: Int?, reason: String)?
        var lost: [String] = []
        for attempt in 0..<20 where seen == nil {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(50)) }
            let socket = try await connector.connect(ElevenLabsSocketRequest(url: server.url("/bye")))
            let pending = Task { () -> Bool in
                do { _ = try await socket.receive(); return false } catch { return true }
            }
            try await Task.sleep(for: .milliseconds(20))
            await socket.close(code: 1000, reason: "User ended conversation")
            try #require(await server.waitForConnections(attempt + 1))
            let connection = server.openedConnections[attempt]
            seen = await connection.waitForClose()
            if seen == nil { lost.append(connection.endedBy) }
            // Either way the socket has ended: the pending receive throws.
            #expect(await pending.value)
        }
        let frame = try #require(seen, "no close frame was read from 20 sockets (their ends: \(lost))")
        #expect(frame.code == 1000)
        #expect(frame.reason == "User ended conversation")
    }

    @Test func aPingIsAnswered() async throws {
        let server = try RealtimeLoopbackServer { _ in .accept { _ in } }
        defer { server.stop() }
        let connector = URLSessionWebSocketConnector.loopbackForTesting(port: Int(server.port))
        let socket = try await connector.connect(ElevenLabsSocketRequest(url: server.url("/ping")))
        try await socket.ping()
        let connection = try #require(server.openedConnections.first)
        #expect(connection.received.contains { if case .ping = $0 { true } else { false } })
        await socket.close(code: 1000, reason: "")
    }

    @Test(arguments: [401, 403, 404, 429, 500])
    func aRefusedUpgradeSaysItsStatus(status: Int) async throws {
        let server = try RealtimeLoopbackServer { _ in .refuse(status: status, headers: [:]) }
        defer { server.stop() }
        let connector = URLSessionWebSocketConnector.loopbackForTesting(port: Int(server.port))
        do {
            _ = try await connector.connect(ElevenLabsSocketRequest(url: server.url("/v1/speech-to-text/realtime"),
                                                                    headers: ["xi-api-key": Self.key]))
            Issue.record("expected a refusal")
        } catch let error as ElevenLabsRealtimeError {
            #expect(error == .handshakeFailed(status: status, message: HTTPURLResponse.localizedString(forStatusCode: status)))
            #expect(!error.description.contains(Self.key))
        }
    }

    /// A redirect answer to the upgrade is not followed: the key stays with the host it was for.
    @Test func aRedirectedUpgradeIsNotFollowed() async throws {
        let server = try RealtimeLoopbackServer { upgrade in
            upgrade.target == "/v1/speech-to-text/realtime"
                ? .refuse(status: 302, headers: ["Location": "/elsewhere"])
                : .accept { _ in }
        }
        defer { server.stop() }
        let connector = URLSessionWebSocketConnector.loopbackForTesting(port: Int(server.port))
        await #expect(throws: ElevenLabsRealtimeError.self) {
            _ = try await connector.connect(ElevenLabsSocketRequest(
                url: server.url("/v1/speech-to-text/realtime"), headers: ["xi-api-key": Self.key]
            ))
        }
        #expect(server.receivedUpgrades.map(\.target) == ["/v1/speech-to-text/realtime"])
    }

    @Test func cancellingAConnectStopsIt() async throws {
        let server = try RealtimeLoopbackServer { _ in .hang }
        defer { server.stop() }
        let connector = URLSessionWebSocketConnector.loopbackForTesting(port: Int(server.port))
        // A minute's open timeout, so only the cancel can end it inside the bound below.
        let task = Task { try await connector.connect(ElevenLabsSocketRequest(url: server.url("/hang"), openTimeout: 60)) }
        let deadline = ContinuousClock.now + .seconds(60)
        while server.receivedUpgrades.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let started = ContinuousClock.now
        task.cancel()
        await #expect(throws: ElevenLabsRealtimeError.cancelled) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(30))
    }

    @Test func aHandshakeThatNeverAnswersTimesOut() async throws {
        let server = try RealtimeLoopbackServer { _ in .hang }
        defer { server.stop() }
        let connector = URLSessionWebSocketConnector.loopbackForTesting(port: Int(server.port))
        await #expect(throws: ElevenLabsRealtimeError.self) {
            _ = try await connector.connect(ElevenLabsSocketRequest(url: server.url("/slow"), openTimeout: 0.5))
        }
    }

    /// Only `wss` to the five region hosts, on the default port, with no user in the URL — and the
    /// production connector has no loopback allowance at all.
    @Test func onlyTheRegionHostsOverWSSAreOpened() async throws {
        let allowed = ElevenLabsRegion.allowedHosts
        for region in ElevenLabsRegion.allCases {
            #expect(URLSessionWebSocketConnector.isAllowed(region.webSocketBaseURL.appendingPathComponent("v1"),
                                                            allowedHosts: allowed, loopbackPort: nil))
        }
        for text in [
            "ws://api.elevenlabs.io/v1/speech-to-text/realtime", "https://api.elevenlabs.io/v1/x",
            "wss://api.elevenlabs.io.example.com/v1/x", "wss://api.elevenlabs.io:8443/v1/x",
            "wss://user:pass@api.elevenlabs.io/v1/x", "wss://elevenlabs.io/v1/x", "wss://127.0.0.1/v1/x",
            "wss://API.ELEVENLABS.IO/v1/x", "ws://127.0.0.1:9/v1/x",
        ] {
            #expect(!URLSessionWebSocketConnector.isAllowed(URL(string: text)!, allowedHosts: allowed, loopbackPort: nil), "\(text)")
        }
        let server = try RealtimeLoopbackServer { _ in .accept { _ in } }
        defer { server.stop() }
        // The loopback allowance is one port, plain ws, on 127.0.0.1 only.
        #expect(!URLSessionWebSocketConnector.isAllowed(URL(string: "ws://127.0.0.1:\(Int(server.port) + 1)/")!,
                                                         allowedHosts: allowed, loopbackPort: Int(server.port)))
        #expect(!URLSessionWebSocketConnector.isAllowed(URL(string: "ws://localhost:\(server.port)/")!,
                                                         allowedHosts: allowed, loopbackPort: Int(server.port)))
        await #expect(throws: ElevenLabsRealtimeError.refusedHost("127.0.0.1")) {
            _ = try await URLSessionWebSocketConnector().connect(ElevenLabsSocketRequest(url: server.url("/")))
        }
        #expect(server.receivedUpgrades.isEmpty)
    }

}
