import Foundation

/// The swarm: N Silicon nodes advertising what they are and delegating work to whoever
/// fits it. This file holds the Mac's half of the frozen Phase 4 shapes — the peer registry
/// config both platforms read, and the `/v1/node` advertisement both platforms serve.
/// JSON is snake_case throughout, matching the Windows node's live implementation.

/// One peer in the registry. The registry is also the allowlist: mDNS discovery, when it
/// comes, only ever *suggests* entries for this file, never bypasses it.
public struct SwarmPeer: Codable, Sendable, Identifiable, Hashable {
    public var name: String
    public var baseURL: String
    /// This machine's own credential for that peer (a per-client token minted by the
    /// peer's admin). Nil falls back to the shared swarm token. Per-client tokens are
    /// what let a node's activity log say *which* machine asked — and let one member
    /// be revoked without rotating everyone.
    public var token: String?

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case baseURL = "base_url"
        case token
    }

    public init(name: String, baseURL: String, token: String? = nil) {
        self.name = name
        self.baseURL = baseURL
        self.token = token
    }
}

/// The per-node swarm configuration, read from a file rather than app preferences because
/// every platform's node reads the same shape — a Mac, the Windows node, and whatever
/// joins later.
public struct SwarmConfig: Codable, Sendable, Equatable {
    /// The shared secret. Jobs execute code paths, so a node must refuse to listen beyond
    /// localhost without this set.
    public var swarmToken: String?
    public var peers: [SwarmPeer]

    enum CodingKeys: String, CodingKey {
        case swarmToken = "swarm_token"
        case peers
    }

    public init(swarmToken: String? = nil, peers: [SwarmPeer] = []) {
        self.swarmToken = swarmToken
        self.peers = peers
    }

    /// A token that is present but blank counts as absent — an empty string in a template
    /// file must not satisfy the bind rule.
    public var effectiveToken: String? {
        guard let token = swarmToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    /// The credential to present to one peer: its per-client token when this machine
    /// holds one, else the shared swarm token. Admin operations (minting and revoking
    /// client tokens) must keep using `effectiveToken` directly — a client token can
    /// never administer.
    public func bearer(forPeer name: String) -> String? {
        if let token = peers.first(where: { $0.name == name })?.token?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        return effectiveToken
    }

    /// Records a freshly minted per-client token for one peer.
    public mutating func setToken(_ token: String?, forPeer name: String) {
        guard let index = peers.firstIndex(where: { $0.name == name }) else { return }
        peers[index].token = token
    }

    public static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["SILICON_SWARM_CONFIG"] {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("SiliconOptimizer/swarm.json")
    }

    public static func load() -> SwarmConfig? {
        guard let data = try? Data(contentsOf: configURL) else { return nil }
        return try? JSONDecoder().decode(SwarmConfig.self, from: data)
    }

    /// Writes a starter config (with a generated token) if none exists, and returns the
    /// config on disk either way. The token is a credential; the file is user-only.
    @discardableResult
    public static func ensureExists() -> SwarmConfig {
        if let existing = load() { return existing }
        let fresh = SwarmConfig(swarmToken: UUID().uuidString, peers: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if let data = try? encoder.encode(fresh) {
            try? data.write(to: configURL, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: configURL.path
            )
        }
        return fresh
    }
}

extension ControlAPI {

    /// What this node tells its peers it is. Top-level shape is standardized across
    /// platforms; the keys inside `profile` are each platform's own.
    public struct NodeAdvertisement: Codable, Sendable {
        public var name: String
        public var platform: String
        public var profile: MacProfile
        public var capabilities: [NodeCapability]
        public var metrics: NodeMetrics

        public init(
            name: String, platform: String, profile: MacProfile,
            capabilities: [NodeCapability], metrics: NodeMetrics
        ) {
            self.name = name
            self.platform = platform
            self.profile = profile
            self.capabilities = capabilities
            self.metrics = metrics
        }
    }

    /// The Mac's native profile keys — peers only need the standardized top level.
    public struct MacProfile: Codable, Sendable {
        public var chip: String
        public var memoryGB: Double
        public var bandwidthGBps: Double
        public var gpuCores: Int

        enum CodingKeys: String, CodingKey {
            case chip
            case memoryGB = "memory_gb"
            case bandwidthGBps = "bandwidth_gbps"
            case gpuCores = "gpu_cores"
        }

        public init(chip: String, memoryGB: Double, bandwidthGBps: Double, gpuCores: Int) {
            self.chip = chip
            self.memoryGB = memoryGB
            self.bandwidthGBps = bandwidthGBps
            self.gpuCores = gpuCores
        }
    }

    public struct NodeCapability: Codable, Sendable {
        public var id: String
        public var kind: String
        public var ready: Bool
        public var peakGB: Double?
        public var typicalSeconds: Double?
        public var detail: String

        enum CodingKeys: String, CodingKey {
            case id, kind, ready, detail
            case peakGB = "peak_gb"
            case typicalSeconds = "typical_seconds"
        }

        public init(
            id: String, kind: String, ready: Bool, peakGB: Double?,
            typicalSeconds: Double?, detail: String
        ) {
            self.id = id
            self.kind = kind
            self.ready = ready
            self.peakGB = peakGB
            self.typicalSeconds = typicalSeconds
            self.detail = detail
        }
    }

    public struct NodeMetrics: Codable, Sendable {
        public var queueDepth: Int
        /// The normalized cross-platform field the router ranks on: how much work this
        /// node could take right now, in GB, computed each platform's own way.
        public var headroomGB: Double
        public var gpuUtilPct: Int
        public var memoryUsedPct: Int

        enum CodingKeys: String, CodingKey {
            case queueDepth = "queue_depth"
            case headroomGB = "headroom_gb"
            case gpuUtilPct = "gpu_util_pct"
            case memoryUsedPct = "memory_used_pct"
        }

        public init(queueDepth: Int, headroomGB: Double, gpuUtilPct: Int, memoryUsedPct: Int) {
            self.queueDepth = queueDepth
            self.headroomGB = headroomGB
            self.gpuUtilPct = gpuUtilPct
            self.memoryUsedPct = memoryUsedPct
        }
    }
}
