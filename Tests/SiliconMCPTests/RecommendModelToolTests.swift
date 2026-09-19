import Foundation
import SiliconControl
import Testing
@testable import SiliconMCP

/// `recommend_model` once it knows what the model is for: the tool an agent sees, the query
/// it builds, and what it prints back.
@Suite("MCP recommend_model with a task")
struct RecommendModelToolTests {

    @Test func theToolAdvertisesAnOptionalTaskAndSaysWhatItBuys() throws {
        let tool = try #require(Tools.all.first { $0.name == "recommend_model" })
        #expect(tool.properties["task"] != nil)
        #expect(tool.properties["category"] != nil)
        // Optional: an agent that does not know the job still gets the old answer.
        #expect(tool.required.isEmpty)
        #expect(tool.description.contains("task"))
    }

    /// A job description travels in a POST body, so nothing about it has to survive a
    /// query string — no escaping, no `&` splitting the sentence in two, and nothing of the
    /// user's prose in a URL that ends up in a shell history or a proxy log.
    @Test func aTaskWithQuerySyntaxInItSurvivesTheBody() throws {
        let task = "C++ & Rust; a=b?c#d"
        let encoded = try JSONEncoder().encode(
            ControlAPI.RecommendRequest(category: "Coding", task: task)
        )
        let back = try JSONDecoder().decode(ControlAPI.RecommendRequest.self, from: encoded)
        #expect(back.task == task)
        #expect(back.category == "Coding")
    }

    /// The category still rides in a query string on the free GET, and still has to be
    /// escaped: "Small & Fast" is a real category name.
    @Test func aCategoryWithAnAmpersandInItSurvivesEscaping() throws {
        let escaped = try #require(
            "Small & Fast".addingPercentEncoding(
                withAllowedCharacters: Tools.queryValueCharacters
            )
        )
        for character in ["&", "+", "=", "?", "#"] {
            #expect(!escaped.contains(character), "a raw \(character) reached the query")
        }
        let components = try #require(
            URLComponents(string: "http://localhost/recommend?category=\(escaped)")
        )
        #expect(components.queryItems?.count == 1)
        #expect(components.queryItems?.first?.value == "Small & Fast")
    }

    @Test func aRankedAnswerPrintsTheTopThreeWithTheirReasons() {
        let model = ControlAPI.CatalogModel.recommendationFixture(
            id: "winner", reason: "needs vision; fits at Q4_K_M at ~28 tok/s",
            note: "Jev could not separate these for this job (confidence 0.18), so they "
                + "are ranked by how well they run here.",
            alternatives: [
                .recommendationFixture(
                    id: "second", reason: "needs vision; fits at Q6_K at ~12 tok/s"
                ),
                .recommendationFixture(
                    id: "third", reason: "needs vision; fits at Q8_0 at ~9 tok/s"
                ),
            ]
        )
        let printed = Tools.describeRecommendation(model)
        #expect(printed.contains("1. Winner [winner] — needs vision; fits at Q4_K_M at ~28 tok/s"))
        #expect(printed.contains("2. Second [second] — needs vision; fits at Q6_K at ~12 tok/s"))
        #expect(printed.contains("3. Third [third] — needs vision; fits at Q8_0 at ~9 tok/s"))
        // The winner is still printed in full underneath, so nothing an agent used to get
        // from this tool has gone away.
        #expect(printed.contains("Catalog id: winner"))
        #expect(printed.contains("Recommended for this Mac:"))
        // Why this list is this list, when that is not simply "Jev said so" — an agent that
        // reads it knows not to quote the order as a judgment about the models.
        #expect(printed.contains("Note: Jev could not separate these"))
    }

    @Test func withoutATaskItPrintsExactlyWhatItPrintedBefore() {
        var plain = ControlAPI.CatalogModel.recommendationFixture(id: "winner", reason: nil)
        plain.alternatives = nil
        #expect(Tools.describeRecommendation(plain) == Tools.describe(plain))
        #expect(!Tools.describeRecommendation(plain).contains("Best for this job"))
    }
}

extension ControlAPI.CatalogModel {
    static func recommendationFixture(
        id: String, reason: String?, note: String? = nil,
        alternatives: [ControlAPI.CatalogModel]? = nil
    ) -> Self {
        .init(
            id: id, name: id.capitalized, author: "Fixture", license: "Apache-2.0",
            summary: "A model.", category: "Vision", parameters: "8B",
            activeParameters: nil, isMoE: false, capabilities: ["Vision"], rating: 4,
            maxContext: 131_072, quantizations: ["Q4_K_M"],
            recommendation: .init(
                quantization: "Q4_K_M", contextLength: 32_768, expertSlots: nil,
                estimatedGenerationTokensPerSecond: 28, estimatedPromptTokensPerSecond: 600,
                downloadBytes: 5_000_000_000,
                plan: .init(
                    verdict: "fits", residentBytes: 6_000_000_000,
                    budgetBytes: 29_200_000_000, weightsBytes: 5_000_000_000,
                    expertsBytes: 0, kvCacheBytes: 900_000_000, computeBytes: 100_000_000,
                    streamedFromDiskBytes: 0, suggestions: [], notes: []
                ),
                rationale: "Fits comfortably."
            ),
            reason: reason, note: note, alternatives: alternatives
        )
    }
}
