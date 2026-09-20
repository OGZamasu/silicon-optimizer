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
    /// Set while `start` is between "the process is up" and "the model answered", which is
    /// the only window in which being stopped means being interrupted rather than unloaded.
    private var loadInFlight = false

    /// Who owns the machine, so a load that is displaced by another one is told so.
    private let arbiter: LoadArbiter
    /// Where a failed load leaves its account of itself, for `/status` to answer with after
    /// the app has dropped this object.
    private let recorder: LoadFailureRecorder
    /// How long a load may take before the app gives up on it.
    ///
    /// Large models legitimately take minutes to load from disk on first run, before the
    /// file cache is warm. Ten minutes is generous rather than optimistic — and since a
    /// server that dies now ends the wait immediately, this is only ever spent on a server
    /// that is genuinely still working.
    private let readinessTimeout: TimeInterval

    /// What went wrong with the last load, if the last load went wrong.
    public private(set) var lastFailure: LoadFailure?
    /// The log of the server that is no longer here.
    ///
    /// A failed load drops its `ServerProcess`, and the app's own log pane — the one a
    /// person opens *because* a load failed — was reading the log off that object, so it
    /// showed nothing at exactly the moment it had something to show.
    private var lastServerLog = ""

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

    /// The name of the binary, which is what a person sees in Activity Monitor and what
    /// every sentence about a failed load names.
    static let processName = "llama-server"

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
        // A second load on a runtime that is already loading replaces the first, and the
        // first is told which of those two things happened to it.
        await stop(because: loadInFlight ? .replaced : .unload)

        let installation = self.installation ?? Self.locate()
        guard let installation else {
            throw record(RuntimeError.notInstalled(.llamaCpp), reason: .notInstalled)
        }
        self.installation = installation

        let port = request.port > 0 ? request.port : PortAllocator.free()
        let arguments = LlamaArguments(
            model: request.model, configuration: request.configuration,
            port: port, installation: installation,
            extraArguments: request.extraArguments,
            chatTemplateFile: request.chatTemplateFile
        )

        let problems = arguments.validate()
        if let blocking = problems.first, request.configuration.expertStreaming != nil,
           installation.hasExpertStreaming == false {
            throw record(RuntimeError.launchFailed(blocking), reason: .launchFailed)
        }

        transition(to: .starting(stage: "Starting llama.cpp…"))
        loadProgress = 0

        let claim = await arbiter.begin(model: request.model.name, runtime: kind)
        loadInFlight = true
        defer { loadInFlight = false }

        let server = ServerProcess()
        self.server = server

        do {
            try await server.start(
                executable: installation.executable,
                arguments: arguments.build(),
                environment: [:],
                onLogLine: { [weak self] line in
                    Task { await self?.consume(logLine: line) }
                }
            )
        } catch {
            await arbiter.finish(claim)
            self.server = nil
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
            await arbiter.finish(claim)
            self.server = nil
            self.client = nil

            lastServerLog = log
            let failure = LoadDiagnosis.failure(
                ending: outcome.ending,
                summary: Self.diagnose(
                    log: log, ending: outcome.ending, replacedBy: outcome.replacedBy
                ),
                log: log, runtime: kind
            )
            recorder.record(failure)
            lastFailure = failure
            // A load that was replaced is no longer the state anyone is looking at: the load
            // that displaced it is, and stamping `.failed` over its progress would replace a
            // true line with a stale one. The error still carries the sentence, so the
            // caller — and the alert the app raises from it — still says what happened.
            if !failure.wasReplaced { transition(to: .failed(message: failure.summary)) }
            throw RuntimeError.didNotBecomeReady(failure)
        }

        loadProgress = 1
        lastFailure = nil
        recorder.clear()
        await arbiter.finish(claim)
        transition(to: .ready(endpoint: endpoint))
    }

    public func stop() async {
        await stop(because: .unload)
    }

    /// Stops the server, saying why — which is what lets a load that was interrupted report
    /// an unload as an unload and a replacement as a replacement.
    public func stop(because request: StopRequest) async {
        guard server != nil else {
            if case .idle = state {} else { transition(to: .idle) }
            return
        }
        transition(to: .stopping)
        lastServerLog = await server?.log ?? lastServerLog
        await server?.terminate(because: request)
        server = nil
        client = nil
        loadProgress = 0
        transition(to: .idle)
    }

    // MARK: - Why a load ended

    /// Records a failure that happened before there was ever a process, and hands the error
    /// back so a call site can `throw record(…)`.
    @discardableResult
    private func record(_ error: any Error, reason: LoadFailure.Reason) -> any Error {
        let failure = LoadFailure(
            reason: reason, summary: error.localizedDescription, runtime: kind
        )
        recorder.record(failure)
        lastFailure = failure
        return error
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

    /// Whether the server process is up. Internal rather than public: the tests that stop a
    /// load in flight have to know the thing they are stopping is really there.
    var serverIsRunning: Bool {
        get async { await server?.isRunning ?? false }
    }

    public func serverLog() async -> String {
        await server?.log ?? lastServerLog
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

    /// Turns a failed load into one sentence a user can act on.
    ///
    /// The log is read first, because a runtime that said why it failed has said something
    /// better than anything this code could infer: "reduce the context length" beats "exit
    /// 1" every time. Only when the log says nothing recognisable does the sentence fall
    /// back to *how the load ended* — which is the fix for the bug this method used to
    /// have, where the fallback printed the last eight lines of a log and left the reader
    /// to work out that the process had died at all.
    static func diagnose(
        log: String, ending: LoadEnding? = nil, replacedBy: String? = nil
    ) -> String {
        if let advice = advice(for: log) { return advice }
        if let ending {
            return ending.sentence(process: processName, replacedBy: replacedBy)
        }
        return "\(processName) stopped without saying why."
    }

    /// The failures llama.cpp announces in words, and what to do about each.
    private static func advice(for log: String) -> String? {
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
        return nil
    }
}
