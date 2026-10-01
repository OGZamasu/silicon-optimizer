import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Creates whose answer was lost though they may have been carried out (a 500 after the work):
/// a credential, a signing secret, an invitation, a sign-in connection. The list is read again,
/// the draft stays, and that create — only that one — is held until the owner says they have
/// checked; a refusal holds nothing. Hermetic: every answer comes from a fake.
@Suite("ElevenLabs voices & studio — creates whose answer was lost", .timeLimit(.minutes(3)))
@MainActor
struct VoicesStudioLostAnswerTests {
    @MainActor final class Done { var value = false }

    /// Runs `action`, answering yes (or `yes`) to any question it puts up.
    func answering(_ actions: VoicesStudioActions, yes: Bool = true, _ action: @escaping @MainActor () async -> Void) async throws {
        let done = Done()
        let task = Task { await action(); done.value = true }
        try await voicesStudioWait {
            if actions.presentedQuestion != nil { actions.answer(yes) }
            return done.value
        }
        await task.value
    }

    nonisolated static let lost = FakeElevenLabsTransport.Reply.jsonText(#"{"detail":"Internal error"}"#, status: 500)
    nonisolated static let refused = FakeElevenLabsTransport.Reply.jsonText(
        #"{"detail":{"status":"invalid","message":"Not allowed"}}"#, status: 422
    )

    /// Counts what a fake carried out, and loses the answers it is told to.
    final class Made: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        private var losing: [String: Int] = [:]
        private var refusing: Set<String> = []
        func lose(_ operationID: String, _ count: Int = 1) { lock.withLock { losing[operationID, default: 0] += count } }
        func refuse(_ operationID: String) { lock.withLock { _ = refusing.insert(operationID) } }
        /// Carries the call out (unless it is refused) and says how to answer.
        func answer(_ operationID: String, _ ok: FakeElevenLabsTransport.Reply) -> FakeElevenLabsTransport.Reply {
            lock.withLock {
                if refusing.remove(operationID) != nil { return VoicesStudioLostAnswerTests.refused }
                counts[operationID, default: 0] += 1
                guard losing[operationID, default: 0] > 0 else { return ok }
                losing[operationID, default: 0] -= 1
                return VoicesStudioLostAnswerTests.lost
            }
        }
        func count(_ operationID: String) -> Int { lock.withLock { counts[operationID, default: 0] } }
    }

    // MARK: - Service-account keys and accounts

    func keysFixture(_ made: Made) -> VoicesStudioFixture {
        let keys: JSONValue = ["api-keys": [VoicesStudioLateAnswerTests.key("k1", of: "sa-a")]]
        let accounts: JSONValue = ["service-accounts": [VoicesStudioLateAnswerTests.account("sa-a", key: "k1")]]
        return VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "create_service_account_api_key":
                return made.answer(request.operationID, .json(["xi-api-key": "sk_fixture_not_a_real_key_0000", "key_id": "new"]))
            case "edit_service_account_api_key":
                return made.answer(request.operationID, .json(["status": "ok"]))
            case "create_service_account":
                return made.answer(request.operationID, .json(["service-account-user-id": "sa-new"]))
            case "get_service_account_api_keys_route":
                return .json(keys)
            case "get_workspace_service_accounts":
                return .json(accounts)
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
    }

