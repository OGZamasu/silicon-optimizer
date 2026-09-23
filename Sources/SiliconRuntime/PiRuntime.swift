import Foundation

/// Runs Pi (earendil-works' coding agent) as the app's fourth chat engine, headless
/// over its RPC mode — JSONL on stdio, the same native-embedding pattern as Codex.
///
/// Isolation model: Pi runs in an app-private workspace whose project-local `.pi/`
/// carries our settings and the silicon extension (gateway provider + MCP tool
/// bridge). The `-a` flag trusts that workspace for the run without touching the
/// user's own `~/.pi` trust store; their global Pi customizations still apply,
/// which is a feature.
public actor PiRuntime {

    /// Pinned like every other sidecar: a version we've actually driven. `pi update`
    /// inside someone's terminal must not change what the app embeds.
    public static let packageSpec = AgentPackage.pi.spec
    public static let minimumNodeVersion = (major: 22, minor: 19, patch: 0)

    public static var workspaceDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconOptimizer/pi/workspace", isDirectory: true)
    }

    /// Where Pi reads its settings and extensions for this workspace — including the
    /// guardrail's own. A tool call aimed in here is one the guardrail never waves through.
    public static var configurationDirectory: URL {
        workspaceDirectory.appendingPathComponent(".pi", isDirectory: true)
    }

    public enum State: Sendable, Equatable {
        case idle
        case starting(stage: String)
        case ready
        case stopping
        case failed(message: String)
    }

    private var process: Process?
    private var installedPackage: InstalledAgentPackage?
    private var installationTask: Task<InstalledAgentPackage, any Error>?
    private var startupGeneration = 0
    private var stdinHandle: FileHandle?
    private var eventContinuation: AsyncStream<String>.Continuation?

    public init() {}

    // MARK: - Configuration

    /// Writes the workspace: project settings that pick the silicon provider, and the
    /// extension that registers it. Idempotent; called before every start so a changed
    /// gateway port or model list lands on the next launch.
    public static func ensureConfigured(
        workspace: URL, defaultModel: String?, extensionSource: URL?
    ) throws {
        let piDirectory = workspace.appendingPathComponent(".pi", isDirectory: true)
        let extensions = piDirectory.appendingPathComponent("extensions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: extensions, withIntermediateDirectories: true
        )

        var settings: [String: Any] = [
            "defaultProvider": "silicon",
            // Local models think through the gateway's own controls; Pi's thinking
            // budgets are meaningless against them and just eat context.
            "defaultThinkingLevel": "off",
            "quietStartup": true,
        ]
        if let defaultModel { settings["defaultModel"] = defaultModel }
        let encoded = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]
        )
        try encoded.write(
            to: piDirectory.appendingPathComponent("settings.json"), options: .atomic
        )

        if let extensionSource {
            let destination = extensions.appendingPathComponent(managedExtension)
            let fresh = try Data(contentsOf: extensionSource)
            if (try? Data(contentsOf: destination)) != fresh {
                try fresh.write(to: destination, options: .atomic)
            }
        }

        removeUnmanagedExtensions(in: extensions)
    }

    /// The one extension this app owns in the managed workspace.
    public static let managedExtension = "silicon.ts"

    /// Deletes anything in the managed `.pi/extensions` directory that this app did not put
    /// there, on every start.
    ///
    /// Pi loads *every* module in that directory, and an extension can register its own
    /// `tool_call` handler — which is exactly how the guardrail is installed. A file written
    /// there by the agent could therefore approve its own calls, or rewrite the arguments
    /// after ours has approved them, and nothing later in the session would notice. The
    /// workspace is this app's, not the user's: `~/.pi` is untouched, their own global
    /// extensions still load, and the only thing swept is the directory we manage.
    ///
    /// Best-effort by design. A file that cannot be removed is a reason to keep going — the
    /// screening still runs — not a reason to refuse to start Pi at all.
    static func removeUnmanagedExtensions(in directory: URL) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries where entry.lastPathComponent != managedExtension {
            try? manager.removeItem(at: entry)
        }
    }

    /// The bundled extension, when the app carries one.
    public static func locateExtension() -> URL? {
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("pi-silicon/silicon.ts"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Starts Pi in RPC mode and returns its event stream: one raw JSON line per
    /// event, parsed by the consumer (dictionaries are not Sendable; lines are).
    public func start(
        gatewayPort: Int, gatewayToken: String, mcpServerPath: String?, nodePath: String,
        onState: @escaping @Sendable (State) -> Void
    ) async -> AsyncStream<String>? {
        let generation = await stopAndGetGeneration()
        guard generation == startupGeneration else { return nil }

        let discovery = HarnessRuntime.locateNode(
            customPath: nodePath, minimumVersion: Self.minimumNodeVersion,
            requiresNpm11: true
        )
        guard let node = discovery.node else {
            let floor = Self.minimumNodeVersion
            onState(.failed(message:
                "Pi needs Node.js \(floor.major).\(floor.minor) or newer with npm 11.19 "
                + "or newer; no compatible Node/npm pair was found. Install one with "
                + "`brew install node`, or switch engines in Settings."))
            return nil
        }

        let workspace = Self.workspaceDirectory
        onState(.starting(stage:
            "Verifying Pi… the first run downloads it and can take a few minutes."))

        let installed: InstalledAgentPackage
        do {
            let task = Task { try await AgentPackageInstaller.install(.pi, node: node) }
            installationTask = task
            installed = try await task.value
        } catch {
            if generation == startupGeneration { installationTask = nil }
            guard generation == startupGeneration else { return nil }
            onState(.failed(message: error.localizedDescription))
            return nil
        }
        if generation == startupGeneration { installationTask = nil }
        guard generation == startupGeneration else {
            try? FileManager.default.removeItem(at: installed.directory)
            return nil
        }
        installedPackage = installed

        let process = Process()
        process.executableURL = node
        process.arguments = [
            installed.bin.path,
            "--mode", "rpc",
            // Trust our own workspace for this run without writing the user's
            // trust store.
            "-a",
            "--session-dir", workspace.appendingPathComponent("sessions").path,
        ]
        process.currentDirectoryURL = workspace

        // Pi is installed from a package registry at first use. Give it only the ambient
        // process state it needs, rather than forwarding every credential that happened to
        // be present in the app's launch environment.
        var environment = [
            "HOME": workspace.path,
            "PATH": "\(node.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin",
            "SILICON_GATEWAY_PORT": String(gatewayPort),
        ]
        for harmless in ["LANG", "LC_ALL", "TMPDIR"] {
            if let value = ProcessInfo.processInfo.environment[harmless] {
                environment[harmless] = value
            }
        }
        // The provider config references this variable, keeping the per-launch bearer
        // out of generated files while still letting Pi authenticate every request.
        environment["SILICON_GATEWAY_KEY"] = gatewayToken
        if let mcpServerPath {
            environment["SILICON_MCP_PATH"] = mcpServerPath
        }
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            await stop()
            if startupGeneration == generation + 1 {
                onState(.failed(message: "Could not launch Pi: \(error.localizedDescription)"))
            }
            return nil
        }
        ChildProcessRegistry.register(pid: process.processIdentifier)
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting

        // Stderr is noise unless startup fails; keep a short tail for diagnosis.
        let stderrLines = CodexRuntime.lines(from: stderr.fileHandleForReading)
        let stderrTask = Task {
            var tail: [String] = []
            for await line in stderrLines {
                tail.append(line)
                if tail.count > 20 { tail.removeFirst(tail.count - 20) }
            }
            return tail
        }

        let stdoutLines = CodexRuntime.lines(from: stdout.fileHandleForReading)
        let stream = AsyncStream<String> { continuation in
            self.eventContinuation = continuation
            let monitored = process
            Task {
                for await line in stdoutLines {
                    // Strict JSONL: LF-delimited, tolerate a trailing CR, skip noise.
                    let clean = line.hasSuffix("\r") ? String(line.dropLast()) : line
                    guard !clean.isEmpty else { continue }
                    continuation.yield(clean)
                }
                let tail = await stderrTask.value
                if generation == self.startupGeneration,
                   monitored.isRunning == false, monitored.terminationStatus != 0 {
                    let detail = tail.suffix(3).joined(separator: "\n")
                    onState(.failed(message:
                        "Pi exited (\(monitored.terminationStatus))."
                        + (detail.isEmpty ? "" : "\n\(detail)")))
                }
                continuation.finish()
                self.cleanupExitedProcess(monitored, generation: generation)
            }
        }

        onState(.ready)
        return stream
    }

    /// Sends one RPC command, already encoded as a JSON line (dictionaries are not
    /// Sendable across the actor boundary; encoded strings are).
    public func send(line: String) {
        guard let stdinHandle else { return }
        var data = Data(line.utf8)
        data.append(Data("\n".utf8))
        try? stdinHandle.write(contentsOf: data)
    }

    public func stop() async {
        _ = await stopAndGetGeneration()
    }

    private func stopAndGetGeneration() async -> Int {
        startupGeneration &+= 1
        let generation = startupGeneration
        installationTask?.cancel()
        installationTask = nil
        eventContinuation?.finish()
        eventContinuation = nil
        stdinHandle = nil
        let stoppedProcess = process
        let stoppedPackage = installedPackage
        process = nil
        installedPackage = nil
        if let stoppedProcess {
            if stoppedProcess.isRunning {
                stoppedProcess.terminate()
                for _ in 0..<50 where stoppedProcess.isRunning {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if stoppedProcess.isRunning {
                    kill(stoppedProcess.processIdentifier, SIGKILL)
                }
            }
            ChildProcessRegistry.unregister(pid: stoppedProcess.processIdentifier)
        }
        if let stoppedPackage {
            try? FileManager.default.removeItem(at: stoppedPackage.directory)
        }
        return generation
    }

    private func cleanupExitedProcess(_ ended: Process, generation: Int) {
        guard generation == startupGeneration, process === ended else { return }
        ChildProcessRegistry.unregister(pid: ended.processIdentifier)
        process = nil
        if let installedPackage {
            try? FileManager.default.removeItem(at: installedPackage.directory)
            self.installedPackage = nil
        }
    }
}
