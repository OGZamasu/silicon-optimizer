import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Answers that arrive after the screen moved on. In each test the fake answers one chosen id
/// late; meanwhile the owner picks something else, and the late answer must land with its own
/// item — never on the one now chosen, never taking the screen back, never marking the wrong
/// thing done.
@Suite("ElevenLabs voices and studio sections: late answers", .timeLimit(.minutes(1)))
@MainActor
struct VoicesStudioLateAnswerTests {
    static let late: Duration = .milliseconds(600)

    /// Starts `action`, says yes to any question it asks, and returns once `operationID` is on
    /// its way — so the test can change the screen while its answer is still coming.
    func sending(
        _ actions: VoicesStudioActions, _ operationID: String, _ action: @escaping @MainActor () async -> Void
    ) async throws -> Task<Void, Never> {
        let task = Task { await action() }
        try await voicesStudioWait {
            if actions.presentedQuestion != nil { actions.answer(true) }
            return actions.runner(operationID)?.isRunning == true
        }
        return task
    }

    // MARK: Service accounts

    static func account(_ id: String, key: String) -> JSONValue {
        ["service_account_user_id": .string(id), "name": .string("Account \(id)"), "created_at_unix": 1_780_000_000,
         "api-keys": [Self.key(key, of: id)]]
    }

    static func key(_ id: String, of account: String) -> JSONValue {
        ["name": .string("Key \(id)"), "hint": "a1b2", "key_id": .string(id), "service_account_user_id": .string(account),
         "is_disabled": false, "permissions": ["text_to_speech"], "character_count": 0, "hashed_xi_api_key": "h"]
    }

    /// One account's keys, answered after another account was chosen, stay with their account.
    @Test func keysAnsweredAfterAnotherAccountWasChosenStayWithTheirOwn() async throws {
        let fixture = VoicesStudioFixture([
            "get_service_account_api_keys_route": [.json(["api-keys": [Self.key("k-new", of: "sa-slow")]])],
        ], late: ["sa-slow": Self.late])
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let slow = try #require(ServiceAccount(json: Self.account("sa-slow", key: "k1")))
        let other = try #require(ServiceAccount(json: Self.account("sa2", key: "k2")))
        model.load(accounts: [slow, other], selected: slow)
        let task = try await sending(model.actions, "get_service_account_api_keys_route") { await model.refreshKeys() }
        model.select("sa2")
        await task.value
        #expect(model.selected?.id == "sa2")
        #expect(model.selected?.keys.map(\.id) == ["k2"], "another account's keys were shown under this one")
        #expect(model.accounts.first { $0.id == "sa-slow" }?.keys.map(\.id) == ["k-new"])
    }

    // MARK: Productions

    /// A rename that finishes after another order was chosen does not take the screen back.
    @Test func aRenameFinishingAfterAnotherOrderWasChosenLeavesThatOrderOnScreen() async throws {
        let fixture = VoicesStudioFixture([
            "public_update_order": [.json(["order_id": "o-slow"])],
            "public_get_order": [.json(VoicesStudioProductionsTests.order("o2")),
                                 .json(VoicesStudioProductionsTests.order("o-slow"))],
        ], late: ["o-slow": Self.late])
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        let slow = try #require(ProductionsOrder(json: VoicesStudioProductionsTests.order("o-slow")))
        let other = try #require(ProductionsOrder(json: VoicesStudioProductionsTests.order("o2")))
        model.load(orders: [slow, other], selected: slow)
        model.rename = "Renamed"
        let task = try await sending(model.actions, "public_update_order") { await model.saveName() }
        await model.select("o2")
        await task.value
        #expect(model.selected?.id == "o2", "the renamed order took the screen back")
        #expect(fixture.sent("public_get_order").count == 2)
    }

    // MARK: Dubbing

    /// A download that finishes after another dub was chosen stays with its dub.
    @Test func aDownloadFinishingAfterAnotherDubWasChosenStaysWithItsDub() async throws {
        let fixture = VoicesStudioFixture([
            "get_dubbed_file": [.init(status: 200, headers: ["content-type": "video/mp4"], body: Data(repeating: 7, count: 32))],
            "get_dubbed_metadata": [.json(VoicesStudioDubbingTests.dub("d2"))],
        ], late: ["d-slow": Self.late])
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        let slow = try #require(DubbingDub(json: VoicesStudioDubbingTests.dub("d-slow")))
        let other = try #require(DubbingDub(json: VoicesStudioDubbingTests.dub("d2")))
        model.load(dubs: [slow, other], selected: slow)
        model.downloadLanguage = "es"
        let task = try await sending(model.actions, "get_dubbed_file") { await model.download() }
        await model.selectDub("d2")
        await task.value
        #expect(model.selectedDub?.id == "d2")
        #expect(model.downloaded("d2", "es") == nil, "another dub's file was offered as this one's")
        #expect(model.downloaded("d-slow", "es")?.isVideo == true)
    }

