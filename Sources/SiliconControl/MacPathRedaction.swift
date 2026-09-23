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

    /// `text`, with every folder above replaced where it appears as a whole path.
    func scrub(_ text: String) -> String {
        guard text.contains("/") else { return text }
        return folders.reduce(text) { Self.replace($1.path, with: $1.label, in: $0) }
    }

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
