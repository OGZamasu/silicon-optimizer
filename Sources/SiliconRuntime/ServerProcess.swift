import Foundation
import SiliconCore

/// Supervises a child server process and captures its log output.
///
/// Runtime servers write everything to stderr, including the load progress the user wants to
/// see and the error messages that explain a failed load. Capturing it is what lets the app show
/// "loading 47%" instead of a spinner, and a real diagnosis instead of "something went wrong".
actor ServerProcess {

    private var process: Process?
    private var logBuffer: [String] = []
    private var logHandler: (@Sendable (String) -> Void)?
    /// The app always supervises through the shared registry; tests inject their own so
    /// their assertions never see another suite's children.
    private let registry: ChildProcessRegistry
    /// What became of the child, written the moment it happens and readable without an
    /// `await`. See `Ending`.
    private let ending = Ending()

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

    /// Keeps the tail of the log bounded; a long generation session would otherwise grow it
    /// without limit.
    private static let maximumLogLines = 500

    var isRunning: Bool { process?.isRunning ?? false }

    var log: String { logBuffer.joined(separator: "\n") }

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

        self.logHandler = onLogLine

        // readabilityHandler fires on an arbitrary queue, so hop back onto the actor to touch
        // any state.
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            Task { await self?.append(text) }
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

    private func append(_ text: String) {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
        for line in lines {
            logBuffer.append(line)
            logHandler?(line)
        }
        if logBuffer.count > Self.maximumLogLines {
            logBuffer.removeFirst(logBuffer.count - Self.maximumLogLines)
        }
    }

    /// Stops the child, and records that it was this app that asked.
    ///
    /// The reason is not bookkeeping: "we unloaded it" and "it died" are the two answers a
    /// failed load has to be able to tell apart, and only the caller knows which one this is.
    func terminate(because request: StopRequest = .unload) async {
        ending.requested(request)
        guard let process, process.isRunning else { return }

        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
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
        self.logHandler = nil
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
