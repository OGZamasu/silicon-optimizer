import Foundation
import SiliconElevenLabs
import Testing
@testable import SiliconUI

/// Each creative screen's model: what it sends for what the owner chose, what it refuses to
/// send, and what it makes of the answer — end to end through the client and the in-memory
/// transport.
@Suite("ElevenLabs creative screens")
@MainActor
struct CreativeScreenTests {

    // MARK: - Controls

    @Test func finelySteppedSlidersRoundInsteadOfDrawingTicks() {
        #expect(abs(CreativeSlider.snapped(0.337, to: 0.01, in: 0...1) - 0.34) < 1e-9)
        #expect(CreativeSlider.snapped(1.3, to: 0.01, in: 0.7...1.2) == 1.2)
        #expect(abs(CreativeSlider.snapped(15.4, to: 1, in: 3...120) - 15) < 1e-9)
        #expect(CreativeSlider.snapped(0.123, to: nil, in: 0...1) == 0.123)
    }

    @Test func outputFormatsAreNamedAndRawOnesSayTheyCannotBePlayedHere() {
        #expect(CreativeOutputFormat.title("mp3_44100_128") == "MP3 · 44.1 kHz · 128 kbps")
        #expect(CreativeOutputFormat.title("mp3_22050_32") == "MP3 · 22.05 kHz · 32 kbps")
        #expect(CreativeOutputFormat.title("pcm_16000") == "PCM · 16 kHz")
        #expect(CreativeOutputFormat.title("ulaw_8000") == "μ-law · 8 kHz")
        #expect(CreativeOutputFormat.title("auto") == "Automatic")
        #expect(CreativeOutputFormat.playabilityNote("mp3_44100_128") == nil)
        #expect(CreativeOutputFormat.playabilityNote("opus_48000_64") == nil)
        for raw in ["pcm_44100", "ulaw_8000", "alaw_8000"] {
            #expect(CreativeOutputFormat.playabilityNote(raw) != nil, "\(raw)")
        }
    }

    // MARK: - Fixtures

    static let planJSON: JSONValue = [
        "positive_global_styles": ["lo-fi", "warm"],
        "negative_global_styles": ["harsh"],
        "sections": [
            ["section_name": "Intro", "positive_local_styles": ["piano"], "negative_local_styles": [],
             "duration_ms": 10_000, "lines": []],
            ["section_name": "Chorus", "positive_local_styles": [], "negative_local_styles": [],
             "duration_ms": 15_000, "lines": ["La la la"], "source_from": ["song_id": "s1"]],
        ],
    ]

    static func historyItem(_ id: String) -> JSONValue {
        ["history_item_id": .string(id), "request_id": .string("req-\(id)"), "voice_id": "voice-rachel",
         "model_id": "eleven_flash_v2_5", "voice_name": "Rachel", "voice_category": "premade",
         "text": .string("Hello from \(id)"), "date_unix": 1_790_000_000, "character_count_change_from": 100,
         "character_count_change_to": 112, "content_type": "audio/mpeg", "state": "created", "source": "TTS"]
    }
}
