import Foundation

/// Bring-your-own-key remote providers.
///
/// This app runs models on hardware you own; a cloud provider is the one exception, and it
/// stays off until someone enters a key. Nothing here is consulted — no list is fetched, no
/// model appears in any picker — while `CloudCredentials` is empty. That is the whole
/// contract: opt in or the feature does not exist.
///
/// Five providers, because they all speak OpenAI for chat and the difference is a base URL
/// and which catalogue the key unlocks.
public enum CloudProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case gmi = "gmi"
    case openRouter = "open-router"
    case nvidia = "nvidia"
    case tokenHarbor = "token-harbor"
    case aiHubMix = "aihubmix"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .gmi: "GMI Cloud"
        case .openRouter: "OpenRouter"
        case .nvidia: "NVIDIA"
        case .tokenHarbor: "Token Harbor"
        case .aiHubMix: "AIHubMix"
        }
    }

    /// The OpenAI-compatible root. `/models` and `/chat/completions` hang off this, so the
    /// gateway can treat a provider exactly like a local engine once it has the key.
    public var chatBaseURL: URL {
        switch self {
        case .gmi: URL(string: "https://api.gmi-serving.com/v1")!
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")!
        case .nvidia: URL(string: "https://integrate.api.nvidia.com/v1")!
        case .tokenHarbor: URL(string: "https://tokenharbor.ai/v1")!
        case .aiHubMix: URL(string: "https://aihubmix.com/v1")!
        }
    }

    /// Where audio jobs are submitted and polled. A different host from `chatBaseURL` and a
    /// different protocol — submit-then-poll rather than OpenAI — which is why it is its own
    /// property rather than a path on the other one.
    ///
    /// Only GMI has one. OpenRouter brokers chat, and NVIDIA's hosted catalogue is language
    /// models only — its three `riva-translate` entries are text, not speech, despite Riva
    /// being NVIDIA's speech brand elsewhere. So speech and music are GMI's alone.
    public var jobsBaseURL: URL? {
        switch self {
        case .gmi: URL(string: "https://console.gmicloud.ai")!
        case .openRouter, .nvidia, .tokenHarbor, .aiHubMix: nil
        }
    }

    /// Where someone goes to get a key, for the button next to the empty field.
    public var keyPageURL: URL {
        switch self {
        case .gmi: URL(string: "https://console.gmicloud.ai/apikeys")!
        case .openRouter: URL(string: "https://openrouter.ai/keys")!
        case .nvidia: URL(string: "https://build.nvidia.com/settings/api-keys")!
        case .tokenHarbor: URL(string: "https://tokenharbor.ai/dashboard/api-keys")!
        case .aiHubMix: URL(string: "https://aihubmix.com/token")!
        }
    }

    public var offersAudio: Bool { jobsBaseURL != nil }

    /// How this provider spells "costs nothing" in a model id, when it has such a tier.
    /// Token Harbor: "never charges your balance". AIHubMix: daily quotas, the same
    /// upstream model as the paid id. Per provider on purpose — a "-free" on Token
    /// Harbor is just a name, and a ":free" on AIHubMix is not their tier.
    public var freeSuffix: String? {
        switch self {
        case .tokenHarbor: ":free"
        case .aiHubMix: "-free"
        case .gmi, .openRouter, .nvidia: nil
        }
    }
}

extension CloudModel {
    /// Read from the id the provider sent, never from a list kept here, so a model
    /// moving in or out of a free tier is right on the day it happens.
    public var isFree: Bool {
        guard let suffix = provider.freeSuffix else { return false }
        return id.hasSuffix(suffix)
    }
}

// MARK: - Credentials

/// The keys, kept out of `settings.json` deliberately.
///
/// Settings is read, rewritten and migrated constantly; a credential does not belong in a
/// file with that much traffic. This follows `swarm.json` instead — its own file in the app's
/// Application Support directory, written user-only (0600) — which is already how this app
/// stores the one other secret it holds.
public struct CloudCredentials: Codable, Sendable, Equatable {

    /// Provider raw value → API key. A dictionary rather than one field per provider so an
    /// unknown provider in a file written by a newer build survives a round trip instead of
    /// being silently dropped.
    public var keys: [String: String]

    public init(keys: [String: String] = [:]) {
        self.keys = keys
    }

    public func key(for provider: CloudProvider) -> String? {
        guard let key = keys[provider.rawValue], !key.isEmpty else { return nil }
        return key
    }

    public mutating func set(_ key: String?, for provider: CloudProvider) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            keys[provider.rawValue] = trimmed
        } else {
            keys.removeValue(forKey: provider.rawValue)
        }
    }

    /// The providers this machine can actually reach right now.
    public var configured: [CloudProvider] {
        CloudProvider.allCases.filter { key(for: $0) != nil }
    }

    public var isEmpty: Bool { configured.isEmpty }

    // MARK: Storage

    public static var configURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("SiliconOptimizer/cloud-providers.json")
    }

    /// Absent file, unreadable file and unparseable file all mean the same thing here — no
    /// cloud — so none of them is worth an error path.
    public static func load() -> CloudCredentials {
        guard let data = try? Data(contentsOf: configURL),
              let decoded = try? JSONDecoder().decode(CloudCredentials.self, from: data)
        else { return CloudCredentials() }
        return decoded
    }

    /// Writes user-only, and deletes rather than leaving an empty file behind when the last
    /// key is cleared — "no file" is the honest representation of "no cloud".
    public func save() throws {
        let url = Self.configURL
        let manager = FileManager.default
        if isEmpty {
            if manager.fileExists(atPath: url.path) {
                try manager.removeItem(at: url)
            }
            return
        }
        try manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Discovered models

/// One model a provider says the key can reach.
///
/// Deliberately discovered rather than compiled in. GMI's published catalogue did not list
/// MiniMax M3 on the day it started serving it, and a hardcoded id would have been a dead
/// entry in the picker; asking the provider what it has costs one request and is right on
/// the day a model lands and on the day a promotion ends.
public struct CloudModel: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var displayName: String
    public var provider: CloudProvider
    public var contextWindow: Int?
    /// The `owned_by` field of the listing, when the provider sent one. The maker filter
    /// reads the id's "owner/model" slash first and falls back to this — AIHubMix and
    /// Token Harbor put no slash in their ids, and a 400-model list without a maker
    /// filter is a wall.
    public var owner: String?
    /// What a million input tokens costs, when the provider publishes a price in its own
    /// listing. OpenRouter does; the others do not, and nil means exactly that — nobody
    /// said — rather than "free", which `isFree` answers from the id.
    ///
    /// Read rather than tabulated, for the same reason the model list is: a price kept here
    /// would be wrong the first time a provider changed one.
    public var pricePerMillionInputUSD: Double?

    public init(
        id: String, displayName: String, provider: CloudProvider, contextWindow: Int? = nil,
        owner: String? = nil, pricePerMillionInputUSD: Double? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.contextWindow = contextWindow
        self.owner = owner
        self.pricePerMillionInputUSD = pricePerMillionInputUSD
    }

    /// The gateway id this model answers to — `cloud/<provider>/<model>`. The model half may
    /// itself contain slashes (`MiniMaxAI/MiniMax-M2.7`, `minimax/minimax-m3`), which is why
    /// only the first two separators structure a gateway id.
    public var gatewayID: String { "cloud/\(provider.rawValue)/\(id)" }
}
