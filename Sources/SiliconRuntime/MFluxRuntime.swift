import Foundation
import SiliconCatalog
import SiliconCore
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

    /// - Parameter huggingFaceToken: Passed to mflux as `HF_TOKEN` so gated repositories can be
    ///   fetched. mflux downloads weights itself rather than going through this app's
    ///   `HuggingFaceClient`, so the token stored in Settings does not reach it otherwise — and a
    ///   GUI app launched from the Dock inherits no shell environment to fall back on, which left
    ///   gated image models unreachable however the token was provided.
    /// - Parameter hubCache: Where mflux's own weight downloads land (`HF_HOME`). Without it
    ///   they default to the startup disk's `~/.cache`, ignoring the model-library setting.
    public init(
        installation: RuntimeInstallation? = nil, huggingFaceToken: String? = nil,
        hubCache: URL? = nil
    ) {
        self.installation = installation
        self.huggingFaceToken = huggingFaceToken
        self.hubCache = hubCache
    }

    public nonisolated static func locate() -> RuntimeInstallation? {
        RuntimeLocator.locateMFlux()
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

        let builder = MFluxArguments(request: request, model: model)
        // Each model family has its own entry point; resolve it beside the one discovery found.
        let executable = installation.executable
            .deletingLastPathComponent()
            .appendingPathComponent(builder.executableName)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ImageRuntimeError.generationFailed(
                "\(builder.executableName) is missing from this MFLUX installation. "
                + "Upgrade it with `pip install --upgrade mflux`."
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
private actor ProgressBox {
    private var lastStep = -1
    private var announcedLoading = false

    func interpret(_ line: String, totalSteps: Int) -> ImageEvent? {
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

    public init(request: ImageRequest, model: InstalledModel) {
        self.request = request
        self.model = model
    }

    /// The entry point for this model's family.
    ///
    /// MFLUX does not have one generator: FLUX.1 goes through `mflux-generate`, FLUX.2 through
    /// `mflux-generate-flux2`, Qwen and Z-Image through their own. Passing a FLUX.2 model to
    /// `mflux-generate` is rejected outright, so the binary is part of the model's identity
    /// rather than a detail of invocation.
    public var executableName: String {
        switch model.catalogID {
        case "flux2-klein-4b", "flux2-klein-9b": "mflux-generate-flux2"
        case "qwen-image": "mflux-generate-qwen"
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
        let configuration = request.configuration
        var arguments: [String] = [
            "--model", model.catalogID.flatMap(Self.mfluxAlias) ?? model.name,
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
        case "qwen-image": "qwen"
        case "z-image-turbo": "z-image-turbo"
        case "z-image": "z-image"
        case "ernie-image-turbo": "ernie-image-turbo"
        case "ernie-image": "ernie-image"
        default: nil
        }
    }
}
