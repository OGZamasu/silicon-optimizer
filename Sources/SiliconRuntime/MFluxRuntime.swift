import Foundation
import SiliconCatalog
import SiliconCore
import SiliconControl
import SiliconPlanner

/// Drives `mflux-generate`.
///
/// Unlike the language runtimes there is no server to keep alive: each image is a process that
/// loads weights, denoises, writes a PNG and exits. That is a worse fit for repeated generation
/// but a much better fit for memory, because everything is released between images — and it is
/// the shape the tool actually has, so the driver matches it rather than pretending otherwise.
public actor MFluxRuntime: ImageRuntime {

    public nonisolated let kind: ImageRuntimeKind = .mflux

    public private(set) var state: RuntimeState = .idle

    private var process: ServerProcess?
    private var installation: RuntimeInstallation?
    private var huggingFaceToken: String?
    private var hubCache: URL?
    /// The hub cache pinned weights and adapter files are read from — the one the image
    /// installer fills. Resolved from `hubCache` when not given.
    private let hub: URL
    /// The reviewed manifests the adapter files are checked against.
    private let locks: URL
    /// `silicon_qwen21.py`, which runs an adapter entry; nil when the app carries none.
    private let adapterRunner: URL?

    /// - Parameter huggingFaceToken: Passed to mflux as `HF_TOKEN` so gated repositories can be
    ///   fetched. mflux downloads weights itself rather than going through this app's
    ///   `HuggingFaceClient`, so the token stored in Settings does not reach it otherwise — and a
    ///   GUI app launched from the Dock inherits no shell environment to fall back on, which left
    ///   gated image models unreachable however the token was provided.
    /// - Parameter hubCache: Where mflux's own weight downloads land (`HF_HOME`). Without it
    ///   they default to the startup disk's `~/.cache`, ignoring the model-library setting.
    /// - Parameter hub: The hub cache the image installer fills. Pinned entries are run from
    ///   their snapshot in it, and an adapter's file is fetched into it.
    public init(
        installation: RuntimeInstallation? = nil, huggingFaceToken: String? = nil,
        hubCache: URL? = nil, hub: URL? = nil,
        locks: URL = PinnedInstall.defaultLockRoot(),
        adapterRunner: URL? = MFluxRuntime.adapterRunnerScript()
    ) {
        self.installation = installation
        self.huggingFaceToken = huggingFaceToken
        self.hubCache = hubCache
        self.hub = hub ?? HuggingFaceHub.directory(home: hubCache)
        self.locks = locks
        self.adapterRunner = adapterRunner
    }

    /// The adapter runner shipped with the app: in the bundle's Resources, or — for
    /// `swift run` and the tests — the repository's. A signed app never falls back to a
    /// checkout, for the same reason `PinnedInstall.defaultLockRoot()` does not.
    public nonisolated static func adapterRunnerScript(
        bundle: URL = Bundle.main.bundleURL
    ) -> URL? {
        let candidate: URL
        if bundle.pathExtension.lowercased() == "app" {
            candidate = bundle.appendingPathComponent(
                "Contents/Resources/qwen21/silicon_qwen21.py"
            )
        } else {
            candidate = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // SiliconRuntime
                .deletingLastPathComponent()  // Sources
                .deletingLastPathComponent()  // repository
                .appendingPathComponent("Resources/qwen21/silicon_qwen21.py")
        }
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// The entry point only MFLUX 0.20 and later install. An environment without it is an
    /// older MFLUX, which cannot run Qwen-Image 2.1 by either route.
    public nonisolated static let qwenImage21EntryPoint = "mflux-generate-qwen-2.1"

    /// Whether this MFLUX can run `entry` at all: for Qwen-Image 2.1 and its adapter, whether
    /// it is 0.20 or later. Every other entry runs on any MFLUX the app installs.
    public nonisolated static func canRun(
        _ entry: DiffusionEntry, installation: RuntimeInstallation?
    ) -> Bool {
        guard let installation else { return false }
        guard entry.weightsRepository == DiffusionCatalog.qwenImage21.repository else { return true }
        return FileManager.default.isExecutableFile(
            atPath: installation.executable.deletingLastPathComponent()
                .appendingPathComponent(qwenImage21EntryPoint).path
        )
    }

    public nonisolated static func locate() -> RuntimeInstallation? {
        RuntimeLocator.locateMFlux()
    }

    /// The install, as commands: the shared environment (made with the newest Python the
    /// locks cover, so the voice tools fit in it later) and MFLUX's hash-locked packages,
    /// wheels only. An environment someone already made is kept, and decides the lock — unless
    /// no lock covers it, and then it is made again, and the voice tools that were in it go
    /// back in too when their locks cover the new Python.
    public nonisolated static func installPlan(
        basePython: URL?, locks: URL = PinnedInstall.defaultLockRoot(),
        environment: URL = VoiceRuntime.environment
    ) throws -> [PinnedInstall.Command] {
        let voiceToolsCleared = PinnedInstall.needsRemaking(
            environment, supported: PinnedInstall.mfluxPythons
        ) && VoiceRuntime.hasVoiceTools(in: environment)
        let (python, version, commands) = try PinnedInstall.environment(
            environment, tool: "MFLUX", supported: PinnedInstall.mfluxPythons,
            basePython: basePython
        )
        var plan = commands + [packageInstall(python: python, version: version, locks: locks)]
        if voiceToolsCleared, PinnedInstall.voicePythons.contains(version) {
            plan += VoiceRuntime.toolsInstall(python: python, version: version, locks: locks)
        }
        return plan
    }

    /// MFLUX's hash-locked packages, wheels only, into the shared environment at `python`.
    nonisolated static func packageInstall(
        python: URL, version: String, locks: URL
    ) -> PinnedInstall.Command {
        PinnedInstall.pipInstall(
            python: python,
            lock: PinnedInstall.lock(
                "mflux", directory: PinnedInstall.mlxEnvironmentLocks, python: version, in: locks
            ),
            label: "Installing MFLUX", onlyBinary: true
        )
    }

    /// Environment for the mflux child process.
    ///
    /// Both token names are set: `huggingface_hub` reads `HF_TOKEN` and still honours the older
    /// `HUGGING_FACE_HUB_TOKEN`, and which one applies depends on the version pulled in as a
    /// transitive dependency rather than on anything this app controls.
    static func childEnvironment(
        huggingFaceToken: String?, hubCache: URL? = nil
    ) -> [String: String] {
        var environment = ["PYTHONUNBUFFERED": "1"]
        if let token = huggingFaceToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            environment["HF_TOKEN"] = token
            environment["HUGGING_FACE_HUB_TOKEN"] = token
        }
        if let hubCache {
            environment["HF_HOME"] = hubCache.path
            // Set too, as the image installer does: an `HF_HUB_CACHE` inherited from the app's
            // own environment outranks `HF_HOME`, and would have MFLUX read somewhere other than
            // where the weights were downloaded.
            environment["HF_HUB_CACHE"] = HuggingFaceHub.directory(home: hubCache).path
        }
        return environment
    }

    public func generate(
        _ request: ImageRequest, model: InstalledModel
    ) async throws -> AsyncThrowingStream<ImageEvent, any Error> {
        guard let installation = self.installation ?? Self.locate() else {
            throw ImageRuntimeError.notInstalled
        }
        self.installation = installation

        var request = request
        var builder = MFluxArguments(request: request, model: model)
        if let entry = model.catalogID.flatMap(DiffusionCatalog.entry(id:)) {
            guard Self.canRun(entry, installation: installation) else {
                throw ImageRuntimeError.generationFailed(
                    "\(entry.name) needs MFLUX 0.20, and this installation is older. Update "
                    + "MFLUX from the Images tab — it keeps your models."
                )
            }
            // An adapter runs only on the steps it was trained for.
            request.configuration.steps = entry.normalizedSteps(request.configuration.steps)
            builder.request = request
            try await prepare(entry, into: &builder)
        }
        // Each model family has its own entry point; resolve it beside the one discovery found.
        let executable = installation.executable
            .deletingLastPathComponent()
            .appendingPathComponent(builder.executableName)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ImageRuntimeError.generationFailed(
                "\(builder.executableName) is missing from this MFLUX installation. "
                + "Update MFLUX from the Images tab."
            )
        }

        let arguments = builder.build()
        let process = ServerProcess()
        self.process = process
        state = .starting(stage: "Loading the model…")

        let started = Date()
        let (stream, continuation) = AsyncThrowingStream<ImageEvent, any Error>.makeStream()

        // Everything mflux reports comes over stderr: a tqdm progress bar and, at the end, its
        // own peak-memory figure. Parsing it is what turns a blank wait into a step counter and
        // gives a measured number to check the planner against.
        var peakMemory: Bytes?
        let totalSteps = request.configuration.steps
        let box = ProgressBox()

        try await process.start(
            executable: executable,
            arguments: arguments,
            environment: Self.childEnvironment(
                huggingFaceToken: huggingFaceToken, hubCache: hubCache
            ),
            onLogLine: { line in
                Task {
                    if let event = await box.interpret(line, totalSteps: totalSteps) {
                        continuation.yield(event)
                    }
                }
            }
        )

        Task {
            // Wait for the process to finish, then read what it left behind.
            while await process.isRunning {
                if Task.isCancelled {
                    await process.terminate()
                    continuation.finish(throwing: ImageRuntimeError.cancelled)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }

            let log = await process.log
            peakMemory = Self.parsePeakMemory(from: log)
            let status = await process.terminationStatus ?? 0

            await self.finish()

            guard status == 0 else {
                if Self.isGatedFailure(log: log) {
                    continuation.finish(throwing: ImageRuntimeError.gated)
                } else {
                    continuation.finish(throwing: ImageRuntimeError.generationFailed(
                        Self.diagnose(log: log)
                    ))
                }
                return
            }
            guard FileManager.default.fileExists(atPath: request.output.path) else {
                continuation.finish(throwing: ImageRuntimeError.noImageProduced)
                return
            }

            let elapsed = Date().timeIntervalSince(started)
            continuation.yield(.finished(ImageResult(
                image: request.output,
                elapsed: elapsed,
                peakMemory: peakMemory,
                stepsPerSecond: elapsed > 0 ? Double(totalSteps) / elapsed : 0
            )))
            continuation.finish()
        }

        return stream
    }

    private func finish() {
        process = nil
        state = .idle
    }

    /// What a pinned or adapter entry needs before its process starts: the snapshot its
    /// weights are read from, and for an adapter the file — fetched now, checked against its
    /// reviewed digest, if this is the first time its schedule was chosen.
    ///
    /// A pinned entry is never left to fetch its own weights mid-render: MFLUX would take the
    /// repository's `main`, not the reviewed commit, so a missing snapshot is an install to do,
    /// said plainly, rather than a download to start.
    private func prepare(_ entry: DiffusionEntry, into builder: inout MFluxArguments) async throws {
        guard entry.revision != nil || entry.adapter != nil else { return }
        guard DiffusionInstaller.weightsInPlace(entry, hub: hub),
              let snapshot = DiffusionInstaller.weightsSnapshot(for: entry, hub: hub)
        else {
            let base = entry.baseEntryID.flatMap(DiffusionCatalog.entry(id:)) ?? entry
            throw ImageRuntimeError.generationFailed(
                "\(base.name)'s weights are not downloaded yet. Install \(entry.name) from "
                + "the Images or Models tab first — it fetches the reviewed revision."
            )
        }
        builder.weightsSnapshot = snapshot

        guard let adapter = entry.adapter else { return }
        guard let runner = adapterRunner else {
            throw ImageRuntimeError.generationFailed(
                "The adapter runner is missing from the app. Reinstalling the app puts it back."
            )
        }
        let steps = builder.request.configuration.steps
        guard let variant = adapter.variant(steps: steps) else {
            throw ImageRuntimeError.generationFailed(
                "\(entry.name) runs in \(adapter.variants.map { String($0.steps) }.joined(separator: " or ")) steps."
            )
        }
        let files = DiffusionAdapterFiles(locks: locks, hub: hub)
        let sha256 = try files.sha256(variant, of: adapter)
        if !files.isInPlace(variant, of: adapter) {
            state = .starting(stage: "Fetching the \(variant.steps)-step adapter…")
            try await files.prepare(variant, of: adapter)
        }
        builder.adapterRun = .init(
            runner: runner, file: files.file(variant, of: adapter), sha256: sha256,
            scale: adapter.scale, variant: variant
        )
    }

    public func cancel() async {
        await process?.terminate()
        process = nil
        state = .idle
    }

    // MARK: - Log interpretation

    /// mflux prints `Peak MLX memory: 12.34 GB` when it finishes.
    static func parsePeakMemory(from log: String) -> Bytes? {
        guard let range = log.range(
            of: #"Peak MLX memory:\s*([0-9.]+)\s*GB"#, options: .regularExpression
        ) else { return nil }
        let digits = log[range].filter { $0.isNumber || $0 == "." }
        guard let gigabytes = Double(digits) else { return nil }
        // mflux divides by 10^9, so this is decimal GB.
        return Bytes(Int64(gigabytes * 1e9))
    }

    /// Whether the failure was the licence gate, which callers surface as an actionable
    /// alert rather than a dead-end message.
    static func isGatedFailure(log: String) -> Bool {
        let lowercased = log.lowercased()
        return lowercased.contains("401") || lowercased.contains("gated")
            || lowercased.contains("awaiting a review")
    }

    static func diagnose(log: String) -> String {
        // The adapter runner's own refusals already say what is wrong and what to do.
        for line in log.split(separator: "\n").reversed() {
            if line.hasPrefix("Adapter refused: ") || line.hasPrefix("This needs MFLUX ") {
                return String(line)
            }
        }
        let lowercased = log.lowercased()
        if lowercased.contains("no module named 'mflux'") {
            return "mflux is not installed in that Python environment. "
                + "Run `pip install mflux`, or point at a different interpreter in Settings."
        }
        if lowercased.contains("out of memory") || lowercased.contains("insufficient memory") {
            return "Ran out of memory. Lower the resolution, quantize further, or turn on "
                + "tiled decoding."
        }
        if isGatedFailure(log: log) {
            return "This model is gated on Hugging Face. Accept its licence on the model page "
                + "and add an access token in Settings."
        }
        if lowercased.contains("connection") || lowercased.contains("resolve") {
            return "Could not reach Hugging Face to fetch the weights."
        }
        if lowercased.contains("is not supported by") {
            return "This MFLUX build routes that model through a different generator. "
                + "Upgrade with `pip install --upgrade mflux`."
        }
        let tail = log.split(separator: "\n").suffix(6).joined(separator: "\n")
        return tail.isEmpty ? "The runtime exited without reporting a reason." : tail
    }
}

