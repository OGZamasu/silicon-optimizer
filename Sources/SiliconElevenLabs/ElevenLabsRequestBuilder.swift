import Foundation

/// A call checked and laid out for the wire — everything but the key, which the client adds
/// at the moment it sends.
struct PreparedCall: Sendable {
    enum Body: Sendable {
        case none
        case json(JSONValue)
        case multipart([MultipartPart])
    }

    var operation: ElevenLabsOperation
    var url: URL
    /// Headers besides the key: content type is added when the body is built.
    var headers: [String: String]
    var body: Body

    /// What "Show API call" shows.
    func describe() -> ElevenLabsCallDescription {
        var shown = headers
        shown["xi-api-key"] = ElevenLabsRedaction.placeholder
        var bodyDescription: JSONValue?
        switch body {
        case .none:
            break
        case .json(let value):
            shown["Content-Type"] = "application/json"
            bodyDescription = value
        case .multipart(let parts):
            shown["Content-Type"] = "multipart/form-data"
            var fields: [String: JSONValue] = [:]
            for part in parts {
                let entry: JSONValue
                switch part.value {
                case .text(let text): entry = .string(text)
                case .file(let file, let size):
                    entry = ["file": .string(file.filename), "contentType": .string(file.contentType),
                             "bytes": .number(Double(size))]
                }
                if case .array(let existing)? = fields[part.name] {
                    fields[part.name] = .array(existing + [entry])
                } else if let existing = fields[part.name] {
                    fields[part.name] = .array([existing, entry])
                } else {
                    fields[part.name] = entry
                }
            }
            bodyDescription = .object(fields)
        }
        return ElevenLabsCallDescription(
            operationID: operation.id, method: operation.method, url: url.absoluteString,
            headers: shown, body: bodyDescription
        )
    }
}

/// One field of a multipart body.
struct MultipartPart: Sendable {
    enum Value: Sendable {
        case text(String)
        case file(ElevenLabsFile, size: Int64)
    }

    var name: String
    var value: Value
}

/// Turns an operation and its arguments into a `PreparedCall`, or into every reason it can't.
///
/// Arguments are one flat dictionary: path, query and header parameters by name, and the
/// body's fields by name. A JSON body may instead be given whole as `body` (when the body has
/// no field of that name). Multipart file fields come separately, as files on disk.
enum ElevenLabsRequestBuilder {

