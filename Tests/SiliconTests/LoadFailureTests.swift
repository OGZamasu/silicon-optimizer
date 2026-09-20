import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconCore
@testable import SiliconPlanner
@testable import SiliconRuntime

/// What a failed load says, and how it knows.
///
/// The report these exist for: a 27B ternary model was asked for from the phone, and the
/// phone showed a wall of log text under "The model did not finish loading." The log stopped
/// at eight seconds, mid-sentence. The runtime process had ended — that was the whole story —
/// and nothing anywhere had written down that it had, let alone how.
///
/// No model is loaded here and no `llama-server` is run. The stand-ins are shell scripts that
/// do the four things a real one can do to a load: exit, get killed, never answer, and get
/// stopped by the app.
@Suite("Failed loads say what happened")
struct LoadFailureTests {

    // MARK: - The sentences

    /// The exact wording, pinned. These are the lines a person reads on a phone, and they
    /// are the deliverable — a test that only checked a substring would let them rot into
    /// something no one would want to read.
    @Test func eachEndingHasItsOwnSentence() {
        let exited = LoadEnding.processEnded(
            ProcessTermination(exitStatus: 1, ranFor: 8)
        )
        #expect(exited.sentence(process: "llama-server")
                == "llama-server stopped on its own after 8 seconds (exit 1).")

