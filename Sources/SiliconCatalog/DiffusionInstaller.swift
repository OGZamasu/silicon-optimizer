import Foundation
import SiliconCore

/// Downloads image-model weights ahead of time.
///
/// Language models are single GGUF files this app fetches itself. Diffusion models are Hugging
/// Face repositories of a dozen-odd files that the runtime resolves through its own cache, so
/// fetching them by hand would mean either duplicating that cache or teaching the runtime to look
/// somewhere else. Both are worse than driving `hf` — the CLI that ships inside the same
/// environment as MFLUX, writing to the same cache MFLUX already reads.
///
/// Without this the first generation silently downloads 15 GB mid-run, behind a progress bar that
/// only says "Fetching weights…".
public struct DiffusionInstaller: Sendable {

    /// The parts of a repository the runtime actually loads.
    ///
    /// Not the whole repo: FLUX.2-klein-4B also carries a 7.8 GB single-file variant and a few
    /// megabytes of sample JPEGs that MFLUX never opens. Verified against a snapshot MFLUX
    /// populated itself — these four directories are exactly what it left behind.
    public static let componentPatterns = [
        "transformer/*", "text_encoder/*", "vae/*", "tokenizer/*",
    ]

    public struct Plan: Sendable {
        public var bytesToDownload: Bytes
        public var fileCount: Int
        public var isComplete: Bool
    }

    public enum InstallError: Error, LocalizedError {
        case toolMissing
        case accessDenied(repository: String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .toolMissing:
                "The Hugging Face CLI was not found next to MFLUX. Reinstall MFLUX with "
                + "`pip install --upgrade mflux`."
            case .accessDenied(let repository):
                "\(repository) is gated. Accept its licence on its Hugging Face page while signed "
                + "in, then add an access token in Settings."
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

    /// `hf`, which ships alongside `mflux-generate` in the same environment.
    public static func locate(besideMFlux mflux: URL) -> URL? {
        let candidate = mflux.deletingLastPathComponent().appendingPathComponent("hf")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    // MARK: - Cache inspection

    /// Hugging Face rewrites `org/name` as `models--org--name` under its hub cache.
    public static func cacheDirectory(for repository: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let slug = "models--" + repository.replacingOccurrences(of: "/", with: "--")
        return home.appendingPathComponent(".cache/huggingface/hub/\(slug)")
    }

    /// Whether the weights the runtime needs are already on disk.
    ///
    /// Checks for the three weight-bearing components rather than the directory merely existing —
    /// an interrupted download leaves the folder behind with only blobs in it.
    public static func isInstalled(_ repository: String) -> Bool {
        guard let snapshot = latestSnapshot(for: repository) else { return false }
        return ["transformer", "text_encoder", "vae"].allSatisfy { component in
            let directory = snapshot.appendingPathComponent(component)
            let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            return (contents ?? []).contains { $0.hasSuffix(".safetensors") }
        }
    }

    public static func latestSnapshot(for repository: String) -> URL? {
        let snapshots = cacheDirectory(for: repository).appendingPathComponent("snapshots")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return entries.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return left > right
        }.first
    }

    /// Bytes on disk, following the symlinks the hub cache uses to point snapshots at blobs.
    public static func installedSize(_ repository: String) -> Bytes {
        let blobs = cacheDirectory(for: repository).appendingPathComponent("blobs")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: blobs, includingPropertiesForKeys: [.fileSizeKey]
        )) ?? []
        let total = entries.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return Bytes(total)
    }

    // MARK: - Sizing

    /// Asks the CLI what a download would cost, without starting one.
    ///
    /// `--dry-run` lists every file with a size, or `-` when it is already cached, so the sum of
    /// the sizes is exactly what is left to fetch. That is also how "already installed" is
    /// distinguished from "partly installed" without guessing.
    public func plan(repository: String) async throws -> Plan {
        let output = try await run(
            arguments: downloadArguments(repository: repository)
                + ["--dry-run", "--format", "json"],
            collectingOutput: true
        )
        guard let start = output.firstIndex(of: "["),
              let data = String(output[start...]).data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            if output.lowercased().contains("access denied")
                || output.lowercased().contains("requires approval") {
                throw InstallError.accessDenied(repository: repository)
            }
            throw InstallError.failed("Could not read the file list for \(repository).")
        }

