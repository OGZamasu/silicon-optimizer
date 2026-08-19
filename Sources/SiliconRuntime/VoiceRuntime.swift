import Foundation
import SiliconCatalog
import SiliconCore

/// What the voice tab asks for: text spoken aloud, or a recording turned into text.
public struct SpeechRequest: Sendable {
    public var entryID: String
    public var text: String
    /// A preset voice name, for models that ship voices.
    public var voice: String?
    /// A short recording whose voice the model clones, for models that clone.
    public var referenceAudio: URL?
    /// What the reference recording says — some cloners align against it.
    public var referenceText: String?
    /// Structured lyrics, for music models. Empty means instrumental.
    public var lyrics: String?
    /// Requested length in seconds, for music and sound-effect models.
    public var durationSeconds: Int?
    public var outputDirectory: URL

    public init(
        entryID: String, text: String, voice: String? = nil,
        referenceAudio: URL? = nil, referenceText: String? = nil,
        lyrics: String? = nil, durationSeconds: Int? = nil, outputDirectory: URL
    ) {
        self.entryID = entryID
        self.text = text
        self.voice = voice
        self.referenceAudio = referenceAudio
        self.referenceText = referenceText
        self.lyrics = lyrics
        self.durationSeconds = durationSeconds
        self.outputDirectory = outputDirectory
    }
}

public struct SpeechResult: Sendable, Identifiable {
    public var id: String { audio.path }
    public var audio: URL
    public var modelName: String
    public var elapsed: TimeInterval

    public init(audio: URL, modelName: String, elapsed: TimeInterval) {
        self.audio = audio
        self.modelName = modelName
        self.elapsed = elapsed
    }
}

public struct TranscriptionResult: Sendable, Identifiable {
    public var id: String { source.path + text.prefix(32) }
    public var source: URL
    public var text: String
    public var modelName: String
    public var elapsed: TimeInterval

    public init(source: URL, text: String, modelName: String, elapsed: TimeInterval) {
        self.source = source
        self.text = text
        self.modelName = modelName
        self.elapsed = elapsed
    }
}

/// Whether a voice backend can run right now, and the one thing missing when it cannot.
public struct VoiceInstallation: Sendable {
    public enum Missing: Sendable {
        case nothing
        /// The managed Python environment or the mlx-audio package inside it.
        case tools
        /// The LuxTTS clone beside the environment.
        case luxTTS
        case unsupported
    }

    public var isInstalled: Bool { if case .nothing = missing { return true }; return false }
    public var missing: Missing
    public var detail: String

    public init(missing: Missing, detail: String) {
        self.missing = missing
        self.detail = detail
    }
}

public enum VoiceRuntimeError: LocalizedError {
    case notInstalled(String)
    case failed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let detail): detail
        case .failed(let message): message
        case .cancelled: "Cancelled."
        }
    }
}

