import AppKit
import Foundation
import SiliconElevenLabs
import SwiftUI
import Testing
@testable import SiliconUI

/// Every creative screen drawn with realistic fake data — light and dark, narrow and wide —
/// into PNGs in a scratch folder, so a person (or an agent) can look at them. Each screen is
/// brought to its state the way the owner would: through its model, the client and the
/// in-memory transport.
///
/// The folder is removed at the end unless `ELEVENLABS_KEEP_SNAPSHOTS=1`, in which case its
/// path is printed.
@Suite("ElevenLabs creative screens, drawn", .serialized)
@MainActor
struct CreativeSnapshotTests {

    enum Screen: String, CaseIterable, Sendable {
        case speech, dialogue, voiceChanger, soundEffects, musicCompose, musicPlan, musicFinetunes
        case isolation, transcription, alignment, history, models
    }

    static let variants: [(name: String, width: CGFloat, dark: Bool)] = [
        ("narrow-light", 560, false), ("narrow-dark", 560, true),
        ("wide-light", 980, false), ("wide-dark", 980, true),
    ]

    @Test(arguments: Screen.allCases)
    func drawsInEveryAppearanceAndWidth(screen: Screen) async throws {
        let rig = CreativeRig()
        defer { rig.clean() }
        rig.voices.set(CreativeRig.sampleVoices)
        rig.session.models.set(CreativeRig.modelsJSON.arrayValue!.compactMap(CreativeModel.init(json:)))
        rig.session.dictionaries.set([CreativeDictionary(id: "d1", name: "Product names", latestVersionID: "v3", rules: 12)])
        let view = try await Self.prepare(screen, rig: rig)
        let folder = Self.folder()
        defer { if !Self.keeps { CreativeRig.removeScratch(folder) } }
        for variant in Self.variants {
            let url = folder.appendingPathComponent("\(screen.rawValue)-\(variant.name).png")
            let size = try Self.render(view, width: variant.width, height: 2400, dark: variant.dark, to: url)
            #expect(size.width == variant.width)
            let data = try Data(contentsOf: url)
            #expect(data.count > 10_000, "\(url.lastPathComponent) looks empty")
        }
    }

    // MARK: - Bringing each screen to a realistic state

