import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// My voices: the list and its paging, one voice's settings and samples, deleting with the
/// voice named, instant cloning as a multipart upload, the professional workflow and the
/// similar-voices search — all over the fake transport.
@Suite("ElevenLabs voices section")
@MainActor
struct VoicesStudioVoicesTests {

    @Test func theListSendsItsFiltersAndPagesWithTheTokenItWasGiven() async throws {
        let fixture = VoicesStudioFixture([
            "get_user_voices_v2": [
                .json(["voices": [VoicesStudioFakes.voice("v1", "Ada")], "has_more": true, "total_count": 2,
                       "next_page_token": "page-2"]),
                .json(["voices": [VoicesStudioFakes.voice("v2", "Brian")], "has_more": false, "total_count": 2]),
            ],
        ])
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        model.search = "narrator"
        model.category = "cloned"
        model.sort = "name"
        await model.refresh()
        #expect(model.rows.map(\.name) == ["Ada"])
        #expect(model.hasMore)
        #expect(model.totalCount == 2)
        let first = fixture.query("get_user_voices_v2")
        #expect(first.contains { $0 == ("search", "narrator") })
        #expect(first.contains { $0 == ("category", "cloned") })
        #expect(first.contains { $0 == ("sort", "name") })
        #expect(!first.contains { $0.0 == "next_page_token" })

        await model.loadMore()
        #expect(model.rows.map(\.name) == ["Ada", "Brian"])
        #expect(!model.hasMore)
        #expect(fixture.query("get_user_voices_v2").contains { $0 == ("next_page_token", "page-2") })
        #expect(fixture.transport.hostViolations.isEmpty)
    }

