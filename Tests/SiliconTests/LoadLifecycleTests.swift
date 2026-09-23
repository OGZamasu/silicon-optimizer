import Foundation
import Observation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

/// How a load ends when this Mac stops it, as a phone following that load reads it.
///
/// The phone follows a load after `POST /load` until the Mac says it is loaded, failed,
/// replaced or cancelled. Two of those four never arrived: an unload part-way through, and
/// another load started from the Mac's own window, were not failures, so nothing said the
/// load had ended — and a failure that did arrive did not say whose load it was.
///
/// The app model is the real one, and so is the runtime: `LlamaCppRuntime` driving a script
/// that stands in for llama-server, with its own arbiter and recorder so nothing here can
/// read another suite's loads. What each test changes is who stops the load, and when.
@Suite("How an interrupted load ends")
@MainActor
struct LoadLifecycleTests {

    // MARK: - An unload

    /// The owner presses Unload — or a phone sends `POST /unload` — while a load is still
    /// reading its weights.
    @Test func anUnloadPartWayThroughEndsTheLoadAsCancelled() async throws {
        let bench = try await Bench()
        defer { bench.clean() }
        let qwen = bench.installed("Qwen3-Coder 30B", id: "qwen3-coder-30b@Q4_K_M")

        let load = Task { await bench.model.loadAsync(qwen) }
        try await bench.waitUntilServing()
        await bench.model.unload()

        // Said as the unload returns, not a moment later when the runtime has finished
        // deciding what to call its own ending.
        let said = try #require(await bench.model.status().interruptedLoads)
        #expect(said.map(\.modelID) == [qwen.id])
        #expect(said.map(\.reason) == ["cancelled"])
        #expect(said.first?.replacedBy == nil)

        guard case .interrupted(let interruption) = await load.value else {
            Issue.record("an unloaded load is neither loaded nor failed"); return
        }
        #expect(interruption.cause == .unload)

        // And the state a phone from before `interruptedLoads` stops on: the sentence, with
        // the failure behind it saying `cancelled` — and now whose load it was.
        let status = await bench.model.status()
        #expect(status.state
                == "llama-server was stopped by an unload before it finished loading.")
        #expect(status.failure?.reason == "cancelled")
        #expect(status.failure?.modelID == qwen.id)
        #expect(status.failure?.wasReplaced == false)
        #expect(status.loadedModelID == nil)
        // The owner got what they asked for; that is not an error to put in front of them.
        #expect(bench.model.alert == nil)
        #expect(bench.model.activeRuntime == nil)
    }

    /// An unload followed at once by another load: the unload is what ended the first one,
    /// and the second load's progress is the state line, whatever the first runtime says
    /// about itself afterwards.
    @Test func anUnloadThenAnotherLoadEndsTheFirstAsUnloaded() async throws {
        let bench = try await Bench()
        defer { bench.clean() }
        let qwen = bench.installed("Qwen3-Coder 30B", id: "qwen3-coder-30b@Q4_K_M")
        let gemma = bench.installed("Gemma 4 E2B", id: "gemma-4-e2b@Q4_K_M")

        let first = Task { await bench.model.loadAsync(qwen) }
        let firstRuntime = try await bench.waitUntilServing()
        await bench.model.unload()
        let second = Task { await bench.model.loadAsync(gemma) }

        guard case .interrupted(let interruption) = await first.value else {
            Issue.record("the first load should have been stopped"); return
        }
        #expect(interruption.cause == .unload)
        _ = try await bench.waitUntilServing(after: firstRuntime)

        let status = await bench.model.status()
        #expect(status.interruptedLoads?.map(\.modelID) == [qwen.id])
        #expect(status.interruptedLoads?.map(\.reason) == ["cancelled"])
        #expect(status.failure == nil)
        #expect(bench.model.runtimeState.isBusy, "\(bench.model.runtimeState)")

        await bench.model.unload()
        _ = await second.value
    }

    /// A stopped runtime keeps talking: a moment after the unload it reports how its load
    /// ended. That report used to be applied to the app's state whatever had happened
    /// since — here, a second load that failed at once, whose own sentence it replaced with
    /// the first load's "stopped by an unload".
    @Test func aStoppedRuntimesLateReportDoesNotOverwriteTheNextLoad() async throws {
        let bench = try await Bench()
        defer { bench.clean() }
        let qwen = bench.installed("Qwen3-Coder 30B", id: "qwen3-coder-30b@Q4_K_M")
        // An MLX checkpoint on a Mac with no MLX runtime: refused before any runtime starts,
        // so nothing announces a newer load and the first one's report says "unloaded".
        var mlx = bench.installed("Gemma 4 E2B MLX", id: "gemma-4-e2b-mlx")
        mlx.format = .mlx

        let first = Task { await bench.model.loadAsync(qwen) }
        try await bench.waitUntilServing()
        await bench.model.unload()
        guard case .failed(let sentence) = await bench.model.loadAsync(mlx) else {
            Issue.record("a load with no runtime should fail"); return
        }
        // The first load's runtime has reported by the time its load returns.
        _ = await first.value

        #expect(bench.model.runtimeState == .failed(message: sentence))
        #expect(bench.model.alert?.title == "Could not load Gemma 4 E2B MLX")
        let status = await bench.model.status()
        #expect(status.state == sentence)
        // The first load's failure is recorded, but it is not the one the state line is
        // about, so it is not published beside it.
        #expect(status.failure == nil)
        #expect(status.interruptedLoads?.map(\.modelID) == [qwen.id])
    }

    // MARK: - Another load

    /// The owner starts a second load from the Mac's window while the first is running.
    /// The first ends as replaced, naming the model that replaced it; nothing claims a
    /// failure; the second load's progress is the state line.
    @Test func aLoadReplacedFromTheWindowNamesTheLoadThatReplacedIt() async throws {
        let bench = try await Bench()
        defer { bench.clean() }
        let qwen = bench.installed("Qwen3-Coder 30B", id: "qwen3-coder-30b@Q4_K_M")
        let gemma = bench.installed("Gemma 4 E2B", id: "gemma-4-e2b@Q4_K_M")

        let first = Task { await bench.model.loadAsync(qwen) }
        let firstRuntime = try await bench.waitUntilServing()
        let second = Task { await bench.model.loadAsync(gemma) }

        guard case .interrupted(let interruption) = await first.value,
              case .replaced(let byID, let byName) = interruption.cause else {
            Issue.record("the first load should have been replaced"); return
        }
        #expect(byID == gemma.id)
        #expect(byName == "Gemma 4 E2B")
        _ = try await bench.waitUntilServing(after: firstRuntime)

        let status = await bench.model.status()
        let entry = try #require(status.interruptedLoads?.first)
        #expect(status.interruptedLoads?.count == 1)
        #expect(entry.modelID == qwen.id)
        #expect(entry.reason == "replaced")
        #expect(entry.replacedBy == gemma.id)
        #expect(ControlAPI.date(fromTimestamp: entry.at) != nil)
        // The load that won is loading, so nothing has failed.
        #expect(status.failure == nil)
        #expect(status.loadedModelID == nil)
        #expect(bench.model.runtimeState.isBusy, "\(bench.model.runtimeState)")
        #expect(bench.model.alert == nil)

        // Newest first, one per model: the second load's own ending goes in front.
        await bench.model.unload()
        _ = await second.value
        let after = await bench.model.status()
        #expect(after.interruptedLoads?.map(\.modelID) == [gemma.id, qwen.id])
        #expect(after.interruptedLoads?.map(\.reason) == ["cancelled", "replaced"])
    }

    /// The case the missing model id got wrong: the load that replaced ours fails. The
    /// failure now says it was the other model's, and the list says what became of ours.
    @Test func aFailureOfTheLoadThatReplacedAnotherNamesItsOwnModel() async throws {
        let bench = try await Bench()
        defer { bench.clean() }
        let qwen = bench.installed("Qwen3-Coder 30B", id: "qwen3-coder-30b@Q4_K_M")
        let broken = bench.installed("Broken 7B", id: "\(Bench.failingModel)@Q4_K_M")

        let first = Task { await bench.model.loadAsync(qwen) }
        try await bench.waitUntilServing()
        guard case .failed = await bench.model.loadAsync(broken) else {
            Issue.record("the second load was meant to fail on its own"); return
        }
        _ = await first.value

        let status = await bench.model.status()
        #expect(status.failure?.modelID == broken.id)
        #expect(status.failure?.reason == "exited")
        #expect(status.interruptedLoads?.map(\.modelID) == [qwen.id])
        #expect(status.interruptedLoads?.first?.replacedBy == broken.id)
    }

    /// A new load of a model is the answer to whatever stopped its last one, so a phone
    /// asking for it again is not shown the old ending as the new load's.
    @Test func loadingAModelAgainClearsItsOldEnding() async throws {
        let bench = try await Bench()
        defer { bench.clean() }
        let qwen = bench.installed("Qwen3-Coder 30B", id: "qwen3-coder-30b@Q4_K_M")

        let first = Task { await bench.model.loadAsync(qwen) }
        let firstRuntime = try await bench.waitUntilServing()
        await bench.model.unload()
        _ = await first.value
        #expect(await bench.model.status().interruptedLoads?.map(\.modelID) == [qwen.id])

        let again = Task { await bench.model.loadAsync(qwen) }
        _ = try await bench.waitUntilServing(after: firstRuntime)
        let status = await bench.model.status()
        #expect(status.interruptedLoads == nil)
        #expect(status.failure == nil)

        await bench.model.unload()
        _ = await again.value
    }

    /// A load that failed on its own is over the moment it fails. The app then reads the
    /// runtime's log for its window — an await — and a load started in that moment used to
    /// find the failed one still "in progress" and list it as replaced.
    @Test func aLoadThatFailedIsNotListedAsReplacedByTheNextOne() async throws {
        let bench = try await Bench()
        defer { bench.clean() }
        let broken = bench.installed("Broken 7B", id: "\(Bench.failingModel)@Q4_K_M")
        let qwen = bench.installed("Qwen3-Coder 30B", id: "qwen3-coder-30b@Q4_K_M")

        // The next load is started from inside the failure: as the alert is raised, which is
        // after the load has failed and before the app reads the log. `onChange` runs there,
        // on the main actor, so the load it queues runs before the failed one resumes from
        // that read.
        let next = NextLoad()
        withObservationTracking { _ = bench.model.alert } onChange: {
            MainActor.assumeIsolated {
                next.task = Task { await bench.model.loadAsync(qwen) }
            }
        }
        guard case .failed = await bench.model.loadAsync(broken) else {
            Issue.record("the load was meant to fail on its own"); return
        }
        let started = try #require(next.task, "the next load never started")
        try await bench.waitUntilServing()

        let status = await bench.model.status()
        #expect(status.interruptedLoads?.contains { $0.modelID == broken.id } != true,
                "\(String(describing: status.interruptedLoads))")
        await bench.model.unload()
        _ = await started.value
    }

    /// The same model asked for again before its load finished — the Mac's own window
    /// reloading it with a larger context, say — is that model still being loaded. The load
    /// a phone asked for is answered with the live status to follow, as a slow load is, not
    /// with "replaced by another load (itself)"; and nothing is listed as stopped.
    @Test func theSameModelAskedForAgainIsStillThatModelLoading() async throws {
        let bench = try await Bench()
        defer { bench.clean() }
        let qwen = bench.installed("Qwen3-Coder 30B", id: "qwen3-coder-30b@Q4_K_M")
        bench.model.installedModels = [qwen]

        let asked = Task { try await bench.model.load(ControlAPI.LoadRequest(modelID: qwen.id)) }
        let firstRuntime = try await bench.waitUntilServing()
        let again = Task { await bench.model.loadAsync(qwen) }

        let answer = try await asked.value
        #expect(answer.loadedModelID == nil)
        #expect(answer.failure == nil)
        #expect(answer.interruptedLoads == nil)
        _ = try await bench.waitUntilServing(after: firstRuntime)
        let status = await bench.model.status()
        #expect(status.interruptedLoads == nil)
        #expect(status.failure == nil)
        #expect(bench.model.runtimeState.isBusy, "\(bench.model.runtimeState)")

        await bench.model.unload()
        _ = await again.value
    }

    // MARK: - What `POST /load` answers

    /// A load a phone asked for, replaced by one the owner started on the Mac. It used to
    /// be answered as a failure quoting the *other* load's progress line — "The model
    /// failed to load: Starting llama.cpp…". Now it is a 409 that says what happened.
    @Test func aRequestedLoadThatIsReplacedIsAnsweredAsReplaced() async throws {
        let bench = try await Bench()
        defer { bench.clean() }
        let qwen = bench.installed("Qwen3-Coder 30B", id: "qwen3-coder-30b@Q4_K_M")
        let gemma = bench.installed("Gemma 4 E2B", id: "gemma-4-e2b@Q4_K_M")
        bench.model.installedModels = [qwen, gemma]

        let asked = Task { try await bench.model.load(ControlAPI.LoadRequest(modelID: qwen.id)) }
        try await bench.waitUntilServing()
        let window = Task { await bench.model.loadAsync(gemma) }

        do {
            _ = try await asked.value
            Issue.record("a replaced load must not answer as loaded")
        } catch let error as ControlHostError {
            #expect(error.status == 409)
            #expect(error.localizedDescription == "Qwen3-Coder 30B was not loaded: another "
                    + "load (Gemma 4 E2B) replaced it before it finished.")
        }

        await bench.model.unload()
        _ = await window.value
    }

    /// And one an unload stopped.
    @Test func aRequestedLoadThatIsUnloadedIsAnsweredAsUnloaded() async throws {
        let bench = try await Bench()
        defer { bench.clean() }
        let qwen = bench.installed("Qwen3-Coder 30B", id: "qwen3-coder-30b@Q4_K_M")
        bench.model.installedModels = [qwen]

        let asked = Task { try await bench.model.load(ControlAPI.LoadRequest(modelID: qwen.id)) }
        try await bench.waitUntilServing()
        await bench.model.unload()

        do {
            _ = try await asked.value
            Issue.record("an unloaded load must not answer as loaded")
        } catch let error as ControlHostError {
            #expect(error.status == 409)
            #expect(error.localizedDescription == "Qwen3-Coder 30B was not loaded: an unload "
                    + "stopped it before it finished loading.")
        }
    }

    // MARK: - Fixture

    /// Where a load started from inside another one's failure is kept.
    @MainActor
    private final class NextLoad {
        var task: Task<LoadOutcome, Never>?
    }

    /// An app model whose loads run on a fake llama-server.
    @MainActor
    private final class Bench {
        /// A model whose id contains this fails to load at once, with exit status 3. Every
        /// other model loads for as long as anyone lets it.
        static let failingModel = "fails-to-load"
        /// Set only for the launch that warms the script up, which then exits at once.
        static let warmUp = "SILICON_FIXTURE_WARM_UP"

        let directory: URL
        let model: AppModel

        init() async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("load-lifecycle-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            let executable = directory.appendingPathComponent("llama-server")
            try Data("""
                #!/bin/sh
                [ -n "$\(Self.warmUp)" ] && exit 0
                case "$*" in *\(Self.failingModel)*) echo 'error loading model' >&2; exit 3;; esac
                exec /bin/sleep 30

                """.utf8).write(to: executable)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: executable.path
            )
            // macOS checks a new executable the first time it runs, and on a busy machine
            // that has taken seconds. Paid here, so no load below waits on it.
            let warm = Process()
            warm.executableURL = executable
            warm.environment = [Self.warmUp: "1"]
            let _: Void = try await withCheckedThrowingContinuation { done in
                warm.terminationHandler = { _ in done.resume() }
                do { try warm.run() } catch { done.resume(throwing: error) }
            }

            let installation = RuntimeInstallation(
                kind: .llamaCpp, executable: executable, version: "fixture",
                hasExpertStreaming: false, source: .userPath
            )
            let arbiter = LoadArbiter(settle: .milliseconds(200))
            let recorder = LoadFailureRecorder()
            model = AppModel(settings: .init())
            model.selector = RuntimeSelector(available: [.llamaCpp: installation])
            model.loadFailures = recorder
            model.makeRuntime = { selection in
                LlamaCppRuntime(
                    installation: selection.installation, arbiter: arbiter,
                    recorder: recorder, readinessTimeout: 60
                )
            }
            // A port nothing else in this process is handed: the fake never answers
            // `/health`, and a recycled ephemeral port with another suite's server behind
            // it would make a load that is meant to hang "become ready".
            model.resolvedHarnessPorts = (
                web: 0, inference: try await BuddyControlTests.freeLoopbackPort()
            )
        }

        func installed(_ name: String, id: String) -> InstalledModel {
            InstalledModel(
                id: id, name: name, catalogID: nil, quantization: .q4_K_M, format: .gguf,
                primaryFile: URL(fileURLWithPath: "/Volumes/External/Local Models/\(id).gguf"),
                allFiles: [], projectorFile: nil, sizeOnDisk: .mib(64), installedAt: Date(),
                shape: nil, capabilities: []
            )
        }

        /// Waits for a load's fake server to be running — a newer one than `previous`, when
        /// given — so a test that stops it is really stopping something.
        @discardableResult
        func waitUntilServing(
            after previous: (any InferenceRuntime)? = nil
        ) async throws -> any InferenceRuntime {
            let deadline = ContinuousClock.now + .seconds(30)
            while ContinuousClock.now < deadline {
                if let runtime = model.activeRuntime as? LlamaCppRuntime,
                   runtime !== previous, await runtime.serverIsRunning {
                    return runtime
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw LoadTestError.timeout
        }

        func clean() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
