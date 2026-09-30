import Foundation
import SiliconElevenLabs

/// Where every control on the creative screens (Speech through Models) gets its argument
/// name, its choices, its limits and its default: the pinned catalog, never memory.
///
/// A control names the operations it is sent to and the argument it sets, as a path —
/// `voice_settings.stability`, `inputs[].voice_id`, `additional_formats[].format` — and
/// `schema(_:_:)` finds that argument in the operation's parameters or body schema. The
/// creative tests walk every control of every screen through it, so a spec refresh that
/// renames or drops an argument fails a test instead of sending something ElevenLabs no
/// longer takes.
enum CreativeSpec {

    // MARK: - Finding an argument

    /// The schema of `path` in `operationID`, or nil when the operation has no such argument
    /// (or the catalog has no such operation).
    static func schema(_ operationID: String, _ path: String) -> JSONValue? {
        guard let operation = ElevenLabsCatalog.operation(operationID) else { return nil }
        return schema(in: operation, path: path)
    }

    /// The schema of `path` in `operation`: the first segment is a parameter (path, query or
    /// header) or a body property; each later one a property of the object before it, and
    /// `name[]` steps into a list's items. The schema comes back as written — nullable
    /// wrapper, default and description included — so `defaultValue` can read what sits on
    /// the wrapper.
    static func schema(in operation: ElevenLabsOperation, path: String) -> JSONValue? {
        var segments = path.split(separator: ".").map(String.init)
        guard !segments.isEmpty else { return nil }
        let first = segments.removeFirst()
        let (firstName, firstIsList) = split(first)
        var current: JSONValue
        if let parameter = operation.parameter(named: firstName) {
            current = parameter.schema
        } else if let property = bodyProperties(operation)?[firstName] {
            current = property
        } else {
            return nil
        }
        if firstIsList {
            guard let items = items(of: current) else { return nil }
            current = items
        }
        for segment in segments {
            let (name, isList) = split(segment)
            guard let property = property(named: name, in: current) else { return nil }
            current = property
            if isList {
                guard let items = items(of: current) else { return nil }
                current = items
            }
        }
        return current
    }

    /// Whether `operationID` takes `path`.
    static func has(_ operationID: String, _ path: String) -> Bool {
        schema(operationID, path) != nil
    }

    /// The body's top-level properties, or nil when the body is not an object with any.
    static func bodyProperties(_ operation: ElevenLabsOperation) -> [String: JSONValue]? {
        guard let body = operation.body else { return nil }
        return normalized(body.schema)["properties"].objectValue
    }

    /// The schema without its nullable wrapper, with a lone `allOf` merged in.
    static func normalized(_ schema: JSONValue) -> JSONValue {
        ElevenLabsFormField.resolved(JSONSchema.unwrapNullable(schema))
    }

    private static func split(_ segment: String) -> (String, Bool) {
        segment.hasSuffix("[]") ? (String(segment.dropLast(2)), true) : (segment, false)
    }

    private static func items(of schema: JSONValue) -> JSONValue? {
        let items = normalized(schema)["items"]
        return items == .null ? nil : items
    }

    /// A property of an object schema, looking into each shape of a union when the object is
    /// one (`additional_formats[]` is a union tagged by `format`).
    private static func property(named name: String, in schema: JSONValue) -> JSONValue? {
        let object = normalized(schema)
        let own = object["properties"][name]
        if own != .null { return own }
        for variant in variants(of: object) {
            let property = normalized(variant)["properties"][name]
            if property != .null { return property }
        }
        return nil
    }

    /// The concrete shapes of a union (`oneOf`/`anyOf`), nulls left out.
    static func variants(of schema: JSONValue) -> [JSONValue] {
        (schema["oneOf"].arrayValue ?? schema["anyOf"].arrayValue ?? [])
            .filter { $0["type"].stringValue != "null" }
    }

    // MARK: - What an argument takes

    /// The values an argument's `enum` lists, as strings, in the spec's order.
    static func choices(_ operationID: String, _ path: String) -> [String] {
        guard let schema = schema(operationID, path) else { return [] }
        let normalized = normalized(schema)
        if let values = normalized["enum"].arrayValue {
            return values.compactMap(\.stringValue)
        }
        // A union of enums (some output formats are written as one enum per container).
        var seen = Set<String>()
        return variants(of: normalized).flatMap { ($0["enum"].arrayValue ?? []).compactMap(\.stringValue) }
            .filter { seen.insert($0).inserted }
    }

    /// The tags of a tagged union's shapes: `additional_formats[]`'s `format` constants.
    static func variantTags(_ operationID: String, _ path: String, tag: String) -> [String] {
        guard let schema = schema(operationID, path) else { return [] }
        return variants(of: normalized(schema)).compactMap { variant in
            let property = normalized(variant)["properties"][tag]
            return property["const"].stringValue ?? property["enum"][0].stringValue
        }
    }