    @Test func aFailedListSaysWhyWhereTheListIs() async throws {
        let fixture = VoicesStudioFixture([
            "get_user_voices_v2": [.jsonText(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#, status: 401)],
        ])
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        await model.refresh()
        #expect(model.rows.isEmpty)
        #expect(model.listProblem?.contains("Invalid API key") == true)
        #expect(model.actions.last == nil, "a list failure stays with the list, not the action area")
    }

    @Test func selectingAVoiceFetchesItWithItsSettingsAndSavingSendsTheSliders() async throws {
        let fixture = VoicesStudioFixture([
            "get_voice_by_id": [.json(VoicesStudioFakes.voice("v1", "Ada", settings: VoicesStudioFakes.settings))],
            "edit_voice_settings": [.json(["status": "ok"])],
        ])
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        await model.select("v1")
        #expect(model.selected?.name == "Ada")
        #expect(fixture.query("get_voice_by_id").contains { $0 == ("with_settings", "true") })
        #expect(model.settingsDraft?.stability == 0.4)

        model.settingsDraft?.stability = 0.65
        await model.saveSettings()
        #expect(fixture.path("edit_voice_settings") == "/v1/voices/v1/settings/edit")
        let body = try #require(fixture.body("edit_voice_settings"))
        #expect(body["stability"] == 0.65)
        #expect(body["similarity_boost"] == 0.8)
        #expect(body["use_speaker_boost"] == true)
    }

    @Test func theSlidersUseTheRangesTheSpecGives() {
        #expect(VoicesSectionModel.stabilityRange == 0...1)
        #expect(VoicesSectionModel.similarityRange == 0...1)
        // The spec gives style and speed a default but no bounds; the sliders fall back to the
        // documented span and pick up bounds if a refresh adds them.
        #expect(VoicesStudioSchema.range("edit_voice_settings", "speed") == nil)
        #expect(VoicesSectionModel.speedRange.contains(1.0))
    }

    @Test func deletingAVoiceNamesItAndSendsNothingWhenDeclined() async throws {
        let fixture = VoicesStudioFixture(["delete_voice": [.json(["status": "ok"])]])
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let ada = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v1", "Ada")))
        model.load(rows: [ada], selected: ada)

        let declined = try await voicesStudioConfirm(model.actions.runner("delete_voice"), answer: false) {
            await model.deleteSelected()
        }
        #expect(declined?.title == "Delete the voice “Ada”?")
        #expect(declined?.consequence.contains("“Ada”") == true)
        #expect(fixture.sent("delete_voice").isEmpty)
        #expect(model.selected?.id == "v1")

        _ = try await voicesStudioConfirm(model.actions.runner("delete_voice"), answer: true) {
            await model.deleteSelected()
        }
        #expect(fixture.sent("delete_voice").count == 1)
        #expect(fixture.sent("delete_voice").first?.request.method == "DELETE")
        #expect(model.selected == nil)
        #expect(model.rows.isEmpty)
    }

    @Test func aSampleOfAnInstantCloneAndOfAProfessionalOneComeFromTheirOwnRoutes() async throws {
        let fixture = VoicesStudioFixture([
            "get_audio_from_sample": [.audio(VoicesStudioFakes.audio)],
            "get_pvc_sample_audio": [.json(["audio_base_64": .string(VoicesStudioFakes.audio.base64EncodedString()),
                                            "voice_id": "p1", "sample_id": "s2", "media_type": "audio/mpeg"])],
        ])
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let clone = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v1", "Ada", samples: [VoicesStudioFakes.sample("s1", "a.mp3")])))
        model.load(rows: [clone], selected: clone)
        await model.playSample(clone.samples[0])
        #expect(model.sampleFiles["s1"] != nil)
        #expect(fixture.path("get_audio_from_sample") == "/v1/voices/v1/samples/s1/audio")

        let pro = try #require(VoicesVoice(json: VoicesStudioFakes.voice("p1", "Pro", category: "professional",
                                                                         samples: [VoicesStudioFakes.sample("s2", "b.wav")])))
        model.load(rows: [pro], selected: pro)
        await model.playSample(pro.samples[0])
        #expect(fixture.path("get_pvc_sample_audio") == "/v1/voices/pvc/p1/samples/s2/audio")
        let file = try #require(model.sampleFiles["s2"])
        #expect(try Data(contentsOf: file) == VoicesStudioFakes.audio)
    }

    @Test func instantCloningUploadsTheRecordingsWithTheLabelsAsJSONText() async throws {
        let scratch = try VoicesStudioScratch()
        defer { scratch.remove() }
        let fixture = VoicesStudioFixture([
            "add_voice": [.json(["voice_id": "new1", "requires_verification": false])],
            "get_user_voices_v2": [.json(["voices": [VoicesStudioFakes.voice("new1", "Me")], "has_more": false, "total_count": 1]),
                                   .json(["voices": [VoicesStudioFakes.voice("new1", "Me")], "has_more": false, "total_count": 1])],
            "get_voice_by_id": [.json(VoicesStudioFakes.voice("new1", "Me"))],
        ])
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        #expect(!model.canClone)
        model.clone.name = "Me"
        model.clone.labels = "accent: Irish\nage: young"
        model.clone.files = [try scratch.file("one.mp3"), try scratch.file("two.wav")]
        model.clone.removeBackgroundNoise = true
        #expect(model.canClone)
        await model.runClone()

        let body = fixture.multipart("add_voice")
        #expect(body.contains(#"name="files"; filename="one.mp3""#))
        #expect(body.contains(#"name="files"; filename="two.wav""#))
        #expect(body.contains(#"{"accent":"Irish","age":"young"}"#))
        #expect(body.contains(#"name="remove_background_noise""#))
        #expect(model.selected?.id == "new1")
        #expect(model.mode == .voices)
        #expect(model.clone.files.isEmpty)
    }

    @Test func theProfessionalWorkflowTakesEachStepToItsRoute() async throws {
        let scratch = try VoicesStudioScratch()
        defer { scratch.remove() }
        let pro = VoicesStudioFakes.voice(
            "p1", "Pro", category: "professional", samples: [VoicesStudioFakes.sample("s1", "take.wav")],
            fineTuning: ["is_allowed_to_fine_tune": true, "state": ["eleven_multilingual_v2": "not_started"],
                         "verification_failures": [], "verification_attempts_count": 0,
                         "manual_verification_requested": false]
        )
        let fixture = VoicesStudioFixture([
            "create_pvc_voice": [.json(["voice_id": "p1"])],
            "get_user_voices_v2": [.json(["voices": [pro], "has_more": false, "total_count": 1])],
            "get_voice_by_id": Array(repeating: .json(pro), count: 6),
            "edit_pvc_voice_sample": [.json(["voice_id": "p1"])],
            "get_pvc_sample_speakers": [.json(["voice_id": "p1", "sample_id": "s1", "status": "completed",
                                                "speakers": ["sp1": ["speaker_id": "sp1", "duration_secs": 12.5]]])],
            "get_pvc_sample_visual_waveform": [.json(["sample_id": "s1", "visual_waveform": [0.1, 0.5, -0.3]])],
            "verify_pvc_voice_captcha": [.json(["status": "ok"])],
            "run_pvc_voice_training": [.json(["status": "ok"])],
        ])
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        model.professional.name = "Pro"
        model.professional.language = "en"
        model.professional.labels = "accent: Scottish"
        await model.createProfessional()
        #expect(fixture.body("create_pvc_voice") == ["name": "Pro", "language": "en", "labels": ["accent": "Scottish"]])
        #expect(model.selected?.isProfessional == true)
        #expect(model.trainingModels == ["eleven_multilingual_v2"])

        let sample = try #require(model.selected?.samples.first)
        await model.loadWaveform(sample)
        #expect(model.waveforms["s1"] == [0.1, 0.5, -0.3])
        await model.loadSpeakers(sample)
        #expect(model.speakers["s1"]?.speakers.map(\.id) == ["sp1"])
        model.sampleDrafts["s1"]?.selectedSpeakers = ["sp1"]
        model.sampleDrafts["s1"]?.trimStart = "1500"
        await model.saveSample(sample)
        let edit = try #require(fixture.body("edit_pvc_voice_sample"))
        #expect(edit["selected_speaker_ids"] == ["sp1"])
        #expect(edit["trim_start_time"] == 1500)
        #expect(edit["trim_end_time"] == .null)

        model.captchaRecording = [try scratch.file("me-reading.m4a")]
        await model.verifyCaptcha()
        #expect(fixture.multipart("verify_pvc_voice_captcha").contains(#"name="recording"; filename="me-reading.m4a""#))

        model.trainingModel = "eleven_multilingual_v2"
        await model.train()
        #expect(fixture.path("run_pvc_voice_training") == "/v1/voices/pvc/p1/train")
        #expect(fixture.body("run_pvc_voice_training") == ["model_id": "eleven_multilingual_v2"])
    }

    @Test func aSimilarVoiceIsAddedUnderTheNameGivenIt() async throws {
        let scratch = try VoicesStudioScratch()
        defer { scratch.remove() }
        let fixture = VoicesStudioFixture([
            "get_similar_library_voices": [.json(["voices": [[
                "public_owner_id": "owner1", "voice_id": "lib1", "name": "Library Lou", "accent": "british",
                "gender": "male", "age": "old", "descriptive": "deep", "use_case": "narration",
                "category": "professional", "date_unix": 1, "usage_character_count_1y": 1,
                "usage_character_count_7d": 1, "play_api_usage_character_count_1y": 1, "cloned_by_count": 3,
                "free_users_allowed": true, "live_moderation_enabled": false, "featured": false,
            ]], "has_more": false])],
            "add_sharing_voice": [.json(["voice_id": "mine1"])],
        ])
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        model.similarFile = [try scratch.file("sounds-like.mp3")]
        model.similarityThreshold = "0.5"
        model.similarTopK = "5"
        await model.findSimilar()
        let body = fixture.multipart("get_similar_library_voices")
        #expect(body.contains(#"name="audio_file"; filename="sounds-like.mp3""#))
        #expect(body.contains("0.5"))
        let match = try #require(model.similarResults.first)
        #expect(match.summary == "british · male · old · deep · narration")

        model.addingName[match.id] = "Lou (library)"
        await model.addFromLibrary(match)
        #expect(fixture.path("add_sharing_voice") == "/v1/voices/add/owner1/lib1")
        #expect(fixture.body("add_sharing_voice") == ["new_name": "Lou (library)"])
    }

    @Test func copyingToAnotherWorkspaceIsARealWorldQuestionThatNamesBoth() async throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let ada = try #require(VoicesVoice(json: VoicesStudioFakes.voice("v1", "Ada")))
        model.load(rows: [ada], selected: ada)
        model.replicateWorkspaceID = "ws-eu"
        let asked = try await voicesStudioConfirm(
            model.actions.runner("replicate_voice_to_isolated_environment"), answer: false
        ) { await model.replicate() }
        #expect(asked?.risk == .realWorld)
        #expect(asked?.title.contains("“Ada” to the workspace ws-eu") == true)
        #expect(fixture.sent("replicate_voice_to_isolated_environment").isEmpty)
    }

    @Test func labelsAreReadOneKeyValuePairALine() {
        #expect(VoicesSectionModel.labels(from: "accent: British\nage:  old \nnonsense\n: empty") ==
                ["accent": "British", "age": "old"])
        #expect(VoicesSectionModel.labelsText(["b": "2", "a": "1"]) == "a: 1\nb: 2")
        #expect(VoicesSectionModel.labelsField("") == nil)
    }
}
