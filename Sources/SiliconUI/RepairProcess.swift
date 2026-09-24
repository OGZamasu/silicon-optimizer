import Darwin
import Foundation
import SiliconRuntime

/// One repair step's process, as far as stopping it goes.
///
/// A repair runs pip, xcodebuild or a curl script for minutes, and each of those starts
/// children of its own. Cancelling the task that waits for one stops none of it: the step runs
/// to the end, and the Install button — back on screen the moment the job is gone — starts a
/// second copy beside it in the same environment. So Stop signals the step's whole process
/// group (Foundation starts every child as the leader of a group of its own), and quitting the
/// app does the same for every step still running, because a pip left behind by a quit keeps
/// writing into an environment the next launch is about to use.
final class RepairProcess: @unchecked Sendable {

    /// How long a stopped step gets to exit on SIGTERM before it is killed outright.
    static let stopGrace: TimeInterval = 5

    /// Every step that has started and not yet exited. Read from a `willTerminate` observer,
    /// so a lock rather than an actor, as with `ChildProcessRegistry`.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var running: [ObjectIdentifier: RepairProcess] = [:]

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var stopRequested = false
    private var hasExited = false

    /// Called the moment the step's process has started.
    func launched(_ process: Process) {
        let pid = process.processIdentifier
        let stopNow: Bool? = lock.withLock {
            // The process can finish, and `exited()` run, before the thread that launched it
            // gets here; a pid that has already been reaped is nobody's to track.
            guard !hasExited else { return nil }
            self.pid = pid
            return stopRequested
        }
        guard let stopNow else { return }
        Self.registryLock.withLock { Self.running[ObjectIdentifier(self)] = self }
        // For the next launch's reaper, should this one crash rather than quit.
        ChildProcessRegistry.register(pid: pid)
        if stopNow { stop() }
    }

    /// Called once the step's process has exited and been reaped.
    func exited() {
        let pid = lock.withLock {
            hasExited = true
            return self.pid
        }
        Self.registryLock.withLock { Self.running[ObjectIdentifier(self)] = nil }
        if pid > 0 { ChildProcessRegistry.unregister(pid: pid) }
    }

    /// Stop: SIGTERM to the step and everything it started, then SIGKILL for whatever is still
    /// there after the grace period. Before launch, it only marks the step, and `launched`
    /// stops it as soon as it starts.
    func stop() {
        let pid = lock.withLock {
            stopRequested = true
            return hasExited ? 0 : self.pid
        }
        guard pid > 0 else { return }
        signal(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.stopGrace) { [self] in
            signal(SIGKILL)
        }
    }

    /// Every step still running, as the app quits. Synchronous and SIGTERM only: this runs from
    /// a `willTerminate` observer with the process about to exit underneath it.
    static func stopAll() {
        let steps = registryLock.withLock { Array(running.values) }
        for step in steps { step.signal(SIGTERM) }
    }

    /// Signals the step's process group, or only the step when it is not a group leader. The
    /// pid is read under the lock that `exited()` takes, so a step already reaped — whose pid
    /// the kernel may have handed on — is never signalled.
    private func signal(_ signal: Int32) {
        lock.withLock {
            guard !hasExited, pid > 0 else { return }
            let group = getpgid(pid)
            if group == pid, group != getpgrp() {
                killpg(group, signal)
            } else {
                kill(pid, signal)
            }
        }
    }
}
