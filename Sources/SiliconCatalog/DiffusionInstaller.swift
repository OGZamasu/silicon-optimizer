import Foundation
import SiliconCore

/// Downloads image-model weights ahead of time.
///
/// Language models are single GGUF files this app fetches itself. Diffusion models are Hugging
/// Face repositories of a dozen-odd files that the runtime resolves through its own cache, so
/// fetching them by hand would mean either duplicating that cache or teaching the runtime to look
/// somewhere else. Both are worse than driving `hf` — the CLI that ships inside the same
/// environment as MFLUX, writing to the same cache MFLUX already reads. "The same cache" is a
/// choice to keep making: MFLUX is run with `HF_HOME` set to the engine cache in the model
/// library whenever there is one, so every download, check and removal here names the hub it
/// works in — there is no default. When it quietly meant `~/.cache` the weights went to the
/// startup disk, the first render fetched them all again into the library, and Remove deleted
/// the copy nothing read; and `~/.cache/huggingface` can itself be a link into a real library.
///
/// Without this the first generation silently downloads 15 GB mid-run, behind a progress bar that
/// only says "Fetching weights…".
public struct DiffusionInstaller: Sendable {

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
    private let home: URL?
    private let hub: URL

    /// - Parameters:
    ///   - home: The `HF_HOME` MFLUX is run with — the model library's engine cache — or nil
    ///     when MFLUX inherits the app's own.
    ///   - hub: The hub cache MFLUX reads (see `HuggingFaceHub`). The download goes there and
    ///     the checks look there.
    public init(executable: URL, token: String? = nil, home: URL?, hub: URL) {
        self.executable = executable
        self.token = token
        self.home = home
        self.hub = hub
    }

