import Foundation
import Testing
@testable import SiliconControl

/// The one-button connect edits config files the user's other tools also own.
/// These tests pin the two safety rules — merge, never overwrite; leave anything
/// unparseable untouched — and the detection that decides which buttons appear.
@Suite("Agent bridge")
struct AgentBridgeTests {

    private static let mcpPath =
        "/Applications/Silicon Optimizer.app/Contents/Resources/bin/silicon-mcp"

    /// A throwaway home + Applications pair.
    private func makeEnvironment() throws -> AgentBridge.Environment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        return AgentBridge.Environment(
            home: home, applications: applications, mcpPath: Self.mcpPath)
    }

    private func cleanUp(_ env: AgentBridge.Environment) {
        try? FileManager.default.removeItem(at: env.home.deletingLastPathComponent())
    }

    // MARK: - Claude Desktop (JSON)

    @Test("connecting Claude Desktop creates the config from nothing")
    func claudeDesktopFresh() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }

        #expect(AgentBridge.claudeDesktopStatus(in: env) == .notConnected)
        try AgentBridge.connectClaudeDesktop(in: env)
        #expect(AgentBridge.claudeDesktopStatus(in: env) == .connected)

        let parsed = try JSONSerialization.jsonObject(
            with: Data(contentsOf: AgentBridge.claudeDesktopConfigURL(in: env))
        ) as? [String: Any]
        let entry = (parsed?["mcpServers"] as? [String: Any])?[AgentBridge.serverName]
            as? [String: Any]
        #expect(entry?["command"] as? String == Self.mcpPath)
    }

    @Test("connecting merges into an existing config instead of replacing it")
    func claudeDesktopMerges() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }

        let url = AgentBridge.claudeDesktopConfigURL(in: env)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "mcpServers": ["memories": ["command": "/usr/local/bin/memories"]],
            "theme": "dark",
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: url)

        try AgentBridge.connectClaudeDesktop(in: env)

        let parsed = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as? [String: Any]
        let servers = parsed?["mcpServers"] as? [String: Any]
        #expect((servers?["memories"] as? [String: Any])?["command"] as? String
                == "/usr/local/bin/memories")
        #expect(servers?[AgentBridge.serverName] != nil)
        #expect(parsed?["theme"] as? String == "dark")
    }

    @Test("an unparseable config is reported, never clobbered")
    func claudeDesktopRefusesGarbage() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }

        let url = AgentBridge.claudeDesktopConfigURL(in: env)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: url)

        #expect(throws: AgentBridge.BridgeError.self) {
            try AgentBridge.connectClaudeDesktop(in: env)
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{not json")
    }

    @Test("an entry pointing at an old copy reads as outdated, and Update repoints it")
    func claudeDesktopOutdated() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }

        let url = AgentBridge.claudeDesktopConfigURL(in: env)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing: [String: Any] = [
            "mcpServers": [AgentBridge.serverName: ["command": "/old/silicon-mcp"]]
        ]
        try JSONSerialization.data(withJSONObject: existing).write(to: url)

        #expect(AgentBridge.claudeDesktopStatus(in: env)
                == .outdated("/old/silicon-mcp"))
        try AgentBridge.connectClaudeDesktop(in: env)
        #expect(AgentBridge.claudeDesktopStatus(in: env) == .connected)
    }

    // MARK: - Codex (TOML)

    @Test("connecting Codex writes a fresh config with just our section")
    func codexFresh() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }

        try AgentBridge.connectCodex(in: env)
        #expect(AgentBridge.codexStatus(in: env) == .connected)

        let text = try String(
            contentsOf: AgentBridge.codexConfigURL(in: env), encoding: .utf8)
        #expect(text.contains("[mcp_servers.\(AgentBridge.serverName)]"))
        // The path carries a space; it must round-trip through the quoting.
        #expect(AgentBridge.codexCommand(inTOML: text) == Self.mcpPath)
    }

    @Test("connecting appends to an existing config without touching the rest")
    func codexAppends() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }

        let url = AgentBridge.codexConfigURL(in: env)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = """
        model = "gpt-5"

        [mcp_servers.other]
        command = "/usr/local/bin/other"
        """
        try existing.write(to: url, atomically: true, encoding: .utf8)

        try AgentBridge.connectCodex(in: env)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("model = \"gpt-5\""))
        #expect(text.contains("[mcp_servers.other]"))
        #expect(text.contains("command = \"/usr/local/bin/other\""))
        #expect(AgentBridge.codexStatus(in: env) == .connected)
    }

    @Test("an existing section gets its command replaced in place, other keys kept")
    func codexReplacesInPlace() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }

        let url = AgentBridge.codexConfigURL(in: env)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = """
        [mcp_servers.\(AgentBridge.serverName)]
        command = "/old/silicon-mcp"
        startup_timeout_ms = 20000

        [projects]
        trusted = true
        """
        try existing.write(to: url, atomically: true, encoding: .utf8)

        #expect(AgentBridge.codexStatus(in: env) == .outdated("/old/silicon-mcp"))
        try AgentBridge.connectCodex(in: env)

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(AgentBridge.codexStatus(in: env) == .connected)
        #expect(text.contains("startup_timeout_ms = 20000"))
        #expect(text.contains("[projects]"))
        #expect(!text.contains("/old/silicon-mcp"))

        // Running it again changes nothing.
        try AgentBridge.connectCodex(in: env)
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test("a quoted section header counts as ours")
    func codexQuotedHeader() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }

        let url = AgentBridge.codexConfigURL(in: env)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        [mcp_servers."\(AgentBridge.serverName)"]
        command = '\(Self.mcpPath)'
        """.write(to: url, atomically: true, encoding: .utf8)

        #expect(AgentBridge.codexStatus(in: env) == .connected)
    }

    // MARK: - Claude Code (read-only status; writes go through the CLI)

    @Test("the user-scope entry in ~/.claude.json reads as connected")
    func claudeCodeStatus() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }

        let config: [String: Any] = [
            "mcpServers": [AgentBridge.serverName: ["command": Self.mcpPath]],
            "numStartups": 412,
        ]
        try JSONSerialization.data(withJSONObject: config)
            .write(to: AgentBridge.claudeCodeConfigURL(in: env))

        #expect(AgentBridge.claudeCodeStatus(in: env) == .connected)
    }

    // MARK: - Detection

    @Test("nothing installed, nothing offered")
    func detectsNothing() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }
        #expect(AgentBridge.detect(in: env).isEmpty)
    }

    @Test("each assistant appears once its footprint exists")
    func detectsFootprints() throws {
        let env = try makeEnvironment()
        defer { cleanUp(env) }
        let files = FileManager.default

        try files.createDirectory(
            at: env.applications.appendingPathComponent("Claude.app"),
            withIntermediateDirectories: true)
        try files.createDirectory(
            at: env.home.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: AgentBridge.claudeCodeConfigURL(in: env))
        try files.createDirectory(
            at: env.applications.appendingPathComponent("ChatGPT.app"),
            withIntermediateDirectories: true)

        let rows = AgentBridge.detect(in: env)
        #expect(rows.map(\.client) == [.claudeDesktop, .claudeCode, .codex, .chatGPTDesktop])
        #expect(rows[0].status == .notConnected)
        #expect(rows[1].status == .notConnected)
        #expect(rows[2].status == .notConnected)
        if case .manualOnly = rows[3].status {} else {
            Issue.record("ChatGPT should be detect-only until it takes local tools")
        }
    }
}
