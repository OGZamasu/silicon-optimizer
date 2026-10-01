import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// The agents critic's last nits, taken after the merge.
extension AgentsSectionsTests {

    /// A real-world send ElevenLabs refused with a 4xx (a 422 for a bad recipient list) placed
    /// nothing: the screen is ready again at once. A 408, a 429 or a 5xx does not say whether
    /// the calls went out, so the owner checks first, as after a lost answer.
    @Test func aRefusedBatchIsAKnownOutcomeAndATimeoutOrServerErrorIsNot() async throws {
        let cases: [(reply: FakeElevenLabsTransport.Reply, known: Bool)] = [
            (.jsonText(#"{"detail":{"status":"invalid_recipients","message":"Bad number"}}"#, status: 422), true),
            (.jsonText(#"{"detail":"Not found"}"#, status: 404), true),
            (.jsonText(#"{"detail":"Request timeout"}"#, status: 408), false),
            (.jsonText(#"{"detail":"busy"}"#, status: 429), false),
            (.jsonText(#"{"detail":"Internal error"}"#, status: 500), false),
        ]
        for (reply, known) in cases {
            let rig = AgentsFixtures.Rig(overriding: [AgentsOp.submitBatch: reply])
            defer { rig.clean() }
            await rig.store.directory.agents.refresh()
            await rig.store.directory.phoneNumbers.refresh()
            let model = rig.store.batchCalls
            fillBatch(model)
            let runner = rig.store.calls.runner(AgentsOp.submitBatch)
            let submitting = Task { await model.submit() }
            try await waitUntil { runner.isAwaitingConfirmation }
            runner.confirm()
            await submitting.value
            #expect(rig.requests(AgentsOp.submitBatch).count == 1)
            if known {
                #expect(model.submitGuard.canSend, "\(reply.status): a refusal placed nothing")
                #expect(model.submitGuard.warning == nil, "\(reply.status): \(model.submitGuard.warning ?? "")")
            } else {
                #expect(!model.submitGuard.canSend, "\(reply.status) does not say whether calls were placed")
                #expect(model.submitGuard.warning?.contains("may already have been placed") == true)
                #expect(model.submitGuard.warning?.contains("does not say whether it went out") == true)
            }
        }
    }
}
