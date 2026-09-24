import Foundation
import Security
import ServiceManagement
import os
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

/// A credential kept in the Keychain rather than in the settings document.
///
/// The document only ever carries a placeholder for it: an empty string, or a plaintext copy
/// an older build stored there before the Keychain held it. Whether the value is still that
/// placeholder, or has since been replaced by the Keychain's answer, is what `isResolved` says.
@propertyWrapper
public struct KeychainCredential: Codable, Sendable, Equatable {
    private var value: String

    /// True once the value is authoritative: read from the Keychain, or assigned since.
    ///
    /// A decoded or default credential is only a placeholder, and `Settings.save()` leaves the
    /// Keychain alone rather than write it there — pushing an empty placeholder would delete
    /// the token the user stored. Assignment resolves the value, because a token the user
    /// typed is the one to keep.
    public private(set) var isResolved: Bool

    public var wrappedValue: String {
        get { value }
        set {
            value = newValue
            isResolved = true
        }
    }

    /// A placeholder. The `= ""` on the declaration arrives here.
    public init(wrappedValue: String) {
        value = wrappedValue
        isResolved = false
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = (try? container.decode(String.self)) ?? ""
        isResolved = false
    }

    /// A resolved credential encodes as empty: the Keychain holds it. An unresolved one keeps
    /// whatever the document had, so a legacy plaintext copy survives every save until the
    /// Keychain has confirmed it holds the token and the next save redacts it.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isResolved ? "" : value)
    }

    /// Equality is by value. Resolution is bookkeeping about the Keychain, not a setting.
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.value == rhs.value }
}

/// How a Keychain read ended.
enum KeychainReadResult: Sendable, Equatable {
    case found(String)
    case absent
    /// The Keychain would not answer — locked, or its consent dialog dismissed — so nothing is
    /// known about the credential, and nothing must be written over it.
    case unavailable(OSStatus)
}

/// The two Keychain calls behind `CredentialStore`, as a value so tests can substitute an
/// in-memory store and see exactly which code paths reach for the real one.
///
/// The real one, `.keychain`, can block on a consent dialog: a freshly built app has a new
/// code identity, and macOS asks the user before handing it a token an earlier build stored.
/// That is why nothing on the launch path may call it.
struct KeychainAccess: Sendable {
    var readHuggingFaceToken: @Sendable () -> KeychainReadResult
    /// Stores the token, or deletes the item when the token is empty.
    var writeHuggingFaceToken: @Sendable (String) -> Bool

    private static let service = "dev.siliconoptimizer.credentials"
    private static let huggingFaceAccount = "hugging-face-access-token"

    static let keychain = KeychainAccess(
        readHuggingFaceToken: {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: huggingFaceAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            switch status {
            case errSecSuccess:
                guard let data = result as? Data,
                      let token = String(data: data, encoding: .utf8), !token.isEmpty
                else { return .absent }
                return .found(token)
            case errSecItemNotFound:
                return .absent
            default:
                return .unavailable(status)
            }
        },
        writeHuggingFaceToken: { token in
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
    )
}

enum CredentialStore {
    private static let access = OSAllocatedUnfairLock(initialState: KeychainAccess.keychain)

    /// Blocking, and possibly for a long time: see `KeychainAccess`.
    static func readHuggingFaceToken() -> KeychainReadResult {
        // The call runs outside the lock; it can sit behind the consent dialog indefinitely.
        access.withLock { $0 }.readHuggingFaceToken()
    }

    @discardableResult
    static func setHuggingFaceToken(_ rawValue: String) -> Bool {
        let token = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return access.withLock { $0 }.writeHuggingFaceToken(token)
    }

    /// Testing seam: swaps the Keychain for `replacement` and hands back what was there, for
    /// the caller to restore.
    @discardableResult
    static func replaceAccess(with replacement: KeychainAccess) -> KeychainAccess {
        access.withLock { current in
            defer { current = replacement }
            return current
        }
    }
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

    /// Lives in the Keychain; the document only carries a placeholder. `load()` leaves it
    /// there, and `resolveHuggingFaceToken(migrating:)` fetches it off the main thread.
    @KeychainCredential public var huggingFaceToken = ""

    /// Whether `huggingFaceToken` is the Keychain's answer, or a value assigned since, rather
    /// than the placeholder `load()` leaves behind.
    public var isHuggingFaceTokenResolved: Bool { _huggingFaceToken.isResolved }

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
    /// The trellis2 project folder holding trellis-mac and hunyuan3d-swift. Empty until set
    /// here or found on this Mac — see `AppModel.trellisBaseDirectory`.
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

    /// The folder set in `trellisBaseDirectory`, or nil while none is.
    public var configuredTrellisBaseDirectory: URL? {
        let configured = trellisBaseDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !configured.isEmpty else { return nil }
        return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
    }

    /// The engines found on this Mac as it is right now, without touching Settings.
    public static func discoverTrellisBaseDirectory() -> URL? {
        trellisBaseDirectory(
            home: FileManager.default.homeDirectoryForCurrentUser, disks: localDiskRoots()
        )
    }

