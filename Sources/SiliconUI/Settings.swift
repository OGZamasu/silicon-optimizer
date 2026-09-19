import Foundation
import LocalAuthentication
import Security
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
    /// OpenAI's Codex agent, driven natively over its app-server protocol.
    case codex
    /// Qwen Code's `serve` daemon and its embedded Web Shell.
    case qwenCode
    /// earendil-works' Pi agent, driven natively over its RPC mode.
    case pi
    /// The built-in native chat, talking straight to the local server.
    case legacy
}

/// User preferences, persisted to `UserDefaults`.
/// A credential can still decode from an older settings document for migration, but its
/// encoded representation is always empty. The live value is persisted separately in Keychain.
@propertyWrapper
public struct KeychainCredential: Codable, Sendable, Equatable {
    public var wrappedValue: String
    fileprivate var needsAuthorization = false

    public init(wrappedValue: String) { self.wrappedValue = wrappedValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.wrappedValue = (try? container.decode(String.self)) ?? ""
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode("")
    }
}

enum CredentialReadResult: Equatable {
    case found(String)
    case missing
    case unavailable
}

private enum CredentialStore {
    private static let service = "dev.siliconoptimizer.credentials"
    private static let huggingFaceAccount = "hugging-face-access-token"
    private static let interactionLock = NSLock()

    static func huggingFaceToken(allowInteraction: Bool) -> CredentialReadResult {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        // The file-based login keychain ignores the SecItem no-UI attribute. Scope its
        // process-wide switch to this synchronous startup read, before app workers start,
        // and restore the prior value rather than unconditionally enabling prompts.
        var wasInteractionAllowed: DarwinBoolean = false
        if !allowInteraction {
            guard SecKeychainGetUserInteractionAllowed(&wasInteractionAllowed) == errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false) == errSecSuccess
            else { return .unavailable }
        }
        defer {
            if !allowInteraction {
                SecKeychainSetUserInteractionAllowed(wasInteractionAllowed.boolValue)
            }
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: huggingFaceAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowInteraction {
            // Cover the data-protection implementation as well as the legacy login one.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .unavailable }
        return .found(token)
    }

    @discardableResult
    static func setHuggingFaceToken(_ rawValue: String) -> Bool {
        interactionLock.lock()
        defer { interactionLock.unlock() }
        let token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: huggingFaceAccount,
        ]
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}

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

    /// Port of the model gateway — the loopback server that lists every model this app can
    /// reach and serves them to external harnesses. Stable because the harness plugin and
    /// Codex provider configs both carry its URL.
    public var gatewayPort: Int?

    /// Port the Qwen Code Web Shell binds; stable for the same reasons as the harness's.
    public var qwenWebPort: Int?

    /// Whether Fleet ledger entries keep short prompt/response excerpts alongside the
    /// metadata. Everything stays on this Mac either way; nil means yes.
    public var fleetPreviewsEnabled: Bool?

    /// Gateway model ids the user has switched off on the Swarm page: still installed,
    /// still startable from Models, but absent from the gateway and every engine picker.
    public var hiddenGatewayModels: [String]?

    /// Gateway ids of the remote models the user has switched *on*. An allow-list, not a
    /// hide-list: OpenRouter alone offers hundreds of models, and a picker that listed them
    /// all next to three local ones would bury the point of this app. Nil or empty means no
    /// cloud model appears anywhere, which is also what an unconfigured machine sees.
    public var enabledCloudModels: [String]?

    /// Remote *audio* model ids typed in by hand, one per line.
    ///
    /// The audio queue has no `/models` endpoint to ask, so its catalogue has to be written
    /// down — and a written-down list is out of date the moment a provider ships something.
    /// This is the escape hatch: GMI announced "Speech 2.8" while its own docs still said
    /// 2.6, and without this there would be no way to reach it.
    public var customCloudAudioModels: [String]?

    /// The gateway model id the Pi chat last used.
    public var piModel: String?
    /// Where image renders run: "auto" (strongest machine offering images — a capable
    /// node when one is ready, local otherwise), "local", or "node". Auto is the fix
    /// for the swarm member whose weak Mac rendered locally and looked broken.
    public var imageRenderLocation: String?

