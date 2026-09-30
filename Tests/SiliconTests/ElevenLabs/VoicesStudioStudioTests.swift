import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Studio: a project created from a document with its dictionaries as JSON texts, a project
/// opened with its chapters and snapshots, a chapter's paragraphs written back as the spec's
/// content blocks, dictionaries attached, deletes that name what goes, and podcasts in both
/// formats.
@Suite("ElevenLabs Studio section")
@MainActor
struct VoicesStudioStudioTests {

    static func project(_ id: String, name: String = "The Long Road", chapters: [JSONValue] = []) -> JSONValue {
        ["project_id": .string(id), "name": .string(name), "create_date_unix": 1_780_000_000,
         "created_by_user_id": "u1", "default_title_voice_ref_id": "r1", "default_paragraph_voice_ref_id": "r2",
         "default_model_id": "eleven_multilingual_v2", "can_be_downloaded": true, "volume_normalization": false,
         "state": "default", "access_level": "admin", "quality_check_on": false,
         "quality_check_on_when_bulk_convert": false, "default_title_voice_id": "v1",
         "default_paragraph_voice_id": "v2", "title": "The Long Road", "author": "A. Writer",
         "quality_preset": "high", "chapters": .array(chapters), "pronunciation_dictionary_locators": [],
         "pronunciation_dictionary_versions": [], "apply_text_normalization": "auto", "assets": [], "voices": []]
    }

    static func chapter(_ id: String, name: String, blocks: [JSONValue] = [], credits: Int = 1_200) -> JSONValue {
        ["chapter_id": .string(id), "name": .string(name), "can_be_downloaded": false, "state": "default",
         "statistics": ["characters_unconverted": 1_200, "characters_converted": 0, "paragraphs_converted": 0,
                        "paragraphs_unconverted": 3, "credits_needed_to_convert": .number(Double(credits))],
         "content": ["blocks": .array(blocks)]]
    }

    @Test func aProjectFromADocumentUploadsItWithItsDictionariesAsJSONTexts() throws {
        let scratch = try VoicesStudioScratch()
        defer { scratch.remove() }
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        var draft = StudioProjectDraft()
        #expect(StudioSectionModel.projectArguments(draft).2 == ["Give the project a name."])
        draft.name = "The Long Road"
        draft.source = .document
        #expect(StudioSectionModel.projectArguments(draft).2 == ["Choose the document to read from."])
        draft.document = [try scratch.file("book.epub")]
        draft.qualityPreset = "high"
        draft.genres = "travel, memoir"
        draft.autoConvert = true
        draft.dictionaries = [StudioDictionaryLocator(id: "d1", versionID: "ver1")]
        let (arguments, files, problems) = StudioSectionModel.projectArguments(draft)
        #expect(problems.isEmpty)
        #expect(files["from_document"]?.first?.filename == "book.epub")
        #expect(arguments["genres"] == ["travel", "memoir"])
        #expect(arguments["pronunciation_dictionary_locators"] == [#"{"pronunciation_dictionary_id":"d1","version_id":"ver1"}"#])
        #expect(arguments["auto_convert"] == true)
        #expect(fixture.client.validate("add_project", arguments: arguments, files: files).isEmpty)
    }

    @Test func openingAProjectLoadsItsDetailsSnapshotsAndMutedTracks() async throws {
        let fixture = VoicesStudioFixture([
            "get_project_by_id": [.json(Self.project("p1", chapters: [Self.chapter("c1", name: "One"),
                                                                      Self.chapter("c2", name: "Two", credits: 800)]))],
            "get_project_snapshots": [.json(["snapshots": [["project_snapshot_id": "s1", "project_id": "p1",
                                                            "created_at_unix": 1_780_000_100, "name": "First pass"]]])],
            "get_project_muted_tracks_endpoint": [.json(["chapter_ids": ["c2"]])],
        ])
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        await model.select("p1")
        #expect(model.selected?.chapters.map(\.name) == ["One", "Two"])
        #expect(model.selected?.creditsToConvert == 2_000)
        #expect(model.projectSnapshots.map(\.name) == ["First pass"])
        #expect(model.mutedChapters == ["c2"])
        #expect(model.editDraft.paragraphVoiceID == "v2")
    }

