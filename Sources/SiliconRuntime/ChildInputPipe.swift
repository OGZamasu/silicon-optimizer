import Darwin
import Foundation

extension Pipe {
    /// A pipe for a child's standard input whose writes fail instead of killing this process.
    ///
    /// Writing to a pipe that nobody reads raises SIGPIPE, and the default action for SIGPIPE
    /// is to end the process — here, the whole app, because a sidecar died a moment before a
    /// request went out to it. `isRunning` cannot close that window: the child is gone some
    /// time before Foundation reaps it. `F_SETNOSIGPIPE` turns the signal into an `EPIPE` from
    /// the write, which `FileHandle.write(contentsOf:)` throws like any other I/O error, so the
    /// caller learns the child stopped the ordinary way.
    ///
    /// Per descriptor rather than `signal(SIGPIPE, SIG_IGN)`: the process-wide switch would
    /// also change every socket and pipe this app does not own, and an ignored signal survives
    /// `exec` into every child launched afterwards unless the spawner resets it.
    public static func childInput() -> Pipe {
        let pipe = Pipe()
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        return pipe
    }
}

extension FileHandle {
    /// Writes to a descriptor this process did not make — its own standard error, above all
    /// — and says whether the bytes went, instead of ending the process when nobody reads.
    ///
    /// Launched with stderr piped to a reader that has since exited (`… 2>&1 | head`, a log
    /// collector that crashed), a diagnostic line is a SIGPIPE, and the non-throwing
    /// `write(_:)` raises on the `EPIPE` besides. So the same per-descriptor
    /// `F_SETNOSIGPIPE` as `Pipe.childInput()` is set first — here, because this descriptor
    /// was handed to us rather than made — and the throwing write's error is the answer.
    @discardableResult
    public func writeUnlessNobodyIsReading(_ data: Data) -> Bool {
        _ = fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)
        return (try? write(contentsOf: data)) != nil
    }
}
