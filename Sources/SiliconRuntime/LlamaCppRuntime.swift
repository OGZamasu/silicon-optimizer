import Foundation
import SiliconCatalog
import SiliconCore
import SiliconPlanner

/// llama.cpp backend, driven through `llama-server`'s OpenAI-compatible HTTP API.
///
/// Running the server as a child process rather than linking libllama keeps the app in pure
/// Swift, isolates crashes in a 30 GB model load from the UI, and means a user can swap in their
/// own llama.cpp build — including a patched one with expert paging — without rebuilding the app.
public actor LlamaCppRuntime: InferenceRuntime {

    public nonisolated let kind: RuntimeKind = .llamaCpp

    public private(set) var state: RuntimeState = .idle
    public private(set) var lastMetrics: GenerationMetrics?
    public private(set) var loadProgress: Double = 0

    private var server: ServerProcess?
    private var client: OpenAIChatClient?
    private var installation: RuntimeInstallation?
    private var stateObserver: (@Sendable (RuntimeState) -> Void)?

    public init(installation: RuntimeInstallation? = nil) {
        self.installation = installation
    }

    public nonisolated static func locate() -> RuntimeInstallation? {
        RuntimeLocator.locateLlamaServer()
    }

    public func observeState(_ observer: @escaping @Sendable (RuntimeState) -> Void) {
        stateObserver = observer
        observer(state)
    }

    private func transition(to newState: RuntimeState) {
        state = newState
        stateObserver?(newState)
    }

    // MARK: - Lifecycle

    public func start(_ request: LoadRequest) async throws {
        await stop()

        let installation = self.installation ?? Self.locate()
        guard let installation else { throw RuntimeError.notInstalled(.llamaCpp) }
        self.installation = installation

        let port = request.port > 0 ? request.port : PortAllocator.free()
        let arguments = LlamaArguments(
            model: request.model, configuration: request.configuration,
            port: port, installation: installation,
            extraArguments: request.extraArguments
        )

        let problems = arguments.validate()
        if let blocking = problems.first, request.configuration.expertStreaming != nil,
           installation.hasExpertStreaming == false {
            throw RuntimeError.launchFailed(blocking)
        }

        transition(to: .starting(stage: "Starting llama.cpp…"))
        loadProgress = 0

        let server = ServerProcess()
        self.server = server

        try await server.start(
            executable: installation.executable,
            arguments: arguments.build(),
            environment: [:],
            onLogLine: { [weak self] line in
                Task { await self?.consume(logLine: line) }
            }
        )

        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let client = OpenAIChatClient(endpoint: endpoint)
        self.client = client

        // Large models legitimately take minutes to load from disk on first run, before the
        // file cache is warm. Ten minutes is generous rather than optimistic.
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

        loadProgress = 1
        transition(to: .ready(endpoint: endpoint))
    }

    public func stop() async {
        guard server != nil else {
            if case .idle = state {} else { transition(to: .idle) }
            return
        }
        transition(to: .stopping)
        await server?.terminate()
        server = nil
        client = nil
        loadProgress = 0
        transition(to: .idle)
    }

    // MARK: - Inference

    public func chat(_ request: ChatRequest) async throws -> AsyncThrowingStream<ChatEvent, any Error> {
        guard let client else { throw RuntimeError.notRunning }
        let upstream = try client.stream(request)

        // Tee the terminal metrics into `lastMetrics` so the dashboard has them without the
        // chat layer having to report back.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        if case .finished(let metrics) = event {
                            self.record(metrics)
                        }
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

    private func record(_ metrics: GenerationMetrics) {
        lastMetrics = metrics
    }

    public func serverLog() async -> String {
        await server?.log ?? ""
    }

    // MARK: - Log interpretation

    /// Turns llama.cpp's stderr into load progress, so a multi-minute load of a 40 GB model is
    /// not a blank spinner.
    ///
    /// Two log formats are handled. Older builds print a `load_tensors: ... NN%` percentage.
    /// Build b10280 and later print no percentage at default verbosity at all — only a handful
    /// of stage lines — and the percentage reappears only under `-lv 5`, which also emits a
    /// couple of thousand lines of metadata dump. Coarse honest stages beat a fake progress bar,
    /// so the newer format is mapped to named stages with an approximate fraction.
    private func consume(logLine line: String) {
        // Older builds: a real percentage, so use it verbatim.
        //
        // The percentage must be matched on its own. Scraping digits out of the whole
        // `load_tensors:` span picks up every other number in the line too — "offloading 28
        // repeating layers to GPU 25%" yielded 2825, i.e. a 2825% progress bar.
        if line.contains("load_tensors:"),
           let range = line.range(of: #"\d+%"#, options: .regularExpression),
           let percent = Int(line[range].dropLast()) {
            loadProgress = Double(min(percent, 100)) / 100
            transition(to: .starting(stage: "Loading weights… \(min(percent, 100))%"))
            return
        }

        for stage in Self.stages where line.contains(stage.needle) {
            // Only ever move forward: log lines can interleave, and a load that appears to go
            // backwards reads as a stall.
            guard stage.progress > loadProgress else { return }
            loadProgress = stage.progress
            transition(to: .starting(stage: stage.label))
            return
        }
    }

    /// Substrings that mark a load stage, with the fraction each represents. Ordered by the
    /// order llama.cpp emits them.
    static let stages: [(needle: String, label: String, progress: Double)] = [
        ("load_model: loading model", "Reading model file…", 0.1),
        ("llama_model_loader:", "Reading model metadata…", 0.2),
        ("load_tensors: loading model tensors", "Loading weights…", 0.35),
        ("llama_context: constructing", "Allocating context…", 0.6),
        ("llama_kv_cache:", "Allocating KV cache…", 0.7),
        ("sched_reserve:", "Reserving compute buffers…", 0.8),
        ("warming up", "Warming up…", 0.9),
        ("model loaded", "Starting server…", 0.95),
    ]

    /// Turns the tail of a failed server log into something a user can act on.
    static func diagnose(log: String) -> String {
        let lowercased = log.lowercased()

        if lowercased.contains("unrecognized argument") || lowercased.contains("invalid argument") {
            if lowercased.contains("moe-n-slots") {
                return "This llama.cpp build does not support expert streaming "
                    + "(--moe-n-slots). Turn it off, or install a build that has it."
            }
            return "llama.cpp rejected one of the launch options. "
                + "Check the command in Advanced mode."
        }
        if lowercased.contains("failed to allocate") || lowercased.contains("out of memory")
            || lowercased.contains("insufficient memory") {
            return "Ran out of memory while loading. Reduce the context length, quantize the "
                + "KV cache, or choose a smaller quantization."
        }
        if lowercased.contains("unknown model architecture")
            || lowercased.contains("unsupported model") {
            return "This llama.cpp build does not recognise the model's architecture. "
                + "Update llama.cpp and try again."
        }
        if lowercased.contains("no such file") {
            return "The model file is missing. It may have been moved or deleted."
        }
        if lowercased.contains("address already in use") {
            return "The chosen port was taken. Try loading again."
        }

        // Fall back to the last few lines, which is where the real error almost always is.
        let tail = log.split(separator: "\n").suffix(8).joined(separator: "\n")
        return tail.isEmpty ? "The runtime exited without reporting a reason." : tail
    }
}
