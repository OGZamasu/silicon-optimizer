import Foundation

/// The wire contract Silicon Buddy — the phone and tablet companion — speaks to this Mac.
///
/// These shapes are what the mobile apps are generated from, so they are pinned by
/// `ContractExportTests` rather than left to follow the Mac UI around. Timestamps are
/// ISO-8601 strings rather than Codable `Date`s: the control server encodes with a plain
/// `JSONEncoder`, which would otherwise hand a phone a reference-date double and make every
/// client re-derive the epoch.
extension ControlAPI {

    /// The one timestamp format on this wire.
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    public static func date(fromTimestamp text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: - Pairing

    /// The body of the one unauthenticated POST on this server. A device offers the code the
    /// owner is looking at and says what it is; it gets back a credential of its own.
    public struct BuddyPairRequest: Codable, Sendable, Equatable {
        public var code: String
        public var deviceName: String
        public var platform: String

        public init(code: String, deviceName: String, platform: String) {
            self.code = code
            self.deviceName = deviceName
            self.platform = platform
        }
    }

    /// What a device may do. The phone does not ask for this — the owner chose it on the
    /// Mac before the code was shown — so it arrives in the answer, not the request.
    public static let buddyScopes = ["full", "chat"]

    /// The only time a device token exists in plaintext. The Mac keeps a hash; the phone
    /// keeps this in its own keychain and presents it as a bearer from then on.
    public struct BuddyPairResponse: Codable, Sendable, Equatable {
        public var deviceID: String
        public var token: String
        public var macName: String
        public var port: Int
        /// "full" or "chat". A chat-only device should hide the controls it cannot use
        /// rather than discovering them as 403s.
        public var scope: String

        public init(
            deviceID: String, token: String, macName: String, port: Int,
            scope: String = "full"
        ) {
            self.deviceID = deviceID
            self.token = token
            self.macName = macName
            self.port = port
            self.scope = scope
        }
    }

    /// A paired device as the Settings list and `GET /buddy/devices` show it — never the
    /// token hash, which has no reason to leave the file it is written in.
    public struct BuddyDeviceSummary: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var platform: String
        /// "full" or "chat".
        public var scope: String
        public var pairedAt: String
        public var lastSeen: String?
        /// True when this device was paired before the tailnet listener took a fixed port
        /// and therefore holds an address that no longer answers. Nothing is wrong with the
        /// token — the device simply cannot find this Mac until it is paired again.
        public var needsRepair: Bool

        public init(
            id: String, name: String, platform: String, scope: String = "full",
            pairedAt: String, lastSeen: String? = nil, needsRepair: Bool = false
        ) {
            self.id = id
            self.name = name
            self.platform = platform
            self.scope = scope
            self.pairedAt = pairedAt
            self.lastSeen = lastSeen
            self.needsRepair = needsRepair
        }
    }

    // MARK: - Streaming chat

    /// One frame of `POST /chat/stream`, named after the SSE event that carries it.
    public enum ChatStreamEvent: Sendable, Equatable {
        case token(String)
        case reasoning(String)
        case finished(ChatMetrics)
    }

    /// The payload of a `token` or `reasoning` event. An object rather than a bare string so
    /// a client parses every frame the same way, whatever the event is called.
    public struct StreamToken: Codable, Sendable, Equatable {
        public var text: String

        public init(text: String) { self.text = text }
    }

    /// The payload of a `finished` event.
    public struct ChatMetrics: Codable, Sendable, Equatable {
        public var promptTokens: Int
        public var generatedTokens: Int
        public var tokensPerSecond: Double
        public var timeToFirstToken: Double

        public init(
            promptTokens: Int, generatedTokens: Int,
            tokensPerSecond: Double, timeToFirstToken: Double
        ) {
            self.promptTokens = promptTokens
            self.generatedTokens = generatedTokens
            self.tokensPerSecond = tokensPerSecond
            self.timeToFirstToken = timeToFirstToken
        }
    }

    // MARK: - The /events side channel

    public struct DownloadEvent: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var fraction: Double
        public var bytesReceived: Int64
        public var bytesExpected: Int64
        public var bytesPerSecond: Double
        public var error: String?

