import Foundation
import SiliconCore

/// How a voice model is executed. Like the 3D backends, each engine is its own program
/// with its own invocation, so the entry carries which one runs it.
public enum VoiceBackend: String, Sendable, Codable {
    /// The mlx-audio package in the managed Python environment — Kokoro, CSM, Whisper,
    /// Parakeet all ride the same CLI.
    case mlxAudio
    /// LuxTTS, cloned beside the managed environment and driven through a small script.
    case luxTTS
    /// In the catalog for the roadmap; no runner wired yet.
    case unsupported
}

/// What a voice model does: turns text into speech, or speech into text.
public enum VoiceKind: String, Sendable, Codable {
    case speak
    case transcribe
}

/// One voice model. Sizes are the published weight footprints; durations are what the
/// model actually takes on an M-series Mac, stated as honest ranges.
public struct VoiceEntry: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var author: String
    public var license: String
    public var summary: String
    public var backend: VoiceBackend
    public var kind: VoiceKind
    /// The Hugging Face repo the runtime downloads on first use.
    public var repo: String
    public var weightsSize: Bytes
    public var peakMemory: Bytes
    public var typicalDuration: String
    public var rating: Int
    /// Preset voices, when the model ships them. Empty means the model speaks with a
    /// cloned voice (see `supportsCloning`) or its single built-in one.
    public var voices: [String]
    /// Whether a short reference recording turns into the speaking voice.
    public var supportsCloning: Bool
    /// Whether the model *requires* a reference recording — cloning-only models have no
    /// voice of their own to fall back on.
    public var requiresReference: Bool
    public var setupHint: String?

    public init(
        id: String, name: String, author: String, license: String, summary: String,
        backend: VoiceBackend, kind: VoiceKind, repo: String,
        weightsSize: Bytes, peakMemory: Bytes, typicalDuration: String, rating: Int,
        voices: [String] = [], supportsCloning: Bool = false,
        requiresReference: Bool = false, setupHint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.author = author
        self.license = license
        self.summary = summary
        self.backend = backend
        self.kind = kind
        self.repo = repo
        self.weightsSize = weightsSize
        self.peakMemory = peakMemory
        self.typicalDuration = typicalDuration
        self.rating = rating
        self.voices = voices
        self.supportsCloning = supportsCloning
        self.requiresReference = requiresReference
        self.setupHint = setupHint
    }
}

public enum VoiceCatalog {

    public static let all: [VoiceEntry] = [
        luxTTS, kokoro, csm, whisperTurbo, parakeet,
    ]

    public static var speakers: [VoiceEntry] { all.filter { $0.kind == .speak } }
    public static var transcribers: [VoiceEntry] { all.filter { $0.kind == .transcribe } }

    public static func entry(id: String) -> VoiceEntry? {
        all.first { $0.id == id }
    }

    /// LuxTTS — the cloning pick. ZipVoice-based, runs on MPS, and generates far faster
    /// than realtime from about a gigabyte of weights; give it three seconds of any voice
    /// and it speaks as that voice at 48 kHz.
    public static let luxTTS = VoiceEntry(
        id: "luxtts",
        name: "LuxTTS",
        author: "YatharthS",
        license: "Apache 2.0",
        summary: "The cloning pick: three seconds of any voice becomes the narrator, at "
            + "crisp 48 kHz and well past realtime speed. Tiny — about a gigabyte.",
        backend: .luxTTS,
        kind: .speak,
        repo: "YatharthS/LuxTTS",
        weightsSize: .gib(1),
        peakMemory: .gib(2),
        typicalDuration: "seconds",
        rating: 5,
        supportsCloning: true,
        requiresReference: true
    )

    /// Kokoro 82M — the instant pick: no reference needed, dozens of shipped voices,
    /// and an 82M model that narrates a paragraph in seconds on Apple Silicon.
    public static let kokoro = VoiceEntry(
        id: "kokoro",
        name: "Kokoro 82M",
        author: "hexgrad",
        license: "Apache 2.0",
        summary: "The instant pick: clean narration from a tiny model with a shelf of "
            + "ready voices. Nothing to record, nothing to wait for.",
        backend: .mlxAudio,
        kind: .speak,
        repo: "mlx-community/Kokoro-82M-bf16",
        weightsSize: .mib(350),
        peakMemory: .gib(1),
        typicalDuration: "seconds",
        rating: 4,
        voices: [
            "af_heart", "af_bella", "af_nicole", "af_sky",
            "am_adam", "am_michael", "bf_emma", "bm_george",
        ]
    )

    /// Sesame CSM 1B — conversational speech with cloning, natively in MLX.
    public static let csm = VoiceEntry(
        id: "csm-1b",
        name: "Sesame CSM 1B",
        author: "Sesame",
        license: "Apache 2.0",
        summary: "Conversational rather than narrated: pauses, breath, the rhythm of "
            + "someone talking to you. Clones from a reference recording too.",
        backend: .mlxAudio,
        kind: .speak,
        repo: "mlx-community/csm-1b",
        weightsSize: .gib(2) + .mib(512),
        peakMemory: .gib(4),
        typicalDuration: "5–30 s",
        rating: 4,
        supportsCloning: true
    )

    /// Whisper large-v3 turbo — the accuracy pick for speech-to-text.
    public static let whisperTurbo = VoiceEntry(
        id: "whisper-turbo",
        name: "Whisper large-v3 turbo",
        author: "OpenAI",
        license: "MIT",
        summary: "The dependable transcriber: near large-model accuracy across a hundred "
            + "languages, distilled fast enough for everyday use.",
        backend: .mlxAudio,
        kind: .transcribe,
        repo: "mlx-community/whisper-large-v3-turbo-asr-fp16",
        weightsSize: .gib(1) + .mib(614),
        peakMemory: .gib(3),
        typicalDuration: "far faster than the recording",
        rating: 5
    )

    /// Parakeet 0.6B — the speed pick for English transcription.
    public static let parakeet = VoiceEntry(
        id: "parakeet",
        name: "Parakeet 0.6B",
        author: "NVIDIA",
        license: "CC-BY-4.0",
        summary: "The speed pick for English: tears through long recordings with "
            + "punctuation and timestamps intact.",
        backend: .mlxAudio,
        kind: .transcribe,
        repo: "mlx-community/parakeet-tdt-0.6b-v3",
        weightsSize: .gib(1) + .mib(256),
        peakMemory: .gib(2) + .mib(512),
        typicalDuration: "far faster than the recording",
        rating: 4
    )
}
