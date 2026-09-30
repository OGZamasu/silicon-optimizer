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

    // MARK: - Dot segments

    @Test func aPathValueOfDotsIsRefusedBeforeAnythingIsSent() async throws {
        for dots in [".", ".."] {
            let rig = CoreClientTests.Rig(replies: [.json([:])])
            defer { rig.cleanUp() }
            do {
                _ = try await rig.client.call("delete_sample", arguments: [
                    "voice_id": "voice-1", "sample_id": .string(dots),
                ])
                Issue.record("a path value of \(dots) was accepted")
            } catch ElevenLabsError.invalidArguments(let problems) {
                #expect(problems.contains { $0.contains("sample_id") && $0.contains("\"..\"") })
            }
            #expect(rig.transport.requests.isEmpty)
        }
    }

    @Test func ordinaryPathValuesContainingDotsStillGoThrough() async throws {
        let rig = CoreClientTests.Rig(replies: [.json([:])])
        defer { rig.cleanUp() }
        _ = try await rig.client.call("delete_sample", arguments: [
            "voice_id": "voice.1", "sample_id": "..hidden",
        ])
        let url = try #require(rig.transport.requests.first?.url)
        #expect(url.absoluteString == "https://api.elevenlabs.io/v1/voices/voice.1/samples/..hidden")
    }
}
