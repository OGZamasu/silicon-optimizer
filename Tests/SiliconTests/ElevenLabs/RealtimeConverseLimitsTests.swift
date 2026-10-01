import Foundation
import Testing
import SiliconElevenLabs
@testable import SiliconControl
@testable import SiliconUI

/// How long `elevenlabs_agent_converse` can bill: only what the agent says or does holds a turn
/// open (pings, VAD scores and context usage do not), the whole conversation has a cap, and one
/// conversation runs at a time. In-memory transport and socket only.
@Suite("ElevenLabs realtime over control: how long a conversation runs")
struct RealtimeConverseLimitsTests {

    /// The events that are not activity, one frame each.
    static let noise = ["ping", "vad_score", "context_usage", "agent_response_metadata", "mcp_connection_status", "queue_status"]

    static func noiseFrame(_ kind: String, _ id: Int) -> JSONValue {
        switch kind {
        case "ping": ["type": "ping", "ping_event": ["event_id": .number(Double(id)), "ping_ms": 20]]
        case "vad_score": ["type": "vad_score", "vad_score_event": ["vad_score": 0.4]]
        case "context_usage": ["type": "context_usage", "context_usage_event": ["context_tokens": .number(Double(id))]]
        case "agent_response_metadata":
            ["type": "agent_response_metadata", "agent_response_metadata_event": ["metadata": [:], "event_id": .number(Double(id))]]
        case "mcp_connection_status": ["type": "mcp_connection_status", "mcp_connection_status": ["status": "connected"]]
        default: ["type": "queue_status", "queue_status_event": ["status": "admitted"]]
        }
    }

