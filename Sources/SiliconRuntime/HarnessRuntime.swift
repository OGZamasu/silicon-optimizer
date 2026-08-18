import Foundation
import SiliconCore

/// Manages the DeepSeek Harness (`dsh`) sidecar that powers the agentic chat experience.
///
/// The harness is a Node.js application, launched with `npx` and served as a local web UI the
/// app embeds. It brings what the built-in chat lacks — tool use, web fetch and search, file
/// access, a real agent loop — while the model itself keeps being served by this app's own
/// llama-server, which the harness reaches as a custom OpenAI-compatible provider.
///
/// Isolation matters here: the process runs under its own `DSH_HOME` inside Application
/// Support, so nothing it stores collides with a `dsh` the user may run independently.
public actor HarnessRuntime {

    /// Pinned rather than `@latest`: the harness is in developer preview and promises breaking
    /// changes, so an untested version must never arrive silently under our generated config.
    public static let packageSpec = "@deepseek-ai/dsh@0.1.0-rc.7"

    /// The provider id the harness knows our local server by. Permanent once chosen — saved
    /// harness sessions and its model defaults reference it — so never rename it.
    static let providerID = "silicon-local"

    /// The dummy credential for a local server that requires none. The harness's provider
    /// plugin refuses to run without *a* key, but llama-server ignores the header entirely.
    static let apiKeyVariable = "SILICON_LOCAL_API_KEY"

    private var process: ServerProcess?
    public private(set) var processIdentifier: Int32?

    public init() {}

    // MARK: - Locations

    /// Our private `DSH_HOME`. Profiles, settings, credentials and sessions all live here.
    public static var homeDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconOptimizer/dsh", isDirectory: true)
    }

    // MARK: - Ports

    public static func allocatePort() -> Int { PortAllocator.free() }

    /// Whether a previously chosen port can still be bound. A port persisted across launches
    /// can be squatted by a leftover process; the caller then allocates a fresh one.
    public static func isPortFree(_ port: Int) -> Bool {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { close(socketDescriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    // MARK: - Node discovery

    /// The oldest Node.js the harness runs on: it imports `util.parseEnv`, which appeared in
    /// 20.12. Machines accumulate stale nodes — a leftover installer in /usr/local outlives
    /// years of newer ones elsewhere — so age must be checked, not assumed.
    public static let minimumNodeVersion = (major: 20, minor: 12, patch: 0)

    /// What the search saw, kept so a failure can say "found v20.10, too old" instead of the
    /// misleading "not found" when a node exists but cannot run the harness.
    public struct NodeDiscovery: Sendable {
        public var node: URL?
        /// The newest candidate rejected for age, when no candidate qualified.
        public var rejectedPath: String?
        public var rejectedVersion: String?
    }

    /// Finds the newest usable Node.js the way a person would, because a GUI app inherits
    /// almost no PATH from launchd and "install Node" must not mean "edit a plist".
    ///
    /// Every candidate is version-probed; the newest one at or above the floor wins, except
    /// that a qualifying user-supplied path always wins. A candidate without `npx` beside it
    /// is skipped rather than fatal — some package managers ship the bare binary.
    public static func locateNode(customPath: String = "") -> NodeDiscovery {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.path

        if !customPath.isEmpty, usable(nodeAt: customPath),
           let version = nodeVersion(at: customPath), meetsFloor(version) {
            return NodeDiscovery(node: URL(fileURLWithPath: customPath))
        }

        var candidates: [String] = []
        // The copy shipped inside the app bundle guarantees the default chat path works on
        // a Mac that has never seen a terminal. It competes on version like every other
        // candidate, so someone's newer system Node still wins the pick below.
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/node").path {
            candidates.append(bundled)
        }
        candidates += [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/opt/local/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.bun/bin/node",
            "\(home)/.local/bin/node",
        ]

        // Version managers keep one directory per installed version.
        for versionsRoot in ["\(home)/.nvm/versions/node", "\(home)/.local/share/fnm/node-versions"] {
            if let versions = try? manager.contentsOfDirectory(atPath: versionsRoot) {
                for version in versions {
                    candidates.append("\(versionsRoot)/\(version)/bin/node")
                    candidates.append("\(versionsRoot)/\(version)/installation/bin/node")
                }
            }
        }

        // The environment PATH covers development runs from a terminal.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/node" }
        }

        var discovery = pick(from: candidates, includingRejected: customPath)
        if discovery.node != nil { return discovery }

        // Last resort: ask the user's login shell, which sees their real PATH. Expensive, so
        // only when nothing above qualified.
        var shellCandidates: [String] = []
        for shellArguments in [["-l", "-c"], ["-i", "-l", "-c"]] {
            if let found = shellLookup(arguments: shellArguments + ["command -v node"]) {
                shellCandidates.append(found)
            }
        }
        let fromShell = pick(from: shellCandidates, includingRejected: nil)
        if fromShell.node != nil { return fromShell }
        if discovery.rejectedPath == nil { discovery = fromShell }
        return discovery
    }

    private static func pick(
        from candidates: [String], includingRejected extraCandidate: String?
    ) -> NodeDiscovery {
        var probed = Set<String>()
        var best: (url: URL, version: (Int, Int, Int))?
        var rejected: (path: String, version: (Int, Int, Int))?

        var all = candidates
        if let extraCandidate, !extraCandidate.isEmpty { all.append(extraCandidate) }

        for candidate in all where usable(nodeAt: candidate) {
            let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            guard probed.insert(resolved).inserted else { continue }
            guard let version = nodeVersion(at: candidate) else { continue }
            if meetsFloor(version) {
                if best == nil || version > best!.version {
                    best = (URL(fileURLWithPath: candidate), version)
                }
            } else if rejected == nil || version > rejected!.version {
                rejected = (candidate, version)
            }
        }

        if let best { return NodeDiscovery(node: best.url) }
        return NodeDiscovery(
            node: nil,
            rejectedPath: rejected?.path,
            rejectedVersion: rejected.map { "v\($0.version.0).\($0.version.1).\($0.version.2)" }
        )
    }

    /// Executable, with the `npx` launcher beside it — the harness is started through npx.
    private static func usable(nodeAt path: String) -> Bool {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: path) else { return false }
        let npx = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent("npx").path
        return manager.isExecutableFile(atPath: npx)
    }

    private static func meetsFloor(_ version: (Int, Int, Int)) -> Bool {
        version >= (minimumNodeVersion.major, minimumNodeVersion.minor, minimumNodeVersion.patch)
    }

    /// Parses `v24.19.0`-style output into a comparable triple.
    static func parseNodeVersion(_ output: String) -> (Int, Int, Int)? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("v") else { return nil }
        let parts = trimmed.dropFirst().split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0)
    }

    private static func nodeVersion(at path: String) -> (Int, Int, Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard let data = try? pipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8)
        else { return nil }
        return parseNodeVersion(output)
    }

    private static func shellLookup(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        // An interactive shell with an exotic prompt setup can hang; give it a bounded wait
        // rather than trusting it.
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let output = String(data: data, encoding: .utf8)
        else { return nil }
        let lines = output.split(separator: "\n").map(String.init)
        // Interactive startup files may print banners; the path is the last line.
        return lines.last { $0.hasPrefix("/") }
    }

    // MARK: - Provider configuration

    /// What the harness should believe about the model behind our provider. Both fields ride
    /// the model entry in the settings document: the name is what the picker shows instead of
    /// the bare provider id, and the context window is what the harness budgets compaction
    /// against — left unsaid, it assumes a 262K default that a 32K load will never survive.
    public struct AdvertisedModel: Sendable, Equatable {
        public var name: String?
        public var contextLength: Int?

        public init(name: String? = nil, contextLength: Int? = nil) {
            self.name = name
            self.contextLength = contextLength
        }
    }

    /// The managed provider entry, rendered at `indent` spaces.
    private static func providerLines(
        indent: Int, inferencePort: Int, model: AdvertisedModel
    ) -> [String] {
        let pad = String(repeating: " ", count: indent)
        var lines = [
            "\(pad)\(providerID):",
            "\(pad)  apiKeyEnv: \(apiKeyVariable)",
            "\(pad)  api: openai-completions",
            "\(pad)  baseURL: http://127.0.0.1:\(inferencePort)/v1",
            "\(pad)  models:",
            "\(pad)    - id: \(providerID)",
        ]
        if let name = model.name {
            let escaped = name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            lines.append("\(pad)      name: \"\(escaped)\"")
        }
        if let context = model.contextLength {
            lines.append("\(pad)      contextWindow: \(context)")
        }
        return lines
    }

    /// Returns the harness settings document with our local provider present and current,
    /// starting from `existing` (nil when no settings file exists yet).
    ///
    /// The same file is written by the harness's own settings UI, so this must be surgical:
    /// everything outside our provider entry is preserved byte for byte. Three cases:
    /// our entry exists (replace exactly its block), an `llm-pi-ai` section exists without
    /// our entry (insert into it), or neither exists (append our section).
    static func providerConfiguration(
        existing: String?, inferencePort: Int, model: AdvertisedModel = AdvertisedModel()
    ) -> String {
        guard let existing, !existing.isEmpty else {
            return """
            # Managed by Silicon Optimizer: the '\(providerID)' provider below is how the harness
            # reaches the model this app serves locally. Other settings in this file are yours.
            llm-pi-ai:
              providers:

            """ + providerLines(indent: 4, inferencePort: inferencePort, model: model)
                .joined(separator: "\n") + "\n"
        }

        var lines = existing.components(separatedBy: "\n")

        if let providerIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "\(providerID):"
        }) {
            // Replace our block wholesale — the port, name and context can all have changed.
            // Its indentation is taken from where it actually sits, in case the harness's own
            // settings writer reflowed the document around it.
            let indent = lines[providerIndex].prefix { $0 == " " }.count
            var end = providerIndex + 1
            while end < lines.count {
                let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
                let lineIndent = lines[end].prefix { $0 == " " }.count
                if !trimmed.isEmpty && lineIndent <= indent { break }
                end += 1
            }
            // Trailing blank lines belong to the document, not to our block.
            while end > providerIndex + 1,
                  lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                end -= 1
            }
            lines.replaceSubrange(
                providerIndex..<end,
                with: providerLines(indent: indent, inferencePort: inferencePort, model: model)
            )
            return lines.joined(separator: "\n")
        }

        let fresh = providerLines(indent: 4, inferencePort: inferencePort, model: model)

        if let sectionIndex = lines.firstIndex(where: { $0.hasPrefix("llm-pi-ai:") }) {
            // The user configured other pi-ai providers; join them rather than duplicating
            // the top-level key, which would corrupt the document.
            if let providersIndex = lines[(sectionIndex + 1)...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "providers:"
                    && $0.hasPrefix(" ") && !$0.hasPrefix("    ")
            }) {
                lines.insert(contentsOf: fresh, at: providersIndex + 1)
            } else {
                lines.insert(contentsOf: ["  providers:"] + fresh, at: sectionIndex + 1)
            }
            return lines.joined(separator: "\n")
        }

        let separator = existing.hasSuffix("\n") ? "" : "\n"
        return existing + separator + "llm-pi-ai:\n  providers:\n"
            + fresh.joined(separator: "\n") + "\n"
    }

    /// Writes the provider configuration to disk. Called before the harness starts and again
    /// after each model load; the write is skipped entirely when nothing changed, keeping the
    /// window for racing the harness's own settings writer as small as it can be.
    public static func ensureProviderConfigured(
        home: URL, inferencePort: Int, model: AdvertisedModel = AdvertisedModel()
    ) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let settingsURL = home.appendingPathComponent("settings.yaml")
        let existing = try? String(contentsOf: settingsURL, encoding: .utf8)
        let updated = providerConfiguration(
            existing: existing, inferencePort: inferencePort, model: model
        )
        if updated != existing {
            try updated.write(to: settingsURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Lifecycle

    /// Starts the harness and reports progress through `onState`, ending in `.ready` with the
    /// web UI's URL or `.failed` with a diagnosis worth reading.
    public func start(
        webPort: Int,
        inferencePort: Int,
        nodePath: String = "",
        advertising model: AdvertisedModel = AdvertisedModel(),
        onState: @escaping @Sendable (RuntimeState) -> Void
    ) async {
        await stop()

        let discovery = Self.locateNode(customPath: nodePath)
        guard let node = discovery.node else {
            let floor = Self.minimumNodeVersion
            var message = "The harness needs Node.js \(floor.major).\(floor.minor) or newer. "
            if let path = discovery.rejectedPath, let version = discovery.rejectedVersion {
                message += "Found \(version) at \(path), which is too old. "
            } else {
                message += "None was found. "
            }
            message += "Install a current one with `brew install node`, then reopen this "
                + "tab — or switch to the built-in chat in Settings."
            onState(.failed(message: message))
            return
        }

        let npx = node.deletingLastPathComponent().appendingPathComponent("npx")

        let home = Self.homeDirectory
        do {
            try Self.ensureProviderConfigured(
                home: home, inferencePort: inferencePort, model: model
            )
        } catch {
            onState(.failed(message:
                "Could not write the harness configuration: \(error.localizedDescription)"
            ))
            return
        }

        onState(.starting(stage:
            "Starting DeepSeek Harness… the first run downloads it and can take a few minutes."
        ))

        let process = ServerProcess()
        self.process = process
        do {
            // PATH must contain node's directory: npx is a script whose shebang resolves
            // `env node`, and a launchd-spawned app offers almost nothing in PATH.
            let path = "\(node.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
            try await process.start(
                executable: npx,
                arguments: ["--yes", Self.packageSpec, "web", "--port", String(webPort)],
                environment: [
                    "DSH_HOME": home.path,
                    "PATH": path,
                    Self.apiKeyVariable: "local-server-needs-no-key",
                ],
                currentDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        } catch {
            onState(.failed(message: error.localizedDescription))
            return
        }
        processIdentifier = await process.pid

        let url = URL(string: "http://127.0.0.1:\(webPort)")!
        if await waitUntilServing(url: url, process: process) {
            onState(.ready(endpoint: url))
        } else {
            let log = await process.log
            await stop()
            onState(.failed(message:
                "The harness did not come up. Last output:\n"
                + log.split(separator: "\n").suffix(6).joined(separator: "\n")
            ))
        }
    }

    /// Polls the web UI until it answers. The generous deadline is for npx's first-run
    /// download, not for the server itself, which is up within seconds once installed.
    private func waitUntilServing(url: URL, process: ServerProcess) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: configuration)
        let deadline = Date().addingTimeInterval(600)

        while Date() < deadline {
            if await !process.isRunning { return false }
            if let (_, response) = try? await session.data(from: url),
               let http = response as? HTTPURLResponse, http.statusCode < 500 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    public func stop() async {
        guard let process else { return }
        await process.terminate()
        self.process = nil
        processIdentifier = nil
    }
}
