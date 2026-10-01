import Foundation
import Testing
@testable import SiliconMCP

/// The protocol surface of the bridge — what each method answers, and what it never answers —
/// driven through the run loop with typed lines and fake tools: no process, no stdin, no app.
@Suite("MCP server frames")
struct MCPServerTests {

    @Test func initializeNamesTheProtocolAndTheTools() async throws {
        let bridge = Bridge()
        bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#)
        let answer = try await bridge.answer(1)
        #expect(answer["jsonrpc"] == "2.0")
        #expect(answer["result"]["protocolVersion"] == .string(MCPServer.protocolVersion))
        #expect(answer["result"]["capabilities"]["tools"]["listChanged"] == false)
        #expect(answer["result"]["serverInfo"]["name"] == "silicon-optimizer")
        try await bridge.end()
    }

    @Test func pingAndToolsListAnswerWithTheirOwnIds() async throws {
        let bridge = Bridge()
        bridge.send(#"{"jsonrpc":"2.0","id":"p-1","method":"ping"}"#)
        bridge.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(try await bridge.answer("p-1")["result"] == .object([:]))
        let tools = try await bridge.answer(2)["result"]["tools"].arrayValue ?? []
        #expect(tools.map { $0["name"] } == Tools.all.map { .string($0.name) })
        try await bridge.end()
    }

    @Test func aToolsResultIsTextAndAToolsFailureIsAnErrorResult() async throws {
        let bridge = Bridge()
        bridge.call(1, "echo", ["text": "hello"])
        bridge.call(2, "fail", ["text": "no node offers that model"])
        let answered = try await bridge.answer(1)
        #expect(answered["result"]["isError"] == false)
        #expect(answered["result"]["content"] == [["type": "text", "text": "echo: hello"]])
        // MCP wants a tool's failure as a result the model can read, not a protocol error.
        let failed = try await bridge.answer(2)
        #expect(failed["error"] == .null)
        #expect(failed["result"]["isError"] == true)
        #expect(failed["result"]["content"] == [["type": "text", "text": "no node offers that model"]])
        #expect(bridge.tools.ran.sorted() == ["echo", "fail"])
        try await bridge.end()
    }

    @Test func protocolMistakesAreErrorsAndNotificationsAreSilent() async throws {
        let bridge = Bridge()
        bridge.send("this is not json")
        bridge.send("   ")
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":42}}"#)
        bridge.send(#"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)
        bridge.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{}}"#)
        #expect(try await bridge.answer(3)["error"]["code"] == -32_601)
        #expect(try await bridge.answer(4)["error"] == ["code": -32_602, "message": "Missing tool name"])
        try await bridge.sync()
        // The parse error, the two answers, and the sync's pong: nothing for the blank line
        // or either notification.
        #expect(bridge.frames.all.count == 4)
        #expect(bridge.frames.all.first?["error"]["code"] == -32_700)
        #expect(bridge.frames.all.first?["id"] == .null)
        #expect(bridge.tools.ran.isEmpty)
        try await bridge.end()
    }

    @Test func theLoopEndsWhenTheClientHangsUp() async throws {
        let bridge = Bridge()
        bridge.send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        _ = try await bridge.answer(1)
        try await bridge.end()
        #expect(bridge.hasExited)
    }
}

// MARK: - Harness

/// One bridge, running: `send` types a line into it, `frames` is everything it wrote, and its
/// tools are `FakeTools`.
final class Bridge: Sendable {
    let server: MCPServer
    let frames: FrameLog
    let tools: FakeTools
    private let input: AsyncStream<String>.Continuation
    private let exited = Flag()

    init(tools: FakeTools = FakeTools()) {
        let (lines, input) = AsyncStream.makeStream(of: String.self)
        let frames = FrameLog()
        let server = MCPServer(lines: lines, write: { frames.write($0) }, tools: tools)
        self.server = server
        self.frames = frames
        self.tools = tools
        self.input = input
        let flag = self.exited
        Task {
            await server.run()
            flag.set()
        }
    }

    var hasExited: Bool { exited.isSet }

    func send(_ line: String) { input.yield(line) }

    func send(_ message: JSONValue) {
        send(String(decoding: try! JSONEncoder().encode(message), as: UTF8.self))
    }

    func call(_ id: JSONValue, _ tool: String, _ arguments: [String: JSONValue] = [:]) {
        send([
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": .string(tool), "arguments": .object(arguments)],
        ])
    }

    func cancel(_ id: JSONValue, reason: String = "The user stopped it.") {
        send([
            "jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": ["requestId": id, "reason": .string(reason)],
        ])
    }

    /// The client closes its end of stdin.
    func hangUp() { input.finish() }

    /// The one frame answering `id`, once it has arrived.
    func answer(_ id: JSONValue, within limit: Duration = .seconds(10)) async throws -> JSONValue {
        try await eventually(limit, "an answer to \(id)") { self.frames.answers(to: id).first }
    }

    /// A ping round trip. The loop reads lines in order, so once its answer is back every line
    /// sent before it has been read and handled.
    func sync() async throws {
        let id = JSONValue.string("sync-\(UUID().uuidString)")
        send(["jsonrpc": "2.0", "id": id, "method": "ping"])
        _ = try await answer(id)
    }

