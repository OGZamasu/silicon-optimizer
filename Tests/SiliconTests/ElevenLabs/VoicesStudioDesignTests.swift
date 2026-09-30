import Foundation
import Testing
@testable import SiliconElevenLabs
@testable import SiliconUI

/// Voice design: limits checked before anything is billed, previews read out of the answer in
/// order, and the passed-over ones reported when one is saved.
@Suite("ElevenLabs voice design section")
@MainActor
struct VoicesStudioDesignTests {

    @Test func aDescriptionTooShortForTheSpecIsRefusedBeforeAnythingIsBilled() async throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = VoiceDesignSectionModel(environment: fixture.environment)
        model.voiceDescription = "Deep voice"
        model.autoGenerateText = false
        model.text = "Too short."
        await model.generate()
        #expect(model.problems.contains("The description needs at least 20 characters."))
        #expect(model.problems.contains("The preview text needs at least 100 characters."))
        #expect(fixture.transport.recorded.isEmpty)
    }

    @Test func designingReadsThePreviewsOutInOrderAndSavingReportsTheOnesPassedOver() async throws {
        let clip = { (byte: UInt8) in Data(repeating: byte, count: 40).base64EncodedString() }
        let fixture = VoicesStudioFixture([
            "text_to_voice_design": [.json([
                "previews": [
                    ["audio_base_64": .string(clip(1)), "generated_voice_id": "g1", "media_type": "audio/mpeg",
                     "duration_secs": 4.2, "language": "en"],
                    ["audio_base_64": .string(clip(2)), "generated_voice_id": "g2", "media_type": "audio/mpeg",
                     "duration_secs": 4.4, "language": "en"],
                    ["audio_base_64": .string(clip(3)), "generated_voice_id": "g3", "media_type": "audio/mpeg",
                     "duration_secs": 3.9, "language": "en"],
                ],
                "text": "Some words ElevenLabs wrote.",
            ])],
            "create_voice": [.json(VoicesStudioFakes.voice("saved1", "Narrator", category: "generated"))],
        ])
        defer { fixture.clean() }
        let model = VoiceDesignSectionModel(environment: fixture.environment)
        model.voiceDescription = "A calm, low narrator with a warm Scottish accent."
        model.modelID = "eleven_ttv_v3"
        model.seed = "42"
        await model.generate()

        let sent = try #require(fixture.body("text_to_voice_design"))
        #expect(sent["auto_generate_text"] == true)
        #expect(sent["model_id"] == "eleven_ttv_v3")
        #expect(sent["seed"] == 42)
        #expect(sent["text"] == .null)
        #expect(model.previews.map(\.id) == ["g1", "g2", "g3"])
        for (index, preview) in model.previews.enumerated() {
            let file = try #require(preview.file)
            #expect(try Data(contentsOf: file) == Data(repeating: UInt8(index + 1), count: 40))
        }
        #expect(model.previewText == "Some words ElevenLabs wrote.")
        #expect(model.saveDescription == model.voiceDescription)

        model.notePlayed(model.previews[0])
        model.notePlayed(model.previews[2])
        model.chosenPreview = "g3"
        model.saveName = "Narrator"
        #expect(model.canSave)
        await model.save()
        let saved = try #require(fixture.body("create_voice"))
        #expect(saved["generated_voice_id"] == "g3")
        #expect(saved["voice_name"] == "Narrator")
        #expect(saved["played_not_selected_voice_ids"] == ["g1"])
        #expect(model.savedVoiceID == "saved1")
    }

    @Test func designingSaysItUsesCreditsAndEstimatesFromTheText() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = VoiceDesignSectionModel(environment: fixture.environment)
        let runner = try #require(model.actions.runner("text_to_voice_design"))
        #expect(runner.operation.billable)
        #expect(runner.costNote != nil)
        #expect(model.estimatedCharacters == nil)
        model.autoGenerateText = false
        model.text = String(repeating: "a", count: 150)
        #expect(model.estimatedCharacters == 150)
    }

    @Test func aRemixStartsFromTheChosenVoiceAndTheDesignOnlySettingsStayOut() throws {
        let fixture = VoicesStudioFixture()
        defer { fixture.clean() }
        let model = VoiceDesignSectionModel(environment: fixture.environment)
        model.mode = .remix
        model.voiceDescription = "Brighter."
        model.shouldEnhance = true
        model.setsQuality = true
        let missing = model.arguments()
        #expect(missing.problems == ["Choose the voice to remix."])
        model.remixVoiceID = "v1"
        let built = model.arguments()
        #expect(built.problems.isEmpty)
        #expect(built.arguments["voice_id"] == "v1")
        #expect(built.arguments["should_enhance"] == nil)
        #expect(built.arguments["quality"] == nil)
        #expect(fixture.client.validate("text_to_voice_remix", arguments: built.arguments).isEmpty)
    }

    @Test func aPreviewDesignedWithoutAudioIsFetchedFromItsStream() async throws {
        let fixture = VoicesStudioFixture([
            "text_to_voice_preview_stream": [.audio(VoicesStudioFakes.audio)],
        ])
        defer { fixture.clean() }
        let model = VoiceDesignSectionModel(environment: fixture.environment)
        model.load(previews: [VoiceDesignPreview(generatedVoiceID: "g9")], text: nil)
        await model.fetchAudio(for: model.previews[0])
        #expect(fixture.path("text_to_voice_preview_stream") == "/v1/text-to-voice/g9/stream")
        #expect(model.previews[0].file != nil)
    }
}
