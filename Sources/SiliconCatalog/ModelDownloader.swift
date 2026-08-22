import CryptoKit
import Foundation
import SiliconCore

/// Downloads model files with resume support and SHA-256 verification.
///
/// Model files run to tens of gigabytes, so a download that cannot resume is not usable. We
/// stream bytes to a `.part` file and use an HTTP Range request to pick up where a previous
/// attempt stopped.
public actor ModelDownloader {

    public struct Progress: Sendable, Equatable {
        public var bytesReceived: Bytes
        public var bytesExpected: Bytes
        public var bytesPerSecond: Double
        public var currentFile: String
        public var fileIndex: Int
        public var fileCount: Int

        public var fraction: Double { bytesReceived.fraction(of: bytesExpected) }

        public var estimatedTimeRemaining: TimeInterval? {
            guard bytesPerSecond > 1 else { return nil }
            let remaining = Double((bytesExpected - bytesReceived).rawValue)
            return remaining > 0 ? remaining / bytesPerSecond : 0
        }
    }

    public enum DownloadError: Error, LocalizedError {
        case checksumMismatch(file: String, expected: String, actual: String)
        case insufficientDiskSpace(needed: Bytes, available: Bytes)
        case incompleteTransfer(file: String, received: Bytes, expected: Bytes)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .checksumMismatch(let file, _, _):
                return "\(file) failed verification. The download was corrupted and has been discarded."
            case .insufficientDiskSpace(let needed, let available):
                // Naming the reserve matters: "6 GB needed, 12 GB free" reads as a
                // contradiction unless the cushion is explained.
                let shortfall = Bytes(
                    max(0, needed.rawValue + ModelDownloader.diskReserve.rawValue
                        - available.rawValue)
                )
                return "Not enough disk space. \(needed.formatted) is needed and "
                    + "\(available.formatted) is free, but \(ModelDownloader.diskReserve.formatted) "
                    + "is kept in reserve so a download cannot fill the startup volume. "
                    + "Free about \(shortfall.formatted) and try again."
            case .incompleteTransfer(let file, let received, let expected):
                return "\(file) arrived incomplete: \(received.formatted) of \(expected.formatted). "
                    + "The partial file has been kept and will be resumed."
            case .cancelled:
                return "Download cancelled."
            }
        }
    }

    private let configuration: URLSessionConfiguration
    private let token: String?
    /// Test seam: a local server standing in for huggingface.co, so the multi-file and
    /// resume paths can be exercised for real without moving gigabytes.
    private let overrideBase: URL?

    public init(token: String? = nil, baseURL: URL? = nil) {
        let configuration = URLSessionConfiguration.default
        // Model downloads are long-lived; the default 7-day resource timeout is fine but the
        // per-request timeout must be generous enough for a slow first byte on a busy CDN.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60 * 24 * 7
        configuration.waitsForConnectivity = true
        self.configuration = configuration
        self.token = token
        self.overrideBase = baseURL
    }

    /// Downloads a resolution into `directory`, reporting progress as it goes.
    /// Returns the local URLs of every file written, head shard first.
    public func download(
        _ resolution: ModelResolver.Resolution,
        to directory: URL,
        onProgress: @Sendable @escaping (Progress) -> Void
    ) async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var queue = resolution.files
        if let projector = resolution.projector { queue.append(projector) }

        let totalBytes = resolution.totalSize
        try checkDiskSpace(needed: totalBytes, at: directory)

        var written: [URL] = []
        var completedBytes = Bytes.zero
        // One meter for the whole download rather than one per file: a sharded GGUF finishes a
        // part every few seconds, and a meter that restarted at each boundary would spend most
        // of its life refilling.
        let meter = RateMeter()

        for (index, file) in queue.enumerated() {
            let destination = directory.appendingPathComponent(
                (file.path as NSString).lastPathComponent
            )

            // Skip files already present and verified from an earlier run.
            if FileManager.default.fileExists(atPath: destination.path),
               try await isValid(destination, expecting: file) {
                completedBytes += file.size
                written.append(destination)
                continue
            }

            try await downloadFile(
                file, from: resolution.repository, to: destination,
                alreadyCompleted: completedBytes, grandTotal: totalBytes,
                fileIndex: index, fileCount: queue.count, meter: meter, onProgress: onProgress
            )
            completedBytes += file.size
            written.append(destination)
        }

        return written
    }

    // MARK: - Single file

    private func downloadFile(
        _ file: HuggingFaceClient.RepoFile,
        from repository: String,
        to destination: URL,
        alreadyCompleted: Bytes,
        grandTotal: Bytes,
        fileIndex: Int,
        fileCount: Int,
        meter: RateMeter,
        onProgress: @Sendable @escaping (Progress) -> Void
    ) async throws {
        let partial = destination.appendingPathExtension("part")
        var existingBytes: Int64 = 0
        if let attributes = try? FileManager.default.attributesOfItem(atPath: partial.path) {
            existingBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }

        let remote = overrideBase.map {
            $0.appendingPathComponent(repository).appendingPathComponent(file.path)
        } ?? HuggingFaceClient.downloadURL(repository: repository, file: file.path)
        var request = URLRequest(url: remote)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if existingBytes > 0 {
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        // The file is opened *before* the request goes out.
        //
        // Opening it when the response event arrives looks natural but is a data race: the
        // delegate can deliver body chunks before the consumer has processed the response, and
        // those chunks were being silently discarded. The result was a short file that failed
        // its checksum — intermittently, depending on how fast the first chunk arrived.
        if !FileManager.default.fileExists(atPath: partial.path) {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()

        let streamer = ChunkedDownload()
        let events = streamer.start(request, configuration: configuration)

        var received = existingBytes
        var lastReport = DispatchTime.now()
        var sawResponse = false

        do {
            for try await event in events {
                switch event {
                case .response(let http):
                    sawResponse = true
                    guard (200..<300).contains(http.statusCode) else {
                        streamer.cancel()
                        throw HuggingFaceClient.ClientError.badResponse(http.statusCode)
                    }
                    // A 200 answering a Range request means the server ignored it, so anything
                    // already on disk is a prefix of a different byte stream — start over.
                    if existingBytes > 0 && http.statusCode == 200 {
                        try handle.truncate(atOffset: 0)
                        existingBytes = 0
                        received = 0
                        meter.reset()
                    }

                case .chunk(let data):
                    try handle.write(contentsOf: data)
                    received += Int64(data.count)

                    let now = DispatchTime.now()
                    let elapsed = Double(now.uptimeNanoseconds - lastReport.uptimeNanoseconds) / 1e9
                    if elapsed >= 0.25 {
                        let total = alreadyCompleted + Bytes(received)
                        onProgress(Progress(
                            bytesReceived: total,
                            bytesExpected: grandTotal,
                            bytesPerSecond: meter.record(
                                totalBytes: total.rawValue,
                                at: Double(now.uptimeNanoseconds) / 1e9
                            ),
                            currentFile: (file.path as NSString).lastPathComponent,
                            fileIndex: fileIndex, fileCount: fileCount
                        ))
                        lastReport = now
                    }
                    if Task.isCancelled {
                        streamer.cancel()
                        throw DownloadError.cancelled
                    }
                }
            }
        } catch {
            // The partial file is deliberately kept so the next attempt can resume from it.
            try? handle.synchronize()
            throw error
        }

        guard sawResponse else { throw HuggingFaceClient.ClientError.badResponse(0) }
        try handle.synchronize()
        try handle.close()

        // Size first. A length mismatch means the transfer was cut short, which is a different
        // problem from corruption and deserves a different message.
        let writtenSize = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size])
            .flatMap { ($0 as? NSNumber)?.int64Value } ?? 0
        if file.size > .zero, writtenSize != file.size.rawValue {
            throw DownloadError.incompleteTransfer(
                file: (file.path as NSString).lastPathComponent,
                received: Bytes(writtenSize), expected: file.size
            )
        }

        if let expected = file.sha256 {
            let actual = try sha256(of: partial)
            guard actual == expected else {
                try? FileManager.default.removeItem(at: partial)
                throw DownloadError.checksumMismatch(
                    file: (file.path as NSString).lastPathComponent,
                    expected: expected, actual: actual
                )
            }
        }

        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)

        onProgress(Progress(
            bytesReceived: alreadyCompleted + file.size, bytesExpected: grandTotal,
            bytesPerSecond: 0, currentFile: (file.path as NSString).lastPathComponent,
            fileIndex: fileIndex, fileCount: fileCount
        ))
    }

    // MARK: - Verification

    private func isValid(_ url: URL, expecting file: HuggingFaceClient.RepoFile) async throws -> Bool {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size == file.size.rawValue else { return false }
        // Size matching is enough to skip a re-download; a full re-hash of a 40 GB file on
        // every launch would be worse than the risk it guards against.
        return true
    }

    /// Streams the file through SHA-256 so verification never loads it into memory.
    nonisolated func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 * 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Space kept free regardless of the download, so a model cannot push the startup volume
    /// into the state where macOS cannot swap or take snapshots.
    public static let diskReserve = Bytes.gib(10)

    /// Checks free space without starting anything.
    ///
    /// Exposed so callers can fail *before* telling a user a download has begun. The transfer
    /// itself runs detached, so a check that only happened inside it would surface the failure
    /// long after the caller had reported success.
    public static func checkDiskSpace(needed: Bytes, at directory: URL) throws {
        // Walk up to the nearest existing ancestor: the target directory is usually created
        // as part of the download that has not started yet.
        var probe = directory
        while !FileManager.default.fileExists(atPath: probe.path),
              probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        guard let values = try? probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ), let available = values.volumeAvailableCapacityForImportantUsage else { return }

        guard Bytes(available) > needed + diskReserve else {
            throw DownloadError.insufficientDiskSpace(needed: needed, available: Bytes(available))
        }
    }

    private func checkDiskSpace(needed: Bytes, at directory: URL) throws {
        try Self.checkDiskSpace(needed: needed, at: directory)
    }
}