    static func prepare(_ screen: Screen, rig: CreativeRig) async throws -> AnyView {
        let session = rig.session
        switch screen {
        case .speech:
            rig.always(SpeechScreenModel.fullWithTimestamps, .json(
                ["audio_base64": .string(CreativeRig.wavData(seconds: 2).base64EncodedString()),
                 "alignment": CreativeRig.alignment(for: "Welcome back to the show. Today we talk about sound.")],
                headers: ["request-id": "req-8f2c", "character-cost": "52"]
            ))
            let speech = session.speech
            speech.voiceID = "voice-rachel"
            speech.text = "Welcome back to the show. Today we talk about sound."
            speech.timestamps = true
            speech.outputFormat = "wav_44100"
            speech.settings.overrides = true
            speech.settings.stability = 0.42
            await speech.generate()
            try #require(speech.lastRunner.phase == .succeeded, "\(speech.lastRunner.errorMessage ?? "")")
            speech.text = "And now, the weather."
            return AnyView(SpeechScreen(screen: speech))

        case .dialogue:
            rig.always(DialogueScreenModel.full, .audio(CreativeRig.wavData(seconds: 2), contentType: "audio/wav",
                                                        headers: ["character-cost": "61"]))
            let dialogue = session.dialogue
            dialogue.importScript("""
            Rachel: Did you hear that? [whispers]
            Adam: Hear what?
            Rachel: That noise, coming from the attic.
            """)
            dialogue.outputFormat = "wav_44100"
            await dialogue.generate()
            try #require(dialogue.lastRunner.phase == .succeeded, "\(dialogue.lastRunner.errorMessage ?? "")")
            return AnyView(DialogueScreen(screen: dialogue))

        case .voiceChanger:
            rig.always(VoiceChangerScreenModel.full, .audio(CreativeRig.wavData(seconds: 1.2), contentType: "audio/wav"))
            let changer = session.voiceChanger
            changer.source = rig.wav(named: "my-read.wav", seconds: 1.2)
            changer.voiceID = "voice-adam"
            changer.outputFormat = "wav_44100"
            changer.removeBackgroundNoise = true
            await changer.generate()
            try #require(changer.lastRunner.phase == .succeeded, "\(changer.lastRunner.errorMessage ?? "")")
            return AnyView(VoiceChangerScreen(screen: changer))

        case .soundEffects:
            rig.always(SoundEffectsScreenModel.generate, .audio(CreativeRig.wavData(seconds: 1), contentType: "audio/wav"))
            let effects = session.soundEffects
            effects.text = "Rain on a tin roof, distant thunder"
            effects.automaticDuration = false
            effects.duration = 8
            effects.outputFormat = "pcm_44100"
            await effects.generate()
            effects.loop = true
            await effects.generate()
            return AnyView(SoundEffectsScreen(screen: effects))

        case .musicCompose:
            rig.always(MusicScreenModel.compose, .audio(CreativeRig.wavData(seconds: 2), contentType: "audio/wav",
                                                       headers: ["song-id": "song-4411"]))
            rig.always(MusicScreenModel.listFinetunes, .json(["finetunes": [Self.finetune], "next_cursor": nil, "has_more": false]))
            let music = session.music
            music.prompt = "A warm lo-fi hip hop beat with soft piano and vinyl crackle, 80 bpm"
            music.usesLength = true
            music.lengthSeconds = 95
            await music.refreshFinetunes()
            await music.composeSong()
            try #require(music.lastRunner.phase == .succeeded, "\(music.lastRunner.errorMessage ?? "")")
            return AnyView(MusicScreen(screen: music))

        case .musicPlan:
            rig.always(MusicScreenModel.plan, .json(CreativeScreenTests.planJSON))
            rig.always(MusicScreenModel.listFinetunes, .json(["finetunes": [], "has_more": false]))
            let music = session.music
            music.tab = .plan
            music.planPrompt = "A short lo-fi song with a piano intro and a sung chorus"
            await music.makePlan()
            return AnyView(MusicScreen(screen: music))

        case .musicFinetunes:
            rig.always(MusicScreenModel.listFinetunes, .json(["finetunes": [
                Self.finetune,
                ["id": "ft2", "name": "Chamber strings", "tags": ["strings"], "model_id": "music_v2", "created_at": "2026-09-20T00:00:00Z",
                 "visibility": "workspace", "created_by": "workspace", "status": "in_progress", "training_progress": 0.4],
            ], "next_cursor": nil, "has_more": false]))
            rig.always(MusicScreenModel.getFinetune, .json(Self.finetune))
            let music = session.music
            music.tab = .finetunes
            await music.refreshFinetunes()
            await music.select(music.finetunes[0])
            return AnyView(MusicScreen(screen: music))

        case .isolation:
            rig.always(IsolationScreenModel.full, .audio(CreativeRig.wavData(seconds: 1), contentType: "audio/wav"))
            rig.always(IsolationScreenModel.history, .json(["items": [
                ["id": "iso1", "title": "Street interview", "created_at_unix": 1_790_000_000, "format": "mp3",
                 "duration_seconds": 64, "supports_video": false, "processing": false, "video_processing_failed": false],
                ["id": "iso2", "title": "Podcast intro", "created_at_unix": 1_789_000_000, "format": "wav",
                 "duration_seconds": 12, "supports_video": false, "processing": true, "video_processing_failed": false],
            ], "has_more": false]))
            let isolation = session.isolation
            isolation.source = rig.wav(named: "street-interview.wav")
            await isolation.isolate()
            await isolation.refreshHistory()
            return AnyView(IsolationScreen(screen: isolation))

        case .transcription:
            rig.always(TranscriptionScreenModel.convert, .json(Self.transcript))
            let stt = session.transcription
            stt.source = rig.wav(named: "team-call.wav", seconds: 3)
            stt.diarize = true
            stt.keyterms = ["ElevenLabs", "Scribe"]
            stt.entityDetection = ["pii"]
            await stt.transcribe()
            try #require(stt.runner.phase == .succeeded, "\(stt.runner.errorMessage ?? "")")
            return AnyView(TranscriptionScreen(screen: stt))

        case .alignment:
            rig.always(AlignmentScreenModel.align, .json(["loss": 0.08, "characters": [], "words": [
                ["text": "The", "start": 0.05, "end": 0.2, "loss": 0.02], ["text": "quick", "start": 0.22, "end": 0.5, "loss": 0.05],
                ["text": "brown", "start": 0.52, "end": 0.8, "loss": 0.21], ["text": "fox.", "start": 0.82, "end": 1.1, "loss": 0.04],
            ]]))
            let alignment = session.alignment
            alignment.source = rig.wav(named: "reading.wav")
            alignment.text = "The quick brown fox."
            await alignment.align()
            return AnyView(AlignmentScreen(screen: alignment))

        case .history:
            rig.always(HistoryScreenModel.list, .json(["history": [
                CreativeScreenTests.historyItem("h1"), CreativeScreenTests.historyItem("h2"), CreativeScreenTests.historyItem("h3"),
            ], "has_more": true]))
            rig.always(HistoryScreenModel.get, .json(CreativeScreenTests.historyItem("h1")))
            let history = session.history
            await history.refresh()
            history.selection = ["h2", "h3"]
            await history.open(history.items[0])
            return AnyView(HistoryScreen(screen: history))

        case .models:
            return AnyView(ModelsScreen(screen: session.modelsScreen))
        }
    }

