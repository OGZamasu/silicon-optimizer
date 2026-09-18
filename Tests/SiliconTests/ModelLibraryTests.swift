import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore

/// `load()` used to drop any index entry whose file was momentarily unreachable, permanently,
/// the moment it noticed — fine when that means "deleted," wrong when it means "the external
/// drive this model was saved to isn't mounted right now." These pin the distinction: a model
/// living under the library's own managed directory really is gone once its file disappears; one
/// saved elsewhere is only hidden until its file is reachable again.
@Suite("Model library persistence")
struct ModelLibraryTests {

    private func stubModel(
        id: String,
        primaryFile: URL,
        catalogID: String? = "catalog-model",
        managedDirectory: URL? = nil,
        managedRoot: URL? = nil
    ) -> InstalledModel {
        InstalledModel(
            id: id, name: id, catalogID: catalogID, quantization: .q4_K_M, format: .gguf,
            primaryFile: primaryFile, allFiles: [primaryFile], projectorFile: nil,
            sizeOnDisk: .zero, installedAt: Date(), shape: nil, capabilities: [],
            managedDirectory: managedDirectory, managedRoot: managedRoot
        )
    }

    @Test func externalModelSurvivesAReloadWhileItsFileIsUnreachable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-test-root-\(UUID().uuidString)")
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-test-external-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let externalFile = external.appendingPathComponent("model.gguf")
        try "stand-in".write(to: externalFile, atomically: true, encoding: .utf8)

        let library = ModelLibrary(root: root)
        try await library.load()
        try await library.add(stubModel(id: "external-model", primaryFile: externalFile))

        // The drive goes away.
        try FileManager.default.removeItem(at: externalFile)

        // A fresh instance re-reading the same index simulates relaunching the app while it's
        // still unplugged.
        let whileUnplugged = ModelLibrary(root: root)
        try await whileUnplugged.load()
        #expect(await whileUnplugged.installed.isEmpty, "hidden while unreachable, as expected")

        // The drive comes back, without the model ever having been re-added.
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try "stand-in".write(to: externalFile, atomically: true, encoding: .utf8)

