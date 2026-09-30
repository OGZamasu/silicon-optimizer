import Foundation
import SiliconElevenLabs

/// One input of an operation's form, read from its JSON Schema: what it is called, where it
/// goes, what it takes and what limits it. Pure data — `ElevenLabsFormModel` holds the values.
struct ElevenLabsFormField: Identifiable, Hashable, Sendable {

    enum Location: String, CaseIterable, Sendable {
        case path, query, header, body

        var title: String {
            switch self {
            case .path: "Path"
            case .query: "Query"
            case .header: "Headers"
            case .body: "Body"
            }
        }
    }

    /// What kind of editor the field gets.
    indirect enum Kind: Hashable, Sendable {
        /// Free text. `multiline` for long prose (a script, a prompt).
        case text(multiline: Bool, format: String?)
        case integer
        case number
        case boolean
        /// One of fixed values, as the schema's `enum` lists them.
        case choice([JSONValue])
        /// A single fixed value (`const`) — a union's tag. Sent as is, shown read-only.
        case constant(JSONValue)
        /// A list; each item is edited as the template field says.
        case list(ElevenLabsFormField)
        /// Named properties, each its own field.
        case object([ElevenLabsFormField])
        /// One of several shapes (`oneOf`/`anyOf`); the owner picks which.
        case variants([Variant])
        /// A file upload (multipart); several when `multiple`.
        case file(multiple: Bool)
        /// Anything the typed editors do not cover — a map, a shape nested too deep, a schema
        /// the catalog cut short — edited as JSON text.
        case json
    }

    struct Variant: Hashable, Sendable {
        var title: String
        var field: ElevenLabsFormField
    }

    /// Limits from the schema, checked before anything is sent.
    struct Constraints: Hashable, Sendable {
        var minimum: Double?
        var maximum: Double?
        var exclusiveMinimum: Double?
        var exclusiveMaximum: Double?
        var minLength: Int?
        var maxLength: Int?
        var minItems: Int?
        var maxItems: Int?
        var pattern: String?
    }

    /// Unique in the form: location and the property path, e.g. `body.voice_settings.stability`.
    var id: String
    /// The argument name (the property's own name for nested fields).
    var name: String
    var location: Location
    var title: String
    /// The schema's description. Vendor text: shown as data.
    var description: String
    var required: Bool
    var nullable: Bool
    var deprecated: Bool
    var defaultValue: JSONValue?
    var examples: [JSONValue]
    var kind: Kind
    var constraints: Constraints

    // MARK: - Building

    /// Typed editors go this many objects/lists deep; below that, JSON text.
    static let typedDepthLimit = 4

    /// Every field of `operation`'s form, in the order it is shown: path, query and header
    /// parameters, then the body's properties — or the whole body as one JSON field when it
    /// is not an object with properties.
    static func fields(for operation: ElevenLabsOperation) -> [ElevenLabsFormField] {
        var fields: [ElevenLabsFormField] = []
        for location in [ElevenLabsParameter.Location.path, .query, .header] {
            for parameter in operation.parameters(in: location) {
                let formLocation: Location = switch location {
                case .path: .path
                case .query: .query
                case .header: .header
                }
                fields.append(field(
                    name: parameter.name, schema: parameter.schema, location: formLocation,
                    idPrefix: formLocation.rawValue,
                    required: parameter.required || location == .path,
                    description: parameter.description, defaultValue: parameter.defaultValue,
                    depth: 0, fileFields: []
                ))
            }
        }
        if let body = operation.body {
            fields += bodyFields(body)
        }
        return fields
    }