    // MARK: Webhooks

    static func webhook(_ id: String) -> JSONValue {
        ["name": .string("Hook \(id)"), "webhook_id": .string(id), "webhook_url": "https://example.com/hook",
         "is_disabled": false, "is_auto_disabled": false, "created_at_unix": 1, "auth_type": "hmac", "events": ["flows"]]
    }

    /// A save that finishes after another webhook's editor was opened leaves that editor open.
    @Test func aSaveFinishingAfterAnotherEditorOpenedLeavesThatEditorOpen() async throws {
        let list: JSONValue = ["webhooks": [Self.webhook("w-slow"), Self.webhook("w2")]]
        let fixture = VoicesStudioFixture([
            "edit_workspace_webhook_route": [.json(["status": "ok"])],
            "get_workspace_webhooks_route": [.json(list), .json(list)],
        ], late: ["w-slow": Self.late])
        defer { fixture.clean() }
        let model = WebhooksSectionModel(environment: fixture.environment)
        let slow = try #require(WorkspaceWebhook(json: Self.webhook("w-slow")))
        let other = try #require(WorkspaceWebhook(json: Self.webhook("w2")))
        model.load(webhooks: [slow, other])
        model.edit(slow, eventsKnown: true)
        model.draft.name = "Renamed"
        let task = try await sending(model.actions, "edit_workspace_webhook_route") { await model.save() }
        await model.startEditing(other)
        #expect(model.editing?.id == "w2")
        await task.value
        #expect(model.editing?.id == "w2", "saving one webhook closed another's editor")
        #expect(model.draft.name == "Hook w2")
    }

    // MARK: Studio

    /// A chapter saved after another project was opened is not reopened under that project.
    @Test func aChapterSavedAfterAnotherProjectOpenedIsNotReopenedUnderIt() async throws {
        let fixture = VoicesStudioFixture([
            "edit_chapter": [.json(["chapter": VoicesStudioStudioTests.chapter("c-slow", name: "Renamed")])],
            "get_project_by_id": [.json(VoicesStudioStudioTests.project("p2"))],
        ], late: ["c-slow": Self.late])
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let first = try #require(StudioProject(json: VoicesStudioStudioTests.project("p1")))
        let second = try #require(StudioProject(json: VoicesStudioStudioTests.project("p2")))
        let chapter = try #require(StudioChapter(json: VoicesStudioStudioTests.chapter("c-slow", name: "One")))
        model.load(projects: [first, second], selected: first, chapter: chapter)
        model.chapterName = "Renamed"
        let task = try await sending(model.actions, "edit_chapter") { await model.saveChapter() }
        await model.select("p2")
        await task.value
        #expect(model.selected?.id == "p2")
        #expect(model.chapter == nil)
        #expect(fixture.sent("get_chapter_by_id_endpoint").isEmpty, "the chapter was fetched under another project")
    }

    // MARK: Voice design