    /// An agent that answers each message after 20 ms and, given `noise`, sends that one kind of
    /// event every 100 ms — well inside the 150 ms settle — for as long as the socket is open.
    static func agent(noise: String?) -> FakeElevenLabsSocketConnector.Server {
        { socket in
            guard await socket.nextSent() != nil else { return }
            socket.push(ConverseRig.metadata)
            if let noise {
                Task {
                    var id = 100
                    while socket.endedWith == nil {
                        socket.push(noiseFrame(noise, id))
                        id += 1
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            var answer = 1
            while await socket.nextSent(ofType: "user_message", timeout: .seconds(30)) != nil {
                try? await Task.sleep(for: .milliseconds(20))
                socket.push(ConverseRig.response("Answer \(answer).", answer))
                answer += 1
            }
        }
    }

    func run(_ server: @escaping FakeElevenLabsSocketConnector.Server, timing: ElevenLabsConverseHandler.Timing,
             messages: [String] = ["One", "Two"]) async -> (seconds: Duration, status: Int, answer: JSONValue, socket: FakeElevenLabsSocket?) {
        var rig = ConverseRig(allowRisky: true, server: server)
        rig.timing = timing
        defer { rig.clean() }
        let started = ContinuousClock.now
        let (status, answer) = await rig.converse(["agent_id": "agent_1", "messages": .array(messages.map { .string($0) }), "confirm": true])
        return (ContinuousClock.now - started, status, answer, rig.connector.sockets.first)
    }

    /// The critic's probe, one kind at a time (round 2: rotating three kinds every 100 ms let a
    /// regression in two of them pass, their gaps being longer than the settle): pings every
    /// 100 ms stretched each turn's wait for quiet to the turn's cap, so the same two answers ran
    /// (and billed) a full turn each instead of a fraction of a second.
    @Test(arguments: noise)
    func eventsThatAreNotActivityDoNotHoldATurnOpen(kind: String) async throws {
        // Each turn's cap is a minute: an event kind that held turns open would take two. Done in
        // well under half a minute even in a busy run; nothing here leans on a tighter clock.
        let timing = ElevenLabsConverseHandler.Timing(greeting: .milliseconds(300), settle: .milliseconds(150), turn: .seconds(60))
        let noisy = await run(Self.agent(noise: kind), timing: timing)
        #expect(noisy.status == 200)
        #expect(noisy.answer["messages_sent"] == 2)
        #expect(noisy.seconds < .seconds(30), "\(kind) every 100 ms held the turns open: \(noisy.seconds)")
        #expect(noisy.answer["ended"] == "by this app, after the last message")
    }

    /// An agent that keeps talking never goes quiet: the conversation still ends at the total cap,
    /// says so, and sends nothing more.
    ///
    /// Held by construction, not by the clock: the settle (a minute) is longer than the whole
    /// conversation may run (three seconds), so the wait for quiet after the first answer can only
    /// end at the time limit — however the agent's stream is paced, however loaded the machine.
    /// (A gate run at load 44 failed the earlier version: the stream, starved, paused longer than
    /// its 150 ms settle, the turn was rightly taken as over, and a second message went out —
    /// before the deadline, as the product allows.) With no greeting to wait for, the first
    /// message goes out straight after the deadline is set.
    @Test func aConversationThatNeverGoesQuietEndsAtTheTimeLimit() async throws {
        let chatter: FakeElevenLabsSocketConnector.Server = { socket in
            guard await socket.nextSent() != nil else { return }
            socket.push(ConverseRig.metadata)
            guard await socket.nextSent(ofType: "user_message") != nil else { return }
            socket.push(ConverseRig.response("Let me tell you everything.", 1))
            var id = 2
            while socket.endedWith == nil {
                socket.push(["type": "agent_chat_response_part", "text_response_part": [
                    "text": "and more ", "type": "delta", "event_id": .number(Double(id)),
                ]])
                id += 1
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        let timing = ElevenLabsConverseHandler.Timing(
            greeting: .zero, settle: .seconds(60), turn: .seconds(60), total: .seconds(3)
        )
        let result = await run(chatter, timing: timing, messages: ["One", "Two", "Three"])
        #expect(result.status == 200)
        // Three one-minute turns without the cap; half a minute is room for a busy run.
        #expect(result.seconds < .seconds(30), "ran \(result.seconds) against a 3 s cap")
        #expect(result.answer["ended"] == "time limit")
        #expect((result.answer["note"].stringValue ?? "").contains("Ended: time limit"))
        #expect((result.answer["note"].stringValue ?? "").contains("3 seconds"))
        #expect(result.answer["messages_sent"] == 1)
        let socket = try #require(result.socket)
        #expect(socket.closedByClient?.code == 1000)
        #expect(socket.sentJSON.filter { $0["type"] == "user_message" }.count == 1)
    }

    /// An agent that never answers is bounded by the total cap too, when that is the shorter.
    @Test func theTimeLimitBoundsAWaitForAnAnswer() async throws {
        let silent: FakeElevenLabsSocketConnector.Server = { socket in
            _ = await socket.nextSent()
            socket.push(ConverseRig.metadata)
        }
        let timing = ElevenLabsConverseHandler.Timing(
            greeting: .milliseconds(200), settle: .milliseconds(150), turn: .seconds(60), total: .milliseconds(800)
        )
        let result = await run(silent, timing: timing)
        // A one-minute turn without the cap; half a minute is room for a busy run.
        #expect(result.seconds < .seconds(30), "a one-minute turn ran \(result.seconds) against a 0.8 s cap")
        #expect(result.answer["ended"] == "time limit")
        #expect(!(result.answer["note"].stringValue ?? "").contains("did not answer"))
    }

    /// Opens when the test says so; a server script waits on it.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        func open() { lock.withLock { isOpen = true } }
        func wait() async {
            let deadline = ContinuousClock.now + .seconds(60)
            while !lock.withLock({ isOpen }), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    /// One conversation at a time: a second call while one runs is refused before anything is
    /// read or opened, and the lane is free again once the first is done. The first one's agent
    /// answers only once the test has made the second call, so the first is still running then
    /// however slow the machine.
    @Test func aSecondConversationWhileOneRunsIsRefused() async throws {
        let answerGate = Gate()
        let slow: FakeElevenLabsSocketConnector.Server = { socket in
            guard await socket.nextSent() != nil else { return }
            socket.push(ConverseRig.metadata)
            while await socket.nextSent(ofType: "user_message", timeout: .seconds(60)) != nil {
                await answerGate.wait()
                socket.push(ConverseRig.response("Done.", 1))
            }
        }
        let rig = ConverseRig(allowRisky: true, server: slow)
        defer { rig.clean() }
        let body: JSONValue = ["agent_id": "agent_1", "messages": ["Hi"], "confirm": true]
        let first = Task { await rig.converse(body) }
        let deadline = ContinuousClock.now + .seconds(15)
        while rig.connector.sockets.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(rig.connector.sockets.count == 1)
        let reads = rig.transport.requests.count

        let (status, answer) = await rig.converse(body)
        #expect(status == 409)
        #expect((answer["error"].stringValue ?? "").contains("one runs at a time"))
        #expect(rig.connector.requests.count == 1, "a second socket was opened")
        #expect(rig.transport.requests.count == reads, "the second call read the agent")

        answerGate.open()
        let (firstStatus, _) = await first.value
        #expect(firstStatus == 200)
        let (again, _) = await rig.converse(body)
        #expect(again == 200, "the lane was not let go")
    }

    /// A refusal after the lane was taken (an unknown agent) lets it go.
    @Test func aRefusedConversationLetsTheLaneGo() async throws {
        let lane = ConverseLane()
        #expect(lane.enter())
        #expect(!lane.enter())
        lane.leave()
        #expect(lane.enter())
        lane.leave()

        let rig = ConverseRig(allowRisky: true, replies: { _ in .jsonText(#"{"detail":"no such agent"}"#, status: 404) })
        defer { rig.clean() }
        let (status, _) = await rig.converse(["agent_id": "agent_1", "messages": ["Hi"], "confirm": true])
        #expect(status == 404)
        #expect(rig.lane.enter(), "the refused conversation kept the lane")
    }
}

/// A caller that hangs up on `POST /elevenlabs/agents/converse` ends the conversation: the
/// control server cancels the handler, as it does for `/video/generate`.
@Suite("ElevenLabs realtime over control: a caller that hangs up")
struct RealtimeConverseHangUpTests {

    /// The path as the router reads it: a trailing slash is the same route, and is cancelled too.
    @MainActor
    @Test(arguments: [ElevenLabsControl.agentConversePath, ElevenLabsControl.agentConversePath + "/"])
    func hangingUpCancelsTheConversationRoute(path: String) async throws {
        let host = BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false)
        let id = ObjectIdentifier(host)
        await ConverseHangUpProbe.shared.clear(id)
        try await withServer(host: host) { (fixture: AgentFixture) async throws in
            let call = Task {
                try await fixture.local.call(
                    "POST", path, token: fixture.local.token, body: #"{"fixtureHold":true}"#
                )
            }
            let deadline = ContinuousClock.now + .seconds(15)
            while await ConverseHangUpProbe.shared.count(id).held == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(await ConverseHangUpProbe.shared.count(id).held == 1)
            call.cancel()
            let cancelDeadline = ContinuousClock.now + .seconds(15)
            while await ConverseHangUpProbe.shared.count(id).cancelled == 0, ContinuousClock.now < cancelDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await ConverseHangUpProbe.shared.count(id).cancelled == 1, "\(path): the conversation kept running after its caller hung up")
            _ = try? await call.value
        }
    }
}

extension RealtimeConverseHangUpTests {
    @Test func theConversationPathIsReadAsTheRouterReadsIt() {
        for path in ["/elevenlabs/agents/converse", "/elevenlabs/agents/converse/", "//elevenlabs/agents//converse"] {
            #expect(ElevenLabsControl.isAgentConversePath(path), "\(path)")
        }
        for path in ["/elevenlabs/agents/converse/x", "/elevenlabs/agents", "/video/generate", "/elevenlabs/call"] {
            #expect(!ElevenLabsControl.isAgentConversePath(path), "\(path)")
        }
    }
}

/// What the test host's held conversation saw, by host.
actor ConverseHangUpProbe {
    static let shared = ConverseHangUpProbe()
    private var counts: [ObjectIdentifier: (held: Int, cancelled: Int)] = [:]

    func held(_ id: ObjectIdentifier) { counts[id, default: (0, 0)].held += 1 }
    func cancelled(_ id: ObjectIdentifier) { counts[id, default: (0, 0)].cancelled += 1 }
    func count(_ id: ObjectIdentifier) -> (held: Int, cancelled: Int) { counts[id] ?? (0, 0) }
    func clear(_ id: ObjectIdentifier) { counts[id] = nil }
}
