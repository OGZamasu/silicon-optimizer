import Foundation

/// Where the owner's ElevenLabs account lives. The key is only ever sent to one of these
/// hosts, over https — the allowlist is this enum, and nothing else can name a host.
///
/// Five hosts. The default routes each request to the nearest ElevenLabs region; US-only opts
/// out of that routing with the same account and key. The three residency regions are
/// isolated workspaces with keys of their own: a key from one does not work on another.
public enum ElevenLabsRegion: String, Sendable, Codable, CaseIterable, Identifiable, Hashable {
    case global = "api.elevenlabs.io"
    case us = "api.us.elevenlabs.io"
    case eu = "api.eu.residency.elevenlabs.io"
    case india = "api.in.residency.elevenlabs.io"
    case singapore = "api.sg.residency.elevenlabs.io"

    public var id: String { rawValue }
    public var host: String { rawValue }

    public var displayName: String {
        switch self {
        case .global: "Global (default)"
        case .us: "US only"
        case .eu: "EU data residency"
        case .india: "India data residency"
        case .singapore: "Singapore data residency"
        }
    }

    /// A residency region: an isolated workspace whose keys work nowhere else.
    public var isResidency: Bool {
        switch self {
        case .global, .us: false
        case .eu, .india, .singapore: true
        }
    }

    public var baseURL: URL { URL(string: "https://\(host)")! }

    /// The WebSocket origin for the same region: the REST base with `https` changed to `wss`.
    public var webSocketBaseURL: URL { URL(string: "wss://\(host)")! }

    /// Every host the key may be sent to.
    public static let allowedHosts: Set<String> = Set(allCases.map(\.host))
}

// MARK: - Credential

/// Where the API key comes from. The app's is the Keychain, read lazily off every actor;
/// tests use `FakeCredentialSource`. Nil means no key is linked.
public protocol ElevenLabsCredentialSource: Sendable {
    func apiKey() async throws -> String?
}

/// A credential source that can also be written: what Connect and Remove go through.
public protocol ElevenLabsKeyStore: ElevenLabsCredentialSource {
    func store(_ key: String) async throws
    func remove() async throws
}

// MARK: - Files

/// A file to upload in a multipart body. Read from disk as the body is assembled, never
/// loaded whole.
public struct ElevenLabsFile: Sendable, Codable, Hashable {
    public var url: URL
    /// The name the upload carries; the file's own name unless given.
    public var filename: String
    public var contentType: String

    public init(url: URL, filename: String? = nil, contentType: String? = nil) {
        self.url = url
        self.filename = filename ?? url.lastPathComponent
        self.contentType = contentType ?? ElevenLabsFile.contentType(forExtension: url.pathExtension)
    }

    /// A content type for the common upload extensions, `application/octet-stream` otherwise.
    public static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "m4a": "audio/mp4"
        case "aac": "audio/aac"
        case "flac": "audio/flac"
        case "ogg", "oga", "opus": "audio/ogg"
        case "webm": "video/webm"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "pdf": "application/pdf"
        case "txt": "text/plain"
        case "html", "htm": "text/html"
        case "json": "application/json"
        case "csv": "text/csv"
        case "srt": "application/x-subrip"
        case "vtt": "text/vtt"
        case "pls": "application/pls+xml"
        case "epub": "application/epub+zip"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "zip": "application/zip"
        default: "application/octet-stream"
        }
    }
}

/// Where big response bodies go. The app's writes under
/// `<output folder>/ElevenLabs/<yyyy-MM-dd>/`; tests use `TemporaryFileSink`.
public protocol ElevenLabsFileSink: Sendable {
    /// A fresh path for a body the client is about to write. Must not exist yet.
    func destination(
        for operation: ElevenLabsOperation, suggestedName: String, contentType: String
    ) throws -> URL

    /// Called once the file is complete — where the app registers it with its media table.
    func didWrite(_ file: URL, contentType: String, operation: ElevenLabsOperation) async
}

extension ElevenLabsFileSink {
    public func didWrite(_ file: URL, contentType: String, operation: ElevenLabsOperation) async {}
}

// MARK: - Transport

/// One HTTP request, fully built: the transport adds nothing and decides nothing.
public struct ElevenLabsRequest: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Body: Sendable, Hashable {
        case none
        case data(Data)
        /// A body assembled on disk (multipart), streamed from the file as it is sent.
        case file(URL)
    }

    /// Where the transport puts the answer, and how big it may be.
    public enum ResponseHandling: Sendable, Hashable {
        /// Collected in memory, failing with `tooLarge` past `limit` bytes.
        case memory(limit: Int)
        /// Written to a temporary file the caller then owns, failing past `limit` bytes.
        case file(limit: Int64)
    }

    public var operationID: String
    public var method: String
    public var url: URL
    /// Includes `xi-api-key`. Never printed: `description` leaves headers out.
    public var headers: [String: String]
    public var body: Body
    public var timeout: TimeInterval
    public var responseHandling: ResponseHandling

    public init(
        operationID: String, method: String, url: URL, headers: [String: String],
        body: Body, timeout: TimeInterval, responseHandling: ResponseHandling
    ) {
        self.operationID = operationID
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.responseHandling = responseHandling
    }

    /// Method and URL only; the key lives in a header and headers are never described.
    public var description: String { "\(method) \(ElevenLabsRedaction.maskingQuerySecrets(in: url))" }

    /// The same: `String(reflecting:)` and `dump` must not reach the headers either.
    public var debugDescription: String { description }

    /// A header by case-insensitive name.
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

extension ElevenLabsRequest: CustomReflectable {
    /// `dump` and `Mirror` walk stored properties, so without this they would print `headers`
    /// — and with it the key. Reflect what `description` shows and nothing else.
    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "operationID": operationID, "method": method,
                "url": ElevenLabsRedaction.maskingQuerySecrets(in: url),
            ],
            displayStyle: .struct
        )
    }
}

/// A whole answer.
public struct ElevenLabsResponse: Sendable {
    public enum Body: Sendable {
        case data(Data)
        /// A temporary file the caller now owns.
        case file(URL)
    }

    public var status: Int
    /// Names lower-cased.
    public var headers: [String: String]
    public var body: Body

    public init(status: Int, headers: [String: String], body: Body) {
        self.status = status
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last }
        )
        self.body = body
    }
}

/// An answer whose body is still arriving.
public struct ElevenLabsStreamingResponse: Sendable {
    public var status: Int
    /// Names lower-cased.
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, any Error>

    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, any Error>) {
        self.status = status
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last }
        )
        self.body = body
    }
}

/// Moves requests. Production is `URLSessionTransport`; every test uses
/// `FakeElevenLabsTransport` (or, for wire-level checks only, a loopback server).
///
/// Streaming hands back status and headers before the body, so the cost header and an error
/// status are known before the first chunk — the one change from the design sketch, where
/// `stream` returned bare chunks and a streamed generation could not report its cost.
public protocol ElevenLabsTransport: Sendable {
    func send(_ request: ElevenLabsRequest) async throws -> ElevenLabsResponse
    func stream(_ request: ElevenLabsRequest) async throws -> ElevenLabsStreamingResponse
}