/// Tracks progress across log lines, which arrive out of order and in fragments.
actor ProgressBox {
    private var lastStep = -1
    private var announcedLoading = false

    func interpret(_ line: String, totalSteps: Int) -> ImageEvent? {
        // The adapter runner names its stages itself.
        if line.hasPrefix(MFluxArguments.stagePrefix) {
            announcedLoading = true
            return .stage(String(line.dropFirst(MFluxArguments.stagePrefix.count)) + "…")
        }
        // tqdm renders as `  50%|█████     | 2/4 [00:03<00:03, ...]`
        if let range = line.range(of: #"(\d+)/(\d+)"#, options: .regularExpression) {
            let parts = line[range].split(separator: "/")
            if parts.count == 2, let index = Int(parts[0]), let total = Int(parts[1]),
               total == totalSteps, index != lastStep {
                lastStep = index
                return .step(index: index, total: total)
            }
        }
        if !announcedLoading, line.lowercased().contains("fetching")
            || line.lowercased().contains("loading") {
            announcedLoading = true
            return .stage("Fetching weights…")
        }
        return nil
    }
}

/// Builds the `mflux-generate` command line.
public struct MFluxArguments: Sendable {
    public var request: ImageRequest
    public var model: InstalledModel
    /// The pinned revision's snapshot, for an entry with one: passed as the model, which
    /// mflux reads as a local path, so what loads is exactly that commit's files.
    public var weightsSnapshot: URL?
    /// Set for an adapter entry: the run goes through `silicon_qwen21.py` instead of an
    /// mflux entry point.
    public var adapterRun: AdapterRun?

