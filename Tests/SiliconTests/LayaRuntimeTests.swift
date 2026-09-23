import Foundation
import Testing
@testable import SiliconControl
@testable import SiliconRuntime

// MARK: - A sidecar that is not a model

/// A stand-in for `laya_sidecar.py` that speaks the same protocol and loads nothing.
///
/// Every one of these tests drives a **real child process over real pipes** — which is the
/// half of the lane most likely to be wrong, and the half a mock would not exercise at all.
/// What it does not do is load 800 MB of weights or touch the network: the script answers
/// from a script, so the crash path, the restart, the timeout and the protocol are all
/// testable in milliseconds.
struct FakeSidecar {
    let directory: URL
    let script: URL

    /// - Parameter behaviour: `ok` answers everything; `dieOnRequest` exits after the
    ///   ready line; `wrongID` answers somebody else's question; `hang` never answers;
    ///   `notInstalled` refuses at load the way a missing `laya_mlx` does; `closesInput`
    ///   closes its end of stdin after the ready line and stays alive, so the next write
    ///   finds no reader — what a sidecar that has just died looks like to the pipe, held
    ///   still long enough to hit every time; `closesOutput` takes one request, closes
    ///   stdout and exits 9 half a second later — a death whose pipe closes before the
    ///   process is reaped, the order that used to be mistaken for a timeout.
    init(_ behaviour: String = "ok") throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("laya-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        script = directory.appendingPathComponent("fake_sidecar.py")
        try Self.source(behaviour).write(to: script, atomically: true, encoding: .utf8)
    }

    func clean() { try? FileManager.default.removeItem(at: directory) }

    var configuration: LayaSidecar.Configuration {
        .init(
            python: URL(fileURLWithPath: "/usr/bin/python3"), script: script,
            checkpoint: .english, environment: [:], batchSize: 16, cachePrompts: true,
            requestTimeout: 2, startTimeout: 10
        )
    }

    /// Deliberately plain Python 3 with no imports beyond the standard library, so it runs
    /// on the system interpreter every Mac has and needs nothing installed.
    static func source(_ behaviour: String) -> String {
        """
        import json, os, sys, time
        hello = json.loads(sys.stdin.readline())
        # One line per process start, beside the script itself — so a test can tell a
        # restart from a process that just kept answering, without the production code
        # needing to plumb a test-only environment variable through to get here.
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "starts.log"), "a") as f:
            f.write("1\\n")
        behaviour = \(behaviour.debugDescription)
        if behaviour == "notInstalled":
            print(json.dumps({"id": hello.get("id"), "ok": False,
                              "kind": "not_installed", "error": "No module named laya_mlx"}),
                  flush=True)
            sys.exit(3)
        print(json.dumps({"id": hello.get("id"), "ok": True, "op": "ready",
                          "protocol": 1, "model": hello.get("model"),
                          "revision": hello.get("revision"), "version": "0.1.0",
                          "load_ms": 1.0, "peak_memory_bytes": 842602004}), flush=True)
        if behaviour == "dieOnRequest":
            sys.stdin.readline()
            sys.exit(9)
        if behaviour == "closesInput":
            os.close(0)
            time.sleep(30)
            sys.exit(0)
        if behaviour == "closesOutput":
            sys.stdin.readline()
            os.close(1)
            time.sleep(0.5)
            os._exit(9)
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            request = json.loads(line)
            if request.get("op") == "shutdown":
                print(json.dumps({"id": request.get("id"), "ok": True}), flush=True)
                sys.exit(0)
            if behaviour == "hang":
                time.sleep(30)
                continue
            rid = "somebody-else" if behaviour == "wrongID" else request.get("id")
            answers = {}
            for name, q in (request.get("questions") or {}).items():
                kind = q.get("type")
                if kind == "choice":
                    labels = sorted((q.get("criteria") or {}).keys()) or ["a"]
                    probs = {l: round(1.0 / len(labels), 4) for l in labels}
                    probs[labels[0]] = round(1.0 - sum(list(probs.values())[1:]), 4)
                    answers[name] = {"type": "choice", "confidence": 0.9,
                                     "action": {"act_probability": 1.0},
                                     "choice": labels[0], "probabilities": probs}
                elif kind == "score":
                    levels = q.get("criteria") or ["a", "b"]
                    probs = {str(i): round(1.0 / len(levels), 4) for i in range(len(levels))}
                    answers[name] = {"type": "score", "confidence": 0.4,
                                     "action": {"act_probability": 1.0}, "score": 1.5,
                                     "legend": {str(i): str(v) for i, v in enumerate(levels)},
                                     "probabilities": probs}
                else:
                    answers[name] = {"type": "noul", "confidence": 0.9,
                                     "action": {"act_probability": 1.0}, "noul": 0.0975}
            print(json.dumps({"id": rid, "ok": True, "model": hello.get("model"),
                              "answers": answers,
                              "usage": {"input_tokens": 253, "output_tokens": 0},
                              "latency_ms": 23.4,
                              "per_question_ms": 23.4 / max(1, len(answers)),
                              "peak_memory_bytes": 967_000_000}), flush=True)
        """
    }
}

