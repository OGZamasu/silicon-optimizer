import Foundation
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// One runner, several runs. A read started during another read replaces it; anything else
/// started while a run is in flight is refused and sends nothing, because the run in flight
/// may already have been billed or acted on. Cancel, then run again, is always allowed and
/// says what the cancelled request may have done. Whatever happens, a cancelled or replaced
/// run never touches the state of the run after it — not when its request completes late,
/// not when its question is withdrawn.
///
/// The first request waits on a gate the test opens, and ignores cancellation the way a
/// request already on the wire can, so "late" is decided by the test, not by the clock.
@Suite("ElevenLabs runner generations")
@MainActor
struct ShellRunnerGenerationTests {

    // MARK: - Reads: replaced, free to restart

    @Test func aCancelledReadThatFinishesLateLeavesTheNextRunAlone() async throws {
        let (fixture, gate) = Self.fixture(first: .json(["n": 1]), then: .json(["n": 2]))
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "get_models", context: fixture.context))

        let first = Task { await runner.perform(arguments: [:]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .running && fixture.transport.requests.count == 1 }
        runner.cancel()
        #expect(runner.phase == .cancelled)
        #expect(runner.cancellationNote == "Cancelled.")

        let second = await runner.perform(arguments: [:])
        #expect(Self.number(second) == 2)
        #expect(runner.phase == .succeeded)
        #expect(runner.cancellationNote == nil)

        gate.open()
        #expect(await first.value == nil)
        #expect(runner.phase == .succeeded)
        #expect(Self.number(runner.result) == 2)
        #expect(runner.failure == nil)
        #expect(fixture.pane.recents.count == 1)
    }

    @Test func aReadStartedWhileAnotherReadRunsReplacesIt() async throws {
        let (fixture, gate) = Self.fixture(first: .json(["n": 1]), then: .json(["n": 2]))
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "get_models", context: fixture.context))

        let first = Task { await runner.perform(arguments: [:]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .running && fixture.transport.requests.count == 1 }

        let second = await runner.perform(arguments: [:])
        #expect(Self.number(second) == 2)
        #expect(runner.phase == .succeeded)
        #expect(runner.refusal == nil)
        #expect(!runner.isRunning)

        gate.open()
        #expect(await first.value == nil)
        #expect(runner.phase == .succeeded)
        #expect(Self.number(runner.result) == 2)
        #expect(fixture.pane.recents.count == 1)
        #expect(fixture.transport.requests.count == 2)
    }

    // MARK: - Everything else: refused while busy

    /// A second generation while the first is in flight would be billed twice: it is refused,
    /// nothing is sent, and the first carries on to its own result.
    @Test func aGenerationStartedWhileAnotherRunsIsRefused() async throws {
        let (fixture, gate) = Self.fixture(first: .audio(Data([1])), then: .audio(Data([2])))
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "text_to_speech_full", context: fixture.context))
        #expect(runner.operation.risk == .generate)
        let arguments: [String: JSONValue] = ["voice_id": "v1", "text": "Hello"]

        let first = Task { await runner.perform(arguments: arguments) }
        try await ShellExplorerTests.waitUntil { runner.phase == .running && fixture.transport.requests.count == 1 }

        let second = await runner.perform(arguments: arguments)
        #expect(second == nil)
        #expect(runner.refusal == ElevenLabsRunner.busyMessage)
        #expect(runner.phase == .running)
        #expect(fixture.transport.requests.count == 1)

        gate.open()
        let result = await first.value
        #expect(runner.phase == .succeeded)
        #expect(runner.refusal == nil)
        #expect(try result?.files.first.map { try Data(contentsOf: $0) } == Data([1]))
        #expect(fixture.transport.requests.count == 1)
    }

    /// Cancel, then run again, is the owner's choice and allowed — and the cancelled request
    /// is said to have maybe been billed. Its late answer changes nothing.
    @Test func aCancelledGenerationMayHaveBeenBilledAndCanRunAgain() async throws {
        let (fixture, gate) = Self.fixture(first: .audio(Data([1])), then: .audio(Data([2])))
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "text_to_speech_full", context: fixture.context))
        let arguments: [String: JSONValue] = ["voice_id": "v1", "text": "Hello"]

        let first = Task { await runner.perform(arguments: arguments) }
        try await ShellExplorerTests.waitUntil { runner.phase == .running && fixture.transport.requests.count == 1 }
        runner.cancel()
        #expect(runner.phase == .cancelled)
        #expect(runner.cancellationNote == ElevenLabsRunner.cancelledAfterSendingMessage)
        #expect(runner.cancellationNote?.contains("may already have been billed or performed") == true)

        let second = await runner.perform(arguments: arguments)
        #expect(runner.phase == .succeeded)
        #expect(try second?.files.first.map { try Data(contentsOf: $0) } == Data([2]))

        gate.open()
        #expect(await first.value == nil)
        #expect(runner.phase == .succeeded)
        #expect(try runner.result?.files.first.map { try Data(contentsOf: $0) } == Data([2]))
        #expect(fixture.pane.recents.count == 1)
    }

    /// A destructive run waiting for its answer keeps its question; a second one is refused.
    @Test func aSecondRiskyRunWhileTheFirstAsksIsRefused() async throws {
        let fixture = ShellExplorerTests.Fixture(replies: [.json(["status": "ok"])])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "delete_voice", context: fixture.context))

        let first = Task { await runner.perform(arguments: ["voice_id": "a"]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .awaitingConfirmation }
        let question = try #require(runner.confirmation)

        #expect(await runner.perform(arguments: ["voice_id": "b"]) == nil)
        #expect(runner.refusal == ElevenLabsRunner.busyMessage)
        #expect(runner.confirmation?.id == question.id)
        #expect(fixture.pane.confirming === runner)

        runner.confirm()
        _ = await first.value
        #expect(runner.phase == .succeeded)
        #expect(fixture.transport.requests.map(\.url.lastPathComponent) == ["a"])
    }

    @Test func cancellingAQuestionIsDecliningIt() async throws {
        let fixture = ShellExplorerTests.Fixture()
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "delete_voice", context: fixture.context))
        let running = Task { await runner.perform(arguments: ["voice_id": "a"]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .awaitingConfirmation }
        runner.cancel()
        #expect(await running.value == nil)
        #expect(runner.phase == .idle)
        #expect(runner.cancellationNote == nil)
        #expect(fixture.pane.confirming == nil)
        #expect(fixture.transport.requests.isEmpty)
    }

    // MARK: - Fixtures

    /// The first request waits for `gate` and then answers `first`; every later one answers
    /// `then` at once.
    static func fixture(
        first: FakeElevenLabsTransport.Reply, then: FakeElevenLabsTransport.Reply
    ) -> (ShellExplorerTests.Fixture, Gate) {
        let gate = Gate()
        let count = Counter()
        let fixture = ShellExplorerTests.Fixture(handler: { _ in
            if count.next() == 1 {
                await gate.wait()
                return first
            }
            return then
        })
        return (fixture, gate)
    }

    static func number(_ result: ElevenLabsResult?) -> Int? {
        guard case .json(let value, _)? = result else { return nil }
        return value["n"].intValue
    }

    /// Opened once by the test; waiting on it ignores cancellation, as a request already on
    /// the wire does.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    if isOpen { return true }
                    waiting.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func open() {
            let released = lock.withLock {
                isOpen = true
                defer { waiting = [] }
                return waiting
            }
            released.forEach { $0.resume() }
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { value += 1; return value } }
    }
}
