import Foundation

// The socket every realtime session runs on. ElevenLabs' WebSocket APIs are not in the OpenAPI
// spec; their message shapes come from the AsyncAPI blocks pinned under
// `Scripts/elevenlabs/asyncapi/` and the SDKs (see `docs/ELEVENLABS.md`, "Realtime").

/// One frame. ElevenLabs sends and expects JSON in text frames; a binary frame is read as UTF-8
/// JSON, defensively.
public enum ElevenLabsSocketMessage: Sendable, Equatable {
    case text(String)
    case data(Data)

    /// The frame as JSON, or nil when it is not JSON at all.
    public var json: JSONValue? {
        switch self {
        case .text(let text): try? JSONValue.parse(Data(text.utf8))
        case .data(let data): try? JSONValue.parse(data)
        }
    }
}

/// How a socket ended: the WebSocket close code and reason, as far as they are known.
public struct ElevenLabsSocketClose: Sendable, Equatable, CustomStringConvertible {
    /// The close code; 0 when the connection dropped without one.
    public var code: Int
    /// The close reason, redacted of anything key-shaped and cut to 300 characters.
    public var reason: String

    public enum Kind: Sendable, Equatable {
        /// 1000, or 1005 (no code given): an ordinary end.
        case normal
        /// 4300: a caller held in an agent's call queue waited too long.
        case queueTimedOut
        /// Anything else: an error, whose reason says what.
        case error
    }

    public init(code: Int, reason: String) {
        self.code = code
        let cleaned = ElevenLabsRealtimeRedaction.scrub(reason)
        self.reason = cleaned.count > 300 ? String(cleaned.prefix(300)) + "…" : cleaned
    }

    public static let normalClosure = 1000
    public static let noStatus = 1005
    public static let queueTimeout = 4300

    public var kind: Kind {
        switch code {
        case Self.normalClosure, Self.noStatus: .normal
        case Self.queueTimeout: .queueTimedOut
        default: .error
        }
    }

    public var description: String {
        let reason = reason.isEmpty ? "" : ": \(reason)"
        switch kind {
        case .normal: return "closed normally (\(code))\(reason)"
        case .queueTimedOut: return "the call queue timed out (\(code))\(reason)"
        case .error: return code == 0 ? "the connection dropped\(reason)" : "closed with code \(code)\(reason)"
        }
    }
}

/// What to open: the URL (a region host over `wss`), the upgrade request's headers, and bounds.
///
/// The key, when a socket takes one, is in `headers` — never in the URL, never in a message.
/// Nothing here prints the headers, and the URL is printed with every query value masked
/// except the few that are known to be harmless.
public struct ElevenLabsSocketRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var url: URL
    /// Includes `xi-api-key` for the speech and transcription sockets. Never described.
    public var headers: [String: String]
    /// The largest message accepted from the server. The SDKs use 16 MiB; Foundation's
    /// default is 1 MiB, which a long alignment or a big audio chunk can pass.
    public var maximumMessageSize: Int
    /// How long the opening handshake may take.
    public var openTimeout: TimeInterval

    public static let defaultMaximumMessageSize = 16 << 20

    public init(
        url: URL, headers: [String: String] = [:],
        maximumMessageSize: Int = ElevenLabsSocketRequest.defaultMaximumMessageSize,
        openTimeout: TimeInterval = 20
    ) {
        self.url = url
        self.headers = headers
        self.maximumMessageSize = maximumMessageSize
        self.openTimeout = openTimeout
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// The URL with its query masked; never the headers.
    public var description: String { "WebSocket " + ElevenLabsRealtimeRedaction.describe(url) }
    public var debugDescription: String { description }
}

extension ElevenLabsSocketRequest: CustomReflectable {
    /// `dump` and `Mirror` would otherwise walk `headers`, and with them the key; and `url`,
    /// which for an agent can be a signed URL. Reflect what `description` shows.
    public var customMirror: Mirror {
        Mirror(self, children: ["url": ElevenLabsRealtimeRedaction.describe(url)], displayStyle: .struct)
    }
}

/// One open socket. Production is `URLSessionWebSocketConnector`'s; every test uses
/// `FakeElevenLabsSocketConnector`, or for wire-level checks a loopback server.
public protocol ElevenLabsSocket: AnyObject, Sendable {
    /// Sends one frame. Throws `ElevenLabsRealtimeError.closed` once the socket has ended.
    func send(_ message: ElevenLabsSocketMessage) async throws
    /// The next frame from the server, in order. Throws `ElevenLabsRealtimeError.closed` with
    /// the close code and reason when the socket ends, however it ends.
    func receive() async throws -> ElevenLabsSocketMessage
    /// A WebSocket-level ping (not ElevenLabs' JSON ping), for a liveness check.
    func ping() async throws
    /// Closes with `code` and `reason`. Safe to call more than once.
    func close(code: Int, reason: String) async
}

