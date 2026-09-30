import Foundation
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// Headerless audio (PCM, μ-law, A-law) plays: decoded and wrapped as a WAV in memory for the
/// player only, with the rate from the run's output format. And the result line names what
/// was made.
@Suite("ElevenLabs headerless audio and result ids")
@MainActor
struct ShellRawAudioTests {

    // MARK: - Headerless audio

    @Test func muLawAndALawDecodeToTheStandardValues() {
        #expect(ElevenLabsRawAudio.decodeULaw(0xFF) == 0)
        #expect(ElevenLabsRawAudio.decodeULaw(0x80) == 32_124)
        #expect(ElevenLabsRawAudio.decodeULaw(0x00) == -32_124)
        #expect(ElevenLabsRawAudio.decodeALaw(0xD5) == 8)
        #expect(ElevenLabsRawAudio.decodeALaw(0x55) == -8)
        #expect(ElevenLabsRawAudio.decodeALaw(0xAA) == 32_256)
        #expect(ElevenLabsRawAudio.decodeALaw(0x2A) == -32_256)
    }

    @Test func rawAudioIsWrappedAsAWAVForThePlayerOnly() throws {
        let wav = ElevenLabsRawAudio.wav(from: Data([0x01, 0x00, 0xFF, 0x7F]), encoding: .pcm16, sampleRate: 24_000)
        #expect(wav.count == 44 + 4)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        #expect(wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian } == 24_000)
        #expect(Array(wav.suffix(4)) == [0x01, 0x00, 0xFF, 0x7F])

        let ulaw = ElevenLabsRawAudio.wav(from: Data([0xFF, 0x80]), encoding: .ulaw, sampleRate: 8_000)
        #expect(ulaw.count == 44 + 4)
        #expect(Array(ulaw.suffix(4)) == [0x00, 0x00, 0x7C, 0x7D])  // 0, 32124 little-endian
    }

    @Test func theRateComesFromTheRunsOutputFormat() {
        #expect(ElevenLabsRawAudio.sampleRate(outputFormat: "pcm_24000") == 24_000)
        #expect(ElevenLabsRawAudio.sampleRate(outputFormat: "ulaw_8000") == 8_000)
        #expect(ElevenLabsRawAudio.sampleRate(outputFormat: "mp3_44100_128") == 44_100)
        #expect(ElevenLabsRawAudio.sampleRate(outputFormat: nil) == nil)
        #expect(ElevenLabsRawAudio.encoding(url: URL(fileURLWithPath: "/tmp/a.pcm"), contentType: "") == .pcm16)
        #expect(ElevenLabsRawAudio.encoding(url: URL(fileURLWithPath: "/tmp/a"), contentType: "audio/basic") == .ulaw)
        #expect(ElevenLabsRawAudio.encoding(url: URL(fileURLWithPath: "/tmp/a.alaw"), contentType: "audio/mpeg") == .alaw)
        #expect(ElevenLabsRawAudio.encoding(url: URL(fileURLWithPath: "/tmp/a.mp3"), contentType: "audio/mpeg") == nil)
    }

    // MARK: - Ids

    @Test func theResultLineNamesWhatWasMade() {
        let meta = ElevenLabsMeta(status: 200, headers: ["song-id": "song-42", "dubbing-id": "dub-1", "x-dubbing-id": "dub-1"])
        #expect(ElevenLabsMetaLine.identifiers(meta) == [.init(label: "Song", value: "song-42"), .init(label: "Dub", value: "dub-1")])
        #expect(ElevenLabsMetaLine.identifiers(ElevenLabsMeta(status: 200)).isEmpty)
    }
}
