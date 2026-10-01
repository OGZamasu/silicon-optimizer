@preconcurrency import AVFoundation
import Foundation
import SiliconElevenLabs
import Testing
@testable import SiliconUI

/// The live screens' audio pipeline, driven with synthetic buffers: what the microphone side
/// sends, what the speaker side plays, the jitter buffer, and an interruption. No test touches a
/// microphone or a speaker.
@Suite("ElevenLabs live audio")
struct LiveAudioTests {

    @Test func theMicrophoneIsConvertedToTheSocketsFormatInChunks() throws {
        let converter = try #require(LiveCaptureConverter(target: .pcm(rate: 16_000), chunkMilliseconds: 100))
        #expect(converter.chunkBytes == 3_200)
        var sent = Data()
        // 48 kHz stereo float, a second of it in ten device-sized pieces.
        for _ in 0..<10 {
            for chunk in converter.process(LiveSignal.sine(seconds: 0.1, frequency: 440, rate: 48_000, channels: 2)) {
                #expect(chunk.count == 3_200)
                sent.append(chunk)
            }
        }
        if let rest = converter.flush() { sent.append(rest) }
        let samples = LiveSignal.samples(sent)
        // A second of 16 kHz audio, give or take the resampler's latency.
        #expect(abs(samples.count - 16_000) < 200, "\(samples.count)")
        let frequency = LiveSignal.frequency(samples.map { Float($0) / 32_768 }, rate: 16_000)
        #expect(abs(frequency - 440) < 25, "\(frequency)")
        #expect(converter.level > 0.7)
    }

    @Test func eightKilohertzMuLawIsG711() throws {
        let converter = try #require(LiveCaptureConverter(target: .ulaw, chunkMilliseconds: 100))
        #expect(converter.chunkBytes == 800)
        let chunks = converter.process(LiveSignal.sine(seconds: 0.5, frequency: 300, rate: 44_100))
        #expect(chunks.count >= 4)
        #expect(chunks.allSatisfy { $0.count == 800 })
        // The encoder pairs with the shell's decoder: silence, the extremes, and a round trip.
        #expect(LiveCaptureConverter.encodeULaw(0) == 0xFF)
        #expect(LiveCaptureConverter.encodeULaw(32_767) == 0x80)
        #expect(LiveCaptureConverter.encodeULaw(-32_768) == 0x00)
        for value in stride(from: -32_000, through: 32_000, by: 997) {
            let back = Int(ElevenLabsRawAudio.decodeULaw(LiveCaptureConverter.encodeULaw(Int16(value))))
            #expect(abs(back - value) <= max(8, abs(value) / 16), "\(value) → \(back)")
        }
    }

    @Test func mutedMeansSilenceOfTheSameLengthIsSent() throws {
        let converter = try #require(LiveCaptureConverter(target: .pcm(rate: 16_000), chunkMilliseconds: 100))
        converter.muted = true
        let chunks = converter.process(LiveSignal.sine(seconds: 0.3, frequency: 440, rate: 48_000))
        #expect(chunks.count >= 2)
        #expect(chunks.allSatisfy { $0.allSatisfy { $0 == 0 } })
        #expect(converter.level == 0)
        converter.muted = false
        let loud = converter.process(LiveSignal.sine(seconds: 0.3, frequency: 440, rate: 48_000))
        #expect(loud.contains { $0.contains { $0 != 0 } })
    }

    @Test func theLevelFollowsLoudness() throws {
        let converter = try #require(LiveCaptureConverter(target: .pcm(rate: 16_000), chunkMilliseconds: 100))
        _ = converter.process(LiveSignal.sine(seconds: 0.2, frequency: 440, amplitude: 0.9))
        let loud = converter.level
        let fresh = try #require(LiveCaptureConverter(target: .pcm(rate: 16_000), chunkMilliseconds: 100))
        _ = fresh.process(LiveSignal.sine(seconds: 0.2, frequency: 440, amplitude: 0.0005))
        let quiet = fresh.level
        #expect(loud > 0.8)
        #expect(quiet < 0.2)
        #expect(LiveCaptureConverter(target: .mp3(rate: 44_100, kbps: 128), chunkMilliseconds: 100) == nil)
    }

