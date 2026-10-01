@preconcurrency import AVFoundation
import Foundation
import SiliconElevenLabs
import Testing
@testable import SiliconUI

/// Review follow-ups on the live screens, each pinned by the test that failed without it.
/// In-memory transport, fake socket and fake devices only.
@Suite("ElevenLabs live screens: review follow-ups", .serialized)
@MainActor
struct LiveFollowUpTests {

    /// A text-only Start on an agent that refuses text-only, cancelled while the agent is read,
    /// then a voice Start: the first read's late refusal must not end the second Start.
    @Test func aCancelledStartsLateRefusalLeavesTheNextStartAlone() async throws {
        let base = LiveScreenTests.agentReplies(textOnlyAllowed: false)
        let rig = LiveRig(replies: { request in
            if request.operationID == "get_agent_route" { try? await Task.sleep(for: .milliseconds(400)) }
            return try await base(request)
        }, server: LiveScreenTests.agent())
        defer { rig.clean() }
        let screen = LiveAgentModel(context: rig.context)
        await screen.loadAgents()
        screen.textOnly = true
        let first = Task { await screen.requestStart() }
        await rig.until { screen.phase == .preparing }
        screen.cancelStart()
        screen.textOnly = false
        try await Task.sleep(for: .milliseconds(100))
        let second = Task { await screen.requestStart() }
        await first.value
        await second.value
        await rig.until { screen.phase == .live || screen.phase == .ended }
        #expect(screen.phase == .live, "the voice Start was dropped: \(screen.outcome?.message ?? "no outcome")")
        #expect(rig.connector.requests.count == 1)
        await screen.end()
    }
}
