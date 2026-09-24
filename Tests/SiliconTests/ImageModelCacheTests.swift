import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconRuntime
@testable import SiliconUI

/// With a model library set, MFLUX runs with `HF_HOME` in the library's engine cache. The
/// image-model installer has to download, check and remove in that same cache: when it used
/// `~/.cache` instead, "Download" put 15 GB on the startup disk, the first render fetched it
/// all again into the library, and Remove deleted the copy nothing read.
@Suite("Image model weights live where MFLUX reads them")
@MainActor
struct ImageModelCacheTests {

    private func library() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// What `hf download` leaves for `entry` under a hub cache: a snapshot holding a
    /// safetensors file in every component directory.
    private func placeWeights(for entry: DiffusionEntry, hub: URL) throws -> URL {
        let repository = hub.appendingPathComponent(
            "models--" + entry.repository.replacingOccurrences(of: "/", with: "--"),
            isDirectory: true
        )
        let snapshot = repository.appendingPathComponent("snapshots/0123abcd", isDirectory: true)
        for component in entry.componentDirectories {
            let directory = snapshot.appendingPathComponent(component, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([0]).write(to: directory.appendingPathComponent("weights.safetensors"))
        }
        return repository
    }

    @Test func theDownloaderIsPointedAtTheCacheMFluxReads() throws {
        let engineCache = try library().appendingPathComponent("Engine Cache", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: engineCache.deletingLastPathComponent()) }
        let installer = DiffusionInstaller(
            executable: URL(fileURLWithPath: "/usr/bin/true"), hubCache: engineCache
        )
        let downloader = installer.processEnvironment(base: [
            "HF_HUB_CACHE": "/somewhere/else/hub",
        ])
        let renderer = MFluxRuntime.childEnvironment(huggingFaceToken: nil, hubCache: engineCache)
        #expect(downloader["HF_HOME"] == renderer["HF_HOME"])
        #expect(downloader["HF_HUB_CACHE"] == engineCache.appendingPathComponent("hub").path,
                "an inherited hub cache would send the download elsewhere")
        #expect(DiffusionInstaller.cacheDirectory(
            for: DiffusionCatalog.flux2Klein4B.repository, hubCache: engineCache
        ).path.hasPrefix(engineCache.appendingPathComponent("hub").path + "/"))
    }

    /// A catalog entry under a repository name nobody has, so that removing it — even through
    /// a build that still looks in `~/.cache`, which may be a link into a real library — can
    /// never reach anyone's actual weights.
    private func throwawayEntry() -> DiffusionEntry {
        let real = DiffusionCatalog.flux2Klein4B
        return DiffusionEntry(
            id: "cache-test-\(UUID().uuidString)", name: real.name, author: real.author,
            license: real.license, summary: real.summary, shape: real.shape,
            repository: "silicon-optimizer-tests/cache-\(UUID().uuidString)",
            quantizations: real.quantizations, rating: real.rating,
            downloadPatterns: real.downloadPatterns,
            componentDirectories: real.componentDirectories
        )
    }

    @Test func installedChecksAndRemovalUseTheLibrarysEngineCache() throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = Settings()
        settings.modelLibraryDirectory = root.path
        let model = AppModel(settings: settings)
        let hub = try #require(settings.resolvedEngineCacheDirectory)
            .appendingPathComponent("hub", isDirectory: true)
        let entry = throwawayEntry()
        let repository = try placeWeights(for: entry, hub: hub)

        #expect(model.isImageModelInstalled(entry), "weights in the engine cache read as missing")
        #expect(model.installedImageModelSize(entry) == DiffusionInstaller.installedSize(
            entry.repository, hubCache: settings.resolvedEngineCacheDirectory
        ))
        model.uninstallImageModel(entry)
        #expect(!FileManager.default.fileExists(atPath: repository.path),
                "Remove left the copy MFLUX reads")
        #expect(!model.isImageModelInstalled(entry))
    }

    /// Read-only: the router's candidates come from the catalog, so this one uses a real entry
    /// and only ever looks.
    @Test func theRouterSeesWeightsInTheEngineCache() throws {
        let root = try library()
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = Settings()
        settings.modelLibraryDirectory = root.path
        let model = AppModel(settings: settings)
        let hub = try #require(settings.resolvedEngineCacheDirectory)
            .appendingPathComponent("hub", isDirectory: true)
        let entry = DiffusionCatalog.flux2Klein4B
        _ = try placeWeights(for: entry, hub: hub)
        #expect(model.imageRoutingCandidates().first { $0.id == entry.id }?.isReady == true,
                "the router offered it as a download")
    }
}
