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
    public static let packageSpec = "@earendil-works/pi-coding-agent@0.84.2"

    public static var workspaceDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconOptimizer/pi/workspace", isDirectory: true)
    }

    public enum State: Sendable, Equatable {
        case idle
        case starting(stage: String)
        case ready
        case stopping
        case failed(message: String)
    }

    private var process: Process?
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
            let destination = extensions.appendingPathComponent("silicon.ts")
            let fresh = try Data(contentsOf: extensionSource)
            if (try? Data(contentsOf: destination)) != fresh {
                try fresh.write(to: destination, options: .atomic)
            }
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
        gatewayPort: Int, mcpServerPath: String?, nodePath: String,
        onState: @escaping @Sendable (State) -> Void
    ) async -> AsyncStream<String>? {
        await stop()

        let discovery = HarnessRuntime.locateNode(customPath: nodePath)
        guard let node = discovery.node else {
            let floor = HarnessRuntime.minimumNodeVersion
            onState(.failed(message:
                "Pi needs Node.js \(floor.major).\(floor.minor) or newer and none was "
                + "found. Install one with `brew install node`, or switch engines in "
                + "Settings."))
            return nil
        }

        let workspace = Self.workspaceDirectory
        onState(.starting(stage:
            "Starting Pi… the first run downloads it and can take a few minutes."))

        let process = Process()
        let npx = node.deletingLastPathComponent().appendingPathComponent("npx")
        process.executableURL = npx
        process.arguments = [
            "--yes", Self.packageSpec,
            "--mode", "rpc",
            // Trust our own workspace for this run without writing the user's
            // trust store.
            "-a",
            "--session-dir", workspace.appendingPathComponent("sessions").path,
        ]
        process.currentDirectoryURL = workspace

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] =
            "\(node.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["SILICON_GATEWAY_PORT"] = String(gatewayPort)
        // The gateway is loopback and token-free; the provider config references
        // this variable so Pi never prompts for a key.
        environment["SILICON_GATEWAY_KEY"] = "local"
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
            onState(.failed(message: "Could not launch Pi: \(error.localizedDescription)"))
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
                if monitored.isRunning == false, monitored.terminationStatus != 0 {
                    let detail = tail.suffix(3).joined(separator: "\n")
                    onState(.failed(message:
                        "Pi exited (\(monitored.terminationStatus))."
                        + (detail.isEmpty ? "" : "\n\(detail)")))
                }
                continuation.finish()
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
        eventContinuation?.finish()
        eventContinuation = nil
        stdinHandle = nil
        if let process, process.isRunning {
            process.terminate()
            ChildProcessRegistry.unregister(pid: process.processIdentifier)
        }
        process = nil
    }
}