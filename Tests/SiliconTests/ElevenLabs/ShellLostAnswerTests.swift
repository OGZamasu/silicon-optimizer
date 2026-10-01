import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// The Explorer, after a run whose answer was lost though it may have been carried out: an
/// operation that mints a secret or acts in the real world is held until the owner has
/// checked, for the account it was run for. Hermetic: every answer comes from a fake.
@Suite("ElevenLabs Explorer — runs whose answer was lost", .timeLimit(.minutes(3)))
@MainActor
struct ShellLostAnswerTests {
    /// Counts what was carried out; the first answer is lost (a 500), or refused (a 422).
    final class Minted: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        let firstReply: FakeElevenLabsTransport.Reply
        init(first: FakeElevenLabsTransport.Reply) { firstReply = first }
        func answer() -> FakeElevenLabsTransport.Reply {
            lock.withLock {
                count += 1
                return count == 1 ? firstReply : .json(["token": "sutkn_fixture_not_real"])
            }
        }
    }

    func runConfirming(_ explorer: ElevenLabsExplorerModel, _ session: ElevenLabsExplorerModel.Session) async throws {
        @MainActor final class Done { var value = false }
        let done = Done()
        let task = Task { await explorer.runNow(session); done.value = true }
        try await ShellExplorerTests.waitUntil {
            if session.runner.isAwaitingConfirmation { session.runner.confirm() }
            return done.value
        }
        await task.value
    }

    func tokenSession(_ explorer: ElevenLabsExplorerModel) throws -> ElevenLabsExplorerModel.Session {
        let session = try #require(explorer.session(for: "get_single_use_token"))
        let type = try #require(session.form.nodes.first { $0.field.name == "token_type" })
        type.choice = 0
        type.text = "realtime_scribe"
        #expect(session.form.arguments().problems.isEmpty, "\(session.form.arguments().problems)")
        return session
    }

    /// A single-use token minted, its answer lost: the token was made and never shown. Run is
    /// held with the words for a secret that cannot be shown again; a second run sends nothing
    /// until the owner says they have checked. (Before: it showed only "answered 500", and the
    /// next run minted another.)
    @Test func aRunThatMintsASecretIsHeldAfterItsAnswerWasLost() async throws {
        let minted = Minted(first: .jsonText(#"{"detail":"Internal error"}"#, status: 500))
        let fixture = ShellExplorerTests.Fixture(handler: { request in
            request.operationID == "get_single_use_token" ? minted.answer() : .jsonText(#"{"detail":"not scripted"}"#, status: 418)
        })
        defer { fixture.clean() }
        let explorer = ElevenLabsExplorerModel(context: fixture.context)
        let session = try tokenSession(explorer)
        #expect(ElevenLabsExplorerModel.holdsAfterUnknown(session.operation))
        try await runConfirming(explorer, session)
        #expect(minted.count == 1)
        #expect(explorer.hold(for: "get_single_use_token")?.contains("its secret cannot be shown again") == true,
                "\(explorer.hold(for: "get_single_use_token") ?? "not held")")
        try await runConfirming(explorer, session)
        #expect(minted.count == 1, "a second secret was minted after the first one's answer was lost")
        explorer.acknowledgeHold("get_single_use_token")
        try await runConfirming(explorer, session)
        #expect(minted.count == 2)
        #expect(explorer.hold(for: "get_single_use_token") == nil)
    }

    /// A refusal minted nothing: nothing is held.
    @Test func aRefusedRunIsNotHeld() async throws {
        let minted = Minted(first: .jsonText(#"{"detail":{"status":"invalid","message":"Not allowed"}}"#, status: 422))
        let fixture = ShellExplorerTests.Fixture(handler: { request in
            request.operationID == "get_single_use_token" ? minted.answer() : .jsonText(#"{"detail":"not scripted"}"#, status: 418)
        })
        defer { fixture.clean() }
        let explorer = ElevenLabsExplorerModel(context: fixture.context)
        let session = try tokenSession(explorer)
        try await runConfirming(explorer, session)
        #expect(explorer.hold(for: "get_single_use_token") == nil)
        try await runConfirming(explorer, session)
        #expect(minted.count == 2)
    }

    /// The hold is the account's: once the pane moves to another account (a new session epoch),
    /// it no longer holds — that account has no such run.
    @Test func aHoldIsTheAccountsItWasRunFor() async throws {
        let minted = Minted(first: .jsonText(#"{"detail":"Internal error"}"#, status: 500))
        let fixture = ShellExplorerTests.Fixture(handler: { request in
            request.operationID == "get_single_use_token" ? minted.answer() : .jsonText(#"{"detail":"not scripted"}"#, status: 418)
        })
        defer { fixture.clean() }
        let explorer = ElevenLabsExplorerModel(context: fixture.context)
        let session = try tokenSession(explorer)
        try await runConfirming(explorer, session)
        #expect(explorer.hold(for: "get_single_use_token") != nil)
        fixture.pane.reset()
        #expect(explorer.hold(for: "get_single_use_token") == nil, "another account's run is held")
    }

    /// Reads that answer with a credential — an existing token, a short-lived signed link — are
    /// not held: running them again mints nothing lasting.
    @Test func readsThatAnswerWithACredentialAreNotHeld() throws {
        for id in ["get_agent_route", "get_conversation_signed_link", "get_livekit_token"] {
            let operation = try #require(ElevenLabsCatalog.operation(id))
            #expect(operation.returnsCredential)
            #expect(!ElevenLabsExplorerModel.holdsAfterUnknown(operation), "\(id)")
        }
        for id in ["create_service_account_api_key", "create_workspace_webhook_route", "get_single_use_token", "invite_user"] {
            let operation = try #require(ElevenLabsCatalog.operation(id))
            #expect(ElevenLabsExplorerModel.holdsAfterUnknown(operation), "\(id)")
        }
    }
}
