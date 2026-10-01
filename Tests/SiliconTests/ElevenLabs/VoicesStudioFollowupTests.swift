import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

extension VoicesStudioFixture {
    /// A fixture whose fake ElevenLabs answers through `handler` — by id rather than in order,
    /// for answers that must wait on each other.
    init(handler: @escaping @Sendable (ElevenLabsRequest) async throws -> FakeElevenLabsTransport.Reply) {
        routes = VoicesStudioRoutes([:])
        transport = FakeElevenLabsTransport(handler: handler)
        var limits = ElevenLabsClient.Limits()
        limits.retries = 0
        limits.firstBackoff = 0.01
        client = ElevenLabsClient(credentials: credentials, region: .global, transport: transport, sink: sink, limits: limits)
        let client = client
        voices = ElevenLabsVoiceDirectory(client: { client })
    }
}

/// The voices-and-studio critic's last nits, taken after the merge. Hermetic: the section
/// fixture (fake transport, fake key, temporary sink).
@Suite("ElevenLabs voices & studio follow-ups", .timeLimit(.minutes(1)))
@MainActor
struct VoicesStudioFollowupTests {

    // MARK: - Known and unknown outcomes, by status

    /// A spending call answered 408 or 5xx may have been carried out — it holds the next
    /// spending call until the owner has checked; a 409 or a 429 is ElevenLabs refusing before
    /// any work and holds nothing. Judged by the failure's HTTP status, not by the words
    /// "answered 4xx".
    @Test func aTimeoutOrServerErrorIsAnUnknownOutcomeAndARefusalIsNot() async throws {
        let fixture = VoicesStudioFixture([
            "create_podcast": [
                .jsonText(#"{"detail":"Request timeout"}"#, status: 408),
                .jsonText(#"{"detail":"Bad gateway"}"#, status: 502),
                .jsonText(#"{"detail":"busy"}"#, status: 429),
                .jsonText(#"{"detail":{"status":"conflict","message":"Already exists"}}"#, status: 409),
            ],
            "get_projects": [.json(["projects": []]), .json(["projects": []])],
        ])
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        model.podcast.modelID = "eleven_multilingual_v2"
        model.podcast.hostVoiceID = "v1"
        model.podcast.guestVoiceID = "v2"
        model.podcast.text = "Why the road is long."
        for status in [408, 502] {
            await model.createPodcast()
            #expect(model.actions.unknownOutcomes["create_podcast"] != nil, "\(status) may have made the podcast")
            model.actions.acknowledgeUnknownOutcomes()
        }
        for status in [429, 409] {
            await model.createPodcast()
            #expect(model.actions.unknownOutcomes.isEmpty, "a \(status) is ElevenLabs' refusal: nothing was made")
        }
        #expect(fixture.sent("create_podcast").count == 4)
    }

    // MARK: - Helpers

    /// Starts `action`, answers any question it puts on screen, and returns once its call is on
    /// the wire.
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

    // MARK: - N1: each changed item is fetched again on its own runner

    /// Things the fake ElevenLabs has been asked, for answers that wait on each other.
    final class Signals: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: Set<String> = []
        private var counts: [String: Int] = [:]

        /// Notes `name` and returns how many times it has been noted, this one included.
        @discardableResult
        func note(_ name: String) -> Int {
            lock.withLock {
                seen.insert(name)
                counts[name, default: 0] += 1
                return counts[name] ?? 0
            }
        }

        func has(_ name: String) -> Bool { lock.withLock { seen.contains(name) } }

        /// Waits (up to a minute) until `name` has been noted.
        func wait(for name: String) async {
            let deadline = ContinuousClock.now + .seconds(60)
            while !has(name), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }

    /// Voice B's sample delete is on its way; A is opened, renamed and saved. B's delete answers
    /// only once A's fetch after the save is on its way, and A's fetch answers only once B's
    /// fetch after the delete has started — so the two overlap however loaded the machine is.
    /// Both land: A's row and the open voice show A's new name.
    @Test func twoChangesToTwoVoicesBothFetchTheirVoiceAgain() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            let path = request.url.path
            switch request.operationID {
            case "delete_sample":
                await signals.wait(for: "refetch v-a")
                return .json(["status": "ok"])
            case "edit_voice":
                return .json(["status": "ok"])
            case "get_voice_by_id" where path.hasSuffix("/v-a"):
                if signals.note("get v-a") == 1 { return .json(VoicesStudioFakes.voice("v-a", "Voice A")) }
                signals.note("refetch v-a")
                await signals.wait(for: "refetch v-b")
                return .json(VoicesStudioFakes.voice("v-a", "Voice A renamed"))
            case "get_voice_by_id" where path.hasSuffix("/v-b"):
                signals.note("refetch v-b")
                return .json(VoicesStudioFakes.voice("v-b", "Voice B"))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let a = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-a", "Voice A")))
        let b = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-b", "Voice B", samples: [
            VoicesStudioFakes.sample("s-b", "b.mp3"),
        ])))
        model.load(rows: [a, b], selected: b)
        let sample = try #require(b.samples.first)
        let deleting = try await sending(model.actions, "delete_sample") { await model.deleteSample(sample) }
        await model.select("v-a")
        model.editDraft.name = "Voice A renamed"
        let saving = Task { await model.saveEdit() }
        await deleting.value
        await saving.value
        #expect(fixture.sent("get_voice_by_id").count == 3)
        #expect(model.rows.first { $0.id == "v-a" }?.name == "Voice A renamed",
                "A's fetch after its own edit was abandoned: the row still reads “\(model.rows.first { $0.id == "v-a" }?.name ?? "")”")
        #expect(model.selected?.id == "v-a")
        #expect(model.selected?.name == "Voice A renamed")
    }

    nonisolated static func dictionary(_ id: String, name: String) -> JSONValue {
        ["id": .string(id), "name": .string(name), "latest_version_id": "ver1", "latest_version_rules_num": 1,
         "rules": [["string_to_replace": "Nguyen", "type": "alias", "alias": "Win"]]]
    }

    /// Pronunciation, the same overlap: rules added to B, A opened and renamed; B's add answers
    /// once A's fetch after the rename is on its way. A's row still takes its new name.
    @Test func twoChangesToTwoDictionariesBothFetchTheirDictionaryAgain() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            let path = request.url.path
            switch request.operationID {
            case "add_rules":
                await signals.wait(for: "refetch d-a")
                return .json(["id": "d-b", "version_id": "ver2"])
            case "patch_pronunciation_dictionary":
                return .json(["id": "d-a"])
            case "get_pronunciation_dictionary_metadata" where path.hasSuffix("/d-a"):
                if signals.note("get d-a") == 1 { return .json(Self.dictionary("d-a", name: "Dict A")) }
                signals.note("refetch d-a")
                await signals.wait(for: "refetch d-b")
                return .json(Self.dictionary("d-a", name: "Dict A renamed"))
            case "get_pronunciation_dictionary_metadata" where path.hasSuffix("/d-b"):
                signals.note("refetch d-b")
                return .json(Self.dictionary("d-b", name: "Dict B"))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        let a = try #require(PronunciationDictionary(json: Self.dictionary("d-a", name: "Dict A")))
        let b = try #require(PronunciationDictionary(json: Self.dictionary("d-b", name: "Dict B")))
        model.load(dictionaries: [a, b], selected: b)
        var rule = PronunciationRule()
        rule.stringToReplace = "Siobhan"
        rule.alias = "Shivawn"
        model.rules = [rule]
        let adding = try await sending(model.actions, "add_rules") { await model.addRules() }
        await model.select("d-a")
        model.rename = "Dict A renamed"
        let renaming = Task { await model.saveName() }
        await adding.value
        await renaming.value
        #expect(fixture.sent("get_pronunciation_dictionary_metadata").count == 3)
        #expect(model.dictionaries.first { $0.id == "d-a" }?.name == "Dict A renamed",
                "A's fetch after its rename was abandoned")
        #expect(model.selected?.id == "d-a")
        #expect(model.selected?.name == "Dict A renamed")
    }

    // MARK: - N2: typing on the item being saved survives the fetch after the save

    /// Save is pressed on voice A's new name; while it is on its way (the fake holds it until the
    /// typing is done) the owner types a description. The fetch after the save keeps the
    /// description typed, takes the saved name, and takes a field nobody touched (labels changed
    /// elsewhere) from the answer.
    @Test func typingOnAVoiceWhileItsSaveIsOnItsWayIsKept() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_voice":
                await signals.wait(for: "typed")
                return .json(["status": "ok"])
            case "get_voice_by_id":
                return .json(VoicesStudioFakes.voice("v-a", "Voice A renamed", labels: ["accent": "irish"]))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let a = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-a", "Voice A")))
        model.load(rows: [a], selected: a)
        model.editDraft.name = "Voice A renamed"
        let saving = try await sending(model.actions, "edit_voice") { await model.saveEdit() }
        model.editDraft.description = "typed while the save was on its way"
        signals.note("typed")
        await saving.value
        #expect(fixture.sent("get_voice_by_id").count == 1)
        #expect(model.editDraft.description == "typed while the save was on its way",
                "typing after Save was replaced: “\(model.editDraft.description)”")
        #expect(model.editDraft.name == "Voice A renamed")
        #expect(model.editDraft.labels == VoicesSectionModel.labelsText(["accent": "irish"]),
                "an untouched field takes the fresh value")
        #expect(model.selected?.name == "Voice A renamed")
    }

    /// The owner saves A's new name, opens B and comes back to A while the save is on its way:
    /// the form was filled afresh from A's old values meanwhile, so those are not taken for
    /// typing — the fetch after the save puts the saved name in.
    @Test func aVoiceLeftAndReopenedDuringItsSaveTakesTheSavedValues() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_voice":
                await signals.wait(for: "back on A")
                return .json(["status": "ok"])
            case "get_voice_by_id" where request.url.path.hasSuffix("/v-b"):
                return .json(VoicesStudioFakes.voice("v-b", "Voice B"))
            case "get_voice_by_id":
                let name = signals.note("get v-a") == 1 ? "Voice A" : "Voice A renamed"
                return .json(VoicesStudioFakes.voice("v-a", name))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let a = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-a", "Voice A")))
        let b = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-b", "Voice B")))
        model.load(rows: [a, b], selected: a)
        model.editDraft.name = "Voice A renamed"
        let saving = try await sending(model.actions, "edit_voice") { await model.saveEdit() }
        await model.select("v-b")
        await model.select("v-a")
        #expect(model.editDraft.name == "Voice A", "reopened: the form shows A as it is before the save lands")
        signals.note("back on A")
        await saving.value
        #expect(model.editDraft.name == "Voice A renamed", "the saved name: “\(model.editDraft.name)”")
    }

    /// A professional voice's details: Save details is pressed on a new name; the description
    /// typed while it is on its way stays, the saved name and a field nobody touched (labels
    /// changed elsewhere) come from the fetch after the save.
    @Test func typingInAProfessionalVoicesDetailsWhileTheirSaveIsOnItsWayIsKept() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_pvc_voice":
                await signals.wait(for: "typed")
                return .json(["voice_id": "v-p"])
            case "get_voice_by_id":
                return .json(VoicesStudioFakes.voice("v-p", "Pro renamed", category: "professional",
                                                     labels: ["accent": "irish"], settings: VoicesStudioFakes.settings))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let voice = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-p", "Pro", category: "professional",
                                                                          settings: VoicesStudioFakes.settings)))
        model.load(rows: [voice], selected: voice)
        model.professional.name = "Pro renamed"
        let saving = try await sending(model.actions, "edit_pvc_voice") { await model.editProfessional() }
        model.professional.description = "typed while the save was on its way"
        signals.note("typed")
        await saving.value
        #expect(fixture.sent("get_voice_by_id").count == 1)
        #expect(model.professional.description == "typed while the save was on its way",
                "typing after Save details was replaced: “\(model.professional.description)”")
        #expect(model.professional.name == "Pro renamed")
        #expect(model.professional.labels == VoicesSectionModel.labelsText(["accent": "irish"]),
                "an untouched field takes the fresh value")
    }

    /// The settings sliders: a stability dragged while a save of the voice is on its way stays
    /// where it was put; a slider nobody touched (the speed, changed elsewhere) takes the value
    /// the fetch after the save brings.
    @Test func aSliderMovedWhileTheVoiceIsSavedStaysWhereItWasPut() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_voice":
                await signals.wait(for: "dragged")
                return .json(["status": "ok"])
            case "get_voice_by_id":
                return .json(VoicesStudioFakes.voice("v-a", "Voice A renamed", settings: [
                    "stability": 0.4, "similarity_boost": 0.8, "style": 0.1, "speed": 1.1, "use_speaker_boost": true,
                ]))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let a = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-a", "Voice A", settings: VoicesStudioFakes.settings)))
        model.load(rows: [a], selected: a)
        #expect(model.settingsDraft?.stability == 0.4)
        model.editDraft.name = "Voice A renamed"
        let saving = try await sending(model.actions, "edit_voice") { await model.saveEdit() }
        model.settingsDraft?.stability = 0.75
        signals.note("dragged")
        await saving.value
        #expect(fixture.sent("get_voice_by_id").count == 1)
        #expect(model.settingsDraft?.stability == 0.75, "the dragged slider was put back: \(model.settingsDraft?.stability ?? -1)")
        #expect(model.settingsDraft?.speed == 1.1, "an untouched slider takes the fresh value")
    }

    /// Settings saved, then the voice fetched again (after an edit): the sliders show what the
    /// voice holds — the saved values are not mistaken for moves the owner has not saved.
    @Test func savedSettingsAreNotKeptAsUnsavedMoves() async throws {
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_voice_settings", "edit_voice":
                return .json(["status": "ok"])
            case "get_voice_by_id":
                // ElevenLabs holds the saved stability, rounded, and a speed changed elsewhere.
                return .json(VoicesStudioFakes.voice("v-a", "Voice A", settings: [
                    "stability": 0.7, "similarity_boost": 0.8, "style": 0.1, "speed": 1.1, "use_speaker_boost": true,
                ]))
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let a = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v-a", "Voice A", settings: VoicesStudioFakes.settings)))
        model.load(rows: [a], selected: a)
        model.settingsDraft?.stability = 0.7004
        await model.saveSettings()
        #expect(fixture.sent("edit_voice_settings").count == 1)
        model.editDraft.description = "New description"
        await model.saveEdit()
        #expect(model.settingsDraft?.stability == 0.7, "the voice's own (saved) value, not the draft's")
        #expect(model.settingsDraft?.speed == 1.1)
    }

    /// Studio: the project's settings saved; the author typed while the save is on its way stays,
    /// untouched fields take the answer's values.
    @Test func typingInAProjectsSettingsWhileItsSaveIsOnItsWayIsKept() async throws {
        let signals = Signals()
        let saved = VoicesStudioStudioTests.project("p-a", name: "Renamed")
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "edit_project":
                await signals.wait(for: "typed")
                return .json(["project": saved])
            case "get_project_by_id":
                return .json(saved)
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        var before = VoicesStudioStudioTests.project("p-a", name: "First")
        if case .object(var fields) = before {
            fields["title"] = "An older title"
            before = .object(fields)
        }
        let project = try #require(StudioProject(json: before))
        model.load(projects: [project], selected: project)
        model.editDraft.name = "Renamed"
        let saving = try await sending(model.actions, "edit_project") { await model.saveEdit() }
        model.editDraft.author = "typed while saving"
        signals.note("typed")
        await saving.value
        #expect(model.editDraft.author == "typed while saving", "typing after Save was replaced: “\(model.editDraft.author)”")
        #expect(model.editDraft.name == "Renamed")
        #expect(model.editDraft.title == "The Long Road", "an untouched field takes the fresh value")
    }

    nonisolated static func segment(_ id: String, _ text: String) -> JSONValue {
        ["id": .string(id), "speaker_id": "speaker_1", "start_s": 0, "end_s": 2, "text": .string(text)]
    }

    /// Dubbing: one segment's edit is saved; another segment edited while the save is on its
    /// way keeps its edit after the transcript is loaded again. The saved edit is gone (it is the
    /// transcript now).
    @Test func transcriptEditsTypedWhileASaveIsOnItsWayAreKept() async throws {
        let signals = Signals()
        let fixture = VoicesStudioFixture(handler: { request in
            switch request.operationID {
            case "dubbing_transcript_segment_update":
                await signals.wait(for: "typed")
                return .json(["status": "ok"])
            case "dubbing_transcript_get":
                return .json(["segments": [Self.segment("s1", "Hello there"), Self.segment("s2", "World")]])
            default:
                return .jsonText(#"{"detail":"not scripted"}"#, status: 418)
            }
        })
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        let project = try #require(DubbingProject(json: ["project_id": "p-a", "status": "ready", "language_ids": []]))
        let first = try #require(DubbingSegment(json: Self.segment("s1", "Hello")))
        let second = try #require(DubbingSegment(json: Self.segment("s2", "World")))
        model.load(projects: [project], selected: project, source: [first, second])
        model.sourceEdits["s1"] = "Hello there"
        let saving = try await sending(model.actions, "dubbing_transcript_segment_update") { await model.saveSourceEdits() }
        model.sourceEdits["s2"] = "World, typed while saving"
        signals.note("typed")
        await saving.value
        #expect(fixture.sent("dubbing_transcript_get").count == 1)
        #expect(model.sourceEdits == ["s2": "World, typed while saving"], "unsaved edits were dropped: \(model.sourceEdits)")
        #expect(model.sourceSegments.map(\.text) == ["Hello there", "World"])
    }
}
