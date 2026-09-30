import Foundation
import SiliconElevenLabs
import Testing
@testable import SiliconUI

/// Timings read out of speech, transcript and alignment answers, grouped into lines and
/// written back out as subtitles.
@Suite("ElevenLabs creative timings")
struct CreativeTimelineTests {

    @Test func charactersBecomeWordsSplitAtWhitespace() {
        let words = CreativeTimeline.words(fromCharacterAlignments: [CreativeRigTimings.alignment("Hi there.")])
        #expect(words.map(\.text) == ["Hi", "there."])
        #expect(words[0].start == 0)
        #expect(abs(words[0].end - 0.16) < 0.0001)
        #expect(abs(words[1].start - 0.24) < 0.0001)
    }

    /// A streamed answer's chunks may each start their times at zero; they are laid end to end.
    @Test func chunksWhoseTimesStartOverFollowTheChunkBefore() {
        let words = CreativeTimeline.words(fromCharacterAlignments: [
            CreativeRigTimings.alignment("One "), CreativeRigTimings.alignment("two"),
        ])
        #expect(words.map(\.text) == ["One", "two"])
        #expect(abs(words[1].start - 0.32) < 0.0001)
        // Chunks already on one clock are left alone.
        let absolute = CreativeTimeline.words(fromCharacterAlignments: [
            CreativeRigTimings.alignment("One "), CreativeRigTimings.alignment("two", start: 1.0),
        ])
        #expect(abs(absolute[1].start - 1.0) < 0.0001)
    }

