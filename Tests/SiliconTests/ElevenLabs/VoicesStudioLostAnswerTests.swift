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

    /// Counts reads, and fails the first `failing` of them.
    final class Reads: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
        var failing: Int
        init(failing: Int = 0) { self.failing = failing }
        func fails() -> Bool { lock.withLock { count += 1; return count <= failing } }
    }

    func keysFixture(_ made: Made, keyReads: Reads = Reads()) -> VoicesStudioFixture {
        let keys: JSONValue = ["api-keys": [VoicesStudioLateAnswerTests.key("k1", of: "sa-a")]]
        let accounts: JSONValue = ["service-accounts": [VoicesStudioLateAnswerTests.account("sa-a", key: "k1")]]
        return VoicesStudioFixture(handler: { request in
            if request.operationID == "get_service_account_api_keys_route", keyReads.fails() {
                return VoicesStudioLostAnswerTests.lost
            }
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
        #expect(model.actions.acknowledgeHeldCreate("create_service_account_api_key"))
        model.keyDraft = ServiceAccountKeyDraft(name: "CI key", allPermissions: true)
        try await answering(model.actions) { await model.createKey() }
        #expect(made.count("create_service_account_api_key") == 2)
        #expect(model.actions.heldCreate("create_service_account_api_key") == nil)
    }

    /// R6-1: "Make key" lost, and the keys read after it fails too. Nothing was read, so nothing
    /// says it was: the hold's caption says the list could not be read, "I have checked" is
    /// refused (a second "Make key" stays held, though the owner never saw the list), and "Read
    /// again" is offered. Once a read succeeds the caption says so and the check is taken; or the
    /// owner can say they checked on elevenlabs.io. (Before: the box said the list had been read,
    /// and after "I have checked" a second key was minted.)
    @Test func aCheckIsNotTakenWhileTheListCouldNotBeRead() async throws {
        let made = Made()
        made.lose("create_service_account_api_key")
        let fixture = keysFixture(made, keyReads: Reads(failing: 1))
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let account = try #require(ServiceAccount(json: VoicesStudioLateAnswerTests.account("sa-a", key: "k1")))
        model.load(accounts: [account], selected: account)
        model.keyDraft.name = "CI key"
        model.keyDraft.allPermissions = true
        try await answering(model.actions) { await model.createKey() }
        #expect(fixture.sent("get_service_account_api_keys_route").count == 1)
        let held = try #require(model.actions.held("create_service_account_api_key"))
        #expect(!held.listRead)
        #expect(model.actions.holdCaption(held).hasPrefix("The list could not be read"), "\(model.actions.holdCaption(held))")
        #expect(!model.actions.acknowledgeHeldCreate("create_service_account_api_key"),
                "a check was taken though the list was never read")
        try await answering(model.actions) { await model.createKey() }
        #expect(made.count("create_service_account_api_key") == 1, "a second key was minted though the list was never read")
        // "Read again": this time the keys are read.
        await model.actions.onReadAgain?(held)
        let read = try #require(model.actions.held("create_service_account_api_key"))
        #expect(read.listRead)
        #expect(model.actions.holdCaption(read).hasPrefix("The list has been read again"))
        #expect(model.actions.acknowledgeHeldCreate("create_service_account_api_key"))
        try await answering(model.actions) { await model.createKey() }
        #expect(made.count("create_service_account_api_key") == 2)
    }

    /// The same, the keys never readable: "I checked on elevenlabs.io" releases the hold — the
    /// owner's word that they looked where the key would be.
    @Test func checkingOnTheWebsiteReleasesAHoldWhoseListCouldNotBeRead() async throws {
        let made = Made()
        made.lose("create_service_account_api_key")
        let fixture = keysFixture(made, keyReads: Reads(failing: 100))
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let account = try #require(ServiceAccount(json: VoicesStudioLateAnswerTests.account("sa-a", key: "k1")))
        model.load(accounts: [account], selected: account)
        model.keyDraft.name = "CI key"
        model.keyDraft.allPermissions = true
        try await answering(model.actions) { await model.createKey() }
        #expect(!model.actions.acknowledgeHeldCreate("create_service_account_api_key"))
        model.actions.acknowledgeHeldCreateOnWebsite("create_service_account_api_key")
        try await answering(model.actions) { await model.createKey() }
        #expect(made.count("create_service_account_api_key") == 2)
    }

    /// What this screen cannot list (an invitation) says so, and is checked on elevenlabs.io:
    /// "I have checked" — which would mean the list here was looked at — is refused.
    @Test func whatThisScreenCannotListIsCheckedOnTheWebsite() async throws {
        let made = Made()
        made.lose("invite_user")
        let fixture = workspaceFixture(made)
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        model.inviteEmails = "sam@example.com"
        try await answering(model.actions) { await model.invite() }
        let held = try #require(model.actions.held("invite_user"))
        #expect(!held.listedHere)
        #expect(model.actions.holdCaption(held).hasPrefix("This screen cannot list it"))
        #expect(!model.actions.acknowledgeHeldCreate("invite_user"))
        model.actions.acknowledgeHeldCreateOnWebsite("invite_user")
        #expect(model.invitationsHeld == nil)
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
        #expect(model.actions.acknowledgeHeldCreate("create_service_account"))
        try await answering(model.actions) { await model.createAccount() }
        #expect(made.count("create_service_account") == 2)
    }

    /// N5-1: the line saying a key change's answer was lost is about that account's keys; it
    /// does not follow the owner to another account.
    @Test func theLostAnswerLineStaysWithItsAccount() async throws {
        let made = Made()
        made.lose("edit_service_account_api_key")
        let fixture = keysFixture(made)
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let a = try #require(ServiceAccount(json: VoicesStudioLateAnswerTests.account("sa-a", key: "k1")))
        let b = try #require(ServiceAccount(json: VoicesStudioLateAnswerTests.account("sa-b", key: "kb")))
        model.load(accounts: [a, b], selected: a)
        model.edit(try #require(model.selected?.keys.first))
        model.keyDraft.allPermissions = true
        model.keyDraft.permissions = []
        model.keyDraft.name = "Renamed"
        try await answering(model.actions) { await model.saveKey() }
        #expect(model.problems.first?.contains("was lost") == true, "\(model.problems)")
        model.select("sa-b")
        #expect(model.problems.isEmpty, "account A's lost answer is shown under account B: \(model.problems)")
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
        #expect(model.actions.acknowledgeHeldCreate("create_workspace_webhook_route"))
        try await answering(model.actions) { await model.create() }
        #expect(fixture.sent("create_workspace_webhook_route").count == 2)
    }

    // MARK: - Workspace: invitations and sign-in connections

    func workspaceFixture(_ made: Made) -> VoicesStudioFixture {
        VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "invite_user", "invite_users_bulk":
                return made.answer(request.operationID, .json(["status": "ok"]))
            case "create_auth_connection":
                return made.answer(request.operationID, .json(["id": "ac-new"]))
            case "list_auth_connections":
                return .json(["auth_connections": []])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
    }

    /// An invitation sent, its answer lost: it may have gone, and sending again would email
    /// the same person twice. Inviting is held — one address or several — until the owner has
    /// checked; the addresses stay typed. (Before: nothing was held.)
    @Test func anInvitationWhoseAnswerWasLostHoldsInvitingUntilTheOwnerHasChecked() async throws {
        let made = Made()
        made.lose("invite_user")
        let fixture = workspaceFixture(made)
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        model.inviteEmails = "sam@example.com"
        try await answering(model.actions) { await model.invite() }
        #expect(made.count("invite_user") == 1)
        #expect(model.inviteEmails == "sam@example.com")
        #expect(model.invitationsHeld == WorkspaceSectionModel.lostInviteMessage(["sam@example.com"]))
        try await answering(model.actions) { await model.invite() }
        #expect(fixture.sent("invite_user").count == 1, "the invitation was sent a second time")
        model.inviteEmails = "sam@example.com, kim@example.com"
        try await answering(model.actions) { await model.invite() }
        #expect(fixture.sent("invite_users_bulk").isEmpty, "inviting several people was not held")
        #expect(model.inviteProblems == [WorkspaceSectionModel.lostInviteMessage(["sam@example.com"])])
        model.actions.acknowledgeHeldCreateOnWebsite("invite_user")
        try await answering(model.actions) { await model.invite() }
        #expect(fixture.sent("invite_users_bulk").count == 1)
    }

    /// A sign-in connection created, its answer lost: it may exist, holding the credentials
    /// typed. The connections are read at once, the form keeps what was typed, and a second
    /// create is held until the owner has checked.
    @Test func aSignInConnectionCreatedWithItsAnswerLostIsHeldUntilTheOwnerHasChecked() async throws {
        let made = Made()
        made.lose("create_auth_connection")
        let fixture = workspaceFixture(made)
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        model.newConnectionType = "bearer_auth"
        let form = try #require(model.connectionForm("create_auth_connection", authType: "bearer_auth"))
        for node in form.nodes where node.field.required {
            if case .text = node.field.kind { node.text = node.field.name == "name" ? "Search API" : "value-for-test" }
        }
        try await answering(model.actions) { await model.createConnection() }
        #expect(made.count("create_auth_connection") == 1)
        #expect(fixture.sent("list_auth_connections").count == 1, "the connections were not read after a lost answer")
        #expect(form.nodes.contains { $0.text == "Search API" }, "the form was cleared")
        #expect(model.actions.heldCreate("create_auth_connection") == WorkspaceSectionModel.lostConnectionMessage("Search API"))
        try await answering(model.actions) { await model.createConnection() }
        #expect(made.count("create_auth_connection") == 1, "a second connection was made after the first one's answer was lost")
        #expect(model.actions.acknowledgeHeldCreate("create_auth_connection"))
        try await answering(model.actions) { await model.createConnection() }
        #expect(made.count("create_auth_connection") == 2)
    }

    // MARK: - Voices: a copy to another workspace whose answer was lost

    /// A voice copied to another workspace, carried out, its answer lost: the copy is where this
    /// screen cannot list it, so a second "Copy voice" would make a second copy unseen. It is
    /// held until the owner has checked that workspace.
    @Test func aVoiceCopiedWithItsAnswerLostIsHeldUntilTheOwnerHasChecked() async throws {
        let made = Made()
        made.lose("replicate_voice_to_isolated_environment")
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "replicate_voice_to_isolated_environment":
                return made.answer(request.operationID, .json(["voice_id": "v-copy"]))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let voice = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-a", "Voice A", settings: VoicesStudioFakes.settings)))
        model.load(rows: [voice], selected: voice)
        model.replicateWorkspaceID = "ws-isolated"
        try await answering(model.actions) { await model.replicate() }
        #expect(model.actions.heldCreate("replicate_voice_to_isolated_environment")
                == VoicesSectionModel.lostCopyMessage("Voice A", workspace: "ws-isolated"))
        try await answering(model.actions) { await model.replicate() }
        #expect(made.count("replicate_voice_to_isolated_environment") == 1, "a second copy was sent")
        model.actions.acknowledgeHeldCreateOnWebsite("replicate_voice_to_isolated_environment")
        try await answering(model.actions) { await model.replicate() }
        #expect(made.count("replicate_voice_to_isolated_environment") == 2)
    }

    // MARK: - Dubbing: a segment whose answer was lost

    /// "Add segment", carried out, its answer lost: a second Add would add it twice. The
    /// transcript is read again at once, the section says the segment may have been added, and
    /// the fields stay as typed (as do unsaved edits). (Before: nothing was read or said.)
    @Test func aSegmentAddedWithItsAnswerLostIsReadAgainAndSaidSo() async throws {
        let made = Made()
        made.lose("dubbing_transcript_segment_add")
        let segments: JSONValue = ["segments": [VoicesStudioFollowupTests.segment("s1", "Hello"),
                                                VoicesStudioFollowupTests.segment("s2", "Added")]]
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "dubbing_transcript_segment_add":
                return made.answer(request.operationID, .json(["status": "ok"]))
            case "dubbing_transcript_get":
                return .json(segments)
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        let project = try #require(DubbingProject(json: ["project_id": "p-a", "status": "ready", "language_ids": []]))
        let first = try #require(DubbingSegment(json: VoicesStudioFollowupTests.segment("s1", "Hello")))
        model.load(projects: [project], selected: project, source: [first])
        model.sourceEdits["s1"] = "Hello, unsaved"
        model.newSegment.speaker = "speaker_1"
        model.newSegment.start = "2"
        model.newSegment.end = "3"
        model.newSegment.text = "Added"
        try await answering(model.actions) { await model.addSegment() }
        #expect(made.count("dubbing_transcript_segment_add") == 1)
        #expect(fixture.sent("dubbing_transcript_get").count == 1, "the transcript was not read after a lost answer")
        #expect(model.sourceSegments.map(\.text) == ["Hello", "Added"])
        #expect(model.segmentNote == DubbingSectionModel.lostSegmentMessage)
        #expect(model.newSegment.text == "Added", "the fields were cleared")
        #expect(model.sourceEdits == ["s1": "Hello, unsaved"], "unsaved edits were dropped")
    }
}