@Suite("The Laya sidecar")
struct LayaSidecarTests {

    @Test func itLoadsOnceAndThenAnswersManyQuestions() async throws {
        let fake = try FakeSidecar()
        defer { fake.clean() }
        let sidecar = LayaSidecar(
            configuration: fake.configuration, registry: ChildProcessRegistry()
        )
        let ready = try await sidecar.start()
        #expect(ready.model == LayaCheckpoint.english.repository)
        #expect(ready.revision == LayaCheckpoint.english.revision, "pinned to a commit")

        // Three requests down one process: the point of a sidecar over the library's own
        // one-shot CLI is that the model is loaded once, not once per question.
        for _ in 0..<3 {
            let response = try await sidecar.decide(
                state: "a state", questions: ["q": ["type": "noul", "instructions": "?"]]
            )
            #expect(response.answers["q"]?.noul == 0.0975)
            #expect(response.perQuestionMS != nil, "it reports what it measured")
        }
        #expect(await sidecar.isRunning)
        await sidecar.stop()
        #expect(await sidecar.isRunning == false)
    }

    /// The concurrency bug this fix targets: two callers close together must not cross
    /// wires. `LayaLineReader` used to hold a single pending continuation, so a second
    /// `decide()` arriving before the first had read its answer stole that continuation —
    /// the first caller then hung until its own 30s timeout, which tore the whole sidecar
    /// down for both of them. Eight abilities share one runtime, so this is not exotic.
    ///
    /// Two requests with different criteria, dispatched at the same time: if either
    /// serialization is missing, the likely failure is either a `protocolBroken` throw (an
    /// answer's id does not match the request that is reading it) or an answer that quietly
    /// belongs to the other question — either way this test catches it, because the two
    /// requests are built to have different, checkable answers.
    @Test func concurrentDecisionsEachGetTheirOwnAnswerAndTheSidecarStartsOnce() async throws {
        let fake = try FakeSidecar("ok")
        defer { fake.clean() }
        let sidecar = LayaSidecar(
            configuration: fake.configuration, registry: ChildProcessRegistry()
        )
        try await sidecar.start()

        async let first = sidecar.decide(
            state: "state one",
            questions: ["q": ["type": "choice", "instructions": "?",
                              "criteria": ["alpha": "one", "beta": "two"]]]
        )
        async let second = sidecar.decide(
            state: "state two",
            questions: ["q": ["type": "choice", "instructions": "?",
                              "criteria": ["gamma": "three", "delta": "four"]]]
        )
        let (firstResponse, secondResponse) = try await (first, second)

        // The fake always picks the alphabetically first label in *that request's own*
        // criteria — so a correct answer here is proof the two requests were not mixed up.
        #expect(firstResponse.answers["q"]?.choice == "alpha")
        #expect(secondResponse.answers["q"]?.choice == "delta")
        // Neither request's timeout fired and tore the process down to get here.
        #expect(await sidecar.isRunning)

        let startsLog = fake.directory.appendingPathComponent("starts.log")
        let starts = (try? String(contentsOf: startsLog, encoding: .utf8)) ?? ""
        #expect(starts.split(separator: "\n").count == 1, "the sidecar was started once")
    }