/// Runs the voice models: mlx-audio's CLI for the MLX family, and a small driver script
/// for LuxTTS. Like image generation there is no server to keep alive — each utterance
/// is a process that loads, speaks, writes a WAV and exits, releasing its memory.
public actor VoiceRuntime {

    private var process: ServerProcess?

    public init() {}

    // MARK: - Locations

    /// The managed Python environment shared with MFLUX — mlx-audio lives here.
    public nonisolated static var environment: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".silicon-mlx")
    }

    public nonisolated static var python: URL {
        environment.appendingPathComponent("bin/python3")
    }

    /// LuxTTS gets its own environment: its requirements pin transformers to the 4.x
    /// line while mflux and mlx-audio need 5.x, so sharing one environment quietly
    /// breaks whichever family installed first. Learned the hard way, once.
    public nonisolated static var luxTTSEnvironment: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".silicon-luxtts")
    }

    public nonisolated static var luxTTSPython: URL {
        luxTTSEnvironment.appendingPathComponent("bin/python3")
    }

    /// LuxTTS lives as a clone inside its environment — it is not on PyPI.
    public nonisolated static var luxTTSClone: URL {
        luxTTSEnvironment.appendingPathComponent("luxtts")
    }

    // MARK: - Installation

    public nonisolated static func installation(for entry: VoiceEntry) -> VoiceInstallation {
        let manager = FileManager.default
        switch entry.backend {
        case .mlxAudio:
            guard manager.isExecutableFile(atPath: python.path), hasMLXAudio else {
                return VoiceInstallation(
                    missing: .tools,
                    detail: "The voice tools aren't set up yet — one click installs them."
                )
            }
            return VoiceInstallation(missing: .nothing, detail: "Ready.")
        case .mlxSpeech:
            let cli = environment.appendingPathComponent("bin/mlx-speech")
            guard manager.isExecutableFile(atPath: cli.path) else {
                return VoiceInstallation(
                    missing: .tools,
                    detail: "The audio tools aren't set up yet — one click installs them."
                )
            }
            return VoiceInstallation(missing: .nothing, detail: "Ready.")
        case .luxTTS:
            let module = luxTTSClone.appendingPathComponent("zipvoice/luxvoice.py")
            guard manager.isExecutableFile(atPath: luxTTSPython.path),
                  manager.fileExists(atPath: module.path) else {
                return VoiceInstallation(
                    missing: .luxTTS,
                    detail: "LuxTTS isn't set up yet — one click installs it."
                )
            }
            return VoiceInstallation(missing: .nothing, detail: "Ready.")
        case .unsupported:
            return VoiceInstallation(
                missing: .unsupported, detail: "No runner is wired up for this one yet."
            )
        }
    }

    private nonisolated static var hasMLXAudio: Bool {
        let lib = environment.appendingPathComponent("lib")
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: lib.path)
        else { return false }
        return versions.contains { version in
            FileManager.default.fileExists(
                atPath: lib.appendingPathComponent("\(version)/site-packages/mlx_audio").path
            )
        }
    }

    // MARK: - Speaking

    public func speak(
        _ request: SpeechRequest, onStage: @escaping @Sendable (String) -> Void
    ) async throws -> SpeechResult {
        guard let entry = VoiceCatalog.entry(id: request.entryID) else {
            throw VoiceRuntimeError.failed("Unknown voice model \(request.entryID).")
        }
        let installation = Self.installation(for: entry)
        guard installation.isInstalled else {
            throw VoiceRuntimeError.notInstalled(installation.detail)
        }

        try FileManager.default.createDirectory(
            at: request.outputDirectory, withIntermediateDirectories: true
        )
        // Each run writes into its own scratch folder, then the newest audio file is
        // claimed — naming conventions differ between backends and versions, and a scan
        // of a private folder is robust against all of them.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-voice-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let executable: URL
        let arguments: [String]
        switch entry.backend {
        case .mlxAudio where entry.kind == .music:
            executable = Self.python
            arguments = Self.musicArguments(entry: entry, request: request, scratch: scratch)
        case .mlxAudio:
            executable = Self.python
            arguments = Self.mlxAudioSpeakArguments(entry: entry, request: request, scratch: scratch)
        case .mlxSpeech:
            executable = Self.environment.appendingPathComponent("bin/mlx-speech")
            arguments = Self.soundEffectArguments(entry: entry, request: request, scratch: scratch)
        case .luxTTS:
            guard let reference = request.referenceAudio else {
                throw VoiceRuntimeError.failed(
                    "LuxTTS speaks with a cloned voice — add a short recording (3 seconds "
                    + "or more) of the voice it should use."
                )
            }
            let script = scratch.appendingPathComponent("drive.py")
            try Self.luxTTSDriver.write(to: script, atomically: true, encoding: .utf8)
            executable = Self.luxTTSPython
            arguments = [
                script.path, Self.luxTTSClone.path, reference.path, request.text,
                scratch.appendingPathComponent("speech.wav").path,
            ]
        case .unsupported:
            throw VoiceRuntimeError.notInstalled("No runner is wired up for this one yet.")
        }

        let started = Date()
        let output = try await run(executable: executable, arguments: arguments, onStage: onStage)

        guard let produced = Self.newestAudioFile(in: scratch) else {
            throw VoiceRuntimeError.failed(Self.diagnosis(from: output))
        }
        let destination = request.outputDirectory
            .appendingPathComponent(Self.outputName(kind: entry.kind))
        try FileManager.default.moveItem(at: produced, to: destination)
        return SpeechResult(
            audio: destination, modelName: entry.name,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    static func mlxAudioSpeakArguments(
        entry: VoiceEntry, request: SpeechRequest, scratch: URL
    ) -> [String] {
        var arguments = [
            "-m", "mlx_audio.tts.generate",
            "--model", entry.repo,
            "--text", request.text,
            "--output_path", scratch.path,
            "--file_prefix", "speech",
            "--join_audio",
        ]
        if let voice = request.voice, !voice.isEmpty {
            arguments += ["--voice", voice]
        }
        if entry.supportsCloning, let reference = request.referenceAudio {
            arguments += ["--ref_audio", reference.path]
            if let text = request.referenceText, !text.isEmpty {
                arguments += ["--ref_text", text]
            }
        }
        return arguments
    }

    /// The music CLI wants a caption plus structured lyrics ("[verse]…" lines) and a
    /// concrete output file. Empty lyrics become "[instrumental]" — the flag is
    /// mandatory, and that is the tag for a song without words.
    static func musicArguments(
        entry: VoiceEntry, request: SpeechRequest, scratch: URL
    ) -> [String] {
        let lyrics = request.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "-m", "mlx_audio.music.generate",
            "--model", entry.repo,
            "--caption", request.text,
            "--lyrics", (lyrics?.isEmpty ?? true) ? "[instrumental]" : lyrics!,
            "--duration", String(request.durationSeconds ?? 30),
            "--output", scratch.appendingPathComponent("music.wav").path,
        ]
    }

    static func soundEffectArguments(
        entry: VoiceEntry, request: SpeechRequest, scratch: URL
    ) -> [String] {
        [
            "tts",
            "--model", entry.repo,
            "--text", request.text,
            "--duration-seconds", String(request.durationSeconds ?? 6),
            "-o", scratch.appendingPathComponent("effect.wav").path,
        ]
    }

    /// The LuxTTS driver, verified against the clone's actual layout: the class lives at
    /// `zipvoice.luxvoice.LuxTTS`, encodes a reference prompt, and returns 48 kHz audio.
    /// Everything variable arrives through argv so no text ever needs escaping.
    static let luxTTSDriver = """
    import sys
    clone, reference, text, output = sys.argv[1:5]
    sys.path.insert(0, clone)
    print("stage: Loading LuxTTS", flush=True)
    from zipvoice.luxvoice import LuxTTS
    import soundfile as sf
    lux = LuxTTS("YatharthS/LuxTTS", device="mps")
    print("stage: Reading the reference voice", flush=True)
    prompt = lux.encode_prompt(reference, rms=0.01)
    print("stage: Speaking", flush=True)
    wav = lux.generate_speech(text, prompt, num_steps=4)
    sf.write(output, wav.numpy().squeeze(), 48000)
    print("stage: Done", flush=True)
    """

    // MARK: - Transcribing

    public func transcribe(
        audio: URL, entryID: String, onStage: @escaping @Sendable (String) -> Void
    ) async throws -> TranscriptionResult {
        guard let entry = VoiceCatalog.entry(id: entryID) else {
            throw VoiceRuntimeError.failed("Unknown transcriber \(entryID).")
        }
        let installation = Self.installation(for: entry)
        guard installation.isInstalled else {
            throw VoiceRuntimeError.notInstalled(installation.detail)
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-stt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let started = Date()
        // `--output-path X` means "write X.txt", not "write into X" — verified live.
        let output = try await run(
            executable: Self.python,
            arguments: [
                "-m", "mlx_audio.stt.generate",
                "--model", entry.repo,
                "--audio", audio.path,
                "--output-path", scratch.appendingPathComponent("transcript").path,
                "--format", "txt",
            ],
            onStage: onStage
        )

        let file = scratch.appendingPathComponent("transcript.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw VoiceRuntimeError.failed(Self.diagnosis(from: output))
        }
        return TranscriptionResult(
            source: audio,
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            modelName: entry.name,
            elapsed: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Process plumbing

    /// The child environment. Kokoro's phonemizer needs the espeak-ng library, which
    /// ships inside the `espeakng-loader` wheel — but misaki only looks for a Homebrew
    /// copy at a hardcoded path. phonemizer honors these variables, so point them at
    /// the bundled library and every machine works, Homebrew or not.
    nonisolated static func childEnvironment() -> [String: String] {
        var environment = ["PYTHONUNBUFFERED": "1"]
        let lib = Self.environment.appendingPathComponent("lib")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: lib.path) {
            for version in versions {
                let loader = lib.appendingPathComponent(
                    "\(version)/site-packages/espeakng_loader"
                )
                let dylib = loader.appendingPathComponent("libespeak-ng.dylib")
                if FileManager.default.fileExists(atPath: dylib.path) {
                    environment["PHONEMIZER_ESPEAK_LIBRARY"] = dylib.path
                    environment["ESPEAK_DATA_PATH"] =
                        loader.appendingPathComponent("espeak-ng-data").path
                    break
                }
            }
        }
        return environment
    }

    private func run(
        executable: URL, arguments: [String], onStage: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let process = ServerProcess()
        self.process = process
        try await process.start(
            executable: executable,
            arguments: arguments,
            environment: Self.childEnvironment(),
            onLogLine: { line in
                if let stage = Self.stage(from: line) { onStage(stage) }
            }
        )
        while await process.isRunning {
            if Task.isCancelled {
                await process.terminate()
                throw VoiceRuntimeError.cancelled
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await process.log
    }

    public func cancel() async {
        await process?.terminate()
    }

    /// The lines worth relaying: our own driver's stages, plus the download progress the
    /// Hugging Face client prints the first time a model is fetched.
    static func stage(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("stage: ") {
            return String(trimmed.dropFirst("stage: ".count))
        }
        if trimmed.contains("Fetching") || trimmed.contains("Downloading") {
            return "Downloading the model — first run only"
        }
        return nil
    }

    static func newestAudioFile(in directory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return contents
            .filter { ["wav", "flac", "mp3", "ogg"].contains($0.pathExtension.lowercased()) }
            .max { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return dateA < dateB
            }
    }

    public static func outputName(kind: VoiceKind = .speak, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let suffix = String(UUID().uuidString.prefix(8))
        let prefix = switch kind {
        case .music: "silicon-music"
        case .soundEffect: "silicon-sfx"
        default: "silicon-voice"
        }
        return "\(prefix)-\(formatter.string(from: date))-\(suffix).wav"
    }

    /// The last few meaningful lines of a failed run — enough to act on, short enough
    /// to read.
    static func diagnosis(from log: String) -> String {
        let lines = log.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("stage: ") }
        let tail = lines.suffix(3).joined(separator: " ")
        return tail.isEmpty ? "The voice engine produced no audio and no explanation."
            : tail
    }
}
