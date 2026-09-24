import CryptoKit
import Foundation

/// What a caller that is not this Mac is told about where a file is.
///
/// A render's answer names the file it made, and on a Mac that name is a path through the
/// owner's folders — `/Users/<name>/Movies/…`: the account name, and how the disk is laid
/// out. This Mac's own token belongs to its scripts and MCP tools, which open those files, so
/// they keep the paths. A paired phone or a swarm node cannot open a path on this Mac at all —
/// it fetches by `mediaID` — so it is told the file's name, which is enough to show and to
/// read an extension off, and nothing about the folders above it.
///
/// Sentences get the same treatment. A warning or a refusal written for the owner may quote a
/// path ("No image at …"), and one that reaches somebody else says the folder's own name, or
/// `~` for the home folder, in its place.
struct MacPathRedaction: Sendable {

    /// Absolute folders a sentence may mention, longest first, each with what replaces it.
    private let folders: [(path: String, label: String)]

    /// - Parameters:
    ///   - roots: the folders this Mac writes results and uploads into.
    ///   - home: the owner's home folder, which is where the account name is.
    init(roots: [String], home: String = NSHomeDirectory()) {
        var folders: [(path: String, label: String)] = []
        func add(_ folder: String, label: String) {
            let trimmed = folder.count > 1 && folder.hasSuffix("/")
                ? String(folder.dropLast()) : folder
            guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return }
            // Every spelling: a temporary folder is /var/… and /private/var/… at once, a
            // root may sit behind a link, and which one a sentence quotes depends on who
            // wrote it.
            var spellings: Set<String> = [trimmed]
            if let resolved = MediaRegistry.resolve(trimmed) { spellings.insert(resolved) }
            for spelling in spellings {
                if spelling.hasPrefix("/private/") {
                    spellings.insert(String(spelling.dropFirst("/private".count)))
                } else {
                    spellings.insert("/private" + spelling)
                }
            }
            for spelling in spellings { folders.append((spelling, label)) }
        }
        for root in roots {
            add(root, label: (root as NSString).lastPathComponent)
        }
        add(home, label: "~")
        self.folders = folders.sorted { $0.path.count > $1.path.count }
    }

    /// A file's own name. Something that is not a path — an empty field, a bare name — is
    /// left as it was.
    func name(_ path: String) -> String {
        guard path.contains("/") else { return path }
        return (path as NSString).lastPathComponent
    }

    /// `text`, with every folder above replaced where it appears as a whole path, and every
    /// other absolute path reduced to the name at its end.
    ///
    /// The folders above are the ones worth a readable label. They are not the only ones a
    /// sentence quotes: a mesh or image tool that fails hands back the tail of its own log,
    /// and a Python traceback names every file on the way down — the external drive, the
    /// folder the tool was installed in, how the owner's disk is laid out. So whatever path
    /// is left once the labels are in is cut to its last component, the way a runtime's log
    /// is (`LoadFailure.withoutPaths`, which this module cannot reach).
    func scrub(_ text: String) -> String {
        guard text.contains("/") else { return text }
        let labelled = folders.reduce(text) { Self.replace($1.path, with: $1.label, in: $0) }
        return Self.namesOnly(labelled)
    }

    /// Every path on this Mac's disk in `text`, cut to its last component.
    ///
    /// A path here is one that starts at a folder a Mac's disk actually has at its top —
    /// `/Volumes`, `/Users`, `/private` and the rest — so `/v1/jobs` in a sentence about a
    /// node's API is left as it was. It starts at a slash that begins a word — the start of
    /// the text, or after a space, a quote, a bracket, `=` or a comma — so the path inside
    /// a URL, which follows a host name, is not one either, nor are `~/…` and `Movies/…`
    /// that a label above has already made safe. Folder names may hold spaces; a segment
    /// ending in one is where the next path begins. Quotes, brackets, commas and colons end
    /// a path, because that is what a log puts around one.
    static func namesOnly(_ text: String) -> String {
        guard text.contains("/"), let expression = absolutePath else { return text }
        let whole = text as NSString
        var out = ""
        var cursor = 0
        for match in expression.matches(
            in: text, range: NSRange(location: 0, length: whole.length)
        ) {
            out += whole.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor)
            )
            let path = whole.substring(with: match.range)
            out += path.split(separator: "/").last.map(String.init) ?? path
            cursor = match.range.location + match.range.length
        }
        return out + whole.substring(from: cursor)
    }

    private static let absolutePath = try? NSRegularExpression(
        pattern: #"(?<![^\s'"(\[{<=,])"#  // a slash that begins a word,
            + "/(?i:" + topLevelFolders.joined(separator: "|") + ")"  // a folder at the top,
            + #"(?=[/\s'"(),:\[\]{}<>]|$)"#  // the whole of its name,
            + #"(?:/[^/\n'"(),:\[\]{}<>]*[^/\s'"(),:\[\]{}<>](?=/))*"#  // the ones below it,
            + #"(?:/[^/\n'"(),:\[\]{}<>]*)?"#  // and the name they end in
    )

    /// What a Mac has at the top of its disk. Matched without regard to case, as the disk
    /// itself is.
    private static let topLevelFolders = [
        "Applications", "Library", "System", "Users", "Volumes", "private", "var", "tmp",
        "etc", "opt", "usr", "bin", "sbin", "cores", "dev", "home", "nix",
    ]

    /// Whole-path matches only: `/Users/you` is not replaced inside `/Users/youngest`, and
    /// `/var/folders/…` is not replaced inside `/private/var/folders/…`.
    private static func replace(_ folder: String, with label: String, in text: String) -> String {
        func continuesAName(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.isLetter || character.isNumber || "-_.".contains(character)
        }
        var output = ""
        var rest = text[...]
        while let found = rest.range(of: folder) {
            let before = found.lowerBound > text.startIndex
                ? text[text.index(before: found.lowerBound)] : nil
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            output += rest[..<found.lowerBound]
            output += continuesAName(before) || continuesAName(after)
                ? String(rest[found]) : label
            rest = rest[found.upperBound...]
        }
        return output + rest
    }
}

