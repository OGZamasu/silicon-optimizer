import AppKit
import Foundation
import SiliconControl
import SiliconRuntime

/// Lifecycle of the Qwen Code sidecar behind the Chat tab — the third engine, embedded
/// the same way the DeepSeek Harness is: lazy start on first show, torn down on engine
/// change, killed with the app.
extension AppModel {

    /// The Web Shell's stable port, persisted like the harness's for the same reason:
    /// the embedded page's address should not drift between launches.
    func qwenPorts() -> Int {
        if let resolved = resolvedQwenPort { return resolved }
        var port = settings.qwenWebPort ?? 0
        if port == 0 || !HarnessRuntime.isPortFree(port) {
            port = HarnessRuntime.allocatePort()
        }
        if settings.qwenWebPort != port {
            settings.qwenWebPort = port
            settings.save()
        }
        resolvedQwenPort = port
        return port
    }

    public func startQwenIfNeeded() {
        switch qwenState {
        case .ready, .starting: return
        case .idle, .failed, .stopping: break
        }

        let runtime = qwenRuntime ?? QwenCodeRuntime()
        qwenRuntime = runtime
        qwenState = .starting(stage: "Looking for Node.js…")
        registerQwenTermination()
        // Warm the swarm view so node models make the generated settings.
        Task { await refreshSwarm() }

        let webPort = qwenPorts()
        let gateway = gatewayPort()
        // Every gateway model becomes a provider entry in the generated settings, so the
        // Web Shell's model picker lists this Mac and the swarm alike. Written at start;
        // models that appear later arrive on the next restart.
        let snapshot = gatewayModelSnapshot()
        let models = snapshot.map {
            QwenCodeRuntime.ModelEntry(id: $0.id, name: $0.displayName)
        }
        let defaultModel = snapshot.first(where: \.serving)?.id
            ?? snapshot.first?.id ?? "local/none"
        let nodePath = settings.nodeBinaryPath ?? ""
        Task {
            await runtime.start(
                webPort: webPort, gatewayPort: gateway, models: models,
                defaultModel: defaultModel, nodePath: nodePath
            ) { [weak self] state in
                Task { @MainActor in self?.qwenState = state }
            }
            let pid = await runtime.processIdentifier
            await MainActor.run { [weak self] in self?.qwenProcessID = pid }
        }
    }

    public func stopQwen() {
        guard let runtime = qwenRuntime else { return }
        qwenState = .stopping
        qwenProcessID = nil
        Task {
            await runtime.stop()
            await MainActor.run { [weak self] in self?.qwenState = .idle }
        }
    }

    public func restartQwen() {
        guard let runtime = qwenRuntime else { return startQwenIfNeeded() }
        qwenState = .stopping
        qwenProcessID = nil
        Task {
            await runtime.stop()
            await MainActor.run { [weak self] in
                self?.qwenState = .idle
                self?.startQwenIfNeeded()
            }
        }
    }

    /// Same synchronous-signal pattern as the other sidecars, for the same reason.
    private func registerQwenTermination() {
        guard !qwenTerminationRegistered else { return }
        qwenTerminationRegistered = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if let pid = self?.qwenProcessID {
                    kill(pid, SIGTERM)
                }
            }
        }
    }
}