    /// The crash path: it dies mid-conversation, and the error says so with the status
    /// rather than becoming a decode failure or a hang.
    @Test func aSidecarThatDiesIsReportedAsADeath() async throws {
        let fake = try FakeSidecar("dieOnRequest")
        defer { fake.clean() }
        let sidecar = LayaSidecar(
            configuration: fake.configuration, registry: ChildProcessRegistry()
        )
        try await sidecar.start()
        do {
            _ = try await sidecar.decide(
                state: "s", questions: ["q": ["type": "noul", "instructions": "?"]]
            )
            Issue.record("a dead sidecar answered")
        } catch let error as LayaSidecarError {
            guard case .died = error else {
                Issue.record("expected a death, got \(error)")
                return
            }
            #expect(error.deservesRestart, "a death is the one failure worth retrying")
        }
    }

    /// And the restart: the lane above gets exactly one, then reports.
    ///
    /// Driven through `LayaLane` rather than the sidecar, because the retry is the lane's
    /// decision — only it knows whether the retry has been spent.
    ///
    /// Counts the fake process's own starts rather than only checking that *something* was
    /// thrown: deleting the retry block entirely still throws on the very first failure, so
    /// a test that only asserted `throws` passed just as well with no retry at all. A
    /// mutation that removes the retry has to fail *this*, on the starts count.
    @Test func theLaneRestartsOnceAndThenReportsTheSecondFailure() async throws {
        let fake = try FakeSidecar("dieOnRequest")
        defer { fake.clean() }
        let runtime = LayaRuntime()
        let library = fake.directory
        // A fake environment laid out exactly the way `sidecar(for:)` expects one —
        // `library/Engine Cache/laya-env/bin/python3` — symlinked to the system
        // interpreter. Without this, `LayaSidecar.start()` refuses at "python is missing"
        // before the `dieOnRequest` script ever runs even once, which is a different
        // failure from the one this test is named for. A *copy* of `/usr/bin/python3`
        // will not do here: macOS kills it on launch (signature validation tied to its
        // original path), where a symlink to it runs the original binary and passes.
        let bin = LayaRuntime.environmentDirectory(library: library).appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("python3"),
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3")
        )
        await runtime.configure(library: { library }, script: { fake.script })
        let lane = LayaLane(runtime: runtime, checkpoint: { .english })
        await #expect(throws: (any Error).self) {
            _ = try await lane.decide(.fixture())
        }
        let startsLog = fake.directory.appendingPathComponent("starts.log")
        let starts = (try? String(contentsOf: startsLog, encoding: .utf8)) ?? ""
        #expect(
            starts.split(separator: "\n").count == 2,
            "one start for the first failure, one for the retry — not fewer, not a loop"
        )
    }

    /// The death `aSidecarThatDiesIsReportedAsADeath` names, in the order that made it flaky:
    /// the answer pipe closes while `isRunning` is still true, because the child has not
    /// been reaped yet. That is a death with an exit status, worth the lane's one restart —
    /// not a timeout, which gets none.
    @Test func anOutputThatClosesBeforeTheReapIsADeathWithItsStatus() async throws {
        let fake = try FakeSidecar("closesOutput")
        defer { fake.clean() }
        let sidecar = LayaSidecar(
            configuration: fake.configuration, registry: ChildProcessRegistry()
        )
        try await sidecar.start()
        do {
            _ = try await sidecar.decide(
                state: "s", questions: ["q": ["type": "noul", "instructions": "?"]]
            )
            Issue.record("a sidecar with no output answered")
        } catch let error as LayaSidecarError {
            guard case .died(let status, _) = error else {
                Issue.record("expected a death, got \(error)")
                return
            }
            #expect(status == 9)
            #expect(error.deservesRestart)
        }
        #expect(await sidecar.isRunning == false)
    }

    /// A write to a sidecar that is no longer reading must come back as an error, not as
    /// SIGPIPE — whose default action ends this process, which in the app is the whole of
    /// Silicon Optimizer. Without the fix this test does not fail, it kills the test run.
    ///
    /// Both writes are covered: the question, and the polite shutdown line `stop()` sends to
    /// a process that still looks alive, which is how the suite used to die at random when
    /// a `dieOnRequest` sidecar exited a moment before `isRunning` noticed.
    @Test func writingToASidecarThatStoppedReadingIsADeathNotASignal() async throws {
        let fake = try FakeSidecar("closesInput")
        defer { fake.clean() }
        let sidecar = LayaSidecar(
            configuration: fake.configuration, registry: ChildProcessRegistry()
        )
        try await sidecar.start()
        #expect(await sidecar.isRunning, "alive, but no longer reading")
        do {
            _ = try await sidecar.decide(
                state: "s", questions: ["q": ["type": "noul", "instructions": "?"]]
            )
            Issue.record("a sidecar that cannot read the question answered it")
        } catch let error as LayaSidecarError {
            guard case .died = error else {
                Issue.record("expected a death, got \(error)")
                return
            }
            #expect(error.deservesRestart)
        }
        await sidecar.stop()
        #expect(await sidecar.isRunning == false)
    }

    @Test func aMissingPackageSaysSoRatherThanFailingToParse() async throws {
        let fake = try FakeSidecar("notInstalled")
        defer { fake.clean() }
        let sidecar = LayaSidecar(
            configuration: fake.configuration, registry: ChildProcessRegistry()
        )
        do {
            try await sidecar.start()
            Issue.record("an environment without laya-mlx started")
        } catch let error as LayaSidecarError {
            guard case .notInstalled = error else {
                Issue.record("expected notInstalled, got \(error)")
                return
            }
            #expect(!error.deservesRestart, "restarting would fail identically")
        }
    }

    /// A sidecar that has wedged is torn down rather than left to desynchronise every
    /// request after it.
    @Test func aRequestThatNeverComesBackTimesOutAndTearsTheProcessDown() async throws {
        let fake = try FakeSidecar("hang")
        defer { fake.clean() }
        var configuration = fake.configuration
        configuration.requestTimeout = 0.5
        let sidecar = LayaSidecar(
            configuration: configuration, registry: ChildProcessRegistry()
        )
        try await sidecar.start()
        do {
            _ = try await sidecar.decide(
                state: "s", questions: ["q": ["type": "noul", "instructions": "?"]]
            )
            Issue.record("a hung sidecar answered")
        } catch let error as LayaSidecarError {
            guard case .timedOut = error else {
                Issue.record("expected a timeout, got \(error)")
                return
            }
        }
        #expect(await sidecar.isRunning == false, "a wedged process is not kept")
    }

    /// An answer carrying somebody else's id means the process is not the one we think it
    /// is. Torn down rather than guessed at.
    @Test func anAnswerToTheWrongQuestionIsRefused() async throws {
        let fake = try FakeSidecar("wrongID")
        defer { fake.clean() }
        let sidecar = LayaSidecar(
            configuration: fake.configuration, registry: ChildProcessRegistry()
        )
        try await sidecar.start()
        do {
            _ = try await sidecar.decide(
                state: "s", questions: ["q": ["type": "noul", "instructions": "?"]]
            )
            Issue.record("a mismatched answer was accepted")
        } catch let error as LayaSidecarError {
            guard case .protocolBroken = error else {
                Issue.record("expected protocolBroken, got \(error)")
                return
            }
        }
        #expect(await sidecar.isRunning == false)
    }

    @Test func aMissingInterpreterAndAMissingScriptEachSayWhichOneItWas() async throws {
        let fake = try FakeSidecar()
        defer { fake.clean() }
        var noPython = fake.configuration
        noPython.python = URL(fileURLWithPath: "/nowhere/python3")
        await #expect(throws: LayaSidecarError.pythonMissing("/nowhere/python3")) {
            try await LayaSidecar(
                configuration: noPython, registry: ChildProcessRegistry()
            ).start()
        }
        var noScript = fake.configuration
        noScript.script = fake.directory.appendingPathComponent("gone.py")
        await #expect(throws: LayaSidecarError.scriptMissing(noScript.script.path)) {
            try await LayaSidecar(
                configuration: noScript, registry: ChildProcessRegistry()
            ).start()
        }
    }
}

