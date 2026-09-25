import CryptoKit
import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
import SiliconCore
import SiliconPlanner
@testable import SiliconRuntime

/// The Qwen-Image 2.1 runtime: the command lines the app builds, the adapter runner's own
/// tests, and the whole local path — fetch-free, weight-free — through a stand-in MFLUX
/// environment whose `python3` records what it was asked and writes a PNG.
///
/// Hermetic: the stand-in environment, the hub, the manifests and the output all live in a
/// temporary directory made here. No MLX, no mflux, no weights, no network.
@Suite("Qwen-Image 2.1 runtime")
struct QwenImage21RunnerTests {

    static let base = DiffusionCatalog.qwenImage21
    static let pruna = DiffusionCatalog.qwenImage21Pruna
    static var adapter: DiffusionAdapter { pruna.adapter! }

    static let runnerDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/qwen21", isDirectory: true)

    private func carrier(_ entry: DiffusionEntry, quantization: Quantization = .mlx8) -> InstalledModel {
        InstalledModel(
            id: entry.id, name: entry.name, catalogID: entry.id,
            quantization: quantization, format: .mlx,
            primaryFile: URL(fileURLWithPath: "/tmp/out.png"), allFiles: [],
            projectorFile: nil, sizeOnDisk: .zero, installedAt: Date(),
            shape: nil, capabilities: []
        )
    }

