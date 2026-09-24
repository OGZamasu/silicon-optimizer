import Darwin
import Foundation
import Testing
@testable import SiliconRuntime
@testable import SiliconUI

/// The in-app installs — MFLUX, the voice tools, the hy3d build — run pip, xcodebuild and curl
/// for minutes. Stop has to stop them, and quitting has to as well: a step left running keeps
/// writing into the environment the next install, or the next launch, is about to use.
///
/// The steps here are shell scripts that start a child of their own and sleep, standing in for
/// pip and the compilers xcodebuild starts. Nothing is downloaded or built.
@Suite("Stopping an in-app install", .serialized)
@MainActor
struct RepairStopTests {

    /// A step that records its own pid and its child's, then waits on the child for a minute
    /// and leaves `finished` behind if it ever gets that far.
    @MainActor
    private struct SleepingStep {
        let directory: URL
        var leaderFile: URL { directory.appendingPathComponent("leader.pid") }
        var childFile: URL { directory.appendingPathComponent("child.pid") }
        var finished: URL { directory.appendingPathComponent("finished") }

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("repair-stop-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        var script: String {
            """
            echo $$ > "\(leaderFile.path).tmp" && mv "\(leaderFile.path).tmp" "\(leaderFile.path)"
            /bin/sleep 60 &
            echo $! > "\(childFile.path).tmp" && mv "\(childFile.path).tmp" "\(childFile.path)"
            wait
            : > "\(finished.path)"
            """
        }

        var step: AppModel.RepairStep {
            AppModel.RepairStep(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                currentDirectory: nil, label: "Installing"
            )
        }

        func pids() async throws -> (leader: pid_t, child: pid_t) {
            try await RepairStopTests.waitUntil("the step started its child") {
                FileManager.default.fileExists(atPath: childFile.path)
            }
            func read(_ url: URL) throws -> pid_t {
                let text = try String(contentsOf: url, encoding: .utf8)
                return try #require(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            return (try read(leaderFile), try read(childFile))
        }

        func clean() { try? FileManager.default.removeItem(at: directory) }
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        // A zombie still answers kill(0); it has stopped all the same.
        guard kill(pid, 0) == 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_status != UInt32(SZOMB)
    }

    private static func waitUntil(
        _ what: String, seconds: Double = 20, _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("timed out waiting until \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("Stop ends the step and everything it started, and Install waits until they have gone")
    func stopEndsTheStepsProcesses() async throws {
        let sleeping = try SleepingStep()
        defer { sleeping.clean() }
        let model = AppModel(settings: .init())
        var succeeded = false
        model.runRepair(id: "repair-stop-test", steps: [sleeping.step]) { succeeded = true }
        let (leader, child) = try await sleeping.pids()
        #expect(Self.isAlive(leader) && Self.isAlive(child))
        #expect(ChildProcessRegistry.tracked.contains { $0.pid == leader },
                "a crash mid-install must leave the next launch something to reap")

        model.cancelRepair("repair-stop-test")
        // Until the step has exited the job stays — so the Install button stays away — and a
        // second install of the same thing cannot start beside the one still stopping.
        let stopping = try #require(model.repairs["repair-stop-test"])
        #expect(stopping.stage == "Stopping…")
        let second = try SleepingStep()
        defer { second.clean() }
        model.runRepair(id: "repair-stop-test", steps: [second.step]) {}
        #expect(model.repairs["repair-stop-test"] === stopping)

        try await Self.waitUntil("the stopped job went away") {
            model.repairs["repair-stop-test"] == nil
        }
        try await Self.waitUntil("the step and its child exited") {
            !Self.isAlive(leader) && !Self.isAlive(child)
        }
        #expect(!Self.isAlive(leader), "the step outlived Stop")
        #expect(!Self.isAlive(child), "what the step started outlived Stop")
        #expect(!FileManager.default.fileExists(atPath: sleeping.finished.path))
        #expect(!FileManager.default.fileExists(atPath: second.leaderFile.path),
                "a second copy ran beside the one being stopped")
        #expect(!succeeded)
        #expect(!ChildProcessRegistry.tracked.contains { $0.pid == leader })
    }

    @Test("Quitting stops a step that is still running, and what it started")
    func quittingStopsARunningStep() async throws {
        let sleeping = try SleepingStep()
        defer { sleeping.clean() }
        let model = AppModel(settings: .init())
        // This model's own set of running steps, so "all" is only this test's.
        model.runningRepairs = RepairProcess.Running()
        model.runRepair(id: "repair-quit-test", steps: [sleeping.step]) {}
        let (leader, child) = try await sleeping.pids()

        // What the app's willTerminate observer does, synchronously, as it quits.
        model.runningRepairs.stopAll()

        try await Self.waitUntil("the step and its child exited") {
            !Self.isAlive(leader) && !Self.isAlive(child)
        }
        #expect(!Self.isAlive(leader), "the step outlived the app")
        #expect(!Self.isAlive(child), "what the step started outlived the app")
        #expect(!FileManager.default.fileExists(atPath: sleeping.finished.path))
    }

    /// A crash runs no quit handler. The step is on record, and the next launch's reap has to
    /// end what it started as well as the step: a `curl` left under `sh`, the compilers under
    /// `xcodebuild`, pip's build backend. Each launch is its own registry here, on a scratch
    /// store, as in the registry's own tests.
    @Test("After a crash, the next launch reaps the step and everything it started")
    func theNextLaunchReapsTheWholeStep() async throws {
        let sleeping = try SleepingStep()
        defer { sleeping.clean() }
        let store = sleeping.directory.appendingPathComponent("child-processes.json")
        let crashed = ChildProcessRegistry()
        crashed.open(at: store)
        // bash rather than sh: macOS's /bin/sh execs the real shell a moment after launch, and
        // whether the registry still knows a process that has exec'd is its own question.
        let step = Process()
        step.executableURL = URL(fileURLWithPath: "/bin/bash")
        step.arguments = ["-c", sleeping.script]
        step.standardOutput = FileHandle.nullDevice
        step.standardError = FileHandle.nullDevice
        try step.run()
        crashed.register(pid: step.processIdentifier)
        let (leader, child) = try await sleeping.pids()

        let next = ChildProcessRegistry()
        let orphans = next.open(at: store)
        #expect(orphans.map(\.pid) == [leader])
        next.reap(orphans)

        try await Self.waitUntil("the step and its child exited") {
            !Self.isAlive(leader) && !Self.isAlive(child)
        }
        #expect(!Self.isAlive(leader), "the step outlived the reap")
        #expect(!Self.isAlive(child), "what the step started outlived the reap")
    }

    @Test("A failed step still reports its error, and clearing it allows another try")
    func aFailureIsStillShown() async throws {
        let model = AppModel(settings: .init())
        let failing = AppModel.RepairStep(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo 'the lock did not match'; exit 1"],
            currentDirectory: nil, label: "Installing"
        )
        model.runRepair(id: "repair-fail-test", steps: [failing]) {}
        try await Self.waitUntil("the step failed") {
            model.repairs["repair-fail-test"]?.error != nil
        }
        model.cancelRepair("repair-fail-test")
        #expect(model.repairs["repair-fail-test"] == nil)
    }
}