    static func prepare(
        _ operation: ElevenLabsOperation, arguments: [String: JSONValue],
        files: [String: [ElevenLabsFile]], region: ElevenLabsRegion, uploadLimit: Int64
    ) -> Result<PreparedCall, ElevenLabsError> {
        var problems: [String] = []

        // Parameters.
        var path = operation.path
        var query: [(String, String)] = []
        var headers: [String: String] = [:]
        for parameter in operation.parameters {
            let value = arguments[parameter.name]
            guard let value, value != .null else {
                if parameter.required { problems.append("missing required \(parameter.location.rawValue) parameter \"\(parameter.name)\"") }
                continue
            }
            problems += typeProblems(value, schema: parameter.schema, name: parameter.name)
            switch parameter.location {
            case .path:
                guard let text = scalarText(value), !text.isEmpty else {
                    problems.append("path parameter \"\(parameter.name)\" must be a non-empty string or number")
                    continue
                }
                path = path.replacingOccurrences(
                    of: "{\(parameter.name)}", with: percentEncode(text, allowed: segmentAllowed)
                )
            case .query:
                if case .array(let items) = value {
                    // OpenAPI's default for query arrays: form style, exploded — the name repeated.
                    for item in items {
                        guard let text = scalarText(item) else {
                            problems.append("query parameter \"\(parameter.name)\" takes strings or numbers")
                            continue
                        }
                        query.append((parameter.name, text))
                    }
                } else {
                    query.append((parameter.name, scalarText(value) ?? value.jsonString()))
                }
            case .header:
                guard let text = scalarText(value), !text.contains(where: \.isNewline) else {
                    problems.append("header \"\(parameter.name)\" must be a single-line string")
                    continue
                }
                headers[parameter.name] = text
            }
        }

        // Body.
        let parameterNames = Set(operation.parameters.map(\.name))
        var body: PreparedCall.Body = .none
        if let spec = operation.body {
            let schema = JSONSchema.unwrapNullable(spec.schema)
            let known = knownFields(of: schema)
            var fields: [String: JSONValue] = [:]
            if let whole = arguments["body"], !(known?.contains("body") ?? false), !parameterNames.contains("body") {
                guard case .object(let object) = whole else {
                    return .failure(.invalidArguments(problems + ["\"body\" must be a JSON object"]))
                }
                fields = object
                for (name, _) in arguments where name != "body" && !parameterNames.contains(name) {
                    problems.append("\"\(name)\" was given alongside a whole \"body\"; put it inside the body")
                }
            } else {
                for (name, value) in arguments where !parameterNames.contains(name) {
                    fields[name] = value
                }
            }
            problems += bodyProblems(fields, schema: schema, known: known, spec: spec, files: files)

            switch spec.contentType {
            case .json:
                if !files.isEmpty {
                    problems.append("this operation takes a JSON body, not files")
                }
                if !fields.isEmpty || spec.required {
                    body = .json(.object(fields))
                }
            case .multipart:
                var parts: [MultipartPart] = []
                for name in fields.keys.sorted() {
                    guard let value = fields[name], value != .null else { continue }
                    parts += textParts(name: name, value: value)
                }
                var total: Int64 = 0
                for field in files.keys.sorted() {
                    guard spec.fileFields.contains(field) else {
                        problems.append("\"\(field)\" is not a file field of this operation (it takes: \(spec.fileFields.joined(separator: ", ")))")
                        continue
                    }
                    let list = files[field] ?? []
                    if list.count > 1, !spec.acceptsMultipleFiles(field) {
                        problems.append("\"\(field)\" takes one file, not \(list.count)")
                    }
                    for file in list {
                        switch fileSize(file.url) {
                        case .success(let size):
                            total += size
                            parts.append(MultipartPart(name: field, value: .file(file, size: size)))
                        case .failure(let problem):
                            problems.append("\"\(field)\": \(problem.text)")
                        }
                    }
                }
                if total > uploadLimit {
                    problems.append("the files add up to \(total) bytes, past the \(uploadLimit)-byte upload limit")
                }
                if !parts.isEmpty || spec.required {
                    body = .multipart(parts)
                }
            }
        } else {
            for name in arguments.keys.sorted() where !parameterNames.contains(name) {
                problems.append("unknown argument \"\(name)\" (this operation has no body)")
            }
            if !files.isEmpty { problems.append("this operation takes no files") }
        }

        guard problems.isEmpty else { return .failure(.invalidArguments(problems)) }

        var components = URLComponents()
        components.scheme = "https"
        components.host = region.host
        components.percentEncodedPath = path
        if !query.isEmpty {
            components.percentEncodedQuery = query
                .map { "\(percentEncode($0.0, allowed: queryAllowed))=\(percentEncode($0.1, allowed: queryAllowed))" }
                .joined(separator: "&")
        }
        guard let url = components.url else {
            return .failure(.invalidArguments(["the arguments do not make a valid URL"]))
        }
        return .success(PreparedCall(operation: operation, url: url, headers: headers, body: body))
    }

    // MARK: - Checking

    /// Top-level problems with a body: missing required fields, unknown fields, wrong types.
    static func bodyProblems(
        _ fields: [String: JSONValue], schema: JSONValue, known: Set<String>?, spec: ElevenLabsBody,
        files: [String: [ElevenLabsFile]]
    ) -> [String] {
        var problems: [String] = []
        let properties = schema["properties"].objectValue ?? [:]
        let required = schema["required"].arrayValue?.compactMap(\.stringValue) ?? []
        for name in required {
            let isFile = spec.fileFields.contains(name)
            let present = isFile ? !(files[name] ?? []).isEmpty : (fields[name].map { $0 != .null } ?? false)
            if !present, spec.required || !fields.isEmpty || !files.isEmpty {
                problems.append(isFile ? "missing required file \"\(name)\"" : "missing required field \"\(name)\"")
            }
        }
        if let known {
            for name in fields.keys.sorted() where !known.contains(name) {
                problems.append("unknown argument \"\(name)\"")
            }
        }
        for name in fields.keys.sorted() {
            guard let value = fields[name], let property = properties[name] else { continue }
            if spec.fileFields.contains(name) {
                problems.append("\"\(name)\" is a file: pass it in files, not arguments")
                continue
            }
            problems += typeProblems(value, schema: property, name: name)
        }
        return problems
    }

    /// Field names a body accepts, or nil when it accepts anything (open objects, or a schema
    /// this bounded catalog could not see into).
    static func knownFields(of schema: JSONValue) -> Set<String>? {
        if schema["x-truncated"] == true { return nil }
        if let additional = schema.objectValue?["additionalProperties"], additional != false { return nil }
        if let variants = schema["oneOf"].arrayValue ?? schema["anyOf"].arrayValue {
            var union = Set<String>()
            for variant in variants where variant["type"].stringValue != "null" {
                guard let names = knownFields(of: variant) else { return nil }
                union.formUnion(names)
            }
            return union
        }
        guard let properties = schema["properties"].objectValue else { return nil }
        return Set(properties.keys)
    }

