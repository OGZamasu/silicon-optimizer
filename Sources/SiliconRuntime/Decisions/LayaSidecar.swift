import Foundation

// MARK: - What comes back

/// What the sidecar answered, before it is turned into control-API answers.
///
/// Decoded loosely on purpose. laya-mlx returns a plain dict rather than a typed object, so
/// a key that moves in a later release should cost one field rather than the whole response
/// — and the fields that matter are checked when they are read, by name, with the
/// question's id in the error.
public struct LayaSidecarResponse: Decodable, Sendable, Equatable {
    public var model: String?
    public var answers: [String: LayaSidecarAnswer]
    public var usage: Usage?
    /// Measured inside the sidecar, around `system_one` alone: laya-mlx reports no timing
    /// of its own, so this is the only figure that is the model's rather than the pipe's.
    public var latencyMS: Double?
    public var perQuestionMS: Double?
    public var peakMemoryBytes: Int64?

    public struct Usage: Decodable, Sendable, Equatable {
        public var inputTokens: Int?
        public var outputTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case model, answers, usage
        case latencyMS = "latency_ms"
        case perQuestionMS = "per_question_ms"
        case peakMemoryBytes = "peak_memory_bytes"
    }
}

/// One answer as laya-mlx spells it.
///
/// The spellings are the library's: the expected score is `score` rather than
/// `expected_score`, P(true) is `noul` rather than `p_true`, and the distribution is
/// `probabilities` rather than `probs`. Every answer also carries
/// `action.act_probability`, which this app deliberately ignores — it has its own bands,
/// tuned per feature, and a second act/do-not-act opinion from the model would be a policy
/// arriving through the back door.
public struct LayaSidecarAnswer: Decodable, Sendable, Equatable {
    public var type: String
    public var confidence: Double?
    public var choice: String?
    public var score: Double?
    public var noul: Double?
    public var probabilities: [String: Double]?
    public var legend: [String: String]?
}

// MARK: - What can go wrong

public enum LayaSidecarError: Error, LocalizedError, Equatable {
    /// The interpreter is not where it was expected — the environment was moved or deleted,
    /// which on this Mac usually means the drive holding it is not mounted.
    case pythonMissing(String)
    case scriptMissing(String)
    /// `laya_mlx` is not importable in that environment.
    case notInstalled(String)
    case loadFailed(String)
    /// It started, then went away. Carries the exit status when there was one.
    case died(status: Int32?, detail: String)
    case failed(String)
    case protocolBroken(String)
    case timedOut(seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .pythonMissing(let path):
            "The Laya environment's Python is missing (\(path)). If it is on an external "
            + "drive, mount it; otherwise install Laya again from Settings → Decisions."
        case .scriptMissing(let path):
            "The Laya driver script is missing (\(path)). Reinstalling the app restores it."
        case .notInstalled(let detail):
            "laya-mlx is not installed in the Laya environment (\(detail)). Install it from "
            + "Settings → Decisions."
        case .loadFailed(let detail):
            "The Laya checkpoint would not load: \(detail)"
        case .died(let status, let detail):
            "The Laya process stopped"
            + (status.map { " (exit \($0))" } ?? "")
            + (detail.isEmpty ? "." : ": \(detail)")
        case .failed(let detail):
            "Laya could not answer: \(detail)"
        case .protocolBroken(let detail):
            "The Laya process said something unexpected: \(detail)"
        case .timedOut(let seconds):
            String(format: "Laya did not answer within %.0fs.", seconds)
        }
    }

    /// Whether restarting the process is a sensible response.
    ///
    /// A death is: the next one may well load fine. A missing interpreter, a missing
    /// package and a checkpoint that will not load are not — they would fail identically,
    /// slowly, and the second failure tells the owner nothing the first did not.
    public var deservesRestart: Bool {
        switch self {
        case .died, .protocolBroken: true
        case .pythonMissing, .scriptMissing, .notInstalled, .loadFailed, .failed, .timedOut:
            false
        }
    }
}

