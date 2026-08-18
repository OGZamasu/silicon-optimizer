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

    public init(
        id: String, name: String, catalogID: String?, quantization: Quantization,
        format: ModelFormat, primaryFile: URL, allFiles: [URL], projectorFile: URL?,
        sizeOnDisk: Bytes, installedAt: Date, shape: ModelShape?, capabilities: ModelCapabilities
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
    private var index: [String: InstalledModel] = [:]

    private var indexURL: URL { root.appendingPathComponent("index.json") }

    public init(root: URL = ModelLibrary.defaultRoot) {
        self.root = root
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
            let isManaged = model.primaryFile.path.hasPrefix(root.path)
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
        root.appendingPathComponent("\(catalogID)/\(quantization.rawValue)", isDirectory: true)
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
            capabilities: entry.capabilities
        )
        try add(model)
        return model
    }

    public func remove(id: String) throws {
        guard let model = index[id] else { return }
        // Remove the model's own directory rather than individual files so companion files
        // (projectors, partial downloads) go with it.
        let directory = model.primaryFile.deletingLastPathComponent()
        if directory.path.hasPrefix(root.path) && directory.path != root.path {
            try? FileManager.default.removeItem(at: directory)
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
