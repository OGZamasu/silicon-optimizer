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

    private func stubModel(id: String, primaryFile: URL) -> InstalledModel {
        InstalledModel(
            id: id, name: id, catalogID: id, quantization: .q4_K_M, format: .gguf,
            primaryFile: primaryFile, allFiles: [primaryFile], projectorFile: nil,
            sizeOnDisk: .zero, installedAt: Date(), shape: nil, capabilities: []
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

    @Test func managedModelIsPrunedOnceItsFileIsActuallyGone() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("silicon-test-root-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let managedFile = root.appendingPathComponent("model.gguf")
        try "stand-in".write(to: managedFile, atomically: true, encoding: .utf8)

        let library = ModelLibrary(root: root)
        try await library.load()
        try await library.add(stubModel(id: "managed-model", primaryFile: managedFile))

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
}
