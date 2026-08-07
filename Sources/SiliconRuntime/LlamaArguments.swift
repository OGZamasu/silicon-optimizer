import Foundation
import SiliconCatalog
import SiliconCore
import SiliconPlanner

/// Builds the `llama-server` command line from a plan.
///
/// This type is the reason the app can promise "never open Terminal": every flag a user would
/// otherwise have to research is derived here from the model's architecture and the machine's
/// memory. It is pure and synchronous so it can be unit-tested and shown to the user verbatim in
/// Advanced mode.
public struct LlamaArguments: Sendable {

    public var model: InstalledModel
    public var configuration: LoadConfiguration
    public var port: Int
    public var installation: RuntimeInstallation?

    public init(
        model: InstalledModel, configuration: LoadConfiguration,
        port: Int, installation: RuntimeInstallation? = nil
    ) {
        self.model = model
        self.configuration = configuration
        self.port = port
        self.installation = installation
    }

    public func build() -> [String] {
        var arguments: [String] = [
            "--model", model.primaryFile.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--ctx-size", String(configuration.contextLength),
            "--batch-size", String(configuration.batchSize),
            "--ubatch-size", String(configuration.microBatchSize),
        ]

        // On Apple Silicon the GPU shares the same physical memory as the CPU, so there is no
        // reason to leave any layer behind. 999 is the idiomatic "all of them".
        arguments += ["--n-gpu-layers", configuration.gpuLayerFraction >= 1.0
            ? "999"
            : String(Int(Double(model.shape?.blockCount ?? 32) * configuration.gpuLayerFraction))]

        // Recent llama.cpp takes on/off/auto here; older builds accept the bare flag. "auto"
        // is safe on both because it is also a valid value for the newer parser.
        arguments += ["--flash-attn", configuration.flashAttention ? "on" : "off"]

        if configuration.kvCachePrecision != .f16 {
            arguments += [
                "--cache-type-k", configuration.kvCachePrecision.rawValue,
                "--cache-type-v", configuration.kvCachePrecision.rawValue,
            ]
        }

        if configuration.threads > 0 {
            // Only the performance cores are worth scheduling on; including efficiency cores
            // slows generation because the fast cores end up waiting at each barrier.
            arguments += ["--threads", String(configuration.threads)]
        }

        if let projector = model.projectorFile {
            arguments += ["--mmproj", projector.path]
        }

        // Jinja templating enables the model's own chat template and tool-call grammar, which
        // is what makes function calling work without per-model special cases.
        arguments += ["--jinja"]

        arguments += expertStreamingArguments()

        return arguments
    }

    /// Flags for the on-demand MoE expert paging described in ggml-org/llama.cpp#23324.
    func expertStreamingArguments() -> [String] {
        guard let streaming = configuration.expertStreaming else { return [] }
        var arguments = ["--moe-n-slots", String(streaming.slotCount)]

        // `--moe-n-layers` must always be sent, even though `--help` documents "0 = all layers".
        //
        // That default only holds for the *context* parameters, which llama.cpp normalises from
        // 0 to INT32_MAX. The model loader reads the un-normalised *model* parameter, and its
        // check is `layer_idx >= params.moe.n_layers` — so with the flag omitted every layer is
        // skipped for offload and the expert tensors load in full. Measured on Qwen3-Coder-30B:
        // 19 GB resident without the flag, 5.3 GB with it. The feature silently does nothing.
        let layerCount = streaming.layerCount > 0
            ? streaming.layerCount
            : (model.shape?.moe?.moeLayerCount ?? model.shape?.blockCount ?? 0)
        if layerCount > 0 {
            arguments += ["--moe-n-layers", String(layerCount)]
        }

        // Both are required by the proof of concept, and for good reason:
        //  --no-mmap   so expert tensors are never mapped into the address space up front,
        //              which is the whole point — the pool is allocated explicitly instead.
        //  --no-warmup so the warmup pass does not try to touch every expert and defeat the
        //              slot pool by OOMing before the first real token.
        arguments += ["--no-mmap", "--no-warmup"]
        return arguments
    }

    /// The command exactly as it will be run, for display in Advanced mode and for bug reports.
    public func displayCommand(executable: URL) -> String {
        ([executable.path] + build())
            .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            .joined(separator: " ")
    }

    /// Validates the configuration against constraints the runtime itself enforces, so the user
    /// sees a clear message instead of a crashed subprocess.
    public func validate() -> [String] {
        var problems: [String] = []

        if let streaming = configuration.expertStreaming {
            guard let moe = model.shape?.moe else {
                problems.append("Expert streaming only applies to mixture-of-experts models.")
                return problems
            }
            if !streaming.satisfiesConstraint(
                microBatch: configuration.microBatchSize,
                expertsUsedPerToken: moe.expertsUsedPerToken
            ) {
                let maximum = ExpertStreamingConfiguration.maximumMicroBatch(
                    slotCount: streaming.slotCount, expertsUsedPerToken: moe.expertsUsedPerToken
                )
                problems.append(
                    "Micro-batch \(configuration.microBatchSize) exceeds what a "
                    + "\(streaming.slotCount)-slot pool can hold. Lower it to \(maximum) or fewer, "
                    + "or raise the slot count."
                )
            }
            if streaming.slotCount > moe.expertCount {
                problems.append(
                    "Slot count \(streaming.slotCount) is larger than the model's "
                    + "\(moe.expertCount) experts — the extra slots would do nothing."
                )
            }
            if installation?.hasExpertStreaming == false {
                problems.append(
                    "The installed llama.cpp build does not accept --moe-n-slots."
                )
            }
        }

        if configuration.microBatchSize > configuration.batchSize {
            problems.append("Micro-batch cannot exceed batch size.")
        }
        if let shape = model.shape, configuration.contextLength > shape.trainingContextLength * 4 {
            problems.append(
                "Context \(configuration.contextLength) is far beyond the model's trained "
                + "\(shape.trainingContextLength); quality will degrade badly."
            )
        }
        return problems
    }
}

/// Builds the `mlx_lm.server` command line.
public struct MLXArguments: Sendable {
    public var model: InstalledModel
    public var configuration: LoadConfiguration
    public var port: Int

    public init(model: InstalledModel, configuration: LoadConfiguration, port: Int) {
        self.model = model
        self.configuration = configuration
        self.port = port
    }

    public func build() -> [String] {
        // MLX takes a model directory rather than a single weights file.
        [
            "--model", model.primaryFile.deletingLastPathComponent().path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--max-tokens", String(configuration.contextLength),
        ]
    }
}