/// A response that names files on this Mac, and the same response for somebody else.
protocol MacPathBearing: Sendable {
    func withoutMacPaths(_ redaction: MacPathRedaction) -> Self
}

extension ControlAPI.ImageResponse: MacPathBearing {
    func withoutMacPaths(_ redaction: MacPathRedaction) -> Self {
        var copy = self
        copy.path = redaction.name(path)
        copy.warning = warning.map(redaction.scrub)
        return copy
    }
}

extension ControlAPI.MeshResponse: MacPathBearing {
    func withoutMacPaths(_ redaction: MacPathRedaction) -> Self {
        var copy = self
        copy.glbPath = glbPath.map(redaction.name)
        copy.objPath = objPath.map(redaction.name)
        copy.warning = warning.map(redaction.scrub)
        return copy
    }
}

extension ControlAPI.VideoResponse: MacPathBearing {
    func withoutMacPaths(_ redaction: MacPathRedaction) -> Self {
        var copy = self
        copy.file = redaction.name(file)
        copy.detail = detail.map(redaction.scrub)
        return copy
    }
}

extension ControlAPI.VideoQueueView: MacPathBearing {
    func withoutMacPaths(_ redaction: MacPathRedaction) -> Self {
        var copy = self
        copy.message = message.map(redaction.scrub)
        for index in copy.items.indices {
            let item = copy.items[index]
            copy.items[index].file = item.file.map(redaction.name)
            copy.items[index].outputDirectory = redaction.name(item.outputDirectory)
            copy.items[index].error = item.error.map(redaction.scrub)
            copy.items[index].detail = item.detail.map(redaction.scrub)
            copy.items[index].cancelDetail = item.cancelDetail.map(redaction.scrub)
        }
        return copy
    }
}

/// An imported model's id, as a swarm node is told it.
///
/// A GGUF the owner imported rather than downloaded stays where it was, and its id is
/// `external:` and that file's absolute path (`ModelLibrary.importExternal`) — the account
/// name again, on `GET /installed`, on `GET /status` and in the `status` frames on `/events`.
/// A paired phone sends that id back to `POST /load`, and so do this Mac's own tools, so for
/// them it stays what it is. A swarm node cannot load anything here (`/load` is outside its
/// scope), so it is told a token instead: the same token for the same model on all three,
/// and no way back to the path.
///
/// Keyed, with a key made at launch. A plain digest of the id could be checked against a
/// guessed `/Users/<name>/…` by anyone who holds it, which is exactly the question it must
/// not answer. So the token is stable while the app runs and changes when it restarts.
public enum ImportedModelID {

    /// `ModelLibrary.externalIDPrefix`, which this module cannot import.
    public static let prefix = "external:"

    private static let key = Array(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })

    /// `external:` and sixteen hex digits for an imported model; any other id unchanged.
    public static func forPeers(_ id: String) -> String {
        guard id.hasPrefix(prefix) else { return id }
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(id.utf8), using: SymmetricKey(data: key)
        )
        return prefix + code.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension ControlAPI.InstalledModel {
    /// This entry as a swarm node is told it. See `ImportedModelID`.
    var forPeers: Self {
        var copy = self
        copy.id = ImportedModelID.forPeers(id)
        return copy
    }
}

extension ControlAPI.Status {
    /// This status as a swarm node is told it, on `GET /status` and on `/events` alike:
    /// without the runtime's log, as for every caller short of full control, with an
    /// imported model named by its token wherever its id appears, and with the home folder
    /// out of the state line.
    ///
    /// "Wherever" is four places: the loaded model, the model a failure belongs to, and each
    /// stopped load's model and the one that replaced it. The last three name loads that are
    /// over, and an imported model's id is its path whether or not it is still in memory.
    var forPeers: Self {
        var peer = withoutPrivilegedDetail
        if let id = loadedModelID, id.hasPrefix(ImportedModelID.prefix) {
            let token = ImportedModelID.forPeers(id)
            peer.loadedModelID = token
            peer.state = peer.state.replacingOccurrences(of: id, with: token)
        }
        peer.failure?.modelID = failure?.modelID.map(ImportedModelID.forPeers)
        peer.interruptedLoads = interruptedLoads?.map { stopped in
            var told = stopped
            told.modelID = ImportedModelID.forPeers(stopped.modelID)
            told.replacedBy = stopped.replacedBy.map(ImportedModelID.forPeers)
            return told
        }
        if peer.state.contains("/") {
            peer.state = MacPathRedaction(roots: []).scrub(peer.state)
        }
        return peer
    }
}