    // Codex engine
    /// The gateway model id the Codex chat last used.
    public var codexModel: String?
    /// The folder Codex works in. Empty means Codex remains stopped until one is chosen.
    public var codexWorkingDirectory: String?
    /// Codex approval policy wire value ("on-request", "untrusted", "never").
    /// Nil or unrecognized means on-request.
    public var codexApprovalPolicy: String?
    /// Codex sandbox wire value ("read-only", "workspace-write", "danger-full-access").
    /// Nil or unrecognized means read-only; write authority is an explicit choice.
    public var codexSandbox: String?

    /// Saved load-settings presets, applied from the advanced sheet.
    public var configurationPresets: [ConfigurationPreset] = []

    public var chatEngine: ChatEngine {
        get { chatEngineRaw.flatMap(ChatEngine.init(rawValue:)) ?? .harness }
        set { chatEngineRaw = newValue.rawValue }
    }

    // Credentials
    @KeychainCredential public var huggingFaceToken = ""
    /// Session-only: a saved credential needs an explicit user action before it can be read
    /// or migrated. Never encoded; routine preference saves must not prompt or erase it.
    public private(set) var huggingFaceTokenNeedsAuthorization: Bool {
        get { _huggingFaceToken.needsAuthorization }
        set { _huggingFaceToken.needsAuthorization = newValue }
    }

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
    /// images wants. The random suffix keeps two images produced in the same second from
    /// colliding — batches do that routinely. Eight hex characters, because four proved too few:
    /// a 64-image batch collided about one run in thirty (the birthday bound at 16^4), which
    /// surfaced as a flaky CI test before it could surface as a silently overwritten image.
    public static func imageFilename(
        extension fileExtension: String = "png",
        date: Date = Date(),
        uniqueSuffix: String = String(UUID().uuidString.prefix(8))
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "silicon-\(formatter.string(from: date))-\(uniqueSuffix).\(fileExtension)"
    }

    // Model library

    /// Where language-model downloads land. Empty means the app-managed default. The
    /// library index never moves with this — models downloaded to earlier locations stay
    /// listed and loadable, exactly like imported files.
    public var modelLibraryDirectory: String = ""

    public var resolvedModelLibraryDirectory: URL? {
        let configured = modelLibraryDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else { return nil }
        return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
    }

    /// Where the Python engines' own downloads (the Hugging Face cache) belong.
    ///
    /// The engines — MFLUX, mlx-audio, the music and sound-effect models — fetch their
    /// weights themselves and default to `~/.cache/huggingface` on the startup disk,
    /// silently ignoring the model-library choice above. 153 GB accumulated there once
    /// before anyone noticed the disk was full. When a library location is configured,
    /// every engine child process gets `HF_HOME` pointed here instead, so "save models
    /// to this drive" means all of them.
    public var resolvedEngineCacheDirectory: URL? {
        resolvedModelLibraryDirectory?.appendingPathComponent("Engine Cache")
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

    /// The tab the window was last on, so reopening lands where you left off.
    public var lastTab: String = ""

    /// Which panels of the Video tab are open. Only the clip composer to begin with — the
    /// rest of that tab is six panels of tools nobody needs all at once. Stored rather than
    /// held in the view so switching tabs, or quitting, keeps the arrangement someone chose.
    public var expandedVideoPanels: [String] = [VideoPanel.clip.rawValue]

    /// Port the live face camera serves its picture on. Fixed rather than ephemeral
    /// so an OBS source keeps working across restarts.
    public var faceCamPort: Int = 8791
    /// Port face tracking publishes its numbers on.
    public var trackerPort: Int = 8792
    /// Whether tracking is also sent out as VMC, for a rigged model elsewhere.
    public var sendVMC = false
    public var vmcHost: String = "127.0.0.1"
    /// The port VSeeFace and friends listen on by convention.
    public var vmcPort: Int = 39539

    /// Render Qwen chat with the "sharp" template — answers that lead with the
    /// answer, and fewer thinking tokens to get there. Off by default: it changes how
    /// a model replies, which is not a decision to make for someone silently.
    public var useSharpChatTemplate = false

    // Personas

    /// The characters this app can speak and perform as.
    public var personas: [Persona] = []
    public var selectedPersonaID: String = ""

    // Voice and video

    /// Where spoken audio is written. Empty means `~/Music/Silicon Optimizer`.
    public var voiceOutputDirectory: String = ""
    /// Where generated clips are written. Empty means `~/Movies/Silicon Optimizer`.
    public var videoOutputDirectory: String = ""

    public var resolvedVoiceOutputDirectory: URL {
        let configured = voiceOutputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
        return music?.appendingPathComponent("Silicon Optimizer")
            ?? FileManager.default.temporaryDirectory
    }

    public var resolvedVideoOutputDirectory: URL {
        let configured = videoOutputDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        return movies?.appendingPathComponent("Silicon Optimizer")
            ?? FileManager.default.temporaryDirectory
    }

    public var resolvedTrellisBaseDirectory: URL {
        let configured = trellisBaseDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: "/Volumes/T9/trellis2")
    }