    public struct AdapterRun: Sendable, Equatable {
        public var runner: URL
        public var file: URL
        public var sha256: String
        public var scale: Double
        public var variant: DiffusionAdapter.Variant

        public init(
            runner: URL, file: URL, sha256: String, scale: Double,
            variant: DiffusionAdapter.Variant
        ) {
            self.runner = runner
            self.file = file
            self.sha256 = sha256
            self.scale = scale
            self.variant = variant
        }
    }

    /// What the adapter runner starts its stage lines with.
    public static let stagePrefix = "silicon-stage: "
    /// The adapter runner runs on the MFLUX environment's own interpreter.
    public static let adapterInterpreter = "python3"

    public init(
        request: ImageRequest, model: InstalledModel,
        weightsSnapshot: URL? = nil, adapterRun: AdapterRun? = nil
    ) {
        self.request = request
        self.model = model
        self.weightsSnapshot = weightsSnapshot
        self.adapterRun = adapterRun
    }

    /// The entry point for this model's family.
    ///
    /// MFLUX does not have one generator: FLUX.1 goes through `mflux-generate`, FLUX.2 through
    /// `mflux-generate-flux2`, Qwen and Z-Image through their own. Passing a FLUX.2 model to
    /// `mflux-generate` is rejected outright, so the binary is part of the model's identity
    /// rather than a detail of invocation.
    public var executableName: String {
        adapterRun == nil ? Self.executableName(for: model.catalogID ?? "") : Self.adapterInterpreter
    }

