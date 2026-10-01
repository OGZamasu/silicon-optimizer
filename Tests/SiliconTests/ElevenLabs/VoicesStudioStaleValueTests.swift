import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// The follow-ups critic's R1: two ways a stale value could still be saved onto an item.
///
/// (a) A details read asked before a change answered lands after the change's own fetch — on
///     another runner, so nothing abandons it — and its older values took the screen and the
///     form; the next Save then wrote them back.
/// (b) Save pressed before the open item's details arrived sent the list row's values for every
///     field the owner had not touched.
///
/// Every answer that must come late is held on a signal, never on a delay.
@Suite("ElevenLabs voices & studio — stale values", .timeLimit(.minutes(3)))
@MainActor
struct VoicesStudioStaleValueTests {
    typealias Signals = VoicesStudioFollowupTests.Signals

    func body(_ fixture: VoicesStudioFixture, _ operationID: String) -> String {
        fixture.sent(operationID).last.map { String(decoding: $0.body, as: UTF8.self) } ?? ""
    }

    @MainActor final class Done { var value = false }

    /// Runs `action`, declining any question it puts up, so a regression that asks fails the
    /// test instead of waiting for an answer for ever.
    func declining(_ actions: VoicesStudioActions, _ action: @escaping @MainActor () async -> Void) async throws {
        try await answering(actions, yes: false, action)
    }

    /// Runs `action`, answering any question it puts up with `yes`, until it returns.
    func answering(_ actions: VoicesStudioActions, yes: Bool = true, _ action: @escaping @MainActor () async -> Void) async throws {
        let done = Done()
        let task = Task { await action(); done.value = true }
        try await voicesStudioWait {
            if actions.presentedQuestion != nil { actions.answer(yes) }
            return done.value
        }
        await task.value
    }

    // MARK: - (a) a read asked before a change, answering after it

