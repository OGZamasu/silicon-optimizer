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
///
/// Each `tools/call` runs in a task of its own while the loop goes on reading, so a render or an
/// ElevenLabs conversation that takes minutes neither delays `ping` and `tools/list` nor hides
/// the client's `notifications/cancelled`. Cancelling the task cancels its request to the app,
/// and the app stops waiting on the render or ends the conversation when that connection closes.
struct MCPServer: Sendable {

    static let protocolVersion = "2025-06-18"

    /// Tool calls running at once. One more is refused with an error rather than queued: a
    /// queue would only hide that the client is waiting on work that has not started. As many
    /// as `ControlClient` keeps connections for, so every running call has its request open.
    static let maximumConcurrentCalls = ControlClient.maximumConnections

    /// How long the calls of a client that hung up get to close their requests before the
    /// bridge exits anyway.
    static let shutdownGrace: Duration = .seconds(2)

    /// One line per frame, as the client sent them. The stream ending is the client hanging up.
    let lines: AsyncStream<String>
    let tools: any ToolRunner
    let maximumConcurrentCalls: Int
    let shutdownGrace: Duration
    /// One line for whoever runs the bridge by hand — stderr, never the protocol's stdout.
    let log: @Sendable (String) -> Void
    private let output: FrameWriter
    private let calls = CallRegistry()

    /// - Parameter write: Writes one whole frame, without its newline, to the client. It is
    ///   never called again before an earlier call has returned.
    init(
        lines: AsyncStream<String>, write: @escaping @Sendable (String) -> Void,
        tools: any ToolRunner = ControlTools(),
        maximumConcurrentCalls: Int = MCPServer.maximumConcurrentCalls,
        shutdownGrace: Duration = MCPServer.shutdownGrace,
        log: @escaping @Sendable (String) -> Void = MCPServer.standardError
    ) {
        self.lines = lines
        self.output = FrameWriter(write)
        self.tools = tools
        self.maximumConcurrentCalls = maximumConcurrentCalls
        self.shutdownGrace = shutdownGrace
        self.log = log
    }

    static let standardError: @Sendable (String) -> Void = { message in
        fputs(message + "\n", stderr)
    }

