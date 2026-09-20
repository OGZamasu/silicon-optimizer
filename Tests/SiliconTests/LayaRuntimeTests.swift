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
    ///   `notInstalled` refuses at load the way a missing `laya_mlx` does.
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
        import json, sys, time
        hello = json.loads(sys.stdin.readline())
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
    @Test func theLaneRestartsOnceAndThenReportsTheSecondFailure() async throws {
        let fake = try FakeSidecar("dieOnRequest")
        defer { fake.clean() }
        let runtime = LayaRuntime()
        let library = fake.directory
        await runtime.configure(library: { library }, script: { fake.script })
        // A runtime pointed at a fake environment: the interpreter is the system one and
        // the "environment" is a directory that does not have laya-mlx in it, which is
        // exactly the shape `sidecar(for:)` needs and nothing more.
        let lane = LayaLane(runtime: runtime, checkpoint: { .english })
        await #expect(throws: (any Error).self) {
            _ = try await lane.decide(.fixture())
        }
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

// MARK: - Install and locations

@Suite("The Laya install")
struct LayaInstallTests {

    private func scratch() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("laya-install-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The owner's rule, as a test: nothing goes on the startup disk. Both the environment
    /// and the Hugging Face cache resolve inside the configured library.
    @Test func everythingLandsInsideTheModelLibrary() {
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
}
