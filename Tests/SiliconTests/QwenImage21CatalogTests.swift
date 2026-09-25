import CryptoKit
import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconControl
@testable import SiliconRuntime
@testable import SiliconUI

/// Qwen-Image 2.1 and Pruna's few-step adapters: the catalogue entries, their pins, the
/// schedules, and the rule that an adapter installs its base and never removes it.
///
/// Hermetic: every file written, fetched or removed here is under a temporary directory this
/// suite made, proved scratch before anything is armed to delete from it. The fetches run the
/// real digest-checking commands against a `file://` "server" in that same directory.
@Suite("Qwen-Image 2.1 catalogue", .redirectedConversationStore)
@MainActor
struct QwenImage21CatalogTests {

    static let base = DiffusionCatalog.qwenImage21
    static let pruna = DiffusionCatalog.qwenImage21Pruna
    static var adapter: DiffusionAdapter { pruna.adapter! }

    // MARK: - Entries and pins

    /// The node keys image jobs on these exact strings, so they are part of the contract.
    @Test func theIDsAreTheOnesTheNodeUses() {
        #expect(Self.base.id == "qwen-image-2.1")
        #expect(Self.pruna.id == "qwen-image-2.1-pruna")
        #expect(DiffusionCatalog.entry(id: "qwen-image-2.1") == Self.base)
        #expect(DiffusionCatalog.entry(id: "qwen-image-2.1-pruna") == Self.pruna)
    }

    @Test func bothArePinnedToTheReviewedRevisions() {
        #expect(Self.base.repository == "Qwen/Qwen-Image-2.1")
        #expect(Self.base.revision == "790c92633540aa0cb11d9abf19eb46d861714758")
        #expect(Self.base.adapter == nil && Self.base.baseEntryID == nil)

        #expect(Self.pruna.repository == "PrunaAI/Pruna-Qwen-Image-2.1")
        #expect(Self.pruna.baseEntryID == Self.base.id)
        #expect(Self.pruna.weightsRepository == Self.base.repository)
        #expect(Self.pruna.revision == Self.base.revision)
        #expect(Self.adapter.repository == Self.pruna.repository)
        #expect(Self.adapter.revision == "113e63bb993001b3411eb3470b84fc444040cd7e")
        #expect(Self.adapter.scale == 2.0, "lora_alpha 128 / r 64")
    }

    /// Research licence, shown as it is on every entry; neither repository is gated.
    @Test func bothCarryTheQwenResearchLicence() {
        for entry in [Self.base, Self.pruna] {
            #expect(entry.license == "Qwen RESEARCH LICENSE AGREEMENT (research, non-commercial)")
            #expect(!entry.isGated)
            #expect(entry.summary.contains("not for commercial use"))
        }
    }

    /// What `mflux-generate-qwen-2.1` reads, from 0.20.0's `Qwen21WeightDefinition` — and the
    /// tokenizer is under `processor/`, which every older family's list would miss.
    @Test func theDownloadIsWhatTheQwen21WeightDefinitionReads() {
        let expected = [
            "vae/*.safetensors", "vae/*.json",
            "transformer/*.safetensors", "transformer/*.json",
            "text_encoder/*.safetensors", "text_encoder/*.json",
            "processor/**",
        ]
        #expect(Self.base.downloadPatterns == expected)
        #expect(Self.pruna.downloadPatterns == expected)
        #expect(!expected.contains { $0.hasPrefix("scheduler/") || $0.hasPrefix("assets/") })
    }

    /// Both fetch the base repository at its commit; the adapter entry's own repository is
    /// never handed to `hf`.
    @Test func bothFetchTheBaseWeightsAtTheirCommit() {
        let installer = DiffusionInstaller(
            executable: URL(fileURLWithPath: "/usr/bin/true"), home: nil,
            hub: FileManager.default.temporaryDirectory.appendingPathComponent("hub")
        )
        for entry in [Self.base, Self.pruna] {
            let arguments = installer.downloadArguments(entry)
            #expect(Array(arguments.prefix(2)) == ["download", "Qwen/Qwen-Image-2.1"])
            let index = arguments.firstIndex(of: "--revision")
            #expect(index.map { arguments[$0 + 1] } == DiffusionCatalog.qwenImage21Revision)
            #expect(!arguments.contains("PrunaAI/Pruna-Qwen-Image-2.1"))
        }
        // The older entries still follow `main`.
        #expect(!installer.downloadArguments(DiffusionCatalog.qwenImage).contains("--revision"))
    }