    @Test func alignmentsAreFoundInEveryJSONPartOfAnAnswer() {
        let meta = ElevenLabsMeta(status: 200)
        let result = ElevenLabsResult.parts([
            .json(["alignment": CreativeRigTimings.alignment("A"), "audio_base64_bytes": 10]),
            .json(["normalized_alignment": CreativeRigTimings.alignment("B")]),
            .file(URL(fileURLWithPath: "/dev/null"), contentType: "audio/mpeg", bytes: 0),
        ], meta)
        #expect(CreativeTimeline.characterAlignments(in: result).count == 2)
        // A collected stream: the audio as a file, the chunks as one JSON array.
        let collected = ElevenLabsResult.parts([
            .file(URL(fileURLWithPath: "/dev/null"), contentType: "audio/mpeg", bytes: 0),
            .json([["alignment": CreativeRigTimings.alignment("A ")], ["alignment": CreativeRigTimings.alignment("B")]]),
        ], meta)
        #expect(CreativeTimeline.words(fromCharacterAlignments: CreativeTimeline.characterAlignments(in: collected))
                    .map(\.text) == ["A", "B"])
    }

    @Test func aTranscriptLeavesOutSpacingAndKeepsSpeakersAndSounds() {
        let transcript: JSONValue = ["text": "Hello (laughs) there", "words": [
            ["text": "Hello", "start": 0.0, "end": 0.4, "type": "word", "speaker_id": "speaker_0", "logprob": 0],
            ["text": " ", "start": 0.4, "end": 0.5, "type": "spacing", "speaker_id": "speaker_0", "logprob": 0],
            ["text": "(laughs)", "start": 0.5, "end": 1.0, "type": "audio_event", "speaker_id": "speaker_0", "logprob": 0],
            ["text": "there", "start": 1.0, "end": 1.3, "type": "word", "speaker_id": "speaker_1", "logprob": 0],
        ]]
        let words = CreativeTimeline.words(fromTranscript: transcript)
        #expect(words.map(\.text) == ["Hello", "(laughs)", "there"])
        #expect(words.map(\.isEvent) == [false, true, false])
        #expect(words.map(\.speaker) == ["speaker_0", "speaker_0", "speaker_1"])
    }

    @Test func aMultichannelTranscriptIsMergedInTimeOrderWithChannelsAsSpeakers() {
        let transcript: JSONValue = ["transcripts": [
            ["channel_index": 0, "text": "a c", "words": [
                ["text": "a", "start": 0.0, "end": 0.2, "type": "word", "logprob": 0],
                ["text": "c", "start": 1.0, "end": 1.2, "type": "word", "logprob": 0],
            ]],
            ["channel_index": 1, "text": "b", "words": [
                ["text": "b", "start": 0.5, "end": 0.7, "type": "word", "logprob": 0],
            ]],
        ]]
        let words = CreativeTimeline.words(fromTranscript: transcript)
        #expect(words.map(\.text) == ["a", "b", "c"])
        #expect(words.map(\.speaker) == ["channel_0", "channel_1", "channel_0"])
        #expect(CreativeTimeline.speakerName("channel_1") == "Channel 2")
        #expect(CreativeTimeline.speakerName("speaker_0") == "Speaker 1")
        #expect(CreativeTimeline.speakerName("agent") == "Agent")
    }

    @Test func aForcedAlignmentKeepsEachWordsLoss() {
        let words = CreativeTimeline.words(fromForcedAlignment: ["loss": 0.2, "characters": [], "words": [
            ["text": "Hello", "start": 0.1, "end": 0.5, "loss": 0.1],
            ["text": " ", "start": 0.5, "end": 0.5, "loss": 0],
            ["text": "world", "start": 0.6, "end": 1.0, "loss": 0.4],
        ]])
        #expect(words.map(\.text) == ["Hello", "world"])
        #expect(words.map(\.loss) == [0.1, 0.4])
    }

    @Test func segmentsBreakAtSpeakersPausesAndSentences() {
        func word(_ text: String, _ start: Double, _ speaker: String? = nil) -> CreativeTimedWord {
            CreativeTimedWord(text: text, start: start, end: start + 0.3, speaker: speaker)
        }
        let words = [
            word("One", 0), word("two", 0.4), word("three", 0.8), word("four.", 1.2), word("Five", 1.6),
            word("six", 4.0), // a pause
            word("seven", 4.4, "speaker_1"), // another speaker
        ]
        let segments = CreativeTimeline.segments(words)
        #expect(segments.map(\.text) == ["One two three four.", "Five", "six", "seven"])
        #expect(segments.map(\.id) == [0, 1, 2, 3])
    }

    @Test func subtitlesAreWrittenInSubRipAndWebVTT() {
        let segments = [
            CreativeSegment(id: 0, start: 0, end: 1.25, speaker: "speaker_0", words: [
                CreativeTimedWord(text: "Hello,", start: 0, end: 0.5), CreativeTimedWord(text: "you", start: 0.6, end: 1.25),
            ]),
            CreativeSegment(id: 1, start: 3661.5, end: 3662, speaker: "speaker_1", words: [
                CreativeTimedWord(text: "Bye", start: 3661.5, end: 3662), CreativeTimedWord(text: "!", start: 3662, end: 3662),
            ]),
        ]
        #expect(CreativeTimeline.srt(segments) == """
        1
        00:00:00,000 --> 00:00:01,250
        Speaker 1: Hello, you

        2
        01:01:01,500 --> 01:01:02,000
        Speaker 2: Bye!

        """)
        #expect(CreativeTimeline.vtt(segments, speakers: false) == """
        WEBVTT

        00:00:00.000 --> 00:00:01.250
        Hello, you

        01:01:01.500 --> 01:01:02.000
        Bye!

        """)
        #expect(CreativeTimeline.plainText(segments) == "Speaker 1: Hello, you\nSpeaker 2: Bye!")
    }

    @Test func theWordBeingHeardIsFoundByTime() {
        let words = (0..<10).map { CreativeTimedWord(text: "w\($0)", start: Double($0), end: Double($0) + 0.5) }
        #expect(CreativeTimeline.wordIndex(at: 3.2, in: words) == 3)
        #expect(CreativeTimeline.wordIndex(at: 3.7, in: words) == nil)
        #expect(CreativeTimeline.wordIndex(at: 0, in: []) == nil)
    }

    @Test func wordsAsJSONKeepEverythingTheyCarry() {
        let json = CreativeTimeline.json([CreativeTimedWord(text: "(sigh)", start: 1, end: 2, speaker: "speaker_0", isEvent: true, loss: 0.3)])
        #expect(json == [["text": "(sigh)", "start": 1, "end": 2, "speaker": "speaker_0", "event": true, "loss": 0.3]])
    }
}

/// Alignment fixtures for tests that do not need a rig.
enum CreativeRigTimings {
    /// A character alignment for `text`, 80 ms a character.
    static func alignment(_ text: String, start: Double = 0) -> JSONValue {
        let characters = text.map { String($0) }
        return [
            "characters": .array(characters.map(JSONValue.string)),
            "character_start_times_seconds": .array(characters.indices.map { .number(start + Double($0) * 0.08) }),
            "character_end_times_seconds": .array(characters.indices.map { .number(start + Double($0 + 1) * 0.08) }),
        ]
    }
}
