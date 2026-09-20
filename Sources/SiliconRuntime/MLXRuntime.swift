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
    private var loadInFlight = false

    private let arbiter: LoadArbiter
    private let recorder: LoadFailureRecorder
    private let readinessTimeout: TimeInterval

    /// What went wrong with the last load, if the last load went wrong.
    public private(set) var lastFailure: LoadFailure?

    public init(
        installation: RuntimeInstallation? = nil,
        arbiter: LoadArbiter = .shared,
        recorder: LoadFailureRecorder = .shared,
        readinessTimeout: TimeInterval = 600
    ) {
        self.installation = installation
        self.arbiter = arbiter
        self.recorder = recorder
        self.readinessTimeout = readinessTimeout
    }

    /// What `mlx_lm.server` is called where a person would look for it.
    static let processName = "mlx_lm.server"

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
        await stop(because: loadInFlight ? .replaced : .unload)

        guard let installation = self.installation ?? Self.locate() else {
            throw record(RuntimeError.notInstalled(.mlx), reason: .notInstalled)
        }
        self.installation = installation

        guard request.configuration.expertStreaming == nil else {
            throw record(RuntimeError.expertStreamingUnsupported, reason: .launchFailed)
        }

        let port = request.port > 0 ? request.port : PortAllocator.free()
        transition(to: .starting(stage: "Starting MLX…"))

        let claim = await arbiter.begin(model: request.model.name, runtime: kind)
        loadInFlight = true
        defer { loadInFlight = false }

        let server = ServerProcess()
        self.server = server
        do {
            try await server.start(
                executable: installation.executable,
                arguments: MLXArguments(
                    model: request.model, configuration: request.configuration, port: port
                ).build()
            )
        } catch {
            self.release(server)
            throw record(error, reason: .launchFailed)
        }

        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let client = OpenAIChatClient(endpoint: endpoint)
        self.client = client

        let readiness = await client.waitUntilReady(
            timeout: readinessTimeout,
            isCancelled: { Task.isCancelled },
            hasEnded: { server.hasEnded }
        )
        guard readiness == .ready, await server.isRunning else {
            let log = await server.log
            let outcome = await LoadDiagnosis.ending(
                of: server, readiness: readiness, claim: claim,
                arbiter: arbiter, timeout: readinessTimeout
            )
            await server.terminate()
            self.release(server)

            let failure = LoadDiagnosis.failure(
                ending: outcome.ending,
                summary: Self.diagnose(
                    log: log, ending: outcome.ending, replacedBy: outcome.replacedBy
                ),
                log: log, runtime: kind
            )
            recorder.record(failure)
            lastFailure = failure
            if !failure.wasReplaced { transition(to: .failed(message: failure.summary)) }
            throw RuntimeError.didNotBecomeReady(failure)
        }

        lastFailure = nil
        recorder.clear()
        transition(to: .ready(endpoint: endpoint))
    }

    public func stop() async {
        await stop(because: .unload)
    }

    /// Lets go of a server, but only if it is still this load's.
    ///
    /// `start` allows a second load on a runtime that is already loading: it stops the first
    /// and takes the slot. The first then tidies up after itself — and clearing `server` and
    /// `client` unconditionally wiped the *winner's* handles. Its process stayed alive, a
    /// later `stop()` had nothing to stop, and the model it was holding was not released
    /// until the app quit.
    private func release(_ server: ServerProcess) {
        guard self.server === server else { return }
        self.server = nil
        self.client = nil
    }

    public func stop(because request: StopRequest) async {
        guard server != nil else { return }
        transition(to: .stopping)
        await server?.terminate(because: request)
        server = nil
        client = nil
        transition(to: .idle)
    }

    @discardableResult
    private func record(_ error: any Error, reason: LoadFailure.Reason) -> any Error {
        let failure = LoadFailure(
            reason: reason, summary: error.localizedDescription, runtime: kind
        )
        recorder.record(failure)
        lastFailure = failure
        return error
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

    /// As in `LlamaCppRuntime`: what MLX said about itself first, how the load ended
    /// second, and never a slab of log as the headline.
    static func diagnose(
        log: String, ending: LoadEnding? = nil, replacedBy: String? = nil
    ) -> String {
        // A load this app stopped is not diagnosable, and reading its log for advice puts
        // words in the runtime's mouth: a replaced load whose log happened to carry "failed
        // to allocate" was being reported as having run out of memory, which is a bug
        // report nobody can act on.
        if let ending, ending.wasAppCaused {
            return ending.sentence(process: processName, replacedBy: replacedBy)
        }
        if let advice = advice(for: log) { return advice }
        if let ending {
            return ending.sentence(process: processName, replacedBy: replacedBy)
        }
        return "\(processName) stopped without saying why."
    }

    private static func advice(for log: String) -> String? {
        let lowercased = log.lowercased()
        if lowercased.contains("modulenotfounderror") || lowercased.contains("no module named") {
            return "mlx-lm is not installed in the Python environment that was found. "
                + "Run `pip install mlx-lm`, or point at a different interpreter in Settings."
        }
        if lowercased.contains("metal") && lowercased.contains("out of memory") {
            return "MLX ran out of unified memory. Reduce the context length or use a smaller model."
        }
        return nil
    }
}