    @Test func anEditedParagraphIsWrittenBackAsContentBlocksInItsVoice() async throws {
        let blocks: [JSONValue] = [
            ["block_id": "b1", "nodes": [["type": "tts_node", "text": "It was late.", "voice_id": "v2",
                                          "project_voice_ref_id": "r2"]]],
            ["block_id": "b2", "nodes": [["type": "tts_node", "text": "The road went on.", "voice_id": "v3",
                                          "project_voice_ref_id": "r3"]]],
        ]
        let fixture = VoicesStudioFixture([
            "get_chapter_by_id_endpoint": [.json(Self.chapter("c1", name: "One", blocks: blocks))],
            "get_chapter_snapshots": [.json(["snapshots": []])],
        ])
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        model.load(projects: [], selected: try #require(StudioProject(json: Self.project("p1"))))
        await model.openChapter("c1")
        #expect(model.chapterIsEditable)
        model.blockEdits["b2"] = "The road went on and on."
        let arguments = try #require(model.chapterArguments())
        #expect(arguments["name"] == nil)
        #expect(arguments["content"] == ["blocks": [
            ["block_id": "b1", "nodes": [["type": "tts_node", "text": "It was late.", "voice_id": "v2"]]],
            ["block_id": "b2", "nodes": [["type": "tts_node", "text": "The road went on and on.", "voice_id": "v3"]]],
        ]])
        #expect(fixture.client.validate("edit_chapter", arguments: arguments).isEmpty)
    }

    @Test func aChapterWithContentTheEditorCannotWriteIsReadOnly() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let chapter = try #require(StudioChapter(json: Self.chapter("c1", name: "One", blocks: [
            ["block_id": "b1", "nodes": [["type": "_other"]]],
        ])))
        model.load(projects: [], selected: try #require(StudioProject(json: Self.project("p1"))), chapter: chapter)
        #expect(!model.chapterIsEditable)
        model.blockEdits["b1"] = "changed"
        #expect(model.chapterArguments()?["content"] == nil)
    }

    @Test func attachingADictionarySendsEveryLocatorWithItsVersion() async throws {
        let fixture = VoicesStudioFixture([
            "update_pronunciation_dictionaries": [.json(["status": "ok"])],
            "get_project_by_id": [.json(Self.project("p1"))],
        ])
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        model.load(projects: [], selected: try #require(StudioProject(json: Self.project("p1"))))
        await model.setDictionary(StudioDictionary(id: "d1", name: "Names", latestVersionID: "ver3"), attached: true)
        #expect(fixture.body("update_pronunciation_dictionaries") == [
            "pronunciation_dictionary_locators": [["pronunciation_dictionary_id": "d1", "version_id": "ver3"]],
            "invalidate_affected_text": true,
        ])
    }

    @Test func deletingAProjectOrAChapterNamesIt() async throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let project = try #require(StudioProject(json: Self.project("p1", chapters: [Self.chapter("c1", name: "One")])))
        model.load(projects: [project], selected: project)
        let projectQuestion = try await voicesStudioConfirm(model.actions.runner("delete_project"), answer: false) {
            await model.delete()
        }
        #expect(projectQuestion?.title == "Delete the Studio project “The Long Road”?")
        let chapterQuestion = try await voicesStudioConfirm(model.actions.runner("delete_chapter_endpoint"), answer: false) {
            await model.deleteChapter(project.chapters[0])
        }
        #expect(chapterQuestion?.title == "Delete the chapter “One” of “The Long Road”?")
        #expect(fixture.transport.recorded.isEmpty)
    }

    @Test func convertingSaysItUsesCreditsWithTheEstimateElevenLabsGives() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let runner = try #require(model.actions.runner("convert_project_endpoint"))
        #expect(runner.operation.billable)
        let project = try #require(StudioProject(json: Self.project("p1", chapters: [Self.chapter("c1", name: "One")])))
        #expect(ElevenLabsCostNote.text(for: runner.operation, characters: project.creditsToConvert)?.contains("1,200") == true)
    }

    @Test func aPodcastIsAConversationOrABulletinFromTextOrAPage() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        var draft = StudioPodcastDraft()
        #expect(StudioSectionModel.podcastArguments(draft).1 == [
            "Choose the model to speak with.", "Choose the host's voice.", "Choose the guest's voice.",
            "Give the text to make the podcast from.",
        ])
        draft.modelID = "eleven_multilingual_v2"
        draft.hostVoiceID = "v1"
        draft.guestVoiceID = "v2"
        draft.text = "Today: why the road is long."
        draft.highlights = "Why roads are long\nWhat to pack"
        draft.durationScale = "short"
        let conversation = StudioSectionModel.podcastArguments(draft)
        #expect(conversation.1.isEmpty)
        #expect(conversation.0["mode"] == ["type": "conversation", "conversation": ["host_voice_id": "v1", "guest_voice_id": "v2"]])
        #expect(conversation.0["source"] == ["type": "text", "text": "Today: why the road is long."])
        #expect(fixture.client.validate("create_podcast", arguments: conversation.0).isEmpty)

        draft.conversation = false
        draft.fromURL = true
        draft.url = "https://example.com/article"
        let bulletin = StudioSectionModel.podcastArguments(draft)
        #expect(bulletin.0["mode"] == ["type": "bulletin", "bulletin": ["host_voice_id": "v1"]])
        #expect(bulletin.0["source"] == ["type": "url", "url": "https://example.com/article"])
        #expect(fixture.client.validate("create_podcast", arguments: bulletin.0).isEmpty)
    }

    @Test func aSnapshotPlaysAsMPEGAndItsArchiveDownloads() async throws {
        let fixture = VoicesStudioFixture([
            "stream_project_snapshot_audio_endpoint": [.audio(VoicesStudioFakes.audio)],
            "stream_project_snapshot_archive_endpoint": [.init(status: 200, headers: ["content-type": "application/zip"],
                                                               body: Data([0x50, 0x4B, 3, 4]))],
        ])
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let snapshot = try #require(StudioSnapshot(json: ["project_snapshot_id": "s1", "name": "First pass"]))
        model.load(projects: [], selected: try #require(StudioProject(json: Self.project("p1"))), snapshots: [snapshot])
        await model.playSnapshot(snapshot)
        #expect(fixture.body("stream_project_snapshot_audio_endpoint") == ["convert_to_mpeg": true])
        #expect(model.snapshotAudio["s1"]?.isAudio == true)
        await model.downloadArchive(snapshot)
        #expect(fixture.path("stream_project_snapshot_archive_endpoint") == "/v1/studio/projects/p1/snapshots/s1/archive")
        #expect(model.snapshotAudio["s1/zip"] != nil)
    }
}