    /// A `trellis2` folder with an engine in it — `trellis-mac` or `hunyuan3d-swift` — at the
    /// top of `home` or of one of `disks`. The home folder's comes first. Among disks, only one
    /// that is alone in having one: choosing between two would be a guess, and the choice is
    /// written into Settings and kept.
    static func trellisBaseDirectory(home: URL, disks: [URL]) -> URL? {
        func engines(under root: URL) -> URL? {
            let base = root.appendingPathComponent("trellis2", isDirectory: true)
            let holdsEngine = ["trellis-mac", "hunyuan3d-swift"].contains { engine in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(
                    atPath: base.appendingPathComponent(engine).path, isDirectory: &isDirectory
                ) && isDirectory.boolValue
            }
            return holdsEngine ? base : nil
        }
        if let found = engines(under: home) { return found }
        let found = disks.compactMap(engines(under:))
        return found.count == 1 ? found[0] : nil
    }

    /// The disks engines may be set up on, read from the mount table without waiting on any
    /// of them, so a network share that has gone away cannot stall the lookup.
    static func localDiskRoots() -> [URL] {
        let capacity = getfsstat(nil, 0, MNT_NOWAIT)
        guard capacity > 0 else { return [] }
        var table: [statfs] = Array(repeating: .init(), count: Int(capacity))
        let count = getfsstat(
            &table, Int32(MemoryLayout<statfs>.stride * table.count), MNT_NOWAIT
        )
        guard count > 0 else { return [] }
        let mounts = table.prefix(Int(count)).map { mount in
            Mount(
                path: withUnsafeBytes(of: mount.f_mntonname) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                },
                flags: mount.f_flags
            )
        }
        return diskRoots(in: mounts)
    }

    struct Mount: Equatable {
        var path: String
        var flags: UInt32
    }

    /// Local disks under /Volumes that could hold a working engine tree. Not a read-only mount
    /// (the engines write their venv and build there), not a quarantined one (a downloaded
    /// disk image, whose programs the app would otherwise run), and not one hidden from the
    /// Finder (system and backup volumes).
    static func diskRoots(in mounts: [Mount]) -> [URL] {
        let unusable = UInt32(MNT_RDONLY | MNT_QUARANTINE | MNT_DONTBROWSE)
        return mounts
            .filter {
                $0.flags & UInt32(MNT_LOCAL) != 0 && $0.flags & unusable == 0
                    && $0.path.hasPrefix("/Volumes/")
            }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
            .sorted { $0.path < $1.path }
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

    /// Whether the control server also listens on this Mac's tailscale address (port 8788)
    /// so swarm peers can reach it. Ignored — the server stays loopback — unless swarm.json
    /// holds a token, because the jobs API is remote execution, and unless this Mac is on a
    /// tailnet, because there is no other interface it will bind.
    ///
    /// The name is the stored key, and it predates the decision that the swarm is
    /// tailnet-only; renaming it would silently turn the setting off for everyone who
    /// already has it on.
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
        _huggingFaceToken = value(.huggingFaceToken, fallback._huggingFaceToken)
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

    static let defaultsKey = "dev.siliconoptimizer.settings"

    /// The saved preferences, with the credential still a placeholder.
    ///
    /// Deliberately never touches the Keychain. This runs on the main thread at launch, and a
    /// Keychain read can block on the consent dialog every freshly built app gets: while it
    /// was here, nothing came up behind it — no window, no control server, no handshake file,
    /// so the bundled MCP reported the app not running until the dialog was answered. The
    /// token arrives through `resolveHuggingFaceToken(migrating:)`, off the main thread; until
    /// then `huggingFaceToken` is what the document holds: empty, or a plaintext copy from
    /// before the Keychain kept it.
    public static func load() -> Settings {
        let data = UserDefaults.standard.data(forKey: defaultsKey)
        return data.flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    /// What the Keychain said about the Hugging Face token.
    public enum HuggingFaceTokenResolution: Sendable, Equatable {
        /// The credential is settled: this is the token, empty when none is stored.
        case token(String)
        /// The Keychain would not answer — locked, or its consent dialog dismissed. The
        /// credential stays as it was, so a bad moment cannot lose anything that was stored.
        case unavailable
    }

    /// Consults the Keychain for the Hugging Face token, moving `legacyToken` — a plaintext
    /// copy an older build kept in the settings document — into it when the Keychain has none.
    ///
    /// Blocking, and on a fresh build blocked behind the consent dialog: call it off the main
    /// thread, never at launch. `AppModel.loadHuggingFaceToken()` does; `load()` does not.
    public static func resolveHuggingFaceToken(
        migrating legacyToken: String
    ) -> HuggingFaceTokenResolution {
        let legacy = legacyToken.trimmingCharacters(in: .whitespacesAndNewlines)
        switch CredentialStore.readHuggingFaceToken() {
        case .found(let token):
            return .token(token)
        case .absent:
            guard !legacy.isEmpty else { return .token("") }
            // The document holds the only copy, and keeps it — `save()` leaves an unresolved
            // credential in the document — until the Keychain has taken it.
            return CredentialStore.setHuggingFaceToken(legacy) ? .token(legacy) : .unavailable
        case .unavailable:
            return .unavailable
        }
    }

    /// Returns false without rewriting preferences when secure credential persistence fails.
    /// Existing fire-and-forget callers keep their previous durable settings instead of
    /// silently replacing them with a redacted credential.
    @discardableResult
    public func save() -> Bool {
        // Only a resolved credential goes to the Keychain. A placeholder is nothing to store —
        // an empty one would delete the token the user has — and a legacy plaintext copy rides
        // along in the document until `resolveHuggingFaceToken(migrating:)` has moved it.
        if _huggingFaceToken.isResolved {
            guard CredentialStore.setHuggingFaceToken(huggingFaceToken) else { return false }
        }
        guard let data = try? JSONEncoder().encode(self) else { return false }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        return true
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
