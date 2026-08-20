import Foundation
import SiliconCore

/// Manages the Qwen Code sidecar — the Qwen team's Apache-2.0 agent — whose `serve`
/// daemon ships a full browser chat UI the app embeds, exactly the way the DeepSeek
/// Harness is embedded.
///
/// Model access goes through the app's gateway: every local install and every swarm
/// model is written into the generated settings as its own provider entry, so the Web
/// Shell's model picker lists them all, and picking one loads or starts it on demand.
/// No Qwen or Alibaba account is involved at any point.
///
/// Isolation differs from the other sidecars because qwen-code offers no home-relocating
/// environment variable: instead the daemon runs in an app-private *workspace* directory
/// whose project-level `.qwen/settings.json` — which qwen-code ranks above the user's own
/// `~/.qwen` — carries our whole configuration. A qwen-code the user runs themselves
/// keeps its settings untouched.
public actor QwenCodeRuntime {

    /// Pinned for the same reason the harness and Codex are: an untested version must
    /// never arrive silently under our generated configuration.
    public static let packageSpec = "@qwen-code/qwen-code@0.21.14"

    private var process: ServerProcess?
    public private(set) var processIdentifier: Int32?

    public init() {}

    // MARK: - Locations

    /// The app-private workspace the daemon serves from. Its `.qwen/settings.json` is
    /// ours to regenerate; the folder itself is where the agent's file tools operate.
    public static var workspaceDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconOptimizer/qwen/workspace", isDirectory: true)
    }

    // MARK: - Configuration

    /// One model the settings should offer, in the shape the gateway lists them.
    public struct ModelEntry: Sendable, Equatable {
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The project settings document: OpenAI-compatible auth against the gateway, one
    /// model entry per gateway model so the picker shows them all, and the app's MCP
    /// bridge for tools. Rendered wholesale — the file lives in an app-owned workspace.
    ///
    /// Shape per the shipped v4 settings (the docs' flat-array example is stale):
    /// `modelProviders` is an object keyed by protocol, each key holding the model
    /// array — `{"openai": [{id, name, baseUrl, envKey}, …]}`.
    static func settingsJSON(
        gatewayPort: Int, models: [ModelEntry], mcpServerPath: String?
    ) -> Data {
        let base = "http://127.0.0.1:\(gatewayPort)/v1"
        var settings: [String: Any] = [
            "$version": 4,
            "security": ["auth": ["selectedType": "openai"]],
            "modelProviders": [
                "openai": models.map { model in
                    [
                        "id": model.id,
                        "name": model.name,
                        "baseUrl": base,
                        // The gateway takes no key; the env var this names is set to a
                        // placeholder by the launcher.
                        "envKey": "SILICON_GATEWAY_KEY",
                    ] as [String: Any]
                },
            ],
        ]
        if let mcpServerPath {
            settings["mcpServers"] = [
                "silicon-optimizer": [
                    "command": mcpServerPath,
                    // The longest tool renders a video clip on the node for ~10 minutes.
                    "timeout": 1_800_000,
                ] as [String: Any],
            ]
        }
        return (try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]
        )) ?? Data("{}".utf8)
    }

    public static func ensureConfigured(
        workspace: URL, gatewayPort: Int, models: [ModelEntry], mcpServerPath: String?
    ) throws {
        let settingsDirectory = workspace.appendingPathComponent(".qwen", isDirectory: true)
        try FileManager.default.createDirectory(
            at: settingsDirectory, withIntermediateDirectories: true
        )
        let url = settingsDirectory.appendingPathComponent("settings.json")
        let content = settingsJSON(
            gatewayPort: gatewayPort, models: models, mcpServerPath: mcpServerPath
        )
        if (try? Data(contentsOf: url)) != content {
            try content.write(to: url, options: .atomic)
        }
    }

    // MARK: - Lifecycle

    /// Starts `qwen serve` and reports progress through `onState`, ending in `.ready`
    /// with the Web Shell's URL or `.failed` with a diagnosis worth reading.
    public func start(
        webPort: Int,
        gatewayPort: Int,
        models: [ModelEntry],
        defaultModel: String,
        nodePath: String = "",
        onState: @escaping @Sendable (RuntimeState) -> Void
    ) async {
        await stop()

        let discovery = HarnessRuntime.locateNode(customPath: nodePath)
        guard let node = discovery.node else {
            let floor = HarnessRuntime.minimumNodeVersion
            var message = "Qwen Code needs Node.js \(floor.major).\(floor.minor) or newer. "
            if let path = discovery.rejectedPath, let version = discovery.rejectedVersion {
                message += "Found \(version) at \(path), which is too old. "
            } else {
                message += "None was found. "
            }
            message += "Install one with `brew install node`, or switch engines in Settings."
            onState(.failed(message: message))
            return
        }

        let workspace = Self.workspaceDirectory
        do {
            try Self.ensureConfigured(
                workspace: workspace, gatewayPort: gatewayPort, models: models,
                mcpServerPath: CodexRuntime.locateMCPServer()
            )
        } catch {
            onState(.failed(message:
                "Could not write the Qwen Code configuration: \(error.localizedDescription)"))
            return
        }

        onState(.starting(stage:
            "Starting Qwen Code… the first run downloads it and can take a few minutes."))

        let npx = node.deletingLastPathComponent().appendingPathComponent("npx")
        let process = ServerProcess()
        self.process = process
        do {
            let path = "\(node.deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin"
            try await process.start(
                executable: npx,
                arguments: ["--yes", Self.packageSpec, "serve", "--port", String(webPort)],
                environment: [
                    "PATH": path,
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                    // The provider entries in settings point at the gateway; these fill
                    // the default model and the placeholder credential.
                    "OPENAI_BASE_URL": "http://127.0.0.1:\(gatewayPort)/v1",
                    "OPENAI_API_KEY": "local-gateway-needs-no-key",
                    "SILICON_GATEWAY_KEY": "local-gateway-needs-no-key",
                    "OPENAI_MODEL": defaultModel,
                ],
                currentDirectory: workspace
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
                "Qwen Code did not come up. Last output:\n"
                + log.split(separator: "\n").suffix(6).joined(separator: "\n")
            ))
        }
    }

    /// Polls the Web Shell until it answers; the generous deadline is for npx's
    /// first-run download, not the server itself.
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