        let pending = rows.compactMap { $0["size"] as? String }.filter { $0 != "-" }
        let bytes = pending.reduce(Int64(0)) { $0 + Self.parseSize($1) }
        return Plan(
            bytesToDownload: Bytes(bytes),
            fileCount: pending.count,
            isComplete: pending.isEmpty
        )
    }

    /// Parses the CLI's human sizes — `7.8G`, `1.6K`, `446.0`.
    static func parseSize(_ text: String) -> Int64 {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last else { return 0 }
        let multiplier: Double
        switch last {
        case "K": multiplier = 1_000
        case "M": multiplier = 1_000_000
        case "G": multiplier = 1_000_000_000
        case "T": multiplier = 1_000_000_000_000
        default: multiplier = 1
        }
        let number = multiplier == 1 ? trimmed : String(trimmed.dropLast())
        return Int64((Double(number) ?? 0) * multiplier)
    }

    // MARK: - Download

    /// Fetches the repository, reporting progress by watching the cache grow.
    ///
    /// The CLI hides its progress bars when stdout is not a terminal, so there is nothing to
    /// parse. Sizing the job up front and polling the blob directory gives a real byte count
    /// instead — and it stays honest across the parallel, resumed and deduplicated transfers the
    /// hub client does internally, which a per-file parser would not.
    public func download(
        repository: String,
        onProgress: @Sendable @escaping (ModelDownloader.Progress) -> Void
    ) async throws {
        let sizing = try await plan(repository: repository)
        guard !sizing.isComplete else { return }

        let already = Self.installedSize(repository)
        let expected = already + sizing.bytesToDownload
        let started = Date()

        let watcher = Task {
            while !Task.isCancelled {
                let current = Self.installedSize(repository)
                let elapsed = Date().timeIntervalSince(started)
                let gained = Double((current - already).rawValue)
                onProgress(ModelDownloader.Progress(
                    bytesReceived: current,
                    bytesExpected: expected,
                    bytesPerSecond: elapsed > 0.5 ? gained / elapsed : 0,
                    currentFile: repository,
                    fileIndex: 0,
                    fileCount: sizing.fileCount
                ))
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        defer { watcher.cancel() }

        let output = try await run(
            arguments: downloadArguments(repository: repository), collectingOutput: true
        )
        let lowered = output.lowercased()
        if lowered.contains("access denied") || lowered.contains("requires approval") {
            throw InstallError.accessDenied(repository: repository)
        }
        guard Self.isInstalled(repository) else {
            throw InstallError.failed(
                output.split(separator: "\n").suffix(4).joined(separator: "\n")
            )
        }
    }

    private func downloadArguments(repository: String) -> [String] {
        var arguments = ["download", repository]
        // One `--include` per pattern: passing several values to a single flag makes the CLI
        // read the extras as positional filenames and drop the flag entirely, with only a
        // warning — which quietly fetches the whole repository instead of four directories.
        for pattern in Self.componentPatterns {
            arguments += ["--include", pattern]
        }
        if let token, !token.isEmpty {
            arguments += ["--token", token]
        }
        return arguments
    }

    @discardableResult
    private func run(arguments: [String], collectingOutput: Bool) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        if let token, !token.isEmpty { environment["HF_TOKEN"] = token }
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        try process.run()
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        continuation.resume(
                            returning: String(data: data, encoding: .utf8) ?? ""
                        )
                    } catch {
                        continuation.resume(throwing: InstallError.toolMissing)
                    }
                }
            }
        } onCancel: {
            process.terminate()
        }
    }
}