    static let finetune: JSONValue = [
        "id": "ft1", "name": "Synth dreams", "tags": ["synth", "retro"], "primary_genre": "synthwave",
        "model_id": "music_v1", "created_at": "2026-09-01T00:00:00Z", "visibility": "private",
        "created_by": "self", "status": "completed", "training_progress": 1,
    ]

    static let transcript: JSONValue = [
        "language_code": "en", "language_probability": 0.99, "transcription_id": "tr-5521",
        "text": "Morning everyone. Morning! Let's start with the launch. (laughter) Sure.",
        "words": [
            ["text": "Morning", "start": 0.0, "end": 0.4, "type": "word", "speaker_id": "speaker_0", "logprob": 0],
            ["text": "everyone.", "start": 0.45, "end": 0.9, "type": "word", "speaker_id": "speaker_0", "logprob": 0],
            ["text": "Morning!", "start": 1.2, "end": 1.6, "type": "word", "speaker_id": "speaker_1", "logprob": 0],
            ["text": "Let's", "start": 1.9, "end": 2.1, "type": "word", "speaker_id": "speaker_0", "logprob": 0],
            ["text": "start", "start": 2.1, "end": 2.3, "type": "word", "speaker_id": "speaker_0", "logprob": 0],
            ["text": "with", "start": 2.3, "end": 2.4, "type": "word", "speaker_id": "speaker_0", "logprob": 0],
            ["text": "the", "start": 2.4, "end": 2.5, "type": "word", "speaker_id": "speaker_0", "logprob": 0],
            ["text": "launch.", "start": 2.5, "end": 2.8, "type": "word", "speaker_id": "speaker_0", "logprob": 0],
            ["text": "(laughter)", "start": 2.8, "end": 3.2, "type": "audio_event", "speaker_id": "speaker_1", "logprob": 0],
            ["text": "Sure.", "start": 3.3, "end": 3.6, "type": "word", "speaker_id": "speaker_1", "logprob": 0],
        ],
        "entities": [["text": "Ann", "entity_type": "person_name", "start_char": 0, "end_char": 3]],
    ]

    // MARK: - Drawing

    /// Draws `view` in an off-screen window at `width` × `height` and writes a PNG.
    static func render(_ view: AnyView, width: CGFloat, height: CGFloat, dark: Bool, to url: URL) throws -> CGSize {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = view
            .environment(AppModel(settings: .init()))
            .frame(width: width, height: height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.appearance = appearance
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        host.layoutSubtreeIfNeeded()
        host.display()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
        window.contentView = nil
        window.close()
        return host.bounds.size
    }

    /// Whether the PNGs stay after the run (`ELEVENLABS_KEEP_SNAPSHOTS=1`).
    static var keeps: Bool { ProcessInfo.processInfo.environment["ELEVENLABS_KEEP_SNAPSHOTS"] == "1" }

    /// Where a test draws: one shared folder in the system temporary directory when the PNGs
    /// are kept (its path printed), otherwise a folder of the test's own, removed at its end.
    static func folder() -> URL {
        let name = keeps ? "elevenlabs-creative-snapshots" : "elevenlabs-creative-snapshots-\(UUID().uuidString)"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if keeps { print("Creative snapshots: \(folder.path)") }
        return folder
    }
}
