import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconRuntime
@testable import SiliconUI

@Suite("Voice catalog and runtime")
struct VoiceTests {

    @Test func catalogPartitionsIntoSpeakersAndTranscribers() {
        #expect(!VoiceCatalog.speakers.isEmpty)
        #expect(!VoiceCatalog.transcribers.isEmpty)
        #expect(VoiceCatalog.speakers.allSatisfy { $0.kind == .speak })
        #expect(VoiceCatalog.transcribers.allSatisfy { $0.kind == .transcribe })
        #expect(VoiceCatalog.entry(id: "luxtts")?.requiresReference == true)
        #expect(VoiceCatalog.entry(id: "kokoro")?.voices.isEmpty == false)
    }

    @Test func buildsTheMLXAudioCommandExactly() {
        let scratch = URL(fileURLWithPath: "/tmp/scratch")
        let request = SpeechRequest(
            entryID: "kokoro", text: "Hello there", voice: "af_heart",
            outputDirectory: URL(fileURLWithPath: "/tmp/out")
        )
        let arguments = VoiceRuntime.mlxAudioSpeakArguments(
            entry: VoiceCatalog.kokoro, request: request, scratch: scratch
        )
        #expect(arguments == [
            "-m", "mlx_audio.tts.generate",
            "--model", "mlx-community/Kokoro-82M-bf16",
            "--text", "Hello there",
            "--output_path", "/tmp/scratch",
            "--file_prefix", "speech",
            "--join_audio",
            "--voice", "af_heart",
        ])
    }

    @Test func cloningModelsCarryTheReference() {
        let request = SpeechRequest(
            entryID: "csm-1b", text: "Hi",
            referenceAudio: URL(fileURLWithPath: "/tmp/ref.wav"),
            referenceText: "the reference says this",
            outputDirectory: URL(fileURLWithPath: "/tmp/out")
        )
        let arguments = VoiceRuntime.mlxAudioSpeakArguments(
            entry: VoiceCatalog.csm, request: request,
            scratch: URL(fileURLWithPath: "/tmp/scratch")
        )
        #expect(arguments.contains("--ref_audio"))
        #expect(arguments.contains("/tmp/ref.wav"))
        #expect(arguments.contains("--ref_text"))
        // CSM ships no preset voices, so no --voice flag sneaks in.
        #expect(!arguments.contains("--voice"))
    }

    /// The driver is what actually runs LuxTTS; its argv contract and import path are
    /// pinned here against the clone layout that was verified live.
    @Test func luxTTSDriverMatchesTheVerifiedContract() {
        let driver = VoiceRuntime.luxTTSDriver
        #expect(driver.contains("from zipvoice.luxvoice import LuxTTS"))
        #expect(driver.contains("sys.argv[1:5]"))
        #expect(driver.contains("device=\"mps\""))
        #expect(driver.contains("48000"))
    }

    /// The model-library setting must reach the engines: HF_HOME in every child.
    @Test func childEnvironmentCarriesTheEngineCache() {
        let cache = URL(fileURLWithPath: "/Volumes/Big/Local Models/Engine Cache")
        #expect(VoiceRuntime.childEnvironment(hubCache: cache)["HF_HOME"]
            == "/Volumes/Big/Local Models/Engine Cache")
        #expect(VoiceRuntime.childEnvironment()["HF_HOME"] == nil)
        #expect(MFluxRuntime.childEnvironment(huggingFaceToken: nil, hubCache: cache)["HF_HOME"]
            == "/Volumes/Big/Local Models/Engine Cache")
    }

    @Test func namesTheRealProblemWhenTheDiskFills() {
        let diagnosis = VoiceRuntime.diagnosis(
            from: "RuntimeError: Task error: File reconstruction error: Internal "
                + "Writer Error: Background writer channel closed"
        )
        #expect(diagnosis.contains("disk space"))
        #expect(diagnosis.contains("Settings"))
    }

    @Test func relaysOnlyMeaningfulStages() {
        #expect(VoiceRuntime.stage(from: "stage: Speaking") == "Speaking")
        #expect(VoiceRuntime.stage(from: "Fetching 56 files: 3%")
            == "Downloading the model — first run only")
        #expect(VoiceRuntime.stage(from: "some tqdm noise") == nil)
    }

    @Test func outputNamesSortAndDoNotCollide() {
        let a = VoiceRuntime.outputName()
        let b = VoiceRuntime.outputName()
        #expect(a != b)
        #expect(a.hasPrefix("silicon-voice-"))
        #expect(a.hasSuffix(".wav"))
        #expect(VoiceRuntime.outputName(kind: .music).hasPrefix("silicon-music-"))
        #expect(VoiceRuntime.outputName(kind: .soundEffect).hasPrefix("silicon-sfx-"))
    }

    @Test func catalogNowCoversMusicAndSoundEffects() {
        #expect(!VoiceCatalog.musicians.isEmpty)
        #expect(!VoiceCatalog.soundEffects.isEmpty)
        #expect(VoiceCatalog.entry(id: "minimax-music3")?.kind == .music)
        #expect(VoiceCatalog.entry(id: "moss-sound-effect")?.backend == .mlxSpeech)
    }

    @Test func buildsTheMusicCommandWithInstrumentalFallback() {
        let scratch = URL(fileURLWithPath: "/tmp/scratch")
        let request = SpeechRequest(
            entryID: "minimax-music3", text: "warm lo-fi beat",
            lyrics: "   ", durationSeconds: 30,
            outputDirectory: URL(fileURLWithPath: "/tmp/out")
        )
        let arguments = VoiceRuntime.musicArguments(
            entry: VoiceCatalog.minimaxMusic, request: request, scratch: scratch
        )
        #expect(arguments == [
            "-m", "mlx_audio.music.generate",
            "--model", "mlx-community/MiniMax-Music3-4bit",
            "--caption", "warm lo-fi beat",
            "--lyrics", "[instrumental]",
            "--duration", "30",
            "--output", "/tmp/scratch/music.wav",
        ])

        var withLyrics = request
        withLyrics.lyrics = "[verse]\nHello world"
        let sung = VoiceRuntime.musicArguments(
            entry: VoiceCatalog.minimaxMusic, request: withLyrics, scratch: scratch
        )
        #expect(sung.contains("[verse]\nHello world"))
    }

    @Test func buildsTheSoundEffectCommandExactly() {
        let request = SpeechRequest(
            entryID: "moss-sound-effect", text: "glass shattering",
            durationSeconds: 6,
            outputDirectory: URL(fileURLWithPath: "/tmp/out")
        )
        let arguments = VoiceRuntime.soundEffectArguments(
            entry: VoiceCatalog.mossSoundEffect, request: request,
            scratch: URL(fileURLWithPath: "/tmp/scratch")
        )
        #expect(arguments == [
            "tts",
            "--model", "moss-sound-effect",
            "--text", "glass shattering",
            "--duration-seconds", "6",
            "-o", "/tmp/scratch/effect.wav",
        ])
    }
}