    /// The spec's default for an argument: the parameter's own, the wrapper's, or the
    /// concrete schema's.
    static func defaultValue(_ operationID: String, _ path: String) -> JSONValue? {
        if !path.contains("."), !path.contains("[]"),
           let parameter = ElevenLabsCatalog.operation(operationID)?.parameter(named: path),
           let value = parameter.defaultValue, value != .null {
            return value
        }
        guard let schema = schema(operationID, path) else { return nil }
        for candidate in [schema["default"], normalized(schema)["default"]] where candidate != .null {
            return candidate
        }
        return nil
    }

    static func defaultString(_ operationID: String, _ path: String) -> String? {
        defaultValue(operationID, path)?.stringValue
    }

    static func defaultNumber(_ operationID: String, _ path: String) -> Double? {
        defaultValue(operationID, path)?.doubleValue
    }

    static func defaultBool(_ operationID: String, _ path: String) -> Bool? {
        defaultValue(operationID, path)?.boolValue
    }

    /// Example values the schema gives (the transcription model's `scribe_v2`, say).
    static func examples(_ operationID: String, _ path: String) -> [String] {
        guard let schema = schema(operationID, path) else { return [] }
        let normalized = normalized(schema)
        let listed = (normalized["examples"].arrayValue ?? schema["examples"].arrayValue ?? [])
            .compactMap(\.stringValue)
        return listed + [normalized["example"].stringValue].compactMap { $0 }
    }

    /// Whether the spec marks the argument deprecated.
    static func isDeprecated(_ operationID: String, _ path: String) -> Bool {
        guard let schema = schema(operationID, path) else { return false }
        return schema["deprecated"].boolValue == true || normalized(schema)["deprecated"].boolValue == true
    }

    /// Enum values the spec marks deprecated where the catalog cannot say (the raw spec keeps
    /// them in an `x-fern-enum` extension the catalog leaves out). A test holds this to the
    /// pinned spec.
    static let deprecatedValues: [String: Set<String>] = [
        "MusicModelID": ["music_v1"],
    ]

    /// `value` in words for a picker, with "(deprecated)" when the spec says so.
    static func choiceTitle(_ value: String, schemaTitle: String) -> String {
        let title = ElevenLabsFormField.humanized(value)
        return deprecatedValues[schemaTitle]?.contains(value) == true ? title + " (deprecated)" : title
    }

    static func maxLength(_ operationID: String, _ path: String) -> Int? {
        schema(operationID, path).flatMap { normalized($0)["maxLength"].intValue }
    }

    static func minLength(_ operationID: String, _ path: String) -> Int? {
        schema(operationID, path).flatMap { normalized($0)["minLength"].intValue }
    }

    static func maxItems(_ operationID: String, _ path: String) -> Int? {
        schema(operationID, path).flatMap { normalized($0)["maxItems"].intValue }
    }

    /// The range a number takes: the schema's own bounds, or — where the schema leaves them
    /// out — the documented range from `fallbackRanges`. Nil when neither says.
    static func range(_ operationID: String, _ path: String) -> ClosedRange<Double>? {
        if let bounds = schemaRange(operationID, path) { return bounds }
        return fallback(operationID, path)?.range
    }

    /// Only what the schema itself says: `minimum`/`exclusiveMinimum` and
    /// `maximum`/`exclusiveMaximum`, both present.
    static func schemaRange(_ operationID: String, _ path: String) -> ClosedRange<Double>? {
        guard let schema = schema(operationID, path) else { return nil }
        let concrete = normalized(schema)
        let lower = concrete["minimum"].doubleValue ?? concrete["exclusiveMinimum"].doubleValue
        let upper = concrete["maximum"].doubleValue ?? concrete["exclusiveMaximum"].doubleValue
        guard let lower, let upper, lower <= upper else { return nil }
        return lower...upper
    }

    /// Whether the lower bound itself is excluded (`finetune_strength` must be above 0).
    static func excludesLowerBound(_ operationID: String, _ path: String) -> Bool {
        schema(operationID, path).map { normalized($0)["exclusiveMinimum"] != .null } ?? false
    }

    // MARK: - Ranges the schema leaves out

    /// Why a range that is not in an argument's own schema can be trusted.
    enum Evidence: Hashable, Sendable {
        /// The argument's description states it; the text must still contain this.
        case description(String)
        /// The same setting carries these bounds in another operation's schema.
        case boundedIn(operationID: String, property: String)
    }

    struct Fallback: Hashable, Sendable {
        var range: ClosedRange<Double>
        var evidence: Evidence
    }

