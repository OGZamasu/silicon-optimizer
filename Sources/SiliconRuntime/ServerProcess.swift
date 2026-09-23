import Foundation
import SiliconCore

/// Supervises a child server process and captures its log output.
///
/// Runtime servers write everything to stderr, including the load progress the user wants to
/// see and the error messages that explain a failed load. Capturing it is what lets the app show
/// "loading 47%" instead of a spinner, and a real diagnosis instead of "something went wrong".
actor ServerProcess {

    private var process: Process?
    /// The app always supervises through the shared registry; tests inject their own so
    /// their assertions never see another suite's children.
    private let registry: ChildProcessRegistry
    /// What became of the child, written the moment it happens and readable without an
    /// `await`. See `Ending`.
    private let ending = Ending()
    /// Everything the child has written. See `Output`.
    private let output = Output()

    init(registry: ChildProcessRegistry = .shared) {
        self.registry = registry
    }

    /// The end of a child process, recorded where anyone can read it synchronously.
    ///
    /// `Process.terminationHandler` fires on an arbitrary queue, and a load that is waiting
    /// on `/health` has to be able to ask "is it still there?" between polls without hopping
    /// onto this actor — which it cannot do, because it is *inside* a call on this actor. So
    /// the fact is kept behind a lock, in the same spirit as `ChildProcessRegistry`: an
    /// actor cannot answer the one question that matters at the moment it matters.
    private final class Ending: @unchecked Sendable {
        private let lock = NSLock()
        private var termination: ProcessTermination?
        private var stopRequest: StopRequest?
        private var startedAt: Date?

        func began(at date: Date) {
            lock.lock()
            startedAt = date
            lock.unlock()
        }

        /// Recorded *before* the signal goes out, so a process that dies instantly still
        /// ends up attributed to the app rather than to a mystery.
        ///
        /// Deliberately does not touch a termination that has already been recorded. A
        /// failed load terminates a process that is often already gone — tidying up after
        /// itself — and back-filling the request there would turn "it exited with status 3"
        /// into "we stopped it", which is the exact confusion this type exists to end.
        func requested(_ request: StopRequest) {
            lock.lock()
            if termination == nil { stopRequest = request }
            lock.unlock()
        }

        func finished(exitStatus: Int32?, signal: Int32?, at date: Date) {
            lock.lock()
            defer { lock.unlock() }
            guard termination == nil else { return }
            termination = ProcessTermination(
                exitStatus: exitStatus, signal: signal, stopRequest: stopRequest,
                ranFor: startedAt.map { date.timeIntervalSince($0) } ?? 0
            )
        }

        var snapshot: ProcessTermination? {
            lock.lock()
            defer { lock.unlock() }
            return termination
        }

        var hasEnded: Bool { snapshot != nil }
    }

    /// The child's output, taken in on the pipe's own queue and kept behind a lock.
    ///
    /// Each read used to hop onto the actor in a `Task` of its own. Nothing ordered those
    /// tasks against the termination handler, so a load that saw the process end and asked
    /// for its log could be answered before the last read had landed — and the last thing a
    /// runtime writes before it exits is the line that says why. Taken in here, a read is
    /// in the log by the time the handler returns, in the order it arrived. The end of the
    /// pipe is recorded too, because the exit and the last bytes arrive as two separate
    /// events in either order: the log of a finished child waits for the second one.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private var onLine: (@Sendable (String) -> Void)?
        private var closed = false
        private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
        private var nextWaiter = 0

        func listen(_ handler: (@Sendable (String) -> Void)?) {
            lock.lock()
            onLine = handler
            lock.unlock()
        }

        func take(_ data: Data) {
            let arrived = String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.isEmpty }
            lock.lock()
            lines.append(contentsOf: arrived)
            if lines.count > ServerProcess.maximumLogLines {
                lines.removeFirst(lines.count - ServerProcess.maximumLogLines)
            }
            let handler = onLine
            lock.unlock()
            // Outside the lock: a handler is free to ask for the log.
            if let handler { arrived.forEach(handler) }
        }

        /// Nothing more is coming — the pipe reached its end, or the app stopped reading it —
        /// so anyone waiting for the rest of the output has all of it there will be.
        func close() {
            lock.lock()
            closed = true
            onLine = nil
            let pending = waiters.values
            waiters = [:]
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        /// Waits for `close()`, but not forever: a grandchild that inherited the pipe can
        /// hold it open long after the child is gone, and a failed load should not wait on
        /// that to say what it already knows. Not cancellable on purpose — a cancelled load
        /// still wants the last line its runtime wrote.
        func drain(within allowance: Duration) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                guard !closed else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                let id = nextWaiter
                nextWaiter += 1
                waiters[id] = continuation
                lock.unlock()
                Task {
                    try? await Task.sleep(for: allowance)
                    self.giveUp(on: id)
                }
            }
        }

        private func giveUp(on id: Int) {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            // Once is enough: a pipe that outlived the allowance will not be waited on again.
            if continuation != nil { closed = true }
            lock.unlock()
            continuation?.resume()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return lines.joined(separator: "\n")
        }
    }

    /// Keeps the tail of the log bounded; a long generation session would otherwise grow it
    /// without limit.
    private static let maximumLogLines = 500

    /// How long the log of a finished child waits for output still in the pipe. The last
    /// bytes normally follow the exit within a millisecond; this is the bound for a pipe
    /// something else is still holding.
    private static let drainAllowance: Duration = .seconds(2)

    var isRunning: Bool { process?.isRunning ?? false }

    /// What the child has written, most recent last.
    ///
    /// Once the child has ended this includes everything it wrote before it did — which is
    /// the part a failed load reads, and the part that used to go missing (#76).
    var log: String {
        get async {
            let childIsGone = ending.hasEnded || process.map { !$0.isRunning } ?? false
            if childIsGone { await output.drain(within: Self.drainAllowance) }
            return output.text
        }
    }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        inheritEnvironment: Bool = true,
        currentDirectory: URL? = nil,
        onLogLine: (@Sendable (String) -> Void)? = nil
    ) throws {
        precondition(process == nil, "ServerProcess is single-use per load")

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        var mergedEnvironment = inheritEnvironment ? ProcessInfo.processInfo.environment : [:]
        mergedEnvironment.merge(environment) { _, new in new }
        process.environment = mergedEnvironment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        // readabilityHandler fires on the handle's own queue; `Output` is safe to fill from
        // there directly, which is what keeps the last read ahead of anyone asking for it.
        let output = self.output
        output.listen(onLogLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // End of file: every byte the child wrote has been read. Left in place, the
                // handler would go on firing, empty, until somebody stopped the process.
                handle.readabilityHandler = nil
                output.close()
                return
            }
            output.take(data)
        }

        // Nothing on macOS makes a child die with its parent, so every spawn is recorded where
        // a synchronous `willTerminate` observer — and the next launch, after a crash — can
        // find it. A server that exits on its own takes itself back out here, so the registry
        // never accumulates pids the kernel is free to reissue.
        //
        // This is also the only moment the exit status and the signal exist, so they are
        // written down here rather than read back later: by the time a failed load asks,
        // `terminate` has already released the `Process` object.
        let registry = self.registry
        let ending = self.ending
        process.terminationHandler = { finished in
            registry.unregister(pid: finished.processIdentifier)
            let signalled = finished.terminationReason == .uncaughtSignal
            ending.finished(
                exitStatus: signalled ? nil : finished.terminationStatus,
                signal: signalled ? finished.terminationStatus : nil,
                at: Date()
            )
        }

        do {
            ending.began(at: Date())
            try process.run()
        } catch {
            throw RuntimeError.launchFailed(error.localizedDescription)
        }
        registry.register(pid: process.processIdentifier)
        self.process = process
    }

    /// Stops the child, and records that it was this app that asked.
    ///
    /// The reason is not bookkeeping: "we unloaded it" and "it died" are the two answers a
    /// failed load has to be able to tell apart, and only the caller knows which one this is.
    func terminate(because request: StopRequest = .unload) async {
        ending.requested(request)
        guard let process, process.isRunning else { return }

        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        // Nobody is reading any more, so the end of the pipe will never be seen; nothing
        // should wait for it.
        output.close()
        process.terminate()

        // Give the server a moment to release its Metal allocations cleanly. A SIGKILL leaves
        // multi-gigabyte buffers to be reclaimed by the kernel, which stalls the whole system.
        for _ in 0..<50 {
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        registry.unregister(pid: process.processIdentifier)
        self.process = nil
    }

    /// Process identifier, or nil when nothing is running.
    var pid: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    /// Exit status, or nil while still running.
    var terminationStatus: Int32? {
        guard let process, !process.isRunning else { return nil }
        return process.terminationStatus
    }

    /// What became of the child — exit status or signal, whether this app asked for it, and
    /// how long it ran. Nil while it is still running.
    ///
    /// Survives `terminate()`, which is the whole point: the failed load that needs this is
    /// the one whose server is already gone.
    var termination: ProcessTermination? { ending.snapshot }

    /// Whether the child is over, answerable without an `await`.
    ///
    /// A load waiting on `/health` runs this between polls. Before it existed, a server that
    /// died two seconds in left the load waiting out its full ten-minute timeout for an
    /// answer that was never coming — which is how an eight-second failure took ten minutes
    /// to be reported.
    nonisolated var hasEnded: Bool { ending.hasEnded }
}

/// Finds a free localhost port for the server to bind.
enum PortAllocator {
    /// Asks the kernel for an ephemeral port, then releases it. There is an inherent race
    /// between releasing and the child binding, but the window is small and the alternative —
    /// scanning a fixed range — collides far more often in practice.
    static func free() -> Int {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return 8080 }
        defer { close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                                   // let the kernel choose
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return 8080 }

        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &length)
            }
        }
        guard named == 0 else { return 8080 }
        return Int(UInt16(bigEndian: resolved.sin_port))
    }
}