    static func bodyFields(_ body: ElevenLabsBody) -> [ElevenLabsFormField] {
        let schema = resolved(JSONSchema.unwrapNullable(body.schema))
        guard let properties = schema["properties"].objectValue, !properties.isEmpty else {
            // A union of shapes, an array, a map, or nothing typed: one field for the whole
            // body, which the client takes as `body`.
            let variants = schema["oneOf"].arrayValue ?? schema["anyOf"].arrayValue ?? []
            let kind: Kind = variants.filter({ $0["type"].stringValue != "null" }).count > 1
                ? self.kind(for: schema, id: "body.body", location: .body, depth: 0) : .json
            return [ElevenLabsFormField(
                id: "body.body", name: "body", location: .body, title: "Body",
                description: schema["description"].stringValue ?? "The request body, as JSON.",
                required: body.required, nullable: false, deprecated: false, defaultValue: nil,
                examples: [], kind: kind, constraints: Constraints()
            )]
        }
        let required = Set(schema["required"].arrayValue?.compactMap(\.stringValue) ?? [])
        return orderedKeys(properties, schema: schema).map { name in
            field(
                name: name, schema: properties[name] ?? .null, location: .body, idPrefix: "body",
                required: required.contains(name), description: nil, defaultValue: nil,
                depth: 0, fileFields: Set(body.fileFields)
            )
        }
    }

    /// One field from a property's or parameter's schema.
    static func field(
        name: String, schema raw: JSONValue, location: Location, idPrefix: String,
        required: Bool, description: String?, defaultValue: JSONValue?, depth: Int,
        fileFields: Set<String>
    ) -> ElevenLabsFormField {
        let nullable = JSONSchema.isNullable(raw)
        let schema = resolved(JSONSchema.unwrapNullable(raw))
        let id = "\(idPrefix).\(name)"
        let kind: Kind
        if depth == 0, fileFields.contains(name) || JSONSchema.isFile(schema) {
            kind = .file(multiple: JSONSchema.isArray(schema))
        } else {
            kind = self.kind(for: schema, id: id, location: location, depth: depth)
        }
        return ElevenLabsFormField(
            id: id, name: name, location: location,
            title: schema["title"].stringValue ?? raw["title"].stringValue ?? humanized(name),
            description: description.flatMap { $0.isEmpty ? nil : $0 }
                ?? raw["description"].stringValue ?? schema["description"].stringValue ?? "",
            required: required, nullable: nullable,
            deprecated: raw["deprecated"].boolValue == true || schema["deprecated"].boolValue == true,
            defaultValue: defaultValue.flatMap(nonNull) ?? nonNull(raw["default"]) ?? nonNull(schema["default"]),
            examples: (schema["examples"].arrayValue ?? []) + [schema["example"]].filter { $0 != .null },
            kind: kind,
            constraints: Constraints(
                minimum: schema["minimum"].doubleValue,
                maximum: schema["maximum"].doubleValue,
                exclusiveMinimum: schema["exclusiveMinimum"].doubleValue,
                exclusiveMaximum: schema["exclusiveMaximum"].doubleValue,
                minLength: schema["minLength"].intValue,
                maxLength: schema["maxLength"].intValue,
                minItems: schema["minItems"].intValue,
                maxItems: schema["maxItems"].intValue,
                pattern: schema["pattern"].stringValue
            )
        )
    }

