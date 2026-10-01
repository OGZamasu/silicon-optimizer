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
@Suite("ElevenLabs voices & studio — stale values", .timeLimit(.minutes(1)))
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
        let done = Done()
        let task = Task { await action(); done.value = true }
        try await voicesStudioWait {
            if actions.presentedQuestion != nil { actions.answer(false) }
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

}
