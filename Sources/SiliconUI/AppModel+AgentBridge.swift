import Foundation
import SiliconControl
import SiliconRuntime

/// The Settings-pane face of `AgentBridge`: find the AIs on this Mac, connect the
/// chosen one with a click, and keep a per-client note about what just happened.
extension AppModel {

    /// The live environment, or nil when this build carries no bridge binary
    /// (a bare `swift run` without the bundle step).
    var agentBridgeEnvironment: AgentBridge.Environment? {
        guard let mcpPath = CodexRuntime.locateMCPServer() else { return nil }
        return AgentBridge.Environment(
            home: FileManager.default.homeDirectoryForCurrentUser,
            applications: URL(fileURLWithPath: "/Applications", isDirectory: true),
            mcpPath: mcpPath)
    }

    func refreshAgentBridges() {
        guard let environment = agentBridgeEnvironment else {
            agentBridgeRows = []
            return
        }
        agentBridgeRows = AgentBridge.detect(in: environment)
    }

    func connectAgentBridge(_ client: AgentBridge.Client) async {
        guard let environment = agentBridgeEnvironment, agentBridgeBusy == nil else { return }
        agentBridgeBusy = client
        defer {
            agentBridgeBusy = nil
            refreshAgentBridges()
        }
        do {
            switch client {
            case .claudeDesktop:
                agentBridgeNotes[client.id] =
                    try AgentBridge.connectClaudeDesktop(in: environment)
            case .codex:
                agentBridgeNotes[client.id] =
                    try AgentBridge.connectCodex(in: environment)
            case .claudeCode:
                agentBridgeNotes[client.id] = try await connectClaudeCode(in: environment)
            case .chatGPTDesktop:
                break
            }
        } catch {
            agentBridgeNotes[client.id] = error.localizedDescription
        }
    }

    /// Claude Code owns ~/.claude.json and rewrites it while running, so the entry
    /// goes in through its own CLI rather than a raw file edit.
    private func connectClaudeCode(in environment: AgentBridge.Environment) async throws -> String {
        guard let cli = AgentBridge.claudeCLI(in: environment) else {
            throw AgentBridge.BridgeError.claudeCLIMissing(
                manualCommand: AgentBridge.claudeCodeManualCommand(in: environment))
        }
        // `add` refuses to overwrite, so clear any stale entry first; a missing
        // one makes this a harmless failure.
        _ = try? await Self.runBridgeCommand(
            cli, ["mcp", "remove", "--scope", "user", AgentBridge.serverName])
        let result = try await Self.runBridgeCommand(
            cli, ["mcp", "add", "--scope", "user", AgentBridge.serverName,
                  environment.mcpPath])
        guard result.status == 0 else {
            throw AgentBridge.BridgeError.commandFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return "Connected — every Claude Code session on this Mac gets the tools."
    }

    private struct BridgeCommandResult: Sendable {
        let status: Int32
        let output: String
    }

    private static func runBridgeCommand(
        _ executable: URL, _ arguments: [String]
    ) async throws -> BridgeCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: BridgeCommandResult(
                    status: finished.terminationStatus,
                    output: String(data: data, encoding: .utf8) ?? ""))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            // A wedged CLI must not pin the Connect button forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}
