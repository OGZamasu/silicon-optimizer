import Darwin
import Foundation

/// Every server process this app has spawned, tracked so that none of them outlives it.
///
/// Two problems need this, and neither can go through the actors that own the processes.
///
/// `NSApplication.willTerminateNotification` is delivered synchronously and the app exits as
/// soon as its observers return, so there is no time for an `await` to reach `ServerProcess`
/// and ask what it is running. A lock-protected set can answer in that window; an actor cannot.
///
/// And a crash, a SIGKILL or a force quit runs no handler at all. Those leave a `llama-server`
/// holding a model's worth of wired memory and its TCP port, reparented to launchd, for as long
/// as the machine stays up. So the set is mirrored to a file, and the next launch reaps whatever
/// the last one abandoned.
///
/// The app uses one process-wide instance through the static API below. The instance form
/// exists for tests: registry state was process-global once, and every suite that asserted on
/// `tracked` raced every other suite that spawned a child (hub issue #12). A test now builds
/// its own registry and cannot see anyone else's children.
public final class ChildProcessRegistry: @unchecked Sendable {

    /// Enough to recognise a process across launches without ever mistaking a recycled pid for
    /// one of ours.
    ///
    /// The start time is what makes that safe. The kernel reissues pids freely, so a stored pid
    /// on its own is a loaded gun pointed at whatever process inherited it; the same pid with
    /// the same executable *and* the same start second is the process we started.
    public struct Entry: Codable, Sendable, Equatable {
        public var pid: Int32
        public var executablePath: String
        /// Seconds since the epoch, as the kernel reports the process's start.
        public var startedAt: UInt64

        public init(pid: Int32, executablePath: String, startedAt: UInt64) {
            self.pid = pid
            self.executablePath = executablePath
            self.startedAt = startedAt
        }
    }

    /// The one registry the app itself uses.
    public static let shared = ChildProcessRegistry()

    /// The lock is the whole point: this is read from a `willTerminate` observer, from
    /// `Process.terminationHandler` on an arbitrary queue, and from actors. An actor could not
    /// serve the first of those, so the mutable state is guarded by hand.
    private let lock = NSLock()
    private var entries: [Int32: Entry] = [:]
    private var storeURL: URL?

    public init() {}

    // MARK: - Identity

    /// Reads a live process's identity from the kernel. Nil when the pid is gone, or belongs to
    /// something this process is not allowed to inspect.
    public static func identify(_ pid: Int32) -> Entry? {
        guard pid > 0 else { return nil }

        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }

        // The header's PROC_PIDPATHINFO_MAXSIZE macro does not import into Swift; it is
        // 4 * MAXPATHLEN, and proc_pidpath will not write more than it is given.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }

        return Entry(
            pid: pid,
            executablePath: String(cString: buffer),
            startedAt: UInt64(info.pbi_start_tvsec)
        )
    }

    /// Whether `entry` still describes the process holding that pid right now.
    public static func isStillAlive(_ entry: Entry) -> Bool {
        guard let live = identify(entry.pid) else { return false }
        return live.executablePath == entry.executablePath && live.startedAt == entry.startedAt
    }

    // MARK: - Membership

    /// Records a freshly spawned child. Called with the pid the moment `Process.run()` returns,
    /// so the window in which a child is running but untracked is as small as it can be.
    public func register(pid: Int32) {
        guard let entry = Self.identify(pid) else { return }
        lock.lock()
        entries[pid] = entry
        lock.unlock()
        persist()
    }

    /// Forgets a child that has exited or been terminated deliberately.
    public func unregister(pid: Int32) {
        lock.lock()
        entries[pid] = nil
        lock.unlock()
        persist()
    }

    /// Everything currently tracked, membership order unspecified.
    public var tracked: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.values)
    }

    // MARK: - Termination

    /// Signals every tracked child and returns the ones it signalled.
    ///
    /// Deliberately synchronous and allocation-light: this runs from a `willTerminate`
    /// observer, with the process about to exit underneath it. SIGTERM rather than SIGKILL so
    /// the server releases its Metal buffers itself — the kernel reclaiming tens of gigabytes
    /// stalls the whole machine for seconds.
    @discardableResult
    public func terminateAll() -> [Entry] {
        lock.lock()
        let doomed = Array(entries.values)
        entries.removeAll()
        lock.unlock()

        for entry in doomed where Self.isStillAlive(entry) {
            kill(entry.pid, SIGTERM)
        }
        persist()
        return doomed
    }

    // MARK: - Crossing launches

    /// Points the registry at the file it mirrors itself to, and returns what the previous
    /// launch left behind.
    ///
    /// Call once at startup, before anything allocates a port: `reap` clears the orphans that
    /// would otherwise still be holding them.
    @discardableResult
    public func open(at url: URL) -> [Entry] {
        lock.lock()
        storeURL = url
        lock.unlock()

        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }

        // Anything still alive under its recorded identity is ours and was abandoned; anything
        // else is a pid that has already been reused or released, and must be left alone.
        return stored.filter { Self.isStillAlive($0) && $0.pid != getpid() }
    }

    /// Terminates orphans left by a previous launch. Returns the ones it killed.
    @discardableResult
    public func reap(_ orphans: [Entry]) -> [Entry] {
        var killed: [Entry] = []
        for orphan in orphans where Self.isStillAlive(orphan) {
            kill(orphan.pid, SIGTERM)
            killed.append(orphan)
        }
        // The port matters more than the memory here: a survivor still holding the harness's
        // inference port pushes the next server onto a random one, and the harness's provider
        // config keeps pointing at the corpse. Give SIGTERM a moment, then insist.
        guard !killed.isEmpty else { return killed }
        for _ in 0..<20 {
            if !killed.contains(where: { Self.isStillAlive($0) }) { break }
            usleep(100_000)
        }
        for orphan in killed where Self.isStillAlive(orphan) {
            kill(orphan.pid, SIGKILL)
        }
        // Only now: until the reap has happened the file is the sole record of these processes,
        // so a crash between `open` and here has to leave the next launch something to retry
        // with. Afterwards it should describe what is actually running, which is whatever this
        // launch has spawned so far.
        persist()
        return killed
    }

    /// Writes the current membership out, so a launch that never gets to run a handler still
    /// leaves its successor something to work from.
    private func persist() {
        lock.lock()
        let url = storeURL
        let snapshot = Array(entries.values)
        lock.unlock()

        guard let url else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - The app's process-wide face

    // Call sites throughout the app address the shared instance through these; only tests
    // construct registries of their own.

    public static func register(pid: Int32) { shared.register(pid: pid) }
    public static func unregister(pid: Int32) { shared.unregister(pid: pid) }
    public static var tracked: [Entry] { shared.tracked }
    @discardableResult
    public static func terminateAll() -> [Entry] { shared.terminateAll() }
    @discardableResult
    public static func open(at url: URL) -> [Entry] { shared.open(at: url) }
    @discardableResult
    public static func reap(_ orphans: [Entry]) -> [Entry] { shared.reap(orphans) }
}
