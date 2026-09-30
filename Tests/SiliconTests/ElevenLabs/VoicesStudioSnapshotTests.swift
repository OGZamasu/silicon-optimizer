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