    private func request(steps: Int, seed: Int? = 42) -> ImageRequest {
        ImageRequest(
            prompt: "A glowing neon shop sign that reads \"QWEN IMAGE 2.1\"",
            configuration: ImageConfiguration(width: 1024, height: 1024, steps: steps, quantization: .mlx8),
            seed: seed, guidance: 3.5, output: URL(fileURLWithPath: "/tmp/qwen21 out.png")
        )
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).map { arguments[$0 + 1] }
    }

    // MARK: - Command lines

    @Test func theAdapterRunsThroughTheRunnerWithItsScheduleAndNothingElse() throws {
        let snapshot = URL(fileURLWithPath: "/hub/models--Qwen--Qwen-Image-2.1/snapshots/790c926")
        let variant = Self.adapter.defaultVariant
        let run = MFluxArguments.AdapterRun(
            file: URL(fileURLWithPath: "/hub/adapter/p_qwen_image_2.1_8step_v0.1.safetensors"),
            sha256: String(repeating: "ab", count: 32), scale: Self.adapter.scale, variant: variant
        )
        let builder = MFluxArguments(
            request: request(steps: 8), model: carrier(Self.pruna), weightsSnapshot: snapshot,
            runner: URL(fileURLWithPath: "/app/qwen21/silicon_qwen21.py"), adapterRun: run
        )
        #expect(builder.executableName == "python3")
        let arguments = builder.build()
        #expect(arguments.first == "/app/qwen21/silicon_qwen21.py")
        #expect(value(after: "--model-path", in: arguments) == snapshot.path)
        #expect(value(after: "--adapter", in: arguments) == run.file.path)
        #expect(value(after: "--adapter-sha256", in: arguments) == run.sha256)
        #expect(value(after: "--adapter-scale", in: arguments) == "2.0")
        #expect(value(after: "--steps", in: arguments) == "8")
        #expect(value(after: "--quantize", in: arguments) == "8")
        #expect(value(after: "--seed", in: arguments) == "42")
        #expect(value(after: "--output", in: arguments) == "/tmp/qwen21 out.png")
        let sigmas = try #require(value(after: "--sigmas", in: arguments))
        #expect(sigmas.split(separator: ",").compactMap { Double($0) } == variant.sigmas)
        // Guidance was asked for, and is not passed: the adapters are single-pass.
        #expect(!arguments.contains("--guidance"))
        #expect(!arguments.contains("--negative-prompt"))
        #expect(!arguments.contains("--model"))
    }

    @Test func theFiveStepChoiceCarriesItsOwnSchedule() throws {
        let variant = try #require(Self.adapter.variant(steps: 5))
        let run = MFluxArguments.AdapterRun(
            file: URL(fileURLWithPath: "/a"), sha256: "00", scale: 2.0, variant: variant
        )
        let arguments = MFluxArguments(
            request: request(steps: 5), model: carrier(Self.pruna),
            weightsSnapshot: URL(fileURLWithPath: "/s"), runner: URL(fileURLWithPath: "/r.py"),
            adapterRun: run
        ).build()
        #expect(value(after: "--steps", in: arguments) == "5")
        #expect(value(after: "--sigmas", in: arguments)?.split(separator: ",").compactMap { Double($0) }
                == [1.0, 0.94, 6.0 / 7.0, 2.0 / 3.0, 0.4])
    }

    /// The base goes through the same runner, from its pinned snapshot, with no adapter and
    /// no schedule of its own — mflux's for the model, as its entry point would use.
    @Test func theBaseRunsFromItsPinnedSnapshotOnMFLUXsSchedule() {
        let snapshot = URL(fileURLWithPath: "/hub/models--Qwen--Qwen-Image-2.1/snapshots/790c926")
        let builder = MFluxArguments(
            request: request(steps: 40), model: carrier(Self.base), weightsSnapshot: snapshot,
            runner: URL(fileURLWithPath: "/app/qwen21/silicon_qwen21.py")
        )
        #expect(builder.executableName == "python3")
        let arguments = builder.build()
        #expect(arguments.first == "/app/qwen21/silicon_qwen21.py")
        #expect(value(after: "--model-path", in: arguments) == snapshot.path)
        #expect(value(after: "--steps", in: arguments) == "40")
        for flag in ["--adapter", "--adapter-sha256", "--adapter-scale", "--sigmas", "--guidance", "--negative-prompt"] {
            #expect(!arguments.contains(flag), "\(flag)")
        }
        #expect(MFluxArguments.executableName(for: Self.base.id) == "python3")
    }

    /// The runner's parser accepts exactly what the app builds, and reads the sigmas back as
    /// the same doubles — the contract between the two languages, checked in both. A prompt
    /// that looks like an option reaches the model as a prompt, and sets nothing else.
    @Test(arguments: [
        "A glowing neon shop sign that reads \"QWEN IMAGE 2.1\"",
        "-x --steps 1 --output /tmp/elsewhere.png",
        "--low-ram",
        "-- two dashes, then words",
    ])
    func theRunnerAcceptsTheAppsCommandLine(prompt: String) throws {
        let variants: [DiffusionAdapter.Variant?] = Self.adapter.variants + [nil]
        for variant in variants {
            let run = variant.map {
                MFluxArguments.AdapterRun(
                    file: URL(fileURLWithPath: "/a/adapter.safetensors"),
                    sha256: String(repeating: "cd", count: 32), scale: 2.0, variant: $0
                )
            }
            let steps = variant?.steps ?? 40
            var withImage = request(steps: steps)
            withImage.prompt = prompt
            withImage.configuration.initImage = URL(fileURLWithPath: "/tmp/base.png")
            withImage.configuration.initImageInfluence = 0.6
            withImage.configuration.lowRAM = prompt != "--low-ram"
            let arguments = MFluxArguments(
                request: withImage, model: carrier(variant == nil ? Self.base : Self.pruna),
                weightsSnapshot: URL(fileURLWithPath: "/s"),
                runner: Self.runnerDirectory.appendingPathComponent("silicon_qwen21.py"),
                adapterRun: run
            ).build()
            let script = """
                import json, sys
                sys.path.insert(0, \(Self.runnerDirectory.path.debugDescription))
                import silicon_qwen21 as r
                a = r.build_parser().parse_args(sys.argv[1:])
                r.check_arguments(a)
                sigmas = r.parse_sigmas(a.sigmas, a.steps) if a.sigmas else None
                print(json.dumps({"sigmas": [repr(s) for s in sigmas] if sigmas else None,
                                  "adapter": a.adapter, "steps": a.steps, "scale": a.adapter_scale,
                                  "quantize": a.quantize, "image": a.image, "low_ram": a.low_ram,
                                  "prompt": a.prompt, "output": a.output}))
                """
            let (status, output) = try Self.python(["-c", script] + arguments.dropFirst())
            #expect(status == 0, "\(output)")
            let parsed = try #require(
                try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            )
            #expect(parsed["steps"] as? Int == steps)
            if let variant {
                #expect((parsed["sigmas"] as? [String])?.compactMap(Double.init) == variant.sigmas)
                #expect(parsed["scale"] as? Double == 2.0)
            } else {
                #expect(parsed["sigmas"] is NSNull && parsed["adapter"] is NSNull)
            }
            #expect(parsed["quantize"] as? Int == 8)
            #expect(parsed["image"] as? [String] == ["/tmp/base.png", "0.6"])
            #expect(parsed["low_ram"] as? Bool == withImage.configuration.lowRAM)
            #expect(parsed["prompt"] as? String == prompt)
            #expect(parsed["output"] as? String == "/tmp/qwen21 out.png")
            #expect(arguments.contains("--prompt=" + prompt) && !arguments.contains("--prompt"))
        }
    }

    /// The runner's own suite — key mapping, metadata checks, the merge on a synthetic
    /// safetensors, the schedules — on the system Python, with nothing installed.
    @Test func theRunnersMergeTestsPass() throws {
        let (status, output) = try Self.python(
            ["-m", "unittest", "-v", "test_silicon_qwen21"], directory: Self.runnerDirectory
        )
        #expect(status == 0, "\(output)")
        #expect(output.contains("OK"))
    }

    static func python(_ arguments: [String], directory: URL? = nil) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = directory }
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Progress

    @Test func theRunnersStagesAndMFLUXsBarAreBothRead() async {
        let box = ProgressBox()
        if case .stage(let text) = await box.interpret("silicon-stage: Encoding the prompt", totalSteps: 8) {
            #expect(text == "Encoding the prompt…")
        } else {
            Issue.record("a stage line was not read as a stage")
        }
        if case .step(let index, let total) = await box.interpret(" 38%|███▊      | 3/8 [00:04<00:07,  1.4s/it]", totalSteps: 8) {
            #expect(index == 3 && total == 8)
        } else {
            Issue.record("the tqdm line was not read as a step")
        }
        #expect(MFluxRuntime.parsePeakMemory(from: "Peak MLX memory: 21.37 GB")
                == Bytes(Int64(21.37e9)))
        #expect(MFluxRuntime.diagnose(log: "loading\nRefused: the adapter does not fit")
                == "Refused: the adapter does not fit")
    }

    // MARK: - The local path, end to end, with a stand-in environment

    struct StandIn {
        let root: URL
        let installation: RuntimeInstallation
        let hub: URL
        let locks: URL
        let runner: URL
        let record: URL
        let adapterBytes = Data("the reviewed eight-step adapter".utf8)

        /// - Parameter entryPoint: whether the environment is MFLUX 0.20, which installs
        ///   `mflux-generate-qwen-2.1`.
        init(entryPoint: Bool = true) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("qwen21-runtime-\(UUID().uuidString)", isDirectory: true)
            let bin = root.appendingPathComponent("env/bin", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try requireTemporaryDirectory(root)
            record = root.appendingPathComponent("argv.json")
            hub = root.appendingPathComponent("hub", isDirectory: true)
            locks = root.appendingPathComponent("locks", isDirectory: true)
            runner = root.appendingPathComponent("silicon_qwen21.py")
            try Data("# stand-in\n".utf8).write(to: runner)

            func executable(_ name: String, _ body: String) throws {
                let url = bin.appendingPathComponent(name)
                try Data(body.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            try executable("mflux-generate", "#!/bin/sh\nexit 1\n")
            if entryPoint { try executable("mflux-generate-qwen-2.1", "#!/bin/sh\nexit 1\n") }
            // Records its arguments, speaks the runner's lines, writes the PNG it was asked for.
            try executable("python3", """
                #!/bin/sh
                /usr/bin/python3 - "$@" <<'PY'
                import json, sys
                args = sys.argv[1:]
                json.dump(args, open(\(record.path.debugDescription), "w"))
                out = args[args.index("--output") + 1]
                steps = int(args[args.index("--steps") + 1])
                sys.stderr.write("silicon-stage: Encoding the prompt\\n")
                for i in range(1, steps + 1):
                    sys.stderr.write(f"{i}/{steps} [00:01<00:00]\\n")
                open(out, "wb").write(b"\\x89PNG\\r\\n")
                sys.stderr.write("Peak MLX memory: 20.50 GB\\n")
                PY
                """)
            installation = RuntimeInstallation(
                kind: .mlx, executable: bin.appendingPathComponent("mflux-generate"),
                version: nil, hasExpertStreaming: false, source: .managed
            )
        }

        func placeBase() throws {
            let snapshot = DiffusionInstaller.cacheDirectory(for: DiffusionCatalog.qwenImage21.repository, hub: hub)
                .appendingPathComponent("snapshots/\(DiffusionCatalog.qwenImage21Revision)")
            for component in DiffusionCatalog.qwenImage21.componentDirectories {
                let directory = snapshot.appendingPathComponent(component)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try tinySafetensors().write(to: directory.appendingPathComponent("w.safetensors"))
            }
        }

        /// The default adapter file in place, and a manifest reviewing exactly its bytes.
        func placeAdapter() throws -> String {
            let adapter = QwenImage21RunnerTests.adapter
            let file = DiffusionInstaller.adapterFile(adapter.defaultVariant, of: adapter, hub: hub)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try adapterBytes.write(to: file)
            let digest = SHA256.hash(data: adapterBytes).map { String(format: "%02x", $0) }.joined()
            let model = PinnedInstall.HubModel(
                repository: adapter.repository, revision: adapter.revision,
                files: [.init(path: adapter.defaultVariant.file, sha256: digest, size: Int64(adapterBytes.count))]
            )
            let manifest = PinnedInstall.HubModel.manifest(adapter.repository, in: locks)
            try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(model).write(to: manifest)
            return digest
        }

        func runtime() -> MFluxRuntime {
            MFluxRuntime(installation: installation, hub: hub, locks: locks, qwenRunner: runner)
        }

        func clean() { removeTemporaryDirectory(root) }
    }

    @Test func anAdapterRenderRunsTheRunnerOnTheReviewedFile() async throws {
        let standIn = try StandIn()
        defer { standIn.clean() }
        try standIn.placeBase()
        let digest = try standIn.placeAdapter()
        let output = standIn.root.appendingPathComponent("out.png")
        // Asked for 20 steps — the few-step entry takes the nearest schedule it has.
        let asked = ImageRequest(
            prompt: "a lighthouse", configuration: ImageConfiguration(width: 1024, height: 1024, steps: 20, quantization: .mlx4),
            seed: 7, output: output
        )

        // Stage and step events are delivered as the lines arrive, on their own tasks, and on a
        // loaded machine the last of them can land after the stream has finished; how those
        // lines read is pinned by `theRunnersStagesAndMFLUXsBarAreBothRead`. Here: the result.
        var finished: ImageResult?
        for try await event in try await standIn.runtime().generate(asked, model: carrier(Self.pruna, quantization: .mlx4)) {
            if case .step(_, let total) = event { #expect(total == 8) }
            if case .finished(let result) = event { finished = result }
        }
        let result = try #require(finished)
        #expect(result.image == output)
        #expect(result.peakMemory == Bytes(Int64(20.5e9)))

        let argv = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: standIn.record)) as? [String])
        #expect(argv.first == standIn.runner.path)
        #expect(value(after: "--adapter-sha256", in: argv) == digest)
        #expect(value(after: "--adapter", in: argv)
                == DiffusionInstaller.adapterFile(Self.adapter.defaultVariant, of: Self.adapter, hub: standIn.hub).path)
        #expect(value(after: "--model-path", in: argv)?.hasSuffix("snapshots/\(DiffusionCatalog.qwenImage21Revision)") == true)
        #expect(value(after: "--steps", in: argv) == "8")
        #expect(value(after: "--quantize", in: argv) == "4")
    }

    /// The base through the same stand-in: the runner, its snapshot, no adapter, its 40 steps.
    @Test func aBaseRenderRunsTheRunnerWithoutAnAdapter() async throws {
        let standIn = try StandIn()
        defer { standIn.clean() }
        try standIn.placeBase()
        let output = standIn.root.appendingPathComponent("base.png")
        let asked = ImageRequest(
            prompt: "a lighthouse", configuration: ImageConfiguration(steps: 40, quantization: .mlx8),
            seed: 7, output: output
        )
        var finished: ImageResult?
        for try await event in try await standIn.runtime().generate(asked, model: carrier(Self.base)) {
            if case .finished(let result) = event { finished = result }
        }
        #expect(finished?.image == output)
        let argv = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: standIn.record)) as? [String])
        #expect(argv.first == standIn.runner.path)
        #expect(value(after: "--steps", in: argv) == "40")
        #expect(!argv.contains("--adapter") && !argv.contains("--sigmas"))
    }

    @Test func withoutTheBaseWeightsNothingIsFetchedOrRun() async throws {
        let standIn = try StandIn()
        defer { standIn.clean() }
        _ = try standIn.placeAdapter()
        let asked = ImageRequest(prompt: "p", configuration: ImageConfiguration(steps: 8), output: standIn.root.appendingPathComponent("o.png"))
        await #expect(throws: ImageRuntimeError.self) {
            _ = try await standIn.runtime().generate(asked, model: carrier(Self.pruna))
        }
        #expect(!FileManager.default.fileExists(atPath: standIn.record.path), "the runner must not have started")
    }

    /// An MFLUX older than 0.20 has no Qwen-Image 2.1 at all; both entries say so rather than
    /// failing somewhere inside it.
    @Test func anOlderMFLUXIsToldToUpdate() async throws {
        let standIn = try StandIn(entryPoint: false)
        defer { standIn.clean() }
        try standIn.placeBase()
        _ = try standIn.placeAdapter()
        #expect(!MFluxRuntime.canRun(Self.pruna, installation: standIn.installation))
        #expect(!MFluxRuntime.canRun(Self.base, installation: standIn.installation))
        #expect(MFluxRuntime.canRun(DiffusionCatalog.flux2Klein4B, installation: standIn.installation))
        let asked = ImageRequest(prompt: "p", configuration: ImageConfiguration(steps: 8), output: standIn.root.appendingPathComponent("o.png"))
        do {
            _ = try await standIn.runtime().generate(asked, model: carrier(Self.pruna))
            Issue.record("an older MFLUX ran Qwen-Image 2.1")
        } catch ImageRuntimeError.generationFailed(let message) {
            #expect(message.contains("MFLUX 0.20"))
        }
    }
}
