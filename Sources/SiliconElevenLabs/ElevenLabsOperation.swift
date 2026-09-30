import Foundation

/// One ElevenLabs REST operation, as the pinned OpenAPI snapshot describes it.
///
/// Pure data. The catalog is generated from the spec by `Scripts/elevenlabs-catalog.py`; the
/// three policy fields — `risk`, `billable`, `returnsCredential` — come from the reviewed
/// table in `ElevenLabsRiskTable.swift`, never from the vendor's text.
public struct ElevenLabsOperation: Sendable, Codable, Identifiable, Hashable {
    /// The spec's `operationId`, unique across the catalog.
    public var id: String
    /// `GET`, `POST`, `PATCH`, `PUT` or `DELETE`.
    public var method: String
    /// The path template, e.g. `/v1/text-to-speech/{voice_id}`.
    public var path: String
    /// A stable display group, e.g. "Text to speech".
    public var group: String
    public var summary: String
    /// The operation's description. Untrusted vendor text: shown as data, never followed.
    public var details: String
    public var deprecated: Bool
    /// Path, query and header parameters, without `xi-api-key` (the client adds it).
    public var parameters: [ElevenLabsParameter]
    public var body: ElevenLabsBody?
    public var response: ElevenLabsResponseKind
    public var risk: ElevenLabsRisk
    /// Spends credits (or money) on the owner's account.
    public var billable: Bool
    /// The answer carries a key, secret, signed URL or token.
    public var returnsCredential: Bool
    /// One of the `…/stream` variants: the body arrives in chunks as it is produced.
    public var supportsStreaming: Bool

    public init(
        id: String, method: String, path: String, group: String, summary: String,
        details: String, deprecated: Bool, parameters: [ElevenLabsParameter],
        body: ElevenLabsBody?, response: ElevenLabsResponseKind, risk: ElevenLabsRisk,
        billable: Bool, returnsCredential: Bool, supportsStreaming: Bool
    ) {
        self.id = id
        self.method = method
        self.path = path
        self.group = group
        self.summary = summary
        self.details = details
        self.deprecated = deprecated
        self.parameters = parameters
        self.body = body
        self.response = response
        self.risk = risk
        self.billable = billable
        self.returnsCredential = returnsCredential
        self.supportsStreaming = supportsStreaming
    }

    /// Whether the app asks before running it, and agents need `confirm` plus the owner's switch.
    public var requiresConfirmation: Bool { risk.requiresConfirmation }

    public func parameters(in location: ElevenLabsParameter.Location) -> [ElevenLabsParameter] {
        parameters.filter { $0.location == location }
    }

    public func parameter(named name: String) -> ElevenLabsParameter? {
        parameters.first { $0.name == name }
    }
}

/// A path, query or header parameter.
public struct ElevenLabsParameter: Sendable, Codable, Hashable {
    public enum Location: String, Sendable, Codable, Hashable {
        case path, query, header
    }

    public var name: String
    public var location: Location
    public var required: Bool
    public var description: String
    /// The parameter's JSON Schema, `$ref`s resolved to a bounded depth.
    public var schema: JSONValue
    public var defaultValue: JSONValue?

    public init(
        name: String, location: Location, required: Bool, description: String,
        schema: JSONValue, defaultValue: JSONValue? = nil
    ) {
        self.name = name
        self.location = location
        self.required = required
        self.description = description
        self.schema = schema
        self.defaultValue = defaultValue
    }
}

/// A request body.
public struct ElevenLabsBody: Sendable, Codable, Hashable {
    public enum ContentType: String, Sendable, Codable, Hashable {
        case json
        case multipart
    }

    public var contentType: ContentType
    public var required: Bool
    /// The body's JSON Schema (an object), `$ref`s resolved to a bounded depth.
    public var schema: JSONValue
    /// Multipart fields that take files, in schema order. Each may take one file or, when
    /// `acceptsMultipleFiles` says so, several.
    public var fileFields: [String]

