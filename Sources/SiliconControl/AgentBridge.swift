import Foundation

/// Finds the AI assistants installed on this Mac and wires the app's MCP bridge
/// into each one's configuration — the one-button version of "edit this JSON file,
/// then that TOML file". Connecting an assistant gives it every tool this app has,
/// so the heavy work (local chat, images, 3D, transcription) runs here instead of
/// spending the user's subscription tokens.
///
/// Config surgery rules: merge, never overwrite — a user's other MCP servers and
/// settings always survive. A config that can't be parsed is left untouched and
/// reported, never clobbered.
public enum AgentBridge {

    /// The MCP entry name used in every client's config. One name everywhere, and
    /// the same one `Scripts/install-mcp.sh` writes, so a manual install and a
    /// one-click install recognise each other.
    public static let serverName = "silicon-optimizer"

    /// Where things live on *this* run — injectable so tests build throwaway homes.
    public struct Environment: Sendable {
        public var home: URL
        public var applications: URL
        /// Absolute path of the silicon-mcp binary configs should point at.
        public var mcpPath: String

        public init(home: URL, applications: URL, mcpPath: String) {
            self.home = home
            self.applications = applications
            self.mcpPath = mcpPath
        }
    }

    public enum Client: String, CaseIterable, Sendable, Identifiable {
        case claudeDesktop
        case claudeCode
        case codex
        case chatGPTDesktop

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .claudeDesktop: return "Claude Desktop"
            case .claudeCode: return "Claude Code"
            case .codex: return "Codex"
            case .chatGPTDesktop: return "ChatGPT"
            }
        }
    }

    public enum Status: Equatable, Sendable {
        /// Found, no bridge entry yet.
        case notConnected
        /// Entry present and pointing at the current bridge binary.
        case connected
        /// Entry present but pointing somewhere else (an old copy, a moved app).
        case outdated(String)
        /// Found, but there is no local hook to configure; the text says why.
        case manualOnly(String)
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public let client: Client
        public let status: Status
        public var id: String { client.id }

        public init(client: Client, status: Status) {
            self.client = client
            self.status = status
        }
    }

    public enum BridgeError: LocalizedError {
        case unreadableConfig(String)
        case claudeCLIMissing(manualCommand: String)
        case commandFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unreadableConfig(let path):
                return "The existing config at \(path) isn't valid JSON, so it was "
                    + "left untouched. Fix or remove it, then try again."
            case .claudeCLIMissing(let command):
                return "Claude Code is here, but its `claude` command wasn't in the "
                    + "usual places. Run this once in Terminal instead:\n\(command)"
            case .commandFailed(let output):
                return output.isEmpty ? "The command failed." : output
            }
        }
    }

    // MARK: - Detection

    /// One row per assistant that is actually on this Mac, with its live status.
    public static func detect(in env: Environment) -> [Row] {
        let files = FileManager.default
        var rows: [Row] = []

        let desktopApp = env.applications.appendingPathComponent("Claude.app")
        if files.fileExists(atPath: desktopApp.path)
            || files.fileExists(atPath: claudeDesktopConfigURL(in: env).path) {
            rows.append(Row(client: .claudeDesktop, status: claudeDesktopStatus(in: env)))
        }

        if files.fileExists(atPath: claudeCodeConfigURL(in: env).path)
            || files.fileExists(atPath: env.home.appendingPathComponent(".claude").path)
            || claudeCLI(in: env) != nil {
            rows.append(Row(client: .claudeCode, status: claudeCodeStatus(in: env)))
        }

        if files.fileExists(atPath: env.home.appendingPathComponent(".codex").path)
            || codexCLI(in: env) != nil {
            rows.append(Row(client: .codex, status: codexStatus(in: env)))
        }

        if files.fileExists(atPath: env.applications.appendingPathComponent("ChatGPT.app").path) {
            rows.append(Row(client: .chatGPTDesktop, status: .manualOnly(
                "ChatGPT's desktop app only takes internet-hosted connectors so far, "
                + "so there is nothing local to configure. Your ChatGPT plan includes "
                + "Codex, which connects fully — install it and a Connect button "
                + "appears here.")))
        }

        return rows
    }

    // MARK: - Claude Desktop

    public static func claudeDesktopConfigURL(in env: Environment) -> URL {
        env.home.appendingPathComponent(
            "Library/Application Support/Claude/claude_desktop_config.json")
    }

    public static func claudeDesktopStatus(in env: Environment) -> Status {
        let url = claudeDesktopConfigURL(in: env)
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = parsed["mcpServers"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any]
        else { return .notConnected }
        return status(forConfiguredCommand: entry["command"] as? String, env: env)
    }

    /// Adds (or repoints) the bridge entry, preserving every other key in the file.
    @discardableResult
    public static func connectClaudeDesktop(in env: Environment) throws -> String {
        let url = claudeDesktopConfigURL(in: env)
        var config: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
            else { throw BridgeError.unreadableConfig(url.path) }
            config = parsed
        }
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": env.mcpPath]
        config["mcpServers"] = servers

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
        return "Connected — restart Claude Desktop and the tools appear."
    }

    // MARK: - Claude Code

    public static func claudeCodeConfigURL(in env: Environment) -> URL {
        env.home.appendingPathComponent(".claude.json")
    }

    /// User-scope MCP servers live at the top of ~/.claude.json. Reading it is
    /// safe; writing it is not — Claude Code rewrites that file while it runs, so
    /// connecting goes through its own CLI (see `claudeCLI`).
    public static func claudeCodeStatus(in env: Environment) -> Status {
        guard let data = try? Data(contentsOf: claudeCodeConfigURL(in: env)),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = parsed["mcpServers"] as? [String: Any],
              let entry = servers[serverName] as? [String: Any]
        else { return .notConnected }
        return status(forConfiguredCommand: entry["command"] as? String, env: env)
    }

    public static func claudeCLI(in env: Environment) -> URL? {
        firstExecutable([
            env.home.appendingPathComponent(".local/bin/claude"),
            env.home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            env.home.appendingPathComponent(".npm-global/bin/claude"),
            env.home.appendingPathComponent("bin/claude"),
        ])
    }

    /// The one-liner shown when the CLI can't be found.
    public static func claudeCodeManualCommand(in env: Environment) -> String {
        "claude mcp add --scope user \(serverName) \"\(env.mcpPath)\""
    }

    // MARK: - Codex

    public static func codexConfigURL(in env: Environment) -> URL {
        env.home.appendingPathComponent(".codex/config.toml")
    }

    public static func codexStatus(in env: Environment) -> Status {
        guard let text = try? String(contentsOf: codexConfigURL(in: env), encoding: .utf8)
        else { return .notConnected }
        return status(forConfiguredCommand: codexCommand(inTOML: text), env: env)
    }

    public static func codexCLI(in env: Environment) -> URL? {
        firstExecutable([
            env.home.appendingPathComponent(".local/bin/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex"),
            env.home.appendingPathComponent(".npm-global/bin/codex"),
            env.home.appendingPathComponent("bin/codex"),
        ])
    }

    /// Adds (or repoints) our `[mcp_servers.silicon-optimizer]` section, touching
    /// nothing else in the file.
    @discardableResult
    public static func connectCodex(in env: Environment) throws -> String {
        let url = codexConfigURL(in: env)
        let escaped = env.mcpPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let commandLine = "command = \"\(escaped)\""

        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = text.isEmpty ? [String]() : text.components(separatedBy: "\n")

        if let start = sectionStart(in: lines) {
            var index = start + 1
            var commandIndex: Int?
            while index < lines.count {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") { break }
                if isTOMLKey("command", line: trimmed) { commandIndex = index; break }
                index += 1
            }
            if let commandIndex {
                lines[commandIndex] = commandLine
            } else {
                lines.insert(commandLine, at: start + 1)
            }
        } else {
            if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("")
            }
            lines.append("[mcp_servers.\(serverName)]")
            lines.append(commandLine)
            lines.append("")
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return "Connected — new Codex sessions get the tools."
    }

    /// The `command` value inside our section, when the section exists.
    static func codexCommand(inTOML text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = sectionStart(in: lines) else { return nil }
        for line in lines[(start + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            if isTOMLKey("command", line: trimmed) {
                return tomlStringValue(afterKey: "command", in: trimmed)
            }
        }
        return nil
    }

    // MARK: - Shared pieces

    private static func status(forConfiguredCommand command: String?, env: Environment) -> Status {
        guard let command else { return .notConnected }
        return command == env.mcpPath ? .connected : .outdated(command)
    }

    private static func firstExecutable(_ candidates: [URL]) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Index of our section header. Bare and quoted key forms both count —
    /// `codex mcp add` writes the bare form, careful hands sometimes quote it.
    private static func sectionStart(in lines: [String]) -> Int? {
        let bare = "[mcp_servers.\(serverName)]"
        let quoted = "[mcp_servers.\"\(serverName)\"]"
        return lines.firstIndex {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed == bare || trimmed == quoted
        }
    }

    /// True when the line assigns exactly `key` — not a longer key sharing the prefix.
    private static func isTOMLKey(_ key: String, line: String) -> Bool {
        guard line.hasPrefix(key) else { return false }
        let rest = line.dropFirst(key.count)
        guard let next = rest.first else { return false }
        return next == "=" || next == " " || next == "\t"
    }

    /// Parses a basic or literal TOML string on the right of `key = …`.
    private static func tomlStringValue(afterKey key: String, in line: String) -> String? {
        var rest = Substring(line).dropFirst(key.count)
            .drop(while: { $0 == " " || $0 == "\t" })
        guard rest.first == "=" else { return nil }
        rest = rest.dropFirst().drop(while: { $0 == " " || $0 == "\t" })
        guard let quote = rest.first, quote == "\"" || quote == "'" else { return nil }
        rest = rest.dropFirst()
        if quote == "'" {
            return rest.firstIndex(of: "'").map { String(rest[..<$0]) }
        }
        var value = ""
        var escaped = false
        for character in rest {
            if escaped {
                value.append(character)
                escaped = false
                continue
            }
            if character == "\\" { escaped = true; continue }
            if character == "\"" { return value }
            value.append(character)
        }
        return nil
    }
}
