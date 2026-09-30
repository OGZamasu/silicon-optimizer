import Foundation
import Testing
@testable import SiliconElevenLabs

/// Every one of the 403 operations, built from arguments derived from its own schemas, sent
/// through the client to the in-memory transport, and checked against the raw spec — not the
/// catalog, so a generator mistake shows up here too: method, path, query, headers, content
/// type and body.
@Suite("ElevenLabs spec conformance")
struct CoreConformanceTests {

    static let key = "sk_" + String(repeating: "conformance", count: 3)
    static let pathSample = "id 1/x"

    @Test func everyOperationIsReachableThroughCallAndBuildsWhatTheSpecSays() async throws {
        let snapshot = CoreCatalogTests.repository.appendingPathComponent("Scripts/elevenlabs/openapi.json")
        let spec = try JSONValue.parse(Data(contentsOf: snapshot))
        let transport = FakeElevenLabsTransport { request in Self.reply(for: request) }
        let sink = TemporaryFileSink()
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs-conformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {
            sink.removeAll()
            transport.removeTemporaryFiles()
            TemporaryFileSink.removeScratch(scratch)
        }
        let client = ElevenLabsClient(credentials: FakeCredentialSource(key: Self.key), region: .global,
                                      transport: transport, sink: sink)

        var specOperations: [String: (method: String, path: String, item: JSONValue)] = [:]
        for (path, item) in spec["paths"].objectValue ?? [:] {
            for method in ["get", "post", "put", "patch", "delete"] where item[method] != .null {
                specOperations[item[method]["operationId"].stringValue ?? ""] = (method.uppercased(), path, item[method])
            }
        }
        #expect(specOperations.count == 403)
        #expect(Set(specOperations.keys) == Set(ElevenLabsCatalog.all.map(\.id)))

        var checked = 0
        for operation in ElevenLabsCatalog.all {
            let raw = try #require(specOperations[operation.id], "\(operation.id) is not in the spec")
            #expect(operation.method == raw.method, "\(operation.id)")
            #expect(operation.path == raw.path, "\(operation.id)")

            // Arguments from the schemas: every path and query parameter, required headers, and
            // the body's required fields (or one optional one when nothing is required).
            var arguments: [String: JSONValue] = [:]
            for parameter in operation.parameters where parameter.location != .header || parameter.required {
                let plain = JSONSchema.unwrapNullable(parameter.schema)
                let freeText = plain["type"] == "string" && plain["enum"] == .null && plain.objectValue?["const"] == nil
                arguments[parameter.name] = parameter.location == .path && freeText
                    ? .string(Self.pathSample) : Sample.value(for: parameter.schema, name: parameter.name)
            }
            var expectedBody: [String: JSONValue] = [:]
            var files: [String: [ElevenLabsFile]] = [:]
            if let body = operation.body {
                let schema = Sample.bodySchema(body.schema)
                let properties = schema["properties"].objectValue ?? [:]
                var names = schema["required"].arrayValue?.compactMap(\.stringValue) ?? []
                if names.isEmpty, let first = properties.keys.sorted().first(where: { !body.fileFields.contains($0) }) {
                    names = [first]
                }
                for name in names where !body.fileFields.contains(name) {
                    expectedBody[name] = Sample.value(for: properties[name] ?? .null, name: name)
                }
                for field in body.fileFields {
                    let file = scratch.appendingPathComponent("\(operation.id)-\(field).bin")
                    try Data("file for \(field)".utf8).write(to: file)
                    files[field] = [ElevenLabsFile(url: file, contentType: "application/octet-stream")]
                }
                for (name, value) in expectedBody { arguments[name] = value }
            }

            let before = transport.recorded.count
            do {
                _ = try await client.call(operation.id, arguments: arguments, files: files)
            } catch {
                Issue.record("\(operation.id): \(error)")
                continue
            }
            let recorded = transport.recorded
            #expect(recorded.count == before + 1, "\(operation.id) sent \(recorded.count - before) requests")
            guard let sent = recorded.last else { continue }
            let request = sent.request
            checked += 1

            let rawParameters = raw.item["parameters"].arrayValue ?? []

            // Method, host, path.
            #expect(request.method == raw.method, "\(operation.id)")
            #expect(request.url.host == "api.elevenlabs.io", "\(operation.id)")
            var expectedPath = raw.path
            for parameter in rawParameters where parameter["in"] == "path" {
                let name = parameter["name"].stringValue ?? ""
                let text = arguments[name].flatMap(ElevenLabsRequestBuilder.scalarText) ?? ""
                expectedPath = expectedPath.replacingOccurrences(
                    of: "{\(name)}", with: text == Self.pathSample ? "id%201%2Fx" : text
                )
            }
            #expect(request.url.path(percentEncoded: true) == expectedPath, "\(operation.id)")

            // Query and headers, against the raw spec's parameter list.
            let queryNames = Set(rawParameters.filter { $0["in"] == "query" }.compactMap { $0["name"].stringValue })
            let sentQuery = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(Set(sentQuery.map(\.name)) == queryNames.intersection(arguments.keys), "\(operation.id)")
            for item in sentQuery {
                let given = arguments[item.name]
                if case .array(let values)? = given {
                    #expect(sentQuery.filter { $0.name == item.name }.count == values.count, "\(operation.id) \(item.name)")
                } else {
                    #expect(item.value == given.flatMap(ElevenLabsRequestBuilder.scalarText) ?? given?.jsonString(),
                            "\(operation.id) \(item.name)")
                }
            }
            for parameter in rawParameters where parameter["in"] == "header" && parameter["name"] != "xi-api-key" {
                if let name = parameter["name"].stringValue, arguments[name] != nil {
                    #expect(request.header(name) == arguments[name]?.stringValue, "\(operation.id) \(name)")
                }
            }
            #expect(request.header("xi-api-key") == Self.key, "\(operation.id)")

            // Body and content type, against the raw spec's request body.
            let content = raw.item["requestBody"]["content"].objectValue ?? [:]
            if content.isEmpty {
                #expect(sent.body.isEmpty, "\(operation.id) sent a body it does not take")
                #expect(request.header("Content-Type") == nil, "\(operation.id)")
            } else if content["multipart/form-data"] != nil {
                let type = try #require(request.header("Content-Type"), "\(operation.id)")
                #expect(type.hasPrefix("multipart/form-data; boundary="), "\(operation.id)")
                let parts = MultipartMixed.split(sent.body, boundary: String(type.dropFirst("multipart/form-data; boundary=".count)))
                var sentNames: [String: Int] = [:]
                for part in parts {
                    let name = part.headers["content-disposition"]?.components(separatedBy: "name=\"").dropFirst().first?
                        .components(separatedBy: "\"").first ?? "?"
                    sentNames[name, default: 0] += 1
                }
                var expectedNames: [String: Int] = [:]
                for (name, value) in expectedBody {
                    expectedNames[name] = ElevenLabsRequestBuilder.textParts(name: name, value: value).count
                }
                for field in files.keys { expectedNames[field, default: 0] += 1 }
                #expect(sentNames == expectedNames, "\(operation.id)")
            } else {
                #expect(content["application/json"] != nil, "\(operation.id)")
                #expect(request.header("Content-Type") == "application/json", "\(operation.id)")
                #expect((try? JSONValue(data: sent.body)) == .object(expectedBody), "\(operation.id)")
            }
            #expect(!request.url.absoluteString.contains(Self.key), "\(operation.id)")
        }
        #expect(checked == 403)
        #expect(transport.hostViolations.isEmpty)
    }

    /// A plausible success for any request, shaped by what the operation answers.
    static func reply(for request: ElevenLabsRequest) -> FakeElevenLabsTransport.Reply {
        guard let operation = ElevenLabsCatalog.operation(request.operationID) else {
            return .jsonText("{}", status: 500)
        }
        switch operation.response {
        case .audio: return .audio(Data([0x49, 0x44, 0x33]))
        case .binary(let type): return .init(status: 200, headers: ["content-type": type], body: Data("binary".utf8))
        case .text: return .init(status: 200, headers: ["content-type": "text/html"], body: Data("<p/>".utf8))
        case .events:
            return .init(status: 200, headers: ["content-type": "text/event-stream"],
                         body: Data("event: done\ndata: {}\n\n".utf8))
        case .multipartMixed:
            return .init(status: 200, headers: ["content-type": "multipart/mixed; boundary=b"],
                         body: Data("--b\r\nContent-Type: application/json\r\n\r\n{}\r\n--b--\r\n".utf8))
        case .json: return .json([:])
        }
    }
}