        public init(
            id: String, name: String, fraction: Double, bytesReceived: Int64,
            bytesExpected: Int64, bytesPerSecond: Double, error: String? = nil
        ) {
            self.id = id
            self.name = name
            self.fraction = fraction
            self.bytesReceived = bytesReceived
            self.bytesExpected = bytesExpected
            self.bytesPerSecond = bytesPerSecond
            self.error = error
        }
    }

    /// A render in flight — a video clip or an image — as a phone needs to see it.
    public struct JobEvent: Codable, Sendable, Equatable {
        public var id: String
        public var kind: String
        public var status: String
        public var title: String
        public var fraction: Double?

        public init(
            id: String, kind: String, status: String, title: String, fraction: Double? = nil
        ) {
            self.id = id
            self.kind = kind
            self.status = status
            self.title = title
            self.fraction = fraction
        }
    }

    /// Proof of life on an otherwise silent stream.
    public struct HeartbeatEvent: Codable, Sendable, Equatable {
        public var at: String

        public init(at: String) { self.at = at }
    }

    // MARK: - Conversations

    public struct ConversationSummary: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var title: String
        public var updatedAt: String
        public var messageCount: Int

        public init(id: String, title: String, updatedAt: String, messageCount: Int) {
            self.id = id
            self.title = title
            self.updatedAt = updatedAt
            self.messageCount = messageCount
        }
    }

    public struct ConversationDetail: Codable, Sendable, Equatable, Identifiable {
        /// Images are deliberately absent. A transcript with a few photographs in it is
        /// megabytes of base64 that a phone has already got, or never wanted.
        public struct Message: Codable, Sendable, Equatable {
            public var role: String
            public var content: String
            public var createdAt: String

            public init(role: String, content: String, createdAt: String) {
                self.role = role
                self.content = content
                self.createdAt = createdAt
            }
        }

        public var id: String
        public var title: String
        public var updatedAt: String
        /// True while an answer is still being written into this conversation, here or on
        /// the Mac. Sending into it would poison the prompt, so the server answers 409.
        public var isGenerating: Bool
        public var messages: [Message]

        public init(
            id: String, title: String, updatedAt: String,
            isGenerating: Bool = false, messages: [Message]
        ) {
            self.id = id
            self.title = title
            self.updatedAt = updatedAt
            self.isGenerating = isGenerating
            self.messages = messages
        }
    }

    public struct NewConversationRequest: Codable, Sendable, Equatable {
        public var title: String?

        public init(title: String? = nil) { self.title = title }
    }

    /// A message sent from a phone. Answered as a stream, and both halves are written into
    /// the Mac's own history, so the exchange is on screen there too.
    public struct NewMessageRequest: Codable, Sendable, Equatable {
        public var content: String
        /// Base64 `data:` URLs, for vision models. Accepted, never returned.
        public var images: [String]
        public var temperature: Double?
        public var maxTokens: Int?

        public init(
            content: String, images: [String] = [],
            temperature: Double? = nil, maxTokens: Int? = nil
        ) {
            self.content = content
            self.images = images
            self.temperature = temperature
            self.maxTokens = maxTokens
        }

        /// Everything but `content` is optional on the wire. A phone sending plain text
        /// should not have to spell out that it attached no photographs.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.content = try container.decode(String.self, forKey: .content)
            self.images = try container.decodeIfPresent([String].self, forKey: .images) ?? []
            self.temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
            self.maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        }
    }
}

/// Raised by hosts that have no conversation store or no model to stream from, so the
/// server can answer with a sentence and a status instead of dropping the connection.
public enum BuddyHostError: Error, LocalizedError, Equatable {
    case noSuchConversation(String)
    case conversationBusy(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .noSuchConversation(let id): "No conversation with id \(id)."
        case .conversationBusy:
            "That conversation is still being answered. Wait for it to finish, or start "
                + "another one."
        case .unsupported(let what): "\(what) is not available on this host."
        }
    }

    /// What the server answers. A phone can act on 404 and 409; it cannot act on 400.
    public var status: Int {
        switch self {
        case .noSuchConversation: 404
        case .conversationBusy: 409
        case .unsupported: 501
        }
    }
}

/// What a device may send, and how much of it.
///
/// A paired phone is trusted, not unlimited: these caps are what stop a bug on the other
/// side — or a lost handset — from turning a tailnet into a memory exhaustion tool.
public enum BuddyLimits {
    /// A phone sends prompts and photographs, not model weights.
    public static let requestBodyBytes = 4 * 1_048_576
    /// What an unauthenticated tailnet caller may send — which is `/buddy/pair` and
    /// nothing else. Its body is a code, a name and a platform.
    public static let unauthenticatedBodyBytes = 65_536
    public static let imagesPerMessage = 8
    /// A base64 `data:` URL, so roughly 1.5 MB of actual image.
    public static let imageCharacters = 2_000_000

    /// Nil when the attachments are within reach, a sentence when they are not.
    public static func refusal(forImages images: [String]) -> String? {
        if images.count > imagesPerMessage {
            return "At most \(imagesPerMessage) images in one message."
        }
        if images.contains(where: { $0.count > imageCharacters }) {
            return "One of those images is too large. The limit is about 1.5 MB each."
        }
        return nil
    }
}