/// Opens sockets. Refuses any URL that is not `wss` to one of the region hosts.
public protocol ElevenLabsSocketConnector: Sendable {
    func connect(_ request: ElevenLabsSocketRequest) async throws -> any ElevenLabsSocket
}

/// A connector that opens nothing: what an app model built for a test or a preview gets, so no
/// code path there can reach ElevenLabs.
public struct UnavailableElevenLabsSocketConnector: ElevenLabsSocketConnector {
    public init() {}

    public func connect(_ request: ElevenLabsSocketRequest) async throws -> any ElevenLabsSocket {
        throw ElevenLabsRealtimeError.network("no network in this context")
    }
}

// MARK: - Errors

/// Everything a realtime session can end with, in words that can be shown as they are. Every
/// message has been through `ElevenLabsRedaction.redact`.
public enum ElevenLabsRealtimeError: Error, Sendable, Equatable, LocalizedError, CustomStringConvertible {
    /// No key is linked.
    case notLinked
    /// The key could not be read (Keychain locked, or its dialog dismissed).
    case credentialUnavailable(String)
    /// The settings were refused before anything was sent; every problem is listed.
    case invalidConfiguration([String])
    /// A URL that is not `wss` to an ElevenLabs region host. Nothing was opened.
    case refusedHost(String)
    /// The server answered the upgrade with something other than 101.
    case handshakeFailed(status: Int?, message: String)
    /// The socket ended.
    case closed(ElevenLabsSocketClose)
    /// ElevenLabs could not be reached, or the connection failed.
    case network(String)
    /// Something did not arrive in time (the handshake, the conversation's first message).
    case timedOut(String)
    /// A message larger than the socket accepts.
    case messageTooLarge
    /// ElevenLabs reported an error in a message (`auth_error`, `quota_exceeded`, `client_error`…).
    case server(type: String, message: String)
    /// The REST call that mints an agent's signed URL failed; the socket was never opened.
    case signedLink(ElevenLabsError)
    /// The session has ended, so nothing more can be sent on it.
    case ended
    case cancelled

    public var description: String {
        ElevenLabsRealtimeRedaction.scrub(sentence)
    }

    private var sentence: String {
        switch self {
        case .notLinked:
            ElevenLabsError.notLinked.description
        case .credentialUnavailable(let why):
            ElevenLabsError.credentialUnavailable(why).description
        case .invalidConfiguration(let problems):
            "Nothing was sent because: " + problems.joined(separator: "; ")
        case .refusedHost(let host):
            "Refused to open a socket to \(host): only the ElevenLabs API hosts, over wss."
        case .handshakeFailed(let status, let message):
            "ElevenLabs refused the connection" + (status.map { " (\($0))" } ?? "")
                + (message.isEmpty ? "." : ": \(message)")
        case .closed(let close):
            "The connection \(close)."
        case .network(let why):
            "Could not reach ElevenLabs: \(why)"
        case .timedOut(let what):
            "Timed out: \(what)"
        case .messageTooLarge:
            "ElevenLabs sent a message larger than this app accepts."
        case .server(let type, let message):
            "ElevenLabs reported \(type)" + (message.isEmpty ? "." : ": \(message)")
        case .signedLink(let error):
            "The conversation's link could not be made: \(error.description)"
        case .ended:
            "The session has ended."
        case .cancelled:
            "Cancelled."
        }
    }

    public var errorDescription: String? { description }

