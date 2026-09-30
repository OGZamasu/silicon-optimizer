import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// A secret shown once is forgotten when the owner leaves it (shell critic S4, probe P4), and
/// a Keychain removal that fails after Remove said it was done is shown, not kept silent (S5).
@Suite("ElevenLabs forgetting and failures that must show")
@MainActor
struct ShellForgettingTests {

    @Test func aSecretShownOnceIsForgottenWhenTheOwnerLeaves() async throws {
        for leave in ["another section", "recent results"] {
            let fixture = ShellExplorerTests.Fixture(replies: [.json(["signed_url": "wss://api.elevenlabs.io/x?conversation_signature=sig999"])])
            defer { fixture.clean() }
            fixture.pane.open(.explorer)
            let explorer = ElevenLabsExplorerModel(context: fixture.context)
            let session = try #require(explorer.session(for: "get_conversation_signed_link"))
            await session.runner.perform(arguments: ["agent_id": "a1"])
            #expect(session.runner.credential != nil)
            if leave == "another section" { fixture.pane.open(.speech) } else { fixture.pane.showRecents() }
            fixture.pane.open(.explorer)
            #expect(try #require(explorer.session(for: "get_conversation_signed_link")).runner.credential == nil, "\(leave)")
        }
    }

    @Test func staysWhileTheOwnerStaysAndGoesWithTheAccount() async throws {
        let fixture = ShellExplorerTests.Fixture(replies: [.json(["signed_url": "wss://api.elevenlabs.io/x?conversation_signature=sig999"])])
        defer { fixture.clean() }
        fixture.pane.open(.explorer)
        let runner = try #require(ElevenLabsRunner(operationID: "get_conversation_signed_link", context: fixture.context))
        await runner.perform(arguments: ["agent_id": "a1"])
        fixture.pane.open(.explorer)
        #expect(runner.credential != nil)
        fixture.pane.reset()
        #expect(runner.credential == nil)
    }

    @Test func aKeychainRemovalThatFailsIsShown() async throws {
        let (model, transport, store) = ShellSettingsTests.model(linkedKey: ShellSettingsTests.key) { request in
            ShellSettingsTests.accountAnswer(request)
        }
        defer { ShellSettingsTests.clean(model, transport) }
        store.setFailure(.credentialUnavailable("the Keychain is locked"))
        let connection = ElevenLabsConnectionModel()
        connection.remove(model: model)
        await model.elevenLabsLink.pendingRemoval?.value
        let shown = try #require(ElevenLabsSettingsSection.errorToShow(
            connectionFailure: connection.failure, lastError: model.elevenLabsLastError
        ))
        #expect(shown.contains("could not be removed from the Keychain"))
        // A Connect's own failure comes first.
        #expect(ElevenLabsSettingsSection.errorToShow(connectionFailure: "refused", lastError: "old") == "refused")
    }
}