    /// Ranges for sliders whose schema is an unbounded number. Keyed `operation:path`, or
    /// `*:path` for every operation. `CreativeSpecTests` checks each entry's evidence against
    /// the catalog, so a spec that changes the range fails there.
    static let fallbackRanges: [String: Fallback] = {
        var table: [String: Fallback] = [
        "sound_generation:duration_seconds": Fallback(
            range: 0.5...30, evidence: .description("at least 0.5 and at most 30")
        ),
        "sound_generation:prompt_influence": Fallback(
            range: 0...1, evidence: .description("between 0 and 1")
        ),
        "*:voice_settings.speed": Fallback(
            range: 0.7...1.2,
            evidence: .boundedIn(operationID: "create_text_to_speech_generation", property: "speed")
        ),
        "*:voice_settings.style": Fallback(
            range: 0...1,
            evidence: .boundedIn(operationID: "create_text_to_speech_generation", property: "style")
        ),
        ]
        // Seeds whose schema is unbounded state their range in the description; music and
        // transcription bound theirs in the schema (at 2147483647), which wins.
        for id in ["text_to_speech_full", "text_to_speech_full_with_timestamps", "text_to_speech_stream",
                   "text_to_speech_stream_with_timestamps", "text_to_dialogue", "text_to_dialogue_stream",
                   "text_to_dialogue_stream_with_timestamps", "text_to_dialogue_full_with_timestamps",
                   "speech_to_speech_full", "speech_to_speech_stream"] {
            table["\(id):seed"] = Fallback(range: 0...4_294_967_295, evidence: .description("between 0 and 4294967295"))
        }
        return table
    }()

    static func fallback(_ operationID: String, _ path: String) -> Fallback? {
        fallbackRanges["\(operationID):\(path)"] ?? fallbackRanges["*:\(path)"]
    }

    // MARK: - Values only the description lists

    /// Values an argument takes that its description names but its schema does not enumerate,
    /// each with the text that must stay in the description.
    static let documentedValues: [String: [(value: String, evidence: String)]] = [
        "speech_to_text:entity_detection": [
            ("all", "'all'"), ("pii", "'pii'"), ("phi", "'phi'"), ("pci", "'pci'"),
            ("other", "'other'"), ("offensive_language", "'offensive_language'"),
        ],
        "speech_to_text:entity_redaction_mode": [
            ("redacted", "'redacted'"), ("entity_type", "'entity_type'"),
            ("enumerated_entity_type", "'enumerated_entity_type'"),
        ],
        "download_speech_history_items:output_format": [
            ("wav", "wav"), ("default", "default"),
        ],
    ]

    static func documented(_ operationID: String, _ path: String) -> [String] {
        documentedValues["\(operationID):\(path)"]?.map(\.value) ?? []
    }

    // MARK: - Checking built arguments

    /// Every name in `arguments` that `operation` does not take, as a dotted path — for the
    /// tests that fill a screen completely and check what it would send.
    static func unknownArguments(_ arguments: [String: JSONValue], for operation: ElevenLabsOperation) -> [String] {
        var unknown: [String] = []
        for (name, value) in arguments {
            guard let schema = schema(in: operation, path: name) else {
                unknown.append(name)
                continue
            }
            unknown += unknownKeys(value, schema: schema, path: name)
        }
        return unknown.sorted()
    }

    private static func unknownKeys(_ value: JSONValue, schema: JSONValue, path: String) -> [String] {
        let concrete = normalized(schema)
        switch value {
        case .object(let object):
            let shapes = [concrete] + variants(of: concrete).map(normalized)
            let described = shapes.compactMap { $0["properties"].objectValue }
            // A map (`additionalProperties`) or a shape the catalog cut short: nothing to check.
            guard !described.isEmpty else { return [] }
            var unknown: [String] = []
            for (key, inner) in object {
                guard let property = described.lazy.compactMap({ $0[key] }).first else {
                    unknown.append("\(path).\(key)")
                    continue
                }
                unknown += unknownKeys(inner, schema: property, path: "\(path).\(key)")
            }
            return unknown
        case .array(let array):
            let items = concrete["items"]
            guard items != .null else { return [] }
            return array.flatMap { unknownKeys($0, schema: items, path: "\(path)[]") }
        default:
            return []
        }
    }
}

/// One control on a creative screen: what it is called on screen, the operations it is sent
/// to, and the argument it sets there.
struct CreativeControl: Hashable, Sendable {
    var label: String
    var operations: [String]
    var argument: String

    init(_ label: String, _ operations: [String], _ argument: String) {
        self.label = label
        self.operations = operations
        self.argument = argument
    }
}

/// A screen whose controls the catalog tests walk.
@MainActor
protocol CreativeScreenModel: AnyObject {
    /// Every control on the screen.
    static var controls: [CreativeControl] { get }
    /// Every operation the screen reaches.
    static var operationIDs: [String] { get }
}
