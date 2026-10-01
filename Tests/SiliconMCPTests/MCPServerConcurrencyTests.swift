import Foundation
import Testing
@testable import SiliconMCP

/// Tool calls run beside each other and beside the read loop: a long call — a render, an
/// ElevenLabs conversation — can be cancelled while it runs, never holds up anything else, and
/// ends when the client hangs up. The `wait` fake stands in for the control request behind it.
@Suite("MCP server concurrency and cancellation")
struct MCPServerConcurrencyTests {

    @Test func cancellingARunningCallStopsItsRequestAndAnswersNothing() async throws {
        let bridge = Bridge()
        bridge.call(1, "wait", ["tag": "render"])
        bridge.call("conversation", "wait", ["tag": "talk"])
        try await running(bridge, "render", "talk")

        bridge.cancel(1)
        bridge.cancel("conversation", reason: "The user pressed stop.")
        try await eventually(.seconds(10), "both requests to be cancelled") {
            bridge.tools.fate("render") == .cancelled && bridge.tools.fate("talk") == .cancelled
                ? true : nil
        }
        try await eventually(.seconds(10), "both tasks to end") {
            bridge.server.callsInFlight == 0 ? true : nil
        }
        try await bridge.sync()
        // Only the sync's pong: the spec says a cancelled request gets no response at all.
        #expect(bridge.frames.answers(to: 1).isEmpty)
        #expect(bridge.frames.answers(to: "conversation").isEmpty)
        #expect(bridge.frames.all.count == 1)
        try await bridge.end()
    }

