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
        let hub = HuggingFaceHub.directory(home: engineCache)
        let installer = DiffusionInstaller(
            executable: URL(fileURLWithPath: "/usr/bin/true"), home: engineCache, hub: hub
        )
        let downloader = installer.processEnvironment(base: [
            "HF_HUB_CACHE": "/somewhere/else/hub",
        ])
        let renderer = MFluxRuntime.childEnvironment(huggingFaceToken: nil, hubCache: engineCache)
        #expect(downloader["HF_HOME"] == renderer["HF_HOME"])
        #expect(downloader["HF_HUB_CACHE"] == hub.path,
                "an inherited hub cache would send the download elsewhere")
        #expect(renderer["HF_HUB_CACHE"] == hub.path,
                "an inherited hub cache would have MFLUX read somewhere else")
        #expect(hub.path == engineCache.appendingPathComponent("hub").path)
        #expect(DiffusionInstaller.cacheDirectory(
            for: DiffusionCatalog.flux2Klein4B.repository, hub: hub
        ).path.hasPrefix(hub.path + "/"))
    }

    /// With no library the child keeps the app's own `HF_HOME`, but the download is still told
    /// the hub it will be checked in.
    @Test func withoutALibraryTheDownloadStillGoesWhereItIsChecked() throws {
        let hub = try library().appendingPathComponent("hub", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: hub.deletingLastPathComponent()) }
        let installer = DiffusionInstaller(
            executable: URL(fileURLWithPath: "/usr/bin/true"), home: nil, hub: hub
        )
        let environment = installer.processEnvironment(base: ["HF_HOME": "/inherited"])
        #expect(environment["HF_HOME"] == "/inherited")
        #expect(environment["HF_HUB_CACHE"] == hub.path)
    }

    /// Tests build `AppModel(settings: .init())`, with no library. Such a model must not resolve
    /// the real `~/.cache/huggingface` — a link into a real model library on some Macs — for
    /// anything, least of all a removal: it gets a scratch hub of its own.
    @Test func aModelWithInjectedSettingsNeverResolvesTheRealCache() throws {
        let model = AppModel(settings: .init())
        defer { try? FileManager.default.removeItem(at: model.fallbackHuggingFaceHub) }
        let scratch = FileManager.default.temporaryDirectory.standardizedFileURL.path + "/"
        #expect(model.imageModelHub.standardizedFileURL.path.hasPrefix(scratch))
        #expect(model.imageModelHub != HuggingFaceHub.directory(home: nil))

        let entry = throwawayEntry()
        let repository = try placeWeights(for: entry, hub: model.imageModelHub)
        #expect(model.isImageModelInstalled(entry))
        model.uninstallImageModel(entry)
        #expect(!FileManager.default.fileExists(atPath: repository.path))
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
            entry.repository, hub: hub
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