/// Values that satisfy a schema: enums take their first option, defaults their default,
/// objects their required properties, and so on down to a bounded depth.
enum Sample {
    static func bodySchema(_ schema: JSONValue) -> JSONValue {
        let unwrapped = JSONSchema.unwrapNullable(schema)
        if let variants = unwrapped["oneOf"].arrayValue ?? unwrapped["anyOf"].arrayValue,
           let first = variants.first(where: { $0["type"].stringValue != "null" }) {
            return first
        }
        return unwrapped
    }

    static func value(for schema: JSONValue, name: String, depth: Int = 0) -> JSONValue {
        let schema = JSONSchema.unwrapNullable(schema)
        if let constant = schema.objectValue?["const"] { return constant }
        if let first = schema["enum"].arrayValue?.first { return first }
        if let fallback = schema.objectValue?["default"], fallback != .null, depth > 0 || !(fallback.arrayValue?.isEmpty ?? false) {
            return fallback
        }
        if let variants = schema["anyOf"].arrayValue ?? schema["oneOf"].arrayValue,
           let first = variants.first(where: { $0["type"].stringValue != "null" }) {
            return value(for: first, name: name, depth: depth)
        }
        switch schema["type"].stringValue {
        case "string":
            switch schema["format"].stringValue {
            case "date-time": return "2026-09-29T12:00:00Z"
            case "date": return "2026-09-29"
            case "uri", "url": return "https://example.com/source"
            case "email": return "someone@example.com"
            default: return .string("sample-\(name)")
            }
        case "integer":
            if let minimum = schema["minimum"].doubleValue { return .number(minimum.rounded(.up)) }
            if let minimum = schema["exclusiveMinimum"].doubleValue { return .number(minimum.rounded(.down) + 1) }
            return 1
        case "number":
            if let minimum = schema["minimum"].doubleValue, let maximum = schema["maximum"].doubleValue {
                return .number((minimum + maximum) / 2)
            }
            return .number(schema["minimum"].doubleValue ?? 0.5)
        case "boolean":
            return true
        case "array":
            guard depth < 4 else { return [] }
            return [value(for: schema["items"], name: name, depth: depth + 1)]
        case "object":
            guard depth < 4 else { return [:] }
            let properties = schema["properties"].objectValue ?? [:]
            var object: [String: JSONValue] = [:]
            for required in schema["required"].arrayValue?.compactMap(\.stringValue) ?? [] {
                object[required] = value(for: properties[required] ?? .null, name: required, depth: depth + 1)
            }
            return .object(object)
        default:
            return .string("sample-\(name)")
        }
    }
}