    /// Ids are JSON values: a number and the same digits as a string are two requests, and
    /// `9` and `9.0` are one.
    @Test func aCancelNamesItsCallByTheIdsJSONValue() async throws {
        let bridge = Bridge()
        bridge.call(9, "wait", ["tag": "number"])
        bridge.call("9", "wait", ["tag": "string"])
        try await running(bridge, "number", "string")

        bridge.cancel("9")
        try await eventually(.seconds(10), "the string id's call to be cancelled") {
            bridge.tools.fate("string") == .cancelled ? true : nil
        }
        try await bridge.sync()
        #expect(bridge.tools.fate("number") == .running)

        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9.0}}"#)
        try await eventually(.seconds(10), "the number id's call to be cancelled") {
            bridge.tools.fate("number") == .cancelled ? true : nil
        }
        try await eventually(.seconds(10), "both tasks to end") {
            bridge.server.callsInFlight == 0 ? true : nil
        }
        try await bridge.sync()
        #expect(bridge.frames.all.count == 2)
        try await bridge.end()
    }

    @Test func otherRequestsAreAnsweredWhileALongCallRuns() async throws {
        let bridge = Bridge()
        bridge.call(1, "wait", ["tag": "render"])
        try await running(bridge, "render")

        bridge.send(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#)
        bridge.send(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)
        bridge.send(#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#)
        bridge.call(5, "echo", ["text": "quick"])
        #expect(try await bridge.answer(2)["result"]["protocolVersion"] == .string(MCPServer.protocolVersion))
        #expect(try await bridge.answer(3)["result"] == .object([:]))
        #expect(try await bridge.answer(4)["result"]["tools"].arrayValue?.isEmpty == false)
        #expect(try await bridge.answer(5)["result"]["content"] == [["type": "text", "text": "echo: quick"]])
        #expect(bridge.tools.fate("render") == .running)
        #expect(bridge.frames.answers(to: 1).isEmpty)

        // And the long call still answers when it is done.
        bridge.tools.release("render", with: "rendered")
        #expect(try await bridge.answer(1)["result"]["content"] == [["type": "text", "text": "rendered"]])
        try await bridge.end()
    }

    /// Many answers finishing together, from many tasks, with pings answered from the read loop
    /// in between: every frame is written whole and alone.
    @Test func framesNeverInterleave() async throws {
        let calls = 64
        let bridge = Bridge(maximumConcurrentCalls: calls)
        let padding = String(repeating: "frame ", count: 4_000)
        for round in 0..<4 {
            let tags = (0..<calls).map { "round\(round)-call\($0)" }
            for (index, tag) in tags.enumerated() {
                bridge.call(.number(Double(round * 1_000 + index)), "wait", ["tag": .string(tag)])
            }
            try await running(bridge, tags)
            await withTaskGroup(of: Void.self) { group in
                for tag in tags {
                    group.addTask { bridge.tools.release(tag, with: padding + tag) }
                }
                for ping in 0..<16 {
                    bridge.send(["jsonrpc": "2.0", "id": .string("ping-\(round)-\(ping)"), "method": "ping"])
                }
            }
            try await eventually(.seconds(20), "round \(round)'s answers") {
                bridge.frames.all.count == (round + 1) * (calls + 16) ? true : nil
            }
            for (index, tag) in tags.enumerated() {
                let answer = try await bridge.answer(.number(Double(round * 1_000 + index)))
                #expect(answer["result"]["content"] == [["type": "text", "text": .string(padding + tag)]])
            }
            for ping in 0..<16 { _ = try await bridge.answer(.string("ping-\(round)-\(ping)")) }
        }
        #expect(bridge.frames.overlaps == 0)
        let frames = bridge.frames.all
        #expect(frames.count == 4 * (calls + 16))
        #expect(!frames.contains(.null), "a frame that is not one JSON object on one line")
        let ids = frames.map { $0["id"] }
        #expect(Set(ids.map(\.wireKey)).count == ids.count, "an id answered twice")
        try await bridge.end()
    }

    @Test func aHangUpCancelsEveryCallAndEndsTheLoop() async throws {
        let bridge = Bridge()
        let tags = ["render", "conversation", "image"]
        for (index, tag) in tags.enumerated() { bridge.call(.number(Double(index)), "wait", ["tag": .string(tag)]) }
        try await running(bridge, tags)

        bridge.hangUp()
        try await eventually(.seconds(10), "the loop to end") { bridge.hasExited ? true : nil }
        for tag in tags { #expect(bridge.tools.fate(tag) == .cancelled, "\(tag)") }
        #expect(bridge.server.callsInFlight == 0)
        #expect(bridge.frames.all.isEmpty)
    }

    /// A call that ignores its cancellation holds the exit up for the grace period, no longer.
    @Test func aHangUpWaitsOnlyBrieflyForACallThatIgnoresCancellation() async throws {
        let bridge = Bridge(shutdownGrace: .milliseconds(200))
        bridge.call(1, "stubborn", ["tag": "stuck"])
        try await running(bridge, "stuck")

        let start = ContinuousClock.now
        bridge.hangUp()
        try await eventually(.seconds(10), "the loop to end") { bridge.hasExited ? true : nil }
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(bridge.tools.fate("stuck") == .running)

        // When it does finish, there is nobody to answer.
        bridge.tools.release("stuck")
        try await eventually(.seconds(10), "the stubborn task to end") {
            bridge.server.callsInFlight == 0 ? true : nil
        }
        #expect(bridge.frames.all.isEmpty)
    }

    @Test func aCallPastTheCapIsRefusedWithAnError() async throws {
        let bridge = Bridge()
        let cap = MCPServer.maximumConcurrentCalls
        let tags = (0..<cap).map { "slot\($0)" }
        for (index, tag) in tags.enumerated() { bridge.call(.number(Double(index)), "wait", ["tag": .string(tag)]) }
        try await running(bridge, tags)

        bridge.call(100, "echo", ["text": "one too many"])
        let refused = try await bridge.answer(100)
        #expect(refused["error"]["code"] == -32_000)
        #expect(refused["error"]["message"].stringValue?.contains("\(cap) tool calls are already running") == true)
        #expect(refused["result"] == .null)
        #expect(!bridge.tools.ran.contains("echo"))
        #expect(bridge.server.callsInFlight == cap)
        try await bridge.sync()   // and the loop is still answering

        // A cancelled call gives its slot back once its task has ended.
        bridge.cancel(0)
        try await eventually(.seconds(10), "the cancelled call's slot") {
            bridge.server.callsInFlight == cap - 1 ? true : nil
        }
        bridge.call(101, "echo", ["text": "fits now"])
        #expect(try await bridge.answer(101)["result"]["content"] == [["type": "text", "text": "echo: fits now"]])
        try await bridge.end()
        for tag in tags { #expect(bridge.tools.fate(tag) == .cancelled, "\(tag)") }
    }

    /// The cap counts tasks, not answers: a cancelled call that has not unwound yet still holds
    /// its slot, so call-and-cancel cannot pile up tasks without bound.
    @Test func aCancelledCallHoldsItsSlotUntilItHasUnwound() async throws {
        let bridge = Bridge(maximumConcurrentCalls: 2, shutdownGrace: .milliseconds(200))
        bridge.call(1, "stubborn", ["tag": "slow-to-stop"])
        try await running(bridge, "slow-to-stop")
        bridge.cancel(1)
        bridge.call(2, "wait", ["tag": "second"])
        try await running(bridge, "second")
        bridge.call(3, "echo", ["text": "third"])
        #expect(try await bridge.answer(3)["error"]["code"] == -32_000)

        bridge.tools.release("slow-to-stop")
        try await eventually(.seconds(10), "the stubborn call's slot") {
            bridge.server.callsInFlight == 1 ? true : nil
        }
        bridge.call(4, "echo", ["text": "fourth"])
        #expect(try await bridge.answer(4)["result"]["content"] == [["type": "text", "text": "echo: fourth"]])
        // The cancelled call answered nothing even though it finished normally.
        #expect(bridge.frames.answers(to: 1).isEmpty)
        try await bridge.end()
    }

    @Test func aSecondCallUnderARunningCallsIdIsRefused() async throws {
        let bridge = Bridge()
        bridge.call(7, "wait", ["tag": "first"])
        try await running(bridge, "first")

        bridge.call(7, "echo", ["text": "second"])
        let refused = try await bridge.answer(7)
        #expect(refused["error"]["code"] == -32_600)
        #expect(refused["error"]["message"].stringValue?.contains("Request id 7 ") == true)
        #expect(!bridge.tools.ran.contains("echo"))
        #expect(bridge.tools.fate("first") == .running)

        // The same digits as a string are another id.
        bridge.call("7", "echo", ["text": "string id"])
        #expect(try await bridge.answer("7")["result"]["content"] == [["type": "text", "text": "echo: string id"]])
        bridge.cancel("7")   // answered already: ignored, and the number id is untouched
        try await bridge.sync()
        #expect(bridge.tools.fate("first") == .running)

        bridge.tools.release("first", with: "first done")
        try await eventually(.seconds(10), "the first call's answer") {
            bridge.frames.answers(to: 7).count == 2 ? true : nil
        }
        #expect(bridge.frames.answers(to: 7)[1]["result"]["content"] == [["type": "text", "text": "first done"]])

        // Once answered, the id names nothing running, so a new call may use it.
        bridge.call(7, "echo", ["text": "again"])
        try await eventually(.seconds(10), "the reused id's answer") {
            bridge.frames.answers(to: 7).count == 3 ? true : nil
        }
        #expect(bridge.frames.answers(to: 7)[2]["result"]["content"] == [["type": "text", "text": "echo: again"]])
        try await bridge.end()
    }

    /// A cancel that arrives as the call finishes: whichever wins, the call answers at most
    /// once, a call whose request saw the cancel answers nothing, and an answer that does go
    /// out is the call's own result.
    @Test func aCancelRacingTheAnswerAnswersAtMostOnce() async throws {
        let bridge = Bridge()
        let rounds = 200
        for round in 0..<rounds {
            let id = JSONValue.number(Double(round))
            let tag = "race\(round)"
            bridge.call(id, "wait", ["tag": .string(tag)])
            try await running(bridge, tag)
            // Back to back either way round, and a millisecond apart either way round, so both
            // outcomes and the moments between them all come up.
            switch round % 4 {
            case 0:
                bridge.cancel(id)
                bridge.tools.release(tag, with: "finished \(round)")
            case 1:
                bridge.tools.release(tag, with: "finished \(round)")
                bridge.cancel(id)
            case 2:
                bridge.cancel(id)
                try await Task.sleep(for: .milliseconds(1))
                bridge.tools.release(tag, with: "finished \(round)")
            default:
                bridge.tools.release(tag, with: "finished \(round)")
                try await Task.sleep(for: .milliseconds(1))
                bridge.cancel(id)
            }
            try await eventually(.seconds(10), "round \(round) to end") {
                bridge.server.callsInFlight == 0 ? true : nil
            }
        }
        try await bridge.end()
        var answered = 0
        for round in 0..<rounds {
            let answers = bridge.frames.answers(to: .number(Double(round)))
            #expect(answers.count <= 1, "round \(round) answered \(answers.count) times")
            if bridge.tools.fate("race\(round)") == .cancelled {
                #expect(answers.isEmpty, "round \(round): its request was cancelled, yet it answered")
            }
            if let answer = answers.first {
                answered += 1
                #expect(answer["result"]["isError"] == false, "round \(round)")
                #expect(answer["result"]["content"] == [["type": "text", "text": .string("finished \(round)")]])
            }
        }
        #expect(bridge.frames.all.count == answered)
    }

    @Test func aCancelForNoRunningCallIsIgnoredSilently() async throws {
        let bridge = Bridge()
        bridge.cancel(404)
        bridge.call(5, "echo", ["text": "done already"])
        _ = try await bridge.answer(5)
        bridge.cancel(5)
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#)
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"reason":"no id"}}"#)
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":null}}"#)
        bridge.send(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":"not an object"}"#)
        try await bridge.sync()
        #expect(bridge.frames.all.count == 2)
        try await bridge.end()
    }

    // MARK: Helpers

    private func running(_ bridge: Bridge, _ tags: String...) async throws {
        try await running(bridge, tags)
    }

    /// Waits until each tagged call has reached its fake request.
    private func running(_ bridge: Bridge, _ tags: [String]) async throws {
        try await eventually(.seconds(10), "\(tags.count) calls to start") {
            tags.allSatisfy { bridge.tools.fate($0) == .running } ? true : nil
        }
    }
}

private extension JSONValue {
    /// A hashable stand-in, for counting distinct ids.
    var wireKey: String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self)
    }
}
