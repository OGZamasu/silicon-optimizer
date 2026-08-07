import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore

/// Exercises interrupted downloads against a real file on Hugging Face.
///
/// Model files run to tens of gigabytes, so resuming is not a nicety — a download that restarts
/// from zero after a dropped connection is unusable. Opt-in because it transfers ~270 MB:
///
///     SILICON_NETWORK_TESTS=1 swift test --filter DownloadResume
@Suite("Download resume", .enabled(if: ProcessInfo.processInfo.environment["SILICON_NETWORK_TESTS"] == "1"))
struct DownloadResumeTests {

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-resume-\(UUID().uuidString)")
    }

    /// Interrupt partway, then resume: the second attempt must continue from the bytes already
    /// on disk rather than starting over, and the finished file must still pass its checksum.
    @Test func resumesFromPartialFileAndVerifies() async throws {
        let entry = try #require(ModelCatalog.entry(id: "nomic-embed-text-v1.5"))
        let resolution = try await ModelResolver(client: HuggingFaceClient())
            .resolve(entry: entry, quantization: .f16)
        let expected = try #require(resolution.files.first)
        try #require(expected.sha256 != nil, "no checksum published; resume test is meaningless")

        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        await CancelFlag.shared.reset()
        // First attempt: cut it as soon as anything meaningful has landed. The trigger has to
        // be small — this file transfers in about nine seconds, so a large threshold fires
        // after the download has already finished and there is nothing left to resume.
        let firstAttempt = Task {
            do {
                return try await ModelDownloader().download(resolution, to: directory) { progress in
                    if progress.bytesReceived > .mib(8) {
                        Task { await CancelFlag.shared.trip() }
                    }
                }
            } catch {
                await CancelFlag.shared.recordError("\(error)")
                throw error
            }
        }
        // Poll the flag rather than the task, so cancellation happens from outside.
        while await !CancelFlag.shared.isTripped, !firstAttempt.isCancelled {
            try await Task.sleep(for: .milliseconds(100))
            if await CancelFlag.shared.isTripped { break }
        }
        firstAttempt.cancel()
        _ = try? await firstAttempt.value

        let partial = directory.appendingPathComponent(
            (expected.path as NSString).lastPathComponent
        ).appendingPathExtension("part")

        let partialSize = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size])
            .flatMap { ($0 as? NSNumber)?.int64Value } ?? 0
        let failure = await CancelFlag.shared.lastError ?? "none"
        try #require(partialSize > 0,
                     "the download finished before it could be cut; error: \(failure)")
        #expect(partialSize < expected.size.rawValue, "the download finished before it was cut")

        // Second attempt: must resume, not restart.
        let witness = ProgressWitness()
        let files = try await ModelDownloader().download(resolution, to: directory) { progress in
            Task { await witness.note(progress) }
        }
        // The first progress report of the resumed attempt must already be past what was on
        // disk; a restart would report a few megabytes.
        let firstReport = await witness.firstReportedBytes ?? 0
        #expect(firstReport >= partialSize,
                "progress restarted at \(firstReport) with \(partialSize) already on disk")

        let finished = try #require(files.first)
        let size = (try FileManager.default.attributesOfItem(atPath: finished.path)[.size]
            as? NSNumber)?.int64Value ?? 0
        #expect(size == expected.size.rawValue, "final size does not match the published size")

        // The checksum is the real proof: a resumed file assembled from two ranges must hash
        // identically to one fetched in a single pass.
        let digest = try ModelDownloader().sha256(of: finished)
        #expect(digest == expected.sha256, "resumed file failed verification")
    }

    /// A finished file must not be downloaded again.
    @Test func completedFileIsNotRefetched() async throws {
        let entry = try #require(ModelCatalog.entry(id: "nomic-embed-text-v1.5"))
        let resolution = try await ModelResolver(client: HuggingFaceClient())
            .resolve(entry: entry, quantization: .f16)

        let directory = scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await ModelDownloader().download(resolution, to: directory) { _ in }

        let witness = ProgressWitness()
        _ = try await ModelDownloader().download(resolution, to: directory) { progress in
            Task { await witness.note(progress) }
        }
        #expect(await !witness.transferred, "an already-complete file was downloaded again")
    }
}

/// Minimal cross-task state, since the progress callback is `@Sendable` and cannot capture
/// mutable locals.
actor CancelFlag {
    static let shared = CancelFlag()
    private var tripped = false
    private(set) var lastError: String?
    var isTripped: Bool { tripped }
    func trip() { tripped = true }
    func reset() { tripped = false; lastError = nil }
    func recordError(_ message: String) { lastError = message }
}

/// Records observations made from inside a `@Sendable` progress callback.
actor ProgressWitness {
    private(set) var sawResumePoint = false
    private(set) var transferred = false
    private(set) var firstReportedBytes: Int64?

    func note(_ progress: ModelDownloader.Progress) {
        if firstReportedBytes == nil { firstReportedBytes = progress.bytesReceived.rawValue }
        if progress.bytesPerSecond > 0 { transferred = true }
    }

    func markResumed() { sawResumePoint = true }
}
