import Foundation
import SiliconCore

/// The Mac's copies of the phone's fallback models: fetched from Hugging Face at their
/// pinned commits, verified against their SHA-256, and kept in a folder of their own until
/// a phone takes them over the tailnet.
///
/// The folder is `PhoneModels/` under the app's support directory, and it is nothing else:
/// not the Mac's model library, not a place the library scans, not an output folder the
/// media routes serve from. A file in it is served only by the phone-model route, only
/// under its catalogue id, and only once this store has verified it.
///
/// **Ready means verified.** A file's size is not enough here, because the digest is what
/// the phone is promised — it is the ETag, and the phone checks it again at the end of its
/// own transfer, having spent up to 3.35 GB of its storage to find out. So a download that
/// passed its checksum leaves a small marker beside the file saying which bytes were
/// verified (size, inode, modification time), and a file without a marker that still
/// matches is not ready until it has been hashed again.
///
/// **No credential goes out.** These are public files, and the downloader is built here
/// with no token at all — not the owner's Hugging Face token from the Keychain, not
/// anything. There is no parameter through which one could be passed.
public actor PhoneModelStore {

    /// `~/Library/Application Support/SiliconOptimizer/PhoneModels`.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconOptimizer/PhoneModels", isDirectory: true)
    }

    public enum State: Sendable, Equatable {
        /// Not on this Mac, and not on its way.
        case absent
        case downloading(bytesReceived: Int64, bytesPerSecond: Double)
        /// On this Mac and verified: servable.
        case ready
        case failed(Failure)
    }

    /// Why a model is not ready, in words a phone can show and a kind it can act on.
    public struct Failure: Sendable, Equatable {
        public enum Kind: String, Sendable, CaseIterable {
            /// The Mac does not have room. Retrying will not help until space is freed.
            case diskFull
            /// The bytes were not the pinned ones. They have been deleted; a retry
            /// starts from zero.
            case checksumMismatch
            /// The connection was cut. What arrived is kept, and a retry resumes it.
            case network
            /// Hugging Face refused or failed the request.
            case server
            /// A partial download with nothing fetching it — the app quit mid-transfer.
            case interrupted
            case other
        }

        public var kind: Kind
        public var reason: String
        /// What a retry would resume from.
        public var bytesOnDisk: Int64

        public init(kind: Kind, reason: String, bytesOnDisk: Int64) {
            self.kind = kind
            self.reason = reason
            self.bytesOnDisk = bytesOnDisk
        }
    }

    public enum PrepareOutcome: Sendable, Equatable {
        case alreadyReady
        case alreadyDownloading
        case started
    }

    public enum StoreError: Error, LocalizedError, Equatable {
        case unknownModel(String)
        /// Refused before a byte moved. The failure is recorded as the model's state too.
        case noSpace(Failure)

        public var errorDescription: String? {
            switch self {
            case .unknownModel(let id): "No phone model with id \(id)."
            case .noSpace(let failure): failure.reason
            }
        }
    }

    /// A file this store has verified, as the route that serves it needs it.
    public struct VerifiedFile: Sendable, Equatable {
        public var url: URL
        public var sizeBytes: Int64
        public var sha256: String
    }

    /// Asked before anything is fetched. Throws `ModelDownloader.DownloadError
    /// .insufficientDiskSpace` when the file would eat into the startup volume's reserve —
    /// the same rule, and the same reserve, as every other download this app makes.
    public typealias SpaceCheck = @Sendable (_ needed: Bytes, _ directory: URL) throws -> Void

    public nonisolated let root: URL
    private let entries: [String: PhoneModelEntry]
    /// Catalogue order, which is the order a phone lists them in.
    public nonisolated let catalog: [PhoneModelEntry]
    /// Where the files come from. Nil is huggingface.co; a test hands in a loopback server.
    private let source: URL?
    private let spaceCheck: SpaceCheck

    private var attempts: [String: Attempt] = [:]
    /// The last failure per model in this run. A partial left by a previous run reads as
    /// `interrupted` without one.
    private var failures: [String: Failure] = [:]
    /// Removals in flight. A model being removed reads as absent, and a prepare waits for
    /// the removal to finish rather than fetching into a folder that is being emptied.
    private var removals: [String: Task<Void, Never>] = [:]

    public init(
        root: URL = PhoneModelStore.defaultRoot,
        catalog: [PhoneModelEntry] = PhoneModelCatalog.all,
        source: URL? = nil,
        spaceCheck: @escaping SpaceCheck = { needed, directory in
            try ModelDownloader.checkDiskSpace(needed: needed, at: directory)
        }
    ) {
        self.root = root
        // An entry whose file name could climb out of the folder is not an entry at all.
        // The pins below never do; this is what makes that a property of the store rather
        // than of whoever edits the catalogue next.
        var byID: [String: PhoneModelEntry] = [:]
        var ordered: [PhoneModelEntry] = []
        for entry in catalog where entry.hasPlainFileName && byID[entry.id] == nil {
            byID[entry.id] = entry
            ordered.append(entry)
        }
        self.entries = byID
        self.catalog = ordered
        self.source = source
        self.spaceCheck = spaceCheck
    }

    /// The catalogue entry for an id, or nil. The only way into this store: an id is looked
    /// up, never parsed, and nothing from a request is ever joined to a path.
    public nonisolated func entry(id: String) -> PhoneModelEntry? {
        entries[id]
    }

    // MARK: - Reading

    public func state(of id: String) -> State? {
        guard let entry = entries[id] else { return nil }
        if removals[id] != nil { return .absent }
        if let attempt = attempts[id] {
            let reading = attempt.progress.reading
            return .downloading(bytesReceived: reading.received, bytesPerSecond: reading.rate)
        }
        if isVerified(entry) { return .ready }
        let partial = partialBytes(of: entry)
        if var failure = failures[id] {
            failure.bytesOnDisk = partial
            return .failed(failure)
        }
        if partial > 0 {
            return .failed(Failure(
                kind: .interrupted,
                reason: "The Mac had fetched \(Self.percent(partial, of: entry))% of "
                    + "\(entry.label) when it stopped — most likely the app quit. Prepare it "
                    + "again to resume.",
                bytesOnDisk: partial
            ))
        }
        return .absent
    }

    /// The verified file, or nil while the model is anything but ready.
    public func verifiedFile(id: String) -> VerifiedFile? {
        guard let entry = entries[id], removals[id] == nil, attempts[id] == nil,
              isVerified(entry)
        else { return nil }
        return VerifiedFile(
            url: fileURL(for: entry), sizeBytes: entry.sizeBytes, sha256: entry.sha256
        )
    }

    /// Returns once nothing is fetching or removing this model. For callers that started
    /// work and need its result — the tests, and anything that reports completion.
    public func waitUntilSettled(id: String) async {
        while true {
            if let removal = removals[id] {
                await finish(removal, of: id)
            } else if let attempt = attempts[id] {
                // The attempt clears its own row before its task completes, so this does
                // not come round to the same one twice.
                await attempt.task.value
            } else {
                return
            }
        }
    }

    /// Waits for a removal and takes it out of the table. Whoever gets there first clears
    /// the row: a finished task answers `value` at once, so a waiter that left clearing to
    /// `remove` could come round the loop to the same finished task for as long as `remove`
    /// had not yet been scheduled to resume.
    private func finish(_ removal: Task<Void, Never>, of id: String) async {
        await removal.value
        if removals[id] == removal { removals[id] = nil }
    }

    // MARK: - Fetching

    /// Starts fetching a model, unless it is already here or already on its way.
    ///
    /// Idempotent in both directions: a ready model is not fetched again, and a download in
    /// flight is not restarted or doubled. A failed one is retried — resuming from what is
    /// on disk when the failure left anything there.
    public func prepare(id: String) async throws -> PrepareOutcome {
        guard let entry = entries[id] else { throw StoreError.unknownModel(id) }
        while let removal = removals[id] { await finish(removal, of: id) }
        if attempts[id] != nil { return .alreadyDownloading }
        if isVerified(entry) { return .alreadyReady }

        // Asked now, so a Mac without room says so before telling a phone a download has
        // begun. The downloader asks again when it starts, which is the one that counts if
        // something else filled the disk in between.
        do {
            try spaceCheck(Bytes(entry.sizeBytes), root)
        } catch {
            let failure = Self.failure(for: error, entry: entry, partial: partialBytes(of: entry))
            failures[id] = failure
            throw StoreError.noSpace(failure)
        }

        failures[id] = nil
        let progress = ProgressBox(received: partialBytes(of: entry))
        let token = UUID()
        let task = Task { await self.run(entry, token: token, progress: progress) }
        attempts[id] = Attempt(token: token, task: task, progress: progress)
        return .started
    }

    private func run(_ entry: PhoneModelEntry, token: UUID, progress: ProgressBox) async {
        var failure: (any Error)?
        do {
            try await fetch(entry, progress: progress)
        } catch {
            failure = error
        }
        // Only the attempt that is still current may settle anything. A removal takes its
        // attempt out before cancelling it, so a cancelled fetch ends here with nothing to
        // say — it must not leave a failure behind for a model the owner just deleted.
        guard attempts[entry.id]?.token == token else { return }
        attempts[entry.id] = nil
        if let failure {
            failures[entry.id] = Self.failure(
                for: failure, entry: entry, partial: partialBytes(of: entry)
            )
        } else {
            failures[entry.id] = nil
        }
    }

    private func fetch(_ entry: PhoneModelEntry, progress: ProgressBox) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = fileURL(for: entry)
        let partial = partialURL(for: entry)

        // A file already in place that this store never verified — a crash between the
        // rename and the marker, or one copied in by hand. Its size proves nothing, so it
        // is hashed; a match is adopted without a byte of network, anything else goes.
        if FileManager.default.fileExists(atPath: destination.path) {
            let digest = try await Self.digest(of: destination)
            try Task.checkCancellation()
            if digest == entry.sha256, Self.isRegularFile(destination) {
                try writeMarker(for: entry)
                return
            }
            try? FileManager.default.removeItem(at: destination)
        }
        // A partial as long as the file, or longer, is not a prefix of anything a Range
        // request could finish.
        if partialBytes(of: entry) >= entry.sizeBytes {
            try? FileManager.default.removeItem(at: partial)
        }

        let resolution = ModelResolver.Resolution(
            repository: entry.repository,
            files: [.init(path: entry.file, size: Bytes(entry.sizeBytes), sha256: entry.sha256)],
            projector: nil,
            revision: entry.commit
        )
        // No token, on purpose and without a way to add one. See the type's comment.
        let downloader = ModelDownloader(token: nil, baseURL: source)
        _ = try await downloader.download(resolution, to: root) { progress.note($0) }
        try Task.checkCancellation()
        try writeMarker(for: entry)
    }

    // MARK: - Removing

    /// Deletes the Mac's copy and anything partial, stopping a download in flight first.
    /// Idempotent: removing a model that is not here succeeds and leaves it not here.
    public func remove(id: String) async throws {
        guard let entry = entries[id] else { throw StoreError.unknownModel(id) }
        if let removal = removals[id] {
            await finish(removal, of: id)
            return
        }
        // Out of the table before it is cancelled, so the attempt's own ending sees it is
        // no longer current and records nothing.
        let attempt = attempts.removeValue(forKey: id)
        failures[id] = nil
        let doomed = [fileURL(for: entry), partialURL(for: entry), markerURL(for: entry)]
        let removal = Task {
            attempt?.task.cancel()
            // Waited for, not just cancelled: a fetch that was hashing when the cancel
            // arrived would otherwise rename its file into place after the delete below.
            await attempt?.task.value
            for url in doomed { try? FileManager.default.removeItem(at: url) }
        }
        removals[id] = removal
        await finish(removal, of: id)
    }

    // MARK: - Where things are

    private func fileURL(for entry: PhoneModelEntry) -> URL {
        root.appendingPathComponent(entry.file, isDirectory: false)
    }

    /// The downloader's own name for the file it is resuming.
    private func partialURL(for entry: PhoneModelEntry) -> URL {
        fileURL(for: entry).appendingPathExtension("part")
    }

    private func markerURL(for entry: PhoneModelEntry) -> URL {
        root.appendingPathComponent(".\(entry.file).verified", isDirectory: false)
    }

    private func partialBytes(of entry: PhoneModelEntry) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: partialURL(for: entry).path
        )
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Verification

    /// What was true of the file at the moment its digest matched.
    private struct Verification: Codable, Equatable {
        var sha256: String
        var size: Int64
        var inode: UInt64
        var modified: Double
    }

    private struct Fingerprint: Equatable {
        var size: Int64
        var inode: UInt64
        var modified: Double
    }

    /// The file's identity now. Nil for anything that is not a plain regular file — a
    /// link planted where the file should be is not the file.
    private static func fingerprint(of url: URL) -> Fingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return Fingerprint(size: size, inode: inode, modified: modified)
    }

    private static func isRegularFile(_ url: URL) -> Bool { fingerprint(of: url) != nil }

    /// Whether the file on disk is the one whose digest matched, unchanged since. A stat
    /// and a hundred-byte read — cheap enough to ask on every request, which is what keeps
    /// "ready" from outliving the file it describes.
    private func isVerified(_ entry: PhoneModelEntry) -> Bool {
        guard let data = try? Data(contentsOf: markerURL(for: entry)),
              let marker = try? JSONDecoder().decode(Verification.self, from: data),
              marker.sha256 == entry.sha256, marker.size == entry.sizeBytes,
              let now = Self.fingerprint(of: fileURL(for: entry))
        else { return false }
        return now == Fingerprint(
            size: marker.size, inode: marker.inode, modified: marker.modified
        )
    }

    private func writeMarker(for entry: PhoneModelEntry) throws {
        guard let now = Self.fingerprint(of: fileURL(for: entry)), now.size == entry.sizeBytes
        else { throw CocoaError(.fileReadCorruptFile) }
        let marker = Verification(
            sha256: entry.sha256, size: now.size, inode: now.inode, modified: now.modified
        )
        try JSONEncoder().encode(marker).write(to: markerURL(for: entry), options: .atomic)
    }

    /// Hashes off the actor: a 3.35 GB file takes seconds, and every state query waits on
    /// this actor.
    private static func digest(of url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            try ModelDownloader().sha256(of: url)
        }.value
    }

    // MARK: - Saying why

    /// A network failure in words, rather than the `NSURLErrorDomain error -1005` a
    /// URLError carries when nothing filled in its description.
    static func describe(_ error: URLError) -> String {
        switch error.code {
        case .networkConnectionLost: "the connection dropped"
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            "the Mac is offline"
        case .timedOut: "the connection timed out"
        case .cannotFindHost, .dnsLookupFailed: "huggingface.co could not be found"
        case .cannotConnectToHost: "the connection was refused"
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            "the secure connection failed"
        default: "network error \(error.code.rawValue)"
        }
    }

    static func percent(_ bytes: Int64, of entry: PhoneModelEntry) -> Int {
        guard entry.sizeBytes > 0 else { return 0 }
        return Int((Double(bytes) / Double(entry.sizeBytes) * 100).rounded(.down))
    }

    /// One sentence a phone can show, and the kind it can act on. Nothing in any of them
    /// is a path on this Mac or a credential.
    static func failure(
        for error: any Error, entry: PhoneModelEntry, partial: Int64
    ) -> Failure {
        let label = entry.label
        let resume = partial > 0
            ? " The Mac kept the \(Self.percent(partial, of: entry))% that arrived; prepare "
                + "it again to resume."
            : " Prepare it again to retry."
        switch error {
        case let error as ModelDownloader.DownloadError:
            switch error {
            case .insufficientDiskSpace(let needed, let available):
                let reserve = ModelDownloader.diskReserve
                let shortfall = Bytes(
                    max(0, needed.rawValue + reserve.rawValue - available.rawValue)
                )
                return Failure(
                    kind: .diskFull,
                    reason: "There is not enough space on the Mac for \(label): it needs "
                        + "\(needed.formatted), and \(available.formatted) is free, of which "
                        + "\(reserve.formatted) is kept in reserve so a download cannot fill the "
                        + "startup volume. Free about \(shortfall.formatted) on the Mac, then "
                        + "try again.",
                    bytesOnDisk: partial
                )
            case .checksumMismatch:
                return Failure(
                    kind: .checksumMismatch,
                    reason: "\(label) arrived but did not match its published checksum, so "
                        + "the Mac deleted it. Prepare it again to download it afresh.",
                    bytesOnDisk: partial
                )
            case .incompleteTransfer:
                return Failure(
                    kind: .network,
                    reason: "The download of \(label) was cut off." + resume,
                    bytesOnDisk: partial
                )
            case .cancelled:
                return Failure(
                    kind: .interrupted, reason: "The download of \(label) was stopped." + resume,
                    bytesOnDisk: partial
                )
            }
        case let error as HuggingFaceClient.ClientError:
            switch error {
            case .rateLimited:
                return Failure(
                    kind: .server,
                    reason: "Hugging Face is rate limiting this Mac. Try again in a few "
                        + "minutes.",
                    bytesOnDisk: partial
                )
            case .badResponse(let code):
                return Failure(
                    kind: .server,
                    reason: "Hugging Face answered HTTP \(code) for \(label)'s pinned file."
                        + resume,
                    bytesOnDisk: partial
                )
            case .fileNotFound:
                return Failure(
                    kind: .server,
                    reason: "Hugging Face no longer has \(label)'s pinned file.",
                    bytesOnDisk: partial
                )
            }
        case let error as URLError:
            return Failure(
                kind: .network,
                reason: "The Mac could not keep a connection to Hugging Face while fetching "
                    + "\(label): \(Self.describe(error))." + resume,
                bytesOnDisk: partial
            )
        default:
            let underlying = error as NSError
            if (underlying.domain == NSCocoaErrorDomain
                && underlying.code == NSFileWriteOutOfSpaceError)
                || (underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOSPC)) {
                return Failure(
                    kind: .diskFull,
                    reason: "The Mac ran out of disk space while fetching \(label). Free some "
                        + "space on the Mac, then prepare it again.",
                    bytesOnDisk: partial
                )
            }
            return Failure(
                kind: .other,
                reason: "The Mac could not fetch \(label): \(error.localizedDescription)",
                bytesOnDisk: partial
            )
        }
    }
}

// MARK: - A download in flight

extension PhoneModelStore {

    fileprivate struct Attempt {
        let token: UUID
        let task: Task<Void, Never>
        let progress: ProgressBox
    }

    /// The downloader reports from its own actor, four times a second. Written here under
    /// a lock rather than hopped onto the store's actor, so a reading can never arrive
    /// after the state it describes has already been settled.
    fileprivate final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var received: Int64
        private var rate: Double = 0

        init(received: Int64) { self.received = received }

        func note(_ progress: ModelDownloader.Progress) {
            lock.lock()
            received = progress.bytesReceived.rawValue
            rate = progress.bytesPerSecond
            lock.unlock()
        }

        var reading: (received: Int64, rate: Double) {
            lock.lock()
            defer { lock.unlock() }
            return (received, rate)
        }
    }
}
