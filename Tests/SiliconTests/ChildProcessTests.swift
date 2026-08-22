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

    // MARK: - Identity

    @Test func identifiesALiveProcessByPathAndStartTime() throws {
        let process = try spawnSleeper()
        defer { process.terminate() }

        let entry = try #require(ChildProcessRegistry.identify(process.processIdentifier))
        #expect(entry.pid == process.processIdentifier)
        #expect(entry.executablePath == "/bin/sleep")
        #expect(entry.startedAt > 0)
        #expect(ChildProcessRegistry.isStillAlive(entry))
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
            pid: real.pid, executablePath: real.executablePath, startedAt: real.startedAt - 500
        )
        let impostorByPath = ChildProcessRegistry.Entry(
            pid: real.pid, executablePath: "/usr/bin/true", startedAt: real.startedAt
        )

        #expect(ChildProcessRegistry.isStillAlive(impostorByTime) == false)
        #expect(ChildProcessRegistry.isStillAlive(impostorByPath) == false)
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
