import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore
@testable import SiliconPlanner
@testable import SiliconRuntime

/// Drives the MLX runtime against a real `mlx_lm.server`.
///
/// Opt-in like the catalog suite, because it needs mlx-lm installed and a model in the Hugging
/// Face cache:
///
///     python3 -m venv ~/.silicon-mlx && ~/.silicon-mlx/bin/pip install mlx-lm
///     SILICON_MLX_TESTS=1 swift test --filter MLXIntegration
@Suite("MLX integration", .enabled(if: ProcessInfo.processInfo.environment["SILICON_MLX_TESTS"] == "1"))
struct MLXIntegrationTests {

    /// A directory of safetensors + tokenizer files, which is what MLX consumes — as opposed to
    /// llama.cpp's single GGUF.
    private func cachedModelDirectory() -> URL? {
        guard let path = try? String(contentsOfFile: "/tmp/mlx_snapshot_path.txt", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("config.json").path)
            ? url : nil
    }

    private func mlxModel(at directory: URL) -> InstalledModel {
        InstalledModel(
            id: "mlx-test", name: "Qwen2.5 0.5B (MLX)", catalogID: nil,
            quantization: .mlx4, format: .mlx,
            // MLX takes the containing directory; the runtime strips the last component, so a
            // file inside it is what gets stored.
            primaryFile: directory.appendingPathComponent("model.safetensors"),
            allFiles: [], projectorFile: nil, sizeOnDisk: .mib(320),
            installedAt: Date(), shape: nil, capabilities: []
        )
    }

    @Test func startsServesAndStops() async throws {
        let directory = try #require(cachedModelDirectory(), "no cached MLX model")
        try #require(MLXRuntime.locate() != nil, "mlx-lm not installed")

        let model = mlxModel(at: directory)
        let runtime = MLXRuntime()
        let configuration = LoadConfiguration(contextLength: 2048)

        try await runtime.start(LoadRequest(model: model, configuration: configuration))
        let state = await runtime.state
        #expect(state.isRunning, "MLX did not become ready: \(state.label)")

        var text = ""
        var metrics = GenerationMetrics()
        let request = ChatRequest(
            messages: [ChatMessage(role: .user, content: "Reply with the single word: PONG")],
            temperature: 0, maxTokens: 24
        )
        for try await event in try await runtime.chat(request) {
            switch event {
            case .token(let token): text += token
            case .reasoningToken: break
            case .finished(let final): metrics = final
            }
        }

        #expect(!text.isEmpty, "MLX produced no output")
        #expect(metrics.generatedTokens > 0)
        // MLX does not report llama.cpp's `timings` block, so throughput must come from the
        // client's own measurement rather than the server's.
        #expect(metrics.generationTokensPerSecond > 0,
                "throughput fallback failed for a server that reports no timings")

        await runtime.stop()
        let stopped = await runtime.state
        #expect(!stopped.isRunning)
    }

    /// Expert streaming is a llama.cpp feature; asking MLX for it must fail clearly rather than
    /// launching a server that silently ignores it.
    @Test func rejectsExpertStreaming() async throws {
        let directory = try #require(cachedModelDirectory(), "no cached MLX model")
        try #require(MLXRuntime.locate() != nil, "mlx-lm not installed")

        var configuration = LoadConfiguration(contextLength: 2048)
        configuration.expertStreaming = ExpertStreamingConfiguration(slotCount: 16)

        await #expect(throws: RuntimeError.self) {
            try await MLXRuntime().start(
                LoadRequest(model: mlxModel(at: directory), configuration: configuration)
            )
        }
    }
}
