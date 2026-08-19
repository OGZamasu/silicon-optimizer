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

    /// Keeps the tail of the log bounded; a long generation session would otherwise grow it
    /// without limit.
    private static let maximumLogLines = 500

    var isRunning: Bool { process?.isRunning ?? false }

    var log: String { logBuffer.joined(separator: "\n") }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
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

        var mergedEnvironment = ProcessInfo.processInfo.environment
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
        process.terminationHandler = { finished in
            ChildProcessRegistry.unregister(pid: finished.processIdentifier)
        }

        do {
            try process.run()
        } catch {
            throw RuntimeError.launchFailed(error.localizedDescription)
        }
        ChildProcessRegistry.register(pid: process.processIdentifier)
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

    func terminate() async {
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
        ChildProcessRegistry.unregister(pid: process.processIdentifier)
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
