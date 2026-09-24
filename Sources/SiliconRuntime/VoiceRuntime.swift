import Foundation
import SiliconCatalog
import SiliconControl
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
    /// Where the engine's own weight downloads land (`HF_HOME`); nil means the system
    /// default on the startup disk.
    public var hubCache: URL?
    public var outputDirectory: URL

    public init(
        entryID: String, text: String, voice: String? = nil,
        referenceAudio: URL? = nil, referenceText: String? = nil,
        lyrics: String? = nil, durationSeconds: Int? = nil,
        hubCache: URL? = nil, outputDirectory: URL
    ) {
        self.entryID = entryID
        self.text = text
        self.voice = voice
        self.referenceAudio = referenceAudio
        self.referenceText = referenceText
        self.lyrics = lyrics
        self.durationSeconds = durationSeconds
        self.hubCache = hubCache
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
    /// Where the pinned model manifests are, and where their files come from — tests stand a
    /// local folder in for the Hub.
    private let locks: URL
    private let hubServer: URL
    private let hubProtocols: String
    /// Repositories whose files a run is putting in place right now, so two runs of one
    /// model never write the same blob at once.
    private var preparing: Set<String> = []

    public init() {
        self.init(locks: PinnedInstall.defaultLockRoot())
    }

    init(
        locks: URL, hubServer: URL = URL(string: "https://huggingface.co")!,
        hubProtocols: String = "=https"
    ) {
        self.locks = locks
        self.hubServer = hubServer
        self.hubProtocols = hubProtocols
    }

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

    // MARK: - Installing

    /// The voice tools into the environment MFLUX shares: build tools first, so docopt (a
    /// source-only dependency of num2words) builds with the locked setuptools instead of one
    /// an isolated build would download, then the hash-locked set — which includes the spaCy
    /// model by its release URL and digest.
    ///
    /// An environment no voice lock covers — MFLUX's on 3.12, say — is made again, and MFLUX,
    /// if it was in it, goes back in first: its locks cover every Python the voice tools' do.
    public nonisolated static func toolsInstallPlan(
        basePython: URL?, locks: URL = PinnedInstall.defaultLockRoot(),
        environment: URL = VoiceRuntime.environment
    ) throws -> [PinnedInstall.Command] {
        let mfluxCleared = PinnedInstall.needsRemaking(
            environment, supported: PinnedInstall.voicePythons
        ) && FileManager.default.isExecutableFile(
            atPath: environment.appendingPathComponent("bin/mflux-generate").path
        )
        let (python, version, commands) = try PinnedInstall.environment(
            environment, tool: "The voice tools", supported: PinnedInstall.voicePythons,
            basePython: basePython
        )
        var plan = commands
        if mfluxCleared {
            plan.append(MFluxRuntime.packageInstall(python: python, version: version, locks: locks))
        }
        return plan + toolsInstall(python: python, version: version, locks: locks)
    }

    /// The voice tools' build tools, then their hash-locked set, into the shared environment.
    nonisolated static func toolsInstall(
        python: URL, version: String, locks: URL
    ) -> [PinnedInstall.Command] {
        let directory = PinnedInstall.mlxEnvironmentLocks
        return [
            PinnedInstall.pipInstall(
                python: python,
                lock: PinnedInstall.lock("build", directory: directory, python: version, in: locks),
                label: "Installing the voice tools' build tools"
            ),
            PinnedInstall.pipInstall(
                python: python,
                lock: PinnedInstall.lock("voice", directory: directory, python: version, in: locks),
                label: "Installing the voice tools", noBuildIsolation: true
            ),
        ]
    }

    /// LuxTTS in its own environment: LuxTTS and its LinaCodec at their reviewed commits, both
    /// checked before anything in them runs; build tools, then the hash-locked dependencies
    /// (jieba and encodec build from their hashed sources with the locked setuptools); then
    /// LinaCodec itself from the verified checkout, offline and without dependencies.
    public nonisolated static func luxTTSInstallPlan(
        basePython: URL?, git: URL, locks: URL = PinnedInstall.defaultLockRoot(),
        environment: URL = VoiceRuntime.luxTTSEnvironment
    ) throws -> [PinnedInstall.Command] {
        let (python, version, environmentCommands) = try PinnedInstall.environment(
            environment, tool: "LuxTTS", supported: PinnedInstall.luxTTSPythons,
            basePython: basePython
        )
        let linaCodec = environment.appendingPathComponent("linacodec")
        var commands = environmentCommands
        commands += PinnedInstall.fetch(
            PinnedInstall.luxTTS, into: environment.appendingPathComponent("luxtts"), git: git
        )
        commands += PinnedInstall.fetch(PinnedInstall.linaCodec, into: linaCodec, git: git)
        commands.append(PinnedInstall.pipInstall(
            python: python,
            lock: PinnedInstall.lock("build", for: PinnedInstall.luxTTS, python: version, in: locks),
            label: "Installing its build tools"
        ))
        commands.append(PinnedInstall.pipInstall(
            python: python,
            lock: PinnedInstall.lock("requirements", for: PinnedInstall.luxTTS, python: version, in: locks),
            label: "Installing LuxTTS's dependencies (a few minutes)", noBuildIsolation: true
        ))
        // Checked again right before it is installed: the checkout could only have changed in
        // between by someone else's hand, and then it is not what was reviewed.
        commands.append(PinnedInstall.verify(PinnedInstall.linaCodec, in: linaCodec, git: git))
        commands.append(PinnedInstall.pipInstallVerifiedCheckout(
            python: python, checkout: linaCodec, label: "Installing LinaCodec"
        ))
        return commands
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
        case .cloud:
            // There is nothing to install. Whether it *works* depends on a key and a network,
            // and both are reported where they can actually be fixed rather than here.
            return VoiceInstallation(missing: .nothing, detail: "Runs on your provider.")
        case .unsupported:
            return VoiceInstallation(
                missing: .unsupported, detail: "No runner is wired up for this one yet."
            )
        }
    }

    private nonisolated static var hasMLXAudio: Bool { hasMLXAudio(in: environment) }

    private nonisolated static func hasMLXAudio(in environment: URL) -> Bool {
        let lib = environment.appendingPathComponent("lib")
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: lib.path)
        else { return false }
        return versions.contains { version in
            FileManager.default.fileExists(
                atPath: lib.appendingPathComponent("\(version)/site-packages/mlx_audio").path
            )
        }
    }

    /// Whether the voice tools were ever installed into `environment`.
    nonisolated static func hasVoiceTools(in environment: URL) -> Bool {
        hasMLXAudio(in: environment) || FileManager.default.isExecutableFile(
            atPath: environment.appendingPathComponent("bin/mlx-speech").path
        )
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
            arguments = Self.mlxAudioSpeakArguments(
                entry: entry, request: request, scratch: scratch,
                defaultReference: try defaultReference(for: entry, hubCache: request.hubCache)
            )
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
        case .cloud:
            // Loud on purpose. A remote model is routed to CloudAudioRuntime long before it
            // reaches here, so arriving at this line means the routing broke — and a silent
            // no-op would look like a model that simply never answers.
            throw VoiceRuntimeError.failed(
                "\(entry.name) runs on a provider, not on this Mac, and should not have been "
                + "sent to the local runner. This is a bug — please report it."
            )
        case .unsupported:
            throw VoiceRuntimeError.notInstalled("No runner is wired up for this one yet.")
        }

        let started = Date()
        try await preparePinnedModels(
            Self.pinnedRepositories(for: entry, request: request),
            hubCache: request.hubCache, onStage: onStage
        )
        let output = try await run(
            executable: executable, arguments: arguments,
            hubCache: request.hubCache, onStage: onStage
        )

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
        entry: VoiceEntry, request: SpeechRequest, scratch: URL, defaultReference: URL? = nil
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
        } else if entry.supportsCloning, let reference = defaultReference {
            arguments += ["--ref_audio", reference.path]
        }
        return arguments
    }

    /// CSM with no recording of its own speaks as a stock speaker whose prompt mlx-audio
    /// takes from `sesame/csm-1b` — a gated repository, whose files cannot be pinned by
    /// digest without an accepted licence and fail for anyone without one. The same prompt
    /// ships, ungated, in the model's own pinned repository; handed over as the reference,
    /// its transcript comes from the pinned Whisper turbo.
    func defaultReference(for entry: VoiceEntry, hubCache: URL?) throws -> URL? {
        guard entry.id == VoiceCatalog.csm.id else { return nil }
        let model = try pinnedModel(entry.repo)
        return model.snapshot(hub: Self.hubDirectory(hubCache: hubCache))
            .appendingPathComponent(Self.csmDefaultPrompt)
    }

    static let csmDefaultPrompt = "prompts/conversational_a.wav"

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
        audio: URL, entryID: String, hubCache: URL? = nil,
        onStage: @escaping @Sendable (String) -> Void
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
        try await preparePinnedModels(
            Self.pinnedRepositories(for: entry, request: nil), hubCache: hubCache, onStage: onStage
        )
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
            hubCache: hubCache,
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

    // MARK: - Pinned models

    /// Every Hub repository a run reads — the model's own, and the ones its library names
    /// inside itself (Kokoro's voices, CSM's tokenizer and codec, MOSS's codec, LuxTTS's
    /// transcriber) — each pinned to a commit and a digest per file in
    /// `Resources/pinned-installs/models`.
    nonisolated static let pinnedRepositories: [String: [String]] = [
        VoiceCatalog.kokoro.id: ["mlx-community/Kokoro-82M-bf16", "prince-canuma/Kokoro-82M"],
        VoiceCatalog.csm.id: [
            "mlx-community/csm-1b", "unsloth/Llama-3.2-1B", "kyutai/moshiko-pytorch-bf16",
        ],
        VoiceCatalog.whisperTurbo.id: ["mlx-community/whisper-large-v3-turbo-asr-fp16"],
        VoiceCatalog.parakeet.id: ["mlx-community/parakeet-tdt-0.6b-v3"],
        VoiceCatalog.minimaxMusic.id: ["mlx-community/MiniMax-Music3-4bit"],
        VoiceCatalog.mossSoundEffect.id: [
            "appautomaton/openmoss-sound-effect-mlx", "appautomaton/openmoss-audio-tokenizer-mlx",
        ],
        VoiceCatalog.luxTTS.id: ["YatharthS/LuxTTS", "openai/whisper-base"],
    ]

    nonisolated static func pinnedRepositories(
        for entry: VoiceEntry, request: SpeechRequest?
    ) -> [String] {
        var repositories = pinnedRepositories[entry.id] ?? []
        // CSM has Whisper turbo write down a reference nobody transcribed — its stock
        // speaker's included.
        if entry.id == VoiceCatalog.csm.id,
           request?.referenceText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            repositories.append(VoiceCatalog.whisperTurbo.repo)
        }
        return repositories
    }

    /// The hub cache a child reads: the engine cache's, or wherever Hugging Face's own rules
    /// put it when none is set.
    nonisolated static func hubDirectory(
        hubCache: URL?, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let hubCache { return hubCache.appendingPathComponent("hub", isDirectory: true) }
        if let hub = environment["HF_HUB_CACHE"], !hub.isEmpty {
            return URL(fileURLWithPath: hub, isDirectory: true)
        }
        if let home = environment["HF_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("hub")
        }
        let cache = environment["XDG_CACHE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache")
        return cache.appendingPathComponent("huggingface/hub", isDirectory: true)
    }

    func pinnedModel(_ repository: String) throws -> PinnedInstall.HubModel {
        do {
            return try PinnedInstall.HubModel.load(repository, from: locks)
        } catch {
            throw VoiceRuntimeError.failed(
                "The reviewed file list for \(repository) is missing from the app, so it was "
                + "not run. Reinstalling the app puts it back."
            )
        }
    }

    /// Puts each repository's pinned files in place in the hub cache and points its `main`
    /// at the pinned commit, so the offline run that follows loads exactly those. A
    /// repository checked before, and still whole, costs a few `stat`s; otherwise every file
    /// is hashed, and only a missing or wrong one is fetched.
    func preparePinnedModels(
        _ repositories: [String], hubCache: URL?,
        onStage: @escaping @Sendable (String) -> Void
    ) async throws {
        let hub = Self.hubDirectory(hubCache: hubCache)
        for repository in repositories {
            let model = try pinnedModel(repository)
            let key = model.cacheDirectory(hub: hub).path
            while preparing.contains(key) {
                if Task.isCancelled { throw VoiceRuntimeError.cancelled }
                try? await Task.sleep(for: .milliseconds(200))
            }
            if Self.isInPlace(model, hub: hub) { continue }
            preparing.insert(key)
            defer { preparing.remove(key) }
            onStage("Checking \(repository)'s files")
            for command in model.fetchCommands(
                hub: hub, server: hubServer, protocols: hubProtocols
            ) {
                try await runChecked(command, onStage: onStage)
            }
            try Self.markInPlace(model, hub: hub)
        }
    }

    /// What `markInPlace` wrote last time, in the repository's cache folder — beside Hugging
    /// Face's own `refs`, `snapshots` and `blobs`, which its tools ignore.
    nonisolated static func marker(_ model: PinnedInstall.HubModel, hub: URL) -> URL {
        model.cacheDirectory(hub: hub).appendingPathComponent("silicon-pinned.json")
    }

    nonisolated static func markerContents(_ model: PinnedInstall.HubModel) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(model)
    }

    /// Whether this exact manifest was put in place before, `main` still names its commit,
    /// and every file is still there at its size. Anything else is checked in full.
    nonisolated static func isInPlace(_ model: PinnedInstall.HubModel, hub: URL) -> Bool {
        guard let recorded = try? Data(contentsOf: marker(model, hub: hub)),
              let expected = try? markerContents(model), recorded == expected,
              let main = try? String(
                  contentsOf: model.cacheDirectory(hub: hub).appendingPathComponent("refs/main"),
                  encoding: .utf8
              ),
              main.trimmingCharacters(in: .whitespacesAndNewlines) == model.revision
        else { return false }
        let snapshot = model.snapshot(hub: hub)
        return model.files.allSatisfy { file in
            let path = snapshot.appendingPathComponent(file.path).resolvingSymlinksInPath().path
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
            return size?.int64Value == file.size
        }
    }

    nonisolated static func markInPlace(_ model: PinnedInstall.HubModel, hub: URL) throws {
        let refs = model.cacheDirectory(hub: hub).appendingPathComponent("refs", isDirectory: true)
        try FileManager.default.createDirectory(at: refs, withIntermediateDirectories: true)
        // Hugging Face writes the bare commit, no newline.
        try Data(model.revision.utf8).write(to: refs.appendingPathComponent("main"), options: .atomic)
        try markerContents(model).write(to: marker(model, hub: hub), options: .atomic)
    }

    /// Runs one fetch to completion and fails with what it said if it failed.
    private func runChecked(
        _ command: PinnedInstall.Command, onStage: @escaping @Sendable (String) -> Void
    ) async throws {
        let process = ServerProcess()
        self.process = process
        try await process.start(
            executable: command.executable, arguments: command.arguments,
            onLogLine: { line in
                if line.hasPrefix("Downloading ") { onStage(line) }
            }
        )
        while await process.isRunning {
            if Task.isCancelled {
                await process.terminate()
                throw VoiceRuntimeError.cancelled
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        let log = await process.log
        guard await process.terminationStatus == 0 else {
            let tail = log.split(separator: "\n").suffix(2).joined(separator: " ")
            throw VoiceRuntimeError.failed(tail.isEmpty ? "\(command.label) failed." : tail)
        }
    }

    // MARK: - Process plumbing

    /// The child environment. Kokoro's phonemizer needs the espeak-ng library, which
    /// ships inside the `espeakng-loader` wheel — but misaki only looks for a Homebrew
    /// copy at a hardcoded path. phonemizer honors these variables, so point them at
    /// the bundled library and every machine works, Homebrew or not.
    ///
    /// Offline, always: the pinned files are already in the cache, and a library that
    /// reached for anything else — a moved `main`, a repository nobody reviewed — should
    /// fail rather than quietly fetch it.
    nonisolated static func childEnvironment(hubCache: URL? = nil) -> [String: String] {
        var environment = [
            "PYTHONUNBUFFERED": "1",
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
        ]
        if let hubCache {
            environment["HF_HOME"] = hubCache.path
            // Set too, so a cache location inherited from the app cannot send the child
            // somewhere other than where the pinned files were put.
            environment["HF_HUB_CACHE"] = hubDirectory(hubCache: hubCache).path
        }
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

    /// Runs one child to completion. Internal so a test can stand a harmless process in
    /// for a model and check that cancelling one job leaves another running.
    func run(
        executable: URL, arguments: [String], hubCache: URL? = nil,
        onStage: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let process = ServerProcess()
        self.process = process
        try await process.start(
            executable: executable,
            arguments: arguments,
            environment: Self.childEnvironment(hubCache: hubCache),
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
        // A full startup disk surfaces as opaque downloader errors; name the real
        // problem and the fix instead of relaying them.
        if log.contains("No space left on device")
            || log.contains("Background writer channel closed") {
            return "The download ran out of disk space. Point the model library at a "
                + "bigger drive in Settings → Model library — engine downloads follow it."
        }
        if ["OfflineModeIsEnabled", "LocalEntryNotFoundError", "IncompleteSnapshotError",
            "outgoing traffic has been disabled"].contains(where: log.contains) {
            return "The model asked for a file outside the ones reviewed for it, and voice "
                + "models only load reviewed files, so it was not fetched."
        }
        let lines = log.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("stage: ") }
        let tail = lines.suffix(3).joined(separator: " ")
        return tail.isEmpty ? "The voice engine produced no audio and no explanation."
            : tail
    }
}
