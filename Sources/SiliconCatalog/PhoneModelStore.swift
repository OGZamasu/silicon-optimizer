import CryptoKit
import Darwin
import Foundation
import SiliconCore

/// Where the phone's models live on this Mac, worked out at the moment it is asked.
public enum PhoneModelPlace: Sendable, Equatable {
    /// The folder to use.
    case folder(URL)
    /// The model library is on a drive that is not connected. There is no second choice:
    /// the Mac does not put gigabytes on its startup disk because a drive was unplugged.
    case driveMissing(drive: String)
}

/// The Mac's copies of the phone's fallback models: fetched from Hugging Face at their
/// pinned commits, verified against their SHA-256, and kept until a phone takes them over
/// the tailnet.
///
/// **Where.** In `Phone Models/` inside the model library folder the owner chose — on this
/// owner's Mac, the external drive — and only when no library folder is set, in the app's
/// support directory. Decided on every call from the setting as it is then, never cached,
/// so a library that moves takes its phone models with it (see `relocate`). A library on a
/// drive that is not connected is reported as exactly that, never swapped for the startup
/// disk. The Mac's own model index never lists these files: `ModelLibrary.importExternal`
/// refuses anything in a folder with this name.
///
/// **Ready means verified.** The digest is what a phone is promised — it is the ETag, and
/// the phone checks it again after spending up to 3.35 GB of its storage — so `seal` is the
/// one place a file becomes servable, and it hashes the bytes itself before it writes the
/// small marker that says so. The marker records what the file was at that moment: device,
/// inode, size, and both the modification and the change time. The change time cannot be
/// put back by hand, so a file edited in place reads as changed even with its modification
/// time restored, and is hashed again before it is served.
///
/// **No credential goes out.** The downloader is built with its public-file initialiser,
/// which has no token parameter at all, keeps no cookies or credentials, follows redirects
/// only to Hugging Face over HTTPS, and does not wait for a network that is not there.
public actor PhoneModelStore {

    /// The folder's name, inside the model library.
    public static let folderName = "Phone Models"

    /// Used only when no model library folder is set.
    public static var fallbackRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconOptimizer/\(folderName)", isDirectory: true)
    }

    /// Where the store remembers which folder it last used — the only way it can find its
    /// files again after the library moves. A few hundred bytes; the models never live here.
    public static var defaultStateFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiliconOptimizer/phone-models.json")
    }

    // MARK: - Where

    /// Where phone models go for a library setting: `<library>/Phone Models`, the fallback
    /// when no library is set, or a missing drive — never the fallback *because* the drive
    /// is missing.
    public static func place(
        forLibrary library: URL?, fallback: URL = fallbackRoot,
        missingDrive: (URL) -> String? = PhoneModelStore.missingDrive(for:)
    ) -> PhoneModelPlace {
        guard let library else { return .folder(fallback.standardizedFileURL) }
        let folder = library.standardizedFileURL
            .appendingPathComponent(folderName, isDirectory: true)
        if let drive = missingDrive(folder) { return .driveMissing(drive: drive) }
        return .folder(folder)
    }

    /// The drive a folder is on, when that drive is not connected; nil when it is, and for
    /// anything on the startup disk, which always is.
    ///
    /// "Connected" means `/Volumes/<drive>` is the top of a volume of its own. A folder of
    /// that name sitting on the startup disk — which is what writing to an unplugged drive's
    /// path can leave behind — is not the drive, and neither is a path that merely starts
    /// the same way. Asking the folder's nearest existing ancestor for free space would have
    /// measured the startup disk in both cases.
    public static func missingDrive(for folder: URL) -> String? {
        let resolved = folder.standardizedFileURL.resolvingSymlinksInPath()
        let parts = resolved.pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        let drive = parts[2]
        let mount = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            .appendingPathComponent(drive, isDirectory: true)
        guard let volume = (try? mount.resourceValues(forKeys: [.volumeURLKey]))?.volume,
              volume.standardizedFileURL.path == mount.standardizedFileURL.path
        else { return drive }
        return nil
    }

    /// Whether a file sits in a folder this store keeps phone models in. The Mac's model
    /// library asks, so a folder scan never registers one of these as a Mac model.
    public static func isInPhoneModelsFolder(_ file: URL) -> Bool {
        file.standardizedFileURL.deletingLastPathComponent().lastPathComponent
            .compare(folderName, options: .caseInsensitive) == .orderedSame
    }

    /// What `prepare`, `file` and `remove` say while the library's drive is away.
    public static func driveMissingSentence(_ drive: String) -> String {
        "The drive “\(drive)” that holds this Mac's model library is not connected, and the "
            + "phone models are kept beside the library. Connect it and try again — the Mac "
            + "will not put them on its startup disk instead."
    }

    // MARK: - States

    public enum State: Sendable, Equatable {
        /// Not on this Mac, and not on its way.
        case absent
        /// Arriving, being checked, or being moved with the library. `bytesReceived` is how
        /// much of the file that stage has got through.
        case downloading(bytesReceived: Int64, bytesPerSecond: Double, stage: Stage)
        /// On this Mac and verified: servable.
        case ready
        case failed(Failure)
    }

    /// What an in-progress model is waiting on.
    public enum Stage: String, Sendable, CaseIterable {
        /// Bytes arriving from Hugging Face.
        case fetching
        /// The Mac hashing what it has.
        case checking
        /// The file following the model library to its new folder.
        case moving
    }

    /// Why a model is not ready, in words a phone can show and a kind it can act on.
    public struct Failure: Sendable, Equatable {
        public enum Kind: String, Sendable, CaseIterable {
            /// The Mac does not have room. Retrying will not help until space is freed.
            case diskFull
            /// The bytes were not the pinned ones. They have been deleted; a retry
            /// starts from zero.
            case checksumMismatch
            /// The connection was cut, or never made. What arrived is kept, and a retry
            /// resumes it.
            case network
            /// Hugging Face refused or failed the request, or sent it somewhere else.
            case server
            /// Stopped before it finished, or never checked: the app quit, the owner
            /// pressed Stop, or the file changed. A retry resumes, or checks.
            case interrupted
            /// The drive the model library is on is not connected.
            case driveMissing
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
        /// The sentence to show, which names the drive.
        case driveMissing(String)
        /// Not verified and in place.
        case notReady(String)

        public var errorDescription: String? {
            switch self {
            case .unknownModel(let id): "No phone model with id \(id)."
            case .noSpace(let failure): failure.reason
            case .driveMissing(let sentence): sentence
            case .notReady(let id): "Phone model \(id) is not ready on this Mac."
            }
        }
    }

    /// A file this store has verified, as the route that serves it needs it.
    public struct VerifiedFile: Sendable, Equatable {
        public var url: URL
        public var sizeBytes: Int64
        public var sha256: String
    }

    /// Something the owner should know about files this store could not put where the
    /// library is now. Shown on the Mac only: it names folders, and a phone has no use for
    /// this Mac's paths.
    public struct Notice: Sendable, Equatable {
        public var folder: URL
        public var reason: String

        public init(folder: URL, reason: String) {
            self.folder = folder
            self.reason = reason
        }
    }

    /// Asked before anything is fetched or moved to another drive. Throws
    /// `ModelDownloader.DownloadError.insufficientDiskSpace` when `needed` would eat into
    /// the reserve on the drive `folder` is on.
    public typealias SpaceCheck = @Sendable (_ needed: Bytes, _ folder: URL) throws -> Void

    /// Where a test pauses a fetch. Nil in the app.
    public struct Hooks: Sendable {
        /// Called with the model's id each time its file is about to be hashed — after a
        /// download, for a verify, for a file found in place — before any of it is read.
        public var beforeCheck: (@Sendable (String) async -> Void)?

        public init(beforeCheck: (@Sendable (String) async -> Void)? = nil) {
            self.beforeCheck = beforeCheck
        }
    }

    private let entries: [String: PhoneModelEntry]
    /// Catalogue order, which is the order a phone lists them in.
    public nonisolated let catalog: [PhoneModelEntry]
    private let fallback: URL
    private let stateFile: @Sendable () -> URL
    /// Where the files come from. Nil is huggingface.co; a test hands in a loopback server.
    private let source: @Sendable () -> URL?
    private let spaceCheck: SpaceCheck
    private let missingDrive: @Sendable (URL) -> String?
    private let hooks: Hooks

    private var attempts: [String: Attempt] = [:]
    /// The last failure per model in this run. A partial left by a previous run reads as
    /// `interrupted` without one.
    private var failures: [String: Failure] = [:]
    /// Removals in flight. A model being removed reads as absent, and a prepare waits for
    /// the removal to finish rather than fetching into a folder that is being emptied.
    private var removals: [String: Task<Void, Never>] = [:]
    private var relocation: Relocation?
    /// Why a former folder still holds files, by its path, from the last relocation.
    private var leftBehind: [String: String] = [:]
    private var memory: Memory?
    private var memoryURL: URL?

    public init(
        catalog: [PhoneModelEntry] = PhoneModelCatalog.all,
        fallback: URL = PhoneModelStore.fallbackRoot,
        stateFile: @escaping @Sendable () -> URL = { PhoneModelStore.defaultStateFile },
        source: @escaping @Sendable () -> URL? = { nil },
        spaceCheck: @escaping SpaceCheck = PhoneModelStore.checkRoom(needed:at:),
        missingDrive: @escaping @Sendable (URL) -> String? = PhoneModelStore.missingDrive(for:),
        hooks: Hooks = Hooks()
    ) {
        // An entry whose file name could climb out of the folder is not an entry at all.
        // The pins never do; this is what makes that a property of the store rather than
        // of whoever edits the catalogue next.
        var byID: [String: PhoneModelEntry] = [:]
        var ordered: [PhoneModelEntry] = []
        for entry in catalog where entry.hasPlainFileName && byID[entry.id] == nil {
            byID[entry.id] = entry
            ordered.append(entry)
        }
        self.entries = byID
        self.catalog = ordered
        self.fallback = fallback.standardizedFileURL
        self.stateFile = stateFile
        self.source = source
        self.spaceCheck = spaceCheck
        self.missingDrive = missingDrive
        self.hooks = hooks
    }

    /// The catalogue entry for an id, or nil. The only way into this store: an id is looked
    /// up, never parsed, and nothing from a request is ever joined to a path.
    public nonisolated func entry(id: String) -> PhoneModelEntry? {
        entries[id]
    }

    /// Where a library setting puts the phone models, by this store's rules.
    public nonisolated func place(forLibrary library: URL?) -> PhoneModelPlace {
        Self.place(forLibrary: library, fallback: fallback, missingDrive: missingDrive)
    }

    // MARK: - Reading

    public func state(of id: String, library: URL?) -> State? {
        guard let entry = entries[id] else { return nil }
        let root: URL
        switch settle(library) {
        case .driveMissing(let drive):
            return .failed(Failure(
                kind: .driveMissing, reason: Self.driveMissingSentence(drive), bytesOnDisk: 0
            ))
        case .folder(let folder):
            root = folder
        }
        if removals[id] != nil { return .absent }
        if let relocation, relocation.involved.contains(id) {
            let reading = relocation.progress[id]?.reading
            return .downloading(
                bytesReceived: reading?.received ?? 0, bytesPerSecond: 0,
                stage: reading?.stage ?? .moving
            )
        }
        if let attempt = attempts[id] {
            let reading = attempt.progress.reading
            return .downloading(
                bytesReceived: reading.received, bytesPerSecond: reading.rate,
                stage: reading.stage
            )
        }
        if isVerified(entry, in: root) { return .ready }
        let partial = partialBytes(of: entry, in: root)
        if var failure = failures[id] {
            failure.bytesOnDisk = partial
            return .failed(failure)
        }
        // The whole file is here and nobody has checked it since it last changed — a
        // crash between arriving and checking, a file changed after it was checked, or a
        // download that finished just as the app quit.
        if FileManager.default.fileExists(atPath: fileURL(for: entry, in: root).path)
            || partial == entry.sizeBytes {
            return .failed(Failure(
                kind: .interrupted,
                reason: "The Mac has all of \(entry.label) but has not checked it since it "
                    + "last changed. Prepare it again to check it — nothing needs downloading.",
                bytesOnDisk: entry.sizeBytes
            ))
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

    /// The verified file. Throws `driveMissing` while the library's drive is away and
    /// `notReady` while the model is anything but ready.
    public func verifiedFile(id: String, library: URL?) throws -> VerifiedFile {
        guard let entry = entries[id] else { throw StoreError.unknownModel(id) }
        let root = try settledRoot(library)
        guard removals[id] == nil, attempts[id] == nil,
              relocation?.involved.contains(id) != true,
              isVerified(entry, in: root)
        else { throw StoreError.notReady(id) }
        return VerifiedFile(
            url: fileURL(for: entry, in: root), sizeBytes: entry.sizeBytes, sha256: entry.sha256
        )
    }

    /// What the owner should be told about folders the library has left behind.
    public func notices(library: URL?) -> [Notice] {
        guard case .folder(let root) = settle(library) else { return [] }
        return rememberedFormerFolders().compactMap { folder in
            if let drive = missingDrive(folder) {
                return Notice(
                    folder: folder,
                    reason: "Phone models are still in this folder, on the drive “\(drive)”, "
                        + "which is not connected. They will be moved to \(root.path) when "
                        + "it is."
                )
            }
            if relocation != nil {
                return Notice(
                    folder: folder, reason: "Moving phone models from here to \(root.path)."
                )
            }
            if let reason = leftBehind[folder.path] {
                return Notice(folder: folder, reason: reason)
            }
            return nil
        }
    }

    /// Returns once nothing is fetching, removing or moving this model. For callers that
    /// started work and need its result — the tests, and anything that reports completion.
    public func waitUntilSettled(id: String) async {
        while true {
            if let relocation {
                await relocation.task.value
            } else if let removal = removals[id] {
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
    ///
    /// `verify` hashes a ready model's file again before it is served. A phone whose
    /// download did not hash to the pin asks for this once, then fetches from zero: if the
    /// Mac's copy was the problem it is deleted and fetched afresh, and if it was not, the
    /// phone's own transfer was.
    public func prepare(
        id: String, library: URL?, verify: Bool = false
    ) async throws -> PrepareOutcome {
        guard let entry = entries[id] else { throw StoreError.unknownModel(id) }
        var root = try settledRoot(library)
        while let removal = removals[id] {
            await finish(removal, of: id)
            root = try settledRoot(library)
        }
        if relocation?.involved.contains(id) == true {
            relocation?.wanted.insert(id)
            return .alreadyDownloading
        }
        if attempts[id] != nil { return .alreadyDownloading }
        if isVerified(entry, in: root) {
            guard verify else { return .alreadyReady }
            // Checked again from the bytes, as though nobody ever had.
            try? FileManager.default.removeItem(at: markerURL(for: entry, in: root))
        }
        return try begin(entry, in: root)
    }

    private func begin(_ entry: PhoneModelEntry, in root: URL) throws -> PrepareOutcome {
        // Asked now, so a Mac without room says so before telling a phone a download has
        // begun — and only when something needs downloading: checking a file already here
        // costs no space. The downloader asks again when it starts, which is the one that
        // counts if something else filled the drive in between.
        let complete = FileManager.default.fileExists(atPath: fileURL(for: entry, in: root).path)
            || partialBytes(of: entry, in: root) == entry.sizeBytes
        if !complete {
            do {
                try spaceCheck(Bytes(entry.sizeBytes), root)
            } catch {
                let failure = Self.failure(
                    for: error, entry: entry, partial: partialBytes(of: entry, in: root)
                )
                failures[entry.id] = failure
                throw StoreError.noSpace(failure)
            }
        }
        failures[entry.id] = nil
        // A file already here is checked, not fetched, so the first reading says so.
        let progress = complete
            ? ProgressBox(received: 0, stage: .checking)
            : ProgressBox(received: partialBytes(of: entry, in: root))
        let token = UUID()
        let task = Task { await self.run(entry, in: root, token: token, progress: progress) }
        attempts[entry.id] = Attempt(token: token, task: task, progress: progress, root: root)
        return .started
    }

    private func run(
        _ entry: PhoneModelEntry, in root: URL, token: UUID, progress: ProgressBox
    ) async {
        var failure: (any Error)?
        do {
            try await fetch(entry, in: root, progress: progress)
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
                for: failure, entry: entry, partial: partialBytes(of: entry, in: root)
            )
        } else {
            failures[entry.id] = nil
        }
    }

    private func fetch(_ entry: PhoneModelEntry, in root: URL, progress: ProgressBox) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = fileURL(for: entry, in: root)
        let partial = partialURL(for: entry, in: root)

        // A whole file already in place that nobody has checked since it last changed — a
        // crash between arriving and checking, a verify, or one copied in by hand. Its
        // size proves nothing, so it is hashed; a match is kept without a byte of network.
        if manager.fileExists(atPath: destination.path) {
            if try await seal(entry, in: root, progress: progress) { return }
            try? manager.removeItem(at: destination)
        }
        // A partial as long as the file is a finished download nobody checked: checked
        // now, and kept if it is right. One longer than the file is a prefix of nothing.
        let kept = Self.size(of: partial) ?? 0
        if kept > entry.sizeBytes {
            try? manager.removeItem(at: partial)
        } else if kept == entry.sizeBytes {
            try manager.moveItem(at: partial, to: destination)
            if try await seal(entry, in: root, progress: progress) { return }
            try? manager.removeItem(at: destination)
        }
        try Task.checkCancellation()

        progress.begin(.fetching, at: Self.size(of: partial) ?? 0)
        let resolution = ModelResolver.Resolution(
            repository: entry.repository,
            // No digest for the downloader: `seal` below hashes what arrived, once, and is
            // the only thing that can make it servable.
            files: [.init(path: entry.file, size: Bytes(entry.sizeBytes), sha256: nil)],
            projector: nil,
            revision: entry.commit
        )
        let downloader = ModelDownloader(
            publicFilesFrom: source(), redirects: HuggingFaceClient.isHubRedirect
        )
        _ = try await downloader.download(resolution, to: root) { progress.note($0) }
        try Task.checkCancellation()
        guard try await seal(entry, in: root, progress: progress) else {
            try? manager.removeItem(at: destination)
            throw ModelDownloader.DownloadError.checksumMismatch(
                file: entry.file, expected: entry.sha256, actual: "the bytes that arrived"
            )
        }
    }

    // MARK: - Removing and stopping

    /// Deletes the Mac's copy and anything partial, stopping a download in flight first.
    /// Idempotent: removing a model that is not here succeeds and leaves it not here.
    public func remove(id: String, library: URL?) async throws {
        guard let entry = entries[id] else { throw StoreError.unknownModel(id) }
        var root = try settledRoot(library)
        // A model on its way to a new folder is removed from where it lands.
        while let relocation {
            await relocation.task.value
            root = try settledRoot(library)
        }
        if let removal = removals[id] {
            await finish(removal, of: id)
            return
        }
        // Out of the table before it is cancelled, so the attempt's own ending sees it is
        // no longer current and records nothing.
        let attempt = attempts.removeValue(forKey: id)
        failures[id] = nil
        var doomed = [
            fileURL(for: entry, in: root), partialURL(for: entry, in: root),
            markerURL(for: entry, in: root),
        ]
        if let other = attempt?.root, other != root {
            doomed += [
                fileURL(for: entry, in: other), partialURL(for: entry, in: other),
                markerURL(for: entry, in: other),
            ]
        }
        let removal = Task {
            attempt?.task.cancel()
            // Waited for, not just cancelled: a fetch that was checking when the cancel
            // arrived would otherwise finish its work after the delete below.
            await attempt?.task.value
            for url in doomed { try? FileManager.default.removeItem(at: url) }
        }
        removals[id] = removal
        await finish(removal, of: id)
    }

    /// Stops a download in flight and keeps what arrived, so the next prepare resumes it.
    public func cancel(id: String) async {
        guard let entry = entries[id] else { return }
        relocation?.wanted.remove(id)
        guard let attempt = attempts.removeValue(forKey: id) else { return }
        attempt.task.cancel()
        await attempt.task.value
        let kept = partialBytes(of: entry, in: attempt.root)
        failures[id] = Failure(
            kind: .interrupted,
            reason: kept > 0
                ? "Stopped at \(Self.percent(kept, of: entry))% of \(entry.label). The Mac kept "
                    + "what arrived; prepare it again to resume."
                : "Stopped before any of \(entry.label) arrived. Prepare it again to start.",
            bytesOnDisk: kept
        )
    }

    // MARK: - Following the library

    private enum Settled {
        case folder(URL)
        case driveMissing(String)
    }

    private func settledRoot(_ library: URL?) throws -> URL {
        switch settle(library) {
        case .folder(let root): return root
        case .driveMissing(let drive): throw StoreError.driveMissing(Self.driveMissingSentence(drive))
        }
    }

    /// Where the library says to be now, remembering where the store was until now — and
    /// starting to move whatever is left in a former folder.
    ///
    /// Every public call comes through here first, so a library moved in Settings is
    /// noticed by the next thing that asks: the Settings row, a phone's request, the
    /// progress watcher. The folder the store last used is written to a small state file,
    /// so the move survives a relaunch in between.
    private func settle(_ library: URL?) -> Settled {
        switch place(forLibrary: library) {
        case .driveMissing(let drive):
            return .driveMissing(drive)
        case .folder(let root):
            var memory = loadMemory()
            let path = root.path
            if memory.current != path {
                if let old = memory.current, !memory.former.contains(old) {
                    memory.former.append(old)
                }
                memory.current = path
                memory.former.removeAll { $0 == path }
                saveMemory(memory)
            }
            if relocation == nil { startRelocationIfNeeded(to: root) }
            return .folder(root)
        }
    }

    private func rememberedFormerFolders() -> [URL] {
        loadMemory().former.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func startRelocationIfNeeded(to root: URL) {
        var sources: [URL] = []
        var memory = loadMemory()
        for folder in rememberedFormerFolders() {
            // Out of reach for now. Kept in memory, and reported, until the drive is back.
            if missingDrive(folder) != nil { continue }
            if holdsPhoneModels(folder) {
                sources.append(folder)
            } else {
                // Nothing of ours there any more: forget it, and tidy what is ours.
                tidy(folder)
                memory.former.removeAll { $0 == folder.path }
                leftBehind[folder.path] = nil
            }
        }
        saveMemory(memory)
        let strays = attempts.filter { $0.value.root != root }
        guard !sources.isEmpty || !strays.isEmpty else { return }

        var involved = Set(strays.keys)
        for source in sources {
            for entry in catalog where hasFiles(entry, in: source) { involved.insert(entry.id) }
        }
        let task = Task { await self.relocate(to: root, from: sources) }
        relocation = Relocation(task: task, involved: involved, wanted: [], progress: [:])
    }

    /// Moves every phone model out of `sources` into `root`: a fetch in flight stops and
    /// resumes here, a finished file comes across and is checked again, and a copy already
    /// here wins over the one being moved once it has been checked. What cannot be moved —
    /// no room on the new drive, or a failure — stays where it is and is reported, never
    /// left behind in silence.
    private func relocate(to root: URL, from sources: [URL]) async {
        for (id, attempt) in attempts where attempt.root != root {
            attempts[id] = nil
            attempt.task.cancel()
            relocation?.wanted.insert(id)
            await attempt.task.value
        }
        for source in sources {
            var problems: [String] = []
            for entry in catalog where hasFiles(entry, in: source) {
                let progress = ProgressBox(received: 0, stage: .moving)
                relocation?.progress[entry.id] = progress
                if let problem = await move(entry, from: source, to: root, progress: progress) {
                    problems.append(problem)
                }
                relocation?.progress[entry.id] = nil
                if relocation?.wanted.contains(entry.id) != true {
                    relocation?.involved.remove(entry.id)
                }
            }
            if problems.isEmpty {
                tidy(source)
                var memory = loadMemory()
                memory.former.removeAll { $0 == source.path }
                saveMemory(memory)
                leftBehind[source.path] = nil
            } else {
                leftBehind[source.path] = problems.joined(separator: " ")
            }
        }
        let wanted = relocation?.wanted ?? []
        relocation = nil
        for id in wanted.sorted() {
            guard let entry = entries[id], attempts[id] == nil, !isVerified(entry, in: root)
            else { continue }
            _ = try? begin(entry, in: root)
        }
    }

    /// One model's files from a former folder to the current one. Nil when that went
    /// well; otherwise the sentence saying why its files are still where they were.
    private func move(
        _ entry: PhoneModelEntry, from source: URL, to root: URL, progress: ProgressBox
    ) async -> String? {
        let manager = FileManager.default
        let oldFile = fileURL(for: entry, in: source)
        let oldPart = partialURL(for: entry, in: source)
        let newFile = fileURL(for: entry, in: root)
        let newPart = partialURL(for: entry, in: root)
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return "The Mac could not create the phone models folder in the model library, "
                + "so \(entry.label) stayed where it was."
        }
        defer { try? manager.removeItem(at: markerURL(for: entry, in: source)) }

        // A copy already here, checked, beats moving another one over it.
        if manager.fileExists(atPath: newFile.path) {
            if (try? await seal(entry, in: root, progress: progress)) == true {
                try? manager.removeItem(at: oldFile)
                try? manager.removeItem(at: oldPart)
                return nil
            }
            try? manager.removeItem(at: newFile)
        }
        let moving = manager.fileExists(atPath: oldFile.path) ? oldFile : oldPart
        let target = moving == oldFile ? newFile : newPart
        if moving == oldPart, manager.fileExists(atPath: newPart.path) {
            // The partial already here is the one to resume.
            try? manager.removeItem(at: oldPart)
            return nil
        }
        let bytes = Self.size(of: moving) ?? 0
        if !Self.sameVolume(source, root) {
            do {
                try spaceCheck(Bytes(bytes), root)
            } catch {
                return "There was not enough space on the model library's drive to move "
                    + "\(entry.label) there, so it is still in the old folder. Free some space "
                    + "on that drive, then open this page again."
            }
        }
        progress.begin(.moving, at: 0)
        do {
            try await Self.offActor { try FileManager.default.moveItem(at: moving, to: target) }
        } catch {
            return "The Mac could not move \(entry.label) from the old folder."
        }
        if moving == oldFile {
            try? manager.removeItem(at: oldPart)
            try? manager.removeItem(at: newPart)
            // Moved bytes are checked again before anything is served from here. A copy
            // that no longer matches is gone, and is fetched afresh when a phone asks.
            if (try? await seal(entry, in: root, progress: progress)) != true {
                try? manager.removeItem(at: newFile)
            }
        }
        return nil
    }

    private func hasFiles(_ entry: PhoneModelEntry, in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: entry, in: folder).path)
            || FileManager.default.fileExists(atPath: partialURL(for: entry, in: folder).path)
    }

    private func holdsPhoneModels(_ folder: URL) -> Bool {
        catalog.contains { hasFiles($0, in: folder) }
    }

    /// Removes this store's markers from a folder it has left, and the folder itself if
    /// nothing else is in it. Anything the owner put there stays.
    private func tidy(_ folder: URL) {
        let manager = FileManager.default
        for entry in catalog { try? manager.removeItem(at: markerURL(for: entry, in: folder)) }
        let left = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
        if left.allSatisfy({ $0 == ".DS_Store" }) { try? manager.removeItem(at: folder) }
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func device(_ url: URL) -> dev_t? {
            var probe = url
            while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
                probe = probe.deletingLastPathComponent()
            }
            var info = stat()
            return stat(probe.path, &info) == 0 ? info.st_dev : nil
        }
        guard let left = device(a), let right = device(b) else { return false }
        return left == right
    }

    private struct Memory: Codable, Equatable {
        var current: String?
        var former: [String] = []
    }

    private func loadMemory() -> Memory {
        let url = stateFile()
        if let memory, memoryURL == url { return memory }
        let loaded = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode(Memory.self, from: $0) } ?? Memory()
        memory = loaded
        memoryURL = url
        return loaded
    }

    private func saveMemory(_ fresh: Memory) {
        let url = stateFile()
        guard fresh != memory || memoryURL != url else { return }
        memory = fresh
        memoryURL = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(fresh).write(to: url, options: .atomic)
    }

    // MARK: - Where things are

    private func fileURL(for entry: PhoneModelEntry, in root: URL) -> URL {
        root.appendingPathComponent(entry.file, isDirectory: false)
    }

    /// The downloader's own name for the file it is resuming.
    private func partialURL(for entry: PhoneModelEntry, in root: URL) -> URL {
        fileURL(for: entry, in: root).appendingPathExtension("part")
    }

    private func markerURL(for entry: PhoneModelEntry, in root: URL) -> URL {
        root.appendingPathComponent(".\(entry.file).verified", isDirectory: false)
    }

    private func partialBytes(of entry: PhoneModelEntry, in root: URL) -> Int64 {
        Self.size(of: partialURL(for: entry, in: root)) ?? 0
    }

    static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { ($0[.size] as? NSNumber)?.int64Value }
    }

    // MARK: - Room

    /// The same rule, and the same reserve, as the Mac's own model downloads — asked of the
    /// drive the folder is on. Important-usage capacity counts what macOS can free up, and
    /// is what the Mac's own downloads use; a volume that does not report it is measured by
    /// its plain free space instead, never waved through.
    public static func checkRoom(needed: Bytes, at folder: URL) throws {
        var probe = folder
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        let important = values?.volumeAvailableCapacityForImportantUsage.flatMap { $0 > 0 ? $0 : nil }
        guard let available = important ?? values?.volumeAvailableCapacity.map(Int64.init) else {
            return
        }
        guard Bytes(available) > needed + ModelDownloader.diskReserve else {
            throw ModelDownloader.DownloadError.insufficientDiskSpace(
                needed: needed, available: Bytes(available)
            )
        }
    }

    // MARK: - Verification

    /// What was true of the file at the moment its digest matched — or now.
    struct Fingerprint: Codable, Equatable {
        var device: Int64
        var inode: UInt64
        var size: Int64
        var modifiedSeconds: Int64
        var modifiedNanoseconds: Int64
        /// The change time: set by the system on any write or attribute change, and not
        /// something a caller can put back — which is what makes an in-place edit with the
        /// modification time restored still read as changed.
        var changedSeconds: Int64
        var changedNanoseconds: Int64

        /// Nil for anything that is not a plain regular file — a link planted where the
        /// file should be is not the file.
        static func of(_ url: URL) -> Fingerprint? {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return Fingerprint(
                device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                changedSeconds: Int64(info.st_ctimespec.tv_sec),
                changedNanoseconds: Int64(info.st_ctimespec.tv_nsec)
            )
        }
    }

    private struct Verification: Codable, Equatable {
        /// What this store computed from the bytes, not what anyone said they were.
        var sha256: String
        var fingerprint: Fingerprint
    }

    /// Whether the file on disk is the one whose digest matched, unchanged since. A stat
    /// and a small read — cheap enough to ask on every request, which is what keeps
    /// "ready" from outliving the file it describes.
    private func isVerified(_ entry: PhoneModelEntry, in root: URL) -> Bool {
        guard let data = try? Data(contentsOf: markerURL(for: entry, in: root)),
              let marker = try? JSONDecoder().decode(Verification.self, from: data),
              marker.sha256 == entry.sha256, marker.fingerprint.size == entry.sizeBytes,
              let now = Fingerprint.of(fileURL(for: entry, in: root))
        else { return false }
        return now == marker.fingerprint
    }

    /// The only place a file becomes servable. It hashes the file itself, and writes the
    /// marker only when the digest is the pin and the file did not change while it was
    /// being read — so no marker can exist for bytes this store did not hash.
    private func seal(
        _ entry: PhoneModelEntry, in root: URL, progress: ProgressBox?
    ) async throws -> Bool {
        let file = fileURL(for: entry, in: root)
        guard Fingerprint.of(file)?.size == entry.sizeBytes else { return false }
        progress?.begin(.checking, at: 0)
        await hooks.beforeCheck?(entry.id)
        try Task.checkCancellation()
        // Taken after the pause, so the fingerprint is of the file as it is hashed.
        guard let before = Fingerprint.of(file), before.size == entry.sizeBytes else {
            return false
        }
        let digest = try await Self.digest(of: file, progress: progress)
        try Task.checkCancellation()
        guard digest == entry.sha256, let after = Fingerprint.of(file), after == before else {
            return false
        }
        let marker = Verification(sha256: digest, fingerprint: after)
        try JSONEncoder().encode(marker)
            .write(to: markerURL(for: entry, in: root), options: .atomic)
        return true
    }

    /// Hashes off the actor, reporting as it goes: a 3.35 GB file takes seconds, and every
    /// state query waits on this actor. Cancelling the caller stops the read.
    static func digest(of url: URL, progress: ProgressBox? = nil) async throws -> String {
        let work = Task.detached(priority: .utility) { () throws -> String in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var done: Int64 = 0
            while let chunk = try handle.read(upToCount: 8 * 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
                done += Int64(chunk.count)
                progress?.noteChecked(done)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func offActor(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await Task.detached(priority: .utility) { try body() }.value
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

    /// One fixed sentence a phone can show, and the kind it can act on. No system error
    /// text ever reaches it — those can carry folder and drive names — and nothing in any
    /// of them is a path on this Mac or a credential.
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
                    reason: "There is not enough space for \(label) on the drive the phone "
                        + "models are kept on: it needs \(needed.formatted), and "
                        + "\(available.formatted) is free, of which \(reserve.formatted) is kept "
                        + "free so a download cannot fill the drive. Free about "
                        + "\(shortfall.formatted) there, then try again.",
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
        case is CancellationError:
            return Failure(
                kind: .interrupted, reason: "The download of \(label) was stopped." + resume,
                bytesOnDisk: partial
            )
        case is RedirectRefused:
            return Failure(
                kind: .server,
                reason: "Hugging Face sent the download of \(label) somewhere this Mac does "
                    + "not fetch from, so it stopped." + resume,
                bytesOnDisk: partial
            )
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
            if error.code == .cancelled {
                return Failure(
                    kind: .interrupted, reason: "The download of \(label) was stopped." + resume,
                    bytesOnDisk: partial
                )
            }
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
                    reason: "The drive the phone models are kept on ran out of space while "
                        + "fetching \(label). Free some space there, then prepare it again.",
                    bytesOnDisk: partial
                )
            }
            return Failure(
                kind: .other,
                reason: "The Mac could not save \(label) in its phone models folder. Check "
                    + "that the drive is connected and has room, then prepare it again.",
                bytesOnDisk: partial
            )
        }
    }
}