    /// Saving marks the preview that was saved — not one chosen while the save was on its way,
    /// which could then never be saved (or the saved one saved twice).
    @Test func theSavedPreviewIsTheOneChosenWhenSaveWasPressed() async throws {
        let fixture = VoicesStudioFixture([
            "create_voice": [.init(status: 200, headers: ["content-type": "application/json"],
                                   body: Data(#"{"voice_id":"v9","name":"Nova"}"#.utf8), delay: Self.late)],
        ])
        defer { fixture.clean() }
        let model = VoiceDesignSectionModel(environment: fixture.environment)
        model.load(previews: [VoiceDesignPreview(generatedVoiceID: "g1"), VoiceDesignPreview(generatedVoiceID: "g2")], text: nil)
        model.chosenPreview = "g1"
        model.saveName = "Nova"
        let task = try await sending(model.actions, "create_voice") { await model.save() }
        model.chosenPreview = "g2"
        await task.value
        #expect(fixture.body("create_voice")?["generated_voice_id"] == "g1")
        #expect(model.savedPreviews == ["g1"])
    }

    // MARK: Audio Native

    /// A player's settings read late are kept with their project, never shown under another.
    @Test func settingsReadLateAreNeverShownUnderAnotherProject() async throws {
        let fixture = VoicesStudioFixture([
            "get_audio_native_project_settings_endpoint": [.json(VoicesStudioAudioNativeTests.settings)],
        ], late: ["an-slow": Self.late])
        defer { fixture.clean() }
        let model = AudioNativeSectionModel(environment: fixture.environment)
        model.load(snippet: nil, projectID: "an-slow", settings: nil)
        let task = try await sending(model.actions, "get_audio_native_project_settings_endpoint") { await model.loadSettings() }
        model.projectID = "an2"
        await task.value
        #expect(model.settings == nil, "another project's settings were shown under this one")
        model.projectID = "an-slow"
        #expect(model.settings != nil)
    }

    // MARK: Sharing

    /// A resource looked up late is not shown once another id was typed.
    @Test func aResourceLookedUpLateIsNotShownUnderAnotherId() async throws {
        let fixture = VoicesStudioFixture([
            "get_resource_metadata": [.json([
                "resource_id": "r-slow", "resource_name": "Narrator", "resource_type": "voice", "creator_user_id": "u1",
                "role_to_group_ids": ["admin": ["g1"]], "share_options": [],
            ])],
        ], late: ["r-slow": Self.late])
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        model.resourceType = "voice"
        model.resourceID = "r-slow"
        let task = try await sending(model.actions, "get_resource_metadata") { await model.loadResource() }
        model.resourceID = "r2"
        await task.value
        #expect(model.resource == nil, "another resource was shown under the id typed")
        model.resourceID = "r-slow"
        #expect(model.resource?.name == "Narrator")
    }

    // MARK: Pronunciation

    /// Rules added to one dictionary, answered after another was chosen, leave that one on screen.
    @Test func rulesAddedAfterAnotherDictionaryWasChosenLeaveThatOneOnScreen() async throws {
        let fixture = VoicesStudioFixture([
            "add_rules": [.json(["id": "d-slow", "version_id": "ver2"])],
            "get_pronunciation_dictionary_metadata": [.json(VoicesStudioPronunciationTests.dictionary("d2")),
                                                      .json(VoicesStudioPronunciationTests.dictionary("d-slow"))],
        ], late: ["d-slow": Self.late])
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        let slow = try #require(PronunciationDictionary(json: VoicesStudioPronunciationTests.dictionary("d-slow")))
        let other = try #require(PronunciationDictionary(json: VoicesStudioPronunciationTests.dictionary("d2")))
        model.load(dictionaries: [slow, other], selected: slow)
        var rule = PronunciationRule()
        rule.stringToReplace = "Nginx"
        rule.alias = "engine x"
        model.rules = [rule]
        let task = try await sending(model.actions, "add_rules") { await model.addRules() }
        await model.select("d2")
        await task.value
        #expect(model.selected?.id == "d2", "the dictionary just changed took the screen back")
    }

    // MARK: Voices

    /// A voice deleted after another was chosen leaves that one on screen.
    @Test func aDeleteFinishingAfterAnotherVoiceWasChosenLeavesThatVoiceOnScreen() async throws {
        let fixture = VoicesStudioFixture([
            "delete_voice": [.json(["status": "ok"])],
            "get_voice_by_id": [.json(VoicesStudioFakes.voice("v2", "Ben", settings: VoicesStudioFakes.settings))],
        ], late: ["v-slow": Self.late])
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let slow = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-slow", "Ada")))
        let other = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v2", "Ben")))
        model.load(rows: [slow, other], selected: slow)
        let task = try await sending(model.actions, "delete_voice") { await model.deleteSelected() }
        await model.select("v2")
        await task.value
        #expect(model.selected?.id == "v2", "deleting one voice cleared another from the screen")
        #expect(!model.rows.contains { $0.id == "v-slow" })
    }

    // MARK: Failed reads

    /// A detail that could not be read says why at the foot; a list that failed says so where
    /// the list is, and is not repeated at the foot.
    @Test func aFailedDetailReadSaysWhyAndIsClearedByTheNextRead() async throws {
        let fixture = VoicesStudioFixture([
            "get_pronunciation_dictionaries_metadata": [.jsonText(#"{"detail":"try later"}"#, status: 503)],
            "get_pronunciation_dictionary_metadata": [.jsonText(#"{"detail":"not found"}"#, status: 404),
                                                      .json(VoicesStudioPronunciationTests.dictionary("d1"))],
        ])
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        await model.refresh()
        #expect(model.listProblem != nil)
        #expect(model.actions.readProblems().isEmpty, "a list's failure was repeated at the foot")

        let dictionary = try #require(PronunciationDictionary(json: VoicesStudioPronunciationTests.dictionary("d1")))
        model.load(dictionaries: [dictionary])
        await model.select("d1")
        let problems = model.actions.readProblems()
        #expect(problems.map(\.operationID) == ["get_pronunciation_dictionary_metadata"])
        #expect(problems.first?.text.contains("could not be read") == true)
        await model.select("d1")
        #expect(model.actions.readProblems().isEmpty)
    }
}