    public static func executableName(for catalogID: String) -> String {
        switch catalogID {
        case "flux2-klein-4b", "flux2-klein-9b": "mflux-generate-flux2"
        case "qwen-image": "mflux-generate-qwen"
        case "qwen-image-2.1": MFluxRuntime.qwenImage21EntryPoint
        // No entry point takes an adapter for 2.1, so the MFLUX environment's own Python runs
        // the app's runner, which builds mflux's QwenImage21 itself.
        case "qwen-image-2.1-pruna": adapterInterpreter
        case "z-image-turbo": "mflux-generate-z-image-turbo"
        case "z-image": "mflux-generate-z-image"
        case "ernie-image-turbo": "mflux-generate-ernie-image-turbo"
        case "ernie-image": "mflux-generate-ernie-image"
        // flux1-krea-dev shares FLUX.1's entry point — it is a dev finetune, not a separate
        // architecture, and has no binary of its own.
        default: "mflux-generate"
        }
    }

    public func build() -> [String] {
        if let adapterRun { return adapterArguments(adapterRun) }
        let configuration = request.configuration
        var arguments: [String] = [
            "--model", weightsSnapshot?.path ?? model.catalogID.flatMap(Self.mfluxAlias) ?? model.name,
            "--prompt", request.prompt,
            "--width", String(configuration.width),
            "--height", String(configuration.height),
            "--steps", String(configuration.steps),
            "--output", request.output.path,
        ]

        // mflux takes the bit width as a bare number.
        if let bits = Self.quantizeFlag(configuration.quantization) {
            arguments += ["--quantize", String(bits)]
        }
        if let seed = request.seed {
            arguments += ["--seed", String(seed)]
        }
        if let guidance = request.guidance {
            arguments += ["--guidance", String(guidance)]
        }

        // Revision: start from an existing image instead of noise. The atomic `--image
        // PATH STRENGTH` form is current mflux; `--image-path` is deprecated.
        if let initImage = configuration.initImage {
            arguments += [
                "--image", initImage.path,
                String(configuration.initImageInfluence),
            ]
        }

        // `--low-ram` frees the transformer between images and caps the MLX buffer cache. It
        // does not lower the peak of a single image — measured byte-identical with and without
        // on FLUX.2-klein-4B (issue #3) — so it is passed when asked for and never as a
        // memory remedy.
        if configuration.lowRAM || configuration.residentBlocks != nil {
            arguments.append("--low-ram")
        }

        return arguments
    }

