import Foundation
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// Return never starts something billable, "Uses credits" is said once, and a section can
/// word a question fully — title, button, one more warning line (voices/studio V1/V3, agents
/// A1/A2, creative C4).
@Suite("ElevenLabs Run button and questions")
@MainActor
struct ShellRunButtonAndQuestionTests {

    @Test func returnPressesRunOnlyWhenAskedAndOnlyForARead() throws {
        let context = ElevenLabsRunner.Context(client: { nil })
        let read = try #require(ElevenLabsRunner(operationID: "get_models", context: context))
        let generate = try #require(ElevenLabsRunner(operationID: "text_to_speech_full", context: context))
        let delete = try #require(ElevenLabsRunner(operationID: "delete_voice", context: context))
        #expect(!ElevenLabsRunButton(runner: read) {}.usesReturnKey)
        #expect(ElevenLabsRunButton(runner: read, respondsToReturn: true) {}.usesReturnKey)
        #expect(!ElevenLabsRunButton(runner: generate, respondsToReturn: true) {}.usesReturnKey)
        #expect(!ElevenLabsRunButton(runner: delete, respondsToReturn: true) {}.usesReturnKey)
    }

    @Test func usesCreditsIsSaidOnce() throws {
        let context = ElevenLabsRunner.Context(client: { nil })
        let generate = try #require(ElevenLabsRunner(operationID: "text_to_speech_full", context: context))
        let enabled = ElevenLabsRunButton(runner: generate) {}
        #expect(!enabled.showsRiskBadge)
        #expect(ElevenLabsCostNote.text(for: generate.operation) != nil)
        #expect(ElevenLabsRunButton(runner: generate, disabled: true, disabledReason: "Type something") {}.showsRiskBadge)
        let delete = try #require(ElevenLabsRunner(operationID: "delete_voice", context: context))
        #expect(ElevenLabsRunButton(runner: delete) {}.showsRiskBadge)
        let read = try #require(ElevenLabsRunner(operationID: "get_models", context: context))
        #expect(!ElevenLabsRunButton(runner: read) {}.showsRiskBadge)
    }

    @Test func aSectionWordsItsOwnQuestion() async throws {
        let fixture = ShellExplorerTests.Fixture(replies: [.json(["status": "ok"])])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "cancel_batch_call", context: fixture.context))
        let running = Task {
            await runner.perform(
                arguments: ["batch_id": "b1"], title: "Stop the batch “Monday”?", confirmLabel: "Stop calls",
                warning: "Calls already ringing are not taken back."
            )
        }
        try await ShellExplorerTests.waitUntil { runner.phase == .awaitingConfirmation || runner.phase == .failed }
        let question = try #require(runner.confirmation, "\(runner.problems)")
        #expect(question.title == "Stop the batch “Monday”?")
        #expect(question.confirmLabel == "Stop calls")
        #expect(question.warning == "Calls already ringing are not taken back.")
        runner.decline()
        _ = await running.value

        let plain = ElevenLabsConfirmationRequest.make(for: runner.operation)
        #expect(plain.warning == nil)
        #expect(plain.confirmLabel == "Run")
    }

    @Test func acronymsAndNamesKeepTheirCase() {
        #expect(ElevenLabsConfirmationRequest.sentenceCase("Create Mcp Server") == "Create MCP server")
        #expect(ElevenLabsConfirmationRequest.sentenceCase("Get Whatsapp Account") == "Get WhatsApp account")
        #expect(ElevenLabsConfirmationRequest.sentenceCase("Export Batch Call Csv") == "Export batch call CSV")
        #expect(ElevenLabsConfirmationRequest.sentenceCase("Handle Sip Trunk Outbound Call") == "Handle SIP trunk outbound call")
        #expect(ElevenLabsConfirmationRequest.sentenceCase("Get Signed Url") == "Get signed URL")
        #expect(ElevenLabsConfirmationRequest.sentenceCase("Update Api Key") == "Update API key")
    }
}
