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

    /// Codex had none of the guards above. The runtime's stop waits for a slow process to
    /// exit, and a start that began meanwhile came up — then the stop finished and marked
    /// the live session idle, with its sidecar still running.
    @Test @MainActor func aStopThatFinishesLateCannotIdleANewerCodexSession() async throws {
        let model = AppModel(settings: .init())
        let endpoint = URL(string: "codex://app-server")!
        model.codexRuntime = CodexRuntime()
        model.codexState = .ready(endpoint: endpoint)

        model.stopCodex()
        #expect(model.codexState == .stopping)
        // What `startCodexIfNeeded` does before its runtime reports, then the report: the
        // new session is up before the stop's own completion reaches the main actor.
        model.codexLifecycleGeneration &+= 1
        let current = model.codexLifecycleGeneration
        model.codexState = .starting(stage: "Looking for Node.js…")
        model.applyCodexRuntimeState(.ready(endpoint: endpoint), generation: current)
        model.applyCodexProcessID(4242, generation: current)

        // Let the stop's task run to the end.
        for _ in 0..<20 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.codexState == .ready(endpoint: endpoint))
        #expect(model.codexProcessID == 4242)

        // The rest of the harness rules hold too: an older session's exit is not this one's,
        // and this one's exit is final for it.
        model.applyCodexRuntimeState(.failed(message: "old exit"), generation: current - 1)
        #expect(model.codexState == .ready(endpoint: endpoint))
        model.applyCodexRuntimeState(.failed(message: "current exit"), generation: current)
        model.applyCodexRuntimeState(.ready(endpoint: endpoint), generation: current)
        model.applyCodexProcessID(4242, generation: current)
        #expect(model.codexState == .failed(message: "current exit"))
        #expect(model.codexProcessID == nil)

        // And a stop nothing overtook still lands.
        model.stopCodex()
        for _ in 0..<20 where model.codexState != .idle {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.codexState == .idle)
    }
}