    /// Whether `value` fits `schema` at its own level: type, enum, const. Nested objects and
    /// arrays of objects are left to ElevenLabs, which reports them precisely.
    static func typeProblems(_ value: JSONValue, schema: JSONValue, name: String) -> [String] {
        if schema["x-truncated"] == true { return [] }
        if value == .null {
            return JSONSchema.isNullable(schema) ? [] : ["\"\(name)\" must not be null"]
        }
        let unwrapped = JSONSchema.unwrapNullable(schema)
        if let variants = unwrapped["anyOf"].arrayValue ?? unwrapped["oneOf"].arrayValue {
            let concrete = variants.filter { $0["type"].stringValue != "null" }
            if concrete.isEmpty || concrete.contains(where: { typeProblems(value, schema: $0, name: name).isEmpty }) {
                return []
            }
            return ["\"\(name)\" does not match any of the shapes it accepts"]
        }
        if let constant = unwrapped.objectValue?["const"], constant != value {
            return ["\"\(name)\" must be \(constant.jsonString())"]
        }
        if let options = unwrapped["enum"].arrayValue, !options.isEmpty, !options.contains(value) {
            let listed = options.prefix(12).map { $0.stringValue ?? $0.jsonString() }.joined(separator: ", ")
            return ["\"\(name)\" must be one of: \(listed)\(options.count > 12 ? ", …" : "")"]
        }
        switch unwrapped["type"].stringValue {
        case "string":
            if case .string = value { return [] }
            return ["\"\(name)\" must be a string"]
        case "integer":
            if case .number(let number) = value, number == number.rounded() { return [] }
            return ["\"\(name)\" must be a whole number"]
        case "number":
            if case .number = value { return [] }
            return ["\"\(name)\" must be a number"]
        case "boolean":
            if case .bool = value { return [] }
            return ["\"\(name)\" must be true or false"]
        case "array":
            guard case .array(let items) = value else { return ["\"\(name)\" must be an array"] }
            let itemSchema = unwrapped["items"]
            guard itemSchema != .null else { return [] }
            return Array(items.enumerated().flatMap { index, item in
                typeProblems(item, schema: itemSchema, name: "\(name)[\(index)]")
            }.prefix(3))
        case "object":
            if case .object = value { return [] }
            return ["\"\(name)\" must be an object"]
        default:
            return []
        }
    }

    // MARK: - Encoding

    /// A multipart field's text parts: strings as they are, numbers and booleans as JSON,
    /// arrays of scalars as the field repeated, anything else as JSON text.
    static func textParts(name: String, value: JSONValue) -> [MultipartPart] {
        if case .array(let items) = value, items.allSatisfy({ scalarText($0) != nil }) {
            return items.compactMap { scalarText($0).map { MultipartPart(name: name, value: .text($0)) } }
        }
        return [MultipartPart(name: name, value: .text(scalarText(value) ?? value.jsonString()))]
    }

    /// A scalar as the API writes it in a URL or form field; nil for arrays and objects.
    static func scalarText(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text): text
        case .bool(let flag): flag ? "true" : "false"
        case .number(let number):
            number == number.rounded() && abs(number) < 9e15 ? String(Int64(number)) : String(number)
        case .null, .array, .object: nil
        }
    }

    struct FileProblem: Error { var text: String }

    static func fileSize(_ url: URL) -> Result<Int64, FileProblem> {
        guard url.isFileURL else { return .failure(.init(text: "\(url.lastPathComponent) is not a local file")) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return .failure(.init(text: "\(url.lastPathComponent) does not exist or cannot be read"))
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return .failure(.init(text: "\(url.lastPathComponent) is not a regular file"))
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return .failure(.init(text: "\(url.lastPathComponent) cannot be read"))
        }
        return .success((attributes[.size] as? NSNumber)?.int64Value ?? 0)
    }

    /// RFC 3986 unreserved characters only. ASCII spelled out: `CharacterSet.alphanumerics`
    /// would let non-ASCII letters through unencoded.
    private static let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    static let queryAllowed = CharacterSet(charactersIn: unreserved)
    /// A path segment: unreserved plus the sub-delimiters a segment may carry. Never `/`, so
    /// an id cannot climb into another route.
    static let segmentAllowed = CharacterSet(charactersIn: unreserved + "!$&'()*+,=:@")

    static func percentEncode(_ text: String, allowed: CharacterSet) -> String {
        text.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