    /// The manifest the download is checked against names the same revision and files as the
    /// catalogue, with the sizes and digests the Hub publishes for them.
    @Test func theReviewedManifestMatchesTheCatalogue() throws {
        let manifest = try PinnedInstall.HubModel.load(
            Self.adapter.repository, from: PinnedInstall.defaultLockRoot()
        )
        #expect(manifest.revision == Self.adapter.revision)
        let byPath = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0) })
        #expect(Set(byPath.keys) == Set(Self.adapter.variants.map(\.file)))
        let eight = try #require(byPath["p_qwen_image_2.1_8step_v0.1.safetensors"])
        #expect(eight.size == 335_606_104)
        #expect(eight.sha256 == "f0865d68b02511a3a0ed232d9d1aa99cac3a94166f574b38bcbab1a7a297bb15")
        let five = try #require(byPath["p_qwen_image_2.1_5step_v0.1.safetensors"])
        #expect(five.size == 335_606_144)
        #expect(five.sha256 == "021a6228a0fcd217275190b89072416a2f28548e8e18fe049531dc9b77ef89bd")
    }

    // MARK: - Schedules

    /// Exactly the model card's lists, one sigma per step; the sampler appends the 0.
    @Test func eachAdapterCarriesItsOwnSigmaSchedule() throws {
        let eight = try #require(Self.adapter.variant(steps: 8))
        #expect(eight.file == "p_qwen_image_2.1_8step_v0.1.safetensors")
        #expect(eight.sigmas == [1.0, 14.0 / 15.0, 6.0 / 7.0, 10.0 / 13.0, 2.0 / 3.0,
                                 6.0 / 11.0, 0.4, 2.0 / 9.0])
        // σ = 2t / (1 + t) on evenly spaced t — the card's own derivation of the 8-step list.
        for (index, sigma) in eight.sigmas.enumerated() {
            let t = 1.0 - Double(index) / 8.0
            #expect(abs(sigma - 2 * t / (1 + t)) < 1e-12, "step \(index)")
        }

        let five = try #require(Self.adapter.variant(steps: 5))
        #expect(five.file == "p_qwen_image_2.1_5step_v0.1.safetensors")
        #expect(five.sigmas == [1.0, 0.94, 6.0 / 7.0, 2.0 / 3.0, 0.4])
        #expect(five.label.contains("lower quality"))

        for variant in Self.adapter.variants {
            #expect(variant.sigmas.first == 1.0)
            #expect(zip(variant.sigmas, variant.sigmas.dropFirst()).allSatisfy { $0 > $1 })
            #expect(variant.sigmas.allSatisfy { $0 > 0 && $0 <= 1 })
        }
        #expect(Self.adapter.defaultVariant == eight, "the 8-step adapter is the default")
    }

    /// Steps are restricted to what an adapter was trained for; anything else lands on the
    /// nearest, the larger of a tie.
    @Test func stepsAreRestrictedToTheAdaptersSchedules() {
        #expect(Self.pruna.stepChoices == [8, 5])
        #expect(Self.pruna.shape.defaultSteps == 8)
        #expect(Self.pruna.normalizedSteps(8) == 8)
        #expect(Self.pruna.normalizedSteps(5) == 5)
        #expect(Self.pruna.normalizedSteps(40) == 8)
        #expect(Self.pruna.normalizedSteps(7) == 8)
        #expect(Self.pruna.normalizedSteps(6) == 5)
        #expect(Self.pruna.normalizedSteps(1) == 5)

        #expect(Self.base.stepChoices == nil)
        #expect(Self.base.shape.defaultSteps == 40)
        #expect(Self.base.normalizedSteps(13) == 13)
    }

    // MARK: - Installed, and removal

    /// Stops the test unless `url` is inside the temporary directory. Nothing here writes to,
    /// or lets the code under test remove from, a hub until it is proved scratch.
    private func requireScratch(_ url: URL) throws {
        let scratch = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        try #require(url.resolvingSymlinksInPath().path.hasPrefix(scratch),
                     "\(url.path) is not a scratch directory; refusing to write to or remove it")
    }

    private func scratchHub() throws -> URL {
        let hub = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen21-hub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: hub, withIntermediateDirectories: true)
        try requireScratch(hub)
        return hub
    }

    /// What `hf download --revision` leaves for the base: a safetensors file in every
    /// component directory of `snapshots/<revision>`.
    private func placeBaseWeights(hub: URL, revision: String = DiffusionCatalog.qwenImage21Revision) throws {
        let snapshot = DiffusionInstaller.cacheDirectory(for: Self.base.repository, hub: hub)
            .appendingPathComponent("snapshots/\(revision)", isDirectory: true)
        for component in Self.base.componentDirectories {
            let directory = snapshot.appendingPathComponent(component, isDirectory: true)
            if component == "vae" {
                // One file and no index, as the real VAE is.
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try tinySafetensors().write(to: directory.appendingPathComponent("diffusion_pytorch_model.safetensors"))
            } else {
                try placeShardedComponent(at: directory, shards: ["model-00001-of-00002.safetensors",
                                                                  "model-00002-of-00002.safetensors"])
            }
        }
    }

    private func placeAdapter(_ variant: DiffusionAdapter.Variant, hub: URL) throws {
        let file = DiffusionInstaller.adapterFile(variant, of: Self.adapter, hub: hub)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("adapter".utf8).write(to: file)
    }

    @Test func theAdapterIsInstalledOnlyWithItsBase() throws {
        let hub = try scratchHub()
        defer { removeTemporaryDirectory(hub) }

        #expect(!DiffusionInstaller.isInstalled(Self.base, hub: hub))
        #expect(!DiffusionInstaller.isInstalled(Self.pruna, hub: hub))

        // The adapter file alone runs nothing.
        try placeAdapter(Self.adapter.defaultVariant, hub: hub)
        #expect(!DiffusionInstaller.isInstalled(Self.pruna, hub: hub))

        try placeBaseWeights(hub: hub)
        #expect(DiffusionInstaller.isInstalled(Self.base, hub: hub))
        #expect(DiffusionInstaller.isInstalled(Self.pruna, hub: hub))

        // The base alone is the base; the few-step entry needs its default adapter too, and
        // the 5-step file does not stand in for it.
        let adapterCache = DiffusionInstaller.cacheDirectory(for: Self.adapter.repository, hub: hub)
        try requireScratch(adapterCache)
        try FileManager.default.removeItem(at: adapterCache)
        try placeAdapter(Self.adapter.variants[1], hub: hub)
        #expect(DiffusionInstaller.isInstalled(Self.base, hub: hub))
        #expect(!DiffusionInstaller.isInstalled(Self.pruna, hub: hub))
    }

    /// A pinned entry is read from its own revision's snapshot, not whichever is newest.
    @Test func weightsAtAnotherRevisionAreNotTheInstalledOnes() throws {
        let hub = try scratchHub()
        defer { removeTemporaryDirectory(hub) }
        try placeBaseWeights(hub: hub, revision: String(repeating: "e5", count: 20))
        #expect(!DiffusionInstaller.isInstalled(Self.base, hub: hub))
        #expect(DiffusionInstaller.weightsSnapshot(for: Self.base, hub: hub) == nil)

        try placeBaseWeights(hub: hub)
        #expect(DiffusionInstaller.weightsSnapshot(for: Self.pruna, hub: hub)?.lastPathComponent
                == DiffusionCatalog.qwenImage21Revision)
    }

    /// The runner reads the pinned snapshot's path directly, past mflux's own completeness
    /// check, so an interrupted download must not read as installed: every shard the index
    /// names has to be there, and as long as its header says.
    @Test func anInterruptedDownloadIsNotInstalled() throws {
        let hub = try scratchHub()
        defer { removeTemporaryDirectory(hub) }
        try placeBaseWeights(hub: hub)
        try placeAdapter(Self.adapter.defaultVariant, hub: hub)
        #expect(DiffusionInstaller.isInstalled(Self.base, hub: hub))
        #expect(DiffusionInstaller.isInstalled(Self.pruna, hub: hub))

        let transformer = try #require(DiffusionInstaller.weightsSnapshot(for: Self.base, hub: hub))
            .appendingPathComponent("transformer")
        let second = transformer.appendingPathComponent("model-00002-of-00002.safetensors")
        let whole = try Data(contentsOf: second)

        // A shard the index names is missing — the download stopped before it.
        try requireScratch(second)
        try FileManager.default.removeItem(at: second)
        #expect(!DiffusionInstaller.isInstalled(Self.base, hub: hub))
        #expect(!DiffusionInstaller.isInstalled(Self.pruna, hub: hub))

        // Present but short of what its header says.
        try whole.prefix(whole.count - 2).write(to: second)
        #expect(!DiffusionInstaller.isInstalled(Self.base, hub: hub))

        // Not even a header.
        try Data([0]).write(to: second)
        #expect(!DiffusionInstaller.isInstalled(Self.base, hub: hub))

        // Whole again.
        try whole.write(to: second)
        #expect(DiffusionInstaller.isInstalled(Self.base, hub: hub))

        // An index that names nothing is no index of a complete download.
        try Data("{\"weight_map\": {}}".utf8).write(
            to: transformer.appendingPathComponent("model.safetensors.index.json")
        )
        #expect(!DiffusionInstaller.isInstalled(Self.base, hub: hub))
    }

    /// Removing the base while the few-step entry is installed says what it will stop.
    @Test func removingTheBaseSaysItStopsTheFewStepEntry() throws {
        let model = AppModel(
            videoQueue: VideoBatchQueue(storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("scratch-video-queue-\(UUID().uuidString).json")),
            settings: .init()
        )
        let hub = model.imageModelHub
        try requireScratch(hub)
        defer { removeTemporaryDirectory(hub) }

        try placeBaseWeights(hub: hub)
        #expect(model.imageRemovalWarning(for: Self.base) == nil, "nothing else runs on it yet")
        try placeAdapter(Self.adapter.defaultVariant, hub: hub)
        let warning = try #require(model.imageRemovalWarning(for: Self.base))
        #expect(warning.contains(Self.pruna.name))
        #expect(warning.contains("will not run"))
        // Removing the adapter stops nothing else.
        #expect(model.imageRemovalWarning(for: Self.pruna) == nil)
        #expect(model.imageRemovalWarning(for: DiffusionCatalog.flux2Klein4B) == nil)
    }

    @Test func removingTheAdapterNamesOnlyTheAdaptersFiles() throws {
        let hub = FileManager.default.temporaryDirectory.appendingPathComponent("hub")
        let targets = DiffusionInstaller.removalTargets(for: Self.pruna, hub: hub)
        #expect(targets == [DiffusionInstaller.cacheDirectory(for: Self.adapter.repository, hub: hub)])
        #expect(!targets.contains(DiffusionInstaller.cacheDirectory(for: Self.base.repository, hub: hub)))
    }

    /// Through the app model, in its own scratch hub: removing the few-step entry takes the
    /// adapter and leaves Qwen-Image 2.1 installed and whole.
    @Test func uninstallingTheAdapterLeavesTheBaseInstalled() throws {
        let model = AppModel(
            videoQueue: VideoBatchQueue(storeURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("scratch-video-queue-\(UUID().uuidString).json")),
            settings: .init()
        )
        let hub = model.imageModelHub
        // Proved scratch before anything is written there or a removal is armed.
        try requireScratch(hub)
        defer { removeTemporaryDirectory(hub) }

        try placeBaseWeights(hub: hub)
        try placeAdapter(Self.adapter.defaultVariant, hub: hub)
        #expect(model.isImageModelInstalled(Self.pruna))

        model.uninstallImageModel(Self.pruna)
        #expect(!model.isImageModelInstalled(Self.pruna))
        #expect(!FileManager.default.fileExists(
            atPath: DiffusionInstaller.cacheDirectory(for: Self.adapter.repository, hub: hub).path
        ))
        #expect(model.isImageModelInstalled(Self.base), "the base weights must survive")

        // And the other way round the base goes, taking the few-step entry's ability to run
        // with it but not its files.
        try placeAdapter(Self.adapter.defaultVariant, hub: hub)
        model.uninstallImageModel(Self.base)
        #expect(!model.isImageModelInstalled(Self.base))
        #expect(!model.isImageModelInstalled(Self.pruna))
        #expect(DiffusionInstaller.isAdapterInPlace(Self.adapter.defaultVariant, of: Self.adapter, hub: hub))
    }

    // MARK: - Fetching the adapter file

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A reviewed manifest for the two adapter files and a `file://` server holding `served`,
    /// both in `root`.
    private func stage(
        root: URL, served: [String: Data], reviewed: [String: Data], revision: String? = nil
    ) throws -> (locks: URL, server: URL) {
        let revision = revision ?? Self.adapter.revision
        let server = root.appendingPathComponent("server"), locks = root.appendingPathComponent("locks")
        for (path, data) in served {
            let url = server.appendingPathComponent(
                "\(Self.adapter.repository)/resolve/\(Self.adapter.revision)/\(path)"
            )
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        let model = PinnedInstall.HubModel(
            repository: Self.adapter.repository, revision: revision,
            files: reviewed.sorted { $0.key < $1.key }.map {
                .init(path: $0.key, sha256: Self.sha256($0.value), size: Int64($0.value.count))
            }
        )
        let manifest = PinnedInstall.HubModel.manifest(Self.adapter.repository, in: locks)
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(model).write(to: manifest)
        return (locks, server)
    }

    /// Installing fetches the one default file, checked; the other schedule's file stays on
    /// the server until it is chosen.
    @Test func installingFetchesOnlyTheDefaultAdapterFile() async throws {
        let root = try scratchHub()
        defer { removeTemporaryDirectory(root) }
        let eight = Data("eight-step adapter".utf8), five = Data("five-step adapter".utf8)
        let files = [Self.adapter.variants[0].file: eight, Self.adapter.variants[1].file: five]
        let (locks, server) = try stage(root: root, served: files, reviewed: files)
        let hub = root.appendingPathComponent("hub")
        let fetcher = DiffusionAdapterFiles(locks: locks, hub: hub, server: server, protocols: "=file")

        try await fetcher.prepare(Self.adapter.defaultVariant, of: Self.adapter)
        #expect(fetcher.isInPlace(Self.adapter.variants[0], of: Self.adapter))
        #expect(!fetcher.isInPlace(Self.adapter.variants[1], of: Self.adapter))
        #expect(try Data(contentsOf: fetcher.file(Self.adapter.variants[0], of: Self.adapter)) == eight)
        #expect(try fetcher.sha256(Self.adapter.variants[0], of: Self.adapter) == Self.sha256(eight))

        // Chosen later, the 5-step file is fetched the same way.
        try await fetcher.prepare(Self.adapter.variants[1], of: Self.adapter)
        #expect(try Data(contentsOf: fetcher.file(Self.adapter.variants[1], of: Self.adapter)) == five)
    }

    /// A file that is not the reviewed one is discarded, and nothing is left in place.
    @Test func aChangedAdapterFileIsRefused() async throws {
        let root = try scratchHub()
        defer { removeTemporaryDirectory(root) }
        let file = Self.adapter.defaultVariant.file
        let (locks, server) = try stage(
            root: root, served: [file: Data("someone else's adapter".utf8)],
            reviewed: [file: Data("the reviewed adapter".utf8)]
        )
        let hub = root.appendingPathComponent("hub")
        let fetcher = DiffusionAdapterFiles(locks: locks, hub: hub, server: server, protocols: "=file")
        await #expect(throws: DiffusionAdapterFiles.Failure.self) {
            try await fetcher.prepare(Self.adapter.defaultVariant, of: Self.adapter)
        }
        #expect(!fetcher.isInPlace(Self.adapter.defaultVariant, of: Self.adapter))
    }

    /// A manifest for another revision, or one that does not list the file, is no review of
    /// the file the catalogue names.
    @Test func anUnreviewedRevisionOrFileIsNotFetched() throws {
        let root = try scratchHub()
        defer { removeTemporaryDirectory(root) }
        let file = Self.adapter.defaultVariant.file
        let (locks, server) = try stage(
            root: root, served: [:], reviewed: [file: Data("x".utf8)],
            revision: String(repeating: "f6", count: 20)
        )
        let hub = root.appendingPathComponent("hub")
        let fetcher = DiffusionAdapterFiles(locks: locks, hub: hub, server: server, protocols: "=file")
        #expect(throws: DiffusionAdapterFiles.Failure.self) {
            try fetcher.fetchCommands(Self.adapter.defaultVariant, of: Self.adapter)
        }
        let other = root.appendingPathComponent("other")
        let (otherLocks, _) = try stage(root: other, served: [:], reviewed: ["unrelated.safetensors": Data("x".utf8)])
        let narrow = DiffusionAdapterFiles(locks: otherLocks, hub: hub, server: server, protocols: "=file")
        #expect(throws: DiffusionAdapterFiles.Failure.self) {
            try narrow.pinned(Self.adapter.defaultVariant, of: Self.adapter)
        }
    }
}
