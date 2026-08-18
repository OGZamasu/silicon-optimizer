import Foundation
import ServiceManagement
import SiliconCore
import SiliconPlanner
import SiliconRuntime

/// A named, reusable set of load settings — context, cache precision, batches, expert slots
/// and extra flags — so a combination that took tuning can be applied again with one click.
public struct ConfigurationPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var configuration: LoadConfiguration
    public var extraArguments: String

    public init(
        id: UUID = UUID(), name: String,
        configuration: LoadConfiguration, extraArguments: String
    ) {
        self.id = id
        self.name = name
        self.configuration = configuration
        self.extraArguments = extraArguments
    }

    /// The stored knobs, laid over the current machine's own facts: the thread count and GPU
    /// fraction stay whatever the planner chose here, and expert streaming only survives onto
    /// a model that has experts to stream.
    public func applied(to base: LoadConfiguration, isMoE: Bool) -> LoadConfiguration {
        var result = configuration
        result.threads = base.threads
        result.gpuLayerFraction = base.gpuLayerFraction
        if !isMoE { result.expertStreaming = nil }
        return result
    }
}

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

    /// Saved load-settings presets, applied from the advanced sheet.
    public var configurationPresets: [ConfigurationPreset] = []

    public var chatEngine: ChatEngine {
        get { chatEngineRaw.flatMap(ChatEngine.init(rawValue:)) ?? .harness }
        set { chatEngineRaw = newValue.rawValue }
    }

    // Credentials
    public var huggingFaceToken = ""

    // Output

    /// Where generated images are written. Empty means the default below.
    public var imageOutputDirectory: String = ""

    /// Last external folder chosen to save a downloaded model to. Only pre-fills the folder
    /// picker for next time — it doesn't redirect anything by itself, since which models go
    /// where is chosen per download, not as a standing default.
    public var lastExternalModelDirectory: String = ""

    /// The directory images are actually written to.
    ///
    /// Defaults to `~/Pictures/Silicon Optimizer`. Generation previously wrote into
    /// `FileManager.temporaryDirectory`, which resolves to a per-boot path under `/var/folders`
    /// that no one can navigate to from Finder and that macOS is free to purge — so an image that
    /// took minutes to produce was both hard to find and not safe to leave there.
    public var resolvedImageOutputDirectory: URL {
        let configured = imageOutputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        return Self.defaultImageOutputDirectory
    }

    public static var defaultImageOutputDirectory: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        return pictures?.appendingPathComponent("Silicon Optimizer")
            ?? FileManager.default.temporaryDirectory
    }

    /// Filename for a generated image.
    ///
    /// Sorts chronologically in Finder, which is the order anyone browsing a folder of generated
    /// images wants. The short random suffix keeps two images produced in the same second from
    /// colliding — batches do that routinely.
    public static func imageFilename(
        extension fileExtension: String = "png",
        date: Date = Date(),
        uniqueSuffix: String = String(UUID().uuidString.prefix(4))
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "silicon-\(formatter.string(from: date))-\(uniqueSuffix).\(fileExtension)"
    }

    // 3D toolkit

    /// Where generated meshes are written. Empty means the default below.
    public var meshOutputDirectory: String = ""
    /// The trellis2 project folder holding trellis-mac and hunyuan3d-swift. Empty means the
    /// T9 default the engines were set up at.
    public var trellisBaseDirectory: String = ""
    /// Base URL of the remote LATO.2 service, e.g. "http://192.168.1.20:8790". Empty means
    /// not configured.
    public var lato2ServiceURL: String = ""

    /// Each generation gets its own folder under here — a mesh is several files (GLB, OBJ,
    /// textures) and mixing jobs in one directory would interleave them.
    public var resolvedMeshOutputDirectory: URL {
        let configured = meshOutputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        return Self.defaultMeshOutputDirectory
    }

    public static var defaultMeshOutputDirectory: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first
        return documents?.appendingPathComponent("Silicon Optimizer 3D")
            ?? FileManager.default.temporaryDirectory
    }

    public var resolvedTrellisBaseDirectory: URL {
        let configured = trellisBaseDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: "/Volumes/T9/trellis2")
    }

    /// Base name for one generation's files — same chronological-sort idea as images.
    public static func meshBaseName(
        date: Date = Date(),
        uniqueSuffix: String = String(UUID().uuidString.prefix(4))
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "silicon3d-\(formatter.string(from: date))-\(uniqueSuffix)"
    }

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

    // MARK: - Decoding

    /// Decoded key by key, defaulting anything absent.
    ///
    /// The synthesized decoder throws on a missing key even where the property has a default, so
    /// settings written by an earlier build fail to decode the moment a field is added here.
    /// `load()` swallows that and returns defaults, which reads to the user as the app having
    /// silently forgotten everything — their token included — on upgrade. Decoding leniently
    /// makes adding a field a non-event, which is the only way it is safe to keep doing.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Settings()

        func value<T: Decodable>(_ key: CodingKeys, _ default: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? `default`
        }

        temperature = try value(.temperature, fallback.temperature)
        topP = try value(.topP, fallback.topP)
        maxTokens = try value(.maxTokens, fallback.maxTokens)
        reasoningEffort = try value(.reasoningEffort, fallback.reasoningEffort)
        launchAtLogin = try value(.launchAtLogin, fallback.launchAtLogin)
        unloadWhenIdle = try value(.unloadWhenIdle, fallback.unloadWhenIdle)
        idleUnloadMinutes = try value(.idleUnloadMinutes, fallback.idleUnloadMinutes)
        showAdvancedControls = try value(.showAdvancedControls, fallback.showAdvancedControls)
        measuredSSDReadMBps = try container.decodeIfPresent(
            Double.self, forKey: .measuredSSDReadMBps
        )
        measuredSSDVolumeID = try container.decodeIfPresent(
            String.self, forKey: .measuredSSDVolumeID
        )
        speedCalibrations = try value(.speedCalibrations, fallback.speedCalibrations)
        huggingFaceToken = try value(.huggingFaceToken, fallback.huggingFaceToken)
        imageOutputDirectory = try value(.imageOutputDirectory, fallback.imageOutputDirectory)
        meshOutputDirectory = try value(.meshOutputDirectory, fallback.meshOutputDirectory)
        trellisBaseDirectory = try value(.trellisBaseDirectory, fallback.trellisBaseDirectory)
        lato2ServiceURL = try value(.lato2ServiceURL, fallback.lato2ServiceURL)
        lastExternalModelDirectory = try value(
            .lastExternalModelDirectory, fallback.lastExternalModelDirectory
        )
        llamaServerPath = try value(.llamaServerPath, fallback.llamaServerPath)
        mlxServerPath = try value(.mlxServerPath, fallback.mlxServerPath)
        chatEngineRaw = try container.decodeIfPresent(String.self, forKey: .chatEngineRaw)
        harnessWebPort = try container.decodeIfPresent(Int.self, forKey: .harnessWebPort)
        harnessInferencePort = try container.decodeIfPresent(
            Int.self, forKey: .harnessInferencePort
        )
        nodeBinaryPath = try container.decodeIfPresent(String.self, forKey: .nodeBinaryPath)
        configurationPresets = try value(.configurationPresets, fallback.configurationPresets)
    }

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
