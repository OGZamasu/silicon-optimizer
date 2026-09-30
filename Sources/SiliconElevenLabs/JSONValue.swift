import Foundation

/// Any JSON value, for arguments, schemas and results the catalog cannot type ahead of time.
///
/// Its own copy rather than `SiliconRuntime`'s: this module depends on Foundation alone, so the
/// app can link it without the runtime and nothing here drags the runtime into a test. Numbers
/// are doubles; ElevenLabs sends nothing that needs more than 53 bits.
public indirect enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Not a JSON value"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers as integers, so ids and counts go out as the API expects them.
            if value == value.rounded(), abs(value) < 9e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Reading

    public subscript(key: String) -> JSONValue {
        if case .object(let object) = self { return object[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> JSONValue {
        if case .array(let array) = self, array.indices.contains(index) { return array[index] }
        return .null
    }

    public var isNull: Bool { self == .null }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self, value == value.rounded(), abs(value) < 9e15 {
            return Int(value)
        }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    // MARK: Bytes

    /// Parses JSON text. Fragments (a bare string or number) are accepted.
    public init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// A value from `JSONSerialization`. Anything that is not JSON becomes `.null`.
    public init(foundation value: Any) {
        switch value {
        case let number as NSNumber:
            // JSONSerialization hands booleans over as NSNumber too; only their type says so.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSONValue.init(foundation:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init(foundation:)))
        default: self = .null
        }
    }

    /// Parses JSON text quickly (through `JSONSerialization`). Fragments are accepted.
    public static func parse(_ data: Data) throws -> JSONValue {
        JSONValue(foundation: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// Compact JSON with sorted keys, so the same value always produces the same bytes.
    public func encoded(pretty: Bool = false) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty
            ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("null".utf8)
    }

    /// The value as JSON text, for display.
    public func jsonString(pretty: Bool = false) -> String {
        String(decoding: encoded(pretty: pretty), as: UTF8.self)
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