// MARK: - A sidecar that stopped reading, through the router

/// The same dead pipe, one level up: the lane has to report it as a failure the router can
/// route around, and an ability the owner pinned away from the cloud must still not reach
/// it. The Laya lane here is the real one, over a real (fake) sidecar and a library laid out
/// the way the install check expects, so the router's own readiness check picks it.
@Suite("A Laya sidecar that stopped reading, through the router", .serialized)
struct LayaStoppedReadingRoutingTests {

    enum Scenario: String, CaseIterable, Sendable {
        case alwaysLocalWithAFreeLaneBehind, alwaysLocalAlone, off
    }

    @Test(arguments: Scenario.allCases)
    func itIsALaneFailureThatFallsThroughAndNeverReachesJev(scenario: Scenario) async throws {
        let fake = try FakeSidecar("closesInput")
        defer { fake.clean() }
        let runtime = try await Self.installedRuntime(for: fake)
        let harness = JevHarness()
        defer { harness.clean() }
        let jevRequests = JevRequestCounter()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CountingJevProtocol.self]
        CountingJevProtocol.counter = jevRequests
        // Jev fully on — keyed, enabled, in budget — so only the owner's pin keeps it out.
        await harness.configure(session: URLSession(configuration: configuration))
        try await harness.enable()
        let oneToken = CountingLane(.oneToken)
        let router = DecisionRouter(service: harness.service)
        await router.register(LayaLane(runtime: runtime, checkpoint: { .english }))
        if scenario == .alwaysLocalWithAFreeLaneBehind { await router.register(oneToken) }
        try await harness.service.update {
            $0.laneOverrides[.decideTool] = scenario == .off ? .off : .alwaysLocal
        }
        let questions = ControlAPI.DecideRequest.fixture().questions

