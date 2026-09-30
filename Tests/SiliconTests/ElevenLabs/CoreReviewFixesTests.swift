import Foundation
import Testing
@testable import SiliconElevenLabs

/// What the core's review found, one test per finding, each written to fail without its fix.
@Suite("ElevenLabs core — review fixes")
struct CoreReviewFixesTests {

    static let key = CoreClientTests.key

    // MARK: - The key never appears in a dump

    @Test func aRequestDumpedOrReflectedNeverShowsItsKey() throws {
        let request = ElevenLabsRequest(
            operationID: "get_user_info", method: "GET",
            url: try #require(URL(string: "https://api.elevenlabs.io/v1/user")),
            headers: ["xi-api-key": Self.key, "Accept": "application/json"],
            body: .none, timeout: 10, responseHandling: .memory(limit: 1_000)
        )
        var dumped = ""
        dump(request, to: &dumped)
        #expect(!dumped.contains(Self.key))
        #expect(!dumped.contains("xi-api-key"))
        #expect(!String(reflecting: request).contains(Self.key))
        #expect(!"\(request)".contains(Self.key))
        // What is reflected is still useful.
        #expect(dumped.contains("get_user_info"))
        #expect(dumped.contains("https://api.elevenlabs.io/v1/user"))
    }
}
