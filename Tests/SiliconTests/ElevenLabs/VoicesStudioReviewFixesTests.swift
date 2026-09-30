import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// The review of the voices-and-studio sections: each test pins one finding (named in its
/// comment) and failed before its fix.
@Suite("ElevenLabs voices and studio sections: review fixes", .timeLimit(.minutes(1)))
@MainActor
struct VoicesStudioReviewFixesTests {

    static func delayed(_ json: String, seconds: Int = 5) -> FakeElevenLabsTransport.Reply {
        .init(status: 200, headers: ["content-type": "application/json"], body: Data(json.utf8), delay: .seconds(seconds))
    }

    final class Flag { var done = false }

    /// Runs an action and declines any question it asks — so a screen that asks when it must
    /// not fails the test instead of waiting for an answer forever. Returns what was asked.
    func runDeclining(
        _ actions: VoicesStudioActions, _ action: @escaping @MainActor () async -> Void
    ) async throws -> ElevenLabsConfirmationRequest? {
        let flag = Flag()
        let task = Task { await action(); flag.done = true }
        var asked: ElevenLabsConfirmationRequest?
        for _ in 0..<500 where !flag.done {
            if let question = actions.presentedQuestion {
                asked = question
                actions.answer(false)
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await task.value
        return asked
    }

    /// The pinned spec's text, for checking the screens' money sentences against it.
    static func specText() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Scripts/elevenlabs/openapi.json"), encoding: .utf8)
    }

    // MARK: Productions (B1, R3)

    /// B1: the spec says a sandbox order "auto-progresses without producer intervention" and
    /// states the charge on submit without exception — it never says a sandbox order is free.
    @Test func aSandboxOrderIsDescribedInTheSpecsWordsAndStillStatesTheCharge() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        let order = try #require(ProductionsOrder(json: VoicesStudioProductionsTests.order("o1", sandbox: true,
                                                                                            items: [VoicesStudioProductionsTests.dubItem])))
        model.load(orders: [order], selected: order)
        let question = try #require(model.submitQuestion())
        let said = (question.title + " " + question.consequence).lowercased()
        #expect(!said.contains("nothing is charged") && !said.contains("free") && !said.contains("not charged"))
        #expect(question.consequence.contains("$240.00"))
        #expect(question.consequence.contains(ProductionsSectionModel.sandboxWords))
        let spec = try Self.specText()
        #expect(spec.contains("auto-progresses without producer intervention"))
    }

    /// R3: the spec leaves `total_amount_usd` out "until quotes are available". Submit fetches
    /// the order first, asks with the amount it states now, and never asks without one.
    @Test func submittingFetchesTheOrderAndNeverAsksWithoutAnAmount() async throws {
        let quoted: JSONValue = VoicesStudioProductionsTests.order("o1", total: 310, items: [VoicesStudioProductionsTests.dubItem])
        let unquoted: JSONValue = VoicesStudioProductionsTests.order("o1", total: nil, items: [VoicesStudioProductionsTests.dubItem])
        let fixture = VoicesStudioFixture([
            "public_get_order": [.json(unquoted), .json(quoted), .json(quoted)],
        ])
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        // Selected with a stale $240.00; ElevenLabs no longer has a quote.
        model.load(orders: [], selected: try #require(ProductionsOrder(json: VoicesStudioProductionsTests.order(
            "o1", total: 240, items: [VoicesStudioProductionsTests.dubItem]))))
        let askedUnquoted = try await runDeclining(model.actions) { await model.submit() }
        #expect(askedUnquoted == nil, "asked to charge with no quote: “\(askedUnquoted?.consequence ?? "")”")
        #expect(fixture.sent("public_submit_order").isEmpty)
        #expect(model.submitHold?.contains("Waiting for ElevenLabs' quote") == true)

        // Now quoted at $310.00: that is the amount asked about, not the one on screen before.
        let asked = try await voicesStudioAsk(model.actions, answer: false) { await model.submit() }
        #expect(asked?.title == "Submit “Launch video” and charge the workspace $310.00?")
        #expect(asked?.confirmLabel == "Submit and pay $310.00")
        #expect(fixture.sent("public_submit_order").isEmpty)
    }

    // MARK: Webhooks (B2)

    /// B2: the list carries `events` only "when usages are requested", and the edit's `events`
    /// is "the complete set": a rename must not unsubscribe the webhook or turn retries on.
    @Test func renamingAWebhookListedWithoutUsagesKeepsItsEventsAndRetries() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = WebhooksSectionModel(environment: fixture.environment)
        let webhook = try #require(WorkspaceWebhook(json: [
            "name": "Ops", "webhook_id": "w1", "webhook_url": "https://example.com/hook", "is_disabled": false,
            "is_auto_disabled": false, "created_at_unix": 1, "auth_type": "hmac",
        ]))
        model.load(webhooks: [webhook])
        model.edit(webhook)
        model.draft.name = "Ops renamed"
        let arguments = try #require(model.editArguments())
        #expect(arguments == ["webhook_id": "w1", "name": "Ops renamed", "is_disabled": false])
        #expect(fixture.client.validate("edit_workspace_webhook_route", arguments: arguments).isEmpty)
    }

    /// B2: opening the editor lists the webhooks with their usages first, so the events it
    /// shows are ElevenLabs'; only a change to them is sent.
    @Test func editingAWebhookStartsFromItsSubscriptionsAndSendsOnlyAChange() async throws {
        let listed: JSONValue = ["webhooks": [[
            "name": "Ops", "webhook_id": "w1", "webhook_url": "https://example.com/hook", "is_disabled": false,
            "is_auto_disabled": false, "created_at_unix": 1, "auth_type": "hmac", "events": ["flows"],
            "usage": [["usage_type": "flows"]],
        ]]]
        let fixture = VoicesStudioFixture(["get_workspace_webhooks_route": [.json(listed)]])
        defer { fixture.clean() }
        let model = WebhooksSectionModel(environment: fixture.environment)
        let bare = try #require(WorkspaceWebhook(json: [
            "name": "Ops", "webhook_id": "w1", "webhook_url": "https://example.com/hook", "is_disabled": false,
            "is_auto_disabled": false, "created_at_unix": 1,
        ]))
        await model.startEditing(bare)
        #expect(fixture.query("get_workspace_webhooks_route").contains { $0 == ("include_usages", "true") })
        #expect(model.eventsKnown)
        #expect(model.draft.events == ["flows"])
        #expect(model.editArguments()?["events"] == nil, "unchanged subscriptions are not sent")
        model.draft.events.insert("speech_to_text")
        #expect(model.editArguments()?["events"] == ["flows", "speech_to_text"])
    }

    // MARK: Studio (R1, R4)

    /// R1: a project created with "convert now" spends credits, so it waits for a conversion
    /// under way — and a conversion waits for it.
    @Test func aProjectThatConvertsOnCreationAndAConversionWaitForEachOther() async throws {
        let fixture = VoicesStudioFixture([
            "convert_project_endpoint": [Self.delayed(#"{"status":"ok"}"#)],
            "add_project": [Self.delayed(#"{"project":{"project_id":"p2","name":"B"}}"#)],
        ])
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let project = try #require(StudioProject(json: ["project_id": "p1", "name": "A"]))
        model.load(projects: [project], selected: project)

        let convert = Task { await model.convert() }
        try await voicesStudioWait { fixture.sent("convert_project_endpoint").count == 1 }
        model.draft.name = "B"
        model.draft.autoConvert = true
        await model.createProject()
        #expect(fixture.sent("add_project").isEmpty)
        #expect(model.actions.refusal?.contains("still running") == true)
        for runner in model.actions.active { runner.cancel() }
        await convert.value
        model.actions.acknowledgeUnknownOutcomes()

        let create = Task { await model.createProject() }
        try await voicesStudioWait { fixture.sent("add_project").count == 1 }
        await model.convert()
        #expect(fixture.sent("convert_project_endpoint").count == 1, "no second conversion while the create converts")
        for runner in model.actions.active { runner.cancel() }
        await create.value
    }

    /// R1: without "convert now" a create spends nothing and is not held.
    @Test func aProjectCreatedWithoutConvertingIsNotHeldByAConversion() async throws {
        let fixture = VoicesStudioFixture([
            "convert_project_endpoint": [Self.delayed(#"{"status":"ok"}"#)],
            "add_project": [.json(["project": ["project_id": "p2", "name": "B"]])],
        ])
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let project = try #require(StudioProject(json: ["project_id": "p1", "name": "A"]))
        model.load(projects: [project], selected: project)
        let convert = Task { await model.convert() }
        try await voicesStudioWait { fixture.sent("convert_project_endpoint").count == 1 }
        model.draft.name = "B"
        let runner = try #require(model.actions.runner("add_project"))
        #expect(!model.actions.isBlocked(runner, spends: false))
        #expect(model.actions.isBlocked(runner, spends: true))
        for runner in model.actions.active { runner.cancel() }
        await convert.value
    }

    /// R4: replacing a project's content replaces every chapter, so it asks first — naming the
    /// project, the chapters and the source — and sends nothing on a no.
    @Test func replacingAProjectsContentAsksFirstNamingWhatIsReplaced() async throws {
        let scratch = try VoicesStudioScratch()
        defer { scratch.remove() }
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let project = try #require(StudioProject(json: VoicesStudioStudioTests.project("p1", chapters: [
            VoicesStudioStudioTests.chapter("c1", name: "One"), VoicesStudioStudioTests.chapter("c2", name: "Two"),
        ])))
        model.load(projects: [project], selected: project)
        model.contentDocument = [try scratch.file("second-draft.epub")]
        model.contentAutoConvert = true
        let asked = try await runDeclining(model.actions) { await model.updateContent() }
        #expect(asked?.title == "Replace everything in “The Long Road” with “second-draft.epub”?")
        #expect(asked?.confirmLabel == "Replace content")
        #expect(asked?.consequence.contains("Its 2 chapters and your edits in them are replaced") == true)
        #expect(asked?.consequence.contains("uses credits") == true)
        #expect(fixture.sent("edit_project_content").isEmpty)
    }

    // MARK: Cancel, then start again (R2)

    /// R2: a dub cancelled after it was sent may already have been started and billed: the
    /// list is fetched again, and another dub waits until the owner says they have checked.
    @Test func aCancelledDubHoldsTheNextOneUntilTheOwnerHasChecked() async throws {
        let scratch = try VoicesStudioScratch()
        defer { scratch.remove() }
        let fixture = VoicesStudioFixture([
            "create_dubbing": [Self.delayed(#"{"dubbing_id":"d1","expected_duration_sec":10}"#),
                               .json(["dubbing_id": "d2", "expected_duration_sec": 10])],
            "list_dubs": [.json(["dubs": [VoicesStudioDubbingTests.dub("d1", status: "dubbing")], "has_more": false]),
                          .json(["dubs": [], "has_more": false])],
            "get_dubbed_metadata": [.json(VoicesStudioDubbingTests.dub("d2", status: "dubbing"))],
        ])
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        model.draft.files = [try scratch.file("trailer.mp4")]
        model.draft.targetLanguage = "es"
        let first = Task { await model.createDub() }
        try await voicesStudioWait { fixture.sent("create_dubbing").count == 1 }
        for runner in model.actions.active { runner.cancel() }
        await first.value

        #expect(model.actions.unknownOutcomes["create_dubbing"] != nil)
        #expect(fixture.sent("list_dubs").count == 1, "the dubs are listed again at once")
        #expect(model.dubs.map(\.id) == ["d1"], "…showing the dub that was started after all")
        await model.createDub()
        #expect(fixture.sent("create_dubbing").count == 1)
        #expect(model.actions.refusal?.contains("I have checked") == true)

        model.actions.acknowledgeUnknownOutcomes()
        await model.createDub()
        #expect(fixture.sent("create_dubbing").count == 2)
    }

    /// R2: the same holds when the answer is lost on the way back, and for the other creates
    /// that spend — a podcast here — while a refusal ElevenLabs gave (4xx) is a known outcome.
    @Test func aLostAnswerIsAnUnknownOutcomeAndARefusalIsNot() async throws {
        let fixture = VoicesStudioFixture([
            "create_podcast": [.failure(.network("The request timed out.")),
                               .jsonText(#"{"detail":{"status":"invalid","message":"Bad source"}}"#, status: 422)],
            "get_projects": [.json(["projects": []])],
        ])
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        model.podcast.modelID = "eleven_multilingual_v2"
        model.podcast.hostVoiceID = "v1"
        model.podcast.guestVoiceID = "v2"
        model.podcast.text = "Why the road is long."
        await model.createPodcast()
        #expect(model.actions.unknownOutcomes["create_podcast"] != nil)
        #expect(fixture.sent("get_projects").count == 1)
        await model.createPodcast()
        #expect(fixture.sent("create_podcast").count == 1)

        model.actions.acknowledgeUnknownOutcomes()
        await model.createPodcast()
        #expect(fixture.sent("create_podcast").count == 2)
        #expect(model.actions.unknownOutcomes.isEmpty, "a 422 is ElevenLabs' refusal: nothing was made")
    }

    /// R2: voice design previews leave nothing lasting, so a cancelled design does not hold the
    /// next one.
    @Test func aCancelledDesignNeedsNoCheck() async throws {
        let fixture = VoicesStudioFixture(["text_to_voice_design": [Self.delayed(#"{"previews":[],"text":""}"#)]])
        defer { fixture.clean() }
        let model = VoiceDesignSectionModel(environment: fixture.environment)
        model.voiceDescription = "A calm, low narrator with a warm Scottish accent."
        let design = Task { await model.generate() }
        try await voicesStudioWait { fixture.sent("text_to_voice_design").count == 1 }
        for runner in model.actions.active { runner.cancel() }
        await design.value
        #expect(model.actions.unknownOutcomes.isEmpty)
    }

    // MARK: Credentials (R5, R6, R7, R12)

    /// R5: a key shown once belongs to the account it was made for, and to this visit.
    @Test func aNewKeyIsForgottenOnAnotherAccountOrWhenTheSectionIsLeft() async throws {
        let secret = "sk_" + String(repeating: "z", count: 30)
        let fixture = VoicesStudioFixture([
            "create_service_account_api_key": [.json(["xi-api-key": .string(secret), "key_id": "k2"]),
                                               .json(["xi-api-key": .string(secret), "key_id": "k3"])],
            "get_service_account_api_keys_route": [.json(["api-keys": []]), .json(["api-keys": []])],
        ])
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let a = try #require(ServiceAccount(json: ["service_account_user_id": "sa1", "name": "Render farm", "api-keys": []]))
        let b = try #require(ServiceAccount(json: ["service_account_user_id": "sa2", "name": "Support bot", "api-keys": []]))
        model.load(accounts: [a, b], selected: a)
        model.keyDraft.name = "Nightly"
        _ = try await voicesStudioAsk(model.actions, answer: true) { await model.createKey() }
        let runner = try #require(model.actions.runner("create_service_account_api_key"))
        #expect(runner.credential != nil)
        model.select("sa2")
        #expect(runner.credential == nil)

        model.keyDraft.name = "Support"
        _ = try await voicesStudioAsk(model.actions, answer: true) { await model.createKey() }
        #expect(runner.credential != nil)
        model.actions.dismissCredentials()  // what leaving the section does
        #expect(runner.credential == nil)
    }

    /// R6: the kill switch asks in its own words, and says only elevenlabs.io can undo it.
    @Test func theKillSwitchAsksInItsOwnWords() async throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let asked = try await voicesStudioAsk(model.actions, answer: false) { await model.disableOwnKey() }
        #expect(asked?.title == "Disable the key this Mac uses?")
        #expect(asked?.confirmLabel == "Disable key")
        #expect(asked?.warning?.contains("elevenlabs.io") == true)
        #expect(fixture.transport.recorded.isEmpty)
    }

    /// R6: turning a key off and changing a member's seat ask in their own words too.
    @Test func keysAndSeatsAskInTheirOwnWords() async throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let accounts = ServiceAccountsSectionModel(environment: fixture.environment)
        let account = try #require(ServiceAccount(json: VoicesStudioAccountsTests.account))
        accounts.load(accounts: [account], selected: account)
        let off = try await voicesStudioAsk(accounts.actions, answer: false) { await accounts.setEnabled(account.keys[0], false) }
        #expect(off?.title == "Turn off the API key “CI” of “Render farm”?")
        #expect(off?.confirmLabel == "Turn off key")

        let workspace = WorkspaceSectionModel(environment: fixture.environment)
        let member = try #require(WorkspaceMember(json: VoicesStudioWorkspaceTests.member))
        workspace.load(members: [member])
        workspace.seatEdits[member.id] = "workspace_admin"
        let seat = try await voicesStudioAsk(workspace.actions, answer: false) { await workspace.changeSeat(member) }
        #expect(seat?.title == "Give sam@example.com a workspace admin seat?")
        #expect(seat?.confirmLabel == "Change seat")
        #expect(fixture.transport.recorded.isEmpty)
    }

    /// A yes given after the account changed — asked for account A, answered under B — sends
    /// nothing: the kill switch must never disable B's key.
    @Test func anAnswerGivenAfterTheAccountChangedSendsNothing() async throws {
        let one = VoicesStudioFixture()
        let two = VoicesStudioFixture(["disable": [.json(["status": "ok"])]])
        defer { one.clean(); two.clean() }
        let current = VoicesStudioSwitchableClient(one.client)
        let environment = VoicesStudioEnvironment(context: .init(client: { current.client }), voices: one.voices)
        let model = ServiceAccountsSectionModel(environment: environment)
        let task = Task { await model.disableOwnKey() }
        try await voicesStudioWait { model.actions.presentedQuestion != nil }
        current.client = two.client
        model.actions.answer(true)
        await task.value
        #expect(two.transport.recorded.isEmpty && one.transport.recorded.isEmpty)
        #expect(model.actions.refusal?.contains("account changed") == true)
    }

    /// R7: "Show API call" and "Copy as curl" never show what an owner types as a sign-in
    /// connection's secret — an mTLS private key and passphrase included.
    @Test func noSignInConnectionSecretReachesShowAPICallOrCurl() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let secretNames: Set<String> = ["client_secret", "token", "password", "secret_key", "client_key", "key_passphrase"]
        let kinds = WorkspaceAuthKind.kinds(of: "create_auth_connection")
        #expect(kinds.map(\.authType).contains("mtls"))
        for kind in kinds {
            var arguments: [String: JSONValue] = ["auth_type": .string(kind.authType)]
            for (name, schema) in kind.schema["properties"].objectValue ?? [:] where name != "auth_type" {
                if JSONSchema.unwrapNullable(schema)["type"].stringValue == "string" {
                    arguments[name] = .string("typed-\(name)-value")
                }
            }
            let described = try fixture.client.describe("create_auth_connection", arguments: arguments)
            let curl = ElevenLabsCurl.command(for: described)
            for name in secretNames where arguments[name] != nil {
                #expect(!described.body!.jsonString().contains("typed-\(name)-value"), "\(kind.authType).\(name) shown")
                #expect(!curl.contains("typed-\(name)-value"), "\(kind.authType).\(name) in curl")
            }
        }
    }

    /// R12: a secret typed into a connection's edit form is gone once saved or cancelled.
    @Test func aConnectionsTypedSecretIsForgottenAfterSaveOrCancel() async throws {
        let fixture = VoicesStudioFixture([
            "update_auth_connection": [.json(["id": "c1"])],
            "list_auth_connections": [.json(["auth_connections": []])],
        ])
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        let connection = try #require(WorkspaceAuthConnection(json: ["id": "c1", "name": "Search API", "auth_type": "bearer_auth"]))
        model.load(connections: [connection])
        model.edit(connection)
        let form = try #require(model.connectionForm("update_auth_connection", authType: "bearer_auth"))
        let token = try #require(form.nodes.first { $0.field.name == "token" })
        token.text = "typed-secret-value-123"
        _ = try await voicesStudioAsk(model.actions, answer: true) { await model.updateConnection() }
        #expect(fixture.sent("update_auth_connection").count == 1)
        #expect(token.text.isEmpty)

        model.edit(connection)
        token.text = "typed-again"
        model.edit(nil)
        #expect(token.text.isEmpty)
    }

    // MARK: Workspace (R11)

    /// R11: a share option's `name` is "The name of the principal": a user is shared with by
    /// the email typed for them, never by that name.
    @Test func sharingNeverSendsAPrincipalsNameAsAnEmail() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        model.load(resource: try #require(WorkspaceResource(json: [
            "resource_id": "r1", "resource_name": "Narrator", "resource_type": "voice", "role_to_group_ids": [:],
            "share_options": [["id": "user_123", "name": "Kim Lee", "type": "user"],
                              ["id": "g1", "name": "Editors", "type": "group"]],
        ])))
        #expect(model.groupOptions.map(\.name) == ["Editors"])
        model.shareTarget = "user_123"
        #expect(model.targetArguments().isEmpty)
        model.shareEmail = "kim@example.com"
        #expect(model.targetArguments() == ["user_email": "kim@example.com"])
    }

    // MARK: Voices (R9) and the rest

    /// R9: `with_settings` is deprecated and ignored, and the voice's `settings` may be null:
    /// the settings route fills the sliders.
    @Test func aVoiceWhoseAnswerHasNoSettingsStillGetsItsSliders() async throws {
        let fixture = VoicesStudioFixture([
            "get_voice_by_id": [.json(VoicesStudioFakes.voice("v1", "Rachel"))],
            "get_voice_settings": [.json(VoicesStudioFakes.settings)],
        ])
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        await model.select("v1")
        #expect(model.settingsDraft?.stability == 0.4)
        #expect(fixture.path("get_voice_settings") == "/v1/voices/v1/settings")
        #expect(!fixture.query("get_voice_by_id").contains { $0.0 == "with_settings" })
    }

    /// R10: the dubbing buttons' cost notes are the spec's own words, and none of them bills
    /// by the source's length.
    @Test func dubbingCostNotesAreTheSpecsWords() throws {
        let spec = try Self.specText()
        let notes = [DubbingSectionModel.CostNote.project, DubbingSectionModel.CostNote.language,
                     DubbingSectionModel.CostNote.regenerate]
        for note in notes { #expect(!note.lowercased().contains("length"), "\(note)") }
        #expect(spec.contains("each additional language is charged separately"))
        #expect(spec.contains("it is billed per generation"))
        #expect(spec.contains("charged like a generation, less the free-regeneration allowance"))
        #expect(spec.contains("Enterprise only. Re-dub a target"))
    }

    /// Regenerating re-dubs what ElevenLabs holds, so it waits for unsaved edits.
    @Test func regeneratingWaitsForUnsavedTranslationEdits() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        #expect(model.regenerateHold == nil)
        model.targetEdits = ["s1": "Hola"]
        #expect(model.regenerateHold?.contains("Save the edits first") == true)
    }

    /// A reference recording past the limit is refused before it is read.
    @Test func aReferenceRecordingPastTheLimitIsRefusedUnread() throws {
        let scratch = try VoicesStudioScratch()
        defer { scratch.remove() }
        let big = scratch.directory.appendingPathComponent("interview.wav")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(VoiceDesignSectionModel.referenceLimit + 1))
        try handle.close()
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = VoiceDesignSectionModel(environment: fixture.environment)
        model.voiceDescription = "A calm, low narrator with a warm Scottish accent."
        model.modelID = "eleven_ttv_v3"
        model.referenceAudio = [big]
        let built = model.arguments(reference: "should-not-be-used")
        #expect(built.problems.contains { $0.contains("at most") })
        #expect(built.arguments["reference_audio_base64"] == nil)
    }

    /// A chosen preview is saved once: a second save would make a second voice.
    @Test func aPreviewIsSavedOnce() async throws {
        let fixture = VoicesStudioFixture(["create_voice": [.json(VoicesStudioFakes.voice("saved1", "Narrator"))]])
        defer { fixture.clean() }
        let model = VoiceDesignSectionModel(environment: fixture.environment)
        model.load(previews: [VoiceDesignPreview(generatedVoiceID: "g1")], text: nil)
        model.saveName = "Narrator"
        model.saveDescription = "A calm, low narrator with a warm Scottish accent."
        #expect(model.canSave)
        await model.save()
        #expect(!model.canSave)
    }

    /// Nits: training is not offered while it runs; Audio Native publishes only when asked.
    @Test func trainingIsNotOfferedTwiceAndPublishingIsOptIn() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let voices = VoicesSectionModel(environment: fixture.environment)
        let training = try #require(VoicesVoice(json: VoicesStudioFakes.voice(
            "p1", "Pro", category: "professional",
            fineTuning: ["is_allowed_to_fine_tune": true, "state": ["eleven_multilingual_v2": "fine_tuning"],
                         "verification_failures": [], "verification_attempts_count": 1, "manual_verification_requested": false]
        )))
        voices.load(rows: [training], selected: training)
        #expect(voices.isTraining)
        #expect(AudioNativeSectionModel(environment: fixture.environment).contentAutoPublish == false)
    }
}
