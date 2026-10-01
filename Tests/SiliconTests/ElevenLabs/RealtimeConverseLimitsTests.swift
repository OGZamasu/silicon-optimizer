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

    /// An agent that answers each message after 20 ms and, when `noisy`, sends a ping, a VAD
    /// score or a context-usage event every 100 ms for as long as the socket is open.
    static func agent(noisy: Bool) -> FakeElevenLabsSocketConnector.Server {
        { socket in
            guard await socket.nextSent() != nil else { return }
            socket.push(ConverseRig.metadata)
            if noisy {
                Task {
                    var id = 100
                    while socket.endedWith == nil {
                        switch id % 3 {
                        case 0: socket.push(["type": "ping", "ping_event": ["event_id": .number(Double(id)), "ping_ms": 20]])
                        case 1: socket.push(["type": "vad_score", "vad_score_event": ["vad_score": 0.4]])
                        default: socket.push(["type": "context_usage", "context_usage_event": ["context_tokens": .number(Double(id))]])
                        }
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

    /// The critic's probe: pings every 100 ms stretched each turn's wait for quiet to the turn's
    /// cap, so the same two answers ran (and billed) 3 s a turn instead of a fraction of one.
    @Test func pingsAndScoresDoNotHoldATurnOpen() async throws {
        let timing = ElevenLabsConverseHandler.Timing(greeting: .milliseconds(300), settle: .milliseconds(150), turn: .seconds(3))
        let quiet = await run(Self.agent(noisy: false), timing: timing)
        let noisy = await run(Self.agent(noisy: true), timing: timing)
        #expect(quiet.status == 200 && noisy.status == 200)
        #expect(noisy.answer["messages_sent"] == 2)
        #expect(noisy.seconds < quiet.seconds + .seconds(1), "pings turned \(quiet.seconds) into \(noisy.seconds)")
        #expect(noisy.answer["ended"] == "by this app, after the last message")
    }

    /// An agent that keeps talking never goes quiet: the conversation still ends at the total cap,
    /// says so, and sends nothing more.
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
            greeting: .milliseconds(200), settle: .milliseconds(150), turn: .seconds(10), total: .milliseconds(1_500)
        )
        let result = await run(chatter, timing: timing, messages: ["One", "Two", "Three"])
        #expect(result.status == 200)
        #expect(result.seconds < .seconds(4), "ran \(result.seconds) against a 1.5 s cap")
        #expect(result.answer["ended"] == "time limit")
        #expect((result.answer["note"].stringValue ?? "").contains("Ended: time limit"))
        #expect((result.answer["note"].stringValue ?? "").contains("1.5 seconds"))
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
            greeting: .milliseconds(200), settle: .milliseconds(150), turn: .seconds(10), total: .milliseconds(800)
        )
        let result = await run(silent, timing: timing)
        #expect(result.seconds < .seconds(3))
        #expect(result.answer["ended"] == "time limit")
        #expect(!(result.answer["note"].stringValue ?? "").contains("did not answer"))
    }

    /// One conversation at a time: a second call while one runs is refused before anything is
    /// read or opened, and the lane is free again once the first is done.
    @Test func aSecondConversationWhileOneRunsIsRefused() async throws {
        let slow: FakeElevenLabsSocketConnector.Server = { socket in
            guard await socket.nextSent() != nil else { return }
            socket.push(ConverseRig.metadata)
            while await socket.nextSent(ofType: "user_message", timeout: .seconds(30)) != nil {
                try? await Task.sleep(for: .milliseconds(800))
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

    @MainActor
    @Test func hangingUpCancelsTheConversationRoute() async throws {
        let host = BuddyTestHost(tokens: ["ok"], pace: .milliseconds(1), failing: false)
        let id = ObjectIdentifier(host)
        await ConverseHangUpProbe.shared.clear(id)
        try await withServer(host: host) { (fixture: AgentFixture) async throws in
            let call = Task {
                try await fixture.local.call(
                    "POST", ElevenLabsControl.agentConversePath, token: fixture.local.token, body: #"{"fixtureHold":true}"#
                )
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while await ConverseHangUpProbe.shared.count(id).held == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            try #require(await ConverseHangUpProbe.shared.count(id).held == 1)
            call.cancel()
            let cancelDeadline = ContinuousClock.now + .seconds(8)
            while await ConverseHangUpProbe.shared.count(id).cancelled == 0, ContinuousClock.now < cancelDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await ConverseHangUpProbe.shared.count(id).cancelled == 1, "the conversation kept running after its caller hung up")
            _ = try? await call.value
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
