import Foundation

/// Discover media independently of queue history. Only the output root and
/// Batches/<job>/ are scanned; inputs, symlinks and arbitrary deeper trees are
/// never followed. Call off the main actor for large editing destinations.
public enum RecentVideoFiles {
    public static func scan(
        in directory: URL, queuedFiles: [URL] = [],
        maximumEntries: Int = 50_000, maximumFolders: Int = 2_000, limit: Int = 60
    ) -> [URL] {
        guard directory.isFileURL, limit > 0 else { return [] }
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                                      .contentModificationDateKey]
        var candidates: [URL: Date] = [:]
        var budget = max(0, maximumEntries)

        func include(_ url: URL) {
            guard url.isFileURL, ["mp4", "mov", "webm"].contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return }
            candidates[url.resolvingSymlinksInPath()] = values.contentModificationDate ?? .distantPast
        }
        func children(_ folder: URL, visit: (URL, URLResourceValues) -> Void) {
            guard budget > 0, !Task.isCancelled,
                  let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  let iterator = manager.enumerator(at: folder, includingPropertiesForKeys: keys,
                      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return }
            while budget > 0, !Task.isCancelled, let child = iterator.nextObject() as? URL {
                budget -= 1
                guard let values = try? child.resourceValues(forKeys: Set(keys)),
                      values.isSymbolicLink != true else { continue }
                visit(child, values)
            }
        }

        // Receipts can also point at a previously configured output destination.
        for url in queuedFiles.prefix(2_000) where !Task.isCancelled { include(url) }
        let root = directory.resolvingSymlinksInPath()
        children(root) { url, _ in include(url) }
        var folders: [(URL, Date)] = []
        children(root.appendingPathComponent("Batches", isDirectory: true)) { url, values in
            if values.isDirectory == true {
                folders.append((url, values.contentModificationDate ?? .distantPast))
            }
        }
        // Prefer recently updated job folders before spending the bounded budget.
        folders.sort { $0.1 == $1.1 ? $0.0.path > $1.0.path : $0.1 > $1.1 }
        for (folder, _) in folders.prefix(max(0, maximumFolders)) where budget > 0 && !Task.isCancelled {
            children(folder) { url, _ in include(url) }
        }
        return candidates.sorted { $0.value == $1.value ? $0.key.path < $1.key.path : $0.value > $1.value }
            .prefix(limit).map(\.key)
    }
}
