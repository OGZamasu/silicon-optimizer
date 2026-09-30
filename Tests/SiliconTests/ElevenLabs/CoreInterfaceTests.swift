import Foundation
import Testing
import SiliconElevenLabs
@testable import SiliconUI

/// The seams every other ElevenLabs builder codes against: the test doubles behave, old
/// settings still load, and an app model built for a test cannot reach anything real.
@Suite("ElevenLabs core interface")
struct CoreInterfaceTests {

    @Test func jsonValueRoundTripsWithSortedKeysAndWholeNumbers() throws {
        let value: JSONValue = ["b": 2, "a": [true, nil, "x", 1.5]]
        #expect(value.jsonString() == #"{"a":[true,null,"x",1.5],"b":2}"#)
        #expect(try JSONValue(data: value.encoded()) == value)
        #expect(value["a"][3].doubleValue == 1.5)
        #expect(value["b"].intValue == 2)
        #expect(value["missing"].isNull)
    }

    @Test func theFakeTransportRecordsAndAnswersInOrder() async throws {
        let transport = FakeElevenLabsTransport(replies: [
            .json(["ok": true]), .audio(Data([1, 2, 3])),
        ])
        defer { transport.removeTemporaryFiles() }
        let first = try await transport.send(Self.request("/v1/user", handling: .memory(limit: 1_000)))
        #expect(first.status == 200)
        guard case .data(let data) = first.body else { Issue.record("expected data"); return }
        #expect(try JSONValue(data: data) == ["ok": true])

        let second = try await transport.send(Self.request("/v1/audio", handling: .file(limit: 1_000)))
        guard case .file(let url) = second.body else { Issue.record("expected a file"); return }
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
        #expect(transport.requests.map(\.url.path) == ["/v1/user", "/v1/audio"])

        let third = try await transport.send(Self.request("/v1/more", handling: .memory(limit: 1_000)))
        #expect(third.status == 599)
    }

    @Test func theKeyGoesToExactlyTheFiveElevenLabsHosts() {
        #expect(ElevenLabsRegion.allowedHosts == [
            "api.elevenlabs.io", "api.us.elevenlabs.io", "api.eu.residency.elevenlabs.io",
            "api.in.residency.elevenlabs.io", "api.sg.residency.elevenlabs.io",
        ])
        for region in ElevenLabsRegion.allCases {
            #expect(region.baseURL.scheme == "https")
            #expect(region.baseURL.host == region.host)
            #expect(region.webSocketBaseURL.absoluteString == "wss://\(region.host)")
        }
        #expect(ElevenLabsRegion.allCases.filter(\.isResidency) == [.eu, .india, .singapore])
    }

    @Test func theFakeTransportRefusesAnyOtherHostAndPlainHTTP() async {
        let transport = FakeElevenLabsTransport(replies: [.json(["ok": true])])
        for url in ["https://example.com/v1/user", "http://api.elevenlabs.io/v1/user"] {
            var request = Self.request("/v1/user", handling: .memory(limit: 100))
            request.url = URL(string: url)!
            await #expect(throws: ElevenLabsError.self) { try await transport.send(request) }
        }
        #expect(transport.hostViolations.count == 2)
    }

    @Test func theFakeTransportLimitsWhatItHandsBack() async {
        let transport = FakeElevenLabsTransport(replies: [.audio(Data(count: 2_000))])
        await #expect(throws: ElevenLabsError.self) {
            try await transport.send(Self.request("/v1/audio", handling: .memory(limit: 1_000)))
        }
    }

    @Test func theFakeCredentialCountsReadsAndCanFail() async throws {
        let credential = FakeCredentialSource(key: "fixture-key")
        #expect(try await credential.apiKey() == "fixture-key")
        try await credential.remove()
        #expect(try await credential.apiKey() == nil)
        #expect(credential.reads == 2)
        credential.setFailure(.credentialUnavailable("locked"))
        await #expect(throws: ElevenLabsError.credentialUnavailable("locked")) {
            try await credential.apiKey()
        }
    }

    @Test func theTemporarySinkNamesUniquelyAndRemovesOnlyItsOwnDirectory() throws {
        let sink = TemporaryFileSink()
        defer { sink.removeAll() }
        let operation = ElevenLabsOperation(
            id: "fixture", method: "GET", path: "/v1/fixture", group: "Fixture", summary: "",
            details: "", deprecated: false, parameters: [], body: nil, response: .audio,
            risk: .read, billable: false, returnsCredential: false, supportsStreaming: false
        )
        let first = try sink.destination(for: operation, suggestedName: "a/b.mp3", contentType: "audio/mpeg")
        try Data([1]).write(to: first)
        let second = try sink.destination(for: operation, suggestedName: "a/b.mp3", contentType: "audio/mpeg")
        #expect(first.lastPathComponent == "a-b.mp3")
        #expect(second.lastPathComponent == "a-b 2.mp3")
        #expect(first.deletingLastPathComponent() == sink.directory)
        sink.removeAll()
        #expect(!FileManager.default.fileExists(atPath: sink.directory.path))
    }

    @Test func settingsWrittenBeforeElevenLabsStillLoadWithItsDefaults() throws {
        let old = #"{"temperature":0.5,"lastTab":"Models"}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(settings.temperature == 0.5)
        #expect(settings.elevenLabsLinked == false)
        #expect(settings.elevenLabsRegion == .global)
        #expect(settings.elevenLabsAllowRiskyForAgents == false)
    }

    @Test func anUnknownRegionFallsBackToTheDefaultWithoutLosingTheRest() throws {
        let stored = #"{"temperature":0.5,"elevenLabsRegion":"api.example.com","elevenLabsLinked":true}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(stored.utf8))
        #expect(settings.elevenLabsRegion == .global)
        #expect(settings.elevenLabsLinked)
        #expect(settings.temperature == 0.5)
    }

    @MainActor
    @Test func anAppModelBuiltForATestHasNothingRealBehindIt() async {
        let model = AppModel(settings: .init())
        #expect(model.elevenLabsLink.store is FakeCredentialSource)
        #expect(model.elevenLabsLink.transport is UnavailableElevenLabsTransport)
        #expect(!model.elevenLabsLink.persistsSettings)
        #expect(!model.elevenLabsLinked)
        #expect(model.elevenLabsClient == nil)

        // Connect against the inert transport fails without the seconds of backoff a real
        // network failure earns, and stores nothing.
        #expect(model.elevenLabsLink.limits.firstBackoff <= 0.01)
        #expect(model.elevenLabsLink.limits.longestRetryWait <= 0.05)
        await #expect(throws: ElevenLabsError.self) { try await model.linkElevenLabs(key: "sk_" + "inert_0000000000") }
        #expect(!model.elevenLabsLinked)
        TemporaryFileSink.removeScratch(model.elevenLabsOutputDirectory)
    }

    static func request(_ path: String, handling: ElevenLabsRequest.ResponseHandling) -> ElevenLabsRequest {
        ElevenLabsRequest(
            operationID: "fixture", method: "GET",
            url: URL(string: "https://api.elevenlabs.io\(path)")!, headers: [:], body: .none,
            timeout: 10, responseHandling: handling
        )
    }
}
