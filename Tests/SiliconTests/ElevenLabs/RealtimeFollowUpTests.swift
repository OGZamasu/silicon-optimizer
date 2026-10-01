import Foundation
import Testing
@testable import SiliconElevenLabs

/// Review follow-ups on the protocol layer, each pinned by the test that failed without it.
@Suite("ElevenLabs realtime: review follow-ups")
struct RealtimeFollowUpTests {

    /// A closed socket reads as one sentence, never "The connection the connection dropped."
    @Test(arguments: [
        (0, "", "The connection dropped."),
        (1000, "", "The connection closed normally (1000)."),
        (1005, "", "The connection closed normally (1005)."),
        (1011, "boom", "The connection closed with code 1011: boom."),
        (4300, "", "The call queue timed out (4300)."),
    ])
    func aClosedSocketReadsAsOneSentence(code: Int, reason: String, expected: String) {
        let close = ElevenLabsSocketClose(code: code, reason: reason)
        #expect(ElevenLabsRealtimeError.closed(close).description == expected)
        #expect(!ElevenLabsRealtimeError.closed(close).description.lowercased().contains("connection the connection"))
        // As a clause after "ended early: ", it carries its own subject.
        #expect(close.description.hasPrefix("the "))
    }

    /// A close waits for the frame the writer is sending, not only for the queue: on a slow
    /// connection the declines queued just before the close were handed to the writer, the
    /// queue looked empty, and the close went first — the second decline never left.
    @Test func endingOnASlowConnectionStillSendsEveryDecline() async throws {
        let rig = RealtimeRig(server: RealtimeRig.agentServer { socket in
            socket.push(RealtimeSessionTests.mcpCall("call_a", state: "awaiting_approval"))
            socket.push(RealtimeSessionTests.mcpCall("call_b", state: "awaiting_approval"))
        })
        defer { rig.clean() }
        let conversation = try await rig.realtime.agentConversation(.init(agentID: "agent_1", auth: .publicAgent))
        var seen = 0
        for await event in conversation.events {
            if case .mcpToolCall = event { seen += 1 }
            if seen == 2 { break }
        }
        let socket = try #require(rig.connector.sockets.first)
        socket.delaySends(by: .milliseconds(150))
        await conversation.end()
        #expect(socket.sentJSON.suffix(2) == [
            ["type": "mcp_tool_approval_result", "tool_call_id": "call_a", "is_approved": false],
            ["type": "mcp_tool_approval_result", "tool_call_id": "call_b", "is_approved": false],
        ])
        #expect(socket.closedByClient == .init(code: 1000, reason: "User ended conversation"))
    }

    /// The same for a typed message sent just before End: it reaches the socket before the close.
    @Test func aMessageSentJustBeforeEndArrivesBeforeTheClose() async throws {
        let rig = RealtimeRig(server: RealtimeRig.agentServer())
        defer { rig.clean() }
        let conversation = try await rig.realtime.agentConversation(.init(agentID: "agent_1", auth: .publicAgent, textOnly: true))
        let socket = try #require(rig.connector.sockets.first)
        socket.delaySends(by: .milliseconds(150))
        async let sending: Void = conversation.sendUserMessage("last words")
        try await Task.sleep(for: .milliseconds(20))
        await conversation.end()
        try? await sending
        #expect(socket.sentJSON.last == ["type": "user_message", "text": "last words"])
        #expect(socket.closedByClient?.code == 1000)
    }

    /// A start that is cancelled while the agent has not answered yet ends at once — cancelled,
    /// the socket closed — instead of waiting out the start timeout.
    @Test func aCancelledStartDoesNotWaitForTheAgent() async throws {
        var rig = RealtimeRig(server: { socket in _ = await socket.nextSent() })
        rig.realtime.limits.agentStartTimeout = 10
        defer { rig.clean() }
        let realtime = rig.realtime
        let start = Task { try await realtime.agentConversation(.init(agentID: "agent_1", auth: .publicAgent)) }
        let deadline = ContinuousClock.now + .seconds(10)
        while rig.connector.sockets.first?.sentJSON.isEmpty != false, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let socket = try #require(rig.connector.sockets.first)
        let cancelled = ContinuousClock.now
        start.cancel()
        let result = await start.result
        #expect(ContinuousClock.now - cancelled < .seconds(2))
        guard case .failure(let error) = result else {
            Issue.record("a cancelled start came back with a conversation")
            return
        }
        #expect(error as? ElevenLabsRealtimeError == .cancelled)
        #expect(socket.closedByClient != nil)
    }

    /// A reader that stops reading (or a server that floods) cannot grow memory without limit:
    /// past the cap the session ends itself — 1011, "fell behind" — and `.ended` still arrives.
    @Test func aTranscriptionWhoseReaderFallsBehindEndsItself() async throws {
        var rig = RealtimeRig(server: { socket in
            for index in 0..<50 { socket.push(["message_type": "partial_transcript", "text": .string("part \(index)")]) }
        })
        rig.realtime.limits.maximumWaitingEvents = 8
        defer { rig.clean() }
        let stream = try await rig.realtime.transcriptionStream(.init())
        let socket = try #require(rig.connector.sockets.first)
        try #require(await socket.waitUntilEnded(), "the session kept growing a queue nobody read")
        var events: [ElevenLabsTranscriptionStreamEvent] = []
        for await event in stream.events { events.append(event) }
        #expect(events.count <= 9)
        guard case .ended(let close) = events.last else {
            Issue.record("the last event was \(String(describing: events.last))")
            return
        }
        #expect(close.code == 1011)
        #expect(close.reason == "This app fell behind reading the session")
        #expect(socket.closedByClient?.code == 1011)
    }

    @Test func aConversationWhoseReaderFallsBehindEndsItself() async throws {
        var rig = RealtimeRig(server: RealtimeRig.agentServer { socket in
            for _ in 0..<50 { socket.push(["type": "vad_score", "vad_score_event": ["vad_score": 0.5]]) }
        })
        rig.realtime.limits.maximumWaitingEvents = 8
        defer { rig.clean() }
        let conversation = try await rig.realtime.agentConversation(.init(agentID: "agent_1", auth: .publicAgent))
        let socket = try #require(rig.connector.sockets.first)
        try #require(await socket.waitUntilEnded(), "the conversation kept growing a queue nobody read")
        var last: ElevenLabsAgentEvent?
        for await event in conversation.events { last = event }
        #expect(last == .ended(ElevenLabsSocketClose(code: 1011, reason: "This app fell behind reading the session")))
        #expect(socket.closedByClient?.code == 1011)
    }
}
