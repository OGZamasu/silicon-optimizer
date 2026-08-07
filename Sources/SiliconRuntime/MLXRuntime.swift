import Foundation
import SiliconCatalog
import SiliconCore
import SiliconPlanner

/// MLX backend, driven through `mlx_lm.server`.
///
/// MLX generally reaches first token faster than llama.cpp on dense models and integrates more
/// naturally with Apple's unified memory, but it has no equivalent of llama.cpp's on-demand
/// expert paging, so the selector prefers llama.cpp whenever a model needs to be streamed.
public actor MLXRuntime: InferenceRuntime {

    public nonisolated let kind: RuntimeKind = .mlx

    public private(set) var state: RuntimeState = .idle
    public private(set) var lastMetrics: GenerationMetrics?

    private var server: ServerProcess?
    private var client: OpenAIChatClient?
    private var installation: RuntimeInstallation?
    private var stateObserver: (@Sendable (RuntimeState) -> Void)?

    public init(installation: RuntimeInstallation? = nil) {
        self.installation = installation
    }

    public nonisolated static func locate() -> RuntimeInstallation? {
        RuntimeLocator.locateMLXServer()
    }

    public func observeState(_ observer: @escaping @Sendable (RuntimeState) -> Void) {
        stateObserver = observer
        observer(state)
    }

    private func transition(to newState: RuntimeState) {
        state = newState
        stateObserver?(newState)
    }

    public func start(_ request: LoadRequest) async throws {
        await stop()

        guard let installation = self.installation ?? Self.locate() else {
            throw RuntimeError.notInstalled(.mlx)
        }
        self.installation = installation

        guard request.configuration.expertStreaming == nil else {
            throw RuntimeError.expertStreamingUnsupported
        }

        let port = request.port > 0 ? request.port : PortAllocator.free()
        transition(to: .starting(stage: "Starting MLX…"))

        let server = ServerProcess()
        self.server = server
        try await server.start(
            executable: installation.executable,
            arguments: MLXArguments(
                model: request.model, configuration: request.configuration, port: port
            ).build()
        )

        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let client = OpenAIChatClient(endpoint: endpoint)
        self.client = client

        let ready = await client.waitUntilReady(timeout: 600) { Task.isCancelled }
        guard ready, await server.isRunning else {
            let log = await server.log
            await server.terminate()
            self.server = nil
            self.client = nil
            let message = Self.diagnose(log: log)
            transition(to: .failed(message: message))
            throw RuntimeError.didNotBecomeReady(log: message)
        }

        transition(to: .ready(endpoint: endpoint))
    }

    public func stop() async {
        guard server != nil else { return }
        transition(to: .stopping)
        await server?.terminate()
        server = nil
        client = nil
        transition(to: .idle)
    }

    public func chat(_ request: ChatRequest) async throws -> AsyncThrowingStream<ChatEvent, any Error> {
        guard let client else { throw RuntimeError.notRunning }
        let upstream = try client.stream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        if case .finished(let metrics) = event { self.record(metrics) }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func record(_ metrics: GenerationMetrics) { lastMetrics = metrics }

    static func diagnose(log: String) -> String {
        let lowercased = log.lowercased()
        if lowercased.contains("modulenotfounderror") || lowercased.contains("no module named") {
            return "mlx-lm is not installed in the Python environment that was found. "
                + "Run `pip install mlx-lm`, or point at a different interpreter in Settings."
        }
        if lowercased.contains("metal") && lowercased.contains("out of memory") {
            return "MLX ran out of unified memory. Reduce the context length or use a smaller model."
        }
        let tail = log.split(separator: "\n").suffix(8).joined(separator: "\n")
        return tail.isEmpty ? "MLX exited without reporting a reason." : tail
    }
}
