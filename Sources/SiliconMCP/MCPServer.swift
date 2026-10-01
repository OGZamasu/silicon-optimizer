import Foundation
import SiliconControl

/// An MCP server over stdio.
///
/// Model Context Protocol is JSON-RPC 2.0 framed as newline-delimited JSON on stdin/stdout.
/// The protocol surface a server needs is small — `initialize`, `tools/list`, `tools/call` — so
/// this implements it directly rather than taking a dependency, which keeps the bridge a single
/// self-contained binary that any MCP client can spawn.
///
/// Every tool proxies to the running app's control server, so Claude and ChatGPT drive the model
/// the user already has loaded rather than starting a competing copy.
///
/// The frames in, the frames out and the tools are all given to it: `overStandardIO()` is the
/// bridge a client spawns, and a test drives the same loop with lines it types and fake tools.
struct MCPServer: Sendable {

    static let protocolVersion = "2025-06-18"

    /// One line per frame, as the client sent them. The stream ending is the client hanging up.
    let lines: AsyncStream<String>
    /// Writes one whole frame, without its newline, to the client.
    let write: @Sendable (String) -> Void
    let tools: any ToolRunner

    init(
        lines: AsyncStream<String>, write: @escaping @Sendable (String) -> Void,
        tools: any ToolRunner = ControlTools()
    ) {
        self.lines = lines
        self.write = write
        self.tools = tools
    }

    /// The bridge as a client spawns it: frames in on stdin, out on stdout, every tool a request
    /// to the running app.
    static func overStandardIO() -> MCPServer {
        MCPServer(lines: standardInputLines()) { frame in
            // stdout carries protocol frames only. Anything diagnostic must go to stderr or it
            // corrupts the stream — the single most common way to break an MCP server.
            fputs(frame + "\n", stdout)
            fflush(stdout)
        }
    }

    /// stdin, line by line, read on a thread of its own: `readLine` blocks, and a blocked
    /// cooperative thread is one the tools cannot use.
    static func standardInputLines() -> AsyncStream<String> {
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        Thread {
            while let line = readLine(strippingNewline: true) { continuation.yield(line) }
            continuation.finish()
        }.start()
        return lines
    }

    // MARK: - Run loop

    func run() async {
        for await line in lines {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let request = try? JSONDecoder().decode(RPCRequest.self, from: data)
            else {
                emit(RPCResponse(id: .null, error: .init(code: -32_700, message: "Parse error")))
                continue
            }
            await handle(request)
        }
    }

    private func handle(_ request: RPCRequest) async {
        switch request.method {
        case "initialize":
            emit(RPCResponse(id: request.id, result: .object([
                "protocolVersion": .string(Self.protocolVersion),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object([
                    "name": .string("silicon-optimizer"),
                    "version": .string("0.1.0"),
                ]),
            ])))

        case let method where method.hasPrefix("notifications/"):
            break   // notifications carry no id and take no response — any of them

        case "ping":
            emit(RPCResponse(id: request.id, result: .object([:])))

        case "tools/list":
            emit(RPCResponse(id: request.id, result: .object([
                "tools": .array(Tools.all.map(\.descriptor))
            ])))

        case "tools/call":
            await callTool(request)

        default:
            emit(RPCResponse(
                id: request.id,
                error: .init(code: -32_601, message: "Unknown method \(request.method)")
            ))
        }
    }

    private func callTool(_ request: RPCRequest) async {
        guard case .object(let params)? = request.params,
              case .string(let name)? = params["name"] else {
            emit(RPCResponse(
                id: request.id, error: .init(code: -32_602, message: "Missing tool name")
            ))
            return
        }
        let arguments: [String: JSONValue] = {
            if case .object(let value)? = params["arguments"] { return value }
            return [:]
        }()

        do {
            let text = try await tools.run(name, arguments: arguments)
            emit(RPCResponse(id: request.id, result: .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(text),
                ])]),
                "isError": .bool(false),
            ])))
        } catch {
            // MCP wants tool failures reported as results with isError, not as protocol errors:
            // that way the model can read the message and adapt instead of the call just dying.
            emit(RPCResponse(id: request.id, result: .object([
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string(error.localizedDescription),
                ])]),
                "isError": .bool(true),
            ])))
        }
    }

    private func emit(_ response: RPCResponse) {
        guard response.id != .null || response.error != nil else { return }
        guard let data = try? JSONEncoder().encode(response),
              let line = String(data: data, encoding: .utf8) else { return }
        write(line)
    }
}

/// Runs one tool by name. The bridge's runs `Tools.invoke` against the app's control API; a
/// test gives a fake, so the server can be driven without the app.
protocol ToolRunner: Sendable {
    func run(_ name: String, arguments: [String: JSONValue]) async throws -> String
}

/// The tools as the bridge runs them: each one a request to the running app.
struct ControlTools: ToolRunner {
    let client: ControlClient

    init(client: ControlClient = ControlClient()) {
        self.client = client
    }

    func run(_ name: String, arguments: [String: JSONValue]) async throws -> String {
        try await Tools.invoke(name, arguments: arguments, client: client)
    }
}

// MARK: - JSON-RPC types

struct RPCRequest: Decodable {
    var id: JSONValue
    var method: String
    var params: JSONValue?

    private enum CodingKeys: String, CodingKey { case id, method, params }

    // Synthesized decoding would demand an `id` key even with a default value,
    // which made every id-less notification a "Parse error" on the wire —
    // exactly the noise a strict client (Claude Desktop) logs at the user.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(JSONValue.self, forKey: .id) ?? .null
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
    }
}

struct RPCResponse: Encodable {
    var jsonrpc = "2.0"
    var id: JSONValue
    var result: JSONValue?
    var error: RPCError?

    struct RPCError: Encodable {
        var code: Int
        var message: String
    }

    init(id: JSONValue, result: JSONValue) {
        self.id = id
        self.result = result
    }

    init(id: JSONValue, error: RPCError) {
        self.id = id
        self.error = error
    }
}

/// A minimal JSON tree. MCP payloads are shallow, so this avoids pulling in a JSON library while
/// still letting tool schemas be expressed literally.
indirect enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .null }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Encode whole numbers as integers so ids round-trip as the client sent them.
            if value == value.rounded(), abs(value) < 9e15 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// A fraction is truncated, as it always was; a number no `Int` can hold is no number
    /// at all, like a string that does not parse. `Int(_: Double)` traps on those — a
    /// seed of 2^64-1 or 1e20 in any tool's arguments used to kill the bridge.
    var intValue: Int? {
        switch self {
        case .number(let value): Int(exactly: value.rounded(.towardZero))
        case .string(let value): Int(value)
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}
