import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore

@Suite("Transfer rate smoothing")
struct RateMeterTests {

    /// The downloader reports four times a second.
    private let interval = 0.25

    /// A steady stream reads as its actual speed. The window must not bias the answer, only
    /// stabilise it.
    @Test func reportsTheTrueRateForASteadyStream() {
        let meter = RateMeter()
        let perSecond = 20_000_000.0
        var rate = 0.0
        for step in 1...40 {
            let t = Double(step) * interval
            rate = meter.record(totalBytes: Int64(perSecond * t), at: t)
        }
        #expect(abs(rate - perSecond) / perSecond < 0.01)
    }

    /// The bug this exists for. One quarter-second in which nothing arrives used to take the
    /// reported rate to zero, which took the time remaining to nil, which made the readout blink
    /// between a number and nothing several times a second.
    @Test func oneStalledSampleBarelyMovesTheRate() {
        let meter = RateMeter()
        let perSecond = 20_000_000.0
        var bytes = Int64(0)
        var rate = 0.0
        for step in 1...30 {
            // Nothing arrives in sample 25; twice as much arrives in sample 26.
            let arrived: Double = switch step {
            case 25: 0
            case 26: perSecond * interval * 2
            default: perSecond * interval
            }
            bytes += Int64(arrived)
            rate = meter.record(totalBytes: bytes, at: Double(step) * interval)
        }
        #expect(rate > perSecond * 0.9, "a single stall should not collapse the rate")
        #expect(rate < perSecond * 1.1, "nor should the burst after it overshoot")
    }

    /// Smoothing is only worth having if it still tracks reality. A connection that genuinely
    /// halves must be reflected within a few seconds, not held up by stale history.
    @Test func followsARealChangeInSpeedWithinTheWindow() {
        let meter = RateMeter()
        let fast = 40_000_000.0, slow = 10_000_000.0
        var bytes = Int64(0)
        var time = 0.0

        for _ in 1...40 {
            time += interval
            bytes += Int64(fast * interval)
            _ = meter.record(totalBytes: bytes, at: time)
        }
        // Six and a quarter seconds later — one full window — the old speed is entirely gone.
        var rate = 0.0
        for _ in 1...25 {
            time += interval
            bytes += Int64(slow * interval)
            rate = meter.record(totalBytes: bytes, at: time)
        }
        #expect(abs(rate - slow) / slow < 0.05)
    }

    /// Twenty-five samples at four a second is a little over six seconds of history. Longer
    /// would be smoother and would also mean a download that stops looks healthy for far too
    /// long.
    @Test func keepsAboutSixSecondsOfHistory() {
        #expect(RateMeter.defaultCapacity == 25)
        let seconds = Double(RateMeter.defaultCapacity) * 0.25
        #expect(seconds > 5 && seconds < 8)
    }

    /// The first sample has nothing to compare against, and a rate of zero is the honest answer
    /// — the UI shows "Starting…" rather than a fabricated number.
    @Test func reportsNothingUntilThereIsAWindowToMeasureOver() {
        let meter = RateMeter()
        #expect(meter.record(totalBytes: 1_000_000, at: 1.0) == 0)
        #expect(meter.record(totalBytes: 2_000_000, at: 2.0) == 1_000_000)
    }

    /// A resumed transfer can report a smaller total than the sample before it, and a negative
    /// speed would come back as a negative time remaining.
    @Test func neverReportsANegativeRate() {
        let meter = RateMeter()
        _ = meter.record(totalBytes: 5_000_000, at: 1.0)
        #expect(meter.record(totalBytes: 1_000_000, at: 2.0) == 0)
    }

    /// The window measures across the whole span rather than averaging per-sample rates, which
    /// matters because the samples are not evenly spaced. Averaging the rates of a 0.25s sample
    /// and a 2s sample weights them equally; only one of those is a second of real transfer.
    @Test func weightsSamplesByTimeNotByCount() {
        let meter = RateMeter()
        // 1 MB in 0.25s, then 1 MB in 2s. True average: 2 MB over 2.25s = 889 KB/s.
        _ = meter.record(totalBytes: 0, at: 0)
        _ = meter.record(totalBytes: 1_000_000, at: 0.25)
        let rate = meter.record(totalBytes: 2_000_000, at: 2.25)
        #expect(abs(rate - 888_889) < 1000, "got \(rate)")
        // The mean of the two sample rates would have been 2.25 MB/s — two and a half times out.
    }

    /// The time remaining is what a person actually reads, so it is the thing that had to stop
    /// swinging. Measured against the arithmetic the downloader used to do, on the same stream.
    ///
    /// A boxcar window does not remove the swing entirely — the seven-step arrival pattern here
    /// does not divide into a twenty-five-sample window, so a few percent of oscillation
    /// survives. That is the residue, and it is not what anyone noticed.
    @Test func timeRemainingStopsSwinging() {
        let perSecond = 20_000_000.0
        let total = Bytes(Int64(2_000_000_000))
        // A quarter of a second of a real TCP stream is not a quarter of the second's bytes.
        // This is a fixed pattern rather than a random one so the test means the same thing
        // every run; it averages to exactly the nominal rate and swings by ten times across
        // neighbouring samples, which is the shape of the readout people complained about.
        let arrivalPattern = [0.2, 1.9, 0.5, 1.4, 0.0, 2.0, 1.0]

        func estimates(smoothed: Bool) -> [TimeInterval?] {
            let meter = RateMeter()
            var bytes = Int64(0), previous = Int64(0)
            var out: [TimeInterval?] = []
            for step in 1...60 {
                let arrived = arrivalPattern[step % arrivalPattern.count] * perSecond * interval
                bytes += Int64(arrived)
                let time = Double(step) * interval
                let rate = smoothed
                    ? meter.record(totalBytes: bytes, at: time)
                    : Double(bytes - previous) / interval               // the old calculation
                previous = bytes
                let progress = ModelDownloader.Progress(
                    bytesReceived: Bytes(bytes), bytesExpected: total,
                    bytesPerSecond: rate, currentFile: "x", fileIndex: 0, fileCount: 1
                )
                if step > RateMeter.defaultCapacity { out.append(progress.estimatedTimeRemaining) }
            }
            return out
        }

        let smoothed = estimates(smoothed: true)
        let raw = estimates(smoothed: false)

        // The blinking: the old rate went to zero whenever a sample happened to catch a gap
        // between chunks, which made the estimate nil, which made the label vanish and come back.
        #expect(raw.contains { $0 == nil })
        #expect(!smoothed.contains { $0 == nil }, "the estimate must never disappear")

        func worstSwing(_ values: [TimeInterval?]) -> Double {
            let present = values.compactMap { $0 }
            return zip(present, present.dropFirst())
                .map { abs($1 - $0) / max($0, 1) }
                .max() ?? 0
        }

        // The old figure moved by several times the remaining time between one sample and the
        // next — "31 seconds left" to "five minutes left" and back, four times a second.
        #expect(worstSwing(raw) > 2.0, "got \(worstSwing(raw))")
        #expect(worstSwing(smoothed) < 0.10, "got \(worstSwing(smoothed))")
        #expect(worstSwing(smoothed) < worstSwing(raw) / 10)
    }
}