    /// `hf`, which ships alongside `mflux-generate` in the same environment.
    public static func locate(besideMFlux mflux: URL) -> URL? {
        let candidate = mflux.deletingLastPathComponent().appendingPathComponent("hf")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    // MARK: - Cache inspection

    /// Hugging Face rewrites `org/name` as `models--org--name` under its hub cache.
    public static func cacheDirectory(for repository: String, hub: URL) -> URL {
        let slug = "models--" + repository.replacingOccurrences(of: "/", with: "--")
        return hub.appendingPathComponent(slug)
    }

    /// Whether the weights the runtime needs are already on disk.
    ///
    /// Checks every weight-bearing component rather than the directory merely existing — an
    /// interrupted download leaves the folder behind with only blobs in it. The component list
    /// comes from the catalog entry because it is not the same across families: FLUX.1 keeps its
    /// T5-XXL in `text_encoder_2`, and a check that did not look for it would call a repository
    /// missing 9.5 GB of weights complete.
    ///
    /// An adapter entry is installed when its base's weights are and its default adapter file
    /// is in place too — either alone runs nothing.
    public static func isInstalled(_ entry: DiffusionEntry, hub: URL) -> Bool {
        guard weightsInPlace(entry, hub: hub) else { return false }
        guard let adapter = entry.adapter else { return true }
        return isAdapterInPlace(adapter.defaultVariant, of: adapter, hub: hub)
    }

    /// Whether the Hub weights `entry` runs on — its own, or its base's — are all there.
    ///
    /// For a pinned entry, all there means every shard: each one its component's index names,
    /// present and as long as its own header says it is. Those entries are run from their
    /// snapshot's path, which bypasses the completeness check and repair mflux applies to a
    /// repository it resolves itself, so an interrupted download that left some shards would
    /// otherwise read as installed and fail minutes into loading. The older entries keep the
    /// lighter check: mflux resolves them itself, and finishes what is missing.
    public static func weightsInPlace(_ entry: DiffusionEntry, hub: URL) -> Bool {
        guard let snapshot = weightsSnapshot(for: entry, hub: hub) else { return false }
        return entry.componentDirectories.allSatisfy { component in
            let directory = snapshot.appendingPathComponent(component)
            if entry.revision != nil { return shardsComplete(in: directory) }
            let contents = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
            return (contents ?? []).contains { $0.hasSuffix(".safetensors") }
        }
    }

    /// Every shard a component's `*.safetensors.index.json` names — or, with no index, every
    /// `*.safetensors` in it, of which there must be one — present and complete.
    static func shardsComplete(in directory: URL) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return false }
        let shards: [String]
        if let index = names.first(where: { $0.hasSuffix(".safetensors.index.json") }) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(index)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let map = json["weight_map"] as? [String: String], !map.isEmpty
            else { return false }
            shards = Array(Set(map.values))
        } else {
            shards = names.filter { $0.hasSuffix(".safetensors") }
        }
        return !shards.isEmpty && shards.allSatisfy {
            // A name that is not a plain file name is no shard of this directory.
            !$0.contains("/") && isCompleteSafetensors(directory.appendingPathComponent($0))
        }
    }

    /// Whether a safetensors file is as long as its header says: the 8-byte header length,
    /// the header, and the data up to the furthest tensor's end. A download cut short, or a
    /// file truncated since, is shorter. Remembered per path, size and modification date, so
    /// a view asking again reads nothing.
    static func isCompleteSafetensors(_ url: URL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value, size > 8
        else { return false }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(size)|\(modified)"
        if let known = completeness.value(for: key) { return known }

        var complete = false
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            if let prefix = try? handle.read(upToCount: 8), prefix.count == 8 {
                let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
                if length > 0, length < 100_000_000, Int64(length) + 8 <= size,
                   let header = try? handle.read(upToCount: Int(length)), header.count == Int(length),
                   let json = try? JSONSerialization.jsonObject(with: header) as? [String: Any] {
                    let end = json.compactMap { key, value -> Int64? in
                        guard key != "__metadata__",
                              let offsets = (value as? [String: Any])?["data_offsets"] as? [NSNumber],
                              offsets.count == 2
                        else { return nil }
                        return offsets[1].int64Value
                    }.max() ?? 0
                    complete = 8 + Int64(length) + end == size
                }
            }
        }
        completeness.set(complete, for: key)
        return complete
    }

    private static let completeness = CompletenessCache()

    private final class CompletenessCache: @unchecked Sendable {
        private let lock = NSLock()
        private var known: [String: Bool] = [:]

        func value(for key: String) -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return known[key]
        }

        func set(_ value: Bool, for key: String) {
            lock.lock()
            defer { lock.unlock() }
            known[key] = value
        }
    }

    /// The snapshot `entry`'s weights are read from: the pinned revision's when it has one —
    /// never a newer snapshot that happens to be beside it — and otherwise the newest.
    public static func weightsSnapshot(for entry: DiffusionEntry, hub: URL) -> URL? {
        guard let revision = entry.revision else {
            return latestSnapshot(for: entry.weightsRepository, hub: hub)
        }
        let pinned = cacheDirectory(for: entry.weightsRepository, hub: hub)
            .appendingPathComponent("snapshots/\(revision)", isDirectory: true)
        return FileManager.default.fileExists(atPath: pinned.path) ? pinned : nil
    }

    /// Where an adapter file lives once fetched: the hub cache's own layout, at the adapter's
    /// pinned revision.
    public static func adapterFile(
        _ variant: DiffusionAdapter.Variant, of adapter: DiffusionAdapter, hub: URL
    ) -> URL {
        cacheDirectory(for: adapter.repository, hub: hub)
            .appendingPathComponent("snapshots/\(adapter.revision)", isDirectory: true)
            .appendingPathComponent(variant.file)
    }

    /// Whether the adapter file is there. Only a file whose digest matched is ever moved into
    /// place, and the runner checks the digest again before it merges anything, so presence is
    /// what this asks.
    public static func isAdapterInPlace(
        _ variant: DiffusionAdapter.Variant, of adapter: DiffusionAdapter, hub: URL
    ) -> Bool {
        let path = adapterFile(variant, of: adapter, hub: hub).resolvingSymlinksInPath().path
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return attributes?[.type] as? FileAttributeType == .typeRegular
            && ((attributes?[.size] as? NSNumber)?.int64Value ?? 0) > 0
    }

    /// What removing `entry` deletes: its own repository's cache and nothing else. For an
    /// adapter that is the adapter's files — never its base's weights, which belong to the base
    /// entry and stay installed, and usable, for as long as that entry is.
    public static func removalTargets(for entry: DiffusionEntry, hub: URL) -> [URL] {
        [cacheDirectory(for: entry.repository, hub: hub)]
    }

    public static func latestSnapshot(for repository: String, hub: URL) -> URL? {
        let snapshots = cacheDirectory(for: repository, hub: hub)
            .appendingPathComponent("snapshots")
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
    public static func installedSize(_ repository: String, hub: URL) -> Bytes {
        let blobs = cacheDirectory(for: repository, hub: hub)
            .appendingPathComponent("blobs")
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
    public func plan(_ entry: DiffusionEntry) async throws -> Plan {
        let repository = entry.weightsRepository
        let output = try await run(
            arguments: downloadArguments(entry) + ["--dry-run", "--format", "json"],
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

    /// Fetches the repository, reporting progress by watching the cache grow. For an adapter
    /// entry that is its base's weights; the adapter file is fetched, and checked against its
    /// reviewed digest, by `DiffusionAdapterFiles`.
    ///
    /// The CLI hides its progress bars when stdout is not a terminal, so there is nothing to
    /// parse. Sizing the job up front and polling the blob directory gives a real byte count
    /// instead — and it stays honest across the parallel, resumed and deduplicated transfers the
    /// hub client does internally, which a per-file parser would not.
    public func download(
        _ entry: DiffusionEntry,
        onProgress: @Sendable @escaping (ModelDownloader.Progress) -> Void
    ) async throws {
        let repository = entry.weightsRepository
        let sizing = try await plan(entry)
        guard !sizing.isComplete else { return }

        let already = Self.installedSize(repository, hub: hub)
        let expected = already + sizing.bytesToDownload
        // Same moving window as the GGUF downloader. This path polls the cache directory rather
        // than counting bytes off a stream, which is chunkier still — a file appears all at once
        // when the hub client renames it into place — so smoothing matters more here, not less.
        let meter = RateMeter()

        let watcher = Task {
            while !Task.isCancelled {
                let current = Self.installedSize(repository, hub: hub)
                let now = Double(DispatchTime.now().uptimeNanoseconds) / 1e9
                onProgress(ModelDownloader.Progress(
                    bytesReceived: current,
                    bytesExpected: expected,
                    bytesPerSecond: meter.record(totalBytes: current.rawValue, at: now),
                    currentFile: repository,
                    fileIndex: 0,
                    fileCount: sizing.fileCount
                ))
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        defer { watcher.cancel() }

        let output = try await run(arguments: downloadArguments(entry), collectingOutput: true)
        let lowered = output.lowercased()
        if lowered.contains("access denied") || lowered.contains("requires approval") {
            throw InstallError.accessDenied(repository: repository)
        }
        guard Self.weightsInPlace(entry, hub: hub) else {
            throw InstallError.failed(
                output.split(separator: "\n").suffix(4).joined(separator: "\n")
            )
        }
    }

    func downloadArguments(_ entry: DiffusionEntry) -> [String] {
        var arguments = ["download", entry.weightsRepository]
        // The commit, not a branch: the snapshot lands under `snapshots/<revision>`, which is
        // exactly where `weightsSnapshot` and the runtime look.
        if let revision = entry.revision {
            arguments += ["--revision", revision]
        }
        // One `--include` per pattern: passing several values to a single flag makes the CLI
        // read the extras as positional filenames and drop the flag entirely, with only a
        // warning — which quietly fetches the whole repository instead of the parts wanted.
        for pattern in entry.downloadPatterns {
            arguments += ["--include", pattern]
        }
        return arguments
    }

    func processEnvironment(base: [String: String] = ProcessInfo.processInfo.environment)
        -> [String: String] {
        var environment = base
        environment["PYTHONUNBUFFERED"] = "1"
        if let token, !token.isEmpty { environment["HF_TOKEN"] = token }
        if let home { environment["HF_HOME"] = home.path }
        // Always: a hub cache inherited from the app's own environment must not send the
        // download somewhere the checks above do not look.
        environment["HF_HUB_CACHE"] = hub.path
        return environment
    }

    func redactingCredential(in output: String) -> String {
        guard let token, !token.isEmpty else { return output }
        return output.replacingOccurrences(of: token, with: "[redacted]")
    }

    @discardableResult
    private func run(arguments: [String], collectingOutput: Bool) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = processEnvironment()

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
                        continuation.resume(returning: redactingCredential(
                            in: String(data: data, encoding: .utf8) ?? ""
                        ))
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
