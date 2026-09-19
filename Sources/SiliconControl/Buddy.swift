import CryptoKit
import Foundation
import Security

/// What the owner has decided about their phones and tablets, kept in
/// `~/Library/Application Support/SiliconOptimizer/buddy.json`.
///
/// Its own file rather than a line in the app's settings because this is a credential store:
/// the file is user-only on disk, and a device's token is written down as a SHA-256 digest,
/// so a copy of buddy.json cannot be replayed against the server. Nothing in here is ever
/// sent to a device except through `BuddyDeviceSummary`, which has no hashes in it.
public struct BuddyConfig: Codable, Sendable, Equatable {

    /// The one switch. Off means the control server stays exactly as it was: loopback,
    /// one bearer token, nothing on the tailnet.
    public var allowTailnetDevices: Bool
    public var devices: [BuddyDevice]

    public init(allowTailnetDevices: Bool = false, devices: [BuddyDevice] = []) {
        self.allowTailnetDevices = allowTailnetDevices
        self.devices = devices
    }

    public static var configURL: URL {
        if let override = ProcessInfo.processInfo.environment["SILICON_BUDDY_CONFIG"] {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("SiliconOptimizer/buddy.json")
    }

    /// A missing or unreadable file reads as "nothing allowed, nothing paired" — the state
    /// this feature ships in, and the only safe thing to assume about a file we cannot parse.
    public static func load(from url: URL = configURL) -> BuddyConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? decoder.decode(BuddyConfig.self, from: data)
        else { return BuddyConfig() }
        return config
    }

    public func save(to url: URL = configURL) {
        guard let data = try? Self.encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// What a paired device is allowed to do.
///
/// The owner picks this while they are holding the device, which is the only moment they
/// can be sure which one they are answering for. Full control is the default because the
/// product is remote parity with the Mac; chat-only exists for a device that is lent out,
/// left at the office, or simply does not need to be able to start a 20 GB download.
public enum BuddyScope: String, Codable, Sendable, Equatable, CaseIterable {
    case full
    case chat

    public var label: String {
        switch self {
        case .full: "Full control"
        case .chat: "Chat only"
        }
    }

    public var detail: String {
        switch self {
        case .full: "Everything this Mac can do: models, images, video, 3D."
        case .chat: "Read the Mac's state and talk to the loaded model. Nothing else."
        }
    }
}

/// One paired phone or tablet.
public struct BuddyDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String
    /// Absent in a file written before scopes existed, which can only have been a device
    /// the owner approved when full control was the only thing on offer.
    public var scope: BuddyScope?
    /// Hex SHA-256 of the 32-byte token handed to the device at pairing. The token itself
    /// exists once, in the pairing response, and is never written anywhere on this Mac.
    public var tokenHash: String
    public var pairedAt: Date
    public var lastSeen: Date?

    public init(
        id: String, name: String, platform: String, scope: BuddyScope = .full,
        tokenHash: String, pairedAt: Date, lastSeen: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.scope = scope
        self.tokenHash = tokenHash
        self.pairedAt = pairedAt
        self.lastSeen = lastSeen
    }

    public var effectiveScope: BuddyScope { scope ?? .full }

    public var summary: ControlAPI.BuddyDeviceSummary {
        ControlAPI.BuddyDeviceSummary(
            id: id, name: name, platform: platform, scope: effectiveScope.rawValue,
            pairedAt: ControlAPI.timestamp(pairedAt),
            lastSeen: lastSeen.map(ControlAPI.timestamp)
        )
    }
}

/// The small pieces of the pairing handshake that are worth testing on their own: the code
/// the owner reads aloud, the token the device keeps, and the link the QR encodes.
public enum BuddyPairing {

    /// The URL scheme both companion apps register.
    public static let scheme = "siliconbuddy"

    /// A pairing code lives exactly this long. Long enough to walk to the other device,
    /// short enough that a code left on screen is not a standing invitation.
    public static let codeLifetime: TimeInterval = 300

    /// Six digits. Short because someone has to read it off a screen; safe only because
    /// `BuddyRegistry` makes guessing it expensive.
    public static func makeCode() -> String {
        // Rejection sampling rather than a modulo: 2^32 is not a multiple of a million, and
        // a code generator with a favourite range is not a thing to ship in a credential.
        let limit = UInt32.max - (UInt32.max % 1_000_000)
        while true {
            var bytes = [UInt8](repeating: 0, count: 4)
            if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
                preconditionFailure("The system random number generator refused.")
            }
            let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            if value < limit { return String(format: "%06d", Int(value % 1_000_000)) }
        }
    }

    /// Spaced for reading aloud. The URL and the wire always carry the bare digits.
    public static func display(code: String) -> String {
        guard code.count == 6 else { return code }
        return "\(code.prefix(3)) \(code.suffix(3))"
    }

    /// 32 bytes from the system CSPRNG, base64url so the token survives a header, a QR and
    /// a keychain unchanged. `SecRandomCopyBytes` rather than `Int.random`: this is the only
    /// thing standing between a tailnet and the model on this Mac.
    public static func makeDeviceToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Documented never to fail on Darwin, but a silently weak token is the one
            // outcome worth trapping for.
            preconditionFailure("The system random number generator refused.")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func hash(token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Digest comparison in constant time. The digests are not themselves secret, but a
    /// length-independent compare costs nothing and keeps the habit.
    public static func digestsMatch(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8), b = Array(right.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    /// What the QR encodes: where to dial, and the code that proves the phone was in the
    /// room. No token — that is minted only after the code comes back.
    public static func pairingURL(host: String, port: Int, code: String) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "code", value: code),
        ]
        return components.url?.absoluteString ?? "\(scheme)://pair"
    }
}

/// An open invitation: one code, one use, five minutes.
public struct BuddyInvitation: Sendable, Equatable {
    public var code: String
    public var host: String
    public var port: Int
    /// Chosen on the Mac before the code goes on screen — the one moment the owner knows
    /// which device they are answering for.
    public var scope: BuddyScope
    public var expiresAt: Date

    public init(
        code: String, host: String, port: Int,
        scope: BuddyScope = .full, expiresAt: Date
    ) {
        self.code = code
        self.host = host
        self.port = port
        self.scope = scope
        self.expiresAt = expiresAt
    }

    public var displayCode: String { BuddyPairing.display(code: code) }

    public var url: String {
        BuddyPairing.pairingURL(host: host, port: port, code: code)
    }

    public func isLive(at moment: Date) -> Bool { moment < expiresAt }
}
