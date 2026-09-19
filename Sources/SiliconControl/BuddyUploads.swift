import Foundation

/// Where a photograph a phone sends lands, and how long it stays.
///
/// A device cannot name a file on the Mac — that is the whole point of `MediaRegistry` — so
/// a mesh made from a picture on someone's camera roll needs somewhere for the picture to
/// arrive. It arrives here: under the app's own support directory, in a folder per device,
/// so revoking a phone and deleting what it sent are the same gesture, and nothing a device
/// uploads can land next to the owner's own renders.
///
/// Seven days, then gone. An upload is working material for one render, not a library, and
/// a folder that only ever grows is a folder somebody finds in a year wondering what it is.
public enum BuddyUploads {

    /// How long an upload survives without being asked for again.
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    /// What a device may send to `POST /uploads`: enough for a phone photograph or a short
    /// clip off the camera roll, and nowhere near enough for model weights. It is six times
    /// the ordinary device ceiling, which is why it is raised for this one route and no
    /// other.
    public static let maximumBytes = 24 * 1_048_576

    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["SILICON_BUDDY_UPLOADS"] {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("SiliconOptimizer/uploads")
    }

    /// One device's folder. The id is a UUID this Mac minted at pairing, but it arrives as a
    /// path component either way, so it is sanitised rather than trusted: anything that is
    /// not a letter, a digit, a dash or an underscore is replaced, which leaves no `.` and
    /// no `/` for a bucket name to climb out of.
    public static func deviceRoot(_ bucket: String, at root: URL = BuddyUploads.root) -> URL {
        root.appendingPathComponent(safe(bucket), isDirectory: true)
    }

    static func safe(_ bucket: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = String(bucket.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        })
        return cleaned.isEmpty ? "unknown" : String(cleaned.prefix(64))
    }

    /// Deletes everything older than `lifetime` and any device folder left empty by that.
    /// Returns how many files went, which is what the test reads and what a log line would.
    @discardableResult
    public static func sweep(
        at root: URL = BuddyUploads.root, now: Date = Date(),
        lifetime: TimeInterval = BuddyUploads.lifetime
    ) -> Int {
        let manager = FileManager.default
        guard let devices = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return 0 }

        var removed = 0
        for device in devices {
            guard let files = try? manager.contentsOfDirectory(
                at: device, includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }
            for file in files {
                let modified = (try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? Date.distantPast
                guard now.timeIntervalSince(modified) > lifetime else { continue }
                if (try? manager.removeItem(at: file)) != nil { removed += 1 }
            }
            // An empty folder is a device that has sent nothing in a week. Tidying it means
            // the uploads root reads as "who has sent something lately" rather than as a
            // list of every phone ever paired.
            if (try? manager.contentsOfDirectory(atPath: device.path))?.isEmpty == true {
                try? manager.removeItem(at: device)
            }
        }
        return removed
    }

    /// Creates a device's folder and hands back where a body should be written. The name is
    /// the upload id plus the extension the *sniffer* chose — never the one the sender put
    /// in `X-Filename`, which is used for nothing but the error message it can cause.
    public static func destination(
        forBucket bucket: String, uploadID: String, fileExtension: String,
        at root: URL = BuddyUploads.root
    ) throws -> URL {
        let folder = root.appendingPathComponent(safe(bucket), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: folder.path
        )
        return folder.appendingPathComponent("\(uploadID).\(fileExtension)")
    }

    /// The file one `uploadID` names, inside one device's folder.
    ///
    /// Scoped to the bucket on purpose: an id is a UUID nobody else should have, and
    /// looking it up only where its owner put it means that even if one somehow leaks, it
    /// is not a key to another device's photographs. An id that is not a plain token —
    /// anything with a dot or a slash in it — resolves to nothing rather than being
    /// sanitised into somebody else's file.
    public static func resolve(
        uploadID: String, bucket: String, at root: URL = BuddyUploads.root
    ) -> URL? {
        guard !uploadID.isEmpty, safe(uploadID) == uploadID else { return nil }
        let folder = root.appendingPathComponent(safe(bucket), isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ) else { return nil }
        return files.first {
            $0.deletingPathExtension().lastPathComponent == uploadID
        }
    }
}

/// Where a clip's poster frame is kept.
///
/// Its own folder under the app's support directory rather than beside the clip, because
/// the clip is in the owner's Movies folder and a JPEG nobody asked for does not belong
/// there. A poster is a cache: deleting the folder costs the next request a few hundred
/// milliseconds and nothing else.
public enum BuddyPosters {

    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["SILICON_BUDDY_POSTERS"] {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        return base.appendingPathComponent("SiliconOptimizer/posters")
    }

    /// The poster for one clip, named after what it is a poster *of*: the path, its size
    /// and its modification time. A clip re-rendered to the same path gets a new name, so
    /// a stale frame can never be served for a new video.
    public static func destination(
        forVideo path: String, at root: URL = BuddyPosters.root
    ) -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attributes[.size] as? NSNumber)?.int64Value
        else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let name = BuddyPairing.hash(token: "\(path)|\(size)|\(Int64(modified * 1000))")
        return root.appendingPathComponent("\(name.prefix(32)).jpg")
    }
}