        let afterReconnecting = ModelLibrary(root: root)
        try await afterReconnecting.load()
        let found = await afterReconnecting.installed
        #expect(found.contains { $0.id == "external-model" }, "should reappear, not need reinstalling")
    }

    @Test func legacyIndexEntriesWithoutOwnershipMetadataStillDecode() throws {
        let file = URL(fileURLWithPath: "/tmp/legacy-model.gguf")
        let encoded = try JSONEncoder().encode(stubModel(id: "legacy", primaryFile: file))
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "managedDirectory")
        object.removeValue(forKey: "managedRoot")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(InstalledModel.self, from: legacy)

        #expect(decoded.id == "legacy")
        #expect(decoded.managedDirectory == nil)
        #expect(decoded.managedRoot == nil)
    }

    @Test func managedModelIsPrunedOnceItsFileIsActuallyGone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-test-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let managedDirectory = root.appendingPathComponent("catalog/Q4", isDirectory: true)
        try FileManager.default.createDirectory(
            at: managedDirectory, withIntermediateDirectories: true
        )
        let managedFile = managedDirectory.appendingPathComponent("model.gguf")
        try "stand-in".write(to: managedFile, atomically: true, encoding: .utf8)

        let library = ModelLibrary(root: root)
        try await library.load()
        try await library.add(stubModel(
            id: "managed-model", primaryFile: managedFile,
            managedDirectory: managedDirectory, managedRoot: root
        ))

        // Deleted behind the library's back, the scenario `pruneTrulyDeleted` exists for.
        try FileManager.default.removeItem(at: managedFile)

        let reloaded = ModelLibrary(root: root)
        try await reloaded.load()
        #expect(await reloaded.installed.isEmpty)

        // Recreating the file at the same path does not resurrect the entry — unlike the
        // external case above, it really was removed from the persisted index, not just hidden.
        try "stand-in".write(to: managedFile, atomically: true, encoding: .utf8)
        let afterRecreate = ModelLibrary(root: root)
        try await afterRecreate.load()
        #expect(await afterRecreate.installed.isEmpty)
    }

    @Test func totalSizeOnDiskCountsOnlyWhatIsCurrentlyReachable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-test-root-\(UUID().uuidString)")
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-test-external-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let library = ModelLibrary(root: root)
        try await library.load()

        let managedFile = root.appendingPathComponent("model.gguf")
        try "stand-in".write(to: managedFile, atomically: true, encoding: .utf8)
        var managed = stubModel(id: "managed-model", primaryFile: managedFile)
        managed.sizeOnDisk = .mib(100)
        try await library.add(managed)

        // Not mounted -- never written at this path.
        let unreachableExternal = external.appendingPathComponent("model.gguf")
        var external2 = stubModel(id: "external-model", primaryFile: unreachableExternal)
        external2.sizeOnDisk = .gib(50)
        try await library.add(external2)

        let total = await library.totalSizeOnDisk
        #expect(total == .mib(100), "an unmounted model's recorded size should not count")
    }

    /// A changed download destination moves only where the next download lands; the index
    /// stays home so every previously downloaded model remains listed.
    @Test func downloadRootMovesDestinationNotTheIndex() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-test-\(UUID().uuidString)")
        let elsewhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-external-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let library = ModelLibrary(root: root)
        try await library.load()

        let before = await library.directory(for: "some-model", quantization: .q4_K_M)
        #expect(before.path.hasPrefix(root.path))

        await library.setDownloadRoot(elsewhere)
        let after = await library.directory(for: "some-model", quantization: .q4_K_M)
        #expect(after.path.hasPrefix(elsewhere.path))

        // A model registered while pointed elsewhere still lands in the home index, so it
        // survives pointing the destination somewhere else again.
        let file = elsewhere.appendingPathComponent("some-model/Q4_K_M/model.gguf")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "stand-in".write(to: file, atomically: true, encoding: .utf8)
        try await library.add(stubModel(id: "elsewhere-model", primaryFile: file))
        await library.setDownloadRoot(nil)

        let reloaded = ModelLibrary(root: root)
        try await reloaded.load()
        let ids = await reloaded.installed.map(\.id)
        #expect(ids.contains("elsewhere-model"))
    }

    @Test func prefixCollidingDirectoryIsNeverRecursivelyDeleted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-\(UUID().uuidString)")
        let collision = URL(fileURLWithPath: root.path + "-backup", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: collision)
        }
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        let modelFile = collision.appendingPathComponent("model.gguf")
        let unrelated = collision.appendingPathComponent("family-photos.txt")
        try "model".write(to: modelFile, atomically: true, encoding: .utf8)
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)
        let library = ModelLibrary(root: root)
        try await library.add(stubModel(
            id: "collision", primaryFile: modelFile,
            managedDirectory: collision, managedRoot: root
        ))

        try await library.remove(id: "collision")

        #expect(!FileManager.default.fileExists(atPath: modelFile.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: collision.path))
    }

    @Test func importedFileBelowRootDoesNotGrantDirectoryOwnership() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("user-files", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modelFile = directory.appendingPathComponent("model.gguf")
        let unrelated = directory.appendingPathComponent("notes.txt")
        try "model".write(to: modelFile, atomically: true, encoding: .utf8)
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)
        let library = ModelLibrary(root: root)
        try await library.add(stubModel(
            id: "import", primaryFile: modelFile, catalogID: nil
        ))

        try await library.remove(id: "import")

        #expect(!FileManager.default.fileExists(atPath: modelFile.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func symlinkEscapeFallsBackToDeletingOnlyRegisteredFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-\(UUID().uuidString)")
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let modelFile = link.appendingPathComponent("model.gguf")
        let unrelated = external.appendingPathComponent("keep.txt")
        try "model".write(to: modelFile, atomically: true, encoding: .utf8)
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)
        let library = ModelLibrary(root: root)
        try await library.add(stubModel(
            id: "symlink", primaryFile: modelFile,
            managedDirectory: link, managedRoot: root
        ))

        try await library.remove(id: "symlink")

        #expect(!FileManager.default.fileExists(atPath: external.appendingPathComponent("model.gguf").path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test func replacingTheOwnedRootWithASymlinkRevokesRecursiveDeletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-\(UUID().uuidString)")
        let movedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("moved-models-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: movedRoot)
        }
        let directory = root.appendingPathComponent("catalog/Q4", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modelFile = directory.appendingPathComponent("model.gguf")
        let unrelated = directory.appendingPathComponent("keep.txt")
        try "model".write(to: modelFile, atomically: true, encoding: .utf8)
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)

        let library = ModelLibrary(root: root)
        try await library.add(stubModel(
            id: "replaced-root", primaryFile: modelFile,
            managedDirectory: directory, managedRoot: root
        ))

        try FileManager.default.moveItem(at: root, to: movedRoot)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: movedRoot)
        try await library.remove(id: "replaced-root")

        #expect(!FileManager.default.fileExists(
            atPath: movedRoot.appendingPathComponent("catalog/Q4/model.gguf").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: movedRoot.appendingPathComponent("catalog/Q4/keep.txt").path
        ))
    }

    @Test func dotSegmentEscapeCannotAuthorizeRecursiveDeletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-\(UUID().uuidString)")
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: external)
        }
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let escapedFile = root.appendingPathComponent(
            "../\(external.lastPathComponent)/model.gguf"
        )
        let actualFile = external.appendingPathComponent("model.gguf")
        let unrelated = external.appendingPathComponent("keep.txt")
        try "model".write(to: actualFile, atomically: true, encoding: .utf8)
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)
        let library = ModelLibrary(root: root)
        try await library.add(stubModel(
            id: "dot-segment", primaryFile: escapedFile,
            managedDirectory: external, managedRoot: root
        ))

        try await library.remove(id: "dot-segment")

        #expect(!FileManager.default.fileExists(atPath: actualFile.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test func strictManagedDescendantStillRemovesItsWholeOwnedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("catalog/Q4", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modelFile = directory.appendingPathComponent("model.gguf")
        let companion = directory.appendingPathComponent("projector.gguf")
        try "model".write(to: modelFile, atomically: true, encoding: .utf8)
        try "companion".write(to: companion, atomically: true, encoding: .utf8)
        let library = ModelLibrary(root: root)
        try await library.add(stubModel(
            id: "managed", primaryFile: modelFile,
            managedDirectory: directory, managedRoot: root
        ))

        try await library.remove(id: "managed")

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func persistedOwnershipSurvivesChangingTheDownloadRoot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-\(UUID().uuidString)")
        let formerRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("former-root-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: formerRoot)
        }
        let library = ModelLibrary(root: root)
        await library.setDownloadRoot(formerRoot)
        let entry = ModelCatalog.qwen3_8B
        let directory = await library.directory(for: entry.id, quantization: .q4_K_M)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modelFile = directory.appendingPathComponent("model.gguf")
        try "model".write(to: modelFile, atomically: true, encoding: .utf8)
        let model = try await library.register(
            entry: entry, quantization: .q4_K_M, files: [modelFile], projector: nil
        )
        #expect(model.managedDirectory?.standardizedFileURL == directory.standardizedFileURL)
        #expect(model.managedRoot?.standardizedFileURL == formerRoot.standardizedFileURL)
        await library.setDownloadRoot(nil)

        try await library.remove(id: model.id)

        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func libraryRootItselfIsNeverRecursivelyDeleted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let modelFile = root.appendingPathComponent("model.gguf")
        let unrelated = root.appendingPathComponent("keep.txt")
        try "model".write(to: modelFile, atomically: true, encoding: .utf8)
        try "keep".write(to: unrelated, atomically: true, encoding: .utf8)
        let library = ModelLibrary(root: root)
        try await library.add(stubModel(
            id: "root-file", primaryFile: modelFile,
            managedDirectory: root, managedRoot: root
        ))

        try await library.remove(id: "root-file")

        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