    /// The adapter runner's command line: the base's pinned snapshot, the adapter file with the
    /// digest and scale it must match, and the schedule it was trained for — spelled so Python
    /// reads back the same doubles. No guidance and no negative prompt, ever: the adapters
    /// are distilled for a single conditional pass.
    func adapterArguments(_ run: AdapterRun) -> [String] {
        let configuration = request.configuration
        var arguments: [String] = [
            run.runner.path,
            "--model-path", weightsSnapshot?.path ?? "",
            "--adapter", run.file.path,
            "--adapter-sha256", run.sha256,
            "--adapter-scale", String(run.scale),
            "--sigmas", run.variant.sigmas.map { String($0) }.joined(separator: ","),
            "--steps", String(run.variant.steps),
            "--prompt", request.prompt,
            "--width", String(configuration.width),
            "--height", String(configuration.height),
            "--output", request.output.path,
        ]
        if let bits = Self.quantizeFlag(configuration.quantization) {
            arguments += ["--quantize", String(bits)]
        }
        if let seed = request.seed {
            arguments += ["--seed", String(seed)]
        }
        if let initImage = configuration.initImage {
            arguments += ["--image", initImage.path, String(configuration.initImageInfluence)]
        }
        if configuration.lowRAM || configuration.residentBlocks != nil {
            arguments.append("--low-ram")
        }
        return arguments
    }

