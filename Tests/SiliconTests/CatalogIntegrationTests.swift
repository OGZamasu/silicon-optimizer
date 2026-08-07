import Foundation
import Testing
@testable import SiliconCatalog
@testable import SiliconCore

/// Checks every catalog entry against the live Hugging Face API.
///
/// The bundled catalog is a set of claims about repositories the project does not control:
/// that they exist, that they carry the quantizations advertised, and that vision entries ship
/// a projector. Any of those can rot without warning, and the failure lands on a user as a
/// download that 404s.
///
/// Network-dependent, so it is opt-in rather than part of the default run:
///
///     SILICON_NETWORK_TESTS=1 swift test --filter CatalogIntegration
@Suite("Catalog integration", .enabled(if: ProcessInfo.processInfo.environment["SILICON_NETWORK_TESTS"] == "1"))
struct CatalogIntegrationTests {

    private var resolver: ModelResolver { ModelResolver(client: HuggingFaceClient()) }

    @Test(arguments: ModelCatalog.all)
    func everyEntryResolvesItsRecommendedQuantization(entry: ModelEntry) async throws {
        // The quantization a user is most likely to land on.
        let quantization = entry.variants.first(where: { $0.quantization == .q4_K_M })?.quantization
            ?? entry.variants[0].quantization

        let resolution = try await resolver.resolve(entry: entry, quantization: quantization)

        #expect(!resolution.files.isEmpty, "\(entry.id): resolved to no files")
        #expect(resolution.totalSize > .mib(100), "\(entry.id): resolved size implausibly small")

        // Vision models are useless without their projector.
        if entry.capabilities.contains(.vision) {
            #expect(resolution.projector != nil, "\(entry.id): no mmproj found")
        }

        // Catalog size estimates drive the disk-space check, so they must not be wildly wrong.
        if let declared = entry.variant(for: quantization)?.downloadSize, declared > .zero {
            let ratio = Double(resolution.totalSize.rawValue) / Double(declared.rawValue)
            #expect(ratio > 0.6 && ratio < 1.6,
                    "\(entry.id): declared \(declared.formatted), actual \(resolution.totalSize.formatted)")
        }
    }

    /// GLM-4.5-Air genuinely ships split weights, in a per-quantization subdirectory:
    /// `Q3_K_M/GLM-4.5-Air-Q3_K_M-00001-of-00002.gguf`. It is the only catalog entry that
    /// exercises sharding, so it is named explicitly rather than left to a `guard` that turns
    /// the whole test into a no-op the day a publisher stops splitting a file.
    @Test func shardedModelResolvesAllPartsInOrder() async throws {
        let entry = try #require(ModelCatalog.entry(id: "glm-4.5-air"))
        let quantization = entry.variants.first!.quantization
        let resolution = try await resolver.resolve(entry: entry, quantization: quantization)

        #expect(resolution.isSharded, "GLM-4.5-Air should resolve to multiple shards")
        #expect(resolution.files.count >= 2)

        let paths = resolution.files.map(\.path)
        // Shards must come back in ascending order — llama.cpp is handed the head and walks
        // the rest itself, so a head that is not 00001 loads a truncated model.
        #expect(paths == paths.sorted(), "shards out of order: \(paths)")
        #expect(paths[0].contains("00001"), "head shard is \(paths[0])")

        // Sizing must span every shard, not just the head.
        let headSize = resolution.files[0].size
        #expect(resolution.totalSize > headSize, "total size ignored the trailing shards")

        // Every shard must belong to the same set.
        let totals = Set(paths.compactMap { path -> String? in
            guard let range = path.range(of: #"of-\d{5}"#, options: .regularExpression)
            else { return nil }
            return String(path[range])
        })
        #expect(totals.count == 1, "mixed shard sets \(totals)")
    }

    /// Some repositories ship a speculative-decoding draft model beside the real one. Asking for
    /// a quantization the draft also carries must not return the draft.
    @Test(arguments: ["gpt-oss-20b", "gpt-oss-120b"])
    func draftModelsAreNotMistakenForTheRealOne(modelID: String) async throws {
        let entry = try #require(ModelCatalog.entry(id: modelID))
        let resolution = try await resolver.resolve(entry: entry, quantization: .mxfp4)

        let head = try #require(resolution.files.first)
        #expect(!ModelResolver.isCompanionFile(head.path), "resolved a companion file: \(head.path)")
        // The real weights dwarf any draft in these repositories.
        #expect(head.size > .gib(9), "resolved \(head.path) at \(head.size.formatted)")
    }
}