    /// Hangs up and waits for the loop to return.
    func end(within limit: Duration = .seconds(10)) async throws {
        hangUp()
        try await eventually(limit, "the loop to end") { self.hasExited ? true : nil }
    }
}

/// What the bridge wrote, frame by frame. Each `write` is checked as it happens: it must be one
/// whole JSON object on one line, and no other write may be in progress at the same time.
final class FrameLog: Sendable {
    private let state = Locked(State())

    private struct State {
        var lines: [String] = []
        var writing = 0
        var overlaps = 0
    }

    func write(_ line: String) {
        state.withLock {
            $0.writing += 1
            if $0.writing > 1 { $0.overlaps += 1 }
        }
        // Long enough for a second writer to arrive if writes are not serialised.
        usleep(50)
        state.withLock {
            $0.lines.append(line)
            $0.writing -= 1
        }
    }

    /// Writes that began while another was still in progress.
    var overlaps: Int { state.withLock { $0.overlaps } }

    var lines: [String] { state.withLock { $0.lines } }

    /// Every frame, parsed. A line that is not one JSON object parses as `.null`.
    var all: [JSONValue] {
        lines.map { line in
            guard !line.contains("\n"),
                  let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  value.objectValue != nil
            else { return .null }
            return value
        }
    }

    func answers(to id: JSONValue) -> [JSONValue] {
        all.filter { $0.objectValue?["id"] == id }
    }
}

/// Tools that stand in for the control API. Each call is told apart by its `tag` argument.
///
/// - `echo` answers at once with its `text`; `fail` throws its `text`.
/// - `wait` is a long request — a render, a conversation: it runs until `release(tag)` or until
///   its task is cancelled, which ends it at once the way `URLSession` ends a request.
/// - `stubborn` ignores cancellation and runs until released.
final class FakeTools: ToolRunner, Sendable {
    enum Fate: Equatable, Sendable { case running, answered, cancelled }

    struct Failure: LocalizedError { var errorDescription: String? }

    private let state = Locked(State())

    private struct State {
        var ran: [String] = []
        var fates: [String: Fate] = [:]
        var waiting: [String: CheckedContinuation<String, any Error>] = [:]
        var released: [String: String] = [:]
        var cancelled: Set<String> = []
    }

    /// Tool names in the order their calls began.
    var ran: [String] { state.withLock { $0.ran } }

    func fate(_ tag: String) -> Fate? { state.withLock { $0.fates[tag] } }

    var running: Int { state.withLock { $0.fates.values.filter { $0 == .running }.count } }

    func run(_ name: String, arguments: [String: JSONValue]) async throws -> String {
        let tag = arguments["tag"]?.stringValue ?? UUID().uuidString
        let text = arguments["text"]?.stringValue ?? ""
        state.withLock {
            $0.ran.append(name)
            $0.fates[tag] = .running
        }
        do {
            let answer: String
            switch name {
            case "echo": answer = "echo: \(text)"
            case "fail": throw Failure(errorDescription: text)
            case "wait": answer = try await waitForRelease(tag, honouringCancellation: true)
            case "stubborn": answer = try await waitForRelease(tag, honouringCancellation: false)
            default: throw Tools.ToolError.unknown(name)
            }
            state.withLock { $0.fates[tag] = .answered }
            return answer
        } catch {
            state.withLock { $0.fates[tag] = $0.cancelled.contains(tag) ? .cancelled : .answered }
            throw error
        }
    }

    /// Ends the `wait` or `stubborn` call with this tag, now or as soon as it starts.
    func release(_ tag: String, with answer: String = "done") {
        let waiter = state.withLock {
            $0.released[tag] = answer
            return $0.waiting.removeValue(forKey: tag)
        }
        waiter?.resume(returning: answer)
    }

    private func waitForRelease(_ tag: String, honouringCancellation: Bool) async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                let early: Result<String, any Error>? = state.withLock {
                    if let answer = $0.released[tag] { return .success(answer) }
                    if honouringCancellation, $0.cancelled.contains(tag) { return .failure(CancellationError()) }
                    $0.waiting[tag] = continuation
                    return nil
                }
                if let early { continuation.resume(with: early) }
            }
        } onCancel: {
            guard honouringCancellation else { return }
            let waiter = state.withLock {
                $0.cancelled.insert(tag)
                return $0.waiting.removeValue(forKey: tag)
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

/// A value behind a lock, for the fakes above: they are called from the bridge's tasks and
/// read from the test at the same time.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

final class Flag: Sendable {
    private let value = Locked(false)
    var isSet: Bool { value.withLock { $0 } }
    func set() { value.withLock { $0 = true } }
}

struct TimedOut: Error, CustomStringConvertible {
    var waitingFor: String
    var description: String { "Timed out waiting for \(waitingFor)" }
}

/// Polls `condition` until it gives a value, or throws after `limit`.
@discardableResult
func eventually<T>(
    _ limit: Duration = .seconds(10), _ what: String = "a condition",
    _ condition: () async throws -> T?
) async throws -> T {
    let deadline = ContinuousClock.now + limit
    while true {
        if let value = try await condition() { return value }
        guard ContinuousClock.now < deadline else { throw TimedOut(waitingFor: what) }
        try await Task.sleep(for: .milliseconds(2))
    }
}
