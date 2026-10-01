import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Answers that arrive after the screen moved on. In each test the fake answers one chosen id
/// late; meanwhile the owner picks something else, and the late answer must land with its own
/// item — never on the one now chosen, never taking the screen back, never marking the wrong
/// thing done.
@Suite("ElevenLabs voices and studio sections: late answers", .timeLimit(.minutes(3)))
@MainActor
struct VoicesStudioLateAnswerTests {

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
        ], held: ["sa-slow"])
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let slow = try #require(ServiceAccount(json: Self.account("sa-slow", key: "k1")))
        let other = try #require(ServiceAccount(json: Self.account("sa2", key: "k2")))
        model.load(accounts: [slow, other], selected: slow)
        // Each account's keys are read on a runner of their own: wait for the request itself.
        let task = Task { await model.refreshKeys() }
        try await voicesStudioWait { fixture.sent("get_service_account_api_keys_route").count == 1 }
        model.select("sa2")
        fixture.release()
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
        ], held: ["o-slow"])
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        let slow = try #require(ProductionsOrder(json: VoicesStudioProductionsTests.order("o-slow")))
        let other = try #require(ProductionsOrder(json: VoicesStudioProductionsTests.order("o2")))
        model.load(orders: [slow, other], selected: slow)
        model.rename = "Renamed"
        let task = try await sending(model.actions, "public_update_order") { await model.saveName() }
        await model.select("o2")
        fixture.release()
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
        ], held: ["d-slow"])
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        let slow = try #require(DubbingDub(json: VoicesStudioDubbingTests.dub("d-slow")))
        let other = try #require(DubbingDub(json: VoicesStudioDubbingTests.dub("d2")))
        model.load(dubs: [slow, other], selected: slow)
        model.downloadLanguage = "es"
        let task = try await sending(model.actions, "get_dubbed_file") { await model.download() }
        await model.selectDub("d2")
        fixture.release()
        await task.value
        #expect(model.selectedDub?.id == "d2")
        #expect(model.downloaded("d2", "es") == nil, "another dub's file was offered as this one's")
        #expect(model.downloaded("d-slow", "es")?.isVideo == true)
    }

    // MARK: Webhooks

    nonisolated static func webhook(_ id: String) -> JSONValue {
        ["name": .string("Hook \(id)"), "webhook_id": .string(id), "webhook_url": "https://example.com/hook",
         "is_disabled": false, "is_auto_disabled": false, "created_at_unix": 1, "auth_type": "hmac", "events": ["flows"]]
    }

    /// A save that finishes after another webhook's editor was opened leaves that editor open.
    /// The save's answer is held until the other editor is open — on a signal, not a delay.
    @Test func aSaveFinishingAfterAnotherEditorOpenedLeavesThatEditorOpen() async throws {
        let signals = VoicesStudioFollowupTests.Signals()
        let list: JSONValue = ["webhooks": [Self.webhook("w-slow"), Self.webhook("w2")]]
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_workspace_webhook_route":
                try await signals.wait(for: "other editor open")
                return .json(["status": "ok"])
            case "get_workspace_webhooks_route":
                return .json(list)
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
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
        signals.note("other editor open")
        await task.value
        #expect(model.editing?.id == "w2", "saving one webhook closed another's editor")
        #expect(model.draft.name == "Hook w2")
    }

    /// The other way round: Edit pressed on another webhook while a save is on its way, and the
    /// save (with the list it fetches again) answers while Edit's own read is still coming. The
    /// list's read must not abandon Edit's: the other editor opens. (The fake holds Edit's read
    /// until the save's list has been answered.)
    @Test func aListReadAfterASaveDoesNotAbandonAnEditBeingOpened() async throws {
        let signals = VoicesStudioFollowupTests.Signals()
        let list: JSONValue = ["webhooks": [Self.webhook("w-slow"), Self.webhook("w2")]]
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_workspace_webhook_route":
                try await signals.wait(for: "edit asked")
                return .json(["status": "ok"])
            case "get_workspace_webhooks_route":
                if signals.note("list") == 1 {
                    signals.note("edit asked")
                    try await signals.wait(for: "listed after the save")
                } else {
                    signals.note("listed after the save")
                }
                return .json(list)
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = WebhooksSectionModel(environment: fixture.environment)
        let slow = try #require(WorkspaceWebhook(json: Self.webhook("w-slow")))
        let other = try #require(WorkspaceWebhook(json: Self.webhook("w2")))
        model.load(webhooks: [slow, other])
        model.edit(slow, eventsKnown: true)
        model.draft.name = "Renamed"
        let saving = try await sending(model.actions, "edit_workspace_webhook_route") { await model.save() }
        await model.startEditing(other)
        await saving.value
        #expect(fixture.sent("get_workspace_webhooks_route").count == 2)
        #expect(model.editing?.id == "w2", "the other webhook's editor did not open")
        #expect(model.draft.name == "Hook w2")
        #expect(model.problems.isEmpty, "\(model.problems)")
    }

    /// Webhook A renamed and saved; Edit pressed on B while the save is on its way, B's read
    /// answering only after the save's own list refresh. B's editor opens, and A's row keeps the
    /// saved name — the older list from B's read does not replace the newer one.
    @Test func anEditReadOlderThanASavesRefreshDoesNotPutTheOldListBack() async throws {
        let signals = VoicesStudioFollowupTests.Signals()
        func list(_ aName: String) -> JSONValue {
            var a = Self.webhook("w-a")
            if case .object(var fields) = a { fields["name"] = .string(aName); a = .object(fields) }
            return ["webhooks": [a, Self.webhook("w2")]]
        }
        let old = list("Hook w-a"), new = list("A renamed")
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_workspace_webhook_route":
                try await signals.wait(for: "edit asked")
                return .json(["status": "ok"])
            case "get_workspace_webhooks_route":
                if signals.note("list") == 1 {                     // Edit on w2
                    signals.note("edit asked")
                    try await signals.wait(for: "refreshed")
                    return .json(old)
                }
                signals.note("refreshed")                           // the save's refresh
                return .json(new)
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = WebhooksSectionModel(environment: fixture.environment)
        let a = try #require(WorkspaceWebhook(json: Self.webhook("w-a")))
        let other = try #require(WorkspaceWebhook(json: Self.webhook("w2")))
        model.load(webhooks: [a, other])
        model.edit(a, eventsKnown: true)
        model.draft.name = "A renamed"
        let saving = try await sending(model.actions, "edit_workspace_webhook_route") { await model.save() }
        await model.startEditing(other)
        await saving.value
        #expect(model.editing?.id == "w2")
        #expect(model.webhooks.first { $0.id == "w-a" }?.name == "A renamed", "the older list put A's old name back")
    }

    // MARK: Studio

    /// A chapter saved after another project was opened is not reopened under that project.
    @Test func aChapterSavedAfterAnotherProjectOpenedIsNotReopenedUnderIt() async throws {
        let fixture = VoicesStudioFixture([
            "edit_chapter": [.json(["chapter": VoicesStudioStudioTests.chapter("c-slow", name: "Renamed")])],
            "get_project_by_id": [.json(VoicesStudioStudioTests.project("p2"))],
        ], held: ["c-slow"])
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let first = try #require(StudioProject(json: VoicesStudioStudioTests.project("p1")))
        let second = try #require(StudioProject(json: VoicesStudioStudioTests.project("p2")))
        let chapter = try #require(StudioChapter(json: VoicesStudioStudioTests.chapter("c-slow", name: "One")))
        model.load(projects: [first, second], selected: first, chapter: chapter)
        model.chapterName = "Renamed"
        let task = try await sending(model.actions, "edit_chapter") { await model.saveChapter() }
        await model.select("p2")
        fixture.release()
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
                                   body: Data(#"{"voice_id":"v9","name":"Nova"}"#.utf8))],
        ], held: ["/v1/text-to-voice"])
        defer { fixture.clean() }
        let model = VoiceDesignSectionModel(environment: fixture.environment)
        model.load(previews: [VoiceDesignPreview(generatedVoiceID: "g1"), VoiceDesignPreview(generatedVoiceID: "g2")], text: nil)
        model.chosenPreview = "g1"
        model.saveName = "Nova"
        let task = try await sending(model.actions, "create_voice") { await model.save() }
        model.chosenPreview = "g2"
        fixture.release()
        await task.value
        #expect(fixture.body("create_voice")?["generated_voice_id"] == "g1")
        #expect(model.savedPreviews == ["g1"])
    }

    // MARK: Audio Native

    /// A player's settings read late are kept with their project, never shown under another.
    @Test func settingsReadLateAreNeverShownUnderAnotherProject() async throws {
        let fixture = VoicesStudioFixture([
            "get_audio_native_project_settings_endpoint": [.json(VoicesStudioAudioNativeTests.settings)],
        ], held: ["an-slow"])
        defer { fixture.clean() }
        let model = AudioNativeSectionModel(environment: fixture.environment)
        model.load(snippet: nil, projectID: "an-slow", settings: nil)
        let task = try await sending(model.actions, "get_audio_native_project_settings_endpoint") { await model.loadSettings() }
        model.projectID = "an2"
        fixture.release()
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
        ], held: ["r-slow"])
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        model.resourceType = "voice"
        model.resourceID = "r-slow"
        let task = try await sending(model.actions, "get_resource_metadata") { await model.loadResource() }
        model.resourceID = "r2"
        fixture.release()
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
        ], held: ["d-slow"])
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
        var typed = PronunciationRule()
        typed.stringToReplace = "SQL"
        typed.alias = "sequel"
        model.rules = [typed]
        fixture.release()
        await task.value
        #expect(model.selected?.id == "d2", "the dictionary just changed took the screen back")
        #expect(model.rules.map(\.stringToReplace) == ["SQL"], "d2's rules being typed were cleared")
    }

    // MARK: Voices

    /// A voice deleted after another was chosen leaves that one on screen.
    @Test func aDeleteFinishingAfterAnotherVoiceWasChosenLeavesThatVoiceOnScreen() async throws {
        let fixture = VoicesStudioFixture([
            "delete_voice": [.json(["status": "ok"])],
            "get_voice_by_id": [.json(VoicesStudioFakes.voice("v2", "Ben", settings: VoicesStudioFakes.settings))],
        ], held: ["v-slow"])
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let slow = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-slow", "Ada")))
        let other = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v2", "Ben")))
        model.load(rows: [slow, other], selected: slow)
        let task = try await sending(model.actions, "delete_voice") { await model.deleteSelected() }
        await model.select("v2")
        fixture.release()
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

    // MARK: Round 3 — the critic's probes, and the sweep they led to

    nonisolated static func template(_ id: String) -> JSONValue {
        ["id": .string(id), "name": .string("Template \(id)"),
         "versions": [["version_id": "v1", "is_latest": true, "inputs": [], "outputs": []]]]
    }

    /// L1: a paid template run that answers after another template was opened is kept with its
    /// own template — not listed under the one open, not lost — and a notice says where it went.
    ///
    /// The run's answer is held until the other template is open — on a signal, not a delay, so
    /// a busy main actor cannot make the answer arrive first.
    @Test func aTemplateRunAnsweredAfterAnotherTemplateOpenedStaysWithItsTemplate() async throws {
        let signals = VoicesStudioFollowupTests.Signals()
        let template = Self.template
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "create_public_template_run":
                try await signals.wait(for: "other template open")
                return .json(["id": "run-of-slow", "status": "pending", "version_id": "v1"])
            case "get_public_template":
                return .json(template(signals.note("get") == 1 ? "tmpl-two" : "tmpl-slow"))
            case "list_public_template_runs" where signals.note("list") == 1:
                return .json(["runs": []])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = FlowsSectionModel(environment: fixture.environment)
        let slow = try #require(FlowsTemplate(json: Self.template("tmpl-slow")))
        let two = try #require(FlowsTemplate(json: Self.template("tmpl-two")))
        model.load(templates: [slow, two], open: slow)
        let task = try await sending(model.actions, "create_public_template_run") { await model.run() }
        await model.open("tmpl-two")
        signals.note("other template open")
        await task.value
        #expect(model.template?.id == "tmpl-two")
        #expect(model.runs.isEmpty, "the run started for tmpl-slow is listed under tmpl-two: \(model.runs.map(\.id))")
        #expect(model.runNotice?.templateID == "tmpl-slow")
        #expect(model.runNotice?.text == "Run started for “Template tmpl-slow”: pending. It is listed under “Template tmpl-slow”.")
        // Back on its template, the run is there even though listing the runs now fails.
        await model.open("tmpl-slow")
        #expect(model.runs.map(\.id) == ["run-of-slow"])
        #expect(model.runNotice == nil)
    }

    static func professional(_ id: String) -> JSONValue {
        VoicesStudioFakes.voice(id, "Voice \(id)", category: "professional")
    }

    /// L2: the text to read aloud for one voice's verification, answered after another voice
    /// was chosen, is not shown under that voice (reading it for the wrong voice would be a
    /// failed verification attempt).
    @Test func verificationTextReadLateIsNotShownUnderAnotherVoice() async throws {
        let fixture = VoicesStudioFixture([
            "get_pvc_voice_captcha": [.json(["text": "Read this for voice-slow"])],
            "get_voice_by_id": [.json(Self.professional("voice-two"))],
        ], held: ["voice-slow/captcha"])
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let slow = try #require(VoicesVoice(json: Self.professional("voice-slow")))
        let two = try #require(VoicesVoice(json: Self.professional("voice-two")))
        model.load(rows: [slow, two], selected: slow)
        let task = try await sending(model.actions, "get_pvc_voice_captcha") { await model.loadCaptcha() }
        await model.select("voice-two")
        fixture.release()
        await task.value
        #expect(model.selected?.id == "voice-two")
        #expect(model.captcha == nil, "voice-slow's verification text is shown under voice-two")
    }

    /// L3: an edit of one voice that finishes after another was chosen and typed into refetches
    /// the edited voice only — the other's unsaved typing stays.
    @Test func aVoiceEditFinishingAfterAnotherVoiceWasChosenKeepsThatVoicesTyping() async throws {
        let fixture = VoicesStudioFixture([
            "edit_voice": [.json(["status": "ok"])],
            "get_voice_by_id": [.json(VoicesStudioFakes.voice("voice-two", "Two")),
                                .json(VoicesStudioFakes.voice("voice-slow", "Slow renamed"))],
        ], held: ["voice-slow/edit"])
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let slow = try #require(VoicesVoice(json: VoicesStudioFakes.voice("voice-slow", "Slow")))
        let two = try #require(VoicesVoice(json: VoicesStudioFakes.voice("voice-two", "Two")))
        model.load(rows: [slow, two], selected: slow)
        model.editDraft.name = "Slow renamed"
        let task = try await sending(model.actions, "edit_voice") { await model.saveEdit() }
        await model.select("voice-two")
        model.editDraft.description = "typed for voice-two, not saved yet"
        fixture.release()
        await task.value
        #expect(model.selected?.id == "voice-two")
        #expect(model.editDraft.description == "typed for voice-two, not saved yet",
                "voice-two's unsaved edit was replaced: “\(model.editDraft.description)”")
        #expect(fixture.sent("get_voice_by_id").last?.request.url.path.hasSuffix("/voice-slow") == true)
        #expect(model.rows.first { $0.id == "voice-slow" }?.name == "Slow renamed")
    }

    /// L3: a source-transcript save of one dubbing project that finishes after another was
    /// opened and edited leaves that project's unsaved edits alone.
    @Test func aSourceSaveFinishingAfterAnotherProjectOpenedKeepsItsEdits() async throws {
        let segment: JSONValue = ["id": "s9", "speaker_id": "speaker_1", "start_s": 0, "end_s": 2, "text": "Hello two"]
        let fixture = VoicesStudioFixture([
            "dubbing_transcript_segment_update": [.json(["status": "ok"])],
            "dubbing_project_get": [.json(["project_id": "p-two", "status": "ready", "language_ids": []])],
            "dubbing_language_list": [.json(["languages": []])],
            "dubbing_transcript_get": [.json(["segments": [segment]])],
        ], held: ["p-slow/transcript"])
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        let slow = try #require(DubbingProject(json: ["project_id": "p-slow", "status": "ready", "language_ids": []]))
        let two = try #require(DubbingProject(json: ["project_id": "p-two", "status": "ready", "language_ids": []]))
        let first = try #require(DubbingSegment(json: ["id": "s1", "speaker_id": "speaker_1", "start_s": 0, "end_s": 2,
                                                       "text": "Hello slow"]))
        model.load(projects: [slow, two], selected: slow, source: [first])
        model.sourceEdits["s1"] = "Hello slow, edited"
        let task = try await sending(model.actions, "dubbing_transcript_segment_update") { await model.saveSourceEdits() }
        await model.selectProject("p-two")
        await model.loadSourceTranscript()
        model.sourceEdits["s9"] = "typed for p-two, not saved yet"
        fixture.release()
        await task.value
        #expect(model.selectedProject?.id == "p-two")
        #expect(model.sourceEdits == ["s9": "typed for p-two, not saved yet"],
                "p-two's unsaved transcript edits were dropped: \(model.sourceEdits)")
        #expect(fixture.sent("dubbing_transcript_get").count == 1)
    }

    /// L3: a Studio project's settings saved after another project was opened refetch the saved
    /// project only; the open project's settings form keeps what the owner typed.
    @Test func aProjectSaveFinishingAfterAnotherOpenedKeepsThatProjectsForm() async throws {
        let fixture = VoicesStudioFixture([
            "edit_project": [.json(["project": VoicesStudioStudioTests.project("p-slow", name: "Renamed")])],
            "get_project_by_id": [.json(VoicesStudioStudioTests.project("p2", name: "Second")),
                                  .json(VoicesStudioStudioTests.project("p-slow", name: "Renamed"))],
        ], held: ["p-slow"])
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let slow = try #require(StudioProject(json: VoicesStudioStudioTests.project("p-slow", name: "First")))
        let second = try #require(StudioProject(json: VoicesStudioStudioTests.project("p2", name: "Second")))
        model.load(projects: [slow, second], selected: slow)
        model.editDraft.name = "Renamed"
        let task = try await sending(model.actions, "edit_project") { await model.saveEdit() }
        await model.select("p2")
        model.editDraft.author = "typed for p2"
        fixture.release()
        await task.value
        #expect(model.selected?.id == "p2")
        #expect(model.editDraft.author == "typed for p2", "p2's settings form was reset: “\(model.editDraft.author)”")
        #expect(model.projects.first { $0.id == "p-slow" }?.name == "Renamed")
    }

    /// L3: replacing one project's content, finished after another was opened, leaves the
    /// content fields the owner is filling for that other project.
    @Test func aContentReplaceFinishingAfterAnotherProjectOpenedKeepsItsFields() async throws {
        let fixture = VoicesStudioFixture([
            "edit_project_content": [.json(["project": VoicesStudioStudioTests.project("p-slow")])],
            "get_project_by_id": [.json(VoicesStudioStudioTests.project("p2")),
                                  .json(VoicesStudioStudioTests.project("p-slow"))],
        ], held: ["p-slow/content"])
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let slow = try #require(StudioProject(json: VoicesStudioStudioTests.project("p-slow")))
        let second = try #require(StudioProject(json: VoicesStudioStudioTests.project("p2")))
        model.load(projects: [slow, second], selected: slow)
        model.contentURL = "https://example.com/for-slow"
        let task = try await sending(model.actions, "edit_project_content") { await model.updateContent() }
        await model.select("p2")
        model.contentURL = "https://example.com/typed-for-p2"
        fixture.release()
        await task.value
        #expect(model.contentURL == "https://example.com/typed-for-p2")
    }

    /// Media registered for one order, answered after another was opened, stays with its order:
    /// it is not added to the other order's item, and that order's media form is left alone.
    @Test func mediaRegisteredLateStaysWithItsOrder() async throws {
        let fixture = VoicesStudioFixture([
            "public_register_media": [.json(["media_id": "m-slow"])],
            "public_get_order": [.json(VoicesStudioProductionsTests.order("o2"))],
            "public_get_media_info": [.json(["media_id": "m-slow", "name": "clip.mp4", "content_type": "video/mp4"])],
        ], held: ["o-slow"])
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        let slow = try #require(ProductionsOrder(json: VoicesStudioProductionsTests.order("o-slow")))
        let other = try #require(ProductionsOrder(json: VoicesStudioProductionsTests.order("o2")))
        model.load(orders: [slow, other], selected: slow)
        model.mediaLanguage = "en"
        model.mediaURL = "https://example.com/clip.mp4"
        model.mediaURLType = "video/mp4"
        model.mediaURLName = "clip.mp4"
        let task = try await sending(model.actions, "public_register_media") { await model.registerMedia() }
        await model.select("o2")
        model.mediaURL = "https://example.com/typed-for-o2"
        fixture.release()
        await task.value
        #expect(model.selected?.id == "o2")
        #expect(model.item.mediaIDs.isEmpty, "o-slow's media was put in o2's item")
        #expect(model.mediaURL == "https://example.com/typed-for-o2")
        #expect(model.media["o-slow"]?.map(\.id) == ["m-slow"])
        #expect(fixture.path("public_get_media_info")?.contains("o-slow") == true)
    }

    /// The order clicked shows as loading, then its failure with a way to try again — never
    /// the previous order in its place.
    @Test func anOrderWhoseReadFailsSaysSoInItsPlaceAndCanBeRetried() async throws {
        let one: JSONValue = ["order_id": "o-one", "name": "One", "state": "open", "sandbox": false, "items": []]
        let two: JSONValue = ["order_id": "o-two", "name": "Two", "state": "open", "sandbox": false, "items": []]
        let fixture = VoicesStudioFixture([
            "public_get_order": [.jsonText(#"{"detail":"not found"}"#, status: 404), .json(two)],
            "public_get_available_languages": [.json(["languages": []]), .json(["languages": []])],
        ])
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        let first = try #require(ProductionsOrder(json: one))
        model.load(orders: [first, try #require(ProductionsOrder(json: two))], selected: first)
        await model.select("o-two")
        #expect(model.selected == nil, "order o-one was left on screen for o-two")
        #expect(model.wantedOrder == "o-two")
        #expect(model.orderProblem?.contains("404") == true)
        #expect(model.actions.readProblems().isEmpty, "said in place, not again at the foot")
        await model.select("o-two")
        #expect(model.selected?.id == "o-two")
        #expect(model.orderProblem == nil)
    }

    /// Key on/off acts on the key's own account and names it — a stale row of account A pressed
    /// after B was selected does not send B's id with A's key.
    @Test func keyOffActsOnTheKeysOwnAccount() async throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let a = try #require(ServiceAccount(json: Self.account("sa-a", key: "key-a")))
        let b = try #require(ServiceAccount(json: Self.account("sa-b", key: "key-b")))
        model.load(accounts: [a, b], selected: a)
        let keyOfA = try #require(model.selected?.keys.first)
        model.select("sa-b")
        let task = Task { await model.setEnabled(keyOfA, false) }
        try await voicesStudioWait { model.actions.presentedQuestion != nil }
        let sent = model.actions.runner("edit_service_account_api_key")?.arguments["service_account_user_id"]
        let asked = model.actions.presentedQuestion?.title ?? ""
        model.actions.answer(false)
        await task.value
        #expect(sent == "sa-a")
        #expect(asked == "Turn off the API key “Key key-a” of “Account sa-a”?")
        #expect(fixture.transport.recorded.isEmpty)
    }

    /// A spending call that asks, answered after the account changed, sends nothing — and that
    /// is a known outcome: nothing holds the next spending call behind "I have checked".
    @Test func aSubmitAnsweredAfterTheAccountChangedIsAKnownOutcome() async throws {
        let quoted = VoicesStudioProductionsTests.order("o1", total: 310, items: [VoicesStudioProductionsTests.dubItem])
        let one = VoicesStudioFixture(["public_get_order": [.json(quoted)]])
        let two = VoicesStudioFixture(["public_submit_order": [.json(["status": "ok"])]])
        defer { one.clean(); two.clean() }
        let current = VoicesStudioSwitchableClient(one.client)
        let environment = VoicesStudioEnvironment(context: .init(client: { current.client }), voices: one.voices)
        let model = ProductionsSectionModel(environment: environment)
        model.load(orders: [], selected: try #require(ProductionsOrder(json: quoted)))
        let task = Task { await model.submit() }
        try await voicesStudioWait { model.actions.presentedQuestion != nil }
        current.client = two.client
        model.actions.answer(true)
        await task.value
        #expect(one.sent("public_submit_order").isEmpty && two.transport.recorded.isEmpty)
        let runner = try #require(model.actions.runner("public_submit_order"))
        #expect(runner.failure == .accountChanged)
        #expect(model.actions.unknownOutcomes.isEmpty)
        #expect(model.actions.blockReason(runner) == nil, "a refusal before sending held the next spending call")
    }
}