    /// "Try again" on voice A is slow; meanwhile A is renamed and saved, and the save's own fetch
    /// lands. Then the older read answers: it is dropped — the form, the selection and the row
    /// keep the new name, and the next Save sends it.
    @Test func aVoiceReadAskedBeforeASaveIsDroppedWhenItAnswersAfter() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_voice":
                return .json(["status": "ok"])
            case "get_voice_by_id":
                if signals.note("get") == 1 {
                    try await signals.wait(for: "saved")
                    return .json(VoicesStudioFakes.voice("v-a", "Voice A"))            // as before the save
                }
                return .json(VoicesStudioFakes.voice("v-a", "Voice A renamed"))       // after it
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let a = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-a", "Voice A")))
        model.load(rows: [a], selected: a)
        let tryingAgain = Task { await model.reloadSelected() }
        try await voicesStudioWait { fixture.sent("get_voice_by_id").count == 1 }
        model.editDraft.name = "Voice A renamed"
        await model.saveEdit()
        #expect(fixture.sent("get_voice_by_id").count == 2, "the save's own fetch")
        signals.note("saved")
        await tryingAgain.value
        #expect(model.editDraft.name == "Voice A renamed", "the older read put the old name back in the form")
        #expect(model.selected?.name == "Voice A renamed")
        #expect(model.rows.first?.name == "Voice A renamed")
        model.editDraft.labels = "accent: irish"
        await model.saveEdit()
        #expect(fixture.sent("edit_voice").count == 2)
        #expect(body(fixture, "edit_voice").contains("Voice A renamed"), "the next Save wrote the old name back")
    }

    /// The same for the sliders: a slow read of voice A, then its settings saved (stability 0.9);
    /// the older read answers last and is dropped.
    @Test func aSettingsReadAskedBeforeASaveIsDroppedWhenItAnswersAfter() async throws {
        let signals = Signals()
        let saved: JSONValue = ["stability": 0.9, "similarity_boost": 0.8, "style": 0.1, "speed": 1.05, "use_speaker_boost": true]
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_voice_settings":
                return .json(["status": "ok"])
            case "get_voice_by_id":
                if signals.note("get") == 1 {
                    try await signals.wait(for: "saved")
                    return .json(VoicesStudioFakes.voice("v-a", "Voice A", settings: VoicesStudioFakes.settings))
                }
                return .json(VoicesStudioFakes.voice("v-a", "Voice A", settings: saved))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let a = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-a", "Voice A", settings: VoicesStudioFakes.settings)))
        model.load(rows: [a], selected: a)
        let tryingAgain = Task { await model.reloadSelected() }
        try await voicesStudioWait { fixture.sent("get_voice_by_id").count == 1 }
        model.settingsDraft?.stability = 0.9
        await model.saveSettings()
        #expect(fixture.sent("edit_voice_settings").count == 1)
        signals.note("saved")
        await tryingAgain.value
        #expect(model.settingsDraft?.stability == 0.9, "the older read moved the saved slider back")
        #expect(model.selected?.settings?.stability == 0.9)
    }

    /// Studio: a slow read of project A, then its settings renamed and saved; the older read
    /// answers last and is dropped.
    @Test func aProjectReadAskedBeforeASaveIsDroppedWhenItAnswersAfter() async throws {
        let signals = Signals()
        let renamed = VoicesStudioStudioTests.project("p-a", name: "Renamed")
        let first = VoicesStudioStudioTests.project("p-a", name: "First")
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_project":
                return .json(["project": renamed])
            case "get_project_by_id":
                if signals.note("get") == 1 {
                    try await signals.wait(for: "saved")
                    return .json(first)
                }
                return .json(renamed)
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let project = try #require(StudioProject(json: first))
        model.load(projects: [project], selected: project)
        let tryingAgain = Task { await model.reloadSelected() }
        try await voicesStudioWait { fixture.sent("get_project_by_id").count == 1 }
        model.editDraft.name = "Renamed"
        await model.saveEdit()
        signals.note("saved")
        await tryingAgain.value
        #expect(model.editDraft.name == "Renamed", "the older read put the old name back in the form")
        #expect(model.selected?.name == "Renamed")
        #expect(model.projects.first?.name == "Renamed")
    }

    /// Productions: a slow read of order A, then A renamed; the older read answers last and is
    /// dropped — the name field keeps the new name.
    @Test func anOrderReadAskedBeforeARenameIsDroppedWhenItAnswersAfter() async throws {
        let signals = Signals()
        let order = Self.order
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "public_update_order":
                return .json(["order_id": "o-a"])
            case "public_get_order":
                if signals.note("get") == 1 {
                    try await signals.wait(for: "saved")
                    return .json(order("Old name"))
                }
                return .json(order("New name"))
            case "public_get_available_languages":
                return .json(["languages": []])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        let open = try #require(ProductionsOrder(json: order("Old name")))
        model.load(orders: [open], selected: open)
        let reading = Task { await model.select("o-a") }
        try await voicesStudioWait { fixture.sent("public_get_order").count == 1 }
        model.rename = "New name"
        await model.saveName()
        signals.note("saved")
        await reading.value
        #expect(model.rename == "New name", "the older read put the old name back in the field")
        #expect(model.selected?.name == "New name")
    }

    nonisolated static func order(_ name: String) -> JSONValue {
        ["order_id": "o-a", "name": .string(name), "state": "open", "sandbox": false, "items": []]
    }

    /// Pronunciation: a slow read of dictionary A, then A renamed; the older read is dropped.
    @Test func aDictionaryReadAskedBeforeARenameIsDroppedWhenItAnswersAfter() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "patch_pronunciation_dictionary":
                return .json(["id": "d-a"])
            case "get_pronunciation_dictionary_metadata":
                if signals.note("get") == 1 {
                    try await signals.wait(for: "saved")
                    return .json(VoicesStudioFollowupTests.dictionary("d-a", name: "Old name"))
                }
                return .json(VoicesStudioFollowupTests.dictionary("d-a", name: "New name"))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        let a = try #require(PronunciationDictionary(json: VoicesStudioFollowupTests.dictionary("d-a", name: "Old name")))
        model.load(dictionaries: [a], selected: a)
        let reading = Task { await model.select("d-a") }
        try await voicesStudioWait { fixture.sent("get_pronunciation_dictionary_metadata").count == 1 }
        model.rename = "New name"
        await model.saveName()
        signals.note("saved")
        await reading.value
        #expect(model.rename == "New name", "the older read put the old name back in the field")
        #expect(model.selected?.name == "New name")
    }

    // MARK: - (b) Save before the open item's details are in

    /// Voice A opened, its details slow: the forms hold the list row's values, so none of them
    /// can be saved yet — nothing is sent, and the screen says why. Once the details are in, the
    /// typed name stays and the description is ElevenLabs' (changed on the website), not the
    /// row's older one; that is what Save then sends.
    @Test func nothingIsSavedFromAVoiceBeforeItsDetailsArrive() async throws {
        let signals = Signals()
        var server = VoicesStudioFakes.voice("v-a", "Voice A", settings: VoicesStudioFakes.settings)
        if case .object(var fields) = server {
            fields["description"] = "Changed on the website"
            server = .object(fields)
        }
        let fresh = server
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_voice", "edit_voice_settings":
                return .json(["status": "ok"])
            case "get_voice_by_id":
                if signals.note("get") == 1 { try await signals.wait(for: "tried") }
                return .json(fresh)
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let row = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-a", "Voice A", settings: VoicesStudioFakes.settings)))
        model.load(rows: [row])
        let opening = Task { await model.select("v-a") }
        try await voicesStudioWait { fixture.sent("get_voice_by_id").count == 1 }
        #expect(!model.detailsAreIn)
        #expect(model.waitingForDetails == "Waiting for this voice's details.")
        model.editDraft.name = "Voice A renamed"
        model.settingsDraft?.stability = 0.9
        await model.saveEdit()
        await model.saveSettings()
        #expect(fixture.sent("edit_voice").isEmpty && fixture.sent("edit_voice_settings").isEmpty,
                "a save went out with the list row's values")
        signals.note("tried")
        await opening.value
        #expect(model.detailsAreIn && model.waitingForDetails == nil)
        #expect(model.editDraft.name == "Voice A renamed", "the typing stays")
        #expect(model.editDraft.description == "Changed on the website")
        #expect(model.settingsDraft?.stability == 0.9)
        await model.saveEdit()
        let sent = body(fixture, "edit_voice")
        #expect(sent.contains("Changed on the website") && !sent.contains("Voice A, for tests."),
                "the row's older description was sent")
    }

    /// A professional voice's details: the same — Save details waits for them.
    @Test func aProfessionalVoicesDetailsAreNotSavedBeforeTheyArrive() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_pvc_voice":
                return .json(["voice_id": "v-p"])
            case "get_voice_by_id":
                if signals.note("get") == 1 { try await signals.wait(for: "tried") }
                return .json(VoicesStudioFakes.voice("v-p", "Pro", category: "professional", labels: ["accent": "irish"]))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let row = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-p", "Pro", category: "professional")))
        model.load(rows: [row])
        let opening = Task { await model.select("v-p") }
        try await voicesStudioWait { fixture.sent("get_voice_by_id").count == 1 }
        model.professional.name = "Pro renamed"
        await model.editProfessional()
        #expect(fixture.sent("edit_pvc_voice").isEmpty, "the row's labels went out")
        signals.note("tried")
        await opening.value
        await model.editProfessional()
        let sent = body(fixture, "edit_pvc_voice")
        #expect(sent.contains("Pro renamed") && sent.contains("irish"))
    }

    /// Studio: project A opened, its details slow — its settings and dictionaries cannot be saved
    /// yet (a dictionary switch sends every attached dictionary, and the row has none listed).
    @Test func nothingIsSavedFromAProjectBeforeItsDetailsArrive() async throws {
        let signals = Signals()
        var server = VoicesStudioStudioTests.project("p-a", name: "First")
        if case .object(var fields) = server {
            fields["author"] = "Changed on the website"
            fields["pronunciation_dictionary_locators"] = [["pronunciation_dictionary_id": "d-kept", "version_id": "v1"]]
            server = .object(fields)
        }
        let fresh = server
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_project":
                return .json(["project": fresh])
            case "update_pronunciation_dictionaries":
                return .json(["status": "ok"])
            case "get_project_by_id":
                if signals.note("get") == 1 { try await signals.wait(for: "tried") }
                return .json(fresh)
            case "get_project_snapshots":
                return .json(["snapshots": []])
            case "get_project_muted_tracks_endpoint":
                return .json(["chapter_ids": []])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let row = try #require(StudioProject(json: VoicesStudioStudioTests.project("p-a", name: "First")))
        let added = StudioDictionary(id: "d-new", name: "New", latestVersionID: "v1")
        model.load(projects: [row], dictionaries: [added])
        let opening = Task { await model.select("p-a") }
        try await voicesStudioWait { fixture.sent("get_project_by_id").count == 1 }
        #expect(!model.detailsAreIn)
        model.editDraft.name = "Renamed"
        await model.saveEdit()
        try await declining(model.actions) { await model.setDictionary(added, attached: true) }
        #expect(fixture.sent("edit_project").isEmpty, "the row's settings went out")
        #expect(fixture.sent("update_pronunciation_dictionaries").isEmpty, "the row's (empty) dictionary list went out")
        signals.note("tried")
        await opening.value
        #expect(model.detailsAreIn)
        #expect(model.editDraft.author == "Changed on the website")
        await model.setDictionary(added, attached: true)
        let locators = body(fixture, "update_pronunciation_dictionaries")
        #expect(locators.contains("d-kept") && locators.contains("d-new"), "a dictionary attached elsewhere was dropped")
    }

    // MARK: - The rename field of another dictionary

    /// Dictionary A open (its name in the rename field); B chosen, its details slow: the rename
    /// field no longer holds A's name, so Rename cannot give B the name of A.
    @Test func choosingAnotherDictionaryDoesNotLeaveTheFirstOnesNameToSend() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "patch_pronunciation_dictionary":
                return .json(["id": "d-b"])
            case "get_pronunciation_dictionary_metadata":
                // Only B's opening read is held; the fetch after a rename answers at once.
                if signals.note("get") == 1 { try await signals.wait(for: "checked") }
                return .json(VoicesStudioFollowupTests.dictionary("d-b", name: "Dict B"))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        let a = try #require(PronunciationDictionary(json: VoicesStudioFollowupTests.dictionary("d-a", name: "Dict A")))
        let b = try #require(PronunciationDictionary(json: VoicesStudioFollowupTests.dictionary("d-b", name: "Dict B")))
        model.load(dictionaries: [a, b], selected: a)
        #expect(model.rename == "Dict A")
        let choosing = Task { await model.select("d-b") }
        try await voicesStudioWait { fixture.sent("get_pronunciation_dictionary_metadata").count == 1 }
        #expect(model.rename == "Dict B", "B's rename field still holds A's name: “\(model.rename)”")
        await model.saveName()
        #expect(!body(fixture, "patch_pronunciation_dictionary").contains("Dict A"), "B was renamed to A's name")
        signals.note("checked")
        await choosing.value
    }

    // MARK: - Webhooks: no editor from an old row

    /// Edit pressed on a webhook, and the fresh list cannot be read: the editor is not opened
    /// from the row drawn earlier (a save would send its name and on/off state, which may be
    /// older than ElevenLabs'). The screen says so.
    @Test func aWebhookIsNotEditedFromAnOldRowWhenItCannotBeReadAgain() async throws {
        let fixture = VoicesStudioFixture([
            "get_workspace_webhooks_route": [.jsonText(#"{"detail":"Internal error"}"#, status: 500)],
        ])
        defer { fixture.clean() }
        let model = WebhooksSectionModel(environment: fixture.environment)
        let webhook = try #require(WorkspaceWebhook(json: [
            "webhook_id": "wh-1", "name": "Ops", "webhook_url": "https://hooks.example.com/ops", "is_disabled": false,
        ]))
        await model.startEditing(webhook)
        #expect(model.editing == nil, "the editor opened on the row's possibly older values")
        #expect(model.problems.first?.contains("could not be read again") == true)
        try await declining(model.actions) { await model.save() }
        #expect(fixture.sent("edit_workspace_webhook_route").isEmpty)
    }

    // MARK: - Round 3: the window between a change answering and its fetch

    static func project(_ id: String, dictionaries: [String]) -> JSONValue {
        var project = VoicesStudioStudioTests.project(id, name: "First")
        if case .object(var fields) = project {
            fields["pronunciation_dictionary_locators"] = .array(dictionaries.map {
                ["pronunciation_dictionary_id": .string($0), "version_id": "v1"]
            })
            project = .object(fields)
        }
        return project
    }

    /// d-new is switched on and the call answers; while the fetch after it is still on its way,
    /// d-two is switched on. That call sends the whole list again: it must keep d-new, which
    /// ElevenLabs now holds, rather than the list from before the first switch.
    @Test func aSecondDictionarySwitchBeforeTheFirstsFetchLandsKeepsTheFirst() async throws {
        let signals = Signals()
        let before = Self.project("p-a", dictionaries: ["d-kept"])
        let after = Self.project("p-a", dictionaries: ["d-kept", "d-new", "d-two"])
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "update_pronunciation_dictionaries":
                return .json(["status": "ok"])
            case "get_project_by_id":
                if signals.note("get") == 1 { try await signals.wait(for: "second sent") }
                return .json(after)
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let project = try #require(StudioProject(json: before))
        let new = StudioDictionary(id: "d-new", name: "New", latestVersionID: "v1")
        let two = StudioDictionary(id: "d-two", name: "Two", latestVersionID: "v1")
        model.load(projects: [project], selected: project, dictionaries: [new, two])
        let first = Task { try await answering(model.actions) { await model.setDictionary(new, attached: true) } }
        try await voicesStudioWait { fixture.sent("get_project_by_id").count == 1 }
        #expect(model.selected?.dictionaries.map(\.id) == ["d-kept", "d-new"], "the switch shows what ElevenLabs holds now")
        try await answering(model.actions) { await model.setDictionary(two, attached: true) }
        signals.note("second sent")
        try await first.value
        #expect(fixture.sent("update_pronunciation_dictionaries").count == 2)
        let second = body(fixture, "update_pronunciation_dictionaries")
        #expect(second.contains("d-new") && second.contains("d-kept") && second.contains("d-two"),
                "the second switch dropped the dictionary the first one attached: \(second)")
    }

    /// Rules added to dictionary A; while the fetch after the add is on its way, "Edit all in the
    /// editor" would copy the rules from before the add — and Replace would then remove the rule
    /// just added. It waits for the fetch; then it copies the rules as they are now.
    @Test func theRulesAreNotCopiedForAReplaceBeforeTheFetchAfterAChangeLands() async throws {
        let signals = Signals()
        var after = VoicesStudioFollowupTests.dictionary("d-a", name: "Dict A")
        if case .object(var fields) = after {
            fields["rules"] = [["string_to_replace": "Nguyen", "type": "alias", "alias": "Win"],
                               ["string_to_replace": "Siobhan", "type": "alias", "alias": "Shivawn"]]
            after = .object(fields)
        }
        let added = after
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "add_rules":
                return .json(["id": "d-a", "version_id": "ver2"])
            case "get_pronunciation_dictionary_metadata":
                try await signals.wait(for: "tried to copy")
                return .json(added)
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        let a = try #require(PronunciationDictionary(json: VoicesStudioFollowupTests.dictionary("d-a", name: "Dict A")))
        model.load(dictionaries: [a], selected: a)
        #expect(model.rulesAreIn)
        var rule = PronunciationRule()
        rule.stringToReplace = "Siobhan"
        rule.alias = "Shivawn"
        model.rules = [rule]
        let adding = Task { await model.addRules() }
        try await voicesStudioWait { fixture.sent("get_pronunciation_dictionary_metadata").count == 1 }
        #expect(!model.rulesAreIn, "the rules on screen are from before the add")
        model.editCurrentRules()
        #expect(!model.rules.contains { $0.stringToReplace == "Nguyen" }, "the rules from before the add were copied")
        signals.note("tried to copy")
        await adding.value
        #expect(model.rulesAreIn)
        model.editCurrentRules()
        #expect(model.rules.map(\.stringToReplace) == ["Nguyen", "Siobhan"], "the rules as they are now")
    }

    // MARK: - Round 3: the sliders when the settings cannot be read

    /// The voice's details answer without its settings, and the settings route then fails: the
    /// sliders still hold the list row's values. They cannot be saved, the screen says why and
    /// offers Try again; once the settings are read, Save sends them.
    @Test func theSlidersAreNotSavedWhenTheVoicesSettingsCannotBeRead() async throws {
        let signals = Signals()
        let saved: JSONValue = ["stability": 0.6, "similarity_boost": 0.8, "style": 0.1, "speed": 1.0, "use_speaker_boost": true]
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "get_voice_by_id":
                return .json(VoicesStudioFakes.voice("v-a", "Voice A"))              // no settings
            case "get_voice_settings":
                if signals.note("settings") == 1 { return .jsonText(#"{"detail":"Internal error"}"#, status: 500) }
                return .json(saved)
            case "edit_voice_settings":
                return .json(["status": "ok"])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let row = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-a", "Voice A", settings: VoicesStudioFakes.settings)))
        model.load(rows: [row])
        await model.select("v-a")
        #expect(model.detailsAreIn, "the voice's own details are in")
        #expect(!model.settingsAreIn)
        #expect(model.waitingForSettings == "Its settings could not be read — try again.")
        model.settingsDraft?.speed = 1.2
        try await answering(model.actions) { await model.saveSettings() }
        #expect(fixture.sent("edit_voice_settings").isEmpty, "the list row's sliders were saved after the settings read failed")
        await model.reloadSelected()                      // Try again
        #expect(model.settingsAreIn && model.waitingForSettings == nil)
        #expect(model.settingsDraft?.stability == 0.6, "an untouched slider takes the voice's own value")
        #expect(model.settingsDraft?.speed == 1.2, "the slider moved stays where it was put")
        try await answering(model.actions) { await model.saveSettings() }
        let sent = body(fixture, "edit_voice_settings")
        #expect(sent.contains("0.6") && !sent.contains("0.4"), "the row's stability was sent: \(sent)")
    }

    // MARK: - Round 3: a failed fetch after a change, while the opening read was dropped

    /// Voice A opened (its read held); a sample deleted meanwhile, and the fetch after it fails;
    /// then the opening read answers — older than the delete, so it is dropped. Nothing is
    /// loading any more: the screen says the details could not be read (not "Waiting…"), and a
    /// click on the voice reads them again.
    @Test func aFailedFetchAfterAChangeIsShownWhenTheOpeningReadWasDropped() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "delete_sample":
                return .json(["status": "ok"])
            case "get_voice_by_id":
                switch signals.note("get") {
                case 1:
                    try await signals.wait(for: "refetch failed")
                    return .json(VoicesStudioFakes.voice("v-a", "Voice A"))
                case 2:
                    return .jsonText(#"{"detail":"Internal error"}"#, status: 500)
                default:
                    return .json(VoicesStudioFakes.voice("v-a", "Voice A"))
                }
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let row = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-a", "Voice A", samples: [VoicesStudioFakes.sample("s1", "a.mp3")])))
        model.load(rows: [row])
        let opening = Task { await model.select("v-a") }
        try await voicesStudioWait { fixture.sent("get_voice_by_id").count == 1 }
        let sample = try #require(model.selected?.samples.first)
        try await answering(model.actions) { await model.deleteSample(sample) }
        signals.note("refetch failed")
        await opening.value
        #expect(!model.detailsAreIn)
        #expect(model.waitingForDetails == "Its details could not be read — try again.", "\(model.waitingForDetails ?? "-")")
        await model.select("v-a")
        #expect(model.detailsAreIn)
    }

    /// Productions: order A renamed (held), B opened and A again (its read held); the rename
    /// lands, the fetch after it fails, and A's read — older than the rename — is dropped. The
    /// order's card says it could not be read, with Try again, not "Loading the order…".
    @Test func anOrderWhoseFetchAfterARenameFailsSaysSo() async throws {
        let signals = Signals()
        let order = Self.order
        let fixture = VoicesStudioFixture(handler: { request in
            let path = request.url.path
            switch request.operationID {
            case "public_update_order":
                try await signals.wait(for: "reopened")
                signals.note("renamed")
                return .json(["order_id": "o-a"])
            case "public_get_order" where path.hasSuffix("/o-b"):
                return .json(["order_id": "o-b", "name": "B", "state": "open", "sandbox": false, "items": []])
            case "public_get_order":
                // Told apart by when they come, not by their order: a read of A before the rename
                // answered is A opened again; the first one after, the fetch after the rename.
                if !signals.has("renamed") {
                    signals.note("reopened")
                    try await signals.wait(for: "refetched")
                    return .json(order("Old name"))
                }
                if signals.note("after the rename") == 1 {
                    signals.note("refetched")
                    return .jsonText(#"{"detail":"Internal error"}"#, status: 500)
                }
                return .json(order("New name"))
            case "public_get_available_languages":
                return .json(["languages": []])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        let a = try #require(ProductionsOrder(json: order("Old name")))
        let b = try #require(ProductionsOrder(json: ["order_id": "o-b", "name": "B", "state": "open", "sandbox": false, "items": []]))
        model.load(orders: [a, b], selected: a)
        model.rename = "New name"
        let renaming = Task { try await answering(model.actions) { await model.saveName() } }
        try await voicesStudioWait { fixture.sent("public_update_order").count == 1 }
        // Should either awaited read never be sent (a regression), the request held for it is let
        // go once the task that would have sent it has finished, so the test fails at once rather
        // than at the fake's backstop. In the working code both signals have come by then.
        let releasing = Task { _ = try? await renaming.value; signals.note("refetched") }
        await model.select("o-b")
        await model.select("o-a")
        signals.note("reopened")
        try await renaming.value
        await releasing.value
        #expect(model.selected == nil, "A's older read was dropped")
        #expect(model.orderProblem != nil, "nothing is loading: the card must say why")
        await model.select("o-a")                         // Try again
        #expect(model.selected?.name == "New name")
    }

    // MARK: - Round 3: a chapter save with nothing to save

    /// Save chapter with nothing changed (or only paragraphs of a chapter whose content cannot
    /// be written back) would send `edit_chapter` with only its ids: it sends nothing.
    @Test func aChapterSaveWithNothingChangedSendsNothing() async throws {
        let blocks: [JSONValue] = [["block_id": "b1", "nodes": [["type": "tts_node", "text": "It was late.", "voice_id": "v2"]]]]
        let chapter = VoicesStudioStudioTests.chapter("c1", name: "One", blocks: blocks)
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "get_chapter_by_id_endpoint": return .json(chapter)
            case "get_chapter_snapshots": return .json(["snapshots": []])
            case "get_chapters": return .json(["chapters": []])
            case "edit_chapter": return .json(["status": "ok"])
            default: return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let project = try #require(StudioProject(json: VoicesStudioStudioTests.project("p-a")))
        model.load(projects: [project], selected: project)
        await model.openChapter("c1")
        #expect(!model.chapterHasChanges)
        try await answering(model.actions) { await model.saveChapter() }
        #expect(fixture.sent("edit_chapter").isEmpty, "a save with nothing to save went out")
        model.chapterName = "One, renamed"
        #expect(model.chapterHasChanges)
        try await answering(model.actions) { await model.saveChapter() }
        #expect(fixture.sent("edit_chapter").count == 1)
        #expect(body(fixture, "edit_chapter").contains("One, renamed"))
    }

    // MARK: - Round 4: a service-account key edited again before its keys are read again

    nonisolated static func key(_ id: String, of account: String, permissions: [String]) -> JSONValue {
        ["name": .string("Key \(id)"), "hint": "a1b2", "key_id": .string(id), "service_account_user_id": .string(account),
         "is_disabled": false, "permissions": .array(permissions.map(JSONValue.string)), "character_count": 0,
         "hashed_xi_api_key": "h"]
    }

    func permissionsSent(_ fixture: VoicesStudioFixture) -> [[String]] {
        fixture.sent("edit_service_account_api_key").map {
            ((try? JSONValue(data: $0.body))?["permissions"].arrayValue ?? []).compactMap(\.stringValue)
        }
    }

    /// A permission granted to key k1; while the account's keys are read again, the row shows
    /// what the save sent (not the permissions from before), and Edit waits for that read — the
    /// editor must not start from a row the save has just made stale, or the next save would
    /// take back the permission just granted. Once the read lands, Edit works and the next
    /// save keeps it.
    @Test func aKeyChangedAMomentAgoIsEditedFromItsNextRead() async throws {
        let signals = Signals()
        let model0 = ServiceAccountsSectionModel(environment: VoicesStudioFixture().environment)
        let choices = model0.permissionChoices.filter { $0 != "text_to_speech" }
        let first = try #require(choices.first), second = try #require(choices.dropFirst().first)
        let afterFirst = Self.key("k1", of: "sa-a", permissions: [first, "text_to_speech"].sorted())
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_service_account_api_key":
                return .json(["status": "ok"])
            case "get_service_account_api_keys_route":
                if signals.note("keys") == 1 { try await signals.wait(for: "tried to edit") }
                return .json(["api-keys": [afterFirst]])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let account = try #require(ServiceAccount(json: VoicesStudioLateAnswerTests.account("sa-a", key: "k1")))
        model.load(accounts: [account], selected: account)
        let key = try #require(account.keys.first)
        model.edit(key)
        model.keyDraft.allPermissions = false
        model.keyDraft.permissions.insert(first)
        let saving = Task { try await answering(model.actions) { await model.saveKey() } }
        try await voicesStudioWait { fixture.sent("get_service_account_api_keys_route").count == 1 }
        let row = try #require(model.selected?.keys.first)
        #expect(row.permissions.contains(first), "the row still shows the permissions from before the save: \(row.permissions)")
        #expect(model.accounts.first?.keys.first?.permissions.contains(first) == true)
        model.edit(row)
        #expect(model.editingKey == nil, "the editor opened on a key whose read is still on its way")
        #expect(model.editBlockReason(row) == "Waiting for its keys to be read again after the last change.")
        #expect(model.problems == ["Waiting for its keys to be read again after the last change."])
        signals.note("tried to edit")
        try await saving.value
        let fresh = try #require(model.selected?.keys.first)
        #expect(model.editBlockReason(fresh) == nil)
        model.edit(fresh)
        #expect(model.keyDraft.permissions.contains(first))
        model.keyDraft.permissions.insert(second)
        try await answering(model.actions) { await model.saveKey() }
        let sent = permissionsSent(fixture)
        #expect(sent.count == 2)
        #expect(sent.last?.contains(first) == true && sent.last?.contains(second) == true,
                "the second save took back the permission the first one granted: \(sent)")
    }

    /// A key change ElevenLabs refuses claims nothing: the row keeps what it had, and Edit is
    /// not held.
    @Test func aRefusedKeyChangeClaimsNothing() async throws {
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_service_account_api_key":
                return .jsonText(#"{"detail":{"status":"invalid","message":"Not allowed"}}"#, status: 422)
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let account = try #require(ServiceAccount(json: VoicesStudioLateAnswerTests.account("sa-a", key: "k1")))
        model.load(accounts: [account], selected: account)
        let key = try #require(account.keys.first)
        model.edit(key)
        model.keyDraft.allPermissions = true
        try await answering(model.actions) { await model.saveKey() }
        #expect(fixture.sent("edit_service_account_api_key").count == 1)
        #expect(model.selected?.keys.first?.permissions == ["text_to_speech"], "a refused change was claimed")
        #expect(model.editBlockReason(key) == nil)
        // A refusal is a known outcome — nothing was done: the editor stays open on the draft, and
        // nothing is read again (only a lost answer is).
        #expect(model.editingKey?.id == key.id, "a refused change closed the editor")
        #expect(fixture.sent("get_service_account_api_keys_route").isEmpty, "a refused change was read again as if it may have landed")
    }

    /// The accounts list, asked for before a key change answered and answering after it, does
    /// not put the key's old permissions back.
    @Test func anAccountsListOlderThanAKeyChangeDoesNotPutTheOldKeyBack() async throws {
        let signals = Signals()
        let model0 = ServiceAccountsSectionModel(environment: VoicesStudioFixture().environment)
        let first = try #require(model0.permissionChoices.first { $0 != "text_to_speech" })
        let oldList: JSONValue = ["service-accounts": [VoicesStudioLateAnswerTests.account("sa-a", key: "k1")]]
        let changed = Self.key("k1", of: "sa-a", permissions: [first])
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "get_workspace_service_accounts":
                try await signals.wait(for: "saved")
                return .json(oldList)
            case "edit_service_account_api_key":
                return .json(["status": "ok"])
            case "get_service_account_api_keys_route":
                return .json(["api-keys": [changed]])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let account = try #require(ServiceAccount(json: VoicesStudioLateAnswerTests.account("sa-a", key: "k1")))
        model.load(accounts: [account], selected: account)
        let listing = Task { await model.refresh() }
        try await voicesStudioWait { fixture.sent("get_workspace_service_accounts").count == 1 }
        model.edit(try #require(account.keys.first))
        model.keyDraft.allPermissions = false
        model.keyDraft.permissions = [first]
        try await answering(model.actions) { await model.saveKey() }
        signals.note("saved")
        await listing.value
        #expect(model.selected?.keys.first?.permissions == [first], "the older list put the old permissions back")
        #expect(model.accounts.first?.keys.first?.permissions == [first])
    }

    /// A change to a key of account A, then one to a key of account B while A's keys are being
    /// read again: B's read does not abandon A's, so A's key can be edited once its read lands.
    @Test func readingOneAccountsKeysDoesNotAbandonAnothersRead() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            let account = request.url.path.contains("sa-a") ? "sa-a" : "sa-b"
            switch request.operationID {
            case "edit_service_account_api_key":
                return .json(["status": "ok"])
            case "get_service_account_api_keys_route" where account == "sa-a":
                try await signals.wait(for: "b changed")
                return .json(["api-keys": [Self.key("ka", of: "sa-a", permissions: ["all"])]])
            case "get_service_account_api_keys_route":
                return .json(["api-keys": [Self.key("kb", of: "sa-b", permissions: ["text_to_speech"])]])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let a = try #require(ServiceAccount(json: VoicesStudioLateAnswerTests.account("sa-a", key: "ka")))
        let b = try #require(ServiceAccount(json: VoicesStudioLateAnswerTests.account("sa-b", key: "kb")))
        model.load(accounts: [a, b], selected: a)
        model.edit(try #require(a.keys.first))
        model.keyDraft.allPermissions = true
        let savingA = Task { try await answering(model.actions) { await model.saveKey() } }
        try await voicesStudioWait { fixture.sent("get_service_account_api_keys_route").count == 1 }
        let keyB = try #require(b.keys.first)
        try await answering(model.actions) { await model.setEnabled(keyB, false) }
        signals.note("b changed")
        try await savingA.value
        let keyA = try #require(model.accounts.first { $0.id == "sa-a" }?.keys.first)
        #expect(model.editBlockReason(keyA) == nil, "A's read was abandoned by B's: A's key stays locked")
        #expect(keyA.permissions == ["all"])
    }

    // MARK: - Round 4 sweep: a workspace member's seat and lock, while the members are read again

    /// A seat change answers; while the members are read again, the row shows the seat sent —
    /// so going back to the previous seat is a change the picker offers, not one it hides — and
    /// a lock shows as locked (its button offers Unlock).
    @Test func aMembersSeatAndLockShowWhatWasSentWhileTheMembersAreReadAgain() async throws {
        let signals = Signals()
        let member = VoicesStudioWorkspaceTests.member
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "update_workspace_member":
                return .json(["status": "ok"])
            case "get_workspace_members":
                try await signals.wait(for: "checked")
                return .json([member])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        let row = try #require(WorkspaceMember(json: member))
        model.load(members: [row])
        model.seatEdits[row.id] = "workspace_admin"
        let changing = Task { try await answering(model.actions) { await model.changeSeat(row) } }
        try await voicesStudioWait { fixture.sent("get_workspace_members").count == 1 }
        #expect(model.members.first?.seatType == "workspace_admin", "the row still shows the seat from before")
        let current = try #require(model.members.first)
        let locking = Task { try await answering(model.actions) { await model.setLocked(current, true) } }
        // The lock has answered once the members are being read again after it.
        try await voicesStudioWait { fixture.sent("get_workspace_members").count == 2 }
        #expect(model.members.first?.isLocked == true, "the row still shows the member unlocked")
        signals.note("checked")
        try await changing.value
        try await locking.value
    }

    // MARK: - Round 4: held requests let go when abandoned

    /// Polls `condition` for up to `limit`; true as soon as it holds.
    func within(_ limit: Duration, _ condition: @MainActor () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Two reads held by the fake are abandoned in turn ("Try again" pressed three times): each
    /// abandoned read lets go of its connection, as URLSession does, so the third read is sent
    /// at once. (The client allows two at a time; held reads that ignored cancellation kept
    /// both, and the third waited for the fake's backstop.)
    @Test func abandonedHeldReadsLetGoOfTheirConnections() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "get_voice_by_id":
                if signals.note("get") <= 2 { try await signals.wait(for: "never") }
                return .json(VoicesStudioFakes.voice("v-a", "Voice A"))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let a = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-a", "Voice A", settings: VoicesStudioFakes.settings)))
        model.load(rows: [a], selected: a)
        let asked = ContinuousClock.now
        let first = Task { await model.reloadSelected() }
        try await voicesStudioWait { fixture.sent("get_voice_by_id").count == 1 }
        // How long one read takes to reach the fake on this machine, as loaded as it is now.
        let oneRead = ContinuousClock.now - asked
        let second = Task { await model.reloadSelected() }
        try await voicesStudioWait { fixture.sent("get_voice_by_id").count == 2 }
        let third = Task { await model.reloadSelected() }
        // The third read goes as soon as the second is abandoned: allow three seconds, or ten
        // times what the first took on a loaded machine. Held reads that ignore cancellation
        // keep both connections, so a regression fails here in seconds.
        let sent = try await within(max(.seconds(3), oneRead * 10)) { fixture.sent("get_voice_by_id").count == 3 }
        signals.note("never")
        await first.value
        await second.value
        await third.value
        #expect(sent, "the third read waited for connections held by abandoned reads")
    }

    // MARK: - Round 4: Pronunciation "Edit all" after a failed fetch

    /// Rules added, and the fetch after it fails. Nothing is reading the rules any more, so
    /// "Edit all" says they could not be read, with Try again, instead of "Waiting…". While Try
    /// again's read is on its way it is waiting again; once it answers, Edit all works.
    @Test func editAllAfterAFailedFetchSaysSoAndTryAgainReadsTheRules() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "add_rules":
                return .json(["id": "d-a", "version_id": "ver2"])
            case "get_pronunciation_dictionary_metadata":
                if signals.note("get") == 1 { return .jsonText(#"{"detail":"Internal error"}"#, status: 500) }
                try await signals.wait(for: "seen waiting")
                return .json(VoicesStudioFollowupTests.dictionary("d-a", name: "Dict A"))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        let a = try #require(PronunciationDictionary(json: VoicesStudioFollowupTests.dictionary("d-a", name: "Dict A")))
        model.load(dictionaries: [a], selected: a)
        var rule = PronunciationRule()
        rule.stringToReplace = "Siobhan"
        rule.alias = "Shivawn"
        model.rules = [rule]
        try await answering(model.actions) { await model.addRules() }
        #expect(fixture.sent("get_pronunciation_dictionary_metadata").count == 1)
        #expect(!model.rulesAreIn)
        #expect(model.rulesProblem != nil, "a fetch that failed is shown as \"Waiting…\"")
        let retrying = Task { await model.select("d-a") }           // Try again
        // A read never sent (a regression) lets the wait below end once Try again has finished.
        let releasing = Task { await retrying.value; signals.note("seen waiting") }
        try await voicesStudioWait {
            fixture.sent("get_pronunciation_dictionary_metadata").count == 2 || signals.has("seen waiting")
        }
        #expect(model.rulesProblem == nil, "the old failure is shown while the rules are read again")
        signals.note("seen waiting")
        await retrying.value
        await releasing.value
        #expect(model.rulesAreIn)
        #expect(model.rulesProblem == nil)
    }

    /// The same when the read that opens the dictionary fails: its rules shown are the list's,
    /// and "Edit all" says they could not be read rather than waiting.
    @Test func editAllAfterAFailedOpeningReadSaysSo() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "get_pronunciation_dictionary_metadata":
                if signals.note("get") == 1 { return .jsonText(#"{"detail":"Internal error"}"#, status: 500) }
                return .json(VoicesStudioFollowupTests.dictionary("d-a", name: "Dict A"))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        let a = try #require(PronunciationDictionary(json: VoicesStudioFollowupTests.dictionary("d-a", name: "Dict A")))
        model.load(dictionaries: [a])
        await model.select("d-a")
        #expect(model.selected?.id == "d-a")
        #expect(!model.rulesAreIn)
        #expect(model.rulesProblem != nil, "a read that failed is shown as \"Waiting…\"")
        await model.select("d-a")                                  // Try again
        #expect(model.rulesAreIn)
        #expect(model.rulesProblem == nil)
    }

    // MARK: - Round 5: a change whose answer was lost

    /// A pretend ElevenLabs that remembers each key's permissions and whether it is off, as
    /// edits set them — and can carry out an edit while losing its answer (a 500).
    final class KeyServer: @unchecked Sendable {
        private let lock = NSLock()
        private var permissions: [String: [String]]
        private var disabled: [String: Bool] = [:]
        private var answersToLose: Int
        init(_ keys: [String: [String]], losing: Int = 0) {
            permissions = keys
            answersToLose = losing
        }

        /// Carries out the edit; false when its answer is to be lost.
        func edit(_ request: ElevenLabsRequest) -> Bool {
            lock.withLock {
                let data: Data = if case .data(let data) = request.body { data } else { Data() }
                let json = (try? JSONValue(data: data)) ?? .null
                let id = request.url.lastPathComponent
                if let list = json["permissions"].arrayValue?.compactMap(\.stringValue) { permissions[id] = list }
                if let enabled = json["is_enabled"].boolValue { disabled[id] = !enabled }
                guard answersToLose > 0 else { return true }
                answersToLose -= 1
                return false
            }
        }

        func keys(of account: String) -> JSONValue {
            lock.withLock {
                ["api-keys": .array(permissions.keys.sorted().map { id in
                    ["name": .string("Key \(id)"), "hint": "a1b2", "key_id": .string(id),
                     "service_account_user_id": .string(account), "is_disabled": .bool(disabled[id] ?? false),
                     "permissions": .array((permissions[id] ?? []).map(JSONValue.string)),
                     "character_count": 0, "hashed_xi_api_key": "h"]
                })]
            }
        }

        func current(_ id: String) -> [String] { lock.withLock { (permissions[id] ?? []).sorted() } }
        func isDisabled(_ id: String) -> Bool { lock.withLock { disabled[id] ?? false } }
    }

    /// A permission granted to key k1 reaches ElevenLabs and is carried out, but the answer is a
    /// 500. The row claims nothing, yet it may now be older than ElevenLabs: the editor closes,
    /// the key's Edit waits, and the account's keys are read again. Opened from that read, the
    /// editor keeps the permission the lost-answer save granted when another is added. (Before:
    /// no read, and an editor reopened from the row sent the list without it, taking it back.)
    @Test func aKeyChangeWhoseAnswerWasLostIsReadAgainBeforeItIsEditedAgain() async throws {
        let signals = Signals()
        let catalog = VoicesStudioFixture()
        defer { catalog.clean() }
        let choices = ServiceAccountsSectionModel(environment: catalog.environment).permissionChoices
            .filter { $0 != "text_to_speech" }
        try #require(choices.count >= 2)
        let granted = choices[0], added = choices[1]
        let server = KeyServer(["k1": ["text_to_speech"]], losing: 1)
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_service_account_api_key":
                if server.edit(request) { return .json(["status": "ok"]) }
                return .jsonText(#"{"detail":"Internal error"}"#, status: 500)    // carried out; answer lost
            case "get_service_account_api_keys_route":
                if signals.note("keys") == 1 { try await signals.wait(for: "looked") }
                return .json(server.keys(of: "sa-a"))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let account = try #require(ServiceAccount(json: VoicesStudioLateAnswerTests.account("sa-a", key: "k1")))
        model.load(accounts: [account], selected: account)
        model.edit(try #require(model.selected?.keys.first))
        model.keyDraft.allPermissions = false
        model.keyDraft.permissions.insert(granted)
        let saving = Task { try await answering(model.actions) { await model.saveKey() } }
        // Should no read be made (a regression), the save ends at once, and so does this wait.
        let releasing = Task { _ = try? await saving.value; signals.note("looked") }
        try await voicesStudioWait {
            fixture.sent("get_service_account_api_keys_route").count == 1 || signals.has("looked")
        }
        #expect(fixture.sent("get_service_account_api_keys_route").count == 1, "the keys were not read again after a lost answer")
        let row = try #require(model.selected?.keys.first)
        #expect(row.permissions == ["text_to_speech"], "a change whose answer was lost was claimed")
        #expect(model.editingKey == nil, "the editor stayed open, its starting point a row older than ElevenLabs")
        #expect(model.problems == [ServiceAccountsSectionModel.lostAnswerMessage(row.name)], "\(model.problems)")
        #expect(model.editBlockReason(row) != nil, "Edit did not wait for the keys to be read again")
        model.edit(row)
        #expect(model.editingKey == nil, "the editor opened from the unread row")
        signals.note("looked")
        try await saving.value
        await releasing.value
        let fresh = try #require(model.selected?.keys.first)
        #expect(fresh.permissions.sorted() == ["text_to_speech", granted].sorted(), "the row is not what ElevenLabs holds")
        #expect(model.editBlockReason(fresh) == nil)
        model.edit(fresh)
        model.keyDraft.permissions.insert(added)
        try await answering(model.actions) { await model.saveKey() }
        #expect(server.current("k1") == ["text_to_speech", granted, added].sorted(),
                "the next change took back the permission the lost-answer save granted: \(server.current("k1"))")
    }

    /// Turned off, carried out, answer lost: the row would keep showing the key on, its button
    /// offering "Turn off…" again. The keys are read again, and the row says the key is off.
    @Test func aKeyTurnedOffWhoseAnswerWasLostIsReadAgain() async throws {
        let server = KeyServer(["k1": ["text_to_speech"]], losing: 1)
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_service_account_api_key":
                if server.edit(request) { return .json(["status": "ok"]) }
                return .jsonText(#"{"detail":"Internal error"}"#, status: 500)
            case "get_service_account_api_keys_route":
                return .json(server.keys(of: "sa-a"))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = ServiceAccountsSectionModel(environment: fixture.environment)
        let account = try #require(ServiceAccount(json: VoicesStudioLateAnswerTests.account("sa-a", key: "k1")))
        model.load(accounts: [account], selected: account)
        let key = try #require(model.selected?.keys.first)
        try await answering(model.actions) { await model.setEnabled(key, false) }
        #expect(server.isDisabled("k1"))
        #expect(fixture.sent("get_service_account_api_keys_route").count == 1, "the keys were not read again after a lost answer")
        #expect(model.selected?.keys.first?.isDisabled == true, "the row still shows the key on")
        #expect(model.accounts.first?.keys.first?.isDisabled == true)
        #expect(model.problems == [ServiceAccountsSectionModel.lostAnswerMessage(key.name)], "\(model.problems)")
    }

    /// The request body a fake received, as JSON.
    nonisolated static func body(_ request: ElevenLabsRequest) -> JSONValue {
        let data: Data = if case .data(let data) = request.body { data } else { Data() }
        return (try? JSONValue(data: data)) ?? .null
    }

    /// A seat change and a lock, each carried out with its answer lost (a 500): the members are
    /// read again after each, so the row shows the seat and the lock the member now has. (Before:
    /// nothing was read; the row kept the seat from before — picking it to go back looked like no
    /// change — and offered "Lock…" for a member just locked.) A refused change reads nothing.
    @Test func aMembersSeatOrLockWhoseAnswerWasLostIsReadAgain() async throws {
        final class Member: @unchecked Sendable {
            let lock = NSLock()
            var json: JSONValue
            var refuseNext = false
            init(_ json: JSONValue) { self.json = json }
        }
        let server = Member(VoicesStudioWorkspaceTests.member)
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "update_workspace_member":
                let body = Self.body(request)
                return server.lock.withLock {
                    if server.refuseNext {
                        server.refuseNext = false
                        return .jsonText(#"{"detail":{"status":"invalid","message":"Not allowed"}}"#, status: 422)
                    }
                    guard case .object(var fields) = server.json else { return .jsonText("{}", status: 500) }
                    if let seat = body["workspace_seat_type"].stringValue { fields["seat_type"] = .string(seat) }
                    if let locked = body["is_locked"].boolValue { fields["is_locked"] = .bool(locked) }
                    server.json = .object(fields)
                    return .jsonText(#"{"detail":"Internal error"}"#, status: 500)        // carried out; answer lost
                }
            case "get_workspace_members":
                return .json([server.lock.withLock { server.json }])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = WorkspaceSectionModel(environment: fixture.environment)
        let row = try #require(WorkspaceMember(json: VoicesStudioWorkspaceTests.member))
        model.load(members: [row])
        model.seatEdits[row.id] = "workspace_admin"
        try await answering(model.actions) { await model.changeSeat(row) }
        #expect(fixture.sent("get_workspace_members").count == 1, "the members were not read again after a lost answer")
        #expect(model.members.first?.seatType == "workspace_admin", "the row still shows the seat from before")
        let current = try #require(model.members.first)
        try await answering(model.actions) { await model.setLocked(current, true) }
        #expect(fixture.sent("get_workspace_members").count == 2)
        #expect(model.members.first?.isLocked == true, "the row still offers to lock a member just locked")
        server.lock.withLock { server.refuseNext = true }
        let locked = try #require(model.members.first)
        try await answering(model.actions) { await model.setLocked(locked, false) }
        #expect(fixture.sent("update_workspace_member").count == 3)
        #expect(fixture.sent("get_workspace_members").count == 2, "a refused change was read again as if it may have landed")
    }

    /// A rule added to dictionary A reaches ElevenLabs, but the answer is a 500. The rules on
    /// screen are those from before the add, so "Edit all" waits while the dictionary is read
    /// again; once that lands it copies the rules with the added one, and a Replace keeps it.
    /// (Before: nothing was read, "Edit all" copied the rules from before the add, and Replace
    /// took the added rule back.)
    @Test func aRuleAddedWithItsAnswerLostIsReadAgainBeforeEditAllCopiesTheRules() async throws {
        final class Rules: @unchecked Sendable {
            let lock = NSLock()
            var rules: [JSONValue]
            var answersToLose = 1
            init(_ rules: [JSONValue]) { self.rules = rules }
            func dictionary() -> JSONValue {
                lock.withLock {
                    ["id": "d-a", "name": "Dict A", "latest_version_id": "ver2",
                     "latest_version_rules_num": .number(Double(rules.count)), "rules": .array(rules)]
                }
            }
            var strings: [String] { lock.withLock { rules.compactMap { $0["string_to_replace"].stringValue }.sorted() } }
        }
        let signals = Signals()
        let server = Rules([["string_to_replace": "Nguyen", "type": "alias", "alias": "Win"]])
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "add_rules":
                let added = Self.body(request)["rules"].arrayValue ?? []
                let lose = server.lock.withLock {
                    server.rules += added
                    defer { server.answersToLose = max(0, server.answersToLose - 1) }
                    return server.answersToLose > 0
                }
                if lose { return .jsonText(#"{"detail":"Internal error"}"#, status: 500) }   // carried out; answer lost
                return .json(["id": "d-a", "version_id": "ver2"])
            case "set_rules":
                let rules = Self.body(request)["rules"].arrayValue ?? []
                server.lock.withLock { server.rules = rules }
                return .json(["id": "d-a", "version_id": "ver3"])
            case "get_pronunciation_dictionary_metadata":
                if signals.note("get") == 1 { try await signals.wait(for: "looked") }
                return .json(server.dictionary())
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        let a = try #require(PronunciationDictionary(json: VoicesStudioFollowupTests.dictionary("d-a", name: "Dict A")))
        model.load(dictionaries: [a], selected: a)
        var rule = PronunciationRule()
        rule.stringToReplace = "Siobhan"
        rule.alias = "Shivawn"
        model.rules = [rule]
        let adding = Task { try await answering(model.actions) { await model.addRules() } }
        // Should no read be made (a regression), the add ends at once, and so does this wait.
        let releasing = Task { _ = try? await adding.value; signals.note("looked") }
        try await voicesStudioWait {
            fixture.sent("get_pronunciation_dictionary_metadata").count == 1 || signals.has("looked")
        }
        #expect(server.strings == ["Nguyen", "Siobhan"])
        #expect(fixture.sent("get_pronunciation_dictionary_metadata").count == 1, "the dictionary was not read again after a lost answer")
        #expect(!model.rulesAreIn, "\"Edit all\" would copy the rules from before the add")
        signals.note("looked")
        try await adding.value
        await releasing.value
        #expect(model.rulesAreIn)
        model.editCurrentRules()
        #expect(model.rules.map(\.stringToReplace).sorted() == ["Nguyen", "Siobhan"], "\(model.rules.map(\.stringToReplace))")
        try await answering(model.actions) { await model.replaceRules() }
        #expect(server.strings == ["Nguyen", "Siobhan"], "Replace took back the rule whose answer was lost: \(server.strings)")
    }

    /// A pretend ElevenLabs holding order o-a with one dub item, whose upserts it carries out —
    /// losing the answer to as many as asked.
    final class OrderServer: @unchecked Sendable {
        private let lock = NSLock()
        private var item: JSONValue = [
            "item_id": "i1", "quote": ["amount_usd": 240],
            "item": ["kind": "dub", "media_id": "m1", "source_language": "en", "destination_languages": ["es-ES"],
                     "instructions": "Warm", "include_captions": false, "include_source_captions": false],
        ]
        private var answersToLose: Int
        init(losing: Int = 0) { answersToLose = losing }

        /// Carries out the upsert; false when its answer is to be lost.
        func upsert(_ body: JSONValue) -> Bool {
            lock.withLock {
                let request = body["item"] != .null ? body : body["request"]
                item = ["item_id": request["item_id"] != .null ? request["item_id"] : "i1",
                        "quote": ["amount_usd": 240], "item": request["item"]]
                guard answersToLose > 0 else { return true }
                answersToLose -= 1
                return false
            }
        }

        func order() -> JSONValue {
            lock.withLock {
                ["order_id": "o-a", "name": "Launch", "state": "open", "sandbox": false, "items": [item],
                 "total_amount_usd": 240]
            }
        }

        var instructions: String? { lock.withLock { item["item"]["instructions"].stringValue } }
    }

    func productionsFixture(_ server: OrderServer, signals: Signals) -> VoicesStudioFixture {
        VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "public_upsert_order_item":
                if server.upsert(Self.body(request)) { return .json(["item_id": "i1"]) }
                return .jsonText(#"{"detail":"Internal error"}"#, status: 500)        // carried out; answer lost
            case "public_get_order":
                if signals.note("get") == 1 { try await signals.wait(for: "looked") }
                return .json(server.order())
            case "public_get_available_languages":
                return .json(["languages": []])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
    }

    /// An item's instructions changed and saved; while the order is read again, its row still
    /// holds the instructions from before. Edit waits for that read — the form would start from
    /// the old instructions, and the next save, which sends the whole item, would put them back.
    /// Once the read lands, Edit starts from the instructions saved.
    @Test func anItemChangedAMomentAgoIsEditedFromTheOrdersNextRead() async throws {
        let signals = Signals()
        let server = OrderServer()
        let fixture = productionsFixture(server, signals: signals)
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        let order = try #require(ProductionsOrder(json: server.order()))
        model.load(orders: [order], selected: order)
        model.edit(try #require(model.selected?.items.first))
        model.item.instructions = "Bright"
        let saving = Task { try await answering(model.actions) { await model.saveItem() } }
        let releasing = Task { _ = try? await saving.value; signals.note("looked") }
        try await voicesStudioWait { fixture.sent("public_get_order").count == 1 || signals.has("looked") }
        #expect(server.instructions == "Bright")
        let stale = try #require(model.selected?.items.first)
        #expect(model.itemEditBlockReason != nil, "Edit did not wait for the order to be read again")
        model.edit(stale)
        #expect(model.item.itemID == nil && model.item.instructions != "Warm", "the form was filled from the row before the save")
        signals.note("looked")
        try await saving.value
        await releasing.value
        #expect(model.itemsAreIn)
        model.edit(try #require(model.selected?.items.first))
        #expect(model.item.itemID == "i1" && model.item.instructions == "Bright")
    }

    /// The same item change carried out with its answer lost (a 500): the order is read again,
    /// and Edit waits for that read and then starts from what ElevenLabs holds. (Before: nothing
    /// was read, and Edit filled the form with the instructions from before.)
    @Test func anItemChangeWhoseAnswerWasLostIsReadAgainBeforeItIsEdited() async throws {
        let signals = Signals()
        let server = OrderServer(losing: 1)
        let fixture = productionsFixture(server, signals: signals)
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        let order = try #require(ProductionsOrder(json: server.order()))
        model.load(orders: [order], selected: order)
        model.edit(try #require(model.selected?.items.first))
        model.item.instructions = "Bright"
        let saving = Task { try await answering(model.actions) { await model.saveItem() } }
        let releasing = Task { _ = try? await saving.value; signals.note("looked") }
        try await voicesStudioWait { fixture.sent("public_get_order").count == 1 || signals.has("looked") }
        #expect(server.instructions == "Bright")
        #expect(fixture.sent("public_get_order").count == 1, "the order was not read again after a lost answer")
        #expect(model.itemEditBlockReason != nil, "Edit did not wait for the order to be read again")
        signals.note("looked")
        try await saving.value
        await releasing.value
        model.edit(try #require(model.selected?.items.first))
        #expect(model.item.instructions == "Bright", "Edit started from the instructions before the change")
    }
}
