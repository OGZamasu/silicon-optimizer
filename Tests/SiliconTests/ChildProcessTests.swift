import Foundation
import Testing
@testable import SiliconRuntime

/// The bug these exist for: quitting the app left `llama-server` running, reparented to
/// launchd, still holding the model's wired memory and still bound to the harness's inference
/// port. Two of them on a 26 GB machine was enough to make every request fail inside Metal.
///
/// Every test builds its own `ChildProcessRegistry`, so nothing here can see — or disturb —
/// children spawned by other suites. That isolation is what closed hub issue #12: the old
/// static registry made `tracked` a process-global assertion target, and `.serialized` only
/// orders tests within one suite, not across suites.
@Suite("Child process registry")
struct ChildProcessRegistryTests {

    /// A cheap, harmless real process to stand in for a runtime server.
    private func spawnSleeper(seconds: Int = 60) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [String(seconds)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private func store() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("child-process-tests-\(UUID().uuidString).json")
    }

    /// A stand-in for Homebrew's framework `python3.x`, which is a stub that execs the real
    /// interpreter inside `Python.app` a moment after it starts: same pid, same start time,
    /// a different executable from the one that was running when the pid was recorded.
    /// Nothing here is Python — `sleep` stands in for the server it would have become.
    private func spawnReexecingStub() throws -> (process: Process, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("reexec-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stub = directory.appendingPathComponent("python3.13")
        try "#!/bin/sh\n/bin/sleep 0.2\nexec /bin/sleep 60\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let process = Process()
        process.executableURL = stub
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process, directory)
    }