// MARK: - Work in flight

extension PhoneModelStore {

    fileprivate struct Attempt {
        let token: UUID
        let task: Task<Void, Never>
        let progress: ProgressBox
        /// The folder this attempt is writing into, which is not the current one once the
        /// library has moved.
        let root: URL
    }

    fileprivate struct Relocation {
        let task: Task<Void, Never>
        /// Models with files on the move, or a fetch waiting for them.
        var involved: Set<String>
        /// Models to fetch once the move is done: the ones that were fetching, and any a
        /// phone asked for meanwhile.
        var wanted: Set<String>
        var progress: [String: ProgressBox]
    }

    /// Progress for one model, written from the downloader's actor and the hashing task
    /// and read from this one — under a lock, so a reading can never arrive after the state
    /// it describes has already been settled.
    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var received: Int64
        private var rate: Double = 0
        private var stage: Stage

        init(received: Int64, stage: Stage = .fetching) {
            self.received = received
            self.stage = stage
        }

        func begin(_ stage: Stage, at bytes: Int64) {
            lock.withLock {
                self.stage = stage
                received = bytes
                rate = 0
            }
        }

        func note(_ progress: ModelDownloader.Progress) {
            lock.withLock {
                received = progress.bytesReceived.rawValue
                rate = progress.bytesPerSecond
            }
        }

        func noteChecked(_ bytes: Int64) {
            lock.withLock { received = bytes }
        }

        var reading: (received: Int64, rate: Double, stage: Stage) {
            lock.withLock { (received, rate, stage) }
        }
    }
}