        let killed = LoadEnding.processEnded(
            ProcessTermination(signal: SIGKILL, ranFor: 8)
        )
        #expect(killed.sentence(process: "llama-server")
                == "llama-server was killed (signal 9) after 8 seconds, which usually means "
                + "the system reclaimed its memory.")

        let replaced = LoadEnding.processEnded(
            ProcessTermination(signal: SIGTERM, stopRequest: .replaced, ranFor: 8)
        )
        #expect(replaced.sentence(process: "llama-server", replacedBy: "Qwen3-Coder 30B")
                == "llama-server was replaced by another load (Qwen3-Coder 30B).")
        #expect(replaced.sentence(process: "llama-server")
                == "llama-server was replaced by another load.")

        let unloaded = LoadEnding.processEnded(
            ProcessTermination(signal: SIGTERM, stopRequest: .unload, ranFor: 8)
        )
        #expect(unloaded.sentence(process: "llama-server")
                == "llama-server was stopped by an unload before it finished loading.")

        #expect(LoadEnding.neverAnswered(after: 600).sentence(process: "llama-server")
                == "llama-server never answered in 10 minutes.")

        #expect(LoadEnding.cancelled(by: nil).sentence(process: "llama-server")
                == "The load was cancelled before llama-server finished loading.")
        #expect(LoadEnding.cancelled(by: "the app quitting").sentence(process: "llama-server")
                == "The load was cancelled by the app quitting before llama-server "
                + "finished loading.")
    }

    /// A crash is not the memory killer, and saying so would send someone to buy RAM they
    /// do not need.
    @Test func aCrashIsNotBlamedOnMemory() {
        let crashed = LoadEnding.processEnded(ProcessTermination(signal: SIGSEGV, ranFor: 3))
        let sentence = crashed.sentence(process: "llama-server")
        #expect(sentence == "llama-server was killed (signal 11) after 3 seconds, which "
                + "means it crashed.")
        #expect(!sentence.contains("memory"))
    }

    @Test(arguments: [
        (0.0, "less than a second"), (0.4, "less than a second"), (1.0, "1 second"),
        (8.4, "8 seconds"), (60.0, "60 seconds"), (120.0, "2 minutes"), (600.0, "10 minutes"),
    ])
    func durationsReadLikeSomeoneSayingThem(seconds: TimeInterval, expected: String) {
        #expect(LoadEnding.spell(seconds) == expected)
    }

    /// The reason a client switches on, beside the sentence a person reads.
    @Test func everyEndingCarriesAMachineReadableReason() {
        #expect(LoadEnding.processEnded(ProcessTermination(exitStatus: 1)).reason == .exited)
        #expect(LoadEnding.processEnded(ProcessTermination(signal: 9)).reason == .killed)
        #expect(LoadEnding.processEnded(
            ProcessTermination(signal: 15, stopRequest: .replaced)
        ).reason == .replaced)
        #expect(LoadEnding.processEnded(
            ProcessTermination(signal: 15, stopRequest: .unload)
        ).reason == .cancelled)
        #expect(LoadEnding.neverAnswered(after: 600).reason == .timedOut)
        #expect(LoadEnding.cancelled(by: nil).reason == .cancelled)
    }

    // MARK: - What the log still wins

    /// The whole point of the pattern matches: llama.cpp saying "failed to allocate" is
    /// better advice than anything the exit status can support, so it keeps its place at
    /// the front of the queue even though the ending is now known.
    @Test func aLogThatExplainsItselfBeatsTheExitStatus() {
        let message = LlamaCppRuntime.diagnose(
            log: "ggml_metal_graph_compute: failed to allocate buffer",
            ending: .processEnded(ProcessTermination(exitStatus: 1, ranFor: 8))
        )
        #expect(message.contains("context length"))
        #expect(!message.contains("exit 1"))
    }

    /// And the fallback is the fix: an unrecognised log no longer becomes the headline.
    @Test func anUnrecognisedLogFallsBackToHowItEnded() {
        let log = "loaded multimodal model, 'mmproj-Q8_0.gguf'"
        let message = LlamaCppRuntime.diagnose(
            log: log, ending: .processEnded(ProcessTermination(exitStatus: 1, ranFor: 8))
        )
        #expect(message == "llama-server stopped on its own after 8 seconds (exit 1).")
        // The log is not thrown away — it moves to where a client can put it behind a tap.
        #expect(LoadDiagnosis.tail(of: log) == log)
    }

    @Test func mlxSpeaksForItselfTheSameWay() {
        #expect(MLXRuntime.diagnose(
            log: "ModuleNotFoundError: No module named 'mlx_lm'",
            ending: .processEnded(ProcessTermination(exitStatus: 1, ranFor: 2))
        ).contains("pip install mlx-lm"))
        #expect(MLXRuntime.diagnose(
            log: "chatter", ending: .processEnded(ProcessTermination(signal: SIGKILL, ranFor: 8))
        ) == "mlx_lm.server was killed (signal 9) after 8 seconds, which usually means the "
            + "system reclaimed its memory.")
    }

    /// The detail a phone puts behind a tap is bounded, because it rides on every poll of
    /// `/status`.
    @Test func theLogTailIsBounded() throws {
        let long = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let tail = try #require(LoadDiagnosis.tail(of: long))
        #expect(tail.split(separator: "\n").count == LoadDiagnosis.detailLines)
        #expect(tail.hasSuffix("line 200"))
        #expect(LoadDiagnosis.tail(of: "") == nil)

        let enormous = String(repeating: "x", count: 10_000)
        let clipped = try #require(LoadDiagnosis.tail(of: enormous))
        #expect(clipped.count == LoadDiagnosis.detailCharacters + 1)
        #expect(clipped.hasPrefix("…"))
    }

    // MARK: - Reading it off a real process

    /// A server that exits on its own, with a status, is reported as exactly that — and the
    /// load stops waiting the moment it happens rather than at its ten-minute timeout.
    @Test func aRuntimeThatExitsIsReportedWithItsStatus() async throws {
        let fixture = try Fixture(script: "sleep 1; echo 'chatter nobody can act on' >&2; exit 3")
        defer { fixture.clean() }

        let began = ContinuousClock.now
        let failure = try await fixture.expectFailedLoad()
        #expect(ContinuousClock.now - began < .seconds(20))

        #expect(failure.reason == .exited)
        #expect(failure.exitStatus == 3)
        #expect(failure.signal == nil)
        #expect(failure.wasReplaced == false)
        #expect(failure.runtime == .llamaCpp)
        #expect(failure.summary.hasPrefix("llama-server stopped on its own after"))
        #expect(failure.summary.hasSuffix("(exit 3)."))
        #expect(failure.detail?.contains("chatter nobody can act on") == true)
        // The sentence is the headline; the log is not in it.
        #expect(!failure.summary.contains("chatter"))
    }

    /// The one the owner actually hit: the process is gone and nothing in the log explains
    /// it, because the system took the memory back.
    @Test func aRuntimeKilledBySignalSaysWhatThatUsuallyMeans() async throws {
        let fixture = try Fixture(script: "echo 'loaded multimodal model' >&2; sleep 1; kill -9 $$")
        defer { fixture.clean() }

        let failure = try await fixture.expectFailedLoad()
        #expect(failure.reason == .killed)
        #expect(failure.signal == 9)
        #expect(failure.exitStatus == nil)
        #expect(failure.summary.contains("was killed (signal 9)"))
        #expect(failure.summary.hasSuffix("which usually means the system reclaimed its memory."))
        #expect(failure.detail?.contains("loaded multimodal model") == true)
    }

    /// A server that is alive and simply never answers is a different failure, and must not
    /// be described as having died.
    @Test func aRuntimeThatNeverAnswersSaysHowLongItWasGiven() async throws {
        let fixture = try Fixture(script: "sleep 30", readinessTimeout: 1)
        defer { fixture.clean() }

        let failure = try await fixture.expectFailedLoad()
        #expect(failure.reason == .timedOut)
        #expect(failure.summary == "llama-server never answered in 1 second.")
        #expect(failure.exitStatus == nil && failure.signal == nil)
        #expect(failure.wasReplaced == false)
    }

    /// A second load stops the first, and the first says so instead of reporting a mystery.
    ///
    /// The ordering here is the app's own, and it is why the arbiter waits: the old server is
    /// stopped *before* the new load announces itself, so asked at the moment of the stop the
    /// honest answer is "nobody yet".
    @Test func aLoadStoppedByAnotherLoadIsReportedAsReplaced() async throws {
        let fixture = try Fixture(
            script: "sleep 30", readinessTimeout: 30, settle: .seconds(3)
        )
        defer { fixture.clean() }

        let load = Task { try await fixture.runtime.start(fixture.request) }
        try await fixture.waitUntilRunning()

        await fixture.runtime.stop()
        _ = await fixture.arbiter.begin(model: "Qwen3-Coder 30B", runtime: .llamaCpp)

        let failure = try await fixture.failure(from: load)
        #expect(failure.reason == .replaced)
        #expect(failure.wasReplaced)
        #expect(failure.summary == "llama-server was replaced by another load (Qwen3-Coder 30B).")
        // The load that lost is not the state anyone is looking at, so it does not stamp
        // its failure over the load that won.
        #expect(await fixture.runtime.state == .idle)
    }

    /// Without a second load, the same stop is an unload — and says so rather than
    /// inventing a replacement.
    @Test func anUnloadMidLoadIsReportedAsAnUnload() async throws {
        let fixture = try Fixture(
            script: "sleep 30", readinessTimeout: 30, settle: .milliseconds(200)
        )
        defer { fixture.clean() }

        let load = Task { try await fixture.runtime.start(fixture.request) }
        try await fixture.waitUntilRunning()
        await fixture.runtime.stop()

        let failure = try await fixture.failure(from: load)
        #expect(failure.reason == .cancelled)
        #expect(failure.wasReplaced == false)
        #expect(failure.summary
                == "llama-server was stopped by an unload before it finished loading.")
    }

    /// Cancelling the task a load runs in is its own ending, and one a client can tell from
    /// a model that failed.
    @Test func aCancelledLoadSaysItWasCancelled() async throws {
        let fixture = try Fixture(script: "sleep 30", readinessTimeout: 30)
        defer { fixture.clean() }

        let load = Task { try await fixture.runtime.start(fixture.request) }
        try await fixture.waitUntilRunning()
        load.cancel()

        let failure = try await fixture.failure(from: load)
        #expect(failure.reason == .cancelled)
        #expect(failure.summary
                == "The load was cancelled before llama-server finished loading.")
        await fixture.runtime.stop()
    }

    /// The app throws the runtime object away the moment a load fails, so the account of
    /// the failure has to outlive it — that is what `/status` answers from.
    @Test func theFailureOutlivesTheRuntimeObject() async throws {
        let fixture = try Fixture(script: "sleep 1; exit 3")
        defer { fixture.clean() }

        #expect(fixture.recorder.last == nil)
        let failure = try await fixture.expectFailedLoad()
        #expect(fixture.recorder.last == failure)

        let wire = failure.wire
        #expect(wire.reason == "exited")
        #expect(wire.exitStatus == 3)
        #expect(wire.runtime == "llama.cpp")
        #expect(wire.wasReplaced == false)
        #expect(ControlAPI.date(fromTimestamp: wire.at) != nil)
    }

    /// And the error the app shows is the sentence, not the log — which is the bug, in one
    /// assertion.
    @Test func theErrorAPersonSeesIsOneSentence() async throws {
        let fixture = try Fixture(script: "sleep 1; echo 'ggml_metal: whatever' >&2; exit 1")
        defer { fixture.clean() }

        let failure = try await fixture.expectFailedLoad()
        let described = RuntimeError.didNotBecomeReady(failure).localizedDescription
        #expect(described == failure.summary)
        #expect(described.split(separator: "\n").count == 1)
        #expect(!described.contains("The model did not finish loading"))
        #expect(described.hasSuffix("(exit 1)."))
    }

    // MARK: - The process itself

    /// `ServerProcess` is where the facts are: a stop this app asked for is not a death, and
    /// the two used to be indistinguishable by the time anybody asked.
    @Test func aServerProcessRemembersWhoStoppedIt() async throws {
        let registry = ChildProcessRegistry()
        let server = ServerProcess(registry: registry)
        try await server.start(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"])
        #expect(await server.termination == nil)
        #expect(server.hasEnded == false)

        await server.terminate(because: .replaced)
        let termination = try #require(await server.termination)
        #expect(termination.stopRequest == .replaced)
        #expect(termination.signal == SIGTERM)
        #expect(termination.exitStatus == nil)
        #expect(server.hasEnded)
    }

    @Test func aServerProcessThatExitsOnItsOwnRemembersItsStatus() async throws {
        let registry = ChildProcessRegistry()
        let server = ServerProcess(registry: registry)
        try await server.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 7"])

        let deadline = ContinuousClock.now + .seconds(5)
        while !server.hasEnded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let termination = try #require(await server.termination)
        #expect(termination.exitStatus == 7)
        #expect(termination.signal == nil)
        #expect(termination.stopRequest == nil)
        #expect(termination.ranFor >= 0)
    }

    /// Tidying up after a process that has already gone must not rewrite what happened to
    /// it. The failure path terminates the server it has just read the ending off, and a
    /// stop request recorded on top of a real exit status would turn "it exited with 7"
    /// into "we stopped it".
    @Test func terminatingAnAlreadyDeadProcessDoesNotRewriteItsEnding() async throws {
        let server = ServerProcess(registry: ChildProcessRegistry())
        try await server.start(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 7"]
        )
        let deadline = ContinuousClock.now + .seconds(5)
        while !server.hasEnded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        await server.terminate(because: .replaced)
        let termination = try #require(await server.termination)
        #expect(termination.exitStatus == 7)
        #expect(termination.stopRequest == nil)
    }

    // MARK: - Fixture

    /// A fake `llama-server`: a shell script that does whatever the test needs a runtime to
    /// do, wired to a runtime with its own arbiter and its own recorder so nothing here can
    /// see another suite's loads.
    private struct Fixture {
        let directory: URL
        let runtime: LlamaCppRuntime
        let arbiter: LoadArbiter
        let recorder: LoadFailureRecorder
        let request: LoadRequest

        init(
            script: String, readinessTimeout: TimeInterval = 15,
            settle: Duration = .milliseconds(100)
        ) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("load-failure-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let executable = directory.appendingPathComponent("llama-server")
            try Data("#!/bin/sh\n\(script)\n".utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path
            )

            arbiter = LoadArbiter(settle: settle)
            recorder = LoadFailureRecorder()
            runtime = LlamaCppRuntime(
                installation: RuntimeInstallation(
                    kind: .llamaCpp, executable: executable, version: "fixture",
                    hasExpertStreaming: false, source: .userPath
                ),
                arbiter: arbiter, recorder: recorder, readinessTimeout: readinessTimeout
            )
            request = LoadRequest(
                model: InstalledModel(
                    id: "fixture", name: "Fixture 1B", catalogID: nil, quantization: .q4_K_M,
                    format: .gguf,
                    primaryFile: URL(fileURLWithPath: "/Volumes/External/Local Models/fixture.gguf"),
                    allFiles: [], projectorFile: nil, sizeOnDisk: .mib(64),
                    installedAt: Date(), shape: nil, capabilities: []
                ),
                configuration: LoadConfiguration(contextLength: 2048)
            )
        }

        func clean() { try? FileManager.default.removeItem(at: directory) }

        /// Waits for the fake server to be up, so a test that stops it mid-load is really
        /// stopping something.
        func waitUntilRunning() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if await runtime.serverIsRunning { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("the fake runtime never started")
        }

        func expectFailedLoad() async throws -> LoadFailure {
            try await failure(from: Task { try await runtime.start(request) })
        }

        func failure(from load: Task<Void, any Error>) async throws -> LoadFailure {
            do {
                try await load.value
                Issue.record("the load was supposed to fail and did not")
                throw LoadFixtureError.didNotFail
            } catch let error as RuntimeError {
                guard case .didNotBecomeReady(let failure) = error else {
                    Issue.record("expected a load failure, got \(error)")
                    throw LoadFixtureError.wrongError
                }
                return failure
            }
        }
    }

    private enum LoadFixtureError: Error { case wrongError, didNotFail }
}
