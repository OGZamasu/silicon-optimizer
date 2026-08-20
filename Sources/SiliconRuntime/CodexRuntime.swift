import Foundation
import SiliconCore

/// A JSON value that can cross actor boundaries, for the Codex app-server protocol whose
/// payloads have no fixed schema worth typing out. Ids in particular must round-trip
/// exactly as the peer sent them, whether number or string.
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else { self = .null }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers as integers, so ids round-trip as the peer sent them.
            if value == value.rounded(), abs(value) < 9e15 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Access

    public subscript(key: String) -> JSONValue {
        if case .object(let object) = self { return object[key] ?? .null }
        return .null
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// The first string found under any of these keys — the protocol has renamed delta
    /// fields before, and a missed rename should cost nothing.
    public func firstString(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key].stringValue { return value }
        }
        return nil
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

/// What the app-server connection surfaces to the app.
public enum CodexEvent: Sendable {
    /// A notification: streamed items, deltas, turn lifecycle, token counts.
    case notification(method: String, params: JSONValue)
    /// A server-initiated request that must be answered (approvals). Reply through
    /// `CodexRuntime.respond(id:result:)` with the same id.
    case serverRequest(id: JSONValue, method: String, params: JSONValue)
    /// The sidecar exited. The last stderr lines make failures diagnosable.
    case terminated(message: String?)
}

