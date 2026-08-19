import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconRuntime

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