    /// Tool calls whose tasks have not ended yet, cancelled ones still unwinding included.
    var callsInFlight: Int { calls.count }

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
            handle(request)
        }
        // The client hung up. Nobody is left to read an answer, and a render or a conversation
        // it started must not outlive it: cancel every call, give their requests a moment to
        // close, then return — and the process exits.
        let (tasks, cancelled) = calls.cancelAll()
        if cancelled > 0 {
            // `printf '<tools/call>' | silicon-mcp` otherwise ends in silence, with no word of why.
            log("silicon-mcp: stdin closed: cancelled \(cancelled) in-flight call(s)")
        }
        await unwind(tasks)
    }

    /// Never waits on a tool: those run in tasks of their own, so the next line is read at once.
    private func handle(_ request: RPCRequest) {
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

        case "notifications/cancelled":
            // The client has given up on a call: end it, and answer nothing, not even an error
            // — it has moved on. An id that is unknown or already answered is ignored.
            if let id = request.cancelledID, id != .null {
                calls.cancel(id)
            }

        case let method where method.hasPrefix("notifications/"):
            break   // notifications carry no id and take no response — any of them

        case "ping":
            emit(RPCResponse(id: request.id, result: .object([:])))

        case "tools/list":
            emit(RPCResponse(id: request.id, result: .object([
                "tools": .array(Tools.all.map(\.descriptor))
            ])))

        case "tools/call":
            startCall(request)

        default:
            emit(RPCResponse(
                id: request.id,
                error: .init(code: -32_601, message: "Unknown method \(request.method)")
            ))
        }
    }

    private func startCall(_ request: RPCRequest) {
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

        let ticket: CallRegistry.Ticket
        switch calls.admit(request.id, limit: maximumConcurrentCalls) {
        case .admitted(let admitted):
            ticket = admitted
        case .duplicate:
            // Cancelling by id has to name one call, so a second call under the id of one that
            // is still running is refused, and the first runs on untouched.
            emit(RPCResponse(id: request.id, error: .init(
                code: -32_600,
                message: "Request id \(request.id.wireText) belongs to a tool call that is "
                    + "still running. Give each request an id of its own."
            )))
            return
        case .busy:
            emit(RPCResponse(id: request.id, error: .init(
                code: -32_000,
                message: "\(maximumConcurrentCalls) tool calls are already running, as many as "
                    + "this bridge runs at once. Wait for one to finish, or cancel one, then "
                    + "call again."
            )))
            return
        }

        let task = Task {
            // The slot is held until the task has ended, cancelled or not, so calls that are
            // slow to unwind still count against the cap.
            defer { calls.release(ticket) }
            let response: RPCResponse
            do {
                let text = try await tools.run(name, arguments: arguments)
                response = RPCResponse(id: request.id, result: .object([
                    "content": .array([.object([
                        "type": .string("text"),
                        "text": .string(text),
                    ])]),
                    "isError": .bool(false),
                ]))
            } catch {
                // MCP wants tool failures reported as results with isError, not as protocol
                // errors: that way the model can read the message and adapt instead of the call
                // just dying.
                response = RPCResponse(id: request.id, result: .object([
                    "content": .array([.object([
                        "type": .string("text"),
                        "text": .string(error.localizedDescription),
                    ])]),
                    "isError": .bool(true),
                ]))
            }
            // A cancelled call answers nothing. `claim` settles that under the same lock as
            // `cancel`, so a call that finishes just as it is cancelled answers at most once.
            if calls.claim(ticket) { emit(response) }
        }
        calls.attach(task, to: ticket)
    }

    /// Waits for `tasks` to end, but no longer than `shutdownGrace`: a call that ignores its
    /// cancellation must not keep a bridge whose client has gone running.
    private func unwind(_ tasks: [Task<Void, Never>]) async {
        guard !tasks.isEmpty else { return }
        let (ended, end) = AsyncStream.makeStream(of: Void.self)
        let grace = shutdownGrace
        let waiting = Task {
            for task in tasks { await task.value }
            end.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: grace)
            end.finish()
        }
        for await _ in ended {}
        waiting.cancel()
        timer.cancel()
    }

    private func emit(_ response: RPCResponse) {
        guard response.id != .null || response.error != nil else { return }
        guard let data = try? JSONEncoder().encode(response),
              let line = String(data: data, encoding: .utf8) else { return }
        output.write(line)
    }
}

/// The one way out to the client. Answers finish in any order, from any task; each frame is
/// written whole under one lock, so two can never interleave.
private final class FrameWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: @Sendable (String) -> Void

    init(_ sink: @escaping @Sendable (String) -> Void) {
        self.sink = sink
    }

    func write(_ frame: String) {
        lock.withLock { sink(frame) }
    }
}

/// The tool calls in flight, each under the id its client gave it. Ids are compared as JSON
/// values: `7` and `7.0` are one id, `7` and `"7"` are two (see `RequestID`).
final class CallRegistry: @unchecked Sendable {

    struct Ticket: Hashable, Sendable {
        fileprivate let number: UInt64
    }

    enum Admission: Equatable {
        case admitted(Ticket)
        /// A call under this id is still running.
        case duplicate
        /// As many calls are running as the limit allows.
        case busy
    }

    private struct Call {
        let id: RequestID
        var task: Task<Void, Never>?
        /// Cancelled — by the client, or by its hanging up — and never to be answered.
        var cancelled = false
        /// Its answer has been claimed: the call is over as far as the client is concerned.
        var answered = false

        var isOpen: Bool { !cancelled && !answered }
    }

    private let lock = NSLock()
    private var calls: [Ticket: Call] = [:]
    private var issued: UInt64 = 0

    var count: Int { lock.withLock { calls.count } }

    /// A slot for a call, or why there is none. A cancelled call still unwinding keeps its slot
    /// but not its id. A call without an id (a notification) can be neither duplicated nor
    /// cancelled.
    func admit(_ id: RequestID, limit: Int) -> Admission {
        lock.withLock {
            if id != .null, calls.values.contains(where: { $0.id == id && $0.isOpen }) {
                return .duplicate
            }
            guard calls.count < limit else { return .busy }
            issued += 1
            let ticket = Ticket(number: issued)
            calls[ticket] = Call(id: id)
            return .admitted(ticket)
        }
    }

    /// Hands over the call's task once it exists. A task that has already ended has nothing
    /// left to attach to.
    func attach(_ task: Task<Void, Never>, to ticket: Ticket) {
        lock.withLock { calls[ticket]?.task = task }
    }

