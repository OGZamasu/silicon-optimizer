import Foundation
import Testing
@testable import SiliconUI

/// The in-app repairs run their steps through `AppModel.runProcess`, and a step that fails
/// is explained by the last lines it wrote. Those lines are the whole of the message the
/// owner sees, so losing them loses the reason.
@Suite("In-app repair steps")
struct RepairProcessTests {

    /// Far longer than any of these needs: the suite shares the machine with other builds,
    /// and a stall must make a test slow rather than cut its output short.
    private let patient: TimeInterval = 30

    private func step(_ script: String) -> AppModel.RepairStep {
        .init(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            currentDirectory: nil, label: "test"
        )
    }

    /// A step on a set of running steps of its own, so a suite that stops "every" step as
    /// the app quits cannot reach these, nor these it.
    private func run(_ script: String, grace: TimeInterval) async -> String? {
        await AppModel.runProcess(
            step: step(script), process: RepairProcess(running: RepairProcess.Running()),
            outputGrace: grace
        ) { _ in }
    }

    /// The exit was noticed on one queue and the output read on another, and the answer went
    /// out on the exit alone — so a last line still in the pipe was dropped, and a step with
    /// one line of output failed with an empty message. Made deterministic here by writing
    /// that line from a process that outlives the step by a moment.
    @Test func aFailedStepsLastLineIsInItsMessage() async {
        let message = await run(
            "(sleep 0.3; echo 'x.whl did not match its reviewed SHA-256') & exit 1", grace: patient
        )
        #expect(message == "x.whl did not match its reviewed SHA-256")
    }

    @Test func aFailedStepsEarlierLinesStillLeadUpToIt() async {
        let message = await run("echo one; echo two; echo 'the reason'; exit 3", grace: patient)
        #expect(message == "one\ntwo\nthe reason")
    }

    /// The wait for the output is bounded. A step that leaves something behind holding the
    /// pipe — a build service, a daemon — must not hold the repair with it.
    /// Proved by the holder still being there when the answer comes back, rather than by a
    /// stopwatch a busy machine could stop.
    @Test func aPipeHeldOpenAfterTheStepDoesNotHoldTheRepair() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("repair-holder-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let message = await run(
            "/bin/sleep 60 & echo $! > '\(pidFile.path)'; echo 'gave up'; exit 2", grace: 0.5
        )
        let holder = try #require(Int32(
            try String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        defer { kill(holder, SIGKILL) }
        #expect(message == "gave up")
        #expect(kill(holder, 0) == 0, "the repair waited for whatever held its output to go")
    }

    @Test func aStepThatSucceedsHasNoMessage() async {
        #expect(await run("echo fine", grace: patient) == nil)
    }
}
