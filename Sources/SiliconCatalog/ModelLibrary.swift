import Foundation
import SiliconCore

/// A model that has been downloaded and is ready to load.
public struct InstalledModel: Sendable, Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var catalogID: String?
    public var quantization: Quantization
    public var format: ModelFormat
    /// Primary weights file — the head shard for split models.
    public var primaryFile: URL
    public var allFiles: [URL]
    public var projectorFile: URL?
    public var sizeOnDisk: Bytes
    public var installedAt: Date
    /// Architecture read from the GGUF header at install time, which supersedes catalog estimates.
    public var shape: ModelShape?
    public var capabilities: ModelCapabilities
    /// Canonical directory created for a download. Nil for imports and legacy entries whose
    /// ownership cannot be proven, which limits removal to the explicitly registered files.
    public var managedDirectory: URL?
    /// Canonical download root that authorized `managedDirectory` when the model was registered.
    public var managedRoot: URL?

    public init(
        id: String, name: String, catalogID: String?, quantization: Quantization,
        format: ModelFormat, primaryFile: URL, allFiles: [URL], projectorFile: URL?,
        sizeOnDisk: Bytes, installedAt: Date, shape: ModelShape?, capabilities: ModelCapabilities,
        managedDirectory: URL? = nil, managedRoot: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.catalogID = catalogID
        self.quantization = quantization
        self.format = format
        self.primaryFile = primaryFile
        self.allFiles = allFiles
        self.projectorFile = projectorFile
        self.sizeOnDisk = sizeOnDisk
        self.installedAt = installedAt
        self.shape = shape
        self.capabilities = capabilities
        self.managedDirectory = managedDirectory
        self.managedRoot = managedRoot
    }

    public var supportsVision: Bool { capabilities.contains(.vision) && projectorFile != nil }
}

