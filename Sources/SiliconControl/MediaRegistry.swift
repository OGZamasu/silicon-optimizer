import Foundation
import Security

/// The id→path table behind `GET /media/{id}`.
///
/// A phone must be able to fetch a clip the Mac rendered without ever being handed a path,
/// and without a path it sends being able to become a file it reads. Both halves of that are
/// this type: an id is a random 128-bit token minted here and meaningful nowhere else, and
/// nothing is registrable unless it already lives inside one of the app's own output roots.
/// The route never parses an id — it looks one up, and a miss is a 404 with nothing in it.
///
/// Registering is idempotent by path, because the queue view is rebuilt on every
/// `GET /video/queue`: the same file asked for twice gets the same id, so a phone can cache
/// what it fetched and the table does not grow once per poll.
public actor MediaRegistry {

    /// The one every real caller uses. `ControlServer` defaults to it and so does the event
    /// pump, which is what makes the `mediaID` on a `job` event the same id the queue view
    /// published a second earlier.
    public static let shared = MediaRegistry()

    /// What an id is for. A poster is a few kilobytes of JPEG made *from* a result and
    /// shown in a list; the result itself is the render. They are different things to be
    /// allowed to fetch, which is why the difference is recorded rather than inferred.
    public enum Kind: String, Codable, Sendable {
        case result
        case poster
    }

    /// One served file.
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var path: String
        public var contentType: String
        public var registeredAt: Date
        /// Optional so a table written before posters were distinguished reads as a table
        /// of results, which is what it was.
        public var kind: Kind?

        public var isPoster: Bool { kind == .poster }

        public init(
            id: String, path: String, contentType: String, registeredAt: Date,
            kind: Kind = .result
        ) {
            self.id = id
            self.path = path
            self.contentType = contentType
            self.registeredAt = registeredAt
            self.kind = kind
        }
    }

    private var entries: [String: Entry] = [:]
    /// Resolved path → id, so a second registration of the same file is the first one's id.
    private var byPath: [String: String] = [:]
    /// When each id was last handed out or served, as a count of uses since launch. What
    /// eviction goes by: see `evictLeastRecentlyUsedIfCrowded`. Memory only, because every
    /// queue poll touches every id in it, and rewriting the file for that is the write per
    /// second `dirty` exists to avoid. An id from the file that has not been used since
    /// launch counts as the least recent of all.
    private var lastUse: [String: UInt64] = [:]
    private var uses: UInt64 = 0
    private let url: URL?
    private let capacity: Int
    /// Set while a save is worth doing. Registration happens on every queue poll, and
    /// rewriting the file when nothing changed is a write per second for nothing.
    private var dirty = false

    /// Beside the queue, under the app's own support directory. Nil means in-memory only,
    /// which is what the tests that do not care about persistence use.
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["SILICON_MEDIA_REGISTRY"] {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("SiliconOptimizer/media.json")
    }

    /// - Parameter maximumEntries: the ceiling, for the tests that cannot wait for ten
    ///   thousand registrations. See `maximumEntries`.
    public init(
        url: URL? = MediaRegistry.defaultURL, maximumEntries: Int = MediaRegistry.maximumEntries
    ) {
        self.url = url
        self.capacity = max(1, maximumEntries)
        guard let url, let data = try? Data(contentsOf: url),
              let stored = try? Self.decoder.decode([Entry].self, from: data)
        else { return }
        for entry in stored {
            entries[entry.id] = entry
            byPath[entry.path] = entry.id
        }
    }

    // MARK: - Registering

    /// Mints (or returns) the id for a file inside one of `roots`, and nil for anything else.
    ///
    /// "Anything else" is the whole point, and it is decided on the *resolved* path: `..`
    /// segments are collapsed and symlinks followed before the roots are compared, so
    /// neither a traversal nor a link planted inside an output folder can name a file
    /// outside one. A type this server does not serve is refused here too, so an id can
    /// never exist for something `GET /media` would have to guess the content type of.
    @discardableResult
    public func register(
        path: String, within roots: [String], kind: Kind = .result
    ) -> String? {
        guard let resolved = Self.resolve(path), Self.isInside(resolved, roots: roots) else {
            return nil
        }
        guard let type = GatewayAPI.mediaContentTypes[
            URL(fileURLWithPath: resolved).pathExtension.lowercased()
        ] else { return nil }
        if let existing = byPath[resolved] {
            noteUse(existing)
            return existing
        }
        let id = Self.makeID()
        let entry = Entry(
            id: id, path: resolved, contentType: type, registeredAt: Date(), kind: kind
        )
        entries[id] = entry
        byPath[resolved] = id
        noteUse(id)
        dirty = true
        evictLeastRecentlyUsedIfCrowded()
        return id
    }

    /// How many ids this table keeps. A render a month ago is still fetchable if the file
    /// is still there, but a table that only ever grows is a file somebody finds in a year
    /// wondering what it is.
    ///
    /// It has to hold more than one queue poll publishes. The queue keeps two thousand
    /// items, and each finished clip is two ids — the result and its poster — so a full
    /// queue alone is four thousand, which was this whole table: every render past that
    /// pushed out an id the queue was still showing, the next poll minted it again, and a
    /// phone's cached links broke one by one. The rest is room for renders, meshes and
    /// uploads that a phone holds an id for.
    public static let maximumEntries = 10_000

    private func noteUse(_ id: String) {
        uses += 1
        lastUse[id] = uses
    }

    private func forget(_ entry: Entry) {
        entries.removeValue(forKey: entry.id)
        byPath.removeValue(forKey: entry.path)
        lastUse.removeValue(forKey: entry.id)
    }

    /// Drops the ids used longest ago once the table is over its ceiling. By use rather
    /// than by registration: an id the queue view publishes again on every poll is in use
    /// however long ago it was minted, and dropping it only means minting it again — a new
    /// id for the same file, and a link a phone had cached that now answers 404.
    private func evictLeastRecentlyUsedIfCrowded() {
        guard entries.count > capacity else { return }
        let doomed = entries.values
            .sorted {
                let (left, right) = (lastUse[$0.id] ?? 0, lastUse[$1.id] ?? 0)
                return left == right ? $0.registeredAt < $1.registeredAt : left < right
            }
            .prefix(entries.count - capacity)
        for entry in doomed { forget(entry) }
    }

    /// What `GET /media/{id}` serves, or nil.
    ///
    /// The roots are checked **again here**, against the path re-resolved now, and that is
    /// not belt and braces. Registration proved where a file was at the moment it was
    /// registered; serving happens minutes or days later, and in between the file can be
    /// replaced by a symlink pointing anywhere, or the owner can move their output folder
    /// so a path that was inside one no longer is. An id is a promise about a file, and
    /// this is where the promise is rechecked rather than remembered.
    ///
    /// A miss for any reason — gone, swapped, moved out of the roots — drops the entry and
    /// answers nil. The caller turns all of them into the same 404, because a caller can
    /// do nothing with the difference and an attacker could.
    public func entry(id: String, within roots: [String]) -> Entry? {
        guard let entry = entries[id] else { return nil }
        guard FileManager.default.fileExists(atPath: entry.path),
              let resolved = Self.resolve(entry.path),
              // Re-resolving lands somewhere else: the file at that path is now a link
              // out of the roots, or through one.
              resolved == entry.path,
              Self.isInside(resolved, roots: roots)
        else {
            forget(entry)
            dirty = true
            return nil
        }
        noteUse(id)
        return entry
    }

    /// The id a path already has, without minting one. Used where a caller is resolving an
    /// id a device sent back rather than publishing one.
    public func id(forPath path: String) -> String? {
        Self.resolve(path).flatMap { byPath[$0] }
    }

    public var count: Int { entries.count }

    /// Writes the table if anything changed. Called after a batch of registrations rather
    /// than inside `register`, which runs once per queue item per poll.
    public func persist() {
        guard dirty, let url else { dirty = false; return }
        dirty = false
        let sorted = entries.values.sorted { $0.id < $1.id }
        guard let data = try? Self.encoder.encode(sorted) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Self.writeUserOnly(data, to: url)
    }

    /// Writes a file that is never, for any instant, readable by anyone else.
    ///
    /// `Data.write(options: .atomic)` writes a temporary file at the default mode and
    /// renames it, so chmod-afterwards leaves a window in which the contents are world
    /// readable. Creating the temporary with the mode already on it closes the window,
    /// and the rename is still atomic.
    static func writeUserOnly(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: temporary.path, contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Forgets every id whose file is gone. Called by the uploads sweep, so a device that
    /// uploaded a photograph a fortnight ago does not leave an id pointing at nothing.
    public func forgetMissingFiles() {
        for entry in entries.values where !FileManager.default.fileExists(atPath: entry.path) {
            forget(entry)
            dirty = true
        }
        persist()
    }

    // MARK: - The two rules, as functions

    /// A path with its `..` collapsed and its symlinks followed. Nil for anything that is
    /// not an absolute path to begin with — a relative one has no meaning on a server.
    static func resolve(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        // `standardized` collapses `..` textually, which is what stops traversal even when
        // the file does not exist; `resolvingSymlinksInPath` then follows any link, which is
        // what stops a link *inside* a root pointing out of one.
        return URL(fileURLWithPath: expanded)
            .standardized
            .resolvingSymlinksInPath()
            .path
    }

    /// Whether a resolved path is one of the roots or sits under one. String prefixes are
    /// compared with the separator attached, so `/Movies/Silicon` does not admit
    /// `/Movies/SiliconSecrets`.
    static func isInside(_ resolved: String, roots: [String]) -> Bool {
        roots.contains { root in
            guard let canonical = resolve(root) else { return false }
            if resolved == canonical { return true }
            let prefix = canonical.hasSuffix("/") ? canonical : canonical + "/"
            return resolved.hasPrefix(prefix)
        }
    }

    /// 128 bits from the system CSPRNG, base64url. Long enough that an id cannot be guessed
    /// by a caller that already holds a token, and short enough to sit in a URL.
    static func makeID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            preconditionFailure("The system random number generator refused.")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The entity tag for one file: its size and modification time, which is exactly what
    /// changes when a render overwrites a clip at the same path.
    public static func etag(for path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber
        else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\"\(size.int64Value)-\(Int64(modified * 1000))\""
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - What a device may send

/// What a body actually is, read from its first bytes rather than from what the sender
/// called it.
///
/// A phone says `Content-Type: image/jpeg` and `X-Filename: holiday.jpg`; both are the
/// sender's word for it, and an upload root that trusts either is a file-type confusion
/// waiting to be written to disk. The magic bytes are not the sender's word for it.
public enum MediaSniffer {

    public struct Kind: Sendable, Equatable {
        public var contentType: String
        public var fileExtension: String
        public var isVideo: Bool
    }

    /// Nil for anything that is not an image or a short video this server serves back.
    public static func kind(of data: Data) -> Kind? {
        func matches(_ bytes: [UInt8?], at offset: Int = 0) -> Bool {
            guard data.count >= offset + bytes.count else { return false }
            let start = data.startIndex + offset
            for (index, expected) in bytes.enumerated() {
                guard let expected else { continue }
                if data[start + index] != expected { return false }
            }
            return true
        }

        if matches([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return Kind(contentType: "image/png", fileExtension: "png", isVideo: false)
        }
        if matches([0xFF, 0xD8, 0xFF]) {
            return Kind(contentType: "image/jpeg", fileExtension: "jpg", isVideo: false)
        }
        if matches([0x47, 0x49, 0x46, 0x38]) {
            return Kind(contentType: "image/gif", fileExtension: "gif", isVideo: false)
        }
        // RIFF....WEBP — the four size bytes in between are whatever the file is long.
        if matches([0x52, 0x49, 0x46, 0x46]), matches([0x57, 0x45, 0x42, 0x50], at: 8) {
            return Kind(contentType: "image/webp", fileExtension: "webp", isVideo: false)
        }
        // EBML, which on this route only ever means WebM.
        if matches([0x1A, 0x45, 0xDF, 0xA3]) {
            return Kind(contentType: "video/webm", fileExtension: "webm", isVideo: true)
        }
        // ISO base media: four size bytes, then `ftyp`, then the brand that says which
        // dialect. `qt  ` is QuickTime; everything else this route takes is MP4.
        //
        // The length guard covers the brand, not just the marker. `matches` proves there
        // are eight bytes; reading the brand needs twelve, and an eight-to-eleven-byte
        // body that happens to start `....ftyp` would otherwise slice past the end and
        // trap the whole app — from an unauthenticated-shaped request, at that.
        if data.count >= 12, matches([nil, nil, nil, nil, 0x66, 0x74, 0x79, 0x70]) {
            let brand = String(decoding: data[(data.startIndex + 8)..<(data.startIndex + 12)],
                               as: UTF8.self)
            if brand == "qt  " {
                return Kind(contentType: "video/quicktime", fileExtension: "mov", isVideo: true)
            }
            return Kind(contentType: "video/mp4", fileExtension: "mp4", isVideo: true)
        }
        return nil
    }
}
