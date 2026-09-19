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

    /// One served file.
    public struct Entry: Codable, Sendable, Equatable {
        public var id: String
        public var path: String
        public var contentType: String
        public var registeredAt: Date

        public init(id: String, path: String, contentType: String, registeredAt: Date) {
            self.id = id
            self.path = path
            self.contentType = contentType
            self.registeredAt = registeredAt
        }
    }

    private var entries: [String: Entry] = [:]
    /// Resolved path → id, so a second registration of the same file is the first one's id.
    private var byPath: [String: String] = [:]
    private let url: URL?
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

    public init(url: URL? = MediaRegistry.defaultURL) {
        self.url = url
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
    public func register(path: String, within roots: [String]) -> String? {
        guard let resolved = Self.resolve(path), Self.isInside(resolved, roots: roots) else {
            return nil
        }
        guard let type = GatewayAPI.mediaContentTypes[
            URL(fileURLWithPath: resolved).pathExtension.lowercased()
        ] else { return nil }
        if let existing = byPath[resolved] { return existing }
        let id = Self.makeID()
        let entry = Entry(
            id: id, path: resolved, contentType: type, registeredAt: Date()
        )
        entries[id] = entry
        byPath[resolved] = id
        dirty = true
        return id
    }

    /// What `GET /media/{id}` serves, or nil. An entry whose file has since been deleted is
    /// dropped rather than returned: the queue keeps history long after a clip has been
    /// moved to the bin, and a 404 is the truth about it.
    public func entry(id: String) -> Entry? {
        guard let entry = entries[id] else { return nil }
        guard FileManager.default.fileExists(atPath: entry.path) else {
            entries.removeValue(forKey: id)
            byPath.removeValue(forKey: entry.path)
            dirty = true
            return nil
        }
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
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    /// Forgets every id whose file is gone. Called by the uploads sweep, so a device that
    /// uploaded a photograph a fortnight ago does not leave an id pointing at nothing.
    public func forgetMissingFiles() {
        for (id, entry) in entries where !FileManager.default.fileExists(atPath: entry.path) {
            entries.removeValue(forKey: id)
            byPath.removeValue(forKey: entry.path)
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
        if matches([nil, nil, nil, nil, 0x66, 0x74, 0x79, 0x70]) {
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
