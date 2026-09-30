import Foundation

/// What a call produced.
public enum ElevenLabsResult: Sendable {
    /// A JSON answer (`.null` for an empty `204`).
    case json(JSONValue, ElevenLabsMeta)
    /// A body written through the file sink: audio, zip, video, CSV…
    case file(URL, contentType: String, bytes: Int, ElevenLabsMeta)
    /// `text/html` or `text/plain`, inline.
    case text(String, ElevenLabsMeta)
    /// Server-sent events or streamed JSON chunks, collected, with nothing binary in them.
    case events([JSONValue], ElevenLabsMeta)
    /// An answer in several pieces: `multipart/mixed` (metadata plus audio), or a stream
    /// whose chunks carried audio — the audio joined into one file, the rest kept as JSON.
    case parts([ElevenLabsResultPart], ElevenLabsMeta)

    public var meta: ElevenLabsMeta {
        switch self {
        case .json(_, let meta), .file(_, _, _, let meta), .text(_, let meta),
             .events(_, let meta), .parts(_, let meta):
            meta
        }
    }

    /// Every file this result wrote.
    public var files: [URL] {
        switch self {
        case .file(let url, _, _, _): [url]
        case .parts(let parts, _):
            parts.compactMap { if case .file(let url, _, _) = $0 { url } else { nil } }
        case .json, .text, .events: []
        }
    }
}

/// One piece of a `.parts` result.
public enum ElevenLabsResultPart: Sendable {
    case json(JSONValue)
    case text(String)
    case file(URL, contentType: String, bytes: Int)
}

/// What came with an answer besides its body.
public struct ElevenLabsMeta: Sendable, Codable, Hashable {
    public var status: Int
    public var requestID: String?
    /// The `character-cost` header: what the call spent, when ElevenLabs says.
    public var characterCost: Int?
    public var contentType: String?
    /// Allowlisted response headers only (request id, cost, rate limits, song id…), names
    /// lower-cased.
    public var headers: [String: String]

    public init(
        status: Int, requestID: String? = nil, characterCost: Int? = nil,
        contentType: String? = nil, headers: [String: String] = [:]
    ) {
        self.status = status
        self.requestID = requestID
        self.characterCost = characterCost
        self.contentType = contentType
        self.headers = headers
    }
}

/// A piece of a streamed answer, in arrival order.
public enum ElevenLabsChunk: Sendable {
    /// First, always: status and allowlisted headers, before any body.
    case started(ElevenLabsMeta)
    /// Audio bytes: raw from a chunked-audio variant, or decoded from a JSON or SSE chunk's
    /// base64 payload.
    case audio(Data)
    /// A JSON chunk or SSE event, with any audio payload taken out (it arrives as `.audio`).
    case event(JSONValue)
    /// Body bytes of any other kind.
    case bytes(Data)
}

/// Everything that can go wrong, in words that can be shown as they are. Every message has
/// been through `ElevenLabsRedaction.redact`.
public enum ElevenLabsError: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
    /// No key is linked.
    case notLinked
    /// The key could not be read (Keychain locked, or its dialog dismissed).
    case credentialUnavailable(String)
    case unknownOperation(String)
    /// Every problem with the arguments, all at once; nothing was sent.
    case invalidArguments([String])
    /// ElevenLabs answered with an error.
    case api(status: Int, code: String?, message: String, requestID: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case network(String)
    /// A host outside the region allowlist, or not https.
    case refusedHost(String)
    case tooLarge(String)
    case cancelled

    public var description: String {
        switch self {
        case .notLinked:
            "ElevenLabs is not connected. Add an API key in Settings → ElevenLabs."
        case .credentialUnavailable(let why):
            "The ElevenLabs key could not be read from the Keychain: \(why)"
        case .unknownOperation(let id):
            "There is no ElevenLabs operation named \"\(id)\"."
        case .invalidArguments(let problems):
            "The arguments were not sent because: " + problems.joined(separator: "; ")
        case .api(let status, let code, let message, let requestID):
            "ElevenLabs answered \(status)"
                + (code.map { " (\($0))" } ?? "") + ": \(message)"
                + (requestID.map { " [request \($0)]" } ?? "")
        case .rateLimited(let retryAfter):
            "ElevenLabs is rate limiting this account"
                + (retryAfter.map { "; try again in \(Int($0.rounded(.up))) s." } ?? ".")
        case .network(let why):
            "Could not reach ElevenLabs: \(why)"
        case .refusedHost(let host):
            "Refused to send the ElevenLabs key to \(host): only the ElevenLabs API hosts, over https."
        case .tooLarge(let why):
            "The ElevenLabs answer or upload was too large: \(why)"
        case .cancelled:
            "Cancelled."
        }
    }

    public var errorDescription: String? { description }
}

extension ElevenLabsError {
    /// Any error as an `ElevenLabsError` — cancellation as `.cancelled`, URL errors as
    /// `.network` — with `key` and anything key-shaped redacted from its text.
    public init(wrapping error: any Error, redactingKey key: String? = nil) {
        self = ElevenLabsClient.normalized(error, key: key)
    }
}

/// The linked account at a glance: what Settings and the pane's header show.
public struct ElevenLabsAccount: Sendable, Codable, Hashable {
    public var userID: String
    public var firstName: String?
    /// The plan: "free", "starter", "creator", "pro", "scale", "business"…
    public var tier: String
    public var status: String?
    public var characterCount: Int
    public var characterLimit: Int
    public var nextResetAt: Date?
    public var voiceSlotsUsed: Int?
    public var voiceLimit: Int?
    public var professionalVoiceLimit: Int?
    public var canUseInstantVoiceCloning: Bool?
    public var canUseProfessionalVoiceCloning: Bool?
    /// Requests the client lets run at once, from the plan.
    public var concurrencyLimit: Int
    public var checkedAt: Date

    public init(
        userID: String, firstName: String? = nil, tier: String, status: String? = nil,
        characterCount: Int, characterLimit: Int, nextResetAt: Date? = nil,
        voiceSlotsUsed: Int? = nil, voiceLimit: Int? = nil, professionalVoiceLimit: Int? = nil,
        canUseInstantVoiceCloning: Bool? = nil, canUseProfessionalVoiceCloning: Bool? = nil,
        concurrencyLimit: Int, checkedAt: Date = Date()
    ) {
        self.userID = userID
        self.firstName = firstName
        self.tier = tier
        self.status = status
        self.characterCount = characterCount
        self.characterLimit = characterLimit
        self.nextResetAt = nextResetAt
        self.voiceSlotsUsed = voiceSlotsUsed
        self.voiceLimit = voiceLimit
        self.professionalVoiceLimit = professionalVoiceLimit
        self.canUseInstantVoiceCloning = canUseInstantVoiceCloning
        self.canUseProfessionalVoiceCloning = canUseProfessionalVoiceCloning
        self.concurrencyLimit = concurrencyLimit
        self.checkedAt = checkedAt
    }

    /// Credits left this period.
    public var remainingCharacters: Int { max(0, characterLimit - characterCount) }
}

/// What a call will send, for "Show API call": never the key.
public struct ElevenLabsCallDescription: Sendable, Codable, Hashable {
    public var operationID: String
    public var method: String
    /// The full URL including the query string.
    public var url: String
    /// Headers sent besides the key (content type, `safety-identifier`), and
    /// `xi-api-key: <redacted>` in place of the key.
    public var headers: [String: String]
    /// The JSON body, or for multipart the non-file fields plus each file's name and size.
    public var body: JSONValue?

    public init(operationID: String, method: String, url: String, headers: [String: String], body: JSONValue?) {
        self.operationID = operationID
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}
