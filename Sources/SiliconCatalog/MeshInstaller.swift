import Foundation
import SiliconCore

/// Downloads 3D-model weights ahead of time, driving the same `hf` CLI as image models.
///
/// Two destinations exist because the two engines resolve weights differently: TRELLIS.2 goes
/// through the shared Hugging Face hub cache (so a pre-download is exactly what its own loader
/// would have fetched mid-run), while hy3d expects a plain directory of safetensors under its
/// weights folder (`hf download --local-dir`).
public struct MeshInstaller: Sendable {

    public enum Destination: Sendable, Equatable {
        /// The shared Hugging Face cache — where TRELLIS.2's loader resolves from.
        case hubCache
        /// A literal directory — the hy3d weights layout.
        case localDirectory(URL)
    }

    /// One downloadable fix for a not-ready backend.
    public struct Download: Sendable, Equatable {
        public var repository: String
        public var destination: Destination
        /// Catalog estimate, used for the progress denominator until real bytes arrive.
        public var expectedSize: Bytes

        public init(repository: String, destination: Destination, expectedSize: Bytes) {
            self.repository = repository
            self.destination = destination
            self.expectedSize = expectedSize
        }
    }

    public enum InstallError: Error, LocalizedError {
        case toolMissing
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .toolMissing:
                "The downloader that ships with MFLUX was not found. Install MFLUX from the "
                    + "Images tab first — 3D downloads ride on the same tool."
            case .failed(let message):
                message
            }
        }
    }

    private let executable: URL
    private let token: String?

    public init(executable: URL, token: String? = nil) {
        self.executable = executable
        self.token = token
    }

    /// Bytes already on disk for a download, wherever it lands.
    public static func downloadedSize(of download: Download) -> Bytes {
        switch download.destination {
        case .hubCache:
            return DiffusionInstaller.installedSize(download.repository)
        case .localDirectory(let directory):
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.fileSizeKey]
            )) ?? []
            let total = entries.reduce(Int64(0)) { sum, url in
                sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
            return Bytes(total)
        }
    }

    /// Fetches the weights, reporting progress by watching the destination grow — same
    /// technique as the image installer, for the same reason: the CLI hides its progress bars
    /// from a pipe, and polling stays honest across its parallel and resumed transfers.
    public func download(
        _ download: Download,
        onProgress: @Sendable @escaping (ModelDownloader.Progress) -> Void
    ) async throws {
        var arguments = ["download", download.repository]
        if case .localDirectory(let directory) = download.destination {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            arguments += ["--local-dir", directory.path]
        }
        if let token, !token.isEmpty {
            arguments += ["--token", token]
        }

        let already = Self.downloadedSize(of: download)
        let expected = max(download.expectedSize, already)
        let meter = RateMeter()

        let watcher = Task {
            while !Task.isCancelled {
                let current = Self.downloadedSize(of: download)
                let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
                onProgress(ModelDownloader.Progress(
                    bytesReceived: current,
                    bytesExpected: max(expected, current),
                    bytesPerSecond: meter.record(totalBytes: current.rawValue, at: now),
                    currentFile: download.repository,
                    fileIndex: 0,
                    fileCount: 1
                ))
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        defer { watcher.cancel() }

        let output = try await run(arguments: arguments)
        let lowered = output.lowercased()
        if lowered.contains("access denied") || lowered.contains("requires approval")
            || lowered.contains("401") {
            throw InstallError.failed(
                "\(download.repository) needs a sign-in. Add a Hugging Face token in "
                    + "Settings, and accept the model's licence on its page."
            )
        }
        // The caller re-probes the installation to decide success; a partial fetch that the
        // probe rejects surfaces the CLI's own last words.
        if Self.downloadedSize(of: download).rawValue == already.rawValue,
           download.expectedSize > already {
            throw InstallError.failed(
                output.split(separator: "\n").suffix(4).joined(separator: "\n")
            )
        }
    }

    private func run(arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        try process.run()
        // Read concurrently: a full pipe buffer would deadlock a chatty download.
        let reader = Task.detached {
            String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in continuation.resume() }
            }
        } onCancel: {
            process.terminate()
        }
        try Task.checkCancellation()
        return await reader.value
    }
}