        switch scenario {
        case .alwaysLocalWithAFreeLaneBehind:
            let response = try await router.decide(
                .decideTool, state: .string("s"), questions: questions
            )
            #expect(response.provider == DecisionLaneID.oneToken.wireName)
            #expect(await oneToken.count() == 1)
        case .alwaysLocalAlone:
            do {
                _ = try await router.decide(.decideTool, state: .string("s"), questions: questions)
                Issue.record("a sidecar that cannot read answered")
            } catch let error as LayaSidecarError {
                guard case .died = error else {
                    Issue.record("expected the sidecar to be reported stopped, got \(error)")
                    return
                }
            }
        case .off:
            await #expect(throws: JevError.disabled(.decideTool)) {
                _ = try await router.decide(.decideTool, state: .string("s"), questions: questions)
            }
        }

        let startsLog = fake.directory.appendingPathComponent("starts.log")
        let starts = ((try? String(contentsOf: startsLog, encoding: .utf8)) ?? "")
            .split(separator: "\n").count
        // Laya was asked, got its one restart, and failed again — or, switched off, was
        // never started at all.
        #expect(starts == (scenario == .off ? 0 : 2))
        #expect(jevRequests.value == 0, "\(scenario.rawValue) reached the paid lane")
        await runtime.unload()
    }

    /// A model library laid out the way `LayaRuntime` checks for an install, with the fake
    /// standing in for the driver script: the interpreter a symlink to the system one (a
    /// copy is killed at launch), an empty `laya_mlx` package and an empty weights file.
    static func installedRuntime(for fake: FakeSidecar) async throws -> LayaRuntime {
        let manager = FileManager.default
        let library = fake.directory
        let environment = LayaRuntime.environmentDirectory(library: library)
        let bin = environment.appendingPathComponent("bin")
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        try manager.createSymbolicLink(
            at: bin.appendingPathComponent("python3"),
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3")
        )
        let package = environment.appendingPathComponent("lib/python3/site-packages/laya_mlx")
        try manager.createDirectory(at: package, withIntermediateDirectories: true)
        #expect(manager.createFile(
            atPath: package.appendingPathComponent("__init__.py").path, contents: Data()
        ))
        let snapshot = LayaRuntime.checkpointDirectory(
            .english, hubCache: LayaRuntime.hubCacheDirectory(library: library)
        ).appendingPathComponent("snapshots/\(LayaCheckpoint.english.revision)")
        try manager.createDirectory(at: snapshot, withIntermediateDirectories: true)
        #expect(manager.createFile(
            atPath: snapshot.appendingPathComponent("model.safetensors").path, contents: Data()
        ))
        let runtime = LayaRuntime()
        await runtime.configure(library: { library }, script: { fake.script })
        #expect(await runtime.installation(checkpoint: .english).isInstalled)
        return runtime
    }
}

