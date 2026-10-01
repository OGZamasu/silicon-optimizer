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
                    await signals.wait(for: "saved")
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
                    await signals.wait(for: "saved")
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
                    await signals.wait(for: "saved")
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
                    await signals.wait(for: "saved")
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
                    await signals.wait(for: "saved")
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
                if signals.note("get") == 1 { await signals.wait(for: "tried") }
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
                if signals.note("get") == 1 { await signals.wait(for: "tried") }
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
                if signals.note("get") == 1 { await signals.wait(for: "tried") }
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
                if signals.note("get") == 1 { await signals.wait(for: "checked") }
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
                if signals.note("get") == 1 { await signals.wait(for: "second sent") }
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
                await signals.wait(for: "tried to copy")
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
}
