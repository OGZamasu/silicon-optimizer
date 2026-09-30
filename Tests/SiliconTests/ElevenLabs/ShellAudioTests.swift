import AVFoundation
import Foundation
import Testing
@testable import SiliconUI

/// Audio arriving in pieces is decoded as it comes — MP3 packet by packet, raw PCM sample by
/// sample even across chunk boundaries. These drive the decoders only; nothing here opens an
/// audio device or plays a sound.
@Suite("ElevenLabs stream audio")
struct ShellAudioTests {

    /// Thirty silent MPEG-1 Layer III frames (128 kb/s, 44.1 kHz): valid MP3 without an
    /// encoder, which macOS does not ship.
    static let silentMP3: Data = {
        var data = Data()
        for _ in 0..<30 { data.append(contentsOf: [0xFF, 0xFB, 0x90, 0x64] + [UInt8](repeating: 0, count: 413)) }
        return data
    }()

    @Test func mp3IsDecodedWhileItIsStillArriving() {
        let decoder = ElevenLabsMP3StreamDecoder()
        var buffers: [AVAudioPCMBuffer] = []
        decoder.onBuffer = { buffers.append($0) }
        let chunks = stride(from: 0, to: Self.silentMP3.count, by: 1_000).map {
            Self.silentMP3[$0..<min($0 + 1_000, Self.silentMP3.count)]
        }
        decoder.feed(Data(chunks[0]))
        decoder.feed(Data(chunks[1]))
        let early = buffers.count
        for chunk in chunks.dropFirst(2) { decoder.feed(Data(chunk)) }
        #expect(early > 0, "nothing was decoded until the stream was nearly over")
        #expect(buffers.count > early)
        let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        #expect(frames > 20 * 1_152)
        #expect(buffers.first?.format.sampleRate == 44_100)
    }

    @Test func somethingThatIsNotMP3IsIgnoredRatherThanCrashing() {
        let decoder = ElevenLabsMP3StreamDecoder()
        var buffers = 0
        decoder.onBuffer = { _ in buffers += 1 }
        decoder.feed(Data([1, 2, 3, 4, 5, 6]))
        decoder.feed(Data(repeating: 0x42, count: 4_096))
        #expect(buffers == 0)
    }

    @Test func pcmSamplesThatStraddleChunksAreKept() throws {
        let decoder = ElevenLabsPCMStreamDecoder(sampleRate: 24_000)
        var samples: [Float] = []
        decoder.onBuffer = { buffer in
            #expect(buffer.format.sampleRate == 24_000)
            let channel = buffer.floatChannelData![0]
            samples += (0..<Int(buffer.frameLength)).map { channel[$0] }
        }
        decoder.feed(Data([0x00]))                    // half a sample
        decoder.feed(Data([0x00, 0xFF, 0x7F, 0x00]))  // …its other half, a whole one, half another
        decoder.feed(Data([0x80]))
        #expect(samples == [0, Float(32_767) / 32_768, -1])
    }

    @MainActor
    @Test func aFormatThatCannotPlayLiveSaysSoAndStillCounts() {
        let player = ElevenLabsStreamPlayer(outputFormat: "ulaw_8000")
        #expect(player.problem != nil)
        player.append(Data([1, 2, 3]))
        #expect(player.receivedBytes == 3)
        player.stop()
        #expect(!player.isPlaying)
        #expect(ElevenLabsStreamPlayer(outputFormat: "mp3_44100_128").problem == nil)
        #expect(ElevenLabsStreamPlayer(outputFormat: "pcm_16000").problem == nil)
        #expect(ElevenLabsStreamPlayer().problem == nil)
    }

    @Test func streamedFilesAreNamedForWhatTheyHold() {
        #expect(ElevenLabsStreamCollector.fileExtension(for: "audio/mpeg") == "mp3")
        #expect(ElevenLabsStreamCollector.fileExtension(for: "audio/wav; charset=binary") == "wav")
        #expect(ElevenLabsStreamCollector.fileExtension(for: "audio/pcm") == "pcm")
        #expect(ElevenLabsStreamCollector.fileExtension(for: "application/zip") == "zip")
        #expect(ElevenLabsStreamCollector.fileExtension(for: "audio/x-something") == "audio")
        #expect(ElevenLabsStreamCollector.fileExtension(for: "application/x-unknown") == "bin")
    }

    @MainActor
    @Test func headerlessAudioIsNotHandedToAPlayer() {
        #expect(ElevenLabsFileResult.isRawAudio(url: URL(fileURLWithPath: "/tmp/a.pcm"), contentType: "audio/pcm"))
        #expect(ElevenLabsFileResult.isRawAudio(url: URL(fileURLWithPath: "/tmp/a.bin"), contentType: "audio/basic"))
        #expect(ElevenLabsFileResult.isRawAudio(url: URL(fileURLWithPath: "/tmp/a.ulaw"), contentType: "audio/mpeg"))
        #expect(!ElevenLabsFileResult.isRawAudio(url: URL(fileURLWithPath: "/tmp/a.mp3"), contentType: "audio/mpeg"))
        #expect(!ElevenLabsFileResult.isRawAudio(url: URL(fileURLWithPath: "/tmp/a.wav"), contentType: "audio/wav"))
    }

    @MainActor
    @Test func theClockReadsMinutesAndSeconds() {
        #expect(ElevenLabsAudioPlayerView.clock(0) == "0:00")
        #expect(ElevenLabsAudioPlayerView.clock(61.9) == "1:01")
        #expect(ElevenLabsAudioPlayerView.clock(.nan) == "0:00")
    }
}
