import Foundation
import SiliconCore

/// Transfer speed measured over a moving window rather than a single sample.
///
/// The downloader reports four times a second, and the obvious way to compute a rate is to divide
/// the bytes that arrived since the last report by the time since the last report. That number is
/// almost right and completely unusable: a quarter of a second is short enough that one delayed
/// packet halves it and the burst that follows doubles it. As a speed readout it flickers. As the
/// input to a time remaining it is worse than useless, because the swing is divided into the
/// bytes left and comes out as an estimate that alternates between twenty seconds and four
/// minutes several times a second.
///
/// Twenty-five samples is about six seconds of history at that report interval — long enough that
/// a stalled chunk does not show, short enough that a connection genuinely slowing down appears
/// within a couple of seconds.
///
/// The rate is taken across the window as a whole — newest bytes minus oldest, over newest time
/// minus oldest — not as the mean of the individual samples. The two differ whenever the samples
/// are not evenly spaced, which is exactly the case here, and only the first is the actual
/// average speed over the period.
public final class RateMeter: @unchecked Sendable {

    /// Samples kept. At the downloader's four-per-second this is roughly a six-second window.
    public static let defaultCapacity = 25

    private struct Sample {
        var bytes: Int64
        var at: Double
    }

    private let capacity: Int
    private let lock = NSLock()
    private var samples: [Sample] = []

    public init(capacity: Int = RateMeter.defaultCapacity) {
        self.capacity = max(2, capacity)
        samples.reserveCapacity(self.capacity)
    }

    /// Records a cumulative byte count and returns the smoothed rate in bytes per second.
    ///
    /// Cumulative rather than incremental deliberately: a download that spans several files
    /// restarts its per-file counter at each boundary, and a meter fed those increments would
    /// read a spurious zero every time one finished.
    @discardableResult
    public func record(totalBytes: Int64, at seconds: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }

        samples.append(Sample(bytes: totalBytes, at: seconds))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }

        guard let oldest = samples.first, let newest = samples.last else { return 0 }
        let span = newest.at - oldest.at
        // One sample is no window at all, and a window with no time in it would divide by zero.
        guard span > 0.001 else { return 0 }
        // Resuming an interrupted transfer can rewind the count; report nothing rather than a
        // negative speed, and let the window refill.
        return max(0, Double(newest.bytes - oldest.bytes) / span)
    }

    /// Drops the history, for when the thing being measured has changed rather than varied.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
    }
}
