import AppKit
import Foundation
import SwiftUI
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Every voices-and-studio screen drawn with realistic fake data, light and dark, narrow and
/// wide — to look at (set `VOICES_STUDIO_SNAPSHOTS` to keep the PNGs), and so a screen that
/// cannot be drawn at all fails here rather than in the owner's window.
@Suite("ElevenLabs voices and studio screens draw", .serialized)
@MainActor
struct VoicesStudioSnapshotTests {

    // MARK: Voices

    @Test func myVoicesWithAVoiceOpen() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let voices = try Self.voices()
        model.load(rows: voices, selected: voices[0], hasMore: true, total: 48)
        try VoicesStudioSnapshots.render("voices-list", height: 1900) { VoicesScreen(model: model) }
    }

    @Test func instantCloneAndSimilarVoices() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        model.mode = .clone
        model.clone.name = "My narration voice"
        model.clone.labels = "accent: Irish\nuse_case: narration"
        try VoicesStudioSnapshots.render("voices-clone", height: 760) { VoicesScreen(model: model) }

        model.mode = .similar
        model.load(similar: [
            try #require(VoicesLibraryMatch(json: ["public_owner_id": "o1", "voice_id": "l1", "name": "Harold",
                                                   "accent": "british", "gender": "male", "age": "old",
                                                   "descriptive": "deep", "use_case": "narration"])),
            try #require(VoicesLibraryMatch(json: ["public_owner_id": "o2", "voice_id": "l2", "name": "Juniper",
                                                   "accent": "american", "gender": "female", "age": "young",
                                                   "descriptive": "bright", "use_case": "social media"])),
        ])
        try VoicesStudioSnapshots.render("voices-similar", height: 760) { VoicesScreen(model: model) }
    }

    @Test func theProfessionalCloneWorkflow() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = VoicesSectionModel(environment: fixture.environment)
        let pro = try #require(VoicesVoice(json: VoicesStudioFakes.voice(
            "p1", "Studio Me", category: "professional",
            samples: [VoicesStudioFakes.sample("s1", "chapter-one.wav", seconds: 1260),
                      VoicesStudioFakes.sample("s2", "chapter-two.wav", seconds: 1480)],
            fineTuning: ["is_allowed_to_fine_tune": true,
                         "state": ["eleven_multilingual_v2": "fine_tuning", "eleven_v3": "not_started"],
                         "progress": ["eleven_multilingual_v2": 0.42], "verification_failures": [],
                         "verification_attempts_count": 1, "manual_verification_requested": false,
                         "dataset_duration_seconds": 2740]
        )))
        model.mode = .professional
        model.load(rows: [pro], selected: pro)
        model.load(waveform: (0..<120).map { sin(Double($0) / 6) * Double($0 % 7 + 3) }, for: "s1")
        try VoicesStudioSnapshots.render("voices-professional", height: 2100) { VoicesScreen(model: model) }
    }

    // MARK: Voice design and library

    @Test func voiceDesignWithPreviews() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = VoiceDesignSectionModel(environment: fixture.environment)
        model.voiceDescription = "A calm, low-pitched narrator in their fifties with a warm Scottish accent."
        model.load(previews: [
            VoiceDesignPreview(generatedVoiceID: "g1", durationSecs: 6.2, language: "en"),
            VoiceDesignPreview(generatedVoiceID: "g2", durationSecs: 5.8, language: "en"),
            VoiceDesignPreview(generatedVoiceID: "g3", durationSecs: 6.0, language: "en"),
        ], text: "The glen was quiet that morning, and the mist sat low over the water.")
        model.saveName = "Glen narrator"
        model.saveDescription = model.voiceDescription
        try VoicesStudioSnapshots.render("voice-design", height: 1300) { VoiceDesignScreen(model: model) }
    }

    @Test func theVoiceLibrary() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = VoiceLibrarySectionModel(environment: fixture.environment)
        let rows: [VoiceLibraryVoice] = try [
            ("Lena", "british", "female", "young", "narration", 1_204, true),
            ("Marcus", "american", "male", "middle_aged", "conversational", 88_120, false),
            ("Aiko", "japanese", "female", "young", "characters", 3_400, false),
        ].enumerated().map { index, entry in
            try #require(VoiceLibraryVoice(json: [
                "public_owner_id": .string("owner\(index)"), "voice_id": .string("lib\(index)"), "name": .string(entry.0),
                "accent": .string(entry.1), "gender": .string(entry.2), "age": .string(entry.3),
                "use_case": .string(entry.4), "descriptive": "calm", "category": "professional",
                "cloned_by_count": .number(Double(entry.5)), "usage_character_count_1y": 1_250_000,
                "featured": .bool(entry.6), "description": "A clear, friendly voice for long reads.",
                "preview_url": "https://storage.example/preview.mp3",
            ]))
        }
        model.load(rows: rows, hasMore: true, total: 5_021)
        try VoicesStudioSnapshots.render("voice-library", height: 900) { VoiceLibraryScreen(model: model) }
    }

    // MARK: Dubbing

    @Test func dubsAndOneDub() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        let dubs = try [
            VoicesStudioDubbingTests.dub("d1"), VoicesStudioDubbingTests.dub("d2", status: "dubbing"),
            VoicesStudioDubbingTests.dub("d3", status: "failed"),
        ].map { try #require(DubbingDub(json: $0)) }
        model.load(dubs: dubs, selected: dubs[0])
        model.downloadLanguage = "es"
        model.load(transcript: "1\n00:00:00,000 --> 00:00:02,400\nBienvenidos a la presentación.\n\n2\n00:00:02,400 --> 00:00:05,100\nHoy os enseñamos algo nuevo.")
        try VoicesStudioSnapshots.render("dubbing-dubs", height: 1900) { DubbingScreen(model: model) }
    }

    @Test func aDubbingProjectWithItsTranscript() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = DubbingSectionModel(environment: fixture.environment)
        model.mode = .projects
        let project = try #require(DubbingProject(json: VoicesStudioDubbingTests.project("p1")))
        let language = try #require(DubbingLanguage(json: [
            "language_id": "lang-es", "target_language": "es", "status": "completed",
            "voice_settings": ["cloning_strength": 7], "outputs": ["lossless_audio": "https://files.example/es.flac"],
        ]))
        let segments = try [("s1", "Welcome to the launch.", "Bienvenidos al lanzamiento."),
                            ("s2", "Today we show you something new.", "Hoy os enseñamos algo nuevo.")]
            .enumerated().map { index, entry in
                try #require(DubbingSegment(json: ["id": .string(entry.0), "speaker_id": "speaker_1",
                                                   "start_s": .number(Double(index) * 2.5), "end_s": .number(Double(index) * 2.5 + 2.4),
                                                   "text": .string(entry.1), "source_text": .string(entry.1),
                                                   "translation": .string(entry.2)]))
            }
        model.load(projects: [project], selected: project, languages: [language], source: segments,
                   target: segments, languageID: "lang-es")
        try VoicesStudioSnapshots.render("dubbing-project", height: 1700) { DubbingScreen(model: model) }
    }

    // MARK: Studio

    @Test func aStudioProjectWithAChapterOpen() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        let chapters = [
            VoicesStudioStudioTests.chapter("c1", name: "Chapter 1 — Leaving", blocks: [
                ["block_id": "b1", "nodes": [["type": "tts_node", "text": "It was late when we left the city.", "voice_id": "v2"]]],
                ["block_id": "b2", "nodes": [["type": "tts_node", "text": "The road went north, into the hills.", "voice_id": "v2"]]],
            ]),
            VoicesStudioStudioTests.chapter("c2", name: "Chapter 2 — The Pass", credits: 2_310),
        ]
        let project = try #require(StudioProject(json: VoicesStudioStudioTests.project("p1", chapters: chapters)))
        let other = try #require(StudioProject(json: VoicesStudioStudioTests.project("p2", name: "Quarterly report")))
        let snapshot = try #require(StudioSnapshot(json: ["project_snapshot_id": "s1", "name": "First full pass",
                                                          "created_at_unix": 1_780_000_500]))
        model.load(projects: [project, other], selected: project, snapshots: [snapshot],
                   chapter: try #require(StudioChapter(json: chapters[0])),
                   dictionaries: [StudioDictionary(id: "d1", name: "Place names", latestVersionID: "ver1")],
                   models: [VoicesStudioSpeechModel(id: "eleven_multilingual_v2", name: "Eleven Multilingual v2")])
        try VoicesStudioSnapshots.render("studio-project", height: 1900) { StudioScreen(model: model) }
    }

    @Test func aNewPodcast() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = StudioSectionModel(environment: fixture.environment)
        model.load(projects: [], models: [VoicesStudioSpeechModel(id: "eleven_multilingual_v2", name: "Eleven Multilingual v2")])
        model.mode = .podcast
        model.podcast.text = "Why the road is long: a conversation about travel, maps and patience."
        try VoicesStudioSnapshots.render("studio-podcast", height: 900) { StudioScreen(model: model) }
    }

    // MARK: Productions

    @Test func aProductionsOrderWithItsItems() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = ProductionsSectionModel(environment: fixture.environment)
        let order = try #require(ProductionsOrder(json: VoicesStudioProductionsTests.order("o1", items: [VoicesStudioProductionsTests.dubItem])))
        let others = try [VoicesStudioProductionsTests.order("o2", state: "done", total: 80),
                          VoicesStudioProductionsTests.order("o3", state: "submitted", total: 1_150, sandbox: true)]
            .map { try #require(ProductionsOrder(json: $0)) }
        model.load(orders: [order] + others, selected: order,
                   media: [ProductionsMedia(id: "prodmedia_1", name: "launch-video.mp4", contentType: "video/mp4", language: "en")],
                   languages: ["kind": "pair", "language_pairs": [
                       ["source_language": ["code": "en", "label": "English"],
                        "destination_languages": [["code": "es-ES", "label": "Spanish (Spain)"],
                                                  ["code": "fr-FR", "label": "French (France)"],
                                                  ["code": "de-DE", "label": "German"]]],
                   ]])
        model.item.mediaIDs = ["prodmedia_1"]
        model.item.sourceLanguage = "en"
        model.item.destinationLanguages = ["es-ES"]
        try VoicesStudioSnapshots.render("productions-order", height: 1700) { ProductionsScreen(model: model) }
    }

    // MARK: Flows

    @Test func flowsImageGenerations() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = FlowsSectionModel(environment: fixture.environment)
        model.mode = .image
        model.choose("gpt-image-1", for: .image)
        model.form(.image)?.nodes.first { $0.field.name == "prompt" }?.text = "A lighthouse at dusk, painted in gouache"
        model.load(generations: try [
            ["id": "img_01HZX", "status": "completed", "content_url": "https://files.example/a.png", "content_mime_type": "image/png"],
            ["id": "img_01HZY", "status": "generating"],
            ["id": "img_01HZZ", "status": "failed", "error_message": "The prompt was blocked."],
        ].map { try #require(FlowsGeneration(json: $0)) }, for: .image)
        try VoicesStudioSnapshots.render("flows-image", height: 1500) { FlowsScreen(model: model) }
    }

    @Test func flowsTemplateRun() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = FlowsSectionModel(environment: fixture.environment)
        model.mode = .templates
        let template = try #require(FlowsTemplate(json: [
            "id": "t1", "name": "Product video", "description": "A short product video from a script and a photo.",
            "has_more_versions": false,
            "versions": [["version_id": "ver2", "published_at_unix": 1_780_000_000, "is_latest": true,
                          "inputs": [["id": "script", "content_schema": ["type": "string"]],
                                     ["id": "settings", "content_schema": ["type": "object"]]],
                          "outputs": [["id": "video", "content_schema": ["type": "string"]]]]],
        ]))
        model.load(templates: [template], open: template, runs: [
            try #require(FlowsRun(json: ["id": "run_1", "status": "completed", "outputs": ["video": "https://files.example/v.mp4"]])),
        ])
        model.inputs = ["script": "Meet the new lamp.", "settings": #"{"length": 15}"#]
        try VoicesStudioSnapshots.render("flows-template", height: 1100) { FlowsScreen(model: model) }
    }

    // MARK: Pronunciation

    @Test func aPronunciationDictionary() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = PronunciationSectionModel(environment: fixture.environment)
        let rules: [JSONValue] = [
            ["string_to_replace": "Leicester", "type": "alias", "alias": "Lester", "case_sensitive": true, "word_boundaries": true],
            ["string_to_replace": "Edinburgh", "type": "phoneme", "phoneme": "ˈɛdɪnbərə", "alphabet": "ipa",
             "case_sensitive": false, "word_boundaries": true],
        ]
        let dictionary = try #require(PronunciationDictionary(json: VoicesStudioPronunciationTests.dictionary("d1", rules: rules)))
        var other = try #require(PronunciationDictionary(json: VoicesStudioPronunciationTests.dictionary("d2")))
        other.name = "Product terms"
        other.archivedAt = 1_780_000_100
        model.load(dictionaries: [dictionary, other], selected: dictionary)
        var rule = PronunciationRule()
        rule.stringToReplace = "Worcestershire"
        rule.alias = "Wooster-sheer"
        model.rules = [rule]
        try VoicesStudioSnapshots.render("pronunciation", height: 1200) { PronunciationScreen(model: model) }
    }

    // MARK: Fakes

    static func voices() throws -> [VoicesVoice] {
        try [
            VoicesStudioFakes.voice("v1", "Rachel Reads", labels: ["accent": "american", "age": "young", "gender": "female",
                                                                   "use_case": "narration"],
                                    samples: [VoicesStudioFakes.sample("s1", "intro.mp3"), VoicesStudioFakes.sample("s2", "chapter.mp3", seconds: 96)],
                                    settings: VoicesStudioFakes.settings),
            VoicesStudioFakes.voice("v2", "Brian", category: "premade", labels: ["accent": "american", "age": "middle_aged",
                                                                                "gender": "male", "use_case": "narration"]),
            VoicesStudioFakes.voice("v3", "Glen narrator", category: "generated", labels: ["accent": "scottish"]),
            VoicesStudioFakes.voice("v4", "Studio Me", category: "professional",
                                    fineTuning: ["is_allowed_to_fine_tune": true, "state": ["eleven_multilingual_v2": "fine_tuned"],
                                                 "verification_failures": [], "verification_attempts_count": 1,
                                                 "manual_verification_requested": false]),
        ].map { try #require(VoicesVoice(json: $0)) }
    }
}