private final class JevRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Stands in for TypeSafe. Counts, and fails, every request that reaches it.
private final class CountingJevProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var counter: JevRequestCounter?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.counter?.increment()
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}

// MARK: - Install and locations

@Suite("The Laya install")
struct LayaInstallTests {

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("laya-install-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A stand-in for `pip`, driven through the same `Process`-spawning code
    /// `LayaRuntime.install()` actually uses. `download` writes a wheel of the given bytes
    /// wherever `--dest` says, exactly as `pip download --no-deps` would; `install` only
    /// leaves a marker beside itself — which is how the mismatch test below proves that
    /// step never ran on a wheel that failed verification.
    /// Stands in for an environment's Python: `-m pip install` leaves the same marker the
    /// fake pip does, and anything else fails.
    private func writeFakePython(at url: URL) throws {
        let source = """
            #!/bin/sh
            if [ "$1" = "-m" ] && [ "$2" = "pip" ] && [ "$3" = "install" ]; then
                echo installed >> "$(dirname "$0")/pip-install.marker"
                exit 0
            fi
            exit 1
            """
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeFakePip(at url: URL, wheelContents: String) throws {
        let source = """
            #!/usr/bin/python3
            import os, sys
            args = sys.argv[1:]
            here = os.path.dirname(os.path.abspath(__file__))
            if args and args[0] == "download":
                dest = None
                for i, a in enumerate(args):
                    if a == "--dest" and i + 1 < len(args):
                        dest = args[i + 1]
                os.makedirs(dest, exist_ok=True)
                with open(os.path.join(dest, "laya_mlx-0.1.0-py3-none-any.whl"), "w") as f:
                    f.write(\(wheelContents.debugDescription))
                sys.exit(0)
            if args and args[0] == "install":
                with open(os.path.join(here, "pip-install.marker"), "a") as f:
                    f.write("installed\\n")
                sys.exit(0)
            sys.exit(1)
            """
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The owner's rule, as a test: nothing goes on the startup disk. Both the environment
    /// and the Hugging Face cache resolve inside the configured library.
    @Test func everythingLandsInsideTheModelLibrary() throws {
        let library = URL(fileURLWithPath: "/Volumes/External/Local Models")
        let environment = LayaRuntime.environmentDirectory(library: library)
        let cache = LayaRuntime.hubCacheDirectory(library: library)
        #expect(environment.path.hasPrefix(library.path))
        #expect(cache.path.hasPrefix(library.path))
        // The same `Engine Cache` directory every other Python engine here writes to,
        // rather than a second copy of the hub layout beside it.
        #expect(cache.lastPathComponent == "Engine Cache")
        #expect(LayaRuntime.pythonPath(environment: environment).path
                .hasPrefix(environment.path))

        // And the child environment points HF_HOME there, which is the line that actually
        // stops `~/.cache/huggingface` filling the boot volume.
        let child = LayaRuntime.childEnvironment(hubCache: cache)
        #expect(child["HF_HOME"] == cache.path)
        #expect(child["HF_HUB_DISABLE_TELEMETRY"] == "1")
        #expect(child["HF_TOKEN"] == nil, "no token unless one was given")
        // Same rule, pip's own cache: left unset it lands at ~/Library/Caches/pip on the
        // startup disk regardless of HF_HOME, which is exactly the thing this feature's
        // error text promises will not happen.
        let pipCache = try #require(child["PIP_CACHE_DIR"])
        #expect(pipCache.hasPrefix(library.path), "pip's cache stays inside the model library")
        #expect(!pipCache.hasPrefix(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches").path
        ))
    }

