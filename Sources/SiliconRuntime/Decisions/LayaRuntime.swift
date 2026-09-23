import CryptoKit
import Foundation

// MARK: - Where everything lives

/// The Laya install: where its Python environment and weights live, how they get there, and
/// whether they are there now.
///
/// **Everything goes where the model library goes.** The environment is a few hundred
/// megabytes and each checkpoint is another six hundred to eight hundred, and the default
/// places for both — `~/.cache/huggingface` and a venv in the home directory — are on the
/// startup disk. This Mac's startup disk has about thirteen gigabytes free. So the
/// environment is created inside the configured library and `HF_HOME` is pointed at the
/// same `Engine Cache` directory every other Python engine here already uses, which is the
/// pattern that exists precisely because 153 GB once accumulated on the startup disk before
/// anybody noticed.
///
/// With no library configured there is nowhere safe to put any of it, and the install says
/// so rather than quietly filling the boot volume.
public struct LayaInstallation: Sendable, Equatable {

    /// What is missing, in the order it has to be fixed.
    public enum Missing: Sendable, Equatable {
        case nothing
        /// No model library is configured, so there is nowhere this may write.
        case libraryNotConfigured
        /// The library is configured but not there — an external drive, unmounted.
        case libraryUnreachable(String)
        /// No Python new enough to build the environment with.
        case python
        /// No environment, or one without `laya_mlx` in it.
        case environment
        /// The environment is there; this checkpoint is not.
        case checkpoint(LayaCheckpoint)
    }

    public var missing: Missing
    public var detail: String
    public var environment: URL?
    public var python: URL?
    public var hubCache: URL?
    /// Which checkpoints are fully on disk right now.
    public var installedCheckpoints: Set<LayaCheckpoint>
    /// Bytes the environment and the fetched checkpoints occupy together.
    public var bytesOnDisk: Int64

    public var isInstalled: Bool { missing == .nothing }

    public init(
        missing: Missing, detail: String, environment: URL? = nil, python: URL? = nil,
        hubCache: URL? = nil, installedCheckpoints: Set<LayaCheckpoint> = [],
        bytesOnDisk: Int64 = 0
    ) {
        self.missing = missing
        self.detail = detail
        self.environment = environment
        self.python = python
        self.hubCache = hubCache
        self.installedCheckpoints = installedCheckpoints
        self.bytesOnDisk = bytesOnDisk
    }
}

public enum LayaInstallError: Error, LocalizedError, Equatable {
    case noModelLibrary
    case libraryUnreachable(String)
    case noPython(tried: [String])
    case stepFailed(step: String, detail: String)
    /// The wheel pip fetched does not hash to the pinned `LayaPackage.wheelSHA256`. Thrown
    /// before that file is ever handed to `pip install`, so nothing is half-installed —
    /// the venv exists, but `laya_mlx` is not in it.
    case wheelHashMismatch(expected: String, got: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noModelLibrary:
            "Set a model library folder in Settings first. Laya's environment and its "
            + "weights are about 1.5 GB, and they must not land on the startup disk."
        case .libraryUnreachable(let path):
            "The model library at \(path) is not there. If it is on an external drive, "
            + "mount it and try again."
        case .noPython(let tried):
            "No Python \(LayaPackage.minimumPython.major).\(LayaPackage.minimumPython.minor) "
            + "or newer was found. laya-mlx needs one. Tried: \(tried.joined(separator: ", "))."
        case .stepFailed(let step, let detail):
            "\(step) failed: \(detail)"
        case .wheelHashMismatch(let expected, let got):
            "The downloaded \(LayaPackage.requirement) wheel does not match the pinned "
            + "checksum (expected \(expected.prefix(12))\u{2026}, got \(got.prefix(12))\u{2026}"
            + "). Nothing was installed. This usually means PyPI served something other than "
            + "the pinned release — try again, and if it keeps happening do not proceed."
        case .cancelled:
            "The Laya install was cancelled."
        }
    }
}

/// One line of progress from an install, for a label and a bar.
public struct LayaInstallProgress: Sendable, Equatable {
    public var step: String
    public var detail: String
    /// 0–1 across the whole install, not within the step.
    public var fraction: Double

    public init(step: String, detail: String, fraction: Double) {
        self.step = step
        self.detail = detail
        self.fraction = fraction
    }
}