// MARK: - Reading lines off a pipe

/// Lines from a file handle, buffered so none is lost between requests.
///
/// Its own class rather than an `AsyncStream` because of what has to happen on a timeout:
/// the stream's iterator cannot be abandoned and picked up again, and a request that gave
/// up would desynchronise every answer after it. This hands out one line at a time and
/// keeps the rest, and the sidecar checks the id on every answer besides.
final class LayaLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var closed = false
    private let handle: FileHandle

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                self?.finish()
                return
            }
            self?.take(data)
        }
    }

    private func take(_ data: Data) {
        var delivered: [String] = []
        lock.lock()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            let text = String(decoding: line, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { delivered.append(text) }
        }
        lines.append(contentsOf: delivered)
        let continuation = pullWaiterLocked()
        lock.unlock()
        continuation?()
    }

    private func finish() {
        lock.lock()
        closed = true
        let continuation = pullWaiterLocked()
        lock.unlock()
        continuation?()
        handle.readabilityHandler = nil
    }

    /// Hands the pending waiter its line, if there is one to hand it. Called with the lock
    /// held; returns the resume to run *after* it is dropped, because resuming a
    /// continuation inside a lock invites the resumed task straight back into it.
    private func pullWaiterLocked() -> (() -> Void)? {
        guard let waiter else { return nil }
        if !lines.isEmpty {
            let line = lines.removeFirst()
            self.waiter = nil
            return { waiter.resume(returning: line) }
        }
        if closed {
            self.waiter = nil
            return { waiter.resume(returning: nil) }
        }
        return nil
    }

    /// What `next()` can answer without waiting: a buffered line, or nil-because-closed.
    /// `.none` means neither — somebody has to wait.
    ///
    /// Split out because taking a lock is unavailable from an async context, and because
    /// the two callers below want exactly this answer.
    private func takeReady() -> String?? {
        lock.lock()
        defer { lock.unlock() }
        if !lines.isEmpty { return .some(lines.removeFirst()) }
        if closed { return .some(nil) }
        return .none
    }

    /// Parks the caller until a line arrives or the pipe closes. Re-checks under the lock
    /// first: a line can land between `takeReady` returning nothing and this running.
    private func park(_ continuation: CheckedContinuation<String?, Never>) {
        lock.lock()
        if !lines.isEmpty {
            let line = lines.removeFirst()
            lock.unlock()
            continuation.resume(returning: line)
            return
        }
        if closed {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        waiter = continuation
        lock.unlock()
    }

    /// The next line, or nil once the pipe is closed and the buffer is empty.
    ///
    /// Not cancellable, and that is deliberate: a cancelled read that left a continuation
    /// pending would be a deadlock the next time anybody asked. Callers that need to give
    /// up race this against a timer and then throw the whole process away.
    func next() async -> String? {
        if let ready = takeReady() { return ready }
        return await withCheckedContinuation { park($0) }
    }

    func stop() {
        handle.readabilityHandler = nil
        finish()
    }
}

/// Whatever the sidecar wrote to stderr, kept so a death can be explained.
///
/// Bounded: a process wedged in a loop printing warnings must not grow this without limit,
/// and the last two kilobytes are where the reason is anyway.
final class LayaDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    static let limit = 2_048

    init(handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.append(String(decoding: data, as: UTF8.self))
        }
    }

    private func append(_ more: String) {
        lock.lock()
        defer { lock.unlock() }
        text += more
        if text.count > Self.limit { text = String(text.suffix(Self.limit)) }
    }

    /// The last line worth showing, trimmed. Python puts the exception on the final line of
    /// a traceback, which is the one a person wants.
    func summary() -> String {
        lock.lock()
        let copy = text
        lock.unlock()
        let lines = copy.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return lines.last.map { String($0.prefix(200)) } ?? ""
    }
}

// MARK: - The process

