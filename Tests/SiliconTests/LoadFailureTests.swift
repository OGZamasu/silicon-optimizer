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

    /// A kill in the first moment is not the memory killer: a binary that never got to run
    /// is one macOS refused — a quarantined download, a signature that does not check out —
    /// and sending that owner to shorten their context length wastes their afternoon.
    @Test func aKillBeforeItCouldEvenStartIsNotBlamedOnMemory() {
        let instant = LoadEnding.processEnded(
            ProcessTermination(signal: SIGKILL, ranFor: 0.4)
        )
        #expect(instant.sentence(process: "llama-server")
                == "llama-server was killed (signal 9) after less than a second, which this "
                + "early usually means macOS refused to run it at all — a quarantined or "
                + "unsigned build — rather than memory pressure.")

        // And once a load has really started, it is the memory reading again.
        let later = LoadEnding.processEnded(
            ProcessTermination(signal: SIGKILL, ranFor: LoadEnding.tooSoonForMemoryPressure)
        )
        #expect(later.sentence(process: "llama-server")
                .hasSuffix("which usually means the system reclaimed its memory."))
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
        (8.4, "8 seconds"), (60.0, "60 seconds"), (119.4, "119 seconds"),
        // Rounded before it is classified, not after: these two used to read "120 seconds"
        // and "60 minutes".
        (119.6, "2 minutes"), (120.0, "2 minutes"), (600.0, "10 minutes"),
        (3_600.0, "1 hour"), (9_000.0, "3 hours"),
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

    /// But a load *this app* stopped is not diagnosable, and reading its log for advice puts
    /// words in the runtime's mouth. A replaced load whose log happened to carry "failed to
    /// allocate" was being reported as having run out of memory — a bug report nobody can
    /// act on, about a load nobody asked to keep.
    @Test func anAppCausedEndingIsNeverReadOutOfTheLog() {
        let log = "ggml_metal_graph_compute: failed to allocate buffer"
        let replaced = LoadEnding.processEnded(
            ProcessTermination(signal: SIGTERM, stopRequest: .replaced, ranFor: 8)
        )
        #expect(LlamaCppRuntime.diagnose(log: log, ending: replaced, replacedBy: "Qwen3 30B")
                == "llama-server was replaced by another load (Qwen3 30B).")

        let unloaded = LoadEnding.processEnded(
            ProcessTermination(signal: SIGTERM, stopRequest: .unload, ranFor: 8)
        )
        #expect(LlamaCppRuntime.diagnose(log: log, ending: unloaded)
                == "llama-server was stopped by an unload before it finished loading.")

        #expect(LlamaCppRuntime.diagnose(log: log, ending: .cancelled(by: nil))
                == "The load was cancelled before llama-server finished loading.")

        // And the endings that are the runtime's own still read the log first.
        for ending in [
            LoadEnding.processEnded(ProcessTermination(exitStatus: 1, ranFor: 8)),
            .processEnded(ProcessTermination(signal: SIGKILL, ranFor: 8)),
            .neverAnswered(after: 600),
        ] {
            #expect(LlamaCppRuntime.diagnose(log: log, ending: ending).contains("context length"),
                    "\(ending)")
            #expect(ending.wasAppCaused == false)
        }
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
        // No `sleep`: while a fake runtime is alive the load is polling `/health` on a
        // recycled ephemeral port, and anything that answers 200 there — another suite's
        // control server, say — makes a load that was supposed to fail "become ready". The
        // window is only as long as the process lives, so it lives no longer than it must.
        let fixture = try await Fixture(script: "echo 'chatter nobody can act on' >&2; exit 3")
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
        let fixture = try await Fixture(script: "echo 'loaded multimodal model' >&2; kill -9 $$")
        defer { fixture.clean() }

        let failure = try await fixture.expectFailedLoad()
        #expect(failure.reason == .killed)
        #expect(failure.signal == 9)
        #expect(failure.exitStatus == nil)
        #expect(failure.summary.contains("was killed (signal 9)"))
        // Which of the two readings of a signal 9 this gets is decided by how long it
        // lived, and that is pinned on the sentences themselves rather than raced against
        // a real process here.
        #expect(failure.summary.contains("signal 9)"))
        #expect(failure.detail?.contains("loaded multimodal model") == true)
    }

    /// A server that is alive and simply never answers is a different failure, and must not
    /// be described as having died.
    @Test func aRuntimeThatNeverAnswersSaysHowLongItWasGiven() async throws {
        let fixture = try await Fixture(script: "sleep 30", readinessTimeout: 1)
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
        let fixture = try await Fixture(
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
        let fixture = try await Fixture(
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
        let fixture = try await Fixture(script: "sleep 30", readinessTimeout: 30)
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
        let fixture = try await Fixture(script: "exit 3")
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
        let fixture = try await Fixture(script: "echo 'ggml_metal: whatever' >&2; exit 1")
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

    /// The last thing a runtime writes before it exits is the line that says why, and it has
    /// to be in the log by the time anybody knows the process is gone. The exit and those
    /// last bytes reach the app as two separate events, in either order, so one process at a
    /// time rarely shows the race; a few dozen at once used to lose the line in about a third
    /// of them, and `aRuntimeThatExitsIsReportedWithItsStatus` now and then in a full run.
    @Test func aProcessThatHasEndedHasItsLastLineInItsLog() async throws {
        let lost = await withTaskGroup(of: String?.self) { group in
            for n in 0..<32 {
                group.addTask {
                    let words = "last words \(n)"
                    let server = ServerProcess(registry: ChildProcessRegistry())
                    guard (try? await server.start(
                        executable: URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", "echo '\(words)' >&2; exit 3"]
                    )) != nil else { return "\(n) never started" }
                    let deadline = ContinuousClock.now + .seconds(10)
                    while !server.hasEnded, ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    guard server.hasEnded else { return "\(n) never ended" }
                    let log = await server.log
                    return log.hasSuffix(words) ? nil : "\(n) read \(log.debugDescription)"
                }
            }
            return await group.reduce(into: [String]()) { lost, outcome in
                if let outcome { lost.append(outcome) }
            }
        }
        #expect(lost.isEmpty)
    }

    /// Waiting for the rest of the output is bounded, because the end of the pipe is not the
    /// end of the process: anything the child started inherits the pipe and holds it open.
    /// Python's resource tracker does exactly that. The log still says what was written.
    @Test func aPipeHeldOpenByAGrandchildDoesNotHoldUpTheLog() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("held-pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pidFile = directory.appendingPathComponent("grandchild.pid")
        defer {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let server = ServerProcess(registry: ChildProcessRegistry())
        try await server.start(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & echo $! > '\(pidFile.path)'; echo 'bye' >&2; exit 3"]
        )
        let deadline = ContinuousClock.now + .seconds(5)
        while !server.hasEnded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(server.hasEnded)

        let began = ContinuousClock.now
        let log = await server.log
        #expect(ContinuousClock.now - began < .seconds(10))
        #expect(log.hasSuffix("bye"))
    }

    // MARK: - The arbiter

    /// A winner that has already finished is still the load that displaced this one. The
    /// arbiter used to forget a claim the moment it ended, so a fast winner left the loser
    /// reporting an unload nobody had asked for.
    @Test func aWinnerThatHasAlreadyFinishedStillCounts() async {
        let arbiter = LoadArbiter(settle: .seconds(3))
        let loser = await arbiter.begin(model: "Bonsai 2 27B", runtime: .llamaCpp)
        let winner = await arbiter.begin(model: "Qwen3-Coder 30B", runtime: .llamaCpp)

        // The winner is over before the loser gets around to asking.
        let began = ContinuousClock.now
        let displacement = await arbiter.displacement(of: loser)
        #expect(displacement?.model == "Qwen3-Coder 30B")
        #expect(displacement?.id == winner.id)
        // And an answer that is already known costs no waiting at all.
        #expect(ContinuousClock.now - began < .milliseconds(500))
    }

    /// With nobody else in the race, the wait is real and the answer is honestly nothing.
    @Test func aLoadNothingDisplacedIsToldSo() async {
        let arbiter = LoadArbiter(settle: .milliseconds(200))
        let only = await arbiter.begin(model: "Bonsai 2 27B", runtime: .llamaCpp)
        #expect(await arbiter.displacement(of: only) == nil)
    }

    // MARK: - Two loads on one runtime

    /// The load that wins must keep its server. `start` lets a second load take a runtime
    /// that is already loading; the loser then tidies up after itself, and clearing
    /// `server`/`client` unconditionally threw away the *winner's* handles — its process
    /// stayed alive, `stop()` had nothing to stop, and the model it held was not released
    /// until the app quit.
    @Test func aSecondLoadOnOneRuntimeDoesNotOrphanTheWinnersServer() async throws {
        let fixture = try await Fixture(
            script: "sleep 30", readinessTimeout: 30, settle: .milliseconds(200)
        )
        defer { fixture.clean() }

        let first = Task { try await fixture.runtime.start(fixture.request) }
        try await fixture.waitUntilRunning()

        // The second load displaces the first, exactly as a second tap would.
        let second = Task { try await fixture.runtime.start(fixture.request) }
        let failure = try await fixture.failure(from: first)
        #expect(failure.wasReplaced)

        // The winner is still there, and still this runtime's.
        try await fixture.waitUntilRunning()
        #expect(await fixture.runtime.serverIsRunning)

        // And stopping really stops it.
        second.cancel()
        _ = try? await second.value
        await fixture.runtime.stop()
        #expect(await fixture.runtime.serverIsRunning == false)
    }

    // MARK: - What travels

    /// The log is the runtime's raw output, and llama.cpp names the model file on most of
    /// its opening lines. That text goes to a phone and rides `/events`, so the part that
    /// identifies the model stays and the part that describes somebody's disk does not.
    @Test func theLogTailKeepsFileNamesAndDropsThePathsAroundThem() throws {
        let log = """
        llama_model_loader: loaded meta data with 30 key-value pairs and 435 tensors from         /Volumes/External/Local Models/orca/Ternary-2-27B-PTQ1_0.gguf (version GGUF V3)
        load_model: loading model '/Volumes/External/Local Models/orca/mmproj-Q8_0.gguf'
        error loading model: failed to open /Users/someone/Library/x.gguf: No such file
        """
        let tail = try #require(LoadDiagnosis.tail(of: log))

        #expect(tail.contains("Ternary-2-27B-PTQ1_0.gguf"))
        #expect(tail.contains("mmproj-Q8_0.gguf"))
        #expect(tail.contains("x.gguf"))
        #expect(!tail.contains("/Volumes"))
        #expect(!tail.contains("/Users"))
        #expect(!tail.contains("Local Models"))
        // The prose around a path survives it.
        #expect(tail.contains("loaded meta data with 30 key-value pairs"))
        #expect(tail.contains("(version GGUF V3)"))
        #expect(tail.contains("No such file"))
    }

    /// A relative word with a slash in it is not a path, and a log that mentions one should
    /// come out the other side unchanged.
    @Test func ordinaryTextIsLeftAlone() {
        let log = "llama_context: n_ctx = 16384, 24/7 slots busy, ratio 3/4"
        #expect(LoadDiagnosis.tail(of: log) == log)
    }

    // MARK: - Fixture

    /// A fake `llama-server`: a shell script that does whatever the test needs a runtime to
    /// do, wired to a runtime with its own arbiter and its own recorder so nothing here can
    /// see another suite's loads.
    private struct Fixture {
        /// Set only for the launch that warms the script up, which then exits at once.
        static let warmUp = "SILICON_FIXTURE_WARM_UP"

        let directory: URL
        let runtime: LlamaCppRuntime
        let arbiter: LoadArbiter
        let recorder: LoadFailureRecorder
        let request: LoadRequest

        init(
            script: String, readinessTimeout: TimeInterval = 15,
            settle: Duration = .milliseconds(100)
        ) async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("load-failure-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let executable = directory.appendingPathComponent("llama-server")
            try Data("#!/bin/sh\n[ -n \"$\(Self.warmUp)\" ] && exit 0\n\(script)\n".utf8)
                .write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path
            )
            // macOS checks a new executable the first time it is launched, and that first
            // launch is slow in a way nothing here controls: a fraction of a second alone,
            // seconds when others queue beside it, and now and then fourteen or twenty seconds
            // — measured on a Mac where `/bin/sh` itself never took a third of one. Inside the
            // load that wait counted against its readiness timeout: the script had not run,
            // so the process had neither ended nor written anything, and the load reported a
            // server that never answered. Paying for it here keeps it out of the timed window.
            // Awaited rather than waited on: a blocked thread is one the rest of a parallel
            // run cannot have, for as long as the check takes.
            let warm = Process()
            warm.executableURL = executable
            warm.environment = [Self.warmUp: "1"]
            let _: Void = try await withCheckedThrowingContinuation { done in
                warm.terminationHandler = { _ in done.resume() }
                do { try warm.run() } catch { done.resume(throwing: error) }
            }

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
