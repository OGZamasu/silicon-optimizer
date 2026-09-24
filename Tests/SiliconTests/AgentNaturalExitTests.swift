import Foundation
import Testing
@testable import SiliconRuntime
@testable import SiliconUI

@Suite("Agent natural exits", .serialized)
struct AgentNaturalExitTests {
    private final class StateCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [RuntimeState] = []

        func record(_ state: RuntimeState) {
            lock.lock()
            states.append(state)
            lock.unlock()
        }

        var last: RuntimeState? {
            lock.lock()
            defer { lock.unlock() }
            return states.last
        }
    }

    private func server(command: String) async throws -> ServerProcess {
        let server = ServerProcess(registry: ChildProcessRegistry())
        try await server.start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command], inheritEnvironment: false
        )
        return server
    }

    @Test func harnessNaturalExitReportsFailure() async throws {
        let process = try await server(command: "/bin/sleep 0.3; exit 7")
        guard let pid = await process.pid else {
            Issue.record("the test harness process did not launch")
            return
        }
        let runtime = HarnessRuntime(testProcess: process, testPID: pid)
        let capture = StateCapture()
        await runtime.observeReadyProcess(
            process, generation: 0, pollInterval: .milliseconds(20), onState: capture.record
        )
        guard case .failed(let message) = capture.last else {
            Issue.record("a dead harness did not leave the ready state")
            return
        }
        #expect(message.contains("exited unexpectedly"))
        #expect(message.contains("exit status 7"))
        #expect(await runtime.processIdentifier == nil)
    }

    @Test func qwenNaturalExitReportsFailure() async throws {
        let process = try await server(command: "/bin/sleep 0.3; exit 8")
        guard let pid = await process.pid else {
            Issue.record("the test Qwen process did not launch")
            return
        }
        let runtime = QwenCodeRuntime(testProcess: process, testPID: pid)
        let capture = StateCapture()
        await runtime.observeReadyProcess(
            process, generation: 0, pollInterval: .milliseconds(20), onState: capture.record
        )
        guard case .failed(let message) = capture.last else {
            Issue.record("a dead Qwen server did not leave the ready state")
            return
        }
        #expect(message.contains("exited unexpectedly"))
        #expect(message.contains("exit status 8"))
        #expect(await runtime.processIdentifier == nil)
    }

    @Test func deliberateStopCannotReportAnUnexpectedExit() async throws {
        let harnessProcess = try await server(command: "exec /bin/sleep 30")
        guard let harnessPID = await harnessProcess.pid else {
            Issue.record("the test harness process did not launch")
            return
        }
        let harness = HarnessRuntime(testProcess: harnessProcess, testPID: harnessPID)
        let harnessStates = StateCapture()
        let harnessMonitor = Task {
            await harness.observeReadyProcess(
                harnessProcess, generation: 0, pollInterval: .milliseconds(20),
                onState: harnessStates.record
            )
        }
        await harness.stop()
        await harnessMonitor.value
        #expect(harnessStates.last == nil)

        let qwenProcess = try await server(command: "exec /bin/sleep 30")
        guard let qwenPID = await qwenProcess.pid else {
            Issue.record("the test Qwen process did not launch")
            return
        }
        let qwen = QwenCodeRuntime(testProcess: qwenProcess, testPID: qwenPID)
        let qwenStates = StateCapture()
        let qwenMonitor = Task {
            await qwen.observeReadyProcess(
                qwenProcess, generation: 0, pollInterval: .milliseconds(20),
                onState: qwenStates.record
            )
        }
        await qwen.stop()
        await qwenMonitor.value
        #expect(qwenStates.last == nil)
    }

    @Test @MainActor func staleUICallbacksCannotOverwriteAStopOrNewSession() {
        let model = AppModel(settings: .init())
        let endpoint = URL(string: "http://127.0.0.1:43210")!

        model.harnessLifecycleGeneration = 2
        model.harnessState = .ready(endpoint: endpoint)
        model.harnessProcessID = 12345
        model.applyHarnessRuntimeState(.failed(message: "old exit"), generation: 1)
        #expect(model.harnessState == .ready(endpoint: endpoint))
        #expect(model.harnessProcessID == 12345)
        model.applyHarnessRuntimeState(.failed(message: "current exit"), generation: 2)
        #expect(model.harnessState == .failed(message: "current exit"))
        #expect(model.harnessProcessID == nil)
        model.applyHarnessRuntimeState(.ready(endpoint: endpoint), generation: 2)
        model.applyHarnessRuntimeState(.starting(stage: "stale callback"), generation: 2)
        model.applyHarnessProcessID(12345, generation: 2)
        #expect(model.harnessState == .failed(message: "current exit"))
        #expect(model.harnessProcessID == nil)

        model.qwenLifecycleGeneration = 2
        model.qwenState = .ready(endpoint: endpoint)
        model.qwenProcessID = 12346
        model.applyQwenRuntimeState(.failed(message: "old exit"), generation: 1)
        #expect(model.qwenState == .ready(endpoint: endpoint))
        #expect(model.qwenProcessID == 12346)
        model.applyQwenRuntimeState(.failed(message: "current exit"), generation: 2)
        #expect(model.qwenState == .failed(message: "current exit"))
        #expect(model.qwenProcessID == nil)
        model.applyQwenRuntimeState(.ready(endpoint: endpoint), generation: 2)
        model.applyQwenRuntimeState(.starting(stage: "stale callback"), generation: 2)
        model.applyQwenProcessID(12346, generation: 2)
        #expect(model.qwenState == .failed(message: "current exit"))
        #expect(model.qwenProcessID == nil)
    }
}

