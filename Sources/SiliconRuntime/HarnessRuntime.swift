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
    static func providerConfiguration(
        existing: String?, inferencePort: Int, model: AdvertisedModel = AdvertisedModel()
    ) -> String {
        upserting(
            providerID: providerID,
            into: existing,
            header: """
            # Managed by Silicon Optimizer: the '\(providerID)' provider below is how the harness
            # reaches the model this app serves locally. Other settings in this file are yours.
            """
        ) { indent in
            providerLines(indent: indent, inferencePort: inferencePort, model: model)
        }
    }

    /// Replaces or inserts one provider block by id, preserving everything else.
    ///
    /// The same file is written by the harness's own settings UI, so this must be surgical:
    /// everything outside the named entry is preserved byte for byte. Three cases: the
    /// entry exists (replace exactly its block), an `llm-pi-ai` section exists without it
    /// (insert into it), or neither exists (append the section under `header`).
    private static func upserting(
        providerID id: String, into existing: String?, header: String,
        render: (Int) -> [String]
    ) -> String {
        guard let existing, !existing.isEmpty else {
            return header + "\nllm-pi-ai:\n  providers:\n\n"
                + render(4).joined(separator: "\n") + "\n"
        }

        var lines = existing.components(separatedBy: "\n")

        if let providerIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "\(id):"
        }) {
            // Replace the block wholesale — the port, name and context can all have changed.
            // Its indentation is taken from where it actually sits, in case the harness's own
            // settings writer reflowed the document around it.
            let indent = lines[providerIndex].prefix { $0 == " " }.count
            let end = endOfBlock(startingAt: providerIndex, indent: indent, in: lines)
            lines.replaceSubrange(providerIndex..<end, with: render(indent))
            return lines.joined(separator: "\n")
        }

        let fresh = render(4)

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

    /// Where a provider block ends: the next non-blank line at or above its indentation.
    /// Trailing blank lines belong to the document, not to the block.
    private static func endOfBlock(startingAt start: Int, indent: Int, in lines: [String]) -> Int {
        var end = start + 1
        while end < lines.count {
            let trimmed = lines[end].trimmingCharacters(in: .whitespaces)
            let lineIndent = lines[end].prefix { $0 == " " }.count
            if !trimmed.isEmpty && lineIndent <= indent { break }
            end += 1
        }
        while end > start + 1,
              lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            end -= 1
        }
        return end
    }

    // MARK: - Swarm provider retirement

    /// The prefix of the per-peer providers this app used to write into the settings
    /// document. The `silicon` plugin provider now lists every node model live, so managed
    /// entries with this prefix are removed on sight — after repairing anything that
    /// still points at them.
    static let swarmProviderPrefix = "silicon-swarm-"

    /// Removes every managed `silicon-swarm-*` provider from the settings document,
    /// first rewriting stored model references so saved defaults keep working: the pair
    /// `provider: silicon-swarm-<peer>` / `model: <m>` becomes `provider: silicon` /
    /// `model: node/<peer>/<m>` — exactly the id the plugin's gateway knows the model by.
    /// Everything the user wrote stays untouched.
    static func retiringSwarmProviders(existing: String?) -> String? {
        guard let existing, !existing.isEmpty else { return existing }
        var document = rewritingSwarmReferences(in: existing)
        for id in managedSwarmIDs(in: document) {
            document = removingProvider(id: id, from: document)
        }
        return document
    }

    private static func rewritingSwarmReferences(in document: String) -> String {
        var lines = document.components(separatedBy: "\n")
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("provider: \(swarmProviderPrefix)") else { continue }
            let slug = String(trimmed.dropFirst("provider: \(swarmProviderPrefix)".count))
            guard !slug.isEmpty, !slug.contains(" ") else { continue }
            for neighbor in [index + 1, index - 1] where lines.indices.contains(neighbor) {
                let neighborTrimmed = lines[neighbor].trimmingCharacters(in: .whitespaces)
                guard neighborTrimmed.hasPrefix("model: ") else { continue }
                let model = String(neighborTrimmed.dropFirst("model: ".count))
                guard !model.hasPrefix("node/") else { continue }
                let indent = String(lines[neighbor].prefix { $0 == " " })
                lines[neighbor] = "\(indent)model: node/\(slug)/\(model)"
            }
            let indent = String(lines[index].prefix { $0 == " " })
            lines[index] = "\(indent)provider: silicon"
        }
        return lines.joined(separator: "\n")
    }

    private static func managedSwarmIDs(in document: String) -> [String] {
        document.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(swarmProviderPrefix), trimmed.hasSuffix(":"),
                  !trimmed.contains(" ") else { return nil }
            return String(trimmed.dropLast())
        }
    }

    private static func removingProvider(id: String, from document: String) -> String {
        var lines = document.components(separatedBy: "\n")
        guard let providerIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "\(id):"
        }) else { return document }
        let indent = lines[providerIndex].prefix { $0 == " " }.count
        let end = endOfBlock(startingAt: providerIndex, indent: indent, in: lines)
        lines.removeSubrange(providerIndex..<end)
        return lines.joined(separator: "\n")
    }

    /// Applies the retirement to disk; skipped when there is nothing to retire.
    public static func ensureSwarmProvidersRetired(home: URL) throws {
        let settingsURL = home.appendingPathComponent("settings.yaml")
        let existing = try? String(contentsOf: settingsURL, encoding: .utf8)
        guard let updated = retiringSwarmProviders(existing: existing), updated != existing
        else { return }
        try updated.write(to: settingsURL, atomically: true, encoding: .utf8)
    }

    // MARK: - The silicon models plugin

    /// Where the vendored `dsh-llm-silicon` plugin lives at runtime: inside the app bundle
    /// for installed copies, beside the sources for `swift run` during development.
    public static func siliconPluginSource() -> URL? {
        let manager = FileManager.default
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("dsh-llm-silicon", isDirectory: true),
           manager.fileExists(atPath: bundled.appendingPathComponent("lib/index.js").path) {
            return bundled
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SiliconRuntime
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Resources/dsh-llm-silicon", isDirectory: true)
        if manager.fileExists(atPath: repo.appendingPathComponent("lib/index.js").path) {
            return repo
        }
        return nil
    }

    /// Files that make up the plugin, copied verbatim.
    static let siliconPluginFiles = ["package.json", "lib/index.js"]

    /// Installs (or updates) the plugin inside the profile tree. The location matters:
    /// under `profiles/` the plugin's bare `@deepseek-ai/dsh-llm` import resolves through
    /// `profiles/node_modules` — the same physical tree the running harness loads from, so
    /// both sides share one module instance and `instanceof` checks hold.
    @discardableResult
    public static func ensureSiliconPluginInstalled(home: URL, source: URL) throws -> URL {
        let destination = home.appendingPathComponent(
            "profiles/plugins/dsh-llm-silicon", isDirectory: true
        )
        let manager = FileManager.default
        for file in siliconPluginFiles {
            let fromData = try Data(contentsOf: source.appendingPathComponent(file))
            let to = destination.appendingPathComponent(file)
            if let existing = try? Data(contentsOf: to), existing == fromData { continue }
            try manager.createDirectory(
                at: to.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try fromData.write(to: to, options: .atomic)
        }
        return destination.appendingPathComponent("lib/index.js")
    }

    /// The `--patch` overlay that loads the plugin. A file this app owns outright —
    /// regenerated every start, never merged — which is what keeps the user's own
    /// `cordis.patch.yml` theirs.
    ///
    /// With an `mcpServerPath`, a second row wires this app's MCP bridge in through the
    /// harness's bundled MCP client, so the chat can also *do* things — generate images
    /// and 3D on this Mac, render video on the swarm's node, load models. Tools appear
    /// to the model as `mcp__silicon__<name>`.
    static func siliconOverlay(
        pluginIndexPath: String, gatewayPort: Int, mcpServerPath: String? = nil
    ) -> String {
        let escaped = pluginIndexPath.replacingOccurrences(of: "'", with: "''")
        var document = """
        # Managed by Silicon Optimizer: loads the dsh-llm-silicon plugin, which lists every
        # model this Mac and its swarm nodes can serve. Regenerated at each harness start —
        # edits here are overwritten. Your profile's own cordis.patch.yml is untouched.
        - insert:
            - id: silicon-models
              name: '\(escaped)'
              config:
                baseURL: http://127.0.0.1:\(gatewayPort)/v1

        """
        if let mcpServerPath {
            let escapedServer = mcpServerPath.replacingOccurrences(of: "'", with: "''")
            document += """
                - id: silicon-tools
                  name: '@deepseek-ai/dsh-mcp-client'
                  config:
                    serverName: silicon
                    transport: stdio
                    command: '\(escapedServer)'
                    # The longest tool renders a video clip on the node for ~10 minutes.
                    toolCallTimeoutMs: 1800000

            """
        }
        return document
    }

    /// Writes the overlay next to the settings document and returns its path.
    public static func writeSiliconOverlay(
        home: URL, pluginIndexPath: String, gatewayPort: Int, mcpServerPath: String? = nil
    ) throws -> URL {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let url = home.appendingPathComponent("silicon-overlay.patch.yml")
        let content = siliconOverlay(
            pluginIndexPath: pluginIndexPath, gatewayPort: gatewayPort,
            mcpServerPath: mcpServerPath
        )
        if (try? String(contentsOf: url, encoding: .utf8)) != content {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
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
    ///
    /// With a `gatewayPort`, the silicon models plugin is installed into the profile tree and
    /// loaded through a `--patch` overlay, putting every local and swarm model in the
    /// harness's picker. Without one the harness still runs on the `silicon-local` provider.
    public func start(
        webPort: Int,
        inferencePort: Int,
        nodePath: String = "",
        advertising model: AdvertisedModel = AdvertisedModel(),
        gatewayPort: Int? = nil,
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

        // The plugin is a nicety, never a gatekeeper: any failure here leaves the harness
        // to boot exactly as it did before the gateway existed.
        var overlayPath: String?
        if let gatewayPort, let source = Self.siliconPluginSource() {
            if let pluginIndex = try? Self.ensureSiliconPluginInstalled(home: home, source: source),
               let overlay = try? Self.writeSiliconOverlay(
                   home: home, pluginIndexPath: pluginIndex.path, gatewayPort: gatewayPort,
                   mcpServerPath: CodexRuntime.locateMCPServer()
               ) {
                overlayPath = overlay.path
            }
        }

        onState(.starting(stage:
            "Starting DeepSeek Harness… the first run downloads it and can take a few minutes."
        ))

        // The `--profile web` root form rather than the `web` subcommand: `--patch` is a
        // launcher flag, and the launcher only accepts it ahead of profile arguments.
        var arguments = ["--yes", Self.packageSpec, "--profile", "web"]
        if let overlayPath {
            arguments += ["--patch", overlayPath]
        }
        arguments += ["--port", String(webPort)]

        let process = ServerProcess()
        self.process = process
        do {
            // PATH must contain node's directory: npx is a script whose shebang resolves
            // `env node`, and a launchd-spawned app offers almost nothing in PATH.
            let path = "\(node.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
            try await process.start(
                executable: npx,
                arguments: arguments,
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