    /// Bit widths mflux accepts. Anything else is left unquantized rather than guessed at.
    static func quantizeFlag(_ quantization: Quantization) -> Int? {
        switch quantization {
        case .mlx4, .q4_K_M, .q4_K_S, .q4_0: 4
        case .mlx6, .q6_K: 6
        case .mlx8, .q8_0: 8
        case .q3_K_M, .q3_K_S, .q3_K_L: 3
        case .q5_K_M, .q5_K_S: 5
        default: nil
        }
    }

    /// Maps a catalog id onto the alias mflux knows it by.
    static func mfluxAlias(_ catalogID: String) -> String? {
        switch catalogID {
        case "flux1-schnell": "schnell"
        case "flux1-dev": "dev"
        case "flux1-krea-dev": "krea-dev"
        case "flux2-klein-4b": "flux2-klein-4b"
        case "flux2-klein-9b": "flux2-klein-9b"
        // The repository, not an alias. `mflux-generate-qwen` never reads `--model` as a model
        // choice: a built-in name leaves it on its default, and only anything else becomes the
        // weights path. Its default was Qwen/Qwen-Image through mflux 0.18.1 and is
        // Qwen/Qwen-Image-2512 from 0.20.0 (`qwen` became that one's alias), so the old `qwen`
        // would quietly fetch and render a different 57 GB model than the one installed.
        case "qwen-image": "Qwen/Qwen-Image"
        case "z-image-turbo": "z-image-turbo"
        case "z-image": "z-image"
        case "ernie-image-turbo": "ernie-image-turbo"
        case "ernie-image": "ernie-image"
        // Only a fallback: a pinned entry is passed as its snapshot's path instead.
        case "qwen-image-2.1": "qwen-image-2.1"
        default: nil
        }
    }
}
