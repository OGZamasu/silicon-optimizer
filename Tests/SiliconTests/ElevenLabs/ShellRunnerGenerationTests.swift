import Foundation
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// One runner, several runs: a run that was cancelled or replaced never touches the state of
/// the run after it — not when its request completes late, not when its question is withdrawn.
///
/// The first request waits on a gate the test opens, and ignores cancellation the way a
/// request already on the wire can, so "late" is decided by the test, not by the clock.
@Suite("ElevenLabs runner generations")
@MainActor
struct ShellRunnerGenerationTests {

    @Test func aCancelledRunThatFinishesLateLeavesTheNextRunAlone() async throws {
        let (fixture, gate) = Self.fixture()
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "get_models", context: fixture.context))

        let first = Task { await runner.perform(arguments: [:]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .running && fixture.transport.requests.count == 1 }
        runner.cancel()
        #expect(runner.phase == .cancelled)

        let second = await runner.perform(arguments: [:])
        #expect(Self.number(second) == 2)
        #expect(runner.phase == .succeeded)

        gate.open()
        #expect(await first.value == nil)
        #expect(runner.phase == .succeeded)
        #expect(Self.number(runner.result) == 2)
        #expect(runner.failure == nil)
        #expect(fixture.pane.recents.count == 1)
    }

    @Test func aRunStartedWhileAnotherRunsReplacesIt() async throws {
        let (fixture, gate) = Self.fixture()
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "get_models", context: fixture.context))

        let first = Task { await runner.perform(arguments: [:]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .running && fixture.transport.requests.count == 1 }

        let second = await runner.perform(arguments: [:])
        #expect(Self.number(second) == 2)
        #expect(runner.phase == .succeeded)
        #expect(!runner.isRunning)

        gate.open()
        #expect(await first.value == nil)
        #expect(runner.phase == .succeeded)
        #expect(Self.number(runner.result) == 2)
        #expect(fixture.pane.recents.count == 1)
        #expect(fixture.transport.requests.count == 2)
    }

    @Test func aNewRunWithdrawsTheQuestionTheOldOneAsked() async throws {
        let fixture = ShellExplorerTests.Fixture(replies: [.json(["status": "ok"])])
        defer { fixture.clean() }
        let runner = try #require(ElevenLabsRunner(operationID: "delete_voice", context: fixture.context))

        let first = Task { await runner.perform(arguments: ["voice_id": "a"]) }
        try await ShellExplorerTests.waitUntil { runner.phase == .awaitingConfirmation }
        let firstQuestion = try #require(runner.confirmation)

        let second = Task { await runner.perform(arguments: ["voice_id": "b"]) }
        try await ShellExplorerTests.waitUntil { runner.confirmation.map { $0.id != firstQuestion.id } == true }
        #expect(await first.value == nil)
        // The old frame woke after the new question went up, and left it there.
        #expect(runner.phase == .awaitingConfirmation)
        #expect(fixture.pane.confirming === runner)

        runner.confirm()
        _ = await second.value
        #expect(runner.phase == .succeeded)
        #expect(fixture.transport.requests.map(\.url.lastPathComponent) == ["b"])
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
        #expect(fixture.pane.confirming == nil)
        #expect(fixture.transport.requests.isEmpty)
    }

    // MARK: - Fixtures

    /// The first request waits for `gate` and then answers `{"n": 1}`; every later one answers
    /// `{"n": 2}` at once.
    static func fixture() -> (ShellExplorerTests.Fixture, Gate) {
        let gate = Gate()
        let count = Counter()
        let fixture = ShellExplorerTests.Fixture(handler: { _ in
            if count.next() == 1 {
                await gate.wait()
                return .json(["n": 1])
            }
            return .json(["n": 2])
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