    /// Any error as a realtime error, redacted, with the key (when known) taken out too.
    public init(wrapping error: any Error, redactingKey key: String? = nil) {
        func scrub(_ text: String) -> String { ElevenLabsRealtimeRedaction.scrub(text, knownKey: key) }
        switch error {
        case let error as ElevenLabsRealtimeError:
            switch error {
            case .credentialUnavailable(let why): self = .credentialUnavailable(scrub(why))
            case .invalidConfiguration(let problems): self = .invalidConfiguration(problems.map(scrub))
            case .refusedHost(let host): self = .refusedHost(scrub(host))
            case .handshakeFailed(let status, let message): self = .handshakeFailed(status: status, message: scrub(message))
            case .closed(let close): self = .closed(ElevenLabsSocketClose(code: close.code, reason: scrub(close.reason)))
            case .network(let why): self = .network(scrub(why))
            case .timedOut(let what): self = .timedOut(scrub(what))
            case .server(let type, let message): self = .server(type: scrub(type), message: scrub(message))
            case .signedLink(let inner): self = .signedLink(ElevenLabsError(wrapping: inner, redactingKey: key))
            case .notLinked, .messageTooLarge, .ended, .cancelled: self = error
            }
        case let error as ElevenLabsError:
            switch error {
            case .notLinked: self = .notLinked
            case .credentialUnavailable(let why): self = .credentialUnavailable(scrub(why))
            case .cancelled: self = .cancelled
            case .refusedHost(let host): self = .refusedHost(scrub(host))
            case .invalidArguments(let problems): self = .invalidConfiguration(problems.map(scrub))
            default: self = .network(scrub(error.description))
            }
        case is CancellationError:
            self = .cancelled
        case let error as URLError where error.code == .cancelled:
            self = .cancelled
        case let error as URLError where error.code == .timedOut:
            self = .timedOut("the connection")
        case let error as URLError:
            self = .network(scrub(error.localizedDescription))
        default:
            // Never `"\(error)"`: an NSError prints its whole userInfo, and URLSession's carry the
            // failing URL — for an agent, a signed one. The words and the domain/code only.
            let error = error as NSError
            self = .network(scrub("\(error.localizedDescription) (\(error.domain) \(error.code))"))
        }
    }
}

// MARK: - Redaction

/// What a socket URL may show of itself. Signed agent URLs carry a signature under a name the
/// docs do not agree on (`conversation_signature`, `token`), and the speech sockets can take a
/// single-use token, so the query is masked by an allowlist, not a denylist: only values known
/// to be harmless are shown.
public enum ElevenLabsRealtimeRedaction {
    /// Query parameters whose values are settings, not credentials.
    public static let harmlessQueryParameters: Set<String> = [
        "agent_id", "model_id", "output_format", "language_code", "inactivity_timeout",
        "sync_alignment", "auto_mode", "apply_text_normalization", "seed", "enable_ssml_parsing",
        "enable_logging", "audio_format", "commit_strategy", "vad_threshold",
        "vad_silence_threshold_secs", "min_speech_duration_ms", "min_silence_duration_ms",
        "include_timestamps", "include_language_detection", "no_verbatim",
        "filter_background_audio", "environment", "branch_id",
    ]

    /// `text` with every URL in it described as `describe` would (its query masked by the
    /// allowlist), every `signature`/`token`-like parameter masked wherever it stands, and anything
    /// key-shaped redacted — what every realtime error, close reason and outcome goes through.
    public static func scrub(_ text: String, knownKey: String? = nil) -> String {
        var result = text
        let range = NSRange(result.startIndex..., in: result)
        let urls = urlPattern.matches(in: result, range: range).reversed()
        for match in urls {
            guard let swiftRange = Range(match.range, in: result) else { continue }
            let found = String(result[swiftRange])
            let shown: String
            if let url = URL(string: found), url.scheme != nil {
                shown = describe(url)
            } else if let mark = found.firstIndex(of: "?") {
                shown = String(found[..<mark]) + "?" + ElevenLabsRedaction.placeholder
            } else {
                shown = found
            }
            result.replaceSubrange(swiftRange, with: shown)
        }
        result = secretParameterPattern.stringByReplacingMatches(
            in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1=" + ElevenLabsRedaction.placeholder
        )
        return ElevenLabsRedaction.redact(result, knownKey: knownKey)
    }

    private static let urlPattern = try! NSRegularExpression(pattern: #"(?i)\b(?:wss?|https?)://[^\s"'<>,)]+"#)
    private static let secretParameterPattern = try! NSRegularExpression(
        pattern: #"(?i)\b(conversation_signature|single_use_token|signature|token|xi-api-key|xi_api_key|authorization)=(?!‹)[^&\s"'<>,)]+"#
    )

    /// `url` as text: scheme, host, path, and the query with every value not on the allowlist
    /// replaced by the placeholder. Any key-shaped text left is redacted too.
    public static func describe(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return ElevenLabsRedaction.placeholder
        }
        components.user = nil
        components.password = nil
        components.fragment = nil
        if let items = components.percentEncodedQueryItems, !items.isEmpty {
            components.percentEncodedQueryItems = items.map { item in
                harmlessQueryParameters.contains(item.name.lowercased())
                    ? item : URLQueryItem(name: item.name, value: "%E2%80%B9redacted%E2%80%BA")
            }
        }
        return ElevenLabsRedaction.redact(components.string ?? ElevenLabsRedaction.placeholder)
    }
}