/// Owns the on-disk model library and its index.
public actor ModelLibrary {

    public static let defaultRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SiliconOptimizer/Models", isDirectory: true)
    }()

    private let root: URL
    /// Where new downloads land. Distinct from `root` so the index — the app's memory of
    /// every model it knows — never moves when the user points downloads at a bigger disk.
    /// Entries hold absolute paths, so models in every previous location stay listed and
    /// loadable; only the destination of the *next* download changes.
    private var downloadRoot: URL
    private var index: [String: InstalledModel] = [:]

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = canonical(candidate).pathComponents
        let rootComponents = canonical(root).pathComponents
        return candidateComponents.count > rootComponents.count
            && candidateComponents.starts(with: rootComponents)
    }

    /// Ownership URLs are stored after canonicalization. If either path resolves somewhere
    /// different later, an ancestor was replaced by a symlink and the old capability no longer
    /// authorizes recursive deletion at that name.
    private static func isStillCanonical(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        return canonical(standardized).path == standardized.path
    }

    /// Returns the canonical directory only when recursive deletion is confined below a root
    /// currently owned by the library. Returning the resolved path also avoids following a
    /// different final symlink at the deletion sink.
    private func downloadOwnership(for directory: URL) -> (directory: URL, root: URL)? {
        let resolved = Self.canonical(directory)
        let roots = [root, downloadRoot].map(Self.canonical)
        guard let owner = roots.first(where: { Self.isStrictDescendant(resolved, of: $0) })
        else { return nil }
        return (resolved, owner)
    }

    private func recursiveDeletionDirectory(for model: InstalledModel) -> URL? {
        guard model.catalogID != nil,
              let claimedDirectory = model.managedDirectory,
              let claimedRoot = model.managedRoot
        else {
            return nil
        }
        guard Self.isStillCanonical(claimedDirectory), Self.isStillCanonical(claimedRoot)
        else { return nil }
        let claimed = Self.canonical(claimedDirectory)
        let owner = Self.canonical(claimedRoot)
        let primaryDirectory = model.primaryFile.deletingLastPathComponent().standardizedFileURL
        guard Self.isStillCanonical(primaryDirectory) else { return nil }
        let actual = Self.canonical(primaryDirectory)
        guard claimed == actual,
              Self.isStrictDescendant(claimed, of: owner)
        else { return nil }
        return claimed
    }

    public init(root: URL = ModelLibrary.defaultRoot) {
        self.root = root
        self.downloadRoot = root
    }

    /// Points new downloads somewhere else; nil returns to the index root.
    public func setDownloadRoot(_ url: URL?) {
        downloadRoot = url ?? root
    }

    public func load() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = (try? decoder.decode([InstalledModel].self, from: data)) ?? []
        index = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        pruneTrulyDeleted()
    }

    /// Drops index entries whose file is gone from under this library's own managed directory —
    /// that really is a deletion, done behind our back in a visible folder. A model stored
    /// elsewhere (external media, an imported file) is left in the index even when its file is
    /// briefly unreachable, since for those that far more often means the volume isn't mounted
    /// right now than that the model was deleted; `installed` already hides it either way, and
    /// pruning it here would forget it permanently the next time the drive isn't plugged in.
    private func pruneTrulyDeleted() {
        let before = index.count
        index = index.filter { _, model in
            let isManaged = if let directory = model.managedDirectory,
                               let owner = model.managedRoot,
                               Self.isStillCanonical(directory), Self.isStillCanonical(owner) {
                Self.canonical(directory)
                    == Self.canonical(model.primaryFile.deletingLastPathComponent())
                    && Self.isStrictDescendant(directory, of: owner)
            } else {
                false
            }
            return !isManaged || FileManager.default.fileExists(atPath: model.primaryFile.path)
        }
        if index.count != before { try? save() }
    }

    public var installed: [InstalledModel] {
        index.values
            .filter { FileManager.default.fileExists(atPath: $0.primaryFile.path) }
            .sorted { $0.installedAt > $1.installedAt }
    }

    public func model(id: String) -> InstalledModel? { index[id] }

    public func isInstalled(catalogID: String, quantization: Quantization) -> Bool {
        index.values.contains { $0.catalogID == catalogID && $0.quantization == quantization }
    }

    public func directory(for catalogID: String, quantization: Quantization) -> URL {
        downloadRoot.appendingPathComponent(
            "\(catalogID)/\(quantization.rawValue)", isDirectory: true
        )
    }

    public func add(_ model: InstalledModel) throws {
        index[model.id] = model
        try save()
    }

    /// Registers a freshly downloaded model, reading its real architecture from the GGUF header.
    public func register(
        entry: ModelEntry,
        quantization: Quantization,
        files: [URL],
        projector: URL?
    ) throws -> InstalledModel {
        guard let primary = files.first else {
            throw CocoaError(.fileNoSuchFile)
        }

        // Prefer the header's numbers over the catalog's estimates — they describe the file we
        // actually have, including any re-quantization the publisher has done since.
        let shape = (try? GGUFReader().read(at: primary))
            .flatMap { GGUFReader().shape(from: $0, fallback: entry.shape) } ?? entry.shape
        let ownership = downloadOwnership(for: primary.deletingLastPathComponent())

        let model = InstalledModel(
            id: "\(entry.id)@\(quantization.rawValue)",
            name: entry.name,
            catalogID: entry.id,
            quantization: quantization,
            format: entry.format,
            primaryFile: primary,
            allFiles: files,
            projectorFile: projector,
            sizeOnDisk: files.reduce(Bytes.zero) { $0 + Self.fileSize($1) },
            installedAt: Date(),
            shape: shape,
            capabilities: entry.capabilities,
            managedDirectory: ownership?.directory,
            managedRoot: ownership?.root
        )
        try add(model)
        return model
    }

    public func remove(id: String) throws {
        guard let model = index[id] else { return }
        // Remove the model's own directory rather than individual files so companion files
        // (projectors, partial downloads) go with it. Managed means "under a root this
        // library downloads into" — imported files elsewhere only lose the files we know.
        // Imports are never evidence that their containing directory belongs to this app, even
        // when the selected file happens to sit below a managed root.
        if let managed = recursiveDeletionDirectory(for: model) {
            try? FileManager.default.removeItem(at: managed)
        } else {
            for file in model.allFiles { try? FileManager.default.removeItem(at: file) }
        }
        index[id] = nil
        try save()
    }

    /// Sums only what's actually reachable right now — `index` can also hold entries on
    /// external media that isn't currently mounted, which shouldn't count toward "on disk".
    public var totalSizeOnDisk: Bytes {
        installed.reduce(Bytes.zero) { $0 + $1.sizeOnDisk }
    }

    /// Imports a GGUF file the user already has, without copying it.
    public func importExternal(file: URL, name: String? = nil) throws -> InstalledModel {
        let metadata = try GGUFReader().read(at: file)
        let shape = GGUFReader().shape(from: metadata)
        let quantization = Quantization.inferred(fromFilename: file.lastPathComponent) ?? .q4_K_M
        let model = InstalledModel(
            id: "external:\(file.path)",
            name: name ?? metadata.name ?? file.deletingPathExtension().lastPathComponent,
            catalogID: nil,
            quantization: quantization,
            format: .gguf,
            primaryFile: file,
            allFiles: [file],
            projectorFile: nil,
            sizeOnDisk: Self.fileSize(file),
            installedAt: Date(),
            shape: shape,
            capabilities: []
        )
        try add(model)
        return model
    }

    /// Persists every known entry, not just `installed` — a model on unmounted external media
    /// still belongs in the index even while `installed` is hiding it for being unreachable.
    private func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(Array(index.values)).write(to: indexURL, options: .atomic)
    }

    nonisolated static func fileSize(_ url: URL) -> Bytes {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return Bytes((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
    }
}
