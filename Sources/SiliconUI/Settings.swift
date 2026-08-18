import Foundation
import ServiceManagement
import SiliconCore
import SiliconRuntime

/// Which implementation serves the Chat tab.
public enum ChatEngine: String, Codable, Sendable, CaseIterable {
    /// The DeepSeek Harness web UI: an agent with tools, web fetch and search.
    case harness
    /// The built-in native chat, talking straight to the local server.
    case legacy
}

/// User preferences, persisted to `UserDefaults`.
public struct Settings: Codable, Sendable, Equatable {

    // Generation
    public var temperature: Double = 0.7
    public var topP: Double = 0.95
    public var maxTokens: Int = 0                  // 0 means no explicit limit
    public var reasoningEffort: String = ""        // "low" / "medium" / "high" for gpt-oss

    // Behaviour
    public var launchAtLogin = false
    public var unloadWhenIdle = true
    public var idleUnloadMinutes = 30
    public var showAdvancedControls = false

    /// Sequential read throughput of the volume holding the model library, in MB/s.
    ///
    /// Cached because measuring it writes and reads a few hundred megabytes; re-measured only
    /// on request, or when the library moves to a different volume.
    public var measuredSSDReadMBps: Double?
    /// Volume the measurement was taken on, so moving the library to an external disk
    /// invalidates a figure that no longer describes it.
    public var measuredSSDVolumeID: String?

    /// Speed-estimate corrections learned from benchmarks, keyed by catalog model id.
    ///
    /// Deliberately per-model rather than one number for the machine. Architectures differ in
    /// how close they get to peak — a dense 7B reached 46% above the physical estimate while a
    /// 30B mixture-of-experts matched it exactly — so a single global factor learned from one
    /// model actively corrupts predictions for every other one.
    public var speedCalibrations: [String: Double] = [:]

    // Chat engine
    //
    // The new fields are optionals so that settings saved by an older build — whose JSON
    // lacks these keys — still decode instead of silently resetting everything to defaults.

    /// Raw storage for `chatEngine`; nil means the default.
    public var chatEngineRaw: String?
    /// Port the harness web UI binds. Chosen once and persisted so harness state, sessions
    /// and the embedded page all keep their addresses across launches.
    public var harnessWebPort: Int?
    /// Port the local inference server binds, which the harness's provider entry points at.
    /// Stable for the same reason: the generated provider config should never go stale.
    public var harnessInferencePort: Int?
    /// Manual Node.js path for setups the automatic search cannot see.
    public var nodeBinaryPath: String?

    public var chatEngine: ChatEngine {
        get { chatEngineRaw.flatMap(ChatEngine.init(rawValue:)) ?? .harness }
        set { chatEngineRaw = newValue.rawValue }
    }

    // Credentials
    public var huggingFaceToken = ""

    // Runtime overrides
    public var llamaServerPath: String = ""
    public var mlxServerPath: String = ""

    public var customRuntimePaths: [RuntimeKind: URL] {
        var paths: [RuntimeKind: URL] = [:]
        if !llamaServerPath.isEmpty {
            paths[.llamaCpp] = URL(fileURLWithPath: llamaServerPath)
        }
        if !mlxServerPath.isEmpty {
            paths[.mlx] = URL(fileURLWithPath: mlxServerPath)
        }
        return paths
    }

    public init() {}

    // MARK: - Persistence

    private static let defaultsKey = "dev.siliconoptimizer.settings"

    public static func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return settings
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    /// Registers or removes the login item to match `launchAtLogin`.
    ///
    /// `SMAppService` reflects the real system state, which the user can change in System
    /// Settings behind our back, so this reconciles rather than assuming our stored flag wins.
    public func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            switch (launchAtLogin, service.status) {
            case (true, .enabled), (false, .notRegistered), (false, .notFound):
                break                      // already in the requested state
            case (true, _):
                try service.register()
            case (false, _):
                try service.unregister()
            }
        } catch {
            // Not worth interrupting the user: the toggle simply will not stick, and the
            // reconciliation above will retry on the next change.
        }
    }
}