    /// A sample can straddle two socket messages; it is put back together.
    @Test func pcmFromTheSocketDecodesAcrossOddBoundaries() {
        let decoder = LivePlaybackDecoder(encoding: .pcm(rate: 16_000))
        var bytes = Data()
        for value: Int16 in [1_000, -1_000, 32_767, -32_768, 0] {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        var samples: [Float] = []
        for piece in [bytes.prefix(3), bytes.dropFirst(3).prefix(4), bytes.dropFirst(7)] {
            for buffer in decoder.decode(Data(piece)) {
                #expect(buffer.format.sampleRate == 16_000)
                samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            }
        }
        #expect(samples == [1_000, -1_000, 32_767, -32_768, 0].map { Float($0) / 32_768 })
    }

    @Test func muLawAndALawFromTheSocketDecode() {
        let ulaw = LivePlaybackDecoder(encoding: .ulaw).decode(Data([0xFF, 0x80, 0x00]))
        let values = ulaw.flatMap { UnsafeBufferPointer(start: $0.floatChannelData![0], count: Int($0.frameLength)) }
        #expect(values == [0xFF, 0x80, 0x00].map { Float(ElevenLabsRawAudio.decodeULaw($0)) / 32_768 })
        #expect(ulaw.first?.format.sampleRate == 8_000)
        let alaw = LivePlaybackDecoder(encoding: .alaw).decode(Data([0xD5]))
        #expect(alaw.first?.frameLength == 1)
        #expect(!LivePlaybackDecoder(encoding: .opus(rate: 48_000, kbps: 64)).canPlay)
    }

    @Test func theJitterBufferHoldsThenFlowsAndAnInterruptionDropsEverything() {
        var jitter = LiveJitterBuffer(prebuffer: 0.15)
        func piece() -> AVAudioPCMBuffer { LiveSignal.sine(seconds: 0.05, frequency: 200, rate: 16_000) }
        #expect(jitter.add(piece()).isEmpty)
        #expect(jitter.add(piece()).isEmpty)
        #expect(jitter.add(piece()).count == 3, "150 ms held: it flows")
        #expect(jitter.add(piece()).count == 1, "flowing: straight through")
        jitter.played(0.2)
        #expect(!jitter.flowing, "ran dry: hold again")
        #expect(jitter.add(piece()).isEmpty)
        jitter.flush()
        #expect(jitter.held.isEmpty)
        #expect(!jitter.flowing)
        #expect(jitter.add(piece()).isEmpty)
        #expect(jitter.finish().count == 1, "the end of a stream lets what is held play")
    }

    @MainActor
    @Test func playbackStartsAfterThePrebufferAndAnInterruptionSilencesIt() async throws {
        let audio = FakeLiveAudio()
        let playback = LivePlayback(audio: audio, encoding: .pcm(rate: 16_000))
        playback.append(LiveSignal.pcm(seconds: 0.1))
        #expect(audio.scheduled.isEmpty, "100 ms is under the prebuffer")
        playback.append(LiveSignal.pcm(seconds: 0.1))
        #expect(abs(audio.scheduledSeconds - 0.2) < 0.001)
        playback.interrupt()
        #expect(audio.flushes == 1)
        // Late completions of what was dropped count for nothing.
        try await Task.sleep(for: .milliseconds(50))
        #expect(playback.playedSeconds == 0)
        playback.append(LiveSignal.pcm(seconds: 0.05))
        #expect(abs(audio.scheduledSeconds - 0.2) < 0.001, "after an interruption it holds again")
        playback.finish()
        #expect(abs(audio.scheduledSeconds - 0.25) < 0.001)
        audio.finishPlaying()
        try await Task.sleep(for: .milliseconds(50))
        #expect(abs(playback.playedSeconds - 0.05) < 0.001)
    }

    @MainActor
    @Test func aFileIsReadIntoOneSecondChunks() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { TemporaryFileSink.removeScratch(folder) }
        let url = folder.appendingPathComponent("talk.wav")
        let samples = (0..<Int(2.5 * 44_100)).map { Float(0.4 * sin(2 * Double.pi * 330 * Double($0) / 44_100)) }
        try MicRecorder.wavData(samples: samples, sampleRate: 44_100).write(to: url)
        let converter = try #require(LiveCaptureConverter(target: .pcm(rate: 16_000), chunkMilliseconds: 1_000))
        let (chunks, total) = try LiveAudioFile.chunks(of: url, with: converter)
        #expect(abs(total - 2.5) < 0.01)
        #expect(chunks.count == 3)
        #expect(chunks.prefix(2).allSatisfy { $0.count == 32_000 })
        #expect(abs(chunks.reduce(0) { $0 + $1.count } - 80_000) < 400)
    }
}