    /// "Make key" for "CI key", carried out, its answer lost: the key may exist, its secret
    /// never shown. The account's keys are read at once, the draft stays, and a second "Make
    /// key" is held — no second key is minted — until the owner says they have checked. Other
    /// calls (an edit of another key) are not held. (Before: no read, nothing held, and a second
    /// "Make key" minted a second key.)
    @Test func aKeyMadeWithItsAnswerLostIsHeldUntilTheOwnerHasChecked() async throws {
        let made = Made()
        made.lose("create_service_account_api_key")
        let fixture = keysFixture(made)
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let account = try #require(ServiceAccount(json: VoicesStudioLateAnswerTests.account("sa-a", key: "k1")))
        model.load(accounts: [account], selected: account)
        model.keyDraft.name = "CI key"
        model.keyDraft.allPermissions = true
        try await answering(model.actions) { await model.createKey() }
        #expect(made.count("create_service_account_api_key") == 1)
        #expect(fixture.sent("get_service_account_api_keys_route").count == 1, "the keys were not read after a lost answer")
        #expect(model.keyDraft.name == "CI key", "the draft was not kept")
        let held = model.actions.heldCreate("create_service_account_api_key")
        #expect(held == ServiceAccountsSectionModel.lostKeyMessage("CI key", account: account.name))
        try await answering(model.actions) { await model.createKey() }
        #expect(made.count("create_service_account_api_key") == 1, "a second key was minted after the first one's answer was lost")
        #expect(model.actions.refusal?.contains("may have been made") == true, "\(model.actions.refusal ?? "-")")
        // Only that create is held: another key can still be changed.
        model.edit(try #require(model.selected?.keys.first))
        model.keyDraft.allPermissions = true
        model.keyDraft.permissions = []
        model.keyDraft.name = "Renamed"
        try await answering(model.actions) { await model.saveKey() }
        #expect(made.count("edit_service_account_api_key") == 1)
        // Checked: "Make key" goes again, from the draft.
        model.actions.acknowledgeHeldCreate("create_service_account_api_key")
        model.keyDraft = ServiceAccountKeyDraft(name: "CI key", allPermissions: true)
        try await answering(model.actions) { await model.createKey() }
        #expect(made.count("create_service_account_api_key") == 2)
        #expect(model.actions.heldCreate("create_service_account_api_key") == nil)
    }

    /// A key create ElevenLabs refused made nothing: nothing is read, nothing is held, and
    /// "Make key" goes again at once.
    @Test func aRefusedKeyCreateHoldsNothing() async throws {
        let made = Made()
        made.refuse("create_service_account_api_key")
        let fixture = keysFixture(made)
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let account = try #require(ServiceAccount(json: VoicesStudioLateAnswerTests.account("sa-a", key: "k1")))
        model.load(accounts: [account], selected: account)
        model.keyDraft.name = "CI key"
        model.keyDraft.allPermissions = true
        try await answering(model.actions) { await model.createKey() }
        #expect(model.actions.heldCreate("create_service_account_api_key") == nil, "a refused create was held")
        #expect(fixture.sent("get_service_account_api_keys_route").isEmpty)
        try await answering(model.actions) { await model.createKey() }
        #expect(made.count("create_service_account_api_key") == 1)
        #expect(fixture.sent("create_service_account_api_key").count == 2)
    }

    /// "Create service account", carried out, its answer lost: the accounts are read again, the
    /// name stays, and a second create is held until the owner has checked.
    @Test func aServiceAccountCreatedWithItsAnswerLostIsHeldUntilTheOwnerHasChecked() async throws {
        let made = Made()
        made.lose("create_service_account")
        let fixture = keysFixture(made)
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        model.load(accounts: [])
        model.newAccountName = "CI"
        try await answering(model.actions) { await model.createAccount() }
        #expect(fixture.sent("get_workspace_service_accounts").count == 1, "the accounts were not read after a lost answer")
        #expect(model.newAccountName == "CI")
        #expect(model.actions.heldCreate("create_service_account") == ServiceAccountsSectionModel.lostAccountMessage("CI"))
        try await answering(model.actions) { await model.createAccount() }
        #expect(made.count("create_service_account") == 1, "a second service account was made after the first one's answer was lost")
        model.actions.acknowledgeHeldCreate("create_service_account")
        try await answering(model.actions) { await model.createAccount() }
        #expect(made.count("create_service_account") == 2)
    }

    // MARK: - Webhooks

    /// "Create webhook", carried out, its answer lost: the webhook may exist (its signing secret
    /// never shown), and a second would send every event twice. The list is read at once, the
    /// draft stays, and a second create is held until the owner has checked. (Before: no read,
    /// nothing held, and a second create was sent.)
    @Test func aWebhookCreatedWithItsAnswerLostIsHeldUntilTheOwnerHasChecked() async throws {
        let made = Made()
        made.lose("create_workspace_webhook_route")
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "create_workspace_webhook_route":
                return made.answer(request.operationID, .json(["webhook_id": "w2", "webhook_secret": "whsec_fixture_not_real"]))
            case "get_workspace_webhooks_route":
                return .json(["webhooks": []])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = WebhooksSectionModel(environment: fixture.environment)
        model.load(webhooks: [])
        model.draft.name = "Ops"
        model.draft.url = "https://hooks.example.com/ops"
        try await answering(model.actions) { await model.create() }
        #expect(fixture.sent("get_workspace_webhooks_route").count == 1, "the list was not read after a lost answer")
        #expect(model.draft.name == "Ops" && model.draft.url == "https://hooks.example.com/ops", "the draft was not kept")
        #expect(model.actions.heldCreate("create_workspace_webhook_route")
                == WebhooksSectionModel.lostCreateMessage("Ops", url: "https://hooks.example.com/ops"))
        try await answering(model.actions) { await model.create() }
        #expect(fixture.sent("create_workspace_webhook_route").count == 1, "a second subscription was sent")
        model.actions.acknowledgeHeldCreate("create_workspace_webhook_route")
        try await answering(model.actions) { await model.create() }
        #expect(fixture.sent("create_workspace_webhook_route").count == 2)
    }
}