    /// Whether the call may answer: true once at most, and never once it has been cancelled.
    func claim(_ ticket: Ticket) -> Bool {
        lock.withLock {
            guard calls[ticket]?.isOpen == true else { return false }
            calls[ticket]?.answered = true
            return true
        }
    }

    /// The call's task has ended; its slot is free.
    func release(_ ticket: Ticket) {
        lock.withLock { calls[ticket] = nil }
    }

    /// Cancels the call the client knows as `id`, if one is running and unanswered.
    func cancel(_ id: RequestID) {
        let task: Task<Void, Never>? = lock.withLock {
            guard let ticket = calls.first(where: { $0.value.id == id && $0.value.isOpen })?.key
            else { return nil }
            calls[ticket]?.cancelled = true
            return calls[ticket]?.task
        }
        task?.cancel()
    }

    /// Cancels every call, for a client that has hung up. Returns every task still to end,
    /// and how many calls were still waiting on an answer — calls cancelled earlier, and answers
    /// already being written, are not among those.
    func cancelAll() -> (tasks: [Task<Void, Never>], cancelled: Int) {
        let (tasks, cancelled): ([Task<Void, Never>], Int) = lock.withLock {
            var cancelled = 0
            for ticket in calls.keys where calls[ticket]?.isOpen == true {
                calls[ticket]?.cancelled = true
                cancelled += 1
            }
            return (calls.values.compactMap(\.task), cancelled)
        }
        for task in tasks { task.cancel() }
        return (tasks, cancelled)
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

/// A request id as the client wrote it: a string or a number, kept exact. `JSONValue` holds
/// numbers as `Double`, which cannot tell 2^53 from 2^53 + 1 — two calls the client numbered
/// apart would share an id, a cancel could stop the wrong one, and the answer would carry an id
/// the client never sent. So an integer an `Int64` holds is kept as one.
enum RequestID: Codable, Equatable, Sendable {
    case integer(Int64)
    /// A string, a fraction, null, or anything else a client sends, as JSON.
    case value(JSONValue)

    static let null = RequestID.value(.null)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int64.self) {
            self = .integer(integer)
        } else {
            self = .value(try JSONValue(from: decoder))
        }
    }

    func encode(to encoder: any Encoder) throws {
        switch self {
        case .integer(let integer):
            var container = encoder.singleValueContainer()
            try container.encode(integer)
        case .value(let value):
            try value.encode(to: encoder)
        }
    }

    /// Compared as JSON values: `7` and `7.0` are one id, `7` and `"7"` are two.
    static func == (lhs: RequestID, rhs: RequestID) -> Bool {
        switch (lhs.normalized, rhs.normalized) {
        case (.integer(let left), .integer(let right)): left == right
        case (.value(let left), .value(let right)): left == right
        default: false
        }
    }

    private var normalized: RequestID {
        if case .value(.number(let number)) = self, let integer = Int64(exactly: number) {
            return .integer(integer)
        }
        return self
    }

    /// As it reads on the wire, for a message that names it.
    var wireText: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

struct RPCRequest: Decodable {
    var id: RequestID
    var method: String
    var params: JSONValue?
    /// `params.requestId` of a `notifications/cancelled`, read as exactly as `id` is.
    var cancelledID: RequestID?

    private enum CodingKeys: String, CodingKey { case id, method, params }
    private enum CancelKeys: String, CodingKey { case requestId }

    // Synthesized decoding would demand an `id` key even with a default value,
    // which made every id-less notification a "Parse error" on the wire —
    // exactly the noise a strict client (Claude Desktop) logs at the user.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(RequestID.self, forKey: .id) ?? .null
        method = try container.decode(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
        if method == "notifications/cancelled",
           let cancel = try? container.nestedContainer(keyedBy: CancelKeys.self, forKey: .params) {
            cancelledID = try? cancel.decodeIfPresent(RequestID.self, forKey: .requestId)
        }
    }
}

struct RPCResponse: Encodable {
    var jsonrpc = "2.0"
    var id: RequestID
    var result: JSONValue?
    var error: RPCError?

    struct RPCError: Encodable {
        var code: Int
        var message: String
    }

    init(id: RequestID, result: JSONValue) {
        self.id = id
        self.result = result
    }

    init(id: RequestID, error: RPCError) {
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