// MARK: - The runtime

/// Installs laya-mlx, fetches checkpoints, and keeps one sidecar alive to answer with.
///
/// An actor because all three of those are serialised against each other: a decision
/// arriving mid-install must wait rather than start a second interpreter, and two features
/// asking at once share the one loaded model.
public actor LayaRuntime {

    public static let shared = LayaRuntime()

    /// Where the model library is, read fresh on every call rather than captured.
    ///
    /// A closure because this target cannot see the app's settings object, and because the
    /// owner can move the library while the app is running — a captured path would then be
    /// pointing at the old drive.
    private var libraryProvider: @Sendable () async -> URL? = { nil }
    /// Where the driver script was installed to, out of the app bundle.
    private var scriptProvider: @Sendable () async -> URL? = { nil }
    private var sidecar: LayaSidecar?
    private var activeCheckpoint: LayaCheckpoint?
    private var lastUsed = Date()
    /// What the last successful load and answer measured on this machine, which is what the
    /// Decisions panel shows in place of a published benchmark.
    public private(set) var lastReady: LayaSidecar.Ready?
    public private(set) var lastPerQuestionMS: Double?
    public private(set) var lastPeakMemoryBytes: Int64?
    /// Set while an install is running, so the panel can say so and a second one is refused.
    public private(set) var isInstalling = false

    public init() {}

    public func configure(
        library: @escaping @Sendable () async -> URL?,
        script: @escaping @Sendable () async -> URL?
    ) {
        libraryProvider = library
        scriptProvider = script
    }

    // MARK: Locations

    /// The environment directory inside the library. Named for the app rather than for
    /// Laya so a library folder does not accumulate one directory per engine.
    public static func environmentDirectory(library: URL) -> URL {
        library.appendingPathComponent("Engine Cache/laya-env", isDirectory: true)
    }

    /// `HF_HOME`: the same cache directory every other Python engine here writes to, so a
    /// checkpoint fetched by Laya and one fetched by MFLUX sit side by side rather than in
    /// two copies of the hub layout.
    public static func hubCacheDirectory(library: URL) -> URL {
        library.appendingPathComponent("Engine Cache", isDirectory: true)
    }

    public static func pythonPath(environment: URL) -> URL {
        environment.appendingPathComponent("bin/python3")
    }

    /// Hugging Face's own layout under `HF_HOME`: `hub/models--org--name`.
    public static func checkpointDirectory(_ checkpoint: LayaCheckpoint, hubCache: URL) -> URL {
        let slug = "models--" + checkpoint.repository.replacingOccurrences(of: "/", with: "--")
        return hubCache.appendingPathComponent("hub/\(slug)", isDirectory: true)
    }

    /// Whether a checkpoint's weights are really there.
    ///
    /// The snapshot for the pinned revision, holding a `model.safetensors` — not merely the
    /// directory existing, which an interrupted download also leaves behind.
    public static func isInstalled(_ checkpoint: LayaCheckpoint, hubCache: URL) -> Bool {
        let snapshot = checkpointDirectory(checkpoint, hubCache: hubCache)
            .appendingPathComponent("snapshots/\(checkpoint.revision)", isDirectory: true)
        let weights = snapshot.appendingPathComponent("model.safetensors")
        return FileManager.default.fileExists(atPath: weights.path)
    }

    public static func installedBytes(_ checkpoint: LayaCheckpoint, hubCache: URL) -> Int64 {
        let blobs = checkpointDirectory(checkpoint, hubCache: hubCache)
            .appendingPathComponent("blobs", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: blobs, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        return entries.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    // MARK: What is installed

    public func installation(checkpoint: LayaCheckpoint = .default) async -> LayaInstallation {
        await Self.installation(
            checkpoint: checkpoint, library: libraryProvider(),
            script: scriptProvider()
        )
    }

    /// The same answer as a pure function, so a test can ask it about a directory it built
    /// rather than about this Mac.
    public static func installation(
        checkpoint: LayaCheckpoint = .default, library: URL?, script: URL?
    ) -> LayaInstallation {
        guard let library else {
            return LayaInstallation(
                missing: .libraryNotConfigured,
                detail: "Choose a model library folder in Settings. Laya needs about 1.5 GB "
                    + "and must not write to the startup disk."
            )
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: library.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return LayaInstallation(
                missing: .libraryUnreachable(library.path),
                detail: "The model library is not there. If it is on an external drive, "
                    + "mount it."
            )
        }
        let environment = environmentDirectory(library: library)
        let python = pythonPath(environment: environment)
        let hubCache = hubCacheDirectory(library: library)
        var installed: Set<LayaCheckpoint> = []
        var bytes: Int64 = 0
        for candidate in LayaCheckpoint.allCases where isInstalled(candidate, hubCache: hubCache) {
            installed.insert(candidate)
            bytes += installedBytes(candidate, hubCache: hubCache)
        }

        guard FileManager.default.isExecutableFile(atPath: python.path),
              hasPackage(environment: environment)
        else {
            return LayaInstallation(
                missing: .environment,
                detail: "Laya is not installed yet. It fetches "
                    + "\(LayaPackage.requirement) and a "
                    + "\(ByteCountFormatter.string(fromByteCount: checkpoint.downloadBytes, countStyle: .file))"
                    + " checkpoint into your model library.",
                environment: environment, python: python, hubCache: hubCache,
                installedCheckpoints: installed, bytesOnDisk: bytes
            )
        }
        bytes += directorySize(environment)
        guard installed.contains(checkpoint) else {
            return LayaInstallation(
                missing: .checkpoint(checkpoint),
                detail: "\(checkpoint.displayName) has not been downloaded yet "
                    + "(\(ByteCountFormatter.string(fromByteCount: checkpoint.downloadBytes, countStyle: .file))).",
                environment: environment, python: python, hubCache: hubCache,
                installedCheckpoints: installed, bytesOnDisk: bytes
            )
        }
        guard script != nil, FileManager.default.fileExists(atPath: script!.path) else {
            return LayaInstallation(
                missing: .environment,
                detail: "The Laya driver script is missing from the app bundle.",
                environment: environment, python: python, hubCache: hubCache,
                installedCheckpoints: installed, bytesOnDisk: bytes
            )
        }
        return LayaInstallation(
            missing: .nothing,
            detail: "\(checkpoint.displayName), pinned to "
                + "\(checkpoint.revision.prefix(7)), in your model library.",
            environment: environment, python: python, hubCache: hubCache,
            installedCheckpoints: installed, bytesOnDisk: bytes
        )
    }

    /// Whether `laya_mlx` is in that environment, by looking for the package directory
    /// rather than by running the interpreter — this is called while drawing a settings
    /// pane, and spawning Python to answer it would make the window stutter.
    static func hasPackage(environment: URL) -> Bool {
        let lib = environment.appendingPathComponent("lib", isDirectory: true)
        let versions = (try? FileManager.default.contentsOfDirectory(
            at: lib, includingPropertiesForKeys: nil
        )) ?? []
        return versions.contains { version in
            FileManager.default.fileExists(
                atPath: version.appendingPathComponent("site-packages/laya_mlx/__init__.py").path
            )
        }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    // MARK: Installing

    /// Which interpreters to build the environment from, newest first.
    ///
    /// laya-mlx needs 3.11 or newer and macOS ships 3.9, so `/usr/bin/python3` is listed
    /// last and usually fails the version check — it is there for a future macOS rather
    /// than as a real candidate today.
    public static let pythonCandidates = [
        "/opt/homebrew/bin/python3.13",
        "/opt/homebrew/bin/python3.12",
        "/opt/homebrew/bin/python3.11",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3.13",
        "/usr/local/bin/python3.12",
        "/usr/local/bin/python3.11",
        "/usr/bin/python3",
    ]

    /// The first interpreter that is both executable and new enough.
    public static func locatePython(
        candidates: [String] = pythonCandidates,
        version: (URL) -> (Int, Int)? = { probeVersion(of: $0) }
    ) -> URL? {
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.isExecutableFile(atPath: path),
                  let (major, minor) = version(url)
            else { continue }
            if major > minimum.major || (major == minimum.major && minor >= minimum.minor) {
                return url
            }
        }
        return nil
    }

    private static var minimum: (major: Int, minor: Int) { LayaPackage.minimumPython }

    public static func probeVersion(of interpreter: URL) -> (Int, Int)? {
        guard let output = RuntimeLocator.run(
            interpreter, arguments: ["-c", "import sys;print(sys.version_info[0],sys.version_info[1])"]
        ) else { return nil }
        let parts = output.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1])
        else { return nil }
        return (major, minor)
    }

    /// Creates the environment, installs the pinned package, fetches the pinned checkpoint.
    ///
    /// Each step is a separate short-lived process whose output is streamed, so a long pip
    /// download is a moving label rather than a frozen window — and so a failure names the
    /// step that failed instead of "install failed".
    public func install(
        checkpoint: LayaCheckpoint = .default,
        progress: @escaping @Sendable (LayaInstallProgress) -> Void = { _ in }
    ) async throws {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }

        guard let library = await libraryProvider() else { throw LayaInstallError.noModelLibrary }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: library.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw LayaInstallError.libraryUnreachable(library.path) }

        // The sidecar holds the environment's Python open; installing over a running one is
        // how a half-upgraded site-packages happens.
        await unload()

        let environment = Self.environmentDirectory(library: library)
        let hubCache = Self.hubCacheDirectory(library: library)
        let python = Self.pythonPath(environment: environment)
        try FileManager.default.createDirectory(
            at: hubCache, withIntermediateDirectories: true
        )

        if !FileManager.default.isExecutableFile(atPath: python.path) {
            guard let interpreter = Self.locatePython() else {
                throw LayaInstallError.noPython(tried: Self.pythonCandidates)
            }
            progress(.init(
                step: "Making a Python environment", detail: interpreter.path, fraction: 0.05
            ))
            try await run(
                interpreter, ["-m", "venv", environment.path],
                step: "Making a Python environment", environment: [:]
            ) { _ in }
        }

        let pip = environment.appendingPathComponent("bin/pip")
        let wheel = try await downloadAndVerifyWheel(pip: pip, hubCache: hubCache, progress: progress)
        defer { try? FileManager.default.removeItem(at: wheel) }

        progress(.init(
            step: "Installing \(LayaPackage.requirement)",
            detail: "about 300 MB, mostly MLX", fraction: 0.2
        ))
        try await run(
            pip,
            // The wheel on disk, not the requirement string: pip has already fetched and
            // this has already verified it, so this step never touches the network for the
            // package itself — only for its dependencies, which are not pinned by a hash.
            ["install", "--disable-pip-version-check", "--no-input", wheel.path],
            step: "Installing \(LayaPackage.requirement)",
            environment: Self.childEnvironment(hubCache: hubCache)
        ) { line in
            progress(.init(
                step: "Installing \(LayaPackage.requirement)",
                detail: String(line.prefix(120)), fraction: 0.35
            ))
        }

        try await fetch(checkpoint, python: python, hubCache: hubCache, progress: progress)
        progress(.init(step: "Ready", detail: checkpoint.displayName, fraction: 1))
    }

    /// Fetches the pinned wheel by itself — `pip download --no-deps`, never `install` — and
    /// checks its sha256 against `LayaPackage.wheelSHA256` before anything is handed to
    /// `pip install`.
    ///
    /// Only the top-level package is verified this way, deliberately: `--require-hashes`
    /// would need a pinned hash for every transitive dependency too (MLX, huggingface_hub,
    /// numpy, and whatever they pull in), which is a much larger reproducibility promise
    /// than this pin is making. What matters most — that the code laya-mlx itself runs is
    /// the exact release this was reviewed against — is what this checks.
    ///
    /// A mismatch throws before `pip install` ever runs, so a bad wheel never reaches
    /// site-packages: the venv exists, `laya_mlx` does not, and the next attempt starts
    /// clean rather than atop a partial install.
    private func downloadAndVerifyWheel(
        pip: URL, hubCache: URL, progress: @escaping @Sendable (LayaInstallProgress) -> Void
    ) async throws -> URL {
        let step = "Downloading \(LayaPackage.requirement)"
        progress(.init(step: step, detail: "verifying the pinned sha256 before install", fraction: 0.15))
        let downloadDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("laya-wheel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: downloadDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: downloadDirectory) }

        try await run(
            pip,
            [
                "download", "--no-deps", "--disable-pip-version-check", "--no-input",
                "--dest", downloadDirectory.path, LayaPackage.requirement,
            ],
            step: step, environment: Self.childEnvironment(hubCache: hubCache)
        ) { _ in }

        let downloaded = (try? FileManager.default.contentsOfDirectory(
            at: downloadDirectory, includingPropertiesForKeys: nil
        )) ?? []
        guard let wheel = downloaded.first(where: { $0.pathExtension == "whl" }) else {
            throw LayaInstallError.stepFailed(
                step: step, detail: "pip did not produce a wheel file"
            )
        }

        let digest = try Self.sha256Hex(ofFileAt: wheel)
        guard digest.caseInsensitiveCompare(LayaPackage.wheelSHA256) == .orderedSame else {
            throw LayaInstallError.wheelHashMismatch(expected: LayaPackage.wheelSHA256, got: digest)
        }

        // Moved out of the directory this function is about to delete, so the caller still
        // has a file to hand `pip install`.
        let verified = FileManager.default.temporaryDirectory
            .appendingPathComponent(wheel.lastPathComponent)
        try? FileManager.default.removeItem(at: verified)
        try FileManager.default.copyItem(at: wheel, to: verified)
        return verified
    }

    /// sha256 of a file on disk, lowercase hex. A pure, testable seam: the install path
    /// calls it on a real download, and a test calls it on a fixture it wrote itself.
    static func sha256Hex(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Fetches one checkpoint at its pinned revision, through `huggingface_hub` — which is
    /// already in the environment as a dependency of laya-mlx, and which writes into the
    /// same hub cache the library will later read from.
    public func fetch(
        _ checkpoint: LayaCheckpoint,
        progress: @escaping @Sendable (LayaInstallProgress) -> Void = { _ in }
    ) async throws {
        guard let library = await libraryProvider() else { throw LayaInstallError.noModelLibrary }
        try await fetch(
            checkpoint,
            python: Self.pythonPath(environment: Self.environmentDirectory(library: library)),
            hubCache: Self.hubCacheDirectory(library: library),
            progress: progress
        )
    }

    private func fetch(
        _ checkpoint: LayaCheckpoint, python: URL, hubCache: URL,
        progress: @escaping @Sendable (LayaInstallProgress) -> Void
    ) async throws {
        let size = ByteCountFormatter.string(
            fromByteCount: checkpoint.downloadBytes, countStyle: .file
        )
        let step = "Downloading \(checkpoint.displayName)"
        progress(.init(step: step, detail: size, fraction: 0.5))
        try await run(
            python,
            [
                "-c",
                // Pinned to the revision, never to a branch. `snapshot_download` is the
                // hub's own fetch, so the layout is exactly the one `laya_mlx.load` reads.
                "import sys;from huggingface_hub import snapshot_download;"
                + "p=snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2]);"
                + "print(p)",
                checkpoint.repository, checkpoint.revision,
            ],
            step: step, environment: Self.childEnvironment(hubCache: hubCache)
        ) { line in
            progress(.init(step: step, detail: String(line.prefix(120)), fraction: 0.75))
        }
    }

    /// The environment every Laya child process gets.
    ///
    /// `HF_HOME` is the whole point: without it `huggingface_hub` writes to
    /// `~/.cache/huggingface` on the startup disk and ignores the library setting entirely.
    /// `HF_HUB_DISABLE_TELEMETRY` because a decision lane that phones home about what it
    /// loaded is not what "nothing leaves the Mac" means.
    ///
    /// `PIP_CACHE_DIR` is the same rule applied to pip: left unset, pip's own cache lands at
    /// `~/Library/Caches/pip` on the startup disk regardless of where the venv or `HF_HOME`
    /// point, and it does not shrink itself. Pointed at the library instead, beside
    /// `Engine Cache`, so a wheel downloaded once during install and any later `pip`
    /// invocation share a cache that lives where every other byte of this feature does.
    public static func childEnvironment(
        hubCache: URL, token: String? = nil
    ) -> [String: String] {
        var environment = [
            "PYTHONUNBUFFERED": "1",
            "HF_HOME": hubCache.path,
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "PIP_CACHE_DIR": hubCache.appendingPathComponent("pip-cache", isDirectory: true).path,
        ]
        if let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            environment["HF_TOKEN"] = token
        }
        return environment
    }

    private func run(
        _ executable: URL, _ arguments: [String], step: String,
        environment: [String: String], onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LayaInstallError.stepFailed(
                step: step, detail: "\(executable.lastPathComponent) is missing."
            )
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        // One reader per handle. `LayaDiagnostics` installs a `readabilityHandler` too, so
        // attaching both here would have meant the second silently replacing the first and
        // the install reporting no output at all.
        let reader = LayaLineReader(handle: pipe.fileHandleForReading)
        do {
            try process.run()
        } catch {
            throw LayaInstallError.stepFailed(step: step, detail: error.localizedDescription)
        }
        ChildProcessRegistry.register(pid: process.processIdentifier)
        defer { ChildProcessRegistry.unregister(pid: process.processIdentifier) }

        var tail: [String] = []
        while let line = await reader.next() {
            onLine(line)
            tail.append(line)
            if tail.count > 20 { tail.removeFirst() }
            if Task.isCancelled {
                process.terminate()
                reader.stop()
                throw LayaInstallError.cancelled
            }
        }
        while process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        reader.stop()
        guard process.terminationStatus == 0 else {
            throw LayaInstallError.stepFailed(
                step: step,
                detail: tail.suffix(4).joined(separator: " / ").prefix(300).description
            )
        }
    }

    // MARK: Running

    /// The sidecar for this checkpoint, started if it is not up and swapped if the owner
    /// has changed checkpoints since.
    public func sidecar(for checkpoint: LayaCheckpoint) async throws -> LayaSidecar {
        if let sidecar, activeCheckpoint == checkpoint, await sidecar.isRunning {
            lastUsed = Date()
            return sidecar
        }
        if sidecar != nil { await unload() }

        guard let library = await libraryProvider() else {
            throw LayaSidecarError.pythonMissing("no model library is configured")
        }
        guard let script = await scriptProvider() else {
            throw LayaSidecarError.scriptMissing("laya_sidecar.py")
        }
        let environment = Self.environmentDirectory(library: library)
        let hubCache = Self.hubCacheDirectory(library: library)
        let fresh = LayaSidecar(configuration: .init(
            python: Self.pythonPath(environment: environment),
            script: script,
            checkpoint: checkpoint,
            environment: Self.childEnvironment(hubCache: hubCache)
        ))
        let ready = try await fresh.start()
        self.sidecar = fresh
        activeCheckpoint = checkpoint
        lastReady = ready
        lastPeakMemoryBytes = ready.peakMemoryBytes
        lastUsed = Date()
        return fresh
    }

    /// Releases the model. Called by the idle sweep, before an install, and when the owner
    /// switches checkpoints.
    public func unload() async {
        if let sidecar { await sidecar.stop() }
        sidecar = nil
        activeCheckpoint = nil
        lastReady = nil
    }

    public var isLoaded: Bool { sidecar != nil }
    public var loadedCheckpoint: LayaCheckpoint? { activeCheckpoint }

    func noteAnswer(perQuestionMS: Double?, peakMemoryBytes: Int64?) {
        lastUsed = Date()
        if let perQuestionMS { lastPerQuestionMS = perQuestionMS }
        if let peakMemoryBytes { lastPeakMemoryBytes = peakMemoryBytes }
    }

    /// How long a loaded checkpoint may sit unused before it is released.
    ///
    /// Twenty minutes, and the number is a measurement rather than a guess. Loading the
    /// English checkpoint off an external drive on this machine took **29 seconds**, not
    /// the second the library's benchmark timings might suggest — those measure inference
    /// on an already-resident model. So the unload has to pay for itself: holding about a
    /// gigabyte resident is worth avoiding half a minute of silence the next time a
    /// guardrail screens a command.
    ///
    /// Twenty minutes is long enough to cover a working session where decisions arrive in
    /// bursts, and short enough that a Mac left alone overnight is not still holding the
    /// weights in the morning.
    public static let idleUnloadSeconds: TimeInterval = 20 * 60

    /// Unloads if nothing has used it for `idleUnloadSeconds`. Returns whether it did.
    @discardableResult
    public func unloadIfIdle(now: Date = Date()) async -> Bool {
        guard sidecar != nil,
              now.timeIntervalSince(lastUsed) >= Self.idleUnloadSeconds
        else { return false }
        await unload()
        return true
    }
}
