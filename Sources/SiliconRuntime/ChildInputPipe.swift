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
