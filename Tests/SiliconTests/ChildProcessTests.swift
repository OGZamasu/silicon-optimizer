import Foundation
import Testing
@testable import SiliconRuntime

/// The bug these exist for: quitting the app left `llama-server` running, reparented to
/// launchd, still holding the model's wired memory and still bound to the harness's inference
/// port. Two of them on a 26 GB machine was enough to make every request fail inside Metal.
///
/// Serialized: the registry is process-wide state, and these tests spawn real children.
@Suite("Child process registry", .serialized)
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
        ChildProcessRegistry.resetForTesting()
        let first = try spawnSleeper()
        let second = try spawnSleeper()
        defer { first.terminate(); second.terminate() }

        ChildProcessRegistry.register(pid: first.processIdentifier)
        ChildProcessRegistry.register(pid: second.processIdentifier)
        #expect(ChildProcessRegistry.tracked.count == 2)

        ChildProcessRegistry.terminateAll()
        first.waitUntilExit()
        second.waitUntilExit()

        #expect(first.isRunning == false)
        #expect(second.isRunning == false)
        #expect(ChildProcessRegistry.tracked.isEmpty)
    }

    @Test func aDeliberatelyStoppedChildIsForgotten() throws {
        ChildProcessRegistry.resetForTesting()
        let process = try spawnSleeper()
        ChildProcessRegistry.register(pid: process.processIdentifier)

        ChildProcessRegistry.unregister(pid: process.processIdentifier)
        #expect(ChildProcessRegistry.tracked.isEmpty)

        process.terminate()
        process.waitUntilExit()
    }

    // MARK: - Crossing launches

    /// A crash runs no handler, so the next launch has to find the survivors on disk.
    @Test func aLaterLaunchFindsAndReapsWhatTheLastOneAbandoned() throws {
        ChildProcessRegistry.resetForTesting()
        let url = store()
        defer { try? FileManager.default.removeItem(at: url) }

        // Launch one: starts a server and records it, then dies without cleaning up.
        ChildProcessRegistry.open(at: url)
        let abandoned = try spawnSleeper()
        ChildProcessRegistry.register(pid: abandoned.processIdentifier)
        ChildProcessRegistry.resetForTesting()

        // Launch two: reads the file and finds it still running.
        let orphans = ChildProcessRegistry.open(at: url)
        #expect(orphans.count == 1)
        #expect(orphans.first?.pid == abandoned.processIdentifier)

        let killed = ChildProcessRegistry.reap(orphans)
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
        ChildProcessRegistry.resetForTesting()
        let url = store()
        defer { try? FileManager.default.removeItem(at: url) }

        ChildProcessRegistry.open(at: url)
        let abandoned = try spawnSleeper()
        defer { abandoned.terminate() }
        ChildProcessRegistry.register(pid: abandoned.processIdentifier)
        ChildProcessRegistry.resetForTesting()

        // Launch two reads the file but dies before reaping.
        #expect(ChildProcessRegistry.open(at: url).count == 1)
        ChildProcessRegistry.resetForTesting()

        // Launch three still finds it.
        #expect(ChildProcessRegistry.open(at: url).count == 1)
    }

    /// Servers that shut down cleanly leave nothing for the next launch to do.
    @Test func aLaterLaunchIgnoresProcessesThatAreAlreadyGone() throws {
        ChildProcessRegistry.resetForTesting()
        let url = store()
        defer { try? FileManager.default.removeItem(at: url) }

        ChildProcessRegistry.open(at: url)
        let process = try spawnSleeper()
        ChildProcessRegistry.register(pid: process.processIdentifier)
        process.terminate()
        process.waitUntilExit()
        ChildProcessRegistry.resetForTesting()

        #expect(ChildProcessRegistry.open(at: url).isEmpty)
    }

    @Test func anAbsentStoreIsNotAnError() {
        ChildProcessRegistry.resetForTesting()
        let url = store()
        #expect(ChildProcessRegistry.open(at: url).isEmpty)
    }
}

/// `ServerProcess` is the only thing that spawns runtime servers, so registration has to happen
/// there rather than at each of its eight call sites.
@Suite("Server process registration", .serialized)
struct ServerProcessRegistrationTests {

    @Test func startingAServerTracksItAndStoppingItDoesNot() async throws {
        ChildProcessRegistry.resetForTesting()
        let server = ServerProcess()

        try await server.start(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"]
        )
        let pid = try #require(await server.pid)
        #expect(ChildProcessRegistry.tracked.contains { $0.pid == pid })

        await server.terminate()
        #expect(ChildProcessRegistry.tracked.contains { $0.pid == pid } == false)
    }

    /// A server that dies on its own must take itself out of the registry, or the next quit
    /// signals a pid the kernel has since handed to somebody else.
    @Test func aServerThatExitsOnItsOwnIsUntracked() async throws {
        ChildProcessRegistry.resetForTesting()
        let server = ServerProcess()

        try await server.start(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0"]
        )
        let pid = try #require(await server.pid)

        // terminationHandler fires on a background queue shortly after the child exits.
        for _ in 0..<50 where ChildProcessRegistry.tracked.contains(where: { $0.pid == pid }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(ChildProcessRegistry.tracked.contains { $0.pid == pid } == false)
    }
}