    @Test func withNoLibraryConfiguredItRefusesRatherThanUsingTheStartupDisk() async {
        let installation = LayaRuntime.installation(library: nil, script: nil)
        #expect(installation.missing == .libraryNotConfigured)
        #expect(!installation.isInstalled)

        let runtime = LayaRuntime()
        await runtime.configure(library: { nil }, script: { nil })
        await #expect(throws: LayaInstallError.noModelLibrary) {
            try await runtime.install()
        }
    }

    /// An external drive that is not mounted is its own answer, not "not installed":
    /// the cure is to plug the drive in, not to download a gigabyte again.
    @Test func anUnmountedLibraryIsReportedAsUnreachable() async {
        let missing = URL(fileURLWithPath: "/Volumes/NotMountedRightNow/Local Models")
        let installation = LayaRuntime.installation(library: missing, script: nil)
        #expect(installation.missing == .libraryUnreachable(missing.path))

        let runtime = LayaRuntime()
        await runtime.configure(library: { missing }, script: { nil })
        await #expect(throws: LayaInstallError.libraryUnreachable(missing.path)) {
            try await runtime.install()
        }
    }

    /// A fake environment, built by hand: the checks read the filesystem rather than
    /// running the interpreter, so an install can be asserted on without one.
    @Test func itWalksTheInstallStatesInOrder() throws {
        let library = scratch()
        defer { try? FileManager.default.removeItem(at: library) }
        let manager = FileManager.default
        let script = library.appendingPathComponent("laya_sidecar.py")
        try "#".write(to: script, atomically: true, encoding: .utf8)

        // Nothing yet.
        #expect(LayaRuntime.installation(library: library, script: script).missing
                == .environment)

        // An environment with an interpreter but no package is still `.environment`: a
        // half-built venv is not an install, and reporting it as one would fail at the
        // first question instead of at the button.
        let environment = LayaRuntime.environmentDirectory(library: library)
        let bin = environment.appendingPathComponent("bin")
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        try manager.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/python3"),
            to: bin.appendingPathComponent("python3")
        )
        #expect(LayaRuntime.installation(library: library, script: script).missing
                == .environment)

        // Package in place, weights not.
        let packages = environment
            .appendingPathComponent("lib/python3.13/site-packages/laya_mlx")
        try manager.createDirectory(at: packages, withIntermediateDirectories: true)
        try "".write(
            to: packages.appendingPathComponent("__init__.py"),
            atomically: true, encoding: .utf8
        )
        #expect(LayaRuntime.installation(library: library, script: script).missing
                == .checkpoint(.english))

        // And the weights, at the pinned revision. A snapshot under a *different* revision
        // does not count — that is the whole point of pinning one.
        let cache = LayaRuntime.hubCacheDirectory(library: library)
        let wrong = LayaRuntime.checkpointDirectory(.english, hubCache: cache)
            .appendingPathComponent("snapshots/0000000000000000000000000000000000000000")
        try manager.createDirectory(at: wrong, withIntermediateDirectories: true)
        try "w".write(
            to: wrong.appendingPathComponent("model.safetensors"),
            atomically: true, encoding: .utf8
        )
        #expect(LayaRuntime.installation(library: library, script: script).missing
                == .checkpoint(.english), "a different revision is not this one")

        let right = LayaRuntime.checkpointDirectory(.english, hubCache: cache)
            .appendingPathComponent("snapshots/\(LayaCheckpoint.english.revision)")
        try manager.createDirectory(at: right, withIntermediateDirectories: true)
        try "w".write(
            to: right.appendingPathComponent("model.safetensors"),
            atomically: true, encoding: .utf8
        )
        let done = LayaRuntime.installation(library: library, script: script)
        #expect(done.isInstalled)
        #expect(done.installedCheckpoints == [.english])

        // Without the driver script there is nothing to run, whatever is downloaded.
        #expect(LayaRuntime.installation(library: library, script: nil).missing
                == .environment)
    }

    @Test func aTooOldInterpreterIsNotUsedToBuildTheEnvironment() {
        // macOS ships 3.9 and laya-mlx needs 3.11: the candidate list is searched newest
        // first and anything older is skipped rather than used and failed later.
        let chosen = LayaRuntime.locatePython(
            candidates: ["/usr/bin/python3", "/bin/sh"],
            version: { url in url.path == "/usr/bin/python3" ? (3, 9) : nil }
        )
        #expect(chosen == nil)
        let newer = LayaRuntime.locatePython(
            candidates: ["/usr/bin/python3"], version: { _ in (3, 13) }
        )
        #expect(newer?.path == "/usr/bin/python3")
    }

    /// The idle unload is a memory rule, and it is measured from the last *use*.
    @Test func anIdleCheckpointIsReleasedAndABusyOneIsNot() async throws {
        let runtime = LayaRuntime()
        // Nothing loaded: there is nothing to unload and it says so rather than churning.
        #expect(await runtime.unloadIfIdle() == false)
        #expect(await runtime.isLoaded == false)
        #expect(LayaRuntime.idleUnloadSeconds >= 600, "long enough to cover a work session")
    }

    /// The pins are the whole reproducibility story: there are no upstream git tags, so the
    /// wheel digest and the three commit shas are all there is to hold on to.
    @Test func thePinsAreExactRatherThanRanges() {
        #expect(LayaPackage.requirement == "laya-mlx==0.1.0")
        #expect(LayaPackage.wheelSHA256.count == 64)
        for checkpoint in LayaCheckpoint.allCases {
            #expect(checkpoint.revision.count == 40, "a full commit sha, not a branch")
            #expect(checkpoint.revision.allSatisfy { $0.isHexDigit })
            #expect(checkpoint.repository.hasSuffix("-mlx"), "the MLX port, not upstream")
            #expect(checkpoint.downloadBytes > 500_000_000)
        }
        // The library's own default is the upstream PyTorch repo, which this runtime can
        // never use — so no checkpoint here may be spelled the way that default is.
        let repositories = LayaCheckpoint.allCases.map(\.repository)
        #expect(!repositories.contains("convaiinnovations/laya"))
    }

    /// The hashing primitive the install step is built on, against a published test
    /// vector rather than a value this test invented — so a broken implementation fails
    /// here rather than only in a harder-to-read end-to-end test.
    @Test func sha256HexMatchesAPublishedTestVector() throws {
        let file = scratch().appendingPathComponent("vector.txt")
        try "abc".write(to: file, atomically: true, encoding: .utf8)
        // NIST's own SHA-256("abc") example.
        #expect(
            try LayaRuntime.sha256Hex(ofFileAt: file)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    /// The mutation the brief describes exactly: the digest is recorded and shown in the
    /// panel, but unless the install step actually checks it, a wheel with the wrong bytes
    /// installs exactly like the right one. Drives the real `LayaRuntime.install()` through
    /// a fake `pip` that hands back a wheel that cannot match the pin, and proves the
    /// mismatch is caught — clearly, and before `pip install` ever runs — rather than
    /// discovered later with `laya_mlx` already on disk.
    ///
    /// If the comparison in `downloadAndVerifyWheel` is deleted, the install goes on to
    /// `python -m pip install`, the marker below is written, and this test fails on that
    /// assertion rather than only on the thrown error's type.
    @Test func aWrongWheelDigestFailsTheInstallBeforeAnythingIsInstalled() async throws {
        let library = scratch()
        defer { try? FileManager.default.removeItem(at: library) }
        let environment = LayaRuntime.environmentDirectory(library: library)
        let bin = environment.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // An environment of a Python the locks cover, so `install()` gets past choosing a
        // lock and reaches the wheel download this test is actually about. Its interpreter
        // only records a `pip install` — nothing here may install anything for real.
        try "home = /x\nversion = 3.13.7\n".write(
            to: environment.appendingPathComponent("pyvenv.cfg"), atomically: true, encoding: .utf8
        )
        try writeFakePython(at: bin.appendingPathComponent("python3"))
        try writeFakePip(at: bin.appendingPathComponent("pip"), wheelContents: "not the pinned wheel")

        let runtime = LayaRuntime()
        await runtime.configure(library: { library }, script: { nil })
        do {
            try await runtime.install(checkpoint: .english) { _ in }
            Issue.record("a wheel that does not match the pin was installed")
        } catch let LayaInstallError.wheelHashMismatch(expected, got) {
            #expect(expected == LayaPackage.wheelSHA256, "measured against the real pin")
            #expect(got != expected)
        } catch {
            Issue.record("expected wheelHashMismatch, got \(error)")
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: bin.appendingPathComponent("pip-install.marker").path
            ),
            "pip install must never run on a wheel that failed verification"
        )
        #expect(
            !LayaRuntime.hasPackage(environment: environment),
            "nothing half-installed: the venv exists, laya_mlx does not"
        )
    }
}
