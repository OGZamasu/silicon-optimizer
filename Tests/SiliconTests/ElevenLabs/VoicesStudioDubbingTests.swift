import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Dubbing: a dub needs a file or a link (not both) and a language; the finished dub and its
/// subtitles come back; a project's languages and transcript edits go to the right routes,
/// one edit alone and several together.
@Suite("ElevenLabs dubbing section")
@MainActor
struct VoicesStudioDubbingTests {

    static func dub(_ id: String, status: String = "dubbed") -> JSONValue {
        ["dubbing_id": .string(id), "name": "Trailer", "status": .string(status), "source_language": "en",
         "target_languages": ["es", "fr"], "created_at": "2026-09-20T10:00:00Z",
         "media_metadata": ["content_type": "video/mp4", "duration": 95.5]]
    }

    static func project(_ id: String) -> JSONValue {
        ["project_id": .string(id), "status": "ready", "reference": "Launch video", "source_language": "en",
         "model_id": "dubbing_v2", "media": ["filename": "launch.mp4", "duration_s": 61, "has_video": true],
         "language_ids": ["lang-es"], "revision": 3, "created_at": "2026-09-21T09:00:00Z",
         "updated_at": "2026-09-21T09:05:00Z"]
    }

    @Test func aDubNeedsOneSourceAndALanguageBeforeAnythingIsSent() async throws {
        let scratch = try VoicesStudioScratch()
        defer { scratch.remove() }
        var draft = DubbingDraft()
        #expect(DubbingSectionModel.dubArguments(draft).2 == [
            "Choose a file or give a link to dub.", "Say which language to dub into.",
        ])
        draft.files = [try scratch.file("clip.mp4")]
        draft.sourceURL = "https://example.com/clip.mp4"
        draft.targetLanguage = "es"
        #expect(DubbingSectionModel.dubArguments(draft).2 == ["Dub a file or a link, not both."])
        draft.sourceURL = ""
        draft.speakers = "two"
        #expect(DubbingSectionModel.dubArguments(draft).2 == ["Num speakers must be a whole number."])
    }

    @Test func startingADubUploadsTheFileAndOpensTheNewDub() async throws {
        let scratch = try VoicesStudioScratch()
        defer { scratch.remove() }
        let fixture = VoicesStudioFixture([
            "create_dubbing": [.json(["dubbing_id": "d1", "expected_duration_sec": 120])],
            "list_dubs": [.json(["dubs": [Self.dub("d1", status: "dubbing")], "next_cursor": "", "has_more": false])],
            "get_dubbed_metadata": [.json(Self.dub("d1", status: "dubbing"))],
        ])
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        model.draft.files = [try scratch.file("clip.mp4")]
        model.draft.targetLanguage = "es"
        model.draft.speakers = "2"
        model.draft.watermark = true
        await model.createDub()
        let body = fixture.multipart("create_dubbing")
        #expect(body.contains(#"name="file"; filename="clip.mp4""#))
        #expect(body.contains(#"name="target_lang""#))
        #expect(body.contains(#"name="num_speakers""#))
        #expect(body.contains(#"name="watermark""#))
        #expect(!body.contains(#"name="csv_file""#))
        #expect(model.selectedDub?.id == "d1")
        #expect(model.selectedDub?.status == "dubbing")
        #expect(model.draft == DubbingDraft())
    }

    @Test func aFinishedDubDownloadsPerLanguageAndItsSubtitlesComeAsText() async throws {
        let fixture = VoicesStudioFixture([
            "get_dubbed_metadata": [.json(Self.dub("d1"))],
            "get_dubbed_file": [.init(status: 200, headers: ["content-type": "video/mp4"], body: Data(repeating: 7, count: 32))],
            "get_dubbing_transcripts": [.json(["transcript_format": "srt", "srt": "1\n00:00:00,000 --> 00:00:02,000\nHola\n"])],
        ])
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        model.load(dubs: [try #require(DubbingDub(json: Self.dub("d1")))])
        await model.selectDub("d1")
        #expect(model.downloadLanguage == "es")
        await model.download()
        #expect(fixture.path("get_dubbed_file") == "/v1/dubbing/d1/audio/es")
        #expect(model.downloads["es"]?.isVideo == true)

        model.transcriptLanguage = "source"
        model.transcriptFormat = "srt"
        await model.loadTranscript()
        #expect(fixture.path("get_dubbing_transcripts") == "/v1/dubbing/d1/transcripts/source/format/srt")
        #expect(model.transcript?.contains("Hola") == true)
    }

    @Test func deletingADubNamesIt() async throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        let dub = try #require(DubbingDub(json: Self.dub("d1")))
        model.load(dubs: [dub], selected: dub)
        let asked = try await voicesStudioConfirm(model.actions.runner("delete_dubbing"), answer: false) {
            await model.deleteDub()
        }
        #expect(asked?.title == "Delete the dub “Trailer”?")
        #expect(fixture.sent("delete_dubbing").isEmpty)
    }

    @Test func aProjectLanguageCarriesItsCloningStrengthInsideVoiceSettings() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        #expect(DubbingSectionModel.cloningRange == 0...10)
        model.load(projects: [], selected: try #require(DubbingProject(json: Self.project("p1"))))
        model.newLanguage = "fr"
        #expect(model.addLanguageArguments() == ["project_id": "p1", "target_language": "fr"])
        model.setsCloningStrength = true
        model.cloningStrength = 4
        let arguments = try #require(model.addLanguageArguments())
        #expect(arguments["voice_settings"] == ["cloning_strength": 4])
        #expect(fixture.client.validate("dubbing_language_create", arguments: arguments).isEmpty)
    }

    @Test func oneTranscriptEditGoesAloneAndSeveralGoTogether() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        model.load(projects: [], selected: try #require(DubbingProject(json: Self.project("p1"))), languageID: "lang-es")
        model.sourceEdits = ["s1": "Hello there"]
        let single = try #require(model.sourceSaveCall())
        #expect(single.operationID == "dubbing_transcript_segment_update")
        #expect(single.arguments == ["project_id": "p1", "segment_id": "s1", "text": "Hello there"])
        model.sourceEdits["s2"] = "General Kenobi"
        let bulk = try #require(model.sourceSaveCall())
        #expect(bulk.operationID == "dubbing_transcript_segments_update")
        #expect(bulk.arguments["segments"] == ["s1": ["text": "Hello there"], "s2": ["text": "General Kenobi"]])
        #expect(fixture.client.validate(bulk.operationID, arguments: bulk.arguments).isEmpty)

        model.targetEdits = ["s1": "Hola", "s2": "General Kenobi"]
        let target = try #require(model.targetSaveCall())
        #expect(target.operationID == "dubbing_target_transcript_segments_update")
        #expect(target.arguments["language_id"] == "lang-es")
        #expect(fixture.client.validate(target.operationID, arguments: target.arguments).isEmpty)
    }

    @Test func aProjectLoadsItsLanguagesAndItsTranslation() async throws {
        let fixture = VoicesStudioFixture([
            "dubbing_project_get": [.json(Self.project("p1"))],
            "dubbing_language_list": [.json(["languages": [[
                "language_id": "lang-es", "project_id": "p1", "target_language": "es", "status": "completed",
                "revision": 1, "voice_settings": ["cloning_strength": 7],
                "outputs": ["lossless_audio": "https://files.example/es.flac?sig=abc"],
                "created_at": "2026-09-21T09:00:00Z", "updated_at": "2026-09-21T09:00:00Z",
            ]]])],
            "dubbing_target_transcript_get": [.json(["target_language": "es", "revision": 1, "segments": [
                ["id": "s1", "speaker_id": "sp1", "start_s": 0, "end_s": 2, "source_text": "Hello", "translation": "Hola"],
            ]])],
        ])
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        model.load(projects: [try #require(DubbingProject(json: Self.project("p1")))])
        await model.selectProject("p1")
        #expect(model.selectedProject?.title == "Launch video")
        #expect(model.languages.first?.losslessAudio?.host == "files.example")
        await model.loadTargetTranscript("lang-es")
        #expect(model.targetSegments.first?.text == "Hello")
        #expect(model.targetSegments.first?.translation == "Hola")
        #expect(fixture.path("dubbing_target_transcript_get") == "/v1/dubbing/project/p1/language/lang-es/transcript")
    }

    @Test func deletingAProjectSaysEveryLanguageGoesWithIt() async throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        model.load(projects: [], selected: try #require(DubbingProject(json: Self.project("p1"))))
        let asked = try await voicesStudioConfirm(model.actions.runner("dubbing_project_delete"), answer: false) {
            await model.deleteProject()
        }
        #expect(asked?.title == "Delete the dubbing project “Launch video”?")
        #expect(asked?.consequence.contains("every language") == true)
    }
}