    /// Waits until the stub has become the thing it execs, so a test never passes merely by
    /// asking before the exec happened.
    /// Bounded generously: the suite runs beside other builds, and a stalled machine should
    /// make these slow, not wrong.
    private func waitForExec(_ pid: Int32) async throws {
        for _ in 0..<400 {
            if ChildProcessRegistry.identify(pid)?.executablePath == "/bin/sleep" { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("the stub never exec'd")
    }

    private func waitForExit(_ process: Process) async throws {
        for _ in 0..<400 where process.isRunning {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Identity

    @Test func identifiesALiveProcessAndWhenItStarted() throws {
        let process = try spawnSleeper()
        defer { process.terminate() }

        let entry = try #require(ChildProcessRegistry.identify(process.processIdentifier))
        #expect(entry.pid == process.processIdentifier)
        #expect(entry.executablePath == "/bin/sleep")
        #expect(entry.startedAt > 0)
        #expect(entry.startedAtMicroseconds != nil)
        #expect(ChildProcessRegistry.isStillAlive(entry))
    }

    /// `exec` changes what a process is running and nothing about which process it is. The
    /// entry recorded a moment after launch names the stub; by the time anyone asks, the pid
    /// is running something else — and it is still ours.
    @Test func aChildThatHasExecdSinceItWasRecordedIsStillOurs() async throws {
        let (process, directory) = try spawnReexecingStub()
        defer { process.terminate(); try? FileManager.default.removeItem(at: directory) }
        let recorded = try #require(ChildProcessRegistry.identify(process.processIdentifier))

        try await waitForExec(process.processIdentifier)
        #expect(recorded.executablePath != "/bin/sleep", "recorded before the exec")
        #expect(ChildProcessRegistry.isStillAlive(recorded))
    }

    @Test func aProcessThatHasExitedIsNotAlive() throws {
        let process = try spawnSleeper()
        let entry = try #require(ChildProcessRegistry.identify(process.processIdentifier))

        process.terminate()
        process.waitUntilExit()

        #expect(ChildProcessRegistry.isStillAlive(entry) == false)
    }

    /// The one that keeps this safe. The kernel reissues pids, so a stored pid on its own says
    /// nothing; matching the start time is what stops a reap from killing whatever innocent
    /// process inherited the number.
    @Test func aRecycledPidIsNotMistakenForOurs() throws {
        let process = try spawnSleeper()
        defer { process.terminate() }
        let real = try #require(ChildProcessRegistry.identify(process.processIdentifier))

        let impostorByTime = ChildProcessRegistry.Entry(
            pid: real.pid, executablePath: real.executablePath, startedAt: real.startedAt - 500,
            startedAtMicroseconds: real.startedAtMicroseconds
        )
        // The same second is not enough: the microseconds are what stand in for the path now
        // that a path is allowed to change.
        let microseconds = try #require(real.startedAtMicroseconds)
        let impostorWithinTheSecond = ChildProcessRegistry.Entry(
            pid: real.pid, executablePath: real.executablePath, startedAt: real.startedAt,
            startedAtMicroseconds: (microseconds + 1) % 1_000_000
        )

        #expect(ChildProcessRegistry.isStillAlive(impostorByTime) == false)
        #expect(ChildProcessRegistry.isStillAlive(impostorWithinTheSecond) == false)
    }

    /// The file a previous launch left may come from a build that recorded the second only.
    /// Those orphans are still worth reaping, and the second is still enough to tell them
    /// from a pid the kernel has handed on.
    @Test func anEntryWrittenBeforeMicrosecondsWereRecordedStillMatches() throws {
        let process = try spawnSleeper()
        defer { process.terminate() }
        var entry = try #require(ChildProcessRegistry.identify(process.processIdentifier))
        entry.startedAtMicroseconds = nil

        let decoded = try JSONDecoder().decode(
            ChildProcessRegistry.Entry.self,
            from: Data(#"{"pid":\#(entry.pid),"executablePath":"/bin/sleep","startedAt":\#(entry.startedAt)}"#.utf8)
        )
        #expect(decoded == entry)
        #expect(ChildProcessRegistry.isStillAlive(decoded))
    }

    // MARK: - Termination

    /// The reported bug, directly: a tracked server must not survive the app.
    @Test func terminateAllKillsEveryTrackedChild() throws {
        let registry = ChildProcessRegistry()
        let first = try spawnSleeper()
        let second = try spawnSleeper()
        defer { first.terminate(); second.terminate() }

        registry.register(pid: first.processIdentifier)
        registry.register(pid: second.processIdentifier)
        #expect(registry.tracked.count == 2)

        registry.terminateAll()
        first.waitUntilExit()
        second.waitUntilExit()

        #expect(first.isRunning == false)
        #expect(second.isRunning == false)
        #expect(registry.tracked.isEmpty)
    }

    /// The reported bug: Homebrew's framework Python re-execs itself, so `mlx_lm.server` was
    /// running under a different path from the one recorded, and quitting skipped it — it
    /// outlived the app, holding its model and its port, every time.
    @Test func terminateAllKillsAChildThatHasExecdSinceItWasRecorded() async throws {
        let registry = ChildProcessRegistry()
        let (process, directory) = try spawnReexecingStub()
        defer { process.terminate(); try? FileManager.default.removeItem(at: directory) }
        registry.register(pid: process.processIdentifier)
        try await waitForExec(process.processIdentifier)

        registry.terminateAll()
        try await waitForExit(process)

        #expect(process.isRunning == false, "the child outlived terminateAll")
    }

    @Test func aDeliberatelyStoppedChildIsForgotten() throws {
        let registry = ChildProcessRegistry()
        let process = try spawnSleeper()
        registry.register(pid: process.processIdentifier)

        registry.unregister(pid: process.processIdentifier)
        #expect(registry.tracked.isEmpty)

        process.terminate()
        process.waitUntilExit()
    }

    // MARK: - Crossing launches

    /// A crash runs no handler, so the next launch has to find the survivors on disk. Each
    /// launch is its own registry instance here, which is exactly what a relaunch is.
    @Test func aLaterLaunchFindsAndReapsWhatTheLastOneAbandoned() throws {
        let url = store()
        defer { try? FileManager.default.removeItem(at: url) }

        // Launch one: starts a server and records it, then dies without cleaning up.
        let launchOne = ChildProcessRegistry()
        launchOne.open(at: url)
        let abandoned = try spawnSleeper()
        launchOne.register(pid: abandoned.processIdentifier)

        // Launch two: reads the file and finds it still running.
        let launchTwo = ChildProcessRegistry()
        let orphans = launchTwo.open(at: url)
        #expect(orphans.count == 1)
        #expect(orphans.first?.pid == abandoned.processIdentifier)

        let killed = launchTwo.reap(orphans)
        abandoned.waitUntilExit()
        #expect(killed.count == 1)
        #expect(abandoned.isRunning == false)

        // And the record goes with them — otherwise the file keeps naming dead processes for
        // the rest of the machine's uptime.
        let remaining = try JSONDecoder().decode(
            [ChildProcessRegistry.Entry].self, from: try Data(contentsOf: url)
        )
        #expect(remaining.isEmpty)
    }

    /// And after a crash: the next launch has to recognise a Python server that exec'd after
    /// it was written down, or it leaves it holding the port it is about to want.
    @Test func aLaterLaunchReapsAnOrphanThatHasExecd() async throws {
        let url = store()
        defer { try? FileManager.default.removeItem(at: url) }

        let launchOne = ChildProcessRegistry()
        launchOne.open(at: url)
        let (abandoned, directory) = try spawnReexecingStub()
        defer { abandoned.terminate(); try? FileManager.default.removeItem(at: directory) }
        launchOne.register(pid: abandoned.processIdentifier)
        try await waitForExec(abandoned.processIdentifier)

        let launchTwo = ChildProcessRegistry()
        let orphans = launchTwo.open(at: url)
        #expect(orphans.map(\.pid) == [abandoned.processIdentifier])

        #expect(launchTwo.reap(orphans).count == 1)
        try await waitForExit(abandoned)
        #expect(abandoned.isRunning == false)
    }

    /// A crash between reading the file and acting on it must not lose the orphans: the file is
    /// the only record of them at that point, so the next launch has to be able to retry.
    @Test func theRecordSurvivesUntilTheReapActuallyHappens() throws {
        let url = store()
        defer { try? FileManager.default.removeItem(at: url) }

        let launchOne = ChildProcessRegistry()
        launchOne.open(at: url)
        let abandoned = try spawnSleeper()
        defer { abandoned.terminate() }
        launchOne.register(pid: abandoned.processIdentifier)

        // Launch two reads the file but dies before reaping.
        #expect(ChildProcessRegistry().open(at: url).count == 1)

        // Launch three still finds it.
        #expect(ChildProcessRegistry().open(at: url).count == 1)
    }

    /// Servers that shut down cleanly leave nothing for the next launch to do.
    @Test func aLaterLaunchIgnoresProcessesThatAreAlreadyGone() throws {
        let url = store()
        defer { try? FileManager.default.removeItem(at: url) }

        let launchOne = ChildProcessRegistry()
        launchOne.open(at: url)
        let process = try spawnSleeper()
        launchOne.register(pid: process.processIdentifier)
        process.terminate()
        process.waitUntilExit()

        #expect(ChildProcessRegistry().open(at: url).isEmpty)
    }

    @Test func anAbsentStoreIsNotAnError() {
        #expect(ChildProcessRegistry().open(at: store()).isEmpty)
    }
}

/// `ServerProcess` is the only thing that spawns runtime servers, so registration has to happen
/// there rather than at each of its eight call sites. The injected registry keeps these
/// assertions blind to every other suite's children.
@Suite("Server process registration")
struct ServerProcessRegistrationTests {

    @Test func startingAServerTracksItAndStoppingItDoesNot() async throws {
        let registry = ChildProcessRegistry()
        let server = ServerProcess(registry: registry)

        try await server.start(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"]
        )
        let pid = try #require(await server.pid)
        #expect(registry.tracked.contains { $0.pid == pid })

        await server.terminate()
        #expect(registry.tracked.contains { $0.pid == pid } == false)
    }

    /// A server that dies on its own must take itself out of the registry, or the next quit
    /// signals a pid the kernel has since handed to somebody else.
    @Test func aServerThatExitsOnItsOwnIsUntracked() async throws {
        let registry = ChildProcessRegistry()
        let server = ServerProcess(registry: registry)

        try await server.start(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0"]
        )
        let pid = try #require(await server.pid)

        // terminationHandler fires on a background queue shortly after the child exits.
        for _ in 0..<50 where registry.tracked.contains(where: { $0.pid == pid }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(registry.tracked.contains { $0.pid == pid } == false)
    }
}

/// A child's stdin whose reader has gone must fail the write, not raise SIGPIPE — whose
/// default action would end this test run, and in the app the app. Laya, Pi and Codex all
/// write to their child through this pipe.
@Suite("A child's input pipe")
struct ChildInputPipeTests {

    @Test func aWriteWithNoReaderIsAnErrorNotASignal() throws {
        let pipe = Pipe.childInput()
        #expect(fcntl(pipe.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE) == 1)
        try pipe.fileHandleForReading.close()
        #expect(throws: (any Error).self) {
            try pipe.fileHandleForWriting.write(contentsOf: Data("a question\n".utf8))
        }
    }

    /// The app's own diagnostics go to a stderr it did not open — `SILICON_JEV_DEBUG` writes
    /// there. Launched with that piped to a reader that has gone, a debug line must be a
    /// write that failed, not the end of the app.
    @Test func aDiagnosticWhoseReaderHasGoneIsDroppedNotASignal() throws {
        let pipe = Pipe()
        let handle = pipe.fileHandleForWriting
        #expect(handle.writeUnlessNobodyIsReading(Data("[jev] 1 question\n".utf8)))
        // Checked while the reader is still there, so a writer that forgot the flag fails
        // here rather than taking the whole test run down with the next line.
        try #require(fcntl(handle.fileDescriptor, F_GETNOSIGPIPE) == 1)
        try pipe.fileHandleForReading.close()
        #expect(handle.writeUnlessNobodyIsReading(Data("[jev] 2 questions\n".utf8)) == false)
    }

    /// And the same with a real child that went away, the way a sidecar does.
    @Test func aWriteToAChildThatExitedIsAnErrorNotASignal() throws {
        let pipe = Pipe.childInput()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(throws: (any Error).self) {
            try pipe.fileHandleForWriting.write(contentsOf: Data("a question\n".utf8))
        }
    }
}