    static func kind(for schema: JSONValue, id: String, location: Location, depth: Int) -> Kind {
        if let values = schema["enum"].arrayValue, !values.isEmpty {
            let concrete = values.filter { $0 != .null }
            return concrete.count == 1 && schema["type"].stringValue == nil ? .constant(concrete[0]) : .choice(concrete)
        }
        if schema["const"] != .null || schema.objectValue?.keys.contains("const") == true {
            return .constant(schema["const"])
        }
        if let variants = (schema["oneOf"].arrayValue ?? schema["anyOf"].arrayValue) {
            let concrete = variants.filter { $0["type"].stringValue != "null" }
            guard depth < typedDepthLimit, concrete.count > 1 else {
                return concrete.count == 1
                    ? kind(for: resolved(concrete[0]), id: id, location: location, depth: depth) : .json
            }
            return .variants(concrete.enumerated().map { index, variant in
                let variant = resolved(variant)
                let title = variantTitle(variant, index: index)
                return Variant(
                    title: title,
                    field: field(
                        name: "variant\(index)", schema: variant, location: location,
                        idPrefix: id, required: true, description: nil, defaultValue: nil,
                        depth: depth + 1, fileFields: []
                    )
                )
            })
        }
        switch schema["type"].stringValue {
        case "string":
            if schema["format"].stringValue == "binary" { return .file(multiple: false) }
            let long = (schema["maxLength"].intValue ?? 0) > 500
                || ["text", "prompt", "script", "content", "description", "first_message"]
                    .contains { id.hasSuffix(".\($0)") }
            return .text(multiline: long, format: schema["format"].stringValue)
        case "integer":
            return .integer
        case "number":
            return .number
        case "boolean":
            return .boolean
        case "array":
            guard depth < typedDepthLimit else { return .json }
            let items = resolved(JSONSchema.unwrapNullable(schema["items"]))
            if JSONSchema.isFile(items) { return .file(multiple: true) }
            return .list(field(
                name: "item", schema: items, location: location, idPrefix: id, required: true,
                description: nil, defaultValue: nil, depth: depth + 1, fileFields: []
            ))
        case "object", nil:
            guard let properties = schema["properties"].objectValue, !properties.isEmpty,
                  depth < typedDepthLimit
            else { return .json }
            let required = Set(schema["required"].arrayValue?.compactMap(\.stringValue) ?? [])
            return .object(orderedKeys(properties, schema: schema).map { name in
                field(
                    name: name, schema: properties[name] ?? .null, location: location,
                    idPrefix: id, required: required.contains(name), description: nil,
                    defaultValue: nil, depth: depth + 1, fileFields: []
                )
            })
        default:
            return .json
        }
    }

    // MARK: - Helpers

    /// A single-element `allOf` (how the spec attaches a description to a `$ref`) is its
    /// element; several are merged, properties and required lists together.
    static func resolved(_ schema: JSONValue) -> JSONValue {
        guard let parts = schema["allOf"].arrayValue, !parts.isEmpty,
              var merged = schema.objectValue else { return schema }
        merged["allOf"] = nil
        var properties: [String: JSONValue] = merged["properties"]?.objectValue ?? [:]
        var required: [JSONValue] = merged["required"]?.arrayValue ?? []
        for part in parts.map(resolved) {
            guard let object = part.objectValue else { continue }
            for (key, value) in object where key != "properties" && key != "required" {
                if merged[key] == nil { merged[key] = value }
            }
            properties.merge(part["properties"].objectValue ?? [:]) { first, _ in first }
            required += part["required"].arrayValue ?? []
        }
        if !properties.isEmpty { merged["properties"] = .object(properties) }
        if !required.isEmpty { merged["required"] = .array(required) }
        return .object(merged)
    }

    /// Required properties first, then the rest, each alphabetically — JSON objects carry no
    /// order, and a stable one keeps a form from reshuffling between launches.
    static func orderedKeys(_ properties: [String: JSONValue], schema: JSONValue) -> [String] {
        let required = Set(schema["required"].arrayValue?.compactMap(\.stringValue) ?? [])
        return properties.keys.sorted { lhs, rhs in
            let left = required.contains(lhs), right = required.contains(rhs)
            return left != right ? left : lhs < rhs
        }
    }

    static func variantTitle(_ variant: JSONValue, index: Int) -> String {
        if let title = variant["title"].stringValue, !title.isEmpty { return title }
        // A tagged union: the tag's constant names the variant.
        for (key, property) in variant["properties"].objectValue ?? [:]
        where ["type", "kind", "source", "mode"].contains(key) {
            if let tag = property["const"].stringValue ?? property["enum"][0].stringValue { return tag }
        }
        if let type = variant["type"].stringValue { return type }
        return "Option \(index + 1)"
    }

    /// `voice_settings` → "Voice settings".
    static func humanized(_ name: String) -> String {
        let spaced = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let first = spaced.first else { return name }
        return first.uppercased() + spaced.dropFirst()
    }

    /// Nil for JSON null. Written out, because `value == .null ? nil : value` is a JSONValue
    /// ternary — the type takes `nil` as a literal — and would hand back `.some(.null)`.
    private static func nonNull(_ value: JSONValue) -> JSONValue? {
        guard value != .null else { return nil }
        return value
    }
}