/// One long-lived `laya_sidecar.py`, talked to over its own stdin and stdout.
///
/// A pipe rather than a socket, and that is a security decision rather than a convenience
/// one: there is no port, no bind and no listener, so there is nothing on this machine for
/// anything else to connect to. A loopback server would have needed a token, an origin
/// check and a rule about a port already in use; a pipe has none of those problems because
/// it has no second end.
///
/// Requests are serialised — one in flight, answered in order, ids checked. The sidecar's
/// own loop is a single thread reading lines, so pipelining would buy nothing, and
/// laya-mlx already batches the questions *within* a request, which is where the
/// throughput actually is.
public actor LayaSidecar {

    public struct Configuration: Sendable, Equatable {
        public var python: URL
        public var script: URL
        public var checkpoint: LayaCheckpoint
        /// `HF_HOME` and friends — where the weights are read from, which on this Mac is
        /// the model library rather than the startup disk.
        public var environment: [String: String]
        public var batchSize: Int
        /// laya-mlx defaults this to false. Turned on here: the state leads every prompt and
        /// a feature asks about the same state repeatedly, which is the case it helps.
        public var cachePrompts: Bool
        /// How long one request may take before the caller gives up. Generous next to the
        /// published 13 ms, because that figure is for one short question: ten
        /// full-context ones are about a second, and the first request after a load pays
        /// for lazy imports on top.
        public var requestTimeout: TimeInterval
        /// How long the load itself may take with the weights already on disk.
        public var startTimeout: TimeInterval

        public init(
            python: URL, script: URL, checkpoint: LayaCheckpoint = .default,
            environment: [String: String] = [:],
            batchSize: Int = LayaPackage.batchSize,
            cachePrompts: Bool = true,
            requestTimeout: TimeInterval = 30,
            startTimeout: TimeInterval = 180
        ) {
            self.python = python
            self.script = script
            self.checkpoint = checkpoint
            self.environment = environment
            self.batchSize = batchSize
            self.cachePrompts = cachePrompts
            self.requestTimeout = requestTimeout
            self.startTimeout = startTimeout
        }
    }

    /// What the sidecar said when it finished loading.
    public struct Ready: Sendable, Equatable {
        public var model: String
        public var revision: String?
        public var version: String?
        public var loadMS: Double?
        public var peakMemoryBytes: Int64?
    }

    private let configuration: Configuration
    private let registry: ChildProcessRegistry
    private var process: Process?
    private var input: FileHandle?
    private var reader: LayaLineReader?
    private var diagnostics: LayaDiagnostics?
    private var loaded: Ready?
    private var nextID = 0
    /// Set while a stop is deliberate, so a clean exit on the way out is not reported as a
    /// death to whoever is still waiting.
    private var stopping = false

    /// Whether a write-then-read round trip is in flight, and who is queued for the next
    /// one.
    ///
    /// `decide()` is `async`, so between its `write` and its matching `answer` there is a
    /// suspension point — and this actor is otherwise reentrant across one, which is exactly
    /// how two callers used to interleave: caller A's request went out, then caller B's did
    /// too, before A had read anything back. Both were then racing `LayaLineReader.next()`
    /// for lines that answer only one of them, and whichever line arrived first went to
    /// whichever caller happened to be parked, not to the one whose id it carried.
    ///
    /// Every `decide()` call now takes a numbered turn before it writes anything, and the
    /// next one in line only starts once the previous caller's answer (or failure) has
    /// been read. The pipe was already answering one request at a time — this just stops
    /// two Swift-side callers from racing to be the one reading it.
    private var turnHolder = false
    private var turnQueue: [CheckedContinuation<Void, Never>] = []

    /// Waits for exclusive use of the pipe, in arrival order.
    private func acquireTurn() async {
        if !turnHolder {
            turnHolder = true
            return
        }
        await withCheckedContinuation { turnQueue.append($0) }
    }

    /// Hands the turn to whoever has been waiting longest, or frees it if nobody has.
    private func releaseTurn() {
        guard !turnQueue.isEmpty else {
            turnHolder = false
            return
        }
        turnQueue.removeFirst().resume()
    }

    public init(configuration: Configuration, registry: ChildProcessRegistry = .shared) {
        self.configuration = configuration
        self.registry = registry
    }

    public var isRunning: Bool { process?.isRunning ?? false }
    public var ready: Ready? { loaded }

    // MARK: Lifecycle

    /// Starts the process and waits for its `ready` line — which is the model load, so this
    /// is the slow call and everything after it is milliseconds.
    @discardableResult
    public func start() async throws -> Ready {
        if let loaded, isRunning { return loaded }
        await stop()

        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: configuration.python.path) else {
            throw LayaSidecarError.pythonMissing(configuration.python.path)
        }
        guard manager.fileExists(atPath: configuration.script.path) else {
            throw LayaSidecarError.scriptMissing(configuration.script.path)
        }

        let process = Process()
        process.executableURL = configuration.python
        process.arguments = [configuration.script.path]
        var environment = configuration.environment
        // Line-buffered, or the ready line sits in a pipe buffer until the process exits
        // and the wait below times out on a sidecar that is working perfectly.
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let reader = LayaLineReader(handle: stdout.fileHandleForReading)
        let diagnostics = LayaDiagnostics(handle: stderr.fileHandleForReading)

        do {
            try process.run()
        } catch {
            reader.stop()
            throw LayaSidecarError.died(status: nil, detail: error.localizedDescription)
        }
        registry.register(pid: process.processIdentifier)

        self.process = process
        self.input = stdin.fileHandleForWriting
        self.reader = reader
        self.diagnostics = diagnostics
        self.stopping = false
        self.nextID = 0

        do {
            try write([
                "id": "hello",
                "model": configuration.checkpoint.repository,
                "revision": configuration.checkpoint.revision,
                "batch_size": configuration.batchSize,
                "cache_prompts": configuration.cachePrompts,
                "dtype": "float16",
            ])
            let object = try await answer(to: "hello", timeout: configuration.startTimeout)
            let ready = Ready(
                model: object["model"] as? String ?? configuration.checkpoint.repository,
                revision: object["revision"] as? String,
                version: object["version"] as? String,
                loadMS: (object["load_ms"] as? NSNumber)?.doubleValue,
                peakMemoryBytes: (object["peak_memory_bytes"] as? NSNumber)?.int64Value
            )
            loaded = ready
            return ready
        } catch {
            // A half-started process is worse than none: it holds a pid, maybe a partial
            // model, and the next call would find `isRunning` true and no `ready`.
            await stop()
            throw error
        }
    }

    /// Asks it to exit, waits briefly, then insists.
    public func stop() async {
        stopping = true
        if let process, process.isRunning {
            // Asked politely first: a shutdown line lets it release the weights and exit 0,
            // where a signal leaves MLX's allocations for the kernel to clean up.
            try? write(["id": "bye", "op": "shutdown"])
            try? input?.close()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            if process.isRunning { process.terminate() }
        }
        if let process { registry.unregister(pid: process.processIdentifier) }
        reader?.stop()
        try? input?.close()
        process = nil
        input = nil
        reader = nil
        diagnostics = nil
        loaded = nil
        stopping = false
    }

    // MARK: Asking

    /// One request, however many questions.
    ///
    /// Starts the process if it is not up. Does **not** restart it on failure — that is the
    /// lane's decision, one level up, because only the lane knows whether it has already
    /// used its one retry.
    public func decide(
        state: Any, questions: [String: Any]
    ) async throws -> LayaSidecarResponse {
        // One caller writes and reads at a time. See `turnHolder` above for why: without
        // this, two calls arriving close together can both write before either reads, and
        // the second caller's line steals the first caller's continuation.
        await acquireTurn()
        defer { releaseTurn() }
        if loaded == nil || !isRunning { try await start() }
        nextID += 1
        let id = "q\(nextID)"
        try write(["id": id, "op": "decide", "state": state, "questions": questions])
        let object = try await answer(to: id, timeout: configuration.requestTimeout)
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            throw LayaSidecarError.protocolBroken("the answer would not re-encode")
        }
        do {
            return try JSONDecoder().decode(LayaSidecarResponse.self, from: data)
        } catch {
            throw LayaSidecarError.protocolBroken("\(error)")
        }
    }

    // MARK: Plumbing

    private func write(_ object: [String: Any]) throws {
        guard let input else {
            throw LayaSidecarError.died(status: nil, detail: "its input is closed")
        }
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object)
        else {
            throw LayaSidecarError.protocolBroken("the request would not encode as JSON")
        }
        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
        } catch {
            // Almost always EPIPE: it died between the check above and this write.
            throw LayaSidecarError.died(
                status: process.flatMap { $0.isRunning ? nil : $0.terminationStatus },
                detail: "it closed its input"
            )
        }
    }

    /// The answer to one request id, or an error saying which of the three bad things
    /// happened: it died, it did not answer in time, or it answered something else.
    ///
    /// The distinction matters upstream. A death is worth one restart; a timeout is not,
    /// because a restart pays the model load again for a process that might still be
    /// working — and a timeout tears the process down here anyway, since a request whose
    /// answer may still arrive would desynchronise every request after it.
    private func answer(to id: String, timeout: TimeInterval) async throws -> [String: Any] {
        guard let reader else {
            throw LayaSidecarError.died(status: nil, detail: "it is not running")
        }
        let line = await race(reader: reader, timeout: timeout)
        guard let line else {
            let dead = process.map { !$0.isRunning } ?? true
            guard dead else {
                await stop()
                throw LayaSidecarError.timedOut(seconds: timeout)
            }
            let status = process?.terminationStatus
            let detail = stopping ? "it was stopped" : (diagnostics?.summary() ?? "")
            await stop()
            throw LayaSidecarError.died(status: status, detail: detail)
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                as? [String: Any]
        else { throw LayaSidecarError.protocolBroken(String(line.prefix(200))) }

        if let answered = object["id"] as? String, answered != id {
            // Cannot happen with one request in flight, so if it does the process is not
            // the one we think it is. Torn down rather than guessed at.
            await stop()
            throw LayaSidecarError.protocolBroken("it answered \(answered), not \(id)")
        }
        guard (object["ok"] as? Bool) == true else {
            let detail = (object["error"] as? String) ?? "no reason given"
            switch object["kind"] as? String {
            case "not_installed": throw LayaSidecarError.notInstalled(detail)
            case "load_failed": throw LayaSidecarError.loadFailed(detail)
            default: throw LayaSidecarError.failed(detail)
            }
        }
        return object
    }

    /// A line, or nil when the pipe closed or the clock ran out.
    ///
    /// First writer wins, exactly as `JevService.settles` does it and for the same reason:
    /// awaiting a task's value does not return early when the waiter is cancelled, so a
    /// deadline has to be a second task posting to a shared slot rather than a cancellation.
    private func race(reader: LayaLineReader, timeout: TimeInterval) async -> String? {
        let slot = Slot()
        let read = Task { await slot.post(await reader.next()) }
        let timer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            await slot.post(nil)
        }
        defer { read.cancel(); timer.cancel() }
        return await slot.take()
    }

    /// First post wins; a line that arrives before anybody is listening is kept.
    private actor Slot {
        private var value: String??
        private var waiting: CheckedContinuation<String?, Never>?

        func post(_ line: String?) {
            guard value == nil else { return }
            value = .some(line)
            waiting?.resume(returning: line)
            waiting = nil
        }

        func take() async -> String? {
            if let value { return value }
            return await withCheckedContinuation { waiting = $0 }
        }
    }
}