/// Manages the Codex sidecar: OpenAI's open-source agent harness, spoken to over its
/// app-server protocol — newline-delimited JSON-RPC 2.0 on stdio.
///
/// Same isolation story as the DeepSeek Harness: a pinned version launched through npx,
/// under an app-private `CODEX_HOME`, so nothing here collides with a codex the user runs
/// themselves. The model side needs no OpenAI account: the generated config points Codex at
/// this app's own model gateway as a custom provider.
public actor CodexRuntime {

    /// Pinned: Codex ships fast and changes its protocol; an untested version must never
    /// arrive silently. Bump deliberately and retest the app-server handshake, approvals,
    /// and the gateway's Responses translation against it.
    public static let packageSpec = "@openai/codex@0.148.0"

    /// The provider id inside the generated Codex config. Permanent once chosen: Codex
    /// threads store model ids against it.
    public static let providerID = "silicon"

    private var process: Process?
    private var stdinPipe: Pipe?
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var nextRequestID = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var recentStderr: [String] = []

    private var eventContinuation: AsyncStream<CodexEvent>.Continuation?
    public private(set) var processIdentifier: Int32?

    public init() {}

    // MARK: - Locations

    /// Our private `CODEX_HOME`: config, auth state and thread history all live here.
    public static var homeDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconOptimizer/codex", isDirectory: true)
    }

    // MARK: - Configuration

    /// The whole config document. Unlike the DeepSeek Harness settings — which the harness's
    /// own UI edits, forcing line surgery — this home exists only for this app, so the file
    /// is rendered outright each start and says so in its header.
    ///
    /// `wire_api = "responses"` is not a choice: Codex dropped chat-completions support in
    /// early 2026, which is exactly why the gateway translates.
    ///
    /// The working folder is written as a trusted project because the user chose it in this
    /// app's own folder picker — that is Codex's trust question, answered here. Without it,
    /// a folder whose ancestors hold a `.codex` directory (any folder under home, for anyone
    /// who has used Codex before) loads that project layer half-disabled, and turns wedge
    /// after sampling without ever finishing.
    static func configuration(
        gatewayPort: Int, defaultModel: String, mcpServerPath: String?,
        trustedProjectPath: String?
    ) -> String {
        var document = """
        # Managed by Silicon Optimizer — regenerated each time Codex starts.
        # Edits here are overwritten; change things in the app instead.

        model = "\(defaultModel)"
        model_provider = "\(providerID)"

        [model_providers.\(providerID)]
        name = "Silicon Optimizer"
        base_url = "http://127.0.0.1:\(gatewayPort)/v1"
        wire_api = "responses"

        """
        if let mcpServerPath {
            document += """

            # This app's own MCP bridge: gives Codex the app's tools (load models, generate
            # images, reach the swarm) next to its built-in shell.
            [mcp_servers.silicon-optimizer]
            command = "\(tomlEscaped(mcpServerPath))"

            """
        }
        if let trustedProjectPath {
            document += """

            # The folder picked in the app's Codex chat. Trusting it is what lets a `.codex`
            # project layer along its path load fully instead of wedging every turn.
            [projects."\(tomlEscaped(trustedProjectPath))"]
            trust_level = "trusted"

            """
        }
        return document
    }

    /// TOML basic-string escaping for paths: backslashes and quotes.
    static func tomlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func ensureConfigured(
        home: URL, gatewayPort: Int, defaultModel: String, mcpServerPath: String?,
        trustedProjectPath: String?
    ) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appendingPathComponent("config.toml")
        let content = configuration(
            gatewayPort: gatewayPort, defaultModel: defaultModel,
            mcpServerPath: mcpServerPath, trustedProjectPath: trustedProjectPath
        )
        if (try? String(contentsOf: url, encoding: .utf8)) != content {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// The MCP bridge to hand Codex, when one is around: bundled copies first, then the
    /// path `install-mcp.sh` uses. Nil simply omits the tools — never a failure.
    public static func locateMCPServer() -> String? {
        var candidates: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/silicon-mcp") {
            candidates.append(bundled.path)
        }
        candidates.append("/usr/local/bin/silicon-mcp")
        candidates.append("/opt/homebrew/bin/silicon-mcp")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Lifecycle

    /// Spawns the sidecar and completes the `initialize` handshake. Events (streamed items,
    /// approvals, termination) arrive on the returned stream for the life of the process.
    public func start(
        nodePath: String = "",
        gatewayPort: Int,
        defaultModel: String,
        trustedProjectPath: String? = nil,
        onState: @escaping @Sendable (RuntimeState) -> Void
    ) async -> AsyncStream<CodexEvent>? {
        await stop()

        let discovery = HarnessRuntime.locateNode(customPath: nodePath)
        guard let node = discovery.node else {
            let floor = HarnessRuntime.minimumNodeVersion
            var message = "Codex is launched through npm, which needs Node.js "
                + "\(floor.major).\(floor.minor) or newer. "
            if let path = discovery.rejectedPath, let version = discovery.rejectedVersion {
                message += "Found \(version) at \(path), which is too old. "
            } else {
                message += "None was found. "
            }
            message += "Install one with `brew install node`, or switch engines in Settings."
            onState(.failed(message: message))
            return nil
        }

        let home = Self.homeDirectory
        do {
            try Self.ensureConfigured(
                home: home, gatewayPort: gatewayPort, defaultModel: defaultModel,
                mcpServerPath: Self.locateMCPServer(),
                trustedProjectPath: trustedProjectPath
            )
        } catch {
            onState(.failed(message:
                "Could not write the Codex configuration: \(error.localizedDescription)"))
            return nil
        }

        onState(.starting(stage:
            "Starting Codex… the first run downloads it and can take a few minutes."))

        let npx = node.deletingLastPathComponent().appendingPathComponent("npx")
        let process = Process()
        process.executableURL = npx
        process.arguments = ["--yes", Self.packageSpec, "app-server"]
        process.environment = [
            "CODEX_HOME": home.path,
            "PATH": "\(node.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
        ]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let (events, continuation) = AsyncStream.makeStream(of: CodexEvent.self)
        eventContinuation = continuation

        do {
            try process.run()
        } catch {
            onState(.failed(message: error.localizedDescription))
            eventContinuation = nil
            return nil
        }
        self.process = process
        self.stdinPipe = stdin
        processIdentifier = process.processIdentifier
        ChildProcessRegistry.register(pid: process.processIdentifier)

        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination() }
        }

        readTask = Task { [weak self] in
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    await self?.handleLine(line)
                }
            } catch {
                // Termination handling reports the exit; a broken pipe adds nothing.
            }
        }
        stderrTask = Task { [weak self] in
            do {
                for try await line in stderr.fileHandleForReading.bytes.lines {
                    await self?.noteStderr(line)
                }
            } catch {}
        }

        // The handshake proves the binary is really up — npx may spend minutes
        // downloading first — and unlocks every other method.
        do {
            _ = try await send(method: "initialize", params: [
                "clientInfo": [
                    "name": "silicon-optimizer",
                    "title": "Silicon Optimizer",
                    "version": "0.2.1",
                ],
                "capabilities": ["experimentalApi": true],
            ], timeout: 600)
            notify(method: "initialized", params: .object([:]))
        } catch {
            onState(.failed(message:
                "Codex did not answer the handshake: \(error.localizedDescription)"
                + diagnosticSuffix()))
            await stop()
            return nil
        }

        onState(.ready(endpoint: URL(string: "codex://app-server")!))
        return events
    }

    public func stop() async {
        readTask?.cancel()
        stderrTask?.cancel()
        readTask = nil
        stderrTask = nil
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
            ChildProcessRegistry.unregister(pid: process.processIdentifier)
        }
        process = nil
        stdinPipe = nil
        processIdentifier = nil
        for (_, continuation) in pending {
            continuation.resume(throwing: CodexError.stopped)
        }
        pending.removeAll()
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func handleTermination() {
        let message = recentStderr.suffix(4).joined(separator: "\n")
        eventContinuation?.yield(.terminated(message: message.isEmpty ? nil : message))
        eventContinuation?.finish()
        eventContinuation = nil
        for (_, continuation) in pending {
            continuation.resume(throwing: CodexError.stopped)
        }
        pending.removeAll()
        if let pid = processIdentifier {
            ChildProcessRegistry.unregister(pid: pid)
        }
        process = nil
        processIdentifier = nil
    }

    private func noteStderr(_ line: String) {
        recentStderr.append(line)
        if recentStderr.count > 40 { recentStderr.removeFirst(recentStderr.count - 40) }
    }

    private func diagnosticSuffix() -> String {
        let tail = recentStderr.suffix(3).joined(separator: "\n")
        return tail.isEmpty ? "" : "\n\(tail)"
    }

    // MARK: - JSON-RPC

    public enum CodexError: Error, LocalizedError {
        case stopped
        case timeout(String)
        case server(code: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .stopped: "Codex is not running."
            case .timeout(let method): "Codex did not answer \(method) in time."
            case .server(let code, let message): "Codex error \(code): \(message)"
            }
        }
    }

    /// Sends one request and awaits its response.
    public func send(
        method: String, params: JSONValue, timeout: TimeInterval = 120
    ) async throws -> JSONValue {
        guard let stdinPipe else { throw CodexError.stopped }
        let id = nextRequestID
        nextRequestID += 1

        let message: JSONValue = .object([
            "jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method),
            "params": params,
        ])
        let line = try Self.encodeLine(message)

        let value: JSONValue = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: line)
            } catch {
                pending[id] = nil
                continuation.resume(throwing: error)
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                await self?.timeOut(id: id, method: method)
            }
        }
        return value
    }

    /// Sends a notification (no response expected).
    public func notify(method: String, params: JSONValue) {
        guard let stdinPipe,
              let line = try? Self.encodeLine(.object([
                  "jsonrpc": "2.0", "method": .string(method), "params": params,
              ]))
        else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: line)
    }

    /// Answers a server-initiated request (an approval) with the given result.
    public func respond(id: JSONValue, result: JSONValue) {
        guard let stdinPipe,
              let line = try? Self.encodeLine(.object([
                  "jsonrpc": "2.0", "id": id, "result": result,
              ]))
        else { return }
        try? stdinPipe.fileHandleForWriting.write(contentsOf: line)
    }

    private func timeOut(id: Int, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CodexError.timeout(method))
    }

    static func encodeLine(_ value: JSONValue) throws -> Data {
        var data = try JSONEncoder().encode(value)
        debugLog(">> \(String(decoding: data.prefix(300), as: UTF8.self))")
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// A wire tap for diagnosing protocol trouble: every line in and out lands in
    /// `CODEX_HOME/wire.log` when that file exists. Touch the file to enable it; delete
    /// it to stop. Nothing is written otherwise.
    static func debugLog(_ line: String) {
        let url = homeDirectory.appendingPathComponent("wire.log")
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = try? FileHandle(forWritingTo: url)
        else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(Date().timeIntervalSince1970) \(line)\n".utf8))
    }

    private func handleLine(_ line: String) {
        Self.debugLog("<< \(line.prefix(300))")
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let fields) = message
        else { return } // npm noise or a blank line, never fatal

        let id = fields["id"] ?? .null
        let method = fields["method"]?.stringValue

        if let method {
            if id.isNull {
                eventContinuation?.yield(.notification(
                    method: method, params: fields["params"] ?? .null
                ))
            } else {
                eventContinuation?.yield(.serverRequest(
                    id: id, method: method, params: fields["params"] ?? .null
                ))
            }
            return
        }

        // A response to one of ours. Ids we mint are always integers.
        guard let numericID = id.intValue,
              let continuation = pending.removeValue(forKey: numericID)
        else { return }
        if let error = fields["error"], case .object = error {
            continuation.resume(throwing: CodexError.server(
                code: error["code"].intValue ?? -1,
                message: error["message"].stringValue ?? "unknown error"
            ))
        } else {
            continuation.resume(returning: fields["result"] ?? .null)
        }
    }
}