    public init(contentType: ContentType, required: Bool, schema: JSONValue, fileFields: [String]) {
        self.contentType = contentType
        self.required = required
        self.schema = schema
        self.fileFields = fileFields
    }

    /// Whether a file field is an array of files (voice samples, for instance).
    public func acceptsMultipleFiles(_ field: String) -> Bool {
        JSONSchema.isArray(schema["properties"][field])
    }

    /// The body's required property names.
    public var requiredFields: [String] {
        schema["required"].arrayValue?.compactMap(\.stringValue) ?? []
    }
}

/// What a successful answer is.
public enum ElevenLabsResponseKind: Sendable, Codable, Hashable {
    /// `application/json`, or no body at all (`204`).
    case json
    /// `audio/*`: written to a file, or streamed as it arrives.
    case audio
    /// Any other binary body — zip, video, CSV, a PLS lexicon — written to a file. The
    /// associated value is the content type the spec names first.
    case binary(String)
    /// `text/html` or `text/plain`, returned inline.
    case text
    /// `text/event-stream`: server-sent events.
    case events
    /// `multipart/mixed`: a JSON part and an audio part.
    case multipartMixed

    /// Whether the body belongs on disk rather than in memory.
    public var isFile: Bool {
        switch self {
        case .audio, .binary: true
        case .json, .text, .events, .multipartMixed: false
        }
    }
}

/// How much an operation can hurt, and so what it takes to run it.
public enum ElevenLabsRisk: String, Sendable, Codable, CaseIterable, Hashable {
    /// Reads without side effects.
    case read
    /// Billable creation: speech, sound, music, transcription, dubbing, voice design…
    case generate
    /// Edits the owner's own resources.
    case modify
    /// Deletes, or edits that cannot be taken back.
    case destructive
    /// Reaches outside the account: phone calls and messages, invites, API keys, webhooks,
    /// secrets, MCP servers, auth connections, workspace membership and settings.
    case realWorld

    /// In the app these ask first; over MCP and control they need `confirm: true` and the
    /// owner's "Let agents run destructive and real-world ElevenLabs actions" switch.
    public var requiresConfirmation: Bool { self == .destructive || self == .realWorld }

    public var displayName: String {
        switch self {
        case .read: "Read"
        case .generate: "Generates (uses credits)"
        case .modify: "Changes your resources"
        case .destructive: "Destructive"
        case .realWorld: "Real-world effect"
        }
    }
}

/// A display group and how many operations it holds.
public struct ElevenLabsGroup: Sendable, Codable, Hashable, Identifiable {
    public var name: String
    public var count: Int
    public var id: String { name }

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

/// The few JSON Schema questions the client and the UI both ask.
public enum JSONSchema {
    /// The schema without its `anyOf: [X, {type: null}]` wrapper, which is how the spec
    /// spells "optional".
    public static func unwrapNullable(_ schema: JSONValue) -> JSONValue {
        guard let variants = schema["anyOf"].arrayValue else { return schema }
        let concrete = variants.filter { $0["type"].stringValue != "null" }
        return concrete.count == 1 ? concrete[0] : schema
    }

    /// Whether `null` is an accepted value.
    public static func isNullable(_ schema: JSONValue) -> Bool {
        if schema["nullable"].boolValue == true { return true }
        if schema["type"].stringValue == "null" { return true }
        return (schema["anyOf"].arrayValue ?? schema["oneOf"].arrayValue ?? [])
            .contains { $0["type"].stringValue == "null" }
    }

    public static func isArray(_ schema: JSONValue) -> Bool {
        unwrapNullable(schema)["type"].stringValue == "array"
    }

    /// Whether the schema (or its array's items) is a file upload.
    public static func isFile(_ schema: JSONValue) -> Bool {
        let schema = unwrapNullable(schema)
        if schema["format"].stringValue == "binary" { return true }
        if schema["type"].stringValue == "array" { return isFile(schema["items"]) }
        return false
    }
}
