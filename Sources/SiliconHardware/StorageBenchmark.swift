import Foundation
import SiliconCore

/// Measures sequential read throughput of the volume holding the model library.
///
/// This matters specifically for MoE expert streaming: when experts are paged in from the GGUF
/// on every token, sustained read bandwidth becomes the bottleneck rather than memory bandwidth.
/// Internal Apple SSDs sit in the 3–7 GB/s range; an external USB 3 enclosure at ~400 MB/s makes
/// streaming a bad trade, so we measure rather than assume.
public struct StorageBenchmark: Sendable {

    public struct Result: Sendable, Equatable {
        public var readMBps: Double
        public var writeMBps: Double
        /// Whether this volume is fast enough that expert streaming is worth offering.
        public var supportsExpertStreaming: Bool { readMBps >= 1500 }
    }

    public init() {}

    /// Runs a short benchmark against `directory`. Uses `F_NOCACHE` so the numbers reflect the
    /// device rather than the unified buffer cache.
    public func run(in directory: URL, sizeMB: Int = 256) async throws -> Result {
        let path = directory.appendingPathComponent(".silicon-benchmark-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: path) }

        let byteCount = sizeMB * 1_048_576
        let chunkSize = 8 * 1_048_576
        let chunk = Data(repeating: 0xA5, count: chunkSize)

        FileManager.default.createFile(atPath: path.path, contents: nil)
        let writeHandle = try FileHandle(forWritingTo: path)
        _ = fcntl(writeHandle.fileDescriptor, F_NOCACHE, 1)

        let writeStart = DispatchTime.now()
        for _ in 0..<(byteCount / chunkSize) {
            try writeHandle.write(contentsOf: chunk)
        }
        try writeHandle.synchronize()
        let writeElapsed = elapsedSeconds(since: writeStart)
        try writeHandle.close()

        let readHandle = try FileHandle(forReadingFrom: path)
        _ = fcntl(readHandle.fileDescriptor, F_NOCACHE, 1)
        let readStart = DispatchTime.now()
        var bytesRead = 0
        while let data = try readHandle.read(upToCount: chunkSize), !data.isEmpty {
            bytesRead += data.count
        }
        let readElapsed = elapsedSeconds(since: readStart)
        try readHandle.close()

        let megabytes = Double(byteCount) / 1_048_576
        return Result(
            readMBps: readElapsed > 0 ? Double(bytesRead) / 1_048_576 / readElapsed : 0,
            writeMBps: writeElapsed > 0 ? megabytes / writeElapsed : 0
        )
    }

    private func elapsedSeconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}