    /// Base name for one generation's files — same chronological-sort and suffix-width
    /// reasoning as `imageFilename`.
    public static func meshBaseName(
        date: Date = Date(),
        uniqueSuffix: String = String(UUID().uuidString.prefix(8))
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "silicon3d-\(formatter.string(from: date))-\(uniqueSuffix)"
    }

    // Swarm

    /// Whether the control server also listens on the LAN (port 8788) so swarm peers can
    /// reach this Mac. Ignored — the server stays loopback — unless swarm.json holds a
    /// token, because the jobs API is remote execution.
    public var exposeControlOnLAN = false

    // Runtime overrides
    public var llamaServerPath: String = ""
    public var mlxServerPath: String = ""
    /// A PrismML fork build of your own; empty means the app fetches one when needed.
    public var prismServerPath: String = ""

    public var customRuntimePaths: [RuntimeKind: URL] {
        var paths: [RuntimeKind: URL] = [:]
        if !llamaServerPath.isEmpty {
            paths[.llamaCpp] = URL(fileURLWithPath: llamaServerPath)
        }
        if !mlxServerPath.isEmpty {
            paths[.mlx] = URL(fileURLWithPath: mlxServerPath)
        }
        if !prismServerPath.isEmpty {
            paths[.llamaCppPrism] = URL(fileURLWithPath: prismServerPath)
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

        // Deliberately non-throwing. A key that fails to decode costs that one key,
        // never the file: this helper used to propagate, so a single stored value the
        // decoder could not read took every other setting down with it and the next
        // save wrote the defaults over the lot — model library, output folders, tokens,
        // characters, all of it. One bad field is a bad field; it is not a reset.
        func value<T: Decodable>(_ key: CodingKeys, _ default: T) -> T {
            (try? container.decode(T.self, forKey: key)) ?? `default`
        }

        temperature = value(.temperature, fallback.temperature)
        topP = value(.topP, fallback.topP)
        maxTokens = value(.maxTokens, fallback.maxTokens)
        reasoningEffort = value(.reasoningEffort, fallback.reasoningEffort)
        launchAtLogin = value(.launchAtLogin, fallback.launchAtLogin)
        unloadWhenIdle = value(.unloadWhenIdle, fallback.unloadWhenIdle)
        idleUnloadMinutes = value(.idleUnloadMinutes, fallback.idleUnloadMinutes)
        showAdvancedControls = value(.showAdvancedControls, fallback.showAdvancedControls)
        measuredSSDReadMBps = try? container.decodeIfPresent(
            Double.self, forKey: .measuredSSDReadMBps
        )
        measuredSSDVolumeID = try? container.decodeIfPresent(
            String.self, forKey: .measuredSSDVolumeID
        )
        speedCalibrations = value(.speedCalibrations, fallback.speedCalibrations)
        huggingFaceToken = value(.huggingFaceToken, fallback.huggingFaceToken)
        imageOutputDirectory = value(.imageOutputDirectory, fallback.imageOutputDirectory)
        meshOutputDirectory = value(.meshOutputDirectory, fallback.meshOutputDirectory)
        voiceOutputDirectory = value(.voiceOutputDirectory, fallback.voiceOutputDirectory)
        videoOutputDirectory = value(.videoOutputDirectory, fallback.videoOutputDirectory)
        lastTab = value(.lastTab, fallback.lastTab)
        expandedVideoPanels = value(.expandedVideoPanels, fallback.expandedVideoPanels)
        faceCamPort = value(.faceCamPort, fallback.faceCamPort)
        useSharpChatTemplate = value(.useSharpChatTemplate, fallback.useSharpChatTemplate)
        trackerPort = value(.trackerPort, fallback.trackerPort)
        sendVMC = value(.sendVMC, fallback.sendVMC)
        vmcHost = value(.vmcHost, fallback.vmcHost)
        vmcPort = value(.vmcPort, fallback.vmcPort)
        personas = value(.personas, fallback.personas)
        selectedPersonaID = value(.selectedPersonaID, fallback.selectedPersonaID)
        modelLibraryDirectory = value(
            .modelLibraryDirectory, fallback.modelLibraryDirectory
        )
        trellisBaseDirectory = value(.trellisBaseDirectory, fallback.trellisBaseDirectory)
        lato2ServiceURL = value(.lato2ServiceURL, fallback.lato2ServiceURL)
        exposeControlOnLAN = value(.exposeControlOnLAN, fallback.exposeControlOnLAN)
        lastExternalModelDirectory = value(
            .lastExternalModelDirectory, fallback.lastExternalModelDirectory
        )
        llamaServerPath = value(.llamaServerPath, fallback.llamaServerPath)
        mlxServerPath = value(.mlxServerPath, fallback.mlxServerPath)
        prismServerPath = value(.prismServerPath, fallback.prismServerPath)
        chatEngineRaw = try? container.decodeIfPresent(String.self, forKey: .chatEngineRaw)
        harnessWebPort = try? container.decodeIfPresent(Int.self, forKey: .harnessWebPort)
        harnessInferencePort = try? container.decodeIfPresent(
            Int.self, forKey: .harnessInferencePort
        )
        nodeBinaryPath = try? container.decodeIfPresent(String.self, forKey: .nodeBinaryPath)
        gatewayPort = try? container.decodeIfPresent(Int.self, forKey: .gatewayPort)
        qwenWebPort = try? container.decodeIfPresent(Int.self, forKey: .qwenWebPort)
        fleetPreviewsEnabled = try? container.decodeIfPresent(
            Bool.self, forKey: .fleetPreviewsEnabled
        )
        hiddenGatewayModels = try? container.decodeIfPresent(
            [String].self, forKey: .hiddenGatewayModels
        )
        enabledCloudModels = try? container.decodeIfPresent(
            [String].self, forKey: .enabledCloudModels
        )
        customCloudAudioModels = try? container.decodeIfPresent(
            [String].self, forKey: .customCloudAudioModels
        )
        piModel = try? container.decodeIfPresent(String.self, forKey: .piModel)
        imageRenderLocation = try? container.decodeIfPresent(
            String.self, forKey: .imageRenderLocation)
        codexModel = try? container.decodeIfPresent(String.self, forKey: .codexModel)
        codexWorkingDirectory = try? container.decodeIfPresent(
            String.self, forKey: .codexWorkingDirectory
        )
        codexApprovalPolicy = try? container.decodeIfPresent(
            String.self, forKey: .codexApprovalPolicy
        )
        codexSandbox = try? container.decodeIfPresent(String.self, forKey: .codexSandbox)
        configurationPresets = value(.configurationPresets, fallback.configurationPresets)
    }

    // MARK: - Persistence

    private static let defaultsKey = "dev.siliconoptimizer.settings"

    public static func load() -> Settings {
        load(defaults: .standard, readCredential: CredentialStore.huggingFaceToken)
    }

    /// Dependencies are injected in persistence tests so they never touch the user's Keychain.
    static func load(
        defaults: UserDefaults,
        readCredential: (Bool) -> CredentialReadResult
    ) -> Settings {
        let data = defaults.data(forKey: defaultsKey)
        var settings = data.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) }
            ?? Settings()
        switch readCredential(false) {
        case .found(let token):
            settings.huggingFaceToken = token
            // A successful read proves the secure copy is durable; any old plaintext copy
            // can now be removed without prompting or rewriting the Keychain item.
            if let legacy = legacyCredential(in: defaults), !legacy.isEmpty {
                settings.save(defaults: defaults, preserveLegacyCredential: false)
            }
        case .missing:
            // Old versions stored the token in preferences. Keep it until the user explicitly
            // saves it to Keychain; launch must never start a migration authorization dialog.
            settings.huggingFaceTokenNeedsAuthorization = !settings.huggingFaceToken.isEmpty
        case .unavailable:
            // Locked, denied, and changed-signature cases are not an absent credential.
            settings.huggingFaceTokenNeedsAuthorization = true
        }
        return settings
    }

    /// Persists preferences only. A tab change, port allocation, or text edit must never
    /// access Keychain. New credentials are stored only by the explicit Settings action.
    @discardableResult
    public func save() -> Bool {
        save(defaults: .standard)
    }

    @discardableResult
    func save(defaults: UserDefaults, preserveLegacyCredential: Bool = true) -> Bool {
        guard let encoded = try? JSONEncoder().encode(self) else { return false }
        var data = encoded
        if preserveLegacyCredential, let legacy = Self.legacyCredential(in: defaults),
           !legacy.isEmpty {
            // Preserve only the pre-existing migration source, never an in-memory new token.
            // Denying Keychain access must not make an unrelated save erase the only copy.
            guard var document = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            else { return false }
            document["huggingFaceToken"] = legacy
            guard let preserved = try? JSONSerialization.data(withJSONObject: document)
            else { return false }
            data = preserved
        }
        defaults.set(data, forKey: Self.defaultsKey)
        return true
    }

    private static func legacyCredential(in defaults: UserDefaults) -> String? {
        guard let data = defaults.data(forKey: defaultsKey),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return document["huggingFaceToken"] as? String
    }

    /// Called only by Save token / Remove token, never the form's general autosave.
    @discardableResult
    mutating func saveHuggingFaceToken(
        _ value: String,
        defaults: UserDefaults = .standard,
        writeCredential: (String) -> Bool = CredentialStore.setHuggingFaceToken
    ) -> Bool {
        let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = self
        candidate.huggingFaceToken = token
        candidate.huggingFaceTokenNeedsAuthorization = false
        // Validate serialization before committing the credential, so a failure cannot
        // replace the Keychain item while the UI reports that the previous token was kept.
        guard let data = try? JSONEncoder().encode(candidate) else { return false }
        guard writeCredential(token) else { return false }
        defaults.set(data, forKey: Self.defaultsKey)
        self = candidate
        return true
    }

    /// The user has explicitly asked macOS to allow access to the saved token.
    @discardableResult
    mutating func authorizeHuggingFaceToken(
        defaults: UserDefaults = .standard,
        readCredential: (Bool) -> CredentialReadResult = CredentialStore.huggingFaceToken,
        writeCredential: (String) -> Bool = CredentialStore.setHuggingFaceToken
    ) -> Bool {
        switch readCredential(true) {
        case .found(let token):
            var candidate = self
            candidate.huggingFaceToken = token
            candidate.huggingFaceTokenNeedsAuthorization = false
            guard candidate.save(defaults: defaults, preserveLegacyCredential: false) else { return false }
            self = candidate
            return true
        case .missing:
            if let legacy = Self.legacyCredential(in: defaults), !legacy.isEmpty {
                return saveHuggingFaceToken(legacy, defaults: defaults, writeCredential: writeCredential)
            }
            var candidate = self
            candidate.huggingFaceToken = ""
            candidate.huggingFaceTokenNeedsAuthorization = false
            guard candidate.save(defaults: defaults, preserveLegacyCredential: false) else { return false }
            self = candidate
            return true
        case .unavailable:
            return false
        }
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