@Suite("Microphone WAV snapshots")
struct MicWAVTests {

    /// The header a transcriber will actually parse: RIFF/WAVE, PCM, mono, 16-bit,
    /// sizes consistent with the payload.
    @Test @MainActor func writesAValidWAVHeader() {
        let samples: [Float] = [0, 0.5, -0.5, 1.0, -1.0]
        let data = MicRecorder.wavData(samples: samples, sampleRate: 16000)

        #expect(data.count == 44 + samples.count * 2)
        #expect(String(data: data[0..<4], encoding: .ascii) == "RIFF")
        #expect(String(data: data[8..<12], encoding: .ascii) == "WAVE")
        #expect(String(data: data[36..<40], encoding: .ascii) == "data")

        func u32(_ offset: Int) -> UInt32 {
            data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        func u16(_ offset: Int) -> UInt16 {
            data[offset..<offset + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        }
        #expect(u32(4) == UInt32(36 + samples.count * 2))
        #expect(u16(20) == 1)                       // PCM
        #expect(u16(22) == 1)                       // mono
        #expect(u32(24) == 16000)                   // sample rate
        #expect(u16(34) == 16)                      // bits per sample
        #expect(u32(40) == UInt32(samples.count * 2))

        // Full-scale samples clip cleanly instead of wrapping.
        func s16(_ offset: Int) -> Int16 {
            Int16(bitPattern: u16(offset))
        }
        #expect(s16(44) == 0)
        #expect(s16(50) == 32767)
        #expect(s16(52) == -32767)
    }
}

@Suite("Video catalog and runtime")
struct VideoTests {

    @Test func catalogEntriesAreRemoteAndHonest() {
        #expect(!VideoCatalog.all.isEmpty)
        #expect(VideoCatalog.all.allSatisfy { $0.backend == .nodeRemote })
        #expect(VideoCatalog.all.allSatisfy { $0.capabilityID == "text-to-video" })
        #expect(VideoCatalog.entry(id: "wan22-ti2v-5b")?.supportsImageInput == true)
    }

    /// The liberal artifact scan: any string ending in a video extension, however the
    /// node nests it, absolute or relative.
    @Test func findsClipURLsAnywhereInTheStatusPayload() {
        let base = URL(string: "http://node:8790")!
        let status: [String: Any] = [
            "status": "done",
            "result": [
                "files": ["/v1/files/out.mp4", "thumbnail.png"],
                "extra": ["nested": "http://node:8790/v1/files/alt.webm"],
            ],
        ]
        let urls = NodeVideoRuntime.videoURLs(in: status, base: base)
        // Dictionary traversal order is arbitrary; the set of findings is the claim.
        #expect(Set(urls.map(\.absoluteString)) == [
            "http://node:8790/v1/files/out.mp4",
            "http://node:8790/v1/files/alt.webm",
        ])
    }

    @Test func describesProgressFromWhateverTheNodeSends() {
        #expect(NodeVideoRuntime.stageDescription(from: ["stage": "Denoising"]) == "Denoising")
        #expect(NodeVideoRuntime.stageDescription(from: ["progress": 0.4])
            == "Rendering — 40%")
        #expect(NodeVideoRuntime.stageDescription(from: ["status": "queued"]) == "Queued")
        #expect(NodeVideoRuntime.stageDescription(from: [:]) == nil)
    }

    @Test func videoOutputNamesSortAndDoNotCollide() {
        let a = NodeVideoRuntime.outputName(extension: "mp4")
        let b = NodeVideoRuntime.outputName(extension: "mp4")
        #expect(a != b)
        #expect(a.hasPrefix("silicon-video-"))
        #expect(a.hasSuffix(".mp4"))
    }
}