/// Pi's process, spoken to over the same pipes the app uses, with `/bin/sh` standing in for
/// Node: `launch` is everything after the install, so nothing here fetches or runs Pi.
///
/// The bug: only a non-zero exit that Foundation had already reaped when Pi's output closed
/// was noticed. A clean exit, or a crash whose pipe closed a moment before the reap, left the
/// engine `ready` with a handle to a pipe nobody reads — and every message after that was
/// written into it, the write's EPIPE swallowed, while a phone was told it had been accepted.
@Suite("Pi's natural exits")
struct PiNaturalExitTests {
    private final class States: @unchecked Sendable {
        private let lock = NSLock()
        private var states: [PiRuntime.State] = []
        func record(_ state: PiRuntime.State) { lock.withLock { states.append(state) } }
        var all: [PiRuntime.State] { lock.withLock { states } }
    }

    private func launch(
        _ runtime: PiRuntime, _ script: String, states: States
    ) async throws -> AsyncStream<String> {
        try #require(await runtime.launch(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            environment: [:], directory: FileManager.default.temporaryDirectory,
            onState: states.record
        ))
    }

    /// Exit status 0 is still Pi gone. Nothing asked it to go, so the engine is not running.
    @Test func aCleanExitLeavesTheEngineFailedNotReady() async throws {
        let runtime = PiRuntime()
        let states = States()
        let events = try await launch(runtime, "read line; exit 0", states: states)
        await runtime.send(line: #"{"type":"prompt","message":"hello"}"#)
        for await _ in events {}

        guard case .failed(let message) = states.all.last else {
            Issue.record("a Pi that exited is still \(String(describing: states.all.last))")
            return
        }
        #expect(message.hasPrefix("Pi exited."))
    }

    /// The crash whose output closes before the process is reaped — deterministic here, where
    /// in the app it was a race lost about one time in ten. Both pipes close first: the old
    /// check waited for stderr to end, and a shell that kept stderr open until it exited would
    /// have waited out the reap for it and hidden the race.
    @Test func aCrashNoticedBeforeTheReapIsStillReportedWithItsStatus() async throws {
        let runtime = PiRuntime()
        let states = States()
        let events = try await launch(
            runtime, "echo 'it broke' >&2; exec 1>&- 2>&-; sleep 0.5; exit 9", states: states
        )
        for await _ in events {}

        guard case .failed(let message) = states.all.last else {
            Issue.record("a Pi that crashed is still \(String(describing: states.all.last))")
            return
        }
        #expect(message.hasPrefix("Pi exited (9)."))
        #expect(message.contains("it broke"), "its last words say why")
    }

    /// Alive but not reading: the message cannot arrive, and the engine must stop looking as
    /// if it could rather than swallowing the write's error.
    @Test func aWriteNobodyReadsFailsTheEngine() async throws {
        let runtime = PiRuntime()
        let states = States()
        let events = try await launch(
            runtime, #"exec 0<&-; echo '{"closed":true}'; sleep 30"#, states: states
        )
        // Written only once its end is closed, so the write below cannot beat the close.
        var lines = events.makeAsyncIterator()
        #expect(await lines.next() == #"{"closed":true}"#)

        await runtime.send(line: #"{"type":"prompt","message":"hello"}"#)

        guard case .failed = states.all.last else {
            Issue.record("a Pi that cannot read is still \(String(describing: states.all.last))")
            await runtime.stop()
            return
        }
        await runtime.stop()
    }

    /// And the reverse, which the fix must not break: the owner stopping Pi is not Pi failing.
    @Test func aDeliberateStopIsNotReportedAsAFailure() async throws {
        let runtime = PiRuntime()
        let states = States()
        let events = try await launch(runtime, "exec /bin/sleep 30", states: states)
        await runtime.stop()
        for await _ in events {}
        try await Task.sleep(for: .milliseconds(200))
        #expect(states.all == [.ready])
    }
}
